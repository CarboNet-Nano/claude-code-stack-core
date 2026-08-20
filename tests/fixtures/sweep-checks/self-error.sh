#!/usr/bin/env bash
# Fixture: a check that completes but reports status error.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .status=\"error\""
