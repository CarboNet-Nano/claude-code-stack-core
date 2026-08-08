#!/usr/bin/env bash
# Regression suite for the ADR-018 native-settings-edit security contract.
# Each case asserts an exit code and/or a file effect against a temp fixture.
# The whole point of the writer is that REFUSALS are the success path for the
# dangerous inputs — so most cases assert rc=2 (refused).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$REPO_ROOT/skills/native-settings-edit/native_settings_edit.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$PY" ]] || { echo "FAIL: writer not found at $PY"; exit 1; }

PASS=0
FAIL=0
WORK=""

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/.claude"
  cat > "$WORK/.claude/settings.json" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "sonnet",
  "enabledPlugins": { "superpowers@anthropic": true },
  "mcpServers": { "supabase": { "command": "npx", "args": ["-y", "x"], "disabled": false } },
  "hooks": { "PreToolUse": [] },
  "env": { "SECRET_TOKEN": "shhh" },
  "permissions": { "allow": ["Bash"] }
}
EOF
}

teardown() { [[ -n "$WORK" ]] && rm -rf "$WORK"; WORK=""; }

# assert_rc <expected-rc> <description> -- <args...>
assert_rc() {
  local want="$1" desc="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local out rc
  out="$(python3 "$PY" "$@" --repo-root "$WORK" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (want rc=$want got rc=$rc)"
    echo "      out: $out"
  fi
}

# assert_contains <needle> <description> -- <args...>  (asserts settings.json content)
json_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d.get(sys.argv[2])))' "$WORK/.claude/settings.json" "$1"; }

echo "== native-settings-edit contract suite =="

# --- happy paths -----------------------------------------------------------
setup
assert_rc 0 "valid model preset write"            -- --path /model --value opus
[[ "$(json_get model)" == '"opus"' ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: model not written"; }
# siblings preserved (C1 set-at-path): env/hooks/permissions untouched
[[ "$(json_get env)" == '{"SECRET_TOKEN": "shhh"}' ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: env sibling mutated"; }
[[ -f "$WORK/.claude/settings.json.tmp" ]] && { FAIL=$((FAIL+1)); echo "FAIL: leftover .tmp"; } || PASS=$((PASS+1))
teardown

setup
assert_rc 0 "disable existing mcp server"         -- --path /mcpServers/supabase/disabled --value true
[[ "$(json_get mcpServers)" == *'"disabled": true'* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: mcp disabled not set"; }
# command/args of that server untouched
[[ "$(json_get mcpServers)" == *'"command": "npx"'* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: mcp command mutated"; }
teardown

setup
assert_rc 0 "toggle existing plugin"              -- --path '/enabledPlugins/superpowers@anthropic' --value false
teardown

setup
assert_rc 0 "statusLine audited preset"           -- --path /statusLine --value minimal
teardown

setup
assert_rc 0 "dry-run writes nothing"              -- --path /model --value opus --dry-run
[[ "$(json_get model)" == '"sonnet"' ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: dry-run mutated file"; }
teardown

setup
assert_rc 0 "unknown output style => diff-only (no write)" -- --path /outputStyle --value Nonexistent12345
[[ "$(json_get outputStyle)" == 'null' ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: unknown style was written"; }
teardown

# --- refusals: denylist (M1) ----------------------------------------------
setup
assert_rc 2 "deny hooks path"            -- --path /hooks/PreToolUse --value true
assert_rc 2 "deny env path"              -- --path /env/SECRET_TOKEN --value x
assert_rc 2 "deny permissions path"      -- --path /permissions/allow --value x
assert_rc 2 "deny mcp command leaf"      -- --path /mcpServers/supabase/command --value evil
assert_rc 2 "deny mcp args leaf"         -- --path /mcpServers/supabase/args --value evil
assert_rc 2 "deny mcp env leaf"          -- --path /mcpServers/supabase/env --value evil
teardown

# --- refusals: allowlist / shape ------------------------------------------
setup
assert_rc 2 "non-allowlisted top key"    -- --path /apiKeyHelper --value x
assert_rc 2 "non-allowlisted nested"     -- --path /enabledPlugins/a/b --value true
assert_rc 2 "bare key non-pointer"       -- --path model --value opus
assert_rc 2 "relative segment .."        -- --path /enabledPlugins/../env --value x
teardown

# --- refusals: value schema (C1, C3, L1) ----------------------------------
setup
assert_rc 2 "object value for scalar"    -- --path /model --value '{"x":1}'
assert_rc 2 "array value for scalar"     -- --path /model --value '["x"]'
assert_rc 2 "statusLine object refused"  -- --path /statusLine --value '{"type":"command","command":"rm -rf /"}'
assert_rc 2 "model not in presets"       -- --path /model --value gpt-9
assert_rc 2 "statusLine unknown preset"  -- --path /statusLine --value sneaky
assert_rc 2 "bool field string False"    -- --path '/enabledPlugins/superpowers@anthropic' --value False
assert_rc 2 "bool field quoted false"    -- --path '/enabledPlugins/superpowers@anthropic' --value '"false"'
assert_rc 2 "bool field numeric 0"       -- --path '/enabledPlugins/superpowers@anthropic' --value 0
assert_rc 2 "bool field whitespace"      -- --path '/enabledPlugins/superpowers@anthropic' --value ' true '
teardown

# --- refusals: create-key (item 11) ---------------------------------------
setup
assert_rc 2 "won't create plugin key"    -- --path /enabledPlugins/brand-new --value true
assert_rc 2 "won't create mcp server"    -- --path /mcpServers/ghost/disabled --value true
teardown

# --- refusals: scope gate (M2) --------------------------------------------
setup
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR/.claude"
echo '{"model":"sonnet"}' > "$HOMEDIR/.claude/settings.json"
out="$(CLAUDE_SETTINGS_HOME="$HOMEDIR" python3 "$PY" --path /model --value opus --scope user 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: user scope without --confirm-global (rc=$rc)"; }
out="$(CLAUDE_SETTINGS_HOME="$HOMEDIR" python3 "$PY" --path /model --value opus --scope user --confirm-global 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: user scope with --confirm-global should write (rc=$rc)"; }
teardown

# finding #1: project scope whose --repo-root resolves to the user-global dir
# must ALSO require --confirm-global (no blast-radius bypass).
setup
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR/.claude"
echo '{"model":"sonnet"}' > "$HOMEDIR/.claude/settings.json"
out="$(CLAUDE_SETTINGS_HOME="$HOMEDIR" python3 "$PY" --path /model --value opus --scope project --repo-root "$HOMEDIR" 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: project scope -> user-global must refuse w/o --confirm-global (rc=$rc)"; }
mv="$(python3 -c 'import json;print(json.load(open("'"$HOMEDIR"'/.claude/settings.json"))["model"])')"
[[ "$mv" == "sonnet" ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: user-global mutated via project-scope bypass (model=$mv)"; }
# with --confirm-global it is allowed
out="$(CLAUDE_SETTINGS_HOME="$HOMEDIR" python3 "$PY" --path /model --value opus --scope project --repo-root "$HOMEDIR" --confirm-global 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: project->user-global with --confirm-global should write (rc=$rc)"; }
teardown

# --- refusals: cloud gate (H4) --------------------------------------------
setup
out="$(CLAUDE_CODE_REMOTE=true python3 "$PY" --path /model --value opus --repo-root "$WORK" 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: cloud write not refused (rc=$rc)"; }
# but dry-run is allowed in cloud
out="$(CLAUDE_CODE_REMOTE=true python3 "$PY" --path /model --value opus --repo-root "$WORK" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: cloud dry-run should be allowed (rc=$rc)"; }
teardown

# --- sanitized errors (M4): never echo file content -----------------------
setup
echo 'not json {{{' > "$WORK/.claude/settings.json"
out="$(python3 "$PY" --path /model --value opus --repo-root "$WORK" 2>&1)"; rc=$?
[[ "$rc" == 3 ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: bad JSON should rc=3 (got $rc)"; }
[[ "$out" != *"{{{"* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: error echoed raw file content"; }
teardown

# --- symlink attacks on tmp/lock (security-auditor findings #1, #2) --------
# A hostile project .claude/ pre-plants settings.json.tmp / .lock as symlinks
# to a victim file. The write must NOT follow them.
setup
SENT="$WORK/victim.json"; echo '{"victim":"intact"}' > "$SENT"
ln -sf "$SENT" "$WORK/.claude/settings.json.tmp"
out="$(python3 "$PY" --path /model --value opus --repo-root "$WORK" 2>&1)"; rc=$?
# mkstemp ignores the planted .tmp -> legit write still lands on the real file
[[ "$(json_get model)" == '"opus"' ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: write did not land with planted .tmp symlink (rc=$rc)"; }
[[ "$(cat "$SENT")" == *intact* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: .tmp symlink was followed -> victim overwritten"; }
teardown

setup
SENT="$WORK/victim.json"; echo '{"victim":"intact"}' > "$SENT"
ln -sf "$SENT" "$WORK/.claude/settings.json.lock"
out="$(python3 "$PY" --path /model --value opus --repo-root "$WORK" 2>&1)"; rc=$?
# O_NOFOLLOW refuses the planted .lock symlink; victim must be byte-intact
[[ "$(cat "$SENT")" == *intact* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: .lock symlink was followed -> victim truncated/overwritten"; }
teardown

# --- statusLine preset AUDIT invariant (item 4) ---------------------------
# No audited preset command may reference a user-writable path.
audit="$(python3 - "$PY" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'STATUSLINE_PRESETS\s*=\s*\{(.*?)\n\}', src, re.DOTALL)
blob = m.group(1) if m else ""
bad = [t for t in ("$HOME", ".claude", "/tmp", "/Users/", "/home/") if t in blob]
print("BAD:" + ",".join(bad) if bad else "OK")
PYEOF
)"
[[ "$audit" == "OK" ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: statusLine preset audit: $audit"; }

echo "----------------------------------------"
echo "native-settings-edit: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] && exit 0 || exit 1
