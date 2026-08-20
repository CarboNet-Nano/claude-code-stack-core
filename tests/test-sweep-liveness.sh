#!/usr/bin/env bash
# Tests for scripts/sweep/sweep-liveness.sh (stack ADR-078, task 8 of the
# Sweep serial spine). B5: does a `sweep.yml` run exist for a given head
# sha, concluded, and did it produce evidence for every check id in the
# installed inventory (scripts/sweep/inventory.txt) minus the repo's
# reason-carrying skips?
#
# The script is invoked directly with a real, throwaway git repo (an
# origin remote is needed for owner_repo() to parse) and a faked `gh` on
# PATH — the mkfakegh pattern from tests/test-sweep-b4.sh, extended with a
# second faked subcommand (`gh run view <id> --log`) for the log-based
# artifact contract this script documents in its own header. Every call is
# logged to FAKE_GH_CALL_LOG so the endpoint/args gh was actually invoked
# with are provable, not assumed.
#
# Fix round 1: the artifact contract moved from scraping render_default()
# prose to reading the runner's frozen `--json` output
# (`{"schema":"sweep-run/v1", ..., "checks":[...]}`). Log fixtures below
# use `sweep_run_json` to build that exact shape and `ci_log_line` to wrap
# it in the `<job>\t<step>\t<timestamp> ` prefix CONFIRMED against a live
# run (gh run view 31877453757 --log) — every real CI log line carries
# it. `t_raw_json_line_without_prefix` is the one deliberately-unprefixed
# case, proving the parser accepts a local/non-CI log too.
#
# Test isolation uses SWEEP_INVENTORY_FILE (an existing test seam,
# scripts/sweep/lib/sweep-config.sh) so these tests never depend on the
# real inventory's contents drifting under them.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sweep/sweep-liveness.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-liveness-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ---- fixtures ---------------------------------------------------------

# INVENTORY: a two-check inventory (B4, E1), isolated from the real
# scripts/sweep/inventory.txt via SWEEP_INVENTORY_FILE.
INVENTORY="$TMP/inventory.txt"
printf 'B4\nE1\n' > "$INVENTORY"

# new_repo <name> -> a real throwaway repo on `main` with a GitHub-shaped
# origin (owner_repo() needs a remote to parse) and an empty
# .claude/sweep.config.json unless populated by the caller.
new_repo() {
  local r="$TMP/repo-$1"
  mkdir -p "$r/.claude"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" \
      && git remote add origin "https://github.com/example/$1.git" )
  echo '{}' > "$r/.claude/sweep.config.json"
  git -C "$r" rev-parse --show-toplevel
}

write_config() {
  local repo="$1" json="$2"
  printf '%s' "$json" > "$repo/.claude/sweep.config.json"
}

# sweep_run_json <check-id>... -> one compact sweep-run/v1 JSON line — the
# real shape sweep-run.sh's render_json() emits under `--json`, with
# .checks[].check_id set from the given ids (zero ids -> an empty
# checks[] array, the "nothing dispatched" case).
sweep_run_json() {
  jq -cn --args '{schema:"sweep-run/v1", run_id:"2026-08-15T00:00:00Z.test01", repo:"test",
    cadence:"push-main", mode:"observe", writes_findings:true, exit_code:0, findings_n:0,
    sentence:null, checks:[$ARGS.positional[] | {check_id:., status:"pass", universe_size:1,
    assertions_executed:1, assertions_passed:1, duration_ms:1, findings_n:0, violation:null}]}' "$@"
}

# ci_log_line <content> -> <content> prefixed with a realistic GitHub
# Actions combined-log prefix (`<job>\t<step>\t<timestamp> `), CONFIRMED
# live (gh run view 31877453757 --log) — every fixture below that
# represents a real CI run log uses this.
ci_log_line() {
  printf 'sweep\trun-sweep\t2026-08-15T09:37:18.9734703Z %s\n' "$1"
}

# mkfakegh <name> -> path to a bin dir carrying a stateful fake `gh`
# supporting two subcommands: `gh api <endpoint> -f head_sha=<sha> --jq
# <filter>` (reads FAKE_GH_RUNS_STATE, a JSON array of workflow-run
# objects, filters by head_sha, wraps as {workflow_runs:[...]}, applies
# the requested --jq filter) and `gh run view <id> --repo <owner/repo>
# --log` (cats FAKE_GH_LOG_DIR/<id>.log). Every call's full argv is logged
# to FAKE_GH_CALL_LOG when set.
mkfakegh() {
  local dir="$TMP/fakegh-$1"; mkdir -p "$dir"
  cat > "$dir/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -uo pipefail
[[ -n "${FAKE_GH_CALL_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_GH_CALL_LOG"
case "${1:-}" in
  api)
    shift
    ENDPOINT="${1:-}"; shift || true
    HEAD_SHA=""
    JQ_FILTER="."
    METHOD=""
    HAS_FIELDS=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f)
          HAS_FIELDS=1
          case "${2:-}" in
            head_sha=*) HEAD_SHA="${2#head_sha=}" ;;
          esac
          shift 2 ;;
        --method|-X) METHOD="${2:-}"; shift 2 ;;
        --jq) JQ_FILTER="${2:-.}"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Real gh switches to POST when any -f field is present unless
    # --method GET is given; the runs-list endpoint rejects POST with
    # 404. Reproduce that so the buggy shape cannot pass here (#222).
    if (( HAS_FIELDS )) && [[ "$METHOD" != "GET" ]]; then
      echo "gh: Not Found (HTTP 404) — POST to a list endpoint" >&2
      exit 1
    fi
    if [[ -n "${FAKE_GH_RUNS_STATE_SEQ:-}" ]]; then
      # sequence mode: consume state-<n>.json per api call (poll tests)
      CNT_FILE="$FAKE_GH_RUNS_STATE_SEQ/counter"
      N=$(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$N" > "$CNT_FILE"
      LAST="$(ls "$FAKE_GH_RUNS_STATE_SEQ"/state-*.json | sort | tail -1)"
      RUNS_STATE="$FAKE_GH_RUNS_STATE_SEQ/state-$N.json"
      [[ -f "$RUNS_STATE" ]] || RUNS_STATE="$LAST"
    else
      RUNS_STATE="${FAKE_GH_RUNS_STATE:?FAKE_GH_RUNS_STATE must be set}"
    fi
    jq -c --arg sha "$HEAD_SHA" '{workflow_runs: [.[] | select(.head_sha == $sha)]}' "$RUNS_STATE" \
      | jq -r "$JQ_FILTER"
    ;;
  run)
    shift
    SUB="${1:-}"; shift || true
    [[ "$SUB" == "view" ]] || { echo "fake gh: unsupported run subcommand: $SUB" >&2; exit 1; }
    RUN_ID="${1:-}"; shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) shift 2 ;;
        --log) shift ;;
        *) shift ;;
      esac
    done
    LOG_DIR="${FAKE_GH_LOG_DIR:?FAKE_GH_LOG_DIR must be set}"
    cat "$LOG_DIR/$RUN_ID.log" 2>/dev/null
    ;;
  *) echo "fake gh: unsupported command: $*" >&2; exit 1 ;;
esac
FAKEGH
  chmod +x "$dir/gh"
  echo "$dir"
}

# run_liveness <repo> <gh-dir> <runs-state> <log-dir> [call-log]
# -> sets OUT (stdout) and EC (exit code).
run_liveness() {
  local repo="$1" ghdir="$2" runs_state="$3" log_dir="$4" call_log="${5:-}"
  OUT="$(PATH="$ghdir:$PATH" SWEEP_INVENTORY_FILE="$INVENTORY" \
    FAKE_GH_RUNS_STATE="$runs_state" FAKE_GH_LOG_DIR="$log_dir" FAKE_GH_CALL_LOG="$call_log" \
    SWEEP_LIVENESS_WAIT_SECS=0 SWEEP_LIVENESS_POLL_SECS=0 \
    "$SCRIPT" --head-sha "$SHA" --repo "$repo" 2>&1)"
  EC=$?
}

# ---- t_full_coverage: both inventory checks appear in the log -> 0 ----

t_full_coverage() {
  local r; r="$(new_repo full-coverage)"
  SHA="deadbeef01"
  local gh runs logdir; gh="$(mkfakegh full-coverage)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:1001, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4 E1)" > "$logdir/1001.log"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "0" ]] \
    && pass "run exists + complete coverage -> exit 0" \
    || fail "run exists + complete coverage -> exit 0 (got EC=$EC, OUT=$OUT)"
}

# ---- t_pc1_declared_full_coverage (controller ruling, task-6 review) ----
# B5 must accept PC1 the same as any other inventory id once a repo
# declares it. Uses its own PC1-only inventory file (never the module-
# level $INVENTORY, which every other test in this file assumes stays
# exactly B4+E1) via a second SWEEP_INVENTORY_FILE-setting helper.

run_liveness_with_inventory() {
  local repo="$1" ghdir="$2" runs_state="$3" log_dir="$4" inventory="$5"
  OUT="$(PATH="$ghdir:$PATH" SWEEP_INVENTORY_FILE="$inventory" \
    FAKE_GH_RUNS_STATE="$runs_state" FAKE_GH_LOG_DIR="$log_dir" FAKE_GH_CALL_LOG="" \
    "$SCRIPT" --head-sha "$SHA" --repo "$repo" 2>&1)"
  EC=$?
}

t_pc1_declared_full_coverage() {
  local pc1_inventory; pc1_inventory="$(mktemp "$TMP/inventory-pc1.XXXXXX")"
  printf 'PC1\n' > "$pc1_inventory"
  local r; r="$(new_repo pc1-coverage)"
  SHA="deadbeef02"
  local gh runs logdir; gh="$(mkfakegh pc1-coverage)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:1002, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json PC1)" > "$logdir/1002.log"
  run_liveness_with_inventory "$r" "$gh" "$runs" "$logdir" "$pc1_inventory"

  [[ "$EC" == "0" ]] \
    && pass "PC1: run exists + PC1 declared in a PC1-only inventory -> exit 0" \
    || fail "PC1: run exists + PC1 declared -> exit 0 (got EC=$EC, OUT=$OUT)"
}

# ---- t_raw_json_line_without_prefix: the same full-coverage shape, but ----
# with NO job/step/timestamp prefix (a local/non-CI log) -> still exit 0.
# Proves the extraction matches on the JSON object itself, not on
# line-start, so it accepts both a real CI log and a raw one.

t_raw_json_line_without_prefix() {
  local r; r="$(new_repo raw-json-line)"
  SHA="rawjsonsha1"
  local gh runs logdir; gh="$(mkfakegh raw-json-line)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:1002, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  sweep_run_json B4 E1 > "$logdir/1002.log"   # no ci_log_line prefix
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "0" ]] \
    && pass "a raw, unprefixed sweep-run/v1 JSON line (local/non-CI log) -> exit 0" \
    || fail "raw unprefixed JSON line -> exit 0 (EC=$EC OUT=$OUT)"
}

# ---- t_no_run: no sweep.yml run for this sha -> 2 + sentence ----

t_no_run() {
  local r; r="$(new_repo no-run)"
  SHA="cafef00d02"
  local gh runs logdir; gh="$(mkfakegh no-run)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n '[]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"did not actually run on"* && "$OUT" == *"reported no work done"* \
     && "$OUT" == *"green tick on this repo means nothing"* ]] \
    && pass "no run for sha -> exit 2 + plain sentence" \
    || fail "no run for sha -> exit 2 + plain sentence (EC=$EC OUT=$OUT)"
}

# ---- t_run_not_concluded: run exists but still in progress -> 2 ----

t_run_not_concluded() {
  local r; r="$(new_repo not-concluded)"
  SHA="ab12cd34"
  local gh runs logdir; gh="$(mkfakegh not-concluded)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:2002, status:"in_progress", conclusion:null}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"reported no work done"* ]] \
    && pass "run exists but has not concluded -> exit 2" \
    || fail "run exists but has not concluded -> exit 2 (EC=$EC OUT=$OUT)"
}

# ---- t_missing_check_no_skip: E1 has no envelope and no skip -> 2, named ----

t_missing_check_no_skip() {
  local r; r="$(new_repo missing-no-skip)"
  SHA="1122334455"
  local gh runs logdir; gh="$(mkfakegh missing-no-skip)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:3003, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4)" > "$logdir/3003.log"   # E1 absent
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"— E1 reported no work done"* ]] \
    && pass "one inventory check (E1) has no envelope and no skip -> exit 2, names E1" \
    || fail "one inventory check missing, no skip -> exit 2 naming E1 (EC=$EC OUT=$OUT)"
}

# ---- t_missing_check_reasoned_skip: E1 absent from log, but skipped ----
# with a reason in config -> 0. This is the shape a real skipped check
# produces: sweep-run.sh's selected_checks() never builds a job for a
# check with no `families` block, so a legally-skipped check never
# appears in the log at all.

t_missing_check_reasoned_skip() {
  local r; r="$(new_repo missing-skipped)"
  write_config "$r" '{"skips":[{"check_id":"E1","reason":"no browser-routable surface in this repo"}]}'
  SHA="6677889900"
  local gh runs logdir; gh="$(mkfakegh missing-skipped)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:4004, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4)" > "$logdir/4004.log"   # E1 absent, but skipped
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "0" ]] \
    && pass "check missing from envelopes but present in skips with a reason -> exit 0" \
    || fail "check missing from envelopes but skipped with reason -> exit 0 (EC=$EC OUT=$OUT)"
}

# ---- t_blank_skip_reason_does_not_count: a blank reason is not a skip ----

t_blank_skip_reason_does_not_count() {
  local r; r="$(new_repo blank-skip)"
  write_config "$r" '{"skips":[{"check_id":"E1","reason":"   "}]}'
  SHA="deadc0de11"
  local gh runs logdir; gh="$(mkfakegh blank-skip)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:5005, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4)" > "$logdir/5005.log"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"E1"* ]] \
    && pass "a blank skip reason does not count as a skip -> exit 2, names E1" \
    || fail "blank skip reason does not count -> exit 2 naming E1 (EC=$EC OUT=$OUT)"
}

# ---- t_rt5_family_deleted_no_skip: the config never declared a families ----
# block for E1 at all (the RT-5 bypass shape — deleting a check from
# `families` without adding a `skips` entry), and the run's log
# correspondingly never mentions E1 either, because sweep-run.sh's
# selected_checks() would never have built a job for it. This is caught
# by the SAME coverage rule as t_missing_check_no_skip, which is exactly
# the point [RT-5]: B5 asserts against the inventory file, not against
# whatever shape `families` happens to be in, so there is no special case
# to bypass by editing `families` instead of `skips`.

t_rt5_family_deleted_no_skip() {
  local r; r="$(new_repo rt5-family-deleted)"
  write_config "$r" '{"families":{"B4":{}}}'   # E1 silently absent, no skip
  SHA="f00dbabe22"
  local gh runs logdir; gh="$(mkfakegh rt5-family-deleted)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:6006, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4)" > "$logdir/6006.log"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"— E1 reported no work done"* ]] \
    && pass "config with E1 silently deleted from families (no skip) -> exit 2, RT-5 proof" \
    || fail "families-deleted RT-5 bypass -> exit 2 naming E1 (EC=$EC OUT=$OUT)"
}

# ---- t_multiple_missing_named: both checks missing -> both named ----

t_multiple_missing_named() {
  local r; r="$(new_repo multiple-missing)"
  SHA="1234567890"
  local gh runs logdir; gh="$(mkfakegh multiple-missing)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:7007, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json)" > "$logdir/7007.log"   # neither B4 nor E1 dispatched
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" && "$OUT" == *"— B4, E1 reported no work done"* ]] \
    && pass "both inventory checks missing, neither skipped -> exit 2 naming both" \
    || fail "both checks missing -> exit 2 naming both (EC=$EC OUT=$OUT)"
}

# ---- t_missing_config_file: no sweep.config.json at all -> 2 ----

t_missing_config_file() {
  local r; r="$(new_repo no-config)"
  rm -f "$r/.claude/sweep.config.json"
  SHA="0011223344"
  local gh runs logdir; gh="$(mkfakegh no-config)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n '[]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  run_liveness "$r" "$gh" "$runs" "$logdir"

  [[ "$EC" == "2" ]] \
    && pass "repo has no sweep.config.json -> exit 2" \
    || fail "no sweep.config.json -> exit 2 (EC=$EC OUT=$OUT)"
}

# ---- t_usage_without_head_sha: missing --head-sha -> exit 2 ----

t_usage_without_head_sha() {
  local out ec
  out="$("$SCRIPT" --repo "$TMP" 2>&1)"; ec=$?
  [[ "$ec" == "2" ]] \
    && pass "--head-sha is required -> exit 2" \
    || fail "--head-sha required -> exit 2 (ec=$ec out=$out)"
}

# ---- t_gh_called_with_correct_endpoint: proves the workflow-scoped ----
# endpoint (not a generic runs list) and head_sha are actually what gh
# was invoked with, via the fake's call log.

t_gh_called_with_correct_endpoint() {
  local r; r="$(new_repo endpoint-proof)"
  SHA="endpointsha1"
  local gh runs logdir log; gh="$(mkfakegh endpoint-proof)"
  runs="$(mktemp "$TMP/runs.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:8008, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4 E1)" > "$logdir/8008.log"
  log="$(mktemp "$TMP/calls.XXXXXX")"
  run_liveness "$r" "$gh" "$runs" "$logdir" "$log"

  grep -q "^api repos/example/endpoint-proof/actions/workflows/sweep.yml/runs --method GET -f head_sha=$SHA" "$log" \
    && pass "gh api called against the sweep.yml-scoped workflow-runs endpoint with GET and the right head_sha" \
    || fail "gh api endpoint/method/head_sha (log: $(cat "$log" 2>/dev/null))"
}

# ---- t_waits_for_unconcluded_run: the PR race — liveness fires while ----
# the sweep.yml run is still in_progress; it must poll (bounded) rather
# than fail on the first read. Round-7 live failure shape.
t_waits_for_unconcluded_run() {
  local r; r="$(new_repo wait-race)"
  SHA="waitracesha1"
  local gh seq logdir; gh="$(mkfakegh wait-race)"
  seq="$(mktemp -d "$TMP/seq.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:7007, status:"in_progress", conclusion:null}]' > "$seq/state-1.json"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:7007, status:"completed", conclusion:"success"}]' > "$seq/state-2.json"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  ci_log_line "$(sweep_run_json B4 E1)" > "$logdir/7007.log"
  OUT="$(PATH="$gh:$PATH" SWEEP_INVENTORY_FILE="$INVENTORY" \
    FAKE_GH_RUNS_STATE_SEQ="$seq" FAKE_GH_LOG_DIR="$logdir" \
    SWEEP_LIVENESS_WAIT_SECS=10 SWEEP_LIVENESS_POLL_SECS=0 \
    "$SCRIPT" --head-sha "$SHA" --repo "$r" 2>&1)"
  EC=$?
  [[ "$EC" == "0" ]] \
    && pass "liveness polls a not-yet-concluded run to completion instead of failing the race" \
    || fail "liveness race not tolerated (EC=$EC OUT=$OUT)"
}

t_wait_deadline_still_fails() {
  local r; r="$(new_repo wait-deadline)"
  SHA="waitdeadsha1"
  local gh seq logdir; gh="$(mkfakegh wait-deadline)"
  seq="$(mktemp -d "$TMP/seq.XXXXXX")"
  jq -n --arg sha "$SHA" '[{head_sha:$sha, id:7008, status:"in_progress", conclusion:null}]' > "$seq/state-1.json"
  logdir="$(mktemp -d "$TMP/logs.XXXXXX")"
  OUT="$(PATH="$gh:$PATH" SWEEP_INVENTORY_FILE="$INVENTORY" \
    FAKE_GH_RUNS_STATE_SEQ="$seq" FAKE_GH_LOG_DIR="$logdir" \
    SWEEP_LIVENESS_WAIT_SECS=1 SWEEP_LIVENESS_POLL_SECS=0 \
    "$SCRIPT" --head-sha "$SHA" --repo "$r" 2>&1)"
  EC=$?
  [[ "$EC" == "2" ]] && printf '%s' "$OUT" | grep -q "has not concluded" \
    && pass "liveness still fails closed when the run never concludes inside the wait budget" \
    || fail "liveness deadline behavior wrong (EC=$EC OUT=$OUT)"
}

t_full_coverage
t_pc1_declared_full_coverage
t_waits_for_unconcluded_run
t_wait_deadline_still_fails
t_raw_json_line_without_prefix
t_no_run
t_run_not_concluded
t_missing_check_no_skip
t_missing_check_reasoned_skip
t_blank_skip_reason_does_not_count
t_rt5_family_deleted_no_skip
t_multiple_missing_named
t_missing_config_file
t_usage_without_head_sha
t_gh_called_with_correct_endpoint

echo "----"
echo "test-sweep-liveness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
