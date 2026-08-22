#!/usr/bin/env bash
# UserPromptSubmit hook (ADR-052): the real-time half of ADR-042's declare-only
# model/advisor pairing design. ADR-042 D-2 established that neither /model nor
# /advisor can be invoked programmatically, and confirmed (ADR-040) the stack
# must never silently write model/advisorModel itself — only print an
# instruction and let the user run the native command. This hook is that
# instruction's real-time trigger.
#
# WHY DETECT-AFTER-THE-FACT, NOT MATCH-ON-PROMPT: native built-in slash
# commands (/model, /advisor) are intercepted and handled entirely client-side
# by the CLI before ANY hook fires — confirmed against the Claude Code hooks
# reference before writing this. UserPromptSubmit only ever sees custom-skill
# invocations and free text, never native commands. So this hook cannot match
# on prompt text at all; instead it runs on every prompt (cheap: two file
# reads, no subprocess beyond jq) and compares the CURRENTLY EFFECTIVE
# model/advisorModel pair to the pair it saw last time. A user who just ran
# `/model sonnet` sees the change reflected in settings.json by the time their
# very next prompt (of any kind) is submitted — this is "next turn", not
# "same turn", but it is real, automatic, and requires no cooperation from the
# native command path that will never expose itself to hooks.
#
# Fires only when ALL of:
#   1) session_prefs.auto_offer_advisor_pair is not explicitly false (default true)
#   2) the (model, advisorModel) pair has actually changed since this hook's
#      own last observation this session (first observation ever this session
#      just seeds state silently -- there is nothing to compare against yet,
#      and nudging on session start regardless of prior state would nag every
#      session for a pair the user set deliberately last time)
#   3) the NEW pair does not already match the ladder's recommended one-tier-up
#      pairing (if the user already fixed both keys before their next prompt,
#      or the drift landed on the recommended pair by coincidence, there is
#      nothing to suggest)
# Output is injected as system-reminder context, instructing the assistant to
# call AskUserQuestion. This hook NEVER writes settings.json itself (D-2).
# Fail-open: any error -> silent, state update skipped rather than corrupted.
# summary: Detects a model/advisorModel change since last seen this session and nudges toward the ladder-recommended pairing, unless auto_offer_advisor_pair is off.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
[[ -z "$CWD" ]] && CWD="$PWD"

STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"
ROUTING="$HOME/.claude/config/model-routing.json"
USER_SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null 2>&1 || exit 0

# 1) auto_offer_advisor_pair off -> silent. Same explicit-null-check idiom as
#    loop-shape-nudge.sh's auto_offer_loop gate: jq's `//` treats `false` as
#    absent, so a bare `.auto_offer_advisor_pair // true` would silently
#    ignore an explicit `false`.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
AUTO_OFFER="$(jq -r 'if has("auto_offer_advisor_pair") and .auto_offer_advisor_pair != null then (.auto_offer_advisor_pair | tostring) else empty end' "$STATE_DIR/current-prefs.json" 2>/dev/null)"
if [[ -z "$AUTO_OFFER" && -n "$CONFIG" ]]; then
  AUTO_OFFER="$(jq -r '(.session_prefs // {}) as $sp | if ($sp | has("auto_offer_advisor_pair")) and $sp.auto_offer_advisor_pair != null then ($sp.auto_offer_advisor_pair | tostring) else "true" end' "$CONFIG" 2>/dev/null)"
fi
[[ -z "$AUTO_OFFER" ]] && AUTO_OFFER="true"
[[ "$AUTO_OFFER" == "false" ]] && exit 0

# 2) Resolve the CURRENTLY EFFECTIVE model. Precedence per ADR-042 Gate G1
#    (empirically confirmed, not assumed): project .claude/settings.json AND
#    project .claude/settings.local.json both outrank user ~/.claude/settings.json
#    for the `model` key. Relative order between the two project files was not
#    itself part of G1's tested claim -- settings.local.json is checked first
#    here on the general Claude Code convention that .local overrides its
#    non-local sibling, consistent with this repo's own
#    settings.local.json-over-settings.json handling elsewhere. Flagged as a
#    judgment call, not a re-verified fact, in the ADR.
resolve_model() {
  local proj_local="" proj_settings="" user_settings=""
  if [[ -n "$CONFIG" ]]; then
    local proj_dir; proj_dir="$(dirname "$(dirname "$CONFIG")")"
    [[ -f "$proj_dir/.claude/settings.local.json" ]] && \
      proj_local="$(jq -r '.model // empty' "$proj_dir/.claude/settings.local.json" 2>/dev/null)"
    [[ -n "$proj_local" && "$proj_local" != "null" ]] && { echo "$proj_local"; return 0; }
    [[ -f "$proj_dir/.claude/settings.json" ]] && \
      proj_settings="$(jq -r '.model // empty' "$proj_dir/.claude/settings.json" 2>/dev/null)"
    [[ -n "$proj_settings" && "$proj_settings" != "null" ]] && { echo "$proj_settings"; return 0; }
  fi
  # Fallback tier applies regardless of whether a project stack-config
  # resolved -- a project with no stack-config.json still has an effective
  # model, from the user-global settings.json.
  [[ -f "$USER_SETTINGS" ]] && \
    user_settings="$(jq -r '.model // empty' "$USER_SETTINGS" 2>/dev/null)"
  [[ -n "$user_settings" && "$user_settings" != "null" ]] && { echo "$user_settings"; return 0; }
  return 0
}
MODEL="$(resolve_model)"
[[ -z "$MODEL" ]] && exit 0

# advisorModel is a global user setting only (~/.claude/settings.json) -- no
# project-scope advisorModel exists, per skills/loop-engineer/loop_lib.sh's
# established precedent (model_fit_advisor_line).
ADVISOR="$([[ -f "$USER_SETTINGS" ]] && jq -r '.advisorModel // empty' "$USER_SETTINGS" 2>/dev/null)"
[[ -z "$ADVISOR" || "$ADVISOR" == "null" ]] && exit 0

# 3) Ladder position -- read LIVE from model-routing.json every time (never
#    hardcoded), so an ADR-042/model-audit change to the ladder is honored
#    without touching this hook. Match by FAMILY KEYWORD substring (haiku/
#    sonnet/opus/fable), the same robustness technique loop_lib.sh's
#    _model_fit_ladder_pos uses -- settings.json may store a short alias
#    ("sonnet") or a full dated id ("claude-sonnet-5"), and exact-string
#    matching against the ladder array would break on that mismatch.
[[ -f "$ROUTING" ]] || exit 0
LADDER_JSON="$(jq -c '.model_fit.tier_ladder // empty' "$ROUTING" 2>/dev/null)"
[[ -z "$LADDER_JSON" || "$LADDER_JSON" == "null" ]] && exit 0

family_of() {
  local m; m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    *haiku*)  echo haiku ;;
    *sonnet*) echo sonnet ;;
    *opus*)   echo opus ;;
    *fable*)  echo fable ;;
    *) echo "" ;;
  esac
}

# Build a family-keyword array parallel to the ladder, in the SAME order --
# position in this array is the ladder's live ordinal, not a hardcoded 1-4.
LADDER_FAMILIES="$(echo "$LADDER_JSON" | jq -r '.[]' 2>/dev/null | while read -r entry; do family_of "$entry"; done)"
MODEL_FAM="$(family_of "$MODEL")"
ADVISOR_FAM="$(family_of "$ADVISOR")"
[[ -z "$MODEL_FAM" ]] && exit 0

MODEL_POS=-1
i=0
RECOMMENDED_FAM=""
while IFS= read -r fam; do
  [[ "$fam" == "$MODEL_FAM" ]] && MODEL_POS=$i
  i=$((i+1))
done <<< "$LADDER_FAMILIES"
[[ "$MODEL_POS" -lt 0 ]] && exit 0
NEXT_POS=$((MODEL_POS+1))
RECOMMENDED_FAM="$(echo "$LADDER_FAMILIES" | sed -n "$((NEXT_POS+1))p")"
[[ -z "$RECOMMENDED_FAM" ]] && exit 0  # model is already at the ladder ceiling -- nothing above to recommend

# 4) Compare to last-seen pair this session. First-ever observation seeds
#    silently. A change from last-seen that ALREADY matches the recommended
#    pairing is not worth nudging about.
PAIR_KEY="${MODEL}|${ADVISOR}"
if [[ -n "$SESSION_ID" ]]; then
  SEEN_FILE="$STATE_DIR/advisor-pair-seen.$SESSION_ID"
  LAST_SEEN=""
  [[ -f "$SEEN_FILE" ]] && LAST_SEEN="$(cat "$SEEN_FILE" 2>/dev/null || true)"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s' "$PAIR_KEY" > "$SEEN_FILE" 2>/dev/null || true

  [[ -z "$LAST_SEEN" ]] && exit 0                 # first observation this session: seed only
  [[ "$LAST_SEEN" == "$PAIR_KEY" ]] && exit 0      # unchanged since last check
fi

[[ "$ADVISOR_FAM" == "$RECOMMENDED_FAM" ]] && exit 0  # already correctly paired

cat <<EOF
<system-reminder>
Model/advisor pair changed: base is now "$MODEL" (recognized as $MODEL_FAM-tier), advisor is "$ADVISOR" ($([[ -n "$ADVISOR_FAM" ]] && echo "$ADVISOR_FAM-tier" || echo "unrecognized")). The ladder in model-routing.json recommends a $RECOMMENDED_FAM-tier advisor for a $MODEL_FAM-tier base. Before doing anything else this turn, call AskUserQuestion offering:
  1) Switch advisor to the recommended $RECOMMENDED_FAM tier — run \`/advisor $RECOMMENDED_FAM\` yourself now (recommended)
  2) Keep the current pair as-is
  3) Skip (say nothing further about it this session unless it changes again)
Per ADR-042 D-2 and this hook's own design (ADR-052): you must NEVER write settings.json or run the native command on the user's behalf — only tell them which command to run themselves, exactly as ADR-042's existing SessionStart instruction does. If they choose option 1, tell them the exact command; do not attempt to invoke it. If the pair doesn't actually look like a real mismatch worth mentioning, use judgment and skip silently instead.
</system-reminder>
EOF
exit 0
