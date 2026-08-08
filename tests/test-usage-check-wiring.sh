#!/usr/bin/env bash
# Confirms the usage-check hooks are actually registered where the stack
# expects them to be, so a tier-manifest install/update actually wires them.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

jq -e '[.hooks.PostToolUse[]? | select(.matcher=="Bash") | .hooks[]? | select(.command | test("usage-check-token.sh"))] | length >= 1' "$REPO_ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && pass "usage-check-token.sh registered on PostToolUse[Bash]" || fail "minting hook not registered in hooks.json"

jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Agent") | .hooks[]? | select(.command | test("usage-check-gate.sh"))] | length >= 1' "$REPO_ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && pass "usage-check-gate.sh registered on PreToolUse[Agent]" || fail "gate hook not registered on Agent matcher"

jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Task") | .hooks[]? | select(.command | test("usage-check-gate.sh"))] | length >= 1' "$REPO_ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && pass "usage-check-gate.sh registered on PreToolUse[Task]" || fail "gate hook not registered on Task matcher"

jq -e '.permissions.deny[] | select(. == "Edit(~/.claude/usage-check/**)")' "$REPO_ROOT/config/settings.global.template.json" >/dev/null 2>&1 \
  && pass "Edit deny rule present for usage-check token directory" || fail "Edit deny rule missing"
# No Write(...) rule: Claude Code matches file-permission rules on Edit() only,
# so a Write() entry is inert and only produces a startup warning.
jq -e '[.permissions.deny[] | select(. == "Write(~/.claude/usage-check/**)")] | length == 0' "$REPO_ROOT/config/settings.global.template.json" >/dev/null 2>&1 \
  && pass "no inert Write deny rule" || fail "inert Write deny rule present"

echo
echo "usage-check (wiring): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
