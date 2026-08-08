#!/usr/bin/env bash
# Test: merge_json preserves user keys when adding stack keys.

set -euo pipefail

source "$(dirname "$0")/../scripts/lib/config-merger.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

# User's config with custom keys
cat > "$TMP/target.json" << 'EOF'
{
  "user_pref": "important_value",
  "hooks": {
    "user_custom_hook": "do-something.sh"
  }
}
EOF

# Stack's config to merge in
cat > "$TMP/source.json" << 'EOF'
{
  "stack_managed": true,
  "hooks": {
    "PostToolUse": [{"matcher": "Edit", "command": "tsc"}]
  }
}
EOF

merge_json "$TMP/source.json" "$TMP/target.json"

# Verify user_pref survives
if ! jq -e '.user_pref == "important_value"' "$TMP/target.json" > /dev/null; then
  echo "FAIL: user_pref lost"
  exit 1
fi

# Verify user_custom_hook survives
if ! jq -e '.hooks.user_custom_hook == "do-something.sh"' "$TMP/target.json" > /dev/null; then
  echo "FAIL: user hook lost"
  exit 1
fi

# Verify stack content added
if ! jq -e '.stack_managed == true' "$TMP/target.json" > /dev/null; then
  echo "FAIL: stack content missing"
  exit 1
fi

# --- Scenario 2: scalar conflict, non-interactive → keep user value + report ---
cat > "$TMP/c-target.json" << 'EOF'
{ "shared_setting": "user_value", "only_user": 1 }
EOF
cat > "$TMP/c-source.json" << 'EOF'
{ "shared_setting": "stack_value", "only_stack": 2 }
EOF

STACK_MERGE_NONINTERACTIVE=1 merge_json "$TMP/c-source.json" "$TMP/c-target.json"

# Non-interactive run must keep the user's conflicting value
if ! jq -e '.shared_setting == "user_value"' "$TMP/c-target.json" > /dev/null; then
  echo "FAIL: conflict overwrote user value in non-interactive run"
  exit 1
fi

# Non-conflicting keys from both sides still merge
if ! jq -e '.only_user == 1 and .only_stack == 2' "$TMP/c-target.json" > /dev/null; then
  echo "FAIL: non-conflicting keys lost"
  exit 1
fi

# A conflict report must be written, naming the conflicting path
if ! jq -e 'length == 1 and .[0].path == ["shared_setting"]' \
  "$TMP/c-target.json.merge-conflicts" > /dev/null 2>&1; then
  echo "FAIL: conflict report missing or wrong"
  exit 1
fi

echo "PASS: config merger preserves user data"
