#!/usr/bin/env bash
# Tests for the /effort-eval harness (ADR-056 follow-up).
# Validates: golden-task fixtures are well-formed and reference real agents,
# the skill documents the pieces the plan requires, and the effort_eval log
# row is additive — existing consumers of subagent-runs.jsonl must exclude it
# exactly as they already exclude workflow_dispatch/main_turn rows.
# No network, no model calls, no dispatches.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTING="$REPO_ROOT/config/model-routing.json"
FIXTURE_DIR="$REPO_ROOT/.claude/effort-eval/golden-tasks"
SKILL="$REPO_ROOT/skills/effort-eval/SKILL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

VALID_EFFORTS='["low","medium","high","xhigh","max"]'

# --- 0. prerequisites must exist — a missing input must FAIL loudly, never
#        silently produce empty output that later checks read as "no problems" ---
if [[ ! -f "$ROUTING" ]] || ! jq empty "$ROUTING" 2>/dev/null; then
  fail "config/model-routing.json missing or not valid JSON"
  echo; echo "effort-eval: $PASS passed, $FAIL failed"; exit 1
fi
pass "config/model-routing.json is present and valid JSON"

if [[ ! -f "$SKILL" ]]; then
  fail "skills/effort-eval/SKILL.md does not exist"
  echo; echo "effort-eval: $PASS passed, $FAIL failed"; exit 1
fi
pass "skills/effort-eval/SKILL.md exists"

if [[ ! -d "$FIXTURE_DIR" ]]; then
  fail "golden-task fixture directory does not exist at $FIXTURE_DIR"
  echo; echo "effort-eval: $PASS passed, $FAIL failed"; exit 1
fi
pass "golden-task fixture directory exists"

# --- 1. at least one fixture, and every fixture is valid JSON ----------------
FIXTURES="$(find "$FIXTURE_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort)"
FIXTURE_COUNT="$(echo "$FIXTURES" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$FIXTURE_COUNT" -ge 1 ]]; then
  pass "at least one golden-task fixture exists ($FIXTURE_COUNT found)"
else
  fail "no golden-task fixtures found"
fi

BAD_JSON=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  jq empty "$f" 2>/dev/null || BAD_JSON="$BAD_JSON $(basename "$f")"
done <<< "$FIXTURES"
if [[ -z "$BAD_JSON" ]]; then
  pass "every fixture is valid JSON"
else
  fail "fixtures with invalid JSON:$BAD_JSON"
fi

# --- 2. every fixture's agent is a real agent in model-routing.json ----------
# A fixture naming an agent that doesn't exist would run against nothing and
# silently produce an empty eval.
BAD_AGENT=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  agent="$(jq -r '.agent // empty' "$f" 2>/dev/null)"
  if [[ -z "$agent" ]]; then
    BAD_AGENT="$BAD_AGENT $(basename "$f"):no-agent-field"
    continue
  fi
  jq -e --arg a "$agent" '.subagent_assignments[$a]' "$ROUTING" >/dev/null 2>&1 \
    || BAD_AGENT="$BAD_AGENT $(basename "$f"):$agent"
done <<< "$FIXTURES"
if [[ -z "$BAD_AGENT" ]]; then
  pass "every fixture references a real agent in model-routing.json"
else
  fail "fixtures naming unknown agents:$BAD_AGENT"
fi

# --- 3. every fixture's agent has a valid effort baseline to compare against -
# The harness compares baseline vs one tier up; an agent with no effort value
# has no baseline, so the eval is undefined for it.
BAD_EFFORT=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  agent="$(jq -r '.agent // empty' "$f" 2>/dev/null)"
  [[ -z "$agent" ]] && continue
  eff="$(jq -r --arg a "$agent" '.subagent_assignments[$a].effort // empty' "$ROUTING" 2>/dev/null)"
  echo "$VALID_EFFORTS" | jq -e --arg e "$eff" 'index($e)' >/dev/null 2>&1 \
    || BAD_EFFORT="$BAD_EFFORT $agent:${eff:-none}"
done <<< "$FIXTURES"
if [[ -z "$BAD_EFFORT" ]]; then
  pass "every fixture's agent has a valid effort baseline"
else
  fail "fixture agents with missing/invalid effort:$BAD_EFFORT"
fi

# --- 4. every task in every fixture has the required shape ------------------
BAD_TASK=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  n="$(jq -r '.tasks | length' "$f" 2>/dev/null)"
  if [[ ! "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]]; then
    BAD_TASK="$BAD_TASK $(basename "$f"):no-tasks"
    continue
  fi
  # id non-empty and unique; prompt non-empty; good_answer_signals non-empty array
  jq -e '
    (.tasks | length) as $n
    | (.tasks | map(.id) | map(select(. != null and . != "")) | unique | length) == $n
      and (.tasks | all(.prompt != null and .prompt != ""))
      and (.tasks | all((.good_answer_signals | type) == "array" and (.good_answer_signals | length) >= 1))
  ' "$f" >/dev/null 2>&1 || BAD_TASK="$BAD_TASK $(basename "$f")"
done <<< "$FIXTURES"
if [[ -z "$BAD_TASK" ]]; then
  pass "every task has a unique non-empty id, a prompt, and >=1 good_answer_signal"
else
  fail "fixtures with malformed tasks:$BAD_TASK"
fi

# --- 5. the skill documents the metered/approval gate ------------------------
# This harness spends real tokens. A version of the skill that lost its cost
# gate would be a silent regression, so pin it.
grep -q "proceed" "$SKILL" && grep -qi "cost" "$SKILL" \
  && pass "skill documents a cost projection and an explicit proceed gate" \
  || fail "skill is missing the cost-projection / proceed gate"

# --- 6. the skill documents blind, order-randomized judging ------------------
# Both protect the signal; losing either silently biases every future result.
grep -qi "never reveal the effort level" "$SKILL" \
  && pass "skill requires the judge be blind to effort level" \
  || fail "skill does not require blind judging"
grep -qi "randomiz" "$SKILL" \
  && pass "skill requires randomized presentation order" \
  || fail "skill does not require randomized presentation order"

# --- 7. the skill states the honest measurement limit ------------------------
# The Agent tool has no native effort parameter, so this measures the effect
# of a directive, not of guaranteed compute. A skill that dropped this caveat
# would license overclaiming from a null result.
grep -qi "no native effort parameter" "$SKILL" \
  && pass "skill states the directive-vs-guaranteed-compute limit" \
  || fail "skill omits the honest measurement limit"

# --- 8. the effort_eval log row is additive — existing consumers exclude it --
# Every consumer of subagent-runs.jsonl filters by event. Simulate a log
# holding a dispatch row and an effort_eval row, then apply the exact filter
# /goodmorning step 6b and /agent-performance-review use, and confirm only
# the dispatch row survives.
TMP_LOG="$(mktemp)"
trap 'rm -f "$TMP_LOG"' EXIT
jq -nc '{ts:"2026-08-05T10:00:00Z", project:"/p", agent:"architect", event:"dispatch"}' >> "$TMP_LOG"
jq -nc '{ts:"2026-08-05T10:01:00Z", project:"/p", agent:"architect", event:"effort_eval",
         baseline_effort:"high", bumped_effort:"xhigh", verdict:"inconclusive"}' >> "$TMP_LOG"

SURVIVORS="$(jq -r 'select((.event // "dispatch") == "dispatch") | select(.agent != "workflow") | .agent' "$TMP_LOG" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SURVIVORS" == "1" ]]; then
  pass "effort_eval rows are excluded by the standard dispatch filter (additive)"
else
  fail "dispatch filter returned $SURVIVORS rows, expected 1 — effort_eval row is leaking into dispatch counts"
fi

# --- 9. the effort_eval row carries no cost key that loop budgeting would sum -
# loop-cost-accrual.sh sums cost_usd/cost into a loop's live budget. An eval
# run is not loop spend; a cost key here would corrupt loop budget math.
grep -q 'cost_usd' "$SKILL" && grep -qi "do not add" "$SKILL" \
  && pass "skill explicitly forbids a cost_usd/cost key on the eval row" \
  || fail "skill does not warn against adding a cost key to the eval row"

# --- 10. the skill refuses to auto-apply a result ---------------------------
grep -qi "human decision\|a human decides" "$SKILL" \
  && pass "skill states results never auto-apply" \
  || fail "skill does not state that results never auto-apply"


# --- N. the skill must test effort DOWNWARD, not only upward -----------------
# Effort is non-monotonic: an agent's optimum can sit BELOW its assigned
# baseline, and an upward-only harness can never find it. The first seven runs
# of this skill were upward-only and all returned inconclusive/not-worth-it,
# which is what a roster already at or past its optimum looks like. A downgrade
# that ties is a cost saving and must be reportable as a positive result.
if grep -qiE 'one tier down|tier DOWN|test downward' "$SKILL"; then
  pass "skill tests one tier DOWN as well as up"
else
  fail "skill is upward-only — a below-baseline optimum would be undiscoverable"
fi

if grep -q 'DOWNGRADE' "$SKILL"; then
  pass "skill defines a DOWNGRADE/saves-money verdict"
else
  fail "skill has no verdict for 'lower effort was as good' — a saving would be buried as 'no difference'"
fi

if grep -qiE 'non-monotonic' "$SKILL"; then
  pass "skill states that effort is non-monotonic"
else
  fail "skill does not record that more effort can be worse"
fi

# dispatch arithmetic must match a three-arm run, or the cost projection lies
if grep -qE 'tasks × 3' "$SKILL"; then
  pass "cost projection accounts for three effort arms"
else
  fail "cost projection still assumes two arms — projection would understate spend"
fi

# and no stale two-arm language may survive alongside it
if grep -qiE '\btwice\b|both efforts' "$SKILL"; then
  fail "skill still contains two-arm language ('twice'/'both efforts') — self-contradictory"
else
  pass "no stale two-arm language remains"
fi

echo
echo "effort-eval: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
