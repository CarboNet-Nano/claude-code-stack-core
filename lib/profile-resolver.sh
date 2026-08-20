#!/usr/bin/env bash
# lib/profile-resolver.sh — the ONE validated resolver for stack config dirs.
# Security contract (2026-08-18 rev-2 design §1): input is a NAME, never a
# path; every writer refuses targets it cannot prove safe; lstat everywhere.
# Sourced lib: callers own set -uo pipefail.

PR_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

pr_validate_name() {
  local n="${1:-}"
  [[ -n "$n" && "$n" =~ $PR_NAME_RE && "$n" != *..* ]]
}

# CLAUDE_CONFIG_DIR is untrusted (a checked-in .envrc sets it). Accept only
# the two exact shapes; never canonicalize an arbitrary value into safety.
pr_resolve_dir() {
  local v="${CLAUDE_CONFIG_DIR:-}"
  if [[ -z "$v" || "$v" == "$HOME/.claude" ]]; then printf '%s' "$HOME/.claude"; return 0; fi
  local name="${v#"$HOME/.claude-"}"
  if [[ "$v" == "$HOME/.claude-"* ]] && pr_validate_name "$name"; then
    printf '%s' "$v"; return 0
  fi
  return 3
}

pr_resolve_dir_or_default() {
  local d
  if d="$(pr_resolve_dir)"; then printf '%s' "$d"; return 0; fi
  echo "[profile-resolver] ignoring invalid CLAUDE_CONFIG_DIR — using ~/.claude" >&2
  printf '%s' "$HOME/.claude"
}

# Safe to create/write/move-aside? Absent is fine (creating it); present must
# be a real dir, not a link, owned by us, directly under the real $HOME.
pr_assert_safe_target() {
  local d="${1:?}"
  [[ "$d" == "$HOME/.claude" || "$d" == "$HOME/.claude-"* ]] || return 4
  [[ -L "$d" ]] && return 4
  [[ -e "$d" && ! -d "$d" ]] && return 4
  if [[ -d "$d" ]]; then
    [[ -O "$d" ]] || return 4
  fi
  local parent; parent="$(dirname "$d")"
  [[ "$parent" == "$HOME" && -d "$parent" && ! -L "$parent" ]] || return 4
  return 0
}

pr_display_path() {
  local p="${1:-}"
  # NOT `${p/#$HOME/~}`. In bash 5.2+ the REPLACEMENT string of a pattern
  # substitution undergoes tilde expansion, so that form turns `~` straight
  # back into $HOME and the path never shortens -- the display is identical
  # to the input. bash 3.2 (macOS's system bash) leaves `~` literal and the
  # same line works, which is why this passed on a dev Mac and failed only
  # on Ubuntu CI. Escaping the tilde is not a fix either: bash 3.2 then
  # emits a literal backslash.
  #
  # Prefix-strip is correct on both. The tilde here sits inside a quoted
  # assignment, where it is never subject to tilde expansion in any version.
  if [[ "$p" == "$HOME" || "$p" == "$HOME"/* ]]; then
    p="~${p#"$HOME"}"
  fi
  printf '%s' "$p" | LC_ALL=C tr -d '[:cntrl:]' | head -c 256
}
