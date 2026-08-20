#!/usr/bin/env bash
# ADR-082 P1c: the doctrine re-scope is pinned by machine anchors, not prose.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

has() { grep -q "$2" "$ROOT/$1"; }

has agents/validator.md '<!-- doctrine-v2:not-covered -->' && ok "validator carries not-covered anchor" || bad "validator missing not-covered anchor"
has skills/validate-output/SKILL.md '<!-- doctrine-v2:not-covered -->' && ok "validate-output carries not-covered anchor" || bad "validate-output missing not-covered anchor"
has agents/tester.md '<!-- doctrine-v2:whole-row-assertion -->' && ok "tester carries whole-row anchor" || bad "tester missing whole-row anchor"
has agents/tester.md '<!-- doctrine-v2:coverage-advisory -->' && ok "tester carries coverage-advisory anchor" || bad "tester missing coverage-advisory anchor"
has agents/tester.md '<!-- doctrine-v2:adversarial-fixture-review -->' && ok "tester carries fixture-review anchor" || bad "tester missing fixture-review anchor"

# banned token: the coverage section may not fail the suite on a coverage drop
if awk '/doctrine-v2:coverage-advisory/,0' "$ROOT/agents/tester.md" | grep -qi 'coverage.*fail the suite'; then
  bad "tester coverage section still says coverage failure fails the suite"
else
  ok "no coverage ship-gate language in tester coverage section"
fi

# the not-covered sections must name the load-bearing classes
for cls in "Disconnected" "Absent writes" "Read-path" "Contract drift"; do
  if awk '/doctrine-v2:not-covered/,0' "$ROOT/agents/validator.md" | grep -qi "$cls"; then
    ok "validator not-covered names: $cls"
  else
    bad "validator not-covered missing: $cls"
  fi
done

# foreman carries the fixture-review step for financial-code
has skills/foreman/SKILL.md 'adversarial fixture review' && ok "foreman names the adversarial fixture review" || bad "foreman missing fixture-review step"
has skills/foreman/SKILL.md 'docs/reviews/fixtures/' && ok "foreman names the artifact path" || bad "foreman missing artifact path"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = "0" ]
