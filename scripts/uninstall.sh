#!/usr/bin/env bash
# Interactive uninstall — asks before each major removal.

set -euo pipefail

echo "Claude Code Stack uninstaller"
echo "This will REMOVE stack-installed content from ~/.claude/"
echo "A backup will be taken first."
echo ""
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 0; }

# Backup
"$(dirname "$0")/backup.sh"

# Confirm specific removals
for item in agents skills hooks templates config/model-routing.json config/domain-modes.json config/prompt-caching.json; do
  target="$HOME/.claude/$item"
  if [[ -e "$target" ]]; then
    read -p "Remove ~/.claude/$item? (yes/no): " r
    if [[ "$r" == "yes" ]]; then
      rm -rf "$target"
      echo "  Removed."
    fi
  fi
done

echo ""
echo "Uninstall complete. Backup retained at ~/.claude.backup.*"
echo "Note: CLAUDE.md and settings.json were NOT removed (user-owned)."
echo "To remove those manually if desired."
