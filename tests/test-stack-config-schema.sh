#!/usr/bin/env bash
# Tests for schemas/stack-config-schema.json and its relationship to
# templates/stack-config.template.json (architect-handoff-carbonet.md, B.6
# "Test plan for schemas/stack-config-schema.json", cases S01-S03).
#
# S01 -> schemas/stack-config-schema.json .properties contains "$schema"
#        (prereq P1 landed and stays landed).
# S02 -> templates/stack-config.template.json passes structural validation
#        against the schema. The repo ships no jsonschema/ajv dependency
#        (see tests/test-permissions-boundary.sh, scripts/stack-sync.sh D7),
#        so this test carries its own minimal jq-based validator: required
#        fields present, and every top-level key whose schema entry has a
#        plain scalar/array/object "type" or an "enum" is checked against it.
# S03 -> every top-level key in the template is present in the schema's
#        properties (closure check, applied upstream of S02).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$REPO_ROOT/schemas/stack-config-schema.json"
TEMPLATE="$REPO_ROOT/templates/stack-config.template.json"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

[[ -f "$SCHEMA" ]] || { echo "FATAL: $SCHEMA not found"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "FATAL: $TEMPLATE not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2 | actual: $3)"; fi
}

# scv_validate <instance-file> <schema-file>
# Minimal structural validator standing in for a real jsonschema/ajv
# dependency (none exists in this repo). Prints one error per line;
# empty output means the instance validates.
scv_validate() {
  local instance="$1" schema="$2"
  jq -nr --slurpfile inst "$instance" --slurpfile sch "$schema" '
    ($inst[0]) as $i |
    ($sch[0]) as $s |
    ($s.required // []) as $req |
    ($s.properties // {}) as $props |
    [ $req[] as $r | select(($i | has($r)) | not) | "missing required field \($r)" ]
    + [ $props | keys[] as $k
        | select($i | has($k))
        | $props[$k] as $p
        | select(($p.type // null) | type == "string")
        | ($i[$k] | type) as $it
        | ($p.type) as $pt
        | select(
            (($pt == "integer") and ($it != "number" or ($i[$k] | floor != $i[$k])))
            or (($pt == "string") and ($it != "string"))
            or (($pt == "boolean") and ($it != "boolean"))
            or (($pt == "array") and ($it != "array"))
            or (($pt == "object") and ($it != "object"))
          )
        | "field \($k) has wrong type: expected \($pt), got \($it)"
      ]
    + [ $props | keys[] as $k
        | select($i | has($k))
        | $props[$k] as $p
        | select(($p.enum // null) != null)
        | select(($p.enum | index($i[$k])) == null)
        | "field \($k) value \($i[$k]) not in enum \($p.enum)"
      ]
    | join("; ")
  '
}

# ═══ S01: schema .properties contains "$schema" ═════════════════════════════
HAS_SCHEMA_PROP="$(jq -r '.properties | has("$schema")' "$SCHEMA")"
assert_eq "S01: schema .properties contains \$schema" "true" "$HAS_SCHEMA_PROP"

SCHEMA_PROP_TYPE="$(jq -r '.properties["$schema"].type // "MISSING"' "$SCHEMA")"
assert_eq "S01: \$schema property has type string" "string" "$SCHEMA_PROP_TYPE"

# ═══ S02: template passes structural validation against the schema ═════════
VALIDATE_ERR="$(scv_validate "$TEMPLATE" "$SCHEMA")"
assert_eq "S02: templates/stack-config.template.json validates against schema" "" "$VALIDATE_ERR"

# S02b — sanity check the validator itself is load-bearing: a required field
# stripped from a copy of the template must fail.
TMP_BAD="$(mktemp)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMP_BAD"' EXIT
jq 'del(.stack_version)' "$TEMPLATE" > "$TMP_BAD"
BAD_ERR="$(scv_validate "$TMP_BAD" "$SCHEMA")"
if [[ -n "$BAD_ERR" ]]; then
  pass "S02b: validator rejects a template missing a required field"
else
  fail "S02b: validator did not catch a missing required field"
fi

# ═══ S03: every top-level key in the template is in the schema's properties ═
TEMPLATE_KEYS="$(jq -r 'keys[]' "$TEMPLATE" | sort)"
UNKNOWN_KEYS=""
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  IN_SCHEMA="$(jq -r --arg k "$key" '.properties | has($k)' "$SCHEMA")"
  if [[ "$IN_SCHEMA" != "true" ]]; then
    UNKNOWN_KEYS="$UNKNOWN_KEYS $key"
  fi
done <<< "$TEMPLATE_KEYS"
assert_eq "S03: every template top-level key is in the schema's properties" "" "$(echo "$UNKNOWN_KEYS" | xargs)"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
