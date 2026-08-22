#!/usr/bin/env bash
# Fixture: a healthy envelope — pass, non-zero universe, non-zero assertions.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE"
