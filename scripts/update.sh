#!/usr/bin/env bash
# Claude Code Stack — Updater
# Pulls the latest stack, then re-runs install.sh in merge mode (which
# preserves your customizations). An update is always a merge — for a clean
# reinstall use `install.sh --mode=fresh` directly.
#
# Usage: ./update.sh --tier=N [--include-ollama=laptop] [--skip-requirements]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIER=""
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
  esac
done

if [[ -z "$TIER" ]]; then
  echo "Usage: $0 --tier=N [--include-ollama=laptop] [--skip-requirements]"
  exit 1
fi

cd "$REPO_ROOT"

# A dirty tree means local edits to stack files — `git pull` could conflict,
# and a merge install could mistake those edits for stack content. Stop and
# let the user decide.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "claude-code-stack has uncommitted changes."
  echo "Commit or stash them before updating, then re-run."
  exit 1
fi

echo "[1/2] Pulling latest claude-code-stack..."
git pull --ff-only

echo "[2/2] Re-running install (merge mode)..."
"$SCRIPT_DIR/install.sh" "$@" --mode=merge
