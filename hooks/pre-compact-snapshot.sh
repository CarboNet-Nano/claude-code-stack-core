#!/usr/bin/env bash
# PreCompact hook: snapshot the current session's loop-state (ADR-020) to a
# sibling file before context compaction runs, so hooks/post-compact-verify.sh
# (the PostCompact companion) can detect whether compaction disturbed it.
#
# ADR-020 keys loop-state per Claude Code session id
# (~/.claude/session-state/loop-state.<session_id>.json, resolved by
# skills/loop-engineer/loop_lib.sh's _loop_state_file). This hook resolves the
# SAME path the same way (source the same lib, export the same session_id from
# the hook payload) so the snapshot always targets this session's real state
# file, never a different session's or the legacy global one.
#
# No active loop-state file yet -> nothing to protect, silent no-op.
#
# Fail-safe + silent-on-success: any stdout this hook prints is folded by
# Claude Code into the compaction's newCustomInstructions (verified against
# the installed binary), so this hook must never print anything on the
# ordinary path -- only errors are swallowed, nothing is ever surfaced here.
# It also never blocks compaction (no hookSpecificOutput / blockedBy is ever
# emitted).
# summary: Snapshots this session's loop-state file to a sibling path before compaction, so PostCompact can detect corruption.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || { LIB="${HOME:-/tmp}/.claude/skills/loop-engineer/loop_lib.sh"; }
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0   # no lib -> nothing to snapshot, never block compaction

INPUT="$(cat 2>/dev/null || echo '{}')"
# PreCompact payload carries session_id directly (same shape as Stop/PreToolUse
# payloads); export it so _loop_state_file resolves THIS session's file.
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

STATE_FILE="$(_loop_state_file 2>/dev/null)"
[[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || exit 0   # no state yet -> nothing to protect

# Sibling snapshot path, ".precompact-snapshot" suffix. Both this hook and
# hooks/post-compact-verify.sh derive it the same way (STATE_FILE + fixed
# suffix) from the same _loop_state_file() resolution -- neither hook shares
# process state with the other (separate invocations around one compaction
# event), so the naming rule itself is the only thing keeping them in sync.
SNAPSHOT="${STATE_FILE}.precompact-snapshot"

# Atomic write via mktemp + mv (same pattern as loop_write_state): never leave
# a half-written snapshot if interrupted mid-copy.
TMP="$(mktemp "${SNAPSHOT}.tmp.XXXXXX" 2>/dev/null)" || exit 0
cp "$STATE_FILE" "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
mv "$TMP" "$SNAPSHOT" 2>/dev/null || rm -f "$TMP"
exit 0
