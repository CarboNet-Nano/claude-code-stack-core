#!/usr/bin/env bash
# Tests for schemas/finding-record.json (finding-record/v1, stack ADR-078
# phase 0). Confirms the schema exists, accepts a well-formed record, and
# rejects records missing required fields or carrying a bad enum value.
#
# No jsonschema/ajv dependency ships in this repo (Karpathy rule 8 —
# every package is permanent code someone else updates on a schedule you
# don't control). check_against_schema uses Ajv via `node -e` when a local
# `ajv` module is resolvable, and otherwise falls back to a jq structural
# check: required keys present, enum membership on every enum-typed
# property (top-level and nested), additionalProperties:false enforcement
# (recursive, key-set comparison read from the schema itself) so an
# `enabled` key anywhere is caught, minLength enforcement on string
# properties that declare it (e.g. skips[].reason), and enum membership on
# additionalProperties-as-map values (e.g. surfaces.<check_id>). This is a
# deliberately narrow structural checker, not a generic JSON Schema engine
# — no $ref, no oneOf/patternProperties. finding-record.json's
# evidence-requires-commit-or-locus anyOf is schema-driven (only fires
# when the schema being validated actually declares
# properties.evidence.anyOf), so it does not leak into other schemas.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }

# check_against_schema <schema-file>
# Reads a JSON instance on stdin. Exit 0 = valid, non-zero = invalid.
check_against_schema() {
  local schema="$1" instance
  instance="$(cat)"

  if node -e "require.resolve('ajv')" >/dev/null 2>&1; then
    node -e '
      const Ajv = require("ajv");
      const fs = require("fs");
      const ajv = new Ajv({ allErrors: true, strict: false });
      const schema = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const instance = JSON.parse(fs.readFileSync(0, "utf8"));
      const validate = ajv.compile(schema);
      process.exit(validate(instance) ? 0 : 1);
    ' "$schema" <<<"$instance"
    return $?
  fi

  jq -e --slurpfile sch "$schema" '
    ($sch[0]) as $s |
    . as $i |
    def enum_errors($obj; $props):
      [ $props | keys[] as $k
        | select($obj | has($k))
        | $props[$k] as $p
        | select(($p.enum // null) != null)
        | select(($p.enum | index($obj[$k])) == null)
        | "enum" ];
    # node_errors: additionalProperties:false (extra-key rejection),
    # additionalProperties-as-map enum checks (e.g. surfaces.<id>), and
    # minLength on string properties — applied recursively wherever the
    # schema itself declares them. Not a generic engine: no $ref,
    # no oneOf/patternProperties, no recursive `required`.
    def node_errors($obj; $node; $path):
      (if ($node.additionalProperties == false) then
         (($node.properties // {}) as $props
          | [ ($obj // {} | keys[]) as $k | select(($props | has($k)) | not) | "extra:\($path).\($k)" ])
       else [] end) as $extra |
      (if (($node.additionalProperties // null) | type) == "object" then
         (($node.additionalProperties.enum // null)) as $en
         | if $en != null then
             [ ($obj // {} | keys[]) as $k | select(($en | index($obj[$k])) == null) | "enum:\($path).\($k)" ]
           else [] end
       else [] end) as $mapenum |
      ([ (($node.properties // {}) | keys[]) as $k
         | select(($obj // {}) | has($k))
         | ($node.properties[$k]) as $child
         | ($obj[$k]) as $cv
         | if ($child.type // null) == "object" then
             node_errors($cv; $child; "\($path).\($k)")
           elif ($child.type // null) == "array" then
             ( ($cv // []) | to_entries | map( node_errors(.value; ($child.items // {}); "\($path).\($k)[\(.key)]") ) | flatten )
           elif (($child.minLength // null) != null) then
             (if (($cv|type)=="string") and (($cv|length) < $child.minLength) then ["minLength:\($path).\($k)"] else [] end)
           else []
           end
       ] | flatten) as $nested |
      ($extra + $mapenum + $nested);
    ($s.required // []) as $req |
    [ $req[] as $r | select(($i | has($r)) | not) | "missing:\($r)" ] as $missing_top |
    (enum_errors($i; $s.properties // {})) as $enum_top |
    (node_errors($i; $s; "")) as $node_level_errors |
    ((($s.properties.evidence.anyOf // []) | length) > 0) as $has_evidence_anyof |
    (($s.properties.evidence.required // [])
      - ["commit","locus"]) as $ev_req_minus_anyof |
    ([ $ev_req_minus_anyof[] as $r
        | select(($i.evidence // {} | has($r)) | not)
        | "missing:evidence.\($r)" ]) as $missing_evidence |
    ($has_evidence_anyof and (($i.evidence.commit // null) == null) and (($i.evidence.locus // null) == null)) as $evidence_anyof_fail |
    (($s.properties.evidence.properties.measurement.required // []) as $mreq
      | [ $mreq[] as $r
          | select((($i.evidence.measurement // {}) | has($r)) | not)
          | "missing:evidence.measurement.\($r)" ]) as $missing_measurement |
    (enum_errors($i.evidence.measurement // {}; $s.properties.evidence.properties.measurement.properties // {})) as $enum_measurement |
    ($missing_top + $enum_top + $node_level_errors + $missing_evidence + $missing_measurement + $enum_measurement
      + (if $evidence_anyof_fail then ["evidence:commit-or-locus-required"] else [] end)
    ) as $errors |
    ($errors | length) == 0
  ' >/dev/null 2>&1 <<<"$instance"
}

SCHEMA="$REPO_ROOT/schemas/finding-record.json"
VALID='{"schema":"finding-record/v1","finding_id":"3f9a1c77b2e04d51","identity_key":"products","run_id":"2026-08-16T02:00:00Z.a1b2c3","repo":"manufacturing-dashboard","created_at":"2026-08-16T02:00:04Z","what":"filterStateToParams emits products; routes read product","plain":"The dashboard filter sends a name the page never looks for, so filtering silently does nothing.","mechanism":"DISCONNECTED","surface":"read-path","surface_source":"declared","found_by":"sweep-family-A","evidence":{"commit":"73c23b53","locus":"apps/web/src/lib/filter-params.ts:88","measurement":{"statement":"producer keys with zero consumers","count":2,"denominator":41,"source":"static-source"}},"liveness":{"assertions_executed":41,"assertions_passed":39},"responsible_agent":null,"roster_action":null}'

t_schema_exists()  { [ -f "$SCHEMA" ] && jq -e '."$schema"' "$SCHEMA" >/dev/null && pass "schema file valid json" || fail "schema file valid json"; }
t_valid_accepts()  { echo "$VALID" | check_against_schema "$SCHEMA" && pass "valid record accepted" || fail "valid record accepted"; }
t_missing_plain()  { echo "$VALID" | jq 'del(.plain)' | check_against_schema "$SCHEMA" && fail "missing plain rejected" || pass "missing plain rejected"; }
t_missing_measurement() { echo "$VALID" | jq 'del(.evidence.measurement)' | check_against_schema "$SCHEMA" && fail "missing measurement rejected" || pass "missing measurement rejected"; }
t_bad_mechanism()  { echo "$VALID" | jq '.mechanism="TYPO"' | check_against_schema "$SCHEMA" && fail "bad mechanism rejected" || pass "bad mechanism rejected"; }
t_no_enabled_anywhere() { grep -q '"enabled"' "$SCHEMA" && fail "no enabled key" || pass "no enabled key"; }

t_schema_exists
t_valid_accepts
t_missing_plain
t_missing_measurement
t_bad_mechanism
t_no_enabled_anywhere

# --- schemas/sweep-config.json (sweep-config/v1, stack ADR-078 phase 1) ---
# Confirms the schema exists, accepts a §5.3 skeleton minus phase-3 blocks
# (no connections, no C2/C3/D0a/D0b), and rejects a config carrying an
# `enabled` key anywhere (RT-5, additionalProperties), a blank skips reason
# (minLength), or a surfaces value outside the closed enum.

CONFIG_SCHEMA="$REPO_ROOT/schemas/sweep-config.json"
VALID_CONFIG='{"schema":"sweep-config/v1","mode":"observe","check_modes":{"B1":"block","B5":"block","E1":"warn"},"surfaces":{"A1":"write-path","A2":"read-path","A4":"schema","E1":"ui-route","B4":"ci-gate","B3":"scheduled-job"},"families":{"A1":{"writer_globs":["packages/api/src/lib/**/*.ts"],"exclusions":[]},"A2":{"producers":["apps/forecast-v2/src/lib/filter-params.ts#filterStateToParams"],"consumer_globs":["packages/api/src/routes/**/*.ts"],"exclusions":[]},"A4":{"tables":["forecast_orders","forecast_miss_events"],"write_path_globs":["packages/api/src/lib/**"],"write_never":[{"unit":"forecast_orders.legacy_note","reason":"read-only import artifact, ADR-041"}]},"E1":{"app":"apps/forecast-v2","route_manifest_cmd":"sweep-adapters/nextjs-app-router.sh src/app","base_url_env":"SWEEP_BASE_URL","exclusions":[]},"B3":{"jobs":[{"id":"downside-sweep","expected_effect_sql":"select count(*) from forecast_orders where status = missed and updated_at > now() minus interval 48 hours","min_rows":1}]},"B4":{}},"skips":[{"check_id":"F1","reason":"phase 4, not built yet"}]}'

t_config_schema_exists() { [ -f "$CONFIG_SCHEMA" ] && jq -e '."$schema"' "$CONFIG_SCHEMA" >/dev/null && pass "sweep-config schema file valid json" || fail "sweep-config schema file valid json"; }
t_config_valid_skeleton_accepts() { echo "$VALID_CONFIG" | check_against_schema "$CONFIG_SCHEMA" && pass "valid §5.3 skeleton (minus phase-3 blocks) accepted" || fail "valid §5.3 skeleton (minus phase-3 blocks) accepted"; }
t_config_enabled_key_rejected() { echo "$VALID_CONFIG" | jq '.families.A1.enabled=true' | check_against_schema "$CONFIG_SCHEMA" && fail "enabled key anywhere rejected" || pass "enabled key anywhere rejected"; }
t_config_blank_skip_reason_rejected() { echo "$VALID_CONFIG" | jq '.skips[0].reason=""' | check_against_schema "$CONFIG_SCHEMA" && fail "blank skips reason rejected" || pass "blank skips reason rejected"; }
t_config_surface_enum_rejected() { echo "$VALID_CONFIG" | jq '.surfaces.A1="not-a-real-surface"' | check_against_schema "$CONFIG_SCHEMA" && fail "surfaces value outside closed enum rejected" || pass "surfaces value outside closed enum rejected"; }

# Fix round 2, IMPORTANT (I3): B4's universe is every commit that landed on
# main in the window, so a repo that genuinely had no landings reports 0 and
# trips invariant 2. `empty_universe_ok` is the declared, reasoned exemption
# — a STRING, never a boolean, because the reason is the whole point (a
# boolean here would be the `enabled` flag wearing a new name, RT-5). It is
# B4's alone: no other family may declare it.
t_config_b4_empty_universe_ok_accepted() { echo "$VALID_CONFIG" | jq '.families.B4.empty_universe_ok="this repo squash-merges; some 30-day windows have no landings at all"' | check_against_schema "$CONFIG_SCHEMA" && pass "B4 empty_universe_ok (string) accepted" || fail "B4 empty_universe_ok (string) accepted"; }
t_config_b4_empty_universe_ok_blank_rejected() { echo "$VALID_CONFIG" | jq '.families.B4.empty_universe_ok=""' | check_against_schema "$CONFIG_SCHEMA" && fail "B4 empty_universe_ok blank string rejected" || pass "B4 empty_universe_ok blank string rejected"; }
# The boolean case (`empty_universe_ok: true` — the `enabled` flag wearing a
# new name) is NOT asserted here: the schema declares type:string, but this
# file's jq fallback checker enforces required/enum/additionalProperties/
# minLength and not `type`, so the assertion would only hold on machines
# where ajv happens to resolve. It is pinned where it can actually hurt
# instead — tests/test-sweep-runner.sh asserts the RUNNER refuses a
# non-string declaration and still exits 2 on an empty universe.
t_config_other_family_empty_universe_ok_rejected() { echo "$VALID_CONFIG" | jq '.families.A1.empty_universe_ok="we do not check writers here"' | check_against_schema "$CONFIG_SCHEMA" && fail "empty_universe_ok on a non-B4 family rejected" || pass "empty_universe_ok on a non-B4 family rejected"; }

# PC1 (2026-08-18 new-user-setup-rev2 plan, task 6, controller ruling on the
# task-6 review): PC1 is in scripts/sweep/inventory.txt, so a repo MUST be
# able to legally declare it — otherwise B5's invariant-6 gate reddens at
# every stack-pin bump with no remedy but a permanent skips entry. No
# GitHub API or app knobs, so the family block is legally just `{}`, same
# minimal shape B4 uses without empty_universe_ok.
t_config_pc1_family_accepted() { echo "$VALID_CONFIG" | jq '.families.PC1={} | .surfaces.PC1="docs"' | check_against_schema "$CONFIG_SCHEMA" && pass "PC1 family (empty object) accepted" || fail "PC1 family (empty object) accepted"; }
t_config_pc1_family_extra_key_rejected() { echo "$VALID_CONFIG" | jq '.families.PC1={"route_manifest_cmd":"echo /"} | .surfaces.PC1="docs"' | check_against_schema "$CONFIG_SCHEMA" && fail "PC1 family rejects any key (no knobs declared)" || pass "PC1 family rejects any key (no knobs declared)"; }
# --- W1 (surface walk) family block -----------------------------------
# W1 sits outside the A-G phase lettering (PC1's precedent) and reuses
# E1's adapter seam verbatim, adding only walk_manifest. These assertions
# read the schema structurally rather than validating an instance: the
# point is that the BLOCK is declared with the right key set, which no
# instance check would pin.
t_config_w1_block_declared() {
  local keys
  keys="$(jq -r '.properties.families.properties.W1.properties | keys | sort | join(",")' "$CONFIG_SCHEMA")"
  [ "$keys" = "base_url_env,exclusions,route_manifest_cmd,walk_manifest" ] \
    && pass "families.W1 declares exactly base_url_env, exclusions, route_manifest_cmd, walk_manifest" \
    || fail "families.W1 key set is '$keys'"
}

t_config_w1_requires_the_three_load_bearing_keys() {
  local req
  req="$(jq -r '.properties.families.properties.W1.required | sort | join(",")' "$CONFIG_SCHEMA")"
  [ "$req" = "base_url_env,route_manifest_cmd,walk_manifest" ] \
    && pass "families.W1 requires base_url_env, route_manifest_cmd, walk_manifest (exclusions stays optional)" \
    || fail "families.W1 required set is '$req'"
}

t_config_w1_forbids_unknown_keys() {
  local addl
  addl="$(jq -r '.properties.families.properties.W1.additionalProperties' "$CONFIG_SCHEMA")"
  [ "$addl" = "false" ] \
    && pass "families.W1 refuses unknown keys — a typo is a config error, not a silent default" \
    || fail "families.W1 additionalProperties is '$addl', expected false"
}

# A W1 block carrying every required key validates; one missing a required
# key does not. This is the instance-level pair for the structural three
# above, run through the same checker every other family uses.
t_config_w1_wellformed_block_accepted() {
  echo "$VALID_CONFIG" \
    | jq '.surfaces.W1="ui-route" | .families.W1={base_url_env:"STAGING_URL",route_manifest_cmd:"npm run routes",walk_manifest:"sweep/walk.json"}' \
    | check_against_schema "$CONFIG_SCHEMA" \
    && pass "a W1 block with all three required keys is accepted" \
    || fail "a W1 block with all three required keys is accepted"
}

t_config_w1_unknown_key_rejected() {
  echo "$VALID_CONFIG" \
    | jq '.surfaces.W1="ui-route" | .families.W1={base_url_env:"STAGING_URL",route_manifest_cmd:"npm run routes",walk_manifest:"sweep/walk.json",screenshot_baseline:"shots/"}' \
    | check_against_schema "$CONFIG_SCHEMA" \
    && fail "a W1 block carrying an undeclared key is rejected" \
    || pass "a W1 block carrying an undeclared key is rejected"
}

t_config_schema_exists
t_config_valid_skeleton_accepts
t_config_enabled_key_rejected
t_config_blank_skip_reason_rejected
t_config_surface_enum_rejected
t_config_b4_empty_universe_ok_accepted
t_config_b4_empty_universe_ok_blank_rejected
t_config_other_family_empty_universe_ok_rejected
t_config_pc1_family_accepted
t_config_pc1_family_extra_key_rejected
t_config_w1_block_declared
t_config_w1_requires_the_three_load_bearing_keys
t_config_w1_forbids_unknown_keys
t_config_w1_wellformed_block_accepted
t_config_w1_unknown_key_rejected

echo "----"
echo "test-sweep-schemas: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
