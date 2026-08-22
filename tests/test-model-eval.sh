#!/usr/bin/env bash
# Tests for the /model-eval harness (plan: docs/plans/2026-08-07-model-matrix-eval.md).
# Validates: the skill documents every gate the plan requires, it reuses
# /effort-eval's fixtures rather than forking them, the model_eval log row is
# additive (existing consumers of subagent-runs.jsonl must exclude it exactly as
# they already exclude effort_eval/workflow_dispatch/main_turn rows), and the
# skill is installed by the tier manifest it claims.
# No network, no model calls, no dispatches.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/model-eval/SKILL.md"
FIXTURE_DIR="$REPO_ROOT/.claude/effort-eval/golden-tasks"
TIER4="$REPO_ROOT/config/tier-manifests/tier-4.json"
REGISTRY="$REPO_ROOT/config/capability-registry.json"
PLAN="$REPO_ROOT/docs/plans/2026-08-07-model-matrix-eval.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
finish() { echo; echo "model-eval: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]] || exit 1; exit 0; }

# --- 0. prerequisites must fail loudly, never silently pass later checks -----
if [[ ! -f "$SKILL" ]]; then
  fail "skills/model-eval/SKILL.md does not exist"
  finish
fi
pass "skills/model-eval/SKILL.md exists"

for f in "$TIER4" "$REGISTRY"; do
  if [[ ! -f "$f" ]] || ! jq empty "$f" 2>/dev/null; then
    fail "$(basename "$f") missing or not valid JSON"
    finish
  fi
done
pass "tier-4 manifest and capability registry are present and valid JSON"

[[ -f "$PLAN" ]] && pass "plan of record exists" || fail "plan of record missing at $PLAN"

# --- 1. the metered-spend gate must be documented, verbatim -----------------
# The whole point of this skill's cost discipline is that "ok"/"go ahead" must
# NOT start a run. If this literal drifts, the gate is decorative.
grep -q 'literal word `proceed`' "$SKILL" \
  && pass "skill requires the literal word 'proceed' before spending" \
  || fail "skill does not require the literal word 'proceed' — metered gate is missing"

grep -qi 'METERED' "$SKILL" \
  && pass "skill frontmatter/body marks the run as METERED" \
  || fail "skill does not mark itself METERED"

grep -qiE 'never scheduled|on-demand only' "$SKILL" \
  && pass "skill states it is on-demand only, never scheduled" \
  || fail "skill does not forbid scheduled runs"

# --- 2. noise floor is the load-bearing step; without it every result is noise
grep -qi 'noise floor' "$SKILL" \
  && pass "skill documents a noise-floor measurement" \
  || fail "skill has no noise-floor step — model gaps cannot be distinguished from noise"

grep -q 'INDISCRIMINATE' "$SKILL" \
  && pass "skill defines the INDISCRIMINATE verdict for sub-noise-floor results" \
  || fail "skill has no verdict for 'all gaps inside the noise floor'"

# --- 3. capability grid must be probed, not inherited from docs -------------
# The published advisor pairing table was wrong on 2026-08-07 (omitted
# same-model pairs, mis-stated haiku). Designing around it again is the
# regression this check exists to prevent.
grep -qiE 'probe the (capability |live )?(api|grid)|Probe the capability grid' "$SKILL" \
  && pass "skill requires probing the capability grid against the live API" \
  || fail "skill does not require probing the live API for the pairing grid"

grep -qi 'do not trust this' "$SKILL" \
  && pass "skill marks its own cached grid as untrusted" \
  || fail "skill presents a cached grid without marking it untrusted"

# --- 4. blind + randomized judging, or the scores mean nothing --------------
grep -qiE 'never reveal the config to the judge' "$SKILL" \
  && pass "skill forbids revealing the config to the judge" \
  || fail "skill does not forbid revealing the config to the judge"

grep -qi 'randomize' "$SKILL" \
  && pass "skill requires randomized presentation order" \
  || fail "skill does not require randomized presentation order"

# --- 5. fixtures are REUSED from effort-eval, not forked --------------------
# A forked fixture set silently makes the two skills incomparable.
grep -q 'effort-eval/golden-tasks' "$SKILL" \
  && pass "skill reads /effort-eval's fixture path" \
  || fail "skill does not reference the shared fixture path"

grep -qi 'do not fork the fixtures' "$SKILL" \
  && pass "skill explicitly forbids forking the fixtures" \
  || fail "skill does not forbid forking the fixtures"

if [[ -d "$FIXTURE_DIR" ]]; then
  pass "shared fixture directory exists"
  # every agent named as a Phase 1 target must actually have a fixture
  for agent in architect security-auditor implementer; do
    if [[ -f "$FIXTURE_DIR/$agent.json" ]] && jq empty "$FIXTURE_DIR/$agent.json" 2>/dev/null; then
      pass "phase-1 target '$agent' has a valid fixture"
    else
      fail "phase-1 target '$agent' has no valid fixture at $FIXTURE_DIR/$agent.json"
    fi
  done
else
  fail "shared fixture directory does not exist at $FIXTURE_DIR"
fi

# --- 6. the model_eval log row must be ADDITIVE ----------------------------
# Every existing consumer filters by .event. A row that omits the event key, or
# carries a cost key, corrupts dispatch counts or loop budgets respectively.
grep -q 'event:"model_eval"' "$SKILL" \
  && pass "skill emits an explicit event:\"model_eval\" key" \
  || fail "skill's log row has no explicit model_eval event key"

grep -qiE 'do not add a `?cost_usd`? or `?cost`? key|never add a cost' "$SKILL" \
  && pass "skill forbids a cost key (would pollute loop-cost-accrual budgets)" \
  || fail "skill does not forbid a cost key — loop budgets would absorb eval spend"

# one row per (agent, config, task) — the fix for effort_eval's aggregate-only flaw
grep -qiE 'one row per \(agent, config, task\)' "$SKILL" \
  && pass "skill logs one row per (agent, config, task), not per comparison" \
  || fail "skill does not log per-cell rows — post-hoc comparison would be impossible"

# --- 6b. real consumers must actually exclude the new event ----------------
# Assert against the shipped consumers rather than trusting the claim.
# REQ-115 removed goodmorning's log read entirely; the readers today are the
# skills/libs below. effort-eval only WRITES rows and is deliberately absent.
CONSUMERS_OK=1
# ADR-074: the handoff skill is a mechanism-free stub and reads no log at all.
# session-close.sh's handoff-gather is the consumer that replaced it — and it
# is the reader, not carbonight, which now only prints what gather returns.
for consumer in "$REPO_ROOT/scripts/session-close.sh" \
                "$REPO_ROOT/skills/team-status/SKILL.md" \
                "$REPO_ROOT/skills/agent-performance-review/SKILL.md" \
                "$REPO_ROOT/skills/loop-engineer/loop_lib.sh"; do
  [[ -f "$consumer" ]] || continue
  # a consumer is safe if it filters on .event at all
  grep -q '\.event' "$consumer" || { CONSUMERS_OK=0; echo "  note: $(basename "$(dirname "$consumer")") does not filter on .event"; }
done
[[ $CONSUMERS_OK -eq 1 ]] \
  && pass "shipped log consumers filter by .event (model_eval rows excluded by construction)" \
  || fail "a shipped log consumer does not filter by .event — model_eval rows would be miscounted"

# --- 7. advisor results must never be treated as production routing --------
# Direct-API runs are not the real agent. This is the 2026-08-05
# security-auditor lesson encoded as a check.
grep -qiE 'directional' "$SKILL" \
  && pass "skill labels advisor results as directional, not production-routing" \
  || fail "skill does not label advisor results as directional"

grep -qi 'security-auditor' "$SKILL" \
  && pass "skill cites the 2026-08-05 precedent for harness-fidelity risk" \
  || fail "skill omits the harness-fidelity precedent"

# --- 8. results must never auto-apply --------------------------------------
grep -qiE 'does not change any model assignment|a human decides' "$SKILL" \
  && pass "skill states results do not auto-apply" \
  || fail "skill does not state that results require a human decision"

# --- 9. cross-family judge discipline (ADR-011) ----------------------------
grep -q 'oair_call' "$SKILL" \
  && pass "skill reuses the existing cross-family judge plumbing" \
  || fail "skill does not reuse oair_call — a bespoke judge would break ADR-011"

grep -qiE 'gmn_call' "$SKILL" \
  && pass "skill documents the Gemini-judge fallback for OpenAI-sourced output" \
  || fail "skill has no cross-family fallback when output is itself OpenAI-sourced"

# --- 10. the skill must actually ship ---------------------------------------
jq -e '.files.global[] | select(.from == "skills/model-eval/SKILL.md")' "$TIER4" >/dev/null 2>&1 \
  && pass "tier-4 manifest installs skills/model-eval/SKILL.md" \
  || fail "tier-4 manifest does not install the skill"

jq -e '.smoke_tests[] | select(test("model-eval"))' "$TIER4" >/dev/null 2>&1 \
  && pass "tier-4 manifest smoke-tests the installed skill" \
  || fail "tier-4 manifest has no smoke test for the skill"

jq -e '.capabilities[] | select(.id == "model-eval")' "$REGISTRY" >/dev/null 2>&1 \
  && pass "capability registry contains the model-eval entry" \
  || fail "capability registry is stale — re-run scripts/gen-capability-registry.sh"

# --- 11. known harness defect must stay visible ----------------------------
# Cross-family agents' effort axis measures the wrong hop until fixed. If this
# warning is dropped, someone will run red-team through this skill and believe it.
grep -qiE 'orchestrating Claude|wrong hop' "$SKILL" \
  && pass "skill carries the cross-family effort-directive defect warning" \
  || fail "skill dropped the cross-family harness defect warning"

finish
