#!/usr/bin/env bash
# Tests for hooks/override-log.sh (ADR-007 #5).
# Covers: logs under financial-code / schema-migration / confidential; silent in
# normal context; never emits a permissionDecision; Tier gating; row schema.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/override-log.sh"

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

# make_repo <dir> <tier> <extra-json-fields>
make_repo() {
  local dir="$1" tier="${2:-2}" extra="${3:-}"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null || true
  local json="{\"stack_tier\":$tier,\"stack_version\":\"1.0.0\",\"purpose\":\"test\",\"created\":\"2026-01-01\""
  [[ -n "$extra" ]] && json="$json,$extra"
  json="$json}"
  echo "$json" > "$dir/.claude/stack-config.json"
}

# run <cwd> <subagent_type> -> stdout from hook
run() {
  jq -nc --arg c "$1" --arg a "$2" \
    '{cwd:$c, tool_name:"Agent", tool_input:{subagent_type:$a, description:"do a thing"}}' \
    | bash "$HOOK" 2>/dev/null
}
last_row() { [[ -f "$LOG" ]] && tail -1 "$LOG" || echo "{}"; }
row_count() { [[ -f "$LOG" ]] && wc -l < "$LOG" | tr -d ' ' || echo "0"; }

# ─── A: financial-code domain logs an override_context row ────────────────────
REPO_A="$TMP/repo-fin"; make_repo "$REPO_A" 2 '"domain_mode":"financial-code","orchestration_mode":"agent-teams"'
OUT=$(run "$REPO_A" "implementer")
[[ -z "$OUT" ]] && pass "A1: no stdout (never a gate)" || fail "A1: unexpected stdout: $OUT"
ROW=$(last_row)
if echo "$ROW" | jq -e '.event=="override_context" and (.contexts|index("financial-code")) and .agent=="implementer" and .orchestration_mode=="agent-teams"' >/dev/null 2>&1; then
  pass "A2: row tags financial-code + agent + orchestration_mode"
else
  fail "A2: row wrong; row: $ROW"
fi

# ─── B: schema-migration domain ──────────────────────────────────────────────
REPO_B="$TMP/repo-schema"; make_repo "$REPO_B" 2 '"domain_mode":"schema-migration"'
run "$REPO_B" "data-engineer" >/dev/null
ROW=$(last_row)
echo "$ROW" | jq -e '(.contexts|index("schema-migration"))' >/dev/null 2>&1 \
  && pass "B: schema-migration tagged" || fail "B: row: $ROW"

# ─── C: confidential sensitivity ─────────────────────────────────────────────
REPO_C="$TMP/repo-conf"; make_repo "$REPO_C" 2 '"sensitivity":{"level":"confidential"}'
run "$REPO_C" "reviewer" >/dev/null
ROW=$(last_row)
echo "$ROW" | jq -e '(.contexts|index("sensitivity:confidential"))' >/dev/null 2>&1 \
  && pass "C: confidential tagged" || fail "C: row: $ROW"

# ─── D: financial-code + confidential -> both contexts ───────────────────────
REPO_D="$TMP/repo-both"; make_repo "$REPO_D" 2 '"domain_mode":"financial-code","sensitivity":{"level":"confidential"}'
run "$REPO_D" "red-team" >/dev/null
ROW=$(last_row)
if echo "$ROW" | jq -e '(.contexts|length)==2 and (.contexts|index("financial-code")) and (.contexts|index("sensitivity:confidential"))' >/dev/null 2>&1; then
  pass "D: both contexts present"
else
  fail "D: row: $ROW"
fi

# ─── E: normal context -> no row, no stdout ──────────────────────────────────
COUNT_BEFORE=$(row_count)
REPO_E="$TMP/repo-normal"; make_repo "$REPO_E" 2
OUT=$(run "$REPO_E" "implementer")
[[ -z "$OUT" ]] && pass "E1: normal context -> no stdout" || fail "E1: got $OUT"
[[ "$(row_count)" -eq "$COUNT_BEFORE" ]] && pass "E2: normal context -> no row appended" || fail "E2: row count changed"

# ─── F: Tier<2 and no-stack -> no row ────────────────────────────────────────
COUNT_BEFORE=$(row_count)
REPO_F1="$TMP/repo-t1"; make_repo "$REPO_F1" 1 '"domain_mode":"financial-code"'
run "$REPO_F1" "implementer" >/dev/null
REPO_F2="$TMP/repo-ns"; mkdir -p "$REPO_F2"; git -C "$REPO_F2" init -q 2>/dev/null || true
run "$REPO_F2" "implementer" >/dev/null
[[ "$(row_count)" -eq "$COUNT_BEFORE" ]] && pass "F: Tier<2 / no-stack -> no row" || fail "F: row count changed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
