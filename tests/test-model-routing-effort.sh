#!/usr/bin/env bash
# Tests for the ADR-056 per-agent effort field in config/model-routing.json.
# Validates: every subagent_assignments entry has a valid 'effort' enum
# value, and every escalation_triggers entry (if present) references a real
# domain_mode from config/domain-modes.json and a valid effort value. No
# network or model calls are made.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTING="$REPO_ROOT/config/model-routing.json"
DOMAIN_MODES="$REPO_ROOT/config/domain-modes.json"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

VALID_EFFORTS='["low","medium","high","xhigh","max"]'

# --- 0. config must parse as JSON — a broken file must FAIL, not silently
#        produce empty jq output that every later check reads as "no violations" ---
if ! jq empty "$ROUTING" 2>/dev/null; then
  fail "config/model-routing.json is not valid JSON"
  echo
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
pass "config/model-routing.json is valid JSON"

# --- 1. every subagent_assignments entry has a valid effort value -----------
MISSING="$(jq -r --argjson valid "$VALID_EFFORTS" '
  .subagent_assignments
  | to_entries[]
  | select(.key | startswith("_") | not)
  | select((.value.effort // empty) == "" or (.value.effort as $e | $valid | index($e) | not))
  | .key
' "$ROUTING")"

if [[ -z "$MISSING" ]]; then
  pass "every subagent_assignments entry has a valid effort value"
else
  fail "entries missing/invalid effort: $(echo "$MISSING" | tr '\n' ' ')"
fi

# --- 2. escalation_triggers entries reference a real domain_mode ------------
REAL_MODES="$(jq -c '.modes | keys' "$DOMAIN_MODES")"

BAD_TRIGGERS="$(jq -r --argjson modes "$REAL_MODES" '
  .subagent_assignments
  | to_entries[]
  | select(.value.escalation_triggers? != null)
  | .key as $agent
  | .value.escalation_triggers[]
  | select((.domain_mode as $m | $modes | index($m) | not))
  | $agent
' "$ROUTING")"

if [[ -z "$BAD_TRIGGERS" ]]; then
  pass "escalation_triggers reference real domain_mode keys"
else
  fail "escalation_triggers with unknown domain_mode: $(echo "$BAD_TRIGGERS" | tr '\n' ' ')"
fi

# --- 3. escalation_triggers effort values are also valid ---------------------
BAD_TRIGGER_EFFORTS="$(jq -r --argjson valid "$VALID_EFFORTS" '
  .subagent_assignments
  | to_entries[]
  | select(.value.escalation_triggers? != null)
  | .key as $agent
  | .value.escalation_triggers[]
  | select((.effort as $e | $valid | index($e) | not))
  | $agent
' "$ROUTING")"

if [[ -z "$BAD_TRIGGER_EFFORTS" ]]; then
  pass "escalation_triggers effort values are valid"
else
  fail "escalation_triggers with invalid effort: $(echo "$BAD_TRIGGER_EFFORTS" | tr '\n' ' ')"
fi

# --- 4. at least one agent has an escalation_triggers entry ------------------
# Policy invariant (plan success criterion), not a schema check: if this ever
# fails because routing policy legitimately changed, update the assertion —
# don't just delete it, the plan requires the escalation_triggers shape to be
# exercised by at least one real agent.
TRIGGER_COUNT="$(jq -r '[.subagent_assignments | to_entries[] | select(.value.escalation_triggers? != null)] | length' "$ROUTING")"
if [[ "$TRIGGER_COUNT" -ge 1 ]]; then
  pass "at least one subagent has escalation_triggers ($TRIGGER_COUNT found)"
else
  fail "no subagent has escalation_triggers"
fi

# --- 5. security-auditor specifically escalates on financial-code / schema-migration ---
# Policy invariant (plan success criterion), not a schema check — same caveat as #4.
SEC_MODES="$(jq -c '[.subagent_assignments.["security-auditor"].escalation_triggers[]?.domain_mode]' "$ROUTING")"
if echo "$SEC_MODES" | jq -e 'index("financial-code") and index("schema-migration")' >/dev/null 2>&1; then
  pass "security-auditor escalates on financial-code and schema-migration"
else
  fail "security-auditor escalation_triggers missing financial-code/schema-migration ($SEC_MODES)"
fi


# --- 6. escalation_triggers that carry `primary` must name a real provider model,
#        and foreman must document that it honors `primary` (ADR-056 amendment,
#        2026-08-07). A trigger that raises the model while the orchestrator only
#        reads `effort` is inert config — it reads as applied and changes nothing. ---
BAD_PRIMARY="$(jq -r '
  [ .providers | to_entries[] | (.value.models // {}) | keys[] ] as $known
  | .subagent_assignments
  | to_entries[]
  | select(.value.escalation_triggers? != null)
  | .key as $agent
  | .value.escalation_triggers[]
  | select(.primary? != null)
  | select((.primary | sub("^[a-z]+/"; "")) as $m | $known | index($m) | not)
  | "\($agent):\(.primary)"
' "$ROUTING")"
KNOWN_COUNT="$(jq -r '[ .providers | to_entries[] | (.value.models // {}) | keys[] ] | length' "$ROUTING")"
if [[ "${KNOWN_COUNT:-0}" -eq 0 ]]; then
  fail "could not enumerate provider models — the primary-validity check would pass vacuously"
elif [[ -z "$BAD_PRIMARY" ]]; then
  pass "escalation_triggers 'primary' values name real provider models ($KNOWN_COUNT known)"
else
  fail "escalation_triggers with unknown primary model: $(echo "$BAD_PRIMARY" | tr '\n' ' ')"
fi

TRIGGERS_WITH_PRIMARY="$(jq -r '
  [ .subagent_assignments | to_entries[]
    | select(.value.escalation_triggers? != null)
    | .value.escalation_triggers[] | select(.primary? != null) ] | length
' "$ROUTING")"
FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
if [[ "$TRIGGERS_WITH_PRIMARY" -eq 0 ]]; then
  pass "no model-raising triggers present (nothing for foreman to honor)"
elif [[ -f "$FOREMAN" ]] && grep -q '`primary`' "$FOREMAN" && grep -qi "model.*parameter\|as the .Agent. tool" "$FOREMAN"; then
  pass "foreman documents honoring escalation_triggers 'primary' as the dispatch model"
else
  fail "config has $TRIGGERS_WITH_PRIMARY model-raising trigger(s) but foreman does not document honoring 'primary' — the config is inert"
fi

# --- 7. a model-raising trigger must carry evidence — a routing change with no
#        cited measurement is the hand-curation ADR-040 warns rots. ---
NO_EVIDENCE="$(jq -r '
  .subagent_assignments | to_entries[]
  | select(.value.escalation_triggers? != null)
  | .key as $agent
  | .value.escalation_triggers[]
  | select(.primary? != null)
  | select((.evidence // "") == "")
  | $agent
' "$ROUTING")"
if [[ -z "$NO_EVIDENCE" ]]; then
  pass "every model-raising trigger cites evidence"
else
  fail "model-raising trigger with no evidence field: $(echo "$NO_EVIDENCE" | tr '\n' ' ')"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
