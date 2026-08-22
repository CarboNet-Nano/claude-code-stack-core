#!/usr/bin/env bash
# tests/run-adr-087-r1.sh — governed R1 test runner for ADR-087.
#
# This is the loop's governed success criterion for the ADR-087 R1
# implementation session. It does two things, in order:
#
#   1. Asserts .claude/sessions/763eee2b-f255-4265-871b-153de022e334/
#      adr-087-r0-answers.md exists and contains all five section headers
#      (a)-(e). R0's five empirical answers are a hard precondition for R1
#      per the architect handoff -- if R0 was skipped or its answers file
#      is missing/incomplete, this runner refuses to proceed rather than
#      run R1's tests against an unverified premise (most load-bearing:
#      answer (c), which R0 exit-gates R1 on).
#   2. Runs every R1 test file and exits 0 only if all of them pass.
#
# No test in the list below is stubbed or trivially-pass -- each one
# exercises real script/hook behavior (subprocess execution, real git
# repos, stubbed-but-real vendor call contracts). See each file's own
# header for what it covers and which case numbers from the ADR's 102-case
# plan it maps to.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Durable, tracked copy (cross-family review finding: the original
# session-local path is untracked, so a clean checkout could never pass).
R0_ANSWERS="$REPO_ROOT/docs/ADRs/087-r0-answers.md"

echo "=== ADR-087 R1 governed test runner ==="
echo ""
echo "--- Precondition: R0 answers file ---"

if [[ ! -f "$R0_ANSWERS" ]]; then
  echo "FATAL: R0 answers file not found: $R0_ANSWERS" >&2
  echo "R1 code must not be validated without R0's five empirical answers on record." >&2
  exit 1
fi

MISSING_SECTIONS=()
for letter in a b c d e; do
  grep -qE "^## \(${letter}\)" "$R0_ANSWERS" || MISSING_SECTIONS+=("$letter")
done

if [[ "${#MISSING_SECTIONS[@]}" -gt 0 ]]; then
  echo "FATAL: R0 answers file is missing section(s): ${MISSING_SECTIONS[*]}" >&2
  echo "All five of (a)-(e) must be present before R1 tests are trusted." >&2
  exit 1
fi

echo "PASS: R0 answers file present with all five sections (a)-(e): $R0_ANSWERS"
echo ""

# ── R1 test files, in dependency order (libs before consumers) ─────────────
R1_TESTS=(
  "tests/test-receipt-lib.sh"
  "tests/test-panel-review.sh"
  "tests/test-review-receipt-mint.sh"
  "tests/test-review-router-change-class.sh"
  "tests/test-review-gate.sh"
  "tests/test-review-gate-override.sh"
  "tests/test-review-gate-iteration.sh"
  "tests/test-rollout-verify.sh"
  "tests/test-fleet-report.sh"
  "tests/test-review-gate-docs.sh"
  "tests/test-review-gate-redteam.sh"
)

echo "--- Running ${#R1_TESTS[@]} R1 test files ---"
echo ""

OVERALL_RC=0
declare -a RESULTS=()

for t in "${R1_TESTS[@]}"; do
  TEST_PATH="$REPO_ROOT/$t"
  if [[ ! -f "$TEST_PATH" ]]; then
    echo "FATAL: declared R1 test file not found: $TEST_PATH" >&2
    OVERALL_RC=1
    RESULTS+=("MISSING $t")
    continue
  fi
  echo "════════════════════════════════════════════════════════════════"
  echo "▶ $t"
  echo "════════════════════════════════════════════════════════════════"
  if bash "$TEST_PATH"; then
    RESULTS+=("PASS $t")
  else
    RESULTS+=("FAIL $t")
    OVERALL_RC=1
  fi
  echo ""
done

echo "=== Summary ==="
for r in "${RESULTS[@]}"; do
  echo "$r"
done

if [[ "$OVERALL_RC" -eq 0 ]]; then
  echo ""
  echo "ALL R1 TEST FILES PASSED."
else
  echo ""
  echo "AT LEAST ONE R1 TEST FILE FAILED." >&2
fi

exit "$OVERALL_RC"
