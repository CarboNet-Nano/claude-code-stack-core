#!/usr/bin/env bash
# Test: installing tier N preserves tier N-1 content; tier N-1 still works.

set -euo pipefail

TMPDIR="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
ORIG_HOME="$HOME"
export HOME="$TMPDIR"

# An ambient CLAUDE_CONFIG_DIR from the outer session points at the real
# $HOME, not $TMPDIR — the resolver correctly refuses it as foreign. Isolate
# it exactly like HOME is isolated (tests/test-install.sh does the same).
HAD_CCD=0
if [[ -n "${CLAUDE_CONFIG_DIR+x}" ]]; then HAD_CCD=1; ORIG_CCD="$CLAUDE_CONFIG_DIR"; fi
unset CLAUDE_CONFIG_DIR

restore_env() {
  export HOME="$ORIG_HOME"
  if [[ "$HAD_CCD" -eq 1 ]]; then export CLAUDE_CONFIG_DIR="$ORIG_CCD"; fi
  rm -rf "$TMPDIR"
}
trap restore_env EXIT

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
