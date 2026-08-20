#!/usr/bin/env bash
# Fixture: a check that dies without printing a result envelope.
set -uo pipefail
cat >/dev/null
echo "fixture check: crashed before emitting a result"
exit 7
