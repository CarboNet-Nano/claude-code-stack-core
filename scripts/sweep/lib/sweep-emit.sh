#!/usr/bin/env bash
# scripts/sweep/lib/sweep-emit.sh — the Sweep emit library (stack ADR-078,
# spec §5.4). Sourceable only; has no side effects when sourced (matches
# scripts/lib/usage-check-common.sh's convention).
#
# Two public functions:
#   sweep_finding_id <repo> <check_id> <mechanism> <locus> <identity_key>
#     -> 16-hex-char id on stdout. finding_id = sha256(repo + check_id +
#     mechanism + normalized_locus + identity_key)[:16] (spec §4.3, RT-10).
#     `what` is never a hash input — it is human prose that drifts between
#     runs, and hashing it would mint a new id every run.
#   sweep_emit_finding <findings.jsonl path> <record-json>
#     -> appends one compact JSON line, or returns non-zero with exactly
#     one stderr line naming the refused rule (R1-R7 below).
#
# Refusal rules (spec §4.3/§5.2, G8, and the controller ruling on R2/R6):
#   R1  identity_key looks like run identity (UUID/ISO-8601 timestamp/4+
#       digit run), not a stable finding identity.
#   R2  record carries a `status` key AND found_by is machine-emitted
#       (starts sweep-family- OR equals ci-self-audit). Dispositions are
#       written only by humans/foreman (controller ruling: extends the
#       brief's sweep-family- only wording to ci-self-audit rows too).
#   R3  `plain` missing/empty, or leaks a check id / file extension —
#       `plain` is the G7 unit and must read as one plain-English sentence.
#   R4  `evidence.measurement.count` missing — no finding without a
#       counted measurement (spec §5.2 hard invariant).
#   R5  G8 value-free evidence. Gated on evidence.measurement.source in
#       {generated-world, production-data} (only connection-bearing checks
#       can leak a cell value): refuse if `evidence` carries a key outside
#       {commit, locus, measurement}, if `what` exceeds 300 chars, or if
#       the record contains the planted-token env SWEEP_LEAK_CANARY
#       anywhere (phase-3 leak proof).
#   R6  `surface` absent (or explicitly null) while found_by starts
#       sweep-family- — surface is declared, never guessed, for every
#       check family (controller ruling: this rule stays narrower than R2
#       and must NOT reject ci-self-audit rows carrying a declared
#       surface, e.g. the future sweep.vacuous-check meta-finding).
#   R7  record fails the finding-record/v1 schema (schemas/finding-record.json)
#       — required keys, enum membership, additionalProperties:false at
#       every declared object level, and the evidence commit-or-locus
#       anyOf. A targeted, schema-driven jq check (not a generic engine),
#       done at emit time — this is the library's own validation, not a
#       reuse of tests/test-sweep-schemas.sh's harness.

_SWEEP_EMIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SWEEP_EMIT_REPO_ROOT="$(cd "$_SWEEP_EMIT_LIB_DIR/../../.." && pwd)"
_SWEEP_EMIT_SCHEMA="$_SWEEP_EMIT_REPO_ROOT/schemas/finding-record.json"

# _sweep_sha256 -> reads stdin, echoes the hex sha256 digest.
# Portable shasum/sha256sum pick (scripts/gen-portable-core-manifest.sh
# precedent) — no new dependency (Karpathy rule 8).
_sweep_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else return 1; fi
}

# sweep_finding_id <repo> <check_id> <mechanism> <locus> <identity_key>
# -> 16-hex-char id on stdout. Deterministic; `what` is not an input.
sweep_finding_id() {
  local repo="$1" check_id="$2" mechanism="$3" locus="$4" identity_key="$5"
  printf '%s%s%s%s%s' "$repo" "$check_id" "$mechanism" "$locus" "$identity_key" \
    | _sweep_sha256 | cut -c1-16
}

# _sweep_schema_errors <schema-file> -> reads a compact JSON instance on
# stdin, echoes a JSON array of error strings (empty array = valid).
# Schema-driven (reads required/enum/additionalProperties/anyOf from the
# schema file itself), recursing only into properties the schema declares
# type:object for — a targeted checker for finding-record/v1's known
# nesting (evidence, evidence.measurement, liveness), not a generic $ref/
# oneOf engine (controller precedent, task-2-report.md).
_sweep_schema_errors() {
  local schema="$1" instance
  instance="$(cat)"
  jq -c --slurpfile sch "$schema" '
    ($sch[0]) as $s |
    . as $i |
    def node_errs($obj; $node; $path):
      ($node.properties // {}) as $props |
      ($node.required // []) as $req |
      (if ($node.additionalProperties == false) then
         [ ($obj // {} | keys[]) as $k | select(($props | has($k)) | not) | "extra:\($path).\($k)" ]
       else [] end) as $extra |
      ([ $req[] as $r | select(($obj // {} | has($r)) | not) | "missing:\($path).\($r)" ]) as $missing |
      ([ $props | keys[] as $k
         | select(($obj // {}) | has($k))
         | ($props[$k]) as $child
         | ($obj[$k]) as $cv
         | ( if ($child.enum // null) != null and (($child.enum | index($cv)) == null)
             then ["enum:\($path).\($k)"] else [] end )
           + ( if ($child.type // null) == "object"
               then node_errs($cv; $child; "\($path).\($k)") else [] end )
       ] | flatten) as $nested |
      ($extra + $missing + $nested);
    (node_errs($i; $s; "")) as $struct_errors |
    ((($s.properties.evidence.anyOf // []) | length) > 0) as $has_evidence_anyof |
    ($has_evidence_anyof and (($i.evidence.commit // null) == null) and (($i.evidence.locus // null) == null)) as $evidence_anyof_fail |
    ($struct_errors + (if $evidence_anyof_fail then ["evidence:commit-or-locus-required"] else [] end))
  ' <<<"$instance"
}

# sweep_emit_finding <findings.jsonl path> <record-json>
# -> appends one compact JSON line to <findings.jsonl path>, or returns
# non-zero with exactly one stderr line naming the refused rule.
sweep_emit_finding() {
  local findings_path="${1:-}" record="${2:-}"
  if [[ -z "$findings_path" || -z "$record" ]]; then
    echo "sweep_emit_finding: usage: sweep_emit_finding <findings.jsonl path> <record-json>" >&2
    return 2
  fi

  local compact
  compact="$(jq -c '.' <<<"$record" 2>/dev/null)" || {
    echo "sweep_emit_finding: refused (R7 not valid JSON)" >&2
    return 1
  }

  local identity_key
  identity_key="$(jq -r '.identity_key // empty' <<<"$compact")"
  if [[ "$identity_key" =~ [0-9a-f]{8}-[0-9a-f]{4} ]] \
    || [[ "$identity_key" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T ]] \
    || [[ "$identity_key" =~ [0-9]{4,} ]]; then
    echo "sweep_emit_finding: refused (R1 identity_key looks like run identity — UUID, ISO-8601 timestamp, or a 4+ digit run — not a stable finding identity)" >&2
    return 1
  fi

  local has_status found_by
  has_status="$(jq -r 'has("status")' <<<"$compact")"
  found_by="$(jq -r '.found_by // empty' <<<"$compact")"
  if [[ "$has_status" == "true" ]] && { [[ "$found_by" == sweep-family-* ]] || [[ "$found_by" == "ci-self-audit" ]]; }; then
    echo "sweep_emit_finding: refused (R2 status is refused on machine-emitted rows — dispositions come only from humans/foreman)" >&2
    return 1
  fi

  local plain
  plain="$(jq -r '.plain // empty' <<<"$compact")"
  if [[ -z "$plain" ]] \
    || echo "$plain" | grep -Eq '\.(ts|tsx|js|mjs|sh|py)\b' \
    || echo "$plain" | grep -Eq '\b[A-G][0-9]\b'; then
    echo "sweep_emit_finding: refused (R3 plain missing/empty, or leaks a check id or file path)" >&2
    return 1
  fi

  local has_count
  has_count="$(jq -r '(.evidence.measurement.count // null) != null' <<<"$compact")"
  if [[ "$has_count" != "true" ]]; then
    echo "sweep_emit_finding: refused (R4 evidence.measurement.count is missing)" >&2
    return 1
  fi

  local source
  source="$(jq -r '.evidence.measurement.source // empty' <<<"$compact")"
  if [[ "$source" == "generated-world" || "$source" == "production-data" ]]; then
    local extra_evidence_keys what_len
    extra_evidence_keys="$(jq -r '[(.evidence // {}) | keys[] | select(. as $k | ["commit","locus","measurement"] | index($k) | not)] | length' <<<"$compact")"
    what_len="$(jq -r '(.what // "") | length' <<<"$compact")"
    if [[ "$extra_evidence_keys" != "0" || "$what_len" -gt 300 ]]; then
      echo "sweep_emit_finding: refused (R5 G8 value-free evidence — evidence carries a key outside the allowlist, or what exceeds 300 chars)" >&2
      return 1
    fi
    if [[ -n "${SWEEP_LEAK_CANARY:-}" && "$compact" == *"$SWEEP_LEAK_CANARY"* ]]; then
      echo "sweep_emit_finding: refused (R5 G8 planted-token canary found in the record)" >&2
      return 1
    fi
  fi

  if [[ "$found_by" == sweep-family-* ]]; then
    local surface_declared
    surface_declared="$(jq -r 'if has("surface") and (.surface != null) then "1" else "0" end' <<<"$compact")"
    if [[ "$surface_declared" != "1" ]]; then
      echo "sweep_emit_finding: refused (R6 surface is absent — every sweep-family- row must declare surface)" >&2
      return 1
    fi
  fi

  local schema_errors_n
  schema_errors_n="$(_sweep_schema_errors "$_SWEEP_EMIT_SCHEMA" <<<"$compact" | jq 'length')"
  if [[ "$schema_errors_n" != "0" ]]; then
    echo "sweep_emit_finding: refused (R7 record fails the finding-record/v1 schema)" >&2
    return 1
  fi

  # Same finding_id already on file -> silent no-op, exit 0 — but ONLY
  # for check-emitted rows (no `status` key). This is the loop-termination
  # property for the per-merge writer: its findings commit triggers
  # another push run that re-finds the same defects, and a re-append
  # would change the tree every run and commit forever. Disposition rows
  # DO carry `status` and share the finding's id by design — resolve's
  # newest-row-wins depends on them appending, and they come from a human
  # or the roster, never from the writer's own cycle, so they cannot feed
  # the loop. The book stays append-only; it just never appends the same
  # check-emitted fact twice.
  local _fid _has_status
  _fid="$(jq -r '.finding_id // ""' <<<"$compact")"
  _has_status="$(jq -r 'has("status")' <<<"$compact")"
  if [[ "$_has_status" != "true" && -n "$_fid" && -f "$findings_path" ]] \
     && grep -qF "\"finding_id\":\"$_fid\"" "$findings_path"; then
    return 0
  fi
  printf '%s\n' "$compact" >> "$findings_path"
}
