#!/usr/bin/env bash
# PostCompact hook: verify this session's loop-state (ADR-020) survived
# compaction intact, by comparing it against the sibling snapshot
# hooks/pre-compact-snapshot.sh wrote just before compaction ran.
#
# On a real mismatch: flag it LOUDLY (plain stdout text) rather than silently
# reverting. Verified against the installed claude-code binary: a PostCompact
# hook's stdout is joined into userDisplayMessage, which IS shown to the user
# directly -- that is the "loud" surface this hook uses, not
# hookSpecificOutput/additionalContext (unverified for this event).
#
# Deliberately does NOT auto-revert on mismatch. ADR-020's own invariants are
# all fail-safe-toward-ALLOWING (loop-stop.sh: "FAIL-CLOSED: on doubt, allow
# the stop" -- surfaced via status, never silently patched), never
# fail-safe-toward-REPAIRING state. Compaction itself does not touch files
# under ~/.claude/session-state, so a mismatch here means something else wrote
# to this session's loop-state between the two hook events (e.g. a genuine
# concurrent write) -- silently overwriting that with the pre-compact snapshot
# would fabricate state and could clobber real, legitimate progress. Flagging
# and leaving the current file in place is the safer default.
#
# Fail-safe: any error here -> silent exit 0, never blocks or crashes.
# summary: Compares this session's post-compaction loop-state against the PreCompact snapshot; flags a mismatch loudly, never auto-reverts.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || { LIB="${HOME:-/tmp}/.claude/skills/loop-engineer/loop_lib.sh"; }
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
# PostCompact payload also carries session_id directly (same common shape as
# PreCompact/Stop); export it so _loop_state_file resolves THIS session's file.
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

STATE_FILE="$(_loop_state_file 2>/dev/null)"
[[ -n "$STATE_FILE" ]] || exit 0

SNAPSHOT="${STATE_FILE}.precompact-snapshot"
[[ -f "$SNAPSHOT" ]] || exit 0   # no snapshot -> nothing was being protected, silent

# Normalize both sides (sorted keys, compact) so formatting-only differences
# never produce a false mismatch. A missing/deleted state file compares
# against the literal string "<deleted>" so that case is caught too.
CUR="<deleted>"
[[ -f "$STATE_FILE" ]] && CUR="$(jq -cS '.' "$STATE_FILE" 2>/dev/null || echo '<unreadable>')"
PREV="$(jq -cS '.' "$SNAPSHOT" 2>/dev/null || echo '<unreadable>')"

# Clean up the snapshot regardless of outcome: each PreCompact/PostCompact
# pair is independent, so a stale snapshot must never linger to be compared
# against a later, unrelated compaction event in the same session.
rm -f "$SNAPSHOT" 2>/dev/null || true

if [[ "$CUR" == "$PREV" ]]; then
  exit 0   # unchanged -> silent, matches the "verify passes clean" contract
fi

cat <<EOF
WARNING: loop-state changed across context compaction (ADR-020/#113/#114).
  session: ${_SID:-unknown}
  state file: $STATE_FILE
  before compaction: $PREV
  after compaction:  $CUR
This was NOT auto-reverted. If a governed loop is active, check its bounds
(iteration/cost/status) before continuing -- compaction itself never touches
this file, so this means something else wrote to it around the same time.
EOF
exit 0
