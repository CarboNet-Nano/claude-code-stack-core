#!/usr/bin/env bash
# Fixture: 400 findings (~400KB envelope). Pins the ARG_MAX regression:
# passing an envelope this size through any external command's argv dies
# with "Argument list too long" on ubuntu runners — the first live B4
# run's failure shape, twice (check-side, then runner-side in
# record_result). printf/echo are bash builtins, so emitting from a
# shell variable here is safe; the runner's INGESTION is what this
# fixture stresses.
set -uo pipefail
JOB="$(cat)"
FF="$(mktemp "${TMPDIR:-/tmp}/large-findings.XXXXXX")"
trap 'rm -f "$FF"' EXIT
jq -cn '[range(0;400) | {identity_key:("key-x-"+([.] | implode)), what:("finding number x "+("padding-padding-padding-"*10)), plain:"plain sentence", mechanism:"NEVER RAN", surface:"ci-gate", surface_source:"declared", found_by:"sweep-family-B", evidence:{locus:null, commit:null, measurement:{statement:"s", count:1, denominator:400, source:"static-source"}}, liveness:{assertions_executed:400, assertions_passed:0}, responsible_agent:null, roster_action:null}]' > "$FF"
ENVELOPE_FILE="$(mktemp "${TMPDIR:-/tmp}/large-envelope.XXXXXX")"
trap 'rm -f "$FF" "$ENVELOPE_FILE"' EXIT
jq -c --slurpfile findings "$FF" '. as $job |
  {schema:"sweep-result/v1", check_id:.check_id, evidence_basis:.evidence_basis,
   surface:.surface, status:"fail", universe_size:400, excluded:[],
   assertions_executed:400, assertions_passed:0,
   measurements:[{statement:"units checked",count:400,denominator:400,source:"static-source"}],
   findings:$findings[0], duration_ms:5}' <<<"$JOB" > "$ENVELOPE_FILE"
echo "fixture check: ran"
echo "SWEEP_RESULT:v1 $(base64 < "$ENVELOPE_FILE" | tr -d '\n')"
