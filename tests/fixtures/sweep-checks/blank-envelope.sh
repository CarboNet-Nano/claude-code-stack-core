#!/usr/bin/env bash
# Fixture: a result line whose payload decodes to a single space.
set -uo pipefail
cat >/dev/null
echo "fixture check: ran"
echo "SWEEP_RESULT:v1 $(printf ' ' | base64 | tr -d '\n')"
