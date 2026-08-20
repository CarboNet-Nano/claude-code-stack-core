#!/usr/bin/env bash
# Tests for .github/workflows/detection-cadence.yml + its two factored libs
# (scripts/lib/detection-cadence-churn.sh, scripts/lib/detection-cadence-issue.sh)
# — stack ADR-082 spec P1e. NO network anywhere: the workflow's YAML is
# asserted structurally (house style: tests/test-sweep-workflows.sh's
# job_block/assert_contains convention), the churn-selection logic is driven
# against real throwaway git fixtures (ties + zero-churn cases), and the
# duplicate-branch logic is driven against a stubbed `improvement-queue.sh`
# and a stubbed `gh` — never the real network-touching scripts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/detection-cadence.yml"
CHURN_LIB="$REPO_ROOT/scripts/lib/detection-cadence-churn.sh"
ISSUE_LIB="$REPO_ROOT/scripts/lib/detection-cadence-issue.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

[[ -f "$WORKFLOW"  ]] || { echo "FATAL: $WORKFLOW not found";  echo "----"; echo "test-detection-cadence: 0 passed, 1 failed"; exit 1; }
[[ -f "$CHURN_LIB"  ]] || { echo "FATAL: $CHURN_LIB not found";  echo "----"; echo "test-detection-cadence: 0 passed, 1 failed"; exit 1; }
[[ -f "$ISSUE_LIB"  ]] || { echo "FATAL: $ISSUE_LIB not found";  echo "----"; echo "test-detection-cadence: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/detection-cadence-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

WORKFLOW_CONTENT="$(cat "$WORKFLOW")"

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "expected to contain [$needle]"; fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "expected NOT to contain [$needle]"; fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}

# job_block <file> <job-key-regex> -> the lines of that job (house convention,
# borrowed verbatim from tests/test-sweep-workflows.sh).
job_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_jobs = 0; in_job = 0 }
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:/ {
      if (in_job) { exit }
      if ($0 ~ "^  " key ":") { in_job = 1 }
    }
    in_job { print }
  ' "$file"
}

# ---------------------------------------------------------------------
# 1. Triggers: both crons present, workflow_dispatch too, no `enabled` key.
# ---------------------------------------------------------------------
assert_contains "fortnightly-cron-present" "$WORKFLOW_CONTENT" "0 14 1,15 * *"
assert_contains "monthly-cron-present" "$WORKFLOW_CONTENT" "0 14 1 * *"
assert_contains "workflow-dispatch-present" "$WORKFLOW_CONTENT" "workflow_dispatch:"

if grep -qiw "enabled" "$WORKFLOW"; then
  fail "no-enabled-key" "$(grep -inw "enabled" "$WORKFLOW")"
else
  pass "no-enabled-key"
fi

# ---------------------------------------------------------------------
# 2. Permissions block (architect nit: repo's own gh token, issues: write).
# ---------------------------------------------------------------------
assert_contains "permissions-issues-write" "$WORKFLOW_CONTENT" "issues: write"
assert_contains "permissions-contents-read" "$WORKFLOW_CONTENT" "contents: read"

# ---------------------------------------------------------------------
# 3. Both jobs exist and are gated to their own cron (a schedule fan-out
#    into two jobs must not let the monthly job fire on the fortnightly tick
#    or vice versa).
# ---------------------------------------------------------------------
WALK_BLOCK="$(job_block "$WORKFLOW" "walkthrough-cadence")"
CROSS_BLOCK="$(job_block "$WORKFLOW" "cross-family-review-cadence")"

assert_contains "walkthrough-job-found" "$WALK_BLOCK" "runs-on: ubuntu-latest"
assert_contains "walkthrough-job-gated-to-its-cron" "$WALK_BLOCK" "0 14 1,15 * *"
assert_not_contains "walkthrough-job-not-gated-to-monthly-cron-alone" "$WALK_BLOCK" "github.event.schedule == '0 14 1 * *'"

assert_contains "cross-family-job-found" "$CROSS_BLOCK" "runs-on: ubuntu-latest"
assert_contains "cross-family-job-gated-to-its-cron" "$CROSS_BLOCK" "0 14 1 * *"

# ---------------------------------------------------------------------
# 4. Owner resolution: absent detection_cadence block is a clean no-op with
#    a log line, never a hard failure. (families.A5 / other blocks are none
#    of this workflow's business — it reads exactly one key.)
# ---------------------------------------------------------------------
for pair in "walkthrough:$WALK_BLOCK" "cross-family:$CROSS_BLOCK"; do
  jobname="${pair%%:*}"; block="${pair#*:}"
  assert_contains "${jobname}-reads-detection-cadence-owner" "$block" ".detection_cadence.owner"
  assert_contains "${jobname}-logs-on-absent-owner" "$block" "clean no-op"
  assert_contains "${jobname}-steps-gated-on-owner" "$block" "steps.owner.outputs.owner != ''"
done

# ---------------------------------------------------------------------
# 5. The queue's single writer, with the spec's exact flags. Never a raw
#    `gh issue create` (LB6/LB7) — the workflow must not shell out to gh to
#    MAKE an issue, only to comment/label/assign one the writer already made.
# ---------------------------------------------------------------------
assert_contains "walkthrough-calls-single-writer" "$WALK_BLOCK" "scripts/improvement-queue.sh add"
assert_contains "walkthrough-title-exact" "$WALK_BLOCK" "walkthrough due \$DATE - run /walkthrough"
assert_contains "walkthrough-where-exact" "$WALK_BLOCK" "--where \".claude/sweep.config.json\""
assert_contains "walkthrough-why-exact" "$WALK_BLOCK" "detection cadence (ADR-082) - humans found 31 percent of the 29-bug audit"
assert_contains "walkthrough-effort-kind-source-flags" "$WALK_BLOCK" "--effort 30m --kind test-gap --source manual"

assert_contains "cross-family-calls-single-writer" "$CROSS_BLOCK" "scripts/improvement-queue.sh add"
assert_contains "cross-family-title-prefix-exact" "$CROSS_BLOCK" "cross-family review due - \$TOPDIR"
assert_contains "cross-family-no-churn-title-exact" "$CROSS_BLOCK" "cross-family review due - no churn - confirm and close"
assert_contains "cross-family-effort-kind-source-flags" "$CROSS_BLOCK" "--effort 30m --kind test-gap --source manual"

for pair in "walkthrough:$WALK_BLOCK" "cross-family:$CROSS_BLOCK"; do
  jobname="${pair%%:*}"; block="${pair#*:}"
  if grep -qE '\bgh issue create\b' <<<"$block"; then
    fail "${jobname}-never-raw-gh-issue-create" "found a bare gh issue create in $jobname"
  else
    pass "${jobname}-never-raw-gh-issue-create"
  fi
done

# ---------------------------------------------------------------------
# 6. Colon-free titles (LB-D: the writer's own allowlist would silently
#    strip a colon anyway, but the workflow's literal title strings must
#    not carry one to begin with — a stripped colon is still evidence of a
#    sloppy title).
# ---------------------------------------------------------------------
WALK_TITLE_LINE="$(grep -F 'walkthrough due $DATE' "$WORKFLOW")"
CROSS_TITLE_LINE_1="$(grep -F 'cross-family review due - $TOPDIR' "$WORKFLOW")"
CROSS_TITLE_LINE_2="$(grep -F 'cross-family review due - no churn' "$WORKFLOW")"

for pair in "walkthrough-title:$WALK_TITLE_LINE" "cross-family-title-1:$CROSS_TITLE_LINE_1" "cross-family-title-2:$CROSS_TITLE_LINE_2"; do
  name="${pair%%:*}"; line="${pair#*:}"
  # Strip the leading `TITLE="` / `--title "` shell syntax before checking
  # for a colon in the actual title text.
  title_only="$(printf '%s' "$line" | sed -E 's/^ *(TITLE=|--title )"//')"
  if [[ "$title_only" == *":"* ]]; then
    fail "${name}-colon-free" "found a colon in: $line"
  else
    pass "${name}-colon-free"
  fi
done

# ---------------------------------------------------------------------
# 7. Label + assignee steps (via the factored dc_handle_writer_result — the
#    literal --add-label/--add-assignee flags live in the sourced lib, so
#    this asserts the workflow actually calls into it with the right args).
# ---------------------------------------------------------------------
for pair in "walkthrough:$WALK_BLOCK" "cross-family:$CROSS_BLOCK"; do
  jobname="${pair%%:*}"; block="${pair#*:}"
  assert_contains "${jobname}-sources-issue-lib" "$block" "source scripts/lib/detection-cadence-issue.sh"
  assert_contains "${jobname}-calls-dc-handle-writer-result" "$block" "dc_handle_writer_result"
  assert_contains "${jobname}-passes-detection-cadence-label" "$block" "\"detection-cadence\""
  assert_contains "${jobname}-passes-owner-as-assignee" "$block" "steps.owner.outputs.owner"
done
assert_contains "issue-lib-add-label-flag" "$(cat "$ISSUE_LIB")" "--add-label"
assert_contains "issue-lib-add-assignee-flag" "$(cat "$ISSUE_LIB")" "--add-assignee"

# ---------------------------------------------------------------------
# 8. Idempotency: the tick comment on a duplicate, keyed on the writer's own
#    dedup result — never a second title-prefix dedup key invented here.
# ---------------------------------------------------------------------
assert_contains "issue-lib-branches-on-dup-prefix" "$(cat "$ISSUE_LIB")" 'dup:*'
assert_contains "issue-lib-tick-comment-sentence" "$(cat "$ISSUE_LIB")" "cadence tick \$date - still open"
assert_contains "issue-lib-comments-via-gh" "$(cat "$ISSUE_LIB")" "gh issue comment"

# ---------------------------------------------------------------------
# 9. actionlint, when installed — the same authoritative safety net
#    tests/test-sweep-workflows.sh uses.
# ---------------------------------------------------------------------
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW" >/dev/null 2>&1; then
    pass "actionlint-clean"
  else
    fail "actionlint-clean" "$(actionlint "$WORKFLOW" 2>&1)"
  fi
else
  echo "SKIP: actionlint not installed — YAML validity not independently checked beyond the greps above."
fi

# =======================================================================
# 10. Churn-selection logic (scripts/lib/detection-cadence-churn.sh),
#     driven against real throwaway git fixture repos. NO network.
# =======================================================================

new_churn_repo() {  # new_churn_repo <name> -> repo root
  local r="$TMP/churn-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t )
  printf '%s' "$r"
}

commit_files() {  # commit_files <repo> <iso-date> <msg> <file>...
  local r="$1" date="$2" msg="$3"; shift 3
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$r/$f")"
    echo x > "$r/$f"
  done
  ( cd "$r" && git add -A \
      && GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git commit -q -m "$msg" )
}

# (a) a clear winner, and a single commit touching two files in the same
#     bucket must count ONCE for that bucket, not twice (the audit-relevant
#     bug this test exists to catch).
R1="$(new_churn_repo winner)"
commit_files "$R1" "2025-01-01T00:00:00Z" "outside the window" "old/dir/file.txt"
commit_files "$R1" "2026-08-10T00:00:00Z" "two files, one bucket, one commit" "alpha/one/a.txt" "alpha/one/b.txt"
commit_files "$R1" "2026-08-11T00:00:00Z" "one file, other bucket" "beta/two/c.txt"
commit_files "$R1" "2026-08-12T00:00:00Z" "second alpha commit" "alpha/one/d.txt"
source "$CHURN_LIB"
WINNER="$(dc_top_churn_dir "$R1" "2026-08-01")"
assert_eq "churn-picks-the-higher-commit-count-bucket" "alpha/one" "$WINNER"

# (b) ties broken alphabetically.
R2="$(new_churn_repo tie)"
commit_files "$R2" "2026-08-05T00:00:00Z" "zulu commit" "zulu/dir/f1.txt"
commit_files "$R2" "2026-08-06T00:00:00Z" "alpha commit" "alpha/dir/f1.txt"
TIE_WINNER="$(dc_top_churn_dir "$R2" "2026-08-01")"
assert_eq "churn-tie-breaks-alphabetically" "alpha/dir" "$TIE_WINNER"

# (c) zero churn since the cutoff -> empty, not an error, not a stale guess.
R3="$(new_churn_repo zero)"
commit_files "$R3" "2026-01-01T00:00:00Z" "long before the cutoff" "gamma/dir/f1.txt"
ZERO="$(dc_top_churn_dir "$R3" "2026-08-01")"
assert_eq "churn-zero-since-cutoff-is-empty" "" "$ZERO"

# (d) a root-level file with no directory component contributes to no
#     bucket at all (nothing to attribute churn to).
R4="$(new_churn_repo rootfile)"
commit_files "$R4" "2026-08-05T00:00:00Z" "root file only" "README.md"
ROOTFILE_RESULT="$(dc_top_churn_dir "$R4" "2026-08-01")"
assert_eq "churn-root-level-file-attributes-to-no-bucket" "" "$ROOTFILE_RESULT"

# (e) depth capped at two segments: a file three levels deep buckets under
#     its first two segments, not its full path.
R5="$(new_churn_repo depth)"
commit_files "$R5" "2026-08-05T00:00:00Z" "three levels deep" "scripts/sweep/checks/a5.sh"
DEPTH_RESULT="$(dc_top_churn_dir "$R5" "2026-08-01")"
assert_eq "churn-buckets-cap-at-depth-two" "scripts/sweep" "$DEPTH_RESULT"

# (f) no explicit since -> defaults to a 30-day window (dc_since_arg), so a
#     commit from today is picked up with no second argument at all.
R6="$(new_churn_repo default-window)"
TODAY_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
commit_files "$R6" "$TODAY_ISO" "today, no since given" "delta/dir/f1.txt"
DEFAULT_WINDOW_RESULT="$(dc_top_churn_dir "$R6")"
assert_eq "churn-default-window-picks-up-a-commit-from-today" "delta/dir" "$DEFAULT_WINDOW_RESULT"

# =======================================================================
# 11. Duplicate-branch logic (scripts/lib/detection-cadence-issue.sh),
#     driven against a stub `gh` AND (per the spec) a stubbed
#     improvement-queue.sh — no network anywhere.
# =======================================================================

GH_LOG="$TMP/gh.log"
GH_STUB_DIR="$TMP/gh-stub"; mkdir -p "$GH_STUB_DIR"
cat > "$GH_STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG_FILE"
exit "${GH_STUB_RC:-0}"
EOF
chmod +x "$GH_STUB_DIR/gh"

run_handle_writer_result() {  # run_handle_writer_result <rc> <out> -> sets HWR_RC
  : > "$GH_LOG"
  ( source "$ISSUE_LIB"
    GH_LOG_FILE="$GH_LOG" PATH="$GH_STUB_DIR:$PATH" \
      dc_handle_writer_result "$1" "$2" "example/repo" "detection-cadence" "octocat" "2026-08-16" )
  HWR_RC=$?
}

# (a) a real, stubbed improvement-queue.sh returning a duplicate — the
#     branch logic must comment the fixed tick sentence, never create or
#     label anything.
FAKE_IQ="$TMP/fake-improvement-queue.sh"
cat > "$FAKE_IQ" <<'EOF'
#!/usr/bin/env bash
echo "dup:42"
exit 0
EOF
chmod +x "$FAKE_IQ"
FAKE_ADD_OUT="$(bash "$FAKE_IQ" add --title t --where w --why y --effort 30m --kind test-gap --source manual)"
FAKE_ADD_RC=$?
run_handle_writer_result "$FAKE_ADD_RC" "$FAKE_ADD_OUT"
assert_eq "duplicate-branch-rc-is-clean" "0" "$HWR_RC"
assert_contains "duplicate-branch-comments-tick-sentence" "$(cat "$GH_LOG")" "gh issue comment 42 --repo example/repo --body cadence tick 2026-08-16 - still open"
assert_not_contains "duplicate-branch-never-labels" "$(cat "$GH_LOG")" "issue edit"
assert_not_contains "duplicate-branch-never-creates" "$(cat "$GH_LOG")" "issue create"

# (b) a created issue — labels + assigns, never comments.
run_handle_writer_result "0" '{"id":"7","title":"walkthrough due 2026-08-16 - run /walkthrough"}'
assert_eq "created-branch-rc-is-clean" "0" "$HWR_RC"
assert_contains "created-branch-labels-and-assigns" "$(cat "$GH_LOG")" "gh issue edit 7 --repo example/repo --add-label detection-cadence --add-assignee octocat"
assert_not_contains "created-branch-never-comments" "$(cat "$GH_LOG")" "issue comment"

# (c) a spooled entry (GitHub unreachable) — not a failure, and nothing to
#     label yet.
run_handle_writer_result "0" "spooled:abc-123"
assert_eq "spooled-branch-rc-is-clean" "0" "$HWR_RC"
assert_eq "spooled-branch-calls-gh-nothing" "" "$(cat "$GH_LOG")"

# (d) the writer itself failed (validation/backend error) — the workflow
#     step, and therefore the job, must fail. Non-vacuity, machine-defined
#     (spec: "workflow fails if the add/comment fails").
run_handle_writer_result "2" "improvement-queue: add: bad-where-grammar"
assert_eq "writer-failure-propagates-nonzero" "2" "$HWR_RC"

echo "----"
echo "test-detection-cadence: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
