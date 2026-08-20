#!/usr/bin/env bash
# Test: the installer's global_dirs copy step (scripts/lib/tier-installer.sh)
# refuses to install a vendored driver whose file doesn't match the sha256
# recorded in UPSTREAM.md (issue #152) — compute-and-compare, not "does a
# sha256: line exist". A hash-matching driver still installs cleanly.
#
# Uses a synthetic tier manifest (tier-9, no real tier uses that number) and
# a synthetic "example-pkg" vendored file — not the real vendored driver —
# so this exercises the generic hash-check mechanism in tier-installer.sh
# rather than duplicating tools/pm/test/neon-literal.test.mjs's coverage of
# the actual committed driver.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# shellcheck source=lib/tier-installer.sh
source scripts/lib/tier-installer.sh

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

FAKE_REPO="$TMP/fake-repo"
DEST="$TMP/dest"
mkdir -p "$FAKE_REPO/config/tier-manifests" "$FAKE_REPO/tools/pm/src/vendor/example-pkg" "$DEST"

cp "$REPO_ROOT/tools/pm/src/vendor-verify.mjs" "$FAKE_REPO/tools/pm/src/vendor-verify.mjs"
cp "$REPO_ROOT/tools/pm/src/vendor/neon-serverless/index.mjs" "$FAKE_REPO/tools/pm/src/vendor/example-pkg/index.mjs"
REAL_SHA="$(shasum -a 256 "$FAKE_REPO/tools/pm/src/vendor/example-pkg/index.mjs" | awk '{print $1}')"
cat > "$FAKE_REPO/tools/pm/src/vendor/example-pkg/UPSTREAM.md" <<EOF
# Vendored: example-pkg (test fixture)
- index.mjs sha256: $REAL_SHA
EOF

cat > "$FAKE_REPO/config/tier-manifests/tier-9.json" <<EOF
{
  "files": {
    "global_dirs": [
      { "from": "tools/pm/src/vendor", "to": "$DEST/vendor" }
    ]
  }
}
EOF

failures=0

echo "=== case 1: hash-matching vendored file — install must succeed ==="
if install_tier 9 "$FAKE_REPO" "$DEST" "fresh" > "$TMP/out1.log" 2>&1; then
  echo "  [PASS] install_tier accepted a hash-matching vendored driver"
else
  echo "  [FAIL] install_tier rejected a valid vendored driver:"
  cat "$TMP/out1.log"
  failures=$((failures + 1))
fi
if [[ ! -f "$DEST/vendor/example-pkg/index.mjs" ]]; then
  echo "  [FAIL] driver file was not actually copied to $DEST/vendor/example-pkg/index.mjs"
  failures=$((failures + 1))
fi

echo "=== case 2: tampered vendored file — install must refuse ==="
printf '\n// tampered\n' >> "$FAKE_REPO/tools/pm/src/vendor/example-pkg/index.mjs"
if install_tier 9 "$FAKE_REPO" "$DEST" "fresh" > "$TMP/out2.log" 2>&1; then
  echo "  [FAIL] install_tier accepted a tampered vendored driver (hash mismatch not caught):"
  cat "$TMP/out2.log"
  failures=$((failures + 1))
else
  if grep -q "UPSTREAM.md" "$TMP/out2.log"; then
    echo "  [PASS] install_tier refused the tampered driver and named UPSTREAM.md"
  else
    echo "  [FAIL] install_tier refused the tampered driver but didn't name UPSTREAM.md:"
    cat "$TMP/out2.log"
    failures=$((failures + 1))
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "$failures failures."
  exit 1
fi

echo "All vendor-hash-check installer tests passed."
