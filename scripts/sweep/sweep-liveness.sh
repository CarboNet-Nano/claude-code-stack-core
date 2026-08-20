#!/usr/bin/env bash
# scripts/sweep/sweep-liveness.sh — B5, the Sweep's own liveness probe
# (stack ADR-078, spec S4.6 B5 / S5.4; task 8 of the Sweep serial spine).
#
# Lives OUTSIDE the runner by construction (spec S4.6): a runner cannot
# report that it was never invoked. This script runs as a REQUIRED job in
# `run-tests.yml` (Task 9 wires the one-line addition; decision 6 makes
# liveness block from day one, independent of the finding ladder) and
# answers exactly one question: did a `sweep.yml` run happen for this
# commit, concluded, and produce evidence for every check in the
# INSTALLED INVENTORY (scripts/sweep/inventory.txt) minus the repo's
# reason-carrying skips?
#
# Deliberately asserts against the inventory file, never against the
# repo's `sweep.config.json` `families` keys [RT-5]: a config that
# silently drops a family block (no skip entry) shrinks its own
# `families` map, but the inventory file is the stack's, not the repo's,
# and this script never reads `families` to decide what "should" have
# run — only to see what a skip claims.
#
# This validation is INDEPENDENT of `sweep-config.sh`'s
# `sweep_config_validate` (exit-3 config validation, invoked only by
# `sweep-run.sh`). B5 does not source that library and does not run
# `sweep-run.sh`. It reads the inventory file and the repo's
# `sweep.config.json` `skips[]` array directly with its own few lines of
# jq, so the RT-5 bypass is caught even in a world where config
# validation itself was bypassed, disabled, or never ran — the whole
# point of a liveness probe that "lives outside the runner".
#
# ---------------------------------------------------------------------
# THE ARTIFACT CONTRACT (designed here; Task 9's sweep.yml template must
# implement the producer side; the controller carries this note into
# Task 9's dispatch). Fix round 1 replaced the original render_default
# prose-scraping design with the runner's frozen structured `--json`
# output, so this couples to a spec-frozen schema tag (`sweep-run/v1`)
# instead of rendering code that could reformat under this script's feet.
#
# Producer (Task 9, sweep.yml's push-main and schedule/nightly jobs):
#   Invoke `scripts/sweep/sweep-run.sh --cadence push-main|nightly ... --json`.
#   sweep-run.sh's existing `render_json()` (unmodified — this task does
#   not touch the runner) already prints exactly one compact JSON line,
#   `{"schema":"sweep-run/v1", ..., "checks":[{"check_id":..., "status":...,
#   ...}, ...]}`, to its own stdout, listing every check id it actually
#   dispatched (i.e. every id present in `sweep.config.json`'s `families`
#   block, narrowed by any `--families` filter — never a skipped id,
#   which never gets a job built at all). GitHub Actions captures a
#   job's stdout as the run's log verbatim; no extra plumbing required
#   from the template beyond "run the command and do not redirect its
#   stdout away". No artifact upload/download, no unzip — bash + jq only.
#
# Consumer (this script):
#   1. `gh api repos/<owner>/<repo>/actions/workflows/sweep.yml/runs \
#        -f head_sha=<sha> --jq '.workflow_runs[0] // empty'`
#      -> the most recent sweep.yml run for this commit (or none).
#   2. Require `.status == "completed"` ("concluded", spec wording).
#   3. `gh run view <run_id> --repo <owner>/<repo> --log`
#      -> the run's full combined log, plain text. CONFIRMED against a
#      live run (gh run view 31877453757 --log): every line carries a
#      `<job>\t<step>\t<timestamp> ` prefix before the content — this
#      script's extraction must tolerate that prefix, and does, by
#      matching the JSON object itself rather than anchoring on
#      line-start (step 4).
#   4. Find the log line(s) containing a JSON object starting at
#      `{"schema":"sweep-run/v1"` (via `grep -o`, which ignores whatever
#      prefix precedes it on the line), validate each with `jq -e
#      'select(.schema=="sweep-run/v1")'`, and take the LAST one that
#      parses (a retried/re-run job could log more than one). Read
#      `.checks[].check_id` from it as the "envelope set" — the set of
#      check ids the run structurally proves it dispatched. A raw,
#      unprefixed line (a local/non-CI log, or the object placed alone on
#      its own line) is accepted identically, since the match is on the
#      JSON object's own leading bytes, not on line-start.
#   5. A check id from the inventory is COVERED iff it is in the
#      envelope set, OR the repo's `sweep.config.json` has a `skips[]`
#      entry `{check_id, reason}` for it with a non-blank reason.
#   6. Any inventory id that is neither covered nor skipped -> exit 2,
#      naming it in the plain sentence.
#
# `sweep-run/v1`'s schema tag is spec-frozen (S5.1); if Task 9 changes
# what fields `--json` emits under that same schema, only step 4's field
# access needs to move — the schema tag itself is the contract, not the
# renderer's code path (which this script never sources or executes).
# ---------------------------------------------------------------------
#
# CLI: sweep-liveness.sh --head-sha <sha> [--repo <dir>]
# exit 0  the Sweep ran, concluded, and covered every inventory check id
# exit 2  anything else — missing run, unconcluded run, or an inventory
#         check id neither in the envelope set nor reason-skipped.
#         ALWAYS prints the S4.6 plain sentence to stdout. The single
#         EXCEPTION is a CLI-usage error (missing/malformed --head-sha,
#         via usage()): that exit 2 is a caller mistake, not a liveness
#         verdict about the Sweep, and intentionally carries no sentence.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: sweep-liveness.sh --head-sha <sha> [--repo <dir>]" >&2
  exit 2
}

HEAD_SHA=""
REPO="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --head-sha) HEAD_SHA="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$HEAD_SHA" ]] || usage

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "sweep-liveness: --repo directory does not exist" >&2; exit 2; }

INVENTORY="${SWEEP_INVENTORY_FILE:-$SCRIPT_DIR/inventory.txt}"
CONFIG="$REPO/.claude/sweep.config.json"

# plain_sentence <named-check> -> the S4.6 sentence, byte-identical to
# sweep-run.sh's plain_sentence() (duplicated intentionally: this script
# does not source the runner).
plain_sentence() {
  local today; today="$(date -u +%Y-%m-%d)"
  echo "The safety checks did not actually run on $today — $1 reported no work done. Until this is fixed, a green tick on this repo means nothing."
}

fail_with() {
  plain_sentence "$1"
  exit 2
}

command -v jq >/dev/null 2>&1 || { echo "sweep-liveness: jq not found" >&2; fail_with "the Sweep (jq is not available)"; }
command -v gh >/dev/null 2>&1 || { echo "sweep-liveness: gh not found" >&2; fail_with "the Sweep (gh is not available)"; }

[[ -f "$INVENTORY" ]] || fail_with "the Sweep (no check inventory installed)"
[[ -f "$CONFIG" ]] || fail_with "the Sweep (no sweep.config.json in this repo)"

# inventory_ids -> one check id per line, comments and blanks dropped
# (matches sweep-config.sh's sweep_inventory_ids(), duplicated so this
# script has no dependency on that library).
inventory_ids() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$INVENTORY" | grep -v '^$'
}

# owner_repo -> "owner/repo" parsed from the origin remote (b4-merge-run.sh's
# owner_repo(), duplicated per house style — no shared lib for it).
owner_repo() {
  git -C "$REPO" remote get-url origin 2>/dev/null \
    | sed -E 's#^(git@|https://|http://)?(github\.com[:/])?##; s#\.git$##'
}

OWNER_REPO="$(owner_repo)"
[[ -n "$OWNER_REPO" ]] || fail_with "the Sweep (no origin remote to ask GitHub about)"

# `2>/dev/null` on every `gh` call below is fail-closed by design, not a
# convenience: a `gh` error (auth failure, rate limit, network hiccup)
# leaves the corresponding variable empty, which every downstream check
# in this script treats as "not proven" -> exit 2. There is no code path
# where a `gh` failure is read as success.
# --method GET is load-bearing: with -f present gh would otherwise POST,
# the list endpoint would 404, and liveness could never find the run it
# exists to verify (#222).
# On a pull request both workflows start together, so this job usually
# WINS the race against the sweep.yml run it exists to verify (round-7
# live failure). Poll with a bounded deadline instead of failing the
# first read: the assertion is unchanged — a run must exist AND have
# concluded — only scheduling latency is tolerated. Fail-closed stands:
# no run, or a run still unconcluded at the deadline, is exit 2.
WAIT_SECS="${SWEEP_LIVENESS_WAIT_SECS:-600}"
POLL_SECS="${SWEEP_LIVENESS_POLL_SECS:-15}"
DEADLINE=$(( SECONDS + WAIT_SECS ))
RUN_JSON=""
RUN_STATUS=""
RUN_ID=""
while :; do
  RUN_JSON="$(gh api "repos/$OWNER_REPO/actions/workflows/sweep.yml/runs" --method GET -f head_sha="$HEAD_SHA" --jq '.workflow_runs[0] // empty' 2>/dev/null)"
  if [[ -n "$RUN_JSON" ]]; then
    RUN_STATUS="$(jq -r '.status // ""' <<<"$RUN_JSON")"
    RUN_ID="$(jq -r '.id // empty' <<<"$RUN_JSON")"
    [[ "$RUN_STATUS" == "completed" ]] && break
  fi
  (( SECONDS >= DEADLINE )) && break
  sleep "$POLL_SECS"
done
[[ -n "$RUN_JSON" ]] || fail_with "the Sweep (no sweep.yml run found for $HEAD_SHA)"
[[ -n "$RUN_ID" ]] || fail_with "the Sweep (the sweep.yml run for $HEAD_SHA could not be read)"
[[ "$RUN_STATUS" == "completed" ]] || fail_with "the Sweep (the sweep.yml run for $HEAD_SHA has not concluded)"

LOG="$(gh run view "$RUN_ID" --repo "$OWNER_REPO" --log 2>/dev/null)"

# envelope_ids -> the set of check ids the run's log proves it
# dispatched (the artifact contract above, step 4). `grep -o` matches the
# JSON object wherever it starts on the line, so a real CI log's
# `<job>\t<step>\t<timestamp> ` prefix (confirmed live, gh run view
# 31877453757 --log) is simply left out of the match — no prefix
# stripping needed. The `jq -ce 'select(...)'` pass re-validates each
# candidate (a `grep -o` match is a byte-pattern hit, not proof of valid
# JSON) and `tail -1` takes the most recent if the log logged more than
# one (e.g. a re-run).
JSON_LINE="$(printf '%s\n' "$LOG" \
  | grep -o '{"schema":"sweep-run/v1".*}' \
  | while IFS= read -r candidate; do jq -ce 'select(.schema == "sweep-run/v1")' <<<"$candidate" 2>/dev/null; done \
  | tail -1)"
ENVELOPE_IDS="$(jq -r '.checks[]?.check_id // empty' <<<"$JSON_LINE" 2>/dev/null | sort -u)"

# skip_reason <check_id> -> the first non-blank skips[] reason for this
# id in the repo's config, or empty.
skip_reason() {
  jq -r --arg id "$1" '
    def blank($s): ($s // "") | tostring | gsub("^\\s+|\\s+$"; "") | length == 0;
    [.skips[]? | select(.check_id == $id and (blank(.reason) | not)) | .reason] | first // empty
  ' "$CONFIG" 2>/dev/null
}

MISSING=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  grep -qx "$id" <<<"$ENVELOPE_IDS" && continue
  [[ -n "$(skip_reason "$id")" ]] && continue
  MISSING+=("$id")
done < <(inventory_ids)

if [[ "${#MISSING[@]}" -gt 0 ]]; then
  NAMED="$(printf '%s, ' "${MISSING[@]}")"
  fail_with "${NAMED%, }"
fi

echo "sweep-liveness: sweep.yml run $RUN_ID for $HEAD_SHA concluded, every inventory check id is covered (ran or reason-skipped)"
exit 0
