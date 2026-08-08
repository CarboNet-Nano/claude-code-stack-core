---
name: effort-eval
description: Measure whether a subagent's reasoning-effort baseline (ADR-056) is actually worth its cost. Runs the same golden task at the agent's baseline effort, one tier DOWN, and one tier up (downward first — effort is non-monotonic, so the optimum may sit below the assigned baseline) — scores both with the cross-family judge, records token cost and wall-time for each, and reports whether the bump paid for itself. Use when tuning config/model-routing.json's effort values, or before proposing a change to one. On-demand only, never scheduled. METERED — every run costs real tokens; the cost projection and explicit approval gate are mandatory, not optional.
---

# /effort-eval

Answer one question with evidence instead of intuition: **does raising this
agent's reasoning effort actually produce better output, and is the
improvement worth the extra cost and latency?**

ADR-056 assigned every subagent an `effort` baseline. Those values were
reasoned about, not measured. This skill measures them.

## When to use

- Before changing an `effort` value in `config/model-routing.json`.
- When an agent's output quality feels wrong for its assigned effort.
- As the evidence-gathering step for the deferred "dynamic effort
  classifier" question (ADR-056 Alternatives §A) — that decision was
  explicitly parked pending data this skill produces.

## When NOT to use

- To compare *models* — that is `/model-audit`'s job.
- To evaluate a prompt change — that is `/eval-bump`'s job. This skill
  holds the prompt fixed and varies only effort.
- On a schedule. This is metered and on-demand — every run spends real
  tokens, so it happens when a human asks for it, never automatically.

## What this is honestly measuring

**The `Agent` tool has no native effort parameter** (ADR-056's platform
finding). Effort reaches a dispatched subagent as a prompt-injected
directive, which the model may or may not honor. So this harness measures
*the effect of the directive*, not the effect of a guaranteed compute
change. If a bump shows no improvement, two explanations remain open —
the extra reasoning didn't help, or the directive was ignored — and this
skill cannot distinguish them. Say so in the report; do not report a null
result as "effort doesn't matter."

Workflow's `agent()` DOES take a real `opts.effort`. A future version of
this harness could run there for a cleaner signal; it does not today.

## Steps

### 1. Identify the target

Which agent(s)? Start with one. Read its current baseline:

```bash
jq -r '.subagent_assignments["<agent>"].effort' config/model-routing.json
```

The comparison is **baseline vs. one tier down AND one tier up** on the ADR-056
ladder (`low → medium → high → xhigh → max`). Run the down arm first.

**Test downward. This is not optional, and it is the arm that usually pays.**

Effort is **non-monotonic** — more thinking is not monotonically better. Measured
elsewhere: the same model on the same mechanical task scored 98 at low effort, 100 at
medium, and **53 at high**. Extended thinking is a cheap-model lever that *dents*
frontier quality. So an agent's optimum can sit *below* its assigned baseline, and a
harness that only tests upward can never find it.

Three reasons the down arm ranks first:

1. **Asymmetric payoff.** A downward win *saves* tokens and wall-time. An upward win
   spends both. A confirmed downgrade is worth strictly more than an equal-sized upgrade.
2. **The baselines were never measured.** ADR-056 assigned an effort to all 24 agents by
   reasoning. If those guesses are high — and the evidence suggests several are — only a
   downward test reveals it.
3. **Our own record points that way.** Seven upward evals to 2026-08-07 returned
   inconclusive or not-worth-it. That is the signature of a roster already at or past its
   optimum. Corroborating cells from the 2026-08-07 model-eval: `implementer` at
   sonnet-5/**medium** beat itself at **high** on the retry task (9,9,8 vs 8,8,9), and the
   single worst cell in that entire run was `architect` on sonnet-5 at **xhigh** (5,6,4).

Edge cases: an agent at `low` has no down arm; one at `max` has no up arm. Run the arm
that exists and say plainly which was skipped — do not report a one-armed run as if both
directions were tested.

Report **three** configurations, not two. A result where down ties baseline is a
**cost saving**, and should be called that in the verdict rather than buried as "no
difference."

### 2. Load the golden tasks

Fixtures live at `.claude/effort-eval/golden-tasks/<agent>.json`. Each is:

```json
{
  "agent": "architect",
  "notes": "<why these tasks, and any caveat about how they were built>",
  "tasks": [
    {
      "id": "architect-01-audit-trail",
      "prompt": "<the full dispatch prompt, self-contained>",
      "good_answer_signals": [
        "<what a strong answer demonstrates — judge-rubric grounding>"
      ]
    }
  ]
}
```

`good_answer_signals` is grounding for the judge, **not a checklist**. An
answer that misses a listed signal but shows equivalent reasoning should
still score well; instruct the judge accordingly.

If no fixture exists for the target agent, write one first (3-5 tasks).
Realistic dispatch scopes, self-contained so they run identically from any
repo. This step needs human judgment — the same reason `/eval-bump` step 2
does.

### 3. Project the cost and STOP

Before spending anything, print:

- agent, its baseline effort, and BOTH the lowered and bumped efforts (say which arm is skipped if the agent sits at `low` or `max`)
- task count, and total dispatches (`tasks × 3` — lowered, baseline, bumped; `tasks × 2` when an arm is unavailable at `low`/`max`)
- the model that agent runs on, from `config/model-routing.json`
- a token estimate per dispatch and the projected total spend
- the judge calls this implies (`tasks × 2` comparisons — lowered-vs-baseline and baseline-vs-bumped)

Then **stop and wait for the literal word `proceed`**. Do not continue on
"ok", "sure", "go ahead", or silence. This mirrors `/cost-gate`'s
discipline; it is not a literal `/cost-gate` invocation, because that skill
expects a script with a `--limit` flag over >100 rows and this is a small
number of live dispatches.

Anchor the estimate in something real — a prior run's logged
`total_tokens` for the same agent if one exists (see step 7), otherwise say
plainly that the estimate is unanchored.

### 4. Run each task at every effort arm

For each golden task, dispatch the target agent **three times**: once with the lowered
effort directive, once with its baseline, once with the bumped one. Everything else must
be byte-identical — same prompt, same model, same context. The only variable is the
effort directive. (Two dispatches when the agent sits at `low` or `max` and one arm does
not exist — record which arm was skipped.)

Record per dispatch: the full output, token counts, and wall-clock time.

Two rules that protect the signal:
- **Never reveal the effort level to the judge.** A judge told "this one
  was high effort" will find reasons to prefer it.
- **Randomize which output is presented first** to the judge, per task.
  Position bias is real and will otherwise track the fixed ordering.

### 5. Score the arms with the cross-family judge

Reuse the existing adversarial-review plumbing (`scripts/lib/openai-review.sh`'s
`oair_call`, ADR-030) rather than inventing a judge. Cross-family per
ADR-011: the judge must not be the same model family that produced the
output.

Judge **two comparisons per task**, each blind and in randomized order: lowered vs.
baseline, and baseline vs. bumped. Present with the task's `good_answer_signals` as
rubric grounding, and ask for:
- a score for each on correctness, completeness, and edge-case handling
- which is stronger overall, or an explicit tie
- one sentence of reasoning

A tie is a legitimate, informative result. Do not force a winner.

### 6. Diff and report

Write `docs/effort-eval/<YYYY-MM-DD>-<agent>.md`:

```
# Effort eval: <agent> (<baseline> vs <bumped>)
Date: <iso>  ·  Tasks: <N>  ·  Judge: <model>

| Task | Lowered score | Baseline score | Bumped score | Winner | Δ cost (best arm) | Δ wall-time |
|---|---|---|---|---|---|---|
| architect-01 | 7 | 7 | 8 | tie-down | -1,400 tok | -12s |

Lowered total:   <tokens>, <wall-time>, mean score <W>
Baseline total:  <tokens>, <wall-time>, mean score <X>
Bumped total:    <tokens>, <wall-time>, mean score <Y>

Verdict: DOWNGRADE — SAVES MONEY | WORTH IT | NOT WORTH IT | INCONCLUSIVE
<one paragraph: what the numbers show, and what they cannot show>
```

Verdict rules — state the rule you applied, and do not overclaim:
- **DOWNGRADE — SAVES MONEY** — the lowered arm wins or ties a clear majority. This is
  a positive result, not an absence of one: same quality, fewer tokens, less wall-time.
  Report the saving explicitly.
- **WORTH IT** — bumped wins a clear majority of tasks, and the cost/latency
  increase is proportionate to the quality gain.
- **NOT WORTH IT** — baseline wins or ties a clear majority, or the bump
  costs substantially more for a marginal gain.
- **INCONCLUSIVE** — mixed results, or too few tasks to distinguish signal
  from noise. **This is the honest default for a small fixture set.** With
  3-5 tasks you are measuring a handful of samples, not establishing a
  fact. Say that plainly rather than dressing a coin-flip as a finding.

A result never auto-applies. Changing an `effort` value is a human decision
made against this report — same as `/model-audit` proposes but does not
apply.

### 7. Log the run

Append one row per completed eval to `~/.claude/logs/subagent-runs.jsonl`,
so `/agent-performance-review` can see effort data over time:

```bash
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg project "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
  --arg agent "<agent>" \
  --arg lowered_effort "<lowered-or-empty>" --arg baseline_effort "<baseline>" --arg bumped_effort "<bumped>" \
  --argjson tasks <N> \
  --argjson baseline_tokens <N> --argjson bumped_tokens <N> \
  --argjson baseline_ms <N> --argjson bumped_ms <N> \
  --argjson baseline_score <N> --argjson bumped_score <N> \
  --arg verdict "<worth-it|not-worth-it|inconclusive>" \
  --arg report "docs/effort-eval/<file>.md" \
  '{event:"effort_eval", ts:$ts, project:$project, agent:$agent,
    lowered_effort:(if $lowered_effort=="" then null else $lowered_effort end),
    baseline_effort:$baseline_effort, bumped_effort:$bumped_effort,
    tasks:$tasks,
    baseline_tokens:$baseline_tokens, bumped_tokens:$bumped_tokens,
    baseline_ms:$baseline_ms, bumped_ms:$bumped_ms,
    baseline_score:$baseline_score, bumped_score:$bumped_score,
    verdict:$verdict, report:$report}' \
  >> ~/.claude/logs/subagent-runs.jsonl
```

`event:"effort_eval"` is additive. Every existing consumer of that log
filters by `event` (`/goodmorning` step 6b, `/handoff`, `/team-status`,
`/agent-performance-review`), so these rows are excluded from dispatch
counts exactly as `workflow_dispatch` and `main_turn` rows already are —
the same way `agent:"workflow"` sentinel rows are handled. Do not add a
`cost_usd` or `cost` key: `loop-cost-accrual.sh` sums those into a loop's
live budget, and an eval run is not loop spend.

### 8. Update CHANGELOG

One line: `Effort eval: <agent> <baseline> vs <bumped> — <verdict> (N tasks)`.

## What this skill does NOT do

- Does not change any `effort` value. It produces evidence; a human decides.
- Does not run on a schedule or in CI.
- Does not cover all 24 agents. Start with the highest-stakes ones
  (`architect`, `security-auditor`, `implementer` have fixtures today) and
  expand based on what the first results show.
- Does not distinguish "extra reasoning didn't help" from "the directive
  was ignored" — see *What this is honestly measuring* above.
