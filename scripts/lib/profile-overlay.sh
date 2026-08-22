#!/usr/bin/env bash
# Overlay profiles (rev-2 design §2, amended): content = per-entry symlinks
# into master; config/state = real files; copy-up before customizing.
# Sourced lib; callers own set -uo pipefail. lstat discipline throughout.

PO_CONTENT_DIRS=(skills agents commands hooks tools lib scripts config)

po_build_overlay() {
  local m="${1:?}" p="${2:?}" d e name
  mkdir -p "$p"
  for d in "${PO_CONTENT_DIRS[@]}"; do
    [[ -d "$m/$d" ]] || continue
    mkdir -p "$p/$d"
    for e in "$m/$d"/* "$m/$d"/.[!.]* "$m/$d"/..?*; do
      [[ -e "$e" ]] || continue
      name="$(basename "$e")"
      # overlay wins: never replace a real entry; refresh existing links
      if [[ -L "$p/$d/$name" ]]; then rm "$p/$d/$name"; ln -s "$e" "$p/$d/$name"
      elif [[ ! -e "$p/$d/$name" ]]; then ln -s "$e" "$p/$d/$name"; fi
    done
  done
  # Top-level CLAUDE.md is content too (spec §2: profiles must serve master
  # content) — link it exactly like a PO_CONTENT_DIRS entry, just not nested
  # under one of those dirs (it lives at $m/CLAUDE.md, not $m/<dir>/...).
  if [[ -e "$m/CLAUDE.md" ]]; then
    if [[ -L "$p/CLAUDE.md" ]]; then rm "$p/CLAUDE.md"; ln -s "$m/CLAUDE.md" "$p/CLAUDE.md"
    elif [[ ! -e "$p/CLAUDE.md" ]]; then ln -s "$m/CLAUDE.md" "$p/CLAUDE.md"; fi
  fi
  # if/fi (not `A || { B && C; }`) — under a caller's `set -e` (install.sh has
  # it, this lib's own tests don't), a guard-false-AND-inner-false chain like
  # `[[ -f p ]] || { [[ -f m ]] && cp; }` still trips errexit at the top
  # level even though every branch here is "nothing to do, not an error".
  if [[ ! -f "$p/settings.json" && -f "$m/settings.json" ]]; then
    cp "$m/settings.json" "$p/settings.json"
  fi
  if [[ ! -f "$p/stack-defaults.json" && -f "$m/stack-defaults.json" ]]; then
    cp "$m/stack-defaults.json" "$p/stack-defaults.json"
  fi
}

po_refresh_links() {
  local m="${1:?}" p="${2:?}" d l tgt
  po_build_overlay "$m" "$p"          # adds links for new/top-level entries
  for d in "${PO_CONTENT_DIRS[@]}"; do
    [[ -d "$p/$d" ]] || continue
    for l in "$p/$d"/* "$p/$d"/.[!.]* "$p/$d"/..?*; do
      [[ -L "$l" ]] || continue
      tgt="$(readlink "$l")"
      [[ -e "$tgt" ]] || { rm "$l"; echo "pruned $(basename "$d")/$(basename "$l")"; }
    done
  done
  if [[ -L "$p/CLAUDE.md" ]]; then
    tgt="$(readlink "$p/CLAUDE.md")"
    [[ -e "$tgt" ]] || { rm "$p/CLAUDE.md"; echo "pruned CLAUDE.md"; }
  fi
}

# Profiles seed settings.json ONCE (po_build_overlay's copy-if-absent), so a
# stack update that adds required wiring to master settings — e.g. ADR-086's
# stack-self-update SessionStart hook — never reached an existing profile's
# settings.json, and the profile silently ran without it. Re-merge the same
# tier settings fragments the tier installer merges into master, add-only,
# profile wins on scalar conflict. Caller must have sourced config-merger.sh.
po_merge_settings_fragments() {
  local repo_root="${1:?}" tier="${2:?}" p="${3:?}" t m frag
  [[ -f "$p/settings.json" ]] || return 0   # no real settings file — seeded later by po_build_overlay
  [[ "$tier" =~ ^[0-9]+$ ]] || return 0
  for ((t=0; t<=tier; t++)); do
    m="$repo_root/config/tier-manifests/tier-$t.json"
    [[ -f "$m" ]] || continue
    while IFS= read -r frag; do
      [[ -n "$frag" && -f "$repo_root/$frag" ]] || continue
      STACK_MERGE_NONINTERACTIVE=1 merge_json "$repo_root/$frag" "$p/settings.json"
    done < <(jq -r '.. | objects | select(.to? == "~/.claude/settings.json") | .from' "$m" 2>/dev/null)
  done
}

po_copy_up() {
  local p="${1:?}" rel="${2:?}" tgt tmp
  local link="$p/$rel"
  [[ -L "$link" ]] || return 0        # already real (or absent) — nothing to do
  tgt="$(readlink "$link")"
  [[ -e "$tgt" ]] || return 1

  # Determine file-vs-dir from the RESOLVED TARGET, never by sniffing what
  # ends up inside the tmp copy — a directory entry may legitimately contain
  # a file literally named "file" (e.g. a skill dir with SKILL.md,
  # subdir/x.md, and a file called "file"). A same-named sentinel there
  # previously matched that real file, moved only it into $link, and left
  # everything else behind in $tmp — then rmdir on a still-nonempty $tmp
  # failed and aborted the caller under set -e (CRITICAL 2).
  if [[ -d "$tgt" ]]; then
    tmp="$(mktemp -d "${link}.XXXX")" || return 1
    if ! cp -R "$tgt/." "$tmp/"; then rm -rf "$tmp"; return 1; fi
  elif [[ -f "$tgt" ]]; then
    tmp="$(mktemp "${link}.XXXX")" || return 1
    if ! cp "$tgt" "$tmp"; then rm -f "$tmp"; return 1; fi
  else
    return 1                          # neither a plain file nor a dir — refuse
  fi

  rm "$link"
  # TOCTOU (IMPORTANT 3): something could recreate $link in the window
  # between the rm above and the mv below (a racing install, another
  # process). If so, abort rather than let mv nest $tmp inside it — leave
  # $tmp on disk for inspection instead of silently discarding it or
  # clobbering whatever now occupies $link.
  if [[ -e "$link" || -L "$link" ]]; then
    echo "po_copy_up: $link was recreated during copy-up — aborting; inspect $tmp" >&2
    return 1
  fi
  mv "$tmp" "$link"
}

po_register() {
  local p="${1:?}" m="$HOME/.claude" name reg
  # M6: master is not a profile. The strip below is a no-op on any path that
  # is not $HOME/.claude-<name>, so registering master (or anything else)
  # would write the FULL PATH into .profiles.json as a "name" — which
  # update.sh then feeds to pr_validate_name and skips forever. Refuse here
  # instead of persisting a garbage entry.
  if [[ "$p" == "$m" || "$p" != "$HOME/.claude-"* ]]; then
    echo "po_register: refusing to register $p — not a profile dir (\$HOME/.claude-<name>)" >&2
    return 0
  fi
  name="${p#"$HOME/.claude-"}"; reg="$m/.profiles.json"
  [[ -f "$reg" ]] || echo '{"profiles":[]}' > "$reg"
  jq --arg n "$name" '.profiles = ((.profiles + [$n]) | unique)' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
}
