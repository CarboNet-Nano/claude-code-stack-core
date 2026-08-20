#!/usr/bin/env bash
# Tests for tools/invariants (ADR-082 P1f, production-data invariants MVP):
# the docs/invariants/*.sql parse contract, non-vacuity, the write-probe
# refusal, verdict/ledger logic, and `report`'s counts + heartbeat.
#
# NO LIVE POSTGRES in CI -- every `run` invocation here uses
# INVARIANTS_FAKE_RESULTS (documented test-only env var, tools/invariants/
# src/executor.mjs's buildFakeExecutor) instead of a real 'pg' connection.
# Parser cases (valid file / missing key / id!=filename / multi-statement /
# bad severity / bad expect) exercise tools/invariants/src/parse.mjs
# directly through `bin.mjs run`'s exit-3 path. Write-probe and verdict/
# ledger logic are exercised through the same fake executor -- "probe
# succeeds -> exit 4" is unit-testable without a real role because the fake
# executor's __probe__ block stands in for the CREATE TEMP TABLE + INSERT
# result.
set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/tools/invariants/bin.mjs"

[[ -f "$BIN" ]] || { echo "FAIL: $BIN not found"; exit 1; }
[[ -d "$REPO_ROOT/tools/invariants/node_modules/pg" ]] || echo "NOTE: tools/invariants/node_modules/pg not installed -- run 'npm install' in tools/invariants (not needed for these fake-executor tests, only for a real 'run')"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected: $2 | actual: $3)"; }
assert_rc() { [[ "$3" -eq "$2" ]] && pass "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 (missing '$3' in: $2)"; }

# new_repo <destdir> -- an empty docs/invariants/ scaffold.
new_repo() { mkdir -p "$1/docs/invariants"; }

# write_invariant <destdir> <filename> <heredoc-body-on-stdin>
write_invariant() {
  local dest="$1" fname="$2"
  cat > "$dest/docs/invariants/$fname"
}

ledger_file() { echo "$1/docs/invariants/.meta/$2.verdicts.jsonl"; }

do_run() {
  local repo="$1" fake="$2"; shift 2
  OUT="$(INVARIANTS_FAKE_RESULTS="$fake" node "$BIN" run --repo-root "$repo" "$@" 2>&1)"
  RC=$?
}

do_report_json() {
  OUT="$(node "$BIN" report --repo-root "$1" --json 2>&1)"
  RC=$?
}

# safe_probe_fake <path> -- a fake-results file whose __probe__ reports a
# safe (not-both-succeeded) role, so `run` proceeds past the probe.
safe_probe_fake() {
  local f="$1"; shift
  local extra="${1:-}"
  if [[ -n "$extra" ]]; then
    jq -n --argjson extra "$extra" '{"__probe__": {"createOk": false, "insertOk": false}} + $extra' > "$f"
  else
    echo '{"__probe__": {"createOk": false, "insertOk": false}}' > "$f"
  fi
}

echo "== tools/invariants test suite =="

# ══════════════════════════════════════════════════════════════════════════
# Parser: valid file -> run succeeds, verdict PASS recorded.
# ══════════════════════════════════════════════════════════════════════════
R_VALID="$TMP/valid"
new_repo "$R_VALID"
write_invariant "$R_VALID" "past-due-predicted-zero.sql" <<'EOF'
-- id: past-due-predicted-zero
-- statement: zero past-due predicted rows survive a completed march day
-- severity: critical
-- expect: zero-rows
SELECT 1 WHERE false
EOF
FAKE_VALID="$TMP/fake-valid.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "past-due-predicted-zero": {"rows": []}}' > "$FAKE_VALID"
do_run "$R_VALID" "$FAKE_VALID"
assert_rc "valid file: run exits 0" 0 "$RC"
assert_contains "valid file: id reported PASS" "$OUT" "past-due-predicted-zero: PASS"
LF_VALID="$(ledger_file "$R_VALID" "past-due-predicted-zero")"
[[ -f "$LF_VALID" ]] && pass "valid file: ledger file was written" || fail "valid file: no ledger file at $LF_VALID"

# ══════════════════════════════════════════════════════════════════════════
# Parser: missing required key -> parse error, exit 3.
# ══════════════════════════════════════════════════════════════════════════
R_MISSING="$TMP/missing-key"
new_repo "$R_MISSING"
write_invariant "$R_MISSING" "bad.sql" <<'EOF'
-- id: bad
-- statement: test
-- expect: zero-rows
SELECT 1
EOF
FAKE_EMPTY="$TMP/fake-empty.json"; safe_probe_fake "$FAKE_EMPTY"
do_run "$R_MISSING" "$FAKE_EMPTY"
assert_rc "missing key: exits 3" 3 "$RC"
assert_contains "missing key: names the missing key" "$OUT" "missing required key 'severity'"
[[ ! -f "$(ledger_file "$R_MISSING" "bad")" ]] && pass "missing key: no ledger file written" \
  || fail "missing key: a ledger file was written despite the parse error"

# ══════════════════════════════════════════════════════════════════════════
# Parser: id != filename -> parse error, exit 3.
# ══════════════════════════════════════════════════════════════════════════
R_IDMISMATCH="$TMP/id-mismatch"
new_repo "$R_IDMISMATCH"
write_invariant "$R_IDMISMATCH" "actual-name.sql" <<'EOF'
-- id: some-other-id
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
do_run "$R_IDMISMATCH" "$FAKE_EMPTY"
assert_rc "id!=filename: exits 3" 3 "$RC"
assert_contains "id!=filename: names the mismatch" "$OUT" "does not match filename basename 'actual-name'"

# ══════════════════════════════════════════════════════════════════════════
# Parser: multi-statement file (semicolon followed by non-whitespace) ->
# parse error, exit 3.
# ══════════════════════════════════════════════════════════════════════════
R_MULTI="$TMP/multi-statement"
new_repo "$R_MULTI"
write_invariant "$R_MULTI" "multi.sql" <<'EOF'
-- id: multi
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1; SELECT 2
EOF
do_run "$R_MULTI" "$FAKE_EMPTY"
assert_rc "multi-statement: exits 3" 3 "$RC"
assert_contains "multi-statement: names the violation" "$OUT" "multi-statement file"

# A trailing semicolon with nothing but whitespace after it is legal (single
# statement, not multi-statement) -- proves the check isn't "any semicolon
# at all is banned."
R_TRAILING_SEMI="$TMP/trailing-semi"
new_repo "$R_TRAILING_SEMI"
write_invariant "$R_TRAILING_SEMI" "trailing.sql" <<'EOF'
-- id: trailing
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1;
EOF
FAKE_TRAILING="$TMP/fake-trailing.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "trailing": {"rows": []}}' > "$FAKE_TRAILING"
do_run "$R_TRAILING_SEMI" "$FAKE_TRAILING"
assert_rc "trailing semicolon (single statement): run exits 0" 0 "$RC"

# ══════════════════════════════════════════════════════════════════════════
# Parser: bad severity -> parse error, exit 3.
# ══════════════════════════════════════════════════════════════════════════
R_BADSEV="$TMP/bad-severity"
new_repo "$R_BADSEV"
write_invariant "$R_BADSEV" "badsev.sql" <<'EOF'
-- id: badsev
-- statement: test
-- severity: urgent
-- expect: zero-rows
SELECT 1
EOF
do_run "$R_BADSEV" "$FAKE_EMPTY"
assert_rc "bad severity: exits 3" 3 "$RC"
assert_contains "bad severity: names the violation" "$OUT" "severity must be 'critical' or 'warn'"

# ══════════════════════════════════════════════════════════════════════════
# Parser: bad expect grammar -> parse error, exit 3.
# ══════════════════════════════════════════════════════════════════════════
R_BADEXPECT="$TMP/bad-expect"
new_repo "$R_BADEXPECT"
write_invariant "$R_BADEXPECT" "badexpect.sql" <<'EOF'
-- id: badexpect
-- statement: test
-- severity: warn
-- expect: nonzero-rows
SELECT 1
EOF
do_run "$R_BADEXPECT" "$FAKE_EMPTY"
assert_rc "bad expect: exits 3" 3 "$RC"
assert_contains "bad expect: names the violation" "$OUT" "expect must be 'zero-rows' or 'scalar-equals:<v>'"

# ══════════════════════════════════════════════════════════════════════════
# Non-vacuity: zero invariant files -> exit 1.
# ══════════════════════════════════════════════════════════════════════════
R_EMPTY="$TMP/no-files"
new_repo "$R_EMPTY"
do_run "$R_EMPTY" "$FAKE_EMPTY"
assert_rc "zero files: exits 1 (vacuous)" 1 "$RC"
assert_contains "zero files: names vacuous" "$OUT" "vacuous"

# Non-vacuity: --only matches nothing -> exit 1.
do_run "$R_VALID" "$FAKE_VALID" --only "no-such-id"
assert_rc "--only matching nothing: exits 1 (vacuous)" 1 "$RC"
assert_contains "--only matching nothing: names vacuous" "$OUT" "vacuous"

# ══════════════════════════════════════════════════════════════════════════
# Write-probe: CREATE TEMP TABLE + INSERT both succeed -> refuse, exit 4,
# names the role, no ledger written.
# ══════════════════════════════════════════════════════════════════════════
R_PROBE="$TMP/probe-refusal"
new_repo "$R_PROBE"
write_invariant "$R_PROBE" "guarded.sql" <<'EOF'
-- id: guarded
-- statement: test
-- severity: critical
-- expect: zero-rows
SELECT 1
EOF
FAKE_PROBE_FAIL="$TMP/fake-probe-fail.json"
jq -n '{"__probe__": {"createOk": true, "insertOk": true, "role": "not_actually_readonly"}, "guarded": {"rows": []}}' > "$FAKE_PROBE_FAIL"
do_run "$R_PROBE" "$FAKE_PROBE_FAIL"
assert_rc "write-probe succeeds -> refuse, exit 4" 4 "$RC"
assert_contains "write-probe refusal names the role" "$OUT" "not_actually_readonly"
[[ ! -f "$(ledger_file "$R_PROBE" "guarded")" ]] && pass "write-probe refusal: no ledger file written" \
  || fail "write-probe refusal: a ledger file was written despite the refusal"

# Write-probe: CREATE succeeds but INSERT fails -> safe, proceeds normally.
FAKE_PROBE_HALF="$TMP/fake-probe-half.json"
jq -n '{"__probe__": {"createOk": true, "insertOk": false}, "guarded": {"rows": []}}' > "$FAKE_PROBE_HALF"
do_run "$R_PROBE" "$FAKE_PROBE_HALF"
assert_rc "write-probe: create-only (not both) -> proceeds, exit 0" 0 "$RC"
[[ -f "$(ledger_file "$R_PROBE" "guarded")" ]] && pass "write-probe: create-only -> ledger file written" \
  || fail "write-probe: create-only -> no ledger file written"

# ══════════════════════════════════════════════════════════════════════════
# Verdict logic: zero-rows expect -- 0 rows -> PASS, >=1 row -> FAIL.
# ══════════════════════════════════════════════════════════════════════════
R_ZR="$TMP/zero-rows-logic"
new_repo "$R_ZR"
write_invariant "$R_ZR" "zr.sql" <<'EOF'
-- id: zr
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
FAKE_ZR_PASS="$TMP/fake-zr-pass.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "zr": {"rows": []}}' > "$FAKE_ZR_PASS"
do_run "$R_ZR" "$FAKE_ZR_PASS"
V_ZR_PASS="$(jq -r '.verdict' "$(ledger_file "$R_ZR" "zr")" | tail -n1)"
assert_eq "zero-rows: empty result -> PASS" "PASS" "$V_ZR_PASS"

FAKE_ZR_FAIL="$TMP/fake-zr-fail.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "zr": {"rows": [{"x": 1}]}}' > "$FAKE_ZR_FAIL"
do_run "$R_ZR" "$FAKE_ZR_FAIL"
V_ZR_FAIL="$(jq -r '.verdict' "$(ledger_file "$R_ZR" "zr")" | tail -n1)"
assert_eq "zero-rows: >=1 row -> FAIL" "FAIL" "$V_ZR_FAIL"

# ══════════════════════════════════════════════════════════════════════════
# Verdict logic: scalar-equals expect -- matching value -> PASS, mismatch ->
# FAIL, wrong shape (not exactly one row/one column) -> 'error' (never FAIL).
# ══════════════════════════════════════════════════════════════════════════
R_SE="$TMP/scalar-equals-logic"
new_repo "$R_SE"
write_invariant "$R_SE" "se.sql" <<'EOF'
-- id: se
-- statement: test
-- severity: critical
-- expect: scalar-equals:0
SELECT 1
EOF
FAKE_SE_PASS="$TMP/fake-se-pass.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"rows": [{"diff": 0}]}}' > "$FAKE_SE_PASS"
do_run "$R_SE" "$FAKE_SE_PASS"
V_SE_PASS="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "scalar-equals: matching value -> PASS" "PASS" "$V_SE_PASS"

FAKE_SE_FAIL="$TMP/fake-se-fail.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"rows": [{"diff": 7}]}}' > "$FAKE_SE_FAIL"
do_run "$R_SE" "$FAKE_SE_FAIL"
V_SE_FAIL="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "scalar-equals: mismatched value -> FAIL" "FAIL" "$V_SE_FAIL"

FAKE_SE_SHAPE="$TMP/fake-se-shape.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"rows": [{"diff": 0}, {"diff": 1}]}}' > "$FAKE_SE_SHAPE"
do_run "$R_SE" "$FAKE_SE_SHAPE"
V_SE_SHAPE="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "scalar-equals: two rows (shape violation) -> error, never FAIL" "error" "$V_SE_SHAPE"

FAKE_SE_2COL="$TMP/fake-se-2col.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"rows": [{"diff": 0, "extra": 1}]}}' > "$FAKE_SE_2COL"
do_run "$R_SE" "$FAKE_SE_2COL"
V_SE_2COL="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "scalar-equals: two columns (shape violation) -> error, never FAIL" "error" "$V_SE_2COL"

# Numeric normalization: "0" (string) vs 0 (number) still compares equal.
FAKE_SE_STR="$TMP/fake-se-str.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"rows": [{"diff": "0"}]}}' > "$FAKE_SE_STR"
do_run "$R_SE" "$FAKE_SE_STR"
V_SE_STR="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "scalar-equals: numeric-normalized string '0' matches expect:0 -> PASS" "PASS" "$V_SE_STR"

# Harness error (query itself threw) -> 'error', never FAIL.
FAKE_SE_ERR="$TMP/fake-se-err.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "se": {"error": "relation does not exist"}}' > "$FAKE_SE_ERR"
do_run "$R_SE" "$FAKE_SE_ERR"
assert_rc "harness error: run still exits 0 (the fault is per-invariant, recorded)" 0 "$RC"
V_SE_ERR="$(jq -r '.verdict' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_eq "harness error: verdict is 'error', never FAIL" "error" "$V_SE_ERR"
ERR_MSG="$(jq -r '.observation.error' "$(ledger_file "$R_SE" "se")" | tail -n1)"
assert_contains "harness error: the underlying message is recorded in observation.error" "$ERR_MSG" "relation does not exist"

# ══════════════════════════════════════════════════════════════════════════
# Ledger row shape: verdict rows carry observation/freshness/scoredBy, and
# NO pin/ratify fields (architect N3 -- those are meaningless without
# value-check's ratify flow).
# ══════════════════════════════════════════════════════════════════════════
LEDGER_LINE="$(jq -c '.' "$(ledger_file "$R_ZR" "zr")" | tail -n1)"
assert_eq "ledger row: type is 'verdict'" "verdict" "$(jq -r '.type' <<<"$LEDGER_LINE")"
assert_contains "ledger row: carries observation" "$LEDGER_LINE" "\"observation\""
assert_contains "ledger row: carries freshness" "$LEDGER_LINE" "\"freshness\""
assert_eq "ledger row: scoredBy is 'deterministic'" "deterministic" "$(jq -r '.scoredBy' <<<"$LEDGER_LINE")"
PIN_KEYS="$(jq -r 'keys[] | select(. == "pin" or . == "ratifiedBy" or . == "ratifiedAt" or . == "review")' <<<"$LEDGER_LINE")"
[[ -z "$PIN_KEYS" ]] && pass "ledger row: no pin/ratification fields present" \
  || fail "ledger row: unexpectedly found pin/ratify field(s): $PIN_KEYS"

# ══════════════════════════════════════════════════════════════════════════
# report --json: counts (pass/failCritical/failWarn/error/neverRun) and
# heartbeat (emptyLedger/staleRun).
# ══════════════════════════════════════════════════════════════════════════
R_REPORT="$TMP/report"
new_repo "$R_REPORT"
write_invariant "$R_REPORT" "crit-pass.sql" <<'EOF'
-- id: crit-pass
-- statement: test
-- severity: critical
-- expect: zero-rows
SELECT 1
EOF
write_invariant "$R_REPORT" "crit-fail.sql" <<'EOF'
-- id: crit-fail
-- statement: test
-- severity: critical
-- expect: zero-rows
SELECT 1
EOF
write_invariant "$R_REPORT" "warn-fail.sql" <<'EOF'
-- id: warn-fail
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
write_invariant "$R_REPORT" "never-run.sql" <<'EOF'
-- id: never-run
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
FAKE_REPORT="$TMP/fake-report.json"
jq -n '{
  "__probe__": {"createOk": false, "insertOk": false},
  "crit-pass": {"rows": []},
  "crit-fail": {"rows": [{"x": 1}]},
  "warn-fail": {"rows": [{"x": 1}]}
}' > "$FAKE_REPORT"
do_run "$R_REPORT" "$FAKE_REPORT" --only crit-pass
assert_rc "report fixture: crit-pass run exits 0" 0 "$RC"
do_run "$R_REPORT" "$FAKE_REPORT" --only crit-fail
assert_rc "report fixture: crit-fail run exits 0" 0 "$RC"
do_run "$R_REPORT" "$FAKE_REPORT" --only warn-fail
assert_rc "report fixture: warn-fail run exits 0" 0 "$RC"
# never-run.sql is deliberately never executed -- exercises neverRun/emptyLedger-per-id.

do_report_json "$R_REPORT"
assert_rc "report --json exits 0" 0 "$RC"
assert_eq "report: counts.pass" "1" "$(jq -r '.counts.pass' <<<"$OUT")"
assert_eq "report: counts.failCritical" "1" "$(jq -r '.counts.failCritical' <<<"$OUT")"
assert_eq "report: counts.failWarn" "1" "$(jq -r '.counts.failWarn' <<<"$OUT")"
assert_eq "report: counts.neverRun" "1" "$(jq -r '.counts.neverRun' <<<"$OUT")"
assert_eq "report: heartbeat.emptyLedger is false (some ids have run)" "false" "$(jq -r '.heartbeat.emptyLedger' <<<"$OUT")"
assert_eq "report: heartbeat.staleRun is false (recent run)" "false" "$(jq -r '.heartbeat.staleRun' <<<"$OUT")"

# report --json: emptyLedger true when no invariant has ever run.
R_NEVERRUN="$TMP/never-run-repo"
new_repo "$R_NEVERRUN"
write_invariant "$R_NEVERRUN" "solo.sql" <<'EOF'
-- id: solo
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
do_report_json "$R_NEVERRUN"
assert_eq "report: emptyLedger true when no ledger exists at all" "true" "$(jq -r '.heartbeat.emptyLedger' <<<"$OUT")"

# report --json: staleRun true when the only run is outside the 35-day
# heartbeat window (same convention as tests/test-value-check.sh's ET17c).
R_STALE="$TMP/stale-run"
new_repo "$R_STALE"
write_invariant "$R_STALE" "stale.sql" <<'EOF'
-- id: stale
-- statement: test
-- severity: warn
-- expect: zero-rows
SELECT 1
EOF
FAKE_STALE="$TMP/fake-stale.json"
jq -n '{"__probe__": {"createOk": false, "insertOk": false}, "stale": {"rows": []}}' > "$FAKE_STALE"
do_run "$R_STALE" "$FAKE_STALE"
assert_rc "stale-run fixture: run exits 0" 0 "$RC"
OLD_TS="$(date -u -v-50d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-50 days' +%Y-%m-%dT%H:%M:%SZ)"
LF_STALE="$(ledger_file "$R_STALE" "stale")"
TMP_LF="$(mktemp)"
jq -c --arg ts "$OLD_TS" '.runAt = $ts' "$LF_STALE" > "$TMP_LF" && mv "$TMP_LF" "$LF_STALE"
do_report_json "$R_STALE"
assert_eq "report: staleRun true when the only run is outside the heartbeat window" "true" "$(jq -r '.heartbeat.staleRun' <<<"$OUT")"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "invariants: $PASS passed, $FAIL failed"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
