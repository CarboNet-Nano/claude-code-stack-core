#!/usr/bin/env bash
# Tests for scripts/lib/gate-vacuity.sh (testing doctrine v2, P1b:
# docs/superpowers/specs/2026-08-16-testing-doctrine-redesign.md) and its
# wiring into .github/workflows/test-install.yml (the unit-tests loop
# wrapper, and the changes job's independent trigger-vacuity predicate).
#
# YAML-content assertion style follows tests/test-sweep-workflows.sh's
# job_block awk-range convention (house precedent; that helper is
# duplicated per test file there too, no shared test lib exists).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/gate-vacuity.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/test-install.yml"
EXEMPTIONS="$REPO_ROOT/config/gate-vacuity-exemptions.txt"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; echo "----"; echo "test-gate-vacuity: 0 passed, 1 failed"; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "FATAL: $WORKFLOW not found"; echo "----"; echo "test-gate-vacuity: 0 passed, 1 failed"; exit 1; }
[[ -f "$EXEMPTIONS" ]] || { echo "FATAL: $EXEMPTIONS not found"; echo "----"; echo "test-gate-vacuity: 0 passed, 1 failed"; exit 1; }

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "expected to contain [$needle]"; fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "expected NOT to contain [$needle]"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-vacuity-test.XXXXXX")" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# fixture <case-dir> -> a scratch cwd with a tests/ subdir the fixtures
# below drop scripts into.
fixture() {
  local dir="$TMP/$1"
  mkdir -p "$dir/tests"
  echo "$dir"
}

# ---------------------------------------------------------------------
# 1. Conforming file: two PASS: lines counted, no vacuity, exit 0.
# ---------------------------------------------------------------------
CASE1="$(fixture case1)"
cat > "$CASE1/tests/test-ok.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: first assertion"
echo "PASS: second assertion"
exit 0
EOF
chmod +x "$CASE1/tests/test-ok.sh"

OUT1="$(cd "$CASE1" && GV_EXEMPTIONS="$EXEMPTIONS" bash -c "source '$LIB' && gv_run_suite 'tests/test-*.sh'"; echo "RC=$?")"
RC1="$(grep -oE 'RC=[0-9]+' <<<"$OUT1" | cut -d= -f2)"
if [[ "$RC1" == "0" ]]; then pass "conforming-file-suite-exits-0"; else fail "conforming-file-suite-exits-0" "rc=$RC1"; fi
assert_contains "conforming-file-counts-two-passes" "$OUT1" "gate-vacuity: 2 passed, 0 failed, 0 vacuous"
assert_not_contains "conforming-file-not-vacuous" "$OUT1" "is vacuous"

# ---------------------------------------------------------------------
# 2. Silent, unexempted file: zero PASS:/FAIL: lines -> vacuous failure,
#    suite exits non-zero, naming the file.
# ---------------------------------------------------------------------
CASE2="$(fixture case2)"
cat > "$CASE2/tests/test-silent.sh" <<'EOF'
#!/usr/bin/env bash
echo "did some stuff, said nothing about pass or fail"
exit 0
EOF
chmod +x "$CASE2/tests/test-silent.sh"
EMPTY_EXEMPTIONS="$TMP/empty-exemptions.txt"
: > "$EMPTY_EXEMPTIONS"

OUT2="$(cd "$CASE2" && GV_EXEMPTIONS="$EMPTY_EXEMPTIONS" bash -c "source '$LIB' && gv_run_suite 'tests/test-*.sh'"; echo "RC=$?")"
RC2="$(grep -oE 'RC=[0-9]+' <<<"$OUT2" | cut -d= -f2)"
if [[ "$RC2" != "0" ]]; then pass "silent-unexempted-file-fails-suite"; else fail "silent-unexempted-file-fails-suite" "expected non-zero rc, got 0"; fi
assert_contains "silent-unexempted-file-names-itself-vacuous" "$OUT2" "tests/test-silent.sh is vacuous"
assert_contains "silent-unexempted-file-summary-counts-it" "$OUT2" "gate-vacuity: 0 passed, 0 failed, 1 vacuous"

# ---------------------------------------------------------------------
# 3. Same silent file, but exempted: no vacuous failure, suite exits 0.
# ---------------------------------------------------------------------
CASE3="$(fixture case3)"
cat > "$CASE3/tests/test-silent.sh" <<'EOF'
#!/usr/bin/env bash
echo "did some stuff, said nothing about pass or fail"
exit 0
EOF
chmod +x "$CASE3/tests/test-silent.sh"
CASE3_EXEMPTIONS="$TMP/case3-exemptions.txt"
echo "tests/test-silent.sh # fixture — exercises the exemption path" > "$CASE3_EXEMPTIONS"

OUT3="$(cd "$CASE3" && GV_EXEMPTIONS="$CASE3_EXEMPTIONS" bash -c "source '$LIB' && gv_run_suite 'tests/test-*.sh'"; echo "RC=$?")"
RC3="$(grep -oE 'RC=[0-9]+' <<<"$OUT3" | cut -d= -f2)"
if [[ "$RC3" == "0" ]]; then pass "exempted-silent-file-suite-exits-0"; else fail "exempted-silent-file-suite-exits-0" "rc=$RC3"; fi
assert_contains "exempted-silent-file-reports-exempt" "$OUT3" "tests/test-silent.sh is exempt"
assert_not_contains "exempted-silent-file-not-reported-vacuous" "$OUT3" "is vacuous"

# ---------------------------------------------------------------------
# 4. Failure semantics preserved: a file that exits non-zero fails the
#    suite with the exact prior sentence, even though it also emitted
#    PASS:/FAIL: lines (so it is not vacuous — the two failure modes are
#    independent and both must be able to fire).
# ---------------------------------------------------------------------
CASE4="$(fixture case4)"
cat > "$CASE4/tests/test-broken.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: setup ran"
echo "FAIL: the thing under test"
exit 1
EOF
chmod +x "$CASE4/tests/test-broken.sh"

OUT4="$(cd "$CASE4" && GV_EXEMPTIONS="$EMPTY_EXEMPTIONS" bash -c "source '$LIB' && gv_run_suite 'tests/test-*.sh'"; echo "RC=$?")"
RC4="$(grep -oE 'RC=[0-9]+' <<<"$OUT4" | cut -d= -f2)"
if [[ "$RC4" != "0" ]]; then pass "nonzero-exit-file-fails-suite"; else fail "nonzero-exit-file-fails-suite" "expected non-zero rc, got 0"; fi
assert_contains "nonzero-exit-file-exact-prior-sentence" "$OUT4" "FAIL: tests/test-broken.sh exited non-zero"
assert_contains "nonzero-exit-file-counts-preserved" "$OUT4" "gate-vacuity: 1 passed, 1 failed, 0 vacuous"

# ---------------------------------------------------------------------
# 5. Mixed glob: totals aggregate across multiple files in one call.
# ---------------------------------------------------------------------
CASE5="$(fixture case5)"
cat > "$CASE5/tests/test-a.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: a1"
echo "PASS: a2"
exit 0
EOF
cat > "$CASE5/tests/test-b.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: b1"
echo "FAIL: b2"
exit 0
EOF
chmod +x "$CASE5/tests/test-a.sh" "$CASE5/tests/test-b.sh"

OUT5="$(cd "$CASE5" && GV_EXEMPTIONS="$EMPTY_EXEMPTIONS" bash -c "source '$LIB' && gv_run_suite 'tests/test-*.sh'"; echo "RC=$?")"
RC5="$(grep -oE 'RC=[0-9]+' <<<"$OUT5" | cut -d= -f2)"
if [[ "$RC5" == "0" ]]; then pass "mixed-glob-suite-exits-0"; else fail "mixed-glob-suite-exits-0" "rc=$RC5"; fi
assert_contains "mixed-glob-aggregates-totals" "$OUT5" "gate-vacuity: 3 passed, 1 failed, 0 vacuous"

# ---------------------------------------------------------------------
# 6. Exemption list accuracy, spot-checked against the real repo: every
#    path in config/gate-vacuity-exemptions.txt exists, and running it
#    for real emits zero ^PASS:/^FAIL: lines — the exemption is honest,
#    not a guess.
# ---------------------------------------------------------------------
SPOT_CHECKED=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  entry="${line%%#*}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [[ -z "$entry" ]] && continue
  path="$REPO_ROOT/$entry"
  if [[ ! -f "$path" ]]; then
    fail "exemption-entry-exists: $entry"
    continue
  fi
  pass "exemption-entry-exists: $entry"
  SPOT_CHECKED=$((SPOT_CHECKED + 1))
done < "$EXEMPTIONS"
if [[ "$SPOT_CHECKED" -ge 3 ]]; then
  pass "exemption-list-has-at-least-3-entries-to-spot-check"
else
  fail "exemption-list-has-at-least-3-entries-to-spot-check" "found $SPOT_CHECKED"
fi

# ---------------------------------------------------------------------
# 7. Wiring proven: YAML-content assertions (test-sweep-workflows.sh
#    precedent) that the wrapper is present in the unit-tests loop and
#    the independent predicate step exists in the changes job.
# ---------------------------------------------------------------------
WORKFLOW_CONTENT="$(cat "$WORKFLOW")"

# job_block <file> <job-key-regex> -> that job's lines, from its header
# under the top-level `jobs:` map to (not including) the next 2-space
# job key or EOF. Copied from tests/test-sweep-workflows.sh (no shared
# test lib exists to import it from).
job_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_jobs = 0; in_job = 0 }
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:/ {
      if (in_job) { exit }
      if ($0 ~ "^  " key ":") { in_job = 1 }
    }
    in_job { print }
  ' "$file"
}

UNIT_TESTS_BLOCK="$(job_block "$WORKFLOW" "unit-tests")"
CHANGES_BLOCK="$(job_block "$WORKFLOW" "changes")"

assert_contains "unit-tests-job-sources-gate-vacuity-lib" "$UNIT_TESTS_BLOCK" "scripts/lib/gate-vacuity.sh"
assert_contains "unit-tests-job-calls-gv-run-suite" "$UNIT_TESTS_BLOCK" "gv_run_suite"
assert_contains "unit-tests-job-still-globs-test-files" "$UNIT_TESTS_BLOCK" "tests/test-*.sh"

assert_contains "changes-job-has-trigger-vacuity-step" "$CHANGES_BLOCK" "Independent trigger-vacuity check"
assert_contains "changes-job-trigger-vacuity-step-id" "$CHANGES_BLOCK" "id: trigger-vacuity"
assert_contains "changes-job-trigger-vacuity-checks-extensions" "$CHANGES_BLOCK" "*.sh|*.mjs"
assert_contains "changes-job-trigger-vacuity-checks-schemas-path" "$CHANGES_BLOCK" "schemas/*"
assert_contains "changes-job-trigger-vacuity-checks-shebang" "$CHANGES_BLOCK" '"#!"'
assert_contains "changes-job-trigger-vacuity-checks-executable-bit" "$CHANGES_BLOCK" '-x "$f"'
assert_contains "changes-job-trigger-vacuity-fails-open-on-unavailable-base" "$CHANGES_BLOCK" "base-unavailable"

# Uses a DIFFERENT predicate from the filter step it audits (LB8): the
# filter step's own regex must not be the thing this step re-runs.
assert_not_contains "trigger-vacuity-does-not-reuse-filter-regex" "$CHANGES_BLOCK" 'grep -vE .(docs/|\.claude/|graphify-out/)'

# ---------------------------------------------------------------------
# 8. YAML validity, when PyYAML is available (house fallback pattern).
# ---------------------------------------------------------------------
if python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 - "$WORKFLOW" << 'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
assert "trigger-vacuity" not in jobs, "trigger-vacuity must be a step, not its own job"
changes_steps = jobs["changes"]["steps"]
ids = [s.get("id") for s in changes_steps]
assert "filter" in ids and "trigger-vacuity" in ids
assert ids.index("trigger-vacuity") > ids.index("filter"), "trigger-vacuity must run after filter"
unit_run = [s for s in jobs["unit-tests"]["steps"] if "gv_run_suite" in (s.get("run") or "")]
assert len(unit_run) == 1, "unit-tests must wire gv_run_suite into exactly one step"
sys.exit(0)
PYEOF
  then
    pass "pyyaml-structural-parse"
  else
    fail "pyyaml-structural-parse"
  fi
else
  echo "SKIP: python3 'yaml' module not installed — structural greps above are the coverage."
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW" >/dev/null 2>&1; then
    pass "actionlint-clean"
  else
    fail "actionlint-clean" "$(actionlint "$WORKFLOW" 2>&1)"
  fi
else
  echo "SKIP: actionlint not installed — test-install.yml validity not independently checked beyond the greps above."
fi

echo "----"
echo "test-gate-vacuity: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
