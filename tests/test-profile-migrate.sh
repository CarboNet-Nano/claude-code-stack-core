#!/usr/bin/env bash
# tests/test-profile-migrate.sh — fixture modeled on the real ~/.claude-william-team farm
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"
trap 'export HOME="$ORIG_HOME"; rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

M="$HOME/.claude"; P="$HOME/.claude-wt"
mkdir -p "$M/skills/goodmorning" "$M/config"; echo x > "$M/skills/goodmorning/SKILL.md"
echo '{"a":1}' > "$M/settings.json"; echo '{}' > "$M/stack-defaults.json"
echo '{"tier":4}' > "$M/.stack-install.json"
mkdir -p "$P/projects"                       # real, profile-private — must survive
ln -s "$M/skills" "$P/skills"                # whole-dir farm link (the Aug-9 shape)
ln -s "$M/config" "$P/config"
ln -s "$M/CLAUDE.md" "$P/CLAUDE.md" 2>/dev/null || true
echo '{"b":2}' > "$P/settings.json"          # real settings — must survive as overlay

./scripts/install.sh --migrate-profile=wt >/dev/null 2>&1 || bad "clean migration exited nonzero"
[[ ! -L "$P/skills" && -d "$P/skills" ]] && ok "whole-dir link became per-entry dir" || bad "skills still a farm link"
[[ -L "$P/skills/goodmorning" ]] && ok "entries relinked" || bad "entries relinked"
[[ "$(jq -r .b "$P/settings.json")" == 2 ]] && ok "real settings survived" || bad "real settings survived"
[[ -f "$P/.stack-install.json" ]] && ok "profile stamped" || bad "profile stamped"
[[ -d "$P/projects" ]] && ok "private state untouched" || bad "private state untouched"

# hostile link → refuse, delete nothing
mkdir -p "$HOME/secret"; touch "$HOME/secret/f"
ln -s "$HOME/secret" "$P/tools"
./scripts/install.sh --migrate-profile=wt >/dev/null 2>&1 && bad "hostile link accepted" || ok "hostile link refused (exit 5)"
[[ -f "$HOME/secret/f" ]] && ok "hostile target untouched" || bad "hostile target deleted"

# CRITICAL regression: expected-set is exact per-name === $M/<name>, not
# merely "anywhere under master". A link whose NAME isn't a known farm entry
# (PO_CONTENT_DIRS or CLAUDE.md) must refuse even though its target sits
# safely inside master — pass 2 must never remove a link pass 1 didn't
# explicitly clear.
P2="$HOME/.claude-wt2"
mkdir -p "$P2"
ln -s "$M/skills/goodmorning" "$P2/my-shortcut"
before="$(readlink "$P2/my-shortcut")"
./scripts/install.sh --migrate-profile=wt2 >/dev/null 2>&1 && bad "mismatched-name link accepted" || ok "mismatched-name link refused (exit 5)"
[[ -L "$P2/my-shortcut" && "$(readlink "$P2/my-shortcut")" == "$before" ]] && ok "mismatched-name link intact" || bad "mismatched-name link intact"
[[ "$(find "$P2" -mindepth 1 | wc -l | tr -d ' ')" == 1 ]] && ok "mismatched-name case: nothing else changed" || bad "mismatched-name case: nothing else changed"

# CRITICAL regression: name/target mismatch. "skills" IS a known farm name,
# but its target must be exactly $M/skills — pointing one level deeper
# (a real subdirectory of master) must still refuse, not be treated as
# "close enough because it's under master".
P3="$HOME/.claude-wt3"
mkdir -p "$P3"
ln -s "$M/skills/goodmorning" "$P3/skills"
./scripts/install.sh --migrate-profile=wt3 >/dev/null 2>&1 && bad "name/target mismatch accepted" || ok "name/target mismatch refused (exit 5)"
[[ -L "$P3/skills" && "$(readlink "$P3/skills")" == "$M/skills/goodmorning" ]] && ok "name/target mismatch link intact" || bad "name/target mismatch link intact"

# Dotfile link to an exact top-level master path (e.g. .mcp.json). Stricter
# reading of the ruling: the expected set is restricted to PO_CONTENT_DIRS
# names + CLAUDE.md — the only top-level links po_build_overlay itself ever
# creates or restores. .mcp.json isn't one of those, so even though its
# target is exactly $M/.mcp.json (the "expected shape" by pattern alone),
# converting it would delete a link po_build_overlay can never recreate,
# stranding the profile with no path back to it. Refuse instead.
P4="$HOME/.claude-wt4"
mkdir -p "$P4"
echo '{}' > "$M/.mcp.json"
ln -s "$M/.mcp.json" "$P4/.mcp.json"
./scripts/install.sh --migrate-profile=wt4 >/dev/null 2>&1 && bad "dotfile link accepted" || ok "dotfile link refused (exit 5)"
[[ -L "$P4/.mcp.json" && "$(readlink "$P4/.mcp.json")" == "$M/.mcp.json" ]] && ok "dotfile link intact" || bad "dotfile link intact"

# IMPORTANT regression (bash 3.2 `set -u` unbound-variable crash): a profile
# with ZERO top-level symlinks (real dirs/files only — nothing for pass 1 to
# collect) must still exit 0. Before the fix, `for l in "${to_remove[@]}"`
# on an empty array aborted with "unbound variable" under `set -u` on
# /bin/bash 3.2.
P5="$HOME/.claude-wt5"
mkdir -p "$P5/skills"; echo real > "$P5/skills/mine.md"
./scripts/install.sh --migrate-profile=wt5 >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "zero-link profile migrates as no-op (exit 0)" || bad "zero-link profile migrates as no-op (exit $rc)"
[[ -f "$P5/skills/mine.md" ]] && ok "zero-link profile: real content untouched" || bad "zero-link profile: real content untouched"

# IMPORTANT regression: idempotency contract from the brief — running
# --migrate-profile a second time on an already-migrated (all-links-real-now)
# profile must exit 0 and change nothing, not crash on the now-empty
# to_remove array.
P6="$HOME/.claude-wt6"
mkdir -p "$P6/projects"
ln -s "$M/skills" "$P6/skills"
ln -s "$M/config" "$P6/config"
echo '{"c":3}' > "$P6/settings.json"
./scripts/install.sh --migrate-profile=wt6 >/dev/null 2>&1 || bad "idempotency: first run exited nonzero"
snapshot1="$(cd "$P6" && find . | sort)"
./scripts/install.sh --migrate-profile=wt6 >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "idempotent second run exits 0" || bad "idempotent second run exits 0 (exit $rc)"
snapshot2="$(cd "$P6" && find . | sort)"
[[ "$snapshot1" == "$snapshot2" ]] && ok "idempotent second run: no changes" || bad "idempotent second run: no changes"

echo "profile-migrate: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
