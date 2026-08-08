#!/usr/bin/env bash
# Test: nested SessionStart hooks from multiple tiers merge correctly.
# Tier 0 ships a SessionStart hook for handoff loading.
# Tier 2 may add a SessionStart hook for cost-log opening.
# After merge, settings.json must have BOTH hooks under SessionStart.
#
# This test exists because Claude's deep_merge logic must concatenate
# arrays inside hook objects, not overwrite — and the SessionStart key
# in particular is an array of hook-group objects (each with its own
# inner hooks array). Easy to get wrong.

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
source "$SCRIPT_DIR/../scripts/lib/config-merger.sh"
TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

# Simulate Tier 0 settings (handoff hook)
cat > "$TMPDIR/tier-0-settings.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-start-handoff.sh" }
        ]
      }
    ]
  }
}
EOF

# Simulate Tier 2 additions (cost-log open hook)
cat > "$TMPDIR/tier-2-settings.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-start-cost-log.sh" }
        ]
      }
    ]
  }
}
EOF

# Run merger: merge_json merges SOURCE into TARGET in place
cp "$TMPDIR/tier-0-settings.json" "$TMPDIR/merged.json"
merge_json "$TMPDIR/tier-2-settings.json" "$TMPDIR/merged.json"

# Assertions
failures=0

# 1. Merged file must be valid JSON
if ! python3 -m json.tool < "$TMPDIR/merged.json" > /dev/null 2>&1; then
  echo "FAIL: merged.json is not valid JSON"
  failures=$((failures + 1))
fi

# 2. SessionStart must contain BOTH hook groups (concatenated, not overwritten)
session_start_count=$(python3 -c "
import json
with open('$TMPDIR/merged.json') as f:
    data = json.load(f)
hook_count = 0
for group in data.get('hooks', {}).get('SessionStart', []):
    hook_count += len(group.get('hooks', []))
print(hook_count)
")

if [ "$session_start_count" -ne 2 ]; then
  echo "FAIL: expected 2 SessionStart hooks after merge, got $session_start_count"
  failures=$((failures + 1))
fi

# 3. Both specific commands must be present
if ! grep -q "session-start-handoff.sh" "$TMPDIR/merged.json"; then
  echo "FAIL: tier-0 handoff hook missing from merged output"
  failures=$((failures + 1))
fi

if ! grep -q "session-start-cost-log.sh" "$TMPDIR/merged.json"; then
  echo "FAIL: tier-2 cost-log hook missing from merged output"
  failures=$((failures + 1))
fi

# 4. Test a three-way merge (simulate adding Tier 4 with another SessionStart hook)
cat > "$TMPDIR/tier-4-settings.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-start-historian.sh" }
        ]
      }
    ]
  }
}
EOF

cp "$TMPDIR/merged.json" "$TMPDIR/merged-3way.json"
merge_json "$TMPDIR/tier-4-settings.json" "$TMPDIR/merged-3way.json"

three_way_count=$(python3 -c "
import json
with open('$TMPDIR/merged-3way.json') as f:
    data = json.load(f)
hook_count = 0
for group in data.get('hooks', {}).get('SessionStart', []):
    hook_count += len(group.get('hooks', []))
print(hook_count)
")

if [ "$three_way_count" -ne 3 ]; then
  echo "FAIL: expected 3 SessionStart hooks after 3-way merge, got $three_way_count"
  failures=$((failures + 1))
fi

# Report
if [ "$failures" -eq 0 ]; then
  echo "PASS: nested SessionStart hooks merge correctly (2-way and 3-way)"
  exit 0
else
  echo "FAILED: $failures assertions failed"
  echo "Merged 2-way output:"
  cat "$TMPDIR/merged.json"
  echo ""
  echo "Merged 3-way output:"
  cat "$TMPDIR/merged-3way.json"
  exit 1
fi
