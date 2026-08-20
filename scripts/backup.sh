#!/usr/bin/env bash
# Backup ~/.claude/ to ~/.claude.backup.<timestamp>/
# Retains last 5 backups.
#
# Excludes regenerable bulk (transcripts, plugin/tool dependency trees, job
# output). Restoring a stack means restoring its config, skills, hooks and
# tool SOURCE — never a 1.4G replay of past conversations. Without this the
# snapshot is ~2.6G and every install re-copies it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/profile-resolver.sh"

CLAUDE_DIR="$(pr_resolve_dir_or_default)"
[[ ! -d "$CLAUDE_DIR" ]] && { echo "Nothing to backup."; exit 0; }

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$HOME/.claude.backup.$timestamp"

EXCLUDES=(
  projects
  plugins
  jobs
  file-history
  session-env
  shell-snapshots
  logs
  debug
  downloads
  telemetry
  statsig
  backups
  node_modules
  .venv
  venv
  __pycache__
)

if command -v rsync >/dev/null 2>&1; then
  args=()
  for e in "${EXCLUDES[@]}"; do args+=(--exclude "$e"); done
  mkdir -p "$backup_dir"
  rsync -a "${args[@]}" "$CLAUDE_DIR/" "$backup_dir/"
else
  cp -R "$CLAUDE_DIR" "$backup_dir"
  for e in "${EXCLUDES[@]}"; do
    find "$backup_dir" -name "$e" -maxdepth 3 -exec rm -rf {} + 2>/dev/null || true
  done
fi

echo "Backed up to $backup_dir ($(du -sh "$backup_dir" | cut -f1))"

# Prune to last 5
ls -dt "$HOME/.claude.backup."* 2>/dev/null | tail -n +6 | xargs -r rm -rf
echo "Backups retained: $(ls -d "$HOME/.claude.backup."* 2>/dev/null | wc -l | tr -d ' ')"
