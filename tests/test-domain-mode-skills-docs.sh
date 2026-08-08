#!/usr/bin/env bash
# Tests for ADR-053 -- BUCKET B of the tester split: structural / docs-logic
# tests against the three-invocation consent flow documented in
# skills/domain-mode/SKILL.md, skills/project-init/SKILL.md and
# skills/sensitivity/SKILL.md.
#
# WHY THIS FILE EXISTS AND WHAT IT DOES NOT PROVE: these three SKILL.md files
# are markdown instructions read by an LLM agent at runtime -- there is no
# interpreter, no function to call, no way to "execute" them in a test
# harness. Every assertion below is a grep against the prose: it proves the
# documented contract (P0/R2b/the three invocations/the exact refusal and
# divergence message text/the one-parser rule) is still WRITTEN DOWN
# correctly. It proves nothing about what an agent actually does at runtime.
# A regression here means the next agent to read this file will be told the
# wrong thing; it does not mean an agent got it wrong today. This is the
# same limitation tests/test-docs-logic-freshness.sh already accepts for its
# own docs-logic checks (see that file's header) -- ADR-053's handoff doc
# explicitly sanctions this style at T-45(c), T-62(a) and T-66(g).
#
# Case IDs (T-N) reference docs/ADRs/053-implementer-handoff.md.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DM_SKILL="$REPO_ROOT/skills/domain-mode/SKILL.md"
PI_SKILL="$REPO_ROOT/skills/project-init/SKILL.md"
SENS_SKILL="$REPO_ROOT/skills/sensitivity/SKILL.md"
ADR="$REPO_ROOT/docs/ADRs/053-multi-domain-mode-path-scoped-routing.md"

[[ -f "$DM_SKILL" ]] || { echo "FAIL: $DM_SKILL not found"; exit 1; }
[[ -f "$PI_SKILL" ]] || { echo "FAIL: $PI_SKILL not found"; exit 1; }
[[ -f "$SENS_SKILL" ]] || { echo "FAIL: $SENS_SKILL not found"; exit 1; }
[[ -f "$ADR" ]] || { echo "FAIL: $ADR not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# assert_grep <label> <file> <pattern> [-F for fixed-string]
assert_grep() {
  local label="$1" file="$2" pattern="$3" mode="${4:-}"
  if [[ "$mode" == "-F" ]]; then
    grep -qF -- "$pattern" "$file" && pass "$label" || fail "$label (pattern not found: $pattern)"
  else
    grep -Eq -- "$pattern" "$file" && pass "$label" || fail "$label (pattern not found: $pattern)"
  fi
}
assert_not_grep() {
  local label="$1" file="$2" pattern="$3"
  grep -qF -- "$pattern" "$file" && fail "$label (unexpectedly found: $pattern)" || pass "$label"
}
assert_order() {
  # assert_order <label> <file> <needle1> <needle2> -- needle1's line number < needle2's
  local label="$1" file="$2" n1="$3" n2="$4"
  local l1 l2
  l1="$(grep -nF -- "$n1" "$file" | head -1 | cut -d: -f1)"
  l2="$(grep -nF -- "$n2" "$file" | head -1 | cut -d: -f1)"
  if [[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]]; then
    pass "$label"
  else
    fail "$label (line($n1)=$l1, line($n2)=$l2)"
  fi
}

echo "== ADR-053 multi-domain-mode suite (BUCKET B: skill-flow docs-logic) =="

# ---------------------------------------------------------------------------
# T-19 / T-45(c) -- the three-invocation flow, in order, one human decision
# ---------------------------------------------------------------------------
assert_order "T-19: domain-mode.SKILL.md documents run 1 before the prompt" "$DM_SKILL" "**Run 1 — the report.**" "**Prompt set**"
assert_order "T-19: domain-mode.SKILL.md documents the prompt before run 2" "$DM_SKILL" "**Prompt set**" "**Run 2 — the drift gate.**"
assert_order "T-19: domain-mode.SKILL.md documents run 2 before the reconcile" "$DM_SKILL" "**Run 2 — the drift gate.**" "**Reconcile — the one durable sidecar write.**"
assert_order "T-19: domain-mode.SKILL.md documents the reconcile before run 3" "$DM_SKILL" "**Reconcile — the one durable sidecar write.**" "**Run 3 — the apply.**"
assert_grep "T-19: the prompt is driven only by clause in {consent, consent-stale}" "$DM_SKILL" \
  'entry in .inputs\.suppressions_withheld. whose .clause. is'
assert_grep "T-19: the y/N batch is named the single human decision point" "$DM_SKILL" \
  "single human decision point" -F
assert_grep "T-19: run 2 has exactly two outcomes (proceed / abort-without-writing)" "$DM_SKILL" \
  "Abort" -F
assert_grep "T-45(c): no path deletes an ack inside an error handler" "$DM_SKILL" \
  "Never delete an ack inside an error" -F
assert_grep "T-45(c): the skill never composes an MCP rule string itself" "$DM_SKILL" \
  "Never compose a rule string yourself" -F

# ---------------------------------------------------------------------------
# T-20 -- canonical write form (D10)
# ---------------------------------------------------------------------------
assert_grep "T-20: canonical form -- 0 modes writes null" "$DM_SKILL" \
  '0 modes.*domain_mode: null'
assert_grep "T-20: canonical form -- 1 mode writes a bare string" "$DM_SKILL" \
  '1 mode.*bare string'
assert_grep "T-20: canonical form -- >=2 modes writes an array" "$DM_SKILL" \
  'modes.*an array'

# ---------------------------------------------------------------------------
# T-23 / T-31(a) -- mode removal deletes inapplicable acks and orphan keys
# ---------------------------------------------------------------------------
# NOTE: the implementer-handoff doc's "Files to touch" section paraphrases
# this as one sentence ("/domain-mode none and any mode-removal delete the
# now-inapplicable ack entries and orphaned keys") -- that exact sentence is
# NOT literal SKILL.md text; the underlying mechanism is: (1) step 2 prunes
# orphaned domain_mode_paths keys on every config write, and (2) the
# reconcile's keep-set rule (T-32, above) deletes every acks_prunable pair,
# which is exactly what a removed mode's now-inapplicable acks become
# (classified undeclared-mode -- see T-51(iii) in BUCKET A). Check both halves.
assert_grep "T-31(a): step 2 prunes orphaned domain_mode_paths keys on every write" "$DM_SKILL" \
  'Prune any `domain_mode_paths` orphan' -F

# ---------------------------------------------------------------------------
# T-32 -- reconcile keep-set A ∪ B; everything else (incl. every prunable pair) deleted
# ---------------------------------------------------------------------------
assert_grep "T-32/T-44: reconcile keep-set is A ∪ B, byte-identical carry-forward for B" "$DM_SKILL" \
  "becomes exactly the union of" -F
assert_grep "T-32: every acks_prunable pair, fresh or stale, is deleted by the reconcile" "$DM_SKILL" \
  "acks_prunable\`, fresh or stale — is deleted" -F

# ---------------------------------------------------------------------------
# T-35 -- empty prompt set writes/deletes nothing
# ---------------------------------------------------------------------------
assert_grep "T-35: an empty prompt set writes no ack and asks nothing" "$DM_SKILL" \
  "Empty → no prompt, no ack written, no ritual" -F

# ---------------------------------------------------------------------------
# T-38 / T-49 / T-50 -- fail-safe when the report is unavailable / drifts
# ---------------------------------------------------------------------------
assert_grep "T-38: domain-mode.SKILL.md prints the exact consent-check-unavailable line" "$DM_SKILL" \
  'consent check unavailable (<reason>); no acknowledgement written' -F
assert_grep "T-38: project-init.SKILL.md prints the same consent-check-unavailable line" "$PI_SKILL" \
  'consent check unavailable (<reason>); no' -F
assert_grep "T-49/T-50: the drift gate compares run2.inputs != run1.inputs by deep equality" "$DM_SKILL" \
  'run2.inputs != run1.inputs` (deep equality)' -F
assert_grep "T-49/T-50: the drift gate names the first differing field, in a fixed order" "$DM_SKILL" \
  "Name the **first**" -F

# ---------------------------------------------------------------------------
# T-43 (the /sensitivity leg) -- non-prompting writer, prune only, no drift gate
# ---------------------------------------------------------------------------
assert_grep "T-43/T-61: /sensitivity gets NO drift gate and NO prompt (pure prune)" "$SENS_SKILL" \
  "deliberately with **no drift gate and no prompt**" -F
assert_grep "T-43/T-59(b): P1 (write) precedes P2 (prune) -- never invert" "$SENS_SKILL" \
  "prune (P2) must come **after** this write, never before" -F

# ---------------------------------------------------------------------------
# T-48 -- verify assertions (against run 3's own plan, never re-derived)
# ---------------------------------------------------------------------------
assert_grep "T-48/T-30: verify asserts inputs.acks_in_force == A ∪ B" "$DM_SKILL" \
  'inputs.acks_in_force == A ∪ B' -F
assert_grep "T-48: verify asserts inputs.acks_prunable == []" "$DM_SKILL" \
  'inputs.acks_prunable == []' -F
assert_grep "T-48: project-init verify asserts inputs.acks_in_force == A (arity carve-out)" "$PI_SKILL" \
  'inputs.acks_in_force == A' -F

# ---------------------------------------------------------------------------
# T-58 -- named residual: a run-2 abort leaves the step-2 config write in place
# ---------------------------------------------------------------------------
assert_grep "T-58: named residual -- a drift-gate abort at step 5 leaves the config write in place" "$DM_SKILL" \
  "a drift-gate abort at step 5 leaves the step-2 config write in" -F
assert_grep "T-58: re-running /domain-mode with the same arguments converges" "$DM_SKILL" \
  "with the same arguments is idempotent and converges" -F

# ---------------------------------------------------------------------------
# T-61 -- /sensitivity's non-prompting writer prune contract, all sub-cases
# ---------------------------------------------------------------------------
assert_order "T-61: P0 precedes P1" "$SENS_SKILL" "P0 — preflight" "P1 — write."
assert_order "T-61: P1 precedes P2" "$SENS_SKILL" "P1 — write." "P2 — report and prune."
assert_order "T-61: P2 precedes P3" "$SENS_SKILL" "P2 — report and prune." "P3 — apply."
assert_grep "T-61(b): acks_prunable == [] -> no sidecar write at all" "$SENS_SKILL" \
  'acks_prunable == []` → **no' -F
assert_grep "T-61(d): a missing acks_prunable key is NOT treated as an empty prune" "$SENS_SKILL" \
  "a missing key is" -F
assert_grep "T-61(d): compiler-unavailable prints the sensitivity-specific unavailable line" "$SENS_SKILL" \
  "no acknowledgement" -F
assert_grep "T-61(d): compiler-unavailable continues to P3 anyway (the apply still runs)" "$SENS_SKILL" \
  "continue to P3 anyway (the apply still runs)" -F
assert_grep "T-61: P2b catches the sidecar becoming unparseable between P0 and P2, aborts before P3" "$SENS_SKILL" \
  "P2b — the sidecar must still parse" -F

# ---------------------------------------------------------------------------
# T-64 -- named residual (c): writer-vs-writer unlocked sidecar race, pinned OPEN
# ---------------------------------------------------------------------------
assert_grep "T-64: ADR names residual (c) -- writer-vs-writer unlocked read-modify-write" "$ADR" \
  "writer-vs-writer on the sidecar" -F
assert_grep "T-64: ADR states residual (c) is pinned, not closed (open residual language present)" "$ADR" \
  "Open, named residuals" -F

# ---------------------------------------------------------------------------
# T-66(a)/(b)/(c)/(d)/(e)/(f)/(g) -- the strengthening-intent asymmetry
# ---------------------------------------------------------------------------
for f in "$DM_SKILL:domain-mode" "$PI_SKILL:project-init" "$SENS_SKILL:sensitivity"; do
  file="${f%%:*}"; name="${f##*:}"
  assert_grep "T-66(a): $name P0 refuses on the mergeability predicate before any write" "$file" \
    "cannot be merged into" -F
  assert_grep "T-66(a): $name refusal names the PERMANENT-deletion clause" "$file" \
    "PERMANENT" -F
  assert_grep "T-66(g): $name uses the pinned python3/json heredoc, never jq" "$file" \
    'python3 -m json.tool' -F
  assert_not_grep "T-66(g): $name never pipes the predicate through \`jq\` for the mergeability check" "$file" \
    'jq ".claude/permissions.stack.json"'
  assert_grep "T-66(g): $name evaluates via Python's json module (import json)" "$file" \
    "import json, sys" -F
done
assert_grep "T-66(e): domain-mode.SKILL.md names the exact cost of deleting the sidecar (waivers[]/pinned[] gone)" "$DM_SKILL" \
  "waivers[] and pinned[]" -F
assert_grep "T-66(f)/T-45(c): R2b is documented as mandatory even if the resulting write would be byte-identical" "$DM_SKILL" \
  "mandatory whenever the file exists," -F
assert_grep "T-66(c): R2b prints the mid-flow divergence message, never the P0 preflight message" "$DM_SKILL" \
  "the mid-flow divergence message (not the" -F
assert_grep "T-66(c): sensitivity's P2b aborts before P3 with the mid-flow divergence message" "$SENS_SKILL" \
  "abort the prune AND abort" -F

echo "----------------------------------------"
echo "domain-mode-skills-docs (ADR-053 BUCKET B): $PASS passed, $FAIL failed"
echo "This file proves the SKILL.md prose is internally consistent and matches"
echo "the ADR's documented contract -- it does NOT prove agent runtime behavior."
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
