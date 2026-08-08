#!/usr/bin/env bash
# Test: installing tier N preserves tier N-1 content; tier N-1 still works.

set -euo pipefail

TMPDIR="$(mktemp -d)"
ORIG_HOME="$HOME"
export HOME="$TMPDIR"
trap "export HOME='$ORIG_HOME'; rm -rf '$TMPDIR'" EXIT

cd "$(dirname "$0")/.."

# Install tier 0
./scripts/install.sh --tier=0 --mode=fresh > /dev/null
# Capture tier-0 file inventory
ls -la "$HOME/.claude/" > /tmp/tier-0-inventory.txt

# Install tier 1
./scripts/install.sh --tier=1 --mode=merge > /dev/null
# Verify tier-0 files still present
if ! ./scripts/verify.sh --tier=0 > /dev/null; then
  echo "FAIL: tier 0 verify failed after tier 1 install"
  exit 1
fi

echo "PASS: tier isolation"
