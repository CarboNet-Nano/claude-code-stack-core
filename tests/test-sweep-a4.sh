#!/usr/bin/env bash
# Tests for scripts/sweep/checks/a4-column-writes.sh (stack ADR-078, Sweep
# family A4). A4 asks whether every column of every configured table is
# either written somewhere on the declared write-path, or covered by a
# reasoned write_never entry — audit row #11: two columns existed since
# launch, never populated, 0 of 6 events resolved in 7.5 weeks.
#
# The column universe is parsed statically from migration files (CREATE
# TABLE / ALTER TABLE ADD COLUMN), not introspected from a live Postgres —
# the check header documents why (spec S4.6 A4's degraded, hermetic-test
# path). Fixtures below are plain directories (no git dependency: A4's
# evidence uses `locus`, the migration file that introduced the column,
# never `commit`).
#
# Most cases invoke the check directly (task 4's stdin/stdout contract),
# mirroring tests/test-sweep-b4.sh's structure. The two end-to-end cases at
# the bottom go through the REAL runner (sweep-run.sh), because an exit
# code is the thing they assert and the check alone has none.
#
# Every emitted finding is also round-tripped through the real
# sweep-emit.sh (sourced, not shelled out to) to prove it survives R1-R7.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/a4-column-writes.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a4-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_fixture <name> -> a fresh throwaway directory under $TMP, echoes its
# absolute path. Plain filesystem, no git — A4 has no commit dependency.
new_fixture() {
  local d="$TMP/repo-$1"
  mkdir -p "$d/supabase/migrations" "$d/packages/api/src/lib"
  echo "$d"
}

# write_migration <repo> <name> <sql> -> writes one migration file.
write_migration() {
  printf '%s\n' "$3" > "$1/supabase/migrations/$2.sql"
}

# write_source <repo> <name> <content> -> writes one write-path file.
write_source() {
  printf '%s\n' "$3" > "$1/packages/api/src/lib/$2.ts"
}

# build_job <repo> <tables-json> <globs-json> <write-never-json> [migrations-glob]
build_job() {
  local mig="${5:-supabase/migrations/*.sql}"
  jq -cn --arg repo "$1" --argjson tables "$2" --argjson globs "$3" --argjson wn "$4" --arg mig "$mig" \
    '{schema:"sweep-job/v1", run_id:"2026-08-15T00:00:00Z.test01", check_id:"A4",
      repo_root:$repo, cadence:"manual", writes_findings:false,
      evidence_basis:"static-source", surface:"schema",
      config:{tables:$tables, write_path_globs:$globs, write_never:$wn, migrations_glob:$mig},
      changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <job> -> sets ENV_OUT (decoded envelope) and RAW_OUT (full
# stdout+stderr) / RAW_EC (exit code).
run_check() {
  local job="$1" line
  RAW_OUT="$(printf '%s' "$job" | bash "$CHECK" 2>&1)"; RAW_EC=$?
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$RAW_OUT" | tail -1)"
  ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
}

ORDERS_TABLE='["forecast_orders"]'
ORDERS_GLOBS='["packages/api/src/lib/**"]'

# ---- t_never_written: a migrated column with no write-path occurrence ----

t_never_written_column_is_a_finding() {
  local r; r="$(new_fixture never-written)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_source "$r" "write" \
    'export const w = (row) => ({ id: row.id, status: row.status });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local status universe executed findings_n ident locus
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  executed="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  locus="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"

  [[ "$status" == "fail" && "$universe" == "3" && "$executed" == "3" && "$findings_n" == "1" \
     && "$ident" == "forecast_orders.legacy_note" && "$locus" == "supabase/migrations/0001_init.sql" ]] \
    && pass "a migrated column never occurring in a write-path file, and not declared write_never, is a finding" \
    || fail "never-written column (status=$status universe=$universe executed=$executed findings=$findings_n ident=$ident locus=$locus)"
}

t_never_written_finding_shape() {
  local r; r="$(new_fixture never-written-shape)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local f mech surface src found plain has_status
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  mech="$(jq -r '.mechanism' <<<"$f")"
  surface="$(jq -r '.surface' <<<"$f")"
  src="$(jq -r '.surface_source' <<<"$f")"
  found="$(jq -r '.found_by' <<<"$f")"
  plain="$(jq -r '.plain' <<<"$f")"
  has_status="$(jq -r 'has("status")' <<<"$f")"

  [[ "$mech" == "DISCONNECTED" && "$surface" == "schema" && "$src" == "declared" \
     && "$found" == "sweep-family-A" && -n "$plain" && "$has_status" == "false" ]] \
    && pass "never-written finding shape (DISCONNECTED / schema / sweep-family-A / no status)" \
    || fail "never-written finding shape (mech=$mech surface=$surface src=$src found=$found status?=$has_status)"
}

t_never_written_finding_survives_emit() {
  local r; r="$(new_fixture never-written-emit)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local f fid ident stamped findings_out
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  fid="$(sweep_finding_id repo A4 "DISCONNECTED" "supabase/migrations/0001_init.sql" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    [[ "$(wc -l < "$findings_out" | tr -d ' ')" == "1" ]] \
      && pass "never-written finding survives sweep_emit_finding (schema-valid, R1-R7)" \
      || fail "never-written finding survives sweep_emit_finding (wrote $(wc -l < "$findings_out") lines)"
  else
    fail "never-written finding survives sweep_emit_finding (refused: $(cat "$TMP/emit.err"))"
  fi
}

# ---- t_written_column: a column referenced in the write-path -> none ----

t_written_column_is_not_a_finding() {
  local r; r="$(new_fixture written)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local status findings_n executed passed
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  executed="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"

  [[ "$status" == "pass" && "$findings_n" == "0" && "$executed" == "2" && "$passed" == "2" ]] \
    && pass "every migrated column occurs in a write-path file: pass, 0 findings" \
    || fail "written columns (status=$status findings=$findings_n executed=$executed passed=$passed)"
}

# ---- t_write_never_with_reason: declared, reasoned -> excluded, no finding ----

t_write_never_with_reason_is_not_a_finding() {
  local r wn; r="$(new_fixture write-never-reasoned)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  wn='[{"unit":"forecast_orders.legacy_note","reason":"read-only import artifact, ADR-041"}]'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" "$wn")"

  local status findings_n excluded_n excluded_reason
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  excluded_n="$(jq -r '.excluded | length' <<<"$ENV_OUT")"
  excluded_reason="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"

  [[ "$status" == "pass" && "$findings_n" == "0" && "$excluded_n" == "1" \
     && "$excluded_reason" == "read-only import artifact, ADR-041" ]] \
    && pass "a write_never entry with a non-empty reason excludes its column: pass, 0 findings, 1 excluded" \
    || fail "write_never with reason (status=$status findings=$findings_n excluded=$excluded_n reason=$excluded_reason)"
}

# ---- t_write_never_blank_reason: fail-closed, no result line at all ----

t_write_never_blank_reason_fails_closed() {
  local r wn; r="$(new_fixture write-never-blank)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  wn='[{"unit":"forecast_orders.legacy_note","reason":"   "}]'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" "$wn")"

  [[ "$RAW_EC" -ne 0 && -z "$ENV_OUT" ]] \
    && pass "a write_never entry with a blank reason fails closed: nonzero exit, no result envelope at all" \
    || fail "write_never blank reason fail-closed (ec=$RAW_EC env_out=$ENV_OUT out=$RAW_OUT)"
}

t_write_never_absent_reason_key_fails_closed() {
  local r wn; r="$(new_fixture write-never-no-reason-key)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  wn='[{"unit":"forecast_orders.legacy_note"}]'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" "$wn")"

  [[ "$RAW_EC" -ne 0 && -z "$ENV_OUT" ]] \
    && pass "a write_never entry with no reason key at all also fails closed" \
    || fail "write_never absent reason key fail-closed (ec=$RAW_EC env_out=$ENV_OUT)"
}

# ---- identity_key stability across reruns (the load-bearing property) ----

t_identity_key_stable_across_reruns() {
  local r; r="$(new_fixture stable-id)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, legacy_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  local job; job="$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  run_check "$job"
  local ident1 locus1 fid1
  ident1="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  locus1="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"
  fid1="$(sweep_finding_id repo A4 "DISCONNECTED" "$locus1" "$ident1")"

  run_check "$job"
  local ident2 locus2 fid2
  ident2="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  locus2="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"
  fid2="$(sweep_finding_id repo A4 "DISCONNECTED" "$locus2" "$ident2")"

  [[ -n "$ident1" && "$ident1" == "$ident2" && "$locus1" == "$locus2" && "$fid1" == "$fid2" ]] \
    && pass "identity_key/finding_id: re-running the same job reproduces the SAME identity_key and finding_id" \
    || fail "identity_key stability across reruns (ident1=$ident1 ident2=$ident2 fid1=$fid1 fid2=$fid2)"
}

t_identity_keys_distinct_per_column() {
  local r; r="$(new_fixture distinct-ids)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, legacy_note text, ghost_flag boolean);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local idents; idents="$(jq -r '[.findings[].identity_key] | unique | length' <<<"$ENV_OUT")"
  local n; n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$n" == "2" && "$idents" == "2" ]] \
    && pass "two different unwritten columns in one run produce two DISTINCT identity_keys" \
    || fail "identity_key distinctness (n=$n unique=$idents)"
}

# ---- R1 defense: a digit-run table name must not collide with a timestamp ----

t_identity_key_groups_digit_runs_for_r1() {
  local r; r="$(new_fixture digit-run-table)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE events_2024 (id integer, gap_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" '["events_2024"]' "$ORDERS_GLOBS" '[]')"

  local ident; ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  [[ "$ident" == "events_202-4.gap_note" ]] \
    && pass "a table name with a 4+ digit run (events_2024) is grouped into runs of 3 so identity_key never trips R1" \
    || fail "digit-run grouping (ident=$ident, want events_202-4.gap_note)"

  local findings_out
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  local fid stamped
  fid="$(sweep_finding_id repo A4 "DISCONNECTED" "supabase/migrations/0001_init.sql" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' \
    <<<"$(jq -c '.findings[0]' <<<"$ENV_OUT")")"
  sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err" \
    && pass "the grouped identity_key survives sweep_emit_finding's R1 refusal" \
    || fail "grouped identity_key survives R1 (refused: $(cat "$TMP/emit.err"))"
}

# ---- ALTER TABLE ADD COLUMN is parsed, same as CREATE TABLE ----

t_alter_table_add_column_is_in_the_universe() {
  local r; r="$(new_fixture alter-add-column)"
  write_migration "$r" "0001_init" 'CREATE TABLE forecast_orders (id integer);'
  write_migration "$r" "0002_add_priority" \
    'ALTER TABLE forecast_orders ADD COLUMN priority integer;'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local universe ident locus
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  locus="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"
  [[ "$universe" == "2" && "$ident" == "forecast_orders.priority" \
     && "$locus" == "supabase/migrations/0002_add_priority.sql" ]] \
    && pass "ALTER TABLE ... ADD COLUMN is parsed into the universe, locus points at the migration that added it" \
    || fail "ALTER TABLE ADD COLUMN parsing (universe=$universe ident=$ident locus=$locus)"
}

# ---- multiple tables, migrations_glob override ----

t_multiple_tables_are_all_checked() {
  local r; r="$(new_fixture multi-table)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, gap_note text);
CREATE TABLE forecast_miss_events (id integer, resolved boolean);'
  write_source "$r" "write" \
    'export const w = (row) => ({ id: row.id, resolved: row.resolved });'
  run_check "$(build_job "$r" '["forecast_orders","forecast_miss_events"]' "$ORDERS_GLOBS" '[]')"

  local universe findings_n unit
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  unit="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  [[ "$universe" == "4" && "$findings_n" == "1" && "$unit" == "forecast_orders.gap_note" ]] \
    && pass "two configured tables: universe sums both, the unwritten column in either is found" \
    || fail "multiple tables (universe=$universe findings=$findings_n unit=$unit)"
}

t_migrations_glob_override_is_honored() {
  local r; r="$(new_fixture custom-glob)"
  mkdir -p "$r/db/schema"
  printf '%s\n' 'CREATE TABLE forecast_orders (id integer, gap_note text);' > "$r/db/schema/001.sql"
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]' "db/schema/*.sql")"

  local universe locus
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  locus="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"
  [[ "$universe" == "2" && "$locus" == "db/schema/001.sql" ]] \
    && pass "config.migrations_glob overrides the default supabase/migrations/*.sql path" \
    || fail "migrations_glob override (universe=$universe locus=$locus)"
}

t_default_migrations_glob_when_unconfigured() {
  local r job; r="$(new_fixture default-glob)"
  write_migration "$r" "0001_init" 'CREATE TABLE forecast_orders (id integer, gap_note text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  job="$(jq -cn --arg repo "$r" \
    '{schema:"sweep-job/v1", run_id:"r", check_id:"A4", repo_root:$repo, cadence:"manual",
      writes_findings:false, evidence_basis:"static-source", surface:"schema",
      config:{tables:["forecast_orders"], write_path_globs:["packages/api/src/lib/**"], write_never:[]},
      changed_paths:null, connection:null, budget_ms:120000}')"
  run_check "$job"

  local universe; universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  [[ "$universe" == "2" ]] \
    && pass "config.migrations_glob absent: defaults to supabase/migrations/*.sql" \
    || fail "default migrations_glob (universe=$universe)"
}

# ---- envelope identity: echoes the job's evidence_basis/surface ----

t_envelope_echoes_job_identity() {
  local r; r="$(new_fixture envelope-identity)"
  write_migration "$r" "0001_init" 'CREATE TABLE forecast_orders (id integer);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local schema check_id basis surface
  schema="$(jq -r '.schema' <<<"$ENV_OUT")"
  check_id="$(jq -r '.check_id' <<<"$ENV_OUT")"
  basis="$(jq -r '.evidence_basis' <<<"$ENV_OUT")"
  surface="$(jq -r '.surface' <<<"$ENV_OUT")"

  [[ "$schema" == "sweep-result/v1" && "$check_id" == "A4" \
     && "$basis" == "static-source" && "$surface" == "schema" ]] \
    && pass "envelope echoes the job's schema/check_id/evidence_basis/surface byte-for-byte" \
    || fail "envelope echoes job identity (schema=$schema check_id=$check_id basis=$basis surface=$surface)"
}

# ---- quiet universe: no migrations for the configured table -> reported honestly ----

t_quiet_universe_reports_zero_honestly() {
  local r; r="$(new_fixture quiet-universe)"
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local universe executed findings_n
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  executed="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  # The runner's B2 invariant decides what universe_size 0 means (exit 2 —
  # see the real-runner test below). This check's job is only to report it
  # honestly, never to fabricate a nonzero universe or a finding to dodge
  # that verdict.
  [[ "$universe" == "0" && "$executed" == "0" && "$findings_n" == "0" ]] \
    && pass "no migrations found for the configured table: universe_size 0 reported honestly, no fabricated findings" \
    || fail "quiet universe (universe=$universe executed=$executed findings=$findings_n)"
}

# ---- end-to-end through the REAL runner: exit code is the runner's contract ----

RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"
CHECKS_DIR="$REPO_ROOT/scripts/sweep/checks"

# run_runner <repo> <config-json> -> sets RUN_OUT / RUN_ERR / RUN_EC.
run_runner() {
  local repo="$1" cfg="$2"
  mkdir -p "$repo/.claude/sweep"
  jq . <<<"$cfg" > "$repo/.claude/sweep.config.json"
  printf 'A4\n' > "$repo/inventory.txt"
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    bash "$RUNNER" --repo "$repo" --cadence manual --json 2>"$TMP/runner.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/runner.err")"
}

CONFIG_A4='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"A4":"schema"},
  "families":{"A4":{"tables":["forecast_orders"],"write_path_globs":["packages/api/src/lib/**"],"write_never":[]}},
  "skips":[]}'

t_runner_empty_universe_is_a_liveness_failure() {
  local r; r="$(new_fixture runner-empty-universe)"
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id });'
  run_runner "$r" "$CONFIG_A4"

  local st; st="$(jq -r '.checks[] | select(.check_id=="A4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "fail" ]] \
    && pass "through the real runner: no migrations for the configured table -> universe 0 -> exit 2 (B2 default-closed)" \
    || fail "runner empty universe -> exit 2 (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

t_runner_fully_covered_repo_exits_zero() {
  local r; r="$(new_fixture runner-covered)"
  write_migration "$r" "0001_init" 'CREATE TABLE forecast_orders (id integer, status text);'
  write_source "$r" "write" 'export const w = (row) => ({ id: row.id, status: row.status });'
  run_runner "$r" "$CONFIG_A4"

  local st findings_n; st="$(jq -r '.checks[] | select(.check_id=="A4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  findings_n="$(jq -r '.checks[] | select(.check_id=="A4") | .findings_n' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "pass" && "$findings_n" == "0" ]] \
    && pass "through the real runner: every configured column written -> exit 0, pass, 0 findings" \
    || fail "runner fully covered -> exit 0 (ec=$RUN_EC status=$st findings=$findings_n out=$RUN_OUT err=$RUN_ERR)"
}

# ---- t_function_body_write: a column written only inside a plpgsql body ----
# Queue #227: 2 of 3 production findings were columns filled by a routine
# the write-path glob scan could not see. A dollar-quoted body's UPDATE is
# a write; the column's own CREATE TABLE declaration (not dollar-quoted)
# must still NOT count as one.

t_function_body_write_is_not_a_finding() {
  local r; r="$(new_fixture fn-body-write)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, filled_by_fn text);'
  write_migration "$r" "0002_fn" \
    'CREATE OR REPLACE FUNCTION fill() RETURNS void AS $fn$
BEGIN
  UPDATE forecast_orders SET filled_by_fn = '"'"'x'"'"';
END;
$fn$ LANGUAGE plpgsql;'
  write_source "$r" "write" \
    'export const w = (row) => ({ id: row.id, status: row.status });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "pass" && "$findings_n" == "0" ]] \
    && pass "a column written only inside a dollar-quoted routine body is not a finding" \
    || fail "function-body write (status=$status findings=$findings_n raw=$RAW_OUT)"
}

t_declaration_in_ddl_is_not_a_write() {
  local r; r="$(new_fixture ddl-not-write)"
  write_migration "$r" "0001_init" \
    'CREATE TABLE forecast_orders (id integer, status text, legacy_note text);'
  write_migration "$r" "0002_fn" \
    'CREATE OR REPLACE FUNCTION touch_status() RETURNS void AS $fn$
BEGIN
  UPDATE forecast_orders SET status = '"'"'x'"'"';
END;
$fn$ LANGUAGE plpgsql;'
  write_source "$r" "write" \
    'export const w = (row) => ({ id: row.id });'
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"

  local status idents
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  idents="$(jq -r '[.findings[].identity_key] | sort | join(",")' <<<"$ENV_OUT")"
  [[ "$status" == "fail" && "$idents" == "forecast_orders.legacy_note" ]] \
    && pass "a column only DECLARED in DDL still counts unwritten while a body-written sibling passes" \
    || fail "ddl-not-write (status=$status idents=$idents)"
}

t_never_written_column_is_a_finding
t_never_written_finding_shape
t_never_written_finding_survives_emit
t_written_column_is_not_a_finding
t_write_never_with_reason_is_not_a_finding
t_write_never_blank_reason_fails_closed
t_write_never_absent_reason_key_fails_closed
t_identity_key_stable_across_reruns
t_identity_keys_distinct_per_column
t_identity_key_groups_digit_runs_for_r1
t_alter_table_add_column_is_in_the_universe
t_multiple_tables_are_all_checked
t_migrations_glob_override_is_honored
t_default_migrations_glob_when_unconfigured
t_envelope_echoes_job_identity
t_quiet_universe_reports_zero_honestly
# ---- couldn't-look ≠ found-nothing (2026-08-19 census): an unreadable
# write-path file must fail loud, never score columns as unwritten ----
t_unreadable_write_path_file_fails_loud() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "SKIP: running as root — chmod 000 cannot make a file unreadable"
    return 0
  fi
  local r; r="$(new_fixture unreadable-write-path)"
  write_migration "$r" "0001_init" \
    'create table forecast_orders (id uuid primary key, total_cents bigint);'
  write_source "$r" "orders" 'export const write = (o) => ({ total_cents: o.totalCents });'
  chmod 000 "$r/packages/api/src/lib/orders.ts"
  run_check "$(build_job "$r" "$ORDERS_TABLE" "$ORDERS_GLOBS" '[]')"
  chmod 644 "$r/packages/api/src/lib/orders.ts"
  [[ "$RAW_EC" -ne 0 && -z "$ENV_OUT" && "$RAW_OUT" == *"could not be read"* ]] \
    && pass "unreadable write-path file: loud failure, no unwritten-column findings fabricated" \
    || fail "unreadable write-path file (ec=$RAW_EC env=${ENV_OUT:0:60} out=${RAW_OUT:0:120})"
}

t_runner_empty_universe_is_a_liveness_failure
t_runner_fully_covered_repo_exits_zero
t_function_body_write_is_not_a_finding
t_declaration_in_ddl_is_not_a_write
t_unreadable_write_path_file_fails_loud

echo "----"
echo "test-sweep-a4: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
