#!/usr/bin/env bash
# StopFailure hook (issue #110): fires instead of Stop when a turn ends due to
# an API error (rate_limit, overloaded, authentication_failed, server_error,
# etc. — see docs). Appends one row to the same reliability log the
# loop-engineering control plane already writes to
# (~/.claude/logs/subagent-runs.jsonl, ADR-024's loop-cost-accrual.sh /
# loop_lib.sh's loop_live_cost), extending its failure-class coverage to API
# errors. Output/exit code are ignored for this event (docs: "notification
# and logging purposes only") — always exit 0.
#
# Invariant this row MUST preserve: loop_live_cost (skills/loop-engineer/
# loop_lib.sh) sums every subagent-runs.jsonl row matching a given loop_id
# by the presence of a cost_usd/cost key, REGARDLESS of event name. This row
# tags loop_id for correlation only (so a StopFailure can be traced back to
# the loop it interrupted) and deliberately carries NO cost_usd/cost key —
# doing otherwise would silently corrupt the live per-run budget the Stop
# hook enforces (ADR-024).
# summary: Logs API-error session terminations to the shared reliability log, without ever contributing a cost row.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"
SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
ERROR="$(echo "$INPUT" | jq -r '.error // "unknown"' 2>/dev/null)"
ERROR_DETAILS="$(echo "$INPUT" | jq -r '.error_details // empty' 2>/dev/null)"

PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

# Best-effort loop_id correlation (see invariant above — no cost fields).
LOOP_ID=""
[[ -n "$SID" ]] && export CLAUDE_CODE_SESSION_ID="$SID"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
if [[ -f "$LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LIB" 2>/dev/null || true
  if command -v loop_read_state &>/dev/null; then
    STATE="$(loop_read_state 2>/dev/null || echo '{}')"
    if [[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]]; then
      LOOP_ID="$(echo "$STATE" | jq -r '.loop_id // empty' 2>/dev/null)"
    fi
  fi
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
jq -nc \
  --arg ts "$TS" --arg project "$PROJECT" --arg sid "$SID" \
  --arg error "$ERROR" --arg details "$ERROR_DETAILS" --arg lid "$LOOP_ID" \
  '{event:"stop_failure", ts:$ts, project:$project, session_id:$sid, error:$error}
   + (if ($details|length) > 0 then {error_details:$details} else {} end)
   + (if ($lid|length) > 0 then {loop_id:$lid} else {} end)' \
  >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true

exit 0
