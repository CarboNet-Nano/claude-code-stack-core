#!/usr/bin/env bash
# Regression suite for design-gate.sh approved_paths glob normalization
# (docs/superpowers/specs/design-gate-glob-normalization.md).
#
# Covers the two silent never-match traps from the SpecOps 2026-07-12 session:
# bare relative globs vs absolute paths, and "[deviceId]"-style bracket
# segments parsed as char classes — plus the (dashboard) route-group case,
# back-compat, the scoped denial diagnostic, and the char-class opt-in.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$REPO_ROOT/hooks/design-gate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$GATE" ]] || { echo "FAIL: design-gate.sh not found at $GATE"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_tmp_home="$(mktemp -d)" || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$_tmp_home"' EXIT
export HOME="$_tmp_home"
unset CLAUDE_CODE_SESSION_ID LOOP_STATE_FILE 2>/dev/null || true

SS="$HOME/.claude/session-state"; mkdir -p "$SS"
MK="$SS/design-approved.json"
run_gate() { CLAUDE_ULTRACODE=1 LOOP_STATE_DIR="$SS" bash "$GATE" <<< "$1"; }
payload() { jq -nc --arg fp "$1" '{tool_input:{file_path:$fp}}'; }
allows() { [[ -z "$(run_gate "$(payload "$1")")" ]]; }
denies() { run_gate "$(payload "$1")" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

REPO="/Users/someone/Code/specops"

# 1. bare relative glob matches the absolute path hooks receive
echo '{"active":true,"approved_paths":["lib/data/readings.ts"]}' > "$MK"
allows "$REPO/lib/data/readings.ts" && ok "bare relative glob matches absolute path" || bad "bare relative glob"

# 2. **-prefixed glob still matches (the old documented workaround)
echo '{"active":true,"approved_paths":["**/lib/data/*.ts"]}' > "$MK"
allows "$REPO/lib/data/readings.ts" && ok "**-prefixed glob matches" || bad "**-prefixed glob"

# 3. bracketed Next.js segment matched literally, not as a char class
echo '{"active":true,"approved_paths":["app/sites/[deviceId]/page.tsx"]}' > "$MK"
allows "$REPO/app/sites/[deviceId]/page.tsx" && ok "[deviceId] segment matches literally" || bad "[deviceId] literal"
denies "$REPO/app/sites/d/page.tsx" && ok "[deviceId] does not act as a char class" || bad "[deviceId] still a char class"

# 4. parenthesized route group
echo '{"active":true,"approved_paths":["app/(dashboard)/raw/page.tsx"]}' > "$MK"
allows "$REPO/app/(dashboard)/raw/page.tsx" && ok "(dashboard) route group matches" || bad "(dashboard) group"

# 5. combined: route group + dynamic segment + ** prefix
echo '{"active":true,"approved_paths":["**/app/(dashboard)/sites/[deviceId]/*.tsx"]}' > "$MK"
allows "$REPO/app/(dashboard)/sites/[deviceId]/page.tsx" && ok "combined group+segment glob matches" || bad "combined glob"

# 6. back-compat: relative file path still matches a relative glob as written
echo '{"active":true,"approved_paths":["skills/foo/**"]}' > "$MK"
allows "skills/foo/bar.sh" && ok "relative path vs relative glob (back-compat)" || bad "relative back-compat"

# 7. non-covered file still denied, with a scoped diagnostic naming target + globs
echo '{"active":true,"approved_paths":["lib/data/readings.ts"]}' > "$MK"
out="$(run_gate "$(payload "$REPO/lib/other/secret.ts")")"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "uncovered file denied" || bad "uncovered file not denied: $out"
reason="$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
[[ "$reason" == *"lib/other/secret.ts"* && "$reason" == *"lib/data/readings.ts"* ]] \
  && ok "denial names target and tried globs" || bad "denial diagnostic missing: $reason"

# 8. glob_char_classes opt-in restores raw char-class matching
echo '{"active":true,"approved_paths":["lib/v[12]/api.ts"],"glob_char_classes":true}' > "$MK"
allows "$REPO/lib/v1/api.ts" && ok "opt-in: char class matches v1" || bad "opt-in char class"
denies "$REPO/lib/v[12]/api.ts" && ok "opt-in: literal brackets no longer match" || bad "opt-in literal"

# 9. opt-in near-miss hint: bracketed glob that would match literally is named
echo '{"active":true,"approved_paths":["app/sites/[deviceId]/page.tsx"],"glob_char_classes":true}' > "$MK"
out="$(run_gate "$(payload "$REPO/app/sites/[deviceId]/page.tsx")")"
reason="$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
[[ "$reason" == *"Near miss"* && "$reason" == *"[deviceId]"* ]] \
  && ok "near-miss hint names the almost-matching glob" || bad "near-miss hint missing: $reason"

rm -f "$MK"
echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
