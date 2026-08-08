#!/usr/bin/env bash
# Tests for the four T0/T1 hook-event wirings (issues #109-#112):
#   #109 hooks/session-end-handoff-reminder.sh  (SessionEnd)
#   #110 hooks/stop-failure-log.sh              (StopFailure)
#   #111 hooks/permission-denied-log.sh         (PermissionDenied)
#   #112 hooks/config-change-flag.sh            (ConfigChange)
# Each appends into the existing subagent-runs.jsonl log (same file
# override-log.sh / loop-cost-accrual.sh already write to) — no new log
# format is introduced. All four are pure observability: never a gate,
# always exit 0.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

last_row() { [[ -f "$LOG" ]] && tail -1 "$LOG" || echo "{}"; }
row_count() { [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo "0"; }

# ─── #109: SessionEnd — session-end-handoff-reminder.sh ────────────────────
HOOK_109="$REPO_ROOT/hooks/session-end-handoff-reminder.sh"

REPO_A="$TMP/repo-a"
mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
git -C "$REPO_A" -c user.email=t@t.com -c user.name=t commit --allow-empty -q -m init
echo "tracked" > "$REPO_A/file.txt"
git -C "$REPO_A" add file.txt
git -C "$REPO_A" -c user.email=t@t.com -c user.name=t commit -q -m "add file"
echo "modified" >> "$REPO_A/file.txt"   # uncommitted tracked change

OUT=$(jq -nc --arg c "$REPO_A" '{cwd:$c, session_id:"sess-a", reason:"other"}' | bash "$HOOK_109" 2>/dev/null)
echo "$OUT" | grep -q "/handoff" && pass "109.1: reminder printed when uncommitted work exists" \
  || fail "109.1: no reminder in output: $OUT"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="session_end_handoff_reminder" and .uncommitted==true and .reminder_shown==true and .session_id=="sess-a"' >/dev/null 2>&1 \
  && pass "109.2: row shape correct for uncommitted work" || fail "109.2: row: $ROW"

REPO_B="$TMP/repo-b"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" -c user.email=t@t.com -c user.name=t commit --allow-empty -q -m init
OUT=$(jq -nc --arg c "$REPO_B" '{cwd:$c, session_id:"sess-b", reason:"other"}' | bash "$HOOK_109" 2>/dev/null)
[[ -z "$OUT" ]] && pass "109.3: clean tree -> no reminder printed" || fail "109.3: unexpected output: $OUT"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="session_end_handoff_reminder" and .uncommitted==false and .reminder_shown==false' >/dev/null 2>&1 \
  && pass "109.4: row still appended (auditable) when clean" || fail "109.4: row: $ROW"

# Clean tree + an ACTIVE loop state file for this session -> reminder fires
# on the "open thread" branch, not the git-status branch.
mkdir -p "$HOME/.claude/session-state"
echo '{"active":true,"loop_id":"L1"}' > "$HOME/.claude/session-state/loop-state.sess-x.json"
OUT=$(jq -nc --arg c "$REPO_B" '{cwd:$c, session_id:"sess-x", reason:"other"}' | bash "$HOOK_109" 2>/dev/null)
echo "$OUT" | grep -q "/handoff" && pass "109.5: reminder printed for an open loop thread (clean git tree)" \
  || fail "109.5: no reminder in output: $OUT"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="session_end_handoff_reminder" and .uncommitted==false and .loop_active==true and .reminder_shown==true and .session_id=="sess-x"' >/dev/null 2>&1 \
  && pass "109.6: row shows loop_active true drove the reminder" || fail "109.6: row: $ROW"

# ─── #110: StopFailure — stop-failure-log.sh ────────────────────────────────
HOOK_110="$REPO_ROOT/hooks/stop-failure-log.sh"
COUNT_BEFORE=$(row_count)
OUT=$(jq -nc --arg c "$TMP" '{cwd:$c, session_id:"sess-c", hook_event_name:"StopFailure", error:"rate_limit", error_details:"429 Too Many Requests"}' \
  | bash "$HOOK_110" 2>/dev/null)
[[ -z "$OUT" ]] && pass "110.1: no stdout (notification-only event)" || fail "110.1: unexpected stdout: $OUT"
[[ "$(row_count)" -eq $((COUNT_BEFORE + 1)) ]] && pass "110.2: exactly one row appended" || fail "110.2: row count $(row_count)"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="stop_failure" and .error=="rate_limit" and .error_details=="429 Too Many Requests" and .session_id=="sess-c"' >/dev/null 2>&1 \
  && pass "110.3: row captures error + error_details" || fail "110.3: row: $ROW"
echo "$ROW" | jq -e 'has("cost_usd") or has("cost")' >/dev/null 2>&1 \
  && fail "110.4: row must NEVER carry cost_usd/cost (would corrupt loop_live_cost)" \
  || pass "110.4: row carries no cost_usd/cost key"

# ─── #111: PermissionDenied — permission-denied-log.sh ─────────────────────
HOOK_111="$REPO_ROOT/hooks/permission-denied-log.sh"
COUNT_BEFORE=$(row_count)
OUT=$(jq -nc --arg c "$TMP" \
  '{cwd:$c, session_id:"sess-d", hook_event_name:"PermissionDenied", tool_name:"Bash", tool_input:{command:"rm -rf /tmp/build"}, tool_use_id:"toolu_01ABC", reason:"Blocked by classifier", permission_mode:"auto"}' \
  | bash "$HOOK_111" 2>/dev/null)
[[ -z "$OUT" ]] && pass "111.1: no stdout (never a gate)" || fail "111.1: unexpected stdout: $OUT"
[[ "$(row_count)" -eq $((COUNT_BEFORE + 1)) ]] && pass "111.2: exactly one row appended" || fail "111.2: row count $(row_count)"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="permission_denied" and .tool_name=="Bash" and .tool_use_id=="toolu_01ABC" and .reason=="Blocked by classifier" and .permission_mode=="auto"' >/dev/null 2>&1 \
  && pass "111.3: row captures classifier-denial fields" || fail "111.3: row: $ROW"

# ─── #112: ConfigChange — config-change-flag.sh ────────────────────────────
HOOK_112="$REPO_ROOT/hooks/config-change-flag.sh"
CFG="$TMP/settings.json"
echo '{"a":1}' > "$CFG"

# First sighting -> silent on stdout, baseline recorded, AND a row logged.
# The row is deliberate (security-report.md 2026-08-04, HIGH): without it a
# malicious first edit would silently become the trusted baseline with zero
# audit trail. These assertions previously expected no row and were stale
# against that fix — they now pin the fix instead of the old behavior.
COUNT_BEFORE=$(row_count)
OUT=$(jq -nc --arg c "$TMP" --arg fp "$CFG" '{cwd:$c, session_id:"sess-e", hook_event_name:"ConfigChange", source:"project_settings", file_path:$fp}' \
  | bash "$HOOK_112" 2>/dev/null)
[[ -z "$OUT" ]] && pass "112.1: first sighting -> no stdout" || fail "112.1: unexpected stdout: $OUT"
[[ "$(row_count)" -eq $((COUNT_BEFORE + 1)) ]] && pass "112.2: first sighting -> row logged (no silent baseline)" || fail "112.2: expected 1 new row, count went $COUNT_BEFORE -> $(row_count)"
ROW=$(last_row)
echo "$ROW" | jq -e '.baseline == "first_sighting" and .sanctioned == "unverified"' >/dev/null 2>&1 \
  && pass "112.2a: first-sighting row is labelled first_sighting/unverified" || fail "112.2a: row: $ROW"

# Re-run unchanged -> no further row (the baseline now exists and matches).
COUNT_BEFORE=$(row_count)
OUT=$(jq -nc --arg c "$TMP" --arg fp "$CFG" '{cwd:$c, session_id:"sess-e", hook_event_name:"ConfigChange", source:"project_settings", file_path:$fp}' \
  | bash "$HOOK_112" 2>/dev/null)
[[ "$(row_count)" -eq "$COUNT_BEFORE" ]] && pass "112.3: unchanged content -> still no row" || fail "112.3: row count changed"

# Content actually changes -> warning + row.
echo '{"a":2}' > "$CFG"
COUNT_BEFORE=$(row_count)
STDERR_OUT=$(jq -nc --arg c "$TMP" --arg fp "$CFG" '{cwd:$c, session_id:"sess-e", hook_event_name:"ConfigChange", source:"project_settings", file_path:$fp}' \
  | bash "$HOOK_112" 2>&1 >/dev/null)
[[ "$(row_count)" -eq $((COUNT_BEFORE + 1)) ]] && pass "112.4: drifted content -> row appended" || fail "112.4: row count $(row_count)"
ROW=$(last_row)
echo "$ROW" | jq -e '.event=="config_change_flag" and .source=="project_settings" and .sanctioned=="unverified" and .file_path' >/dev/null 2>&1 \
  && pass "112.5: row flags unverified provenance" || fail "112.5: row: $ROW"
[[ -n "$STDERR_OUT" ]] && pass "112.6: warning printed to stderr" || fail "112.6: no stderr warning"

# Baseline updates -> a third run with the same (now-current) content is quiet again.
COUNT_BEFORE=$(row_count)
OUT=$(jq -nc --arg c "$TMP" --arg fp "$CFG" '{cwd:$c, session_id:"sess-e", hook_event_name:"ConfigChange", source:"project_settings", file_path:$fp}' \
  | bash "$HOOK_112" 2>/dev/null)
[[ "$(row_count)" -eq "$COUNT_BEFORE" ]] && pass "112.7: baseline re-armed after flagging -> quiet on next unchanged sighting" || fail "112.7: row count changed"

# No decision/block field ever emitted by any of the four (H3: never a gate).
for h in "$HOOK_109" "$HOOK_110" "$HOOK_111" "$HOOK_112"; do
  case "$h" in
    "$HOOK_109") PAYLOAD=$(jq -nc --arg c "$TMP" '{cwd:$c, session_id:"s"}') ;;
    "$HOOK_110") PAYLOAD=$(jq -nc --arg c "$TMP" '{cwd:$c, session_id:"s", error:"unknown"}') ;;
    "$HOOK_111") PAYLOAD=$(jq -nc --arg c "$TMP" '{cwd:$c, session_id:"s", tool_name:"Bash"}') ;;
    "$HOOK_112") PAYLOAD=$(jq -nc --arg c "$TMP" --arg fp "$CFG" '{cwd:$c, session_id:"s", source:"project_settings", file_path:$fp}') ;;
  esac
  OUT=$(echo "$PAYLOAD" | bash "$h" 2>/dev/null)
  if echo "$OUT" | grep -q "permissionDecision\|\"decision\""; then
    fail "H3: $(basename "$h") emitted a decision field"
  else
    pass "H3: $(basename "$h") never emits a decision field"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
