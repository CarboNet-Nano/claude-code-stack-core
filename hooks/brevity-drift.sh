#!/usr/bin/env bash
# UserPromptSubmit hook: adaptive brevity correction.
#
# brevity-reinforce.sh injects the full brevity rules once, at SessionStart.
# That decays as context grows — the model drifts back to verbose prose by
# mid-session. This hook closes that gap: on every prompt it measures the
# assistant's most recent response and, ONLY if that response blew the budget,
# injects a sharp one-shot correction for the upcoming turn. Silent when you're
# already terse, so it never becomes noise the model tunes out.
#
# Fail-safe by design: any parse/measure problem -> empty -> exit 0 silently.
# Worst case the hook is inert; it can never block or corrupt a turn.
# summary: Injects a one-shot brevity correction when the assistant's last response blew its length budget.

set -uo pipefail

# Defaults. A response over EITHER axis triggers a correction. A project can
# override these (or opt out) via a "brevity" block in its stack-config.json;
# see below. Absent config -> these built-in defaults apply everywhere.
WORD_BUDGET=120
SENTENCE_BUDGET=6

INPUT="$(cat 2>/dev/null || echo '{}')"
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# No transcript (e.g. the very first turn) -> nothing to measure.
[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Per-project tuning: read the nearest .claude/stack-config.json via the shared
# finder (same one dispatch-nudge.sh uses). brevity.enabled=false opts a project
# out entirely; word_budget / sentence_budget override the defaults above.
# Anything missing, null, or non-numeric leaves the default in place — so a
# malformed config can never make the hook misbehave, only fall back.
FINDER="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh"
if [[ -x "$FINDER" ]]; then
  CONFIG="$(bash "$FINDER" "$CWD" 2>/dev/null || true)"
  if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
    # Note: do NOT use `.brevity.enabled // true` — jq's // falls through on
    # both null AND false, so an explicit false would be read as true. Compare
    # the raw value instead (absent -> "null" -> stays enabled).
    [[ "$(jq -r '.brevity.enabled' "$CONFIG" 2>/dev/null)" == "false" ]] && exit 0
    WB="$(jq -r '.brevity.word_budget // empty' "$CONFIG" 2>/dev/null)"
    SB="$(jq -r '.brevity.sentence_budget // empty' "$CONFIG" 2>/dev/null)"
    [[ "$WB" =~ ^[0-9]+$ ]] && WORD_BUDGET="$WB"
    [[ "$SB" =~ ^[0-9]+$ ]] && SENTENCE_BUDGET="$SB"
  fi
fi

# Live session override (highest precedence): /session and the session-prefs
# SessionStart hook write communication_style to the session-state file. Map
# style -> budgets; an explicit choice supersedes project config above. Missing
# file or unknown style leaves the values from earlier untouched.
PREFS="$HOME/.claude/session-state/current-prefs.json"
if [[ -f "$PREFS" ]]; then
  STYLE="$(jq -r '.communication_style // empty' "$PREFS" 2>/dev/null)"
  case "$STYLE" in
    terse)    WORD_BUDGET=70;  SENTENCE_BUDGET=4 ;;
    balanced) WORD_BUDGET=120; SENTENCE_BUDGET=6 ;;
    thorough) WORD_BUDGET=320; SENTENCE_BUDGET=16 ;;
  esac
fi

# Pull the text of the most recent assistant turn: every text block emitted
# after the last genuine human prompt. Tool-result entries are also role:user
# in the transcript, so "human prompt" = a user entry whose content is a plain
# string OR an array with no tool_result block. jq reads the whole JSONL stream.
LAST_RESPONSE="$(
  jq -rs '
    def is_human_user:
      .type == "user"
      and ((.message.content | type) == "string"
           or ([.message.content[]? | .type] | (index("tool_result") | not)));
    (map(is_human_user) | rindex(true)) as $u
    | (if $u == null then . else .[$u + 1:] end)
    | map(select(.type == "assistant")
          | .message.content[]? | select(.type == "text") | .text)
    | join(" ")
  ' "$TRANSCRIPT" 2>/dev/null
)"

[[ -z "$LAST_RESPONSE" ]] && exit 0

WORDS=$(echo "$LAST_RESPONSE" | wc -w | tr -d ' ')
# Rough sentence proxy: runs of sentence-ending punctuation.
SENTENCES=$(echo "$LAST_RESPONSE" | grep -oE '[.!?]+(\s|$)' | wc -l | tr -d ' ')

# Under budget on both axes -> already terse. Say nothing.
if [[ "$WORDS" -le "$WORD_BUDGET" && "$SENTENCES" -le "$SENTENCE_BUDGET" ]]; then
  exit 0
fi

cat <<EOF
<system-reminder>
Brevity drift: your last response ran ~$WORDS words / ~$SENTENCES sentences, over budget ($WORD_BUDGET words, $SENTENCE_BUDGET sentences). Tighten this turn — lead with the answer, cut preamble and trailing recap, prefer fragments and short lists over prose. Keep length only where it is genuinely load-bearing (code, commit/PR text, or a multi-step safety-critical sequence); otherwise compress hard.
</system-reminder>
EOF

exit 0
