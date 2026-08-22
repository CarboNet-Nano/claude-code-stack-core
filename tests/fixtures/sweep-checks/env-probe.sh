#!/usr/bin/env bash
# Fixture: the environment half of the G4 fence — dumps its own environment
# to <repo_root>/.claude/sweep/env-dump.txt so the test can assert the
# runner granted only what the job declared. The dump path is derived from
# the job, not from an inherited variable, precisely because the runner is
# expected to strip everything it did not grant.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
JOB="$(fixture_job)"
env > "$(jq -r '.repo_root' <<<"$JOB")/.claude/sweep/env-dump.txt"
fixture_emit "$JOB" "$FIXTURE_BASE"
