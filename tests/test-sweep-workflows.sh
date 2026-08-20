#!/usr/bin/env bash
# Tests for templates/workflows/sweep.yml + the required-job snippet
# (stack ADR-078, task 9 of the Sweep serial spine). Static YAML
# assertions — python3 -c 'import yaml' if available, else structured
# grep/awk (house style: tests/test-mcp-sweep.sh's own workflow-content
# checks use the same fallback shape, plus actionlint as the
# authoritative safety net when installed).
#
# Binding contracts asserted here (architect dispatch, task 9):
#   - PR job: `sweep-run.sh --cadence pr`, no git push/commit step, no
#     concurrency group (S4.3 single-writer rule).
#   - push-main + schedule jobs: `concurrency: {group:
#     sweep-findings-write, cancel-in-progress: false}`, invoke
#     `sweep-run.sh --json` (task 8's producer contract).
#   - A rejected-push path in the writer step exits 2 and prints the
#     fixed S4.6 sentence, "The list of findings could not be saved".
#   - The snippet is ONE job, `sweep-liveness`, running
#     `sweep-liveness.sh --head-sha ${{ github.event.pull_request.head.sha || github.sha }}`.
#   - A schedule job exists with a cron (S4.5 nightly cadence).
#   - No `enabled` key anywhere (RT-5 — the Sweep has no per-check
#     enable flag, same rule spot-checked at the workflow level).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/templates/workflows/sweep.yml"
SNIPPET="$REPO_ROOT/templates/workflows/snippets/run-tests-sweep-liveness.yml"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

[[ -f "$WORKFLOW" ]] || { echo "FATAL: $WORKFLOW not found"; echo "----"; echo "test-sweep-workflows: 0 passed, 1 failed"; exit 1; }
[[ -f "$SNIPPET"  ]] || { echo "FATAL: $SNIPPET not found";  echo "----"; echo "test-sweep-workflows: 0 passed, 1 failed"; exit 1; }

WORKFLOW_CONTENT="$(cat "$WORKFLOW")"
SNIPPET_CONTENT="$(cat "$SNIPPET")"

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

# job_block <file> <job-key-regex> -> the lines of that job, from its
# "  <key>:" header (2-space indent, top-level under the `jobs:` map)
# up to (not including) the next 2-space-indented key or EOF. Scoped
# to start only after the top-level `jobs:` line so a job named the
# same as a trigger (e.g. `schedule`) is never confused with the
# `on.schedule` trigger block, which is also 2-space indented. Mirrors
# tests/test-mcp-sweep.sh's awk-range block-extraction convention.
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

# step_block <file> <step-id> -> the lines of the step carrying
# `id: <step-id>`, from that id line up to (not including) the next
# step's `- name:` header or EOF. Scoped tightly enough that a
# `set -o pipefail` in a NEIGHBOURING step can never satisfy an
# assertion about this one — which is the entire point of the CRITICAL
# fix below (the pr run step's status was tee's, not sweep-run's).
step_block() {
  local file="$1" id="$2"
  awk -v id="$id" '
    $0 ~ "^        id: " id "$" { f = 1 }
    f && /^      - name:/ { exit }
    f { print }
  ' "$file"
}

# ---------------------------------------------------------------------
# 1. sweep.yml exists with the three triggers and no top-level `enabled`.
# ---------------------------------------------------------------------
assert_contains "workflow-has-pull-request-trigger" "$WORKFLOW_CONTENT" "pull_request:"
assert_contains "workflow-has-push-main-trigger" "$WORKFLOW_CONTENT" "branches: [main]"
assert_contains "workflow-has-schedule-trigger" "$WORKFLOW_CONTENT" "schedule:"
assert_contains "workflow-has-cron" "$WORKFLOW_CONTENT" "cron:"

if grep -qiw "enabled" "$WORKFLOW" "$SNIPPET"; then
  fail "no-enabled-key-anywhere" "$(grep -inw "enabled" "$WORKFLOW" "$SNIPPET")"
else
  pass "no-enabled-key-anywhere"
fi

# ---------------------------------------------------------------------
# 2. PR job: --cadence pr, no commit/push step, no concurrency group.
# ---------------------------------------------------------------------
PR_BLOCK="$(job_block "$WORKFLOW" "pr")"
assert_contains "pr-job-found" "$PR_BLOCK" "if: github.event_name == 'pull_request'"
assert_contains "pr-job-invokes-cadence-pr" "$PR_BLOCK" "--cadence pr "
assert_not_contains "pr-job-no-git-commit" "$PR_BLOCK" "git commit"
assert_not_contains "pr-job-no-git-push" "$PR_BLOCK" "git push"
assert_not_contains "pr-job-no-concurrency-group" "$PR_BLOCK" "concurrency:"
assert_not_contains "pr-job-permissions-not-write" "$PR_BLOCK" "contents: write"
# B4 reads actions/runs; an explicit permissions block defaults actions to
# none, the call 403s, and (pre-fix) every landing scored as uncovered —
# 209 false findings on the first month of real history.
assert_contains "pr-job-permissions-actions-read" "$PR_BLOCK" "actions: read"
# The pr tick is green whenever the sweep RAN (observe mode) — the job
# name must say so, or a green "sweep" next to failing checks reads as
# "sweep found nothing".
assert_contains "pr-job-name-says-observe-does-not-block" "$PR_BLOCK" "name: sweep (observe — does not block)"
# ...and the PR comment's first line must carry the counts when any check
# failed, so failures are visible without opening a job log.
assert_contains "pr-comment-headline-counts-failed-checks" "$PR_BLOCK" 'checks failed ($FINDINGS_N findings) — observe mode, does not block this merge.'

# ---------------------------------------------------------------------
# 3. Writer jobs (push-main, schedule): concurrency group + --json,
#    correct cadence each, and the rejected-push exit-2 sentence.
# ---------------------------------------------------------------------
PUSH_BLOCK="$(job_block "$WORKFLOW" "push-main")"
SCHEDULE_BLOCK="$(job_block "$WORKFLOW" "schedule")"

for pair in "push-main:$PUSH_BLOCK" "schedule:$SCHEDULE_BLOCK"; do
  jobname="${pair%%:*}"
  block="${pair#*:}"
  assert_contains "${jobname}-job-found" "$block" "runs-on: ubuntu-latest"
  assert_contains "${jobname}-job-has-concurrency-group" "$block" "group: sweep-findings-write"
  assert_contains "${jobname}-job-concurrency-not-cancel-in-progress" "$block" "cancel-in-progress: false"
  assert_contains "${jobname}-job-invokes-json" "$block" "--json"
  assert_contains "${jobname}-job-permissions-write" "$block" "contents: write"
  assert_contains "${jobname}-job-permissions-actions-read" "$block" "actions: read"
  assert_contains "${jobname}-job-git-commit-step-present" "$block" "commit -m"
  # the findings push authenticates as the merge-bot app (a GITHUB_TOKEN
  # push would be suppressed by the recursion guard AND rejected by the
  # PR-only ruleset), so the push target is the token-bearing URL form
  assert_contains "${jobname}-job-git-push-step-present" "$block" 'push "https://x-access-token:${WRITER_TOKEN}@github.com/${GITHUB_REPOSITORY}"'
  assert_contains "${jobname}-job-writer-token-minted" "$block" "id: writer-token"
  assert_contains "${jobname}-job-rejected-push-sentence" "$block" "The list of findings could not be saved"
  assert_contains "${jobname}-job-rejected-push-sentence-second-half" "$block" "Nothing was lost, but nothing was recorded either."
  assert_contains "${jobname}-job-rejected-push-exits-2" "$block" "exit 2"
done

assert_contains "push-main-job-cadence" "$PUSH_BLOCK" "--cadence push-main "
assert_contains "schedule-job-cadence" "$SCHEDULE_BLOCK" "--cadence nightly "

# PR job's contents come first in the file — the concurrency assertion
# above (job_block scoping) already proves the PR job itself carries no
# group; independently confirm the `jobs:` map overall carries exactly
# two `group: sweep-findings-write` occurrences (one per writer job,
# none elsewhere) — scoped past `jobs:` so the header comment's own
# prose quoting the same syntax is not double-counted.
JOBS_SECTION="$(awk '/^jobs:/{f=1} f' "$WORKFLOW")"
GROUP_COUNT="$(grep -c "group: sweep-findings-write" <<<"$JOBS_SECTION" || true)"
assert_eq "exactly-two-writer-concurrency-groups" "2" "${GROUP_COUNT:-0}"

# ---------------------------------------------------------------------
# 4. No artifact upload/download, no unzip (producer contract: the job
#    log itself is the channel, nothing new).
# ---------------------------------------------------------------------
assert_not_contains "no-artifact-upload" "$WORKFLOW_CONTENT" "upload-artifact"
assert_not_contains "no-artifact-download" "$WORKFLOW_CONTENT" "download-artifact"
assert_not_contains "no-unzip" "$WORKFLOW_CONTENT" "unzip"

# ---------------------------------------------------------------------
# 5. Snippet: exactly one job, `sweep-liveness`, running
#    sweep-liveness.sh --head-sha <the exact PR/push fallback expression>.
# ---------------------------------------------------------------------
JOB_KEY_COUNT="$(grep -cE "^  [A-Za-z0-9_-]+:$" "$SNIPPET" || true)"
assert_eq "snippet-has-exactly-one-job-key" "1" "${JOB_KEY_COUNT:-0}"
assert_contains "snippet-job-is-sweep-liveness" "$SNIPPET_CONTENT" "  sweep-liveness:"
assert_contains "snippet-runs-sweep-liveness-sh" "$SNIPPET_CONTENT" "sweep-liveness.sh"
assert_contains "snippet-has-head-sha-flag" "$SNIPPET_CONTENT" "--head-sha"
assert_contains "snippet-head-sha-expression" "$SNIPPET_CONTENT" 'github.event.pull_request.head.sha || github.sha'
assert_not_contains "snippet-no-git-commit" "$SNIPPET_CONTENT" "git commit"
assert_not_contains "snippet-no-git-push" "$SNIPPET_CONTENT" "git push"

# ---------------------------------------------------------------------
# 6. STACK_REF placeholder is documented and used consistently in both
#    files (architect-ruled fallback — no repo precedent found).
# ---------------------------------------------------------------------
assert_contains "workflow-uses-stack-ref-placeholder" "$WORKFLOW_CONTENT" "{{STACK_REF}}"
assert_contains "snippet-uses-stack-ref-placeholder" "$SNIPPET_CONTENT" "{{STACK_REF}}"
assert_contains "workflow-documents-stack-ref-placeholder" "$WORKFLOW_CONTENT" "STACK_REF"

# ---------------------------------------------------------------------
# 7. PR-comment rendering (task 12, controller ruling after task 9 review
#    — spec S4.3's second half: the no-software-skills user never opens a
#    CI job log, so the G7 block must land as a PR comment, not just a
#    job-log line). pr job only: a pull-requests: write permission, a
#    step that renders via sweep-render.sh, a stable hidden marker used
#    to upsert (find-or-create) rather than posting a new comment every
#    run. Writer jobs (push-main, schedule) get none of this.
# ---------------------------------------------------------------------
assert_contains "pr-job-has-pull-requests-write" "$PR_BLOCK" "pull-requests: write"
assert_contains "pr-job-comment-step-uses-sweep-render" "$PR_BLOCK" "sweep-render.sh"
assert_contains "pr-job-comment-step-has-g7-marker" "$PR_BLOCK" "<!-- sweep-g7 -->"

# Upsert pattern: a lookup/find path (locating an existing comment by the
# marker) AND a distinct update path, so a second run on the same PR
# edits the first comment rather than piling on a new one.
assert_contains "pr-job-comment-step-has-find-path" "$PR_BLOCK" "comments"
assert_contains "pr-job-comment-step-has-update-path" "$PR_BLOCK" "PATCH"
assert_contains "pr-job-comment-step-has-create-path" "$PR_BLOCK" "POST"

if grep -qE '\bgh comment create\b' <<<"$PR_BLOCK"; then
  fail "pr-job-comment-step-not-a-bare-create" "a bare create-only invocation would post a new comment every run"
else
  pass "pr-job-comment-step-not-a-bare-create"
fi

# Fix round 1, CRITICAL: on exit 2 (vacuous check, check-error,
# undeclared-skip, blank-exclusion) the pr cadence writes NO finding
# (WRITES_FINDINGS=false), so sweep_render's run-backed path alone would
# post a false-clean "Found nothing worth your attention" comment on a
# run that just FAILED liveness. The step must read `.exit_code` and
# `.sentence` from the captured sweep-run JSON and lead the comment with
# the plain-English liveness sentence when the run failed liveness.
assert_contains "pr-job-comment-step-reads-exit-code" "$PR_BLOCK" ".exit_code"
assert_contains "pr-job-comment-step-reads-sentence" "$PR_BLOCK" ".sentence"

# Fix round 1, IMPORTANT: a fork PR's default GITHUB_TOKEN is read-only,
# so the comment step's gh api calls 403 — that must not fail the whole
# pr job red on an otherwise-clean run. Pinned choice: continue-on-error
# on the comment step; the sweep result (first step) remains the job's
# verdict.
assert_contains "pr-job-comment-step-continue-on-error" "$PR_BLOCK" "continue-on-error: true"

# #223: GitHub runs step scripts with bash -e, so a bare `cmd; rc=$?`
# dies on the command line itself when sweep-run exits nonzero — findings
# are never committed and the saved rc is never reached. The capture must
# ride on the same line (`|| rc=$?`), which -e ignores.
assert_contains "push-main-rc-capture-survives-errexit" "$PUSH_BLOCK" '--json || rc=$?'
assert_contains "schedule-rc-capture-survives-errexit" "$SCHEDULE_BLOCK" '--json || rc=$?'

# Round-10 live loop: the writer's own findings commit re-triggers the
# workflow and is itself a new B4 landing — one new finding per cycle,
# forever. The push-main job must skip itself on sweep bookkeeping
# commits while the run itself still fires (that run is B4's coverage).
assert_contains "push-main-writer-skips-own-findings-commits" "$PUSH_BLOCK" "startsWith(github.event.head_commit.message, 'chore(sweep):')"

# Writer jobs never gained a PR-comment step or the write scope — the
# single-writer rule (findings) is untouched by the rendering half.
assert_not_contains "push-main-job-no-pull-requests-write" "$PUSH_BLOCK" "pull-requests: write"
assert_not_contains "push-main-job-no-sweep-render" "$PUSH_BLOCK" "sweep-render.sh"
assert_not_contains "push-main-job-no-g7-marker" "$PUSH_BLOCK" "<!-- sweep-g7 -->"
assert_not_contains "schedule-job-no-pull-requests-write" "$SCHEDULE_BLOCK" "pull-requests: write"
assert_not_contains "schedule-job-no-sweep-render" "$SCHEDULE_BLOCK" "sweep-render.sh"
assert_not_contains "schedule-job-no-g7-marker" "$SCHEDULE_BLOCK" "<!-- sweep-g7 -->"

# No new concurrency group introduced by this task — still exactly two,
# both on the writer jobs (re-asserted here since the count is the one
# invariant a careless PR-comment addition could quietly break).
GROUP_COUNT_AFTER_TASK12="$(grep -c "group: sweep-findings-write" <<<"$JOBS_SECTION" || true)"
assert_eq "still-exactly-two-writer-concurrency-groups" "2" "${GROUP_COUNT_AFTER_TASK12:-0}"

# ---------------------------------------------------------------------
# 8. Fix round 2, CRITICAL: the pr job's run step pipes sweep-run.sh into
#    `tee`. GitHub's default shell is `bash -e {0}` — `-e` WITHOUT
#    `pipefail`, so the step's status is tee's (always 0) and the pr job
#    could not fail on sweep-run's exit 1, 2 or 3. The step must set
#    pipefail itself, in its own body (the writer steps' style), and the
#    assertion is scoped to that step so a neighbour's pipefail cannot
#    satisfy it.
#
#    Same section: every job carries `timeout-minutes`. sweep-run.sh
#    passes budget_ms to each check but nothing enforces it, so a check
#    that hangs would hang the job until GitHub's 6-hour default — the
#    triaged mitigation is a job-level wall clock.
# ---------------------------------------------------------------------
PR_RUN_STEP="$(step_block "$WORKFLOW" "sweep-run-pr")"
assert_contains "pr-run-step-found" "$PR_RUN_STEP" "sweep-run.sh --cadence pr"
assert_contains "pr-run-step-sets-pipefail" "$PR_RUN_STEP" "pipefail"
assert_contains "pr-run-step-pipes-to-tee" "$PR_RUN_STEP" "tee "

for jobpair in "pr:$PR_BLOCK" "push-main:$PUSH_BLOCK" "schedule:$SCHEDULE_BLOCK"; do
  jobname="${jobpair%%:*}"
  block="${jobpair#*:}"
  assert_contains "${jobname}-job-has-timeout-minutes" "$block" "timeout-minutes: 15"
done

TIMEOUT_COUNT="$(grep -c "^    timeout-minutes:" <<<"$JOBS_SECTION" || true)"
assert_eq "exactly-three-job-level-timeouts" "3" "${TIMEOUT_COUNT:-0}"

# ---------------------------------------------------------------------
# 9. Fix round 2, IMPORTANT: the PR-comment step on an empty/unparseable
#    sweep-pr.json. On exit 3 sweep-run.sh exits before render_json, so the
#    file is zero bytes; `jq -r '.exit_code'` on it prints nothing and
#    exits 0, and the step used to sail into sweep_render and post
#    "Found nothing worth your attention" for a run that produced no
#    results at all.
#
#    These are EXECUTED, not grepped: the step's own `run:` body is
#    extracted from the YAML, the two `${{ }}` expressions are substituted
#    with fixtures, and it is run against a fake workspace with a stub
#    `gh` and a stub sweep-render.sh. A grep can prove the guard is
#    written; only running it proves the guard is reached.
# ---------------------------------------------------------------------
assert_contains "pr-comment-step-guards-on-nonempty-file" "$PR_BLOCK" '-s "$RUN_JSON"'
assert_contains "pr-comment-step-checks-a-real-run-row" "$PR_BLOCK" "runs.jsonl"
assert_contains "pr-comment-step-honest-failure-sentence" "$PR_BLOCK" "The safety checks could not run"

COMMENT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-comment-step.XXXXXX")"
trap 'rm -rf "$COMMENT_TMP"' EXIT

G7_CLEAN="Found nothing worth your attention"
RUNNER_SENTENCE="The safety checks did not actually run on 2026-08-15 — B4 reported no work done."

# extract_run_script <step-id> -> that step's `run:` body, dedented, with
# the workflow's two `${{ }}` expressions replaced by test fixtures.
extract_run_script() {
  step_block "$WORKFLOW" "$1" \
    | awk 'f { sub(/^          /, ""); print } /^        run: \|/ { f = 1 }' \
    | sed -e 's|\${{ github.repository }}|test-owner/test-repo|g' \
          -e 's|\${{ github.event.pull_request.number }}|7|g'
}

# run_comment_step <sweep-pr.json content> <runs.jsonl content>
# -> sets COMMENT_BODY to the body the stub `gh` was asked to post.
run_comment_step() {
  local payload="$1" runs="$2"
  local ws; ws="$(mktemp -d "$COMMENT_TMP/ws.XXXXXX")"
  mkdir -p "$ws/.sweep-stack/scripts/sweep" "$ws/.claude/sweep" "$ws/runner-temp" "$ws/bin"

  printf 'sweep_render() { echo "Checked 3 screens and 0 background jobs. %s. Nothing else changed."; }\n' \
    "$G7_CLEAN" > "$ws/.sweep-stack/scripts/sweep/sweep-render.sh"
  printf '%s' "$payload" > "$ws/runner-temp/sweep-pr.json"
  printf '%s' "$runs" > "$ws/.claude/sweep/runs.jsonl"

  cat > "$ws/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
METHOD=GET; BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) METHOD="${2:-}"; shift 2 ;;
    -f) [[ "${2:-}" == body=* ]] && BODY="${2#body=}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$METHOD" == "GET" ]] && exit 0   # no existing comment -> the POST path
printf '%s' "$BODY" > "$FAKE_GH_BODY_FILE"
STUBGH
  chmod +x "$ws/bin/gh"

  extract_run_script sweep-comment-pr > "$ws/step.sh"
  ( cd "$ws" && PATH="$ws/bin:$PATH" RUNNER_TEMP="$ws/runner-temp" GITHUB_WORKSPACE="$ws" \
      GH_TOKEN=stub FAKE_GH_BODY_FILE="$ws/gh.body" bash "$ws/step.sh" ) >/dev/null 2>&1
  COMMENT_BODY="$(cat "$ws/gh.body" 2>/dev/null)"
}

RUN_ROW='{"schema":"sweep-run/v1","run_id":"2026-08-15T00:00:00Z.abc123","cadence":"pr","exit_code":0}'
CLEAN_JSON='{"schema":"sweep-run/v1","run_id":"2026-08-15T00:00:00Z.abc123","exit_code":0,"sentence":null}'

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the PR-comment step's behaviour is not executed here."
else
  # (a) exit 3: the runner died before render_json, so the file is empty.
  run_comment_step "" "$RUN_ROW"
  if [[ "$COMMENT_BODY" == *"The safety checks could not run"* && "$COMMENT_BODY" != *"$G7_CLEAN"* ]]; then
    pass "comment-step-empty-file-posts-honest-sentence-not-a-clean-g7-block"
  else
    fail "comment-step-empty-file-posts-honest-sentence-not-a-clean-g7-block" "got: $COMMENT_BODY"
  fi

  # (b) a truncated / unparseable file is the same failure, not a pass.
  run_comment_step '{"schema":"sweep-run/v1","run_i' "$RUN_ROW"
  if [[ "$COMMENT_BODY" == *"The safety checks could not run"* && "$COMMENT_BODY" != *"$G7_CLEAN"* ]]; then
    pass "comment-step-unparseable-file-posts-honest-sentence"
  else
    fail "comment-step-unparseable-file-posts-honest-sentence" "got: $COMMENT_BODY"
  fi

  # (c) exit 2: the runner's OWN sentence leads, and no G7 block follows it.
  run_comment_step "$(jq -cn --arg s "$RUNNER_SENTENCE" \
    '{schema:"sweep-run/v1", run_id:"2026-08-15T00:00:00Z.abc123", exit_code:2, sentence:$s}')" "$RUN_ROW"
  if [[ "$COMMENT_BODY" == *"$RUNNER_SENTENCE"* && "$COMMENT_BODY" != *"$G7_CLEAN"* ]]; then
    pass "comment-step-exit-2-keeps-the-runners-own-sentence-and-posts-no-g7-block"
  else
    fail "comment-step-exit-2-keeps-the-runners-own-sentence-and-posts-no-g7-block" "got: $COMMENT_BODY"
  fi

  # (d) exit 0 with a real run row: the G7 block is posted, as designed.
  run_comment_step "$CLEAN_JSON" "$RUN_ROW"
  if [[ "$COMMENT_BODY" == *"$G7_CLEAN"* && "$COMMENT_BODY" == *"<!-- sweep-g7 -->"* ]]; then
    pass "comment-step-exit-0-with-a-real-run-row-posts-the-g7-block"
  else
    fail "comment-step-exit-0-with-a-real-run-row-posts-the-g7-block" "got: $COMMENT_BODY"
  fi

  # (e) exit 0 but no run row for that run_id — the run did not land, so
  #     there is nothing honest to render.
  run_comment_step "$CLEAN_JSON" '{"schema":"sweep-run/v1","run_id":"some-other-run","exit_code":0}'
  if [[ "$COMMENT_BODY" == *"The safety checks could not run"* && "$COMMENT_BODY" != *"$G7_CLEAN"* ]]; then
    pass "comment-step-exit-0-without-a-run-row-posts-no-g7-block"
  else
    fail "comment-step-exit-0-without-a-run-row-posts-no-g7-block" "got: $COMMENT_BODY"
  fi

  # (f) observe mode with failing checks: the comment's FIRST line carries
  #     the counts, ahead of the G7 block — a green tick means "ran", never
  #     "passed", and the comment is the one surface a reader actually sees.
  FAILING_JSON="$(jq -cn '{schema:"sweep-run/v1", run_id:"2026-08-15T00:00:00Z.abc123",
    exit_code:1, sentence:null, findings_n:212, checks:[
      {check_id:"B4", status:"fail", findings_n:209},
      {check_id:"A1", status:"pass", findings_n:0},
      {check_id:"A2", status:"pass", findings_n:0},
      {check_id:"A4", status:"fail", findings_n:3}]}')"
  run_comment_step "$FAILING_JSON" "$RUN_ROW"
  HEADLINE_WANT="2 of 4 checks failed (212 findings) — observe mode, does not block this merge."
  FIRST_CONTENT_LINE="$(sed -n '2p' <<<"$COMMENT_BODY")"
  if [[ "$FIRST_CONTENT_LINE" == *"$HEADLINE_WANT"* && "$COMMENT_BODY" == *"$G7_CLEAN"* ]]; then
    pass "comment-step-failing-checks-lead-with-counts-before-the-g7-block"
  else
    fail "comment-step-failing-checks-lead-with-counts-before-the-g7-block" "got: $COMMENT_BODY"
  fi

  # (g) all checks passing: no failure headline is prepended.
  ALL_PASS_JSON="$(jq -cn '{schema:"sweep-run/v1", run_id:"2026-08-15T00:00:00Z.abc123",
    exit_code:0, sentence:null, findings_n:0, checks:[
      {check_id:"A1", status:"pass", findings_n:0},
      {check_id:"B4", status:"pass", findings_n:0}]}')"
  run_comment_step "$ALL_PASS_JSON" "$RUN_ROW"
  if [[ "$COMMENT_BODY" == *"$G7_CLEAN"* && "$COMMENT_BODY" != *"checks failed"* ]]; then
    pass "comment-step-all-passing-posts-no-failure-headline"
  else
    fail "comment-step-all-passing-posts-no-failure-headline" "got: $COMMENT_BODY"
  fi
fi

# ---------------------------------------------------------------------
# 10. YAML validity. Real parse via PyYAML when available; otherwise the
#    greps above are the coverage (house fallback, matches the brief).
#    The snippet is deliberately a fragment (no top-level `on:`/`jobs:`
#    — it is pasted under an existing workflow's `jobs:` key) so it is
#    only actionlint-checked as a mapping fragment via PyYAML, not
#    actionlint (which requires a full workflow).
# ---------------------------------------------------------------------
if python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 - "$WORKFLOW" << 'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
# YAML 1.1: an unquoted `on:` key parses as boolean True, not the string "on"
on = doc.get("on", doc.get(True))
assert "pull_request" in on
assert on["push"]["branches"] == ["main"]
assert "schedule" in on
jobs = doc["jobs"]
assert set(jobs.keys()) == {"pr", "push-main", "schedule"}
assert "concurrency" not in jobs["pr"]
assert jobs["push-main"]["concurrency"]["group"] == "sweep-findings-write"
assert jobs["schedule"]["concurrency"]["group"] == "sweep-findings-write"
for name in ("pr", "push-main", "schedule"):
    assert jobs[name]["timeout-minutes"] == 15, f"{name} has no 15-minute job timeout"
pr_run = [s for s in jobs["pr"]["steps"] if s.get("id") == "sweep-run-pr"][0]
assert "pipefail" in pr_run["run"], "the pr run step pipes into tee without pipefail"
sys.exit(0)
PYEOF
  then
    pass "pyyaml-structural-parse"
  else
    fail "pyyaml-structural-parse"
  fi

  if python3 - "$SNIPPET" << 'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert set(doc.keys()) == {"sweep-liveness"}
sys.exit(0)
PYEOF
  then
    pass "pyyaml-snippet-single-job"
  else
    fail "pyyaml-snippet-single-job"
  fi
else
  echo "SKIP: python3 'yaml' module not installed — structural greps above are the coverage."
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW" >/dev/null 2>&1; then
    pass "actionlint-clean"
  else
    fail "actionlint-clean" "$(actionlint "$WORKFLOW" 2>&1)"
  fi
else
  echo "SKIP: actionlint not installed — sweep.yml validity not independently checked beyond the greps above."
fi

echo "----"
echo "test-sweep-workflows: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
