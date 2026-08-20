#!/usr/bin/env bash
# Tests that PreToolUse hooks read their tool input from the stdin JSON payload.
#
# Regression guard: both hooks below originally read CLAUDE_TOOL_INPUT_<param>
# env vars, which Claude Code never populates. subagent-log.sh silently logged
# every dispatch as agent="unknown" (blinding /team-status and the team lines in
# /goodmorning and /handoff), and bulk-job-reminder.sh never fired at all, so the
# bulk-job cost guardrail was dead. Any future hook that regresses to env-only
# reads will fail here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBAGENT_HOOK="$REPO_ROOT/hooks/subagent-log.sh"
BULK_HOOK="$REPO_ROOT/hooks/bulk-job-reminder.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# dispatch <subagent_type> <description> <model>
dispatch() {
  jq -nc --arg a "$1" --arg d "$2" --arg m "$3" \
    '{tool_name:"Agent", tool_input:{subagent_type:$a, description:$d, model:$m}}' \
    | bash "$SUBAGENT_HOOK" 2>/dev/null
}
last_row() { [[ -f "$LOG" ]] && tail -1 "$LOG" || echo "{}"; }

# bash_cmd <command>
bash_cmd() {
  jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | bash "$BULK_HOOK" 2>/dev/null
}

# ─── A: subagent-log reads subagent_type from stdin ──────────────────────────
dispatch "reviewer" "cold-read the diff" "sonnet"
ROW=$(last_row)
if echo "$ROW" | jq -e '.event=="dispatch" and .agent=="reviewer" and .desc=="cold-read the diff" and .model=="sonnet"' >/dev/null 2>&1; then
  pass "A: agent/desc/model come from stdin payload"
else
  fail "A: row: $ROW"
fi

# ─── B: env vars alone must NOT satisfy the hook ──────────────────────────────
# Claude Code does not set these; a hook passing on env alone is the bug.
echo '{}' | CLAUDE_TOOL_INPUT_subagent_type="red-team" bash "$SUBAGENT_HOOK" 2>/dev/null
ROW=$(last_row)
echo "$ROW" | jq -e '.agent=="red-team"' >/dev/null 2>&1 \
  && pass "B: env fallback still honored when stdin is empty" || fail "B: row: $ROW"

# ─── C: no payload at all -> agent is "unknown", never null ──────────────────
echo '{}' | bash "$SUBAGENT_HOOK" 2>/dev/null
ROW=$(last_row)
echo "$ROW" | jq -e '.agent=="unknown" and .desc=="" and .model==""' >/dev/null 2>&1 \
  && pass "C: empty payload -> unknown, no nulls" || fail "C: row: $ROW"

# ─── D: malformed stdin must not crash or write a null agent ─────────────────
echo 'not json' | bash "$SUBAGENT_HOOK" 2>/dev/null
RC=$?
ROW=$(last_row)
if [[ "$RC" -eq 0 ]] && echo "$ROW" | jq -e '.agent=="unknown"' >/dev/null 2>&1; then
  pass "D: malformed stdin -> exit 0, agent=unknown"
else
  fail "D: rc=$RC row: $ROW"
fi

# ─── E: bulk-job-reminder fires on a bulk command from stdin ─────────────────
OUT=$(bash_cmd "node scripts/enrich-items.mjs --batch")
echo "$OUT" | grep -q "bulk-job guardrail" \
  && pass "E: guardrail fires on bulk command from stdin" || fail "E: got: $OUT"

# ─── F: bulk-job-reminder stays silent on an ordinary command ────────────────
OUT=$(bash_cmd "ls -la")
[[ -z "$OUT" ]] && pass "F: silent on non-bulk command" || fail "F: got: $OUT"

# ─── G: bulk-job-reminder survives an empty payload ──────────────────────────
OUT=$(echo '{}' | bash "$BULK_HOOK" 2>/dev/null)
RC=$?
[[ "$RC" -eq 0 && -z "$OUT" ]] && pass "G: empty payload -> exit 0, silent" || fail "G: rc=$RC out: $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
