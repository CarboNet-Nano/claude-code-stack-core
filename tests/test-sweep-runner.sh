#!/usr/bin/env bash
# Tests for scripts/sweep/sweep-run.sh + scripts/sweep/lib/sweep-config.sh
# (stack ADR-078, task 4 of the Sweep serial spine).
#
# The runner is the only place the six structural liveness invariants of
# spec S4.2 live, so each invariant gets its own test with its own fixture
# check — a combined case would let one invariant pass on another's
# behalf. Exit codes are law (spec S5.4): 0 pass/observe, 1 blocking
# findings, 2 liveness failure (always with the plain sentence), 3 invalid
# configuration.
#
# The harness builds a throwaway repo per case and points the runner at a
# fixture inventory and a fixture checks dir via SWEEP_INVENTORY_FILE /
# SWEEP_CHECKS_DIR — the two test seams; the CLI itself stays exactly as
# spec S5.4 froze it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"
CONFIG_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-config.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"
INVENTORY="$REPO_ROOT/scripts/sweep/inventory.txt"
FIXTURES="$REPO_ROOT/tests/fixtures/sweep-checks"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$RUNNER" ] || { echo "FATAL: $RUNNER not found"; exit 1; }
[ -f "$CONFIG_LIB" ] || { echo "FATAL: $CONFIG_LIB not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-runner-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

SENTENCE_TAIL="Until this is fixed, a green tick on this repo means nothing."

CONFIG_B4='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"B4":"ci-gate"},"families":{"B4":{}},"skips":[{"check_id":"E1","reason":"no browser-routable surface in this fixture repo"}]}'
CONFIG_E1='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"E1":"ui-route"},"families":{"E1":{"app":"apps/web","route_manifest_cmd":"echo /","base_url_env":"SWEEP_BASE_URL","exclusions":[]}},"skips":[{"check_id":"B4","reason":"no CI history in this fixture repo"}]}'

# mkrepo -> echoes a throwaway repo dir carrying its own inventory + checks dir
mkrepo() {
  local d; d="$(mktemp -d "$TMP/repo.XXXXXX")"
  mkdir -p "$d/.claude/sweep" "$d/checks"
  printf 'B4\nE1\n' > "$d/inventory.txt"
  cp "$FIXTURES/_envelope.sh" "$d/checks/_envelope.sh"
  echo "$d"
}

# install_check <repo> <check-id> <fixture-file>
install_check() {
  local lower; lower="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  cp "$FIXTURES/$3" "$1/checks/$lower-fixture.sh"
  chmod +x "$1/checks/$lower-fixture.sh"
}

# write_config <repo> <json>
write_config() { jq . <<<"$2" > "$1/.claude/sweep.config.json"; }

# run_sweep <repo> <args...> -> sets RUN_OUT / RUN_ERR / RUN_EC
run_sweep() {
  local repo="$1"; shift
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$repo/checks" \
    bash "$RUNNER" --repo "$repo" "$@" 2>"$TMP/run.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/run.err")"
}

# GNU first: on Linux `stat -f %m` is filesystem status (whose free-block
# counts change between calls), not an error, so BSD-first never falls
# through and the "mtime" is garbage that never compares equal.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
findings_of() { echo "$1/.claude/sweep/findings.jsonl"; }

# ---- ARG_MAX regression: a huge envelope must survive ingestion ----

t_large_envelope_survives_ingestion() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 finds-many-large.sh
  run_sweep "$r" --cadence pr --json
  local n; n="$(jq -r '.checks[] | select(.check_id=="B4") | .findings_n' <<<"$RUN_OUT" 2>/dev/null)"
  local viol; viol="$(jq -r '.checks[] | select(.check_id=="B4") | .violation // "none"' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$n" == "400" && "$viol" == "none" ]] \
    && pass "ARG_MAX: a 400-finding (~400KB) envelope is ingested intact (findings_n=$n)" \
    || fail "ARG_MAX: large envelope mangled (findings_n=$n violation=$viol err=$(tail -2 <<<"$RUN_ERR"))"
}

# ---- invariant 1: non-vacuity (B1) ----

t_inv1_vacuous_exit2_and_meta_finding() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main
  local f; f="$(findings_of "$r")"
  local row; row="$(head -1 "$f" 2>/dev/null)"
  local mech found surface src ident has_status
  mech="$(jq -r '.mechanism // ""' <<<"$row" 2>/dev/null)"
  found="$(jq -r '.found_by // ""' <<<"$row" 2>/dev/null)"
  surface="$(jq -r '.surface // ""' <<<"$row" 2>/dev/null)"
  src="$(jq -r '.surface_source // ""' <<<"$row" 2>/dev/null)"
  ident="$(jq -r '.identity_key // ""' <<<"$row" 2>/dev/null)"
  has_status="$(jq -r 'has("status")' <<<"$row" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$mech" == "NEVER RAN" && "$found" == "ci-self-audit" \
     && "$surface" == "ci-gate" && "$src" == "declared" && "$ident" == "B4" && "$has_status" == "false" ]] \
    && pass "B1: vacuous pass -> exit 2 + sweep.vacuous-check meta-finding (NEVER RAN / ci-self-audit / ci-gate, no status)" \
    || fail "B1: vacuous pass -> exit 2 + meta-finding (ec=$RUN_EC mech=$mech found=$found surface=$surface src=$src ident=$ident status?=$has_status)"
}

t_inv1_plain_sentence_verbatim() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main
  local today; today="$(date -u +%Y-%m-%d)"
  local expect="The safety checks did not actually run on $today — B4 reported no work done. $SENTENCE_TAIL"
  grep -Fq "$expect" <<<"$RUN_OUT$RUN_ERR" \
    && pass "exit 2 carries the plain sentence verbatim, with the date and the check named" \
    || fail "exit 2 carries the plain sentence verbatim (got: $RUN_OUT $RUN_ERR)"
}

t_inv1_vacuous_status_rewritten_to_fail() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$st" == "fail" ]] \
    && pass "B1: runner rewrites the check's own pass to fail" \
    || fail "B1: runner rewrites the check's own pass to fail (got: $st)"
}

t_inv1_vacuous_on_pr_exits_2_without_writing() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence pr
  local f; f="$(findings_of "$r")"
  [[ "$RUN_EC" == "2" && ! -f "$f" ]] \
    && pass "B1: vacuous on --cadence pr still exits 2, and writes no findings.jsonl" \
    || fail "B1: vacuous on --cadence pr still exits 2 without writing (ec=$RUN_EC file?=$([ -f "$f" ] && echo yes || echo no))"
}

# ---- invariant 2: default-closed selection (B2) ----

t_inv2_empty_universe_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 empty-universe.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] && grep -Fq "$SENTENCE_TAIL" <<<"$RUN_OUT$RUN_ERR" \
    && pass "B2: universe_size 0 -> exit 2 with the plain sentence" \
    || fail "B2: universe_size 0 -> exit 2 with the plain sentence (ec=$RUN_EC)"
}

# Fix round 2, IMPORTANT (I3): invariant 2 has exactly one declared
# exemption, and only B4 may declare it. `families.B4.empty_universe_ok` is
# a REASON STRING, so an empty universe becomes a legal, recorded skip
# rather than exit 2 — for the repo that genuinely had no landings in the
# window, not for the check whose selection broke. Three cases below:
# declared (legal skip, exit 0, reason recorded), undeclared (unchanged,
# exit 2 — covered by t_inv2_empty_universe_exit2 above), and non-string
# (default-closed: `true` is the `enabled` flag wearing a new name [RT-5]
# and buys nothing).

t_inv2_empty_universe_declared_ok_is_a_legal_skip() {
  local cfg; cfg="$(jq -c '.families.B4.empty_universe_ok="this repo squash-merges and had no landings in the last 30 days"' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 empty-universe.sh
  run_sweep "$r" --cadence push-main --json
  local st reason
  st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  reason="$(jq -r '.checks[] | select(.check_id=="B4") | .skip_reason // ""' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "skipped" && "$reason" == "this repo squash-merges and had no landings in the last 30 days" ]] \
    && pass "B2 exemption: universe 0 + declared empty_universe_ok -> exit 0, status skipped, reason recorded" \
    || fail "B2 exemption: declared empty_universe_ok (ec=$RUN_EC status=$st reason=$reason err=$RUN_ERR)"
}

t_inv2_empty_universe_declared_ok_emits_no_meta_finding() {
  local cfg; cfg="$(jq -c '.families.B4.empty_universe_ok="no landings in the window; this repo is quiet by design"' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 empty-universe.sh
  run_sweep "$r" --cadence push-main
  local f; f="$(findings_of "$r")"
  [[ ! -s "$f" ]] \
    && pass "B2 exemption: a legal empty-universe skip writes no finding — it is not a failure to report" \
    || fail "B2 exemption: legal skip wrote findings ($(cat "$f" 2>/dev/null))"
}

t_inv2_empty_universe_ok_blank_still_exit2() {
  local cfg; cfg="$(jq -c '.families.B4.empty_universe_ok="   "' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 empty-universe.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "B2 exemption: a whitespace-only empty_universe_ok buys nothing -> still exit 2" \
    || fail "B2 exemption: whitespace-only reason still exits 2 (ec=$RUN_EC)"
}

t_inv2_empty_universe_ok_non_string_still_exit2() {
  local cfg; cfg="$(jq -c '.families.B4.empty_universe_ok=true' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 empty-universe.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "B2 exemption: empty_universe_ok: true is not a reason -> still exit 2 [RT-5]" \
    || fail "B2 exemption: non-string empty_universe_ok still exits 2 (ec=$RUN_EC)"
}

t_inv2_empty_universe_ok_does_not_excuse_a_nonempty_universe() {
  local cfg; cfg="$(jq -c '.families.B4.empty_universe_ok="no landings in the window"' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "B2 exemption: declaring empty_universe_ok does not excuse invariant 1 when the universe is not empty" \
    || fail "B2 exemption: empty_universe_ok wrongly excused a vacuous pass (ec=$RUN_EC)"
}

t_inv2_blank_exclusion_reason_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 blank-reason.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "B2: excluded[] entry with a whitespace-only reason -> exit 2" \
    || fail "B2: excluded[] entry with a whitespace-only reason -> exit 2 (ec=$RUN_EC)"
}

# ---- invariant 3: skip legality ----

t_inv3_undeclared_skip_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 undeclared-skip.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "skip legality: status skipped with no skips entry -> exit 2" \
    || fail "skip legality: status skipped with no skips entry -> exit 2 (ec=$RUN_EC)"
}

t_inv3_declared_skip_is_legal() {
  # B4 is both declared and reason-skipped: the config pre-declares why this
  # check may skip itself at runtime, which is exactly what makes the skip legal.
  local cfg; cfg="$(jq -c '.skips += [{"check_id":"B4","reason":"the fixture repo has no CI history to inspect"}]' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 undeclared-skip.sh
  run_sweep "$r" --cadence push-main --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "skipped" ]] \
    && pass "skip legality: status skipped with a reason-carrying skips entry -> exit 0" \
    || fail "skip legality: declared skip is legal (ec=$RUN_EC status=$st err=$RUN_ERR)"
}

# ---- invariant 4: evidence-basis fence (G4) ----

t_inv4_basis_mismatch_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 wrong-basis.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] && grep -q "evidence_basis" <<<"$RUN_OUT$RUN_ERR" \
    && pass "G4: result evidence_basis != job's -> exit 2, fail-closed" \
    || fail "G4: result evidence_basis != job's -> exit 2 (ec=$RUN_EC out=$RUN_OUT err=$RUN_ERR)"
}

t_inv4_no_undeclared_credentials_in_check_env() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 env-probe.sh
  local dump="$r/.claude/sweep/env-dump.txt" leaked=""
  SWEEP_PROD_RO_DSN="postgres://leak" SWEEP_PG_DSN="postgres://leak" \
    DATABASE_URL="postgres://leak" PGPASSWORD="hunter2" SWEEP_LEAK_CANARY="canary" \
    run_sweep "$r" --cadence push-main
  [[ -s "$dump" ]] || { fail "G4: env dump was never produced (the fixture check did not run)"; return; }
  local name
  for name in SWEEP_PROD_RO_DSN SWEEP_PG_DSN DATABASE_URL PGPASSWORD SWEEP_LEAK_CANARY; do
    grep -q "^$name=" "$dump" && leaked="$leaked $name"
  done
  # An allowlist, not a denylist: the check gets PATH and nothing it was not granted.
  grep -q '^PATH=' "$dump" || leaked="$leaked (PATH missing — the allowlist is too narrow to run a check)"
  [[ -z "$leaked" ]] \
    && pass "G4: the check's env carries only what the runner granted — no inherited credential reaches it" \
    || fail "G4: undeclared environment reached the check:$leaked"
}

t_garbage_envelope_is_not_a_pass() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 garbage-scalar.sh
  run_sweep "$r" --cadence push-main --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "error" ]] \
    && pass "a result payload decoding to a JSON scalar -> status error, exit 2 (never a silently dropped check)" \
    || fail "garbage envelope -> error/exit 2 (ec=$RUN_EC status=$st)"
}

t_blank_envelope_is_not_a_pass() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 blank-envelope.sh
  run_sweep "$r" --cadence push-main --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "error" ]] \
    && pass "a result payload decoding to whitespace -> status error, exit 2" \
    || fail "blank envelope -> error/exit 2 (ec=$RUN_EC status=$st)"
}

t_status_outside_enum_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 bad-status.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] && grep -q "status" <<<"$RUN_OUT$RUN_ERR" \
    && pass "a status outside pass|fail|error|skipped -> exit 2, it cannot walk past invariant 1" \
    || fail "status outside the enum -> exit 2 (ec=$RUN_EC out=$RUN_OUT err=$RUN_ERR)"
}

t_every_selected_check_records_one_row() {
  local cfg; cfg="$(jq -c '.surfaces.E1="ui-route" | .families.E1={"app":"apps/web","route_manifest_cmd":"echo /","base_url_env":"SWEEP_BASE_URL","exclusions":[]} | .skips=[]' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"
  install_check "$r" B4 pass-normal.sh; install_check "$r" E1 garbage-scalar.sh
  run_sweep "$r" --cadence push-main --json
  local ids; ids="$(jq -rc '[.checks[].check_id] | sort' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$ids" == '["B4","E1"]' && "$RUN_EC" == "2" ]] \
    && pass "every selected check leaves exactly one result row, even the one that failed to parse" \
    || fail "every selected check records one row (ids=$ids ec=$RUN_EC)"
}

# ---- invariant 5: surface declaration ----

t_inv5_surface_mismatch_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 wrong-surface.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] && grep -q "surface" <<<"$RUN_OUT$RUN_ERR" \
    && pass "surface: result surface != job's -> exit 2, fail-closed" \
    || fail "surface: result surface != job's -> exit 2 (ec=$RUN_EC out=$RUN_OUT err=$RUN_ERR)"
}

# ---- invariant 6: inventory completeness (config validation, exit 3) ----

t_inv6_inventory_gap_exit3_before_running() {
  local cfg; cfg="$(jq -c '.skips=[]' <<<"$CONFIG_B4")"   # E1 in the inventory, neither declared nor skipped
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" && ! -f "$r/.claude/sweep/runs.jsonl" ]] \
    && pass "inventory: an id neither declared nor skipped -> exit 3 before any check runs" \
    || fail "inventory: an id neither declared nor skipped -> exit 3 before running (ec=$RUN_EC runs?=$([ -f "$r/.claude/sweep/runs.jsonl" ] && echo yes || echo no))"
}

t_inv6_unknown_check_id_exit3() {
  local cfg; cfg="$(jq -c '.families.A1={"writer_globs":[],"exclusions":[]} | .surfaces.A1="write-path"' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] && grep -q "A1" <<<"$RUN_OUT$RUN_ERR" \
    && pass "inventory: a family block for an id absent from the inventory -> exit 3" \
    || fail "inventory: unknown check id -> exit 3 (ec=$RUN_EC out=$RUN_OUT err=$RUN_ERR)"
}

t_inv6_blank_skip_reason_exit3() {
  local cfg; cfg="$(jq -c '.skips=[{"check_id":"E1","reason":"  "}]' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] \
    && pass "config: a skips entry with a blank reason -> exit 3" \
    || fail "config: a skips entry with a blank reason -> exit 3 (ec=$RUN_EC)"
}

t_config_missing_surface_exit3() {
  local cfg; cfg="$(jq -c '.surfaces={}' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] \
    && pass "config: a declared check with no surfaces entry -> exit 3" \
    || fail "config: missing surface -> exit 3 (ec=$RUN_EC)"
}

t_config_enabled_key_exit3() {
  local cfg; cfg="$(jq -c '.families.B4={"enabled":false}' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] && grep -q "enabled" <<<"$RUN_OUT$RUN_ERR" \
    && pass "config: an enabled key anywhere -> exit 3 (RT-5, there is no enabled flag)" \
    || fail "config: enabled key -> exit 3 (ec=$RUN_EC out=$RUN_OUT err=$RUN_ERR)"
}

t_config_missing_file_exit3() {
  local r; r="$(mkrepo)"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] \
    && pass "config: no sweep.config.json -> exit 3" \
    || fail "config: no sweep.config.json -> exit 3 (ec=$RUN_EC)"
}

t_config_wrong_schema_tag_exit3() {
  local cfg; cfg="$(jq -c '.schema="sweep-config/v2"' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] \
    && pass "config: wrong schema tag -> exit 3" \
    || fail "config: wrong schema tag -> exit 3 (ec=$RUN_EC)"
}

# The structural half of validation is delegated to schemas/sweep-config.json
# (via the emit library's schema-driven checker), so these two cases prove the
# delegation still catches what the bespoke code used to.
t_config_missing_required_key_exit3() {
  local cfg; cfg="$(jq -c 'del(.check_modes)' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] && grep -q "check_modes" <<<"$RUN_ERR" \
    && pass "config: a missing required top-level key -> exit 3 (from the schema, not a second copy of it)" \
    || fail "config: missing required key -> exit 3 (ec=$RUN_EC err=$RUN_ERR)"
}

t_config_unknown_top_level_key_exit3() {
  local cfg; cfg="$(jq -c '.connections={}' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "3" ]] && grep -q "connections" <<<"$RUN_ERR" \
    && pass "config: a key the phase-1 schema does not declare -> exit 3 (scope discipline, S5.3)" \
    || fail "config: unknown top-level key -> exit 3 (ec=$RUN_EC err=$RUN_ERR)"
}

t_declared_check_with_no_executable_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"   # B4 declared, nothing installed
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] && grep -Fq "$SENTENCE_TAIL" <<<"$RUN_OUT$RUN_ERR" \
    && pass "a declared check with no executable -> exit 2 with the plain sentence" \
    || fail "a declared check with no executable -> exit 2 (ec=$RUN_EC)"
}

# ---- fail-closed parsing ----

t_no_result_line_is_error_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 no-result-line.sh
  run_sweep "$r" --cadence push-main --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "error" ]] \
    && pass "non-zero exit with no result line -> status error, exit 2, fail-closed" \
    || fail "non-zero exit with no result line -> error/exit 2 (ec=$RUN_EC status=$st)"
}

t_self_reported_error_exit2() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 self-error.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "2" ]] \
    && pass "a check reporting status error -> exit 2, its result is not evidence" \
    || fail "a check reporting status error -> exit 2 (ec=$RUN_EC)"
}

t_emit_refusal_is_not_bypassed() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-refused.sh
  run_sweep "$r" --cadence push-main
  local f; f="$(findings_of "$r")"
  local n; n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
  [[ "$RUN_EC" == "2" && ( ! -s "$f" || "$n" == "0" ) ]] \
    && pass "an emit refusal is structural: nothing is written and the run exits 2" \
    || fail "emit refusal is not bypassed (ec=$RUN_EC rows=$n)"
}

# ---- single-writer cadence rule (S4.3) ----

t_cadence_pr_never_writes_findings() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  local f; f="$(findings_of "$r")"
  printf '%s\n' '{"sentinel":"pre-existing row"}' > "$f"
  local before_sum before_mt; before_sum="$(shasum "$f" | awk '{print $1}')"; before_mt="$(mtime_of "$f")"
  sleep 1
  run_sweep "$r" --cadence pr --json
  local after_sum after_mt n; after_sum="$(shasum "$f" | awk '{print $1}')"; after_mt="$(mtime_of "$f")"
  n="$(jq -r '.findings_n' <<<"$RUN_OUT" 2>/dev/null)"   # the check really did find something
  [[ "$n" == "1" && "$before_sum" == "$after_sum" && "$before_mt" == "$after_mt" ]] \
    && pass "cadence pr: a finding-producing check leaves findings.jsonl untouched (content + mtime)" \
    || fail "cadence pr leaves findings.jsonl untouched (sum $before_sum->$after_sum mt $before_mt->$after_mt)"
}

t_cadence_push_main_appends_finding() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main
  local f; f="$(findings_of "$r")"
  local n ident has_status fid
  n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
  ident="$(jq -r '.identity_key' < "$f" 2>/dev/null)"
  has_status="$(jq -r 'has("status")' < "$f" 2>/dev/null)"
  fid="$(jq -r '.finding_id' < "$f" 2>/dev/null)"
  [[ "$n" == "1" && "$ident" == "products" && "$has_status" == "false" && "$fid" =~ ^[0-9a-f]{16}$ ]] \
    && pass "cadence push-main: the finding is appended, id-stamped, and carries no status" \
    || fail "cadence push-main appends the finding (n=$n ident=$ident status?=$has_status fid=$fid)"
}

t_cadence_nightly_and_session_close_write() {
  local ok=1 c
  for c in nightly session-close; do
    local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
    run_sweep "$r" --cadence "$c"
    [[ -s "$(findings_of "$r")" ]] || ok=0
  done
  [[ "$ok" == "1" ]] \
    && pass "cadences nightly and session-close write findings.jsonl" \
    || fail "cadences nightly and session-close write findings.jsonl"
}

t_cadence_diff_and_manual_render_only() {
  local ok=1 c
  for c in diff manual; do
    local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
    run_sweep "$r" --cadence "$c" --json
    [[ -f "$(findings_of "$r")" ]] && ok=0
    [[ "$(jq -r '.findings_n' <<<"$RUN_OUT" 2>/dev/null)" == "1" ]] || ok=0
  done
  [[ "$ok" == "1" ]] \
    && pass "cadences diff and manual render only — findings.jsonl is never created" \
    || fail "cadences diff and manual render only"
}

t_runs_jsonl_written_on_every_cadence() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence pr
  local runs="$r/.claude/sweep/runs.jsonl"
  local cid; cid="$(jq -r '.checks[0].check_id' < "$runs" 2>/dev/null)"
  [[ -s "$runs" && "$cid" == "E1" ]] \
    && pass "telemetry: runs.jsonl is written even on a non-writing cadence" \
    || fail "telemetry: runs.jsonl written on cadence pr (cid=$cid)"
}

# ---- locus normalization + identity ----

t_locus_normalized_before_hashing() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main
  local f; f="$(findings_of "$r")"
  local locus fid expect
  locus="$(jq -r '.evidence.locus' < "$f" 2>/dev/null)"
  fid="$(jq -r '.finding_id' < "$f" 2>/dev/null)"
  expect="$(sweep_finding_id "$(basename "$r")" "E1" "DISCONNECTED" "apps/web/src/lib/filter-params.ts" "products")"
  [[ "$locus" == "apps/web/src/lib/filter-params.ts:88" && "$fid" == "$expect" ]] \
    && pass "locus: recorded repo-relative with :LINE, hashed repo-relative without it" \
    || fail "locus normalization (locus=$locus fid=$fid expect=$expect)"
}

# ---- mode gating (exit 1) ----

t_observe_mode_findings_exit0() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main
  local n; n="$(wc -l < "$(findings_of "$r")" 2>/dev/null | tr -d ' ')"
  [[ "$RUN_EC" == "0" && "$n" == "1" ]] \
    && pass "observe mode: findings recorded, nothing blocking -> exit 0" \
    || fail "observe mode -> exit 0 with the row recorded (ec=$RUN_EC rows=$n err=$RUN_ERR)"
}

t_block_mode_findings_exit1() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main --mode block
  [[ "$RUN_EC" == "1" ]] \
    && pass "block mode: a finding -> exit 1" \
    || fail "block mode -> exit 1 (ec=$RUN_EC)"
}

t_check_mode_override_exit1() {
  local cfg; cfg="$(jq -c '.check_modes={"E1":"block"}' <<<"$CONFIG_E1")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main
  [[ "$RUN_EC" == "1" ]] \
    && pass "check_modes: a per-check block override -> exit 1" \
    || fail "check_modes override -> exit 1 (ec=$RUN_EC)"
}

t_clean_run_exit0() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main --mode block --json
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "pass" && ! -f "$(findings_of "$r")" ]] \
    && pass "a healthy check in block mode -> exit 0 and no findings row" \
    || fail "healthy check -> exit 0 (ec=$RUN_EC status=$st err=$RUN_ERR)"
}

# ---- CLI surface (spec S5.4) ----

t_bad_cadence_exit3() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence weekly
  [[ "$RUN_EC" == "3" ]] \
    && pass "CLI: an unknown cadence -> exit 3" \
    || fail "CLI: unknown cadence -> exit 3 (ec=$RUN_EC)"
}

t_families_filter_selects_subset() {
  local cfg; cfg="$(jq -c '.surfaces.E1="ui-route" | .families.E1={"app":"apps/web","route_manifest_cmd":"echo /","base_url_env":"SWEEP_BASE_URL","exclusions":[]} | .skips=[]' <<<"$CONFIG_B4")"
  local r; r="$(mkrepo)"; write_config "$r" "$cfg"
  install_check "$r" B4 pass-normal.sh; install_check "$r" E1 pass-normal.sh
  run_sweep "$r" --cadence pr --families B4 --json
  local ids; ids="$(jq -rc '[.checks[].check_id]' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$ids" == '["B4"]' ]] \
    && pass "CLI: --families restricts the run to the named checks" \
    || fail "CLI: --families restricts the run (ids=$ids)"
}

t_families_unknown_id_exit3() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence pr --families E1        # E1 is reason-skipped, so it selects nothing
  [[ "$RUN_EC" == "3" ]] && grep -q "E1" <<<"$RUN_ERR" \
    && pass "CLI: --families naming a check this repo does not declare -> exit 3, never a green empty run" \
    || fail "CLI: --families naming an unselected check -> exit 3 (ec=$RUN_EC err=$RUN_ERR)"
}

t_plain_flag_prints_the_finding_sentence() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 finds-one.sh
  run_sweep "$r" --cadence push-main --plain
  grep -Fq "The dashboard filter sends a name the page never looks for" <<<"$RUN_OUT" \
    && pass "CLI: --plain prints each finding's plain sentence" \
    || fail "CLI: --plain prints the plain sentence (out=$RUN_OUT)"
}

t_json_flag_is_valid_json() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_B4"; install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence pr --json
  local cadence; cadence="$(jq -r '.cadence' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$cadence" == "pr" ]] \
    && pass "CLI: --json emits a parseable run summary" \
    || fail "CLI: --json emits parseable JSON (out=$RUN_OUT)"
}

# ---- the job contract (spec S5.1) ----

t_job_envelope_shape() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 job-dump.sh
  run_sweep "$r" --cadence pr
  local job; job="$(cat "$r/.claude/sweep/job-dump.json" 2>/dev/null)"
  local shape; shape="$(jq -rc '[.schema,.check_id,.cadence,(.writes_findings|tostring),.evidence_basis,.surface,(.connection|tostring),(.changed_paths|tostring),(.config.app)]' <<<"$job" 2>/dev/null)"
  [[ "$shape" == '["sweep-job/v1","E1","pr","false","static-source","ui-route","null","null","apps/web"]' ]] \
    && pass "job: sweep-job/v1 shape — cadence, writes_findings, basis, surface, null connection, family block" \
    || fail "job envelope shape (got: $shape)"
}

t_job_writes_findings_true_on_push_main() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 job-dump.sh
  run_sweep "$r" --cadence push-main
  local w; w="$(jq -r '.writes_findings' < "$r/.claude/sweep/job-dump.json" 2>/dev/null)"
  [[ "$w" == "true" ]] \
    && pass "job: writes_findings is true on push-main" \
    || fail "job: writes_findings true on push-main (got: $w)"
}

t_job_changed_paths_from_sha() {
  local r; r="$(mkrepo)"; write_config "$r" "$CONFIG_E1"; install_check "$r" E1 job-dump.sh
  git -C "$r" init -q 2>/dev/null
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  echo one > "$r/a.txt"; git -C "$r" add -A >/dev/null; git -C "$r" commit -qm one >/dev/null
  local base; base="$(git -C "$r" rev-parse HEAD)"
  echo two > "$r/b.txt"; git -C "$r" add -A >/dev/null; git -C "$r" commit -qm two >/dev/null
  run_sweep "$r" --cadence diff --changed-from "$base"
  local paths; paths="$(jq -rc '.changed_paths' < "$r/.claude/sweep/job-dump.json" 2>/dev/null)"
  [[ "$paths" == '["b.txt"]' ]] \
    && pass "job: --changed-from fills changed_paths from the diff" \
    || fail "job: --changed-from fills changed_paths (got: $paths)"
}

# ---- the shipped inventory ----

t_inventory_is_phase_one() {
  # B4/E1 are the phase-1 exit criteria pin; PC1 (2026-08-18 new-user-setup-rev2
  # plan, task 6) is outside phase 1-3's A-G family lettering entirely — a
  # standalone check added on top, not a phase-1 addition — so it is asserted
  # here as a third, explicitly-named line rather than silently widening the
  # phase-1 pin to "whatever inventory.txt happens to contain".
  local content; content="$(grep -v '^[[:space:]]*$' "$INVENTORY" 2>/dev/null | grep -v '^#' | tr -d ' ')"
  # Phase 2 appended A1/A2/A4 per the inventory's own header; ADR-082
  # doctrine v2 P1a appended A5; PC1 (task 6) is the standalone add on top;
  # each id must have an executable check script, and the set is pinned
  # exactly.
  [[ "$content" == "$(printf 'B4\nE1\nA1\nA2\nA4\nA5\nPC1')" ]] \
    && pass "inventory.txt ships exactly the phase-1 + phase-2 + A5 + PC1 check ids" \
    || fail "inventory.txt ships exactly B4/E1/A1/A2/A4/A5/PC1 (got: $content)"
}

t_inventory_never_lists_b6() {
  grep -q '^B6' "$INVENTORY" 2>/dev/null \
    && fail "inventory.txt must never list B6 (reserved for roster-keeper-liveness, synthesis RD6)" \
    || pass "inventory.txt does not list B6 (reserved, synthesis RD6)"
}

# ---- PC1 dispatch (controller ruling, task-6 review) ----
#
# The review found PC1 in the shared inventory with no legal way for a repo
# to declare it (schemas/sweep-config.json's families block rejected any
# families.PC1 key at all). Fixed in schemas/sweep-config.json; this proves
# the runner actually DISPATCHES a declared PC1 the same as any other
# check, using a throwaway inventory/config scoped to this test only — it
# does not touch mkrepo()'s shared B4/E1 fixture, which every other test
# in this file depends on staying a two-check inventory.
CONFIG_PC1='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"PC1":"docs"},"families":{"PC1":{}},"skips":[]}'

mkrepo_pc1() {
  local d; d="$(mktemp -d "$TMP/repo-pc1.XXXXXX")"
  mkdir -p "$d/.claude/sweep" "$d/checks"
  printf 'PC1\n' > "$d/inventory.txt"
  cp "$FIXTURES/_envelope.sh" "$d/checks/_envelope.sh"
  echo "$d"
}

t_pc1_dispatches_and_passes() {
  local r; r="$(mkrepo_pc1)"; write_config "$r" "$CONFIG_PC1"; install_check "$r" PC1 pass-normal.sh
  run_sweep "$r" --cadence manual --json
  local st surf basis; st="$(jq -r '.checks[] | select(.check_id=="PC1") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "pass" ]] \
    && pass "PC1: a repo that declares families.PC1={} dispatches it and gets a clean run" \
    || fail "PC1: dispatch + clean run (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

t_large_envelope_survives_ingestion
t_inv1_vacuous_exit2_and_meta_finding
t_inv1_plain_sentence_verbatim
t_inv1_vacuous_status_rewritten_to_fail
t_inv1_vacuous_on_pr_exits_2_without_writing

t_inv2_empty_universe_exit2
t_inv2_empty_universe_declared_ok_is_a_legal_skip
t_inv2_empty_universe_declared_ok_emits_no_meta_finding
t_inv2_empty_universe_ok_blank_still_exit2
t_inv2_empty_universe_ok_non_string_still_exit2
t_inv2_empty_universe_ok_does_not_excuse_a_nonempty_universe
t_inv2_blank_exclusion_reason_exit2

t_inv3_undeclared_skip_exit2
t_inv3_declared_skip_is_legal

t_inv4_basis_mismatch_exit2
t_inv4_no_undeclared_credentials_in_check_env
t_garbage_envelope_is_not_a_pass
t_blank_envelope_is_not_a_pass
t_status_outside_enum_exit2
t_every_selected_check_records_one_row

t_inv5_surface_mismatch_exit2

t_inv6_inventory_gap_exit3_before_running
t_inv6_unknown_check_id_exit3
t_inv6_blank_skip_reason_exit3
t_config_missing_surface_exit3
t_config_enabled_key_exit3
t_config_missing_file_exit3
t_config_wrong_schema_tag_exit3
t_config_missing_required_key_exit3
t_config_unknown_top_level_key_exit3
t_declared_check_with_no_executable_exit2

t_no_result_line_is_error_exit2
t_self_reported_error_exit2
t_emit_refusal_is_not_bypassed

t_cadence_pr_never_writes_findings
t_cadence_push_main_appends_finding
t_cadence_nightly_and_session_close_write
t_cadence_diff_and_manual_render_only
t_runs_jsonl_written_on_every_cadence

t_locus_normalized_before_hashing

t_observe_mode_findings_exit0
t_block_mode_findings_exit1
t_check_mode_override_exit1
t_clean_run_exit0

t_bad_cadence_exit3
t_families_filter_selects_subset
t_families_unknown_id_exit3
t_plain_flag_prints_the_finding_sentence
t_json_flag_is_valid_json

t_job_envelope_shape
t_job_writes_findings_true_on_push_main
t_job_changed_paths_from_sha

t_inventory_is_phase_one
t_inventory_never_lists_b6
t_pc1_dispatches_and_passes

echo "----"
echo "test-sweep-runner: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
