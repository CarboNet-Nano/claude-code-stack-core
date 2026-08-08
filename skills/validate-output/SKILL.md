---
name: validate-output
description: Use AFTER implementing financial code or anything where output VALUES matter (not just shapes). Runs the code with representative inputs, asserts specific expected values, not just "response was 200" or "object had X keys". Targets the shape-only-smoke-test friction (Apr 2026 — 32% AR / 38% AP understatement bugs slipped through shape-only validation). Required for financial-code mode at Tier 2+.
---

# /validate-output

Don't trust that the shape is right. Verify the numbers.

## When to use

- Financial code (revenue, AR, AP, costs, anything with $)
- Data aggregations (totals, sums, counts that feed dashboards)
- Reports / digests
- Anything where the user can SEE the output and could spot a wrong number

## When NOT to use

- Pure CRUD where success = "row exists"
- UI styling changes (use /design-match instead)
- Schema migrations (those need their own validation pass)

## Steps

### 1. Identify what to validate

Ask:
- What's the function/endpoint/script being validated?
- What's a known-good input (sample row, known query, prod-like data)?
- What's the expected output VALUE — not just shape?

If user can't tell you the expected value, that's a red flag. The right answer is to compute it manually (calculator, spreadsheet, SQL) BEFORE running the code. Coach the user through that step if needed.

### 2. Run with known input
- Execute the code with the sample input.
- Capture full output.

### 3. Compare actual vs expected
- Don't just check "did it return something."
- Don't just check "did the right keys exist."
- Compare the actual VALUE to the expected VALUE.
- For numerics: exact match if integer, within tolerance if float (declare the tolerance up front).
- For aggregates: cross-check by computing the answer a second way (different query, different code path).

### 4. Cross-check with a second method (CRITICAL for financial code)

For revenue / AR / AP / anything with $:
- Compute the value via the code path being tested.
- Compute the same value via a DIFFERENT path (e.g., direct SQL vs RPC; or sum of components vs total).
- They must match.
- If they don't: STOP. There's a bug in one of them. Don't ship until reconciled.

### 5. Write validation report

`.claude/validations/<YYYY-MM-DD-HHMM>-<target>.md`:

```markdown
# Validation: <target>

## Input
<sample data / parameters>

## Expected
<value, computed manually or via cross-check>

## Actual
<value from code under test>

## Cross-check
- Path A: <code path> → <value>
- Path B: <alternate path> → <value>
- Match: <YES/NO>

## Verdict
<PASS / FAIL>

## If FAIL
<diagnosis: which path is wrong, what's the magnitude of error, who/what depends on this>
```

### 6. Gitignore
- Check `.gitignore` for `.claude/validations/`. If absent, append.

### 7. Stop
- PASS: report path + one-line summary. Cleared to ship.
- FAIL: loud warning. Halt downstream work. Trigger /plan to fix.
