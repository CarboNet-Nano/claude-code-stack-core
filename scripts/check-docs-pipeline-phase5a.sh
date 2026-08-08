#!/usr/bin/env bash
# Phase 5a exit tests — docs-agent-pipeline-v2.md §8. Success criterion for
# the /loop-engineer loop that built the three trust-architecture fixes
# (logic-evidence.mjs, check-harness-target.mjs, logic-parity-gate.sh).
#
# All 3 tests use small synthetic fixtures — they prove the MECHANISMS work
# in general, independent of whether the real SIMS Pareto logic doc has been
# written yet (that's a separate, larger piece of work with its own
# checkpoint — see docs/proposals/2026-07-30-docs-agent-pipeline-v2.md §8).
set -uo pipefail

STACK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$STACK_ROOT/tools/user-docs/src/logic-evidence.mjs"
HARNESS_CHECK="$STACK_ROOT/tools/user-docs/src/check-harness-target.mjs"
PARITY_GATE="$STACK_ROOT/scripts/logic-parity-gate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

for f in "$EVIDENCE" "$HARNESS_CHECK" "$PARITY_GATE"; do
  [[ -x "$f" ]] || { fail "prerequisite missing/not executable: $f"; }
done

REPO="$TMP/fixture-repo"
mkdir -p "$REPO/src"

# entry.mjs: a tiny "route handler" that applies a cap the doc must capture.
cat > "$REPO/src/entry.mjs" <<'EOF'
import { rawDiscount } from './helper.mjs';

export function computeTotal(subtotal, couponPct) {
  const discount = rawDiscount(subtotal, couponPct);
  // Cap: discount can never exceed 20% of subtotal, no matter what the
  // coupon says. This is the caller-side wrapper a bypassing harness misses.
  const cappedDiscount = Math.min(discount, subtotal * 0.2);
  return subtotal - cappedDiscount;
}
EOF

cat > "$REPO/src/helper.mjs" <<'EOF'
export function rawDiscount(subtotal, couponPct) {
  return subtotal * (couponPct / 100);
}
EOF

# ─── Test 3: SOURCES-INCOMPLETE ──────────────────────────────────────────────
# A doc that only cites entry.mjs (omits helper.mjs, which entry.mjs imports)
# must be caught BEFORE any parity call is made.
DOC_INCOMPLETE="$TMP/doc-incomplete.md"
cat > "$DOC_INCOMPLETE" <<'EOF'
# computeTotal
Applies a coupon discount to a subtotal, capped at 20%.
EOF
OUT3="$(bash "$PARITY_GATE" "$DOC_INCOMPLETE" "$REPO/src/entry.mjs" "$REPO" "src/entry.mjs" 2>&1)"
RC3=$?
if [[ "$OUT3" == SOURCES-INCOMPLETE:* && "$OUT3" == *"helper.mjs"* && $RC3 -ne 0 ]]; then
  pass "3: omitted closure file (helper.mjs) -> SOURCES-INCOMPLETE, blocked before parity call"
else
  fail "3: expected SOURCES-INCOMPLETE naming helper.mjs, got (rc=$RC3): $OUT3"
fi

# Sanity: with BOTH files declared, the gate proceeds past the sources check
# (may still PASS or FAIL on parity itself — we only assert it didn't stop at
# SOURCES-INCOMPLETE).
OUT3b="$(bash "$PARITY_GATE" "$DOC_INCOMPLETE" "$REPO/src/entry.mjs" "$REPO" "src/entry.mjs,src/helper.mjs" 2>&1)"
if [[ "$OUT3b" != SOURCES-INCOMPLETE:* ]]; then
  pass "3b: complete sources list -> gate proceeds past the sources check"
else
  fail "3b: expected to proceed past sources check with complete list, got: $OUT3b"
fi

# ─── Test 2: harness-target mechanical check ────────────────────────────────
# Good harness: imports the real entry point (entry.mjs).
cat > "$TMP/harness-good.mjs" <<'EOF'
import { computeTotal } from './fixture-repo/src/entry.mjs';
console.log(computeTotal(100, 50));
EOF
# Bad harness: imports helper.mjs directly, bypassing entry.mjs's 20% cap —
# exactly red-team Critical #2 (scratch harness bypasses caller-side wrapper).
cat > "$TMP/harness-bad.mjs" <<'EOF'
import { rawDiscount } from './fixture-repo/src/helper.mjs';
console.log(rawDiscount(100, 50));
EOF

OUT2_GOOD="$(node "$HARNESS_CHECK" "$TMP/harness-good.mjs" "$REPO/src/entry.mjs" "$REPO" 2>&1)"
RC2_GOOD=$?
OUT2_BAD="$(node "$HARNESS_CHECK" "$TMP/harness-bad.mjs" "$REPO/src/entry.mjs" "$REPO" 2>&1)"
RC2_BAD=$?

if [[ $RC2_GOOD -eq 0 && "$OUT2_GOOD" == PASS:* ]]; then
  pass "2a: harness targeting the real entry point passes"
else
  fail "2a: expected PASS for good harness, got (rc=$RC2_GOOD): $OUT2_GOOD"
fi
if [[ $RC2_BAD -ne 0 && "$OUT2_BAD" == FAIL:* && "$OUT2_BAD" == *"inner function"* ]]; then
  pass "2b: harness bypassing entry point (calls rawDiscount directly) is rejected"
else
  fail "2b: expected FAIL for bad harness (inner-function bypass), got (rc=$RC2_BAD): $OUT2_BAD"
fi

# ─── Test 1: parity gate catches a deliberately mis-documented branch ───────
# The doc claims NO cap exists (wrong — entry.mjs caps at 20%). A correct
# adversarial checker must return FAILED with a counterexample, not PASSED.
DOC_WRONG="$TMP/doc-wrong.md"
cat > "$DOC_WRONG" <<'EOF'
# computeTotal

Computes the final total by subtracting a coupon discount from the subtotal.

## Rules
1. discount = subtotal * (couponPct / 100)
2. total = subtotal - discount

There is no upper limit on the discount — a large enough coupon percentage
can discount the order to zero or below.
EOF
OUT1="$(bash "$PARITY_GATE" "$DOC_WRONG" "$REPO/src/entry.mjs" "$REPO" "src/entry.mjs,src/helper.mjs" 2>&1)"
RC1=$?
if [[ $RC1 -ne 0 && "$OUT1" == FAILED:* ]]; then
  pass "1: parity gate caught the mis-documented missing-cap branch -> FAILED with counterexample"
else
  fail "1: expected FAILED (counterexample) for a doc that omits the 20% cap, got (rc=$RC1): $OUT1"
fi

echo ""
echo "── Phase 5a exit tests: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
