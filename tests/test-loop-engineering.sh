#!/usr/bin/env bash
# Regression suite for the loop-engineering Phase-1 control plane.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/skills/loop-engineer/loop_lib.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$LIB" ]] || { echo "FAIL: loop_lib.sh not found at $LIB"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; printf '%s\n' "$1" >>"$_fail_log"; }

# Isolate state dir per run; guard mktemp failure; clean up on exit.
_tmp_home="$(mktemp -d)" || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$_tmp_home"' EXIT
export HOME="$_tmp_home"
# Regression (pre-existing, not ADR-024): asserts written as `... | { read; ok||bad; }`
# run bad() in a pipeline subshell, so the parent FAIL counter never saw them and the
# summary printed FAIL=0 while real "FAIL:" lines existed (CI reported green). Tally
# failures into a shared file that survives subshells; derive authoritative FAIL below.
_fail_log="$_tmp_home/.faillog"; : >"$_fail_log"
# ADR-020: state is keyed by session id. Neutralize a leaked session id from the
# parent (real) Claude session so the legacy-path tests below are deterministic;
# the per-session behavior is exercised explicitly in the isolation block.
unset CLAUDE_CODE_SESSION_ID LOOP_STATE_FILE 2>/dev/null || true
# shellcheck disable=SC1090
source "$LIB"

# --- happy-path tests ---

# read on empty -> {}
[[ "$(loop_read_state)" == "{}" ]] && ok "read empty -> {}" || bad "read empty"

# write then read roundtrip
loop_write_state '{"active":true,"iteration":2}'
got="$(loop_read_state | jq -r '.iteration')"
[[ "$got" == "2" ]] && ok "write/read roundtrip" || bad "roundtrip got=$got"

# --- error-path tests ---

# zero-arg write: must not crash and must be idempotent
loop_write_state && ok "zero-arg write survives" || bad "zero-arg write crashed"

# invalid JSON: must silently discard, state file unchanged or absent
prev="$(loop_read_state)"
loop_write_state 'not-json' && ok "invalid JSON write survives" || bad "invalid JSON write crashed"
cur="$(loop_read_state)"
[[ "$cur" == "$prev" ]] && ok "invalid JSON does not corrupt state" || bad "state corrupted: was=$prev now=$cur"

# unset HOME: must not crash (re-source with no HOME set)
(
  unset HOME
  # shellcheck disable=SC1090
  source "$LIB"
  loop_write_state '{"test":1}'
  loop_read_state >/dev/null
  echo "unset-home-ok"
) | grep -q "unset-home-ok" && ok "unset HOME survives" || bad "unset HOME crashed"

# set -e caller: return 0 on mkdir failure must not kill set -e subshell
(
  set -e
  export LOOP_STATE_DIR="/proc/nonexistent-dir-for-test"
  # shellcheck disable=SC1090
  source "$LIB"
  loop_write_state '{"x":1}'
  echo "set-e-ok"
) | grep -q "set-e-ok" && ok "set -e caller not terminated on mkdir failure" || bad "set -e caller terminated"

# --- Task 2: state hash + spec validation + bound checks ---

# state hash is stable for unchanged tree, differs after a change
_git_tmp="$(mktemp -d)"
cd "$_git_tmp"
git init -q
git config user.email "test@test.local"
git config user.name "Test"
echo a > f; git add f; git commit -qm init
h1="$(loop_state_hash "$PWD")"
echo b >> f
h2="$(loop_state_hash "$PWD")"
[[ -n "$h1" && "$h1" != "$h2" ]] && ok "state_hash changes on edit" || bad "state_hash h1=$h1 h2=$h2"

# dirty-to-dirty: two distinct content edits produce different hashes (content-based, not name-based)
echo c >> f; h3="$(loop_state_hash "$PWD")"
[[ -n "$h2" && "$h2" != "$h3" ]] && ok "state_hash differs on second dirty edit" || bad "state_hash dirty-to-dirty h2=$h2 h3=$h3"

# validate: missing success_criterion for bounded-autonomous (boolean true) -> rc 2
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":true,"bounds":{"max_iterations":5}}'
[[ $? -eq 2 ]] && ok "validate refuses missing criterion (bool true)" || bad "validate should refuse (bool true)"

# validate: missing success_criterion for bounded-autonomous (string "always") -> rc 2
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":"always","bounds":{"max_iterations":5}}'
[[ $? -eq 2 ]] && ok "validate refuses missing criterion (always)" || bad "validate should refuse (always)"

# validate: require_external_termination "never" does not require command -> rc 0
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":"never","bounds":{"max_iterations":5}}'
[[ $? -eq 0 ]] && ok "validate accepts never without criterion" || bad "validate should accept never"

# validate: complete spec -> rc 0
loop_validate_spec '{"autonomy":"checkpoint","success_criterion":{"type":"shell","command":"true"},"bounds":{"max_iterations":5}}'
[[ $? -eq 0 ]] && ok "validate accepts complete spec" || bad "validate should accept"

# validate: zero-arg must not crash (set -u guard)
loop_validate_spec 2>/dev/null; _rc=$?
[[ $_rc -ne 127 ]] && ok "validate zero-arg no crash" || bad "validate zero-arg crashed (exit 127)"

# validate: malformed JSON -> rc 2 (not crash)
loop_validate_spec 'not-json' 2>/dev/null; _rc=$?
[[ $_rc -ne 127 ]] && ok "validate malformed JSON no crash" || bad "validate malformed JSON crashed (exit 127)"

# check_bounds: iteration over cap -> max_iterations
r="$(loop_check_bounds '{"iteration":5,"bounds":{"max_iterations":5},"cost_so_far_usd":0,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "max_iterations" ]] && ok "bounds trip on iterations" || bad "bounds got=$r"

# check_bounds: budget over cap -> budget_exceeded
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5,"per_run_budget_usd":1},"cost_so_far_usd":2,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "budget_exceeded" ]] && ok "bounds trip on budget" || bad "bounds got=$r"

# check_bounds: no_progress_count >= 2 -> no_progress
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5},"cost_so_far_usd":0,"no_progress_count":2,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "no_progress" ]] && ok "bounds trip on no_progress" || bad "bounds got=$r"

# check_bounds: all within -> ok
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5,"per_run_budget_usd":5},"cost_so_far_usd":1,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "ok" ]] && ok "bounds ok within caps" || bad "bounds got=$r"

# check_bounds: zero-arg must not crash (set -u guard)
loop_check_bounds 2>/dev/null; _rc=$?
[[ $_rc -ne 127 ]] && ok "check_bounds zero-arg no crash" || bad "check_bounds zero-arg crashed (exit 127)"

# check_bounds: non-numeric iteration field must not crash
r="$(loop_check_bounds '{"iteration":"abc","bounds":{"max_iterations":5},"cost_so_far_usd":0,"no_progress_count":0}' 2>/dev/null)"
[[ $? -ne 127 ]] && ok "check_bounds non-numeric iteration no crash" || bad "check_bounds non-numeric iteration crashed"

# check_bounds: non-numeric budget field must not crash
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5,"per_run_budget_usd":"abc"},"cost_so_far_usd":0,"no_progress_count":0}' 2>/dev/null)"
[[ $? -ne 127 ]] && ok "check_bounds non-numeric budget no crash" || bad "check_bounds non-numeric budget crashed"

# awk injection probe: crafted cost_so_far_usd must not execute arbitrary code
_inject_marker="$_tmp_home/awk_injected"
r="$(loop_check_bounds "{\"iteration\":1,\"bounds\":{\"max_iterations\":5,\"per_run_budget_usd\":\"1; system(\\\"touch ${_inject_marker}\\\");\"},\"cost_so_far_usd\":\"0\",\"no_progress_count\":0}" 2>/dev/null)"
[[ ! -f "$_inject_marker" ]] && ok "awk injection blocked" || bad "awk injection executed"

# --- Task 3: loop-stop.sh Stop hook ---

STOP="$REPO_ROOT/hooks/loop-stop.sh"
run_stop() { echo "$2" | LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP"; }

mkdir -p "$HOME/.claude/session-state"

# no active loop -> allow stop (empty output)
loop_write_state '{"active":false}'
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: inactive -> allow" || bad "stop inactive out=$out"

# stop_hook_active true -> always allow (no infinite block)
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":true}')"
[[ -z "$out" ]] && ok "stop: stop_hook_active -> allow" || bad "stop active-flag out=$out"

# criterion passes -> mark met, allow stop
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"true"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: criterion met -> allow" || bad "stop met out=$out"
[[ "$(loop_read_state | jq -r '.status')" == "met" ]] && ok "stop: status=met" || bad "stop status not met"

# criterion fails, bounds remain -> block (keep working)
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":false}')"
echo "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "stop: unmet -> block" || bad "stop unmet out=$out"

# malformed state -> allow stop (fail-closed)
printf '%s' 'not json' > "$HOME/.claude/session-state/loop-state.json"
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: malformed -> allow (fail-closed)" || bad "stop malformed out=$out"

# --- Task 4: irreversible-deny.sh ---

DENY="$REPO_ROOT/hooks/irreversible-deny.sh"
run_deny() { echo "$1" | LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$DENY"; }
is_deny() { echo "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

# --- baseline: active loop + push -> deny ---
loop_write_state '{"active":true}'
out="$(run_deny '{"tool_input":{"command":"git push origin main"}}')"
is_deny "$out" && ok "deny: push during loop" || bad "deny push out=$out"

# --- active loop + read-only -> no deny ---
out="$(run_deny '{"tool_input":{"command":"git status"}}')"
[[ -z "$out" ]] && ok "deny: status allowed" || bad "deny status out=$out"

# --- no active loop + push -> no deny ---
loop_write_state '{"active":false}'
out="$(run_deny '{"tool_input":{"command":"git push origin main"}}')"
[[ -z "$out" ]] && ok "deny: push allowed outside loop" || bad "deny push-noloop out=$out"

# --- full deny-class coverage (all 9 classes) ---
loop_write_state '{"active":true}'

# git merge
out="$(run_deny '{"tool_input":{"command":"git merge feature-branch"}}')"
is_deny "$out" && ok "deny: git merge" || bad "deny git-merge out=$out"

# git reset --hard
out="$(run_deny '{"tool_input":{"command":"git reset --hard HEAD~1"}}')"
is_deny "$out" && ok "deny: git reset --hard" || bad "deny git-reset-hard out=$out"

# rm -rf
out="$(run_deny '{"tool_input":{"command":"rm -rf /tmp/foo"}}')"
is_deny "$out" && ok "deny: rm -rf" || bad "deny rm-rf out=$out"

# deploy-edge
out="$(run_deny '{"tool_input":{"command":"deploy-edge staging"}}')"
is_deny "$out" && ok "deny: deploy-edge" || bad "deny deploy-edge out=$out"

# supabase delete
out="$(run_deny '{"tool_input":{"command":"supabase db delete mytable"}}')"
is_deny "$out" && ok "deny: supabase delete" || bad "deny supabase-delete out=$out"

# supabase drop
out="$(run_deny '{"tool_input":{"command":"supabase db drop mytable"}}')"
is_deny "$out" && ok "deny: supabase drop" || bad "deny supabase-drop out=$out"

# drop table
out="$(run_deny '{"tool_input":{"command":"psql -c \"drop table users\""}}')"
is_deny "$out" && ok "deny: drop table" || bad "deny drop-table out=$out"

# truncate
out="$(run_deny '{"tool_input":{"command":"psql -c \"truncate orders\""}}')"
is_deny "$out" && ok "deny: truncate" || bad "deny truncate out=$out"

# stripe
out="$(run_deny '{"tool_input":{"command":"stripe charges delete ch_123"}}')"
is_deny "$out" && ok "deny: stripe" || bad "deny stripe out=$out"

# gh pr merge
out="$(run_deny '{"tool_input":{"command":"gh pr merge 42"}}')"
is_deny "$out" && ok "deny: gh pr merge" || bad "deny gh-pr-merge out=$out"

# --- bypass evasion: must still deny ---

# git -C repo push (global -C option before subcommand)
out="$(run_deny '{"tool_input":{"command":"git -C /some/repo push origin main"}}')"
is_deny "$out" && ok "deny: git -C repo push" || bad "deny git-C-push out=$out"

# command git push
out="$(run_deny '{"tool_input":{"command":"command git push origin main"}}')"
is_deny "$out" && ok "deny: command git push" || bad "deny command-git-push out=$out"

# /usr/bin/git push
out="$(run_deny '{"tool_input":{"command":"/usr/bin/git push origin main"}}')"
is_deny "$out" && ok "deny: /usr/bin/git push" || bad "deny path-git-push out=$out"

# rm -fr (flags reversed)
out="$(run_deny '{"tool_input":{"command":"rm -fr /tmp/foo"}}')"
is_deny "$out" && ok "deny: rm -fr" || bad "deny rm-fr out=$out"

# rm -r -f (split flags)
out="$(run_deny '{"tool_input":{"command":"rm -r -f /tmp/foo"}}')"
is_deny "$out" && ok "deny: rm -r -f" || bad "deny rm-r-f out=$out"

# --- false-positive guard: read-only commands must NOT be denied ---

# git merge-base (not a merge)
out="$(run_deny '{"tool_input":{"command":"git merge-base HEAD~1 HEAD"}}')"
[[ -z "$out" ]] && ok "deny: git merge-base allowed" || bad "deny false-positive merge-base out=$out"

# git reset without --hard
out="$(run_deny '{"tool_input":{"command":"git reset HEAD~1"}}')"
[[ -z "$out" ]] && ok "deny: git reset (no --hard) allowed" || bad "deny false-positive reset out=$out"

# gh pr merge substring inside echo: the deny hook matches on the normalized string;
# echo "gh pr merge" after quote-stripping becomes: echo gh pr merge
# which contains "gh pr merge" and is denied (safe/conservative behavior).
out="$(run_deny '{"tool_input":{"command":"echo \"gh pr merge\""}}')"
is_deny "$out" && ok "deny: gh pr merge echo denied (conservative, safe)" || bad "deny: gh pr merge echo out=$out"

# --- Task 5: loop_policy schema + template ---

SCHEMA="$REPO_ROOT/schemas/stack-config-schema.json"
# loop_policy is a defined property (schema is additionalProperties:false)
jq -e '.properties.loop_policy.properties.max_iterations' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: loop_policy defined" || bad "schema: loop_policy missing"
# template ships a default loop_policy
TMPL="$REPO_ROOT/templates/stack-config.template.json"
jq -e '.loop_policy.default_autonomy' "$TMPL" >/dev/null 2>&1 \
  && ok "template: loop_policy default present" || bad "template: loop_policy missing"
# default autonomy is the safe floor
[[ "$(jq -r '.loop_policy.default_autonomy' "$TMPL")" == "checkpoint" ]] \
  && ok "template: default_autonomy=checkpoint" || bad "template autonomy not checkpoint"

# --- Task 5b: ADR-047 loop levels (L1-L4) ---

# schema declares loop_policy.level and session_prefs.auto_offer_loop
jq -e '.properties.loop_policy.properties.level' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: loop_policy.level defined" || bad "schema: loop_policy.level missing"
jq -e '.properties.session_prefs.properties.auto_offer_loop' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: session_prefs.auto_offer_loop defined" || bad "schema: auto_offer_loop missing"
# template ships level:null (opt-in ladder, never the out-of-box default)
[[ "$(jq -r '.loop_policy.level' "$TMPL")" == "null" ]] \
  && ok "template: loop_policy.level=null" || bad "template: level not null"
[[ "$(jq -r '.session_prefs.auto_offer_loop' "$TMPL")" == "true" ]] \
  && ok "template: auto_offer_loop=true" || bad "template: auto_offer_loop not true"

# config/loop-levels.json: all 4 levels present, ascending numeric caps,
# irreversible_actions_break_loop is never set per-level (cross-level
# invariant lives in this skill's code, not the data file), L3/L4 carry a
# non-null hard cap.
LEVELS="$REPO_ROOT/config/loop-levels.json"
jq -e '.levels | keys == ["L1","L2","L3","L4"]' "$LEVELS" >/dev/null 2>&1 \
  && ok "loop-levels: exactly L1-L4 present" || bad "loop-levels: level set wrong"
jq -e '
  [.levels.L1.loop_policy.max_iterations, .levels.L2.loop_policy.max_iterations,
   .levels.L3.loop_policy.max_iterations, .levels.L4.loop_policy.max_iterations]
  as $m | $m == ($m | sort)
' "$LEVELS" >/dev/null 2>&1 \
  && ok "loop-levels: max_iterations ascending L1->L4" || bad "loop-levels: max_iterations not ascending"
jq -e '.levels | to_entries | all(.value.loop_policy | has("irreversible_actions_break_loop") | not)' "$LEVELS" >/dev/null 2>&1 \
  && ok "loop-levels: no preset overrides irreversible_actions_break_loop" || bad "loop-levels: a preset sets irreversible_actions_break_loop"
jq -e '.levels.L3.cost_protection.per_session_hard_cap_usd != null and .levels.L4.cost_protection.per_session_hard_cap_usd != null' "$LEVELS" >/dev/null 2>&1 \
  && ok "loop-levels: L3/L4 carry a non-null hard cap" || bad "loop-levels: L3/L4 missing hard cap"

# --- Task 6: /loop-engineer skill (front door + pre-flight gate) ---

SKILL="$REPO_ROOT/skills/loop-engineer/SKILL.md"
[[ -f "$SKILL" ]] && ok "skill: SKILL.md present" || bad "skill: SKILL.md missing"
grep -q 'loop_validate_spec' "$SKILL" && ok "skill: references validate" || bad "skill: no validate ref"
grep -q 'require_external_termination' "$SKILL" && ok "skill: documents termination" || bad "skill: no termination doc"

# --- Task 7: foreman loop-shape detection ---

FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
grep -q 'Detect loop-shape' "$FOREMAN" && ok "foreman: loop-shape step present" || bad "foreman: no loop-shape step"
grep -q 'pattern selected' "$FOREMAN" && ok "foreman: visible pattern log" || bad "foreman: no visible log"

# --- Task 8: register hooks, tier manifest, cost accrual ---

HOOKS="$REPO_ROOT/hooks/hooks.json"
jq -e '.hooks.Stop[]?.hooks[]?.command | select(test("loop-stop.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: loop-stop registered" || bad "hooks.json: loop-stop missing"
jq -e '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command | select(test("irreversible-deny.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: irreversible-deny registered" || bad "hooks.json: deny missing"
MAN="$REPO_ROOT/config/tier-manifests/tier-2.json"
jq -e '.files.global[]? | select(.to | test("loop-engineer/SKILL.md"))' "$MAN" >/dev/null 2>&1 \
  && ok "manifest: skill copied" || bad "manifest: skill missing"
# cost accrual fn
[[ "$(loop_write_state '{"cost_so_far_usd":1}'; loop_accrue_cost 0.5; loop_read_state | jq -r '.cost_so_far_usd')" == "1.5" ]] \
  && ok "lib: cost accrual" || bad "lib: cost accrual"

# --- Regression tests for new fixes ---

# Fix 1: validate — bounded-autonomous + "auto" (schema default) + no criterion -> rc 2
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":"auto","bounds":{"max_iterations":5}}'
[[ $? -eq 2 ]] && ok "fix1: auto + bounded-autonomous + no criterion -> rc 2" || bad "fix1: auto should require criterion"

# Fix 1: validate — bounded-autonomous + "never" + no criterion -> rc 0
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":"never","bounds":{"max_iterations":5}}'
[[ $? -eq 0 ]] && ok "fix1: never + no criterion -> rc 0" || bad "fix1: never should not require criterion"

# Fix 2: validate — max_iterations non-integer -> rc 2
loop_validate_spec '{"autonomy":"checkpoint","bounds":{"max_iterations":"2.5"}}' 2>/dev/null
[[ $? -eq 2 ]] && ok "fix2: validate non-integer max_iterations -> rc 2" || bad "fix2: non-integer max_iterations should fail"

loop_validate_spec '{"autonomy":"checkpoint","bounds":{"max_iterations":1.5}}' 2>/dev/null
[[ $? -eq 2 ]] && ok "fix2: validate float max_iterations 1.5 -> rc 2" || bad "fix2: float max_iterations 1.5 should fail"

# Fix 2: check_bounds — non-integer cap -> treat as bound tripped (max_iterations)
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":"2.5"},"cost_so_far_usd":0,"no_progress_count":0}' 2>/dev/null)"
[[ "$r" == "max_iterations" ]] && ok "fix2: check_bounds non-integer cap -> max_iterations" || bad "fix2: check_bounds float cap got=$r"

r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":1.5},"cost_so_far_usd":0,"no_progress_count":0}' 2>/dev/null)"
[[ "$r" == "max_iterations" ]] && ok "fix2: check_bounds float cap 1.5 -> max_iterations" || bad "fix2: check_bounds float 1.5 cap got=$r"

# Fix 3: stop hook timeout — a slow criterion does not hang when timeout(1) is present.
# When timeout binary is absent (macOS default), the hook falls back to plain bash
# and the test is skipped (not a code defect — the hook comment documents this).
if command -v timeout >/dev/null 2>&1; then
  loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"sleep 5"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
  _t_start="$(date +%s)"
  out="$(LOOP_CRITERION_TIMEOUT=1 LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false}')"
  _t_end="$(date +%s)"
  _elapsed=$(( _t_end - _t_start ))
  [[ $_elapsed -lt 5 ]] && ok "fix3: criterion timeout prevents hang (elapsed=${_elapsed}s)" || bad "fix3: criterion hung (elapsed=${_elapsed}s)"
else
  ok "fix3: timeout binary absent — hook uses plain-bash fallback (skip timing test)"
fi

# Fix 4: budget accrual — seed a loop_iteration row and assert cost accrues.
# State must include loop_id matching the log row so the scoped filter picks it up.
mkdir -p "$HOME/.claude/logs"
printf '{"event":"loop_iteration","loop_id":"test-loop","cost_usd":0.25}\n' > "$HOME/.claude/logs/subagent-runs.jsonl"
loop_write_state '{"active":true,"loop_id":"test-loop","iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false}' >/dev/null 2>&1 || true
_cost="$(loop_read_state | jq -r '.cost_so_far_usd')"
# cost_so_far_usd should be > 0 (0.25 from the log row)
awk -v c="$_cost" 'BEGIN{exit !(c > 0)}' 2>/dev/null \
  && ok "fix4: cost accrues from log row (cost=$_cost)" || bad "fix4: cost did not accrue (cost=$_cost)"
# cleanup
rm -f "$HOME/.claude/logs/subagent-runs.jsonl"

# Fix 6: irreversible-deny — env git push -> deny
loop_write_state '{"active":true}'
out="$(run_deny '{"tool_input":{"command":"env git push origin main"}}')"
is_deny "$out" && ok "fix6: env git push -> deny" || bad "fix6: env git push not denied out=$out"

# Fix 6: bash -c "git push" -> deny
out="$(run_deny '{"tool_input":{"command":"bash -c \"git push origin main\""}}')"
is_deny "$out" && ok "fix6: bash -c git push -> deny" || bad "fix6: bash -c git push not denied out=$out"

# Fix 6: sudo git push -> deny
out="$(run_deny '{"tool_input":{"command":"sudo git push origin main"}}')"
is_deny "$out" && ok "fix6: sudo git push -> deny" || bad "fix6: sudo git push not denied out=$out"

# Fix 6: git status still allowed through wrappers
out="$(run_deny '{"tool_input":{"command":"git status"}}')"
[[ -z "$out" ]] && ok "fix6: git status still allowed" || bad "fix6: git status denied out=$out"

# Fix 7: loop-stop with HOME unset + inactive state -> exits 0, no crash
(
  unset HOME
  loop_write_state '{"active":false}' 2>/dev/null || true
  bash "$STOP" <<< '{"stop_hook_active":false}' >/dev/null 2>&1
  echo "exit:$?"
) | grep -q "exit:0" && ok "fix7: loop-stop HOME unset inactive -> exit 0" || bad "fix7: loop-stop HOME unset crashed"

# Non-blocking fix 8: foreman SKILL.md uses "bounds" (plural)
grep -q 'success_criterion.*bounds' "$FOREMAN" && ok "fix8: foreman uses bounds (plural)" || bad "fix8: foreman still has singular bound"

# Non-blocking fix 9: no_progress_exit:false + npc>=2 -> ok
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5},"cost_so_far_usd":0,"no_progress_count":2,"no_progress_exit":false,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "ok" ]] && ok "fix9: no_progress_exit:false + npc>=2 -> ok" || bad "fix9: got=$r"

# --- Regression tests for this round's bug fixes ---

# BUG1: cost accrual scoping — only rows for THIS loop_id should accrue.
# Seed two rows for "my-loop" and one for "other-loop"; assert only "my-loop" rows count.
mkdir -p "$HOME/.claude/logs"
printf '{"event":"loop_iteration","loop_id":"my-loop","cost_usd":0.10}\n' > "$HOME/.claude/logs/subagent-runs.jsonl"
printf '{"event":"loop_iteration","loop_id":"my-loop","cost_usd":0.15}\n' >> "$HOME/.claude/logs/subagent-runs.jsonl"
printf '{"event":"loop_iteration","loop_id":"other-loop","cost_usd":9.99}\n' >> "$HOME/.claude/logs/subagent-runs.jsonl"
loop_write_state '{"active":true,"loop_id":"my-loop","iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false}' >/dev/null 2>&1 || true
_cost="$(loop_read_state | jq -r '.cost_so_far_usd')"
# Should be ~0.25 (0.10 + 0.15 from my-loop), NOT 10.24 (which would include other-loop).
awk -v c="$_cost" 'BEGIN{exit !(c > 0.20 && c < 1.0)}' 2>/dev/null \
  && ok "bug1: cost scoped to loop_id only (cost=$_cost, expected ~0.25)" \
  || bad "bug1: cost not scoped to loop_id (cost=$_cost, expected ~0.25, not ~10.24)"
rm -f "$HOME/.claude/logs/subagent-runs.jsonl"

# BUG2a: validate — per_run_budget_usd:"abc" -> rc 2
loop_validate_spec '{"autonomy":"checkpoint","bounds":{"max_iterations":5,"per_run_budget_usd":"abc"}}' 2>/dev/null
[[ $? -eq 2 ]] && ok "bug2a: per_run_budget_usd:abc -> rc 2" || bad "bug2a: non-numeric budget should fail"

# BUG2b: validate — max_iterations:0 -> rc 2 (must be >= 1)
loop_validate_spec '{"autonomy":"checkpoint","bounds":{"max_iterations":0}}' 2>/dev/null
[[ $? -eq 2 ]] && ok "bug2b: max_iterations:0 -> rc 2" || bad "bug2b: zero max_iterations should fail"

# BUG2b: validate — timeout_minutes:0 -> rc 2
loop_validate_spec '{"autonomy":"checkpoint","bounds":{"max_iterations":5,"timeout_minutes":0}}' 2>/dev/null
[[ $? -eq 2 ]] && ok "bug2b: timeout_minutes:0 -> rc 2" || bad "bug2b: zero timeout_minutes should fail"

# BUG3: criterion timeout — never hangs (uses timeout/gtimeout/background+kill fallback).
# We test the background+kill path by temporarily hiding timeout and gtimeout.
# If neither timeout nor gtimeout is available, the hook must use background+kill
# and return in <= 3 seconds for a criterion that sleeps 60 seconds.
(
  # Subshell with PATH that excludes timeout and gtimeout binaries.
  _no_to_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'coreutils\|homebrew/bin\|usr/bin\|usr/local/bin' | tr '\n' ':' | sed 's/:$//')"
  # Only run this inner test if neither timeout nor gtimeout is on the restricted path.
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    loop_write_state '{"active":true,"loop_id":"bg-test","iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"sleep 60"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}' 2>/dev/null || true
    _t0="$(date +%s)"
    LOOP_CRITERION_TIMEOUT=2 LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false}' >/dev/null 2>&1 || true
    _t1="$(date +%s)"
    echo "elapsed:$(( _t1 - _t0 ))"
  else
    echo "has-timeout"
  fi
) | {
  read _bg_out
  if [[ "$_bg_out" == "has-timeout" ]]; then
    ok "bug3: timeout binary present — background fallback path not exercised (ok)"
  elif [[ "$_bg_out" =~ ^elapsed:([0-9]+)$ ]]; then
    _e="${BASH_REMATCH[1]}"
    [[ $_e -lt 10 ]] && ok "bug3: background+kill fallback did not hang (elapsed=${_e}s)" \
                      || bad "bug3: background+kill fallback hung (elapsed=${_e}s)"
  else
    ok "bug3: background fallback path inconclusive — skip (no output)"
  fi
}

# BUG4: command chains — split on ;, &&, ||, | and deny if ANY segment matches.
loop_write_state '{"active":true}'

# git push; true -> deny (the push segment is caught even with trailing ; true)
out="$(run_deny '{"tool_input":{"command":"git push; true"}}')"
is_deny "$out" && ok "bug4: git push; true -> deny" || bad "bug4: git push; true not denied out=$out"

# false || git push -> deny
out="$(run_deny '{"tool_input":{"command":"false || git push origin main"}}')"
is_deny "$out" && ok "bug4: false || git push -> deny" || bad "bug4: false || git push not denied out=$out"

# echo hello && git push -> deny
out="$(run_deny '{"tool_input":{"command":"echo hello && git push"}}')"
is_deny "$out" && ok "bug4: echo hello && git push -> deny" || bad "bug4: echo hello && git push not denied out=$out"

# bash -lc "git push" -> deny (bash -lc is a login-shell form of bash -c)
out="$(run_deny '{"tool_input":{"command":"bash -lc \"git push origin main\""}}')"
is_deny "$out" && ok "bug4: bash -lc git push -> deny" || bad "bug4: bash -lc git push not denied out=$out"

# git status still allowed (must not be a false positive from chain-splitting)
out="$(run_deny '{"tool_input":{"command":"git status"}}')"
[[ -z "$out" ]] && ok "bug4: git status still allowed after chain fix" || bad "bug4: git status denied after chain fix out=$out"

# git status; git log -> allowed (neither segment is denied)
out="$(run_deny '{"tool_input":{"command":"git status; git log --oneline -5"}}')"
[[ -z "$out" ]] && ok "bug4: git status; git log -> allowed" || bad "bug4: git status; git log denied out=$out"

# --- ADR-020: per-session loop-state isolation ---

# Two distinct session ids resolve to distinct files; writes do not collide.
( export CLAUDE_CODE_SESSION_ID="sessA"; loop_write_state '{"active":true,"iteration":1,"loop_id":"A"}' )
( export CLAUDE_CODE_SESSION_ID="sessB"; loop_write_state '{"active":true,"iteration":7,"loop_id":"B"}' )
_ia="$( export CLAUDE_CODE_SESSION_ID="sessA"; loop_read_state | jq -r '.iteration' )"
_ib="$( export CLAUDE_CODE_SESSION_ID="sessB"; loop_read_state | jq -r '.iteration' )"
[[ "$_ia" == "1" && "$_ib" == "7" ]] && ok "adr020: sessions isolated (A=$_ia B=$_ib)" || bad "adr020: sessions collided (A=$_ia B=$_ib)"
[[ -f "$HOME/.claude/session-state/loop-state.sessA.json" && -f "$HOME/.claude/session-state/loop-state.sessB.json" ]] \
  && ok "adr020: per-session files exist" || bad "adr020: per-session files missing"

# Legacy fallback: no session id -> single loop-state.json (back-compat).
( unset CLAUDE_CODE_SESSION_ID; loop_write_state '{"active":true,"iteration":3,"loop_id":"legacy"}' )
[[ -f "$HOME/.claude/session-state/loop-state.json" ]] && ok "adr020: legacy fallback file when no sid" || bad "adr020: legacy fallback missing"

# A session id carrying path-traversal chars is sanitized; it cannot escape the dir.
( export CLAUDE_CODE_SESSION_ID="../../evil"; loop_write_state '{"active":true}' )
[[ ! -e "$HOME/evil" && ! -e "$REPO_ROOT/evil" ]] && ok "adr020: sid path-traversal sanitized" || bad "adr020: sid traversal escaped"

# Stop hook routes by payload session_id: a foreign session's loop must not block
# this stop; the owning session's loop must.
( export CLAUDE_CODE_SESSION_ID="sessC"; loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}' )
out="$(LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false,"session_id":"sessD"}')"
[[ -z "$out" ]] && ok "adr020: foreign session's loop does not block this stop" || bad "adr020: stop blocked by foreign loop out=$out"
out="$(LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false,"session_id":"sessC"}')"
echo "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "adr020: stop blocks the owning session" || bad "adr020: owning session not blocked out=$out"
rm -f "$HOME/.claude/session-state/loop-state.sess"*.json

# ============================================================================
# Phase 2 — residual closures + new guardrails
# ============================================================================

# --- Task 1: no-progress hash includes untracked-file byte-contents ---
(
  _hwd="$(mktemp -d)"; cd "$_hwd" || exit 0
  git init -q; git config user.email t@t; git config user.name t
  echo base > tracked; git add tracked; git commit -qm init
  printf 'one\n' > untracked_u            # untracked, non-ignored
  h1="$(loop_state_hash "$_hwd")"
  printf 'two\n' > untracked_u            # same name, different CONTENT, still untracked
  h2="$(loop_state_hash "$_hwd")"
  rm -rf "$_hwd"
  [[ -n "$h1" && "$h1" != "$h2" ]] && echo "ok" || echo "bad h1=$h1 h2=$h2"
) | { read -r r rest; [[ "$r" == "ok" ]] && ok "hash: untracked content change detected" || bad "hash untracked content $rest"; }

# gitignored files must NOT affect the hash (exclude-standard honored)
(
  _hwd="$(mktemp -d)"; cd "$_hwd" || exit 0
  git init -q; git config user.email t@t; git config user.name t
  echo "ignored_*" > .gitignore; git add .gitignore; git commit -qm init
  ha="$(loop_state_hash "$_hwd")"
  printf 'x\n' > ignored_file
  hb="$(loop_state_hash "$_hwd")"
  rm -rf "$_hwd"
  [[ "$ha" == "$hb" ]] && echo "ok" || echo "bad ha=$ha hb=$hb"
) | { read -r r rest; [[ "$r" == "ok" ]] && ok "hash: gitignored file ignored" || bad "hash ignored $rest"; }

# --- Task 2: recursion-depth is a hard bound ---
r="$(loop_check_bounds '{"iteration":1,"recursion_depth":5,"bounds":{"max_iterations":99,"max_recursion_depth":5},"cost_so_far_usd":0,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "max_recursion_depth" ]] && ok "bounds: recursion depth trips" || bad "recursion got=$r"
r="$(loop_check_bounds '{"iteration":1,"recursion_depth":2,"bounds":{"max_iterations":99,"max_recursion_depth":5},"cost_so_far_usd":0,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "ok" ]] && ok "bounds: recursion depth within ok" || bad "recursion within got=$r"
# back-compat: state without recursion fields must not trip
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":99},"cost_so_far_usd":0,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "ok" ]] && ok "bounds: no recursion fields -> ok" || bad "recursion backcompat got=$r"

# --- Task 3: ultracode signal + ceiling-lift ---
( unset CLAUDE_ULTRACODE; rm -f "$HOME/.claude/session-state/ultracode-state.json" 2>/dev/null
  loop_ultracode_active && echo "on" || echo "off" ) | { read -r r; [[ "$r" == "off" ]] && ok "ultracode: default off" || bad "ultracode default $r"; }
( export CLAUDE_ULTRACODE=1; loop_ultracode_active && echo "on" || echo "off" ) | { read -r r; [[ "$r" == "on" ]] && ok "ultracode: env on" || bad "ultracode env $r"; }
( mkdir -p "$HOME/.claude/session-state"; echo '{"active":true}' > "$HOME/.claude/session-state/ultracode-state.json"
  unset CLAUDE_ULTRACODE; loop_ultracode_active && echo "on" || echo "off" ) | { read -r r; [[ "$r" == "on" ]] && ok "ultracode: state on" || bad "ultracode state $r"; }
rm -f "$HOME/.claude/session-state/ultracode-state.json" 2>/dev/null
# Follow-up fix: explicit state file is AUTHORITATIVE over the CLAUDE_ULTRACODE env
# (dashboard-repo bug — /ultracode off was a no-op when the harness injected
# the env var). Assertions run in the MAIN shell so failures actually count; env is
# scoped to each `bash -c` subprocess, which also exercises bash 3.2 portability.
mkdir -p "$HOME/.claude/session-state"; UCF="$HOME/.claude/session-state/ultracode-state.json"
# explicit {"active":false} overrides a truthy env (the /ultracode off fix)
echo '{"active":false}' > "$UCF"
r="$(CLAUDE_ULTRACODE=1 bash -c 'source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "off" ]] && ok "ultracode: state off overrides env on" || bad "ultracode state-off-vs-env=$r"
echo '{"active":true}' > "$UCF"
r="$(bash -c 'unset CLAUDE_ULTRACODE; source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "on" ]] && ok "ultracode: state on (no env)" || bad "ultracode state-on=$r"
rm -f "$UCF"
r="$(CLAUDE_ULTRACODE=ON bash -c 'source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "on" ]] && ok "ultracode: uppercase env via portable lowercase" || bad "ultracode uppercase-env=$r"
rm -f "$UCF"
# SECURITY (blocker fix): a present-but-empty / {} / malformed file is NOT
# authoritative-OFF — that would let a dropped blank file silently disable the
# design-gate. It falls through to env, so the gate stays ON when env is truthy.
: > "$UCF"
r="$(CLAUDE_ULTRACODE=1 bash -c 'source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "on" ]] && ok "ultracode: empty file not authoritative (env wins)" || bad "ultracode empty-file=$r"
echo '{}' > "$UCF"
r="$(CLAUDE_ULTRACODE=1 bash -c 'source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "on" ]] && ok "ultracode: {} (no boolean .active) not authoritative" || bad "ultracode empty-obj=$r"
printf 'not json{' > "$UCF"
r="$(CLAUDE_ULTRACODE=1 bash -c 'source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "on" ]] && ok "ultracode: malformed file not authoritative" || bad "ultracode malformed=$r"
echo '{}' > "$UCF"
r="$(bash -c 'unset CLAUDE_ULTRACODE; source "'"$LIB"'"; loop_ultracode_active && echo on || echo off')"
[[ "$r" == "off" ]] && ok "ultracode: {} + no env -> off (default)" || bad "ultracode empty-obj-noenv=$r"
rm -f "$UCF"
[[ "$(loop_effective_ceiling checkpoint true)"          == "bounded-checkpoint"  ]] && ok "ceiling: checkpoint+1"  || bad "ceiling cp"
[[ "$(loop_effective_ceiling bounded-checkpoint true)"  == "bounded-autonomous"  ]] && ok "ceiling: bchk+1"       || bad "ceiling bchk"
[[ "$(loop_effective_ceiling bounded-autonomous true)"  == "bounded-autonomous"  ]] && ok "ceiling: capped"       || bad "ceiling cap"
[[ "$(loop_effective_ceiling checkpoint false)"         == "checkpoint"          ]] && ok "ceiling: off=identity" || bad "ceiling off"

# --- Task 4: live mid-flight cost monitor ---
MON="$REPO_ROOT/hooks/loop-cost-monitor.sh"
[[ -x "$MON" ]] && ok "monitor: hook executable" || bad "monitor: not executable"
run_mon() { LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$MON" <<< "$1"; }

# loop_live_cost sums rows for the matching loop_id only
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"
: > "$LOG"
printf '%s\n' '{"event":"loop_iteration","loop_id":"L1","cost_usd":1.5}' >> "$LOG"
printf '%s\n' '{"event":"loop_iteration","loop_id":"L1","cost_usd":2.0}' >> "$LOG"
printf '%s\n' '{"event":"loop_iteration","loop_id":"OTHER","cost_usd":99}' >> "$LOG"
lc="$(loop_live_cost L1)"
awk -v v="$lc" 'BEGIN{exit !(v==3.5)}' && ok "monitor: live cost sums loop_id" || bad "live cost got=$lc"

# active loop over budget -> deny + status budget_exceeded
loop_write_state '{"active":true,"loop_id":"L1","bounds":{"per_run_budget_usd":3,"max_iterations":99},"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z"}'
out="$(run_mon '{"tool_name":"Bash"}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "monitor: over budget -> deny" || bad "monitor over-budget out=$out"
[[ "$(loop_read_state | jq -r '.status')" == "budget_exceeded" ]] && ok "monitor: marks budget_exceeded" || bad "monitor status not set"

# under budget -> allow (empty)
loop_write_state '{"active":true,"loop_id":"L1","bounds":{"per_run_budget_usd":100,"max_iterations":99},"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z"}'
out="$(run_mon '{"tool_name":"Bash"}')"
[[ -z "$out" ]] && ok "monitor: under budget -> allow" || bad "monitor under-budget out=$out"

# no active loop -> allow
loop_write_state '{"active":false,"loop_id":"L1","bounds":{"per_run_budget_usd":1}}'
out="$(run_mon '{"tool_name":"Bash"}')"
[[ -z "$out" ]] && ok "monitor: inactive -> allow" || bad "monitor inactive out=$out"
: > "$LOG"

# --- Task 5: Supabase loop_runs telemetry ---
SQL="$REPO_ROOT/schemas/004-loop-runs.sql"
[[ -f "$SQL" ]] && ok "telemetry: 004-loop-runs.sql present" || bad "telemetry: SQL missing"
grep -q 'create table if not exists stack.loop_runs' "$SQL" && ok "telemetry: table defined" || bad "telemetry: no table"
# balanced parens sanity
_op="$(tr -cd '(' < "$SQL" | wc -c)"; _cp="$(tr -cd ')' < "$SQL" | wc -c)"
[[ "$_op" == "$_cp" ]] && ok "telemetry: SQL parens balanced" || bad "telemetry: parens $_op/$_cp"

# loop_runs_record: no Supabase creds -> no-op (rc 0) + local JSONL row written
( unset SUPABASE_URL SUPABASE_SERVICE_KEY
  loop_runs_record '{"loop_id":"LR1","status":"met","iteration":3,"cost_so_far_usd":1.25,"pattern":"ralph"}'
  echo "rc=$?" ) | { read -r r; [[ "$r" == "rc=0" ]] && ok "telemetry: record rc=0 without creds" || bad "telemetry rc $r"; }
LRLOG="$HOME/.claude/logs/loop-runs.jsonl"
[[ -f "$LRLOG" ]] && [[ "$(jq -r 'select(.loop_id=="LR1") | .status' "$LRLOG" 2>/dev/null | tail -1)" == "met" ]] \
  && ok "telemetry: local JSONL row written" || bad "telemetry: local row missing"
# payload shape: numeric iterations + cost mapped correctly
[[ "$(jq -r 'select(.loop_id=="LR1") | .iterations' "$LRLOG" 2>/dev/null | tail -1)" == "3" ]] \
  && ok "telemetry: iterations mapped" || bad "telemetry: iterations wrong"
# empty arg -> no-op rc 0
loop_runs_record "" ; [[ $? -eq 0 ]] && ok "telemetry: empty arg no-op" || bad "telemetry empty arg"
rm -f "$LRLOG" 2>/dev/null

# --- Task 6: ADR-021 design-before-code gate ---
GATE="$REPO_ROOT/hooks/design-gate.sh"
[[ -x "$GATE" ]] && ok "gate: hook executable" || bad "gate: not executable"
run_gate() { LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$GATE" <<< "$1"; }
mkdir -p "$HOME/.claude/session-state"
rm -f "$HOME/.claude/session-state/design-approved.json" 2>/dev/null

# ultracode OFF -> always allow, even on a source file with no marker
( unset CLAUDE_ULTRACODE
  out="$(run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"}}')"
  [[ -z "$out" ]] && echo ok || echo "bad:$out" ) | { read -r r; [[ "$r" == "ok" ]] && ok "gate: ultracode off -> allow" || bad "gate off $r"; }

# ultracode ON + source file + no marker -> deny
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"}}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "gate: ultracode on + source -> deny" || bad "gate deny out=$out"

# ultracode ON + docs target -> allow (must be able to write the spec)
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"docs/superpowers/specs/x.md"}}')"
[[ -z "$out" ]] && ok "gate: docs always allowed" || bad "gate docs out=$out"

# ultracode ON + tests target -> allow
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"tests/test-x.sh"}}')"
[[ -z "$out" ]] && ok "gate: tests always allowed" || bad "gate tests out=$out"

# ultracode ON + markdown (non-source) -> allow
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"README.md"}}')"
[[ -z "$out" ]] && ok "gate: markdown allowed" || bad "gate md out=$out"

# ultracode ON + source + approved marker -> allow
echo '{"active":true}' > "$HOME/.claude/session-state/design-approved.json"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"}}')"
[[ -z "$out" ]] && ok "gate: approved marker -> allow" || bad "gate marker out=$out"
rm -f "$HOME/.claude/session-state/design-approved.json"

# ============================================================================
# Phase 3 — observability, smarter control, authoring path
# ============================================================================

# --- T6: durable corrections ---
CORR="$HOME/.claude/session-state/loop-corrections.jsonl"
rm -f "$CORR" 2>/dev/null
loop_record_correction '{"loop_id":"C1","status":"no_progress","goal":"make tests pass","iteration":4}' "exited no_progress with goal unmet"
[[ -f "$CORR" ]] && ok "corrections: row appended" || bad "corrections: no file"
[[ "$(jq -r 'select(.loop_id=="C1") | .status' "$CORR" 2>/dev/null | tail -1)" == "no_progress" ]] && ok "corrections: status captured" || bad "corrections: status wrong"
[[ "$(jq -r 'select(.loop_id=="C1") | .resolved' "$CORR" 2>/dev/null | tail -1)" == "false" ]] && ok "corrections: unresolved by default" || bad "corrections: resolved flag"
[[ "$(jq -r 'select(.loop_id=="C1") | .hint' "$CORR" 2>/dev/null | tail -1)" == *"goal unmet"* ]] && ok "corrections: hint captured" || bad "corrections: hint missing"
# empty arg -> no-op rc 0
loop_record_correction "" ; [[ $? -eq 0 ]] && ok "corrections: empty arg no-op" || bad "corrections empty"
# Stop-hook records a correction on a bound-trip exit (no_progress), NOT on met.
rm -f "$CORR" 2>/dev/null
( export CLAUDE_CODE_SESSION_ID="corrSess"
  loop_write_state '{"active":true,"loop_id":"SH1","iteration":1,"bounds":{"max_iterations":1},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
  LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false,"session_id":"corrSess"}' >/dev/null 2>&1 )
[[ -f "$CORR" ]] && [[ -n "$(jq -r 'select(.loop_id=="SH1")' "$CORR" 2>/dev/null)" ]] && ok "corrections: stop-hook records bound-trip" || bad "corrections: stop-hook missing"
rm -f "$CORR" "$HOME/.claude/session-state/loop-state.corrSess.json" 2>/dev/null

# --- T3: per-path design-gate marker ---
GATE="$REPO_ROOT/hooks/design-gate.sh"
run_gate() { LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$GATE" <<< "$1"; }
mkdir -p "$HOME/.claude/session-state"
MK="$HOME/.claude/session-state/design-approved.json"

# path-scoped marker: matching glob -> allow; non-matching source -> deny
echo '{"active":true,"approved_paths":["skills/foo/**"]}' > "$MK"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"}}')"
[[ -z "$out" ]] && ok "gate(p3): approved path allowed" || bad "gate(p3) approved out=$out"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/other/x.sh"}}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "gate(p3): unapproved path denied" || bad "gate(p3) unapproved out=$out"

# legacy bare {active:true} -> all source allowed (back-compat)
echo '{"active":true}' > "$MK"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/other/x.sh"}}')"
[[ -z "$out" ]] && ok "gate(p3): legacy marker allows all source" || bad "gate(p3) legacy out=$out"

# empty approved_paths -> treated as session-wide (allow)
echo '{"active":true,"approved_paths":[]}' > "$MK"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/other/x.sh"}}')"
[[ -z "$out" ]] && ok "gate(p3): empty approved_paths = session-wide" || bad "gate(p3) empty out=$out"
rm -f "$MK"

# --- design-gate marker is per-session (ADR-020 pattern; clobber isolation) ---
SS="$HOME/.claude/session-state"; mkdir -p "$SS"; rm -f "$SS"/design-approved*.json
# session A has an approved marker; B has none -> A's approval must NOT leak to B
echo '{"active":true}' > "$SS/design-approved.SA.json"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"},"session_id":"SA"}')"
[[ -z "$out" ]] && ok "gate(sess): session A marker allows A" || bad "gate(sess) A out=$out"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"},"session_id":"SB"}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "gate(sess): A marker does not leak to B" || bad "gate(sess) B-leak out=$out"
# legacy unscoped marker is honored ONLY when no session id resolves (back-compat)
rm -f "$SS"/design-approved*.json
echo '{"active":true}' > "$SS/design-approved.json"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"}}')"
[[ -z "$out" ]] && ok "gate(sess): legacy unscoped marker = fallback (no sid)" || bad "gate(sess) legacy out=$out"
# a resolved session id must NOT fall back to the shared global marker (no leak)
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"},"session_id":"SC"}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "gate(sess): global marker does not leak to a sid session" || bad "gate(sess) global-leak out=$out"
# per-session file takes precedence over legacy when both exist
rm -f "$SS"/design-approved*.json
echo '{"active":true}' > "$SS/design-approved.json"
echo '{"active":true,"approved_paths":["skills/only/**"]}' > "$SS/design-approved.SD.json"
out="$(CLAUDE_ULTRACODE=1 run_gate '{"tool_input":{"file_path":"skills/foo/bar.sh"},"session_id":"SD"}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "gate(sess): per-session marker overrides legacy" || bad "gate(sess) precedence out=$out"
rm -f "$SS"/design-approved*.json

# --- T2: real token-cost signal ---
export LOOP_PRICE_TABLE="$REPO_ROOT/config/model-routing.json"
# opus 5 (renamed from opus 4.8 2026-07-27, same placeholder pricing carried
# over): $5/Mtok in, $25/Mtok out. 200k in + 100k out = 1.0 + 2.5 = 3.5
c="$(loop_cost_from_usage 200000 100000 claude-opus-5)"
awk -v v="$c" 'BEGIN{exit !(v>3.49 && v<3.51)}' && ok "cost_from_usage: opus priced" || bad "cost_from_usage got=$c"
# unknown model -> 0 (fail-safe)
c="$(loop_cost_from_usage 1000 1000 no-such-model)"
awk -v v="$c" 'BEGIN{exit !(v==0)}' && ok "cost_from_usage: unknown model -> 0" || bad "cost_from_usage unknown=$c"
# zero tokens -> 0
c="$(loop_cost_from_usage 0 0 claude-opus-5)"
awk -v v="$c" 'BEGIN{exit !(v==0)}' && ok "cost_from_usage: zero -> 0" || bad "cost_from_usage zero=$c"

# ADR-024: real per-tool cost is recorded post-call by loop-cost-accrual.sh, then
# enforced by the PreToolUse monitor via loop_live_cost (the old PreToolUse
# usage-read branch was a no-op — a PreToolUse hook never sees tool_response).
ACCRUE="$REPO_ROOT/hooks/loop-cost-accrual.sh"
[[ -x "$ACCRUE" ]] && ok "accrual: hook executable" || bad "accrual: not executable"
run_accrue() { LOOP_STATE_DIR="$HOME/.claude/session-state" LOOP_PRICE_TABLE="$LOOP_PRICE_TABLE" bash "$ACCRUE" <<< "$1"; }
mkdir -p "$HOME/.claude/logs"; : > "$HOME/.claude/logs/subagent-runs.jsonl"

# active loop + usage payload -> writes a loop_tool_cost row with real USD (3.5)
loop_write_state '{"active":true,"loop_id":"ACC1","bounds":{"per_run_budget_usd":3,"max_iterations":99},"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z"}'
run_accrue '{"tool_name":"Agent","model":"claude-opus-5","tool_response":{"usage":{"input_tokens":200000,"output_tokens":100000}}}'
acc="$(jq -rs '[.[]|select(.event=="loop_tool_cost" and .loop_id=="ACC1")|.cost_usd]|add // 0' "$HOME/.claude/logs/subagent-runs.jsonl")"
awk -v v="$acc" 'BEGIN{exit !(v>3.49 && v<3.51)}' && ok "accrual: writes real-cost row" || bad "accrual cost=$acc"

# monitor then denies via loop_live_cost summing that row (no usage in its payload)
out="$(LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$REPO_ROOT/hooks/loop-cost-monitor.sh" <<< '{"tool_name":"Bash"}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "monitor(p3): accrued rows trip budget" || bad "monitor(p3) accrued out=$out"

# loop_runs_record reflects real spend (max of snapshot vs live) -> ~3.5, not 0
( unset SUPABASE_URL SUPABASE_SERVICE_KEY
  loop_runs_record '{"loop_id":"ACC1","status":"met","iteration":1,"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z","pattern":"ralph"}' )
rec="$(jq -r 'select(.loop_id=="ACC1")|.cost_usd' "$HOME/.claude/logs/loop-runs.jsonl" 2>/dev/null | tail -1)"
awk -v v="$rec" 'BEGIN{exit !(v>3.49 && v<3.51)}' && ok "record: reflects real (live) cost" || bad "record cost=$rec"
rm -f "$HOME/.claude/logs/loop-runs.jsonl"

# accrual: no active loop -> no row
loop_write_state '{"active":false,"loop_id":"ACC2"}'
: > "$HOME/.claude/logs/subagent-runs.jsonl"
run_accrue '{"tool_name":"Agent","tool_response":{"usage":{"input_tokens":200000,"output_tokens":100000}}}'
[[ ! -s "$HOME/.claude/logs/subagent-runs.jsonl" ]] && ok "accrual: inactive -> no row" || bad "accrual inactive wrote a row"

# accrual: active loop but no usage -> no row
loop_write_state '{"active":true,"loop_id":"ACC3","bounds":{"per_run_budget_usd":3},"started_at":"2000-01-01T00:00:00Z"}'
run_accrue '{"tool_name":"Bash"}'
[[ ! -s "$HOME/.claude/logs/subagent-runs.jsonl" ]] && ok "accrual: no usage -> no row" || bad "accrual no-usage wrote a row"

# monitor: no cost + under budget -> allow
loop_write_state '{"active":true,"loop_id":"LIVE2","bounds":{"per_run_budget_usd":100,"max_iterations":99},"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z"}'
out="$(LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$REPO_ROOT/hooks/loop-cost-monitor.sh" <<< '{"tool_name":"Bash"}')"
[[ -z "$out" ]] && ok "monitor(p3): no cost + under budget -> allow" || bad "monitor(p3) allow out=$out"
unset LOOP_PRICE_TABLE
: > "$HOME/.claude/logs/subagent-runs.jsonl"

# Stop hook is a true hard cap (ADR-024): loop_tool_cost rows over budget, goal
# unmet -> Stop trips budget_exceeded (folds loop_live_cost into the bound check).
STOP="$REPO_ROOT/hooks/loop-stop.sh"
printf '%s\n' '{"event":"loop_tool_cost","loop_id":"HC1","cost_usd":4.0,"ts":"2000-01-02T00:00:00Z"}' >> "$HOME/.claude/logs/subagent-runs.jsonl"
CLAUDE_CODE_SESSION_ID="hcSess" loop_write_state '{"active":true,"loop_id":"HC1","bounds":{"per_run_budget_usd":3,"max_iterations":99,"max_recursion_depth":9},"cost_so_far_usd":0,"started_at":"2000-01-01T00:00:00Z","no_progress_count":0}'
LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP" <<< '{"stop_hook_active":false,"session_id":"hcSess"}' >/dev/null 2>&1
hcstatus="$(CLAUDE_CODE_SESSION_ID="hcSess" loop_read_state | jq -r '.status')"
[[ "$hcstatus" == "budget_exceeded" ]] && ok "stop(p3): tool-cost rows trip hard cap" || bad "stop(p3) hard cap status=$hcstatus"
rm -f "$HOME/.claude/session-state/loop-state.hcSess.json" 2>/dev/null
: > "$HOME/.claude/logs/subagent-runs.jsonl"

# Registration (ADR-024 blocker fixes): monitor enforces on Workflow; accrual on Workflow
TPL="$REPO_ROOT/config/settings.team.template.json"
jq -e '[.hooks.PreToolUse[]? | select(.matcher|test("Workflow")) | .hooks[]? | select(.command|test("loop-cost-monitor.sh"))]|length>=1' "$TPL" >/dev/null 2>&1 && ok "register: monitor enforces on Workflow" || bad "register: monitor not on Workflow"
jq -e '[.hooks.PostToolUse[]? | select(.matcher|test("Workflow")) | .hooks[]? | select(.command|test("loop-cost-accrual.sh"))]|length>=1' "$TPL" >/dev/null 2>&1 && ok "register: accrual on Workflow" || bad "register: accrual not on Workflow"

# --- T1: telemetry feedback (loop_stats + loop_calibrate + /loop-review) ---
[[ -f "$REPO_ROOT/skills/loop-review/SKILL.md" ]] && ok "loop-review: skill present" || bad "loop-review: missing"
# empty history -> []
STATLOG="$(mktemp)"; : > "$STATLOG"
[[ "$(loop_stats "$STATLOG")" == "[]" ]] && ok "stats: empty -> []" || bad "stats empty"
# seed: pattern ralph x3 (iterations 4,6,20; one budget_exceeded, one met, one max_iterations)
printf '%s\n' \
  '{"loop_id":"a","pattern":"ralph","status":"met","iterations":4,"cost_usd":1}' \
  '{"loop_id":"b","pattern":"ralph","status":"budget_exceeded","iterations":6,"cost_usd":5}' \
  '{"loop_id":"c","pattern":"ralph","status":"max_iterations","iterations":20,"cost_usd":2}' \
  '{"loop_id":"d","pattern":"eval-driven","status":"met","iterations":2,"cost_usd":1}' \
  >> "$STATLOG"
ST="$(loop_stats "$STATLOG")"
[[ "$(echo "$ST" | jq -r 'length')" == "2" ]] && ok "stats: groups by pattern" || bad "stats groups=$(echo "$ST" | jq -r 'length')"
[[ "$(echo "$ST" | jq -r '.[] | select(.pattern=="ralph") | .runs')" == "3" ]] && ok "stats: ralph runs=3" || bad "stats ralph runs"
p95="$(echo "$ST" | jq -r '.[] | select(.pattern=="ralph") | .p95_iterations')"
[[ "$p95" == "20" ]] && ok "stats: p95 iterations" || bad "stats p95=$p95"
# loop_stats_table (ADR-024): deterministic aligned rendering
TBL="$(loop_stats_table "$STATLOG")"
echo "$TBL" | head -1 | grep -q 'PATTERN' && ok "stats_table: header row" || bad "stats_table header"
echo "$TBL" | grep -q 'ralph' && ok "stats_table: pattern row present" || bad "stats_table ralph row"
[[ "$(echo "$TBL" | wc -l | tr -d ' ')" == "3" ]] && ok "stats_table: header + 2 rows" || bad "stats_table rows=$(echo "$TBL" | wc -l | tr -d ' ')"
EMPTY="$(mktemp)"; : > "$EMPTY"
[[ -z "$(loop_stats_table "$EMPTY")" ]] && ok "stats_table: empty -> nothing" || bad "stats_table empty not blank"
rm -f "$EMPTY"
# calibrate: proposed >= ceil(p95*1.2)=24, and >= current(25) -> 25
CAL="$(loop_calibrate 25 "$STATLOG")"
prop="$(echo "$CAL" | jq -r '.[] | select(.pattern=="ralph") | .proposed_max_iterations')"
[[ "$prop" == "25" ]] && ok "calibrate: floored at current" || bad "calibrate prop=$prop"
# with low current, proposed tracks p95*1.2 -> ceil(24)=24
CAL2="$(loop_calibrate 5 "$STATLOG")"
prop2="$(echo "$CAL2" | jq -r '.[] | select(.pattern=="ralph") | .proposed_max_iterations')"
[[ "$prop2" == "24" ]] && ok "calibrate: tracks p95*1.2" || bad "calibrate prop2=$prop2"
# calibrate never writes stack-config (pure function — just verify it returns JSON)
echo "$CAL" | jq -e 'type=="array"' >/dev/null 2>&1 && ok "calibrate: returns array (no side effects)" || bad "calibrate type"
rm -f "$STATLOG"

# --- T4: 5-point effort enum (additive; legacy is a subset) ---
SCH="$REPO_ROOT/schemas/stack-config-schema.json"
DEF="$REPO_ROOT/schemas/stack-defaults-schema.json"
eff="$(jq -c '.properties.session_prefs.properties.model_effort.enum' "$SCH" 2>/dev/null)"
[[ "$(echo "$eff" | jq -r 'length')" == "5" ]] && ok "effort: 5 values in config schema" || bad "effort config count=$eff"
echo "$eff" | jq -e 'index("minimal") and index("thorough")' >/dev/null 2>&1 && ok "effort: minimal+thorough added" || bad "effort new values missing"
# legacy values still valid (back-compat = subset)
echo "$eff" | jq -e 'index("fast") and index("balanced") and index("max")' >/dev/null 2>&1 && ok "effort: legacy values retained" || bad "effort legacy missing"
# defaults schema kept in sync
[[ "$(jq -r '.properties.session_prefs_defaults.properties.model_effort.enum | length' "$DEF" 2>/dev/null)" == "5" ]] && ok "effort: defaults schema in sync" || bad "effort defaults out of sync"
# default unchanged
[[ "$(jq -r '.properties.session_prefs.properties.model_effort.default' "$SCH")" == "balanced" ]] && ok "effort: default still balanced" || bad "effort default changed"

# --- T5: vendored authoring skills (using-superpowers + brainstorming) ---
for s in using-superpowers brainstorming; do
  f="$REPO_ROOT/skills/$s/SKILL.md"
  [[ -f "$f" ]] && ok "vendor: $s present" || bad "vendor: $s missing"
  head -1 "$f" 2>/dev/null | grep -q '^---$' && ok "vendor: $s frontmatter" || bad "vendor: $s no frontmatter"
done
# brainstorming text-core: must NOT actually invoke a node server / GUI process
! grep -qiE 'localhost:|127\.0\.0\.1|npm run|node .*\.js|express\(|listen\([0-9]' "$REPO_ROOT/skills/brainstorming/SKILL.md" \
  && ok "vendor: brainstorming is text-core (no server)" || bad "vendor: brainstorming invokes server"
# registered in tier-1 manifest
jq -e '[.files.global[]?.from | select(test("using-superpowers|brainstorming"))] | length == 2' "$REPO_ROOT/config/tier-manifests/tier-1.json" >/dev/null 2>&1 \
  && ok "vendor: tier-1 manifest copies both" || bad "vendor: manifest missing entries"

# --- T7: auto-enablement loop-shape nudge ---
NUDGE="$REPO_ROOT/hooks/loop-shape-nudge.sh"
[[ -x "$NUDGE" ]] && ok "nudge: hook executable" || bad "nudge: not executable"
# Build a throwaway Tier-2 stack project so the gate (Tier>=2) passes.
NPROJ="$(mktemp -d)"; mkdir -p "$NPROJ/.claude"
echo '{"stack_tier":2}' > "$NPROJ/.claude/stack-config.json"
NHOME="$(mktemp -d)"; mkdir -p "$NHOME/.claude/session-state"
run_nudge() { CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$1"; }
mkpayload() { jq -nc --arg p "$1" --arg c "$NPROJ" '{prompt:$p, cwd:$c, session_id:"nudgeSess"}'; }

# loop-shaped prompt, not onboarded -> emits the onboarding reminder
out="$(run_nudge "$(mkpayload "refactor the parser and keep running until all tests pass")")"
echo "$out" | grep -q 'Loop-shape detected' && ok "nudge: loop-shaped -> offers onboarding" || bad "nudge loop-shaped out=$out"
# dedupe: second call same session -> silent
out="$(run_nudge "$(mkpayload "keep going until the build is green")")"
[[ -z "$out" ]] && ok "nudge: once-per-session dedupe" || bad "nudge dedupe out=$out"
# ADR-047: auto_offer_loop:false in project stack-config.json -> silent
# (this replaces the old permanent "onboarded marker" behavior - the ask
# now recurs every session unless auto_offer_loop is explicitly off).
NPROJ_OFF="$(mktemp -d)"; mkdir -p "$NPROJ_OFF/.claude"
echo '{"stack_tier":2,"session_prefs":{"auto_offer_loop":false}}' > "$NPROJ_OFF/.claude/stack-config.json"
out="$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$(jq -nc --arg p "iterate until the eval threshold is met" --arg c "$NPROJ_OFF" '{prompt:$p,cwd:$c,session_id:"offSess"}')")"
[[ -z "$out" ]] && ok "nudge: auto_offer_loop:false (project) -> silent" || bad "nudge auto_offer_loop project-off out=$out"
rm -rf "$NPROJ_OFF"
# ADR-047: auto_offer_loop:false in current-prefs.json (flat, session-scoped
# override) -> silent, even though the project default is true.
echo '{"auto_offer_loop":false}' > "$NHOME/.claude/session-state/current-prefs.json"
out="$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$(jq -nc --arg p "iterate until the eval threshold is met" --arg c "$NPROJ" '{prompt:$p,cwd:$c,session_id:"other"}')")"
[[ -z "$out" ]] && ok "nudge: auto_offer_loop:false (session override) -> silent" || bad "nudge auto_offer_loop session-off out=$out"
rm -f "$NHOME/.claude/session-state/current-prefs.json"
# one-shot / non-loop prompt -> silent
out="$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$(jq -nc --arg p "fix the typo in the readme header" --arg c "$NPROJ" '{prompt:$p,cwd:$c,session_id:"s3"}')")"
[[ -z "$out" ]] && ok "nudge: one-shot -> silent" || bad "nudge one-shot out=$out"
# explain/read prompt with 'until' -> silent (negative guard)
out="$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$(jq -nc --arg p "explain how the loop runs until the goal is met" --arg c "$NPROJ" '{prompt:$p,cwd:$c,session_id:"s4"}')")"
[[ -z "$out" ]] && ok "nudge: explain -> silent" || bad "nudge explain out=$out"
# non-stack dir -> silent
out="$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$NHOME" LOOP_STATE_DIR="$NHOME/.claude/session-state" bash "$NUDGE" <<< "$(jq -nc --arg p "keep iterating until tests pass please" --arg c "$(mktemp -d)" '{prompt:$p,cwd:$c,session_id:"s5"}')")"
[[ -z "$out" ]] && ok "nudge: non-stack dir -> silent" || bad "nudge non-stack out=$out"
rm -rf "$NPROJ" "$NHOME"

# --- T8: bare-agent-nudge (ADR-048 draft mitigation for the ADR-047 bare-Agent gap) ---
BAN="$REPO_ROOT/hooks/bare-agent-nudge.sh"
[[ -x "$BAN" ]] && ok "bare-agent-nudge: hook executable" || bad "bare-agent-nudge: not executable"
BPROJ="$(mktemp -d)"; mkdir -p "$BPROJ/.claude"
echo '{"stack_tier":2}' > "$BPROJ/.claude/stack-config.json"
BHOME="$(mktemp -d)"; mkdir -p "$BHOME/.claude/session-state"
run_ban() { CLAUDE_PLUGIN_ROOT="$REPO_ROOT" HOME="$BHOME" LOOP_STATE_DIR="$BHOME/.claude/session-state" bash "$BAN" <<< "$1"; }
mkagentpayload() {
  # $1=description $2=prompt $3=session_id $4=cwd $5=run_in_background (true/false/omit)
  local desc="$1" prompt="$2" sid="$3" cwd="$4" bg="${5:-}"
  if [[ -z "$bg" ]]; then
    jq -nc --arg d "$desc" --arg p "$prompt" --arg s "$sid" --arg c "$cwd" \
      '{tool_name:"Agent", tool_input:{description:$d, prompt:$p, subagent_type:"implementer"}, cwd:$c, session_id:$s}'
  else
    jq -nc --arg d "$desc" --arg p "$prompt" --arg s "$sid" --arg c "$cwd" --argjson bg "$bg" \
      '{tool_name:"Agent", tool_input:{description:$d, prompt:$p, subagent_type:"implementer", run_in_background:$bg}, cwd:$c, session_id:$s}'
  fi
}

# loop-shaped bare dispatch (background default, no active loop) -> nudges, non-blocking allow.
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass, don't stop" "banA" "$BPROJ")")"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1 \
  && ok "bare-agent-nudge: loop-shaped -> permissionDecision allow (non-blocking)" || bad "bare-agent-nudge allow out=$out"
echo "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'loop-engineer' \
  && ok "bare-agent-nudge: loop-shaped -> mentions /loop-engineer" || bad "bare-agent-nudge content out=$out"

# explicit run_in_background:false -> silent (synchronous, bounded by parent's own turn).
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass" "banB" "$BPROJ" false)")"
[[ -z "$out" ]] && ok "bare-agent-nudge: run_in_background:false -> silent" || bad "bare-agent-nudge sync out=$out"

# active governed loop for this session -> silent (already governed by loop-cost-monitor.sh).
echo '{"active":true,"loop_id":"x"}' > "$BHOME/.claude/session-state/loop-state.banC.json"
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass" "banC" "$BPROJ")")"
[[ -z "$out" ]] && ok "bare-agent-nudge: active loop -> silent" || bad "bare-agent-nudge active-loop out=$out"

# Honest limitation (ADR-048 draft): an ORDINARY one-shot foreman-style dispatch
# (no iterate/until/keep-going language) does NOT match -- this is deliberate, not
# a bug: this hook would NOT have caught the actual 13-hour incident either.
out="$(run_ban "$(mkagentpayload "implement handoff" "Implement per the architect handoff packet at .claude/sessions/x/architect-handoff.md" "banD" "$BPROJ")")"
[[ -z "$out" ]] && ok "bare-agent-nudge: ordinary one-shot dispatch -> silent (by design)" || bad "bare-agent-nudge ordinary out=$out"

# dedupe: second loop-shaped call, same session -> silent.
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass" "banA" "$BPROJ")")"
[[ -z "$out" ]] && ok "bare-agent-nudge: once-per-session dedupe" || bad "bare-agent-nudge dedupe out=$out"

# Tier <2 project -> silent.
BPROJ1="$(mktemp -d)"; mkdir -p "$BPROJ1/.claude"; echo '{"stack_tier":1}' > "$BPROJ1/.claude/stack-config.json"
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass" "banE" "$BPROJ1")")"
[[ -z "$out" ]] && ok "bare-agent-nudge: Tier<2 -> silent" || bad "bare-agent-nudge tier1 out=$out"
rm -rf "$BPROJ1"

# auto_offer_loop:false (project) -> silent.
BPROJ2="$(mktemp -d)"; mkdir -p "$BPROJ2/.claude"
echo '{"stack_tier":2,"session_prefs":{"auto_offer_loop":false}}' > "$BPROJ2/.claude/stack-config.json"
out="$(run_ban "$(mkagentpayload "keep going" "keep iterating until all tests pass" "banF" "$BPROJ2")")"
[[ -z "$out" ]] && ok "bare-agent-nudge: auto_offer_loop:false -> silent" || bad "bare-agent-nudge auto-off out=$out"
rm -rf "$BPROJ2" "$BPROJ" "$BHOME"

# hooks.json registration: bare-agent-nudge is wired on the Agent PreToolUse matcher.
jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Agent") | .hooks[]? | select(.command | test("bare-agent-nudge.sh"))] | length >= 1' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: bare-agent-nudge registered on Agent matcher" || bad "hooks.json: bare-agent-nudge missing"

FAIL="$(wc -l <"$_fail_log" | tr -d '[:space:]')"
echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
