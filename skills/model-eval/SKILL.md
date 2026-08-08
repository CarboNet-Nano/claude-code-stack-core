---
name: model-eval
description: Measure whether a subagent's assigned MODEL is the right one, by running the same golden tasks across models, effort levels, and advisor pairings and scoring blind with the cross-family judge. Distinct from /model-audit (which reads published benchmarks) and /effort-eval (which varies effort only, on one model). Use before changing a model in config/model-routing.json, or to find which agents are actually sensitive to model choice. On-demand only, never scheduled. METERED — the cost projection and explicit approval gate are mandatory.
---

# /model-eval

`/model-audit` reads what the industry published. `/effort-eval` varies how hard one
model thinks. Neither has ever asked the question this skill asks: **for this agent, on
our tasks, does the model actually matter — and by how much?**

Plan of record: `.claude/plans/2026-08-07-model-matrix-eval.md`.

## When to use

- Before changing a `primary` model in `config/model-routing.json`.
- To find which agents are model-sensitive and which are not — the input to deciding
  how often each agent needs re-testing.
- When a new model ships and you want a local read, not a leaderboard.

## When NOT to use

- To compare effort on a fixed model — that is `/effort-eval`.
- To refresh pricing or read benchmarks — that is `/model-audit`.
- To evaluate a prompt change — that is `/eval-bump`.
- On a schedule. Every run spends real money.

## The three axes

| Axis | Varies | Where it runs |
|---|---|---|
| Model | executor model | real agent harness (Agent dispatch) |
| Effort | `low`…`max`, executor only | real agent harness |
| Advisor | the paired second-opinion model | direct API (see Step 2) |

Effort and advisor are **independent**: the advisor tool takes only `type`, `name`,
`model` — `effort`, `thinking`, and `output_config` on it are rejected. Top-level
effort applies to the executor alone.

---

## Steps

### 1. Probe the capability grid — ALWAYS, never skip

The published advisor pairing table has been wrong before (it omitted same-model pairs
and mis-stated haiku). Probe the live API instead. ~16 calls at 64 max_tokens, costs
essentially nothing, and takes seconds.

```bash
KEY=$(security find-generic-password -s anthropic-api-key -w 2>/dev/null)
MODELS=(claude-haiku-4-5 claude-sonnet-5 claude-opus-5 claude-fable-5)
for EX in "${MODELS[@]}"; do for AD in "${MODELS[@]}"; do
  RESP=$(curl -s https://api.anthropic.com/v1/messages -H "x-api-key: $KEY" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: advisor-tool-2026-03-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$EX\",\"max_tokens\":64,\"tools\":[{\"type\":\"advisor_20260301\",\"name\":\"advisor\",\"model\":\"$AD\"}],\"messages\":[{\"role\":\"user\",\"content\":\"Say OK.\"}]}")
  [ -n "$(echo "$RESP" | jq -r '.error.message // empty')" ] && echo "$EX + $AD: no" || echo "$EX + $AD: YES"
done; done
```

Grid as measured 2026-08-07 (re-measure; do not trust this):

| Executor \ Advisor | haiku-4-5 | sonnet-5 | opus-5 | fable-5 |
|---|---|---|---|---|
| haiku-4-5 | – | ✅ | ✅ | ✅ |
| sonnet-5 | – | ✅ | ✅ | ✅ |
| opus-5 | – | – | ✅ | ✅ |
| fable-5 | – | – | ✅ | ✅ |

Haiku is never a valid advisor. Effort errors on Haiku 4.5 — it has no effort axis.

If the probed grid differs from the table above, **use the probe and say so in the
report**. A changed grid is itself a finding.

### 2. Pick the harness per axis (hybrid — the approved design)

- **Model and effort → real agent dispatch.** Same mechanism as `/effort-eval`: the
  agent's own system prompt, tools, and cross-family helpers all participate. This is
  the axis that produces production-routing evidence.
- **Advisor → direct API call.** `advisorModel` is a global user setting
  (`~/.claude/settings.json`) with no project or per-dispatch scope, so it cannot be
  swept inside a session. Going direct also returns full `usage`, which is the only way
  to measure caching.

**Label every advisor result as directional, not production-routing.** A direct API
call is not the real agent — no tools, no Bash, no helper scripts. The
security-auditor eval of 2026-08-05 is the precedent: with Bash disabled it never
exercised the real path and the verdict flipped on rerun. Do not let an advisor result
change `config/model-routing.json` on its own.

### 3. Load golden tasks

Reuse `/effort-eval`'s fixtures verbatim — `.claude/effort-eval/golden-tasks/<agent>.json`.
Same tasks, same `good_answer_signals`, so results are comparable across both skills.
Do not fork the fixtures.

### 4. Measure the noise floor FIRST

This is the step that decides whether anything else is worth running. Pick one config,
run it **twice** on the same task, and score both. The spread between two identical
runs is the floor: any model difference smaller than it is noise, not signal.

Report the floor in the output table. If the floor is wider than every model gap you
subsequently measure, the honest verdict is **INDISCRIMINATE** — the harness cannot
tell these models apart on these tasks, and no routing change is justified.

### 5. Project the cost and STOP

Print before spending anything:

- agent(s), configs per agent, tasks, total dispatches (`configs × tasks`, +1 for the
  noise-floor rerun)
- each model involved and its rate
- token estimate per dispatch, anchored on a prior logged run for the same agent+model
  where one exists — say plainly when it is unanchored
- judge calls implied
- projected total spend

Then **stop and wait for the literal word `proceed`**. Not "ok", not "go ahead", not
silence. Same discipline as `/effort-eval` step 3 and `/cost-gate`.

For reference, the 2026-08-07 `/effort-eval` double run was 12 dispatches ≈ 377k
subagent tokens. Scale from that.

### 6. Run each config

Everything except the axis under test must be byte-identical — same prompt, same
fixture, same context. Record per dispatch: full output, token counts, wall-clock, and
(direct-API runs only) `usage.cache_read_input_tokens` and
`usage.cache_creation_input_tokens`.

Two rules that protect the signal, carried over from `/effort-eval`:
- **Never reveal the config to the judge.** Not the model, not the effort, not whether
  an advisor was present.
- **Randomize presentation order per task.** Position bias is real.

### 7. Score with the cross-family judge

Reuse `scripts/lib/openai-review.sh`'s `oair_call` (ADR-030). Cross-family per ADR-011:
the judge must not be the family that produced the output. When the output is itself
OpenAI-sourced (reviewer, security-auditor with Bash on), judge with Gemini
(`gmn_call`) instead and record the deviation — precedent set 2026-08-05.

Present blind, in randomized order, with `good_answer_signals` as grounding, and ask
for per-answer scores on correctness / completeness / edge-case handling, an overall
winner or explicit TIE, and one sentence of reasoning. **A tie is a real result.**

### 8. Report

Write `docs/model-eval/<YYYY-MM-DD>-<agent>.md`:

```
# Model eval: <agent>
Date: <iso> · Tasks: <N> · Judge: <model> · Noise floor: ±<X> points

| Config | Model | Effort | Advisor | Mean score | Tokens | Wall | vs baseline |
|---|---|---|---|---|---|---|---|

Baseline (current routing): <model>/<effort>, mean <X>
Best measured:              <model>/<effort>, mean <Y>  (gap <Y-X>, floor ±<Z>)

Verdict: CHANGE ROUTING | KEEP CURRENT | INDISCRIMINATE
<one paragraph: what the numbers show, and what they cannot show>
```

Verdict rules — state which you applied:
- **CHANGE ROUTING** — a non-current config beats the current one by more than the
  noise floor, on a majority of tasks, at acceptable cost.
- **KEEP CURRENT** — current config wins or ties, or a winner's cost is
  disproportionate to a gain that barely clears the floor.
- **INDISCRIMINATE** — all gaps are inside the noise floor. **The honest default for a
  3-task fixture.** Say so plainly rather than dressing a coin flip as a finding.

Never overclaim. Three tasks is a handful of samples, not a fact.

### 9. Log every cell

One row per (agent, config, task) — **not** per comparison. This is the fix for
`effort_eval`'s design flaw: those rows store only an aggregate verdict, so per-task
detail is unrecoverable and no new comparison can be made after the fact.

```bash
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg project "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
  --arg agent "<agent>" --arg run_id "<YYYY-MM-DD>-<letter>" \
  --arg executor_model "<model>" --arg advisor_model "<model-or-null>" \
  --arg effort "<level>" --arg task_id "<task>" --arg harness "<agent|api>" \
  --argjson score_correctness <n> --argjson score_completeness <n> \
  --argjson score_edge <n> --argjson tokens <n> \
  --argjson cache_read_tokens <n> --argjson cache_creation_tokens <n> \
  --argjson wall_ms <n> --arg judge "<openai|gemini>" \
  '{event:"model_eval", ts:$ts, project:$project, agent:$agent, run_id:$run_id,
    executor_model:$executor_model, advisor_model:$advisor_model, effort:$effort,
    task_id:$task_id, harness:$harness,
    score_correctness:$score_correctness, score_completeness:$score_completeness,
    score_edge:$score_edge, tokens:$tokens,
    cache_read_tokens:$cache_read_tokens, cache_creation_tokens:$cache_creation_tokens,
    wall_ms:$wall_ms, judge:$judge}' \
  >> ~/.claude/logs/subagent-runs.jsonl
```

`event:"model_eval"` is additive. Every existing consumer of that log filters by
`.event` (`/goodmorning` step 6b, `/handoff`, `/team-status`,
`/agent-performance-review`), so these rows are excluded from dispatch counts exactly
as `effort_eval` and `workflow_dispatch` rows already are.

**Do not add a `cost_usd` or `cost` key.** `loop-cost-accrual.sh` sums those into a
loop's live budget, and an eval run is not loop spend.

### 10. Update CHANGELOG

One line: `Model eval: <agent> — <verdict> (N configs, M tasks, floor ±X)`.

---

## What this skill does NOT do

- Does not change any model assignment. It produces evidence; a human decides.
- Does not run on a schedule or in CI.
- Does not treat advisor results as production-routing evidence — see Step 2.
- Does not cover all 24 agents at once. Start with the high-stakes three
  (`architect`, `security-auditor`, `implementer`), then expand based on which agents
  actually showed a gap wider than the noise floor.

## Known harness defect (fix before evaluating cross-family agents)

For agents whose real work happens on a non-Claude model (`red-team`,
`architecture-critic`, `historian` → Gemini; `reviewer`, `security-auditor`,
`product-critic` → OpenAI), the effort directive reaches the **orchestrating Claude**,
not the API call whose output is judged. Found during the 2026-08-07 red-team eval and
recorded in `docs/effort-eval/2026-08-07-red-team.md`. Any effort axis on those agents
is measuring the wrong hop until this is fixed. The model axis is unaffected.
