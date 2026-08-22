#!/usr/bin/env bash
# PreToolUse hook (matchers: Agent, Task) — blocks dispatching architect,
# red-team, or reviewer unless every "Usage-check-target:" line in the
# dispatch prompt has a fresh, HEAD-current token AND the gate independently
# invokes the checker tool fresh for that target and confirms the same
# verdict-class (the token's recorded search.* fields are audit data only —
# never read back or replayed; see Step 9 below). ADR-057. Fail-CLOSED past
# the disable-file check (deliberate, stated here
# and in the ADR — see hooks/migration-guard.sh for the sibling precedent of
# a fail-closed friction hook in this stack).
#
# Scope statement: this is an accidental-omission control, not a security
# boundary against a hostile or prompt-injected same-user agent. It exists to
# stop an HONEST workflow from silently skipping the usage check that already
# burned real review-agent spend on unused code in a past incident.
#
# Ordering below is load-bearing. Do not reorder without re-reading why.
# summary: Blocks dispatching architect/red-team/reviewer unless every declared usage-check target has a fresh, re-verified token.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Step 1: machine-wide disable, LITERALLY first ───────────────────────────
# ADR-087 D9 amendment: this file moves under the protected namespace, gains
# a mandatory sanitized reason, and is read from a namespace-checked config
# dir. The old bare `~/.claude/usage-check-gate.disabled` sat outside every
# denyWrite glob, so the gated agent could write its own off-switch.
UCG_RECEIPT_LIB="$DIR/../lib/receipt.sh"
[[ -f "$UCG_RECEIPT_LIB" ]] || UCG_RECEIPT_LIB="$HOME/.claude/lib/receipt.sh"
# shellcheck source=/dev/null
source "$UCG_RECEIPT_LIB" 2>/dev/null || true

# NOTE: this gate deliberately does NOT call rcpt_pin_path. ADR-087 D9's
# amendment is about where these override files LIVE; pinning PATH here would
# change ADR-057's own tool resolution, which is that ADR's call to make, not
# this one's. The PATH-hijack hole therefore still exists in this gate and is
# recorded rather than half-closed.
if declare -F rcpt_safe_conf_dir >/dev/null 2>&1; then
  UCG_CONF_DIR="$(rcpt_safe_conf_dir)"
else
  UCG_CONF_DIR="$HOME/.claude"
fi
UCG_DISABLE_FILE="$UCG_CONF_DIR/state/attest/override/usage-check-gate.disabled"
UCG_LEGACY_DISABLE="$HOME/.claude/usage-check-gate.disabled"

ucg_disable_reason() { # <path> -> echoes sanitized first line, empty if none
  local raw trimmed
  raw="$(head -1 "$1" 2>/dev/null)"
  trimmed="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$trimmed" ]] || return 1
  if declare -F rcpt_sanitize >/dev/null 2>&1; then
    rcpt_sanitize "$raw" 200
  else
    printf '%s' "$trimmed"
  fi
}

if [[ -f "$UCG_DISABLE_FILE" ]]; then
  # An empty file does NOT disable — same rule as the review gate's, so the
  # two overrides cannot behave differently for the same shape of mistake.
  ucg_disable_reason "$UCG_DISABLE_FILE" >/dev/null && exit 0
elif [[ -f "$UCG_LEGACY_DISABLE" ]]; then
  # Migration tolerance (ADR-087 D9): a machine that already disabled this
  # gate the old way is honoured ONCE — not silently re-armed mid-flight,
  # and not silently converted into a permanent off-switch either. Writing
  # the new disable file here would mean a single legacy file (possibly
  # empty, possibly forgotten months ago) turns into a standing disable that
  # nobody chose. Honour it, log it, remove it; a human who wants it
  # permanent writes it again through the documented path.
  UCG_LEGACY_REASON="$(ucg_disable_reason "$UCG_LEGACY_DISABLE" || echo "(legacy: no reason recorded)")"
  # shellcheck source=/dev/null
  source "$DIR/override-log.sh" 2>/dev/null
  if declare -F ovlog_append >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ovlog_append "guard_override" "$PWD" \
      "$(jq -nc --arg hook "usage-check-gate" --arg tier "machine-legacy" --arg reason "$UCG_LEGACY_REASON" \
         '{hook:$hook, tier:$tier, reason:$reason}')"
  fi
  rm -f "$UCG_LEGACY_DISABLE" 2>/dev/null
  exit 0
fi
LIB="$DIR/../scripts/lib/usage-check-common.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/scripts/lib/usage-check-common.sh"
# shellcheck source=/dev/null
if ! source "$LIB" 2>/dev/null; then
  # jq/lib unavailable this early would make every downstream check unsafe.
  # Static fallback deny needs neither jq nor the lib to construct.
  # DELIBERATE, CONFIRMED EXCEPTION: this blocks unconditionally — regardless
  # of agent type or warn/on mode — because the hook cannot even establish
  # what agent or mode it's evaluating. Do not "fix" this to respect warn
  # mode or the architect/red-team/reviewer filter; it is intentional.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"usage-check-gate: internal error loading shared library. Fail-closed."}}\n'
  exit 0
fi

INPUT="$(cat 2>/dev/null || echo '{}')"
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  # DELIBERATE, CONFIRMED EXCEPTION: this blocks unconditionally, same
  # reasoning as the lib-load-failure deny above — an unparseable payload
  # means mode/agent-type cannot be determined either. Not a bug.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"usage-check-gate: could not parse tool payload. Fail-closed."}}\n'
  exit 0
fi

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$CWD" ]] || CWD="$PWD"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
SUBAGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
PROMPT="$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)"
RAW_SID="$(echo "$INPUT" | jq -r '.session_id // env.CLAUDE_CODE_SESSION_ID // empty' 2>/dev/null)"
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"

emit_deny() {
  local reason="$1"
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}' \
    2>/dev/null || true
}

# ── Step 3: agent filter ─────────────────────────────────────────────────────
case "$SUBAGENT" in
  architect|red-team|reviewer) : ;;
  *) exit 0 ;;
esac
[[ "$TOOL_NAME" == "Agent" || "$TOOL_NAME" == "Task" ]] || exit 0

# ── Step 4: mode resolution ──────────────────────────────────────────────────
# Resolution order (design spec §3 step 4): repo stack-config, else
# ~/.claude/stack-defaults.json, else the built-in default "warn". The
# stack-defaults rung is consulted ONLY when the repo config is silent on
# this key (missing entirely, or present without a "guards.usage_check_gate"
# key) — never when the repo config specifies a value itself, valid or not.
resolve_default_mode() {
  local defaults="$HOME/.claude/stack-defaults.json" raw=""
  if [[ -f "$defaults" ]] && jq -e . "$defaults" >/dev/null 2>&1; then
    raw="$(jq -r '.guards.usage_check_gate // empty' "$defaults" 2>/dev/null)"
  fi
  case "$raw" in off|warn|on) echo "$raw" ;; *) echo "warn" ;; esac
}

CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
MODE="warn"
CONFIG_UNPARSEABLE=0
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  if jq -e . "$CONFIG" >/dev/null 2>&1; then
    # `// empty` treats an ABSENT key as "not specified" so the stack-defaults
    # rung below can answer. But jq's `//` also swallows null and false, which
    # would let a repo that wrote an explicitly-invalid value silently inherit
    # a machine-wide "on". Probe for the key's presence separately so an
    # explicitly-invalid value stays a repo decision and resolves to the safe
    # "warn", never falling through to defaults.
    if jq -e 'has("guards") and (.guards | type) == "object" and (.guards | has("usage_check_gate"))' \
         "$CONFIG" >/dev/null 2>&1; then
      RAW_MODE="$(jq -r '.guards.usage_check_gate // empty' "$CONFIG" 2>/dev/null)"
      case "$RAW_MODE" in off|warn|on) MODE="$RAW_MODE" ;; *) MODE="warn" ;; esac
    else
      MODE="$(resolve_default_mode)"
    fi
  else
    CONFIG_UNPARSEABLE=1
    MODE="on"
    # Loud stderr line, per the design spec's Error Handling section: an
    # unparseable config silently escalating a repo to hard-deny is exactly
    # the kind of surprise this gate should never spring. The telemetry row
    # records it too, but a human running a dispatch sees stderr, not JSONL.
    printf 'usage-check-gate: %s is not valid JSON — failing closed (mode=on) until it parses.\n' \
      "$CONFIG" >&2
  fi
else
  MODE="$(resolve_default_mode)"
fi
[[ "$MODE" == "off" ]] && exit 0

# ── Step 5: workflow context, THEN repo-local override — this order only ────
IN_WORKFLOW=0
[[ "$TRANSCRIPT" == */workflows/* ]] && IN_WORKFLOW=1

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

if [[ "$IN_WORKFLOW" -eq 0 ]]; then
  ORCH_MODE="main-thread"
  [[ -n "$CONFIG" && -f "$CONFIG" ]] && ORCH_MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG" 2>/dev/null)"
  [[ -n "$ORCH_MODE" ]] || ORCH_MODE="main-thread"
  # ADR-087 D9 amendment: the repo-local single-use override moves under the
  # protected namespace, keyed by repo hash. A file outside the repo cannot
  # be committed, pushed to a teammate, or resurrected by a checkout — so the
  # whole untracked-only rule and its tracked-copy check are DELETED here,
  # not reimplemented. A mandatory sanitized reason applies, same as the
  # machine-wide tier.
  UCG_RH="$(uc_repo_hash "$REPO_ROOT" 2>/dev/null || echo "")"
  OVERRIDE_FILE="$UCG_CONF_DIR/state/attest/override/usage-check-once/${UCG_RH}"
  LEGACY_OVERRIDE_FILE="$REPO_ROOT/.claude/.usage-check-override-once"

  ucg_consume_override() { # <path> <tier> -> rc 0 if consumed
    local f="$1" tier="$2" reason
    reason="$(ucg_disable_reason "$f" 2>/dev/null)" || reason="(legacy: no reason recorded)"
    # Consumed exactly once, via a rename that cannot race a second reader.
    mv "$f" "${f}.used" 2>/dev/null || rm -f "$f" 2>/dev/null
    # shellcheck source=/dev/null
    source "$DIR/override-log.sh" 2>/dev/null
    if declare -F ovlog_append >/dev/null 2>&1; then
      EXTRA="$(jq -nc --arg hook "usage-check-gate" --arg tier "$tier" --arg reason "$reason" \
        '{hook:$hook, tier:$tier, reason:$reason}')"
      ovlog_append "guard_override" "$CWD" "$EXTRA"
    fi
    return 0
  }

  if [[ "$ORCH_MODE" == "main-thread" && -n "$UCG_RH" && -f "$OVERRIDE_FILE" ]]; then
    ucg_consume_override "$OVERRIDE_FILE" "repo-once" && exit 0
  elif [[ "$ORCH_MODE" == "main-thread" && -f "$LEGACY_OVERRIDE_FILE" ]]; then
    # Same one-time migration tolerance as the machine-wide tier — but the
    # old untracked-only rule still applies to the OLD file. A committed
    # override bypasses the gate for everyone who clones the repo; honouring
    # a tracked one "just during migration" would re-open exactly the hole
    # that rule existed to close, once per clone. Untracked: honour once.
    # Tracked: refuse, leave it in place, keep evaluating.
    if git -C "$REPO_ROOT" ls-files --error-unmatch ".claude/.usage-check-override-once" >/dev/null 2>&1; then
      : # tracked -> refused, left in place, evaluation continues below
    else
      ucg_consume_override "$LEGACY_OVERRIDE_FILE" "repo-once-legacy" && exit 0
    fi
  fi
fi

# Logs dir must exist before the FIRST possible log write (the
# no_target_declared warn-mode case just below) — creating it later, only in
# Step 10, silently dropped that earliest log line on a fresh machine.
mkdir -p "$HOME/.claude/logs" 2>/dev/null

# ── Step 6: extract declared targets ─────────────────────────────────────────
# One target per physical line: the marker may appear anywhere in the line
# (not just at line-start), and the target is everything after it to the end
# of that line — matching the brief's original rest-of-line intent, just
# without the line-start-only anchor bug that made the brief's own test 9
# unmatchable.
TARGETS_RAW="$(printf '%s\n' "$PROMPT" \
  | grep -oE 'Usage-check-target:[[:space:]]*.*$' \
  | sed -E 's/^Usage-check-target:[[:space:]]*//')"
if [[ -z "$(echo "$TARGETS_RAW" | sed '/^$/d')" ]]; then
  REASON="usage-check-gate: dispatch of '$SUBAGENT' requires a completed usage check for each target. Run: usage-check.sh --target <path> — then include a \"Usage-check-target: <path>\" line in the subagent prompt. [reason: no_target_declared]"
  if [[ "$MODE" == "on" ]]; then emit_deny "$REASON"; else
    jq -nc --arg r "would_deny: $REASON" --argjson cu "$CONFIG_UNPARSEABLE" \
      '{event:"usage_check_gate", decision:"would_deny", reason:$r, config_unparseable:($cu == 1)}' \
      >> "$HOME/.claude/logs/usage-check-gate.jsonl" 2>/dev/null || true
  fi
  exit 0
fi

RH="$(uc_repo_hash "$REPO_ROOT")"
SID="$(uc_sanitize_sid "$RAW_SID")"
DENY_REASON=""

while IFS= read -r RAW_TARGET; do
  [[ -z "$RAW_TARGET" ]] && continue
  if [[ "$RAW_TARGET" == symbol:* ]]; then
    NORM="$(uc_normalize_target symbol "$RAW_TARGET")"
    TKIND="symbol"
  else
    NORM="$(uc_normalize_target file "$RAW_TARGET")"
    TKIND="file"
  fi
  TH="$(uc_target_hash "$TKIND" "$NORM")"
  TOKEN_PATH="$(uc_token_path "$RH" "$TH" "$SID")"

  # ── Step 7: token lookup + validation ──────────────────────────────────────
  if [[ ! -f "$TOKEN_PATH" ]]; then
    DENY_REASON="usage-check-gate: no usage-check token found for '$NORM'. Run usage-check.sh --target $NORM, then re-dispatch. [reason: no_token]"
    break
  fi
  if ! jq -e . "$TOKEN_PATH" >/dev/null 2>&1; then
    DENY_REASON="usage-check-gate: the token for '$NORM' is unreadable. Re-run the usage check. [reason: token_schema_invalid]"
    break
  fi
  TOKEN_SCHEMA="$(jq -r '.schema' "$TOKEN_PATH" 2>/dev/null)"
  TOKEN_TARGET="$(jq -r '.target' "$TOKEN_PATH" 2>/dev/null)"
  TOKEN_SID="$(jq -r '.session_id' "$TOKEN_PATH" 2>/dev/null)"
  if [[ "$TOKEN_SCHEMA" != "usage-check-token/v1" ]]; then
    DENY_REASON="usage-check-gate: token for '$NORM' has an unrecognized schema. Re-run the usage check. [reason: token_schema_invalid]"
    break
  fi
  if [[ "$TOKEN_TARGET" != "$NORM" ]]; then
    DENY_REASON="usage-check-gate: the recorded usage check does not cover '$NORM'. Run usage-check.sh --target $NORM, then re-dispatch. [reason: target_mismatch]"
    break
  fi
  if [[ "$TOKEN_SID" != "$SID" ]]; then
    DENY_REASON="usage-check-gate: the token for '$NORM' belongs to a different session. Re-run the usage check in this session. [reason: session_mismatch]"
    break
  fi

  # ── Step 8: freshness — TTL AND HEAD, both required ────────────────────────
  MINTED_AT="$(jq -r '.minted_at' "$TOKEN_PATH" 2>/dev/null)"
  TTL="$(jq -r '.ttl_seconds' "$TOKEN_PATH" 2>/dev/null)"
  TOKEN_HEAD="$(jq -r '.head_commit' "$TOKEN_PATH" 2>/dev/null)"
  # A missing/non-numeric ttl_seconds must deny, not fall through to bash
  # arithmetic — an unbound/non-numeric operand there aborts the whole
  # script (exit 127), which is a non-blocking hook error that would
  # silently ALLOW the dispatch instead of denying it.
  if [[ ! "$TTL" =~ ^[0-9]+$ ]]; then
    DENY_REASON="usage-check-gate: token for '$NORM' has an invalid or missing TTL. Re-run the usage check. [reason: token_schema_invalid]"
    break
  fi
  MINTED_EPOCH="$(uc_iso_to_epoch "$MINTED_AT")"
  NOW_EPOCH="$(date -u +%s)"
  if [[ -z "$MINTED_EPOCH" ]] || (( NOW_EPOCH - MINTED_EPOCH > TTL )); then
    DENY_REASON="usage-check-gate: usage check for '$NORM' has expired. Re-run usage-check.sh --target $NORM. [reason: ttl_expired]"
    break
  fi
  CURRENT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "no-git")"
  if [[ "$CURRENT_HEAD" != "$TOKEN_HEAD" ]]; then
    DENY_REASON="usage-check-gate: the repo has changed since '$NORM' was checked. Re-run usage-check.sh --target $NORM. [reason: head_moved]"
    break
  fi

  # ── Step 9: re-verification, every time — invoke the real checker tool ─────
  # Do NOT hand-roll the search here: this machine has neither `timeout` nor
  # `gtimeout` (verified empirically), so an earlier version of this hook
  # wrapping the search in `timeout 20 rg ...` silently failed the wrapper
  # command itself, making the search's match count empty on every run and
  # turning the entire re-verification step into a permanent no-op (every
  # verdict "matched" because none was ever really computed). Hand-rolling
  # also duplicated checker logic (target self-exclusion, symbol thresholds)
  # that can drift from scripts/usage-check.sh's real implementation.
  # Re-running the actual checker eliminates both problems in one move.
  CHECKER="$DIR/../scripts/usage-check.sh"
  [[ -f "$CHECKER" ]] || CHECKER="$HOME/.claude/scripts/usage-check.sh"
  TOKEN_VERDICT="$(jq -r '.verdict' "$TOKEN_PATH" 2>/dev/null)"
  # Residual risk, accepted rather than worked around: on any host with
  # neither `timeout` nor `gtimeout` on PATH, the checker call below runs
  # uncapped (the block just below only applies one of those two binaries
  # when present — see TIMEOUT_BIN). A pure-bash background-plus-poll-plus-
  # kill wrapper was considered and rejected — it trades a rare,
  # self-limiting risk (the checker is a bounded grep/rg over one repo, not
  # an external call) for a new source of real bugs in this file (orphaned
  # processes, stdout only capturable via a temp file that then needs its
  # own cleanup, kill-signal escalation). If this ever needs a real cap,
  # prefer installing `coreutils` (which provides `gtimeout`) over
  # hand-rolling one here.
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  fi
  if [[ -n "$TIMEOUT_BIN" ]]; then
    CHECKER_OUTPUT="$("$TIMEOUT_BIN" 20 bash "$CHECKER" --target "$NORM" --repo "$REPO_ROOT" 2>/dev/null)"
  else
    CHECKER_OUTPUT="$(bash "$CHECKER" --target "$NORM" --repo "$REPO_ROOT" 2>/dev/null)"
  fi
  CHECKER_EXIT=$?
  REVERIFY_RESULT_LINE="$(echo "$CHECKER_OUTPUT" | grep 'USAGE_CHECK_RESULT:v1 ' | tail -1 | sed 's/^.*USAGE_CHECK_RESULT:v1 //')"
  if [[ "$CHECKER_EXIT" -ne 0 || -z "$REVERIFY_RESULT_LINE" ]]; then
    DENY_REASON="usage-check-gate: could not re-verify the usage check for '$NORM' (checker did not complete). [reason: reverify_failed]"
    break
  fi
  REVERIFY_JSON="$(printf '%s' "$REVERIFY_RESULT_LINE" | base64 -d 2>/dev/null)"
  if [[ -z "$REVERIFY_JSON" ]] || ! echo "$REVERIFY_JSON" | jq -e . >/dev/null 2>&1; then
    DENY_REASON="usage-check-gate: could not re-verify the usage check for '$NORM' (checker output unreadable). [reason: reverify_failed]"
    break
  fi
  REVERIFY_VERDICT="$(echo "$REVERIFY_JSON" | jq -r '.verdict' 2>/dev/null)"
  if [[ "$REVERIFY_VERDICT" != "$TOKEN_VERDICT" ]]; then
    DENY_REASON="usage-check-gate: re-checking '$NORM' now disagrees with the token's claimed result. Re-run usage-check.sh --target $NORM. [reason: reverify_verdict_mismatch]"
    break
  fi
done <<< "$TARGETS_RAW"

# ── Step 10: outcome ──────────────────────────────────────────────────────────
# (logs dir already created above, before the earliest possible log write)
if [[ -n "$DENY_REASON" ]]; then
  if [[ "$MODE" == "on" ]]; then
    jq -nc --arg e "usage_check_gate" --arg d "deny" --arg a "$SUBAGENT" --argjson cu "$CONFIG_UNPARSEABLE" \
      '{event:$e, decision:$d, agent:$a, config_unparseable:($cu == 1)}' \
      >> "$HOME/.claude/logs/usage-check-gate.jsonl" 2>/dev/null || true
    emit_deny "$DENY_REASON"
  else
    jq -nc --arg e "usage_check_gate" --arg r "would_deny: $DENY_REASON" --argjson cu "$CONFIG_UNPARSEABLE" \
      '{event:$e, decision:"would_deny", reason:$r, config_unparseable:($cu == 1)}' \
      >> "$HOME/.claude/logs/usage-check-gate.jsonl" 2>/dev/null || true
  fi
else
  jq -nc --arg e "usage_check_gate" --arg a "$SUBAGENT" --argjson cu "$CONFIG_UNPARSEABLE" \
    '{event:$e, decision:"pass", agent:$a, config_unparseable:($cu == 1)}' \
    >> "$HOME/.claude/logs/usage-check-gate.jsonl" 2>/dev/null || true
fi
exit 0
