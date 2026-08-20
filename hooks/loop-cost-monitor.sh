#!/usr/bin/env bash
# PreToolUse hook: live mid-flight cost monitor for the loop-engineering control
# plane (ADR-019 Phase 2 — closes the within-iteration runaway gap that the
# between-iteration Stop-hook accrual leaves open).
#
# During an ACTIVE loop with a per_run_budget_usd, on every tool call it sums the
# real logged cost for this loop_id (loop_live_cost) and, if it has reached the
# budget, DENIES the call and marks the loop budget_exceeded so the next Stop
# releases. Outside a loop, or with no budget, it stays silent. Fail-OPEN: any
# error allows the tool (never crash the session over a monitoring failure).
#
# This complements (does not replace) the Stop-hook's between-iteration accrual:
# the Stop-hook catches overruns between iterations; this catches a single
# iteration that blows the budget without ever stopping.
# summary: Denies a tool call mid-loop once the active loop's per-run cost budget is exhausted.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

# Per-session state (ADR-020): the session id in the payload is authoritative
# for this event; export it so loop_read_state resolves THIS session's file
# instead of falling through to the wrong/legacy one.
INPUT="$(cat 2>/dev/null || echo '{}')"
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

STATE="$(loop_read_state 2>/dev/null || echo '{}')"
[[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

BUDGET="$(echo "$STATE" | jq -r '.bounds.per_run_budget_usd // empty' 2>/dev/null)"
[[ -z "$BUDGET" ]] && exit 0
# Only act on a valid positive number.
[[ "$BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0

LID="$(echo "$STATE" | jq -r '.loop_id // empty' 2>/dev/null)"
[[ -z "$LID" ]] && exit 0
STARTED="$(echo "$STATE" | jq -r '.started_at // empty' 2>/dev/null)"

TOTAL="$(loop_live_cost "$LID" "$STARTED" 2>/dev/null || echo 0)"
[[ "$TOTAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0

# ADR-024: real per-tool cost is recorded post-call by loop-cost-accrual.sh as
# loop_tool_cost rows, which loop_live_cost sums above. (ADR-023 §2 tried to read
# tool_response.usage here, but a PreToolUse hook never sees a response — that
# branch was a no-op and has been removed.) This monitor enforces the budget on
# real spend, catching an overrun on the next call; the Stop hook is the hard cap.

# Over (or at) budget? -> deny + mark budget_exceeded so the loop ends cleanly.
if awk -v t="$TOTAL" -v b="$BUDGET" 'BEGIN{exit !(t >= b)}'; then
  loop_write_state "$(echo "$STATE" | jq -c --argjson t "$TOTAL" \
    '.cost_so_far_usd=$t | .active=false | .status="budget_exceeded"')" 2>/dev/null || true
  jq -nc --arg t "$TOTAL" --arg b "$BUDGET" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
      permissionDecisionReason:("loop-cost-monitor: live loop cost $\($t) has reached the per-run budget $\($b). The loop is halted (budget_exceeded). Raise per_run_budget_usd or clear the loop, then continue.")}}' \
    2>/dev/null || true
fi
exit 0
