#!/usr/bin/env bash
# lib/domain-modes.sh — ADR-053 D7. One shared reader/matcher for
# domain_mode / domain_mode_paths, sourced (never executed) by verify.sh,
# hooks/override-log.sh, hooks/statusline.sh, hooks/session-start-handoff.sh,
# skills/loop-engineer/loop_lib.sh, and skills/foreman/SKILL.md's routing step.
#
# scripts/permissions-compile.sh runs inside a python heredoc and cannot
# source bash; it carries its own inline `active_modes()` twin (ADR-053 D7).
# Keep the two in sync by hand if this file's shape rules ever change.
#
# Every function here is read-only and never fatal: a missing config, an
# unreadable config, or a `domain_mode` of the wrong shape produces no output
# (or the documented fallback) and always exits 0/1 as documented below —
# never a nonzero exit that a caller would need to special-case. Callers must
# not treat empty output as an error.
#
# Glob matching is lifted verbatim from hooks/guard-check.sh:37-42
# (ADR-049) — the stack's one glob dialect. No globstar, no find, no regex.

# dm_active_modes <stack-config-path>
#   -> one mode name per line, in declaration order, deduped.
#      null / absent / unreadable -> no output. Always exit 0.
dm_active_modes() {
  local cfg="$1"
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r '
    .domain_mode as $d
    | if $d == null then empty
      elif ($d | type) == "string" then $d
      elif ($d | type) == "array" and (all($d[]; type == "string"))
        then (reduce $d[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end) | .[])
      else empty
      end
  ' "$cfg" 2>/dev/null
  return 0
}

# dm_has_mode <stack-config-path> <mode>
#   -> exit 0 if <mode> is declared, 1 otherwise. Handles string|array|null.
dm_has_mode() {
  local cfg="$1" mode="$2"
  dm_active_modes "$cfg" | grep -qx -- "$mode"
}

# dm_mode_paths <stack-config-path> <mode>
#   -> one glob per line from domain_mode_paths[<mode>]; NO OUTPUT if the mode
#      is unmapped OR if the mapping exists but is MALFORMED (not a non-empty
#      array of strings). The two cases are deliberately indistinguishable
#      here (ADR-053 D3/D4 — see dm_path_matches_mode). Always exit 0.
dm_mode_paths() {
  local cfg="$1" mode="$2"
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r --arg m "$mode" '
    (.domain_mode_paths // {})[$m] as $v
    | if ($v | type) == "array" and ($v | length) > 0 and (all($v[]; type == "string"))
      then $v[]
      else empty
      end
  ' "$cfg" 2>/dev/null
  return 0
}

# dm_path_matches_mode <stack-config-path> <mode> <project-relative-path>
#   -> exit 0 if the path matches a glob for <mode>, OR <mode> has no usable
#      globs -- i.e. it is UNMAPPED, or its mapping is present but MALFORMED.
#      Both mean "always active" on the routing plane (ADR-053 D3/D4 fail-safe,
#      round 4). Returning 1 for the malformed case would be a routing FAIL-OPEN:
#      the mode's forced review chain would silently never fire. exit 1 otherwise.
#   NOTE: this equivalence is ROUTING-PLANE ONLY. The permission plane still sees
#      the KEY (clause 2 reads keys, never values), so a malformed value keeps the
#      mode scope-incoherent and its suppression withheld. Never "repair" a
#      malformed mapping by deleting the key -- that widens the grant.
dm_path_matches_mode() {
  local cfg="$1" mode="$2" rel="$3"
  local globs
  globs="$(dm_mode_paths "$cfg" "$mode")"
  if [[ -z "$globs" ]]; then
    return 0
  fi
  local glob
  while IFS= read -r glob; do
    if [[ -z "$glob" ]]; then
      continue
    fi
    case "$rel" in
      ${glob//\*\*/\*}) return 0 ;;
    esac
  done <<< "$globs"
  return 1
}

# dm_scoped_modes <stack-config-path> [<rel-path> ...]
#   -> the routing-plane answer: one mode per line.
#      With >=1 path: every declared mode matching any path, plus every
#      unmapped declared mode.
#      With ZERO paths (the UNSCOPED case, D4): every declared mode.
#   Always exit 0. Emits nothing when no modes are declared.
dm_scoped_modes() {
  local cfg="$1"
  shift
  local -a paths=("$@")
  local modes
  modes="$(dm_active_modes "$cfg")"
  if [[ -z "$modes" ]]; then
    return 0
  fi

  if [[ ${#paths[@]} -eq 0 ]]; then
    printf '%s\n' "$modes"
    return 0
  fi

  local m p matched
  while IFS= read -r m; do
    if [[ -z "$m" ]]; then
      continue
    fi
    matched=0
    for p in "${paths[@]}"; do
      if dm_path_matches_mode "$cfg" "$m" "$p"; then
        matched=1
        break
      fi
    done
    if [[ "$matched" -eq 1 ]]; then
      printf '%s\n' "$m"
    fi
  done <<< "$modes"
  return 0
}

# dm_display <stack-config-path>
#   -> comma-joined single line for banners/statusline; "none" when empty.
#      Always exactly one line -- never pretty-printed multi-line JSON.
dm_display() {
  local cfg="$1"
  local -a arr=()
  local m
  while IFS= read -r m; do
    if [[ -n "$m" ]]; then
      arr+=("$m")
    fi
  done < <(dm_active_modes "$cfg")

  if [[ ${#arr[@]} -eq 0 ]]; then
    echo "none"
    return 0
  fi

  local out="${arr[0]}"
  local i
  for ((i = 1; i < ${#arr[@]}; i++)); do
    out="$out, ${arr[$i]}"
  done
  echo "$out"
  return 0
}
