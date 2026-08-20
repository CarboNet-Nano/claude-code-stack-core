#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# skills/foreman/SKILL.md is the load-bearing one: it is the orchestrator that
# handles the overwhelming majority of dispatches, and it was MISSED when this
# feature shipped — the protocol landed only in the rarely-used manual
# /dispatch path. Nothing tested for it, so nothing caught it. Consequences of
# that gap: flipping the gate to "on" would have denied nearly all legitimate
# work, and warn-mode telemetry would have measured a wiring bug rather than
# the idea. Do not remove foreman from this list.
for f in agents/architect.md agents/red-team.md agents/reviewer.md skills/dispatch/SKILL.md skills/foreman/SKILL.md; do
  grep -q "Usage-check-target" "$REPO_ROOT/$f" \
    && pass "$f documents the Usage-check-target protocol" \
    || fail "$f is missing Usage-check-target documentation"
done

echo
echo "usage-check (docs): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
