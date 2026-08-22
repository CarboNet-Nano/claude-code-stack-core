#!/usr/bin/env bash
# PostToolUse hook: run tsc --noEmit if cwd looks like a TypeScript project.
# Prints first 30 lines of errors but does not block.
# summary: Runs tsc --noEmit after a tool call in a TypeScript project, printing errors but never blocking.

set -uo pipefail

# Smart skip: only run if both package.json and tsconfig.json exist
if [[ ! -f "package.json" ]] || [[ ! -f "tsconfig.json" ]]; then
  exit 0
fi

# Only run if typescript is a dependency
if ! grep -q '"typescript"' package.json 2>/dev/null; then
  exit 0
fi

# Run tsc with a timeout; print first 30 lines of output
output="$(timeout 60 npx tsc --noEmit 2>&1 | head -30)" || true

if [[ -n "$output" ]]; then
  echo "──────────────────────────────────────────────"
  echo "tsc --noEmit output (first 30 lines):"
  echo "──────────────────────────────────────────────"
  echo "$output"
fi

exit 0
