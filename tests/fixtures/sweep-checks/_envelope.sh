#!/usr/bin/env bash
# Shared helper for the runner's fixture checks (tests/test-sweep-runner.sh).
# Each fixture reads a sweep-job/v1 on stdin and prints one
# `SWEEP_RESULT:v1 <base64>` line last, exactly like a real check
# (spec S5.1). Fixtures print a noise line first so the runner's
# "last stdout line" parsing is actually exercised.

fixture_job() { cat; }

# fixture_emit <job-json> <jq filter producing the envelope>
fixture_emit() {
  local job="$1" filter="$2" envelope
  envelope="$(jq -c "$filter" <<<"$job")" || return 1
  echo "fixture check: ran"
  echo "SWEEP_RESULT:v1 $(printf '%s' "$envelope" | base64 | tr -d '\n')"
}

# A healthy envelope base: echoes back the job's declared identity fields.
# shellcheck disable=SC2034  # consumed by the fixtures that source this file
FIXTURE_BASE='{schema:"sweep-result/v1",check_id:.check_id,evidence_basis:.evidence_basis,surface:.surface,status:"pass",universe_size:3,excluded:[],assertions_executed:3,assertions_passed:3,measurements:[{statement:"units checked",count:0,denominator:3,source:"static-source"}],findings:[],duration_ms:5}'
