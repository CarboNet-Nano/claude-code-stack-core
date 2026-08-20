#!/usr/bin/env bash
# Fixture: B2 — an exclusion carrying a whitespace-only reason.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .excluded=[{unit:\"legacyRoute\",reason:\"   \"}]"
