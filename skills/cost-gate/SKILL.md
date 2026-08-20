---
name: cost-gate
description: Run before any bulk LLM job (>100 rows or any LLM-per-row script). Samples 10 rows, measures actual tokens, projects total cost, writes projection to .claude/cost-projections/, and stops for explicit approval. Use when about to kick off scripts matching enrich|backfill|bulk-*|rescue or anything calling an LLM in a loop. Targets the cost-runaway friction pattern (May 2026 — $123 unexpected charges before halted).
---

# /cost-gate

Sample, measure, project, stop. Do not run the full job until the user types "proceed".

## Steps

### 1. Identify the job
- Ask which script will run, total row count, and the LLM model.
- Find the limit flag — read argv parsing for `--limit`, `--max`, `--n`, `--batch-size`.
- If no limit flag exists, say so and stop. (Don't proceed without sample capability.)

### 2. Pre-flight input-token sizing (free, before the sampled run)
Before spending anything on the sampled run, size the prompt template with the
Token Counting endpoint (`POST /v1/messages/count_tokens` — docs:
https://platform.claude.com/docs/en/api/messages/count_tokens). This call is
free and doesn't generate output — it only predicts *input* tokens, so it's a
cheap early check, not a replacement for step 3's real sample.

- Requires `ANTHROPIC_API_KEY` (same key the rest of this flow uses).
- Render the prompt template against one representative record (the same
  record step 3 will use first), then call:

```bash
curl -s https://api.anthropic.com/v1/messages/count_tokens \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "<model-id, e.g. claude-sonnet-4-5-20250929>",
    "messages": [{"role": "user", "content": "<rendered prompt>"}]
  }'
```

  Response: `{"input_tokens": <N>}`.

- **Compare against a prior baseline, if one exists.** Look in
  `.claude/cost-projections/` for the most recent projection file for this
  same script (`<script-basename>` match). If found, it records a `Per-call
  avg: <X> tokens in` line from that run's 10-row *sample* — note that figure
  is a mean of actual sampled calls, not a single rendered-template count, so
  treat this as an approximate comparison and say so when reporting it. Flag
  it as a possible regression if the new count is materially higher (e.g.
  >20% above the prior average).
- **If no prior projection file exists for this script**, just surface the
  raw `input_tokens` count — don't invent a baseline-tracking mechanism.
- This step never blocks progress to step 3; it's informational sizing only.

### 3. Run a 10-row sample
- Run with limit set to 10.
- Capture per call: input tokens, output tokens, wall time, API errors.
- If the script doesn't log token usage: wrap the LLM call with a temporary logger that prints `{input_tokens, output_tokens, model}`. Revert before exiting.

### 4. Compute per-call cost
- Use current pricing for the model.
- **Confirm pricing live via web_search if uncertain.** Apr 2026 friction was a 3.4× underforecast.
- Starting reference (verified 2026-05-15 — confirm before use):
  - Claude Opus 4.7: ~$5/M in, ~$25/M out
  - Claude Sonnet 4.6: ~$3/M in, ~$15/M out
  - Claude Haiku 4.5: ~$1/M in, ~$5/M out
  - GPT-5.5: ~$2.50/M in, ~$15/M out
  - Gemini 2.5 Pro: ~$1.25/M in, ~$10/M out
- avg_per_call = mean of the 10 samples (use median if max > 2× median; flag the variance).

### 5. Project total
- projected_cost = avg_per_call × total_rows
- projected_time = avg_wall_time × total_rows (adjust for script parallelism)
- Flag if any sample call returned errors — extrapolate failure rate.

### 6. Write the projection

```bash
mkdir -p .claude/cost-projections
```

Write to `.claude/cost-projections/<YYYY-MM-DD>-<script-basename>.md`:

```markdown
# Cost projection: <script>

_Run: <timestamp>_

## Summary
- Model: <name>
- Pre-flight count_tokens estimate: <N> tokens in (single rendered template, step 2)
- Sample size: 10
- Per-call avg: <X> tokens in, <Y> tokens out → $<Z>
- Total rows: <N>
- **Projected total cost: $<total>**
- Projected wall time: <duration>
- Sample error rate: <pct>

## Variance flags
- <e.g., "max sample 2.8× median — likely scanned PDFs; actual cost could 3× projected">

## Sample data
| Call # | In tokens | Out tokens | $ cost | Wall (s) |
|---|---|---|---|---|
| 1 | ... | ... | ... | ... |
...

## Approval needed
Type "proceed" to run the full job. Or:
- "downgrade to Haiku" — re-sample with cheaper model
- "abort" — don't run
- "adjust" — tell me what to change
```

### 7. Gitignore the directory (one-time per repo)
- Check `.gitignore` for `.claude/cost-projections/`. If absent, append it.

### 8. Stop and wait
Print 3-4 line summary to chat. Include the pre-flight regression flag from
step 2, if any. End with:
> "Type 'proceed' to run the full job, or tell me what to change."

Do NOT run the full script. Do NOT background it. Wait for the explicit word.

### 9. After approval: log to cost_log (Tier 2+ only)
If Supabase cost_log table exists (Tier 2+), the FULL run writes to it as it goes — not just the projection.

### 10. If the approved job is itself a headless Claude Code run
This skill's own 10-row sample and the full run it approves are executed via
the Bash tool in the current session, not by shelling out to a separate
`claude -p` process — there is nothing in this repo to wire a native CLI
flag into for that path. But if the bulk job you're approving is scripted as
its own headless invocation (`claude -p "<prompt>" ...`, e.g. a CI job or a
cron script), pass `--max-budget-usd <N>` sized from this projection's
**Projected total cost** figure (step 4/5 above) as a second, CLI-enforced
ceiling on top of this skill's own gate — belt-and-suspenders, not a
replacement for the approval step. `--max-budget-usd` is print/`-p` mode
only. This is independent of `cost_protection.per_session_hard_cap_usd`
(`/cost-cap`), which caps the current interactive session, not a spawned
headless child.
