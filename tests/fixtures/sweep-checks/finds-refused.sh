#!/usr/bin/env bash
# Fixture: a finding the emit library must refuse (R1 — an identity_key
# carrying a run identity). The runner may not bypass that refusal.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
FINDING='{identity_key:"run-2026-08-15T02:00:00Z",what:"a finding whose identity is a timestamp",plain:"Something on the dashboard is wrong in a way the safety checks noticed.",mechanism:"DISCONNECTED",surface:$job.surface,surface_source:"declared",found_by:"sweep-family-E",evidence:{locus:"apps/web/src/lib/filter-params.ts:88",measurement:{statement:"orphaned keys",count:1,denominator:2,source:"static-source"}},liveness:{assertions_executed:2,assertions_passed:1},responsible_agent:null,roster_action:null}'
fixture_emit "$(fixture_job)" ". as \$job | $FIXTURE_BASE | .status=\"fail\" | .universe_size=2 | .assertions_executed=2 | .assertions_passed=1 | .findings=[$FINDING]"
