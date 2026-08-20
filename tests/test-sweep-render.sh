#!/usr/bin/env bash
# Tests for scripts/sweep/sweep-render.sh (stack ADR-078, task 5 of the
# Sweep serial spine). This is the only place the render sentence is
# assembled, so its two paths each get their own coverage:
#   - the RUN-BACKED path (--run <id> matches a runs.jsonl row): N/M come
#     from that run's real checks[].universe_size, grouped by
#     sweep.config.json's surfaces map, and the output is the G7 fixed
#     acceptance format. The critical case here is a clean universe — a
#     run that checked units with zero findings must still report their
#     real N/M, not 0 (findings.jsonl alone can't prove that).
#   - the FALLBACK path (no --run, or the run isn't in runs.jsonl): N/M
#     are the count of distinct units that have EVER been flagged, in
#     honest (non-"Checked") wording pinned exactly by test.
# Both paths' K/plain-sentence assembly and no-leak guarantee (same
# regexes as Task 3's R3 refusal) are shared and each get their own
# assertion rather than one combined smoke test.
#
# sweep_render and sweep_resolve_status are sourced directly (not shelled
# out to), matching lib/sweep-emit.sh's sourced-library test convention.
# sweep-emit.sh's sweep_emit_finding is reused to write every fixture row
# — it is the only place findings.jsonl is written, in tests as much as
# in the runner. runs.jsonl and sweep.config.json fixture rows are
# written directly (read-only interfaces this library reads, not ones it
# writes — matching test-sweep-runner.sh's write_config precedent).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_LIB="$REPO_ROOT/scripts/sweep/sweep-render.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$EMIT_LIB" ] || { echo "FATAL: $EMIT_LIB not found"; exit 1; }
[ -f "$RENDER_LIB" ] || { echo "FATAL: $RENDER_LIB not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"
# shellcheck source=/dev/null
source "$RENDER_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-render-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A well-formed sweep-family-E record (ui-route). Field values match
# tests/test-sweep-emit.sh's BASE_RECORD shape.
BASE_RECORD='{"schema":"finding-record/v1","finding_id":"e1e1e1e1e1e1e1e1","identity_key":"/dashboard","run_id":"2026-08-16T02:00:00Z.a1b2c3","repo":"manufacturing-dashboard","created_at":"2026-08-16T02:00:04Z","what":"page.tsx throws a client render error on hydrate","plain":"The dashboard screen breaks for some users right after it loads.","mechanism":"NEVER RAN","surface":"ui-route","surface_source":"declared","found_by":"sweep-family-E","evidence":{"commit":"73c23b53","locus":"apps/web/src/app/dashboard/page.tsx:1","measurement":{"statement":"routes that threw on load","count":1,"denominator":41,"source":"static-source"}},"liveness":{"assertions_executed":41,"assertions_passed":40},"responsible_agent":null,"roster_action":null}'

record() { echo "$BASE_RECORD" | jq -c "$1"; }  # record '<jq filter>' -> modified compact record

# mkrepo -> echoes a throwaway repo dir carrying its own .claude/sweep
mkrepo() {
  local d; d="$(mktemp -d "$TMP/repo.XXXXXX")"
  mkdir -p "$d/.claude/sweep"
  echo "$d"
}

findings_of() { echo "$1/.claude/sweep/findings.jsonl"; }
runs_of() { echo "$1/.claude/sweep/runs.jsonl"; }

# write_config <repo> <json> -- sweep.config.json is read-only from this
# library's point of view; tests write it directly rather than through
# sweep-config.sh, matching test-sweep-runner.sh's write_config.
write_config() { jq . <<<"$2" > "$1/.claude/sweep.config.json"; }

# write_runs_row <repo> <json> -- runs.jsonl is read-only from this
# library's point of view (the runner's write_run_row is the only
# writer); tests append a fixture row directly.
write_runs_row() { jq -c . <<<"$2" >> "$(runs_of "$1")"; }

# ---- sweep_render: fallback path, zero-findings case ----

t_zero_findings_missing_file() {
  local r; r="$(mkrepo)"
  local out; out="$(sweep_render "$r")"
  [[ "$out" == "0 screens and 0 background jobs have a finding on record. Found nothing worth your attention. Nothing else changed." ]] \
    && pass "sweep_render: missing findings.jsonl renders the fallback zero-findings sentence" \
    || fail "sweep_render: missing findings.jsonl renders the fallback zero-findings sentence (got: $out)"
}

t_zero_findings_all_dispositioned() {
  local r; r="$(mkrepo)"; local f; f="$(findings_of "$r")"
  local rec; rec="$(record '.surface="ci-gate"')"
  sweep_emit_finding "$f" "$rec"
  local disp; disp="$(echo "$rec" | jq -c '.found_by="human-walkthrough" | .status="wontfix"')"
  sweep_emit_finding "$f" "$disp"
  local out; out="$(sweep_render "$r")"
  [[ "$out" == "0 screens and 1 background jobs have a finding on record. Found nothing worth your attention. Nothing else changed." ]] \
    && pass "sweep_render: all findings dispositioned away renders the fallback zero-findings sentence with real N/M" \
    || fail "sweep_render: all findings dispositioned away renders the fallback zero-findings sentence with real N/M (got: $out)"
}

t_fallback_wording_pinned_exactly() {
  # Named regression: the fallback path must never say "Checked" — that
  # phrasing is reserved for the run-backed path, where N/M are a real
  # coverage count rather than a count of ever-flagged units.
  local r; r="$(mkrepo)"; local f; f="$(findings_of "$r")"
  sweep_emit_finding "$f" "$BASE_RECORD"
  local out; out="$(sweep_render "$r")"
  [[ "$out" == "1 screens and 0 background jobs have a finding on record. Found 1 things worth your attention: The dashboard screen breaks for some users right after it loads. Nothing else changed." ]] \
    && pass "sweep_render: fallback wording is pinned exactly and never claims \"Checked\"" \
    || fail "sweep_render: fallback wording is pinned exactly and never claims \"Checked\" (got: $out)"
}

# ---- sweep_render: the 2-open / 1-wontfix fixture ----

# Three findings: one ui-route, one ci-gate (both left open), one
# scheduled-job later dispositioned wontfix by a human row with the same
# finding_id — exercising sweep_resolve_status's newest-row-wins rule.
seed_three_finding_fixture() {
  local r="$1" f; f="$(findings_of "$r")"

  local rec1; rec1="$(record '.finding_id="e1e1e1e1e1e1e1e1" | .identity_key="/dashboard" | .surface="ui-route" | .found_by="sweep-family-E" | .plain="The dashboard screen breaks for some users right after it loads."')"
  sweep_emit_finding "$f" "$rec1"

  local rec2; rec2="$(record '.finding_id="c2c2c2c2c2c2c2c2" | .identity_key="merge-run" | .surface="ci-gate" | .found_by="sweep-family-B" | .plain="The checks that block a bad merge did not actually run this week."')"
  sweep_emit_finding "$f" "$rec2"

  local rec3; rec3="$(record '.finding_id="d3d3d3d3d3d3d3d3" | .identity_key="nightly-sync" | .surface="scheduled-job" | .found_by="sweep-family-D" | .plain="The nightly sync job silently failed and nobody was told."')"
  sweep_emit_finding "$f" "$rec3"

  local disp3; disp3="$(echo "$rec3" | jq -c '.found_by="human-walkthrough" | .status="wontfix"')"
  sweep_emit_finding "$f" "$disp3"
}

t_two_open_renders_both_plain_sentences_and_counts() {
  local r; r="$(mkrepo)"
  seed_three_finding_fixture "$r"
  local out; out="$(sweep_render "$r")"
  # sweep_resolve_status groups by finding_id (group_by sorts the key), so
  # the sentence order here is finding_id order: c2c2... before e1e1....
  # No runs.jsonl in this repo, so this is the fallback path.
  local expect="1 screens and 2 background jobs have a finding on record. Found 2 things worth your attention: The checks that block a bad merge did not actually run this week. The dashboard screen breaks for some users right after it loads. Nothing else changed."
  [[ "$out" == "$expect" ]] \
    && pass "sweep_render: 2 open findings render both plain sentences and correct N/M/K" \
    || fail "sweep_render: 2 open findings render both plain sentences and correct N/M/K (got: $out)"
}

t_wontfix_disposition_excluded_from_k() {
  local r; r="$(mkrepo)"
  seed_three_finding_fixture "$r"
  local out; out="$(sweep_render "$r")"
  [[ "$out" != *"nightly sync"* ]] \
    && pass "sweep_render: disposition-resolved wontfix finding excluded from K" \
    || fail "sweep_render: disposition-resolved wontfix finding excluded from K (got: $out)"
}

t_no_check_ids_no_family_letters_no_file_paths() {
  local r; r="$(mkrepo)"
  seed_three_finding_fixture "$r"
  local out; out="$(sweep_render "$r")"
  ! grep -Eq '\.(ts|tsx|js|mjs|sh|py)\b' <<<"$out" \
    && ! grep -Eq '\b[A-G][0-9]\b' <<<"$out" \
    && pass "sweep_render: output leaks no check ids, family letters, or file paths" \
    || fail "sweep_render: output leaks no check ids, family letters, or file paths (got: $out)"
}

# ---- sweep_resolve_status: newest-row-wins directly ----

t_resolve_status_defaults_open() {
  local r; r="$(mkrepo)"; local f; f="$(findings_of "$r")"
  sweep_emit_finding "$f" "$BASE_RECORD"
  local status; status="$(sweep_resolve_status "$f" | jq -r '.status')"
  [[ "$status" == "open" ]] \
    && pass "sweep_resolve_status: defaults to open when no row carries status" \
    || fail "sweep_resolve_status: defaults to open when no row carries status (got: $status)"
}

t_resolve_status_newest_disposition_wins() {
  local r; r="$(mkrepo)"; local f; f="$(findings_of "$r")"
  sweep_emit_finding "$f" "$BASE_RECORD"
  local disp1; disp1="$(record '.found_by="human-walkthrough" | .status="fixed"')"
  sweep_emit_finding "$f" "$disp1"
  local disp2; disp2="$(record '.found_by="human-walkthrough" | .status="wontfix"')"
  sweep_emit_finding "$f" "$disp2"
  local status; status="$(sweep_resolve_status "$f" | jq -r '.status')"
  [[ "$status" == "wontfix" ]] \
    && pass "sweep_resolve_status: newest disposition row's status wins" \
    || fail "sweep_resolve_status: newest disposition row's status wins (got: $status)"
}

t_resolve_status_one_line_per_finding_id() {
  local r; r="$(mkrepo)"; local f; f="$(findings_of "$r")"
  sweep_emit_finding "$f" "$BASE_RECORD"
  sweep_emit_finding "$f" "$(record '.found_by="human-walkthrough" | .status="fixed"')"
  local n; n="$(sweep_resolve_status "$f" | jq -s 'length')"
  [[ "$n" == "1" ]] \
    && pass "sweep_resolve_status: one resolved row per distinct finding_id" \
    || fail "sweep_resolve_status: one resolved row per distinct finding_id (got: $n)"
}

# ---- sweep_render: --run scoping ----

t_run_scoping_excludes_other_runs() {
  local r; r="$(mkrepo)"
  seed_three_finding_fixture "$r"
  local rec_other; rec_other="$(record '.finding_id="f4f4f4f4f4f4f4f4" | .identity_key="/settings" | .surface="ui-route" | .found_by="sweep-family-E" | .run_id="2026-08-17T02:00:00Z.z9y8x7" | .plain="The settings screen never saves a change you make there."')"
  sweep_emit_finding "$(findings_of "$r")" "$rec_other"
  local out; out="$(sweep_render "$r" --run "2026-08-16T02:00:00Z.a1b2c3")"
  [[ "$out" != *"settings screen"* ]] \
    && pass "sweep_render --run: excludes findings first seen in a different run" \
    || fail "sweep_render --run: excludes findings first seen in a different run (got: $out)"
}

# ---- sweep_render: run-backed path (real universe coverage) ----

RUN_ID="2026-08-16T02:00:00Z.a1b2c3"  # matches BASE_RECORD's run_id

# seed_run_row <repo> <e1_universe> <b4_universe> -- a runs.jsonl row for
# RUN_ID plus a matching sweep.config.json surfaces map (E1 -> ui-route,
# B4 -> ci-gate), the two read-only inputs the run-backed path joins on.
seed_run_row() {
  local r="$1" e1_universe="$2" b4_universe="$3"
  write_config "$r" '{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"E1":"ui-route","B4":"ci-gate"},"families":{"E1":{},"B4":{}}}'
  write_runs_row "$r" "$(jq -nc --arg run "$RUN_ID" --argjson e1u "$e1_universe" --argjson b4u "$b4_universe" '
    {schema:"sweep-run/v1", run_id:$run, repo:"manufacturing-dashboard", cadence:"push-main",
     mode:"observe", started_at:"2026-08-16T02:00:00Z", writes_findings:true, exit_code:0,
     checks:[
       {check_id:"E1", status:"pass", universe_size:$e1u, assertions_executed:$e1u, assertions_passed:$e1u, duration_ms:100, findings_n:0, violation:null},
       {check_id:"B4", status:"pass", universe_size:$b4u, assertions_executed:$b4u, assertions_passed:$b4u, duration_ms:50, findings_n:0, violation:null}
     ]}')"
}

t_run_backed_clean_universe_not_undercounted() {
  # THE regression this fix closes: E1 checked 5 routes and B4 checked 3
  # jobs, all clean (zero findings). The old findings-only computation
  # would have rendered "Checked 0 screens and 0 background jobs" here —
  # the universe-derived path must report the real 5/3 instead.
  local r; r="$(mkrepo)"
  seed_run_row "$r" 5 3
  local out; out="$(sweep_render "$r" --run "$RUN_ID")"
  [[ "$out" == "Checked 5 screens and 3 background jobs. Found nothing worth your attention. Nothing else changed." ]] \
    && pass "sweep_render --run: a clean checked universe renders its real N/M, not the flagged-unit undercount" \
    || fail "sweep_render --run: a clean checked universe renders its real N/M, not the flagged-unit undercount (got: $out)"
}

t_run_backed_open_finding_uses_universe_count_not_flagged_count() {
  # One open E1 finding (1 flagged unit) inside a 5-route universe: N
  # must be the real 5, not the 1 that happened to produce a finding.
  local r; r="$(mkrepo)"
  seed_run_row "$r" 5 3
  sweep_emit_finding "$(findings_of "$r")" "$BASE_RECORD"
  local out; out="$(sweep_render "$r" --run "$RUN_ID")"
  local expect="Checked 5 screens and 3 background jobs. Found 1 things worth your attention: The dashboard screen breaks for some users right after it loads. Nothing else changed."
  [[ "$out" == "$expect" ]] \
    && pass "sweep_render --run: N is the run's real universe, not the count of flagged units" \
    || fail "sweep_render --run: N is the run's real universe, not the count of flagged units (got: $out)"
}

t_run_backed_falls_back_when_run_id_not_in_runs_jsonl() {
  local r; r="$(mkrepo)"
  seed_run_row "$r" 5 3
  sweep_emit_finding "$(findings_of "$r")" "$BASE_RECORD"
  local out; out="$(sweep_render "$r" --run "some-other-run-id-not-in-runs-jsonl")"
  [[ "$out" == *"have a finding on record"* && "$out" != "Checked"* ]] \
    && pass "sweep_render --run: falls back to findings-derived wording when the run isn't in runs.jsonl" \
    || fail "sweep_render --run: falls back to findings-derived wording when the run isn't in runs.jsonl (got: $out)"
}

t_zero_findings_missing_file
t_zero_findings_all_dispositioned
t_fallback_wording_pinned_exactly
t_two_open_renders_both_plain_sentences_and_counts
t_wontfix_disposition_excluded_from_k
t_no_check_ids_no_family_letters_no_file_paths
t_resolve_status_defaults_open
t_resolve_status_newest_disposition_wins
t_resolve_status_one_line_per_finding_id
t_run_scoping_excludes_other_runs
t_run_backed_clean_universe_not_undercounted
t_run_backed_open_finding_uses_universe_count_not_flagged_count
t_run_backed_falls_back_when_run_id_not_in_runs_jsonl

echo "----"
echo "test-sweep-render: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
