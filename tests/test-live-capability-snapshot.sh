#!/usr/bin/env bash
# Tests for hooks/live-capability-snapshot.sh
# (docs/ADRs/043-capability-registry-hooks-and-live-state.md, D7-D13 + the
# "hooks/live-capability-snapshot.sh -- new" interface contract + field-
# derivation table).
#
# Every case runs with HOME pointed at a synthetic fixture dir built under a
# temp dir -- NEVER the real ~/.claude. That is the load-bearing property of
# D13 (scope containment) and is checked directly in case L09.
#
# Written against the ADR's WRITTEN interface contract only:
#   - no-arg: write ~/.claude/session-state/live-capabilities.json silently,
#     ALWAYS exit 0 (fail-safe: any error leaves any existing file untouched).
#   - --print: write nothing, print the JSON to stdout.
#   - never writes ~/.claude/settings.json.
#   - atomic write: temp file in the destination dir, then mv over the dest.
# hooks/live-capability-snapshot.sh does not exist in this worktree yet (an
# implementer is writing it in the main checkout in parallel). This suite is
# expected to fail wholesale until both pieces land together -- that is
# expected per the task brief, not a bug in this file. `bash -n` on THIS file
# must still pass.
#
# Case-to-ADR-bullet map (ADR-043, "tests/test-live-capability-snapshot.sh"
# section of the Test plan, bullets in document order):
#   L01     -> bullet  1  Leakage (the load-bearing case): none of the planted
#                         secrets (headers/.env/.args/.command/URL query) leak.
#   L02     -> bullet  2  URL with userinfo+path+query -> host is exactly the
#                         host, nothing else survives.
#   L03a-e  -> bullet  3  disabled handling: true->absent, false->present,
#                         absent-key->present, string "true"->present+exit0,
#                         "disabled" never appears as an output field anywhere.
#   L04     -> bullet  4  Enablement asymmetry: no enabledPlugins entry ->
#                         absent, even with a full installed_plugins.json
#                         record; no `disabled` key -> present. Same fixture.
#   L05     -> bullet  5  enabledPlugins = false -> plugin absent (opt-in
#                         side), even with a full installed record.
#   L06     -> bullet  6  Plugin with no installed_plugins.json record ->
#                         version:null, exit 0.
#   L07     -> bullet  7  Plugin whose installPath has no plugin.json ->
#                         summary:null, exit 0 (version still resolves).
#   L08     -> bullet  8  Containment (D8a): installPath outside
#                         $HOME/.claude/plugins/ -> summary:null AND the
#                         external plugin.json's sentinel is never read.
#   L08x    -> EXTRA (not a named bullet, added per D8a's realpath rule): an
#                         installPath that is nominally under
#                         $HOME/.claude/plugins/ but is a symlink resolving
#                         outside it -> same rejection. This is where the
#                         containment rule (realpath, not string-prefix) has
#                         actual teeth.
#   L09a/b  -> bullet  9  Scope containment (D13): static check that the
#                         script hardcodes no absolute path outside $HOME;
#                         runtime check with an EMPTY HOME fixture while the
#                         real ~/.claude on the test machine is populated.
#   L10     -> bullet 10  Output always has "scope":"user".
#   L11a/b  -> bullet 11  Missing ~/.claude/settings.json entirely -> empty
#                         arrays + exit 0 (via --print); a pre-existing
#                         snapshot is left untouched (via the no-arg form).
#   L12a/b  -> bullet 12  Malformed JSON in settings.json / installed_plugins.json
#                         -> exit 0, any existing snapshot untouched.
#   L13a-c  -> bullet 13  Atomicity (D13): temp file lands in the destination
#                         directory (mv-shim, best-effort/mechanism-specific);
#                         inode changes on a successful run (mechanism-
#                         agnostic proof of rename, not in-place rewrite); a
#                         forced mid-run failure leaves the previous file
#                         byte-identical (bytes AND inode).
#   L14a/b  -> bullet 14  --print writes no file (dest absent, and dest
#                         present-but-untouched) and emits valid JSON.
#   L15     -> bullet 15  ~/.claude/settings.json is byte-identical after
#                         every run (dedicated case; also checked inline
#                         after most other runs via assert_untouched).
#   L16a-c  -> bullet 16  mcp_servers sorted by name; plugins sorted by id
#                         (+ name/marketplace split); remote:true iff
#                         transport is http or sse (+ the "absent type but
#                         command present -> stdio" derivation rule).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="$REPO_ROOT/hooks/live-capability-snapshot.sh"
REAL_HOME="$HOME"

[[ -f "$SNAP" ]] || echo "NOTE: $SNAP does not exist yet (ADR-043 Part 2) -- cases below are expected to fail until it lands."

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2 | actual: $3)"; fi
}
assert_rc() {
  # assert_rc <label> <expected-rc> <actual-rc>
  if [[ "$3" -eq "$2" ]]; then pass "$1"; else fail "$1 (expected rc=$2, got rc=$3)"; fi
}
assert_contains() {
  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in: $2)"; fi
}
assert_not_contains() {
  # assert_not_contains <label> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly found '$3' in: $2)"; fi
}
assert_valid_json() {
  # assert_valid_json <label> <json-text>
  if echo "$2" | jq empty >/dev/null 2>&1; then pass "$1"; else fail "$1 (not valid JSON: $2)"; fi
}

# ─── stat/checksum helpers (mac + linux) ─────────────────────────────────────
inode_of() { stat -c '%i' -- "$1" 2>/dev/null || stat -f '%i' -- "$1" 2>/dev/null; }
checksum_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | awk '{print $1}';
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | awk '{print $1}';
  else md5 -q -- "$1" 2>/dev/null || md5sum -- "$1" | awk '{print $1}'; fi
}

# capture_state <path> -- sets CAP_SUM / CAP_INODE, or "ABSENT" if missing
capture_state() {
  local p="$1"
  if [[ -f "$p" ]]; then CAP_SUM=$(checksum_of "$p"); CAP_INODE=$(inode_of "$p");
  else CAP_SUM="ABSENT"; CAP_INODE="ABSENT"; fi
}
# assert_untouched <label> <path> <expected-sum> <expected-inode>
assert_untouched() {
  local label="$1" p="$2" esum="$3" einode="$4" asum ainode
  if [[ -f "$p" ]]; then asum=$(checksum_of "$p"); ainode=$(inode_of "$p");
  else asum="ABSENT"; ainode="ABSENT"; fi
  if [[ "$asum" == "$esum" && "$ainode" == "$einode" ]]; then
    pass "$label"
  else
    fail "$label (checksum: expected $esum got $asum | inode: expected $einode got $ainode)"
  fi
}

# ─── fixture builders ────────────────────────────────────────────────────────

# mk_home <dir> -- minimal skeleton HOME: .claude/ and .claude/session-state/
# exist (as they would after a tier-0 install), but settings.json and
# plugins/installed_plugins.json are NOT created -- each case writes its own.
mk_home() {
  local dir="$1"
  mkdir -p "$dir/.claude/session-state"
}

snapshot_file() { echo "$1/.claude/session-state/live-capabilities.json"; }

# write_settings <home> <<'EOF' ... EOF  -- helper is just `cat >`, kept as a
# named function so every case reads the same way.
write_settings() { cat > "$1/.claude/settings.json"; }
write_installed_plugins() {
  mkdir -p "$1/.claude/plugins"
  cat > "$1/.claude/plugins/installed_plugins.json"
}

# make_plugin_json <dir> <description> -- writes <dir>/.claude-plugin/plugin.json
make_plugin_json() {
  local dir="$1" description="$2"
  mkdir -p "$dir/.claude-plugin"
  jq -n --arg d "$description" '{"name":"fixture-plugin","description":$d}' > "$dir/.claude-plugin/plugin.json"
}

# ─── invocation helpers -- set OUT / ERR / RC ────────────────────────────────
run_snap() {
  # run_snap <home> -- no-arg mode: write file silently, always exit 0
  local home="$1" errfile; errfile=$(mktemp)
  OUT=$(HOME="$home" bash "$SNAP" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_snap_print() {
  # run_snap_print <home> -- --print mode: write nothing, JSON to stdout
  local home="$1" errfile; errfile=$(mktemp)
  OUT=$(HOME="$home" bash "$SNAP" --print 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_snap_shimmed_path() {
  # run_snap_shimmed_path <home> <path-with-shim-dir-prepended>
  local home="$1" path="$2" errfile; errfile=$(mktemp)
  OUT=$(HOME="$home" PATH="$path" bash "$SNAP" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}

# ══════════════════════════════════════════════════════════════════════════
# L01 (bullet 1): Leakage -- the load-bearing case
# ══════════════════════════════════════════════════════════════════════════
H01="$TMP/h01"; mk_home "$H01"
SENTINEL_HEADER="SENTINEL_HEADER_TOKEN_7a3d"
SENTINEL_QUERY="SENTINEL_QUERY_TOKEN_9f8e"
SENTINEL_COMMAND="SENTINEL_COMMAND_BIN_c412"
SENTINEL_ARGS="SENTINEL_ARGS_VALUE_b501"
SENTINEL_ENV="SENTINEL_ENV_VALUE_e620"
write_settings "$H01" <<EOF
{
  "enabledPlugins": {},
  "mcpServers": {
    "leaky-remote": {
      "type": "http",
      "url": "https://mcp.example.com/v1?token=$SENTINEL_QUERY",
      "headers": { "Authorization": "Bearer $SENTINEL_HEADER" }
    },
    "leaky-local": {
      "command": "$SENTINEL_COMMAND",
      "args": ["--secret", "$SENTINEL_ARGS"],
      "env": { "API_KEY": "$SENTINEL_ENV" }
    }
  }
}
EOF
# Precondition (avoids a vacuous pass from a typo'd fixture): the sentinels
# really are present in the input file before we assert they're absent from
# the output.
FIXTURE_CONTENT="$(cat "$H01/.claude/settings.json")"
assert_contains "L01 precondition: header sentinel present in fixture input" "$FIXTURE_CONTENT" "$SENTINEL_HEADER"
assert_contains "L01 precondition: query sentinel present in fixture input" "$FIXTURE_CONTENT" "$SENTINEL_QUERY"
assert_contains "L01 precondition: command sentinel present in fixture input" "$FIXTURE_CONTENT" "$SENTINEL_COMMAND"
assert_contains "L01 precondition: args sentinel present in fixture input" "$FIXTURE_CONTENT" "$SENTINEL_ARGS"
assert_contains "L01 precondition: env sentinel present in fixture input" "$FIXTURE_CONTENT" "$SENTINEL_ENV"

run_snap_print "$H01"
assert_rc "L01: exit 0" 0 "$RC"
assert_valid_json "L01: output is valid JSON" "$OUT"
assert_not_contains "L01: headers secret does not leak" "$OUT" "$SENTINEL_HEADER"
assert_not_contains "L01: URL query secret does not leak" "$OUT" "$SENTINEL_QUERY"
assert_not_contains "L01: command secret does not leak" "$OUT" "$SENTINEL_COMMAND"
assert_not_contains "L01: args secret does not leak" "$OUT" "$SENTINEL_ARGS"
assert_not_contains "L01: env secret does not leak" "$OUT" "$SENTINEL_ENV"
assert_eq "L01: leaky-remote host is stripped to host only (no query)" "mcp.example.com" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="leaky-remote") | .host')"

# ══════════════════════════════════════════════════════════════════════════
# L02 (bullet 2): URL with userinfo + path + query -> host only
# ══════════════════════════════════════════════════════════════════════════
H02="$TMP/h02"; mk_home "$H02"
SENTINEL_URLCASE="SENTINEL_URLCASE_44de"
write_settings "$H02" <<EOF
{
  "enabledPlugins": {},
  "mcpServers": {
    "stripped-server": {
      "type": "http",
      "url": "https://alice:s3cr3t@sub.example.org/deep/path?tok=$SENTINEL_URLCASE#section"
    }
  }
}
EOF
run_snap_print "$H02"
assert_rc "L02: exit 0" 0 "$RC"
assert_eq "L02: host is exactly the host component" "sub.example.org" \
  "$(echo "$OUT" | jq -r '.mcp_servers[0].host')"
assert_not_contains "L02: userinfo does not survive" "$OUT" "alice"
assert_not_contains "L02: userinfo password does not survive" "$OUT" "s3cr3t"
assert_not_contains "L02: path does not survive" "$OUT" "/deep/path"
assert_not_contains "L02: query does not survive" "$OUT" "$SENTINEL_URLCASE"
assert_not_contains "L02: fragment does not survive" "$OUT" "section"

# ══════════════════════════════════════════════════════════════════════════
# L03 (bullet 3): disabled handling -- opt-out side, all sub-cases in one run
# ══════════════════════════════════════════════════════════════════════════
H03="$TMP/h03"; mk_home "$H03"
write_settings "$H03" <<'EOF'
{
  "enabledPlugins": {},
  "mcpServers": {
    "disabled-true-server":   { "command": "echo1", "disabled": true },
    "disabled-false-server":  { "command": "echo2", "disabled": false },
    "disabled-absent-server": { "command": "echo3" },
    "disabled-string-server": { "command": "echo4", "disabled": "true" }
  }
}
EOF
run_snap_print "$H03"
assert_rc "L03: exit 0 (string 'true' does not fail the run)" 0 "$RC"
NAMES03="$(echo "$OUT" | jq -r '[.mcp_servers[].name] | sort | join(",")')"
assert_eq "L03a: disabled=true -> absent" "0" \
  "$(echo "$OUT" | jq '[.mcp_servers[] | select(.name=="disabled-true-server")] | length')"
assert_eq "L03b: disabled=false -> present" "1" \
  "$(echo "$OUT" | jq '[.mcp_servers[] | select(.name=="disabled-false-server")] | length')"
assert_eq "L03c: no disabled key -> present (absence means enabled)" "1" \
  "$(echo "$OUT" | jq '[.mcp_servers[] | select(.name=="disabled-absent-server")] | length')"
assert_eq "L03d: disabled=\"true\" (string, not boolean) -> present" "1" \
  "$(echo "$OUT" | jq '[.mcp_servers[] | select(.name=="disabled-string-server")] | length')"
assert_eq "L03: exactly the 3 non-true-boolean-disabled servers present" \
  "disabled-absent-server,disabled-false-server,disabled-string-server" "$NAMES03"
assert_eq "L03e: 'disabled' never appears as an output field anywhere" "false" \
  "$(echo "$OUT" | jq '[.. | objects | has("disabled")] | any')"

# ══════════════════════════════════════════════════════════════════════════
# L04 (bullet 4): enablement asymmetry, in one fixture
# ══════════════════════════════════════════════════════════════════════════
H04="$TMP/h04"; mk_home "$H04"
PLUGIN_DIR_04="$H04/.claude/plugins/cache/marketX/phantom-plugin/1.0.0"
make_plugin_json "$PLUGIN_DIR_04" "Would be a full entry if enabled -- proves opt-in, not mere installed-record presence."
write_installed_plugins "$H04" <<EOF
{ "version": 2, "plugins": {
  "phantom-plugin@marketX": [ { "installPath": "$PLUGIN_DIR_04", "version": "1.0.0" } ]
} }
EOF
write_settings "$H04" <<'EOF'
{
  "enabledPlugins": {},
  "mcpServers": { "present-by-default-server": { "command": "echoX" } }
}
EOF
run_snap_print "$H04"
assert_rc "L04: exit 0" 0 "$RC"
assert_eq "L04: plugin with NO enabledPlugins entry is absent, despite a full installed_plugins.json record" \
  "0" "$(echo "$OUT" | jq '.plugins | length')"
assert_eq "L04: MCP server with NO disabled key is present -- proving the rules are opposite" \
  "1" "$(echo "$OUT" | jq '[.mcp_servers[] | select(.name=="present-by-default-server")] | length')"

# ══════════════════════════════════════════════════════════════════════════
# L05 (bullet 5): enabledPlugins = false -> plugin absent (opt-in side)
# ══════════════════════════════════════════════════════════════════════════
H05="$TMP/h05"; mk_home "$H05"
PLUGIN_DIR_05="$H05/.claude/plugins/cache/marketY/opt-out-plugin/1.0.0"
make_plugin_json "$PLUGIN_DIR_05" "Fully installed and would resolve, but explicitly disabled via enabledPlugins=false."
write_installed_plugins "$H05" <<EOF
{ "version": 2, "plugins": {
  "opt-out-plugin@marketY": [ { "installPath": "$PLUGIN_DIR_05", "version": "1.0.0" } ]
} }
EOF
write_settings "$H05" <<'EOF'
{ "enabledPlugins": { "opt-out-plugin@marketY": false }, "mcpServers": {} }
EOF
run_snap_print "$H05"
assert_rc "L05: exit 0" 0 "$RC"
assert_eq "L05: enabledPlugins=false -> plugin absent even though fully installed" \
  "0" "$(echo "$OUT" | jq '[.plugins[] | select(.id=="opt-out-plugin@marketY")] | length')"

# ══════════════════════════════════════════════════════════════════════════
# L06 (bullet 6): plugin enabled but no installed_plugins.json record -> version:null
# ══════════════════════════════════════════════════════════════════════════
H06="$TMP/h06"; mk_home "$H06"
write_installed_plugins "$H06" <<'EOF'
{ "version": 2, "plugins": {} }
EOF
write_settings "$H06" <<'EOF'
{ "enabledPlugins": { "orphan-record-plugin@marketZ": true }, "mcpServers": {} }
EOF
run_snap_print "$H06"
assert_rc "L06: exit 0" 0 "$RC"
assert_eq "L06: plugin still present (enabled)" "1" \
  "$(echo "$OUT" | jq '[.plugins[] | select(.id=="orphan-record-plugin@marketZ")] | length')"
assert_eq "L06: version is null with no installed_plugins.json record" "null" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="orphan-record-plugin@marketZ") | .version')"

# ══════════════════════════════════════════════════════════════════════════
# L07 (bullet 7): installPath has no plugin.json -> summary:null (version still resolves)
# ══════════════════════════════════════════════════════════════════════════
H07="$TMP/h07"; mk_home "$H07"
PLUGIN_DIR_07="$H07/.claude/plugins/cache/marketA/no-plugin-json/1.0.0"
mkdir -p "$PLUGIN_DIR_07"   # deliberately: no .claude-plugin/plugin.json inside
write_installed_plugins "$H07" <<EOF
{ "version": 2, "plugins": {
  "no-plugin-json@marketA": [ { "installPath": "$PLUGIN_DIR_07", "version": "2.3.4" } ]
} }
EOF
write_settings "$H07" <<'EOF'
{ "enabledPlugins": { "no-plugin-json@marketA": true }, "mcpServers": {} }
EOF
run_snap_print "$H07"
assert_rc "L07: exit 0" 0 "$RC"
assert_eq "L07: version still resolves from installed_plugins.json" "2.3.4" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="no-plugin-json@marketA") | .version')"
assert_eq "L07: summary is null when installPath has no plugin.json" "null" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="no-plugin-json@marketA") | .summary')"

# ══════════════════════════════════════════════════════════════════════════
# L08 (bullet 8): containment (D8a) -- installPath outside $HOME/.claude/plugins/
# ══════════════════════════════════════════════════════════════════════════
H08="$TMP/h08"; mk_home "$H08"
OUTSIDE_DIR_08="$TMP/outside-home-08/evil-plugin"
SENTINEL_CONTAINMENT="SENTINEL_CONTAINMENT_LEAK_d91a"
make_plugin_json "$OUTSIDE_DIR_08" "$SENTINEL_CONTAINMENT -- should never be read."
# Precondition: the sentinel really is sitting in the external plugin.json.
assert_contains "L08 precondition: sentinel present in the external plugin.json" \
  "$(cat "$OUTSIDE_DIR_08/.claude-plugin/plugin.json")" "$SENTINEL_CONTAINMENT"
write_installed_plugins "$H08" <<EOF
{ "version": 2, "plugins": {
  "outside-plugin@marketB": [ { "installPath": "$OUTSIDE_DIR_08", "version": "9.9.9" } ]
} }
EOF
write_settings "$H08" <<'EOF'
{ "enabledPlugins": { "outside-plugin@marketB": true }, "mcpServers": {} }
EOF
run_snap_print "$H08"
assert_rc "L08: exit 0" 0 "$RC"
assert_eq "L08: summary is null -- installPath outside \$HOME/.claude/plugins/ is rejected" "null" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="outside-plugin@marketB") | .summary')"
assert_not_contains "L08: the external plugin.json's sentinel was never read into output" "$OUT" "$SENTINEL_CONTAINMENT"

# ── L08x (EXTRA, not a named bullet): installPath nominally under
# $HOME/.claude/plugins/ but is a symlink resolving OUTSIDE it -- this is the
# case where D8a's "realpath resolves under" wording (not a string-prefix
# check) actually has teeth.
H08X="$TMP/h08x"; mk_home "$H08X"
REAL_TARGET_08X="$TMP/outside-home-08x/real-target"
SENTINEL_SYMLINK="SENTINEL_SYMLINK_ESCAPE_44aa"
make_plugin_json "$REAL_TARGET_08X" "$SENTINEL_SYMLINK -- reached only via a symlink escaping the plugins dir."
assert_contains "L08x precondition: sentinel present at the symlink target" \
  "$(cat "$REAL_TARGET_08X/.claude-plugin/plugin.json")" "$SENTINEL_SYMLINK"
SYMLINK_INSTALLPATH_08X="$H08X/.claude/plugins/cache/marketC/symlink-escape-plugin/1.0.0"
mkdir -p "$(dirname "$SYMLINK_INSTALLPATH_08X")"
ln -s "$REAL_TARGET_08X" "$SYMLINK_INSTALLPATH_08X"
write_installed_plugins "$H08X" <<EOF
{ "version": 2, "plugins": {
  "symlink-escape-plugin@marketC": [ { "installPath": "$SYMLINK_INSTALLPATH_08X", "version": "1.0.0" } ]
} }
EOF
write_settings "$H08X" <<'EOF'
{ "enabledPlugins": { "symlink-escape-plugin@marketC": true }, "mcpServers": {} }
EOF
run_snap_print "$H08X"
assert_rc "L08x: exit 0" 0 "$RC"
assert_eq "L08x: summary null -- installPath is a symlink escaping \$HOME/.claude/plugins/ via realpath" "null" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="symlink-escape-plugin@marketC") | .summary')"
assert_not_contains "L08x: the symlink target's sentinel was never read into output" "$OUT" "$SENTINEL_SYMLINK"

# ══════════════════════════════════════════════════════════════════════════
# L09 (bullet 9): scope containment (D13) -- static + runtime
# ══════════════════════════════════════════════════════════════════════════
# L09a: static -- the script hardcodes no absolute path literal outside
# $HOME. Written tolerant of variable indirection (e.g. CLAUDE_DIR="$HOME/.claude"
# then "$CLAUDE_DIR/settings.json") -- it checks for LITERAL absolute-path
# prefixes typical of a real machine's filesystem root, not for the string
# "$HOME/.claude" appearing verbatim on every line. Comment-only lines are
# excluded so ADR-quoting prose doesn't trip it.
if [[ -f "$SNAP" ]]; then
  HARDCODED_HITS="$(grep -E '/Users/|/home/|/tmp/|/var/|/etc/|/root/' "$SNAP" | grep -v '^[[:space:]]*#' || true)"
  if [[ -z "$HARDCODED_HITS" ]]; then
    pass "L09a: script hardcodes no absolute path literal outside \$HOME"
  else
    fail "L09a: script hardcodes 1+ absolute path literal(s) outside \$HOME: $HARDCODED_HITS"
  fi
else
  fail "L09a: cannot statically check a script that does not exist yet ($SNAP)"
fi

# L09b: runtime -- with HOME pointed at a genuinely empty fixture (no .claude
# at all), output must be empty arrays, even though the machine's real
# ~/.claude is populated. Precondition per the ADR's own wording ("a real,
# populated ~/.claude exists on the machine") -- if the real environment
# running this suite has no mcpServers/enabledPlugins at all, this specific
# sub-case can't distinguish "reads nothing" from "there was nothing to
# read", so it's skipped rather than passing vacuously.
REAL_SETTINGS="$REAL_HOME/.claude/settings.json"
if [[ -f "$REAL_SETTINGS" ]] && jq -e '((.mcpServers // {}) | length > 0) or ((.enabledPlugins // {}) | length > 0)' "$REAL_SETTINGS" >/dev/null 2>&1; then
  H09B="$TMP/h09b-empty"
  mkdir -p "$H09B"   # deliberately: not even .claude/ exists
  run_snap_print "$H09B"
  assert_rc "L09b: exit 0 against an empty HOME fixture" 0 "$RC"
  assert_eq "L09b: plugins empty despite the real \$HOME being populated" "[]" "$(echo "$OUT" | jq -c '.plugins')"
  assert_eq "L09b: mcp_servers empty despite the real \$HOME being populated" "[]" "$(echo "$OUT" | jq -c '.mcp_servers')"
else
  echo "SKIP: L09b -- the real \$HOME ($REAL_HOME) has no populated ~/.claude/settings.json on this machine, so 'reads nothing' can't be distinguished from 'nothing there to read'"
fi

# ══════════════════════════════════════════════════════════════════════════
# L10 (bullet 10): output always carries "scope":"user"
# ══════════════════════════════════════════════════════════════════════════
run_snap_print "$H01"
assert_eq "L10: scope == user (populated fixture)" "user" "$(echo "$OUT" | jq -r '.scope')"
H10_EMPTY="$TMP/h10-empty"; mkdir -p "$H10_EMPTY"
run_snap_print "$H10_EMPTY"
assert_eq "L10: scope == user (empty fixture, no .claude at all)" "user" "$(echo "$OUT" | jq -r '.scope')"

# ══════════════════════════════════════════════════════════════════════════
# L11 (bullet 11): missing ~/.claude/settings.json entirely
# ══════════════════════════════════════════════════════════════════════════
# L11a: empty arrays + exit 0, checked unambiguously via --print (no write
# side-effect to reason about).
H11="$TMP/h11"; mk_home "$H11"   # .claude/session-state exists; no settings.json
run_snap_print "$H11"
assert_rc "L11a: exit 0 with settings.json entirely missing" 0 "$RC"
assert_eq "L11a: plugins empty" "[]" "$(echo "$OUT" | jq -c '.plugins')"
assert_eq "L11a: mcp_servers empty" "[]" "$(echo "$OUT" | jq -c '.mcp_servers')"

# L11b: any PRE-EXISTING snapshot file is left untouched by the no-arg form,
# same missing-settings.json fixture.
PRIOR_SNAP_11="$(snapshot_file "$H11")"
printf '{"generated_at":"PRIOR","source":"live","scope":"user","plugins":[],"mcp_servers":[]}\n' > "$PRIOR_SNAP_11"
capture_state "$PRIOR_SNAP_11"; PRIOR_SUM_11="$CAP_SUM"; PRIOR_INODE_11="$CAP_INODE"
run_snap "$H11"
assert_rc "L11b: no-arg run still exits 0" 0 "$RC"
assert_untouched "L11b: pre-existing snapshot left untouched when settings.json is missing" \
  "$PRIOR_SNAP_11" "$PRIOR_SUM_11" "$PRIOR_INODE_11"

# ══════════════════════════════════════════════════════════════════════════
# L12 (bullet 12): malformed JSON in either input file
# ══════════════════════════════════════════════════════════════════════════
# L12a: malformed settings.json
H12A="$TMP/h12a"; mk_home "$H12A"
write_settings "$H12A" <<'EOF'
{ this is not valid json,,,
EOF
PRIOR_SNAP_12A="$(snapshot_file "$H12A")"
printf '{"generated_at":"PRIOR-A","source":"live","scope":"user","plugins":[],"mcp_servers":[]}\n' > "$PRIOR_SNAP_12A"
capture_state "$PRIOR_SNAP_12A"; PRIOR_SUM_12A="$CAP_SUM"; PRIOR_INODE_12A="$CAP_INODE"
run_snap "$H12A"
assert_rc "L12a: malformed settings.json -> exit 0" 0 "$RC"
assert_untouched "L12a: malformed settings.json -> pre-existing snapshot untouched" \
  "$PRIOR_SNAP_12A" "$PRIOR_SUM_12A" "$PRIOR_INODE_12A"

# L12b: valid settings.json, malformed installed_plugins.json
H12B="$TMP/h12b"; mk_home "$H12B"
write_settings "$H12B" <<'EOF'
{ "enabledPlugins": { "some-plugin@market": true }, "mcpServers": {} }
EOF
write_installed_plugins "$H12B" <<'EOF'
{ not valid json at all ]]]
EOF
PRIOR_SNAP_12B="$(snapshot_file "$H12B")"
printf '{"generated_at":"PRIOR-B","source":"live","scope":"user","plugins":[],"mcp_servers":[]}\n' > "$PRIOR_SNAP_12B"
capture_state "$PRIOR_SNAP_12B"; PRIOR_SUM_12B="$CAP_SUM"; PRIOR_INODE_12B="$CAP_INODE"
run_snap "$H12B"
assert_rc "L12b: malformed installed_plugins.json -> exit 0" 0 "$RC"
assert_untouched "L12b: malformed installed_plugins.json -> pre-existing snapshot untouched" \
  "$PRIOR_SNAP_12B" "$PRIOR_SUM_12B" "$PRIOR_INODE_12B"

# ══════════════════════════════════════════════════════════════════════════
# L13 (bullet 13): atomicity (D13)
# ══════════════════════════════════════════════════════════════════════════
# L13a: temp file lands in the DESTINATION directory (never /tmp). Mechanism-
# specific and best-effort: shims `mv` via PATH and logs its arguments. A
# correct implementation using a different rename mechanism (os.replace,
# mktemp -p elsewhere, etc.) would not exercise this shim -- see L13b for the
# mechanism-agnostic proof (inode change) that any implementation must satisfy.
H13A="$TMP/h13a"; mk_home "$H13A"
write_settings "$H13A" <<'EOF'
{ "enabledPlugins": {}, "mcpServers": { "svc": { "command": "echo" } } }
EOF
SHIMDIR_13A="$TMP/shim13a"; mkdir -p "$SHIMDIR_13A"
REAL_MV="$(command -v mv)"
MVLOG_13A="$TMP/mvlog13a"; : > "$MVLOG_13A"
cat > "$SHIMDIR_13A/mv" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$MVLOG_13A"
exec "$REAL_MV" "\$@"
EOF
chmod +x "$SHIMDIR_13A/mv"
run_snap_shimmed_path "$H13A" "$SHIMDIR_13A:$PATH"
assert_rc "L13a: exit 0 under the mv shim" 0 "$RC"
if [[ -s "$MVLOG_13A" ]]; then
  LAST_MV_LINE="$(tail -n1 "$MVLOG_13A")"
  read -r -a MV_TOKENS <<< "$LAST_MV_LINE"
  N=${#MV_TOKENS[@]}
  MV_SRC="${MV_TOKENS[$((N-2))]}"
  MV_DEST="${MV_TOKENS[$((N-1))]}"
  DEST_DIR="$H13A/.claude/session-state"
  assert_eq "L13a: mv destination is the real snapshot path" "$(snapshot_file "$H13A")" "$MV_DEST"
  assert_eq "L13a: mv source's directory is the destination directory (temp file staged there, not /tmp)" \
    "$DEST_DIR" "$(dirname "$MV_SRC")"
else
  echo "SKIP: L13a: no 'mv' binary invocation observed (implementation uses a different rename mechanism, e.g. os.replace -- L13b's mechanism-agnostic inode check is the binding proof)"
fi

# L13b: inode changes on a successful run -- mechanism-agnostic proof of
# rename-over-destination, not an in-place truncate+rewrite.
H13B="$TMP/h13b"; mk_home "$H13B"
write_settings "$H13B" <<'EOF'
{ "enabledPlugins": {}, "mcpServers": { "svc": { "command": "echo" } } }
EOF
SNAP_FILE_13B="$(snapshot_file "$H13B")"
printf '{"generated_at":"PRIOR","source":"live","scope":"user","plugins":[],"mcp_servers":[]}\n' > "$SNAP_FILE_13B"
capture_state "$SNAP_FILE_13B"; OLD_INODE_13B="$CAP_INODE"
run_snap "$H13B"
assert_rc "L13b: exit 0" 0 "$RC"
NEW_INODE_13B="$(inode_of "$SNAP_FILE_13B")"
if [[ -n "$NEW_INODE_13B" && "$NEW_INODE_13B" != "$OLD_INODE_13B" ]]; then
  pass "L13b: destination inode changed on a successful run (proves mv/rename, not in-place truncate)"
else
  fail "L13b: destination inode did NOT change (old=$OLD_INODE_13B new=$NEW_INODE_13B) -- suggests in-place rewrite, violating D13"
fi
assert_valid_json "L13b: resulting snapshot file is valid JSON" "$(cat "$SNAP_FILE_13B" 2>/dev/null)"

# L13c: forced mid-run failure leaves the previous file byte-identical
# (bytes AND inode -- proves the destination was never opened at all, not
# merely that its final content happens to match).
H13C="$TMP/h13c"; mk_home "$H13C"
write_settings "$H13C" <<'EOF'
{ "enabledPlugins": {}, "mcpServers": { "svc": { "command": "echo" } } }
EOF
run_snap "$H13C"
assert_rc "L13c: first (good) run exits 0" 0 "$RC"
SNAP_FILE_13C="$(snapshot_file "$H13C")"
capture_state "$SNAP_FILE_13C"; GOOD_SUM_13C="$CAP_SUM"; GOOD_INODE_13C="$CAP_INODE"
if [[ "$GOOD_SUM_13C" == "ABSENT" ]]; then
  fail "L13c: first (good) run did not produce a snapshot file at all -- cannot test the mid-run-failure case"
else
  # Now corrupt the input mid-flight and re-run.
  write_settings "$H13C" <<'EOF'
{ this is now malformed ]]]
EOF
  run_snap "$H13C"
  assert_rc "L13c: second (corrupted-input) run still exits 0" 0 "$RC"
  assert_untouched "L13c: previous snapshot is byte-identical (bytes + inode) after a forced mid-run failure" \
    "$SNAP_FILE_13C" "$GOOD_SUM_13C" "$GOOD_INODE_13C"
fi

# ══════════════════════════════════════════════════════════════════════════
# L14 (bullet 14): --print writes no file, emits valid JSON
# ══════════════════════════════════════════════════════════════════════════
# L14a: destination does not exist beforehand -> --print must not create it.
H14A="$TMP/h14a"; mk_home "$H14A"
write_settings "$H14A" <<'EOF'
{ "enabledPlugins": {}, "mcpServers": {} }
EOF
run_snap_print "$H14A"
assert_rc "L14a: exit 0" 0 "$RC"
assert_valid_json "L14a: stdout is valid JSON" "$OUT"
if [[ -f "$(snapshot_file "$H14A")" ]]; then
  fail "L14a: --print created the destination file when none existed before"
else
  pass "L14a: --print created no file (destination did not exist before or after)"
fi

# L14b: destination DOES exist beforehand -> --print must leave it byte-identical.
H14B="$TMP/h14b"; mk_home "$H14B"
write_settings "$H14B" <<'EOF'
{ "enabledPlugins": {}, "mcpServers": {} }
EOF
SNAP_FILE_14B="$(snapshot_file "$H14B")"
printf '{"generated_at":"PRIOR","source":"live","scope":"user","plugins":[],"mcp_servers":[]}\n' > "$SNAP_FILE_14B"
capture_state "$SNAP_FILE_14B"; PRIOR_SUM_14B="$CAP_SUM"; PRIOR_INODE_14B="$CAP_INODE"
run_snap_print "$H14B"
assert_rc "L14b: exit 0" 0 "$RC"
assert_valid_json "L14b: stdout is still valid JSON" "$OUT"
assert_untouched "L14b: pre-existing destination file untouched by --print" \
  "$SNAP_FILE_14B" "$PRIOR_SUM_14B" "$PRIOR_INODE_14B"

# ══════════════════════════════════════════════════════════════════════════
# L15 (bullet 15): ~/.claude/settings.json is byte-identical after every run
# ══════════════════════════════════════════════════════════════════════════
H15="$TMP/h15"; mk_home "$H15"
write_settings "$H15" <<'EOF'
{ "enabledPlugins": { "some-plugin@market": true }, "mcpServers": { "svc": { "command": "echo" } } }
EOF
SETTINGS_15="$H15/.claude/settings.json"
capture_state "$SETTINGS_15"; SETTINGS_SUM_15="$CAP_SUM"; SETTINGS_INODE_15="$CAP_INODE"
run_snap "$H15"
assert_rc "L15: no-arg run exits 0" 0 "$RC"
assert_untouched "L15: settings.json byte-identical after a no-arg run" \
  "$SETTINGS_15" "$SETTINGS_SUM_15" "$SETTINGS_INODE_15"
run_snap_print "$H15"
assert_rc "L15: --print run exits 0" 0 "$RC"
assert_untouched "L15: settings.json byte-identical after a --print run" \
  "$SETTINGS_15" "$SETTINGS_SUM_15" "$SETTINGS_INODE_15"

# ══════════════════════════════════════════════════════════════════════════
# L16 (bullet 16): sorting + remote derivation
# ══════════════════════════════════════════════════════════════════════════
# L16a: mcp_servers sorted by name
H16A="$TMP/h16a"; mk_home "$H16A"
write_settings "$H16A" <<'EOF'
{
  "enabledPlugins": {},
  "mcpServers": {
    "zeta-server": { "command": "echo" },
    "alpha-server": { "command": "echo" },
    "mid-server": { "command": "echo" }
  }
}
EOF
run_snap_print "$H16A"
assert_rc "L16a: exit 0" 0 "$RC"
assert_eq "L16a: mcp_servers sorted by name" "alpha-server,mid-server,zeta-server" \
  "$(echo "$OUT" | jq -r '[.mcp_servers[].name] | join(",")')"

# L16b: plugins sorted by id, plus name/marketplace split
H16B="$TMP/h16b"; mk_home "$H16B"
write_settings "$H16B" <<'EOF'
{
  "enabledPlugins": {
    "zzz-plugin@marketA": true,
    "aaa-plugin@marketB": true,
    "mmm-plugin@marketC": true
  },
  "mcpServers": {}
}
EOF
write_installed_plugins "$H16B" <<'EOF'
{ "version": 2, "plugins": {} }
EOF
run_snap_print "$H16B"
assert_rc "L16b: exit 0" 0 "$RC"
assert_eq "L16b: plugins sorted by id" "aaa-plugin@marketB,mmm-plugin@marketC,zzz-plugin@marketA" \
  "$(echo "$OUT" | jq -r '[.plugins[].id] | join(",")')"
assert_eq "L16b: name is the id split before @" "aaa-plugin" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="aaa-plugin@marketB") | .name')"
assert_eq "L16b: marketplace is the id split after @" "marketB" \
  "$(echo "$OUT" | jq -r '.plugins[] | select(.id=="aaa-plugin@marketB") | .marketplace')"

# L16c: remote:true iff transport is http/sse; stdio (explicit or via the
# absent-type-but-command-present rule) -> remote:false, host:null.
H16C="$TMP/h16c"; mk_home "$H16C"
write_settings "$H16C" <<'EOF'
{
  "enabledPlugins": {},
  "mcpServers": {
    "svc-http": { "type": "http", "url": "https://http.example.com/mcp" },
    "svc-sse":  { "type": "sse",  "url": "https://sse.example.com/mcp" },
    "svc-stdio-explicit": { "type": "stdio", "command": "echo" },
    "svc-stdio-implicit": { "command": "echo" },
    "svc-stdio-cased": { "type": "STDIO", "command": "echo" },
    "svc-stdio-arraycmd": { "command": ["echo", "hi"], "url": "https://leak.example.com/mcp" },
    "svc-unknown-transport": { "type": "streamable-http", "url": "https://streamable.example.com/mcp" }
  }
}
EOF
run_snap_print "$H16C"
assert_rc "L16c: exit 0" 0 "$RC"
assert_eq "L16c: http transport -> remote true" "true" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-http") | .remote')"
assert_eq "L16c: sse transport -> remote true" "true" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-sse") | .remote')"
assert_eq "L16c: explicit stdio -> remote false" "false" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-explicit") | .remote')"
assert_eq "L16c: absent type + command present -> transport resolves to stdio" "stdio" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-implicit") | .transport')"
assert_eq "L16c: absent-type stdio -> remote false" "false" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-implicit") | .remote')"
assert_eq "L16c: stdio host is null" "null" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-explicit") | .host')"
assert_eq "L16c: cased STDIO type -> remote false (case-insensitive stdio check)" "false" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-cased") | .remote')"
assert_eq "L16c: non-string (array) command still resolves to stdio (key presence, not value type)" "stdio" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-arraycmd") | .transport')"
assert_eq "L16c: non-string command -> host suppressed despite a url being present" "null" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-arraycmd") | .host')"
assert_eq "L16c: non-string command -> remote false" "false" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-stdio-arraycmd") | .remote')"
assert_eq "L16c: unrecognized/newer transport spelling (streamable-http) -> remote true (open, not a closed enum)" "true" \
  "$(echo "$OUT" | jq -r '.mcp_servers[] | select(.name=="svc-unknown-transport") | .remote')"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
