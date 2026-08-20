#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash) — observes genuine scripts/usage-check.sh
# invocations and mints a per-target "I checked this" token the agent cannot
# write directly (permission deny rules cover ~/.claude/usage-check/**).
# ADR-057. Fail-open, always exit 0 — this hook can only decline to mint; it
# can never block a Bash call. A missed mint just surfaces later as a gate
# deny with a clear "run the checker" remediation.
#
# Scope statement: this is an accidental-omission control, not a security
# boundary against a hostile or prompt-injected same-user agent.
# summary: Mints a per-target usage-check token from a genuine scripts/usage-check.sh run observed in Bash output.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../scripts/lib/usage-check-common.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/scripts/lib/usage-check-common.sh"
# shellcheck source=/dev/null
source "$LIB" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
# tool_response's shape is not guaranteed across tools or harness versions —
# hooks/subagent-complete-log.sh:18 documents the same variance and handles a
# bare-string tool_response explicitly. Reading only .tool_response.stdout
# would silently yield empty on any other shape, and because this hook's fast
# path exits when the marker is absent, that failure mode is INDISTINGUISHABLE
# FROM "no checker ran": no token, no log row, no error — the whole feature
# inert while every test (which builds its own payload) still passes. So probe
# the known shapes and fall back to the raw payload text.
STDOUT="$(echo "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response.stdout // empty) != "" then .tool_response.stdout
  elif (.tool_response.output // empty) != "" then .tool_response.output
  elif (.tool_response.content // empty) != "" then (.tool_response.content | if type == "string" then . else tostring end)
  else empty end
' 2>/dev/null)"
# Last-resort: if none of the known shapes carried it but the marker is
# somewhere in the payload, scan the raw JSON. Costs one grep on the rare
# path only (the marker is absent from virtually every Bash call).
if [[ "$STDOUT" != *"USAGE_CHECK_RESULT:v1 "* && "$INPUT" == *"USAGE_CHECK_RESULT:v1 "* ]]; then
  STDOUT="$(echo "$INPUT" | jq -r '[.. | strings] | join("\n")' 2>/dev/null)"
fi

# Fast path out: the common case (any Bash call that isn't the checker) must
# be a two-comparison no-op.
[[ "$STDOUT" == *"USAGE_CHECK_RESULT:v1 "* ]] || exit 0

COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
RAW_SID="$(echo "$INPUT" | jq -r '.session_id // env.CLAUDE_CODE_SESSION_ID // empty' 2>/dev/null)"

# Provenance check: the command must actually invoke a trusted checker path.
# Best-effort by design (pattern match, not attestation) — the gate's own
# re-verification independently catches fabricated evidence regardless.
case "$COMMAND" in
  *usage-check.sh*) : ;;
  *) exit 0 ;;
esac

SID="$(uc_sanitize_sid "$RAW_SID")"

# mint_token_from_result_line <base64 payload after the "USAGE_CHECK_RESULT:v1 "
# marker> -> mints one token, or silently does nothing on any validation
# failure. A single Bash call can legitimately run the checker more than
# once (e.g. a loop over several --target values), so the caller invokes
# this once per result line found in stdout — a malformed line among
# several must not stop the others from minting.
mint_token_from_result_line() {
  local result_line="$1"
  local decoded target kind repo_root repo_hash target_hash minted_at token_path token_json tmp_token

  decoded="$(printf '%s' "$result_line" | base64 -d 2>/dev/null)"
  [[ -n "$decoded" ]] || return 0
  echo "$decoded" | jq -e '.schema and .target and .target_kind and .repo_root and .head_commit and .search.pattern and .search.tool and (.search.match_count != null) and .verdict' >/dev/null 2>&1 || return 0

  target="$(echo "$decoded" | jq -r .target)"
  kind="$(echo "$decoded" | jq -r .target_kind)"
  repo_root="$(echo "$decoded" | jq -r .repo_root)"

  repo_hash="$(uc_repo_hash "$repo_root")"
  target_hash="$(uc_target_hash "$kind" "$target")"
  minted_at="$(uc_now_iso)"
  token_path="$(uc_token_path "$repo_hash" "$target_hash" "$SID")"

  mkdir -p "$(dirname "$token_path")" 2>/dev/null
  chmod 0700 "$(dirname "$token_path")" 2>/dev/null

  token_json="$(echo "$decoded" | jq -c \
    --arg schema "usage-check-token/v1" \
    --arg repo_hash "$repo_hash" \
    --arg sid "$SID" \
    --arg minted_at "$minted_at" \
    --argjson ttl 3600 \
    '{schema:$schema, target:.target, target_kind:.target_kind, repo_root:.repo_root,
      repo_hash:$repo_hash, head_commit:.head_commit, session_id:$sid,
      minted_at:$minted_at, ttl_seconds:$ttl, search:.search, graph_hint:.graph_hint,
      verdict:.verdict}' 2>/dev/null)"
  [[ -n "$token_json" ]] || return 0

  tmp_token="${token_path}.tmp.$$.${RANDOM}"
  printf '%s\n' "$token_json" > "$tmp_token" 2>/dev/null && mv "$tmp_token" "$token_path" 2>/dev/null
}

# Mint one token per USAGE_CHECK_RESULT:v1 line in stdout, not just the last
# one — a batched Bash call (e.g. a for-loop running the checker once per
# building-block target, the obvious realization of skills/dispatch/SKILL.md's
# instruction) produces several genuine result lines in one PostToolUse
# payload, and every one of them needs its own token.
while IFS= read -r LINE; do
  [[ -z "$LINE" ]] && continue
  mint_token_from_result_line "${LINE##*USAGE_CHECK_RESULT:v1 }"
done < <(echo "$STDOUT" | grep 'USAGE_CHECK_RESULT:v1 ')

exit 0
