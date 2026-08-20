#!/usr/bin/env bash
# UserPromptSubmit hook: auto-enablement for loop-engineering (ADR-023 / Phase 3,
# ADR-047 revision). When a prompt looks like iterate-until-verified work, inject
# a reminder telling the assistant to actually ASK (via AskUserQuestion) whether
# to run it as a governed loop. This recurs every session by design (ADR-047) —
# it is no longer a one-time-ever onboarding nudge; the persistent on/off control
# is session_prefs.auto_offer_loop, not a permanent "already onboarded" marker.
#
# Fires only when ALL of:
#   1) prompt is NOT a slash command and not trivially short
#   2) prompt matches the loop-shape taxonomy (foreman's, reused here)
#   3) project is stack-initialized at Tier >= 2 (loop-eng lives at Tier 2+)
#   4) session_prefs.auto_offer_loop is not explicitly false (default true)
#   5) once per session (dedupe), so it never nags every turn
# Output is injected as system-reminder context. Fail-open: any error -> silent.
# summary: Each session, nudges toward a governed-loop ask when a prompt looks like iterate-until-verified work, unless auto_offer_loop is off.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
PROMPT="$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# 1) skip slash commands + short prompts.
[[ "$PROMPT" =~ ^/ ]] && exit 0
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
[[ "$WORD_COUNT" -lt 6 ]] && exit 0

# 2) loop-shape classifier (mirrors foreman's loop-shape table). Conservative:
#    require an explicit iterate/until/recurring signal — one-shot edits, Q&A,
#    and "explain/read" never match.
LOWER="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"
LOOP_RE='\b(until (it|the|all|tests|they|done)|iterate|keep (going|running|trying)|babysit|repeatedly|run .* until|loop until|every (hour|day|commit|run)|recurring|watch the pr|eval.*(threshold|until)|until .* (pass|passes|green|done)|don.?t stop|keep .* until)\b'
echo "$LOWER" | grep -qE "$LOOP_RE" || exit 0
# Negative guard: pure read/explain requests are not loops even if they say "until".
echo "$LOWER" | grep -qE '^\s*(explain|what|why|how does|show me|describe|summari)' && exit 0

# 3) Tier 2+ stack project only.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"

# 4) auto_offer_loop off -> silent. Live session override wins over the
#    project default. current-prefs.json is flat (top-level keys); the
#    project stack-config.json nests the same field under session_prefs.
#    NOTE: jq's `//` treats `false` as absent (same as null), so a bare
#    `.auto_offer_loop // true` would silently ignore an explicit `false`.
#    Use an explicit null-check instead.
AUTO_OFFER="$(jq -r 'if has("auto_offer_loop") and .auto_offer_loop != null then (.auto_offer_loop | tostring) else empty end' "$STATE_DIR/current-prefs.json" 2>/dev/null)"
[[ -z "$AUTO_OFFER" ]] && AUTO_OFFER="$(jq -r '(.session_prefs // {}) as $sp | if ($sp | has("auto_offer_loop")) and $sp.auto_offer_loop != null then ($sp.auto_offer_loop | tostring) else "true" end' "$CONFIG" 2>/dev/null)"
[[ "$AUTO_OFFER" == "false" ]] && exit 0

# 5) once-per-session dedupe (scoped to session id; skip dedupe if absent).
#    Not a permanent marker — a fresh flag is written every session, so the
#    ask recurs next session (ADR-047), unlike the old one-time-ever onboarding.
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
if [[ -n "$SESSION_ID" ]]; then
  FLAG="$STATE_DIR/loop-shape-nudged.$SESSION_ID"
  [[ -f "$FLAG" ]] && exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$FLAG" 2>/dev/null || true
fi

cat <<'EOF'
<system-reminder>
Loop-shape detected: this request looks like iterate-until-verified work. Before doing the work, actually ASK via AskUserQuestion (don't just note it and proceed) — this recurs every session by design (ADR-047); it is not a one-time onboarding, and auto_offer_loop is the persistent off-switch if the user wants it silenced (set via /session or /project-init):
  1) Run as a governed loop (iterate until a check passes)?  — yes (recommended) / one-shot
  2) Autonomy — checkpoint (recommended) / bounded-checkpoint / bounded-autonomous (clamp to the tier ceiling, or /loop-level for a named L1-L4 preset)
  3) Raise autonomy for this session (ultracode)? — off (recommended) / on
  4) Design-first (brainstorming → /plan) before code? — on (recommended) / off
If they say yes: actually invoke the loop-engineer skill now to set it up (don't just record the preference and proceed one-shot). If they want it persisted, point at /session ("save as project default"). If they decline, honor it and proceed one-shot this time — the ask still recurs next session unless they turn auto_offer_loop off. If the work clearly isn't loop-shaped after all, ignore this and proceed.
</system-reminder>
EOF
exit 0
