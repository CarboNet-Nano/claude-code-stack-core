#!/usr/bin/env bash
# Fixture: dumps the sweep-job/v1 it received to
# <repo_root>/.claude/sweep/job-dump.json so the test can assert the job
# contract (spec S5.1) the real checks consume.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
JOB="$(fixture_job)"
printf '%s\n' "$JOB" > "$(jq -r '.repo_root' <<<"$JOB")/.claude/sweep/job-dump.json"
fixture_emit "$JOB" "$FIXTURE_BASE"
