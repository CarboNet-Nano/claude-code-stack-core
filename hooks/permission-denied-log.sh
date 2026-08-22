#!/usr/bin/env bash
# PermissionDenied hook (issue #111): fires only when the auto-mode classifier
# denies a tool call — a real, named gap in override-log.sh, which today only
# sees hook-driven denials (irreversible-deny.sh, migration-guard.sh, etc.),
# never classifier-driven ones. Sources override-log.sh's `ovlog_append`
# (ADR-037 D-1, already the shared single-row JSONL writer for guard-override
# logging) so classifier denials land in the SAME log/schema as every other
# override row — no second log format.
#
# PermissionDenied has decision control (hookSpecificOutput.retry), but this
# hook is pure observability (H3) like override-log.sh itself: it never emits
# a decision and always exits 0.
# summary: Logs classifier-driven PermissionDenied events into the shared override log via ovlog_append.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/override-log.sh" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)"
TOOL_USE_ID="$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)"
REASON="$(echo "$INPUT" | jq -r '.reason // "Blocked by classifier"' 2>/dev/null)"
PERM_MODE="$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)"

# reason is classifier-controlled text of unknown future shape (security-
# report.md 2026-08-04, MEDIUM) — cap it (matches override-log.sh's own
# DESC_TRIMMED="${DESC:0:200}" convention) and strip known secret shapes
# (same patterns validate_pack already greps pack content for) before it
# ever reaches the durable log.
REASON="${REASON:0:500}"
REASON="$(printf '%s' "$REASON" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g; s/sk_live_[A-Za-z0-9_-]+/[REDACTED]/g; s/AKIA[0-9A-Z]{16}/[REDACTED]/g')"

EXTRA="$(jq -nc \
  --arg tool "$TOOL_NAME" --arg tuid "$TOOL_USE_ID" --arg reason "$REASON" --arg mode "$PERM_MODE" \
  '{tool_name:$tool, tool_use_id:$tuid, reason:$reason, permission_mode:$mode}')"

ovlog_append "permission_denied" "$CWD" "$EXTRA"

exit 0
