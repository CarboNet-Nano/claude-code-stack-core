#!/usr/bin/env bash
# scripts/sweep/checks/b4-merge-run.sh — B4: does every commit that LANDS on
# main produce a push-triggered CI run? (stack ADR-078, spec S4.6 B4; task 6 of
# the Sweep serial spine). Reproduces audit row #21's second half: a
# GITHUB_TOKEN merge that never triggers `push` while the repo stays
# green.
#
# Reads sweep-job/v1 on stdin (task 4's contract), asks `git` for the commits
# that landed on main (first-parent) in the last 30 days, asks `gh api`
# whether each sha has a push-triggered workflow run, and emits one
# sweep-result/v1 envelope
# as the LAST stdout line, `SWEEP_RESULT:v1 <base64>` (spec S5.1). Exit
# code is not the contract the runner reads — that line is.
#
# `identity_key` embeds the commit sha grouped into runs of 3 hex chars,
# never 4 or more. This is load-bearing, not just R1-avoidance: this check
# never sets `evidence.locus` (there is no file:line for "a commit has no
# run"; `evidence.commit` is the natural field), and sweep-run.sh's
# stamp_finding computes finding_id's locus input from `evidence.locus`
# ONLY — `evidence.commit` never participates in the hash. So for B4,
# `identity_key` is the ONLY source of per-commit distinctness in
# finding_id; if it collapsed to one constant string, every uncovered
# commit in a run would collide onto the same finding_id. The grouping
# also happens to defeat R1 (a raw git sha, ~62% digit-valued hex chars,
# would trip R1's 4+-digit-run refusal on a large fraction of real
# commits by chance), but that is a second, smaller reason, not the
# primary one. `evidence.commit` carries the real, ungrouped sha for
# human/audit reading; it has no R1-style restriction because it is never
# hashed.
#
# Follow-up (filed, not this task's scope): once sweep-run.sh's
# stamp_finding folds `evidence.commit` into finding_id's hash inputs
# (phase 2), `identity_key` here can drop the sha entirely and become a
# semantic name like "push-run-missing" — the commit would then supply
# distinctness on its own, the way it should for a "the thing found" that
# is genuinely a specific commit instance.

set -uo pipefail

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"

START="$SECONDS"

# owner_repo -> "owner/repo" parsed from the origin remote. gh needs an
# explicit repo target: the runner never `cd`s into repo_root before
# invoking a check (only `git -C`/`gh --repo`-style targeting is safe).
owner_repo() {
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^(git@|https://|http://)?(github\.com[:/])?##; s#\.git$##'
}

# grouped_id <sha> -> "push-run-<sha, grouped into runs of 3 hex chars>".
# Groups of 3 guarantee no run of 4+ consecutive digits and never form a
# UUID's 8-4 split, so this can never trip R1 the way a raw sha could.
grouped_id() {
  local short="${1:0:16}" grouped="" i=0
  while [[ "$i" -lt "${#short}" ]]; do
    grouped="${grouped:+$grouped-}${short:$i:3}"
    i=$((i + 3))
  done
  echo "push-run-$grouped"
}

# covered_push_shas <owner/repo> -> every head sha with a push-triggered
# workflow run in the last ~31 days, one per line. ONE paginated listing
# instead of one API call per landing: the first live CI run proved the
# per-sha shape busts the 120s budget on a month of real history (~200
# sequential calls, killed before the envelope printed). `created` bounds
# the listing server-side; --paginate walks the remainder. --method GET
# is load-bearing: with -f fields present gh would otherwise POST, the
# list endpoint would 404, and every landing would read as uncovered
# (#221).
_b4_since_date() {
  date -u -d "31 days ago" +%Y-%m-%d 2>/dev/null \
    || date -u -v-31d +%Y-%m-%d 2>/dev/null
}
covered_push_shas() {
  gh api "repos/$1/actions/runs" --method GET --paginate \
    -f event=push -f per_page=100 -f "created=>=$(_b4_since_date)" \
    --jq '.workflow_runs[].head_sha' 2>/dev/null
}

OWNER_REPO="$(owner_repo)"

# Universe: every commit that LANDED on main in the last 30 days —
# first-parent, not `--merges`.
#
# Fix round 2, IMPORTANT (I3). `--merges` was a literal reading of "merge
# commits": actual 2-parent merges only. On a repo that squash-merges (the
# GitHub default on a great many repos) every pull request lands as an
# ordinary single-parent commit, so `--merges` returned nothing, the
# universe was 0, and the runner's invariant 2 reported NEVER RAN on every
# run — against a repo whose CI was working perfectly. A check that cries
# NEVER RAN at a healthy repo teaches its reader to ignore it, which is the
# same outcome as not running at all.
#
# `--first-parent` is the right universe because it is exactly the set of
# landings: squash commits, true merge commits and direct pushes all sit on
# main's first-parent chain, and every one of them should have produced a
# push-triggered run. Commits INSIDE a merged branch are deliberately
# excluded — they never triggered a push run on main and were never meant
# to; counting them would manufacture one finding per branch commit.
# Resolve the main ref the way migration-guard.sh does: on a CI checkout
# of a PR head there is no local `main`, only (at best) a remote-tracking
# ref — and only when the workflow fetched history. Each candidate is
# verified and then used EXACTLY as verified. No candidate resolving
# leaves the universe empty, which invariant 2 turns into exit 2 — the
# honest outcome for a shallow checkout that cannot see main at all
# (the producing workflow must fetch-depth: 0).
MAIN_REF=""
for cand in refs/heads/main refs/remotes/origin/main refs/heads/master refs/remotes/origin/master; do
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
    MAIN_REF="$cand"; break
  fi
done

SHAS=()
if [[ -n "$MAIN_REF" ]]; then
  while IFS= read -r sha; do
    [[ -n "$sha" ]] && SHAS+=("$sha")
  done < <(git -C "$REPO_ROOT" log "$MAIN_REF" --first-parent --since="30 days ago" --format='%H' 2>/dev/null)
fi

UNIVERSE_SIZE="${#SHAS[@]}"

# Default-closed: a landing with no verifiable push run is treated as
# uncovered, including when there is no origin remote to ask gh about.
# A listing that FAILS is a different thing from a listing that returns
# nothing: "I asked and the answer was none" is evidence, "I was not
# allowed to ask" is not. A failed call (missing actions:read on the CI
# token, no token, no network) used to score every landing uncovered —
# one false finding per commit on main, 209 on the first month of real
# history — and, worse, made a real CI hole and a permissions problem
# indistinguishable. It now reports an error envelope instead, which the
# runner surfaces as a visible check-error rather than a pile of findings.
COVERED=""
LISTING_FAILED=0
if [[ -n "$OWNER_REPO" && "$UNIVERSE_SIZE" -gt 0 ]]; then
  COVERED="$(covered_push_shas "$OWNER_REPO")" || LISTING_FAILED=1
fi

if [[ "$LISTING_FAILED" -eq 1 ]]; then
  DURATION_MS=$(( (SECONDS - START) * 1000 ))
  ENVELOPE_FILE="$(mktemp "${TMPDIR:-/tmp}/b4-envelope.XXXXXX")" || exit 1
  trap 'rm -f "$ENVELOPE_FILE"' EXIT
  jq -cn \
    --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
    --argjson universe "$UNIVERSE_SIZE" --argjson duration "$DURATION_MS" '
    {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
     status: "error", universe_size: $universe, excluded: [], assertions_executed: 0,
     assertions_passed: 0, measurements: [], findings: [], duration_ms: $duration}' \
    > "$ENVELOPE_FILE"
  echo "b4-merge-run: the workflow-runs listing failed (missing actions:read permission, no token, or no network) — reporting an error, never findings"
  echo "SWEEP_RESULT:v1 $(base64 < "$ENVELOPE_FILE" | tr -d '\n')"
  exit 0
fi

# Ancestry credit (#225): a push of N commits produces ONE push run, at the
# push's head sha — the N-1 buried commits never get a run at their own sha
# and are still covered. So a landing counts as covered when it IS a run's
# head sha, or is an ancestor of one. Credit only reaches backward: a
# landing newer than every run head has provably produced no run and stays
# a finding. Run heads the local repo has never seen (deleted branches, a
# shallow fetch) credit nothing — default-closed still holds, and the
# rev-list walk stays bounded by the same 30-day window as the universe.
ANCESTRY_COVERED=""
if [[ -n "$COVERED" ]]; then
  LOCAL_HEADS="$(while IFS= read -r h; do
      [[ -n "$h" ]] && git -C "$REPO_ROOT" cat-file -e "$h^{commit}" 2>/dev/null && printf '%s\n' "$h"
    done <<<"$COVERED")"
  [[ -n "$LOCAL_HEADS" ]] && ANCESTRY_COVERED="$(git -C "$REPO_ROOT" rev-list --stdin --since="30 days ago" 2>/dev/null <<<"$LOCAL_HEADS")"
fi

UNCOVERED_SHAS=()
if [[ "$UNIVERSE_SIZE" -gt 0 ]]; then
  for sha in "${SHAS[@]+${SHAS[@]}}"; do
    if { [[ -z "$COVERED" ]] || ! grep -qxF "$sha" <<<"$COVERED"; } \
       && { [[ -z "$ANCESTRY_COVERED" ]] || ! grep -qxF "$sha" <<<"$ANCESTRY_COVERED"; }; then
      UNCOVERED_SHAS+=("$sha")
    fi
  done
fi

UNCOVERED="${#UNCOVERED_SHAS[@]}"
ASSERTIONS_PASSED=$((UNIVERSE_SIZE - UNCOVERED))

# Findings flow through a FILE, never through argv: on a month of real
# history (~160 findings) the grown-array-as---argjson shape dies with
# "Argument list too long" on ubuntu runners — silently, after exit 0,
# which the first live runs reported as a missing envelope.
FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/b4-findings.XXXXXX")" || exit 1
trap 'rm -f "$FINDINGS_FILE"' EXIT
for sha in "${UNCOVERED_SHAS[@]+${UNCOVERED_SHAS[@]}}"; do
  [[ -z "$sha" ]] && continue
  FINDING="$(jq -n --arg id "$(grouped_id "$sha")" --arg sha "$sha" --arg surface "$SURFACE" \
    --argjson denom "$UNIVERSE_SIZE" --argjson executed "$UNIVERSE_SIZE" --argjson passed "$ASSERTIONS_PASSED" '
    {identity_key: $id,
     what: ("commit " + $sha + " landed on main but no push-triggered CI run exists for it"),
     plain: "A change landed on the main branch, but the automatic safety checks that were supposed to run on it never started.",
     mechanism: "NEVER RAN",
     surface: $surface,
     surface_source: "declared",
     found_by: "sweep-family-B",
     evidence: {commit: $sha, measurement: {statement: "commits landed on main with no push run", count: 1, denominator: $denom, source: "static-source"}},
     liveness: {assertions_executed: $executed, assertions_passed: $passed},
     responsible_agent: null, roster_action: null}')"
  printf '%s\n' "$FINDING" >> "$FINDINGS_FILE"
done

DURATION_MS=$(( (SECONDS - START) * 1000 ))
STATUS="pass"
[[ "$UNCOVERED" -gt 0 ]] && STATUS="fail"

MEASUREMENTS="$(jq -cn --argjson count "$UNCOVERED" --argjson denom "$UNIVERSE_SIZE" \
  '[{statement: "commits landed on main with no push run", count: $count, denominator: $denom, source: "static-source"}]')"

ENVELOPE_FILE="$(mktemp "${TMPDIR:-/tmp}/b4-envelope.XXXXXX")" || exit 1
jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson passed "$ASSERTIONS_PASSED" \
  --argjson measurements "$MEASUREMENTS" --argjson duration "$DURATION_MS" \
  --slurpfile findings_lines "$FINDINGS_FILE" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: [], assertions_executed: $universe,
   assertions_passed: $passed, measurements: $measurements, findings: $findings_lines, duration_ms: $duration}' \
  > "$ENVELOPE_FILE"
trap 'rm -f "$FINDINGS_FILE" "$ENVELOPE_FILE"' EXIT

echo "b4-merge-run: examined $UNIVERSE_SIZE commit(s) landed on main, $UNCOVERED with no push run"
echo "SWEEP_RESULT:v1 $(base64 < "$ENVELOPE_FILE" | tr -d '\n')"
