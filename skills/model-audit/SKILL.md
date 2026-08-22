---
name: model-audit
description: Run monthly (or on demand) to audit subagent model assignments against current benchmarks and pricing. Pulls live benchmark data, compares to current config/model-routing.json, proposes changes with evidence. Does NOT auto-apply — outputs a diff for user approval. Targets the stagnation pattern (model lineup that made sense 6 months ago doesn't necessarily now).
---

# /model-audit

Audit model assignments against current state of the world.

## When to use

- First of each month
- When a major new model is released (e.g., Claude 5, GPT-6, Gemini 3)
- When perf-review surfaces consistent issues with a subagent's outputs
- When pricing changes dramatically

## Steps

### 1. Pull current state
- Read `~/.claude/config/model-routing.json` for current assignments.
- Note the `last_audited` date.
- Audit `model_fit.tier_ladder` (ADR-033) alongside pricing: it must stay a
  cheap→strong Anthropic tier list whose every id exists in
  `providers.anthropic.models`. Update it in the same pass if a tier id is
  renamed/retired.

### 2. Refresh pricing
For each model in current use:
- WebSearch / WebFetch for current pricing from provider's official docs.
- Compare to pricing in model-routing.json.
- Flag any deltas >10%.

### 3. Pull current benchmarks
For each major capability used by the stack:
- **Reasoning** (architect, foreman, incident-commander): SWE-bench Verified, ARC-AGI, MMLU
- **Code** (implementer, validator): HumanEval+, Aider polyglot, SWE-bench
- **Adversarial review** (reviewer, security-auditor): same as code, but compare across providers
- **Long context** (architecture-critic, historian): RULER, NIAH, large-doc QA
- **Product reasoning** (product-critic): less standard — use general reasoning benchmarks

For each, search the latest leaderboard standings.

### 4. Check for new models
- Anthropic: any newer than the current Opus 4.7 / Sonnet 4.6 / Haiku 4.5?
- OpenAI: any newer than current GPT-5 / Codex?
- Google: any newer than Gemini 2.5 Pro?
- Open source via Ollama: any worth adopting?

### 5. Generate diff
For each subagent, propose:
- KEEP — current assignment still best
- CHANGE — propose new model, with evidence (benchmark delta + cost delta)
- PILOT — new model worth testing in a sandbox before promoting

### 6. Write report

`docs/model-audits/<YYYY-MM-DD>.md`:

```
# Model audit: <date>

## Pricing changes since last audit
- <model>: <old> → <new> (Δ <±X%>)

## Benchmark movements
- <capability>: <model> moved from rank <X> to rank <Y> on <benchmark>

## New models released
- <model>: <one-line summary>

## Proposed reassignments
| Subagent | Current | Proposed | Evidence | Cost Δ |
|---|---|---|---|---|
| architect | Opus 4.7 | Opus 4.7 | Still leads on SWE-bench Verified | 0 |
| reviewer | Codex | Codex | Still best adversarial-to-Claude | 0 |
| ...

## Pilots to consider
- <model> in <subagent role> — sandbox for 2 weeks, compare to current

## Approval required
The above changes are PROPOSED only. To apply:
1. Review the diff above
2. Run /model-audit --apply <proposal-id> to update model-routing.json
3. Run /verify --tier=2 to confirm new assignments work
```

### 7. Update last_audited
- After approval (not before): update `last_audited` in `~/.claude/config/model-routing.json`.

### 8. Do NOT auto-apply
- Skill produces a proposal. User must explicitly approve.
- Rationale: models change behavior in subtle ways. Human approval is the right gate.
