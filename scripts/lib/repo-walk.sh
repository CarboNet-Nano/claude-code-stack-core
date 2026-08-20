#!/usr/bin/env bash
# Repo discovery for the stack's bulk-repo tools (ADR-068 D1a).
#
# Finds directories containing .claude/stack-config.json under one or more
# roots. Depth is a PARAMETER, not a constant: ADR-067's rehome.sh scans to
# depth 2, ADR-068's stack-sync.sh scans to depth 1. Both ADRs were written
# claiming to define this file with their own depth baked in, which is why it
# ships separately and takes depth from the caller.
#
# Usage:
#   source scripts/lib/repo-walk.sh
#   walk_repos --max-depth 1 --root ~/Antigravity --root ~/Claude
#
# Prints one absolute repo path per line, sorted and deduplicated. Diagnostics
# go to stderr so stdout stays parseable.
#
# Roots default to .repo_roots[] in ~/.claude/stack-defaults.json, falling back
# to $HOME when that key is absent.

REPO_WALK_PRUNE_DIRS=(node_modules .git .venv venv __pycache__ vendor dist build .next target)

repo_walk_default_roots() {
  local defaults="$HOME/.claude/stack-defaults.json"
  local roots=""
  if [[ -f "$defaults" ]]; then
    roots="$(jq -r '(.repo_roots // [])[]' "$defaults" 2>/dev/null)"
  fi
  if [[ -n "$roots" ]]; then
    printf '%s\n' "$roots"
  else
    printf '%s\n' "$HOME"
  fi
}

# walk_repos [--max-depth N] [--root PATH]...
walk_repos() {
  local max_depth=1
  local -a roots=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-depth)   max_depth="$2"; shift 2 ;;
      --max-depth=*) max_depth="${1#*=}"; shift ;;
      --root)        roots+=("$2"); shift 2 ;;
      --root=*)      roots+=("${1#*=}"); shift ;;
      *) echo "repo-walk: unknown argument: $1" >&2; return 2 ;;
    esac
  done

  if [[ ! "$max_depth" =~ ^[0-9]+$ ]] || (( max_depth < 1 )); then
    echo "repo-walk: --max-depth must be a positive integer, got '$max_depth'" >&2
    return 2
  fi

  if (( ${#roots[@]} == 0 )); then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && roots+=("$line")
    done < <(repo_walk_default_roots)
  fi

  local -a prune=()
  local d
  for d in "${REPO_WALK_PRUNE_DIRS[@]}"; do
    (( ${#prune[@]} )) && prune+=(-o)
    prune+=(-name "$d")
  done

  local root
  for root in "${roots[@]}"; do
    root="${root/#\~/$HOME}"
    if [[ ! -d "$root" ]]; then
      echo "repo-walk: skipping missing root: $root" >&2
      continue
    fi

    # maxdepth is max_depth+1 because the match target is the .claude directory,
    # which sits one level below the repo being reported. -P refuses to follow
    # symlinks, so a link cannot walk us out of the root.
    find -P "$root" -maxdepth "$((max_depth + 1))" \
      \( "${prune[@]}" \) -prune -o \
      -type d -name .claude -print 2>/dev/null |
    while IFS= read -r claude_dir; do
      [[ -f "$claude_dir/stack-config.json" ]] || continue
      (cd "$(dirname "$claude_dir")" 2>/dev/null && pwd -P)
    done
  done | sort -u
}
