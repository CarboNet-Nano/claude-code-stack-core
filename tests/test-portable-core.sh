#!/usr/bin/env bash
# Tests for lib/portable-core.sh and hooks/portable-core-refresh.sh (ADR-075).
#
# The mechanism rewrites files inside a user's git repo at boot, so the tests
# that matter are the ones proving it REFUSES: every gate here fails toward not
# writing, and a gate that silently stops refusing is the failure mode with no
# symptom. Real throwaway git repos and a fake $HOME throughout; no network.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/portable-core.sh"
HOOK="$REPO_ROOT/hooks/portable-core-refresh.sh"
MANIFEST="$REPO_ROOT/config/portable-core-manifest.json"

PASS=0; FAIL=0; SKIPPED=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP: $1"; }

command -v jq >/dev/null 2>&1 || { echo "test-portable-core: jq required" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "test-portable-core: manifest missing — run scripts/gen-portable-core-manifest.sh" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/portable-core-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# A fake ~/.claude holding the manifest and current copies of every skill.
FAKE_HOME="$TMP/home/.claude"
mkdir -p "$FAKE_HOME/config" "$FAKE_HOME/lib"
cp "$MANIFEST" "$FAKE_HOME/config/portable-core-manifest.json"
cp "$LIB" "$FAKE_HOME/lib/portable-core.sh"
while IFS= read -r s; do
  mkdir -p "$FAKE_HOME/skills/$s"
  cp "$REPO_ROOT/skills/$s/SKILL.md" "$FAKE_HOME/skills/$s/SKILL.md" 2>/dev/null || true
done < <(jq -r '.skills[]' "$REPO_ROOT/config/portable-core-skills.json")

export CLAUDE_PLUGIN_ROOT="$FAKE_HOME"
# shellcheck disable=SC1090
source "$LIB"

# The lib refuses to write in CI (_pc_ci_env), and this suite runs in GitHub
# Actions where CI=true is ambient — scrub those vars so the non-CI gates are
# actually exercised; the PS25/CB-a tests set their own CI env explicitly.
unset CI GITHUB_ACTIONS BUILDKITE JENKINS_URL GITLAB_CI

# An older published version of a managed file — the migration case, not a
# synthetic one. Vendored from 99805b4~1:skills/handoff/SKILL.md so the suite
# runs in shallow clones (CI fetch-depth 1) where that history is absent.
OLD_BLOB="$REPO_ROOT/tests/fixtures/portable-core/pre-fold-handoff-SKILL.md"
[[ -f "$OLD_BLOB" ]] || { echo "test-portable-core: fixture missing: $OLD_BLOB" >&2; exit 1; }

new_repo() {  # new_repo <name> [--no-commit] -> repo root, with a STALE copy
  local name="$1"; local commit="${2:-commit}"
  local r="$TMP/$name"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main . && git config user.email t@t.t && git config user.name t
    mkdir -p .claude/skills/handoff
    cp "$OLD_BLOB" .claude/skills/handoff/SKILL.md
    echo x > README.md
    if [[ "$commit" == "commit" ]]; then git add -A && git commit -qm init; fi ) >/dev/null 2>&1
  printf '%s' "$r"
}
cls() { pc_classify "$1" 2>/dev/null | awk -F'\t' '$1=="skills/handoff/SKILL.md"{print $2" "$3}' | sed 's/ $//'; }
hash_of() { shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------- PS2, PS7
R="$(new_repo ps2)"
[[ "$(cls "$R")" == "stale" ]] \
  && pass "PS2: a copy whose bytes are an older published version classifies stale" \
  || fail "PS2: got '$(cls "$R")'"
BEFORE="$(hash_of "$R/.claude/skills/handoff/SKILL.md")"
pc_reconcile "$R" 0 >/dev/null 2>&1
[[ "$(hash_of "$R/.claude/skills/handoff/SKILL.md")" == "$BEFORE" ]] \
  && pass "PS2: a dry run writes nothing" || fail "PS2: dry run modified the file"
OUT="$(pc_reconcile "$R" 1 2>/dev/null)"
if printf '%s' "$OUT" | jq -e '.refreshed | length == 1' >/dev/null 2>&1 \
   && [[ "$(hash_of "$R/.claude/skills/handoff/SKILL.md")" == "$(hash_of "$REPO_ROOT/skills/handoff/SKILL.md")" ]]; then
  pass "PS2: apply refreshes the copy to the current published bytes"
else
  fail "PS2: apply did not refresh: $OUT"
fi
OUT2="$(pc_reconcile "$R" 1 2>/dev/null)"
printf '%s' "$OUT2" | jq -e '.refreshed | length == 0' >/dev/null 2>&1 \
  && pass "PS2: a second run is a no-op (regression: no refresh loop)" \
  || fail "PS2: second run refreshed again: $OUT2"

# ---------------------------------------------------------------- PS8
R="$(new_repo ps8)"
HEAD_BEFORE="$(git -C "$R" rev-parse HEAD)"
pc_reconcile "$R" 1 >/dev/null 2>&1
STAGED="$(git -C "$R" diff --cached --name-only 2>/dev/null)"
if [[ "$(git -C "$R" rev-parse HEAD)" == "$HEAD_BEFORE" && -z "$STAGED" ]]; then
  pass "PS8: never commits and never stages — HEAD unchanged, index clean"
else
  fail "PS8: HEAD moved or files were staged ('$STAGED')"
fi
git -C "$R" status --porcelain | grep -q '^ M .claude/skills/handoff/SKILL.md' \
  && pass "PS8: the refresh leaves exactly one ordinary modified file" \
  || fail "PS8: unexpected working tree: $(git -C "$R" status --porcelain | tr '\n' ' ')"

# ---------------------------------------------------------------- PS3 (D5)
R="$(new_repo ps3)"
printf 'MY OWN NOTES\n' > "$R/.claude/skills/handoff/SKILL.md"
( cd "$R" && git add -A && git commit -qm edit ) >/dev/null 2>&1
[[ "$(cls "$R")" == "diverged" ]] \
  && pass "PS3: bytes the stack never published classify diverged" || fail "PS3: got '$(cls "$R")'"
BEFORE="$(hash_of "$R/.claude/skills/handoff/SKILL.md")"
pc_reconcile "$R" 1 >/dev/null 2>&1
[[ "$(hash_of "$R/.claude/skills/handoff/SKILL.md")" == "$BEFORE" ]] \
  && pass "PS3: a hand-edited file is never overwritten" || fail "PS3: a hand-edit was clobbered"

# ---------------------------------------------------------------- PS4
R="$(new_repo ps4)"
cp "$REPO_ROOT/skills/handoff/SKILL.md" "$R/.claude/skills/handoff/SKILL.md"
( cd "$R" && git add -A && git commit -qm current ) >/dev/null 2>&1
[[ "$(cls "$R")" == "current" ]] \
  && pass "PS4: an up-to-date copy classifies current and is left alone" || fail "PS4: got '$(cls "$R")'"

# ---------------------------------------------------------------- gates
R="$(new_repo g_dirty)"
cp "$REPO_ROOT/skills/handoff/SKILL.md" "$R/.claude/skills/handoff/SKILL.md"
( cd "$R" && git add -A && git commit -qm current ) >/dev/null 2>&1
cp "$OLD_BLOB" "$R/.claude/skills/handoff/SKILL.md"   # uncommitted, but a KNOWN version
[[ "$(cls "$R")" == "blocked dirty" ]] \
  && pass "gate: an uncommitted change to the target refuses (dirty)" || fail "gate dirty: got '$(cls "$R")'"
BEFORE="$(hash_of "$R/.claude/skills/handoff/SKILL.md")"
pc_reconcile "$R" 1 >/dev/null 2>&1
[[ "$(hash_of "$R/.claude/skills/handoff/SKILL.md")" == "$BEFORE" ]] \
  && pass "gate: a dirty target is not overwritten" || fail "gate dirty: overwrote uncommitted work"

R="$(new_repo g_detached)"; git -C "$R" checkout -q --detach HEAD 2>/dev/null
[[ "$(cls "$R")" == "blocked detached-head" ]] \
  && pass "PS21: detached HEAD refuses (a modified file would break bisect)" \
  || fail "PS21: got '$(cls "$R")'"

R="$(new_repo g_ci)"
[[ "$(CI=true cls "$R")" == "blocked ci" ]] \
  && pass "PS25: a labelled CI checkout refuses" || fail "PS25: got '$(CI=true cls "$R")'"
R="$(new_repo g_ci2)"
mkdir -p "$FAKE_HOME"
echo '{"portable_sync_ci_env":["MY_WEIRD_HARNESS"]}' > "$FAKE_HOME/stack-defaults.json"
[[ "$(MY_WEIRD_HARNESS=1 cls "$R")" == "blocked ci" ]] \
  && pass "PS25: an unknown harness named in stack-defaults is honoured" \
  || fail "PS25: extensible CI list ignored"
rm -f "$FAKE_HOME/stack-defaults.json"

R="$(new_repo g_remote)"
[[ "$(CLAUDE_CODE_REMOTE=true cls "$R")" == "blocked remote" ]] \
  && pass "CB-a: a cloud/remote session refuses explicitly" \
  || fail "CB-a: got '$(CLAUDE_CODE_REMOTE=true cls "$R")'"

for state in rebase-merge rebase-apply; do
  R="$(new_repo "g_$state")"
  mkdir -p "$(git -C "$R" rev-parse --absolute-git-dir)/$state"
  [[ "$(cls "$R")" == "blocked repo-state-rebase" ]] \
    && pass "PS24: mid-rebase ($state) refuses" || fail "PS24 $state: got '$(cls "$R")'"
done
for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  R="$(new_repo "g_$f")"
  : > "$(git -C "$R" rev-parse --absolute-git-dir)/$f"
  case "$f" in
    MERGE_HEAD) want="blocked repo-state-merge" ;;
    CHERRY_PICK_HEAD) want="blocked repo-state-cherry-pick" ;;
    REVERT_HEAD) want="blocked repo-state-revert" ;;
  esac
  [[ "$(cls "$R")" == "$want" ]] && pass "PS24: $f refuses" || fail "PS24 $f: got '$(cls "$R")' want '$want'"
done

R="$(new_repo g_untracked no-commit)"
( cd "$R" && git add README.md && git commit -qm init ) >/dev/null 2>&1
[[ "$(cls "$R")" == "blocked untracked" ]] \
  && pass "gate: an untracked copy refuses (nothing to revert to)" || fail "gate untracked: got '$(cls "$R")'"

# ---------------------------------------------------------------- PS22/PS23 (D7)
R="$(new_repo ps22)"
mkdir -p "$R/.claude"
echo '{"portable_sync":{"mode":"auto","pin":[".claude/skills/handoff/SKILL.md"]}}' > "$R/.claude/stack-config.json"
[[ "$(cls "$R")" == "blocked pinned" ]] \
  && pass "PS22: an explicitly pinned path is never rewritten" || fail "PS22: got '$(cls "$R")'"
echo '{"portable_sync":{"mode":"off"}}' > "$R/.claude/stack-config.json"
[[ -z "$(cls "$R")" ]] \
  && pass "PS23: mode=off disables the mechanism entirely" || fail "PS23: got '$(cls "$R")'"
echo '{"portable_sync":{"mode":"report"}}' > "$R/.claude/stack-config.json"
[[ "$(cls "$R")" == "blocked mode-report" ]] \
  && pass "PS23: mode=report classifies but never writes" || fail "PS23: got '$(cls "$R")'"

# ---------------------------------------------------------------- PS10 (D4)
R="$(new_repo ps10)"
rm -rf "$R/.claude/skills/handoff"
( cd "$R" && git add -A && git commit -qm "delete the stale copy" ) >/dev/null 2>&1
pc_reconcile "$R" 1 >/dev/null 2>&1
if [[ ! -e "$R/.claude/skills/handoff/SKILL.md" ]]; then
  pass "PS10: a deleted skill directory is never re-seeded (D4)"
else
  fail "PS10: a copy the maintainer deleted came back at reconcile"
fi

# ---------------------------------------------------------------- PS28 (worktree)
R="$(new_repo ps28)"
WT="$TMP/ps28-linked"
if git -C "$R" worktree add -q -b wt "$WT" >/dev/null 2>&1; then
  mkdir -p "$WT/.claude/skills/handoff"
  cp "$OLD_BLOB" "$WT/.claude/skills/handoff/SKILL.md"
  ( cd "$WT" && git add -A && git commit -qm wt ) >/dev/null 2>&1
  WT_CLASS="$(pc_classify "$WT" 2>/dev/null | awk -F'\t' '$1=="skills/handoff/SKILL.md"{print $2}')"
  [[ "$WT_CLASS" == "stale" ]] \
    && pass "PS28: a linked worktree is handled (asserted, not assumed)" \
    || fail "PS28: linked worktree classified '$WT_CLASS'"
  MAIN_BEFORE="$(hash_of "$R/.claude/skills/handoff/SKILL.md")"
  pc_reconcile "$WT" 1 >/dev/null 2>&1
  [[ "$(hash_of "$R/.claude/skills/handoff/SKILL.md")" == "$MAIN_BEFORE" ]] \
    && pass "PS28: refreshing a linked worktree does not touch the primary" \
    || fail "PS28: the primary worktree was modified"
else
  skip "PS28: git worktree unavailable"
fi

# ---------------------------------------------------------------- PS13
R="$(new_repo ps13)"
NEST="$R/.claude/skills"
( cd "$NEST" && git init -q -b main . && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm nested ) >/dev/null 2>&1
NEST_CLASS="$(cls "$R")"
[[ "$NEST_CLASS" == "blocked other-worktree" || "$NEST_CLASS" == "blocked dirty" || "$NEST_CLASS" == "blocked untracked" ]] \
  && pass "PS13: a nested repo under .claude/skills refuses ($NEST_CLASS)" \
  || fail "PS13: nested repo not refused: got '$NEST_CLASS'"

# ---------------------------------------------------------------- D15
R="$(new_repo d15)"
pc_reconcile "$R" 1 >/dev/null 2>&1
[[ "$(pc_attribute "$R" .claude/skills/handoff/SKILL.md)" == "stack-self-heal" ]] \
  && pass "D15: a refreshed file is attributable as stack-self-heal" \
  || fail "D15: refresh not attributed"
[[ -z "$(pc_attribute "$R" README.md)" ]] \
  && pass "D15: an unrelated file carries no attribution" || fail "D15: false attribution on README.md"
printf 'hand edit\n' >> "$R/README.md"
[[ -z "$(pc_attribute "$R" README.md)" ]] \
  && pass "D15: a hand-edited file carries no attribution" || fail "D15: false attribution on a hand-edit"
R="$(new_repo d15b)"
[[ -z "$(pc_attribute "$R" .claude/skills/handoff/SKILL.md)" ]] \
  && pass "D15: an un-refreshed stale copy is not attributed" \
  || fail "D15: attributed a file the refresher never wrote"

# ---------------------------------------------------------------- the hook
R="$(new_repo hook1)"
HOOK_OUT="$(cd "$R" && bash "$HOOK" 2>&1)"; HOOK_RC=$?
if [[ $HOOK_RC -eq 0 ]] && printf '%s' "$HOOK_OUT" | grep -q 'self-heal'; then
  pass "HK: the boot hook refreshes and reports what it did"
else
  fail "HK: rc=$HOOK_RC out='$HOOK_OUT'"
fi
HOOK_OUT2="$(cd "$R" && bash "$HOOK" 2>&1)"
[[ -z "$HOOK_OUT2" ]] \
  && pass "D10: a boot with nothing to do prints nothing" || fail "D10: quiet boot printed '$HOOK_OUT2'"

# PS31 — the fail-silent guard. A `[ -t 0 ]` gate here would disable the whole
# mechanism with no output at all, so both redirections must still refresh.
R="$(new_repo ps31a)"
( cd "$R" && bash "$HOOK" < /dev/null >/dev/null 2>&1 )
git -C "$R" status --porcelain | grep -q 'skills/handoff' \
  && pass "PS31: refresh still happens with stdin from /dev/null" \
  || fail "PS31: stdin redirection silently disabled the refresh"
R="$(new_repo ps31b)"
( cd "$R" && echo | bash "$HOOK" >/dev/null 2>&1 )
git -C "$R" status --porcelain | grep -q 'skills/handoff' \
  && pass "PS31: refresh still happens with stdin from a pipe" \
  || fail "PS31: a piped stdin silently disabled the refresh"

# PS14/PS15/PS17 — fail open, always exit 0.
R="$(new_repo ps14)"
mv "$FAKE_HOME/config/portable-core-manifest.json" "$TMP/m.bak"
( cd "$R" && bash "$HOOK" >/dev/null 2>&1 ); [[ $? -eq 0 ]] \
  && pass "PS14: a missing manifest exits 0 silently" || fail "PS14: nonzero exit with no manifest"
mv "$TMP/m.bak" "$FAKE_HOME/config/portable-core-manifest.json"
mv "$FAKE_HOME/lib/portable-core.sh" "$TMP/l.bak"
( cd "$R" && bash "$HOOK" >/dev/null 2>&1 ); [[ $? -eq 0 ]] \
  && pass "PS15: a missing library exits 0 silently" || fail "PS15: nonzero exit with no library"
mv "$TMP/l.bak" "$FAKE_HOME/lib/portable-core.sh"
( cd "$TMP" && bash "$HOOK" >/dev/null 2>&1 ); [[ $? -eq 0 ]] \
  && pass "PS17: outside a git repo it exits 0 silently" || fail "PS17: nonzero exit outside a repo"

# The stack source repo owns the originals and must never be reconciled.
SRC_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- skills/ | wc -l | tr -d ' ')"
( cd "$REPO_ROOT" && bash "$HOOK" >/dev/null 2>&1 )
SRC_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- skills/ | wc -l | tr -d ' ')"
[[ "$SRC_BEFORE" == "$SRC_AFTER" ]] \
  && pass "HK: the stack source repo's own skills are never touched" \
  || fail "HK: the hook modified the source repo ($SRC_BEFORE -> $SRC_AFTER)"

# PS18 — a receipt per repo.
R="$(new_repo ps18)"
( cd "$R" && bash "$HOOK" >/dev/null 2>&1 )
if ls "$FAKE_HOME/state/portable-sync/"*.json >/dev/null 2>&1; then
  pass "PS18: a receipt is written for the run"
else
  fail "PS18: no receipt written"
fi

# PS27 — the cooperative budget is honoured rather than claimed.
R="$(new_repo ps27)"
START=$SECONDS
PORTABLE_SYNC_BUDGET_SECS=0 pc_classify "$R" >/dev/null 2>&1
[[ $((SECONDS - START)) -le 2 ]] \
  && pass "PS27: a zero budget short-circuits promptly" || fail "PS27: budget not honoured"

echo "test-portable-core: $PASS passed, $FAIL failed, $SKIPPED skipped"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
