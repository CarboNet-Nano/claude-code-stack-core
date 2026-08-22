#!/usr/bin/env bash
# PostToolUse[Agent|Workflow] hook: real per-tool token-cost accrual for the
# loop-engineering control plane (ADR-024).
#
# After a token-consuming tool call completes, if a loop is ACTIVE this records
# the call's REAL cost — derived from tool_response.usage via the single audited
# price table (loop_cost_from_usage) — as a row in subagent-runs.jsonl tagged
# with the loop_id. loop_live_cost sums these rows, so the PreToolUse
# loop-cost-monitor (registered on Bash|Agent|Workflow) enforces the per-run
# budget against actual spend, caught on the NEXT tool call. The Stop hook folds
# the same loop_live_cost total into its between-iteration budget check (ADR-024),
# so it is a true hard cap when the goal is still unmet. Outside a loop, or with
# no usage in the payload, it is a silent no-op. Fail-OPEN: any error proceeds.
#
# Why PostToolUse: token usage only exists AFTER the call. A PreToolUse hook
# cannot see tool_response, so per-call usage accrual belongs here — not in the
# monitor (ADR-024 supersedes ADR-023 §2's placement).
# summary: Records real per-tool token cost as a subagent-runs.jsonl row while a loop is active.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# Per-session state (ADR-020): the session id in the payload is authoritative
# for this event; export it so loop_read_state resolves THIS session's file
# instead of falling through to the wrong/legacy one.
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

# Only accrue during an active loop with a loop_id.
STATE="$(loop_read_state 2>/dev/null || echo '{}')"
[[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0
LID="$(echo "$STATE" | jq -r '.loop_id // empty' 2>/dev/null)"
[[ -z "$LID" ]] && exit 0
_IN="$(echo "$INPUT"  | jq -r '(.tool_response.usage.input_tokens  // .usage.input_tokens  // 0)' 2>/dev/null)"
_OUT="$(echo "$INPUT" | jq -r '(.tool_response.usage.output_tokens // .usage.output_tokens // 0)' 2>/dev/null)"
[[ "$_IN"  =~ ^[0-9]+$ ]] || _IN=0
[[ "$_OUT" =~ ^[0-9]+$ ]] || _OUT=0
# No usage in the payload -> nothing to accrue (silent no-op).
[[ "$_IN" == "0" && "$_OUT" == "0" ]] && exit 0

_MODEL="$(echo "$INPUT" | jq -r '(.model // .tool_response.model // "claude-sonnet-5")' 2>/dev/null)"
[[ -z "$_MODEL" || "$_MODEL" == "null" ]] && _MODEL="claude-sonnet-5"

COST="$(loop_cost_from_usage "$_IN" "$_OUT" "$_MODEL" 2>/dev/null || echo 0)"
[[ "$COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0
# Zero/unknown price -> no row (keep the log honest).
awk -v c="$COST" 'BEGIN{exit !(c>0)}' || exit 0

LOG="${HOME:-/tmp}/.claude/logs/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
jq -nc --arg lid "$LID" --argjson c "$COST" --arg ts "$TS" \
  '{event:"loop_tool_cost", loop_id:$lid, cost_usd:$c, ts:$ts}' >> "$LOG" 2>/dev/null || true
exit 0
