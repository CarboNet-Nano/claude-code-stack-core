---
name: grill-me
description: Relentless Socratic interrogation of a plan or design, run AFTER /plan produces a written plan and BEFORE the user approves it. Presses back on stated assumptions and tradeoffs instead of accepting them at face value — the gap /plan leaves open (it forces the author to state tradeoffs but doesn't stress-test them) and that red-team doesn't fill (red-team interrogates a finished artifact for security/adversarial holes, not a plan for reasoning holes). Text-only conversation (no GUI, no background process). Stops when the plan survives a fixed set of question categories or the user says stop.
tier_min: 1
user-invocable: true
model-invocable: true
recommendable: true
tools: Read
---

# /grill-me

Stack-native implementation of the community `grill-me` pattern (relentless
plan-stage interviewing). This is an original write against that pattern's
described behavior, not a vendored copy of upstream source — no upstream
`grill-me` text was available to copy from.

## When to use

- Right after `/plan` (or `brainstorming`) produces a written plan/design, before you say "proceed."
- Any plan you're about to approve mainly because it's the first coherent one, not because you pressure-tested it.
- Financial / auth / schema / migration plans — always grill these before approving.

## When NOT to use

- On a finished artifact (code, config, PR) — that's `red-team` or `reviewer`, not this.
- To generate the plan itself — that's `/plan`. `grill-me` only interrogates a plan that already exists.
- 1-line fixes or anything that wouldn't have gone through `/plan` in the first place.

## How this differs from /plan and brainstorming

- **`/plan`** makes the author *state* assumptions, tradeoffs, and success criteria. It does not challenge whether those statements hold up.
- **`brainstorming`** diverges before a plan exists — it generates alternatives, not pressure.
- **`grill-me`** takes a plan that already states its tradeoffs and tries to break it: wrong assumption, missed failure mode, rejected alternative that was actually better, untestable success criterion, no rollback.
- **`red-team`** does the adversarial pass on a finished artifact (security holes, misuse). `grill-me` never sees code — it only sees the plan.

## Steps

1. **Load the plan.** Read the plan file (or the `/plan` output in-context). If no written plan exists, stop and say so — `grill-me` needs a target, it doesn't produce one.

2. **Interrogate one question at a time, in this order, per plan section:**
   - **Assumptions** — "You assumed X. What if X is false? What did you check vs. what did you guess?"
   - **Alternatives rejected** — "You picked A over B. Steelman B — what would make B the right call?"
   - **Failure modes** — "What breaks this at scale, under bad input, on a second concurrent run, after a partial failure?"
   - **Success criteria** — "Is '<criterion>' something a machine can check, or is it a feeling? Name the exact command/test/value."
   - **Rollback** — "If this ships and is wrong, what's the undo? Is it actually reversible?"
   - **Hidden scope** — "What did this plan implicitly decide that a reasonable person could read differently?" (ties to the global "confirm scope of all-X" pattern)

3. **Do not accept vague answers.** If the response is "it should be fine" or "probably," ask again for the concrete version. Two vague answers in a row on the same question — flag it as an open risk in the summary rather than looping forever.

4. **Track state as you go**: for each question, one of — `held` (answer was concrete and survives), `revised` (plan changed as a result), `open risk` (unresolved, no more looping on it).

5. **Stop condition.** Stop when every category has been asked at least once per major plan section, or the user says stop/proceed. Do not manufacture extra rounds once the categories are covered.

6. **Summarize and hand back.**

## Output shape

```
Grilling: <plan file / topic>

Assumptions:    held: <n>   revised: <n>   open risk: <n>
Alternatives:   held: <n>   revised: <n>   open risk: <n>
Failure modes:  held: <n>   revised: <n>   open risk: <n>
Success crit.:  held: <n>   revised: <n>   open risk: <n>
Rollback:       held: <n>   revised: <n>   open risk: <n>
Hidden scope:   held: <n>   revised: <n>   open risk: <n>

Revisions made to the plan:
- <...>

Open risks carried forward (unresolved, flagged not fixed):
- <...>

Verdict: <plan survives as revised / plan needs another /plan pass because <reason>>
Next: back to /plan for revision, or proceed if no open risks remain.
```
