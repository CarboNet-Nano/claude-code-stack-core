#!/usr/bin/env bash
# Tests for hooks/schema-deploy-gate.sh (ADR-007 #1).
# Covers: MCP apply tools, execute_sql DDL vs read, Bash apply/deploy verbs,
# deny-in-workflow vs ask-on-main-thread, read-only no-trip, Tier gating, off.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/schema-deploy-gate.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/config"
# Point lib + approval-gates resolution at the real repo.
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

make_repo() {
  local dir="$1" tier="${2:-2}" extra="${3:-}"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null || true
  local json="{\"stack_tier\":$tier,\"stack_version\":\"1.0.0\",\"purpose\":\"test\",\"created\":\"2026-01-01\""
  [[ -n "$extra" ]] && json="$json,$extra"
  json="$json}"
  echo "$json" > "$dir/.claude/stack-config.json"
}

# A main-thread transcript path (no /workflows/ segment) and a workflow one.
MAIN_TP="$HOME/.claude/projects/proj/sess.jsonl"
WF_TP="$HOME/.claude/projects/proj/sess/workflows/wf_abc.json"

# run_mcp <cwd> <tool_name> <tool_input_json> <transcript_path>
run_mcp() {
  jq -nc --arg c "$1" --arg t "$2" --argjson ti "$3" --arg tp "$4" \
    '{cwd:$c, tool_name:$t, tool_input:$ti, transcript_path:$tp}' | bash "$HOOK" 2>/dev/null
}
# run_bash <cwd> <command> <transcript_path>
run_bash() {
  jq -nc --arg c "$1" --arg cmd "$2" --arg tp "$3" \
    '{cwd:$c, tool_name:"Bash", tool_input:{command:$cmd}, transcript_path:$tp}' | bash "$HOOK" 2>/dev/null
}

decision_is() { echo "$1" | jq -e --arg d "$2" '.hookSpecificOutput.permissionDecision == $d' >/dev/null 2>&1; }

REPO="$TMP/repo"; make_repo "$REPO" 2
SREF="mcp__b01e2e70-5f54-4546-b543-7afe8050aed4__"

# ─── A: apply_migration ───────────────────────────────────────────────────────
OUT=$(run_mcp "$REPO" "${SREF}apply_migration" '{"name":"x","query":"create table t(id int)"}' "$MAIN_TP")
decision_is "$OUT" "ask" && pass "A1: apply_migration on main thread -> ask" || fail "A1: got $OUT"

OUT=$(run_mcp "$REPO" "${SREF}apply_migration" '{"name":"x","query":"create table t(id int)"}' "$WF_TP")
decision_is "$OUT" "deny" && pass "A2: apply_migration inside workflow -> deny" || fail "A2: got $OUT"

# ─── B: execute_sql — DDL gated, plain read NOT gated ─────────────────────────
OUT=$(run_mcp "$REPO" "${SREF}execute_sql" '{"query":"alter table users add column x int"}' "$MAIN_TP")
decision_is "$OUT" "ask" && pass "B1: execute_sql DDL on main -> ask" || fail "B1: got $OUT"

OUT=$(run_mcp "$REPO" "${SREF}execute_sql" '{"query":"alter table users add column x int"}' "$WF_TP")
decision_is "$OUT" "deny" && pass "B2: execute_sql DDL in workflow -> deny" || fail "B2: got $OUT"

OUT=$(run_mcp "$REPO" "${SREF}execute_sql" '{"query":"select * from users where id = 1"}' "$WF_TP")
[[ -z "$OUT" ]] && pass "B3: execute_sql SELECT -> no trip (read)" || fail "B3: expected empty; got $OUT"

OUT=$(run_mcp "$REPO" "${SREF}execute_sql" '{"query":"grant select on users to app"}' "$WF_TP")
decision_is "$OUT" "deny" && pass "B4: execute_sql GRANT in workflow -> deny" || fail "B4: got $OUT"

# ─── C: deploy_edge_function ──────────────────────────────────────────────────
OUT=$(run_mcp "$REPO" "${SREF}deploy_edge_function" '{"name":"fn"}' "$MAIN_TP")
decision_is "$OUT" "ask" && pass "C1: deploy_edge_function on main -> ask" || fail "C1: got $OUT"
OUT=$(run_mcp "$REPO" "${SREF}deploy_edge_function" '{"name":"fn"}' "$WF_TP")
decision_is "$OUT" "deny" && pass "C2: deploy_edge_function in workflow -> deny" || fail "C2: got $OUT"

# ─── D: non-gated MCP read tools -> no trip ──────────────────────────────────
OUT=$(run_mcp "$REPO" "${SREF}list_migrations" '{}' "$WF_TP")
[[ -z "$OUT" ]] && pass "D1: list_migrations -> no trip" || fail "D1: expected empty; got $OUT"
OUT=$(run_mcp "$REPO" "${SREF}list_tables" '{}' "$MAIN_TP")
[[ -z "$OUT" ]] && pass "D2: list_tables -> no trip" || fail "D2: expected empty; got $OUT"

# ─── E: Bash schema-apply verbs ───────────────────────────────────────────────
for cmd in \
  "npx tsx scripts/apply-public-viewer.owner.ts" \
  "apply-migration-0011" \
  "supabase db push" \
  "supabase migration up" \
  "psql \"\$DB\" -f migrations/0012.sql"; do
  OUT=$(run_bash "$REPO" "$cmd" "$MAIN_TP")
  decision_is "$OUT" "ask" && pass "E(main): '$cmd' -> ask" || fail "E(main): '$cmd' got $OUT"
  OUT=$(run_bash "$REPO" "$cmd" "$WF_TP")
  decision_is "$OUT" "deny" && pass "E(wf): '$cmd' -> deny" || fail "E(wf): '$cmd' got $OUT"
done

# ─── F: Bash deploy verbs ─────────────────────────────────────────────────────
for cmd in "netlify deploy --prod" "vercel deploy --prod" "supabase functions deploy fn"; do
  OUT=$(run_bash "$REPO" "$cmd" "$WF_TP")
  decision_is "$OUT" "deny" && pass "F(wf): '$cmd' -> deny" || fail "F(wf): '$cmd' got $OUT"
done

# ─── G: Bash reads / safe commands -> no trip ────────────────────────────────
for cmd in \
  "cat migrations/0012.sql" \
  "psql \"\$DB\" -c 'select count(*) from users'" \
  "ls migrations/" \
  "supabase migration list" \
  "git status"; do
  OUT=$(run_bash "$REPO" "$cmd" "$WF_TP")
  [[ -z "$OUT" ]] && pass "G: read/safe '$cmd' -> no trip" || fail "G: '$cmd' falsely tripped: $OUT"
done

# ─── H: gating — Tier<2, no-stack, off-switch ────────────────────────────────
REPO1="$TMP/repo-t1"; make_repo "$REPO1" 1
OUT=$(run_mcp "$REPO1" "${SREF}apply_migration" '{"query":"create table t(id int)"}' "$MAIN_TP")
[[ -z "$OUT" ]] && pass "H1: Tier 1 -> no trip" || fail "H1: tier1 tripped: $OUT"

REPO_NS="$TMP/repo-nostack"; mkdir -p "$REPO_NS"; git -C "$REPO_NS" init -q 2>/dev/null || true
OUT=$(run_mcp "$REPO_NS" "${SREF}apply_migration" '{"query":"create table t(id int)"}' "$MAIN_TP")
[[ -z "$OUT" ]] && pass "H2: no stack-config -> no trip" || fail "H2: nostack tripped: $OUT"

REPO_OFF="$TMP/repo-off"; make_repo "$REPO_OFF" 2 '"schema_deploy_gate":"off"'
OUT=$(run_mcp "$REPO_OFF" "${SREF}apply_migration" '{"query":"create table t(id int)"}' "$WF_TP")
[[ -z "$OUT" ]] && pass "H3: off-switch -> no trip" || fail "H3: off tripped: $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
