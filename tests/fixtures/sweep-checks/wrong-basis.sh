#!/usr/bin/env bash
# Fixture: G4 evidence-basis fence — claims a basis the job never granted.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_envelope.sh"
fixture_emit "$(fixture_job)" "$FIXTURE_BASE | .evidence_basis=\"production-data\""
