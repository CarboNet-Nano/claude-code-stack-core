#!/usr/bin/env bash
# scripts/sweep/checks/a1-writer-callers.sh — A1: does every exported writer
# have a caller? (stack ADR-078, spec S4.6 A1; the Sweep serial spine).
# Reproduces the DISCONNECTED mechanism class (28% of the 29-bug audit,
# its single largest bucket): an exported function nothing calls, doing
# whatever it does for nobody.
#
# Reads sweep-job/v1 on stdin. Universe: `.config.writer_globs` (repo-
# relative globs, matched with plain bash `[[ == ]]` pattern matching —
# which already treats `*` as "any characters including /", so `**` behaves
# identically to a single `*` here; no globstar needed, no bash 4
# dependency, matching this machine's system bash 3.2) minus
# `.config.exclusions` (by symbol name / `unit`). For every remaining
# exported symbol this check does NOT reimplement reference search — it
# shells out to the stack's existing `scripts/usage-check.sh --target
# symbol:<Name> --repo <repo_root>` (stack ADR-057) and maps its verdict:
#   used          -> no finding
#   unused        -> finding, mechanism DISCONNECTED
#   indeterminate -> finding, mechanism DISCONNECTED, `what` says so at
#                    lower confidence than unused (spec S4.6 A1)
# `identity_key` = the symbol name (spec S4.6 A1, task 8's explicit choice).
#
# Fail-closed on the reused checker, not just on our own logic: if
# usage-check.sh cannot be invoked, exits non-zero, or prints no readable
# `verdict=` token, this check does not silently treat that symbol as
# "used" (which would be a silent pass hiding a possibly-real DISCONNECTED
# bug) and does not keep going on partial information. It stops and reports
# `status: "error"` — the one envelope status the runner's
# `envelope_liveness_violation` never treats as trustworthy evidence, so a
# reused-checker outage can never look like a clean run.
#
# SWEEP_USAGE_CHECK is a test seam (mirrors sweep-run.sh's
# SWEEP_INVENTORY_FILE / SWEEP_CHECKS_DIR pattern): when set, it names the
# usage-check.sh to invoke instead of this script's own sibling
# `scripts/usage-check.sh` (two levels up from scripts/sweep/checks/, the
# installed layout per spec S4.1). Production callers never set it.
#
# Emits exactly one sweep-result/v1 envelope as the LAST stdout line,
# `SWEEP_RESULT:v1 <base64>` (spec S5.1) — same shape as b4-merge-run.sh.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_CHECK="${SWEEP_USAGE_CHECK:-$DIR/../../usage-check.sh}"

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"

START="$SECONDS"

# writer_globs, read repo-relative, one per line.
WRITER_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && WRITER_GLOBS+=("$g"); done \
  < <(jq -r '(.config.writer_globs // [])[]' <<<"$JOB")

EXCLUDED_JSON="$(jq -c '.config.exclusions // []' <<<"$JOB")"
EXCL_NAMES="$(jq -r '(.config.exclusions // [])[].unit' <<<"$JOB")"

is_excluded() {
  local name="$1"
  [[ -n "$EXCL_NAMES" ]] && grep -qxF "$name" <<<"$EXCL_NAMES"
}

# The walk's exit status is checked (pipefail makes a partial find failure
# fail the pipeline): a failed walk silently shrinking the universe would
# let a real disconnected writer pass unexamined — the quiet twin of B4's
# couldn't-look bug. CALL_FAILED already forces STATUS="error" below; a
# failed walk or a failed per-file scan uses the same path.
WALK_OUT=""
WALK_FAILED=0
if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]]; then
  WALK_OUT="$(cd "$REPO_ROOT" && find . -type f \
    -not -path './.git/*' -not -path './node_modules/*' \
    | sed 's#^\./##' | sort)" || WALK_FAILED=1
fi

# matched_files -> every repo-relative file (excluding .git/node_modules)
# whose path matches at least one declared writer_glob.
matched_files() {
  local rel matched
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    matched=0
    for pat in "${WRITER_GLOBS[@]+"${WRITER_GLOBS[@]}"}"; do
      [[ "$rel" == $pat ]] && { matched=1; break; }
    done
    [[ "$matched" -eq 1 ]] && echo "$rel"
  done <<<"$WALK_OUT"
}

# Exported-symbol detection: a top-of-line `export <kind> <Name>` — the
# common named-export shapes a TS/JS writer takes. Not a TS-compiler-level
# parse (A2/A4 use the compiler API per spec S4.6; A1 reuses usage-check.sh
# for the hard part and only needs a declaration site here, matching
# `scripts/check-fo-writes.mjs`'s existing default-closed convention of a
# targeted regex over a declared glob set, not a full parser).
DECL_RE='^export[[:space:]]+(async[[:space:]]+function|function|const|class|let|var)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)'

RAW_DECLS=()
SCAN_FAILED=0
if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT" && "$WALK_FAILED" -eq 0 ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # grep exit 1 (no exports) is evidence; exit 2+ (unreadable file) is
    # not — a silently skipped file would hide its writers from the
    # universe, and a hidden writer is never examined.
    GREP_OUT="$(grep -nE '^export (async function|function|const|class|let|var) ' "$REPO_ROOT/$f" 2>/dev/null)"
    GREP_RC=$?
    if [[ "$GREP_RC" -ge 2 ]]; then
      SCAN_FAILED=1
      break
    fi
    [[ -z "$GREP_OUT" ]] && continue
    while IFS=: read -r lineno rest; do
      [[ "$rest" =~ $DECL_RE ]] || continue
      RAW_DECLS+=("$f"$'\t'"$lineno"$'\t'"${BASH_REMATCH[2]}")
    done <<<"$GREP_OUT"
  done < <(matched_files)
fi

ANALYZED=()
for decl in "${RAW_DECLS[@]+${RAW_DECLS[@]}}"; do
  IFS=$'\t' read -r _f _l name <<<"$decl"
  is_excluded "$name" && continue
  ANALYZED+=("$decl")
done

UNIVERSE_SIZE="${#ANALYZED[@]}"

RESULTS=()
CALL_FAILED=0
[[ "$WALK_FAILED" -eq 1 || "$SCAN_FAILED" -eq 1 ]] && CALL_FAILED=1
if [[ "$CALL_FAILED" -eq 0 && "$UNIVERSE_SIZE" -gt 0 ]]; then
  for decl in "${ANALYZED[@]}"; do
    IFS=$'\t' read -r file lineno name <<<"$decl"
    UC_OUT="$("$USAGE_CHECK" --target "symbol:$name" --repo "$REPO_ROOT" 2>/dev/null)"
    UC_EC=$?
    VERDICT="$(grep -oE 'verdict=[a-z]+' <<<"$UC_OUT" | head -1 | cut -d= -f2)"
    if [[ "$UC_EC" -ne 0 ]] \
      || [[ -z "$VERDICT" ]] \
      || [[ "$VERDICT" != "used" && "$VERDICT" != "unused" && "$VERDICT" != "indeterminate" ]]; then
      CALL_FAILED=1
      break
    fi
    RESULTS+=("$file"$'\t'"$lineno"$'\t'"$name"$'\t'"$VERDICT")
  done
fi

ASSERTIONS_EXECUTED="${#RESULTS[@]}"
ASSERTIONS_PASSED=0
for r in "${RESULTS[@]+${RESULTS[@]}}"; do
  [[ "$r" == *$'\t'used ]] && ASSERTIONS_PASSED=$((ASSERTIONS_PASSED + 1))
done

FINDINGS='[]'
for r in "${RESULTS[@]+${RESULTS[@]}}"; do
  IFS=$'\t' read -r file lineno name verdict <<<"$r"
  [[ "$verdict" == "used" ]] && continue
  LOCUS="$file:$lineno"
  if [[ "$verdict" == "unused" ]]; then
    WHAT="Exported symbol '$name' ($LOCUS) has no detected caller anywhere in the repo (usage-check verdict: unused)."
    PLAIN="A part of the app that changes data doesn't seem to be used anywhere, so whatever it's supposed to do may never actually happen."
  else
    WHAT="Exported symbol '$name' ($LOCUS) has no direct source match but a related graph hint exists (usage-check verdict: indeterminate — lower confidence than unused)."
    PLAIN="A part of the app that changes data has no clear caller that automated search could confirm; it's worth a quick human look before assuming it's fine."
  fi
  FINDING="$(jq -n --arg id "$name" --arg what "$WHAT" --arg plain "$PLAIN" --arg surface "$SURFACE" \
    --arg locus "$LOCUS" --argjson denom "$UNIVERSE_SIZE" \
    --argjson executed "$ASSERTIONS_EXECUTED" --argjson passed "$ASSERTIONS_PASSED" '
    {identity_key: $id,
     what: $what,
     plain: $plain,
     mechanism: "DISCONNECTED",
     surface: $surface,
     surface_source: "declared",
     found_by: "sweep-family-A",
     evidence: {locus: $locus, measurement: {statement: "exported writers with no detected caller", count: 1, denominator: $denom, source: "static-source"}},
     liveness: {assertions_executed: $executed, assertions_passed: $passed},
     responsible_agent: null, roster_action: null}')"
  FINDINGS="$(jq -c --argjson f "$FINDING" '. + [$f]' <<<"$FINDINGS")"
done

DURATION_MS=$(( (SECONDS - START) * 1000 ))
TOTAL_FINDINGS="$(jq 'length' <<<"$FINDINGS")"

STATUS="pass"
[[ "$TOTAL_FINDINGS" -gt 0 ]] && STATUS="fail"
[[ "$CALL_FAILED" -eq 1 ]] && STATUS="error"

MEASUREMENTS="$(jq -cn --argjson count "$TOTAL_FINDINGS" --argjson denom "$UNIVERSE_SIZE" \
  '[{statement: "exported writers with no detected caller", count: $count, denominator: $denom, source: "static-source"}]')"

ENVELOPE="$(jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson excluded "$EXCLUDED_JSON" \
  --argjson executed "$ASSERTIONS_EXECUTED" --argjson passed "$ASSERTIONS_PASSED" \
  --argjson measurements "$MEASUREMENTS" --argjson findings "$FINDINGS" --argjson duration "$DURATION_MS" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: $excluded, assertions_executed: $executed,
   assertions_passed: $passed, measurements: $measurements, findings: $findings, duration_ms: $duration}')"

echo "a1-writer-callers: examined $UNIVERSE_SIZE exported writer(s), $TOTAL_FINDINGS with no detected caller"
echo "SWEEP_RESULT:v1 $(printf '%s' "$ENVELOPE" | base64 | tr -d '\n')"
