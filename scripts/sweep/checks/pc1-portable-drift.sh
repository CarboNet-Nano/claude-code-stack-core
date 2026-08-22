#!/usr/bin/env bash
# scripts/sweep/checks/pc1-portable-drift.sh — PC1: has a vendored
# portable-core skill copy (ADR-075) drifted from the copy the stack itself
# most recently published? (2026-08-18 new-user-setup-rev2 plan, task 6 of
# the Sweep serial spine).
#
# Reuses lib/portable-core.sh's pc_classify — the SAME classifier
# hooks/portable-core-refresh.sh, scripts/audit-repos.sh and
# scripts/stack-sync.sh already use to decide whether to self-heal a copy —
# rather than reimplementing manifest lookup and hashing a second time.
# `_pc_sha256` there is `shasum -a 256`/`sha256sum`, prefixed `sha256:` —
# the same computation config/gen-portable-core-manifest.sh used to build
# config/portable-core-manifest.json in the first place.
#
# Reads sweep-job/v1 on stdin (task 4's contract) and emits one
# sweep-result/v1 envelope as the LAST stdout line, `SWEEP_RESULT:v1
# <base64>` (spec S5.1) — same contract scripts/sweep/checks/b4-merge-run.sh
# uses. Exit code is not the contract the runner reads; that line is.
#
# Existence alone is NEVER a finding — the four portable-core skills are
# copied into every repo's `.claude/skills/` BY DESIGN
# (config/portable-core-skills.json). Only two states are findings:
#   STALE    — pc_classify says the copy's hash is one the stack published
#              in the past (in `known`) but is not the current one.
#              ADR-075's self-heal is supposed to fix this at the next
#              session start; a STALE finding that keeps recurring means
#              the self-heal hook is not actually running in this repo's
#              profile. `blocked` folds into this bucket too — same
#              underlying stale bytes, self-heal just could not act this
#              run (dirty tree, CI env, pinned path, etc — one of
#              lib/portable-core.sh's own gates); the reason travels in
#              `what`.
#   DIVERGED — the copy's hash is not one the stack ever published. A
#              human edited it. ADR-075 D5: never touched by self-heal,
#              reported here so a maintainer can reconcile by hand.
# `current` (matches today's canonical copy), `absent` (not installed yet)
# and `unmanaged` (the skill directory does not exist in this repo at all)
# are not findings — nothing to flag.
set -uo pipefail

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"

START="$SECONDS"

# locate lib/portable-core.sh — installed-machine path first (matches
# scripts/audit-repos.sh's precedent), then the source-repo layout relative
# to this check's own location (checks/ -> sweep/ -> scripts/ -> repo root).
PC_LIB=""
for _c in "$HOME/.claude/lib/portable-core.sh" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/lib/portable-core.sh"; do
  [[ -n "$_c" && -f "$_c" ]] && { PC_LIB="$_c"; break; }
done
if [[ -n "$PC_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PC_LIB"
fi

FINDINGS='[]'
UNIVERSE_SIZE=0
FLAGGED=0

if declare -F pc_classify >/dev/null 2>&1 && [[ -n "$(pc_manifest_path 2>/dev/null)" ]]; then
  while IFS=$'\t' read -r rel class reason hash; do
    [[ -z "$rel" || "$class" == "unmanaged" ]] && continue
    UNIVERSE_SIZE=$((UNIVERSE_SIZE + 1))
    [[ "$class" == "current" || "$class" == "absent" ]] && continue

    sub="${rel#skills/}"
    locus=".claude/skills/$sub"

    case "$class" in
      stale|blocked)
        note="an older version the stack previously published; self-heal (ADR-075) should refresh it at the next session start (if it persists, the portable-core hook is not running in this repo's profile)"
        [[ "$class" == "blocked" && -n "$reason" ]] && \
          note="an older version the stack previously published; self-heal could not refresh it this run ($reason) (if it persists, the portable-core hook is not running in this repo's profile)"
        FINDING="$(jq -n --arg id "$sub" --arg locus "$locus" --arg note "$note" --arg surface "$SURFACE" '
          {identity_key: $id,
           what: ("vendored copy at " + $locus + " holds " + $note),
           plain: "A built-in setup guide belonging to this project is out of date and should update itself automatically the next time a session starts.",
           mechanism: "CONTRACT DRIFT", surface: $surface, surface_source: "declared", found_by: "sweep-family-B",
           evidence: {locus: $locus, measurement: {statement: "vendored portable-core skill copies drifted from the manifest", count: 1, denominator: 1, source: "static-source"}},
           liveness: {assertions_executed: 1, assertions_passed: 0},
           responsible_agent: null, roster_action: null}')"
        FINDINGS="$(jq -c --argjson f "$FINDING" '. + [$f]' <<<"$FINDINGS")"
        FLAGGED=$((FLAGGED + 1))
        echo "pc1-portable-drift: STALE $locus — old vendored copy; self-heals at next session start (if it persists, the portable-core hook is not running in this repo's profile)"
        ;;
      diverged)
        FINDING="$(jq -n --arg id "$sub" --arg locus "$locus" --arg surface "$SURFACE" '
          {identity_key: $id,
           what: ("vendored copy at " + $locus + " has been edited locally; its hash matches no version the stack ever published"),
           plain: "A built-in setup guide belonging to this project has been hand-edited here, so it is left alone and never overwritten automatically.",
           mechanism: "CONTRACT DRIFT", surface: $surface, surface_source: "declared", found_by: "sweep-family-B",
           evidence: {locus: $locus, measurement: {statement: "vendored portable-core skill copies drifted from the manifest", count: 1, denominator: 1, source: "static-source"}},
           liveness: {assertions_executed: 1, assertions_passed: 0},
           responsible_agent: null, roster_action: null}')"
        FINDINGS="$(jq -c --argjson f "$FINDING" '. + [$f]' <<<"$FINDINGS")"
        FLAGGED=$((FLAGGED + 1))
        echo "pc1-portable-drift: DIVERGED $locus — locally edited, left alone"
        ;;
    esac
  done < <(pc_classify "$REPO_ROOT")
fi

ASSERTIONS_PASSED=$((UNIVERSE_SIZE - FLAGGED))

# Patch every finding's evidence.measurement.denominator and liveness with
# the check-wide totals now that the full pass is complete — matches
# b4-merge-run.sh's convention of stamping check-wide numbers onto each
# per-unit finding, computed only once the loop is done.
FINDINGS="$(jq -c --argjson denom "$UNIVERSE_SIZE" --argjson executed "$UNIVERSE_SIZE" --argjson passed "$ASSERTIONS_PASSED" \
  '[.[] | .evidence.measurement.denominator = $denom | .liveness.assertions_executed = $executed | .liveness.assertions_passed = $passed]' <<<"$FINDINGS")"

DURATION_MS=$(( (SECONDS - START) * 1000 ))
STATUS="pass"
[[ "$FLAGGED" -gt 0 ]] && STATUS="fail"

MEASUREMENTS="$(jq -cn --argjson count "$FLAGGED" --argjson denom "$UNIVERSE_SIZE" \
  '[{statement: "vendored portable-core skill copies drifted from the manifest", count: $count, denominator: $denom, source: "static-source"}]')"

ENVELOPE="$(jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson passed "$ASSERTIONS_PASSED" \
  --argjson measurements "$MEASUREMENTS" --argjson findings "$FINDINGS" --argjson duration "$DURATION_MS" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: [], assertions_executed: $universe,
   assertions_passed: $passed, measurements: $measurements, findings: $findings, duration_ms: $duration}')"

PLURAL="ies"; [[ "$UNIVERSE_SIZE" == "1" ]] && PLURAL="y"
echo "pc1-portable-drift: examined $UNIVERSE_SIZE vendored portable-core cop$PLURAL, $FLAGGED drifted"
echo "SWEEP_RESULT:v1 $(printf '%s' "$ENVELOPE" | base64 | tr -d '\n')"
