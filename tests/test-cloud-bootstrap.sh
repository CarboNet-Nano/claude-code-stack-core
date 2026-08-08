#!/usr/bin/env bash
# Test: cloud-bootstrap.sh behaves safely without ever hard-failing a session.
# Offline-only — covers the no-network decision paths (remote guard, marker
# short-circuit, missing token). The actual clone+install path is exercised by
# test-install.sh / the CI install matrix.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="./scripts/cloud-bootstrap.sh"
MARKER="/tmp/.claude-stack-cloud-bootstrap.done"

failures=0
check() { # desc, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; else
    echo "  [FAIL] $1 (expected rc=$2, got rc=$3)"; failures=$((failures + 1)); fi
}

# 1. No-op (rc 0) when not in a remote/cloud container.
rm -f "$MARKER"
( unset CLAUDE_CODE_REMOTE; bash "$SCRIPT" ) >/dev/null 2>&1; check "no-op outside cloud" 0 $?
[[ ! -f "$MARKER" ]] && echo "  [PASS] no marker written outside cloud" || { echo "  [FAIL] marker written outside cloud"; failures=$((failures + 1)); }

# 2. Public repo: no token needed, and an unreachable clone still exits 0
#    (best-effort, never breaks the session). 127.0.0.1 fails fast, no DNS wait.
rm -f "$MARKER"
out="$(CLAUDE_CODE_REMOTE=true CLAUDE_STACK_REPO_TOKEN="" \
      CLAUDE_STACK_REPO="127.0.0.1:9/nope" bash "$SCRIPT" 2>&1)"; rc=$?
check "tokenless unreachable clone exits 0" 0 "$rc"
grep -q "could not clone" <<<"$out" && echo "  [PASS] clone-failure warning printed" || { echo "  [FAIL] no clone-failure warning"; failures=$((failures + 1)); }

# 3. Marker present, no install stamp → short-circuit (rc 0), even with a token
#    set. HOME is isolated so a real ~/.claude on the machine running the tests
#    cannot turn this into the staleness path below.
: > "$MARKER"
HOME_ISO="$(mktemp -d)"
( HOME="$HOME_ISO" CLAUDE_CODE_REMOTE=true CLAUDE_STACK_REPO_TOKEN="dummy" bash "$SCRIPT" ) >/dev/null 2>&1
check "marker + no stamp short-circuits" 0 $?

# 4. Marker present WITH an install stamp, but the remote is unreachable →
#    staleness is unprovable, so the marker is honored (rc 0) and no refresh is
#    announced. This is the fail-safe that keeps network-blocked environments
#    behaving exactly as they did before the staleness check existed.
mkdir -p "$HOME_ISO/.claude"
printf '{"source_sha":"%s","source_branch":"main"}\n' "0000000000000000000000000000000000000000" \
  > "$HOME_ISO/.claude/.stack-install.json"
out="$(HOME="$HOME_ISO" CLAUDE_CODE_REMOTE=true CLAUDE_STACK_REPO="127.0.0.1:9/nope" \
      bash "$SCRIPT" 2>&1)"; rc=$?
check "marker + stamp + unreachable remote honors marker" 0 "$rc"
if grep -q "refreshing" <<<"$out"; then
  echo "  [FAIL] announced a refresh it could not justify"; failures=$((failures + 1))
else
  echo "  [PASS] no refresh announced when staleness is unprovable"
fi
if grep -q "could not clone" <<<"$out"; then
  echo "  [FAIL] fell through to the clone path"; failures=$((failures + 1))
else
  echo "  [PASS] short-circuited before cloning"
fi

rm -rf "$HOME_ISO"
rm -f "$MARKER"

# NOT covered here: the positive path (marker + stamp + a reachable remote whose
# ref has moved → reinstall). It needs a reachable remote, and these tests are
# offline by contract. It was verified by hand against a live cloud container on
# 2026-07-26 — the case that motivated the change.

if [[ "$failures" -gt 0 ]]; then echo "FAILED: $failures"; exit 1; fi
echo "All cloud-bootstrap tests passed."
