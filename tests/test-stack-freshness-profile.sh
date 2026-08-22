#!/usr/bin/env bash
# tests/test-stack-freshness-profile.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"
trap 'export HOME="$ORIG_HOME"; rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
mkdir -p "$HOME/.claude/lib"; cp lib/stack-freshness.sh lib/profile-resolver.sh "$HOME/.claude/lib/"

# profile dir exists, no stamp → unstamped-profile token, exit 0 (non-fatal)
mkdir -p "$HOME/.claude-team/skills"
out="$(CLAUDE_CONFIG_DIR="$HOME/.claude-team" bash "$HOME/.claude/lib/stack-freshness.sh" --oneline)"; rc=$?
[[ "$out" == "unstamped-profile ~/.claude-team" ]] && ok "unstamped-profile token" || bad "unstamped-profile token (got: $out)"
[[ $rc -eq 0 ]] && ok "non-fatal exit" || bad "non-fatal exit"

# invalid env → benign default behavior, never an error exit
out="$(CLAUDE_CONFIG_DIR="/tmp/evil" bash "$HOME/.claude/lib/stack-freshness.sh" --oneline 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "invalid env non-fatal" || bad "invalid env non-fatal"

# default dir unstamped → the OLD token, unchanged (no regression)
out="$(bash "$HOME/.claude/lib/stack-freshness.sh" --oneline)"
[[ "$out" == "unstamped" ]] && ok "legacy unstamped token unchanged" || bad "legacy token (got: $out)"

# --- C1 regression: profile-resolver.sh ABSENT on a real, healthy install ---
# (this is the exact defect: unguarded `source` on a stamped default install
# with no resolver on disk must NOT emit stderr noise or a malformed token)
RESOLVERLESS="$(mktemp -d)"
mkdir -p "$RESOLVERLESS/.claude/lib"
cp lib/stack-freshness.sh "$RESOLVERLESS/.claude/lib/"   # profile-resolver.sh deliberately NOT copied
mkdir -p "$RESOLVERLESS/repo/.git"
cat > "$RESOLVERLESS/.claude/.stack-install.json" <<JSON
{"source_repo":"$RESOLVERLESS/repo","source_sha":"deadbeef","source_branch":"main","tier":0}
JSON
out="$(HOME="$RESOLVERLESS" bash "$RESOLVERLESS/.claude/lib/stack-freshness.sh" --oneline 2>"$RESOLVERLESS/stderr.log")"; rc=$?
[[ $rc -eq 0 ]] && ok "resolver-absent: non-fatal exit" || bad "resolver-absent: non-fatal exit (rc=$rc)"
[[ ! -s "$RESOLVERLESS/stderr.log" ]] && ok "resolver-absent: clean stderr" || bad "resolver-absent: clean stderr (got: $(cat "$RESOLVERLESS/stderr.log"))"
[[ "$out" != "unstamped-profile "* && "$out" != *"command not found"* ]] && ok "resolver-absent: no malformed unstamped-profile token" || bad "resolver-absent: malformed token (got: $out)"
rm -rf "$RESOLVERLESS"

# --- C2 regression: prove profile-resolver.sh actually ships via install.sh, ---
# --- not only via the manual `cp` above (which papered over the missing    ---
# --- tier-0 manifest entry) ---
INSTHOME="$(mktemp -d)"
HAD_CCD=0
if [[ -n "${CLAUDE_CONFIG_DIR+x}" ]]; then HAD_CCD=1; ORIG_CCD="$CLAUDE_CONFIG_DIR"; fi
unset CLAUDE_CONFIG_DIR
if HOME="$INSTHOME" ./scripts/install.sh --tier=0 --mode=fresh --skip-requirements >"$INSTHOME/install.log" 2>&1; then
  ok "install: tier=0 install succeeded"
else
  bad "install: tier=0 install failed (see $INSTHOME/install.log)"
fi

[[ -f "$INSTHOME/.claude/lib/profile-resolver.sh" ]] && ok "install: profile-resolver.sh shipped by install.sh" || bad "install: profile-resolver.sh NOT shipped by install.sh"
[[ -x "$INSTHOME/.claude/lib/profile-resolver.sh" ]] && ok "install: profile-resolver.sh is executable" || bad "install: profile-resolver.sh not executable"

out="$(HOME="$INSTHOME" bash "$INSTHOME/.claude/lib/stack-freshness.sh" --oneline 2>"$INSTHOME/err-default.log")"; rc=$?
[[ $rc -eq 0 ]] && ok "install: installed-tree default run non-fatal" || bad "install: installed-tree default run non-fatal (rc=$rc)"
[[ ! -s "$INSTHOME/err-default.log" ]] && ok "install: installed-tree default run clean stderr" || bad "install: installed-tree default run clean stderr (got: $(cat "$INSTHOME/err-default.log"))"
[[ -n "$out" ]] && ok "install: installed-tree default run well-formed token (got: $out)" || bad "install: installed-tree default run empty token"

mkdir -p "$INSTHOME/.claude-team"
out2="$(HOME="$INSTHOME" CLAUDE_CONFIG_DIR="$INSTHOME/.claude-team" bash "$INSTHOME/.claude/lib/stack-freshness.sh" --oneline 2>"$INSTHOME/err-profile.log")"; rc2=$?
[[ $rc2 -eq 0 ]] && ok "install: installed-tree profile run non-fatal" || bad "install: installed-tree profile run non-fatal (rc=$rc2)"
[[ ! -s "$INSTHOME/err-profile.log" ]] && ok "install: installed-tree profile run clean stderr" || bad "install: installed-tree profile run clean stderr (got: $(cat "$INSTHOME/err-profile.log"))"
[[ "$out2" == "unstamped-profile ~/.claude-team" ]] && ok "install: installed-tree unstamped-profile token" || bad "install: installed-tree unstamped-profile token (got: $out2)"

if [[ $HAD_CCD -eq 1 ]]; then export CLAUDE_CONFIG_DIR="$ORIG_CCD"; fi
rm -rf "$INSTHOME"

echo "freshness-profile: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
