#!/usr/bin/env bash
# tests/test-sweep-w1-replay.sh — the replay harness reports honestly.
#
# W1 does not enter scripts/sweep/inventory.txt until this instrument has
# run and its number is recorded (spec Decision 6). The number is only
# worth holding the id back for if it cannot be inflated, so these tests
# are mostly about what the harness REFUSES to hide: out-of-scope defects
# are named and excluded from the denominator, misses are named, and an
# absent list is an error rather than an empty perfect score.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$REPO_ROOT/scripts/sweep/w1-replay.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$REPLAY" ] || { echo "FATAL: $REPLAY not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/w1-replay-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

LIST="$TMP/defects.json"
cat > "$LIST" <<'JSON'
[
  {"id":"AP#217","in_scope":true,"caught":true},
  {"id":"AP#209","in_scope":true,"caught":true},
  {"id":"AP#215","in_scope":true,"caught":false},
  {"id":"AP#226","in_scope":false,"reason":"needs a declared per-field expectation, not a control assertion"},
  {"id":"AP#211","in_scope":false,"reason":"embedded viewer layout; needs a screenshot baseline"}
]
JSON

t_out_of_scope_defects_are_named() {
  local out
  out="$(bash "$REPLAY" "$LIST" 2>&1)"
  if printf '%s' "$out" | grep -q 'OUT-OF-SCOPE.*AP#226' && printf '%s' "$out" | grep -q 'OUT-OF-SCOPE.*AP#211'; then
    pass "out-of-scope defects are printed by id, never dropped from the report"
  else
    fail "out-of-scope defects missing from output: $out"
  fi
}

t_out_of_scope_reasons_are_printed() {
  local out
  out="$(bash "$REPLAY" "$LIST" 2>&1)"
  printf '%s' "$out" | grep -q 'screenshot baseline' \
    && pass "each out-of-scope defect carries its stated reason, so 'we cannot see it' is legible" \
    || fail "out-of-scope reason missing: $out"
}

t_catch_rate_denominator_excludes_out_of_scope() {
  local out rate
  out="$(bash "$REPLAY" "$LIST" 2>&1)"
  rate="$(printf '%s' "$out" | sed -n 's/.*\(catch rate: [0-9]*\/[0-9]*\).*/\1/p' | tail -1)"
  [ "$rate" = "catch rate: 2/3" ] \
    && pass "the catch-rate denominator counts only in-scope defects (2 of 3), never inflated by out-of-scope ones" \
    || fail "catch rate was '$rate', expected 'catch rate: 2/3'"
}

t_missed_defects_are_named() {
  local out
  out="$(bash "$REPLAY" "$LIST" 2>&1)"
  printf '%s' "$out" | grep -q 'MISSED.*AP#215' \
    && pass "a missed in-scope defect is named, not summarised away" \
    || fail "AP#215 not reported as MISSED: $out"
}

t_caught_defects_are_named() {
  local out n
  out="$(bash "$REPLAY" "$LIST" 2>&1)"
  n="$(printf '%s\n' "$out" | grep -c 'CAUGHT' || true)"
  [ "$n" = "2" ] \
    && pass "every caught defect is listed individually, so the number can be checked against the list" \
    || fail "CAUGHT line count was '$n', expected 2"
}

t_all_missed_reports_zero_not_silence() {
  local out rate
  cat > "$TMP/all-missed.json" <<'JSON'
[{"id":"X1","in_scope":true,"caught":false},{"id":"X2","in_scope":true,"caught":false}]
JSON
  out="$(bash "$REPLAY" "$TMP/all-missed.json" 2>&1)"
  rate="$(printf '%s' "$out" | sed -n 's/.*\(catch rate: [0-9]*\/[0-9]*\).*/\1/p' | tail -1)"
  [ "$rate" = "catch rate: 0/2" ] \
    && pass "a total miss reports 0/2 explicitly — a bad score is stated, never left blank" \
    || fail "all-missed rate was '$rate', expected 'catch rate: 0/2'"
}

t_every_defect_out_of_scope_reports_no_denominator_of_zero_as_success() {
  local out
  cat > "$TMP/all-oos.json" <<'JSON'
[{"id":"Y1","in_scope":false,"reason":"outside the verb set"}]
JSON
  out="$(bash "$REPLAY" "$TMP/all-oos.json" 2>&1)"
  printf '%s' "$out" | grep -q 'catch rate: 0/0' && printf '%s' "$out" | grep -qi 'nothing in scope' \
    && pass "a list with nothing in scope says so in words rather than presenting 0/0 as a result" \
    || fail "all-out-of-scope output was: $out"
}

t_missing_list_exits_nonzero() {
  local rc
  bash "$REPLAY" "$TMP/nope.json" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] \
    && pass "a missing defect list exits non-zero rather than reporting an empty perfect score" \
    || fail "missing list exited 0"
}

t_no_argument_exits_nonzero() {
  local rc
  bash "$REPLAY" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] \
    && pass "no argument at all exits non-zero" \
    || fail "no argument exited 0"
}

t_malformed_list_exits_nonzero() {
  local rc
  printf '%s' '{not json' > "$TMP/bad.json"
  bash "$REPLAY" "$TMP/bad.json" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] \
    && pass "a malformed defect list exits non-zero rather than scoring zero defects" \
    || fail "malformed list exited 0"
}

t_completed_measurement_exits_zero_whatever_the_score() {
  local rc
  bash "$REPLAY" "$TMP/all-missed.json" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] \
    && pass "a completed measurement exits 0 even at 0/2 — this instrument measures, it does not gate" \
    || fail "a completed measurement with a bad score exited $rc"
}

t_out_of_scope_defects_are_named
t_out_of_scope_reasons_are_printed
t_catch_rate_denominator_excludes_out_of_scope
t_missed_defects_are_named
t_caught_defects_are_named
t_all_missed_reports_zero_not_silence
t_every_defect_out_of_scope_reports_no_denominator_of_zero_as_success
t_missing_list_exits_nonzero
t_no_argument_exits_nonzero
t_malformed_list_exits_nonzero
t_completed_measurement_exits_zero_whatever_the_score

echo ""
echo "test-sweep-w1-replay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
