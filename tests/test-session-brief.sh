#!/usr/bin/env bash
# Tests for scripts/session-brief.sh (ADR-072, Stage 2 of
# docs/plans/2026-08-11-session-bookends-design.md).
#
# Stage 2 only: banner, since, cost, alerts, todos, all. `queue` (W4/G1) and
# `running` (G2) are NOT implemented — they are Stages 4 and 3 respectively
# — so there is nothing to test for them here.
#
# Real throwaway git repos + a fake $HOME + a curated PATH (never the real
# `gh`/`jq`, so real network/tool state can never leak in — same discipline
# as tests/test-carbonet-check.sh).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$REPO_ROOT/scripts/session-brief.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-brief-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"
for t in jq bash git date mktemp grep sed tr wc basename dirname cat mkdir rm ls \
         head tail sort uniq cut awk expr true false env printf python3 kill sleep timeout; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$REALBIN/$t"
done

new_repo() {  # new_repo <name> -> real repo root
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" )
  git -C "$r" rev-parse --show-toplevel
}

run_sb() {  # run_sb <home> <path-prefix> <args...>
  local home="$1" pathprefix="$2"; shift 2
  HOME="$home" PATH="$pathprefix:$REALBIN" bash "$SB" "$@"
}

# ------------------------------------------------------------------- banner
R1="$(new_repo banner)"
H1="$TMP/home-banner"; mkdir -p "$H1"
OUT1="$(run_sb "$H1" "" banner --format box --repo "$R1")"
LINES1="$(printf '%s\n' "$OUT1" | wc -l | tr -d ' ')"
[[ "$LINES1" == "4" ]] && pass "banner --format box: 4 lines" || fail "banner --format box: expected 4 lines, got $LINES1"
MAXWIDTH="$(printf '%s\n' "$OUT1" | python3 -c "import sys; print(max(len(l.rstrip(chr(10))) for l in sys.stdin))")"
# Total line width = 2 (indent) + 48 (border incl corners) = 50 for the
# top/bottom border; content lines are 2 + 1 + 2 + <=46 + 1 = <=52. The
# "inner width" the design bounds is the content field itself (<=48
# between the two border chars) -- assert on that, not total line length.
INNER_OK=1
while IFS= read -r l; do
  case "$l" in
    *"│"*)
      inner="$(python3 -c "
s = '''$l'''
i = s.index('│'); j = s.rindex('│')
print(j - i - 1)
")"
      [[ "$inner" -le 48 ]] || INNER_OK=0
      ;;
  esac
done <<< "$OUT1"
[[ "$INNER_OK" == "1" ]] && pass "banner --format box: inner content width <=48" || fail "banner --format box: a content line exceeded 48 chars"

LONGBRANCH="feature/$(python3 -c "print('x'*200)")"
( cd "$R1" && git checkout -q -b "$LONGBRANCH" )
OUT1B="$(run_sb "$H1" "" banner --format box --repo "$R1")"
if printf '%s' "$OUT1B" | grep -q "…"; then
  pass "banner --format box: a 200-char branch is truncated with …"
else
  fail "banner --format box: long branch not truncated: $OUT1B"
fi

R2="$(new_repo banner-line)"
OUT2="$(run_sb "$TMP/home-bl" "" banner --format line --repo "$R2")"
if printf '%s' "$OUT2" | grep -q "banner-line" && printf '%s' "$OUT2" | grep -qi "main\|tier\|uninit"; then
  pass "banner --format line: 1 line with repo/branch and tier"
else
  fail "banner --format line: unexpected output: $OUT2"
fi
LINES2="$(printf '%s\n' "$OUT2" | wc -l | tr -d ' ')"
[[ "$LINES2" == "1" ]] && pass "banner --format line: exactly 1 line" || fail "banner --format line: expected 1 line, got $LINES2"

NOGIT="$TMP/notgit"; mkdir -p "$NOGIT"
OUT3="$(run_sb "$TMP/home-nogit" "" banner --format line --repo "$NOGIT")"
if printf '%s' "$OUT3" | grep -qE '^[A-Za-z]+ [A-Za-z]+ [0-9]+$'; then
  pass "banner --format line: not a git repo -> date line only"
else
  fail "banner --format line: expected a bare date line, got: $OUT3"
fi

# -------------------------------------------------------------------- since
# The "_Written:" cutoff must land strictly between the base commit and the
# 20 that follow. All fixture commits happen within the same test run
# (effectively the same wall-clock second), so a relative "-1 day" cutoff
# doesn't create a real boundary — capture the timestamp right after the
# base commit instead, with a 1-second gap enforced before continuing.
R4="$(new_repo since-many)"
CUTOFF4="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 1
for i in $(seq 1 20); do
  echo "line $i" >> "$R4/README.md"
  ( cd "$R4" && git commit -aqm "commit number $i" )
done
mkdir -p "$R4/.claude"
printf '# Next-session handoff\n\n_Written: %s_\n' "$CUTOFF4" > "$R4/.claude/next_prompt.md"
SINCE4="$(run_sb "$TMP/home-since" "" since --repo "$R4")"
CNT4="$(printf '%s' "$SINCE4" | jq -r '.commits | length')"
MORE4="$(printf '%s' "$SINCE4" | jq -r '.counts.more_commits')"
[[ "$CNT4" == "12" && "$MORE4" == "8" ]] && pass "since: 20 commits -> 12 shown + more_commits:8" \
  || fail "since: expected 12/8, got commits=$CNT4 more=$MORE4: $SINCE4"

R5="$(new_repo since-long-subject)"
LONGSUBJECT="$(python3 -c "print('x'*400)")"
( cd "$R5" && git commit -aqm "$LONGSUBJECT" --allow-empty )
mkdir -p "$R5/.claude"
printf '_Written: %s_\n' "$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" > "$R5/.claude/next_prompt.md"
SINCE5="$(run_sb "$TMP/home-since5" "" since --repo "$R5")"
SUBJLEN="$(printf '%s' "$SINCE5" | jq -r '.commits[0].subject | length')"
[[ "$SUBJLEN" == "120" ]] && pass "since: a 400-char subject truncated to 120" || fail "since: expected 120, got $SUBJLEN"

R6="$(new_repo since-none)"
SINCE6="$(run_sb "$TMP/home-since6" "" since --repo "$R6")"
SRC6="$(printf '%s' "$SINCE6" | jq -r '.last_session_end_source')"
[[ "$SRC6" == "none" ]] && pass "since: no resolvable end -> last_session_end_source none" || fail "since: expected none, got $SRC6: $SINCE6"

# ---------------------------------------------------------------------- cost
R7="$(new_repo cost)"
H7="$TMP/home-cost"; mkdir -p "$H7/.claude/logs" "$H7/.claude/config"
cat > "$H7/.claude/config/model-routing.json" <<'EOF'
{
  "providers": { "anthropic": { "models": {
    "test-model": { "pricing_per_million_input": 2.0, "pricing_per_million_output": 10.0 }
  } } },
  "model_fit": { "tier_ladder": ["test-model"] }
}
EOF
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$H7/.claude/logs/subagent-runs.jsonl" <<EOF
{"event":"main_turn","agent":"main","ts":"$NOW_TS","session_start":"$NOW_TS","project":"$R7","model":"test-model","in_tokens":100000,"out_tokens":100000}
EOF
mkdir -p "$H7/.claude/state"
printf '%s' "$NOW_TS" > "$H7/.claude/state/session-start.txt"
mkdir -p "$H7/.claude/state/session-markers"
COST7="$(run_sb "$H7" "" cost --repo "$R7")"
# 100000 in @ $2/M = 0.20 ; 100000 out @ $10/M = 1.00 ; total 1.20
if printf '%s' "$COST7" | grep -q '\$1\.20'; then
  pass "cost: numeric assertion against fixture rows and price table, to the cent"
else
  fail "cost: expected \$1.20, got: $COST7"
fi

# skip silently: log absent
COST8="$(run_sb "$TMP/home-cost8" "" cost --repo "$(new_repo cost-nolog)")"
[[ -z "$COST8" ]] && pass "cost: log absent -> empty" || fail "cost: expected empty, got: $COST8"

# skip silently: zero rows in window
H9="$TMP/home-cost9"; mkdir -p "$H9/.claude/logs" "$H9/.claude/config"
cp "$H7/.claude/config/model-routing.json" "$H9/.claude/config/model-routing.json"
R9="$(new_repo cost-zero)"
: > "$H9/.claude/logs/subagent-runs.jsonl"
COST9="$(run_sb "$H9" "" cost --repo "$R9")"
[[ -z "$COST9" ]] && pass "cost: zero rows in window -> empty" || fail "cost: expected empty, got: $COST9"

# skip silently: price table absent. LOOP_PRICE_TABLE must be forced to a
# nonexistent path -- otherwise loop_lib.sh's resolver falls back to this
# checkout's OWN real config/model-routing.json (repo-relative fallback),
# masking the "absent" case entirely.
H10="$TMP/home-cost10"; mkdir -p "$H10/.claude/logs"
R10="$(new_repo cost-nopricetable)"
cat > "$H10/.claude/logs/subagent-runs.jsonl" <<EOF
{"event":"main_turn","agent":"main","ts":"$NOW_TS","session_start":"$NOW_TS","project":"$R10","model":"test-model","in_tokens":1,"out_tokens":1}
EOF
mkdir -p "$H10/.claude/state"
printf '%s' "$NOW_TS" > "$H10/.claude/state/session-start.txt"
COST10="$(HOME="$H10" PATH="$REALBIN" LOOP_PRICE_TABLE="$TMP/nonexistent-model-routing.json" bash "$SB" cost --repo "$R10")"
[[ -z "$COST10" ]] && pass "cost: price table absent -> empty" || fail "cost: expected empty, got: $COST10"

# skip silently: model absent from the table
H11="$TMP/home-cost11"; mkdir -p "$H11/.claude/logs" "$H11/.claude/config"
cat > "$H11/.claude/config/model-routing.json" <<'EOF'
{"providers":{"anthropic":{"models":{}}},"model_fit":{"tier_ladder":[]}}
EOF
R11="$(new_repo cost-nomodel)"
cat > "$H11/.claude/logs/subagent-runs.jsonl" <<EOF
{"event":"main_turn","agent":"main","ts":"$NOW_TS","session_start":"$NOW_TS","project":"$R11","model":"unknown-model","in_tokens":1000,"out_tokens":1000}
EOF
mkdir -p "$H11/.claude/state"
printf '%s' "$NOW_TS" > "$H11/.claude/state/session-start.txt"
COST11="$(run_sb "$H11" "" cost --repo "$R11")"
[[ -z "$COST11" ]] && pass 'cost: model absent from the table -> empty (never a misleading \$0-shaped line)' \
  || fail "cost: expected empty, got: $COST11"

# --plain drops the number when confidence isn't exact
R12="$(new_repo cost-approx)"
H12="$TMP/home-cost12"; mkdir -p "$H12/.claude/logs" "$H12/.claude/config" "$H12/.claude/state"
cp "$H7/.claude/config/model-routing.json" "$H12/.claude/config/model-routing.json"
cat > "$H12/.claude/logs/subagent-runs.jsonl" <<EOF
{"event":"main_turn","agent":"main","ts":"$NOW_TS","session_start":"$NOW_TS","project":"$R12","model":"test-model","in_tokens":100000,"out_tokens":100000}
EOF
printf '%s' "$NOW_TS" > "$H12/.claude/state/session-start.txt"
COST12_TECH="$(run_sb "$H12" "" cost --repo "$R12")"
COST12_PLAIN="$(run_sb "$H12" "" cost --repo "$R12" --plain)"
if printf '%s' "$COST12_TECH" | grep -q "(approximate)"; then
  pass "cost: technical line gains (approximate) when confidence isn't exact"
else
  fail "cost: expected (approximate) in technical line: $COST12_TECH"
fi
[[ -z "$COST12_PLAIN" ]] && pass "cost --plain: drops the number entirely when confidence isn't exact" \
  || fail "cost --plain: expected empty, got: $COST12_PLAIN"

# ------------------------------------------------------------------- alerts
FAKEGH_DIR="$TMP/fakegh"; mkdir -p "$FAKEGH_DIR"
write_fake_gh() {
  cat > "$FAKEGH_DIR/gh" <<EOF
#!/usr/bin/env bash
echo '$1'
exit ${2:-0}
EOF
  chmod +x "$FAKEGH_DIR/gh"
}
R13="$(new_repo alerts)"
( cd "$R13" && git remote add origin "https://github.com/example/alerts.git" )

write_fake_gh "7"
ALERTS7="$(run_sb "$TMP/home-a7" "$FAKEGH_DIR" alerts --repo "$R13")"
[[ "$ALERTS7" == "Alerts: 7 open dependency alerts" ]] && pass "alerts: gh returns 7 -> Alerts: 7 …" \
  || fail "alerts: expected '7 open', got: $ALERTS7"

write_fake_gh "0"
ALERTS0="$(run_sb "$TMP/home-a0" "$FAKEGH_DIR" alerts --repo "$R13")"
[[ -z "$ALERTS0" ]] && pass "alerts: gh returns 0 -> empty" || fail "alerts: expected empty, got: $ALERTS0"

write_fake_gh "150"
ALERTS150="$(run_sb "$TMP/home-a150" "$FAKEGH_DIR" alerts --repo "$R13")"
[[ "$ALERTS150" == "Alerts: 100+ open dependency alerts" ]] && pass "alerts: 100+ caps at the page limit" \
  || fail "alerts: expected 100+, got: $ALERTS150"

write_fake_gh "not-a-number"
ALERTS_NAN="$(run_sb "$TMP/home-anan" "$FAKEGH_DIR" alerts --repo "$R13")"
[[ -z "$ALERTS_NAN" ]] && pass "alerts: non-numeric gh output -> empty" || fail "alerts: expected empty, got: $ALERTS_NAN"

ALERTS_NOGH="$(run_sb "$TMP/home-nogh" "" alerts --repo "$R13")"
[[ -z "$ALERTS_NOGH" ]] && pass "alerts: gh absent -> empty" || fail "alerts: expected empty, got: $ALERTS_NOGH"

cat > "$FAKEGH_DIR/gh" <<'EOF'
#!/usr/bin/env bash
sleep 20
echo "7"
EOF
chmod +x "$FAKEGH_DIR/gh"
START_A=$(date +%s)
ALERTS_HANG="$(HOME="$TMP/home-ahang" PATH="$FAKEGH_DIR:$REALBIN" bash "$SB" alerts --repo "$R13" --timeout 2)"
END_A=$(date +%s)
ELAPSED_A=$((END_A - START_A))
# Ceiling is the fake gh's sleep (20s), not timeout+slack — the claim under
# test is "the 2s timeout fired rather than waiting out the hang", and a
# tight bound around the timeout flakes on a loaded runner without proving
# anything extra.
[[ -z "$ALERTS_HANG" && "$ELAPSED_A" -lt 20 ]] && pass "alerts: a hanging gh -> empty before the 20s hang ends, i.e. the timeout fired (${ELAPSED_A}s)" \
  || fail "alerts: hang case wrong (elapsed=${ELAPSED_A}s, out='$ALERTS_HANG')"

# -------------------------------------------------------------------- todos
R14="$(new_repo todos)"
( cd "$R14" && printf 'a\nb\n' > f.txt && git add -A && git commit -qm "base" )
BASE_SHA="$(git -C "$R14" rev-parse HEAD)"
( cd "$R14" && printf '// TODO: one\n// TODO: two\n// FIXME: three\nnormal line\n' >> f.txt && git add -A && git commit -qm "add todos" )
mkdir -p "$R14/.claude"
cat > "$R14/.claude/session-log.json" <<EOF
{"head_sha_at_close":"$BASE_SHA"}
EOF
TODOS14="$(run_sb "$TMP/home-todos" "" todos --repo "$R14")"
[[ "$TODOS14" == "TODOs: 3 new since last session" ]] && pass "todos: 3 added TODO/FIXME lines -> TODOs: 3 new since last session" \
  || fail "todos: expected 3, got: $TODOS14"

R15="$(new_repo todos-nobase)"
TODOS15="$(run_sb "$TMP/home-todos15" "" todos --repo "$R15")"
[[ -z "$TODOS15" ]] && pass "todos: no base -> empty" || fail "todos: expected empty, got: $TODOS15"

R16="$(new_repo todos-zero)"
mkdir -p "$R16/.claude"
BASE16="$(git -C "$R16" rev-parse HEAD)"
cat > "$R16/.claude/session-log.json" <<EOF
{"head_sha_at_close":"$BASE16"}
EOF
TODOS16="$(run_sb "$TMP/home-todos16" "" todos --repo "$R16")"
[[ -z "$TODOS16" ]] && pass "todos: 0 new -> empty" || fail "todos: expected empty, got: $TODOS16"

R17="$(new_repo todos-cap)"
( cd "$R17" && : > f.txt && git add -A && git commit -qm "base" )
BASE17="$(git -C "$R17" rev-parse HEAD)"
python3 -c "
with open('$R17/f.txt','w') as f:
    for i in range(150):
        f.write('// TODO: item %d\n' % i)
"
( cd "$R17" && git add -A && git commit -qm "many todos" )
mkdir -p "$R17/.claude"
cat > "$R17/.claude/session-log.json" <<EOF
{"head_sha_at_close":"$BASE17"}
EOF
TODOS17="$(run_sb "$TMP/home-todos17" "" todos --repo "$R17")"
[[ "$TODOS17" == "TODOs: 99+ new since last session" ]] && pass "todos: 150 new -> capped at 99+" \
  || fail "todos: expected 99+, got: $TODOS17"

# ------------------------------------------------------------------------ all
R18="$(new_repo all-json)"
ALL18="$(run_sb "$TMP/home-all18" "" all --json --repo "$R18")"
if printf '%s' "$ALL18" | jq -e 'has("banner") and has("since") and has("cost") and has("alerts") and has("todos") and has("running")' >/dev/null 2>&1; then
  pass "all --json: valid JSON with every key present (Stage 2 + Stage 3's running) even when empty"
else
  fail "all --json: missing keys: $ALL18"
fi

# ---------------------------------------------------------------- running (G2)
# The load-bearing case: a doctored log claiming a loop is active must lose
# to whatever the loop-state file says NOW (finding 1).
R19="$(new_repo running-loops)"
H19="$TMP/home-running19"; mkdir -p "$H19/.claude/session-state"
mkdir -p "$R19/.claude"
cat > "$H19/.claude/session-state/loop-state.doctored.json" <<'EOF'
{"active":false,"loop_id":"adr072-smoke","status":"goal_met","iteration":7}
EOF
cat > "$R19/.claude/session-log.json" <<'EOF'
{"to_recheck":{"loop_ids":["adr072-smoke"],"pids":[],"rescue_branches":[],"overnight_item_ids":[]}}
EOF
RUN19="$(HOME="$H19" LOOP_STATE_DIR="$H19/.claude/session-state" bash "$SB" running --repo "$R19")"
if [[ "$RUN19" == "Running: 1 finished (goal_met)" ]]; then
  pass "running: log says nothing about status, but the doctored state file wins -> 1 finished (goal_met)"
else
  fail "running: expected '1 finished (goal_met)', got: $RUN19"
fi

# A genuinely still-active loop.
R20="$(new_repo running-active)"
H20="$TMP/home-running20"; mkdir -p "$H20/.claude/session-state"
mkdir -p "$R20/.claude"
cat > "$H20/.claude/session-state/loop-state.live.json" <<'EOF'
{"active":true,"loop_id":"still-going","status":"running","iteration":3}
EOF
cat > "$R20/.claude/session-log.json" <<'EOF'
{"to_recheck":{"loop_ids":["still-going"],"pids":[],"rescue_branches":[],"overnight_item_ids":[]}}
EOF
RUN20="$(HOME="$H20" LOOP_STATE_DIR="$H20/.claude/session-state" bash "$SB" running --repo "$R20")"
[[ "$RUN20" == "Running: 1 loop still going" ]] && pass "running: a genuinely active loop -> 1 loop still going" \
  || fail "running: expected '1 loop still going', got: $RUN20"

# A dead pid -> reported as finished, re-derived via kill -0 NOW.
R21="$(new_repo running-pid)"
H21="$TMP/home-running21"; mkdir -p "$H21/.claude/session-state"
mkdir -p "$R21/.claude"
cat > "$R21/.claude/session-log.json" <<'EOF'
{"to_recheck":{"loop_ids":[],"pids":[999999],"rescue_branches":[],"overnight_item_ids":[]}}
EOF
RUN21="$(HOME="$H21" LOOP_STATE_DIR="$H21/.claude/session-state" bash "$SB" running --repo "$R21")"
[[ "$RUN21" == "Running: 1 background process finished" ]] && pass "running: a dead pid re-derives as finished" \
  || fail "running: expected '1 background process finished', got: $RUN21"

# No log but a handoff's ## Running work section -> display-only, prefixed, unverified.
R22="$(new_repo running-handoff-fallback)"
mkdir -p "$R22/.claude"
printf '# Next-session handoff\n\n## Running work\n\n- Loop `x` still going\n- pid 123 alive\n\n## Gotchas\n- none\n' > "$R22/.claude/next_prompt.md"
RUN22="$(run_sb "$TMP/home-running22" "" running --repo "$R22")"
if [[ "$RUN22" == "Running (from last night's handoff, not verified): "* ]]; then
  pass "running: no log, handoff section present -> display-only, prefixed 'not verified'"
else
  fail "running: expected the handoff-fallback prefix, got: $RUN22"
fi

# Neither a log nor a handoff section -> empty, line omitted.
R23="$(new_repo running-neither)"
RUN23="$(run_sb "$TMP/home-running23" "" running --repo "$R23")"
[[ -z "$RUN23" ]] && pass "running: neither log nor handoff -> empty" || fail "running: expected empty, got: $RUN23"

# A rescue branch still open on the remote.
R24="$(new_repo running-rescue)"
BARE24="$TMP/bare-running-rescue.git"
git init -q --bare "$BARE24"
git -C "$R24" remote add origin "$BARE24"
git -C "$R24" push -q origin HEAD:main
git -C "$R24" checkout -q -b rescue/2026-01-01-0000-x
( cd "$R24" && echo y >> README.md && git add -A && git commit -qm "rescue commit" )
git -C "$R24" push -q origin rescue/2026-01-01-0000-x
git -C "$R24" checkout -q main
mkdir -p "$R24/.claude"
cat > "$R24/.claude/session-log.json" <<'EOF'
{"to_recheck":{"loop_ids":[],"pids":[],"rescue_branches":["rescue/2026-01-01-0000-x"],"overnight_item_ids":[]}}
EOF
RUN24="$(run_sb "$TMP/home-running24" "" running --repo "$R24")"
[[ "$RUN24" == "Running: 1 rescue branch open" ]] && pass "running: an open rescue branch -> 1 rescue branch open" \
  || fail "running: expected '1 rescue branch open', got: $RUN24"

# ADR-074 D5 / round-2 Concern 4 (display half of SI7). A rescue branch that
# belongs to an OLDER concurrent session must still be named at boot, and
# labelled so nobody reads it as this session's. Before D5 the newest document
# was the only one read, so this branch simply vanished from the boot screen.
R24B="$(new_repo running-rescue-crosssession)"
BARE24B="$TMP/bare-running-rescue-cross.git"
git init -q --bare "$BARE24B"
git -C "$R24B" remote add origin "$BARE24B"
git -C "$R24B" push -q origin HEAD:main
git -C "$R24B" checkout -q -b rescue/2026-01-01-0000-y
( cd "$R24B" && echo y >> README.md && git add -A && git commit -qm "rescue commit" )
git -C "$R24B" push -q origin rescue/2026-01-01-0000-y
git -C "$R24B" checkout -q main
mkdir -p "$R24B/.claude/session-logs"
cat > "$R24B/.claude/session-logs/OLDSESS.json" <<'EOF'
{"session_id":"OLDSESS","to_recheck":{"loop_ids":[],"pids":[],"rescue_branches":["rescue/2026-01-01-0000-y"],"overnight_item_ids":[]}}
EOF
sleep 1
cat > "$R24B/.claude/session-logs/NEWSESS.json" <<'EOF'
{"session_id":"NEWSESS","to_recheck":{"loop_ids":[],"pids":[],"rescue_branches":[],"overnight_item_ids":[]}}
EOF
RUN24B="$(run_sb "$TMP/home-running24b" "" running --repo "$R24B")"
if [[ "$RUN24B" == *"rescue branch open"* ]]; then
  pass "running: a rescue branch from a NON-newest session still surfaces at boot"
else
  fail "running: cross-session rescue branch was hidden by the newer log: '$RUN24B'"
fi
if [[ "$RUN24B" == *"(from another session)"* ]]; then
  pass "running: the cross-session entry is labelled '(from another session)'"
else
  fail "running: expected the '(from another session)' label, got: '$RUN24B'"
fi

# --json emits {"line": "..."} instead of a bare unlabelled flag (non-blocking
# review finding: --json was accepted and silently swallowed).
RUN24_JSON="$(run_sb "$TMP/home-running24json" "" running --repo "$R24" --json)"
[[ "$(printf '%s' "$RUN24_JSON" | jq -r '.line')" == "Running: 1 rescue branch open" ]] \
  && pass "running --json: emits {line: ...} matching the text output" \
  || fail "running --json: unexpected output: $RUN24_JSON"

# A doctored rescue-branch identifier that does NOT match this script's own
# rescue/<ts>-<slug> shape must never reach `ls-remote` as a ref pattern
# (the session log is untrusted -- a value like "*" could otherwise match
# arbitrary remote refs and produce a false positive).
R25="$(new_repo running-bad-branch-id)"
BARE25="$TMP/bare-running-bad-branch-id.git"
git init -q --bare "$BARE25"
git -C "$R25" remote add origin "$BARE25"
git -C "$R25" push -q origin HEAD:main
mkdir -p "$R25/.claude"
cat > "$R25/.claude/session-log.json" <<'EOF'
{"to_recheck":{"loop_ids":[],"pids":[],"rescue_branches":["*"],"overnight_item_ids":[]}}
EOF
RUN25="$(run_sb "$TMP/home-running25" "" running --repo "$R25")"
[[ -z "$RUN25" ]] && pass "running: a malformed rescue-branch identifier ('*') is rejected before it ever reaches ls-remote" \
  || fail "running: expected empty for a malformed branch id, got: $RUN25"

# --------------------------------------------------------- jq absent -> empty
NOJQ_BIN="$TMP/nojq"; mkdir -p "$NOJQ_BIN"
for t in bash git date grep sed tr wc basename dirname cat mkdir head tail sort awk python3 sleep kill; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$NOJQ_BIN/$t"
done
NOJQ_OUT="$(HOME="$TMP/home-nojq" PATH="$NOJQ_BIN" bash "$SB" since --repo "$R18" 2>&1)"
NOJQ_RC=$?
[[ "$NOJQ_RC" -eq 0 && -z "$NOJQ_OUT" ]] && pass "since: jq absent -> exit 0, empty output, never a partial line" \
  || fail "since: jq-absent case wrong (rc=$NOJQ_RC out='$NOJQ_OUT')"

echo "test-session-brief: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
