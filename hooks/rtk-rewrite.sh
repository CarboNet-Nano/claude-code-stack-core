#!/usr/bin/env bash
# PreToolUse[Bash] hook: rewrites shell commands through RTK for token-compressed output.
# RTK's binary owns all rewrite rules (src/discover/registry.rs) — this is a thin wrapper.
# Requires: rtk >= 0.23.0, jq
# Silent no-op if rtk/jq absent or RTK_DISABLED=1.
# summary: Rewrites shell commands through RTK for token-compressed output.

set -uo pipefail

[ "${RTK_DISABLED:-}" = "1" ] && exit 0
command -v rtk >/dev/null 2>&1 || exit 0
command -v jq  >/dev/null 2>&1 || exit 0

# Version gate: rtk rewrite protocol requires >= 0.23.0
# Cache result in /tmp to avoid per-command version checks.
VERSION_CACHE="/tmp/.rtk-version-ok"
if [ ! -f "$VERSION_CACHE" ]; then
  ver="$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
  if [ "${major:-0}" -gt 0 ] || { [ "${major:-0}" -eq 0 ] && [ "${minor:-0}" -ge 23 ]; }; then
    touch "$VERSION_CACHE"
  else
    exit 0
  fi
fi

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$CMD" ] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
[ -z "$CMD" ] && exit 0

# Delegate all rewrite logic to the RTK binary — it is the single source of truth.
REWRITTEN="$(rtk rewrite "$CMD" 2>/dev/null)"
RC=$?

case $RC in
  0)
    # Successful rewrite — auto-allow so Claude doesn't re-prompt.
    printf '%s' "$INPUT" | jq --arg cmd "$REWRITTEN" '
      .tool_input.command = $cmd
    ' 2>/dev/null
    printf '{"permissionDecision":"allow"}\n'
    ;;
  1)
    # No RTK equivalent for this command — pass through unchanged.
    exit 0
    ;;
  2)
    # RTK deny rule matched — let Claude Code handle denial natively.
    exit 2
    ;;
  3)
    # RTK ask rule — rewrite but require user confirmation.
    printf '%s' "$INPUT" | jq --arg cmd "$REWRITTEN" '
      .tool_input.command = $cmd
    ' 2>/dev/null
    ;;
  *)
    exit 0
    ;;
esac
