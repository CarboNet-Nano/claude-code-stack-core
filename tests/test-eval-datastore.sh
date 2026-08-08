#!/usr/bin/env bash
# Tests for the eval datastore (ADR-059).
# Validates: the schema applies cleanly, the loader is genuinely idempotent, repetitions
# are preserved rather than collapsed, cell_stats reports spread (not just mean), and the
# schema stays Postgres-portable. Runs against a temp database — never touches
# ~/.claude/eval.db. No network, no model calls.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$REPO_ROOT/schemas/005-model-eval.sql"
LOADER="$REPO_ROOT/scripts/eval-db-load.sh"
TMP="$(mktemp -d)"
DB="$TMP/eval.db"
LOG="$TMP/log.jsonl"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
finish() { rm -rf "$TMP"; echo; echo "eval-datastore: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]] || exit 1; exit 0; }

# --- 0. prerequisites fail loudly rather than silently skipping ---------------
command -v sqlite3 >/dev/null 2>&1 || { fail "sqlite3 not available"; finish; }
[[ -f "$SCHEMA" ]] || { fail "schema missing: $SCHEMA"; finish; }
[[ -f "$LOADER" ]] || { fail "loader missing: $LOADER"; finish; }
pass "sqlite3, schema and loader are present"

# --- 1. schema applies to an empty database ----------------------------------
if sqlite3 "$DB" < "$SCHEMA" 2>/dev/null; then pass "schema applies cleanly"; else fail "schema failed to apply"; finish; fi

# --- 2. fixture log: 2 cells, one with 3 identical repetitions ----------------
# The repeated cell is the important one — collapsing repetitions would destroy the
# variance data, which is the measurement that has actually changed a routing decision.
cat > "$LOG" <<'JSONL'
{"event":"model_eval","ts":"2026-08-07T00:00:00Z","project":"/p","run_id":"r1","agent":"a1","task_id":"t1","executor_model":"m-lo","effort":"medium","harness":"agent","judge":"openai","score_correctness":6,"score_completeness":6,"score_edge":6,"tokens":100,"cache_read_tokens":0,"cache_creation_tokens":0,"wall_ms":10}
{"event":"model_eval","ts":"2026-08-07T00:00:01Z","project":"/p","run_id":"r1","agent":"a1","task_id":"t1","executor_model":"m-lo","effort":"medium","harness":"agent","judge":"openai","score_correctness":9,"score_completeness":9,"score_edge":9,"tokens":100,"cache_read_tokens":0,"cache_creation_tokens":0,"wall_ms":10}
{"event":"model_eval","ts":"2026-08-07T00:00:02Z","project":"/p","run_id":"r1","agent":"a1","task_id":"t1","executor_model":"m-lo","effort":"medium","harness":"agent","judge":"openai","score_correctness":6,"score_completeness":6,"score_edge":6,"tokens":100,"cache_read_tokens":0,"cache_creation_tokens":0,"wall_ms":10}
{"event":"model_eval","ts":"2026-08-07T00:00:03Z","project":"/p","run_id":"r1","agent":"a1","task_id":"t1","executor_model":"m-hi","effort":"high","harness":"agent","judge":"openai","score_correctness":9,"score_completeness":9,"score_edge":9,"tokens":200,"cache_read_tokens":0,"cache_creation_tokens":0,"wall_ms":20}
{"event":"dispatch","ts":"2026-08-07T00:00:04Z","agent":"a1"}
JSONL

bash "$LOADER" --db "$DB" --log "$LOG" >/dev/null 2>&1
N="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM model_eval;')"
[[ "$N" == "4" ]] && pass "loads only model_eval rows (4, ignoring the dispatch row)" \
                  || fail "expected 4 rows, got $N (non-eval rows may be leaking in)"

# --- 3. repetitions are preserved, not collapsed -----------------------------
REPS="$(sqlite3 "$DB" "SELECT COUNT(*) FROM model_eval WHERE executor_model='m-lo';")"
[[ "$REPS" == "3" ]] && pass "3 identical repetitions preserved as 3 rows" \
                     || fail "repetitions collapsed: expected 3, got $REPS — variance data would be lost"
MAXREP="$(sqlite3 "$DB" "SELECT MAX(rep) FROM model_eval WHERE executor_model='m-lo';")"
[[ "$MAXREP" == "3" ]] && pass "rep index increments within a cell" || fail "rep index wrong: max=$MAXREP"

# --- 4. idempotency — the property that makes drop-and-reload safe ------------
bash "$LOADER" --db "$DB" --log "$LOG" >/dev/null 2>&1
N2="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM model_eval;')"
[[ "$N2" == "4" ]] && pass "second load inserts nothing (idempotent)" \
                   || fail "second load changed row count: $N -> $N2"

# negative control: the idempotency assertion must be capable of failing. Insert a
# deliberate duplicate under a different rep and confirm the count moves — proving the
# check above is not vacuously true.
sqlite3 "$DB" "INSERT INTO model_eval (ts,agent,task_id,executor_model,run_id,advisor_model,effort,rep) VALUES ('x','a1','t1','m-lo','r1','','medium',99);" 2>/dev/null
N3="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM model_eval;')"
[[ "$N3" == "5" ]] && pass "negative control: row count does move when a real duplicate is added" \
                   || fail "negative control failed — the idempotency test may be vacuous"
sqlite3 "$DB" "DELETE FROM model_eval WHERE rep=99;"

# --- 5. cell_stats exposes SPREAD, not just mean -----------------------------
# The 2026-08-07 architect decision turned on spread and worst-case, not mean. A rollup
# that reported only the mean would have produced the wrong answer.
SPREAD="$(sqlite3 "$DB" "SELECT spread FROM cell_stats WHERE executor_model='m-lo';")"
[[ "$SPREAD" == "3.0" ]] && pass "cell_stats computes spread correctly (6,9,6 -> 3.0)" \
                         || fail "spread wrong: expected 3.0, got $SPREAD"
WORST="$(sqlite3 "$DB" "SELECT worst FROM cell_stats WHERE executor_model='m-lo';")"
[[ "$WORST" == "6.0" ]] && pass "cell_stats computes worst-case correctly" || fail "worst wrong: got $WORST"
for col in mean worst best spread n; do
  sqlite3 "$DB" "SELECT $col FROM cell_stats LIMIT 1;" >/dev/null 2>&1 \
    && pass "cell_stats exposes '$col'" || fail "cell_stats missing column '$col'"
done

# --- 6. deterministic rows (no scores) coexist with scored rows --------------
echo '{"event":"model_eval","ts":"2026-08-07T00:00:05Z","run_id":"r2","agent":"a1","task_id":"t1","executor_model":"m-lo","effort":"medium","judge":"deterministic-code-inspection","check":"race_free","passed":false,"tokens":50}' >> "$LOG"
bash "$LOADER" --db "$DB" --log "$LOG" >/dev/null 2>&1
DET="$(sqlite3 "$DB" "SELECT COUNT(*) FROM model_eval WHERE check_name='race_free' AND passed=0;")"
[[ "$DET" == "1" ]] && pass "deterministic check rows load with passed=0 and no scores" \
                    || fail "deterministic row not loaded correctly (got $DET)"
# and they must not pollute the scored rollup
INSTATS="$(sqlite3 "$DB" "SELECT COALESCE(SUM(n),0) FROM cell_stats;")"
[[ "$INSTATS" == "4" ]] && pass "cell_stats excludes unscored rows" \
                        || fail "cell_stats includes unscored rows (n total = $INSTATS, expected 4)"

# --- 7. schema stays Postgres-portable ---------------------------------------
# ADR-059 commits to `.dump` loading into Postgres with only the header changed. These
# are the SQLite-isms that would break that promise.
if grep -qiE 'AUTOINCREMENT|WITHOUT ROWID|\bSTRICT\b|json_extract|sqlite_' "$SCHEMA"; then
  fail "schema uses SQLite-only constructs — breaks the documented Postgres migration path"
else
  pass "schema avoids SQLite-only constructs (stays Postgres-portable)"
fi
if grep -qE 'DATETIME|TIMESTAMP[^Z]' "$SCHEMA"; then
  fail "schema uses engine-specific date types — ADR-059 requires ISO-8601 TEXT"
else
  pass "timestamps stored as portable ISO-8601 TEXT"
fi

# --- 8. every UNIQUE key column is NOT NULL ----------------------------------
# Both engines treat NULLs in a UNIQUE index as distinct, so a nullable key column
# would silently let duplicates through and break idempotency on every re-run.
NULLABLE_KEY=0
for col in run_id agent task_id executor_model advisor_model effort rep; do
  grep -qE "^[[:space:]]*$col[[:space:]]+[A-Z]+[^,]*NOT NULL" "$SCHEMA" || { NULLABLE_KEY=1; echo "  note: '$col' is not NOT NULL"; }
done
[[ $NULLABLE_KEY -eq 0 ]] && pass "all UNIQUE-key columns are NOT NULL (idempotency holds)" \
                          || fail "a UNIQUE-key column is nullable — duplicates would slip through"

# --- 9. loader is safe when the log is missing -------------------------------
bash "$LOADER" --db "$TMP/other.db" --log "$TMP/nope.jsonl" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "missing log exits 0 (nothing measured yet is not an error)" \
               || fail "missing log returned non-zero"

finish
