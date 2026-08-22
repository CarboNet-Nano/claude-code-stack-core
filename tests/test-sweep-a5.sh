#!/usr/bin/env bash
# tests/test-sweep-a5.sh — Tests for scripts/sweep/checks/a5-command-callers.sh
# (stack ADR-078/ADR-082, docs/superpowers/specs/2026-08-16-testing-doctrine-
# redesign.md P1a). A5 is the doctrine v2's one new Sweep check: command-
# has-interface-caller, audit #4's DISCONNECTED class on the command-map
# side — a command a dispatch table knows about that no interface actually
# calls.
#
# Style mirrors tests/test-sweep-a2.sh: every case invokes the check
# directly against a real, throwaway git repo with real fixture files. Two
# cases at the bottom go through the REAL runner
# (scripts/sweep/sweep-run.sh). Every emitted finding is round-tripped
# through the real sweep-emit.sh. The last two cases exercise
# scripts/sweep-install.sh's idempotent upgrade branch (item 7b of the
# implementer's handoff) — generic-over-inventory healing, not A5-specific,
# but A5 is the id used to prove it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/a5-command-callers.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"
CONFIG_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-config.sh"
INSTALL="$REPO_ROOT/scripts/sweep-install.sh"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
[ -f "$EMIT_LIB" ] || { echo "FATAL: $EMIT_LIB not found"; exit 1; }
[ -f "$CONFIG_LIB" ] || { echo "FATAL: $CONFIG_LIB not found"; exit 1; }
[ -f "$INSTALL" ] || { echo "FATAL: $INSTALL not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available — a5-command-callers.sh's lexical extraction is a node script"; echo "test-sweep-a5: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a5-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_repo <name> -> a real throwaway git repo with one commit, so
# `git -C <repo> rev-parse HEAD` (the check's evidence.commit source)
# succeeds. Mirrors tests/test-sweep-a2.sh's new_repo helper.
new_repo() {
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" ) >/dev/null
  git -C "$r" rev-parse --show-toplevel
}

# writefile <path> <heredoc content via stdin>
writefile() { mkdir -p "$(dirname "$1")" && cat > "$1"; }

# build_job <repo_root> <command_map> <interface_files-json-array> <min_expected> [exclusions-json-array]
build_job() {
  jq -cn --arg repo "$1" --arg cmap "$2" --argjson iface "$3" --argjson min "$4" --argjson excl "${5:-[]}" '
    {schema:"sweep-job/v1", run_id:"2026-08-16T00:00:00Z.test01", check_id:"A5",
     repo_root:$repo, cadence:"push-main", writes_findings:true,
     evidence_basis:"static-source", surface:"write-path",
     config:{command_map:$cmap, interface_files:$iface, exclusions:$excl, min_expected_commands:$min},
     changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <job-json> -> sets ENV_OUT (decoded envelope) and RUN_EC.
run_check() {
  local job="$1" out line
  out="$(printf '%s' "$job" | bash "$CHECK" 2>"$TMP/a5.stderr")"
  RUN_EC=$?
  RUN_STDERR="$(cat "$TMP/a5.stderr" 2>/dev/null)"
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
}

# write_command_map <repo> -> the fixture command map: three kebab-case
# command ids, matching the shape real mutation-engine dispatch tables use
# (the reason parseObjectKeys' quoted-key acceptance had to widen beyond
# bare identifiers — see extract.mjs).
write_command_map() {
  local r="$1"
  writefile "$r/src/lib/commands.ts" <<'EOF'
export const COMMAND_MAP = {
  "run-report": doRunReport,
  "sync-data": doSyncData,
  "purge-cache": doPurgeCache,
};
EOF
}

# ---- t_uncalled_command_disconnected: audit #4's catch-proof ----
# "purge-cache" appears nowhere in the interface file; the other two do.

t_uncalled_command_disconnected() {
  local r; r="$(new_repo uncalled)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  if (req.command === "run-report") return runReport();
  if (req.command === "sync-data") return syncData();
  return null;
}
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"

  local status universe assertions passed findings_n has_purge has_run has_sync
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  has_purge="$(jq -r '[.findings[].identity_key] | index("purge-cache") != null' <<<"$ENV_OUT")"
  has_run="$(jq -r '[.findings[].identity_key] | index("run-report") != null' <<<"$ENV_OUT")"
  has_sync="$(jq -r '[.findings[].identity_key] | index("sync-data") != null' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "fail" && "$universe" == "3" && "$assertions" == "3" && "$passed" == "2" \
     && "$findings_n" == "1" && "$has_purge" == "true" && "$has_run" == "false" && "$has_sync" == "false" ]] \
    && pass "'purge-cache' has no interface caller: one DISCONNECTED finding, the other two command ids pass" \
    || fail "uncalled command disconnected (ec=$RUN_EC status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n has_purge=$has_purge has_run=$has_run has_sync=$has_sync out=$ENV_OUT err=$RUN_STDERR)"
}

t_finding_shape() {
  local r; r="$(new_repo shape)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
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

  [[ "$mech" == "DISCONNECTED" && "$surface" == "write-path" && "$src" == "declared" \
     && "$found" == "sweep-family-A" && -n "$ident" && -n "$plain" \
     && "$has_status" == "false" && -n "$commit" && "$commit" != "null" ]] \
    && pass "finding shape (DISCONNECTED / write-path / declared / sweep-family-A / no status / has commit)" \
    || fail "finding shape (mech=$mech surface=$surface src=$src found=$found ident=$ident status?=$has_status commit=$commit)"
}

t_finding_survives_emit() {
  local r; r="$(new_repo emit)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"

  local f ident fid stamped findings_out
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  fid="$(sweep_finding_id repo A5 "DISCONNECTED" "" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-16T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-16T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    [[ "$(wc -l < "$findings_out" | tr -d ' ')" == "1" ]] \
      && pass "finding survives the real sweep_emit_finding" \
      || fail "finding survives sweep_emit_finding (wrote $(wc -l < "$findings_out") lines)"
  else
    fail "finding survives sweep_emit_finding (refused: $(cat "$TMP/emit.err"))"
  fi
}

# ---- t_all_commands_called: pass, no findings ----

t_all_commands_called_no_finding() {
  local r; r="$(new_repo matched)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  if (req.command === "run-report") return runReport();
  if (req.command === "sync-data") return syncData();
  if (req.command === "purge-cache") return purgeCache();
  return null;
}
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"

  local status universe assertions passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "pass" && "$universe" == "3" && "$assertions" == "3" \
     && "$passed" == "3" && "$findings_n" == "0" ]] \
    && pass "every command id has an interface caller: pass, universe 3, no findings" \
    || fail "all commands called (ec=$RUN_EC status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n out=$ENV_OUT err=$RUN_STDERR)"
}

# ---- t_missing_command_map_file: fail-closed check-error ----

t_missing_command_map_file_is_check_error() {
  local r; r="$(new_repo missing-file)"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/does-not-exist.ts#COMMAND_MAP" '["src/routes/*.ts"]' 1)"
  run_check "$job"

  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ -n "$ENV_OUT" && "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "missing command_map file: fails closed with status error (check-error), not a silent pass" \
    || fail "missing command_map file -> status error (status=$status findings=$findings_n out=$ENV_OUT)"
}

t_missing_export_symbol_is_check_error() {
  local r; r="$(new_repo missing-symbol)"
  writefile "$r/src/lib/commands.ts" <<'EOF'
export const OTHER_MAP = { "foo": doFoo };
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 1)"
  run_check "$job"

  local status
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  [[ -n "$ENV_OUT" && "$status" == "error" ]] \
    && pass "declared export symbol not found in the file: fails closed with status error" \
    || fail "missing export symbol -> status error (status=$status out=$ENV_OUT)"
}

# ---- t_not_extractable: dynamic/computed keys -> below floor -> error ----
# The rejection criterion (spec's own wording): a repo whose command ids
# cannot be extracted by the configured pattern never guesses with regex
# heuristics — it fails closed through the SAME min_expected_commands floor
# that catches any other extraction shortfall.

t_dynamic_keys_not_extractable_is_check_error() {
  local r; r="$(new_repo dynamic-keys)"
  writefile "$r/src/lib/commands.ts" <<'EOF'
const dynamicKey = "computed";
export const COMMAND_MAP = {
  [dynamicKey]: doThing,
  "static-one": doStaticOne,
};
EOF
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 2)"
  run_check "$job"

  local status
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  [[ -n "$ENV_OUT" && "$status" == "error" ]] \
    && pass "a computed key silently shrinks extraction below the floor: fails closed with status error, never guesses" \
    || fail "dynamic keys not extractable -> status error (status=$status out=$ENV_OUT)"
}

t_below_floor_is_check_error() {
  local r; r="$(new_repo below-floor)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 10)"
  run_check "$job"

  local status
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  [[ -n "$ENV_OUT" && "$status" == "error" ]] \
    && pass "extracted count (3) below the configured min_expected_commands (10): fails closed with status error" \
    || fail "below floor -> status error (status=$status out=$ENV_OUT)"
}

# ---- t_exclusion: a config.exclusions[] id is excluded, no finding ----

t_exclusion_declared_id_produces_no_finding() {
  local r; r="$(new_repo exclusion)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  if (req.command === "run-report") return runReport();
  if (req.command === "sync-data") return syncData();
  return null;
}
EOF
  local excl='[{"id":"purge-cache","reason":"scheduled-only, no direct interface caller by design"}]'
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3 "$excl")"
  run_check "$job"

  local universe assertions findings_n excluded_n unit reason
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  excluded_n="$(jq -r '.excluded | length' <<<"$ENV_OUT")"
  unit="$(jq -r '.excluded[0].unit' <<<"$ENV_OUT")"
  reason="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"

  [[ "$universe" == "3" && "$assertions" == "2" && "$findings_n" == "0" \
     && "$excluded_n" == "1" && "$unit" == "purge-cache" \
     && "$reason" == "scheduled-only, no direct interface caller by design" ]] \
    && pass "a config.exclusions[] id is reported in excluded[] with its reason and produces no finding" \
    || fail "declared exclusion (universe=$universe assertions=$assertions findings=$findings_n excluded=$excluded_n unit=$unit reason=$reason)"
}

# ---- t_envelope_echoes_job_identity ----

t_envelope_echoes_job_identity() {
  local r; r="$(new_repo identity)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  if (req.command === "run-report") return runReport();
  if (req.command === "sync-data") return syncData();
  if (req.command === "purge-cache") return purgeCache();
  return null;
}
EOF
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"

  local schema check_id basis surface
  schema="$(jq -r '.schema' <<<"$ENV_OUT")"
  check_id="$(jq -r '.check_id' <<<"$ENV_OUT")"
  basis="$(jq -r '.evidence_basis' <<<"$ENV_OUT")"
  surface="$(jq -r '.surface' <<<"$ENV_OUT")"

  [[ "$schema" == "sweep-result/v1" && "$check_id" == "A5" \
     && "$basis" == "static-source" && "$surface" == "write-path" ]] \
    && pass "envelope echoes the job's evidence_basis and surface byte-for-byte" \
    || fail "envelope echoes job identity (schema=$schema check_id=$check_id basis=$basis surface=$surface)"
}

# ---- t_node_unavailable: fails closed with status error, never silent ----

t_node_unavailable_is_check_error() {
  local r; r="$(new_repo no-node)"
  write_command_map "$r"
  local nodeless_bin; nodeless_bin="$(mktemp -d "$TMP/nodeless-bin.XXXXXX")"
  for tool in bash jq git sh mktemp cat rm tr base64 basename dirname od date grep find sed; do
    local found; found="$(command -v "$tool" 2>/dev/null)"
    [[ -n "$found" ]] && ln -sf "$found" "$nodeless_bin/$tool"
  done

  local job out line env_out ec
  job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '[]' 3)"
  out="$(printf '%s' "$job" | PATH="$nodeless_bin" bash "$CHECK" 2>"$TMP/nodeless.stderr")"
  ec=$?
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  env_out="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
  local status; status="$(jq -r '.status // ""' <<<"$env_out" 2>/dev/null)"

  [[ "$ec" -eq 0 && -n "$env_out" && "$status" == "error" ]] \
    && pass "node unavailable on PATH: fails closed with status error, still emits a well-formed envelope (never a silent pass)" \
    || fail "node unavailable -> status error (ec=$ec status=$status out=$env_out err=$(cat "$TMP/nodeless.stderr" 2>/dev/null))"
}

# ---- end-to-end through the REAL runner ----

RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"
CHECKS_DIR="$REPO_ROOT/scripts/sweep/checks"

run_runner() {
  local repo="$1" cfg="$2"
  mkdir -p "$repo/.claude/sweep"
  jq . <<<"$cfg" > "$repo/.claude/sweep.config.json"
  printf 'A5\n' > "$repo/inventory.txt"
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    bash "$RUNNER" --repo "$repo" --cadence manual --json 2>"$TMP/runner.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/runner.err")"
}

t_runner_missing_map_exits_2_check_error() {
  local r; r="$(new_repo runner-missing-map)"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) { return null; }
EOF
  local cfg
  cfg="$(jq -cn '
    {schema:"sweep-config/v1", mode:"observe", check_modes:{}, surfaces:{A5:"write-path"},
     families:{A5:{command_map:"src/lib/does-not-exist.ts#COMMAND_MAP", interface_files:["src/routes/*.ts"],
                   exclusions:[], min_expected_commands:1}},
     skips:[]}')"
  run_runner "$r" "$cfg"

  local st code
  st="$(jq -r '.checks[] | select(.check_id=="A5") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  code="$(jq -r '.checks[] | select(.check_id=="A5") | .violation' <<<"$RUN_OUT" 2>/dev/null)"

  [[ "$RUN_EC" == "2" && "$st" == "fail" && "$code" == *"could not complete"* ]] \
    && pass "runner: a missing command_map file is a liveness failure (exit 2, check-error) — never a silent pass through the real runner" \
    || fail "runner missing-map -> exit 2 check-error (ec=$RUN_EC status=$st violation=$code out=$RUN_OUT err=$RUN_ERR)"
}

t_runner_full_match_passes_clean() {
  local r; r="$(new_repo runner-clean)"
  write_command_map "$r"
  writefile "$r/src/routes/handler.ts" <<'EOF'
export function handler(req) {
  if (req.command === "run-report") return runReport();
  if (req.command === "sync-data") return syncData();
  if (req.command === "purge-cache") return purgeCache();
  return null;
}
EOF
  local cfg
  cfg="$(jq -cn '
    {schema:"sweep-config/v1", mode:"observe", check_modes:{}, surfaces:{A5:"write-path"},
     families:{A5:{command_map:"src/lib/commands.ts#COMMAND_MAP", interface_files:["src/routes/*.ts"],
                   exclusions:[], min_expected_commands:3}},
     skips:[]}')"
  run_runner "$r" "$cfg"

  local st
  st="$(jq -r '.checks[] | select(.check_id=="A5") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "pass" ]] \
    && pass "runner: every command id having a caller passes clean through the real runner (exit 0)" \
    || fail "runner full match -> exit 0 pass (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

# ---- config schema: A5 declared without min_expected_commands/exclusions ----
# is invalid; a missing block + no skip -> sweep_config_validate exit 3.

t_config_missing_a5_block_and_skip_is_exit_3() {
  # shellcheck source=/dev/null
  ( source "$CONFIG_LIB"
    local r="$TMP/config-missing"
    mkdir -p "$r/.claude"
    printf '%s\n' '{
  "schema": "sweep-config/v1",
  "mode": "observe",
  "check_modes": {},
  "surfaces": {"B4": "ci-gate"},
  "families": {"B4": {}},
  "skips": []
}' > "$r/.claude/sweep.config.json"
    SWEEP_INVENTORY_FILE="$TMP/config-missing-inventory.txt"
    printf 'B4\nA5\n' > "$SWEEP_INVENTORY_FILE"
    export SWEEP_INVENTORY_FILE
    sweep_config_validate "$r" >/dev/null 2>"$TMP/validate.err"
    ec=$?
    [[ "$ec" == "3" ]] && grep -q "A5" "$TMP/validate.err" \
      && pass "config declaring A5 in neither families nor skips -> sweep_config_validate exit 3, naming A5" \
      || fail "config missing A5 block+skip -> exit 3 (ec=$ec err=$(cat "$TMP/validate.err"))"
  )
}

t_config_a5_block_missing_min_expected_commands_rejected() {
  local schema="$REPO_ROOT/schemas/sweep-config.json"
  # shellcheck source=/dev/null
  ( source "$EMIT_LIB"
    local bad='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},
      "surfaces":{"A5":"write-path"},
      "families":{"A5":{"command_map":"src/lib/commands.ts#COMMAND_MAP","interface_files":["src/routes/*.ts"],"exclusions":[]}},
      "skips":[]}'
    local errs; errs="$(_sweep_schema_errors "$schema" <<<"$bad" | jq 'length')"
    [[ "$errs" -gt 0 ]] \
      && pass "families.A5 without min_expected_commands is rejected by the sweep-config/v1 schema" \
      || fail "families.A5 missing min_expected_commands should be schema-invalid (errs=$errs)"
  )
}

# ---- sweep-install.sh: idempotent upgrade branch (generic over inventory) ----

t_install_upgrade_branch_appends_skip_for_undeclared_ids() {
  local r="$TMP/install-upgrade"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main && echo x > .gitignore ) >/dev/null
  mkdir -p "$r/.claude"
  printf '%s\n' '{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{},"families":{},"skips":[]}' \
    > "$r/.claude/sweep.config.json"
  local sha="dc6d4d4ac18c8ad38939f9efc4df72055edb6290"
  bash "$INSTALL" --repo "$r" --ref "$sha" >/dev/null 2>"$TMP/install1.err"
  local ec1=$?
  local a5_n; a5_n="$(jq -r '[.skips[] | select(.check_id=="A5")] | length' "$r/.claude/sweep.config.json")"
  local a5_reason; a5_reason="$(jq -r '.skips[] | select(.check_id=="A5") | .reason' "$r/.claude/sweep.config.json")"
  [[ "$ec1" == "0" && "$a5_n" == "1" && "$a5_reason" == *"stack upgrade"* ]] \
    && pass "sweep-install.sh: an inventory id (A5) neither declared nor skipped is appended to skips with a stack-upgrade reason" \
    || fail "install upgrade branch appends A5 skip (ec=$ec1 a5_n=$a5_n reason=$a5_reason err=$(cat "$TMP/install1.err"))"
}

t_install_upgrade_branch_idempotent_on_rerun() {
  local r="$TMP/install-upgrade-idem"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main && echo x > .gitignore ) >/dev/null
  mkdir -p "$r/.claude"
  printf '%s\n' '{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{},"families":{},"skips":[]}' \
    > "$r/.claude/sweep.config.json"
  local sha="dc6d4d4ac18c8ad38939f9efc4df72055edb6290"
  bash "$INSTALL" --repo "$r" --ref "$sha" >/dev/null 2>&1
  bash "$INSTALL" --repo "$r" --ref "$sha" >/dev/null 2>&1
  local ec2=$?
  local a5_n; a5_n="$(jq -r '[.skips[] | select(.check_id=="A5")] | length' "$r/.claude/sweep.config.json")"
  [[ "$ec2" == "0" && "$a5_n" == "1" ]] \
    && pass "sweep-install.sh: running the upgrade branch twice appends exactly one A5 skip entry, not two" \
    || fail "install upgrade branch idempotent rerun (ec=$ec2 a5_n=$a5_n)"
}

t_uncalled_command_disconnected
t_finding_shape
t_finding_survives_emit
t_all_commands_called_no_finding
t_missing_command_map_file_is_check_error
t_missing_export_symbol_is_check_error
t_dynamic_keys_not_extractable_is_check_error
t_below_floor_is_check_error
t_exclusion_declared_id_produces_no_finding
t_envelope_echoes_job_identity
t_node_unavailable_is_check_error
t_runner_missing_map_exits_2_check_error
t_runner_full_match_passes_clean
# ---- couldn't-look ≠ found-nothing (2026-08-19 census) ----
t_unreadable_interface_file_is_check_error() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "SKIP: running as root — chmod 000 cannot make a file unreadable"
    return 0
  fi
  local r; r="$(new_repo unreadable-iface)"
  write_command_map "$r"
  writefile "$r/src/routes/app.ts" <<'EOF'
runCommand("run-report"); runCommand("sync-data"); runCommand("purge-cache");
EOF
  chmod 000 "$r/src/routes/app.ts"
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"
  chmod 644 "$r/src/routes/app.ts"
  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "unreadable interface file: status error, no DISCONNECTED findings fabricated" \
    || fail "unreadable interface file (status=$status findings=$findings_n)"
}

t_unreadable_tree_walk_is_check_error() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "SKIP: running as root — chmod 000 cannot make a directory unwalkable"
    return 0
  fi
  local r; r="$(new_repo unwalkable)"
  write_command_map "$r"
  writefile "$r/src/routes/app.ts" <<'EOF'
runCommand("run-report"); runCommand("sync-data"); runCommand("purge-cache");
EOF
  mkdir -p "$r/src/locked"
  chmod 000 "$r/src/locked"
  local job; job="$(build_job "$r" "src/lib/commands.ts#COMMAND_MAP" '["src/routes/*.ts"]' 3)"
  run_check "$job"
  chmod 755 "$r/src/locked"
  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "unwalkable subtree: the failed walk is an error, never an empty interface list" \
    || fail "unwalkable subtree (status=$status findings=$findings_n)"
}

t_config_missing_a5_block_and_skip_is_exit_3
t_config_a5_block_missing_min_expected_commands_rejected
t_install_upgrade_branch_appends_skip_for_undeclared_ids
t_install_upgrade_branch_idempotent_on_rerun
t_unreadable_interface_file_is_check_error
t_unreadable_tree_walk_is_check_error

echo "----"
echo "test-sweep-a5: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
