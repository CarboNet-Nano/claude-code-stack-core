#!/usr/bin/env bash
# tests/test-sweep-a2.sh — Tests for scripts/sweep/checks/a2-producer-consumer.sh
# (stack ADR-078, spec S4.6 A2). A2 is "the highest-value single check in
# the table" (spec's own words): the same mechanism shipped twice, months
# apart, one instance worth $161,700 on a single specimen (counted, audit
# rows #5, #23) — a producer writes a value under one key name, a
# consumer reads it under another, and the feature silently no-ops.
#
# Every case invokes the check directly (not through sweep-run.sh — that
# is tests/test-sweep-runner.sh's job) against a real, throwaway git repo
# with real producer/consumer fixture files, exactly the mkfakegh-free
# shape tests/test-sweep-b4.sh and tests/test-sweep-e1.sh use for their
# direct-invocation cases. Two cases at the bottom go through the REAL
# runner (scripts/sweep/sweep-run.sh), because "fail-closed, never a
# silent pass" is an exit-code claim the check alone cannot prove.
#
# Every emitted finding is also round-tripped through the real
# sweep-emit.sh (sourced, not shelled out to), the same proof-of-survival
# pattern b4/e1 use for their identity_key claims.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/a2-producer-consumer.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
[ -f "$EMIT_LIB" ] || { echo "FATAL: $EMIT_LIB not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available — a2-producer-consumer.sh's lexical extraction is a node script"; echo "test-sweep-a2: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a2-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_repo <name> -> a real throwaway git repo with one commit, so
# `git -C <repo> rev-parse HEAD` (the check's evidence.commit source)
# succeeds. Mirrors tests/test-sweep-b4.sh's new_repo helper.
new_repo() {
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" ) >/dev/null
  git -C "$r" rev-parse --show-toplevel
}

# writefile <path> <heredoc content via stdin>
writefile() { mkdir -p "$(dirname "$1")" && cat > "$1"; }

# build_job <repo_root> <producers-json-array> <consumer_globs-json-array> [exclusions-json-array]
build_job() {
  jq -cn --arg repo "$1" --argjson producers "$2" --argjson globs "$3" --argjson excl "${4:-[]}" '
    {schema:"sweep-job/v1", run_id:"2026-08-15T00:00:00Z.test01", check_id:"A2",
     repo_root:$repo, cadence:"push-main", writes_findings:true,
     evidence_basis:"static-source", surface:"read-path",
     config:{producers:$producers, consumer_globs:$globs, exclusions:$excl},
     changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <job-json> -> sets ENV_OUT (decoded envelope) and RUN_EC.
run_check() {
  local job="$1" out line
  out="$(printf '%s' "$job" | bash "$CHECK" 2>"$TMP/a2.stderr")"
  RUN_EC=$?
  RUN_STDERR="$(cat "$TMP/a2.stderr" 2>/dev/null)"
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
}

# ---- t_orphan_both_directions: the audit rows #5/#23 catch-proof ----
# producer writes `products`, consumer reads singular `product`, both
# also share `category` — two orphan findings (one per direction), the
# matched key produces no finding.

t_orphan_both_directions() {
  local r; r="$(new_repo orphan-both)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products, category: state.category };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  const product = req.nextUrl.searchParams.get('product');
  const category = req.nextUrl.searchParams.get('category');
  return { product, category };
}
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local status universe assertions passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  local has_products has_product
  has_products="$(jq -r '[.findings[].identity_key] | index("products") != null' <<<"$ENV_OUT")"
  has_product="$(jq -r '[.findings[].identity_key] | index("product") != null' <<<"$ENV_OUT")"
  local has_category
  has_category="$(jq -r '[.findings[].identity_key] | index("category") != null' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "fail" && "$universe" == "3" && "$assertions" == "3" && "$passed" == "1" \
     && "$findings_n" == "2" && "$has_products" == "true" && "$has_product" == "true" \
     && "$has_category" == "false" ]] \
    && pass "producer 'products' vs consumer 'product': two orphan findings (one per direction), shared 'category' produces none" \
    || fail "orphan both directions (ec=$RUN_EC status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n has_products=$has_products has_product=$has_product has_category=$has_category out=$ENV_OUT err=$RUN_STDERR)"
}

t_orphan_finding_shape() {
  local r; r="$(new_repo orphan-shape)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  return {};
}
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local f mech surface src found ident plain has_status commit
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  mech="$(jq -r '.mechanism' <<<"$f")"
  surface="$(jq -r '.surface' <<<"$f")"
  src="$(jq -r '.surface_source' <<<"$f")"
  found="$(jq -r '.found_by' <<<"$f")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  plain="$(jq -r '.plain' <<<"$f")"
  has_status="$(jq -r 'has("status")' <<<"$f")"
  commit="$(jq -r '.evidence.commit' <<<"$f")"

  [[ "$mech" == "CONTRACT DRIFT" && "$surface" == "read-path" && "$src" == "declared" \
     && "$found" == "sweep-family-A" && "$ident" == "products" && -n "$plain" \
     && "$has_status" == "false" && -n "$commit" && "$commit" != "null" ]] \
    && pass "orphan finding shape (CONTRACT DRIFT / read-path / declared / sweep-family-A / no status / has commit)" \
    || fail "orphan finding shape (mech=$mech surface=$surface src=$src found=$found ident=$ident status?=$has_status commit=$commit)"
}

t_orphan_finding_survives_emit() {
  local r; r="$(new_repo orphan-emit)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local f ident fid stamped findings_out
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  fid="$(sweep_finding_id repo A2 "CONTRACT DRIFT" "" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    [[ "$(wc -l < "$findings_out" | tr -d ' ')" == "1" ]] \
      && pass "orphan finding survives the real sweep_emit_finding" \
      || fail "orphan finding survives sweep_emit_finding (wrote $(wc -l < "$findings_out") lines)"
  else
    fail "orphan finding survives sweep_emit_finding (refused: $(cat "$TMP/emit.err"))"
  fi
}

# ---- t_matched_keys: producer and consumer agree -> pass, no findings ----

t_matched_keys_no_finding() {
  local r; r="$(new_repo matched)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { status: state.status };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  const status = req.nextUrl.searchParams.get('status');
  return { status };
}
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local status universe assertions passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "pass" && "$universe" == "1" && "$assertions" == "1" \
     && "$passed" == "1" && "$findings_n" == "0" ]] \
    && pass "producer and consumer agree on 'status': pass, universe 1, no findings" \
    || fail "matched keys (ec=$RUN_EC status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n out=$ENV_OUT err=$RUN_STDERR)"
}

# ---- t_missing_producer_file: fail-closed check-error, never a silent pass ----

t_missing_producer_file_is_check_error() {
  local r; r="$(new_repo missing-producer)"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  return { status: req.nextUrl.searchParams.get('status') };
}
EOF
  local job; job="$(build_job "$r" '["src/lib/does-not-exist.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ -n "$ENV_OUT" && "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "missing producer file: fails closed with status error (check-error), not a silent pass" \
    || fail "missing producer file -> status error (status=$status findings=$findings_n out=$ENV_OUT)"
}

t_missing_producer_function_is_check_error() {
  local r; r="$(new_repo missing-function)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function someOtherFunction(state) {
  return { status: state.status };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local status
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  [[ -n "$ENV_OUT" && "$status" == "error" ]] \
    && pass "declared producer function not found in the file: fails closed with status error" \
    || fail "missing producer function -> status error (status=$status out=$ENV_OUT)"
}

# ---- t_identity_key_stable_across_reruns ----

t_identity_key_stable_across_reruns() {
  local r; r="$(new_repo stable-id)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"

  run_check "$job"
  local ident1 fid1
  ident1="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  fid1="$(sweep_finding_id repo A2 "CONTRACT DRIFT" "" "$ident1")"

  run_check "$job"
  local ident2 fid2
  ident2="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  fid2="$(sweep_finding_id repo A2 "CONTRACT DRIFT" "" "$ident2")"

  [[ -n "$ident1" && "$ident1" == "$ident2" && "$fid1" == "$fid2" ]] \
    && pass "identity_key/finding_id: re-running the same job against the same fixture reproduces the SAME identity_key and finding_id" \
    || fail "identity_key stability across reruns (ident1=$ident1 ident2=$ident2 fid1=$fid1 fid2=$fid2)"
}

# ---- t_digit_run_key: a key with a 4+ digit run survives R1 ----

t_digit_run_key_survives_r1() {
  local r; r="$(new_repo digit-run)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { page2026: state.page };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local ident
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  local r1_safe=true
  [[ "$ident" =~ [0-9]{4,} ]] && r1_safe=false

  local f fid stamped findings_out emit_ok=false
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  fid="$(sweep_finding_id repo A2 "CONTRACT DRIFT" "" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err" && emit_ok=true

  [[ -n "$ident" && "$r1_safe" == "true" && "$emit_ok" == "true" ]] \
    && pass "a key with a 4+ digit run (page2026) sanitizes to an R1-safe identity_key that survives the real sweep_emit_finding" \
    || fail "digit-run key survives R1 (ident=$ident r1_safe=$r1_safe emit_ok=$emit_ok err=$(cat "$TMP/emit.err" 2>/dev/null))"
}

# ---- t_exclusion: a config.exclusions[] key is excluded, no finding ----

t_exclusion_declared_key_produces_no_finding() {
  local r; r="$(new_repo exclusion)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products, legacyDrilldownParam: state.legacy };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local excl='[{"unit":"legacyDrilldownParam","reason":"removed in #991, kept for one release"}]'
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]' "$excl")"
  run_check "$job"

  local universe assertions findings_n excluded_n unit reason
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  excluded_n="$(jq -r '.excluded | length' <<<"$ENV_OUT")"
  unit="$(jq -r '.excluded[0].unit' <<<"$ENV_OUT")"
  reason="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"
  local has_products; has_products="$(jq -r '[.findings[].identity_key] | index("products") != null' <<<"$ENV_OUT")"

  [[ "$universe" == "2" && "$assertions" == "1" && "$findings_n" == "1" && "$has_products" == "true" \
     && "$excluded_n" == "1" && "$unit" == "legacyDrilldownParam" \
     && "$reason" == "removed in #991, kept for one release" ]] \
    && pass "a config.exclusions[] key is reported in excluded[] with its reason and produces no finding of its own" \
    || fail "declared exclusion (universe=$universe assertions=$assertions findings=$findings_n excluded=$excluded_n unit=$unit reason=$reason has_products=$has_products)"
}

# ---- t_envelope_echoes_job_identity ----

t_envelope_echoes_job_identity() {
  local r; r="$(new_repo identity)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { status: state.status };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  return { status: req.nextUrl.searchParams.get('status') };
}
EOF
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"

  local schema check_id basis surface
  schema="$(jq -r '.schema' <<<"$ENV_OUT")"
  check_id="$(jq -r '.check_id' <<<"$ENV_OUT")"
  basis="$(jq -r '.evidence_basis' <<<"$ENV_OUT")"
  surface="$(jq -r '.surface' <<<"$ENV_OUT")"

  [[ "$schema" == "sweep-result/v1" && "$check_id" == "A2" \
     && "$basis" == "static-source" && "$surface" == "read-path" ]] \
    && pass "envelope echoes the job's evidence_basis and surface byte-for-byte" \
    || fail "envelope echoes job identity (schema=$schema check_id=$check_id basis=$basis surface=$surface)"
}

# ---- t_node_unavailable: fails closed with status error, never silent ----

t_node_unavailable_is_check_error() {
  local r; r="$(new_repo no-node)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { status: state.status };
}
EOF
  local nodeless_bin; nodeless_bin="$(mktemp -d "$TMP/nodeless-bin.XXXXXX")"
  for tool in bash jq git sh mktemp cat rm tr base64 basename dirname od date grep; do
    local found; found="$(command -v "$tool" 2>/dev/null)"
    [[ -n "$found" ]] && ln -sf "$found" "$nodeless_bin/$tool"
  done

  local job out line env_out ec
  job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '[]')"
  out="$(printf '%s' "$job" | PATH="$nodeless_bin" bash "$CHECK" 2>"$TMP/nodeless.stderr")"
  ec=$?
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  env_out="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
  local status; status="$(jq -r '.status // ""' <<<"$env_out" 2>/dev/null)"

  [[ "$ec" -eq 0 && -n "$env_out" && "$status" == "error" ]] \
    && pass "node unavailable on PATH: fails closed with status error, still emits a well-formed envelope (never a silent pass)" \
    || fail "node unavailable -> status error (ec=$ec status=$status out=$env_out err=$(cat "$TMP/nodeless.stderr" 2>/dev/null))"
}

# ---- end-to-end through the REAL runner: check-error is a liveness failure ----

RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"
CHECKS_DIR="$REPO_ROOT/scripts/sweep/checks"

run_runner() {
  local repo="$1" cfg="$2"
  mkdir -p "$repo/.claude/sweep"
  jq . <<<"$cfg" > "$repo/.claude/sweep.config.json"
  printf 'A2\n' > "$repo/inventory.txt"
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    bash "$RUNNER" --repo "$repo" --cadence manual --json 2>"$TMP/runner.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/runner.err")"
}

t_runner_missing_producer_exits_2_check_error() {
  local r; r="$(new_repo runner-missing-producer)"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return {}; }
EOF
  local cfg
  cfg="$(jq -cn '
    {schema:"sweep-config/v1", mode:"observe", check_modes:{}, surfaces:{A2:"read-path"},
     families:{A2:{producers:["src/lib/does-not-exist.ts#f"], consumer_globs:["src/routes/**/*.ts"], exclusions:[]}},
     skips:[]}')"
  run_runner "$r" "$cfg"

  local st code
  st="$(jq -r '.checks[] | select(.check_id=="A2") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  code="$(jq -r '.checks[] | select(.check_id=="A2") | .violation' <<<"$RUN_OUT" 2>/dev/null)"

  [[ "$RUN_EC" == "2" && "$st" == "fail" && "$code" == *"could not complete"* ]] \
    && pass "runner: a missing producer file is a liveness failure (exit 2, check-error) — never a silent pass through the real runner" \
    || fail "runner missing-producer -> exit 2 check-error (ec=$RUN_EC status=$st violation=$code out=$RUN_OUT err=$RUN_ERR)"
}

t_runner_full_match_passes_clean() {
  local r; r="$(new_repo runner-clean)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { status: state.status };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  return { status: req.nextUrl.searchParams.get('status') };
}
EOF
  local cfg
  cfg="$(jq -cn '
    {schema:"sweep-config/v1", mode:"observe", check_modes:{}, surfaces:{A2:"read-path"},
     families:{A2:{producers:["src/lib/filter-params.ts#filterStateToParams"],
                   consumer_globs:["src/routes/**/*.ts"], exclusions:[]}},
     skips:[]}')"
  run_runner "$r" "$cfg"

  local st
  st="$(jq -r '.checks[] | select(.check_id=="A2") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "pass" ]] \
    && pass "runner: a matched producer/consumer pair passes clean through the real runner (exit 0)" \
    || fail "runner full match -> exit 0 pass (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

t_orphan_both_directions
t_orphan_finding_shape
t_orphan_finding_survives_emit
t_matched_keys_no_finding
t_missing_producer_file_is_check_error
t_missing_producer_function_is_check_error
t_identity_key_stable_across_reruns
t_digit_run_key_survives_r1
t_exclusion_declared_key_produces_no_finding
# ---- couldn't-look ≠ found-nothing (2026-08-19 census): an unreadable
# consumer file must error out, never make every key a producer orphan ----
t_unreadable_consumer_file_is_check_error() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "SKIP: running as root — chmod 000 cannot make a file unreadable"
    return 0
  fi
  local r; r="$(new_repo unreadable-consumer)"
  writefile "$r/src/lib/filter-params.ts" <<'EOF'
export function filterStateToParams(state) {
  return { products: state.products };
}
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  return { products: req.nextUrl.searchParams.get('products') };
}
EOF
  chmod 000 "$r/src/routes/handler.ts"
  local job; job="$(build_job "$r" '["src/lib/filter-params.ts#filterStateToParams"]' '["src/routes/**/*.ts"]')"
  run_check "$job"
  chmod 644 "$r/src/routes/handler.ts"
  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "unreadable consumer file: status error, no fabricated producer-orphan findings" \
    || fail "unreadable consumer file (status=$status findings=$findings_n)"
}

t_envelope_echoes_job_identity
t_node_unavailable_is_check_error
t_runner_missing_producer_exits_2_check_error
t_runner_full_match_passes_clean
t_unreadable_consumer_file_is_check_error

echo "----"
echo "test-sweep-a2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
