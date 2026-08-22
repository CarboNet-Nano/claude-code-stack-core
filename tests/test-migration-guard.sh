#!/usr/bin/env bash
# Tests for hooks/migration-guard.sh (ADR-037 D-1).
#
# Coverage mirrors the ADR's own required cases: squash-merged file,
# shallow/CI-shaped clone, detached HEAD, no remote, override ordering under
# a workflow context, and a git-tracked override file — plus two additions
# from the design review: the default-branch resolution must use the
# candidate ref AS VERIFIED (never strip "origin/"), and a workflow-context
# deny must leave an untouched override file in place (denied-and-untouched,
# never denied-and-consumed).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/migration-guard.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@t"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# make_repo <dir> [tier] [extra-json-fields]
make_repo() {
  local dir="$1" tier="${2:-2}" extra="${3:-}"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q -b main 2>/dev/null
  local json="{\"stack_tier\":$tier,\"stack_version\":\"1.0.0\",\"purpose\":\"test\",\"created\":\"2026-01-01\""
  [[ -n "$extra" ]] && json="$json,$extra"
  json="$json}"
  echo "$json" > "$dir/.claude/stack-config.json"
}

commit_all() {
  local dir="$1" msg="$2"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -q -m "$msg" >/dev/null 2>&1
}

# run <cwd> <tool> <file_path> [transcript_path] -> stdout from hook
run() {
  local cwd="$1" tool="$2" fp="$3" transcript="${4:-}"
  jq -nc --arg c "$cwd" --arg t "$tool" --arg f "$fp" --arg tr "$transcript" \
    '{cwd:$c, tool_name:$t, tool_input:{file_path:$f}, transcript_path:$tr}' \
    | bash "$HOOK" 2>/dev/null
}

decision_of() { echo "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of()   { echo "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
row_count() { [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo "0"; }
last_row() { [[ -f "$LOG" ]] && tail -1 "$LOG" || echo "{}"; }

# ─── A: non-migration file → silent ─────────────────────────────────────────
R="$TMP/a-nonmig"; make_repo "$R"; mkdir -p "$R/db/migrations" "$R/src"
echo "x" > "$R/db/migrations/001_init.sql"; echo "y" > "$R/src/app.ts"
commit_all "$R" "init"
OUT=$(run "$R" "Edit" "$R/src/app.ts")
[[ -z "$OUT" ]] && pass "A: non-migration file is silent" || fail "A: got $OUT"

# ─── B: uncommitted new migration → silent ──────────────────────────────────
R="$TMP/b-new"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
commit_all "$R" "init"
echo "-- new" > "$R/db/migrations/002_new.sql"
OUT=$(run "$R" "Write" "$R/db/migrations/002_new.sql")
[[ -z "$OUT" ]] && pass "B: uncommitted new migration is silent" || fail "B: got $OUT"

# ─── C: committed migration, interactive, no override → ask, honest claim ──
R="$TMP/c-ask"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
commit_all "$R" "init"
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT"); RS=$(reason_of "$OUT")
[[ "$D" == "ask" ]] && pass "C1: committed + interactive -> ask" || fail "C1: got decision '$D' ($OUT)"
if [[ "$RS" == *"does not assert"* && "$RS" != *"has been applied"*"."* ]]; then
  pass "C2: reason makes the honest (not-proven-applied) claim"
else
  # weaker check: must not claim applied-ness as fact
  if [[ "$RS" == *"cannot rule it out"* || "$RS" == *"does not assert"* ]]; then
    pass "C2: reason makes the honest (not-proven-applied) claim"
  else
    fail "C2: reason overclaims or missing: $RS"
  fi
fi
[[ "$RS" == *".migration-override-once"* ]] && pass "C3: ask reason names the override path" || fail "C3: missing override hint: $RS"

# ─── D: override file present (untracked), interactive → consumed silently ──
R="$TMP/d-override"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
commit_all "$R" "init"
touch "$R/.claude/.migration-override-once"
COUNT_BEFORE=$(row_count)
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
[[ -z "$OUT" ]] && pass "D1: override consumed -> silent (no explicit allow)" || fail "D1: got $OUT"
[[ ! -f "$R/.claude/.migration-override-once" ]] && pass "D2: override file deleted after use" || fail "D2: override file still present"
[[ "$(row_count)" -gt "$COUNT_BEFORE" ]] && pass "D3: override consumption logged" || fail "D3: no log row appended"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="guard_override" and .hook=="migration-guard"' >/dev/null 2>&1 \
  && pass "D4: log row has correct event/hook fields" || fail "D4: row wrong: $ROW"

# ─── E: override file present but git-tracked → refused, falls to ask ──────
R="$TMP/e-tracked"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
touch "$R/.claude/.migration-override-once"
commit_all "$R" "init incl override"   # override file committed alongside
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT"); RS=$(reason_of "$OUT")
[[ "$D" == "ask" ]] && pass "E1: git-tracked override refused -> falls to ask" || fail "E1: got '$D'"
[[ -f "$R/.claude/.migration-override-once" ]] && pass "E2: tracked override file left untouched" || fail "E2: file was deleted"
[[ "$RS" == *"tracked by git"* ]] && pass "E3: reason explains the refusal" || fail "E3: reason: $RS"

# ─── F: workflow context → deny; override file present but NEVER consulted ──
R="$TMP/f-workflow"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
commit_all "$R" "init"
touch "$R/.claude/.migration-override-once"
COUNT_BEFORE=$(row_count)
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql" "/some/path/workflows/run-1/transcript.jsonl")
D=$(decision_of "$OUT")
[[ "$D" == "deny" ]] && pass "F1: workflow context -> deny" || fail "F1: got '$D'"
[[ -f "$R/.claude/.migration-override-once" ]] \
  && pass "F2: CRITICAL — override file untouched under workflow deny (not consumed)" \
  || fail "F2: CRITICAL — override file was deleted despite workflow deny (ordering bug)"
[[ "$(row_count)" -eq "$COUNT_BEFORE" ]] \
  && pass "F3: no override-consumption log row under workflow deny" \
  || fail "F3: a guard_override row was logged despite workflow deny"

# ─── G: orchestration_mode != main-thread, interactive, override present ───
# -> ask, override not honored, file left in place.
R="$TMP/g-agentteams"; make_repo "$R" 2 '"orchestration_mode":"agent-teams"'
mkdir -p "$R/db/migrations"
echo "committed" > "$R/db/migrations/001_init.sql"
commit_all "$R" "init"
touch "$R/.claude/.migration-override-once"
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT"); RS=$(reason_of "$OUT")
[[ "$D" == "ask" ]] && pass "G1: non-main-thread orchestration -> ask, override not honored" || fail "G1: got '$D'"
[[ -f "$R/.claude/.migration-override-once" ]] && pass "G2: override file untouched (not main-thread)" || fail "G2: file deleted"
[[ "$RS" == *"orchestration_mode"* ]] && pass "G3: reason names the orchestration_mode restriction" || fail "G3: reason: $RS"

# ─── H: squash-merge — file present in default branch tree via a squash ────
# commit that shares no history with the feature branch that "created" it.
R="$TMP/h-squash"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "root" > "$R/README.md"; commit_all "$R" "root"
git -C "$R" checkout -q -b feature
mkdir -p "$R/db/migrations"; echo "sq" > "$R/db/migrations/003_sq.sql"
commit_all "$R" "feature commit A"
echo "sq2" >> "$R/db/migrations/003_sq.sql"
commit_all "$R" "feature commit B"
git -C "$R" checkout -q main
# Simulate a squash-merge: bring the FILE content over in one new commit on
# main, deliberately not via `git merge` — main's history never references
# the feature-branch commits, which is exactly what a squash merge produces.
cp "$R/db/migrations/003_sq.sql" "$R/db/migrations/003_sq.sql.bak" 2>/dev/null || true
git -C "$R" checkout -q feature -- db/migrations/003_sq.sql
commit_all "$R" "squash-merge feature into main"
OUT=$(run "$R" "Edit" "$R/db/migrations/003_sq.sql")
D=$(decision_of "$OUT")
[[ "$D" == "ask" ]] && pass "H: squash-merged file is caught (ls-tree, not ancestry)" || fail "H: got '$D' — squash-merge missed"

# ─── I: CI checkout shape — detached HEAD, no local branches, origin/HEAD
# unset (reproduces actions/checkout's default fetch-depth:1 state) ─────────
UPSTREAM="$TMP/i-upstream"; mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main 2>/dev/null
mkdir -p "$UPSTREAM/db/migrations"; echo "u" > "$UPSTREAM/db/migrations/001_init.sql"
git -C "$UPSTREAM" add -A >/dev/null 2>&1
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit -q -m init >/dev/null 2>&1
SHA=$(git -C "$UPSTREAM" rev-parse HEAD)

R="$TMP/i-ci-clone"
git clone -q "$UPSTREAM" "$R" 2>/dev/null
mkdir -p "$R/.claude"
echo '{"stack_tier":2,"stack_version":"1.0.0","purpose":"t","created":"2026-01-01"}' > "$R/.claude/stack-config.json"
# Reproduce the CI shape: detach HEAD, and remove EVERY ref the resolution
# chain would try — a plain `git clone` populates refs/remotes/origin/HEAD
# *and* refs/remotes/origin/main, so dropping only the HEAD symref still
# leaves origin/main resolvable and the test wouldn't reproduce the failure
# actions/checkout's fetch-depth:1 default actually produces (it fetches only
# the target ref, so no remote-tracking main exists at all).
git -C "$R" checkout -q "$SHA" 2>/dev/null
git -C "$R" remote set-head origin -d >/dev/null 2>&1 || true
git -C "$R" update-ref -d refs/remotes/origin/main >/dev/null 2>&1 || true
git -C "$R" update-ref -d refs/remotes/origin/master >/dev/null 2>&1 || true
git -C "$R" branch -D main >/dev/null 2>&1 || true
git -C "$R" branch -D master >/dev/null 2>&1 || true

OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT"); RS=$(reason_of "$OUT")
[[ "$D" == "ask" ]] && pass "I1: unresolvable default branch (CI shape) -> ask (uncertain, fail-closed)" || fail "I1: got '$D'"
# The CI remedy (fetch-depth:0 + remote set-head) is an ADR requirement of the
# DENIAL message (workflow/CI context, asserted below as I5/I6) — a human on
# the interactive thread isn't in CI and doesn't need checkout advice, so the
# ask reason only needs to state the uncertainty plainly.
[[ "$RS" == *"unresolvable default branch"* ]] && pass "I2: interactive ask reason states the uncertainty plainly" \
  || fail "I2: reason unclear about why: $RS"

# Same CI shape, but the tool call arrives via a workflow transcript -> deny,
# and the deny reason must ALSO carry both remedies (ADR requirement).
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql" "/x/workflows/run/transcript.jsonl")
D=$(decision_of "$OUT"); RS=$(reason_of "$OUT")
[[ "$D" == "deny" ]] && pass "I4: CI shape + workflow -> deny" || fail "I4: got '$D'"
[[ "$RS" == *"fetch-depth: 0"* && "$RS" == *"remote set-head origin -a"* ]] \
  && pass "I5: workflow-deny reason names both CI remedies" \
  || fail "I5: reason missing remedies: $RS"
[[ "$RS" == *"guards.migration_hook"* ]] && pass "I6: reason also names the off-switch remedy" \
  || fail "I6: reason: $RS"

# ─── J: rebase in progress -> treated as uncertain even with a resolvable
# default branch ────────────────────────────────────────────────────────────
R="$TMP/j-rebase"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "x" > "$R/db/migrations/001_init.sql"; commit_all "$R" "init"
mkdir -p "$R/.git/rebase-merge"
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT")
[[ "$D" == "ask" ]] && pass "J: rebase-in-progress forces uncertain -> ask" || fail "J: got '$D'"
rm -rf "$R/.git/rebase-merge"

# ─── K: default-branch ref is used AS RESOLVED, never stripped ─────────────
# Repo with ONLY a remote-tracking origin/HEAD (no local main) — the
# resolution chain must succeed via refs/remotes/origin/HEAD and query
# ls-tree with that exact ref, not a stripped "main" that doesn't exist
# locally as origin/main either (only as origin/HEAD's target).
UPSTREAM2="$TMP/k-upstream"; mkdir -p "$UPSTREAM2"
git -C "$UPSTREAM2" init -q -b main 2>/dev/null
mkdir -p "$UPSTREAM2/db/migrations"; echo "k" > "$UPSTREAM2/db/migrations/001_init.sql"
git -C "$UPSTREAM2" add -A >/dev/null 2>&1
git -C "$UPSTREAM2" -c user.name=t -c user.email=t@t commit -q -m init >/dev/null 2>&1

R="$TMP/k-clone"
git clone -q "$UPSTREAM2" "$R" 2>/dev/null
mkdir -p "$R/.claude"
echo '{"stack_tier":2,"stack_version":"1.0.0","purpose":"t","created":"2026-01-01"}' > "$R/.claude/stack-config.json"
# A plain `git clone` already sets origin/HEAD and a local main by default —
# remove ONLY the local branch, keeping origin/HEAD, so resolution must
# succeed via the remote-tracking symref alone.
git -C "$R" checkout -q --detach 2>/dev/null
git -C "$R" branch -D main >/dev/null 2>&1 || true

OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT")
[[ "$D" == "ask" ]] && pass "K: resolves via origin/HEAD alone, no local main needed" || fail "K: got '$D' (should resolve, not fall to uncertain)"

# ─── L: no stack-config -> silent no matter what ────────────────────────────
R="$TMP/l-nostack"; mkdir -p "$R/db/migrations"; git -C "$R" init -q -b main 2>/dev/null
echo "x" > "$R/db/migrations/001_init.sql"; commit_all "$R" "init"
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
[[ -z "$OUT" ]] && pass "L: unconfigured repo -> silent" || fail "L: got $OUT"

# ─── M: guards.migration_hook off -> silent even for a committed migration ──
R="$TMP/m-off"; make_repo "$R" 2 '"guards":{"migration_hook":"off"}'
mkdir -p "$R/db/migrations"
echo "x" > "$R/db/migrations/001_init.sql"; commit_all "$R" "init"
OUT=$(run "$R" "Edit" "$R/db/migrations/001_init.sql")
[[ -z "$OUT" ]] && pass "M: guards.migration_hook off -> silent" || fail "M: got $OUT"

# ─── N: MultiEdit tool name is recognized ───────────────────────────────────
R="$TMP/n-multiedit"; make_repo "$R"; mkdir -p "$R/db/migrations"
echo "x" > "$R/db/migrations/001_init.sql"; commit_all "$R" "init"
OUT=$(run "$R" "MultiEdit" "$R/db/migrations/001_init.sql")
D=$(decision_of "$OUT")
[[ "$D" == "ask" ]] && pass "N: MultiEdit on a committed migration -> ask" || fail "N: got '$D'"

echo
echo "migration-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
