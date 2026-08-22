#!/usr/bin/env bash
# Tests for tools/adr-drift/src/check.mjs.
#
# The load-bearing test here is the PRECISION one: the commit that CREATES an
# ADR necessarily names it, so without a guard the tool would treat a docs-only
# commit as proof the ADR shipped — laundering a document into evidence of code.
# A drift detector that does that is worse than none, because it reports "clean"
# on exactly the drift it exists to find. The guard is one regex
# (NON_IMPLEMENTING) and nothing else pins it; this file does.
#
# Fixtures are real throwaway git repos, not mocks — the tool reads real git
# history, so mocking that away would test nothing that matters.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$REPO_ROOT/tools/adr-drift/src/check.mjs"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available — adr-drift is a node tool"
  echo "adr-drift: 0 passed, 0 failed (skipped)"
  exit 0
fi

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# new_repo <name> -> echoes path to a fresh git repo with a docs/ADRs dir
new_repo() {
  local R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/docs/ADRs"
  ( cd "$R" && git init -q -b main && git config user.email t@t.t && git config user.name t
    echo x > README.md && git add -A && git commit -qm "chore: init" )
  echo "$R"
}

# adr <repo> <num> <status> — writes a minimal ADR with the given status line
adr() {
  printf '# ADR %s: fixture\n\nStatus: %s\n\n## Context\n\nfixture.\n' "$2" "$3" \
    > "$1/docs/ADRs/$2-fixture.md"
}

# run_check <repo> [args...] -> echoes JSON result
run_check() {
  local R="$1"; shift
  ( cd "$R" && node "$CHECK" --json "$@" 2>/dev/null )
}

count_of() { echo "$1" | jq -r '.count // 0' 2>/dev/null; }

# --- 1. PRECISION: a docs-only commit creating the ADR is NOT evidence -------
# This is the regression that matters. If this fails, the tool reports "clean"
# on genuinely stale ADRs and is actively misleading.
R="$(new_repo precision)"
adr "$R" 070 "Proposed"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-070 stub" )
OUT="$(run_check "$R")"
if [[ "$(count_of "$OUT")" == "0" ]]; then
  pass "docs(adr): commit creating an ADR is not counted as evidence it shipped"
else
  fail "docs-only ADR-creating commit was treated as implementation evidence: $OUT"
fi

# The same guard must hold for every non-implementing prefix, not just docs.
for prefix in chore style test ci build revert; do
  R="$(new_repo "precision-$prefix")"
  adr "$R" 071 "Proposed"
  ( cd "$R" && git add -A && git commit -qm "$prefix: touch ADR-071" )
  OUT="$(run_check "$R")"
  [[ "$(count_of "$OUT")" == "0" ]] \
    && pass "'$prefix:' commit naming an ADR is not implementation evidence" \
    || fail "'$prefix:' commit was counted as evidence: $OUT"
done

# --- 2. SENSITIVITY: a real implementing commit IS evidence ------------------
# The mirror of test 1. A guard tuned so tight it never fires is equally useless
# — this proves the tool still catches the drift it exists for.
R="$(new_repo sensitivity)"
adr "$R" 072 "Proposed"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-072 stub" )
mkdir -p "$R/src" && echo "real code" > "$R/src/thing.sh"
( cd "$R" && git add -A && git commit -qm "feat(thing): implement ADR-072" )
OUT="$(run_check "$R")"
if [[ "$(count_of "$OUT")" == "1" ]]; then
  pass "a feat: commit naming an unbuilt-status ADR IS flagged as stale"
else
  fail "real implementing commit was not detected as stale-status evidence: $OUT"
fi
echo "$OUT" | jq -e '.findings[0].type == "stale-status"' >/dev/null 2>&1 \
  && pass "the finding is typed stale-status" \
  || fail "finding was not typed stale-status: $OUT"

# --- 3. a built status is never flagged, even with implementing commits ------
R="$(new_repo built)"
adr "$R" 073 "Accepted"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-073" )
echo "code" > "$R/thing.sh"
( cd "$R" && git add -A && git commit -qm "feat(thing): implement ADR-073" )
OUT="$(run_check "$R")"
[[ "$(count_of "$OUT")" == "0" ]] \
  && pass "an Accepted ADR is never flagged as stale" \
  || fail "Accepted ADR was flagged: $OUT"

# --- 4. an explicit correction banner suppresses the finding ----------------
# A human has reviewed the status; re-flagging it would be noise that trains
# people to ignore the check.
R="$(new_repo corrected)"
printf '# ADR 074: fixture\n\nStatus: Proposed — STATUS CORRECTED 2026-08-05: shipped.\n\n## Context\n\nx.\n' \
  > "$R/docs/ADRs/074-fixture.md"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-074" )
echo "code" > "$R/thing.sh"
( cd "$R" && git add -A && git commit -qm "feat(thing): implement ADR-074" )
OUT="$(run_check "$R")"
[[ "$(count_of "$OUT")" == "0" ]] \
  && pass "an explicit STATUS CORRECTED banner suppresses the stale finding" \
  || fail "corrected ADR was still flagged: $OUT"

# --- 5. dangling reference detection ----------------------------------------
R="$(new_repo dangling)"
printf '# ADR 075: fixture\n\nStatus: Accepted\n\n## Context\n\nBuilds on ADR-999.\n' \
  > "$R/docs/ADRs/075-fixture.md"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-075" )
OUT="$(run_check "$R")"
echo "$OUT" | jq -e '[.findings[] | select(.type == "dangling-ref")] | length >= 1' >/dev/null 2>&1 \
  && pass "a citation of a nonexistent ADR is flagged as dangling-ref" \
  || fail "dangling reference not detected: $OUT"

# a citation of an ADR that exists only under drafts/ is NOT dangling
R="$(new_repo drafts)"
mkdir -p "$R/docs/ADRs/drafts"
printf '# ADR 076: draft\n\nStatus: Proposed\n' > "$R/docs/ADRs/drafts/076-draft.md"
printf '# ADR 077: fixture\n\nStatus: Accepted\n\n## Context\n\nSee ADR-076.\n' \
  > "$R/docs/ADRs/077-fixture.md"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-077 and a draft" )
OUT="$(run_check "$R")"
echo "$OUT" | jq -e '[.findings[] | select(.type == "dangling-ref")] | length == 0' >/dev/null 2>&1 \
  && pass "citing an ADR that exists under drafts/ is not dangling" \
  || fail "draft citation was wrongly flagged dangling: $OUT"

# --- 6. path resolution: works from any CWD, and honors the declared baseline -
# Regression for the fix in 3664a99: reading config/paths from the caller's CWD
# meant the tool worked from exactly one directory, and a declared baseline
# silently never applied.
R="$(new_repo cwd)"
adr "$R" 078 "Proposed"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-078" )
echo "code" > "$R/thing.sh"
( cd "$R" && git add -A && git commit -qm "feat(thing): implement ADR-078" )
mkdir -p "$R/deep/nested"

FROM_ROOT="$(run_check "$R")"
FROM_NESTED="$( cd "$R/deep/nested" && node "$CHECK" --json 2>/dev/null )"
if [[ "$(count_of "$FROM_ROOT")" == "$(count_of "$FROM_NESTED")" ]] && [[ "$(count_of "$FROM_ROOT")" == "1" ]]; then
  pass "same result from repo root and from a nested subdirectory"
else
  fail "CWD changed the result — root=$(count_of "$FROM_ROOT") nested=$(count_of "$FROM_NESTED")"
fi

# a baseline declared in the adopting repo's package.json must actually apply
printf '{"name":"fixture","adrDrift":{"baseline":1}}\n' > "$R/package.json"
( cd "$R" && git add -A && git commit -qm "chore: add package.json" )
( cd "$R" && node "$CHECK" >/dev/null 2>&1 )
BASELINED_EXIT=$?
[[ "$BASELINED_EXIT" -eq 0 ]] \
  && pass "a baseline declared in the repo's package.json is honored (exit 0 at baseline)" \
  || fail "declared baseline was ignored — exit $BASELINED_EXIT, expected 0"

# and drift ABOVE the declared baseline still fails
adr "$R" 079 "Proposed"
( cd "$R" && git add -A && git commit -qm "docs(adr): add ADR-079" )
echo "more" > "$R/thing2.sh"
( cd "$R" && git add -A && git commit -qm "feat(thing2): implement ADR-079" )
( cd "$R" && node "$CHECK" >/dev/null 2>&1 )
OVER_EXIT=$?
[[ "$OVER_EXIT" -eq 1 ]] \
  && pass "drift above the declared baseline exits 1" \
  || fail "drift above baseline did not fail — exit $OVER_EXIT, expected 1"

# --- 7. this repo's own baseline is 0 and the check is clean -----------------
# Guards against the baseline being quietly raised instead of drift being fixed.
DECLARED="$(jq -r '.adrDrift.baseline' "$REPO_ROOT/tools/adr-drift/package.json" 2>/dev/null)"
[[ "$DECLARED" == "0" ]] \
  && pass "this repo's declared baseline is 0" \
  || fail "this repo's baseline is $DECLARED, expected 0 — was it raised instead of fixing drift?"

( cd "$REPO_ROOT" && node "$CHECK" >/dev/null 2>&1 )
SELF_EXIT=$?
[[ "$SELF_EXIT" -eq 0 ]] \
  && pass "this repo currently has zero ADR drift" \
  || fail "this repo has ADR drift — run: node tools/adr-drift/src/check.mjs"

echo
echo "adr-drift: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
