#!/usr/bin/env bash
# tests/test-profile-resolver.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"
trap 'export HOME="$ORIG_HOME"; rm -rf "$TMP"' EXIT
source lib/profile-resolver.sh
pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# -- name validation
pr_validate_name "william-team"       && ok "plain name" || bad "plain name"
pr_validate_name "bill.max_2"         && ok "dots/underscores" || bad "dots/underscores"
pr_validate_name ".hidden"            && bad "leading dot accepted" || ok "leading dot refused"
pr_validate_name "a..b"               && bad "dotdot accepted" || ok "dotdot refused"
pr_validate_name "x/y"                && bad "slash accepted" || ok "slash refused"
pr_validate_name "$(printf 'a\tb')"   && bad "control char accepted" || ok "control char refused"
pr_validate_name ""                   && bad "empty accepted" || ok "empty refused"
pr_validate_name "$(printf 'a%.0s' {1..65})" && bad "65 chars accepted" || ok "over-length refused"

# -- dir resolution
unset CLAUDE_CONFIG_DIR
[[ "$(pr_resolve_dir)" == "$HOME/.claude" ]] && ok "default dir" || bad "default dir"
export CLAUDE_CONFIG_DIR="$HOME/.claude-team"
[[ "$(pr_resolve_dir)" == "$HOME/.claude-team" ]] && ok "profile dir" || bad "profile dir"
export CLAUDE_CONFIG_DIR="$HOME/.ssh"
pr_resolve_dir >/dev/null 2>&1 && bad ".ssh accepted" || ok ".ssh refused (exit 3)"
[[ "$(pr_resolve_dir_or_default 2>/dev/null)" == "$HOME/.claude" ]] && ok "degrade to default" || bad "degrade to default"
export CLAUDE_CONFIG_DIR="/tmp/evil"
pr_resolve_dir >/dev/null 2>&1 && bad "outside-home accepted" || ok "outside-home refused"
export CLAUDE_CONFIG_DIR="$HOME/.claude-a/../.ssh"
pr_resolve_dir >/dev/null 2>&1 && bad "traversal accepted" || ok "traversal refused"

# -- safe-target assertion
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude-real"
pr_assert_safe_target "$HOME/.claude-real" && ok "real dir safe" || bad "real dir safe"
pr_assert_safe_target "$HOME/.claude-absent" && ok "absent dir safe" || bad "absent dir safe"
ln -s "$HOME/.claude-real" "$HOME/.claude-link"
pr_assert_safe_target "$HOME/.claude-link" && bad "symlink target accepted" || ok "symlink target refused"

# -- display sanitization
[[ "$(pr_display_path "$HOME/.claude-team")" == "~/.claude-team" ]] && ok "home-relative" || bad "home-relative"
[[ "$(pr_display_path "$(printf "$HOME/.claude-a\e[31mb")")" == *$'\e'* ]] && bad "escape survives" || ok "escapes stripped"

echo "profile-resolver: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
