#!/usr/bin/env bash
# scripts/sweep/sweep-run.sh — the Sweep runner (stack ADR-078, spec
# S4.2 / S4.3 / S5.1 / S5.4).
#
# Dispatches every declared check with a sweep-job/v1 on stdin, reads one
# sweep-result/v1 envelope back from the last `SWEEP_RESULT:v1 <base64>`
# line of its stdout, and enforces the six structural liveness invariants
# of spec S4.2 — the invariants live HERE, in the runner, precisely so a
# check cannot opt out of them:
#   1. non-vacuity      pass with 0 assertions is rewritten to fail and
#                       emits the sweep.vacuous-check meta-finding
#   2. default-closed   universe_size 0, or a blank exclusion reason.
#                       ONE declared exemption: a family block carrying a
#                       non-blank string `empty_universe_ok` turns
#                       universe_size 0 into a legal, reason-recorded skip
#                       for that check. Only B4 may declare it (the schema
#                       allows it nowhere else) — B4's universe is the
#                       commits that landed on main in the window, and a
#                       quiet or squash-merging repo can honestly have none.
#   3. skip legality    `skipped` needs a reason declared in the config
#   4. evidence basis   the result's basis must byte-equal the job's, and
#                       the check's env carries no DSN the job did not declare
#   5. surface          the result's surface must byte-equal the job's
#   6. inventory        every inventory id is declared or reason-skipped
#                       (checked before anything runs — exit 3)
#
# Single writer, by construction (spec S4.3): only the push-main, nightly
# and session-close cadences append to findings.jsonl. pr, diff and manual
# render and exit — a finding on an unmerged branch is not yet a fact
# about main, and a file two CI jobs commit is a merge conflict in a
# required-adjacent job.
#
# exit 0 pass / observe · 1 blocking findings · 2 liveness failure (always
# with the plain sentence) · 3 configuration invalid.
#
# SWEEP_INVENTORY_FILE and SWEEP_CHECKS_DIR are test seams; the CLI is
# exactly the one spec S5.4 froze.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib/sweep-config.sh"
# shellcheck source=/dev/null
source "$DIR/lib/sweep-emit.sh"

USAGE="usage: sweep-run.sh --cadence pr|diff|push-main|nightly|session-close|manual [--families A1,A2,E1] [--changed-from <sha>] [--repo <dir>] [--mode observe|warn|block] [--json] [--plain]"

CADENCE=""; FAMILY_FILTER=""; CHANGED_FROM=""; REPO="$PWD"; MODE_OVERRIDE=""
OUT_JSON=0; OUT_PLAIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cadence) CADENCE="${2:-}"; shift 2 ;;
    --families) FAMILY_FILTER="${2:-}"; shift 2 ;;
    --changed-from) CHANGED_FROM="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
    --json) OUT_JSON=1; shift ;;
    --plain) OUT_PLAIN=1; shift ;;
    *) echo "sweep-run: unknown argument '$1'" >&2; echo "$USAGE" >&2; exit 3 ;;
  esac
done

case "$CADENCE" in
  pr|diff|push-main|nightly|session-close|manual) : ;;
  *) echo "sweep-run: --cadence must be one of pr|diff|push-main|nightly|session-close|manual (got: ${CADENCE:-absent})" >&2; exit 3 ;;
esac

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "sweep-run: --repo directory does not exist" >&2; exit 3; }
REPO_NAME="$(basename "$REPO")"
CHECKS_DIR="${SWEEP_CHECKS_DIR:-$DIR/checks}"
CFG="$(sweep_config_path "$REPO")"
SWEEP_DIR="$REPO/.claude/sweep"
FINDINGS="$SWEEP_DIR/findings.jsonl"
RUNS="$SWEEP_DIR/runs.jsonl"
BUDGET_MS=120000

# Invariant 6 runs before a single check does: an inventory check that is
# neither declared nor reason-skipped means the run itself is not trusted.
sweep_config_validate "$REPO" || exit 3

MODE="${MODE_OVERRIDE:-$(jq -r '.mode' "$CFG")}"
case "$MODE" in
  observe|warn|block) : ;;
  *) echo "sweep-run: --mode must be one of observe|warn|block (got: $MODE)" >&2; exit 3 ;;
esac

# The single-writer rule, in one line (spec S4.3).
WRITES_FINDINGS=false
case "$CADENCE" in push-main|nightly|session-close) WRITES_FINDINGS=true ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-run.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"

RUN_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ).$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%Y-%m-%d)"

# selected_checks -> the inventory ids this run dispatches, in inventory
# order: declared family blocks, narrowed by --families when given.
selected_checks() {
  local id filter=",${FAMILY_FILTER// /},"
  for id in $(sweep_inventory_ids); do
    jq -e --arg id "$id" '.families | has($id)' "$CFG" >/dev/null || continue
    [[ -n "$FAMILY_FILTER" && "$filter" != *",$id,"* ]] && continue
    echo "$id"
  done
}

# changed_paths_json -> the diff scope for the job, or null.
changed_paths_json() {
  [[ -n "$CHANGED_FROM" ]] || { echo null; return; }
  git -C "$REPO" diff --name-only "$CHANGED_FROM...HEAD" 2>/dev/null \
    | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# build_job <check_id> -> the sweep-job/v1 this check reads on stdin.
# `connection` is null for every phase-1 check (the `connections` block is
# added in the phase it is first used, spec S5.3), and evidence_basis is
# derived from the connection the runner is willing to inject — never
# self-declared by the check, which is what makes the S4.7 fence real.
build_job() {
  jq -cn --arg id "$1" --arg run "$RUN_ID" --arg repo "$REPO" --arg cadence "$CADENCE" \
    --argjson writes "$WRITES_FINDINGS" --argjson budget "$BUDGET_MS" \
    --argjson changed "$(changed_paths_json)" --slurpfile cfg "$CFG" '
    {schema:"sweep-job/v1", run_id:$run, check_id:$id, repo_root:$repo, cadence:$cadence,
     writes_findings:$writes, evidence_basis:"static-source",
     surface:($cfg[0].surfaces[$id]), config:($cfg[0].families[$id]),
     changed_paths:$changed, connection:null, budget_ms:$budget}'
}

# locate_check <check_id> -> the executable for this id, or empty.
locate_check() {
  local lower path
  lower="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  for path in "$CHECKS_DIR/$lower"-*.sh "$CHECKS_DIR/$lower"-*.mjs; do
    [[ -f "$path" ]] && { echo "$path"; return 0; }
  done
  return 1
}

# build_check_env <check_id> -> fills CHECK_ENV with `env -i` plus an
# explicit allowlist. An allowlist, not a denylist: spec S4.2 invariant 4
# says the runner injects only the connection the job declares, and a
# denylist of two DSN names left DATABASE_URL, PGPASSWORD and every other
# inherited credential reachable from a generated-world check.
#   PATH/HOME/TMPDIR/LANG/LC_ALL — a check cannot run without them.
#   GH_TOKEN/GITHUB_TOKEN — family B asks the GitHub API what CI did; it is
#     not a database credential and cannot satisfy a numbers claim, and B4
#     cannot run in CI without it. Documented here so the widening is a
#     decision, not an accident.
#   the family block's declared base_url_env, and the job's connection
#     dsn_env when one exists (phase 1: never) — declared, therefore granted.
build_check_env() {
  local name declared
  CHECK_ENV=(env -i)
  declared="$(jq -r --arg id "$1" '(.families[$id].base_url_env // empty)' "$CFG")"
  for name in PATH HOME TMPDIR LANG LC_ALL GH_TOKEN GITHUB_TOKEN $declared; do
    [[ -n "${!name:-}" ]] && CHECK_ENV+=("$name=${!name}")
  done
}

# invoke_check <path> <job> <stdout-file> <stderr-file> -> the check's exit code.
invoke_check() {
  local runner=bash
  [[ "$1" == *.mjs ]] && runner=node
  printf '%s' "$2" | "${CHECK_ENV[@]}" "$runner" "$1" >"$3" 2>"$4"
}

# parse_result <stdout-file> -> the envelope JSON, or non-zero when there is
# no result line, the payload does not decode, or it decodes to anything
# other than a JSON object. A scalar or a blank string is not an envelope:
# accepting one made every downstream jq fail and the check vanish from the
# run — green with nothing parsed, the exact shape of NEVER RAN.
parse_result() {
  local line; line="$(grep '^SWEEP_RESULT:v1 ' "$1" | tail -1)"
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null \
    | jq -ce 'select(type == "object")' 2>/dev/null
}

# skip_declared <check_id> -> 0 when the config carries a reason-bearing skip.
skip_declared() {
  jq -e --arg id "$1" '[.skips[]? | select(.check_id == $id and
    (((.reason // "") | gsub("^\\s+|\\s+$"; "") | length) > 0))] | length > 0' "$CFG" >/dev/null 2>&1
}

# envelope_identity_violation <job> <envelope> -> one message, or empty.
# The G4 fence and the surface fence: both are byte-equality against what
# the runner granted, and both fail closed. `status` is checked against the
# S5.1 enum here, because a status outside it (`ok`) walked past invariant
# 1's `status == "pass"` clause and turned a zero-assertion run green.
envelope_identity_violation() {
  jq -r --argjson job "$1" '. as $e |
    if ($e.schema // "") != "sweep-result/v1" then "the result envelope is not sweep-result/v1"
    elif ($e.check_id // "") != $job.check_id then "the result envelope names a different check (\($e.check_id // "absent"))"
    elif (["pass","fail","error","skipped"] | index($e.status // "")) == null then
      "status \($e.status // "absent") is not one of pass|fail|error|skipped"
    elif ($e.evidence_basis // "") != $job.evidence_basis then
      "evidence_basis \($e.evidence_basis // "absent") is not the evidence_basis the job granted (\($job.evidence_basis))"
    elif ($e.surface // "") != $job.surface then
      "surface \($e.surface // "absent") is not the surface the job declared (\($job.surface))"
    elif (($e.universe_size // 0) | type) != "number" then "universe_size is not a number"
    elif (($e.assertions_executed // 0) | type) != "number" then "assertions_executed is not a number"
    elif (($e.excluded // []) | type) != "array" then "excluded is not an array"
    elif (($e.findings // []) | type) != "array" then "findings is not an array"
    else "" end' <<<"$2" \
    || echo "the result envelope could not be inspected — an envelope the runner cannot read is not evidence"
}

# envelope_liveness_violation <check_id> <envelope> -> "<code>|<message>", or empty.
envelope_liveness_violation() {
  local status; status="$(jq -r '.status // ""' <<<"$2")"
  if [[ "$status" == "skipped" ]]; then
    skip_declared "$1" && return 0
    echo "undeclared-skip|reported itself skipped, and the config declares no reason for skipping it"
    return 0
  fi
  jq -r 'if .status == "error" then "check-error|reported an error status — it could not complete, so its result is not evidence"
    elif (.universe_size // 0) == 0 then "empty-universe|reported an empty universe — the selection or its adapter found nothing to check"
    elif ([.excluded[]? | select((((.reason // "") | gsub("^\\s+|\\s+$"; "")) | length) == 0)] | length) > 0 then
      "blank-exclusion|excluded a unit with a blank reason — every exclusion carries a reason a reviewer can read"
    elif (.status == "pass") and ((.assertions_executed // 0) == 0) then
      "vacuous|reported a pass without executing a single assertion"
    else "" end' <<<"$2" \
    || echo "unreadable-envelope|produced an envelope the runner could not inspect"
}

# record_result <check_id> <status> <code> <message> <envelope> [skip_reason]
# Every selected check must leave exactly one row here; the count guard in
# the main flow turns a row that never landed into exit 2. `skip_reason` is
# the declared reason a legal skip was legal — carried separately from
# `violation` because a legal skip is not a violation, and a reader who
# cannot tell the two apart learns nothing from either.
record_result() {
  # The envelope reaches jq through a FILE, never through argv: a month of
  # real B4 findings (~200KB) as an --argjson argument dies with "Argument
  # list too long" on ubuntu runners — which then reported the one check
  # that DID run as the one that never ran.
  local _env_file; _env_file="$(mktemp "${TMPDIR:-/tmp}/sweep-envrow.XXXXXX")" || \
    { echo "sweep-run: could not record a result row for $1" >&2; return 1; }
  printf '%s' "$5" > "$_env_file"
  jq -cn --arg id "$1" --arg status "$2" --arg code "$3" --arg msg "$4" \
    --slurpfile envs "$_env_file" \
    --arg skip "${6:-}" '
    ($envs[0] // {}) as $env |
    {check_id:$id, status:$status,
     violation_code:(if $code == "" then null else $code end),
     violation:(if $msg == "" then null else $msg end),
     skip_reason:(if $skip == "" then null else $skip end),
     universe_size:($env.universe_size // 0),
     assertions_executed:($env.assertions_executed // 0),
     assertions_passed:($env.assertions_passed // 0),
     duration_ms:($env.duration_ms // 0),
     findings:($env.findings // [])}' >> "$RESULTS" \
    || { rm -f "$_env_file"; echo "sweep-run: could not record a result row for $1" >&2; return 1; }
  rm -f "$_env_file"
}

# empty_universe_reason <check_id> -> the family block's declared
# `empty_universe_ok`, trimmed — or empty when it is absent, blank, or not a
# string. Default-closed on purpose: `empty_universe_ok: true` stringifies to
# "true" under `jq -r`, and a boolean that silently reads as a reason is the
# `enabled` flag wearing a new name [RT-5]. Only a sentence buys the skip.
empty_universe_reason() {
  jq -r --arg id "$1" '(.families[$id].empty_universe_ok // "")
    | if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end' "$CFG"
}

# evaluate_envelope <check_id> <job> <envelope>
evaluate_envelope() {
  local msg; msg="$(envelope_identity_violation "$2" "$3")"
  [[ -n "$msg" ]] && { record_result "$1" error "fence" "$msg" '{}'; return; }
  # Invariant 2's one declared exemption: a universe of 0 is a legal skip
  # when the repo's config says, in a sentence, why 0 is the honest answer
  # here (B4 on a quiet or squash-merging repo — see schemas/sweep-config.json).
  # An `error` status is never exempt: a check that could not complete has
  # not established that its universe is empty, it has established nothing.
  local declared_reason
  declared_reason="$(empty_universe_reason "$1")"
  if [[ -n "$declared_reason" ]] \
    && [[ "$(jq -r '.universe_size // 0' <<<"$3")" == "0" ]] \
    && [[ "$(jq -r '.status // ""' <<<"$3")" != "error" ]]; then
    record_result "$1" skipped "" "" "$3" "$declared_reason"
    return
  fi
  local liveness code
  liveness="$(envelope_liveness_violation "$1" "$3")"
  code="${liveness%%|*}"; msg="${liveness#*|}"
  [[ -z "$liveness" ]] && { record_result "$1" "$(jq -r .status <<<"$3")" "" "" "$3"; return; }
  # B1: the rewrite happens in the runner, after the check has exited.
  record_result "$1" fail "$code" "$msg" "$3"
}

# run_one_check <check_id>
run_one_check() {
  local id="$1" path job envelope ec
  path="$(locate_check "$id")" \
    || { record_result "$id" error "no-executable" "is declared in the config but has no executable in $CHECKS_DIR" '{}'; return; }
  job="$(build_job "$id")"
  build_check_env "$id"
  invoke_check "$path" "$job" "$TMP/$id.out" "$TMP/$id.err"; ec=$?
  envelope="$(parse_result "$TMP/$id.out")" || {
    record_result "$id" error "no-result" "exited $ec without printing a result envelope" '{}'
    sed 's/^/  '"$id"': /' "$TMP/$id.err" >&2
    return
  }
  CHECK_PATHS="$CHECK_PATHS $id=$path"
  evaluate_envelope "$id" "$job" "$envelope"
}

# normalize_locus <locus> -> repo-relative, never an absolute machine path.
normalize_locus() {
  local locus="${1#./}"
  locus="${locus#$REPO/}"
  [[ "$locus" == /* ]] && locus="$(basename "$locus")"
  echo "$locus"
}

# hash_locus <locus> -> the normalized locus with any :LINE stripped.
# Line numbers drift with every edit above them; hashing one would mint a
# new finding_id every run and orphan every disposition (RT-10).
hash_locus() { printf '%s' "$(normalize_locus "$1")" | sed -E 's/:[0-9]+$//'; }

# stamp_finding <check_id> <finding> -> the record the emitter receives.
stamp_finding() {
  local id="$1" f="$2" locus fid
  locus="$(jq -r '.evidence.locus // ""' <<<"$f")"
  fid="$(sweep_finding_id "$REPO_NAME" "$id" "$(jq -r '.mechanism // ""' <<<"$f")" \
    "$(hash_locus "$locus")" "$(jq -r '.identity_key // ""' <<<"$f")")"
  jq -c --arg fid "$fid" --arg run "$RUN_ID" --arg repo "$REPO_NAME" --arg now "$NOW" \
    --arg locus "$(normalize_locus "$locus")" '
    .schema = "finding-record/v1" | .finding_id = $fid | .run_id = $run | .repo = $repo
    | .created_at = (.created_at // $now)
    | (if ((.evidence.locus // "") | length) > 0 then .evidence.locus = $locus else . end)' <<<"$f"
}

# vacuous_finding <check_id> -> the sweep.vacuous-check meta-finding.
# `plain` names no check and no file, because it is the G7 sentence the
# user reads; the check id lives in `what`.
vacuous_finding() {
  local id="$1" locus fid
  locus="$(normalize_locus "$(check_path_of "$id")")"
  fid="$(sweep_finding_id "$REPO_NAME" "sweep.vacuous-check" "NEVER RAN" "$(hash_locus "$locus")" "$id")"
  jq -cn --arg fid "$fid" --arg id "$id" --arg run "$RUN_ID" --arg repo "$REPO_NAME" \
    --arg now "$NOW" --arg locus "$locus" '
    {schema:"finding-record/v1", finding_id:$fid, identity_key:$id, run_id:$run, repo:$repo,
     created_at:$now,
     what:"\($id) reported status pass with assertions_executed 0; the runner rewrote it to fail",
     plain:"One of the safety checks reported a pass without doing any work at all, so a green tick on this repo means nothing until it is fixed.",
     mechanism:"NEVER RAN", surface:"ci-gate", surface_source:"declared", found_by:"ci-self-audit",
     evidence:{locus:$locus, measurement:{statement:"checks reporting a pass with zero assertions executed",
       count:1, denominator:1, source:"static-source"}},
     liveness:{assertions_executed:0, assertions_passed:0},
     responsible_agent:null, roster_action:null}'
}

check_path_of() {
  local pair
  for pair in $CHECK_PATHS; do
    [[ "$pair" == "$1="* ]] && { echo "${pair#*=}"; return; }
  done
  echo "$1"
}

# emit_run_findings -> appends every trusted finding, plus one meta-finding
# per vacuous check. Findings from a check that violated the contract are
# never written: an envelope the runner does not trust is not evidence.
emit_run_findings() {
  local id code f
  mkdir -p "$SWEEP_DIR"
  while IFS= read -r row; do
    id="$(jq -r '.check_id' <<<"$row")"; code="$(jq -r '.violation_code // ""' <<<"$row")"
    [[ "$code" == "vacuous" ]] && emit_or_fail "$id" "$(vacuous_finding "$id")"
    [[ -n "$code" ]] && continue
    while IFS= read -r f; do
      [[ -n "$f" ]] && emit_or_fail "$id" "$(stamp_finding "$id" "$f")"
    done < <(jq -c '.findings[]?' <<<"$row")
  done < "$RESULTS"
}

# emit_or_fail <check_id> <record> — an emit refusal is structural: the
# library's rules are the contract, so a refused record is a finding that
# was not recorded, and that is a liveness failure, not a warning.
emit_or_fail() {
  sweep_emit_finding "$FINDINGS" "$2" && return 0
  EMIT_REFUSALS="$EMIT_REFUSALS $1"
  return 0
}

# write_run_row <exit-code> -> the always-on telemetry line (gitignored).
write_run_row() {
  mkdir -p "$SWEEP_DIR"
  jq -sc --arg run "$RUN_ID" --arg cadence "$CADENCE" --arg mode "$MODE" --arg repo "$REPO_NAME" \
    --arg now "$NOW" --argjson ec "$1" --argjson writes "$WRITES_FINDINGS" '
    {schema:"sweep-run/v1", run_id:$run, repo:$repo, cadence:$cadence, mode:$mode,
     started_at:$now, writes_findings:$writes, exit_code:$ec,
     checks:[.[] | {check_id, status, universe_size, assertions_executed, assertions_passed,
                    duration_ms, findings_n:(.findings | length), violation, skip_reason}]}' "$RESULTS" >> "$RUNS"
}

# effective_mode <check_id> -> the per-check mode, defaulting to the global one.
effective_mode() {
  local m; m="$(jq -r --arg id "$1" '.check_modes[$id] // ""' "$CFG")"
  [[ -n "$MODE_OVERRIDE" || -z "$m" ]] && m="$MODE"
  echo "$m"
}

# blocking_findings -> 0 when at least one finding sits at a blocking mode.
blocking_findings() {
  local id n status
  while IFS= read -r row; do
    id="$(jq -r '.check_id' <<<"$row")"
    n="$(jq -r '.findings | length' <<<"$row")"
    status="$(jq -r '.status' <<<"$row")"
    [[ "$n" -gt 0 || "$status" == "fail" ]] || continue
    [[ "$(effective_mode "$id")" == "block" ]] && return 0
  done < "$RESULTS"
  return 1
}

first_violation_check() { jq -r 'select(.violation_code != null) | .check_id' "$RESULTS" | head -1; }

# plain_sentence <check_id> -> the S4.6 sentence. Exit 2 is a sentence,
# not a status code: a red square with no translation is no signal at all.
plain_sentence() {
  echo "The safety checks did not actually run on $TODAY — $1 reported no work done. Until this is fixed, a green tick on this repo means nothing."
}

render_default() {
  local row
  while IFS= read -r row; do
    jq -r '"\(.check_id) \(.status) — universe \(.universe_size), assertions \(.assertions_executed), findings \(.findings | length)\(if .violation then ": \(.violation)" elif .skip_reason then ": \(.skip_reason)" else "" end)"' <<<"$row"
  done < "$RESULTS"
  render_plain
}

render_plain() {
  jq -r '.findings[]? | .plain' "$RESULTS"
  [[ -n "$SENTENCE" ]] && echo "$SENTENCE"
  return 0
}

render_json() {
  jq -sc --arg run "$RUN_ID" --arg cadence "$CADENCE" --arg mode "$MODE" --arg repo "$REPO_NAME" \
    --argjson ec "$1" --argjson writes "$WRITES_FINDINGS" --arg sentence "$SENTENCE" '
    {schema:"sweep-run/v1", run_id:$run, repo:$repo, cadence:$cadence, mode:$mode,
     writes_findings:$writes, exit_code:$ec,
     findings_n:([.[] | .findings | length] | add // 0),
     sentence:(if $sentence == "" then null else $sentence end),
     checks:[.[] | {check_id, status, universe_size, assertions_executed, assertions_passed,
                    duration_ms, findings_n:(.findings | length), violation, skip_reason}]}' "$RESULTS"
}

# unselected_filter_id -> the first --families id this run would not have
# dispatched. A filter naming a check that is skipped, undeclared or
# misspelled otherwise produces a green run over an empty set.
unselected_filter_id() {
  local id
  for id in ${FAMILY_FILTER//,/ }; do
    printf '%s\n' "$SELECTED" | grep -qx "$id" || { echo "$id"; return; }
  done
}

# unrecorded_check -> the first selected check with no row in $RESULTS.
# Every path through run_one_check records exactly one row, so a missing
# row means the runner lost a check somewhere — the same fact B1 exists to
# report, and never something to exit 0 on.
unrecorded_check() {
  local id
  for id in $SELECTED; do
    jq -e --arg id "$id" 'select(.check_id == $id)' "$RESULTS" >/dev/null 2>&1 || { echo "$id"; return; }
  done
}

CHECK_PATHS=""
EMIT_REFUSALS=""
CHECK_ENV=(env -i)   # fails closed if a path ever forgets build_check_env
SELECTED="$(selected_checks)"

if [[ -n "$FAMILY_FILTER" ]]; then
  MISSING_FILTER_ID="$(unselected_filter_id)"
  [[ -n "$MISSING_FILTER_ID" ]] && {
    echo "sweep-run: --families names '$MISSING_FILTER_ID', which this repo does not declare as a family block — nothing would have run for it" >&2
    exit 3
  }
fi

for CHECK_ID in $SELECTED; do run_one_check "$CHECK_ID"; done

[[ "$WRITES_FINDINGS" == "true" ]] && emit_run_findings

VIOLATING_CHECK="$(first_violation_check)"
[[ -z "$VIOLATING_CHECK" ]] && VIOLATING_CHECK="$(unrecorded_check)"
[[ -z "$VIOLATING_CHECK" && -n "$EMIT_REFUSALS" ]] && VIOLATING_CHECK="$(awk '{print $1}' <<<"$EMIT_REFUSALS")"

EXIT_CODE=0
if [[ -n "$VIOLATING_CHECK" ]]; then EXIT_CODE=2
elif blocking_findings; then EXIT_CODE=1
fi

SENTENCE=""
[[ "$EXIT_CODE" == "2" ]] && SENTENCE="$(plain_sentence "$VIOLATING_CHECK")"

write_run_row "$EXIT_CODE"

if [[ "$OUT_JSON" == "1" ]]; then
  render_json "$EXIT_CODE"
  [[ -n "$SENTENCE" ]] && echo "$SENTENCE" >&2
elif [[ "$OUT_PLAIN" == "1" ]]; then
  render_plain
else
  render_default
fi

exit "$EXIT_CODE"
