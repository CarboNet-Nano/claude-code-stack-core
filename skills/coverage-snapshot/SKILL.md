---
name: coverage-snapshot
description: Run before any bulk data operation that updates existing rows (enrichment, backfill, migration). Snapshots current coverage (counts of populated fields), runs the operation, snapshots again, fails loudly if any field regressed. Targets the data-overwrite friction (Apr 2026 — re-enrichment script dropped image coverage 90% → 34%). Pairs with /cost-gate for bulk LLM jobs.
---

# /coverage-snapshot

Snapshot before. Run. Snapshot after. Diff. Fail if regression.

## When to use

- Before any script that writes to existing rows in a database
- Especially: enrichment scripts, re-enrichment scripts, backfills, data migrations
- Especially: anything labeled "merge" or "upsert"

## When NOT to use

- Pure inserts to new tables
- Read-only operations
- Schema migrations (use /plan + data-engineer subagent instead)

## Steps

### 1. Identify the target

Ask the user:
- Which table(s) are being modified?
- Which columns are at risk?
- What's the script that will run?

### 2. Pre-snapshot

For each at-risk column, count populated rows:

```sql
SELECT
  count(*) FILTER (WHERE col_a IS NOT NULL) AS col_a_populated,
  count(*) FILTER (WHERE col_b IS NOT NULL) AS col_b_populated,
  count(*) FILTER (WHERE col_c IS NOT NULL AND col_c != '') AS col_c_populated,
  count(*) AS total_rows
FROM <table>;
```

Save snapshot to `.claude/coverage-snapshots/<YYYY-MM-DD-HHMM>-pre-<table>.json`.

### 3. Capture context

Also save:
- `git log -1` (commit hash + message — what version of code is running)
- The script command being run
- Any flags / args

### 4. Confirm with user
Print pre-snapshot summary. Ask: "Run the script now?"

Wait for "proceed".

### 5. Run the script
Execute it. Capture stdout/stderr.

### 6. Post-snapshot
Same query as step 2. Save to `<...>-post-<table>.json`.

### 7. Diff

For each column:
- delta = post - pre
- If delta < 0: **REGRESSION**. Print the column, pre count, post count, delta, percent change.
- If delta < -1% of total: **HARD FAIL** — print "ROLLBACK CANDIDATE" and a rollback hint.
- If delta >= 0: report as info.

### 8. Write report

`.claude/coverage-snapshots/<YYYY-MM-DD-HHMM>-report-<table>.md`:

```markdown
# Coverage snapshot report

_<timestamp>_

## Script
<command>
Commit: <hash> "<message>"

## Results
| Column | Pre | Post | Δ | % | Status |
|---|---|---|---|---|---|
| col_a | 8421 | 8421 | 0 | 0% | ok |
| col_b | 6210 | 2103 | -4107 | -66% | **REGRESSION** |

## Verdict
<PASS / WARN / FAIL>

## If FAIL
Rollback hint: <git revert <hash>> or restore from backup `<location>`.
```

### 9. Gitignore (one-time per repo)
- Check `.gitignore` for `.claude/coverage-snapshots/`. If absent, append.

### 10. Stop
- If FAIL: print loud warning, do NOT proceed to next steps in any task.
- If WARN: surface the warning, ask user how to proceed.
- If PASS: print success, suggest committing the report.
