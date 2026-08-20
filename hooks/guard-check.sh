#!/usr/bin/env bash
# PostToolUse guard runner. ADR-049.
#
# Runs the project's boundary-guard script the moment a guarded file is
# edited, instead of waiting for CI. Generic by design: everything
# project-specific is read from .claude/stack-config.json.
#
#   guards.script  -- the guard command to run (relative to project root)
#   guards.paths   -- globs; the guard runs only if the edited file matches one
#
# A project with no guards block is a no-op. Exit 2 feeds the guard's output
# back to Claude as actionable feedback; every other failure exits 0 so a
# broken hook can never block editing.
# summary: Runs a project's guards.script on Edit/Write/MultiEdit when the file matches guards.paths; exit 2 relays a real guard failure.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.claude/stack-config.json"

[ -f "$CONFIG" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0

# Compare on a project-relative path so the globs in stack-config stay short.
rel="${file#"$PROJECT_DIR"/}"

script=$(jq -r '.guards.script // empty' "$CONFIG" 2>/dev/null)
[ -n "$script" ] || exit 0
[ -f "$PROJECT_DIR/$script" ] || exit 0

# `**` is not special inside a bash `case` pattern, but a plain `*` there does
# match slashes -- so app/** and app/* behave identically for our purposes.
matched=0
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  case "$rel" in
    ${glob//\*\*/\*}) matched=1; break ;;
  esac
done < <(jq -r '.guards.paths // [] | .[]' "$CONFIG" 2>/dev/null)

[ "$matched" -eq 1 ] || exit 0

output=$(cd "$PROJECT_DIR" && bash "$script" 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "Boundary guard failed after editing $rel:" >&2
  echo "$output" >&2
  echo "" >&2
  echo "Fix this before moving on -- the same script runs in CI and will fail the build." >&2
  exit 2
fi

exit 0
