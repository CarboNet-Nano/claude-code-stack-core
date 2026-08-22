#!/usr/bin/env bash
# Stop hook: main-session turn accrual + once-per-session receipt fallback for
# the post-session model-fit receipt (ADR-033). Two jobs, one hook (the ADR's
# "one thin hook" — no separate nudge hook):
#
# 1. Appends ONE main-session turn row per Stop event to subagent-runs.jsonl,
#    tagged event:"main_turn" agent:"main" — the two structural tags that make
#    subagent exclusion trivial for the receipt (model_fit_receipt_line sums
#    only rows with both tags).
#
#    tool_counts, model, and usage are ALL computed by reading the whole
#    transcript file (the Stop payload's transcript_path) and scoping to
#    messages emitted since the last human prompt — same full-slurp idiom as
#    hooks/brevity-drift.sh. The "since last human prompt" scoping is a
#    LOGICAL bound (only this turn's activity is counted), not an I/O bound
#    — a very large transcript is still read in full on every Stop event. This
#    is a COUNT/SUM over the completed turn, not a per-call accrual, so a
#    tool-heavy turn is still exactly one row (the PostToolUse-windowing
#    failure mode the ADR dropped).
#
#    CORRECTION (2026-07-26): the Stop hook payload does NOT carry `.model` or
#    `.usage` — verified by capturing a live payload (fields are session_id,
#    transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name,
#    stop_hook_active, last_assistant_message, background_tasks, session_crons;
#    no usage, no model). The original design read `.model // "claude-opus-
#    4-8"` and `.usage.input_tokens // 0` straight off that payload — both
#    always missing, so every row ever written defaulted to model
#    "claude-opus-4-8" with 0 tokens, regardless of which model actually ran.
#    Since model_fit_receipt_line prices against the LAST row's model, every
#    receipt this stack has ever printed was costed against opus-4-8 pricing
#    no matter what model was in use. The real data lives in the transcript:
#    each assistant message there carries .message.model and .message.usage
#    (input_tokens/output_tokens; also cache_read/cache_creation, not
#    currently summed — see note below). Fixed by pulling both from the same
#    transcript scan that already computes tool_counts, taking the model of
#    the LAST assistant message in the turn (handles a mid-turn /model switch
#    by reporting what was active when the turn closed) and summing
#    input_tokens/output_tokens across every assistant message in the turn
#    (a turn can span multiple assistant messages — one per tool-call round).
#    cache_read_input_tokens/cache_creation_input_tokens are real cost too but
#    are NOT summed here — that changes loop_cost_from_usage's pricing
#    contract (two args, not four) and is out of scope for a bug fix; the
#    receipt still under-counts cache-heavy sessions until that's addressed
#    separately. Missing/unreadable transcript -> model/tokens fall back to
#    the prior defaults (fail-safe, honest — no cost attributed for that turn).
#
# 2. Fallback surface: at most once per session, prints the shared receipt
#    line (model_fit_receipt_line, loop_lib.sh) via <system-reminder> so users
#    who never run /carbonight still see it. Dedupe flag
#    model-fit-receipt.<session_id>.printed, pruned at SessionStart exactly
#    like passive_suggest.*.nudged (hooks/session-prefs-init.sh).
#
# Gated on session_prefs.model_fit_receipt != off (governs BOTH jobs). Fail-safe:
# any error -> exit 0. ALWAYS exits 0 — this never blocks the stop; the sole
# output (if any) is an advisory system-reminder, never {"decision":"block"}.
# summary: Accrues per-turn token usage on Stop and prints a once-per-session model-fit receipt.
set -uo pipefail

PREFS="$HOME/.claude/session-state/current-prefs.json"
if [[ -f "$PREFS" ]]; then
  MODE="$(jq -r '.model_fit_receipt // "on"' "$PREFS" 2>/dev/null || echo on)"
  [[ "$MODE" == "off" ]] && exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# Never re-trigger on a stop-hook-active loop iteration (mirrors loop-stop.sh):
# each Stop invocation should append at most one row for the turn it closes.
SHA="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[[ "$SHA" == "true" ]] && exit 0

TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# tool_counts + model + usage, all from ONE scan of the transcript (see the
# header correction above for why this replaced Stop-payload extraction).
# Scoped to assistant messages emitted after the last genuine human prompt
# (same "last human prompt" definition as brevity-drift.sh). No transcript ->
# every default below (fail-safe, honest — no cost attributed for that turn).
TOOL_COUNTS='{"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}'
_MODEL=""
_IN=0
_OUT=0
_ADVISOR=0
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  TURN_JSON="$(
    jq -rs '
      def is_human_user:
        .type == "user"
        and ((.message.content | type) == "string"
             or ([.message.content[]? | .type] | (index("tool_result") | not)));
      def bucket($name):
        if $name == "Edit" or $name == "MultiEdit" then "edit"
        elif $name == "Write" then "write"
        elif $name == "Bash" then "bash"
        elif $name == "Read" then "read"
        elif $name == "Agent" or $name == "Task" or $name == "Workflow" then "agent"
        else "other" end;
      (map(is_human_user) | rindex(true)) as $u
      | (if $u == null then . else .[$u + 1:] end)
      | [ .[] | select(.type == "assistant") ] as $turn_msgs
      | {
          tool_counts: (
            [ $turn_msgs[] | .message.content[]? | select(.type == "tool_use") | .name ]
            | map(bucket(.))
            | reduce .[] as $b ({"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}; .[$b] += 1)
          ),
          model: (($turn_msgs | map(select(.message.model != null and .message.model != "")) | last // {}).message.model // ""),
          in_tokens: ([ $turn_msgs[] | (.message.usage.input_tokens // 0) ] | add // 0),
          out_tokens: ([ $turn_msgs[] | (.message.usage.output_tokens // 0) ] | add // 0),
          advisor_calls: (
            [ $turn_msgs[] | .message.content[]?
              | select(.type == "server_tool_use" and .name == "advisor") ]
            | length
          )
        }
    ' "$TRANSCRIPT" 2>/dev/null
  )"
  if [[ -n "$TURN_JSON" ]]; then
    TOOL_COUNTS="$(echo "$TURN_JSON" | jq -c '.tool_counts // {"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}' 2>/dev/null)"
    [[ -z "$TOOL_COUNTS" ]] && TOOL_COUNTS='{"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}'
    _MODEL="$(echo "$TURN_JSON" | jq -r '.model // ""' 2>/dev/null)"
    _IN="$(echo "$TURN_JSON" | jq -r '.in_tokens // 0' 2>/dev/null)"
    _OUT="$(echo "$TURN_JSON" | jq -r '.out_tokens // 0' 2>/dev/null)"
    _ADVISOR="$(echo "$TURN_JSON" | jq -r '.advisor_calls // 0' 2>/dev/null)"
  fi
fi

[[ -z "$_MODEL" || "$_MODEL" == "null" ]] && _MODEL="claude-sonnet-5"
# Sanitize at the write site: model ids are always [A-Za-z0-9._-]. Strip
# anything else so a crafted/corrupt transcript model string can never carry
# control characters, markup, or JSON into the log (write-side half of the
# injection fix; model_fit_receipt_line re-sanitizes on read as belt-and-suspenders).
_MODEL="$(printf '%s' "$_MODEL" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$_MODEL" ]] && _MODEL="claude-sonnet-5"

[[ "$_IN"  =~ ^[0-9]+$ ]] || _IN=0
[[ "$_OUT" =~ ^[0-9]+$ ]] || _OUT=0
[[ "$_ADVISOR" =~ ^[0-9]+$ ]] || _ADVISOR=0

PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

SESSION_START=""
[[ -f "$HOME/.claude/state/session-start.txt" ]] && \
  SESSION_START="$(cat "$HOME/.claude/state/session-start.txt" 2>/dev/null || true)"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"

LOG="$HOME/.claude/logs/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0

jq -nc \
  --arg ts "$TS" \
  --arg session_start "$SESSION_START" \
  --arg project "$PROJECT" \
  --arg model "$_MODEL" \
  --argjson in_tok "$_IN" \
  --argjson out_tok "$_OUT" \
  --argjson advisor_calls "$_ADVISOR" \
  --argjson tool_counts "$TOOL_COUNTS" \
  '{event:"main_turn", agent:"main", ts:$ts, session_start:$session_start, project:$project, model:$model, in_tokens:$in_tok, out_tokens:$out_tok, advisor_calls:$advisor_calls, tool_counts:$tool_counts}' \
  >> "$LOG" 2>/dev/null || true

# --- Job 2: once-per-session receipt fallback ---

# No resolvable session_start -> the receipt cannot honestly scope to "this
# session," and must not silently widen to all-time project history. Skip
# Job 2 entirely rather than call the lib with an empty session_start (the
# lib itself also refuses an empty session_start, as belt-and-suspenders).
[[ -z "$SESSION_START" ]] && exit 0

SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -z "$SID" ]] && exit 0   # no session id -> can't dedupe safely, skip the print (row above already landed)
SID="${SID//[^A-Za-z0-9._-]/_}"   # filename-safe, blocks path traversal

STATE_DIR="$HOME/.claude/session-state"
FLAG="$STATE_DIR/model-fit-receipt.$SID.printed"
[[ -f "$FLAG" ]] && exit 0   # already printed this session

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

LINE="$(model_fit_receipt_line "$SESSION_START" "$PROJECT" "$LOG" 2>/dev/null || echo "")"

# Insufficient evidence / no data yet -> stay silent WITHOUT setting the flag,
# so a later Stop in the same session (once enough turns accrue) can still
# print. The flag is set only at the moment a receipt actually prints.
[[ -z "$LINE" ]] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null && : > "$FLAG" 2>/dev/null || true

# ADR-040: append the advisor pair-usage line, if any. A SEPARATE function
# (model_fit_advisor_line), not folded into model_fit_receipt_line's own
# case-block — that function's suggestion is gated behind a minimum-evidence
# check (total_turns>=6, mass>=12) meant for the workload-shape read, and
# nesting this inside it would mean a session with real advisor usage but
# thin turn data prints nothing about advisor — exactly the case most worth
# surfacing. If model_fit_advisor_line errors, fail-safe to no addition
# (never lose the base receipt over this).
ADVISOR_LINE="$(model_fit_advisor_line "$SESSION_START" "$PROJECT" "$LOG" 2>/dev/null || echo "")"
[[ -n "$ADVISOR_LINE" ]] && LINE="$LINE $ADVISOR_LINE"

# Print-site sanitization (third layer, defense in depth): strip any '<', '>',
# or raw newline from the composed line before it goes inside the
# <system-reminder> wrapper, so nothing in the receipt text — model ids are
# already sanitized upstream, but this also covers any future field added to
# the sentence — can break out of the wrapper or fake a JSON decision object
# on the hook's stdout. model_fit_receipt_line's output is a single sentence;
# collapsing embedded newlines to spaces changes nothing for legitimate output.
LINE="$(printf '%s' "$LINE" | tr '\n' ' ' | tr -d '<>')"

printf '<system-reminder>\n%s\n</system-reminder>\n' "$LINE"
exit 0
