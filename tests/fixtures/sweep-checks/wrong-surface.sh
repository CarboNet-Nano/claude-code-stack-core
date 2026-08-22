#!/usr/bin/env bash
# Fixture: surface declaration — reports a surface other than the job's.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .surface=\"scale\""
