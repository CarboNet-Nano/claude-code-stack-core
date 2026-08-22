#!/usr/bin/env bash
# scripts/sweep/lib/sweep-config.sh — validation for <repo>/.claude/sweep.config.json
# (stack ADR-078, spec S4.4 / S5.3). Sourceable only; no side effects when sourced.
#
# One public function:
#   sweep_config_validate <repo>
#     -> 0 when the config is usable; otherwise prints one line per violation
#        to stderr and returns 3 (spec S5.4: exit 3 is "configuration invalid").
#
# The rule that gives this file its reason to exist is S4.2 invariant 6
# [RT-5]: the universe of checks is the STACK's installed inventory
# (scripts/sweep/inventory.txt), not the repo's config. Every inventory id
# must appear either as a family block or as a `skips` entry carrying a
# non-empty reason. There is no `enabled` key — flipping a boolean was the
# NEVER RAN mechanism wearing a config file — so an `enabled` key anywhere
# is itself a violation.
#
# SWEEP_INVENTORY_FILE overrides the inventory path (test seam only; the
# CLI in spec S5.4 has no flag for it).

_SWEEP_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SWEEP_CONFIG_STACK_ROOT="$(cd "$_SWEEP_CONFIG_LIB_DIR/../../.." && pwd)"
_SWEEP_CONFIG_SCHEMA="$_SWEEP_CONFIG_STACK_ROOT/schemas/sweep-config.json"

# The structural half of validation is the schema file itself, read by the
# emit library's schema-driven checker — required keys, enum membership and
# additionalProperties:false at every declared object level. Restating the
# schema in bash was a second copy of sweep-config/v1 that could drift from
# the first. Only the rules a JSON schema cannot express stay bespoke here.
# shellcheck source=/dev/null
command -v _sweep_schema_errors >/dev/null 2>&1 || source "$_SWEEP_CONFIG_LIB_DIR/sweep-emit.sh"

sweep_config_path() { echo "$1/.claude/sweep.config.json"; }

sweep_inventory_path() {
  echo "${SWEEP_INVENTORY_FILE:-$_SWEEP_CONFIG_STACK_ROOT/scripts/sweep/inventory.txt}"
}

# sweep_inventory_ids -> one check id per line, comments and blanks dropped.
sweep_inventory_ids() {
  local inv; inv="$(sweep_inventory_path)"
  [[ -f "$inv" ]] || return 1
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$inv" | grep -v '^$'
}

# _sweep_config_schema_violations <config-json-file>
# -> one line per sweep-config/v1 structural violation, read from the
# schema file rather than restated here.
_sweep_config_schema_violations() {
  [[ -f "$_SWEEP_CONFIG_SCHEMA" ]] || { echo "the sweep-config/v1 schema is missing from this install"; return 0; }
  _sweep_schema_errors "$_SWEEP_CONFIG_SCHEMA" < "$1" \
    | jq -r '.[] | "does not satisfy sweep-config/v1 (\(.))"'
}

# _sweep_config_violations <config-json-file> <inventory-ids-file>
# -> one violation string per line for the rules a JSON schema cannot
# express: the inventory relation (both directions), the absence of an
# `enabled` key, and reasons that are present but blank.
_sweep_config_violations() {
  jq -r --rawfile inv "$2" '
    def blank($s): ($s // "") | tostring | gsub("^\\s+|\\s+$"; "") | length == 0;
    . as $c |
    ($inv | split("\n") | map(select(length > 0))) as $inventory |
    ["observe","warn","block"] as $modes |
    ($c.families // {}) as $fam |
    ($c.skips // []) as $skips |
    ([ ($c.check_modes // {}) | to_entries[] | . as $e | select(($modes | index($e.value)) == null) | "check_modes.\($e.key) must be one of observe|warn|block (got: \($e.value))" ]
     + (if ([$c | paths | .[-1] | select(type == "string" and . == "enabled")] | length) > 0
        then ["an `enabled` key is present — sweep-config/v1 has no enabled flag [RT-5]; the only way not to run a check is a skip with a reason"] else [] end)
     + [ $skips[] | select(blank(.reason)) | "skips entry for `\(.check_id // "(no check_id)")` has a blank reason — turning a check off costs a sentence" ]
     + [ $fam | keys[] | select(. as $k | $inventory | index($k) | not) | "families.\(.) is not in the installed check inventory" ]
     + [ $inventory[] | . as $id
         | select(($fam | has($id)) | not)
         | select([ $skips[] | select(.check_id == $id and (blank(.reason) | not)) ] | length == 0)
         | "check `\($id)` is in the installed inventory but is neither declared nor skipped with a reason [RT-5]" ]
    )[]
  ' "$1"
}

# _sweep_config_surface_violations <config-json-file> -> per-check surface,
# adapter and exclusion-reason violations (S4.4 items 2 and 4).
_sweep_config_surface_violations() {
  jq -r '
    def blank($s): ($s // "") | tostring | gsub("^\\s+|\\s+$"; "") | length == 0;
    ["write-path","read-path","schema","ci-gate","ui-route","scheduled-job",
     "external-integration","scale","docs"] as $surfaces |
    . as $c | ($c.families // {}) as $fam | ($c.surfaces // {}) as $decl |
    ([ $fam | keys[] | . as $id | select(($decl | has($id)) | not)
       | "surfaces.\($id) is missing — surface is declared per check, never inferred [ARCH-1]" ]
     + [ $decl | to_entries[] | . as $e | select(($surfaces | index($e.value)) == null)
       | "surfaces.\($e.key) is not a member of the surface enum (got: \($e.value))" ]
     + [ $fam | to_entries[] | .key as $id | .value
       | (.exclusions // []) + (.write_never // [])
       | .[] | select(blank(.reason))
       | "families.\($id) excludes `\(.unit // "(no unit)")` with a blank reason — every exclusion carries a reason [B2]" ]
     + (if ($fam | has("E1")) and (blank($fam.E1.route_manifest_cmd))
        then ["families.E1.route_manifest_cmd is missing — E1 has no route-manifest adapter to enumerate its universe [RT-9]"] else [] end)
    )[]
  ' "$1"
}

# sweep_config_validate <repo> -> 0, or violations on stderr and return 3.
sweep_config_validate() {
  local repo="$1" cfg inv_ids violations
  cfg="$(sweep_config_path "$repo")"
  if [[ ! -f "$cfg" ]]; then
    echo "sweep-config: $cfg does not exist — every repo the Sweep runs in declares one" >&2
    return 3
  fi
  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    echo "sweep-config: $cfg is not valid JSON" >&2
    return 3
  fi
  inv_ids="$(mktemp "${TMPDIR:-/tmp}/sweep-inv.XXXXXX")" || return 3
  if ! sweep_inventory_ids > "$inv_ids"; then
    rm -f "$inv_ids"
    echo "sweep-config: the installed check inventory ($(sweep_inventory_path)) is missing" >&2
    return 3
  fi
  # A jq failure is never a silent pass: the validator's own error is a
  # violation, or a config could be waved through by breaking the checker.
  violations="$(_sweep_config_schema_violations "$cfg"; _sweep_config_violations "$cfg" "$inv_ids")" \
    || violations="$violations
the validator itself failed on this config — treated as invalid"
  local surface_violations
  surface_violations="$(_sweep_config_surface_violations "$cfg")" \
    || surface_violations="$surface_violations
the surface validator itself failed on this config — treated as invalid"
  rm -f "$inv_ids"
  violations="$(printf '%s\n%s\n' "$violations" "$surface_violations" | grep -v '^$')"
  [[ -z "$violations" ]] && return 0
  echo "$violations" | sed 's/^/sweep-config: /' >&2
  return 3
}
