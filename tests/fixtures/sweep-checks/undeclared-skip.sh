#!/usr/bin/env bash
# Fixture: skip legality — the check skips itself and says nothing else.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .status=\"skipped\" | .assertions_executed=0 | .assertions_passed=0"
