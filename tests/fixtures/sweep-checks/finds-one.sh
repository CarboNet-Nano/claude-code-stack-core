#!/usr/bin/env bash
# Fixture: one real finding. The locus is deliberately absolute and
# :LINE-suffixed so the runner's locus normalization is exercised
# (repo-relative path, :LINE stripped, before sweep_finding_id).
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
FINDING='{identity_key:"products",what:"filterStateToParams emits products; every route reads singular product",plain:"The dashboard filter sends a name the page never looks for, so filtering that screen silently does nothing.",mechanism:"DISCONNECTED",surface:$job.surface,surface_source:"declared",found_by:"sweep-family-E",evidence:{locus:($job.repo_root+"/apps/web/src/lib/filter-params.ts:88"),measurement:{statement:"producer keys with zero consumers",count:1,denominator:2,source:"static-source"}},liveness:{assertions_executed:2,assertions_passed:1},responsible_agent:null,roster_action:null}'
fixture_emit "$(fixture_job)" ". as \$job | $FIXTURE_BASE | .status=\"fail\" | .universe_size=2 | .assertions_executed=2 | .assertions_passed=1 | .findings=[$FINDING]"
