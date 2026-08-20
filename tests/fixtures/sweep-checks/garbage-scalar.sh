#!/usr/bin/env bash
# Fixture: a result line whose payload decodes to a JSON scalar, not an
# envelope. Fail-open bait: every downstream jq errors and the check
# disappears from the run unless the parser demands an object.
set -uo pipefail
cat >/dev/null
echo "fixture check: ran"
echo "SWEEP_RESULT:v1 $(printf '"hello"' | base64 | tr -d '\n')"
