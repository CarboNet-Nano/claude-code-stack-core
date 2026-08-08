#!/usr/bin/env bash
# SessionStart hook: warn about tracked tokens expiring soon.
# Silent when nothing to report (--quiet mode in check script).
# summary: Warns at SessionStart about tracked tokens expiring soon.
exec bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/check-token-expiry.sh" --quiet
