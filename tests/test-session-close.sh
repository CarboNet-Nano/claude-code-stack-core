#!/usr/bin/env bash
# Tests for scripts/session-close.sh (ADR-072, Stages 1 and 3 of
# docs/plans/2026-08-11-session-bookends-design.md).
#
# Stage 1: scope, inventory, docdrift, tests, cost, manifest, verify-push,
# log. Stage 3: `dispose` (the one mutating subcommand — commit /
# rescue-branch / leave).
#
# Every dispose test runs against a REAL throwaway git repo created fresh
# under $TMP by `new_repo`, with a REAL local bare repo (also under $TMP) as
# its `origin` remote — never a real network call, and this checkout (the
# actual claude-code-stack repo) is NEVER touched or used as a fixture.
# `new_repo`'s output already IS the real (symlink-resolved) repo root, so
# nothing here can accidentally resolve back to the real dev checkout.
#
# Real throwaway git repos (tests/test-adr-drift.sh's precedent), a fake
# $HOME, and stubbed subagent-runs.jsonl / model-routing.json fixtures. No
# test makes a real network call or touches the real $HOME.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCL="$REPO_ROOT/scripts/session-close.sh"

PASS=0; FAIL=0; SKIPPED=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP: $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-close-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

new_repo() {  # new_repo <name> -> echoes the real repo root
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" )
  git -C "$r" rev-parse --show-toplevel
}

run_scl() {  # run_scl <home> <cwd> <args...>
  local home="$1" cwd="$2"; shift 2
  ( cd "$cwd" && HOME="$home" LOOP_STATE_DIR="$home/.claude/session-state" bash "$SCL" "$@" )
}

# ------------------------------------------------------------- scope / diff
R1="$(new_repo scope)"
H1="$TMP/home-scope"; mkdir -p "$H1"
echo "line1" >> "$R1/README.md"
OUT="$(run_scl "$H1" "$R1" scope)"
if printf '%s' "$OUT" | jq -e '.diff_path and (.diff_lines >= 0) and (.truncated == false)' >/dev/null 2>&1; then
  pass "scope: captures a diff with diff_path/diff_lines/truncated"
else
  fail "scope: unexpected shape: $OUT"
fi
DIFF_ABS="$R1/$(printf '%s' "$OUT" | jq -r '.diff_path')"
if [[ -s "$DIFF_ABS" ]]; then
  pass "scope: diff file was written and non-empty"
else
  fail "scope: diff file missing or empty at $DIFF_ABS"
fi

# scope: 5,000-line diff -> truncated
R1B="$(new_repo scope-big)"
python3 -c "
with open('$R1B/big.txt','w') as f:
    for i in range(5000):
        f.write('line %d\n' % i)
"
( cd "$R1B" && git add -A && git commit -qm "add big file" )
python3 -c "
with open('$R1B/big.txt','a') as f:
    for i in range(5000):
        f.write('changed %d\n' % i)
"
OUT_BIG="$(run_scl "$H1" "$R1B" scope --since HEAD~1)"
TRUNC="$(printf '%s' "$OUT_BIG" | jq -r '.truncated')"
DL="$(printf '%s' "$OUT_BIG" | jq -r '.diff_lines')"
if [[ "$TRUNC" == "true" && "$DL" == "2000" ]]; then
  pass "scope: a 5,000-line diff is truncated to the 2000-line cap"
else
  fail "scope: truncation mismatch (truncated=$TRUNC diff_lines=$DL)"
fi

# scope --since overrides every rung (even when a marker/session-start.txt exists)
mkdir -p "$H1/.claude/state"
date -u +%Y-%m-%dT%H:%M:%SZ > "$H1/.claude/state/session-start.txt"
OUT_SINCE="$(run_scl "$H1" "$R1" scope --since HEAD)"
SRC_SINCE="$(printf '%s' "$OUT_SINCE" | jq -r '.source')"
if [[ "$SRC_SINCE" == "override" ]]; then
  pass "scope --since overrides every ladder rung"
else
  fail "scope --since did not override the ladder (source=$SRC_SINCE)"
fi

# ------------------------------------------------------------------- inventory
R2="$(new_repo inventory)"
H2="$TMP/home-inventory"; mkdir -p "$H2/.claude/session-state"
echo "dirty" >> "$R2/README.md"
echo "untracked" > "$R2/new-file.txt"
( cd "$R2" && git commit -aqm "second commit" -- README.md 2>/dev/null; true )
echo "dirty again" >> "$R2/README.md"

cat > "$H2/.claude/session-state/loop-state.abc.json" <<'EOF'
{"active":true,"loop_id":"myloop","status":"running","iteration":3,"bounds":{"max_iterations":10},"cost_so_far_usd":0.5}
EOF
cat > "$H2/.claude/session-state/loop-state.def.json" <<'EOF'
{"active":false,"loop_id":"otherloop","status":"goal_met","iteration":9}
EOF

mkdir -p "$R2/.claude"
echo "99999999" > "$R2/.claude/dead.pid"
echo "$$" > "$R2/.claude/alive.pid"

INV="$(run_scl "$H2" "$R2" inventory)"
UNPUSHED="$(printf '%s' "$INV" | jq -r '.unpushed')"
if [[ "$UNPUSHED" == "branch never pushed" ]]; then
  pass "inventory: no upstream -> unpushed is the literal string, not 0"
else
  fail "inventory: unpushed mismatch: $UNPUSHED"
fi
ACTIVE_LOOPS="$(printf '%s' "$INV" | jq '[.loops[] | select(.loop_id=="myloop")] | length')"
INACTIVE_PRESENT="$(printf '%s' "$INV" | jq '[.loops[] | select(.loop_id=="otherloop")] | length')"
if [[ "$ACTIVE_LOOPS" == "1" && "$INACTIVE_PRESENT" == "0" ]]; then
  pass "inventory: only active (active==true) loops are listed"
else
  fail "inventory: loop filtering wrong (active=$ACTIVE_LOOPS inactive_present=$INACTIVE_PRESENT)"
fi
ALIVE_COUNT="$(printf '%s' "$INV" | jq '[.pids[] | select(.alive==true)] | length')"
DEAD_COUNT="$(printf '%s' "$INV" | jq '[.pids[] | select(.alive==false)] | length')"
if [[ "$ALIVE_COUNT" == "1" && "$DEAD_COUNT" == "1" ]]; then
  pass "inventory: 1 live pid, 1 dead pid, both reported"
else
  fail "inventory: pid liveness mismatch (alive=$ALIVE_COUNT dead=$DEAD_COUNT): $(printf '%s' "$INV" | jq -c .pids)"
fi
UNKNOWABLE="$(printf '%s' "$INV" | jq -r '.unknowable[0]')"
if [[ "$UNKNOWABLE" == "background bash shells: not knowable from files — check /bashes in the UI before closing" ]]; then
  pass "inventory: always includes the background-shells unknowable line"
else
  fail "inventory: unknowable line missing/wrong: $UNKNOWABLE"
fi

# inventory never calls pgrep/ps
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
for bad in pgrep ps; do
  cat > "$FAKEBIN/$bad" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$FAKEBIN/$bad"
done
REAL_PATH="$PATH"
NOPS_OUT="$(cd "$R2" && PATH="$FAKEBIN:$REAL_PATH" HOME="$H2" LOOP_STATE_DIR="$H2/.claude/session-state" bash "$SCL" inventory 2>&1)"
NOPS_RC=$?
if [[ $NOPS_RC -eq 0 ]] && printf '%s' "$NOPS_OUT" | jq -e . >/dev/null 2>&1; then
  pass "inventory: never calls pgrep/ps (stubbed to exit 42, still exits 0 with full output)"
else
  fail "inventory: broke when pgrep/ps are poisoned (rc=$NOPS_RC): $NOPS_OUT"
fi

# ------------------------------------------------------------------- docdrift
R3="$(new_repo docdrift)"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "x" > "$R3/code$i.txt"; done
( cd "$R3" && git add -A )
DD1="$(run_scl "$TMP/home-dd" "$R3" docdrift)"
FLAG1="$(printf '%s' "$DD1" | jq -r '.flagged')"
[[ "$FLAG1" == "true" ]] && pass "docdrift: code changed, no doc changed -> flagged true" || fail "docdrift: expected flagged=true, got $DD1"

R4="$(new_repo docdrift-changelog)"
echo "x" > "$R4/code.txt"
echo "y" >> "$R4/CHANGELOG.md" 2>/dev/null || echo "y" > "$R4/CHANGELOG.md"
( cd "$R4" && git add -A )
DD2="$(run_scl "$TMP/home-dd2" "$R4" docdrift)"
FLAG2="$(printf '%s' "$DD2" | jq -r '.flagged')"
[[ "$FLAG2" == "false" ]] && pass "docdrift: code + CHANGELOG.md -> flagged false" || fail "docdrift: expected flagged=false, got $DD2"

R5="$(new_repo docdrift-docsonly)"
mkdir -p "$R5/docs"
echo "y" > "$R5/docs/note.md"
( cd "$R5" && git add -A )
DD3="$(run_scl "$TMP/home-dd3" "$R5" docdrift)"
FLAG3="$(printf '%s' "$DD3" | jq -r '.flagged')"
[[ "$FLAG3" == "false" ]] && pass "docdrift: docs-only change -> flagged false" || fail "docdrift: expected flagged=false, got $DD3"

# ---------------------------------------------------------------------- tests
R6="$(new_repo tests-green)"
mkdir -p "$R6/tests" "$R6/scripts"
echo "x" > "$R6/scripts/widget.sh"
cat > "$R6/tests/test-widget.sh" <<'EOF'
#!/usr/bin/env bash
echo "widget: 5 passed, 0 failed"
EOF
chmod +x "$R6/tests/test-widget.sh"
( cd "$R6" && git add -A )
T1OUT="$(run_scl "$TMP/home-t1" "$R6" tests --write-log)"
T1STATUS="$(printf '%s' "$T1OUT" | jq -r '.status')"
T1PASS="$(printf '%s' "$T1OUT" | jq -r '.totals.passed')"
if [[ "$T1STATUS" == "pass" && "$T1PASS" == "5" ]]; then
  pass "tests: green stub -> pass with counts parsed from the summary line"
else
  fail "tests: green stub mismatch: $T1OUT"
fi
# ADR-074 D5: the log is per-session under .claude/session-logs/ when a session
# id resolves, and the pre-D5 single file otherwise. Resolve rather than assume
# a path — asserting the legacy path alone would fail under a session id.
LOGFILE="$(ls -1t "$R6/.claude/session-logs"/*.json "$R6/.claude/session-log.json" 2>/dev/null | head -1)"
if [[ -n "$LOGFILE" && -f "$LOGFILE" ]] && jq -e '.tests.status == "pass"' "$LOGFILE" >/dev/null 2>&1; then
  pass "tests --write-log: wrote the session log with the tests section"
else
  fail "tests --write-log: log missing or wrong at '${LOGFILE:-<none found>}': $(cat "$LOGFILE" 2>/dev/null)"
fi

R7="$(new_repo tests-red)"
mkdir -p "$R7/tests"
cat > "$R7/tests/test-red.sh" <<'EOF'
#!/usr/bin/env bash
echo "red: 1 passed, 2 failed"
exit 1
EOF
chmod +x "$R7/tests/test-red.sh"
T2OUT="$(run_scl "$TMP/home-t2" "$R7" tests --suites "tests/test-red.sh")"
T2STATUS="$(printf '%s' "$T2OUT" | jq -r '.status')"
[[ "$T2STATUS" == "fail" ]] && pass "tests: red stub -> fail" || fail "tests: expected fail, got $T2OUT"

R8="$(new_repo tests-timeout)"
mkdir -p "$R8/tests"
cat > "$R8/tests/test-slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 10
echo "slow: 1 passed, 0 failed"
EOF
chmod +x "$R8/tests/test-slow.sh"
START_TS=$(date +%s)
T3OUT="$(run_scl "$TMP/home-t3" "$R8" tests --suites "tests/test-slow.sh" --timeout 2)"
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
T3STATUS="$(printf '%s' "$T3OUT" | jq -r '.status')"
# Ceiling is the sleep length (10s), not timeout+slack: what this proves is
# that the 2s timeout fired instead of the suite running to completion. A
# tight bound around the timeout itself flakes on a loaded CI runner (the
# same class of failure that broke test-improvement-queue's lock test in CI
# at 11s against an 8s ceiling) without testing anything more.
if [[ "$T3STATUS" == "timeout" && "$ELAPSED" -lt 10 ]]; then
  pass "tests: a suite sleeping 10s past --timeout 2 -> timeout, returns before the sleep ends (took ${ELAPSED}s)"
else
  fail "tests: timeout mismatch (status=$T3STATUS elapsed=${ELAPSED}s)"
fi

R9="$(new_repo tests-nomatch)"
T4OUT="$(run_scl "$TMP/home-t4" "$R9" tests)"
T4STATUS="$(printf '%s' "$T4OUT" | jq -r '.status')"
T4REASON="$(printf '%s' "$T4OUT" | jq -r '.reason')"
if [[ "$T4STATUS" == "skipped" && "$T4REASON" == "no matching suite" ]]; then
  pass "tests: no matching suite -> skipped, never pass"
else
  fail "tests: expected skipped/no matching suite, got $T4OUT"
fi

# ------------------------------------------------------------------------ cost
R10="$(new_repo cost)"
H10="$TMP/home-cost"; mkdir -p "$H10/.claude/logs" "$H10/.claude/config"
cat > "$H10/.claude/config/model-routing.json" <<'EOF'
{
  "providers": { "anthropic": { "models": {
    "test-model": { "pricing_per_million_input": 1.0, "pricing_per_million_output": 5.0 }
  } } },
  "model_fit": { "tier_ladder": ["test-model"] }
}
EOF
# session-start.txt must resolve (via `git rev-list -1 --before=<ts> HEAD`)
# to a real commit in this fixture repo, so it has to be AT OR AFTER the
# fixture commit's own timestamp (rung 1's marker doesn't exist here, so
# ss_scope_json falls through to rung 2).
COST_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$H10/.claude/logs/subagent-runs.jsonl" <<EOF
{"event":"main_turn","agent":"main","session_start":"$COST_TS","project":"$R10","model":"test-model","in_tokens":100000,"out_tokens":200000,"tool_counts":{"edit":5}}
{"event":"main_turn","agent":"main","session_start":"$COST_TS","project":"$R10","model":"test-model","in_tokens":50000,"out_tokens":100000,"tool_counts":{"edit":3}}
EOF
mkdir -p "$H10/.claude/state"
printf '%s' "$COST_TS" > "$H10/.claude/state/session-start.txt"
COST_OUT="$(run_scl "$H10" "$R10" cost)"
COST_USD="$(printf '%s' "$COST_OUT" | jq -r '.usd')"
# 150000 in @ $1/M = 0.15 ; 300000 out @ $5/M = 1.5 ; total 1.65
if [[ "$COST_USD" == "1.65" ]]; then
  pass "cost: numeric assertion against fixture rows and price table, to the cent"
else
  fail "cost: expected 1.65, got '$COST_USD' (full: $COST_OUT)"
fi

# ---------------------------------------------------------------------- manifest
R11="$(new_repo manifest)"
H11="$TMP/home-manifest"; mkdir -p "$H11/.claude/session-state"
cat > "$H11/.claude/session-state/loop-state.x.json" <<'EOF'
{"active":true,"loop_id":"loopx","status":"running","iteration":4,"bounds":{"max_iterations":10}}
EOF
MAN_JSON="$(run_scl "$H11" "$R11" manifest --json)"
if printf '%s' "$MAN_JSON" | jq -e 'map(select(.text | test("as-of|as_of") | not)) | length >= 0' >/dev/null 2>&1 \
   && printf '%s' "$MAN_JSON" | jq -e '.[0] | has("as_of")' >/dev/null 2>&1; then
  pass "manifest --json: entries carry an as_of timestamp"
else
  fail "manifest --json: missing as_of: $MAN_JSON"
fi
MAN_MD="$(run_scl "$H11" "$R11" manifest --markdown)"
if printf '%s' "$MAN_MD" | grep -q "Kill: /loop-engineer stop loopx"; then
  pass "manifest --markdown: entries carry a kill/resume instruction"
else
  fail "manifest --markdown: missing kill instruction: $MAN_MD"
fi

R12="$(new_repo manifest-empty)"
MAN_EMPTY="$(run_scl "$TMP/home-manifest-empty" "$R12" manifest --markdown)"
if [[ -z "$MAN_EMPTY" ]]; then
  pass "manifest --markdown: empty inventory -> empty output, no bare heading"
else
  fail "manifest --markdown: expected empty output, got: $MAN_EMPTY"
fi

# ------------------------------------------------------------------ verify-push
R13="$(new_repo verifypush)"
BARE="$TMP/bare-verifypush.git"
git init -q --bare "$BARE"
( cd "$R13" && git remote add origin "$BARE" && git push -q origin HEAD:main )
VP_OK="$(run_scl "$TMP/home-vp" "$R13" verify-push --ref main)"
VP_OK_VERIFIED="$(printf '%s' "$VP_OK" | jq -r '.verified')"
[[ "$VP_OK_VERIFIED" == "true" ]] && pass "verify-push: local==remote -> verified true" || fail "verify-push: expected verified true, got $VP_OK"

( cd "$R13" && echo more >> README.md && git commit -aqm "diverge" )
VP_DIVERGED="$(run_scl "$TMP/home-vp" "$R13" verify-push --ref main)"
VP_DIV_VERIFIED="$(printf '%s' "$VP_DIVERGED" | jq -r '.verified')"
VP_DIV_REMOTE="$(printf '%s' "$VP_DIVERGED" | jq -r '.remote_sha')"
if [[ "$VP_DIV_VERIFIED" == "false" && -n "$VP_DIV_REMOTE" ]]; then
  pass "verify-push: diverged -> verified false, both shas present"
else
  fail "verify-push: diverged case wrong: $VP_DIVERGED"
fi

# #186 — the worktree case, which is the one that mattered and the one that
# could never pass. handoff-write must never commit in the primary worktree,
# so its Path B commits somewhere else and pushes from there. Comparing THIS
# checkout's HEAD to the pushed branch then asks a question whose answer is
# always no: a handoff that really landed was reported as local-only.
#
# Reproduced literally: commit in a real second worktree, push from it, then
# diverge the primary checkout so the two are genuinely different.
R13B="$(new_repo verifypush-worktree)"
BARE_B="$TMP/bare-verifypush-wt.git"
git init -q --bare "$BARE_B"
( cd "$R13B" && git remote add origin "$BARE_B" && git push -q origin HEAD:main )
WT_DIR="$TMP/wt-verifypush"
( cd "$R13B" && git worktree add -q -b handoff-wt "$WT_DIR" >/dev/null 2>&1 )
( cd "$WT_DIR" && echo "handoff" >> HANDOFF.md && git add -A && git commit -qm "handoff from the worktree" && git push -q origin HEAD:handoff-wt )
WT_SHA="$(git -C "$WT_DIR" rev-parse --verify -q HEAD)"
( cd "$R13B" && echo "unrelated" >> README.md && git commit -aqm "primary checkout moves on" )

VP_WT_OLD="$(run_scl "$TMP/home-vp3" "$R13B" verify-push --ref handoff-wt)"
[[ "$(printf '%s' "$VP_WT_OLD" | jq -r '.verified')" == "false" ]] \
  && pass "verify-push: without --expect it still compares this checkout's HEAD (the old behaviour, unchanged)" \
  || fail "verify-push: the default comparison changed: $VP_WT_OLD"

VP_WT="$(run_scl "$TMP/home-vp3" "$R13B" verify-push --ref handoff-wt --expect "$WT_SHA")"
[[ "$(printf '%s' "$VP_WT" | jq -r '.verified')" == "true" ]] \
  && pass "verify-push: --expect confirms a commit pushed from a worktree (#186)" \
  || fail "verify-push: a landed worktree push still reports unverified: $VP_WT"
[[ "$(printf '%s' "$VP_WT" | jq -r '.local_sha')" == "$WT_SHA" ]] \
  && pass "verify-push: the reported local sha is the commit asked about, not this checkout's HEAD" \
  || fail "verify-push: local_sha was not the expected commit: $VP_WT"

# --expect must not become a way to claim a push that did not happen.
VP_WT_LIE="$(run_scl "$TMP/home-vp3" "$R13B" verify-push --ref handoff-wt --expect "0000000000000000000000000000000000000000")"
[[ "$(printf '%s' "$VP_WT_LIE" | jq -r '.verified')" == "false" ]] \
  && pass "verify-push: --expect with a sha the remote does not have is still unverified" \
  || fail "verify-push: --expect can claim an unpushed commit: $VP_WT_LIE"

R14="$(new_repo verify-push-noremote)"
VP_NOREMOTE="$(run_scl "$TMP/home-vp2" "$R14" verify-push --ref main)"
VP_NR_VERIFIED="$(printf '%s' "$VP_NOREMOTE" | jq -r '.verified')"
VP_NR_REASON="$(printf '%s' "$VP_NOREMOTE" | jq -r '.reason')"
if [[ "$VP_NR_VERIFIED" == "false" && "$VP_NR_REASON" == "no-remote" ]]; then
  pass "verify-push: no remote -> verified false, distinct reason"
else
  fail "verify-push: no-remote case wrong: $VP_NOREMOTE"
fi

R15="$(new_repo verify-push-missingref)"
git init -q --bare "$TMP/bare-missingref.git"
( cd "$R15" && git remote add origin "$TMP/bare-missingref.git" && git push -q origin HEAD:somebranch )
VP_MISSING="$(run_scl "$TMP/home-vp3" "$R15" verify-push --ref main)"
VP_M_VERIFIED="$(printf '%s' "$VP_MISSING" | jq -r '.verified')"
VP_M_REMOTE="$(printf '%s' "$VP_MISSING" | jq -r '.remote_sha')"
if [[ "$VP_M_VERIFIED" == "false" && -z "$VP_M_REMOTE" ]]; then
  pass "verify-push: missing remote ref -> verified false, remote_sha empty"
else
  fail "verify-push: missing-ref case wrong: $VP_MISSING"
fi
grep -q '"pushed"' <<< "$(printf '%s\n%s\n%s\n%s' "$VP_OK" "$VP_DIVERGED" "$VP_NOREMOTE" "$VP_MISSING")" \
  && fail "verify-push: the word 'pushed' leaked into a non-verified JSON payload" \
  || pass "verify-push: no path prints 'pushed' unqualified"

# --------------------------------------------------------------------------- log
R16="$(new_repo log)"
LOG1="$(run_scl "$TMP/home-log" "$R16" log)"
[[ "$LOG1" == "{}" ]] && pass "log: absent -> {}" || fail "log: expected {}, got $LOG1"

echo '{"cost":{"usd":2.5,"as_of":"2026-01-01T00:00:00Z"}}' | ( cd "$R16" && HOME="$TMP/home-log" bash "$SCL" log --write ) >/dev/null
LOG2="$(run_scl "$TMP/home-log" "$R16" log)"
if printf '%s' "$LOG2" | jq -e '.cost.usd == 2.5' >/dev/null 2>&1; then
  pass "log --write: merges the payload in"
else
  fail "log --write: merge failed: $LOG2"
fi

# Finding-1 schema guard: no live-status keys anywhere, ever.
echo '{"scope":{"source":"marker","confidence":"exact"},"to_recheck":{"loop_ids":["a"],"pids":[123],"unknowable":["x"]}}' \
  | ( cd "$R16" && HOME="$TMP/home-log" bash "$SCL" log --write ) >/dev/null
FORBIDDEN="$(grep -oE '"(loop_active|pid_alive|pr_state|tests_are_green)"' "$R16/.claude/session-log.json" || true)"
if [[ -z "$FORBIDDEN" ]]; then
  pass "log: schema guard — no forbidden live-status keys anywhere in the written log"
else
  fail "log: forbidden key(s) found: $FORBIDDEN"
fi
BOOL_UNDER_RECHECK="$(jq -r '.to_recheck | to_entries[] | select(.value == true or .value == false) | .key' "$R16/.claude/session-log.json" 2>/dev/null)"
if [[ -z "$BOOL_UNDER_RECHECK" ]]; then
  pass "log: schema guard — no boolean under to_recheck"
else
  fail "log: found a boolean under to_recheck: $BOOL_UNDER_RECHECK"
fi

# -------------------------------------------------------------------- dispose
# Stage 3 (ADR-072 D5a/§2.3). Every fixture repo here is a fresh throwaway
# under $TMP with its OWN local bare repo as `origin` -- no network call,
# and the real claude-code-stack checkout is never touched or referenced.

new_bare() {  # new_bare <name> -> path to a fresh local bare repo
  local b="$TMP/bare-$1.git"
  git init -q --bare "$b"
  printf '%s' "$b"
}

new_repo_with_remote() {  # new_repo_with_remote <name> -> repo root, origin already pushed
  local r; r="$(new_repo "$1")"
  local bare; bare="$(new_bare "$1")"
  git -C "$r" remote add origin "$bare"
  git -C "$r" push -q origin HEAD:main
  printf '%s' "$r"
}

# dispose_call <repo> <choice> [<slug-args>] -- <path...>
# Builds repeatable --path flags so tests never re-introduce the
# space-joined --paths word-splitting bug that was removed (BLOCKING
# finding 5) -- this is the ONLY calling convention exercised anywhere in
# this suite, matching the real interface.
dispose_call() {
  local repo="$1" choice="$2"; shift 2
  local -a extra=()
  while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  local -a pathflags=()
  local p
  for p in "$@"; do pathflags+=(--path "$p"); done
  ( cd "$repo" && bash "$SCL" dispose --choice "$choice" "${pathflags[@]}" "${extra[@]+"${extra[@]}"}" )
}

# --- leave: no mutation at all ---
RD1="$(new_repo dispose-leave)"
echo "dirty" >> "$RD1/README.md"
STATUS_BEFORE="$(git -C "$RD1" status --porcelain)"
LEAVE_OUT="$(dispose_call "$RD1" leave -- "README.md")"
STATUS_AFTER="$(git -C "$RD1" status --porcelain)"
if printf '%s' "$LEAVE_OUT" | jq -e '.[0].choice == "leave" and .[0].detail == "left-local"' >/dev/null 2>&1; then
  pass "dispose leave: reports choice=leave, detail=left-local"
else
  fail "dispose leave: unexpected JSON: $LEAVE_OUT"
fi
[[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] && pass "dispose leave: no git mutation at all" \
  || fail "dispose leave: git status changed (before='$STATUS_BEFORE' after='$STATUS_AFTER')"

# --- commit: tracked-modified + untracked, both land in one commit, and
# pre-staged UNRELATED content is left staged and untouched (BLOCKING
# finding 1 — a bare `git commit` with no pathspec would sweep it in) ---
RD2="$(new_repo dispose-commit)"
echo "pre-staged, must survive untouched" > "$RD2/unrelated.txt"
git -C "$RD2" add unrelated.txt
echo "modified" >> "$RD2/README.md"
echo "brand new" > "$RD2/new-file.txt"
COMMIT_OUT="$(dispose_call "$RD2" commit -- "README.md" "new-file.txt")"
COMMIT_CHOICES="$(printf '%s' "$COMMIT_OUT" | jq -r '[.[].choice] | unique | join(",")')"
[[ "$COMMIT_CHOICES" == "commit" ]] && pass "dispose commit: both paths report choice=commit" \
  || fail "dispose commit: unexpected choices: $COMMIT_CHOICES ($COMMIT_OUT)"
SHA1="$(printf '%s' "$COMMIT_OUT" | jq -r '.[0].detail')"
SHA2="$(printf '%s' "$COMMIT_OUT" | jq -r '.[1].detail')"
[[ -n "$SHA1" && "$SHA1" == "$SHA2" ]] && pass "dispose commit: both paths share the same commit sha" \
  || fail "dispose commit: sha mismatch ($SHA1 vs $SHA2)"
STATUS_AFTER_COMMIT="$(git -C "$RD2" status --porcelain)"
[[ "$STATUS_AFTER_COMMIT" == "A  unrelated.txt" ]] \
  && pass "dispose commit: pre-staged unrelated content survives staged and untouched (finding 1)" \
  || fail "dispose commit: unrelated.txt was swept into the commit or otherwise mutated: $STATUS_AFTER_COMMIT"
! git -C "$RD2" show --stat -1 --format= | grep -q "unrelated.txt" \
  && pass "dispose commit: the commit itself does NOT contain the unrelated file" \
  || fail "dispose commit: the commit contains unrelated.txt — whole-index commit bug reintroduced"
git -C "$RD2" show --stat -1 --format= | grep -q "new-file.txt" && \
git -C "$RD2" log -1 --format=%B | grep -q "2 file" && \
  pass "dispose commit: the actual commit contains both requested files, with a count in the message" || \
  fail "dispose commit: commit contents/message unexpected"

# --- commit: failed commit restores the index for exactly those paths
# (non-blocking companion fix, same lines) ---
RD2B="$(new_repo dispose-commit-failcase)"
echo "staged before" > "$RD2B/keep-staged.txt"
git -C "$RD2B" add keep-staged.txt
FAKE_NOCOMMIT="$TMP/fakegit-nocommit"; mkdir -p "$FAKE_NOCOMMIT"
REAL_GIT="$(command -v git)"
cat > "$FAKE_NOCOMMIT/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *" commit "* ]]; then exit 1; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_NOCOMMIT/git"
echo "edit" >> "$RD2B/README.md"
FAILCOMMIT_OUT="$(cd "$RD2B" && PATH="$FAKE_NOCOMMIT:$PATH" bash "$SCL" dispose --choice commit --path README.md)"
[[ "$(printf '%s' "$FAILCOMMIT_OUT" | jq -r '.[0].choice')" == "left-local" ]] \
  && pass "dispose commit: a failed commit degrades to left-local" \
  || fail "dispose commit: failed commit did not degrade cleanly: $FAILCOMMIT_OUT"
STATUS_AFTER_FAILCOMMIT="$(git -C "$RD2B" status --porcelain -- README.md)"
[[ "$STATUS_AFTER_FAILCOMMIT" == " M README.md" ]] \
  && pass "dispose commit: a failed commit un-stages exactly the attempted path (not left staged)" \
  || fail "dispose commit: README.md left in an unexpected state: $STATUS_AFTER_FAILCOMMIT"
[[ "$(git -C "$RD2B" status --porcelain -- keep-staged.txt)" == "A  keep-staged.txt" ]] \
  && pass "dispose commit: a failed commit does not touch unrelated pre-staged content" \
  || fail "dispose commit: keep-staged.txt was disturbed by the failed-commit recovery"

# --- rescue-branch: success path (tracked-modified + untracked), and
# pre-staged UNRELATED content survives here too ---
RD3="$(new_repo_with_remote dispose-rescue-ok)"
ORIGINAL_BRANCH_RD3="$(git -C "$RD3" branch --show-current)"
ORIGINAL_README="$(cat "$RD3/README.md")"
echo "pre-staged, must survive untouched" > "$RD3/unrelated.txt"
git -C "$RD3" add unrelated.txt
printf '%s\nEDITED\n' "$ORIGINAL_README" > "$RD3/README.md"
echo "new content" > "$RD3/scratch-note.txt"
RESCUE_OUT="$(dispose_call "$RD3" rescue-branch --slug mytask -- "README.md" "scratch-note.txt")"
RESCUE_BRANCH_NAME="$(printf '%s' "$RESCUE_OUT" | jq -r '.[0].detail' | sed 's/ (pushed)$//')"
if printf '%s' "$RESCUE_OUT" | jq -e '[.[].choice] == ["rescue-branch","rescue-branch"]' >/dev/null 2>&1 \
   && printf '%s' "$RESCUE_OUT" | jq -e '.[0].detail | endswith(" (pushed)")' >/dev/null 2>&1; then
  pass "dispose rescue-branch: reports choice=rescue-branch, detail ends with (pushed)"
else
  fail "dispose rescue-branch: unexpected JSON: $RESCUE_OUT"
fi
[[ "$RESCUE_BRANCH_NAME" == rescue/*-mytask ]] && pass "dispose rescue-branch: branch name matches rescue/<ts>-<slug>" \
  || fail "dispose rescue-branch: branch name wrong: $RESCUE_BRANCH_NAME"
CURRENT_BRANCH_AFTER="$(git -C "$RD3" branch --show-current)"
[[ "$CURRENT_BRANCH_AFTER" == "$ORIGINAL_BRANCH_RD3" ]] && pass "dispose rescue-branch: original branch restored after the operation" \
  || fail "dispose rescue-branch: left on $CURRENT_BRANCH_AFTER instead of $ORIGINAL_BRANCH_RD3"
README_AFTER="$(cat "$RD3/README.md")"
[[ "$README_AFTER" == "$ORIGINAL_README" ]] && pass "dispose rescue-branch: tracked file reverted to its pre-edit content on the original branch" \
  || fail "dispose rescue-branch: tracked file still shows the edit on the original branch"
[[ ! -f "$RD3/scratch-note.txt" ]] && pass "dispose rescue-branch: the previously-untracked file is gone from the original branch's working tree" \
  || fail "dispose rescue-branch: scratch-note.txt is still present on the original branch"
[[ "$(git -C "$RD3" status --porcelain -- README.md scratch-note.txt)" == "" ]] \
  && pass "dispose rescue-branch: the rescued paths are clean on the original branch (unrelated.txt staying staged is expected — checked separately)" \
  || fail "dispose rescue-branch: rescued paths still show changes on the original branch"
[[ "$(git -C "$RD3" status --porcelain -- unrelated.txt)" == "A  unrelated.txt" ]] \
  && pass "dispose rescue-branch: pre-staged unrelated content survives staged and untouched (finding 1)" \
  || fail "dispose rescue-branch: unrelated.txt was disturbed: $(git -C "$RD3" status --porcelain -- unrelated.txt)"
BARE_RD3="$TMP/bare-dispose-rescue-ok.git"
git -C "$BARE_RD3" show-ref --verify --quiet "refs/heads/$RESCUE_BRANCH_NAME" \
  && pass "dispose rescue-branch: the branch actually exists on the remote (bare repo)" \
  || fail "dispose rescue-branch: branch missing from the remote"
RESCUE_CONTENT="$(git -C "$RD3" show "$RESCUE_BRANCH_NAME:scratch-note.txt" 2>/dev/null)"
[[ "$RESCUE_CONTENT" == "new content" ]] && pass "dispose rescue-branch: the rescued file's content is correct on the rescue branch" \
  || fail "dispose rescue-branch: unexpected content on the rescue branch: $RESCUE_CONTENT"

# --- rescue-branch: push failure degrades to left-local, nothing lost, and
# pre-staged UNRELATED content survives (the reset must be pathspec-scoped
# too — a bare `git reset` would unstage it, same whole-index hazard) ---
RD4="$(new_repo dispose-rescue-fail)"   # note: no remote at all -> push always fails
ORIGINAL_BRANCH_RD4="$(git -C "$RD4" branch --show-current)"
ORIGINAL_README4="$(cat "$RD4/README.md")"
echo "pre-staged, must survive untouched" > "$RD4/unrelated.txt"
git -C "$RD4" add unrelated.txt
printf '%s\nEDITED-FAIL\n' "$ORIGINAL_README4" > "$RD4/README.md"
echo "should survive" > "$RD4/orphan.txt"
FAIL_OUT="$(dispose_call "$RD4" rescue-branch --slug willfail -- "README.md" "orphan.txt")"
if printf '%s' "$FAIL_OUT" | jq -e '[.[].choice] == ["left-local","left-local"]' >/dev/null 2>&1; then
  pass "dispose rescue-branch (push fails): degrades to choice=left-local, never reports success it didn't verify"
else
  fail "dispose rescue-branch (push fails): unexpected JSON: $FAIL_OUT"
fi
[[ "$(git -C "$RD4" branch --show-current)" == "$ORIGINAL_BRANCH_RD4" ]] \
  && pass "dispose rescue-branch (push fails): back on the original branch" \
  || fail "dispose rescue-branch (push fails): not on the original branch"
README_AFTER4="$(cat "$RD4/README.md")"
[[ "$README_AFTER4" == *"EDITED-FAIL"* ]] && pass "dispose rescue-branch (push fails): the edit is RESTORED, not lost" \
  || fail "dispose rescue-branch (push fails): the edit was lost! got: $README_AFTER4"
[[ -f "$RD4/orphan.txt" && "$(cat "$RD4/orphan.txt")" == "should survive" ]] \
  && pass "dispose rescue-branch (push fails): the previously-untracked file is restored, not lost" \
  || fail "dispose rescue-branch (push fails): orphan.txt lost or wrong content"
[[ "$(git -C "$RD4" status --porcelain -- README.md orphan.txt)" == $' M README.md\n?? orphan.txt' ]] \
  && pass "dispose rescue-branch (push fails): files are uncommitted again, exactly as before the attempt" \
  || fail "dispose rescue-branch (push fails): unexpected status: $(git -C "$RD4" status --porcelain -- README.md orphan.txt)"
[[ "$(git -C "$RD4" status --porcelain -- unrelated.txt)" == "A  unrelated.txt" ]] \
  && pass "dispose rescue-branch (push fails): pre-staged unrelated content survives staged and untouched (finding 1, applied to reset too)" \
  || fail "dispose rescue-branch (push fails): unrelated.txt was disturbed: $(git -C "$RD4" status --porcelain -- unrelated.txt)"
LEFTOVER_BRANCHES="$(git -C "$RD4" for-each-ref --format='%(refname:short)' refs/heads/rescue/ 2>/dev/null)"
[[ -z "$LEFTOVER_BRANCHES" ]] && pass "dispose rescue-branch (push fails): the orphaned local rescue branch was deleted (fully restored, safe to drop)" \
  || fail "dispose rescue-branch (push fails): leftover local branch(es): $LEFTOVER_BRANCHES"
[[ ! -f "$(git -C "$RD4" rev-parse --absolute-git-dir)/session-close-dispose.lock" ]] \
  && pass "dispose rescue-branch (push fails): the recovery marker is removed on a fully-resolved outcome" \
  || fail "dispose rescue-branch (push fails): the recovery marker was left behind after a clean restore"

# --- BLOCKING finding 2: a failed cherry-pick during the push-failure
# restore must KEEP the rescue branch (it's the only copy of the work) and
# exit non-zero -- never silently delete the branch and report left-local
# over data that was never actually restored. Simulated with a `git`
# wrapper that fails only `cherry-pick -n`, passing every other git
# invocation through to the real binary. ---
RD7="$(new_repo dispose-cherrypick-fails)"   # no remote -> push fails -> restore path runs
ORIGINAL_BRANCH_RD7="$(git -C "$RD7" branch --show-current)"
echo "edit that must not be lost" >> "$RD7/README.md"
FAKE_CP="$TMP/fakegit-cherrypick"; mkdir -p "$FAKE_CP"
cat > "$FAKE_CP/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"cherry-pick -n"* ]]; then exit 1; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_CP/git"
CP_OUT="$(cd "$RD7" && PATH="$FAKE_CP:$PATH" bash "$SCL" dispose --choice rescue-branch --path README.md --slug cpfail)"
CP_RC=$?
[[ "$CP_RC" != "0" ]] && pass "dispose rescue-branch: a failed cherry-pick restore exits non-zero (was: silently exit 0)" \
  || fail "dispose rescue-branch: a failed cherry-pick restore exited 0"
[[ "$(printf '%s' "$CP_OUT" | jq -r '.[0].choice')" == "error" ]] \
  && pass "dispose rescue-branch: a failed cherry-pick restore reports choice=error, not left-local or rescue-branch" \
  || fail "dispose rescue-branch: unexpected choice on cherry-pick failure: $CP_OUT"
LEFTOVER_RD7="$(git -C "$RD7" for-each-ref --format='%(refname:short)' refs/heads/rescue/ 2>/dev/null)"
[[ -n "$LEFTOVER_RD7" ]] && pass "dispose rescue-branch: the rescue branch is KEPT when cherry-pick fails (it's the only copy of the work)" \
  || fail "dispose rescue-branch: the rescue branch was deleted despite a failed restore — the data-loss path"
git -C "$RD7" show "$LEFTOVER_RD7:README.md" 2>/dev/null | grep -q "edit that must not be lost" \
  && pass "dispose rescue-branch: the kept branch actually contains the edit" \
  || fail "dispose rescue-branch: the kept branch does not contain the expected content"
[[ -f "$(git -C "$RD7" rev-parse --absolute-git-dir)/session-close-dispose.lock" ]] \
  && pass "dispose rescue-branch: the recovery marker is KEPT (not removed) on an unresolved outcome" \
  || fail "dispose rescue-branch: the recovery marker was removed despite an unresolved outcome"
rm -f "$(git -C "$RD7" rev-parse --absolute-git-dir)/session-close-dispose.lock"   # clean up for reuse below is not needed; RD7 is throwaway

# --- BLOCKING finding 3: the recovery marker blocks re-entry ---
RD8="$(new_repo dispose-marker)"
LOCKFILE_RD8="$(git -C "$RD8" rev-parse --absolute-git-dir)/session-close-dispose.lock"
printf 'started_at=stale\nchoice=commit\noriginal_branch=main\npaths:\n  fake.txt\n' > "$LOCKFILE_RD8"
echo "new edit" >> "$RD8/README.md"
MARKER_OUT="$(cd "$RD8" && bash "$SCL" dispose --choice commit --path README.md 2>&1)"
MARKER_RC=$?
[[ "$MARKER_RC" == "1" ]] && pass "dispose: a stale recovery marker blocks re-entry, exit 1" \
  || fail "dispose: expected exit 1 with a stale marker present, got $MARKER_RC"
printf '%s' "$MARKER_OUT" | grep -q "did not complete cleanly" \
  && pass "dispose: the refusal names the recorded state and recovery instructions" \
  || fail "dispose: refusal message missing recovery instructions: $MARKER_OUT"
[[ "$(git -C "$RD8" status --porcelain -- README.md)" == " M README.md" ]] \
  && pass "dispose: a blocked-by-marker call makes no mutation at all" \
  || fail "dispose: repo state changed despite the marker refusal"
[[ -f "$LOCKFILE_RD8" ]] && pass "dispose: the marker itself is left in place until a human resolves it" \
  || fail "dispose: the marker was unexpectedly removed by the refused call"
rm -f "$LOCKFILE_RD8"
# Now that the marker is gone, the same request succeeds normally.
MARKER_RETRY_OUT="$(dispose_call "$RD8" commit -- "README.md")"
[[ "$(printf '%s' "$MARKER_RETRY_OUT" | jq -r '.[0].choice')" == "commit" ]] \
  && pass "dispose: once the marker is removed, a normal dispose call succeeds again" \
  || fail "dispose: retry after clearing the marker failed: $MARKER_RETRY_OUT"

# --- detached HEAD refuses commit/rescue-branch ---
RD5="$(new_repo dispose-detached)"
FIRST_SHA_RD5="$(git -C "$RD5" rev-parse HEAD)"
git -C "$RD5" checkout -q "$FIRST_SHA_RD5"   # detach
echo "dirty" >> "$RD5/README.md"
DETACHED_COMMIT_OUT="$(dispose_call "$RD5" commit -- "README.md")"
[[ "$(printf '%s' "$DETACHED_COMMIT_OUT" | jq -r '.[0].choice')" == "left-local" ]] \
  && pass "dispose commit: detached HEAD refuses and degrades to left-local" \
  || fail "dispose commit: detached HEAD did not refuse: $DETACHED_COMMIT_OUT"
DETACHED_RESCUE_OUT="$(dispose_call "$RD5" rescue-branch --slug x -- "README.md")"
[[ "$(printf '%s' "$DETACHED_RESCUE_OUT" | jq -r '.[0].choice')" == "left-local" ]] \
  && pass "dispose rescue-branch: detached HEAD refuses and degrades to left-local" \
  || fail "dispose rescue-branch: detached HEAD did not refuse: $DETACHED_RESCUE_OUT"

# --- BLOCKING finding 4: path-safety refusals, including pathspec magic
# and leading-dash argv-injection shapes; exit 2, no mutation ---
RD6="$(new_repo dispose-pathsafety)"
STATUS_BEFORE_RD6="$(git -C "$RD6" status --porcelain)"
dispose_call "$RD6" commit -- "/etc/passwd" >/dev/null 2>&1; RC_ABS=$?
dispose_call "$RD6" commit -- "../outside.txt" >/dev/null 2>&1; RC_DOTDOT=$?
dispose_call "$RD6" commit -- ":/" >/dev/null 2>&1; RC_MAGIC1=$?
dispose_call "$RD6" commit -- ":(top)README.md" >/dev/null 2>&1; RC_MAGIC2=$?
dispose_call "$RD6" commit -- "-rf" >/dev/null 2>&1; RC_DASH=$?
dispose_call "$RD6" commit -- "." >/dev/null 2>&1; RC_DOT=$?
dispose_call "$RD6" commit -- "" >/dev/null 2>&1; RC_EMPTY=$?
STATUS_AFTER_RD6="$(git -C "$RD6" status --porcelain)"
[[ "$RC_ABS" == "2" && "$RC_DOTDOT" == "2" ]] && pass "dispose: absolute and '..' paths are refused with exit 2" \
  || fail "dispose: expected exit 2/2, got $RC_ABS/$RC_DOTDOT"
[[ "$RC_MAGIC1" == "2" && "$RC_MAGIC2" == "2" ]] \
  && pass "dispose: git pathspec magic (':/' , ':(top)...') is refused with exit 2 -- ':/' can no longer stage the whole repo" \
  || fail "dispose: expected exit 2/2 for pathspec-magic paths, got $RC_MAGIC1/$RC_MAGIC2"
[[ "$RC_DASH" == "2" ]] && pass "dispose: a leading-dash path (argv-injection shape) is refused with exit 2" \
  || fail "dispose: expected exit 2 for a leading-dash path, got $RC_DASH"
[[ "$RC_DOT" == "2" && "$RC_EMPTY" == "2" ]] && pass "dispose: bare '.' and empty paths are refused with exit 2" \
  || fail "dispose: expected exit 2/2 for '.'/empty, got $RC_DOT/$RC_EMPTY"
[[ "$STATUS_BEFORE_RD6" == "$STATUS_AFTER_RD6" ]] && pass "dispose: every refused path leaves the repo completely unmutated" \
  || fail "dispose: repo state changed despite refused paths"

# Regression proof that ':/' actually WOULD have staged the whole repo
# pre-fix: confirm the real git behavior this validation exists to
# prevent, by checking the porcelain status code actually flips from
# unstaged (' M') to staged ('M ').
echo "dirty for the sanity check" >> "$RD6/README.md"
STATUS_BEFORE_MAGIC="$(git -C "$RD6" status --porcelain -- README.md)"
( cd "$RD6" && git add -- ':/' >/dev/null 2>&1 )
STATUS_AFTER_MAGIC="$(git -C "$RD6" status --porcelain -- README.md)"
[[ "$STATUS_BEFORE_MAGIC" == " M README.md" && "$STATUS_AFTER_MAGIC" == "M  README.md" ]] \
  && pass "dispose: sanity check — ':/' really is repo-wide pathspec magic in real git (staged an unstaged file with no explicit path — confirms the rejection is load-bearing)" \
  || fail "dispose: sanity check inconclusive (before='$STATUS_BEFORE_MAGIC' after='$STATUS_AFTER_MAGIC')"
git -C "$RD6" reset -q >/dev/null 2>&1   # undo the sanity-check stage, not part of the tool under test

# --- BLOCKING finding 5: space- and newline-containing filenames survive
# intact through --path (repeatable, never word-split) ---
RD9="$(new_repo dispose-spacey-paths)"
mkdir -p "$RD9/notes"
printf 'hi\n' > "$RD9/notes/meeting notes.txt"
NEWLINE_NAME=$'weird\nname.txt'
printf 'also hi\n' > "$RD9/$NEWLINE_NAME" 2>/dev/null || true
SPACEY_OUT="$(dispose_call "$RD9" commit -- "notes/meeting notes.txt")"
[[ "$(printf '%s' "$SPACEY_OUT" | jq -r '.[0].path')" == "notes/meeting notes.txt" ]] \
  && pass "dispose: a filename containing a space survives intact as ONE path, not two" \
  || fail "dispose: space-containing filename was split or mangled: $SPACEY_OUT"
git -C "$RD9" show --stat -1 --format= | grep -q "meeting notes.txt" \
  && pass "dispose: the space-named file was actually committed" \
  || fail "dispose: the space-named file is missing from the commit"
if [[ -f "$RD9/$NEWLINE_NAME" ]]; then
  NEWLINE_OUT="$(cd "$RD9" && bash "$SCL" dispose --choice commit --path "$NEWLINE_NAME")"
  [[ "$(printf '%s' "$NEWLINE_OUT" | jq -r '.[0].path')" == "$NEWLINE_NAME" ]] \
    && pass "dispose: a filename containing a newline survives intact via --path (argv, never word-split)" \
    || fail "dispose: newline-containing filename was mangled: $NEWLINE_OUT"
else
  skip "dispose: newline-containing filename — filesystem/shell in this environment could not create one"
fi

# --- usage errors ---
( bash "$SCL" dispose --choice bogus --path "x" ) >/dev/null 2>&1
[[ $? == "2" ]] && pass "dispose: an unsupported --choice (e.g. a 'discard' attempt) exits 2 — no such option exists" \
  || fail "dispose: bad --choice did not exit 2"
( cd "$RD1" && bash "$SCL" dispose --choice commit ) >/dev/null 2>&1
[[ $? == "2" ]] && pass "dispose: no --path at all exits 2" || fail "dispose: missing --path did not exit 2"

# --- no stash anywhere ---
if grep -q "git stash" "$SCL"; then
  fail "dispose: 'git stash' appears in scripts/session-close.sh — rev 2 deleted the stash option entirely"
else
  pass "dispose: 'git stash' does not appear anywhere in scripts/session-close.sh"
fi
CARBONIGHT_SKILL_FOR_STASH="$REPO_ROOT/skills/carbonight/SKILL.md"
if [[ -f "$CARBONIGHT_SKILL_FOR_STASH" ]] && grep -q "git stash" "$CARBONIGHT_SKILL_FOR_STASH"; then
  fail "dispose: 'git stash' appears in skills/carbonight/SKILL.md — rev 2 deleted the stash option entirely"
else
  pass "dispose: 'git stash' does not appear anywhere in skills/carbonight/SKILL.md"
fi

# ==================================================================== ADR-074
# D5 — per-session logs, scalar resolution, and the boot union.
#
# Why these exist: before D5 every session in a repo merged into ONE
# .claude/session-log.json whose session_id was stamped only when empty, so a
# repo that had ever closed a session carried the FIRST session's id forever.
# Concurrent sessions overwrote each other, and the boot union (round-2
# Concern 4) could only ever see the newest document.

SL_SCOPE() { echo "adr-074 D5"; }

sl_write() {  # sl_write <home> <repo> <sid> <json>
  local home="$1" repo="$2" sid="$3" payload="$4"
  ( cd "$repo" && HOME="$home" CLAUDE_CODE_SESSION_ID="$sid" \
      bash "$SCL" log --write <<<"$payload" >/dev/null 2>&1 )
}

RSL="$(new_repo sesslogs)"
HSL="$TMP/home-sesslogs"; mkdir -p "$HSL"

# --- SI1: a session id routes the write to .claude/session-logs/<sid>.json
sl_write "$HSL" "$RSL" "SESSA" '{"tests":{"passed":5,"failed":0}}'
if [[ -f "$RSL/.claude/session-logs/SESSA.json" && ! -f "$RSL/.claude/session-log.json" ]]; then
  pass "SI1: session id A -> .claude/session-logs/SESSA.json, not the legacy single file"
else
  fail "SI1: expected session-logs/SESSA.json and no legacy file; got: $(ls -1 "$RSL/.claude" 2>&1 | tr '\n' ' ')"
fi

# --- SI3 (round-1 C2 regression): two sessions never share a document
sl_write "$HSL" "$RSL" "SESSB" '{"tests":{"passed":9,"failed":0}}'
SI3_A="$(jq -r '.tests.passed // empty' "$RSL/.claude/session-logs/SESSA.json" 2>/dev/null)"
SI3_B="$(jq -r '.tests.passed // empty' "$RSL/.claude/session-logs/SESSB.json" 2>/dev/null)"
if [[ "$SI3_A" == "5" && "$SI3_B" == "9" ]]; then
  pass "SI3: interleaved sessions A and B each hold only their own payload (5 / 9)"
else
  fail "SI3: cross-session contamination — A.passed=$SI3_A B.passed=$SI3_B (want 5 / 9)"
fi
SI3_AID="$(jq -r '.session_id // empty' "$RSL/.claude/session-logs/SESSA.json" 2>/dev/null)"
SI3_BID="$(jq -r '.session_id // empty' "$RSL/.claude/session-logs/SESSB.json" 2>/dev/null)"
if [[ "$SI3_AID" == "SESSA" && "$SI3_BID" == "SESSB" ]]; then
  pass "SI3: each document carries its OWN session_id (the pre-D5 stamp-once bug)"
else
  fail "SI3: session_id wrong — A=$SI3_AID B=$SI3_BID (want SESSA / SESSB)"
fi

# --- SI2: no session id -> today's single-file path, merge semantics intact
RSL2="$(new_repo sesslogs-nosid)"
( cd "$RSL2" && HOME="$HSL" CLAUDE_CODE_SESSION_ID="" bash "$SCL" log --write \
    <<<'{"tests":{"passed":1}}' >/dev/null 2>&1 )
( cd "$RSL2" && HOME="$HSL" CLAUDE_CODE_SESSION_ID="" bash "$SCL" log --write \
    <<<'{"cost":{"usd":2}}' >/dev/null 2>&1 )
if [[ -f "$RSL2/.claude/session-log.json" ]] && \
   jq -e '.tests.passed == 1 and .cost.usd == 2' "$RSL2/.claude/session-log.json" >/dev/null 2>&1; then
  pass "SI2: no session id -> legacy single file, successive writes still merge"
else
  fail "SI2: legacy path broken: $(cat "$RSL2/.claude/session-log.json" 2>&1)"
fi

# --- SI4: scalar resolution is newest-wins across BOTH locations
SI4_OUT="$(cd "$RSL" && HOME="$HSL" bash "$SCL" log --json 2>/dev/null)"
if printf '%s' "$SI4_OUT" | jq -e '.session_id == "SESSB" and .tests.passed == 9' >/dev/null 2>&1; then
  pass "SI4: log read resolves to the NEWEST document (SESSB)"
else
  fail "SI4: expected newest (SESSB/9), got: $SI4_OUT"
fi
RSL3="$(new_repo sesslogs-empty)"
SI4B="$(cd "$RSL3" && HOME="$HSL" bash "$SCL" log --json 2>/dev/null)"
if [[ "$(printf '%s' "$SI4B" | jq -c . 2>/dev/null)" == "{}" ]]; then
  pass "SI4: no log anywhere -> log prints {}"
else
  fail "SI4: expected {} with no logs, got: $SI4B"
fi

# --- SI5 + SI9 (round-3 Blocker 1 regression): retention keeps 20, and the
# union reads ALL 20. The OLD SI9 asserted "15 logs -> only 10 read", which
# encoded the defect as intended behaviour; it now asserts the opposite.
RSL4="$(new_repo sesslogs-retention)"
for i in $(seq -w 1 25); do
  sl_write "$HSL" "$RSL4" "S$i" "{\"rescue_branches\":[\"rescue/2026-08-13-0100-s$i\"]}"
done
SI5_COUNT="$(ls -1 "$RSL4/.claude/session-logs"/*.json 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SI5_COUNT" == "20" ]]; then
  pass "SI5: 25 writes -> exactly the 20 newest survive retention"
else
  fail "SI5: expected 20 retained logs, got $SI5_COUNT"
fi
SI9_UNION="$(cd "$RSL4" && HOME="$HSL" bash "$SCL" __collect-to-recheck --repo "$RSL4" 2>/dev/null)"
SI9_N="$(printf '%s' "$SI9_UNION" | jq -r '.rescue_branches | length' 2>/dev/null)"
if [[ "$SI9_N" == "20" ]]; then
  pass "SI9: the union reads ALL 20 retained logs (read cap == retention cap)"
else
  fail "SI9: union read $SI9_N rescue branches, want 20 — read cap has drifted below retention"
fi
SI9_OLDEST="$(ls -1t "$RSL4/.claude/session-logs"/*.json 2>/dev/null | tail -1)"
SI9_WANT="$(jq -r '.rescue_branches[0] // empty' "$SI9_OLDEST" 2>/dev/null)"
if [[ -n "$SI9_WANT" ]] && printf '%s' "$SI9_UNION" | jq -e --arg b "$SI9_WANT" \
     '.rescue_branches | index($b) != null' >/dev/null 2>&1; then
  pass "SI9: a rescue branch in the 20th-newest log still surfaces ($SI9_WANT)"
else
  fail "SI9: 20th-newest log's rescue branch was silently dropped (want $SI9_WANT)"
fi

# --- SI11: the invariant, asserted rather than commented
SI11_RET="$(grep -E '^_SCL_LOG_RETENTION=' "$SCL" | head -1 | cut -d= -f2)"
SI11_READ="$(grep -E '^_SCL_LOG_READ_CAP=' "$SCL" | head -1 | cut -d= -f2)"
if [[ -n "$SI11_RET" && "$SI11_RET" == "$SI11_READ" ]]; then
  pass "SI11: read cap ($SI11_READ) == retention cap ($SI11_RET) in source — the invariant holds"
else
  fail "SI11: INVARIANT BROKEN — retention=$SI11_RET read=$SI11_READ. Round-3 blocker 1: a read cap below retention silently drops retained rescue branches. Move both or neither."
fi

# --- SI7 (round-2 Concern 4 regression): a NON-newest session's rescue branch
# must still surface, tagged with the session it came from.
RSL5="$(new_repo sesslogs-union)"
sl_write "$HSL" "$RSL5" "OLDS" '{"rescue_branches":["rescue/2026-08-13-0100-keepme"]}'
sleep 1
sl_write "$HSL" "$RSL5" "NEWS" '{"tests":{"passed":3}}'
SI7_UNION="$(cd "$RSL5" && HOME="$HSL" bash "$SCL" __collect-to-recheck --repo "$RSL5" 2>/dev/null)"
if printf '%s' "$SI7_UNION" | jq -e \
     '.rescue_branches | index("rescue/2026-08-13-0100-keepme") != null' >/dev/null 2>&1; then
  pass "SI7: an older concurrent session's rescue branch is NOT dropped by the newer one"
else
  fail "SI7: rescue branch from the non-newest session was hidden: $SI7_UNION"
fi
if printf '%s' "$SI7_UNION" | jq -e \
     '(.foreign // []) | map(select(.session == "OLDS")) | length == 1' >/dev/null 2>&1; then
  pass "SI7: the entry is tagged with its source session (drives the '(from another session)' label)"
else
  fail "SI7: foreign tagging missing/wrong: $SI7_UNION"
fi

# --- SI8: the 72h window bounds the union at both ends
RSL6="$(new_repo sesslogs-window)"
sl_write "$HSL" "$RSL6" "INWIN" '{"rescue_branches":["rescue/2026-08-13-0100-inwindow"]}'
sl_write "$HSL" "$RSL6" "OLDWIN" '{"rescue_branches":["rescue/2026-08-13-0100-toolold"]}'
touch -t 202001010000 "$RSL6/.claude/session-logs/OLDWIN.json" 2>/dev/null
SI8_UNION="$(cd "$RSL6" && HOME="$HSL" bash "$SCL" __collect-to-recheck --repo "$RSL6" 2>/dev/null)"
if printf '%s' "$SI8_UNION" | jq -e \
     '(.rescue_branches | index("rescue/2026-08-13-0100-inwindow") != null) and
      (.rescue_branches | index("rescue/2026-08-13-0100-toolold") == null)' >/dev/null 2>&1; then
  pass "SI8: a log older than the union window is excluded; one inside it is included"
else
  fail "SI8: window bounding wrong: $SI8_UNION"
fi

# --- SI10: scalars still come from the single newest document, not the union
SI10="$(cd "$RSL5" && HOME="$HSL" bash "$SCL" log --json 2>/dev/null)"
if printf '%s' "$SI10" | jq -e '.session_id == "NEWS" and (.rescue_branches // [] | length) == 0' >/dev/null 2>&1; then
  pass "SI10: log (scalars) reads only the newest document — the union never leaks into it"
else
  fail "SI10: expected the newest document alone, got: $SI10"
fi

# --- SI6: every downstream reader works in a session-logs/-only repo
SB="$REPO_ROOT/scripts/session-brief.sh"
SI6_SINCE="$(cd "$RSL5" && HOME="$HSL" bash "$SB" since --json 2>/dev/null)"
if printf '%s' "$SI6_SINCE" | jq -e '.last_session_end_source' >/dev/null 2>&1; then
  pass "SI6: session-brief.sh since runs against a session-logs/-only repo"
else
  fail "SI6: since failed with no legacy log present: $SI6_SINCE"
fi
SI6_SHA="$( cd "$RSL5" && HOME="$HSL" bash -c '
  source "'"$REPO_ROOT"'/lib/session-scope.sh" 2>/dev/null
  ss_last_close_sha "'"$RSL5"'"' 2>/dev/null )"
sl_write "$HSL" "$RSL5" "NEWS" '{"head_sha_at_close":"deadbeefcafe"}'
SI6_SHA2="$( cd "$RSL5" && HOME="$HSL" bash -c '
  source "'"$REPO_ROOT"'/lib/session-scope.sh" 2>/dev/null
  ss_last_close_sha "'"$RSL5"'"' 2>/dev/null )"
if [[ "$SI6_SHA2" == "deadbeefcafe" ]]; then
  pass "SI6: ss_last_close_sha resolves through the per-session location"
else
  fail "SI6: ss_last_close_sha returned '$SI6_SHA2' (want deadbeefcafe; pre-write was '$SI6_SHA')"
fi

# ============================================ ADR-074 — the collapse (commit 2)

# ---------------------------------------------------------------- SL1
# Two tiers by decision, not drift (#187 + #215): the human-attended gates
# (handoff, queue) share one two-tier regex — value-shaped always refuses,
# a bare credential word only with an assignment-shaped value. The
# overnight gate stays word-blunt ON PURPOSE (#215: it fences an
# unattended agent's public PR diff, where a false negative publishes a
# credential). SL1 pins both facts: SCL==IQ byte-identical, and OG equal
# to the exact blunt pattern the #215 review kept — so any change to
# either is still a loud, reviewed event, never silent drift.
HG_RE_SCL="$(grep -m1 "^_SCL_SECRET_RE=" "$SCL" | cut -d= -f2-)"
HG_RE_IQ="$(grep -m1 "^_IQ_SECRET_RE=" "$REPO_ROOT/scripts/improvement-queue.sh" | cut -d= -f2-)"
HG_RE_OG="$(grep -m1 "^_OG_SECRET_RE=" "$REPO_ROOT/scripts/overnight-guard.sh" | cut -d= -f2-)"
HG_RE_OG_PINNED="'secret|password|token|api[_-]?key|service_role|bearer|ey[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{12,}'"
if [[ -n "$HG_RE_SCL" && "$HG_RE_SCL" == "$HG_RE_IQ" ]]; then
  pass "SL1: _SCL_SECRET_RE is byte-identical to _IQ_SECRET_RE (two-tier, human-attended gates)"
else
  fail "SL1: the human-attended secret regexes have drifted apart — scl='$HG_RE_SCL' iq='$HG_RE_IQ'"
fi
if [[ "$HG_RE_OG" == "$HG_RE_OG_PINNED" ]]; then
  pass "SL1: _OG_SECRET_RE is the exact blunt pattern the #215 review kept (deliberately not two-tier)"
else
  fail "SL1: _OG_SECRET_RE changed from the #215-reviewed blunt pattern — og='$HG_RE_OG'"
fi

# ---------------------------------------------------------------- handoff-gather
RHG="$(new_repo handoff-gather)"
HHG="$TMP/home-hg"; mkdir -p "$HHG"
HG1="$(run_scl "$HHG" "$RHG" handoff-gather)"
HG_KEYS='as_of repo branch worktree default_branch repo_state upstream uncommitted untracked commits diffstat prs team loop_corrections model_fit_receipt_pref running_markdown improvement_queue pm degraded'
HG_MISSING=""
for k in $HG_KEYS; do
  printf '%s' "$HG1" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1 || HG_MISSING="$HG_MISSING $k"
done
if [[ -z "$HG_MISSING" ]]; then
  pass "HG1: handoff-gather emits every documented key, always"
else
  fail "HG1: missing keys:$HG_MISSING"
fi

# HG1b — the documented SHAPES, not just the key names.
#
# This exists because the first implementation passed HG1 (every key present)
# while emitting `uncommitted` as a bare string array, `upstream` as an English
# sentence, and `team` without `session_start`/`in_play`/`domain_mode` — all
# contradicting the contract in ADR-074 (§Interface contracts, the worked
# example). Key-presence alone cannot catch that, and a consumer cannot parse
# "2 behind, 0 ahead" or learn a file's status from a bare filename.
if printf '%s' "$HG1" | jq -e '
      (.upstream | type == "object" and has("tracking") and has("ahead") and has("behind"))
   and (.uncommitted | type == "array")
   and (.untracked  | type == "array")
   and (.commits    | type == "array")
   and (.team       | has("available"))
  ' >/dev/null 2>&1; then
  pass "HG1b: upstream is an object with tracking/ahead/behind, per ADR-074's contract"
else
  fail "HG1b: shape drift from ADR-074: $(printf '%s' "$HG1" | jq -c '{upstream}')"
fi
RHG_DIRTY="$(new_repo handoff-gather-shapes)"
echo "changed" >> "$RHG_DIRTY/README.md"
HG1C="$(run_scl "$HHG" "$RHG_DIRTY" handoff-gather)"
if printf '%s' "$HG1C" | jq -e '
    .uncommitted | length > 0 and (all(.[]; has("status") and has("path")))
  ' >/dev/null 2>&1; then
  pass "HG1b: uncommitted[] entries are {status,path} objects, not bare filenames"
else
  fail "HG1b: uncommitted shape wrong: $(printf '%s' "$HG1C" | jq -c '.uncommitted')"
fi
if printf '%s' "$HG1" | jq -e '
    .team.available == false or (.team | has("session_start") and has("in_play") and has("domain_mode"))
  ' >/dev/null 2>&1; then
  pass "HG1b: team carries session_start/in_play/domain_mode when available"
else
  fail "HG1b: team shape drift: $(printf '%s' "$HG1" | jq -c '.team | keys')"
fi

# HG7 (D4 proof): planted session logs in BOTH locations must not reach stdout.
mkdir -p "$RHG/.claude/session-logs"
cat > "$RHG/.claude/session-log.json" <<'EOF'
{"tests":{"status":"pass","passed":41},"summary_3_sentences":"LEAKED-SUMMARY-LEGACY","local_only_paths":["LEAKED-PATH-LEGACY"],"dispositions":[{"path":"LEAKED-DISP-LEGACY"}]}
EOF
cat > "$RHG/.claude/session-logs/PLANT.json" <<'EOF'
{"tests":{"status":"fail","passed":7},"summary_3_sentences":"LEAKED-SUMMARY-PERSESSION","local_only_paths":["LEAKED-PATH-PERSESSION"],"dispositions":[{"path":"LEAKED-DISP-PERSESSION"}]}
EOF
HG7="$(run_scl "$HHG" "$RHG" handoff-gather)"
HG7_LEAK=""
for needle in LEAKED-SUMMARY-LEGACY LEAKED-PATH-LEGACY LEAKED-DISP-LEGACY \
              LEAKED-SUMMARY-PERSESSION LEAKED-PATH-PERSESSION LEAKED-DISP-PERSESSION \
              summary_3_sentences local_only_paths dispositions; do
  printf '%s' "$HG7" | grep -q "$needle" && HG7_LEAK="$HG7_LEAK $needle"
done
if [[ -z "$HG7_LEAK" ]]; then
  pass "HG7 (D4): handoff-gather reads no session log — nothing from either location reaches stdout"
else
  fail "HG7: gather leaked session-log data:$HG7_LEAK"
fi

# HG8 (structural): the function body must not mention the log at all.
HG8_BODY="$(awk '/^cmd_handoff_gather\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SCL")"
HG8_BAD=""
for needle in 'session-log' 'session-logs' 'closed_at' '7200'; do
  printf '%s' "$HG8_BODY" | grep -q -- "$needle" && HG8_BAD="$HG8_BAD $needle"
done
if [[ -z "$HG8_BAD" ]]; then
  pass "HG8: cmd_handoff_gather's body contains no session-log/freshness machinery"
else
  fail "HG8: cmd_handoff_gather still references:$HG8_BAD"
fi

# HG9 (D17): gather must NOT invoke improvement-queue.sh at all.
HG9_BODY="$HG8_BODY"
if printf '%s' "$HG9_BODY" | grep -qE 'improvement-queue\.sh.*(list|show)|bash "\$iq"'; then
  fail "HG9 (D17): cmd_handoff_gather invokes improvement-queue.sh — queue prose must never reach the composing model"
else
  pass "HG9 (D17): cmd_handoff_gather reports availability only, never runs the queue"
fi
if printf '%s' "$HG7" | jq -e '.improvement_queue | has("available") and (keys | length == 1)' >/dev/null 2>&1; then
  pass "HG9: improvement_queue is exactly {available}"
else
  fail "HG9: improvement_queue shape wrong: $(printf '%s' "$HG7" | jq -c '.improvement_queue')"
fi

# HG11 / HG12
run_scl "$HHG" "$RHG" handoff-gather --bogus >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "HG11: unknown argument -> exit 2" || fail "HG11: expected exit 2 for an unknown argument"
HG12_DIR="$TMP/not-a-repo"; mkdir -p "$HG12_DIR"
HG12="$(run_scl "$HHG" "$HG12_DIR" handoff-gather 2>/dev/null)"
HG12_RC=$?
HG12_MISSING=""
for k in $HG_KEYS; do
  printf '%s' "$HG12" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1 || HG12_MISSING="$HG12_MISSING $k"
done
if [[ $HG12_RC -eq 0 && -z "$HG12_MISSING" ]]; then
  pass "HG12: not a git repository -> exit 0 with every key still present"
else
  fail "HG12: rc=$HG12_RC missing:$HG12_MISSING"
fi

# HG15 (ADR-074 D14 item 4, REWRITTEN for ADR-075 D13): the shadow copy now
# surfaces via the manifest classifier, not a line count.
#
# The original assertion counted lines: >12 meant "stale". That could not tell
# an older stack version from a file someone deliberately edited, and knew only
# about `handoff`. The classifier hashes the file against every version the
# stack ever published, so the two cases get different messages — and showing
# the wrong one is exactly what the distinction exists to prevent.
mkdir -p "$RHG/.claude/skills/handoff"
# The refresher copies FROM the installed skill, so the fake HOME must hold a
# current one — otherwise every case correctly refuses as `source-missing`.
mkdir -p "$HHG/.claude/skills/handoff"
cp "$REPO_ROOT/skills/handoff/SKILL.md" "$HHG/.claude/skills/handoff/SKILL.md" 2>/dev/null || true

# (a) bytes the stack never published -> "someone edited this"; hands off.
for i in $(seq 1 230); do echo "line $i"; done > "$RHG/.claude/skills/handoff/SKILL.md"
HG15="$(run_scl "$HHG" "$RHG" handoff-gather)"
if printf '%s' "$HG15" | jq -e '.degraded | map(select(test("someone edited .*skills/handoff"))) | length == 1' >/dev/null 2>&1; then
  pass "HG15: a hand-written project-local copy is reported as edited, never rewritten"
else
  fail "HG15: hand-edited copy not reported: $(printf '%s' "$HG15" | jq -c '.degraded')"
fi

# (b) a genuine older published version -> "stale"; it self-heals.
# The copy must be COMMITTED: the refresher only ever rewrites tracked, clean
# files, so an uncommitted copy is correctly refused as `untracked` instead.
if git -C "$REPO_ROOT" show 99805b4~1:skills/handoff/SKILL.md > "$RHG/.claude/skills/handoff/SKILL.md" 2>/dev/null; then
  git -C "$RHG" add .claude/skills/handoff/SKILL.md >/dev/null 2>&1
  git -C "$RHG" -c user.email=t@t.t -c user.name=t commit -qm "add stale skill copy" >/dev/null 2>&1
  HG15B="$(run_scl "$HHG" "$RHG" handoff-gather)"
  if printf '%s' "$HG15B" | jq -e '.degraded | map(select(test("older stack version of .*skills/handoff"))) | length == 1' >/dev/null 2>&1; then
    pass "HG15: a genuine older stack version is reported as stale"
  elif printf '%s' "$HG15B" | jq -e '.degraded | map(select(index("skills/handoff") and index("(ci)"))) | length == 1' >/dev/null 2>&1; then
    # The portable-core refresher declines to act under CI by design
    # (ADR-075: `ci` and `remote` are expected block reasons, never
    # surfaced as warnings). With refresh declined the copy is reported as
    # BLOCKED rather than classified stale, so this case cannot run here at
    # all -- and the block reason is read off the output rather than
    # assumed, the same way the browser suites probe chromium instead of
    # guessing. Skipping is honest; passing would claim a classification
    # nothing performed.
    skip "HG15: a genuine older stack version is reported as stale — the refresher declines to act under CI (block reason: ci), so no classification happens here"
  else
    fail "HG15: real stale copy not classified: $(printf '%s' "$HG15B" | jq -c '.degraded')"
  fi
else
  skip "HG15: pre-fold blob unavailable in this clone"
fi

# (c) the current version -> nothing to say at all.
if [[ -f "$REPO_ROOT/skills/handoff/SKILL.md" ]]; then
  cp "$REPO_ROOT/skills/handoff/SKILL.md" "$RHG/.claude/skills/handoff/SKILL.md"
  HG15C="$(run_scl "$HHG" "$RHG" handoff-gather)"
  if printf '%s' "$HG15C" | jq -e '.degraded | map(select(test("skills/handoff"))) | length == 0' >/dev/null 2>&1; then
    pass "HG15: an up-to-date copy produces no degraded entry"
  else
    fail "HG15: false positive on a current copy: $(printf '%s' "$HG15C" | jq -c '.degraded')"
  fi
fi
rm -rf "$RHG/.claude/skills"

# ---------------------------------------------------------------- handoff-write
# Fixture: a real repo with a real local bare origin. No network, ever.
new_pushable() {  # new_pushable <name> -> echoes repo root; origin is a local bare repo
  local n="$1" r b
  r="$(new_repo "$n")"
  b="$TMP/bare-$n.git"
  git init -q --bare "$b"
  git -C "$r" remote add origin "$b"
  git -C "$r" push -q origin HEAD:main >/dev/null 2>&1
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
  printf '%s' "$r"
}

mkbody() {  # mkbody <path> — a minimal handoff body with the D6 anchor heading
  cat > "$1" <<'EOF'
# Next-session handoff

## Branch & state
- Branch: `main`

## Gotchas
- none
EOF
}

RHW="$(new_pushable handoff-write)"
BODY="$TMP/body.md"; mkbody "$BODY"
HHW="$TMP/home-hw"; mkdir -p "$HHW"

# HW1 — Path A happy
HW1="$(run_scl "$HHW" "$RHW" handoff-write --body-file "$BODY" 2>/dev/null)"
if printf '%s' "$HW1" | jq -e '.landing == "direct" and .committed == true and .push.verified == true' >/dev/null 2>&1; then
  pass "HW1: Path A on the default branch -> landing 'direct', push verified"
else
  fail "HW1: $(printf '%s' "$HW1" | jq -c '{landing,committed,push}')"
fi

# HW2 — explicit pathspec: unrelated dirty AND pre-staged files must not ride along
RHW2="$(new_pushable handoff-write-pathspec)"
echo "dirty" > "$RHW2/unrelated-dirty.txt"
echo "staged" > "$RHW2/unrelated-staged.txt"
git -C "$RHW2" add unrelated-staged.txt
mkbody "$TMP/body2.md"
run_scl "$HHW" "$RHW2" handoff-write --body-file "$TMP/body2.md" >/dev/null 2>&1
HW2_FILES="$(git -C "$RHW2" show --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' | sort | tr '\n' ' ')"
if [[ "$HW2_FILES" != *"unrelated-staged.txt"* && "$HW2_FILES" != *"unrelated-dirty.txt"* && "$HW2_FILES" == *"next_prompt.md"* ]]; then
  pass "HW2: the commit contains exactly the handoff files — no unrelated file rode along"
else
  fail "HW2: commit contained: $HW2_FILES"
fi
if git -C "$RHW2" diff --cached --name-only 2>/dev/null | grep -qx 'unrelated-staged.txt'; then
  pass "HW2: a file the user had pre-staged is STILL staged afterwards"
else
  fail "HW2: handoff-write disturbed the user's index"
fi

# HW2b (#187) — the close-out skill's own template must survive its own gate.
# It did not: the template's standard cost line said "token/cost breakdown",
# so every handoff written to the template was refused on a word the template
# itself supplied. The gate is deliberately blunt and stays that way, which
# makes it the template's job not to hand it a trigger. Every line of the
# template that ships as literal prose is checked here, not just this one.
RHW2B="$(new_pushable handoff-write-template)"
SKILL_FILE="$REPO_ROOT/skills/carbonight/SKILL.md"
if [[ -f "$SKILL_FILE" ]]; then
  # The template block is the fenced markdown skeleton in Step 10c. Take its
  # literal prose lines -- the ones a handoff copies verbatim.
  awk '/^# Next-session handoff/,/^## Today in one paragraph/' "$SKILL_FILE" > "$TMP/template-lines.md"
  if [[ -s "$TMP/template-lines.md" ]]; then
    printf '# Next-session handoff\n\n' > "$TMP/body-template.md"
    cat "$TMP/template-lines.md" >> "$TMP/body-template.md"
    HW2B="$(run_scl "$HHW" "$RHW2B" handoff-write --body-file "$TMP/body-template.md" 2>/dev/null)"
    if printf '%s' "$HW2B" | jq -e '.reason == "secrets"' >/dev/null 2>&1; then
      fail "HW2b: the template trips the credential gate it has to pass (#187)" "$HW2B"
    else
      pass "HW2b: the close-out template passes its own credential gate (#187)"
    fi
  else
    skip "HW2b: could not locate the template block in the skill"
  fi
else
  skip "HW2b: skills/carbonight/SKILL.md not present"
fi

# HW2c (#179) — a handoff written by anything other than handoff-write skips
# the credential scan and the local-only disclosure. scribe keeps Write for
# its own thread notes, so that rule cannot be enforced by capability. It can
# be made visible: every handoff this command writes carries a provenance
# line, and handoff-gather reports its absence at the next boot.
RHW2C="$(new_pushable handoff-provenance)"
mkbody "$TMP/body-prov.md"
run_scl "$HHW" "$RHW2C" handoff-write --body-file "$TMP/body-prov.md" --no-push >/dev/null 2>&1
if grep -qF '<!-- written by session-close.sh handoff-write -->' "$RHW2C/.claude/next_prompt.md" 2>/dev/null; then
  pass "HW2c: every handoff written by handoff-write carries the provenance line"
else
  fail "HW2c: the written handoff has no provenance line"
fi
GATHER_OK="$(run_scl "$HHW" "$RHW2C" handoff-gather 2>/dev/null)"
if printf '%s' "$GATHER_OK" | jq -e '[.degraded[] | select(test("not written by handoff-write"))] | length == 0' >/dev/null 2>&1; then
  pass "HW2c: a handoff we wrote is not reported as a bypass"
else
  fail "HW2c: our own handoff was flagged: $(printf '%s' "$GATHER_OK" | jq -c '.degraded')"
fi

# Now the bypass itself: someone writes the file directly, as scribe could.
printf '# Next-session handoff\n\nwritten by hand, no gates\n' > "$RHW2C/.claude/next_prompt.md"
GATHER_BYPASS="$(run_scl "$HHW" "$RHW2C" handoff-gather 2>/dev/null)"
if printf '%s' "$GATHER_BYPASS" | jq -e '[.degraded[] | select(test("not written by handoff-write"))] | length == 1' >/dev/null 2>&1; then
  pass "HW2c: a hand-written handoff is reported at the next boot (#179)"
else
  fail "HW2c: a bypass went unreported: $(printf '%s' "$GATHER_BYPASS" | jq -c '.degraded')"
fi

# HW3 / HW4 — secrets, and never printing the matched text
RHW3="$(new_pushable handoff-write-secrets)"
# Assembled at runtime, never written as a literal in this file: the mirror
# scrub guard (scripts/lib/mirror-scrub.sh) rejects any tree containing a
# secret-value SHAPE, and a test fixture is still a shape. The value handed to
# handoff-write is genuinely secret-shaped; the repo just never stores it.
FAKE_KEY="sk-""ant-""abcdefghijklmnopqrst"
printf '# Next-session handoff\n\n## Branch & state\n- key: %s\n' "$FAKE_KEY" > "$TMP/body-secret.md"
HW3_ERR="$( { run_scl "$HHW" "$RHW3" handoff-write --body-file "$TMP/body-secret.md" >"$TMP/hw3.out"; } 2>&1 )"
HW3_OUT="$(cat "$TMP/hw3.out")"
if printf '%s' "$HW3_OUT" | jq -e '.status == "refused" and .reason == "secrets"' >/dev/null 2>&1; then
  pass "HW3: a secret in the body -> exit 1, status refused/secrets"
else
  fail "HW3: expected refusal, got: $HW3_OUT"
fi
if printf '%s%s' "$HW3_OUT" "$HW3_ERR" | grep -q "$FAKE_KEY"; then
  fail "HW3: the matched secret was printed — refusal messages must carry {file,line} only"
else
  pass "HW3: the matched secret text appears in neither stdout nor stderr"
fi
if [[ ! -f "$RHW3/.claude/next_prompt.md" ]]; then
  pass "HW3: nothing was written on refusal"
else
  fail "HW3: a refusal still wrote next_prompt.md"
fi
mkbody "$TMP/body-clean.md"
mkdir -p "$RHW3/.claude/tracks"
printf 'token: ghp_%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$RHW3/.claude/tracks/t.md"
HW4="$(run_scl "$HHW" "$RHW3" handoff-write --body-file "$TMP/body-clean.md" --track ".claude/tracks/t.md" 2>/dev/null)"
if printf '%s' "$HW4" | jq -e '.status == "refused" and .reason == "secrets"' >/dev/null 2>&1; then
  pass "HW4: a secret in the --track file refuses just as the body does"
else
  fail "HW4: expected a track-file refusal, got: $HW4"
fi

# HW5a-d — D6, the generated local-only disclosure
RHW5="$(new_pushable handoff-write-d5a)"
mkbody "$TMP/body5.md"
run_scl "$HHW" "$RHW5" handoff-write --body-file "$TMP/body5.md" \
  --local-only-path "notes with space.txt" --local-only-path "b.txt" >/dev/null 2>&1
HW5_NP="$RHW5/.claude/next_prompt.md"
HW5_ANCHOR="$(grep -n '^## Branch & state' "$HW5_NP" | cut -d: -f1)"
HW5_BLOCK="$(grep -n 'Local-only work:' "$HW5_NP" | cut -d: -f1)"
if [[ -n "$HW5_ANCHOR" && -n "$HW5_BLOCK" ]] && (( HW5_BLOCK == HW5_ANCHOR + 1 )); then
  pass "HW5a: the disclosure is inserted immediately after '## Branch & state'"
else
  fail "HW5a: anchor at line $HW5_ANCHOR, block at line $HW5_BLOCK"
fi
if grep -q 'notes with space.txt' "$HW5_NP" && grep -q -- '- b.txt' "$HW5_NP"; then
  pass "HW5a: both paths appear verbatim, including one containing a space"
else
  fail "HW5a: paths missing from the generated block"
fi
RHW5B="$(new_pushable handoff-write-d5a-noanchor)"
printf '# Next-session handoff\n\n## Gotchas\n- none\n' > "$TMP/body5b.md"
run_scl "$HHW" "$RHW5B" handoff-write --body-file "$TMP/body5b.md" --local-only-path "z.txt" >/dev/null 2>&1
if grep -q '^## Local-only work' "$RHW5B/.claude/next_prompt.md"; then
  pass "HW5b: with no anchor heading the block is appended as its own section"
else
  fail "HW5b: no '## Local-only work' section was appended"
fi
RHW5C="$(new_pushable handoff-write-d5a-dup)"
printf '# H\n\n## Branch & state\nLocal-only work: 1 file\n' > "$TMP/body5c.md"
HW5C="$(run_scl "$HHW" "$RHW5C" handoff-write --body-file "$TMP/body5c.md" --local-only-path "z.txt" 2>/dev/null)"
if printf '%s' "$HW5C" | jq -e '.reason == "d5a-duplicate-disclosure"' >/dev/null 2>&1; then
  pass "HW5c: a body that already carries the disclosure is refused, not doubled"
else
  fail "HW5c: expected d5a-duplicate-disclosure, got: $HW5C"
fi
RHW5D="$(new_pushable handoff-write-d5a-none)"
mkbody "$TMP/body5d.md"
run_scl "$HHW" "$RHW5D" handoff-write --body-file "$TMP/body5d.md" >/dev/null 2>&1
if ! grep -q 'Local-only work' "$RHW5D/.claude/next_prompt.md"; then
  pass "HW5d: no --local-only-path -> no disclosure block anywhere"
else
  fail "HW5d: a disclosure block appeared with no paths given"
fi

# HW15 — a body carrying its own queue section is refused
RHW15="$(new_pushable handoff-write-queue-in-body)"
printf '# H\n\n## Branch & state\n- x\n\n## Improvement queue\nstuff\n' > "$TMP/body15.md"
HW15="$(run_scl "$HHW" "$RHW15" handoff-write --body-file "$TMP/body15.md" 2>/dev/null)"
if printf '%s' "$HW15" | jq -e '.reason == "queue-section-in-body"' >/dev/null 2>&1; then
  pass "HW15: a body that already carries '## Improvement queue' is refused"
else
  fail "HW15: expected queue-section-in-body, got: $HW15"
fi

# HW10 — usage errors, and no mutation on them
RHW10="$(new_pushable handoff-write-usage)"
HW10_HEAD_BEFORE="$(git -C "$RHW10" rev-parse HEAD)"
run_scl "$HHW" "$RHW10" handoff-write >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "HW10: missing --body-file -> exit 2" || fail "HW10: expected exit 2 for a missing --body-file"
mkbody "$TMP/body10.md"
run_scl "$HHW" "$RHW10" handoff-write --body-file "$TMP/body10.md" --track "../escape.md" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "HW10: --track with '..' -> exit 2" || fail "HW10: a '..' track path was accepted"
if [[ "$(git -C "$RHW10" rev-parse HEAD)" == "$HW10_HEAD_BEFORE" ]]; then
  pass "HW10: HEAD is provably unchanged after both usage errors"
else
  fail "HW10: a usage error still moved HEAD"
fi

# HW8 — no remote
RHW8="$(new_repo handoff-write-noremote)"
mkbody "$TMP/body8.md"
HW8="$(run_scl "$HHW" "$RHW8" handoff-write --body-file "$TMP/body8.md" 2>/dev/null)"
if printf '%s' "$HW8" | jq -e '.landing == "local-only"' >/dev/null 2>&1 && \
   ! printf '%s' "$HW8" | grep -q '"pushed"'; then
  pass "HW8: no remote -> landing 'local-only', and the word 'pushed' never appears"
else
  fail "HW8: $(printf '%s' "$HW8" | jq -c '{landing,push}')"
fi

# HW23 (D16) — --no-push commits locally and never pushes
RHW23="$(new_pushable handoff-write-nopush)"
git -C "$RHW23" checkout -q -b feature/x
mkbody "$TMP/body23.md"
HW23="$(run_scl "$HHW" "$RHW23" handoff-write --body-file "$TMP/body23.md" --no-push 2>/dev/null)"
if printf '%s' "$HW23" | jq -e '.committed == true and .landing == "local-only" and .push == null and .reason == "--no-push"' >/dev/null 2>&1; then
  pass "HW23 (D16): --no-push commits on the current branch, pushes nothing, emits no push object"
else
  fail "HW23: $(printf '%s' "$HW23" | jq -c '{committed,landing,push,reason}')"
fi
if ! git -C "$RHW23" ls-remote --heads origin 2>/dev/null | grep -q 'chore/handoff'; then
  pass "HW23: --no-push created no PR branch on the remote"
else
  fail "HW23: --no-push still pushed a handoff branch"
fi

# HW7 (round-1 B1 regression) — a GENUINELY CONFLICTING uncommitted file.
# Merely dirty is not enough: a plain dirty file survives even the broken
# checkout-based design, so this fixture makes README.md differ on
# origin/main AND be uncommitted locally, which is what a checkout aborts on.
RHW7="$(new_pushable handoff-write-conflict)"
git -C "$RHW7" checkout -q -b feature/conflict
( cd "$RHW7" && echo "origin side" > README.md && git add -A && git commit -qm "diverge origin" )
git -C "$RHW7" push -q origin HEAD:main >/dev/null 2>&1
git -C "$RHW7" reset -q --hard HEAD~1
echo "LOCAL UNCOMMITTED EDIT" > "$RHW7/README.md"
HW7_STATUS_BEFORE="$(git -C "$RHW7" status --porcelain -- README.md)"
HW7_HEAD_BEFORE="$(git -C "$RHW7" rev-parse HEAD)"
HW7_BRANCH_BEFORE="$(git -C "$RHW7" branch --show-current)"
mkbody "$TMP/body7.md"
if command -v gh >/dev/null 2>&1; then
  HW7="$(run_scl "$HHW" "$RHW7" handoff-write --body-file "$TMP/body7.md" 2>/dev/null)"
  HW7_LANDING="$(printf '%s' "$HW7" | jq -r '.landing')"
  if [[ "$HW7_LANDING" == "pr" || "$HW7_LANDING" == "local-only" ]]; then
    pass "HW7: a conflicting uncommitted file did not abort the run (landing=$HW7_LANDING)"
  else
    fail "HW7: unexpected landing '$HW7_LANDING'"
  fi
else
  skip "HW7: gh not installed — Path B landing not exercised"
fi
if [[ "$(git -C "$RHW7" status --porcelain -- README.md)" == "$HW7_STATUS_BEFORE" ]]; then
  pass "HW7: the conflicting uncommitted file is byte-identical before and after"
else
  fail "HW7: the uncommitted file was disturbed"
fi
if [[ "$(git -C "$RHW7" rev-parse HEAD)" == "$HW7_HEAD_BEFORE" && \
      "$(git -C "$RHW7" branch --show-current)" == "$HW7_BRANCH_BEFORE" ]]; then
  pass "HW7: HEAD and the current branch never moved in the primary worktree"
else
  fail "HW7: HEAD or branch moved — the primary worktree was checked out"
fi
if [[ "$(git -C "$RHW7" worktree list | wc -l | tr -d ' ')" == "1" ]]; then
  pass "HW7: exactly one worktree remains — the temporary one was cleaned up"
else
  fail "HW7: a worktree was left behind: $(git -C "$RHW7" worktree list)"
fi

# HW16 (round-2 Concern 3, extended) — push rejected, WITH --track.
RHW16="$(new_pushable handoff-write-rejected)"
BARE16="$TMP/bare-handoff-write-rejected.git"
# Reject pushes to the DEFAULT BRANCH ONLY — which is what branch protection
# actually does, and the scenario round-2 Concern 3 is about. A hook that
# rejected every ref would also reject Path B's own PR branch, so the run
# would fall through to a plain local commit and never exercise the
# fall-through this test exists to prove.
cat > "$BARE16/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r _old _new ref; do
  case "$ref" in refs/heads/main) exit 1 ;; esac
done
exit 0
EOF
chmod +x "$BARE16/hooks/pre-receive"
mkdir -p "$RHW16/.claude/tracks"
echo "# track" > "$RHW16/.claude/tracks/t.md"
git -C "$RHW16" add .claude/tracks/t.md >/dev/null 2>&1
git -C "$RHW16" commit -qm "add track" >/dev/null 2>&1
git -C "$RHW16" reset -q --soft HEAD~1
git -C "$RHW16" reset -q -- .claude/tracks/t.md
HW16_HEAD_BEFORE="$(git -C "$RHW16" rev-parse HEAD)"
mkbody "$TMP/body16.md"
HW16="$(run_scl "$HHW" "$RHW16" handoff-write --body-file "$TMP/body16.md" --track ".claude/tracks/t.md" 2>/dev/null)"
if printf '%s' "$HW16" | jq -e '.fell_through == "push-rejected" and .landing == "pr"' >/dev/null 2>&1; then
  pass "HW16: a push rejected by branch protection falls through to a PR branch"
else
  fail "HW16: expected fell_through=push-rejected and landing=pr, got: $(printf '%s' "$HW16" | jq -c '{landing,fell_through,status,reason}')"
fi
if [[ "$(git -C "$RHW16" rev-parse HEAD)" == "$HW16_HEAD_BEFORE" ]]; then
  pass "HW16: HEAD is back at its pre-call value after the soft reset"
else
  fail "HW16: HEAD did not return to its pre-call value"
fi
HW16_STAGED="$(git -C "$RHW16" diff --cached --name-only 2>/dev/null)"
if ! printf '%s' "$HW16_STAGED" | grep -qE 'next_prompt\.md|docs/handoffs/|tracks/t\.md'; then
  pass "HW16: the scoped unstage covered all three paths — the track file is not left staged"
else
  fail "HW16: still staged after fall-through: $HW16_STAGED"
fi

# HW24 / HW24b — worktree lifecycle. The live registration must survive.
RHW24="$(new_pushable handoff-write-prune)"
HW24_GITDIR="$(git -C "$RHW24" rev-parse --absolute-git-dir)"
STALE_WT="$TMP/wt-stale"; LIVE_WT="$TMP/wt-live"
git -C "$RHW24" worktree add -q -b wt-stale "$STALE_WT" >/dev/null 2>&1
git -C "$RHW24" worktree add -q -b wt-live "$LIVE_WT" >/dev/null 2>&1
rm -rf "$STALE_WT"
mkbody "$TMP/body24.md"
run_scl "$HHW" "$RHW24" handoff-write --body-file "$TMP/body24.md" >/dev/null 2>&1
if [[ ! -d "$HW24_GITDIR/worktrees/wt-stale" ]]; then
  pass "HW24: a stale worktree registration from a crashed run is pruned"
else
  fail "HW24: the stale registration survived"
fi
if [[ -d "$HW24_GITDIR/worktrees/wt-live" && -d "$LIVE_WT" ]]; then
  pass "HW24b: the LIVE worktree registration and its directory both survive the prune"
else
  fail "HW24b: prune removed a live worktree a concurrent session was using"
fi

# ---------------------------------------------------------------- handoff-redirect
RHR="$(new_repo handoff-redirect)"
HHR="$TMP/home-hr"
mk_carbonight() {  # mk_carbonight <dir> <good|stale>
  mkdir -p "$1/skills/carbonight"
  if [[ "$2" == "good" ]]; then
    printf 'Step 10b: session-close.sh handoff-write --body-file ...\n' > "$1/skills/carbonight/SKILL.md"
  else
    printf 'Step 10: call /handoff\n' > "$1/skills/carbonight/SKILL.md"
  fi
}
mkdir -p "$HHR/.claude"
mk_carbonight "$HHR/.claude" good
HR1="$(run_scl "$HHR" "$RHR" handoff-redirect 2>/dev/null)"; HR1_RC=$?
if [[ $HR1_RC -eq 0 && "$HR1" == *"/carbonight"* ]]; then
  pass "HR1: every resident copy is current -> exit 0, names /carbonight"
else
  fail "HR1: rc=$HR1_RC out='$HR1'"
fi

# HR2 — project-local copy stale, global good. NO onward pointer.
mkdir -p "$RHR/.claude"
mk_carbonight "$RHR/.claude" stale
HR2_OUT="$(run_scl "$HHR" "$RHR" handoff-redirect 2>/dev/null)"; HR2_RC=$?
HR2_ERR="$( { run_scl "$HHR" "$RHR" handoff-redirect >/dev/null; } 2>&1 )"
if [[ $HR2_RC -eq 1 ]] && [[ "$HR2_OUT$HR2_ERR" != *"/carbonight"* ]]; then
  pass "HR2: a stale project-local copy -> exit 1 and NO /carbonight pointer (the cycle edge is not emitted)"
else
  fail "HR2: rc=$HR2_RC, output still names a close-out command: '$HR2_OUT$HR2_ERR'"
fi
rm -rf "$RHR/.claude/skills"

# HR3 — no copy at all
HR3_EMPTY="$TMP/home-hr-empty"; mkdir -p "$HR3_EMPTY/.claude"
HR3_OUT="$(run_scl "$HR3_EMPTY" "$RHR" handoff-redirect 2>/dev/null)"; HR3_RC=$?
[[ $HR3_RC -eq 1 && "$HR3_OUT" != *"/carbonight"* ]] && \
  pass "HR3: no resident copy -> exit 1, no pointer" || fail "HR3: rc=$HR3_RC out='$HR3_OUT'"

# HR4 (round-2 Blocker 2b) — TWO invocations must BOTH succeed.
HR4_HOME="$TMP/home-hr4"; mkdir -p "$HR4_HOME/.claude"; mk_carbonight "$HR4_HOME/.claude" good
HR4_A="$( cd "$RHR" && HOME="$HR4_HOME" CLAUDE_CODE_SESSION_ID=S1 bash "$SCL" handoff-redirect 2>/dev/null )"; HR4_ARC=$?
HR4_B="$( cd "$RHR" && HOME="$HR4_HOME" CLAUDE_CODE_SESSION_ID=S1 bash "$SCL" handoff-redirect 2>/dev/null )"; HR4_BRC=$?
if [[ $HR4_ARC -eq 0 && $HR4_BRC -eq 0 && "$HR4_A" == *"/carbonight"* && "$HR4_B" == *"/carbonight"* ]]; then
  pass "HR4: typing /handoff twice inside 5 minutes is NOT punished — both emit the pointer"
else
  fail "HR4: second invocation was blocked (rc $HR4_ARC/$HR4_BRC)"
fi

# HR7 — the third trips, names install.sh, and names no close-out command
HR7_OUT="$( cd "$RHR" && HOME="$HR4_HOME" CLAUDE_CODE_SESSION_ID=S1 bash "$SCL" handoff-redirect 2>/dev/null )"; HR7_RC=$?
HR7_ERR="$( cd "$RHR" && HOME="$HR4_HOME" CLAUDE_CODE_SESSION_ID=S1 bash "$SCL" handoff-redirect 2>&1 >/dev/null )"
if [[ $HR7_RC -eq 1 && "$HR7_ERR" == *"install.sh"* && "$HR7_ERR" != *"/carbonight"* ]]; then
  pass "HR7: the third redirect in 5 minutes trips, names install.sh, and names nothing runnable"
else
  fail "HR7: rc=$HR7_RC err='$HR7_ERR'"
fi

# HR8 — concurrency: one session tripping must not affect another
HR8_HOME="$TMP/home-hr8"; mkdir -p "$HR8_HOME/.claude"; mk_carbonight "$HR8_HOME/.claude" good
for n in 1 2 3; do
  ( cd "$RHR" && HOME="$HR8_HOME" CLAUDE_CODE_SESSION_ID=SESSX bash "$SCL" handoff-redirect >/dev/null 2>&1 )
done
HR8_Y="$( cd "$RHR" && HOME="$HR8_HOME" CLAUDE_CODE_SESSION_ID=SESSY bash "$SCL" handoff-redirect 2>/dev/null )"; HR8_YRC=$?
if [[ $HR8_YRC -eq 0 && "$HR8_Y" == *"/carbonight"* ]]; then
  pass "HR8: session X tripping its counter leaves session Y unaffected"
else
  fail "HR8: a different session was blocked by X's counter (rc=$HR8_YRC)"
fi

# HR12 (round-3 Nit 7) — out-of-window entries are pruned; an empty file is deleted
HR12_HOME="$TMP/home-hr12"; mkdir -p "$HR12_HOME/.claude"; mk_carbonight "$HR12_HOME/.claude" good
HR12_DIR="$HR12_HOME/.claude/state/handoff-redirect"; mkdir -p "$HR12_DIR"
HR12_SLUG="$(printf '%s' "$RHR" | tr -c 'A-Za-z0-9._-' '_')"
HR12_FILE="$HR12_DIR/${HR12_SLUG}__S12.json"
echo '[1,2,3,4,5]' > "$HR12_FILE"
( cd "$RHR" && HOME="$HR12_HOME" CLAUDE_CODE_SESSION_ID=S12 bash "$SCL" handoff-redirect >/dev/null 2>&1 )
if [[ -f "$HR12_FILE" ]] && [[ "$(jq -r 'length' "$HR12_FILE" 2>/dev/null)" == "1" ]]; then
  pass "HR12: stale timestamps are pruned on write — only the in-window entry remains"
else
  fail "HR12: counter file holds $(cat "$HR12_FILE" 2>/dev/null)"
fi

# HR11 — the counter file is the only write
HR11_BEFORE="$(git -C "$RHR" status --porcelain | sort)"
( cd "$RHR" && HOME="$HR8_HOME" CLAUDE_CODE_SESSION_ID=SESSZ bash "$SCL" handoff-redirect >/dev/null 2>&1 )
if [[ "$(git -C "$RHR" status --porcelain | sort)" == "$HR11_BEFORE" ]]; then
  pass "HR11: handoff-redirect leaves the repo byte-identical"
else
  fail "HR11: handoff-redirect mutated the repo"
fi

echo "test-session-close: $PASS passed, $FAIL failed, $SKIPPED skipped"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
