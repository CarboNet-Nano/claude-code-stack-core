#!/usr/bin/env bash
# UserPromptSubmit hook: nudge user toward /foreman or /dispatch when their
# prompt looks like multi-step engineering work but they didn't route it.
# Soft, infrequent: only fires when ALL of:
#   1) project has .claude/stack-config.json with stack_tier >= 2
#   2) prompt contains trigger words (build / add / implement / fix / refactor / migrate)
#   3) prompt does NOT already start with / (skill invocation)
#   4) prompt is not trivial-short (< 12 words)
# Output is injected as system-reminder context.
# summary: Nudges the user toward /foreman or /dispatch when a prompt looks multi-step.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
PROMPT="$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Skip if prompt is a slash command.
[[ "$PROMPT" =~ ^/ ]] && exit 0

# Skip short prompts.
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
[[ "$WORD_COUNT" -lt 12 ]] && exit 0

# Skip if no trigger words.
LOWER="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"
if ! echo "$LOWER" | grep -qE '\b(build|add|implement|fix|refactor|migrate|deploy|create.*feature|new feature)\b'; then
  exit 0
fi

# Only nudge in stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0

TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" -lt 2 ]] && exit 0

# Per-session dedupe: fire at most once per session. Scope the flag to the
# session id so concurrent windows can't mute each other (a machine-global flag
# would let the first window silence the rest, and another session's SessionStart
# could wipe it mid-session). If no session id is available, skip dedupe rather
# than risk muting across sessions.
STATE_DIR="$HOME/.claude/session-state"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
DEDUPE=false
if [[ -n "$SESSION_ID" ]]; then
  DEDUPE=true
  NUDGE_FLAG="$STATE_DIR/passive_suggest.$SESSION_ID.nudged"
  [[ -f "$NUDGE_FLAG" ]] && exit 0
fi

# Read passive_suggest (fail-open). Precedence: session prefs file, then the
# project config's session_prefs (honors a project-layer opt-out even when
# SessionStart never ran, e.g. cloud/API), then default true.
# NOTE: never use jq `// true` — `//` treats boolean false as empty and would
# collapse an explicit `false` back to true, making opt-out impossible.
PREFS="$STATE_DIR/current-prefs.json"
_ps="unset"
[[ -f "$PREFS" ]] && _ps="$(jq -r 'if has("passive_suggest") then (.passive_suggest|tostring) else "unset" end' "$PREFS" 2>/dev/null || echo unset)"
if [[ "$_ps" == "unset" ]]; then
  _ps="$(jq -r 'if (.session_prefs|type=="object") and (.session_prefs|has("passive_suggest")) then (.session_prefs.passive_suggest|tostring) else "unset" end' "$CONFIG" 2>/dev/null || echo unset)"
fi
PASSIVE_SUGGEST=true
[[ "$_ps" == "false" ]] && PASSIVE_SUGGEST=false

# Mark this session as nudged (best-effort; ignore failure).
if [[ "$DEDUPE" == true ]]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$NUDGE_FLAG" 2>/dev/null || true
fi

# Inject reminder. The hook's stdout is appended to the model's context.
# The /foreman//dispatch routing reminder fires unconditionally.
# The recommender pointer fires only when passive_suggest is not false.
if [[ "$PASSIVE_SUGGEST" == "true" ]]; then
cat <<EOF
<system-reminder>
Dispatch nudge: this prompt looks like multi-step engineering work in a Tier $TIER project. Consider routing it via /foreman or /dispatch so the right subagents handle it (architect → implementer → validator → reviewer). Or, for parallel read-only fan-out, a Workflow whose agent() calls pass agentType: <roster-name> keeps the named roles (and their Codex/Gemini wiring) in play. If you've already decided this is single-edit / trivial work, ignore this and proceed directly.
If you're unsure which capability fits, run the recommend-capabilities engine (or tell the user to ask "what should I use here").
</system-reminder>
EOF
else
cat <<EOF
<system-reminder>
Dispatch nudge: this prompt looks like multi-step engineering work in a Tier $TIER project. Consider routing it via /foreman or /dispatch so the right subagents handle it (architect → implementer → validator → reviewer). Or, for parallel read-only fan-out, a Workflow whose agent() calls pass agentType: <roster-name> keeps the named roles (and their Codex/Gemini wiring) in play. If you've already decided this is single-edit / trivial work, ignore this and proceed directly.
</system-reminder>
EOF
fi

exit 0
