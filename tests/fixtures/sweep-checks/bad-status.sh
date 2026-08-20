#!/usr/bin/env bash
# Fixture: a status outside the S5.1 enum, carrying zero assertions — the
# shape that walked past invariant 1's `status == "pass"` clause.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .status=\"ok\" | .assertions_executed=0 | .assertions_passed=0"
