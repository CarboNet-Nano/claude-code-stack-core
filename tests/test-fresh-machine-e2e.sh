#!/usr/bin/env bash
# tests/test-fresh-machine-e2e.sh — the rev-2 §1-§3 story in one run: clean
# HOME → install master → create a fresh overlay profile → migrate a
# hand-made symlink-farm profile → repo with .envrc → freshness resolves
# both. (Self-heal itself is ADR-075 machinery, exercised elsewhere —
# tests/test-sweep-portable-drift.sh — not re-tested here.)
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"

# An ambient CLAUDE_CONFIG_DIR from the outer session points at the real
# $HOME, not $TMP — under the resolver that's correctly refused as foreign,
# which would break every step below. Isolate it exactly like HOME is
# isolated (see tests/test-install.sh).
HAD_CCD=0
if [[ -n "${CLAUDE_CONFIG_DIR+x}" ]]; then HAD_CCD=1; ORIG_CCD="$CLAUDE_CONFIG_DIR"; fi
unset CLAUDE_CONFIG_DIR

restore_env() {
  export HOME="$ORIG_HOME"
  if [[ "$HAD_CCD" -eq 1 ]]; then export CLAUDE_CONFIG_DIR="$ORIG_CCD"; fi
  rm -rf "$TMP"
}
trap restore_env EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# --- §2: fresh overlay profile -----------------------------------------------

./scripts/install.sh --tier=0 --skip-requirements >/dev/null 2>&1 || bad "master install"
./scripts/install.sh --tier=0 --profile=team --skip-requirements >/dev/null 2>&1 || bad "profile install"
[[ -L "$HOME/.claude-team/skills/goodmorning" ]] && ok "profile serves master skills" || bad "profile serves master skills"
[[ -f "$HOME/.claude-team/skills/goodmorning/SKILL.md" ]] && ok "profile symlink resolves to real content" || bad "profile symlink resolves to real content"
[[ -f "$HOME/.claude-team/.stack-install.json" ]] && ok "profile stamped" || bad "profile stamped"
jq -e '.tier' "$HOME/.claude-team/.stack-install.json" >/dev/null 2>&1 && ok "profile stamp parses" || bad "profile stamp parses"

# --- §3: migrate a hand-made symlink-farm profile (the William-team shape) --

M="$HOME/.claude"; P="$HOME/.claude-legacy"
mkdir -p "$P"
ln -s "$M/skills" "$P/skills"
ln -s "$M/config" "$P/config"
ln -s "$M/CLAUDE.md" "$P/CLAUDE.md" 2>/dev/null || true
echo '{"real":true}' > "$P/settings.json"

./scripts/install.sh --migrate-profile=legacy >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "migration exits 0" || bad "migration exits 0 (got $rc)"
[[ ! -L "$P/skills" && -d "$P/skills" ]] && ok "farm link converted to per-entry overlay dir" || bad "farm link converted to per-entry overlay dir"
[[ -L "$P/skills/goodmorning" && -f "$P/skills/goodmorning/SKILL.md" ]] && ok "migrated entry symlink resolves to real content" || bad "migrated entry symlink resolves to real content"
[[ "$(jq -r .real "$P/settings.json" 2>/dev/null)" == "true" ]] && ok "migration preserves real settings.json content" || bad "migration preserves real settings.json content"
[[ -f "$P/.stack-install.json" ]] && ok "migrated profile stamped" || bad "migrated profile stamped"
jq -e '.tier' "$P/.stack-install.json" >/dev/null 2>&1 && ok "migrated profile stamp parses" || bad "migrated profile stamp parses"

./scripts/install.sh --migrate-profile=legacy >/dev/null 2>&1
rc2=$?
[[ "$rc2" -eq 0 ]] && ok "re-migration is idempotent (exit 0)" || bad "re-migration is idempotent (got $rc2)"

# --- freshness resolves a stamped, non-default profile ----------------------

mkdir -p "$TMP/repo"; echo 'export CLAUDE_CONFIG_DIR="$HOME/.claude-team"' > "$TMP/repo/.envrc"
out="$(CLAUDE_CONFIG_DIR="$HOME/.claude-team" bash "$HOME/.claude/lib/stack-freshness.sh" --oneline)"
# Closed set of non-unstamped --oneline tokens (lib/stack-freshness.sh):
# current | unknown | repo-not-found | "<N> behind". Any of these means the
# resolver found and read the stamp; only the unstamped* tokens mean it
# didn't. Which one lands is repo/network dependent (this worktree resolves
# to repo-not-found, since its .git is a worktree pointer, not a .git dir).
[[ "$out" =~ ^(current|unknown|repo-not-found|[0-9]+\ behind)$ ]] && ok "freshness resolves profile stamp (got: $out)" || bad "freshness resolves profile stamp (got: $out)"

echo "fresh-machine-e2e: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
