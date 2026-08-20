#!/usr/bin/env bash
# Claude Code statusLine hook.
# Reads .claude/stack-config.json from current project and emits a chip
# showing orchestration mode, tier, strict/permissive, domain.
#
# stdin: JSON with { workspace: { current_dir }, cwd, model, ... }
# stdout: single-line status string
# summary: Emits a statusline chip showing orchestration mode, tier, strict/permissive, and domain from stack-config.

set -uo pipefail

# ADR-053 D7/D8: domain_mode may be a scalar or an array; render it only
# through dm_display so an array never round-trips through `jq -r` (which
# would emit pretty-printed multi-line JSON into a one-line statusline).
_DM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/domain-modes.sh"
[[ -f "$_DM_LIB" ]] || _DM_LIB="$HOME/.claude/lib/domain-modes.sh"
# shellcheck disable=SC1090
source "$_DM_LIB" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD")"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
  echo "⚪ uninit"
  exit 0
fi

MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG")"
TIER="$(jq -r '.stack_tier // "?"' "$CONFIG")"
STRICT="$(jq -r '.strict_mode // false' "$CONFIG")"
DOMAIN="$(dm_display "$CONFIG" 2>/dev/null)"
[[ "$DOMAIN" == "none" ]] && DOMAIN=""
SENS="$(jq -r '.sensitivity.level // "normal"' "$CONFIG")"

case "$MODE" in
  agent-teams)       ICON="🟢" ;;
  hybrid)            ICON="🟡" ;;
  dynamic-workflows) ICON="🔵" ;;
  main-thread)       ICON="⚪" ;;
  *)                 ICON="❔" ;;
esac

STRICT_LBL="permissive"
[[ "$STRICT" == "true" ]] && STRICT_LBL="strict"

OUT="$ICON $MODE · T$TIER · $STRICT_LBL"
[[ -n "$DOMAIN" ]] && OUT="$OUT · $DOMAIN"
[[ "$SENS" != "normal" ]] && OUT="$OUT · 🔒$SENS"

echo "$OUT"
