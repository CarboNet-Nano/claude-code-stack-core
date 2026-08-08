#!/usr/bin/env bash
# SessionEnd hook (issue #109): checks for uncommitted work / an open
# loop-engineering thread at session teardown and prints a `/handoff`
# reminder when something looks unfinished. Best-effort observability
# (H3) — NEVER a gate; SessionEnd has no decision control anyway (docs:
# "can't block session termination but can perform cleanup tasks").
#
# Always appends one row to ~/.claude/logs/subagent-runs.jsonl (same log
# override-log.sh / loop-cost-accrual.sh already write to) so the check
# itself is auditable/testable even when nothing was unfinished.
#
# Budget: SessionEnd hooks default to a 1.5s timeout — every check here is a
# single fast local read (git status on tracked files only, one JSON state
# file), never a network call or a full untracked-file scan.
# summary: Warns and logs at SessionEnd when uncommitted work or an active loop looks unfinished.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"
SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
REASON="$(echo "$INPUT" | jq -r '.reason // "other"' 2>/dev/null)"

GIT_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$GIT_ROOT" ]] && exit 0

# Tracked-file changes only (no untracked scan — CLAUDE.md forbids -uall and
# a full untracked walk risks the 1.5s budget on a large repo).
HAS_UNCOMMITTED="false"
if [[ -n "$(git -C "$GIT_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  HAS_UNCOMMITTED="true"
fi

# Open loop-engineering thread: an ACTIVE loop state file for this session.
# Resolve loop_lib.sh relative to THIS hook's own location (the stack's repo/
# plugin install), never $GIT_ROOT — $GIT_ROOT is the *inspected* project,
# which has no skills/loop-engineer/ of its own.
HAS_OPEN_LOOP="false"
[[ -n "$SID" ]] && export CLAUDE_CODE_SESSION_ID="$SID"
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$_HOOK_DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
if [[ -f "$LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LIB" 2>/dev/null || true
  if command -v loop_read_state &>/dev/null; then
    STATE="$(loop_read_state 2>/dev/null || echo '{}')"
    [[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]] && HAS_OPEN_LOOP="true"
  fi
fi

REMINDER_SHOWN="false"
if [[ "$HAS_UNCOMMITTED" == "true" || "$HAS_OPEN_LOOP" == "true" ]]; then
  REMINDER_SHOWN="true"
  echo "Unfinished work detected at session end (uncommitted:$HAS_UNCOMMITTED, open_loop:$HAS_OPEN_LOOP) — run /handoff before ending the session."
fi

PROJECT="$GIT_ROOT"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
jq -nc \
  --arg ts "$TS" --arg project "$PROJECT" --arg sid "$SID" --arg reason "$REASON" \
  --argjson uncommitted "$HAS_UNCOMMITTED" --argjson loop_active "$HAS_OPEN_LOOP" \
  --argjson reminder "$REMINDER_SHOWN" \
  '{event:"session_end_handoff_reminder", ts:$ts, project:$project, session_id:$sid,
    reason:$reason, uncommitted:$uncommitted, loop_active:$loop_active, reminder_shown:$reminder}' \
  >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true

exit 0
