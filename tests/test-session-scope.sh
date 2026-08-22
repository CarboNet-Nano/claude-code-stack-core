#!/usr/bin/env bash
# Tests for hooks/session-marker.sh and lib/session-scope.sh (ADR-072 D2,
# Stage 1 of docs/plans/2026-08-11-session-bookends-design.md).
#
# Every test builds an isolated fixture world: a fake $HOME and a real
# throwaway git repo (tests/test-adr-drift.sh's precedent — the code under
# test reads real git history, so mocking that away tests nothing that
# matters). No test touches the real $HOME or the real machine's session
# markers.
#
# --since (the "overrides every rung" case) is exercised in
# tests/test-session-close.sh, where the flag actually lives (session-close.sh
# scope --since), not in lib/session-scope.sh itself.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-marker.sh"
LIB="$REPO_ROOT/lib/session-scope.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-scope-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

new_repo() {  # new_repo <name> -> echoes the REAL (symlink-resolved) repo
              # root of a fresh 1-commit git repo — must match what
              # `git rev-parse --show-toplevel` returns, since that's what
              # both the hook and lib/session-scope.sh key markers by (macOS
              # $TMPDIR is a symlink into /private, so the raw mktemp path
              # and git's resolved root can differ).
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" )
  git -C "$r" rev-parse --show-toplevel
}

fire_hook() {  # fire_hook <home> <session_id> <source> <cwd>
  local home="$1" sid="$2" src="$3" cwd="$4"
  jq -nc --arg sid "$sid" --arg src "$src" --arg cwd "$cwd" '{session_id:$sid, source:$src, cwd:$cwd}' \
    | HOME="$home" bash "$HOOK"
}

marker_dir_for() {  # marker_dir_for <home> <repo_root>
  local home="$1" root="$2"
  local slug; slug="$(printf '%s' "$root" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_')"
  if [[ ${#slug} -gt 100 ]]; then slug="${slug: -100}"; fi
  printf '%s/.claude/state/session-markers/%s' "$home" "$slug"
}

# ---------------------------------------------------------------- T1: startup
R1="$(new_repo t1)"
H1="$TMP/home-t1"; mkdir -p "$H1"
fire_hook "$H1" "sess-1" "startup" "$R1" >/dev/null
MDIR="$(marker_dir_for "$H1" "$R1")"
MFILE="$MDIR/sess-1.json"
if [[ -f "$MFILE" ]]; then
  pass "T1: marker written on source:startup"
else
  fail "T1: marker written on source:startup — file missing at $MFILE"
fi
EXPECT_HEAD="$(git -C "$R1" rev-parse HEAD)"
GOT_HEAD="$(jq -r '.head_sha_at_start // empty' "$MFILE" 2>/dev/null)"
if [[ "$GOT_HEAD" == "$EXPECT_HEAD" ]]; then
  pass "T1: head_sha_at_start matches fixture HEAD"
else
  fail "T1: head_sha_at_start mismatch (got '$GOT_HEAD', want '$EXPECT_HEAD')"
fi
SCHEMA_OK="$(jq -e '(.version==1) and (.session_id=="sess-1") and (.source=="startup") and (has("started_at")) and (has("repo")) and (has("branch_at_start")) and (has("head_sha_at_start"))' "$MFILE" 2>/dev/null)"
if [[ "$SCHEMA_OK" == "true" ]]; then
  pass "T1: marker schema matches"
else
  fail "T1: marker schema mismatch"
fi

# --------------------------------------------------------- T2/T3: resume/compact
BEFORE_MTIME="$(cat "$MFILE")"
sleep 1
git -C "$R1" commit -q --allow-empty -m "second commit"
fire_hook "$H1" "sess-1" "resume" "$R1" >/dev/null
AFTER_RESUME="$(cat "$MFILE")"
if [[ "$BEFORE_MTIME" == "$AFTER_RESUME" ]]; then
  pass "T2: source:resume does NOT overwrite an existing marker"
else
  fail "T2: source:resume overwrote the marker (staleness bug reintroduced)"
fi

fire_hook "$H1" "sess-1" "compact" "$R1" >/dev/null
AFTER_COMPACT="$(cat "$MFILE")"
if [[ "$BEFORE_MTIME" == "$AFTER_COMPACT" ]]; then
  pass "T3: source:compact does NOT overwrite an existing marker"
else
  fail "T3: source:compact overwrote the marker"
fi

# ------------------------------------------------------------------ T4: clear
fire_hook "$H1" "sess-1" "clear" "$R1" >/dev/null
AFTER_CLEAR="$(cat "$MFILE")"
NEW_HEAD="$(git -C "$R1" rev-parse HEAD)"
GOT_HEAD2="$(jq -r '.head_sha_at_start // empty' "$MFILE" 2>/dev/null)"
if [[ "$AFTER_CLEAR" != "$BEFORE_MTIME" && "$GOT_HEAD2" == "$NEW_HEAD" ]]; then
  pass "T4: source:clear DOES overwrite (picks up the new HEAD)"
else
  fail "T4: source:clear did not overwrite as expected"
fi

# --------------------------------------------------------- T5: two repos, two dirs
R2="$(new_repo t5)"
fire_hook "$H1" "sess-2" "startup" "$R2" >/dev/null
MDIR2="$(marker_dir_for "$H1" "$R2")"
if [[ -f "$MDIR2/sess-2.json" && "$MDIR2" != "$MDIR" ]]; then
  pass "T5: two repos get two distinct marker dirs"
else
  fail "T5: marker dirs collided or second marker missing"
fi
if [[ ! -f "$MDIR2/sess-1.json" && ! -f "$MDIR/sess-2.json" ]]; then
  pass "T5: neither repo's marker dir sees the other's session"
else
  fail "T5: cross-repo marker leakage"
fi

# ------------------------------------------------------ T6: non-git / malformed
NONGIT="$TMP/not-a-repo"; mkdir -p "$NONGIT"
OUT="$(fire_hook "$H1" "sess-3" "startup" "$NONGIT" 2>&1)"
RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  pass "T6: non-git cwd -> exit 0, no output"
else
  fail "T6: non-git cwd misbehaved (rc=$RC out='$OUT')"
fi
find "$H1/.claude/state/session-markers" -name 'sess-3.json' 2>/dev/null | grep -q . && fail "T6: a marker file was written for a non-git cwd" || pass "T6: no marker file written for a non-git cwd"

OUT2="$(printf '' | HOME="$H1" bash "$HOOK" 2>&1)"; RC2=$?
[[ $RC2 -eq 0 && -z "$OUT2" ]] && pass "T6: empty stdin -> exit 0, no output" || fail "T6: empty stdin misbehaved (rc=$RC2)"

OUT3="$(printf '{not json' | HOME="$H1" bash "$HOOK" 2>&1)"; RC3=$?
[[ $RC3 -eq 0 ]] && pass "T6: malformed stdin -> exit 0" || fail "T6: malformed stdin -> nonzero exit"

# ------------------------------------------------------------------- T7: prune
R3="$(new_repo t7)"
PDIR="$(marker_dir_for "$H1" "$R3")"
mkdir -p "$PDIR"
for i in $(seq 1 205); do
  printf '{"version":1,"session_id":"old-%03d"}' "$i" > "$PDIR/old-$(printf '%03d' "$i").json"
done
# Backdate one marker 40 days so the mtime-based prune has something to catch.
OLD_ONE="$PDIR/old-001.json"
touch -t "$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '-40 days' +%Y%m%d%H%M)" "$OLD_ONE" 2>/dev/null || true
fire_hook "$H1" "sess-prune" "startup" "$R3" >/dev/null
COUNT="$(find "$PDIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
if [[ "$COUNT" -le 200 ]]; then
  pass "T7: prune caps the marker dir at <=200 files"
else
  fail "T7: prune did not cap the marker dir (got $COUNT)"
fi
if [[ ! -f "$OLD_ONE" ]]; then
  pass "T7: the 40-day-old marker was removed"
else
  fail "T7: the 40-day-old marker survived"
fi

# ------------------------------------------------------- lib/session-scope.sh
( set -uo pipefail; source "$LIB" ) 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "lib: sources cleanly"
else
  fail "lib: source failed"
fi

# ------------------------------------------------------ T8: rung 2 (session-start-ts)
R8="$(new_repo t8)"
H8="$TMP/home-t8"; mkdir -p "$H8/.claude/state"
git -C "$R8" rev-parse HEAD > /dev/null
date -u +%Y-%m-%dT%H:%M:%SZ > "$H8/.claude/state/session-start.txt"
SCOPE8="$(cd "$R8" && HOME="$H8" bash -c 'source "'"$LIB"'"; ss_scope_json')"
SRC8="$(printf '%s' "$SCOPE8" | jq -r '.source')"
CONF8="$(printf '%s' "$SCOPE8" | jq -r '.confidence')"
NOTE8="$(printf '%s' "$SCOPE8" | jq -r '.note')"
if [[ "$SRC8" == "session-start-ts" && "$CONF8" == "approximate" && -n "$NOTE8" ]]; then
  pass "T8: rung 2 (session-start.txt) -> session-start-ts/approximate with a note"
else
  fail "T8: rung 2 mismatch (source=$SRC8 confidence=$CONF8 note='$NOTE8')"
fi

# ------------------------------------------------------- T9: rung 3 (handoff-ts)
R9="$(new_repo t9)"
H9="$TMP/home-t9"; mkdir -p "$H9"
mkdir -p "$R9/.claude"
printf '# Next-session handoff\n\n_Written: %s_\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$R9/.claude/next_prompt.md"
SCOPE9="$(cd "$R9" && HOME="$H9" bash -c 'source "'"$LIB"'"; ss_scope_json')"
SRC9="$(printf '%s' "$SCOPE9" | jq -r '.source')"
if [[ "$SRC9" == "handoff-ts" ]]; then
  pass "T9: rung 3 (handoff _Written: line) -> handoff-ts"
else
  fail "T9: rung 3 mismatch (source=$SRC9, full=$SCOPE9)"
fi

# --------------------------------------------------- T10: rung 5 (none/unknown)
R10="$(new_repo t10)"
H10="$TMP/home-t10"; mkdir -p "$H10"
SCOPE10="$(cd "$R10" && HOME="$H10" bash -c 'source "'"$LIB"'"; ss_scope_json')"
SRC10="$(printf '%s' "$SCOPE10" | jq -r '.source')"
CONF10="$(printf '%s' "$SCOPE10" | jq -r '.confidence')"
SHA10="$(printf '%s' "$SCOPE10" | jq -r '.start_sha')"
if [[ "$SRC10" == "none" && "$CONF10" == "unknown" && -z "$SHA10" ]]; then
  pass "T10: rung 5 (nothing resolvable) -> none/unknown, empty start_sha"
else
  fail "T10: rung 5 mismatch (source=$SRC10 confidence=$CONF10 sha='$SHA10')"
fi

# --------------------------------------------------------- T11: ss_diff_range
RANGE10="$(cd "$R10" && HOME="$H10" bash -c 'source "'"$LIB"'"; ss_diff_range')"
if [[ -z "$RANGE10" ]]; then
  pass "T11: ss_diff_range is empty when start_sha is empty"
else
  fail "T11: ss_diff_range returned '$RANGE10' with no start_sha"
fi

# --------------------------------------------- T12: HOME unset / git off PATH
NO_HOME_OUT="$(cd "$R10" && env -u HOME bash -c 'source "'"$LIB"'"; ss_scope_json; echo "rc=$?"' 2>&1)"
if printf '%s' "$NO_HOME_OUT" | grep -q 'rc=0'; then
  pass "T12: ss_scope_json returns 0 with \$HOME unset"
else
  fail "T12: ss_scope_json failed with \$HOME unset: $NO_HOME_OUT"
fi

NOPATH_BIN="$TMP/nopath-bin"; mkdir -p "$NOPATH_BIN"
for t in jq bash; do p="$(command -v "$t")"; ln -sf "$p" "$NOPATH_BIN/$t"; done
NO_GIT_OUT="$(cd "$R10" && PATH="$NOPATH_BIN" HOME="$H10" bash -c 'source "'"$LIB"'"; ss_scope_json; echo "rc=$?"; ss_marker_path; echo "rc=$?"; ss_diff_range; echo "rc=$?"; ss_last_close_sha; echo "rc=$?"' 2>&1)"
FAILCOUNT="$(printf '%s' "$NO_GIT_OUT" | grep -c 'rc=[1-9]')"
if [[ "$FAILCOUNT" -eq 0 ]]; then
  pass "T12: every function returns 0 with git off PATH"
else
  fail "T12: a function returned nonzero with git off PATH: $NO_GIT_OUT"
fi

echo "test-session-scope: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
