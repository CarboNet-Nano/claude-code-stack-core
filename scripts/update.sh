#!/usr/bin/env bash
# Claude Code Stack — Updater
# Pulls the latest stack, then re-runs install.sh in merge mode (which
# preserves your customizations). An update is always a merge — for a clean
# reinstall use `install.sh --mode=fresh` directly.
#
# ADR-071 D15 #3: HUMAN-ONLY. This script writes ~/.claude/hooks, scripts,
# config, agents, skills, and lib — every path the managed floor's
# `denyWrite` protects (docs/runbooks/managed-floor-install.md). Run it from
# a real terminal, never from inside a session's Bash tool (e.g. wired to
# `/tier` or any other skill) — under an installed floor that write will fail
# with EPERM, and even without the floor it defeats the "Bash cannot rewrite
# the stack's own code" property D11 exists to provide. Deliberately NOT
# added to any `excludedCommands` list — that would exempt an arbitrary
# ~/.claude/** write from the sandbox entirely, a wider hole than the
# problem it would solve.
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

# Overlay model: master just updated above — every registered profile's
# per-entry links may now be stale (new master entries need links, removed
# ones need pruning). Best-effort: skip silently if there's no registry yet
# or jq is unavailable.
REGISTRY="$HOME/.claude/.profiles.json"
if [[ -f "$REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
  source "$SCRIPT_DIR/lib/profile-overlay.sh"
  source "$REPO_ROOT/lib/profile-resolver.sh"
  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    # Registry entries are untrusted input (IMPORTANT 4) — a hand-edited or
    # corrupted .profiles.json must not get interpolated straight into a
    # filesystem path. Validate the name, then re-run the same safety gate
    # install.sh itself uses on every profile target before touching it.
    if ! pr_validate_name "$profile_name"; then
      echo "  [skip] invalid profile name in registry: $profile_name" >&2
      continue
    fi
    profile_dir="$HOME/.claude-$profile_name"
    if ! pr_assert_safe_target "$profile_dir"; then
      echo "  [skip] unsafe profile target: $(pr_display_path "$profile_dir")" >&2
      continue
    fi
    echo "  Refreshing profile overlay: $profile_name"
    po_refresh_links "$HOME/.claude" "$profile_dir"
  done < <(jq -r '.profiles[]? // empty' "$REGISTRY")
fi
