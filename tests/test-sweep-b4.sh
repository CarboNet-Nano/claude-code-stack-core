#!/usr/bin/env bash
# Tests for scripts/sweep/checks/b4-merge-run.sh (stack ADR-078, task 6 of
# the Sweep serial spine). B4 asks whether every commit that LANDED on main
# in the last 30 days has a push-triggered CI run — audit row #21's second
# half, a GITHUB_TOKEN merge that never fires `push` while the repo stays
# green.
#
# Fix round 2 (I3) widened that universe from `--merges` to `--first-parent`,
# so the fixtures below come in both shapes: real `git merge --no-ff` merge
# commits AND plain single-parent commits on main (the squash-merge shape,
# which `--merges` could not see and which made B4 report a false NEVER RAN
# on every squash-merging repo). Every repo's init commit is dated outside
# the window so each test's universe count is about the test, not the
# scaffolding.
#
# Most cases invoke the check directly (not through sweep-run.sh — that is
# task 4's contract, exercised by tests/test-sweep-runner.sh) against a real,
# throwaway git repo, with a faked `gh` on PATH (the mkfakegh pattern from
# tests/test-improvement-queue.sh, adapted for `gh api .../actions/runs`
# instead of `gh issue`). No network call, no real GitHub repo. The two
# quiet-repo cases at the bottom go through the REAL runner, because an
# exit code is the thing they assert and the check alone has none.
#
# Every emitted finding is also round-tripped through the real
# sweep-emit.sh (sourced, not shelled out to) to prove the identity_key
# grouping actually survives R1. R1-survival is the SECONDARY reason for
# the grouping, though — the PRIMARY reason (documented in the check's own
# header) is that sweep-run.sh's stamp_finding hashes finding_id from
# evidence.locus ONLY, which B4 never sets, so identity_key is the only
# source of per-commit distinctness. The property tests below
# (t_identity_keys_distinct_per_sha / t_identity_key_stable_across_reruns)
# are the load-bearing proof of that claim, computed the same way
# stamp_finding computes it: sweep_finding_id with an empty locus.
#
# The fake `gh` also logs every call's endpoint + head_sha to
# FAKE_GH_CALL_LOG when set, so owner_repo()'s remote-URL parse is itself
# exercised (a broken parse would otherwise still pass every other test
# here, since the fake ignores the endpoint for its own count logic).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/b4-merge-run.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-b4-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_repo_with_remote <name> <remote-url> -> a real throwaway repo on
# `main`, origin set verbatim to <remote-url> (test-improvement-queue.sh's
# new_repo precedent, parameterized on remote form so SSH-style origins
# can be exercised too).
#
# The init commit is dated OUTSIDE the 30-day window on purpose: B4's
# universe is every commit that landed on main in the last 30 days, so an
# in-window scaffolding commit would silently inflate every universe count
# below and make each test's arithmetic about the fixture rather than about
# the behaviour under test.
OUT_OF_WINDOW_DATE="2020-01-01T00:00:00Z"
new_repo_with_remote() {
  local r="$TMP/repo-$1" remote="$2"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A \
      && GIT_AUTHOR_DATE="$OUT_OF_WINDOW_DATE" GIT_COMMITTER_DATE="$OUT_OF_WINDOW_DATE" \
         git commit -qm "chore: init" \
      && git remote add origin "$remote" )
  git -C "$r" rev-parse --show-toplevel
}

# new_repo <name> -> new_repo_with_remote with a GitHub-shaped HTTPS origin.
new_repo() {
  new_repo_with_remote "$1" "https://github.com/example/$1.git"
}

# add_merge <repo> <n> -> merges a throwaway feature branch into main with
# `--no-ff` (a real 2-parent merge commit), echoes the merge commit sha.
add_merge() {
  local r="$1" n="$2" branch="feature-$2"
  ( cd "$r" \
      && git checkout -qb "$branch" \
      && echo "$n" > "file-$n.txt" && git add -A && git commit -qm "feat: change $n" \
      && git checkout -q main \
      && git merge -q --no-ff "$branch" -m "Merge $branch" \
      && git branch -qd "$branch" ) >/dev/null
  git -C "$r" rev-parse HEAD
}

# add_direct_commit <repo> <n> -> a plain, non-merge commit on main, and
# echoes its sha. This is the SQUASH-MERGE shape: GitHub's "Squash and
# merge" lands a pull request as a single ordinary commit on main with one
# parent, indistinguishable from a direct push. It is a landing, so B4 must
# count it — the whole point of fix round 2's I3.
add_direct_commit() {
  local r="$1" n="$2"
  ( cd "$r" && echo "$n" > "direct-$n.txt" && git add -A && git commit -qm "chore: direct $n" ) >/dev/null
  git -C "$r" rev-parse HEAD
}

# mkfakegh <name> -> path to a bin dir carrying a stateful fake `gh`,
# reading a JSON array of "covered" shas from FAKE_GH_STATE at call time
# (mkfakegh pattern, tests/test-improvement-queue.sh). Captures the
# endpoint it was called with (plus head_sha) to FAKE_GH_CALL_LOG when
# that env var is set, one line per call — this is what lets a test prove
# owner_repo() actually parsed the remote correctly, rather than the fake
# silently working regardless of what endpoint it was handed.
mkfakegh() {
  local dir="$TMP/fakegh-$1"; mkdir -p "$dir"
  cat > "$dir/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -uo pipefail
STATE="${FAKE_GH_STATE:?FAKE_GH_STATE must be set}"
# FAKE_GH_FAIL simulates a listing the token is not allowed to make (the
# 403 a permissions-less CI job gets from actions/runs).
[[ -n "${FAKE_GH_FAIL:-}" ]] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
[[ "${1:-}" == "api" ]] || { echo "fake gh: unsupported command: $*" >&2; exit 1; }
shift
ENDPOINT="${1:-}"
shift || true
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
[[ -n "${FAKE_GH_CALL_LOG:-}" ]] && printf '%s %s\n' "$ENDPOINT" "$HEAD_SHA" >> "$FAKE_GH_CALL_LOG"
# Real gh switches to POST the moment any -f field is present unless
# --method GET is given; the runs-list endpoint rejects POST with 404.
# Reproduce that so the buggy invocation shape cannot pass here (#221).
if (( HAS_FIELDS )) && [[ "$METHOD" != "GET" ]]; then
  echo "gh: Not Found (HTTP 404) — POST to a list endpoint" >&2
  exit 1
fi
if [[ -n "$HEAD_SHA" ]]; then
  # legacy per-sha shape (kept so a regression back to it still works in
  # unit tests but is caught by the call-log batching assertion below)
  COUNT="$(jq -r --arg sha "$HEAD_SHA" '[.[] | select(. == $sha)] | length' "$STATE" 2>/dev/null)"
  [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
  jq -n --argjson n "$COUNT" '{total_count:$n, workflow_runs:[]}' | jq -r "$JQ_FILTER"
else
  # batched listing shape (#budget fix): every covered sha as a run row
  jq '{total_count: length, workflow_runs: [.[] | {head_sha: .}]}' "$STATE" | jq -r "$JQ_FILTER"
fi
FAKEGH
  chmod +x "$dir/gh"
  echo "$dir"
}

# t_batched_covered_listing: B4 makes ONE paginated runs listing, never
# one API call per landing — ~200 sequential calls busted the runner's
# 120s budget on the first month of real history.
t_batched_covered_listing() {
  local r; r="$(new_repo batched)"
  local m1 m2; m1="$(add_merge "$r" 1)"; m2="$(add_merge "$r" 2)"
  local gh state log; gh="$(mkfakegh batched)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$m1" '[$a]' > "$state"
  log="$(mktemp "$TMP/calls.XXXXXX")"
  run_check "$r" "$gh" "$state" "$log"
  local calls uncovered
  calls="$(grep -c "actions/runs" "$log" 2>/dev/null || echo 0)"
  uncovered="$(jq -r '[.findings[]] | length' <<<"$ENV_OUT")"
  [[ "$calls" == "1" ]] \
    && pass "B4 lists covered runs with exactly one API call (was one per landing)" \
    || fail "B4 made $calls runs-API calls for a 2-commit universe"
  [[ "$uncovered" == "1" ]] \
    && pass "B4 batched listing still tells covered from uncovered" \
    || fail "B4 batched coverage wrong (uncovered=$uncovered, want 1)"
}

# t_remote_tracking_main_only: a CI checkout of a PR head has no local
# `main` — only refs/remotes/origin/main (when history was fetched). B4
# must resolve that ref instead of silently reporting an empty universe
# (the first live run's failure shape).
t_remote_tracking_main_only() {
  local r; r="$(new_repo remote-main)"
  local m1; m1="$(add_merge "$r" 1)"
  ( cd "$r" \
      && git update-ref refs/remotes/origin/main "$(git rev-parse main)" \
      && git checkout -q --detach main \
      && git branch -qD main ) >/dev/null 2>&1
  local gh state; gh="$(mkfakegh remote-main)"
  state="$(mktemp "$TMP/state.XXXXXX")"; echo "[]" > "$state"
  run_check "$r" "$gh" "$state"
  local universe; universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  [[ "$universe" == "1" ]] \
    && pass "B4 resolves refs/remotes/origin/main when no local main exists (CI shape)" \
    || fail "B4 empty universe on remote-tracking-only main (universe=$universe)"
}

# build_job <repo> -> a sweep-job/v1 (task 4 contract) for check_id B4.
build_job() {
  jq -cn --arg repo "$1" \
    '{schema:"sweep-job/v1", run_id:"2026-08-15T00:00:00Z.test01", check_id:"B4",
      repo_root:$repo, cadence:"push-main", writes_findings:true,
      evidence_basis:"static-source", surface:"ci-gate", config:{},
      changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <repo> <fakegh-dir> <state-file> [call-log] -> sets ENV_OUT to
# the decoded sweep-result/v1 envelope. When <call-log> is given, the fake
# gh's per-call endpoint+head_sha lines are appended there.
run_check() {
  local repo="$1" ghdir="$2" state="$3" call_log="${4:-}" job out line
  job="$(build_job "$repo")"
  out="$(printf '%s' "$job" | PATH="$ghdir:$PATH" FAKE_GH_STATE="$state" FAKE_GH_CALL_LOG="$call_log" bash "$CHECK")"
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
}

# ---- t_partial_coverage: 2 of 3 merge shas covered -> 1 finding, 1/3 ----

t_partial_coverage() {
  local r; r="$(new_repo partial)"
  local sha1 sha2 sha3
  sha1="$(add_merge "$r" 1)"; sha2="$(add_merge "$r" 2)"; sha3="$(add_merge "$r" 3)"
  local gh state; gh="$(mkfakegh partial)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" '[$a, $b]' > "$state"   # sha3 uncovered
  run_check "$r" "$gh" "$state"

  local status universe assertions passed findings_n meas_count meas_denom
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  meas_count="$(jq -r '.measurements[0].count' <<<"$ENV_OUT")"
  meas_denom="$(jq -r '.measurements[0].denominator' <<<"$ENV_OUT")"
  local finding_commit; finding_commit="$(jq -r '.findings[0].evidence.commit' <<<"$ENV_OUT")"

  [[ "$status" == "fail" && "$universe" == "3" && "$assertions" == "3" && "$passed" == "2" \
     && "$findings_n" == "1" && "$meas_count" == "1" && "$meas_denom" == "3" \
     && "$finding_commit" == "$sha3" ]] \
    && pass "partial coverage: 2/3 covered -> 1 finding, count 1/3, assertions 3, passed 2" \
    || fail "partial coverage (status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n count=$meas_count/$meas_denom commit=$finding_commit want=$sha3)"
}

t_partial_coverage_finding_shape() {
  local r; r="$(new_repo partial-shape)"
  local sha1 sha2 sha3
  sha1="$(add_merge "$r" 1)"; sha2="$(add_merge "$r" 2)"; sha3="$(add_merge "$r" 3)"
  local gh state; gh="$(mkfakegh partial-shape)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" '[$a, $b]' > "$state"
  run_check "$r" "$gh" "$state"

  local f mech surface src found ident plain has_status
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  mech="$(jq -r '.mechanism' <<<"$f")"
  surface="$(jq -r '.surface' <<<"$f")"
  src="$(jq -r '.surface_source' <<<"$f")"
  found="$(jq -r '.found_by' <<<"$f")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  plain="$(jq -r '.plain' <<<"$f")"
  has_status="$(jq -r 'has("status")' <<<"$f")"

  [[ "$mech" == "NEVER RAN" && "$surface" == "ci-gate" && "$src" == "declared" \
     && "$found" == "sweep-family-B" && "$ident" == push-run-* && -n "$plain" \
     && "$has_status" == "false" ]] \
    && pass "partial coverage: finding shape (NEVER RAN / ci-gate / sweep-family-B / push-run- prefix / no status)" \
    || fail "partial coverage: finding shape (mech=$mech surface=$surface src=$src found=$found ident=$ident status?=$has_status)"
}

t_partial_coverage_finding_survives_emit() {
  local r; r="$(new_repo partial-emit)"
  local sha1 sha2 sha3
  sha1="$(add_merge "$r" 1)"; sha2="$(add_merge "$r" 2)"; sha3="$(add_merge "$r" 3)"
  local gh state; gh="$(mkfakegh partial-emit)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" '[$a, $b]' > "$state"
  run_check "$r" "$gh" "$state"

  # Stamp the runner's own fields (schema/finding_id/run_id/repo/created_at
  # — sweep-run.sh's job, not this check's) so sweep_emit_finding sees a
  # fully-formed record, exactly the shape stamp_finding produces.
  local f fid ident stamped findings_out
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  fid="$(sweep_finding_id repo B4 "NEVER RAN" "" "$ident")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    [[ "$(wc -l < "$findings_out" | tr -d ' ')" == "1" ]] \
      && pass "partial coverage: finding survives sweep_emit_finding (identity_key grouping defeats R1)" \
      || fail "partial coverage: finding survives sweep_emit_finding (wrote $(wc -l < "$findings_out") lines)"
  else
    fail "partial coverage: finding survives sweep_emit_finding (refused: $(cat "$TMP/emit.err"))"
  fi
}

# ---- t_full_coverage: all 3 covered -> pass, 0 findings, assertions 3 ----

t_full_coverage() {
  local r; r="$(new_repo full)"
  local sha1 sha2 sha3
  sha1="$(add_merge "$r" 1)"; sha2="$(add_merge "$r" 2)"; sha3="$(add_merge "$r" 3)"
  local gh state; gh="$(mkfakegh full)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" --arg c "$sha3" '[$a, $b, $c]' > "$state"
  run_check "$r" "$gh" "$state"

  local status universe assertions passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ "$status" == "pass" && "$findings_n" == "0" && "$assertions" == "3" && "$passed" == "3" \
     && "$universe" == "3" ]] \
    && pass "full coverage: all 3 covered -> pass, 0 findings, assertions_executed 3 (never 0 when merges exist)" \
    || fail "full coverage (status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n)"
}

# ---- squash-merge shape: the landings that are NOT merge commits ----
# Fix round 2, IMPORTANT (I3). B4's universe used to be `git log --merges`,
# a literal reading of "merge commits". On a repo that squash-merges — the
# GitHub default on a great many repos — there are no merge commits at all,
# so the universe was empty, invariant 2 fired, and B4 reported NEVER RAN
# every single run on a repo whose CI was working perfectly. The universe is
# now FIRST-PARENT commits on main: every landing, however it landed.

t_squash_shaped_landings_are_in_the_universe() {
  local r; r="$(new_repo squash-shaped)"
  local sha1 sha2 sha3
  sha1="$(add_direct_commit "$r" 1)"; sha2="$(add_direct_commit "$r" 2)"; sha3="$(add_direct_commit "$r" 3)"
  local gh state; gh="$(mkfakegh squash-shaped)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" '[$a, $b]' > "$state"   # sha3 uncovered
  run_check "$r" "$gh" "$state"

  local status universe assertions passed findings_n finding_commit
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  finding_commit="$(jq -r '.findings[0].evidence.commit' <<<"$ENV_OUT")"

  [[ "$status" == "fail" && "$universe" == "3" && "$assertions" == "3" && "$passed" == "2" \
     && "$findings_n" == "1" && "$finding_commit" == "$sha3" ]] \
    && pass "squash-shaped landings (plain single-parent commits on main) are counted: universe 3, the uncovered one is found" \
    || fail "squash-shaped landings counted (status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n commit=$finding_commit want=$sha3)"
}

t_squash_shaped_repo_with_all_landings_covered_passes() {
  local r; r="$(new_repo squash-covered)"
  local sha1 sha2
  sha1="$(add_direct_commit "$r" 1)"; sha2="$(add_direct_commit "$r" 2)"
  local gh state; gh="$(mkfakegh squash-covered)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg a "$sha1" --arg b "$sha2" '[$a, $b]' > "$state"
  run_check "$r" "$gh" "$state"

  local status universe findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "pass" && "$universe" == "2" && "$findings_n" == "0" ]] \
    && pass "squash-shaped repo with a push run per landing: pass, universe 2, no false NEVER RAN" \
    || fail "squash-shaped repo fully covered (status=$status universe=$universe findings=$findings_n)"
}

t_feature_branch_commits_are_not_in_the_universe() {
  # --first-parent, not --all: the commits INSIDE a merged branch never
  # triggered a push run on main and were never supposed to. Counting them
  # would manufacture a finding per unmerged-branch commit.
  local r; r="$(new_repo first-parent-only)"
  add_merge "$r" 1 >/dev/null   # 1 merge commit on main + 1 commit on the branch
  local gh state; gh="$(mkfakegh first-parent-only)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"
  run_check "$r" "$gh" "$state"

  local universe; universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  [[ "$universe" == "1" ]] \
    && pass "first-parent only: the merged branch's own commit is not a landing on main (universe 1, not 2)" \
    || fail "first-parent only (universe=$universe, want 1)"
}

# ---- t_quiet_window: nothing landed on main in the window -> universe 0 ----

t_quiet_window_reports_zero_honestly() {
  local r; r="$(new_repo quiet-window)"   # only the out-of-window init commit
  local gh state; gh="$(mkfakegh quiet-window)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n '[]' > "$state"
  run_check "$r" "$gh" "$state"

  local universe assertions findings_n
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  # The runner's B2 invariant decides what universe_size 0 means (exit 2
  # unless the config declares empty_universe_ok — see the runner tests at
  # the bottom of this file). This check's job is only to report it
  # honestly, never to fabricate a nonzero universe or a finding to dodge
  # that verdict.
  [[ "$universe" == "0" && "$assertions" == "0" && "$findings_n" == "0" ]] \
    && pass "nothing landed in the window: universe_size 0 reported honestly, no fabricated findings" \
    || fail "nothing landed in the window (universe=$universe assertions=$assertions findings=$findings_n)"
}

t_envelope_echoes_job_identity() {
  local r; r="$(new_repo identity)"
  add_merge "$r" 1 >/dev/null
  local gh state; gh="$(mkfakegh identity)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n '[]' > "$state"
  run_check "$r" "$gh" "$state"

  local schema check_id basis surface
  schema="$(jq -r '.schema' <<<"$ENV_OUT")"
  check_id="$(jq -r '.check_id' <<<"$ENV_OUT")"
  basis="$(jq -r '.evidence_basis' <<<"$ENV_OUT")"
  surface="$(jq -r '.surface' <<<"$ENV_OUT")"

  [[ "$schema" == "sweep-result/v1" && "$check_id" == "B4" \
     && "$basis" == "static-source" && "$surface" == "ci-gate" ]] \
    && pass "envelope echoes the job's evidence_basis and surface byte-for-byte" \
    || fail "envelope echoes job identity (schema=$schema check_id=$check_id basis=$basis surface=$surface)"
}

# ---- owner_repo() parse: proven via the fake gh's captured endpoint ----

t_owner_repo_https_endpoint() {
  local r; r="$(new_repo https-endpoint)"
  local sha; sha="$(add_merge "$r" 1)"
  local gh state log; gh="$(mkfakegh https-endpoint)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"
  log="$(mktemp "$TMP/calls.XXXXXX")"
  run_check "$r" "$gh" "$state" "$log"
  grep -q "^repos/example/https-endpoint/actions/runs" "$log" \
    && pass "owner_repo(): HTTPS origin (https://github.com/example/https-endpoint.git) parses to the actions/runs endpoint gh was actually called with (batched listing carries no per-sha arg)" \
    || fail "owner_repo(): HTTPS origin parses to the endpoint gh was called with (log: $(cat "$log" 2>/dev/null))"
}

t_owner_repo_ssh_remote_parses() {
  local r; r="$(new_repo_with_remote ssh-remote "git@github.com:owner-ssh/repo-ssh.git")"
  local sha; sha="$(add_merge "$r" 1)"
  local gh state log; gh="$(mkfakegh ssh-remote)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"
  log="$(mktemp "$TMP/calls.XXXXXX")"
  run_check "$r" "$gh" "$state" "$log"
  grep -q "^repos/owner-ssh/repo-ssh/actions/runs" "$log" \
    && pass "owner_repo(): SSH-form origin (git@github.com:owner/repo.git) parses to owner/repo, proven via the endpoint gh was actually called with" \
    || fail "owner_repo(): SSH-form origin parses to owner/repo (log: $(cat "$log" 2>/dev/null))"
}

# ---- identity_key distinctness/stability: the load-bearing property ----
# stamp_finding (sweep-run.sh) computes finding_id from evidence.locus
# ONLY, which B4 never sets — so identity_key must, by itself, (a) differ
# across different uncovered commits in the same run and (b) reproduce
# identically for the same commit across runs. Computed the same way
# stamp_finding computes it: sweep_finding_id with an empty locus.

t_identity_keys_distinct_per_sha() {
  local r; r="$(new_repo distinct-ids)"
  local sha1 sha2
  sha1="$(add_merge "$r" 1)"; sha2="$(add_merge "$r" 2)"
  local gh state; gh="$(mkfakegh distinct-ids)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"   # both uncovered
  run_check "$r" "$gh" "$state"

  local ident1 ident2 fid1 fid2
  ident1="$(jq -r '.findings[] | select(.evidence.commit==$s) | .identity_key' --arg s "$sha1" <<<"$ENV_OUT")"
  ident2="$(jq -r '.findings[] | select(.evidence.commit==$s) | .identity_key' --arg s "$sha2" <<<"$ENV_OUT")"
  fid1="$(sweep_finding_id repo B4 "NEVER RAN" "" "$ident1")"
  fid2="$(sweep_finding_id repo B4 "NEVER RAN" "" "$ident2")"

  [[ -n "$ident1" && -n "$ident2" && "$ident1" != "$ident2" && "$fid1" != "$fid2" ]] \
    && pass "identity_key/finding_id: two different uncovered shas in one run produce two DIFFERENT identity_keys and finding_ids" \
    || fail "identity_key/finding_id distinctness (ident1=$ident1 ident2=$ident2 fid1=$fid1 fid2=$fid2)"
}

t_identity_key_stable_across_reruns() {
  local r; r="$(new_repo stable-id)"
  local sha; sha="$(add_merge "$r" 1)"
  local gh; gh="$(mkfakegh stable-id)"
  local state1 state2
  state1="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state1"
  state2="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state2"   # a second, independent run

  run_check "$r" "$gh" "$state1"
  local ident1 fid1
  ident1="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  fid1="$(sweep_finding_id repo B4 "NEVER RAN" "" "$ident1")"

  run_check "$r" "$gh" "$state2"
  local ident2 fid2
  ident2="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  fid2="$(sweep_finding_id repo B4 "NEVER RAN" "" "$ident2")"

  [[ -n "$ident1" && "$ident1" == "$ident2" && "$fid1" == "$fid2" ]] \
    && pass "identity_key/finding_id: re-running the same job against the same sha reproduces the SAME identity_key and finding_id" \
    || fail "identity_key/finding_id stability across reruns (ident1=$ident1 ident2=$ident2 fid1=$fid1 fid2=$fid2)"
}

# ---- end-to-end through the REAL runner: the quiet-repo exemption ----
# Fix round 2, IMPORTANT (I3), the other half. Making the universe
# first-parent fixes the squash-merge repo; it does not fix the QUIET repo,
# which really did have nothing land in 30 days and would still report
# universe 0 and trip invariant 2 forever. `families.B4.empty_universe_ok`
# is the declared, reasoned exemption. These two run the real sweep-run.sh
# against the real b4-merge-run.sh (test seams only for the inventory and
# the checks dir) — the check alone cannot prove an exit code.

RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"
CHECKS_DIR="$REPO_ROOT/scripts/sweep/checks"

# run_runner <repo> <config-json> -> sets RUN_OUT / RUN_ERR / RUN_EC.
run_runner() {
  local repo="$1" cfg="$2"
  mkdir -p "$repo/.claude/sweep"
  jq . <<<"$cfg" > "$repo/.claude/sweep.config.json"
  printf 'B4\n' > "$repo/inventory.txt"
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    bash "$RUNNER" --repo "$repo" --cadence manual --json 2>"$TMP/runner.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/runner.err")"
}

CONFIG_QUIET_UNDECLARED='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"B4":"ci-gate"},"families":{"B4":{}},"skips":[]}'

t_quiet_repo_without_declaration_exits_2() {
  local r; r="$(new_repo quiet-undeclared)"   # nothing landed inside the window
  run_runner "$r" "$CONFIG_QUIET_UNDECLARED"
  local st; st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "fail" ]] \
    && pass "quiet repo, no empty_universe_ok declared: universe 0 is still a liveness failure -> exit 2 (unchanged)" \
    || fail "quiet repo undeclared -> exit 2 (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

t_quiet_repo_with_declaration_is_a_legal_skip() {
  local r; r="$(new_repo quiet-declared)"
  local cfg reason
  reason="this repo squash-merges and routinely has no landings on main in a 30-day window"
  cfg="$(jq -c --arg re "$reason" '.families.B4.empty_universe_ok=$re' <<<"$CONFIG_QUIET_UNDECLARED")"
  run_runner "$r" "$cfg"
  local st got
  st="$(jq -r '.checks[] | select(.check_id=="B4") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  got="$(jq -r '.checks[] | select(.check_id=="B4") | .skip_reason // ""' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "0" && "$st" == "skipped" && "$got" == "$reason" ]] \
    && pass "quiet repo with empty_universe_ok declared: exit 0, B4 recorded skipped with the declared reason" \
    || fail "quiet repo declared -> exit 0 skipped-with-reason (ec=$RUN_EC status=$st reason=$got out=$RUN_OUT err=$RUN_ERR)"
}

# ---- failed listing ≠ empty listing (the 209-false-findings bug) ----
# A runs listing the token cannot make (403: no actions:read) used to be
# swallowed by 2>/dev/null and read as "no runs exist", scoring every
# landing uncovered — one false finding per commit on main, and a real CI
# hole indistinguishable from a permissions problem. A failed call must
# surface as an error envelope, never as findings.

t_failed_listing_reports_error_not_findings() {
  local r; r="$(new_repo listing-fails)"
  add_merge "$r" 1 >/dev/null; add_merge "$r" 2 >/dev/null
  local gh state; gh="$(mkfakegh listing-fails)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"
  FAKE_GH_FAIL=1 run_check "$r" "$gh" "$state"
  local status universe executed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  executed="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "error" && "$universe" == "2" && "$executed" == "0" && "$findings_n" == "0" ]] \
    && pass "failed runs listing: status error, 0 findings — never one false finding per landing" \
    || fail "failed runs listing (status=$status universe=$universe executed=$executed findings=$findings_n)"
}

t_failed_listing_through_runner_is_check_error() {
  local r; r="$(new_repo listing-fails-runner)"
  add_merge "$r" 1 >/dev/null
  local gh state; gh="$(mkfakegh listing-fails-runner)"
  state="$(mktemp "$TMP/state.XXXXXX")"; jq -n '[]' > "$state"
  mkdir -p "$r/.claude/sweep"
  jq . <<<"$CONFIG_QUIET_UNDECLARED" > "$r/.claude/sweep.config.json"
  printf 'B4\n' > "$r/inventory.txt"
  local out ec code findings_n
  out="$(SWEEP_INVENTORY_FILE="$r/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    PATH="$gh:$PATH" FAKE_GH_STATE="$state" FAKE_GH_FAIL=1 \
    bash "$RUNNER" --repo "$r" --cadence manual --json 2>/dev/null)"
  ec=$?
  code="$(jq -r '.checks[] | select(.check_id=="B4") | .violation // ""' <<<"$out" 2>/dev/null)"
  findings_n="$(jq -r '.checks[] | select(.check_id=="B4") | .findings_n' <<<"$out" 2>/dev/null)"
  [[ "$ec" == "2" && "$findings_n" == "0" && "$code" == *"error"* ]] \
    && pass "failed runs listing through the runner: exit 2 with a visible check-error, 0 findings" \
    || fail "failed listing through runner (ec=$ec findings_n=$findings_n violation=$code)"
}

# ---- #225: a push of N commits produces ONE run at the head sha; the
# N-1 buried commits are covered by that run, not findings. ----

t_multi_commit_push_credits_buried_commits() {
  local r; r="$(new_repo push-ancestry)"
  local c1 c2 c3
  c1="$(add_direct_commit "$r" 1)"; c2="$(add_direct_commit "$r" 2)"; c3="$(add_direct_commit "$r" 3)"
  local gh state; gh="$(mkfakegh push-ancestry)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg h "$c3" '[$h]' > "$state"   # one run, at the push head only
  run_check "$r" "$gh" "$state"
  local status universe passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "pass" && "$universe" == "3" && "$passed" == "3" && "$findings_n" == "0" ]] \
    && pass "multi-commit push: one run at the head credits the buried commits (3 landings, 1 run, 0 findings)" \
    || fail "push-ancestry credit (status=$status universe=$universe passed=$passed findings=$findings_n)"
}

t_ancestry_credit_never_reaches_forward() {
  local r; r="$(new_repo ancestry-forward)"
  local c1 c2 c3
  c1="$(add_direct_commit "$r" 1)"; c2="$(add_direct_commit "$r" 2)"; c3="$(add_direct_commit "$r" 3)"
  local gh state; gh="$(mkfakegh ancestry-forward)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n --arg h "$c2" '[$h]' > "$state"   # run at c2: credits c1, never c3
  run_check "$r" "$gh" "$state"
  local status passed findings_n finding_commit
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  finding_commit="$(jq -r '.findings[0].evidence.commit' <<<"$ENV_OUT")"
  [[ "$status" == "fail" && "$passed" == "2" && "$findings_n" == "1" && "$finding_commit" == "$c3" ]] \
    && pass "ancestry credit reaches backward only: run at c2 covers c1, c3 is still found" \
    || fail "ancestry forward-credit leak (status=$status passed=$passed findings=$findings_n commit=$finding_commit want=$c3)"
}

t_unknown_run_head_credits_nothing() {
  local r; r="$(new_repo unknown-head)"
  local c1; c1="$(add_direct_commit "$r" 1)"
  local gh state; gh="$(mkfakegh unknown-head)"
  state="$(mktemp "$TMP/state.XXXXXX")"
  jq -n '["deadbee0000000000000000000000000000000dd"]' > "$state"  # sha git has never seen
  run_check "$r" "$gh" "$state"
  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "fail" && "$findings_n" == "1" ]] \
    && pass "a run head sha unknown to the local repo credits nothing (default-closed holds)" \
    || fail "unknown head credited coverage (status=$status findings=$findings_n)"
}

t_partial_coverage
t_partial_coverage_finding_shape
t_partial_coverage_finding_survives_emit
t_full_coverage
t_squash_shaped_landings_are_in_the_universe
t_squash_shaped_repo_with_all_landings_covered_passes
t_feature_branch_commits_are_not_in_the_universe
t_quiet_window_reports_zero_honestly
t_quiet_repo_without_declaration_exits_2
t_quiet_repo_with_declaration_is_a_legal_skip
t_envelope_echoes_job_identity
t_owner_repo_https_endpoint
t_owner_repo_ssh_remote_parses
t_batched_covered_listing
t_remote_tracking_main_only
t_identity_keys_distinct_per_sha
t_identity_key_stable_across_reruns
t_multi_commit_push_credits_buried_commits
t_ancestry_credit_never_reaches_forward
t_unknown_run_head_credits_nothing
t_failed_listing_reports_error_not_findings
t_failed_listing_through_runner_is_check_error

echo "----"
echo "test-sweep-b4: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
