#!/usr/bin/env bash
# Tests for scripts/sweep/checks/a1-writer-callers.sh (stack ADR-078, spec
# S4.6 A1). A1 asks whether every exported writer in the config-declared
# glob universe has a detected caller, by reusing the stack's existing
# scripts/usage-check.sh (stack ADR-057) rather than reimplementing
# reference search — the DISCONNECTED mechanism class, the single largest
# bucket in the 29-bug audit (28%).
#
# Real fixture files + the REAL scripts/usage-check.sh are used for the
# happy-path cases (an unused writer really is unused, a called writer
# really is called — no fake needed, usage-check.sh's own ripgrep/grep
# search is deterministic and fast). The fail-closed case fakes
# usage-check.sh via SWEEP_USAGE_CHECK (a1's own test seam, mirroring
# sweep-run.sh's SWEEP_INVENTORY_FILE / SWEEP_CHECKS_DIR pattern) — the real
# checker essentially never errors on a valid symbol target, so a fault
# injection there has to be a substitute script, not a natural failure mode.
#
# Every emitted finding is also round-tripped through the real
# sweep-emit.sh (sourced, not shelled out to), same as tests/test-sweep-b4.sh,
# to prove the finding actually survives R1-R7 and the finding-record/v1
# schema, not just this check's own envelope shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/a1-writer-callers.sh"
EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"
RUNNER="$REPO_ROOT/scripts/sweep/sweep-run.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
[ -f "$RUNNER" ] || { echo "FATAL: $RUNNER not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a1-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_fixture_repo <name> -> a throwaway plain directory (usage-check.sh's
# symbol search needs no git repo — it greps/rgs the tree directly).
new_fixture_repo() {
  local d="$TMP/repo-$1"
  mkdir -p "$d/lib"
  echo "$d"
}

# build_job <repo> <writer_globs-json> <exclusions-json> -> a sweep-job/v1
# for check_id A1 (spec S5.1 shape, families.A1 config per schemas/sweep-config.json).
build_job() {
  jq -cn --arg repo "$1" --argjson globs "$2" --argjson excl "$3" \
    '{schema:"sweep-job/v1", run_id:"2026-08-15T00:00:00Z.test01", check_id:"A1",
      repo_root:$repo, cadence:"pr", writes_findings:false,
      evidence_basis:"static-source", surface:"write-path",
      config:{writer_globs:$globs, exclusions:$excl},
      changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <repo> <globs-json> <exclusions-json> [fake-usage-check] -> sets ENV_OUT.
run_check() {
  local repo="$1" globs="$2" excl="$3" fake="${4:-}" job out line
  job="$(build_job "$repo" "$globs" "$excl")"
  if [[ -n "$fake" ]]; then
    out="$(printf '%s' "$job" | SWEEP_USAGE_CHECK="$fake" bash "$CHECK")"
  else
    out="$(printf '%s' "$job" | bash "$CHECK")"
  fi
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$out" | tail -1)"
  ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
}

# ---- catch-proof 1: an exported writer nothing calls -> finding emitted ----

t_unused_writer_produces_finding() {
  local r; r="$(new_fixture_repo unused)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeOrphan(x) {
  return x + 1;
}
EOF
  run_check "$r" '["lib/*.js"]' '[]'

  local status universe assertions passed findings_n mech surface found ident locus
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  mech="$(jq -r '.findings[0].mechanism' <<<"$ENV_OUT")"
  surface="$(jq -r '.findings[0].surface' <<<"$ENV_OUT")"
  found="$(jq -r '.findings[0].found_by' <<<"$ENV_OUT")"
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  locus="$(jq -r '.findings[0].evidence.locus' <<<"$ENV_OUT")"

  [[ "$status" == "fail" && "$universe" == "1" && "$assertions" == "1" && "$passed" == "0" \
     && "$findings_n" == "1" && "$mech" == "DISCONNECTED" && "$surface" == "write-path" \
     && "$found" == "sweep-family-A" && "$ident" == "writeOrphan" && "$locus" == "lib/writers.js:1" ]] \
    && pass "an exported writer nothing calls -> one DISCONNECTED finding, identity_key = symbol name" \
    || fail "unused writer finding (status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n mech=$mech surface=$surface found=$found ident=$ident locus=$locus)"
}

t_unused_writer_finding_survives_emit() {
  local r; r="$(new_fixture_repo unused-emit)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeOrphan(x) {
  return x + 1;
}
EOF
  run_check "$r" '["lib/*.js"]' '[]'

  local f fid ident stamped findings_out
  f="$(jq -c '.findings[0]' <<<"$ENV_OUT")"
  ident="$(jq -r '.identity_key' <<<"$f")"
  fid="$(sweep_finding_id "$(basename "$r")" A1 "DISCONNECTED" "lib/writers.js" "$ident")"
  stamped="$(jq -c --arg fid "$fid" --arg repo "$(basename "$r")" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo=$repo | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    [[ "$(wc -l < "$findings_out" | tr -d ' ')" == "1" ]] \
      && pass "unused-writer finding survives sweep_emit_finding (R1-R7 + finding-record/v1 schema)" \
      || fail "unused-writer finding survives emit (wrote $(wc -l < "$findings_out") lines)"
  else
    fail "unused-writer finding survives emit (refused: $(cat "$TMP/emit.err"))"
  fi
}

# ---- catch-proof 2: a called writer -> no finding ----

t_called_writer_produces_no_finding() {
  local r; r="$(new_fixture_repo called)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeUsed(x) {
  return x + 1;
}
EOF
  cat > "$r/lib/caller.js" <<'EOF'
import { writeUsed } from './writers';
writeUsed(2);
EOF
  run_check "$r" '["lib/*.js"]' '[]'

  local status universe assertions passed findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  [[ "$status" == "pass" && "$universe" == "1" && "$assertions" == "1" && "$passed" == "1" \
     && "$findings_n" == "0" ]] \
    && pass "a called writer -> pass, no finding, assertions_passed 1/1" \
    || fail "called writer no finding (status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n)"
}

t_mixed_called_and_uncalled_isolates_the_orphan() {
  local r; r="$(new_fixture_repo mixed)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeUsed(x) {
  return x + 1;
}
export function writeOrphanToo(x) {
  return x - 1;
}
EOF
  cat > "$r/lib/caller.js" <<'EOF'
import { writeUsed } from './writers';
writeUsed(2);
EOF
  run_check "$r" '["lib/*.js"]' '[]'

  local universe findings_n ident
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"

  [[ "$universe" == "2" && "$findings_n" == "1" && "$ident" == "writeOrphanToo" ]] \
    && pass "mixed universe: the called writer is silent, only the uncalled one is a finding" \
    || fail "mixed universe (universe=$universe findings=$findings_n ident=$ident)"
}

# ---- exclusions: B2 default-closed surface, echoed back with reasons ----

t_excluded_writer_is_not_analyzed_and_is_echoed_with_reason() {
  local r; r="$(new_fixture_repo excluded)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeGrandfathered(x) {
  return x;
}
EOF
  run_check "$r" '["lib/*.js"]' '[{"unit":"writeGrandfathered","reason":"legacy import artifact, ADR-041"}]'

  local universe findings_n excl_unit excl_reason
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  excl_unit="$(jq -r '.excluded[0].unit' <<<"$ENV_OUT")"
  excl_reason="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"

  [[ "$universe" == "0" && "$findings_n" == "0" && "$excl_unit" == "writeGrandfathered" \
     && "$excl_reason" == "legacy import artifact, ADR-041" ]] \
    && pass "an excluded writer is dropped from the universe and echoed back in excluded[] with its reason" \
    || fail "exclusion (universe=$universe findings=$findings_n unit=$excl_unit reason=$excl_reason)"
}

# ---- catch-proof 3: empty universe -> honest zero, consistent with b4 ----

t_empty_universe_reports_zero_honestly() {
  local r; r="$(new_fixture_repo empty)"
  # writer_globs matches nothing in this repo.
  run_check "$r" '["lib/*.js"]' '[]'

  local status universe assertions findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  # Mirrors b4's t_quiet_window_reports_zero_honestly: the check's job is to
  # report an empty universe honestly (status pass, 0 assertions, 0
  # findings) and leave B1/B2's verdict to the runner — never to fabricate a
  # nonzero universe or a finding to dodge that verdict.
  [[ "$status" == "pass" && "$universe" == "0" && "$assertions" == "0" && "$findings_n" == "0" ]] \
    && pass "empty universe (globs match nothing): reported honestly, no fabricated findings" \
    || fail "empty universe reported honestly (status=$status universe=$universe assertions=$assertions findings=$findings_n)"
}

# Unlike B4, A1's schema (schemas/sweep-config.json) carries no
# empty_universe_ok escape hatch — only B4 may declare it. So an A1 with an
# empty universe has no legal skip at all: it is always exit 2 through the
# real runner. This is "status handling consistent with b4's quiet-repo
# behavior" for the UNDECLARED half specifically (b4's t_quiet_repo_without_declaration_exits_2).
CHECKS_DIR="$REPO_ROOT/scripts/sweep/checks"
CONFIG_EMPTY_A1='{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{"A1":"write-path"},"families":{"A1":{"writer_globs":["lib/*.js"],"exclusions":[]}},"skips":[]}'

run_runner() {
  local repo="$1" cfg="$2"
  mkdir -p "$repo/.claude/sweep"
  jq . <<<"$cfg" > "$repo/.claude/sweep.config.json"
  printf 'A1\n' > "$repo/inventory.txt"
  RUN_OUT="$(SWEEP_INVENTORY_FILE="$repo/inventory.txt" SWEEP_CHECKS_DIR="$CHECKS_DIR" \
    bash "$RUNNER" --repo "$repo" --cadence manual --json 2>"$TMP/runner.err")"
  RUN_EC=$?
  RUN_ERR="$(cat "$TMP/runner.err")"
}

t_empty_universe_through_real_runner_exits_2() {
  local r; r="$(new_fixture_repo empty-runner)"   # writer_globs matches nothing
  run_runner "$r" "$CONFIG_EMPTY_A1"
  local st; st="$(jq -r '.checks[] | select(.check_id=="A1") | .status' <<<"$RUN_OUT" 2>/dev/null)"
  [[ "$RUN_EC" == "2" && "$st" == "fail" ]] \
    && pass "empty universe through the real runner: A1 has no empty_universe_ok escape hatch -> exit 2, same shape as b4's undeclared-quiet-repo case" \
    || fail "empty universe through real runner -> exit 2 (ec=$RUN_EC status=$st out=$RUN_OUT err=$RUN_ERR)"
}

# ---- catch-proof 4: usage-check failure -> fail-closed, not silently pass ----

# mkfake_usage_check_failing -> a fake usage-check.sh that always exits
# non-zero and prints no verdict= line, simulating the reused checker being
# broken/unreachable. Fail-closed means A1 must NOT treat that as "used"
# (a silent pass hiding a possibly-real DISCONNECTED bug).
#
# Direct-invocation only, not through sweep-run.sh: build_check_env's `env
# -i` allowlist (PATH/HOME/TMPDIR/LANG/LC_ALL/GH_TOKEN/GITHUB_TOKEN plus the
# family block's declared base_url_env) is load-bearing S4.2-invariant-4
# fencing, and SWEEP_USAGE_CHECK is deliberately not on it — a repo config
# cannot redirect which usage-check.sh a real run consults. So this seam is
# reachable only by invoking the check directly, which is exactly where the
# fail-closed contract this test proves actually lives (the check's own
# CALL_FAILED handling), not in the runner.
mkfake_usage_check_failing() {
  local f="$TMP/fake-usage-check-failing.sh"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
echo "usage-check: internal error, no search performed" >&2
exit 3
FAKE
  chmod +x "$f"
  echo "$f"
}

t_usage_check_failure_fails_closed() {
  local r; r="$(new_fixture_repo uc-fail)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeMaybe(x) {
  return x;
}
EOF
  local fake; fake="$(mkfake_usage_check_failing)"
  run_check "$r" '["lib/*.js"]' '[]' "$fake"

  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"

  # The load-bearing assertion: status must be "error" (the one envelope
  # status the runner's envelope_liveness_violation never treats as
  # trustworthy evidence), never "pass" — a silent pass here would mean a
  # real DISCONNECTED writer sailed through because its usage-check call
  # happened to fail.
  [[ "$status" == "error" ]] \
    && pass "usage-check.sh failure -> status error (fail-closed), never a silent pass" \
    || fail "usage-check.sh failure fail-closed (status=$status findings=$findings_n, want status=error)"
}

t_unused_writer_produces_finding
t_unused_writer_finding_survives_emit
t_called_writer_produces_no_finding
t_mixed_called_and_uncalled_isolates_the_orphan
t_excluded_writer_is_not_analyzed_and_is_echoed_with_reason
t_empty_universe_reports_zero_honestly
# ---- couldn't-look ≠ found-nothing (2026-08-19 census): an unreadable
# writer file must error out, never silently shrink the universe ----
t_unreadable_writer_file_is_check_error() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "SKIP: running as root — chmod 000 cannot make a file unreadable"
    return 0
  fi
  local r; r="$(new_fixture_repo unreadable)"
  cat > "$r/lib/writers.js" <<'EOF'
export function writeSomething(x) { return x; }
EOF
  chmod 000 "$r/lib/writers.js"
  run_check "$r" '["lib/*.js"]' '[]'
  chmod 644 "$r/lib/writers.js"
  local status findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  [[ "$status" == "error" && "$findings_n" == "0" ]] \
    && pass "unreadable writer file: status error, universe never silently shrunk" \
    || fail "unreadable writer file (status=$status findings=$findings_n)"
}

t_empty_universe_through_real_runner_exits_2
t_usage_check_failure_fails_closed
t_unreadable_writer_file_is_check_error

echo "----"
echo "test-sweep-a1: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
