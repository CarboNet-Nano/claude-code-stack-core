#!/usr/bin/env bash
# Tests for hooks/workflow-roster-check.sh
# Covers: warn, block, quiet, Tier<2, off-mode, always-log, backward-compat.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/workflow-roster-check.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Stub HOME so the log goes to a temp location.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# Point lib resolution at the real repo.
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

make_repo() {
  local dir="$1"
  local tier="${2:-2}"
  local extra="${3:-}"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null || true
  local json="{\"stack_tier\":$tier,\"stack_version\":\"1.0.0\",\"purpose\":\"test\",\"created\":\"2026-01-01\""
  if [[ -n "$extra" ]]; then
    json="$json,$extra"
  fi
  json="$json}"
  echo "$json" > "$dir/.claude/stack-config.json"
}

run_hook() {
  local cwd="$1"
  local script="$2"
  # Use jq to build valid JSON so embedded quotes/special chars don't break parse.
  jq -nc --arg s "$script" --arg c "$cwd" '{"tool_input":{"script":$s},"cwd":$c}' \
    | bash "$HOOK" 2>/dev/null
}

run_hook_scriptpath() {
  local cwd="$1"
  local path="$2"
  jq -nc --arg p "$path" --arg c "$cwd" '{"tool_input":{"scriptPath":$p},"cwd":$c}' \
    | bash "$HOOK" 2>/dev/null
}

# Running counter of Tier>=2 invocations — incremented after each Tier-2 run_hook call.
TIER2_INVOCATIONS=0

log_row_count() {
  [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo "0"
}

last_log_row() {
  [[ -f "$LOG" ]] && tail -1 "$LOG" || echo "{}"
}

# ─── C1: write-heavy + no roster, warn mode ───────────────────────────────────
REPO1="$TMP/repo-c1"
make_repo "$REPO1" 2

SCRIPT_C1='implement the parser and write the file'
OUT=$(run_hook "$REPO1" "$SCRIPT_C1")

if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' > /dev/null 2>&1; then
  pass "C1: stdout permissionDecision==allow"
else
  fail "C1: expected permissionDecision==allow; got: $OUT"
fi

ROW=$(last_log_row)
if echo "$ROW" | jq -e '.decision == "warn"' > /dev/null 2>&1; then
  pass "C1: row decision==warn"
else
  fail "C1: row decision!=warn; row: $ROW"
fi
if echo "$ROW" | jq -e '.write_heavy == true' > /dev/null 2>&1; then
  pass "C1: row write_heavy==true"
else
  fail "C1: row write_heavy!=true; row: $ROW"
fi
if echo "$ROW" | jq -e '.roster_agents == []' > /dev/null 2>&1; then
  pass "C1: row roster_agents==[]"
else
  fail "C1: row roster_agents!=[]"
fi
if echo "$ROW" | jq -e '.uses_roster == false' > /dev/null 2>&1; then
  pass "C1: row uses_roster==false"
else
  fail "C1: row uses_roster!=false"
fi
if echo "$ROW" | jq -e '.mode == "warn"' > /dev/null 2>&1; then
  pass "C1: row mode==warn"
else
  fail "C1: row mode!=warn; row: $ROW"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C1b: same script, block mode ─────────────────────────────────────────────
REPO1B="$TMP/repo-c1b"
make_repo "$REPO1B" 2 '"workflow_roster":"block"'

OUT1B=$(run_hook "$REPO1B" "$SCRIPT_C1")

if echo "$OUT1B" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
  pass "C1b: stdout permissionDecision==deny"
else
  fail "C1b: expected permissionDecision==deny; got: $OUT1B"
fi
if echo "$OUT1B" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("block mode")' > /dev/null 2>&1; then
  pass "C1b: reason contains 'block mode'"
else
  fail "C1b: reason missing 'block mode'; got: $OUT1B"
fi

ROW1B=$(last_log_row)
if echo "$ROW1B" | jq -e '.decision == "deny"' > /dev/null 2>&1; then
  pass "C1b: row decision==deny"
else
  fail "C1b: row decision!=deny; row: $ROW1B"
fi
if echo "$ROW1B" | jq -e '.mode == "block"' > /dev/null 2>&1; then
  pass "C1b: row mode==block"
else
  fail "C1b: row mode!=block"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C2: roster agentType present (both quote forms) ──────────────────────────
REPO2="$TMP/repo-c2"
make_repo "$REPO2" 2

SCRIPT_C2='implement something; agent(agentType: '"'"'reviewer'"'"', task:'"'"'review'"'"'); agent(agentType:"architecture-critic", task:'"'"'critique'"'"')'
OUT2=$(run_hook "$REPO2" "$SCRIPT_C2")

if [[ -z "$OUT2" ]]; then
  pass "C2: quiet (empty stdout)"
else
  fail "C2: expected empty stdout; got: $OUT2"
fi

ROW2=$(last_log_row)
if echo "$ROW2" | jq -e '.decision == "quiet"' > /dev/null 2>&1; then
  pass "C2: row decision==quiet"
else
  fail "C2: row decision!=quiet; row: $ROW2"
fi
if echo "$ROW2" | jq -e '.uses_roster == true' > /dev/null 2>&1; then
  pass "C2: row uses_roster==true"
else
  fail "C2: row uses_roster!=true"
fi
# Both names must be present, sorted
if echo "$ROW2" | jq -e '.roster_agents == ["architecture-critic","reviewer"]' > /dev/null 2>&1; then
  pass "C2: roster_agents == [architecture-critic, reviewer]"
else
  fail "C2: roster_agents wrong; row: $ROW2"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C3: read-only script ─────────────────────────────────────────────────────
REPO3="$TMP/repo-c3"
make_repo "$REPO3" 2

SCRIPT_C3='audit the codebase for unused exports'
OUT3=$(run_hook "$REPO3" "$SCRIPT_C3")

if [[ -z "$OUT3" ]]; then
  pass "C3: quiet (empty stdout)"
else
  fail "C3: expected empty stdout; got: $OUT3"
fi

ROW3=$(last_log_row)
if echo "$ROW3" | jq -e '.write_heavy == false' > /dev/null 2>&1; then
  pass "C3: row write_heavy==false"
else
  fail "C3: row write_heavy!=false; row: $ROW3"
fi
if echo "$ROW3" | jq -e '.decision == "quiet"' > /dev/null 2>&1; then
  pass "C3: row decision==quiet"
else
  fail "C3: row decision!=quiet"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C4: non-stack / Tier<2 → no row appended ────────────────────────────────
COUNT_BEFORE=$(log_row_count)

# C4a: no stack-config
REPO4A="$TMP/repo-c4a"
mkdir -p "$REPO4A"
git -C "$REPO4A" init -q 2>/dev/null || true
OUT4A=$(run_hook "$REPO4A" "$SCRIPT_C1")
if [[ -z "$OUT4A" ]]; then
  pass "C4a: no stdout (no stack-config)"
else
  fail "C4a: unexpected stdout: $OUT4A"
fi

# C4b: tier 1 config
REPO4B="$TMP/repo-c4b"
make_repo "$REPO4B" 1
OUT4B=$(run_hook "$REPO4B" "$SCRIPT_C1")
if [[ -z "$OUT4B" ]]; then
  pass "C4b: no stdout (tier 1)"
else
  fail "C4b: unexpected stdout: $OUT4B"
fi

COUNT_AFTER=$(log_row_count)
if [[ "$COUNT_AFTER" -eq "$COUNT_BEFORE" ]]; then
  pass "C4: no log rows appended for non-stack/Tier<2"
else
  fail "C4: log rows changed ($COUNT_BEFORE → $COUNT_AFTER) for non-stack/Tier<2 runs"
fi

# ─── C5: off mode still logs ──────────────────────────────────────────────────
REPO5="$TMP/repo-c5"
make_repo "$REPO5" 2 '"workflow_roster":"off"'

OUT5=$(run_hook "$REPO5" "$SCRIPT_C1")
if [[ -z "$OUT5" ]]; then
  pass "C5: no stdout (off mode)"
else
  fail "C5: expected empty stdout in off mode; got: $OUT5"
fi

ROW5=$(last_log_row)
if echo "$ROW5" | jq -e '.decision == "quiet"' > /dev/null 2>&1; then
  pass "C5: row decision==quiet"
else
  fail "C5: row decision!=quiet; row: $ROW5"
fi
if echo "$ROW5" | jq -e '.mode == "off"' > /dev/null 2>&1; then
  pass "C5: row mode==off"
else
  fail "C5: row mode!=off"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C8: double-quoted JSON key — "agentType":"reviewer" (FIX 2 confirmed miss) ─
REPO8="$TMP/repo-c8"
make_repo "$REPO8" 2

SCRIPT_C8='implement the pipeline; {"agentType":"reviewer","task":"review changes"}'
OUT8=$(run_hook "$REPO8" "$SCRIPT_C8")

if [[ -z "$OUT8" ]]; then
  pass "C8: quiet (roster role detected via double-quoted key)"
else
  fail "C8: expected quiet stdout; got: $OUT8"
fi

ROW8=$(last_log_row)
if echo "$ROW8" | jq -e '.roster_agents | contains(["reviewer"])' > /dev/null 2>&1; then
  pass "C8: roster_agents includes reviewer from double-quoted key"
else
  fail "C8: double-quoted key not captured; row: $ROW8"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C9: prose mention — 'reviewer' not in agentType form → no false positive ──
REPO9="$TMP/repo-c9"
make_repo "$REPO9" 2

SCRIPT_C9='implement the pipeline; this script is reviewed by a reviewer'
OUT9=$(run_hook "$REPO9" "$SCRIPT_C9")

ROW9=$(last_log_row)
if echo "$ROW9" | jq -e '.roster_agents == []' > /dev/null 2>&1; then
  pass "C9: prose mention does not produce false-positive roster_agents"
else
  fail "C9: prose mention falsely captured; row: $ROW9"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C10: ops role (FIX 1) ────────────────────────────────────────────────────
REPO10="$TMP/repo-c10"
make_repo "$REPO10" 2

SCRIPT_C10="implement deploy; agent(agentType:'ops', task:'run deploy')"
OUT10=$(run_hook "$REPO10" "$SCRIPT_C10")

ROW10=$(last_log_row)
if echo "$ROW10" | jq -e '.roster_agents | contains(["ops"])' > /dev/null 2>&1; then
  pass "C10: ops role captured (FIX 1)"
else
  fail "C10: ops role not captured; row: $ROW10"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C11: scriptPath case (FIX 3) ─────────────────────────────────────────────
REPO11="$TMP/repo-c11"
make_repo "$REPO11" 2

SCRIPT_FILE="$TMP/workflow-script.sh"
printf '%s\n' '#!/usr/bin/env bash' 'implement the feature and write the file' > "$SCRIPT_FILE"

OUT11=$(run_hook_scriptpath "$REPO11" "$SCRIPT_FILE")

ROW11=$(last_log_row)
if echo "$ROW11" | jq -e '.script_source == "scriptPath"' > /dev/null 2>&1; then
  pass "C11: script_source==scriptPath logged"
else
  fail "C11: script_source!=scriptPath; row: $ROW11"
fi
if echo "$ROW11" | jq -e '.write_heavy == true' > /dev/null 2>&1; then
  pass "C11: write_heavy detected from scriptPath file contents"
else
  fail "C11: write_heavy not detected from scriptPath; row: $ROW11"
fi
if [[ -n "$OUT11" ]]; then
  pass "C11: warn emitted for write-heavy scriptPath with no roster"
else
  fail "C11: expected warn output for write-heavy scriptPath; got empty"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C12: saved-name workflow treated as write-heavy worst-case (FIX #4) ──────
# A saved-name workflow has no inspectable body (SCRIPT empty). In block mode it
# must be denied, not waved through.
REPO12="$TMP/repo-c12"
make_repo "$REPO12" 2 '"workflow_roster":"block"'

run_hook_name() {
  local cwd="$1"
  local name="$2"
  jq -nc --arg n "$name" --arg c "$cwd" '{"tool_input":{"name":$n},"cwd":$c}' \
    | bash "$HOOK" 2>/dev/null
}

OUT12=$(run_hook_name "$REPO12" "my-saved-workflow")
if echo "$OUT12" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
  pass "C12: saved-name workflow denied in block mode (FIX #4)"
else
  fail "C12: expected deny for saved-name in block mode; got: $OUT12"
fi
ROW12=$(last_log_row)
if echo "$ROW12" | jq -e '.script_source == "name" and .write_heavy == true and .decision == "deny"' > /dev/null 2>&1; then
  pass "C12: row script_source==name, write_heavy==true, decision==deny"
else
  fail "C12: row wrong; row: $ROW12"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C13: saved-name workflow warns in warn mode (FIX #4) ─────────────────────
REPO13="$TMP/repo-c13"
make_repo "$REPO13" 2
OUT13=$(run_hook_name "$REPO13" "my-saved-workflow")
if echo "$OUT13" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' > /dev/null 2>&1; then
  pass "C13: saved-name workflow warns (allow+reminder) in warn mode"
else
  fail "C13: expected warn/allow for saved-name in warn mode; got: $OUT13"
fi
ROW13=$(last_log_row)
if echo "$ROW13" | jq -e '.decision == "warn" and .write_heavy == true' > /dev/null 2>&1; then
  pass "C13: row decision==warn, write_heavy==true"
else
  fail "C13: row wrong; row: $ROW13"
fi
TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))

# ─── C14: broadened write verbs (grant/revoke/drop/alter table/deploy/push) ───
REPO14="$TMP/repo-c14"
make_repo "$REPO14" 2 '"workflow_roster":"block"'
for verb in "grant select on" "revoke usage" "drop the index" "alter table users" "deploy the function" "push the branch"; do
  OUT14=$(run_hook "$REPO14" "$verb to finish the job")
  if echo "$OUT14" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then
    pass "C14: write verb '$verb' triggers block-mode deny"
  else
    fail "C14: write verb '$verb' did NOT trigger deny; got: $OUT14"
  fi
  TIER2_INVOCATIONS=$((TIER2_INVOCATIONS+1))
done

# ─── C6: log count matches running Tier>=2 invocation counter ─────────────────
TOTAL=$(log_row_count)
if [[ "$TOTAL" -eq "$TIER2_INVOCATIONS" ]]; then
  pass "C6: exactly $TIER2_INVOCATIONS rows logged for $TIER2_INVOCATIONS Tier>=2 invocations"
else
  fail "C6: expected $TIER2_INVOCATIONS rows, got $TOTAL"
fi

# ─── C7: backward-compat — row without roster_agents parses via // [] ─────────
OLD_ROW='{"event":"workflow_dispatch","ts":"2026-01-01T00:00:00Z","project":"/old","agent":"workflow","uses_roster":false,"write_heavy":true}'
echo "$OLD_ROW" >> "$LOG"

RESULT=$(echo "$OLD_ROW" | jq -r '(.roster_agents // []) | length')
if [[ "$RESULT" == "0" ]]; then
  pass "C7: (.roster_agents // []) returns [] on old row"
else
  fail "C7: backward-compat parse failed; result: $RESULT"
fi

# ─── C-merge: tier-split + settings idempotency ───────────────────────────────
# Team hooks live in a tier-2-only fragment, NOT the tier-0 base template
# (ADR-016 follow-up). The base template carries only the Bash matcher; the
# fragment carries the Agent + Workflow PreToolUse matchers, the Agent
# PostToolUse matcher, and dispatch-nudge. Tier-2 install merges the two, and
# re-merging (update mode) must stay idempotent.
BASE="$REPO_ROOT/config/settings.global.template.json"
FRAGMENT="$REPO_ROOT/config/settings.team.template.json"

# Base template: Bash only, no team matchers.
if [[ "$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Bash")]|length' "$BASE")" -eq 1 ]]; then
  pass "C-merge: base template has exactly 1 Bash matcher"
else
  fail "C-merge: base template Bash matcher count wrong"
fi
if [[ "$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Agent" or .matcher=="Workflow")]|length' "$BASE")" -eq 0 ]]; then
  pass "C-merge: base template carries no team matchers"
else
  fail "C-merge: base template still references team matchers (should be in fragment)"
fi

# Fragment: Agent + Workflow (PreToolUse) and Agent (PostToolUse).
if [[ "$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Agent")]|length' "$FRAGMENT")" -eq 1 \
   && "$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Workflow")]|length' "$FRAGMENT")" -eq 1 ]]; then
  pass "C-merge: fragment has Agent + Workflow PreToolUse matchers"
else
  fail "C-merge: fragment missing Agent/Workflow PreToolUse matcher"
fi
if [[ "$(jq '[.hooks.PostToolUse[]?|select(.matcher=="Agent")]|length' "$FRAGMENT")" -eq 1 ]]; then
  pass "C-merge: fragment has Agent PostToolUse matcher"
else
  fail "C-merge: fragment missing Agent PostToolUse matcher"
fi

# Simulate the real install: fresh tier-0 copies the base, tier-2 merges the
# fragment. Re-running (update mode) re-merges both and must not duplicate —
# unique() deduplicates identical matcher objects.
source "$REPO_ROOT/scripts/lib/config-merger.sh"

MDIR="$TMP/merge-test"
mkdir -p "$MDIR"
cp "$BASE" "$MDIR/settings.json"   # fresh tier-0 = cp

assert_wired() {
  local label="$1" f="$MDIR/settings.json"
  local wf ba ag pa dn
  wf=$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Workflow")]|length' "$f")
  ba=$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Bash")]|length' "$f")
  ag=$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Agent")]|length' "$f")
  pa=$(jq '[.hooks.PostToolUse[]?|select(.matcher=="Agent")]|length' "$f")
  dn=$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?|select(.command|test("dispatch-nudge"))]|length' "$f")
  if [[ "$wf" -eq 1 && "$ba" -eq 1 && "$ag" -eq 1 && "$pa" -eq 1 && "$dn" -eq 1 ]]; then
    pass "C-merge: $label — Bash/Agent/Workflow/PostAgent/dispatch-nudge each ==1"
  else
    fail "C-merge: $label — wf=$wf ba=$ba ag=$ag postAgent=$pa nudge=$dn"
  fi
}

STACK_MERGE_NONINTERACTIVE=1 merge_json "$FRAGMENT" "$MDIR/settings.json"  # tier-2 merge
assert_wired "after first install"

# Update mode: re-merge base then fragment into the existing settings.
STACK_MERGE_NONINTERACTIVE=1 merge_json "$BASE" "$MDIR/settings.json"
STACK_MERGE_NONINTERACTIVE=1 merge_json "$FRAGMENT" "$MDIR/settings.json"
assert_wired "after re-merge (idempotent)"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
