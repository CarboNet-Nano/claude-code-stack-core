#!/usr/bin/env bash
# Shared: locate the nearest .claude/stack-config.json for a given dir.
# Walks up from the start dir; if not found, scans immediate subdirs of the
# start dir (wrapper-folder pattern: ~/foo/ contains ~/foo/foo/.claude/...).
# Prints the absolute path to stack-config.json on stdout, or nothing if
# none found. Exit 0 always (callers branch on output).
#
# Usage: CONFIG="$(bash ~/.claude/lib/find-stack-config.sh "$START_DIR")"

set -uo pipefail

START="${1:-$PWD}"

# 1) Walk up.
dir="$START"
while [[ "$dir" != "/" && -n "$dir" ]]; do
  if [[ -f "$dir/.claude/stack-config.json" ]]; then
    echo "$dir/.claude/stack-config.json"
    exit 0
  fi
  dir="$(dirname "$dir")"
done

# 2) Wrapper fallback: scan immediate subdirs of START.
matches=()
for sub in "$START"/*/; do
  [[ -f "$sub.claude/stack-config.json" ]] && matches+=("$sub.claude/stack-config.json")
done
[[ ${#matches[@]} -eq 1 ]] && echo "${matches[0]}"

exit 0
