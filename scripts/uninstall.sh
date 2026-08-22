#!/usr/bin/env bash
# Interactive uninstall — asks before each major removal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/profile-resolver.sh"

CLAUDE_DIR="$(pr_resolve_dir)" || { echo "Error: CLAUDE_CONFIG_DIR is set to an unsupported path — use \$HOME/.claude or \$HOME/.claude-<name>"; exit 4; }
pr_assert_safe_target "$CLAUDE_DIR" || { echo "Error: refusing target $(pr_display_path "$CLAUDE_DIR") — not a real user-owned dir directly under \$HOME"; exit 4; }

echo "Claude Code Stack uninstaller"
echo "This will REMOVE stack-installed content from $(pr_display_path "$CLAUDE_DIR")/"
echo "A backup will be taken first."
echo ""
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 0; }

# Backup
"$SCRIPT_DIR/backup.sh"

# Confirm specific removals
for item in agents skills hooks templates config/model-routing.json config/domain-modes.json config/prompt-caching.json; do
  target="$CLAUDE_DIR/$item"
  pr_assert_safe_target "$CLAUDE_DIR" || { echo "Error: target changed underfoot — aborting"; exit 4; }
  if [[ -e "$target" ]]; then
    read -p "Remove $(pr_display_path "$CLAUDE_DIR")/$item? (yes/no): " r
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
