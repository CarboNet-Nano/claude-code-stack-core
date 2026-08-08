#!/usr/bin/env bash
# Backup ~/.claude/ to ~/.claude.backup.<timestamp>/
# Retains last 5 backups.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
[[ ! -d "$CLAUDE_DIR" ]] && { echo "Nothing to backup."; exit 0; }

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$HOME/.claude.backup.$timestamp"

cp -R "$CLAUDE_DIR" "$backup_dir"
echo "Backed up to $backup_dir"

# Prune to last 5
ls -dt "$HOME/.claude.backup."* 2>/dev/null | tail -n +6 | xargs -r rm -rf
echo "Backups retained: $(ls -d "$HOME/.claude.backup."* 2>/dev/null | wc -l | tr -d ' ')"
