#!/usr/bin/env bash
# Fixture: B2 — a pass over an empty universe (the adapter found nothing).
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .universe_size=0 | .assertions_executed=1 | .assertions_passed=1"
