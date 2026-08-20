#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): non-blocking nudge toward /loop-engineer when a
# bare Agent() dispatch looks like it is starting unbounded background work with no
# governed loop active. ADR-048 (draft) documents the fuller gap this only partially
# mitigates, and the harder floor-policy question this deliberately does NOT attempt
# to close.
#
# Why this exists: ADR-047 named a real gap -- a bare Agent() dispatch bypasses
# loop_policy entirely (no iteration cap, no budget, no timeout), and this already
# caused one ~13-hour ungoverned run. This hook is a conservative MITIGATION, not a
# fix: per the Agent tool's own schema, `run_in_background` defaults to true for
# EVERY Agent() call ("Agents run in the background by default") -- so gating on
# "background" alone would gate the entire foreman pipeline (architect/implementer/
# validator/reviewer all dispatch this way routinely). Instead this only fires when
# a bare (no active loop) dispatch's own description/prompt matches the SAME
# conservative loop-shape taxonomy loop-shape-nudge.sh already uses on user prompts
# -- explicit iterate/until/keep-going signals, not ordinary one-shot task
# descriptions. This deliberately would NOT have caught the actual 13-hour incident
# (its dispatch prompt was an ordinary implementer handoff, not loop-shaped) --
# see ADR-048 draft for the harder design question that would.
#
# Non-blocking: permissionDecision "allow" + additionalContext, the same proven
# channel workflow-roster-check.sh's warn path already uses in this repo. Fail-open:
# any error allows the call silently.
# summary: Nudges toward /loop-engineer when a bare background Agent dispatch (no active loop) looks like an iterate-until-verified pattern.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# Per-session state (ADR-020): resolve THIS session's loop-state file.
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

# Already governed (an active loop) -> loop-cost-monitor.sh owns enforcement here;
# stay silent so this doesn't double-nag inside a loop the user already set up.
STATE="$(loop_read_state 2>/dev/null || echo '{}')"
[[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Loop-eng lives at Tier 2+ only (same gate as loop-shape-nudge.sh).
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

# auto_offer_loop off -> silent (same persistent off-switch loop-shape-nudge.sh
# already uses -- reused here rather than inventing a second control).
STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"
AUTO_OFFER="$(jq -r 'if has("auto_offer_loop") and .auto_offer_loop != null then (.auto_offer_loop | tostring) else empty end' "$STATE_DIR/current-prefs.json" 2>/dev/null)"
[[ -z "$AUTO_OFFER" ]] && AUTO_OFFER="$(jq -r '(.session_prefs // {}) as $sp | if ($sp | has("auto_offer_loop")) and $sp.auto_offer_loop != null then ($sp.auto_offer_loop | tostring) else "true" end' "$CONFIG" 2>/dev/null)"
[[ "$AUTO_OFFER" == "false" ]] && exit 0

# run_in_background defaults to true per the Agent tool's own schema ("Agents run
# in the background by default; ... Set to false to run this agent synchronously").
# Only an explicit false is bounded by the parent's own turn -- exempt that case.
BG="$(echo "$INPUT" | jq -r 'if (.tool_input.run_in_background|type)=="boolean" then (.tool_input.run_in_background|tostring) else "true" end' 2>/dev/null)"
[[ "$BG" == "false" ]] && exit 0

DESC="$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null)"
PROMPT="$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)"
LOWER="$(printf '%s\n%s' "$DESC" "$PROMPT" | tr '[:upper:]' '[:lower:]')"

# Same conservative loop-shape taxonomy as loop-shape-nudge.sh -- deliberately not
# broadened (a wider match here would false-positive on ordinary foreman dispatches,
# gating the whole pipeline; see ADR-048 draft).
LOOP_RE='\b(until (it|the|all|tests|they|done)|iterate|keep (going|running|trying)|babysit|repeatedly|run .* until|loop until|every (hour|day|commit|run)|recurring|watch the pr|eval.*(threshold|until)|until .* (pass|passes|green|done)|don.?t stop|keep .* until)\b'
echo "$LOWER" | grep -qE "$LOOP_RE" || exit 0
# Negative guard: pure read/explain dispatches are not loops even if they say "until".
echo "$LOWER" | grep -qE '^\s*(explain|what|why|how does|show me|describe|summari)' && exit 0

# Once-per-session dedupe so this doesn't nag on every matching dispatch.
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
if [[ -n "$SESSION_ID" ]]; then
  FLAG="$STATE_DIR/bare-agent-nudged.$SESSION_ID"
  [[ -f "$FLAG" ]] && exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$FLAG" 2>/dev/null || true
fi

REASON="This background Agent dispatch looks iterate-until-verified shaped and no governed loop is active -- loop_policy's caps (max_iterations/per_run_budget_usd/timeout_minutes) do NOT apply to a bare dispatch like this (ADR-047's known gap; see ADR-048 draft for the harder, not-yet-closed part). Consider: 1) run this via /loop-engineer first so real bounds apply, or 2) pass run_in_background:false for a synchronous call bounded by your own turn, or 3) if it does run in the background, check on it with the Monitor tool on a stated cadence instead of leaving it unsupervised. Proceeding either way."
jq -nc --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", permissionDecisionReason:"stack bare-agent-nudge", additionalContext:("<system-reminder>"+$r+"</system-reminder>")}}' \
  2>/dev/null || true
exit 0
