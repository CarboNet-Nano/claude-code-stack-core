---
name: agent-performance-review
description: Run monthly to evaluate how each subagent has actually performed over the last 30 days. Reads subagent_runs table, identifies patterns of failure/success, proposes prompt refinements or model changes. Distinct from /model-audit (which looks outside at benchmarks) — this looks inside at actual outcomes. Targets the assumption that current configuration is still optimal.
---

# /agent-performance-review

Look at what subagents actually did. Find what's not working.

## When to use

- First of each month, alongside /model-audit
- When a specific subagent feels off ("validator keeps missing things")
- Before quarterly planning ("is the stack delivering?")

## Steps

### 1. Pull subagent runs

Source: `~/.claude/logs/subagent-runs.jsonl` (append-only, written by the PreToolUse Agent hook `~/.claude/hooks/subagent-log.sh`). Each row has `ts`, `agent`, `desc`, `model`, `project`, `session_start`.

**Filter by event** — this log also carries non-dispatch rows (`event=="main_turn"` from ADR-033's model-fit accrual, `event=="workflow_dispatch"`, loop-cost rows, etc.). Exclude all of them the same way `/handoff`/`/goodmorning`/`/team-status` do, or `main_turn` rows get counted as a subagent literally named `"main"`:

```bash
CUTOFF=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
jq -r --arg c "$CUTOFF" 'select(.ts >= $c) | select((.event // "dispatch") == "dispatch") | select(.agent != "workflow") | .agent' ~/.claude/logs/subagent-runs.jsonl \
  | sort | uniq -c | sort -rn
```

Group by `agent` (optionally filter `.project == "<path>"` for per-repo view). For each: invocation count, model mix, sample of `desc` strings, most recent run.

**Not yet in log for `dispatch` rows** (skip the corresponding Step 2 checks until the log schema grows): success/failure outcome, cost, wall time, escalation events. For ordinary dispatches this skill still produces a usage + benching picture only; revisit when outcome fields are added.

**Partial exception — `event:"effort_eval"` rows (ADR-056 follow-up, written by `/effort-eval`)** do carry cost, wall-time, and quality scores, but *only* for deliberate effort-comparison runs — never for ordinary dispatches, so they cannot stand in for the missing fields above. They are excluded from every dispatch count by the `event` filter in the query above, exactly like `workflow_dispatch` and `main_turn` rows. To surface effort findings, read them separately:

```bash
jq -r --arg c "$CUTOFF" 'select(.ts >= $c) | select(.event == "effort_eval")
  | "\(.agent): \(.baseline_effort) vs \(.bumped_effort) -> \(.verdict) (\(.tasks) tasks)"' \
  ~/.claude/logs/subagent-runs.jsonl
```

A `worth-it` or `not-worth-it` verdict is evidence for a proposed `effort` change in `config/model-routing.json` — surface it under Step 4's proposals. Treat `inconclusive` as no signal, not as "no difference": these runs use small fixture sets by design.

### 2. Identify performance issues

For each subagent:
- **High failure rate** (>15% in 30d): something's off — wrong model, wrong prompt, wrong scope.
- **High escalation rate** (>20% in 30d): subagent can't handle what foreman dispatches.
- **Low usage** (<5 invocations in 30d): unused — either not needed or not triggering.
- **Cost outliers**: subagent costing >2x its expected per-invocation budget.
- **Wall-time outliers**: subagent taking >2x its expected duration.

### 3. Identify pattern issues

Cross-cutting:
- Which task types have highest failure?
- Which subagent pairs (handoffs) have highest re-do rate?
- Which approval gates get rejected most often?
- **(v1.1) Orchestration mode comparison.** For each task type, compare success rate / cost / wall-time across `main-thread`, `agent-teams`, and `hybrid` modes. If one mode is meaningfully outperforming for a given task class, surface it. If `agent-teams` is consistently underperforming `main-thread` for a task class, propose restricting it. This is how the stack learns whether the experimental orchestration is actually worth using.

### 4. Generate proposals

For each issue, propose:
- **Prompt refinement** — specific edit to the subagent's .md file or foreman skill
- **Model change** — propose escalation or downgrade
- **Scope change** — narrow what foreman dispatches to this subagent
- **Orchestration-mode change** (v1.1) — propose changing default mode for a task class
- **Retirement** — if unused for 60+ days, propose removal (librarian's decision)

### 5. Write report

`docs/agent-perf/<YYYY-MM-DD>.md`:

```
# Agent performance review: <date>

## At a glance
- Total invocations: <N>
- Total cost: $<X>
- Average success rate: <%>
- Top subagent by usage: <name> (<N> invocations)
- Top subagent by cost: <name> ($<X>)
- Top failure cause: <pattern>

## Per-subagent
### architect
- Invocations: <N> | Success: <%> | Avg cost: $<X> | p95 wall: <Y>min
- Notable: <pattern>
- Proposal: <none / refinement / model change>

### implementer
...

## Cross-cutting patterns
- <pattern>: observed in <N> sessions, suggested action: <...>

## Proposals summary
- <change>: <evidence> — apply? Y/N
```

### 6. Hand to librarian
After approval: librarian implements the prompt refinements (PRs to claude-code-stack).
