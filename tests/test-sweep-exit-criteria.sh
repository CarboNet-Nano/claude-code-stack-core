#!/usr/bin/env bash
# Tests for the phase-1 exit criteria of spec S6 (stack ADR-078, task 11
# of the Sweep serial spine).
#
# These are NOT a second copy of tests/test-sweep-runner.sh's invariant
# tests. That suite runs the runner out of the SOURCE TREE, where
# `schemas/finding-record.json` and `schemas/sweep-config.json` happen to
# sit two levels above `scripts/sweep/lib/` because that is how the repo
# is laid out. This suite runs it out of an INSTALLED layout assembled
# from `config/tier-manifests/tier-2.json` itself — so the manifest is
# the input, and dropping an entry from it fails a test here rather than
# failing silently on someone's machine six weeks later. Both libraries
# resolve their schema as `$lib/../../../schemas/<name>.json`
# (sweep-config.sh:22, sweep-emit.sh:46), which is exactly the assumption
# the manifest's `to:` paths have to satisfy and nothing else checks.
#
# Three exit criteria from spec S6 phase 1, one block each:
#   (a) a vacuous check -> exit 2 + the sweep.vacuous-check meta-finding
#       + the plain sentence, end-to-end through the installed path.
#   (b) two concurrent `--cadence pr` runs on two branches both exit 0
#       and neither touches findings.jsonl [RT-2] — the concurrency
#       hazard proven absent, not mitigated.
#   (c) a family block deleted with no `skips` entry exits 3 from the
#       runner AND exits 2 from sweep-liveness.sh [RT-5] — the
#       config-level NEVER RAN bypass, proven closed at both layers.
#
# Exit codes are law (spec S5.4): 0 pass/observe, 1 blocking findings,
# 2 liveness failure (always with the plain sentence), 3 config invalid.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/config/tier-manifests/tier-2.json"
FIXTURES="$REPO_ROOT/tests/fixtures/sweep-checks"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-exit-criteria.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

SENTENCE_TAIL="Until this is fixed, a green tick on this repo means nothing."
TODAY="$(date -u +%Y-%m-%d)"

# ---- the installed layout, assembled from the manifest ----------------

# install_stack <dest> -> copies every tier-2 `files.global` entry whose
# source is part of the Sweep into <dest>, rewriting the manifest's
# `~/.claude` prefix to <dest>. Nothing is hard-coded: the file list, the
# destination paths and the executable bits all come out of the manifest,
# which is what makes this a test OF the manifest.
install_stack() {
  local dest="$1" from to executable src dst
  while IFS='|' read -r from to executable; do
    [[ -z "$from" ]] && continue
    src="$REPO_ROOT/$from"
    dst="${to/#\~\/.claude/$dest}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst" || return 1
    [[ "$executable" == "true" ]] && chmod +x "$dst"
  done < <(jq -r '.files.global[]
    | select(.from | test("^scripts/sweep/|^schemas/(finding-record|sweep-config)\\.json$"))
    | "\(.from)|\(.to)|\(.executable // false)"' "$MANIFEST")
  return 0
}

STACK="$TMP/installed"
install_stack "$STACK" || { echo "FATAL: could not assemble the installed layout"; exit 1; }

RUNNER="$STACK/scripts/sweep/sweep-run.sh"
LIVENESS="$STACK/scripts/sweep/sweep-liveness.sh"

# The suite is worthless if the manifest never named the runner, so this
# is a hard precondition rather than a test case that could be skipped.
[ -x "$RUNNER" ] || { echo "FATAL: tier-2.json does not install scripts/sweep/sweep-run.sh"; exit 1; }
[ -x "$LIVENESS" ] || { echo "FATAL: tier-2.json does not install scripts/sweep/sweep-liveness.sh"; exit 1; }

# ---- shared fixtures --------------------------------------------------

# A two-check inventory (B4, E1), isolated from the installed
# inventory.txt via SWEEP_INVENTORY_FILE — the same test seam
# tests/test-sweep-runner.sh uses. The schema paths are NOT seamed, and
# that is the point of this suite.
INVENTORY="$TMP/inventory.txt"
printf 'B4\nE1\n' > "$INVENTORY"

CONFIG_BOTH='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"B4":"ci-gate"},"families":{"B4":{}},"skips":[{"check_id":"E1","reason":"no browser-routable surface in this fixture repo"}]}'
# The RT-5 config: E1's family block is gone AND no skip replaces it.
CONFIG_E1_DELETED='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"B4":"ci-gate"},"families":{"B4":{}},"skips":[]}'

# mkrepo <name> -> a throwaway repo carrying its own checks dir.
mkrepo() {
  local d="$TMP/repo-$1"
  mkdir -p "$d/.claude/sweep" "$d/checks"
  cp "$FIXTURES/_envelope.sh" "$d/checks/_envelope.sh"
  echo "$d"
}

# install_check <repo> <check-id> <fixture-file>
install_check() {
  local lower; lower="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  cp "$FIXTURES/$3" "$1/checks/$lower-fixture.sh"
  chmod +x "$1/checks/$lower-fixture.sh"
}

write_config() { printf '%s' "$2" | jq . > "$1/.claude/sweep.config.json"; }

# run_sweep <repo> <args...> -> sets RUN_OUT / RUN_ERR / RUN_EC, running
# the INSTALLED runner.
run_sweep() {
  local repo="$1"; shift
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$INVENTORY" SWEEP_CHECKS_DIR="$repo/checks" \
    bash "$RUNNER" --repo "$repo" "$@" 2>"$TMP/run.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/run.err")"
}

sha_of() { shasum -a 256 < "$1" | awk '{print $1}'; }
# GNU first: on Linux `stat -f %m` is filesystem status (whose free-block
# counts change between calls), not an error, so BSD-first never falls
# through and the "mtime" is garbage that never compares equal.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# ---- (a) vacuous check, end-to-end through the installed path ---------

t_vacuous_exit2_meta_finding_and_sentence() {
  local r; r="$(mkrepo vacuous)"; write_config "$r" "$CONFIG_BOTH"
  install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main

  local f="$r/.claude/sweep/findings.jsonl"
  local row mech ident plain schema
  row="$(head -1 "$f" 2>/dev/null)"
  schema="$(jq -r '.schema // ""' <<<"$row" 2>/dev/null)"
  mech="$(jq -r '.mechanism // ""' <<<"$row" 2>/dev/null)"
  ident="$(jq -r '.identity_key // ""' <<<"$row" 2>/dev/null)"
  plain="$(jq -r '.plain // ""' <<<"$row" 2>/dev/null)"

  # The meta-finding landing at all is the installed-layout proof: the
  # emit library refuses any record it cannot validate against
  # $STACK/schemas/finding-record.json, and a refusal writes no row.
  [[ "$RUN_EC" == "2" && "$schema" == "finding-record/v1" && "$mech" == "NEVER RAN" \
     && "$ident" == "B4" && -n "$plain" ]] \
    && pass "S6(a): vacuous check -> exit 2 + sweep.vacuous-check written through the INSTALLED finding-record schema" \
    || fail "S6(a): vacuous -> exit 2 + meta-finding via installed schema (ec=$RUN_EC schema=$schema mech=$mech ident=$ident plain='$plain')"
}

t_vacuous_plain_sentence_verbatim() {
  local r; r="$(mkrepo vacuous-sentence)"; write_config "$r" "$CONFIG_BOTH"
  install_check "$r" B4 pass-vacuous.sh
  run_sweep "$r" --cadence push-main

  local expect="The safety checks did not actually run on $TODAY — B4 reported no work done. $SENTENCE_TAIL"
  grep -Fq "$expect" <<<"$RUN_OUT$RUN_ERR" \
    && pass "S6(a): exit 2 carries the plain sentence verbatim from the installed runner" \
    || fail "S6(a): plain sentence verbatim (got: $RUN_OUT | $RUN_ERR)"
}

t_installed_config_validation_resolves_its_schema() {
  # sweep-config.sh degrades to the violation "the sweep-config/v1 schema
  # is missing from this install" when its `../../../schemas` hop does not
  # land. Asserting that string is ABSENT on a valid config is how this
  # suite proves the manifest put sweep-config.json where the library
  # looks, rather than proving it some other way and hoping.
  local r; r="$(mkrepo schema-resolves)"; write_config "$r" "$CONFIG_BOTH"
  install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence pr

  [[ "$RUN_EC" == "0" ]] && ! grep -Fq "schema is missing from this install" <<<"$RUN_ERR" \
    && pass "S6(a): the installed layout satisfies both libraries' ../../../schemas hop" \
    || fail "S6(a): installed layout resolves both schemas (ec=$RUN_EC err=$RUN_ERR)"
}

# ---- (b) RT-2: two concurrent pr runs, findings.jsonl untouched -------

# The seeded row stands in for a repo that already has a findings book.
# "Untouched" is asserted as byte-identity AND mtime, because a rewrite
# that happened to reproduce the same bytes would still be a write.
SEEDED_FINDING='{"schema":"finding-record/v1","finding_id":"seed0000","identity_key":"seed","run_id":"seed","repo":"rt2","created_at":"2026-08-15T00:00:00Z","what":"pre-existing row","plain":"A finding that was already recorded before these runs started.","mechanism":"NEVER RAN","surface":"ci-gate","surface_source":"declared","found_by":"ci-self-audit","evidence":{"locus":"seed","measurement":{"statement":"seed","count":1,"denominator":1,"source":"static-source"}},"liveness":{"assertions_executed":0,"assertions_passed":0},"responsible_agent":null,"roster_action":null}'

t_rt2_concurrent_pr_runs_do_not_write() {
  local base="$TMP/rt2-base"
  mkdir -p "$base/.claude/sweep" "$base/checks"
  cp "$FIXTURES/_envelope.sh" "$base/checks/_envelope.sh"
  cp "$FIXTURES/pass-normal.sh" "$base/checks/b4-fixture.sh"
  chmod +x "$base/checks/b4-fixture.sh"
  printf '%s' "$CONFIG_BOTH" | jq . > "$base/.claude/sweep.config.json"
  printf '%s\n' "$SEEDED_FINDING" > "$base/.claude/sweep/findings.jsonl"
  (
    cd "$base" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && git add -A && git commit -qm "chore: seed findings book"
  ) >/dev/null 2>&1

  # Two real branches, checked out side by side, so the two runs are two
  # different working trees of one repo — the shape a pair of concurrent
  # PR CI jobs actually has.
  local wt1="$TMP/rt2-branch-a" wt2="$TMP/rt2-branch-b"
  git -C "$base" worktree add -q -b branch-a "$wt1" >/dev/null 2>&1
  git -C "$base" worktree add -q -b branch-b "$wt2" >/dev/null 2>&1
  if [[ ! -f "$wt1/.claude/sweep/findings.jsonl" || ! -f "$wt2/.claude/sweep/findings.jsonl" ]]; then
    fail "S6(b): could not create two branch worktrees carrying the findings book"
    return
  fi

  local sha1_before sha2_before mt1_before mt2_before
  sha1_before="$(sha_of "$wt1/.claude/sweep/findings.jsonl")"
  sha2_before="$(sha_of "$wt2/.claude/sweep/findings.jsonl")"
  mt1_before="$(mtime_of "$wt1/.claude/sweep/findings.jsonl")"
  mt2_before="$(mtime_of "$wt2/.claude/sweep/findings.jsonl")"

  # Concurrent by construction: both started before either is waited on.
  SWEEP_INVENTORY_FILE="$INVENTORY" SWEEP_CHECKS_DIR="$wt1/checks" \
    bash "$RUNNER" --repo "$wt1" --cadence pr --json > "$TMP/rt2-a.out" 2>"$TMP/rt2-a.err" &
  local p1=$!
  SWEEP_INVENTORY_FILE="$INVENTORY" SWEEP_CHECKS_DIR="$wt2/checks" \
    bash "$RUNNER" --repo "$wt2" --cadence pr --json > "$TMP/rt2-b.out" 2>"$TMP/rt2-b.err" &
  local p2=$!
  local rc1 rc2
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?

  local sha1_after sha2_after mt1_after mt2_after
  sha1_after="$(sha_of "$wt1/.claude/sweep/findings.jsonl")"
  sha2_after="$(sha_of "$wt2/.claude/sweep/findings.jsonl")"
  mt1_after="$(mtime_of "$wt1/.claude/sweep/findings.jsonl")"
  mt2_after="$(mtime_of "$wt2/.claude/sweep/findings.jsonl")"

  [[ "$rc1" == "0" && "$rc2" == "0" ]] \
    && pass "S6(b) [RT-2]: two concurrent --cadence pr runs on two branches both exit 0" \
    || fail "S6(b) [RT-2]: both concurrent pr runs exit 0 (rc1=$rc1 rc2=$rc2; a: $(cat "$TMP/rt2-a.err"); b: $(cat "$TMP/rt2-b.err"))"

  [[ "$sha1_after" == "$sha1_before" && "$sha2_after" == "$sha2_before" \
     && "$mt1_after" == "$mt1_before" && "$mt2_after" == "$mt2_before" ]] \
    && pass "S6(b) [RT-2]: neither concurrent pr run modified findings.jsonl (bytes and mtime unchanged)" \
    || fail "S6(b) [RT-2]: findings.jsonl untouched (sha $sha1_before->$sha1_after / $sha2_before->$sha2_after; mtime $mt1_before->$mt1_after / $mt2_before->$mt2_after)"

  # A pair of runs that silently did nothing would satisfy both assertions
  # above. runs.jsonl is written on every cadence including pr, so its
  # presence with a pr row in each tree is what makes "did not write" mean
  # "chose not to" rather than "never ran" — the failure this whole design
  # exists to refuse.
  local cad1 cad2
  cad1="$(jq -r 'select(.schema=="sweep-run/v1") | .cadence' "$wt1/.claude/sweep/runs.jsonl" 2>/dev/null | tail -1)"
  cad2="$(jq -r 'select(.schema=="sweep-run/v1") | .cadence' "$wt2/.claude/sweep/runs.jsonl" 2>/dev/null | tail -1)"
  [[ "$cad1" == "pr" && "$cad2" == "pr" ]] \
    && pass "S6(b) [RT-2]: both runs really executed — each tree's runs.jsonl carries a pr sweep-run/v1 row" \
    || fail "S6(b) [RT-2]: both runs really executed (cadence rows: '$cad1' / '$cad2')"

  git -C "$base" worktree remove --force "$wt1" >/dev/null 2>&1
  git -C "$base" worktree remove --force "$wt2" >/dev/null 2>&1
}

# ---- (c) RT-5: family block deleted, no skip -------------------------

t_rt5_runner_exits_3() {
  local r; r="$(mkrepo rt5-runner)"; write_config "$r" "$CONFIG_E1_DELETED"
  install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main

  [[ "$RUN_EC" == "3" ]] && grep -Fq "neither declared nor skipped with a reason" <<<"$RUN_ERR" \
    && pass "S6(c) [RT-5]: E1's family block deleted with no skip -> runner exit 3, naming the inventory id" \
    || fail "S6(c) [RT-5]: deleted family block -> exit 3 (ec=$RUN_EC err=$RUN_ERR)"
}

t_rt5_runner_exit_3_writes_no_findings() {
  # Exit 3 is "configuration invalid", and an invalid config must not
  # produce a findings book — a run the stack does not trust is not
  # evidence, and a row written from one would be permanent (risk 11).
  local r; r="$(mkrepo rt5-no-write)"; write_config "$r" "$CONFIG_E1_DELETED"
  install_check "$r" B4 pass-normal.sh
  run_sweep "$r" --cadence push-main

  [[ ! -f "$r/.claude/sweep/findings.jsonl" ]] \
    && pass "S6(c) [RT-5]: exit 3 writes no findings.jsonl" \
    || fail "S6(c) [RT-5]: exit 3 writes no findings.jsonl (file exists: $(cat "$r/.claude/sweep/findings.jsonl"))"
}

# mkfakegh <name> -> a bin dir carrying the fake `gh` from
# tests/test-sweep-liveness.sh (two subcommands: `gh api ... -f
# head_sha=<sha> --jq <filter>` over FAKE_GH_RUNS_STATE, and `gh run view
# <id> --log` over FAKE_GH_LOG_DIR).
mkfakegh() {
  local dir="$TMP/fakegh-$1"; mkdir -p "$dir"
  cat > "$dir/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  api)
    shift
    shift || true
    HEAD_SHA=""; JQ_FILTER="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f) case "${2:-}" in head_sha=*) HEAD_SHA="${2#head_sha=}" ;; esac; shift 2 ;;
        --jq) JQ_FILTER="${2:-.}"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq -c --arg sha "$HEAD_SHA" '{workflow_runs: [.[] | select(.head_sha == $sha)]}' \
      "${FAKE_GH_RUNS_STATE:?}" | jq -r "$JQ_FILTER"
    ;;
  run)
    shift; shift || true
    RUN_ID="${1:-}"; shift || true
    cat "${FAKE_GH_LOG_DIR:?}/$RUN_ID.log" 2>/dev/null
    ;;
  *) echo "fake gh: unsupported command: $*" >&2; exit 1 ;;
esac
FAKEGH
  chmod +x "$dir/gh"
  echo "$dir"
}

t_rt5_liveness_exits_2() {
  # The same deleted-family-block config, seen from OUTSIDE the runner.
  # sweep-liveness.sh asserts against the inventory, never against
  # `families`, so a config that shrank its own family map cannot shrink
  # what liveness expects — E1 is simply missing and stays missing.
  local r="$TMP/rt5-liveness"
  mkdir -p "$r/.claude"
  (
    cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" \
      && git remote add origin "https://github.com/example/rt5.git"
  ) >/dev/null 2>&1
  printf '%s' "$CONFIG_E1_DELETED" | jq . > "$r/.claude/sweep.config.json"

  local sha="rt5deleted01"
  local gh runs logdir
  gh="$(mkfakegh rt5)"
  runs="$TMP/rt5-runs.json"
  jq -n --arg sha "$sha" '[{head_sha:$sha, id:5001, status:"completed", conclusion:"success"}]' > "$runs"
  logdir="$TMP/rt5-logs"; mkdir -p "$logdir"
  # The run's own envelope lists only B4 — E1's block was deleted, so the
  # runner never built a job for it and it never reached the log.
  jq -cn '{schema:"sweep-run/v1", run_id:"2026-08-15T00:00:00Z.rt5", repo:"rt5",
    cadence:"push-main", mode:"observe", writes_findings:true, exit_code:0, findings_n:0,
    sentence:null, checks:[{check_id:"B4", status:"pass", universe_size:3,
    assertions_executed:3, assertions_passed:3, duration_ms:5, findings_n:0, violation:null}]}' \
    | sed 's/^/sweep\trun-sweep\t2026-08-15T09:37:18.9734703Z /' > "$logdir/5001.log"

  local out ec
  out="$(PATH="$gh:$PATH" SWEEP_INVENTORY_FILE="$INVENTORY" \
    FAKE_GH_RUNS_STATE="$runs" FAKE_GH_LOG_DIR="$logdir" \
    bash "$LIVENESS" --head-sha "$sha" --repo "$r" 2>&1)"
  ec=$?

  [[ "$ec" == "2" ]] && grep -Fq "E1 reported no work done" <<<"$out" \
    && grep -Fq "$SENTENCE_TAIL" <<<"$out" \
    && pass "S6(c) [RT-5]: the same deleted block -> sweep-liveness exit 2, naming E1 in the plain sentence" \
    || fail "S6(c) [RT-5]: sweep-liveness exit 2 on the deleted block (ec=$ec out=$out)"
}

# ---- the {{STACK_REF}} substitution contract -------------------------

t_stack_ref_contract_is_written_down() {
  # Task 11's controller ruling: an unsubstituted template must not be
  # able to ship silently. The stack-install direction is guarded by
  # tier-2.json's smoke tests (asserted below); the target-repo direction
  # has no code owner yet, so its refusal rule lives as a written
  # contract in the template the target repo receives. This test is what
  # stops that contract being deleted by someone tidying the header.
  local tpl="$REPO_ROOT/templates/workflows/sweep.yml"
  local smoke_n
  smoke_n="$(jq -r '[.smoke_tests[] | select(test("STACK_REF"))] | length' "$MANIFEST")"

  grep -q "SUBSTITUTION CONTRACT" "$tpl" \
    && grep -q "refuse to write the file if any" "$tpl" \
    && [[ "$smoke_n" == "2" ]] \
    && pass "the {{STACK_REF}} substitution contract is written in the template and guarded by 2 tier-2 smoke tests" \
    || fail "the {{STACK_REF}} substitution contract is documented and smoke-tested (smoke tests naming STACK_REF: $smoke_n)"
}

t_runs_jsonl_gitignore_guidance_is_installed() {
  # Controller ruling: the target repo's .gitignore gains
  # `.claude/sweep/runs.jsonl` when the workflow template is installed.
  # The template is the only artifact the target repo receives, so the
  # guidance lives in its header and is asserted here.
  local tpl="$REPO_ROOT/templates/workflows/sweep.yml"
  grep -q "GITIGNORE CONTRACT" "$tpl" \
    && grep -q "\.claude/sweep/runs\.jsonl" "$tpl" \
    && grep -q "findings\.jsonl — COMMITTED" "$tpl" \
    && pass "the template carries the runs.jsonl-gitignored / findings.jsonl-committed guidance" \
    || fail "the template carries the runs.jsonl gitignore guidance"
}

# ---- the manifest wiring itself --------------------------------------

t_manifest_installs_every_sweep_file() {
  # Every file under scripts/sweep/ in the source tree must have a
  # manifest entry. A check or adapter added later without a manifest
  # line would install a Sweep that is missing a check — the inventory
  # would name it, the runner would find no executable, and the repo
  # would get exit 2 forever.
  local missing="" f rel
  while IFS= read -r f; do
    rel="${f#$REPO_ROOT/}"
    jq -e --arg from "$rel" '[.files.global[] | select(.from == $from)] | length > 0' "$MANIFEST" >/dev/null \
      || missing="$missing $rel"
  done < <(find "$REPO_ROOT/scripts/sweep" -type f | sort)

  [[ -z "$missing" ]] \
    && pass "tier-2.json installs every file under scripts/sweep/" \
    || fail "tier-2.json installs every file under scripts/sweep/ (missing:$missing)"
}

t_manifest_schema_destinations_match_library_expectation() {
  # Both libraries compute their schema path as
  # `<lib>/../../../schemas/<name>.json`. With the lib installed at
  # ~/.claude/scripts/sweep/lib, that resolves to ~/.claude/schemas —
  # so the manifest's `to:` for the two schemas must be exactly that.
  local fr sc
  fr="$(jq -r '.files.global[] | select(.from == "schemas/finding-record.json") | .to' "$MANIFEST")"
  sc="$(jq -r '.files.global[] | select(.from == "schemas/sweep-config.json") | .to' "$MANIFEST")"

  [[ "$fr" == "~/.claude/schemas/finding-record.json" && "$sc" == "~/.claude/schemas/sweep-config.json" ]] \
    && pass "both schemas install where sweep-config.sh and sweep-emit.sh look for them" \
    || fail "schema destinations match the libraries' ../../../schemas hop (finding-record: $fr, sweep-config: $sc)"
}

t_manifest_installs_both_skills() {
  local n
  n="$(jq -r '[.files.global[] | select(.from == "skills/sweep/SKILL.md" or .from == "skills/walkthrough/SKILL.md")] | length' "$MANIFEST")"
  [[ "$n" == "2" ]] \
    && pass "tier-2.json installs both the /sweep and /walkthrough skills" \
    || fail "tier-2.json installs both skills (found $n)"
}

# ---- run ---------------------------------------------------------------

t_vacuous_exit2_meta_finding_and_sentence
t_vacuous_plain_sentence_verbatim
t_installed_config_validation_resolves_its_schema
t_rt2_concurrent_pr_runs_do_not_write
t_rt5_runner_exits_3
t_rt5_runner_exit_3_writes_no_findings
t_rt5_liveness_exits_2
t_stack_ref_contract_is_written_down
t_runs_jsonl_gitignore_guidance_is_installed
t_manifest_installs_every_sweep_file
t_manifest_schema_destinations_match_library_expectation
t_manifest_installs_both_skills

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
