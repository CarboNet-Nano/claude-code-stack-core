#!/usr/bin/env bash
# PreToolUse[Edit|Write|MultiEdit] hook: deny direct writes to the handoff
# files. ADR-074 D16 routes every handoff through `session-close.sh
# handoff-write`, which owns the credential scan and the local-only
# disclosure; a Write/Edit that lands `.claude/next_prompt.md` or anything
# under `docs/handoffs/` skips both gates. Queue item #179: scribe keeps
# Write for its scratch body and open-threads file, so the rule cannot be
# enforced by stripping capability — enforce it at the files instead, for
# every agent equally. The legitimate writer is a Bash script, not the
# Write tool, so no allowlist or override is needed.
# summary: Denies direct Write/Edit of handoff files; session-close.sh handoff-write is the only writer.
#
# SCOPE: friction, not a boundary — same statement as migration-guard.sh.
# A redirect or heredoc through Bash still lands the file; boot-time
# provenance detection (handoff-gather's missing-marker degrade line)
# remains the backstop that makes such a bypass visible next session.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

FP="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
[[ -z "$FP" ]] && FP="${CLAUDE_TOOL_INPUT_file_path:-}"
[[ -z "$FP" ]] && exit 0

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}' \
    2>/dev/null || true
  exit 0
}

# Match on the path's tail so absolute, relative, and worktree-prefixed
# forms all hit. `..` segments are refused outright rather than resolved —
# a traversal-shaped path aimed near the handoff files has no honest use.
case "$FP" in
  *..*)
    case "$FP" in
      *next_prompt.md|*docs/handoffs/*) deny "handoff-guard (ADR-074 D16): refusing a '..' path aimed at a handoff file: $FP" ;;
    esac
    ;;
  *.claude/next_prompt.md|.claude/next_prompt.md|next_prompt.md)
    deny "handoff-guard (ADR-074 D16): .claude/next_prompt.md is written only by 'session-close.sh handoff-write' (credential scan + local-only disclosure live there). Compose the body to a scratch file and hand it over with --body-file instead."
    ;;
  *docs/handoffs/*)
    deny "handoff-guard (ADR-074 D16): files under docs/handoffs/ are written only by 'session-close.sh handoff-write'. Compose the body to a scratch file and hand it over with --body-file instead."
    ;;
esac

exit 0
