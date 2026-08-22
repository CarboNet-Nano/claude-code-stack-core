#!/usr/bin/env bash
# Tests for scripts/update.sh's pre-update guards.
#
# WHY THIS FILE EXISTS: a cross-family review of the untracked-files fix found
# that BOTH new stager tests could pass while scripts/update.sh remained
# wrong, because neither test invoked update.sh at all. The stager and the
# manual/applier path must agree — the stager decides whether it is safe to
# PREPARE an update, this decides whether it is safe to CHANGE the checkout.
# A fleet whose stager works while manual recovery stays frozen is exactly the
# bug being fixed, moved one script over.
#
# update.sh refuses to run inside a Claude Code session (ADR-086 D7), so every
# invocation here clears the session markers and sets STACK_UPDATE_VIA_HOOK=1.
# These tests exercise ONLY the precondition block: each case must exit
# non-zero before any pull or install runs, so no fixture ever needs a remote.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE="$REPO_ROOT/scripts/update.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# A fixture repo with update.sh copied in at the same relative path, so its
# own REPO_ROOT resolution lands on the fixture rather than the real stack.
make_fixture() {
  local R="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$R/scripts"
  cp "$UPDATE" "$R/scripts/update.sh"
  chmod +x "$R/scripts/update.sh"
  # install.sh is never reached — every case here must fail earlier — but a
  # stub means a REGRESSION (a guard that wrongly passes) fails loudly with a
  # recognisable marker instead of silently doing nothing.
  printf '#!/usr/bin/env bash\necho "REACHED_INSTALL"\n' > "$R/scripts/install.sh"
  chmod +x "$R/scripts/install.sh"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.t
  git -C "$R" config user.name t
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base >/dev/null
  echo "$R"
}

RC=0
# Output goes to a file rather than being returned through a command
# substitution: `OUT="$(run_update ...)"` runs the function in a SUBSHELL, so
# an RC set inside it never reaches the parent and every assertion sees rc=0.
# That is a test-harness bug that silently turns "refused correctly" into
# "failed to refuse" — the wrong direction to be wrong in.
RUN_OUT="$TMP/run-out.txt"
run_update() { # <repo> -> writes output to $RUN_OUT, sets RC
  local R="$1"
  ( cd "$R" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      STACK_UPDATE_VIA_HOOK=1 STACK_UPDATE_NO_PULL=1 \
      bash "$R/scripts/update.sh" --tier=2 ) > "$RUN_OUT" 2>&1
  RC=$?
  cat "$RUN_OUT"
}

# ─── U1: a clean repo reaches the install step ──────────────────────────────
# The control. Without it, every "refused" assertion below could pass simply
# because the script was broken in some unrelated way.
R="$(make_fixture)"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$OUT" == *"REACHED_INSTALL"* ]]; then
  pass "U1: a clean repo passes the preconditions (control)"
else
  fail "U1: clean repo did not reach install — rc=$RC out='$OUT'"
fi

# ─── U2: an untracked file does NOT block ───────────────────────────────────
# The actual fix. One stray generated file used to freeze updates forever.
R="$(make_fixture)"
echo "generated junk" > "$R/some-generated-file.tmp"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$OUT" == *"REACHED_INSTALL"* ]]; then
  pass "U2: an untracked file does not block the update"
else
  fail "U2: untracked file still blocks — rc=$RC out='$OUT'"
fi

# ─── U3: a tracked edit still blocks ────────────────────────────────────────
# Narrowing a check must not disarm it.
R="$(make_fixture)"
echo "a real local edit" >> "$R/README.md"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"uncommitted changes to tracked files"* ]]; then
  pass "U3: a tracked edit still blocks"
else
  fail "U3: tracked edit did not block — rc=$RC out='$OUT'"
fi

# ─── U4: a staged-but-uncommitted change blocks ─────────────────────────────
R="$(make_fixture)"
echo "staged edit" >> "$R/README.md"
git -C "$R" add README.md
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"uncommitted changes to tracked files"* ]]; then
  pass "U4: a staged change blocks"
else
  fail "U4: staged change did not block — rc=$RC out='$OUT'"
fi

# ─── U5: a tracked deletion blocks ──────────────────────────────────────────
R="$(make_fixture)"
rm -f "$R/README.md"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"uncommitted changes to tracked files"* ]]; then
  pass "U5: a tracked deletion blocks"
else
  fail "U5: tracked deletion did not block — rc=$RC out='$OUT'"
fi

# ─── U6: an unfinished merge blocks even with a clean tree ──────────────────
# A clean index does not mean the repository is idle.
R="$(make_fixture)"
git -C "$R" rev-parse HEAD > "$(git -C "$R" rev-parse --absolute-git-dir)/MERGE_HEAD"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"unfinished MERGE"* ]]; then
  pass "U6: an unfinished merge blocks despite a clean tree"
else
  fail "U6: unfinished merge did not block — rc=$RC out='$OUT'"
fi

# ─── U7: an unfinished rebase blocks ────────────────────────────────────────
R="$(make_fixture)"
mkdir -p "$(git -C "$R" rev-parse --absolute-git-dir)/rebase-merge"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"rebase or cherry-pick sequence"* ]]; then
  pass "U7: an unfinished rebase blocks"
else
  fail "U7: unfinished rebase did not block — rc=$RC out='$OUT'"
fi

# ─── U8: a hidden tracked edit blocks ───────────────────────────────────────
# assume-unchanged hides a real edit to tracked stack content from status
# entirely — worse than the accepted untracked-collision residual, because
# nothing surfaces it at all.
R="$(make_fixture)"
git -C "$R" update-index --assume-unchanged README.md
echo "hidden edit" >> "$R/README.md"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"assume-unchanged"* ]]; then
  pass "U8: a tracked file hidden by assume-unchanged blocks"
else
  fail "U8: hidden tracked edit did not block — rc=$RC out='$OUT'"
fi

# ─── U9: an unreadable repository is 'unknown', never 'clean' ───────────────
# "Could not look" must never be recorded as "looked and it was fine".
R="$(make_fixture)"
printf 'not a git index' > "$(git -C "$R" rev-parse --absolute-git-dir)/index"
run_update "$R" >/dev/null; OUT="$(cat "$RUN_OUT")"
if [[ "$RC" -ne 0 && "$OUT" == *"Could not determine"* ]]; then
  pass "U9: a failing git status blocks as unknown, not clean"
elif [[ "$RC" -ne 0 ]]; then
  pass "U9: a failing git status blocks (different message, still refused)"
else
  fail "U9: a broken index read as clean and proceeded — out='$OUT'"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
