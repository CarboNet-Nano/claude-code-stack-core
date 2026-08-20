#!/usr/bin/env bash
# Check tracked tokens for upcoming expiry.
# Standalone:  bash ~/.claude/scripts/check-token-expiry.sh
# Quiet mode:  bash ~/.claude/scripts/check-token-expiry.sh --quiet  (silent unless warnings)
# Add entry:   bash ~/.claude/scripts/check-token-expiry.sh add <name> <service> <YYYY-MM-DD>

set -uo pipefail

MANIFEST="$HOME/.claude/state/token-expiry.json"

cmd="${1:-check}"

ensure_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    mkdir -p "$(dirname "$MANIFEST")"
    echo '{"warn_within_days": 30, "tokens": []}' > "$MANIFEST"
  fi
}

if [[ "$cmd" == "add" ]]; then
  ensure_manifest
  NAME="${2:?usage: add <name> <service> <YYYY-MM-DD>}"
  SERVICE="${3:?usage: add <name> <service> <YYYY-MM-DD>}"
  EXPIRES="${4:?usage: add <name> <service> <YYYY-MM-DD>}"
  TODAY=$(date -u +%Y-%m-%d)
  jq --arg n "$NAME" --arg s "$SERVICE" --arg e "$EXPIRES" --arg t "$TODAY" \
    '.tokens += [{name:$n, service:$s, expires_at:$e, rotated_on:$t, location:"", notes:""}]' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  echo "Added: $NAME ($SERVICE) → expires $EXPIRES"
  exit 0
fi

ensure_manifest
QUIET=false
[[ "$cmd" == "--quiet" ]] && QUIET=true

WARN_DAYS=$(jq -r '.warn_within_days // 30' "$MANIFEST")
TODAY=$(date -u +%Y-%m-%d)

warnings=$(jq -r --arg today "$TODAY" --argjson warn "$WARN_DAYS" '
  .tokens[]
  | select(.expires_at != null)
  | . as $t
  | (((.expires_at | strptime("%Y-%m-%d") | mktime) - ($today | strptime("%Y-%m-%d") | mktime)) / 86400 | floor) as $days
  | select($days <= $warn)
  | "\($days)d  \(.name) (\(.service))  → \(.expires_at)  [\(.location // "")]"
' "$MANIFEST")

if [[ -z "$warnings" ]]; then
  $QUIET || echo "✓ No tracked tokens expiring in next $WARN_DAYS days."
  exit 0
fi

echo "⚠️  Token expiry warnings (within $WARN_DAYS days):"
echo "$warnings" | while IFS= read -r line; do echo "   $line"; done
exit 0
