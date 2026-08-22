#!/usr/bin/env bash
# scripts/panel-review.sh — the SOLE sanctioned adversarial-review seat runner
# (ADR-087 D3a). Every agent that used to call gmn_call/oair_call directly
# now routes through this script so a genuine cross-family review call
# produces a receipt a gate can check.
#
# USAGE
#   scripts/panel-review.sh <seat> (--subject <path> | --diff <base>..<head>)
#                           [--prompt-file <p>] [--out <p>]
#
#   <seat> in architecture-critic | red-team | reviewer | security-auditor
#          | product-critic
#
#   --subject and --diff are MUTUALLY EXCLUSIVE and exactly one is REQUIRED.
#     --subject <path>       -> mints subject.kind "artifact" (satisfies G1)
#     --diff <base>..<head>  -> mints subject.kind "patch"    (satisfies G2)
#
# STDIN IS THE CONTEXT CHANNEL. Whatever is piped in is forwarded to the
# vendor lib byte-for-byte, exactly as gmn_call/oair_call already consume it
# (D3a). The existing agent pattern keeps working unchanged:
#   { echo "PLAN:"; cat plan.md; cat docs/ADRs/*.md; } \
#     | scripts/panel-review.sh architecture-critic --subject docs/ADRs/087-….md
#
# Seat -> vendor resolution (ADR-025's order: env > config > built-in
# default). A Claude-family model id is REFUSED at resolution and falls back
# to the non-Claude default.
#
# This script computes every hash ITSELF (D3e, via lib/receipt.sh). It NEVER
# accepts a hash, a base_commit, or a reviewed_head from its caller as a
# value to record — there is no flag for any of those; --diff's refs are
# resolved here and re-printed as full 40-hex.
#
# On HTTP 200 AND every D3f non-vacuity floor: prints the critique to stdout
# (or --out), then exactly one final line on stdout:
#   REVIEW_EVIDENCE:v1 <base64-json>
# On every degraded path (call failure, or any floor unmet): non-zero exit,
# NO evidence line, and the error text names the vendor and the HTTP status.
set -uo pipefail

# SCRIPT_DIR is where THIS script (and its vendor libs) live -- the stack's
# own install location, used only to locate sibling libs. REPO_ROOT is the
# TARGET repo under review, resolved from the current working directory
# exactly like scripts/lib/review-router.sh -- panel-review.sh is invoked
# from inside whatever repo is being reviewed, which need not be this stack.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$REPO_ROOT" ]]; then
  echo "panel-review.sh: not inside a git repository" >&2
  exit 4
fi

RECEIPT_LIB="$STACK_ROOT/lib/receipt.sh"
[[ -f "$RECEIPT_LIB" ]] || RECEIPT_LIB="$HOME/.claude/lib/receipt.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/usage-check-common.sh" 2>/dev/null || { echo "panel-review.sh: cannot load usage-check-common.sh" >&2; exit 3; }
# shellcheck source=/dev/null
source "$RECEIPT_LIB" 2>/dev/null || { echo "panel-review.sh: cannot load lib/receipt.sh" >&2; exit 3; }

PR_MAX_INPUT_BYTES="${PR_MAX_INPUT_BYTES:-700000}"
PR_CLAUDE_RE='claude|anthropic|opus|sonnet|haiku|fable'

usage() {
  cat >&2 <<'EOF'
Usage: panel-review.sh <seat> (--subject <path> | --diff <base>..<head>)
                        [--prompt-file <p>] [--out <p>]
  seat in architecture-critic | red-team | reviewer | security-auditor | product-critic
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
SEAT="$1"; shift
case "$SEAT" in
  architecture-critic|red-team|reviewer|security-auditor|product-critic) : ;;
  *) echo "panel-review.sh: unknown seat '$SEAT'" >&2; usage ;;
esac

SUBJECT_PATH=""
DIFF_SPEC=""
PROMPT_FILE=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT_PATH="${2:-}"; shift 2 ;;
    --diff) DIFF_SPEC="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --out) OUT_FILE="${2:-}"; shift 2 ;;
    *) echo "panel-review.sh: unrecognized argument '$1'" >&2; usage ;;
  esac
done

if [[ -n "$SUBJECT_PATH" && -n "$DIFF_SPEC" ]]; then
  echo "panel-review.sh: --subject and --diff are mutually exclusive" >&2; usage
fi
if [[ -z "$SUBJECT_PATH" && -z "$DIFF_SPEC" ]]; then
  echo "panel-review.sh: exactly one of --subject or --diff is required" >&2; usage
fi

# ── Subject resolution — this script computes every hash itself ────────────
REPO_HASH="$(uc_repo_hash "$REPO_ROOT")"
MINT_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null || echo "")"

SUBJECT_KIND=""
SUBJECT_SHA=""
SUBJECT_NORM_PATH=""
BASE_COMMIT=""
REVIEWED_HEAD=""

if [[ -n "$SUBJECT_PATH" ]]; then
  SUBJECT_KIND="artifact"
  SUBJECT_NORM_PATH="${SUBJECT_PATH#./}"
  # The subject must live inside the repo under review. Without this, a
  # receipt could be keyed to `../secret` — a file outside the repo the gate
  # will later check (cross-family review finding). The minter enforces the
  # same rule; both paths agree so neither can be the loose one.
  if [[ "$SUBJECT_NORM_PATH" == /* ]]; then
    echo "panel-review.sh: subject must be repo-relative, not absolute: $SUBJECT_NORM_PATH" >&2
    exit 4
  fi
  case "/$SUBJECT_NORM_PATH/" in
    */../*)
      echo "panel-review.sh: subject must stay inside the repo (no '..'): $SUBJECT_NORM_PATH" >&2
      exit 4 ;;
  esac
  ABS="$REPO_ROOT/$SUBJECT_NORM_PATH"
  if [[ -L "$ABS" || -d "$ABS" ]]; then
    echo "panel-review.sh: subject-not-a-regular-file: $SUBJECT_NORM_PATH" >&2
    exit 4
  fi
  SUBJECT_SHA="$(rcpt_artifact_sha "$REPO_ROOT" "$SUBJECT_NORM_PATH")"
  if [[ -z "$SUBJECT_SHA" ]]; then
    echo "panel-review.sh: subject-not-a-regular-file: $SUBJECT_NORM_PATH" >&2
    exit 4
  fi
else
  SUBJECT_KIND="patch"
  BASE_RAW="${DIFF_SPEC%%..*}"
  HEAD_RAW="${DIFF_SPEC##*..}"
  if [[ -z "$BASE_RAW" || -z "$HEAD_RAW" || "$BASE_RAW" == "$DIFF_SPEC" ]]; then
    echo "panel-review.sh: --diff requires <base>..<head>" >&2; usage
  fi
  BASE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${BASE_RAW}^{commit}" 2>/dev/null || echo "")"
  REVIEWED_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${HEAD_RAW}^{commit}" 2>/dev/null || echo "")"
  if [[ -z "$BASE_COMMIT" || -z "$REVIEWED_HEAD" ]]; then
    echo "panel-review.sh: could not resolve --diff refs '$DIFF_SPEC' to commits" >&2
    exit 4
  fi
  SUBJECT_SHA="$(rcpt_patch_sha "$REPO_ROOT" "$BASE_COMMIT" "$REVIEWED_HEAD")"
  if [[ -z "$SUBJECT_SHA" ]]; then
    echo "panel-review.sh: could not compute patch hash for $BASE_COMMIT..$REVIEWED_HEAD" >&2
    exit 4
  fi
fi

# ── Seat -> vendor resolution (env > config > built-in default) ────────────
# Built-in defaults, matching config/model-routing.json's subagent_assignments
# as of ADR-087 rev 3.
_pr_default_vendor() {
  case "$1" in
    architecture-critic|red-team) echo "gemini" ;;
    reviewer|security-auditor|product-critic) echo "openai" ;;
  esac
}
_pr_default_model() {
  case "$1" in
    architecture-critic|red-team) echo "gemini-3.1-pro-preview" ;;
    reviewer|security-auditor|product-critic) echo "gpt-5.6-terra" ;;
  esac
}

_pr_env_name() {
  local up; up="$(echo "$1" | LC_ALL=C tr '[:lower:]-' '[:upper:]_')"
  echo "PANEL_MODEL_${up}"
}

resolve_seat() {
  local seat="$1" env_name val vendor model cfg
  env_name="$(_pr_env_name "$seat")"
  eval "val=\${$env_name:-}"
  if [[ -z "$val" ]]; then
    cfg="$REPO_ROOT/config/model-routing.json"
    [[ -f "$cfg" ]] || cfg="$HOME/.claude/config/model-routing.json"
    if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
      val="$(jq -r --arg s "$seat" '.subagent_assignments[$s].primary // empty' "$cfg" 2>/dev/null)"
    fi
  fi
  if [[ -n "$val" && "$val" == */* ]]; then
    local prov="${val%%/*}" mdl="${val#*/}"
    case "$prov" in
      gemini) vendor="gemini" ;;
      codex|openai) vendor="openai" ;;
      *) vendor="" ;;
    esac
    model="$mdl"
  fi
  if [[ -z "${vendor:-}" || -z "${model:-}" ]]; then
    vendor="$(_pr_default_vendor "$seat")"
    model="$(_pr_default_model "$seat")"
  fi
  if echo "$model" | grep -qiE "$PR_CLAUDE_RE"; then
    echo "panel-review.sh: REFUSED Claude-family model '$model' for seat '$seat' — using non-Claude default." >&2
    vendor="$(_pr_default_vendor "$seat")"
    model="$(_pr_default_model "$seat")"
  fi
  PR_VENDOR="$vendor"
  PR_MODEL="$model"
}
resolve_seat "$SEAT"

# ── Built-in seat prompts (used only when --prompt-file absent) ────────────
_pr_default_prompt() {
  case "$1" in
    architecture-critic)
      echo "Adversarially review this architectural plan/artifact against the existing architecture. Check: consistency; whether it introduces a new pattern where an existing one would do; what it locks the system into globally; whether a past ADR is contradicted or silently reversed; where complexity moves to; cross-repo implications. Generate 1-2 grounded counter-proposals. Output: challenges + alternatives, severity-ranked." ;;
    red-team)
      echo "Red-team this change. Assume an adversarial user or a prompt-injected same-user agent. Find every bypass, every unchecked boundary, every place a control's own disable path is reachable by the thing it gates. Output: attack -> effect -> severity, ranked." ;;
    reviewer)
      echo "Adversarially review the diff below. Check correctness, edge cases, security, error handling, performance, concurrency/idempotency, and dependency risk. Output findings as BLOCKING / NON-BLOCKING / NIT with file:line and a one-line why." ;;
    security-auditor)
      echo "Security-audit the diff below. Check injection, auth bypass, secret leakage, RLS/authz holes, crypto misuse, and supply-chain risk. Output findings as CRITICAL/HIGH/MEDIUM/LOW with file:line and a one-line why." ;;
    product-critic)
      echo "Critique the diff below from a product/UX lens: does it solve the stated problem, what edge case does the happy path miss, what would confuse a real user. Output findings ranked by user impact." ;;
  esac
}

PROMPT_TEXT=""
if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "panel-review.sh: --prompt-file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
else
  PROMPT_TEXT="$(_pr_default_prompt "$SEAT")"
fi

# ── Assemble the FULL text this runner sends, once, so prompt_sha256 /
# prompt_bytes describe exactly what is actually sent (BLOCKER 2's regression
# test, case 14/19). Context arrives on stdin, forwarded byte-for-byte.
CONTEXT_TEXT=""
if [[ ! -t 0 ]]; then CONTEXT_TEXT="$(cat)"; fi
FULL_TEXT="$PROMPT_TEXT"
if [[ -n "$CONTEXT_TEXT" ]]; then
  FULL_TEXT="${PROMPT_TEXT}"$'\n\n--- context ---\n'"${CONTEXT_TEXT}"
fi
# A truncated request is NOT a review of this subject, and must never mint a
# receipt for it (red-team finding 8): the vendor would see a prefix while
# the receipt is keyed to the hash of the whole thing, so prepending enough
# padding hides anything past the cut behind a genuine-looking approval.
# Refuse instead of silently reviewing less than the subject.
if (( ${#FULL_TEXT} > PR_MAX_INPUT_BYTES )); then
  printf 'panel-review.sh: context is %s bytes, over the %s-byte limit.\n' \
    "${#FULL_TEXT}" "$PR_MAX_INPUT_BYTES" >&2
  printf 'A truncated request cannot mint a receipt — the vendor would see less than the subject it attests to.\n' >&2
  printf 'Narrow the subject (fewer files, a smaller --diff range) and run the seat again.\n' >&2
  exit 5
fi
PROMPT_BYTES="${#FULL_TEXT}"
PROMPT_SHA256="$(printf '%s' "$FULL_TEXT" | shasum -a 256 | cut -d' ' -f1)"

# ── Sidecar setup (D3b): caller-created via mktemp, truncated before the
# call, chmod 0600, read once, deleted. Never an exported global.
PR_SIDECAR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/panel-review.XXXXXX" 2>/dev/null)" || { echo "panel-review.sh: mktemp -d failed" >&2; exit 3; }
trap 'rm -rf "$PR_SIDECAR_DIR"' EXIT
SIDECAR="$PR_SIDECAR_DIR/evidence.json"
: > "$SIDECAR"
chmod 0600 "$SIDECAR" 2>/dev/null || true

CALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CRITIQUE=""
CALL_RC=0

# Vendor lib paths are overridable (PR_GEMINI_LIB / PR_OPENAI_LIB) so the test
# suite can point them at a stubbed lib exposing the same gmn_call/oair_call
# contract — no other part of this script's behavior changes under a stub.
PR_GEMINI_LIB="${PR_GEMINI_LIB:-$SCRIPT_DIR/lib/gemini-api.sh}"
PR_OPENAI_LIB="${PR_OPENAI_LIB:-$SCRIPT_DIR/lib/openai-review.sh}"

if [[ "$PR_VENDOR" == "gemini" ]]; then
  export GMN_EVIDENCE_OUT="$SIDECAR"
  export GEMINI_API_MODEL="$PR_MODEL"
  # shellcheck source=/dev/null
  source "$PR_GEMINI_LIB" 2>/dev/null || { echo "panel-review.sh: could not load gemini-api.sh" >&2; exit 3; }
  CRITIQUE="$(gmn_call "$FULL_TEXT" < /dev/null)"; CALL_RC=$?
  VENDOR_LABEL="Gemini"
else
  # shellcheck source=/dev/null
  source "$PR_OPENAI_LIB" 2>/dev/null || { echo "panel-review.sh: could not load openai-review.sh" >&2; exit 3; }
  export OAIR_EVIDENCE_OUT="$SIDECAR"
  export REVIEW_CODEX_TRANSPORT="api"   # D3f's floors need HTTP status/usage; force the API transport
  CRITIQUE="$(oair_call "$FULL_TEXT" "$PR_MODEL" "" < /dev/null)"; CALL_RC=$?
  VENDOR_LABEL="OpenAI"
fi

if [[ "$CALL_RC" -ne 0 ]]; then
  echo "panel-review.sh: ${VENDOR_LABEL} call degraded (seat=${SEAT}, rc=${CALL_RC}): ${CRITIQUE}" >&2
  exit 6
fi

# rc 0 but no/empty sidecar after a real call is itself a failure (D3b) — the
# vendor lib's own success path always writes one on http 200.
if [[ ! -s "$SIDECAR" ]] || ! jq -e . "$SIDECAR" >/dev/null 2>&1; then
  echo "panel-review.sh: ${VENDOR_LABEL} call reported success but wrote no evidence sidecar — nothing minted." >&2
  exit 7
fi

SIDECAR_JSON="$(cat "$SIDECAR")"
rm -f "$SIDECAR" 2>/dev/null

HTTP_STATUS="$(echo "$SIDECAR_JSON" | jq -r '.http_status // 0' 2>/dev/null)"
FAMILY="$(echo "$SIDECAR_JSON" | jq -r '.family // "unknown"' 2>/dev/null)"
VENDOR="$(echo "$SIDECAR_JSON" | jq -r '.vendor // "unknown"' 2>/dev/null)"
MODEL_REQUESTED="$(echo "$SIDECAR_JSON" | jq -r '.model_requested // empty' 2>/dev/null)"
MODEL_RETURNED="$(echo "$SIDECAR_JSON" | jq -r '.model_returned // empty' 2>/dev/null)"
RESPONSE_ID="$(echo "$SIDECAR_JSON" | jq -r '.response_id // empty' 2>/dev/null)"
INPUT_TOKENS="$(echo "$SIDECAR_JSON" | jq -r '.usage.input_tokens // 0' 2>/dev/null)"
OUTPUT_TOKENS="$(echo "$SIDECAR_JSON" | jq -r '.usage.output_tokens // 0' 2>/dev/null)"

OUTPUT_BYTES="${#CRITIQUE}"
OUTPUT_SHA256="$(printf '%s' "$CRITIQUE" | shasum -a 256 | cut -d' ' -f1)"

# ── D3f non-vacuity floors, checked here (mint time re-checks at gate time) ─
FLOOR_FAIL=""
[[ "$HTTP_STATUS" != "200" ]] && FLOOR_FAIL="http_status=${HTTP_STATUS}"
[[ -z "$FLOOR_FAIL" && "$PROMPT_BYTES" -lt 1000 ]] && FLOOR_FAIL="prompt_bytes=${PROMPT_BYTES} < 1000"
[[ -z "$FLOOR_FAIL" && "$OUTPUT_BYTES" -lt 500 ]] && FLOOR_FAIL="output_bytes=${OUTPUT_BYTES} < 500"
[[ -z "$FLOOR_FAIL" && "$OUTPUT_TOKENS" -lt 100 ]] && FLOOR_FAIL="usage.output_tokens=${OUTPUT_TOKENS} < 100"
if [[ -z "$FLOOR_FAIL" ]] && echo "$FAMILY" | grep -qiE "$PR_CLAUDE_RE"; then
  FLOOR_FAIL="family=${FAMILY} is Claude-family"
fi
if [[ -n "$FLOOR_FAIL" ]]; then
  echo "panel-review.sh: ${VENDOR_LABEL} call returned but failed a non-vacuity floor (${FLOOR_FAIL}) — nothing minted." >&2
  exit 8
fi

# ── Print the critique ──────────────────────────────────────────────────────
if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$CRITIQUE" > "$OUT_FILE"
else
  printf '%s\n' "$CRITIQUE"
fi

EVIDENCE_JSON="$(jq -nc \
  --arg schema "review-evidence/v1" \
  --arg seat "$SEAT" \
  --arg vendor "$VENDOR" \
  --arg family "$FAMILY" \
  --arg model_requested "$MODEL_REQUESTED" \
  --arg model_returned "$MODEL_RETURNED" \
  --argjson http_status "$HTTP_STATUS" \
  --arg response_id "$RESPONSE_ID" \
  --argjson input_tokens "$INPUT_TOKENS" \
  --argjson output_tokens "$OUTPUT_TOKENS" \
  --arg subject_kind "$SUBJECT_KIND" \
  --arg subject_path "$SUBJECT_NORM_PATH" \
  --arg subject_sha "$SUBJECT_SHA" \
  --arg base_commit "$BASE_COMMIT" \
  --arg reviewed_head "$REVIEWED_HEAD" \
  --arg prompt_sha256 "$PROMPT_SHA256" \
  --argjson prompt_bytes "$PROMPT_BYTES" \
  --arg output_sha256 "$OUTPUT_SHA256" \
  --argjson output_bytes "$OUTPUT_BYTES" \
  --arg called_at "$CALLED_AT" \
  '{schema:$schema, seat:$seat, vendor:$vendor, family:$family,
    model_requested:$model_requested,
    model_returned:(if $model_returned == "" then $model_requested else $model_returned end),
    http_status:$http_status, response_id:(if $response_id == "" then null else $response_id end),
    usage:{input_tokens:$input_tokens, output_tokens:$output_tokens},
    subject_kind:$subject_kind,
    subject_path:(if $subject_path == "" then null else $subject_path end),
    subject_sha:$subject_sha,
    base_commit:(if $base_commit == "" then null else $base_commit end),
    reviewed_head:(if $reviewed_head == "" then null else $reviewed_head end),
    prompt_sha256:$prompt_sha256, prompt_bytes:$prompt_bytes,
    output_sha256:$output_sha256, output_bytes:$output_bytes,
    called_at:$called_at}' 2>/dev/null)"

if [[ -z "$EVIDENCE_JSON" ]]; then
  echo "panel-review.sh: could not assemble evidence JSON — nothing minted." >&2
  exit 9
fi

ENCODED="$(printf '%s' "$EVIDENCE_JSON" | base64 | tr -d '\n')"
printf 'REVIEW_EVIDENCE:v1 %s\n' "$ENCODED"
exit 0
