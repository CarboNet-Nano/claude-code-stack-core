#!/usr/bin/env bash
# PostToolUse hook (matcher: Agent): log subagent completion as JSONL.
# Pair-source for the dispatch row written by subagent-log.sh.
# Captures success/failure + wall-time-since-last-dispatch for same agent.
# Powers /agent-performance-review outcome metrics.
# summary: Logs subagent completion (success/failure, wall time) as JSONL, pairing with subagent-log.sh's dispatch row.

set -uo pipefail

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/subagent-runs.jsonl"
mkdir -p "$LOG_DIR"

# stdin: PostToolUse JSON with tool_name, tool_input, tool_response.
INPUT="$(cat 2>/dev/null || echo '{}')"

AGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // env.CLAUDE_TOOL_INPUT_subagent_type // "unknown"' 2>/dev/null)"
# tool_response shape varies; we infer success vs error from common fields.
IS_ERROR="$(echo "$INPUT" | jq -r '
  if (.tool_response.is_error // false) then "true"
  elif (.tool_response.error // empty) then "true"
  elif ((.tool_response | type) == "string" and (.tool_response | test("^Error|InputValidationError"; "i"))) then "true"
  else "false" end' 2>/dev/null || echo "false")"

PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SESSION_START=""
[[ -f "$HOME/.claude/state/session-start.txt" ]] && \
  SESSION_START="$(cat "$HOME/.claude/state/session-start.txt" 2>/dev/null || true)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Compute wall_seconds: ts now minus most recent dispatch row for same agent
# in this project. Best-effort; empty if no match.
WALL_SECONDS=""
if command -v jq &>/dev/null && [[ -f "$LOG_FILE" ]]; then
  LAST_DISPATCH_TS="$(tac "$LOG_FILE" 2>/dev/null | jq -r --arg a "$AGENT" --arg p "$PROJECT" \
    'select((.event // "dispatch") == "dispatch") | select(.agent == $a) | select(.project == $p) | .ts' 2>/dev/null | head -1)"
  if [[ -n "$LAST_DISPATCH_TS" ]]; then
    # Python is more portable than date math here.
    WALL_SECONDS="$(python3 -c "
from datetime import datetime
a = datetime.strptime('$LAST_DISPATCH_TS', '%Y-%m-%dT%H:%M:%SZ')
b = datetime.strptime('$TS',               '%Y-%m-%dT%H:%M:%SZ')
print(int((b - a).total_seconds()))
" 2>/dev/null || echo "")"
  fi
fi

if command -v jq &>/dev/null; then
  jq -nc \
    --arg ts "$TS" \
    --arg session_start "$SESSION_START" \
    --arg project "$PROJECT" \
    --arg agent "$AGENT" \
    --arg is_error "$IS_ERROR" \
    --arg wall_seconds "$WALL_SECONDS" \
    '{event:"complete", ts:$ts, session_start:$session_start, project:$project, agent:$agent,
      success: ($is_error != "true"),
      wall_seconds: (if $wall_seconds == "" then null else ($wall_seconds | tonumber) end)}' \
    >> "$LOG_FILE" 2>/dev/null || true
fi

exit 0
