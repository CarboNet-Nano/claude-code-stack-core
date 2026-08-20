---
name: eval-bump
description: Improve evaluation suites (golden sets, classifiers, NL→SQL accuracy). Used heavily for NL→SQL evaluation work — synthesize failure-mode goldens from production traffic, propose patches, A/B against the full suite, only PR when score strictly improves. Generic enough to apply to any eval-driven workflow.
---

# /eval-bump

Improve an eval suite. Catch new failure modes, fix without regressing existing ones.

## Steps

### 1. Identify the eval target
- Which suite? (NL→SQL golden set, classifier, etc.)
- Which failure cases motivated this run? (Recent prod errors, user reports, drift from a benchmark.)

### 2. Synthesize new goldens from failures
For each new failure mode:
- Capture the input that failed
- Determine the correct output (often requires user judgment)
- Write a golden test case

Add to the eval suite in the appropriate fixture file.

### 3. Run current suite against current code
Baseline. Record score.

### 4. Propose patches
Hand off to architect → implementer for the actual code change.

### 5. Run patched code against the FULL suite
- Score must be strictly higher than baseline.
- No previously-passing case may now fail.
- If a case must be sacrificed, that's a separate ADR-worthy decision — escalate.

### 6. Diff scores

```
Baseline:  87.2% (172/197)
Patched:   91.4% (180/197)
Gained:    8 cases (list IDs)
Lost:      0 cases
Status:    READY TO MERGE
```

If lost > 0:
```
Status: BLOCK — patch regresses cases that were passing
Lost cases: <IDs>
```

### 7. Report
Write to `docs/eval-reports/<date>.md`. Commit.

### 8. Update CHANGELOG
One-line entry: `Eval: NL→SQL accuracy 87.2% → 91.4% (+4.2pp, no regressions)`.
