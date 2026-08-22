#!/usr/bin/env bash
# Fixture: B1 — reports pass while having executed zero assertions.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .assertions_executed=0 | .assertions_passed=0"
