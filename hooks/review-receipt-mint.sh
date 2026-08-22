#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash) — observes a genuine scripts/panel-review.sh
# invocation and mints a review receipt the agent cannot write directly
# (state/attest/** is denyWrite-protected, ADR-087 D14). A sibling of
# hooks/usage-check-token.sh, copying its three hard-won details: (1)
# tool_response's shape varies across tools/harness versions; (2) a
# provenance check before minting; (3) mint once per marker line, not once
# per payload. ADR-087 D3d.
#
# Rev-2 additions (audit finding 1's fix): the minter RECOMPUTES subject_sha
# itself from subject_path+repo_root (artifact) or base_commit/reviewed_head
# (patch) — using the SAME helpers (lib/receipt.sh) the gate uses at
# re-derivation time, so the two paths cannot drift. If the recomputed value
# differs from the payload's claim, NOTHING is minted. as_of and
# mint_head_commit come from THIS hook's own clock/git HEAD, never the
# payload. D3f's non-vacuity floors are re-enforced here, at mint time.
#
# Provenance remains a command-string pattern naming panel-review.sh, with
# its honest label: friction, not authentication (D2).
#
# Fail-open, always exit 0 — this hook can only decline to mint; it can
# never block a Bash call. A missed mint surfaces later as a gate deny with
# a compliant-path remedy, never as a silent gap.
# summary: Mints a review receipt from a genuine scripts/panel-review.sh run observed in Bash output.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_LIB="$DIR/../lib/receipt.sh"
[[ -f "$RECEIPT_LIB" ]] || RECEIPT_LIB="$HOME/.claude/lib/receipt.sh"
USAGE_LIB="$DIR/../scripts/lib/usage-check-common.sh"
[[ -f "$USAGE_LIB" ]] || USAGE_LIB="$HOME/.claude/scripts/lib/usage-check-common.sh"
# shellcheck source=/dev/null
source "$RECEIPT_LIB" 2>/dev/null || exit 0
# shellcheck source=/dev/null
source "$USAGE_LIB" 2>/dev/null || exit 0

# The real jq/git must win the PATH lookup, not a planted lookalike that
# feeds this minter fabricated fields (red-team finding 2).
declare -F rcpt_pin_path >/dev/null 2>&1 && rcpt_pin_path

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# tool_response's shape is not guaranteed — probe the known shapes, then
# scan the raw payload as a last resort (usage-check-token.sh:29-41 pattern).
STDOUT="$(echo "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response.stdout // empty) != "" then .tool_response.stdout
  elif (.tool_response.output // empty) != "" then .tool_response.output
  elif (.tool_response.content // empty) != "" then (.tool_response.content | if type == "string" then . else tostring end)
  else empty end
' 2>/dev/null)"
if [[ "$STDOUT" != *"REVIEW_EVIDENCE:v1 "* && "$INPUT" == *"REVIEW_EVIDENCE:v1 "* ]]; then
  STDOUT="$(echo "$INPUT" | jq -r '[.. | strings] | join("\n")' 2>/dev/null)"
fi

# Fast path out: the common case (any Bash call that isn't panel-review.sh)
# must be a two-comparison no-op.
[[ "$STDOUT" == *"REVIEW_EVIDENCE:v1 "* ]] || exit 0

COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$CWD" ]] || CWD="$PWD"

# Provenance check: the command must actually invoke panel-review.sh.
# Best-effort by design (pattern match, not attestation) — the gate's own
# re-derivation independently catches fabricated evidence regardless.
case "$COMMAND" in
  *panel-review.sh*) : ;;
  *) exit 0 ;;
esac

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -n "$REPO_ROOT" ]] || exit 0
REPO_HASH="$(uc_repo_hash "$REPO_ROOT")"
MINT_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null || echo "")"

if declare -F rcpt_safe_conf_dir >/dev/null 2>&1; then
  CONF_DIR="$(rcpt_safe_conf_dir)"
else
  CONF_DIR="${HOME:-}/.claude"
fi

PR_CLAUDE_RE='claude|anthropic|opus|sonnet|haiku|fable'

mint_one() {
  local marker_b64="$1"
  local decoded
  decoded="$(printf '%s' "$marker_b64" | base64 -d 2>/dev/null)"
  [[ -n "$decoded" ]] || return 0
  echo "$decoded" | jq -e '
    .schema == "review-evidence/v1" and .seat and .vendor and .family
    and .http_status != null and .subject_kind and .subject_sha
    and .prompt_bytes != null and .output_bytes != null and .usage.output_tokens != null
  ' >/dev/null 2>&1 || return 0

  local seat vendor family http_status subject_kind subject_path claimed_sha
  local base_commit reviewed_head prompt_bytes output_bytes output_tokens
  seat="$(echo "$decoded" | jq -r '.seat')"
  vendor="$(echo "$decoded" | jq -r '.vendor')"
  family="$(echo "$decoded" | jq -r '.family')"
  http_status="$(echo "$decoded" | jq -r '.http_status')"
  subject_kind="$(echo "$decoded" | jq -r '.subject_kind')"
  subject_path="$(echo "$decoded" | jq -r '.subject_path // empty')"
  claimed_sha="$(echo "$decoded" | jq -r '.subject_sha')"
  base_commit="$(echo "$decoded" | jq -r '.base_commit // empty')"
  reviewed_head="$(echo "$decoded" | jq -r '.reviewed_head // empty')"
  prompt_bytes="$(echo "$decoded" | jq -r '.prompt_bytes')"
  output_bytes="$(echo "$decoded" | jq -r '.output_bytes')"
  output_tokens="$(echo "$decoded" | jq -r '.usage.output_tokens')"

  case "$seat" in
    architecture-critic|red-team|reviewer|security-auditor|product-critic) : ;;
    *) return 0 ;;
  esac
  case "$subject_kind" in
    artifact|patch) : ;;
    *) return 0 ;;
  esac

  # ── D3f non-vacuity floors, re-enforced at mint time ──────────────────────
  [[ "$http_status" == "200" ]] || return 0
  [[ "$prompt_bytes" =~ ^[0-9]+$ ]] && (( prompt_bytes >= 1000 )) || return 0
  [[ "$output_bytes" =~ ^[0-9]+$ ]] && (( output_bytes >= 500 )) || return 0
  [[ "$output_tokens" =~ ^[0-9]+$ ]] && (( output_tokens >= 100 )) || return 0
  echo "$family" | grep -qiE "$PR_CLAUDE_RE" && return 0

  # ── Recompute the subject hash ourselves — never trust the payload's claim ─
  local recomputed=""
  if [[ "$subject_kind" == "artifact" ]]; then
    [[ -n "$subject_path" ]] || return 0
    # The subject must live inside the repo under review. An absolute path or
    # a `..` escape would let a receipt be keyed to a file outside it
    # entirely (cross-family review finding).
    [[ "$subject_path" == /* ]] && return 0
    case "/$subject_path/" in */../*) return 0 ;; esac
    recomputed="$(rcpt_artifact_sha "$REPO_ROOT" "$subject_path" 2>/dev/null)"
  else
    [[ -n "$base_commit" && -n "$reviewed_head" ]] || return 0
    [[ "$base_commit" =~ ^[0-9a-f]{40}$ && "$reviewed_head" =~ ^[0-9a-f]{40}$ ]] || return 0
    git -C "$REPO_ROOT" rev-parse --verify --quiet "${base_commit}^{commit}" >/dev/null 2>&1 || return 0
    git -C "$REPO_ROOT" rev-parse --verify --quiet "${reviewed_head}^{commit}" >/dev/null 2>&1 || return 0

    # BIND THE RECEIPT TO THIS HOOK'S OWN HEAD (red-team finding 3).
    # Recomputing the hash from refs the PAYLOAD names only proves the
    # payload is internally consistent: an agent that picks its own
    # base_commit/reviewed_head gets a hash that matches its own claim, and
    # the mint succeeds. A receipt may only ever describe the state this
    # hook can see right now -- reviewed_head IS our HEAD, and base_commit
    # is an ancestor of it.
    [[ -n "$MINT_HEAD" ]] || return 0
    [[ "$reviewed_head" == "$MINT_HEAD" ]] || return 0
    git -C "$REPO_ROOT" merge-base --is-ancestor "$base_commit" "$MINT_HEAD" 2>/dev/null || return 0

    recomputed="$(rcpt_patch_sha "$REPO_ROOT" "$base_commit" "$reviewed_head" 2>/dev/null)"
  fi
  [[ -n "$recomputed" && "$recomputed" == "$claimed_sha" ]] || return 0

  # ── Assemble the receipt — as_of/mint_head_commit are THIS hook's own,
  # every free-text field sanitized at write time ─────────────────────────
  local as_of receipt_json
  as_of="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local san_model_req san_model_ret san_response_id
  san_model_req="$(rcpt_sanitize "$(echo "$decoded" | jq -r '.model_requested // ""')" 200)"
  san_model_ret="$(rcpt_sanitize "$(echo "$decoded" | jq -r '.model_returned // ""')" 200)"
  san_response_id="$(rcpt_sanitize "$(echo "$decoded" | jq -r '.response_id // ""')" 200)"

  # ── Bound the evidence payload before it is persisted ────────────────────
  # The whole decoded object used to be embedded as-is, with only the three
  # fields above sanitized. Everything else -- unknown keys, nested objects,
  # megabyte strings, control characters -- landed verbatim under the
  # protected receipt path and was read back by the board and org-check
  # (cross-family review finding). Keep the closed set of fields a consumer
  # actually reads, drop the rest, and cap what survives.
  local bounded
  bounded="$(echo "$decoded" | jq -c '{
    schema, seat, vendor, family, http_status, subject_kind, subject_sha,
    base_commit, reviewed_head, prompt_sha256, prompt_bytes, output_bytes,
    latency_ms,
    usage: {output_tokens: (.usage.output_tokens // null),
            input_tokens:  (.usage.input_tokens  // null)}
  } | with_entries(select(.value != null))' 2>/dev/null)"
  [[ -n "$bounded" ]] || return 0
  # A bounded object is still an object of unbounded SIZE if a field is a
  # huge string; refuse rather than persist one.
  (( ${#bounded} <= 4096 )) || return 0
  decoded="$bounded"

  receipt_json="$(jq -nc \
    --arg subject_kind "$subject_kind" \
    --arg path "$subject_path" \
    --arg content_sha "$([[ "$subject_kind" == "artifact" ]] && echo "$recomputed" || echo "")" \
    --arg patch_sha "$([[ "$subject_kind" == "patch" ]] && echo "$recomputed" || echo "")" \
    --arg base_commit "$base_commit" \
    --arg reviewed_head "$reviewed_head" \
    --arg repo_root "$REPO_ROOT" \
    --arg repo_hash "$REPO_HASH" \
    --arg mint_head "$MINT_HEAD" \
    --arg as_of "$as_of" \
    --argjson evidence "$decoded" \
    --arg model_req "$san_model_req" --arg model_ret "$san_model_ret" --arg response_id "$san_response_id" \
    '{
      schema: "stack-receipt/v1", kind: "review", writer: "review-receipt-mint.sh@1",
      as_of: $as_of, max_age_s: 604800,
      subject: {
        kind: $subject_kind,
        path: (if $path == "" then null else $path end),
        content_sha: (if $content_sha == "" then null else $content_sha end),
        patch_sha: (if $patch_sha == "" then null else $patch_sha end),
        base_commit: (if $base_commit == "" then null else $base_commit end),
        reviewed_head: (if $reviewed_head == "" then null else $reviewed_head end),
        repo_root: $repo_root, repo_hash: $repo_hash, mint_head_commit: (if $mint_head == "" then null else $mint_head end)
      },
      verdict: "reviewed", reason: null, needs_human: false,
      evidence: ($evidence + {model_requested: $model_req, model_returned: $model_ret, response_id: $response_id}),
      error: null
    }' 2>/dev/null)"
  [[ -n "$receipt_json" ]] || return 0

  local receipt_path
  receipt_path="$CONF_DIR/state/attest/reviews/${REPO_HASH}/${subject_kind}/${recomputed}/${seat}.json"
  rcpt_write "$receipt_path" "$receipt_json"
  return 0
}

# Mint once per REVIEW_EVIDENCE:v1 line, not just the last one — a batched
# Bash call can legitimately produce several genuine result lines.
while IFS= read -r LINE; do
  [[ -z "$LINE" ]] && continue
  mint_one "${LINE##*REVIEW_EVIDENCE:v1 }"
done < <(echo "$STDOUT" | grep 'REVIEW_EVIDENCE:v1 ')

exit 0
