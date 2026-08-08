#!/usr/bin/env bash
# Test: BUILTIN keys in session-prefs-init.sh exactly match the session_prefs
# property names in stack-config-schema.json.
#
# This is the "single source of truth" parity check called for in ADR-017.
# Schema-read in bash at runtime is impractical, so BUILTIN stays canonical —
# but this test enforces that the two never drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-prefs-init.sh"
SCHEMA="$REPO_ROOT/schemas/stack-config-schema.json"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

# Extract BUILTIN JSON from the hook (the line that starts with BUILTIN='{...}').
BUILTIN_JSON="$(grep -E "^BUILTIN='" "$HOOK" | sed "s/^BUILTIN='//;s/'$//")"
if [[ -z "$BUILTIN_JSON" ]]; then
  echo "FAIL: could not find BUILTIN= line in $HOOK"
  exit 1
fi

# Keys in BUILTIN, sorted.
BUILTIN_KEYS="$(echo "$BUILTIN_JSON" | jq -r 'keys[]' 2>/dev/null | sort)"
if [[ -z "$BUILTIN_KEYS" ]]; then
  echo "FAIL: BUILTIN JSON is empty or invalid: $BUILTIN_JSON"
  exit 1
fi

# Property names from stack-config-schema.json session_prefs, sorted.
SCHEMA_KEYS="$(jq -r '.properties.session_prefs.properties | keys[]' "$SCHEMA" 2>/dev/null | sort)"
if [[ -z "$SCHEMA_KEYS" ]]; then
  echo "FAIL: could not read session_prefs properties from $SCHEMA"
  exit 1
fi

if [[ "$BUILTIN_KEYS" != "$SCHEMA_KEYS" ]]; then
  echo "FAIL: BUILTIN keys and schema session_prefs keys differ."
  echo "  BUILTIN keys: $(echo "$BUILTIN_KEYS" | tr '\n' ' ')"
  echo "  Schema keys:  $(echo "$SCHEMA_KEYS" | tr '\n' ' ')"
  exit 1
fi

echo "PASS: session-prefs-init.sh BUILTIN keys match stack-config-schema.json session_prefs ($(echo "$BUILTIN_KEYS" | wc -w | tr -d ' ') keys)"
