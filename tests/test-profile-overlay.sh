#!/usr/bin/env bash
# tests/test-profile-overlay.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"
trap 'export HOME="$ORIG_HOME"; rm -rf "$TMP"' EXIT
source lib/profile-resolver.sh; source scripts/lib/profile-overlay.sh
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

M="$HOME/.claude"; P="$HOME/.claude-team"
mkdir -p "$M/skills/goodmorning" "$M/skills/foreman" "$M/config"
echo core > "$M/skills/goodmorning/SKILL.md"; echo core > "$M/skills/foreman/SKILL.md"
echo '{}' > "$M/config/org.json"; echo '{"a":1}' > "$M/settings.json"; echo '{}' > "$M/stack-defaults.json"
echo "# master CLAUDE.md" > "$M/CLAUDE.md"

po_build_overlay "$M" "$P"
[[ -L "$P/skills/goodmorning" && "$(readlink "$P/skills/goodmorning")" == "$M/skills/goodmorning" ]] \
  && ok "skill linked per-entry" || bad "skill linked per-entry"
[[ -f "$P/settings.json" && ! -L "$P/settings.json" ]] && ok "settings real" || bad "settings real"

# CRITICAL 1: top-level CLAUDE.md is content too — must be linked like any
# other entry, and restored by a later po_build_overlay if the link is gone.
[[ -L "$P/CLAUDE.md" && "$(readlink "$P/CLAUDE.md")" == "$M/CLAUDE.md" ]] \
  && ok "CLAUDE.md linked top-level" || bad "CLAUDE.md linked top-level"
rm "$P/CLAUDE.md"
for d in skills agents commands hooks tools lib scripts config; do
  [[ -d "$P/$d" ]] || continue
  for l in "$P/$d"/* "$P/$d"/.[!.]* "$P/$d"/..?*; do
    [[ -L "$l" ]] && rm "$l"
  done
done
po_build_overlay "$M" "$P"
[[ -L "$P/CLAUDE.md" && "$(readlink "$P/CLAUDE.md")" == "$M/CLAUDE.md" ]] \
  && ok "CLAUDE.md restored as link after removal" || bad "CLAUDE.md restored as link after removal"

# overlay wins: pre-existing real entry is kept
mkdir -p "$P/skills/mine"; echo local > "$P/skills/mine/SKILL.md"
po_build_overlay "$M" "$P"
[[ ! -L "$P/skills/mine" ]] && ok "real overlay entry kept" || bad "real overlay entry kept"

# refresh: new master entry gains a link, removed one is pruned
mkdir -p "$M/skills/newone"; echo x > "$M/skills/newone/SKILL.md"
rm -rf "$M/skills/foreman"
po_refresh_links "$M" "$P" >/dev/null
[[ -L "$P/skills/newone" ]] && ok "new entry linked" || bad "new entry linked"
[[ ! -e "$P/skills/foreman" && ! -L "$P/skills/foreman" ]] && ok "dangling pruned" || bad "dangling pruned"

# CLAUDE.md is pruned by refresh too, once master's copy is gone
rm "$M/CLAUDE.md"
po_refresh_links "$M" "$P" >/dev/null
[[ ! -e "$P/CLAUDE.md" && ! -L "$P/CLAUDE.md" ]] && ok "CLAUDE.md pruned when master's is gone" || bad "CLAUDE.md pruned when master's is gone"
echo "# master CLAUDE.md again" > "$M/CLAUDE.md"

# copy-up: link becomes an independent real copy
po_copy_up "$P" "skills/goodmorning"
[[ ! -L "$P/skills/goodmorning" && -f "$P/skills/goodmorning/SKILL.md" ]] && ok "copy-up real" || bad "copy-up real"
echo tenant > "$P/skills/goodmorning/SKILL.md"
[[ "$(cat "$M/skills/goodmorning/SKILL.md")" == core ]] && ok "master untouched after copy-up write" || bad "master untouched"

# CRITICAL 2 regression: a directory entry containing SKILL.md, subdir/x.md,
# AND a file literally named "file" must survive copy-up intact — the old
# sentinel design ("$tmp/file" == "did cp -R fall back to the single-file
# branch?") collided with a real file of that name inside the copied dir,
# dropped everything else, and then failed rmdir on the still-nonempty tmp
# dir under set -e.
mkdir -p "$M/skills/multi/subdir"
echo "skill-doc" > "$M/skills/multi/SKILL.md"
echo "nested-doc" > "$M/skills/multi/subdir/x.md"
echo "literal-file-content" > "$M/skills/multi/file"
po_build_overlay "$M" "$P" >/dev/null
[[ -L "$P/skills/multi" ]] || bad "multi entry linked before copy-up (setup)"
po_copy_up "$P" "skills/multi"
rc=$?
[[ $rc -eq 0 ]] && ok "copy-up on dir-with-'file' entry returns 0" || bad "copy-up on dir-with-'file' entry returns 0 (rc=$rc)"
[[ ! -L "$P/skills/multi" ]] && ok "multi entry no longer a symlink" || bad "multi entry no longer a symlink"
[[ "$(cat "$P/skills/multi/SKILL.md" 2>/dev/null)" == "skill-doc" ]] && ok "SKILL.md survived copy-up" || bad "SKILL.md survived copy-up"
[[ "$(cat "$P/skills/multi/subdir/x.md" 2>/dev/null)" == "nested-doc" ]] && ok "subdir/x.md survived copy-up" || bad "subdir/x.md survived copy-up"
[[ "$(cat "$P/skills/multi/file" 2>/dev/null)" == "literal-file-content" ]] && ok "literally-named 'file' survived copy-up" || bad "literally-named 'file' survived copy-up"
leftover="$(find "$P/skills" -maxdepth 1 -name 'multi.*' 2>/dev/null)"
[[ -z "$leftover" ]] && ok "no orphaned tmp dir left behind" || bad "orphaned tmp dir left behind: $leftover"

# registry
po_register "$P"; po_register "$P"
[[ "$(jq -r '.profiles | length' "$M/.profiles.json")" == 1 ]] && ok "registry deduped" || bad "registry deduped"

echo "profile-overlay: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
