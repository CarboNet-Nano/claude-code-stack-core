---
name: brainstorming
description: Diverge before you converge — generate and pressure-test multiple approaches before committing to one. Use at the start of a non-trivial feature or decision, before /plan. Text-only conversation (no GUI, no background process). Produces 2+ distinct options with tradeoffs and a recommendation, which /plan then turns into an approved design. Use when the path isn't obvious, when there are competing approaches, or when the design-before-code discipline (using-superpowers) calls for it.
tier_min: 0
user-invocable: true
model-invocable: true
recommendable: true
tools: Read
---

# /brainstorming

The diverge step of design-before-code. Goal: surface real alternatives and their
tradeoffs **before** anyone is attached to an approach. Text-only conversation
(vendored text core per ADR-023; no GUI, no background process).

## Steps

1. **Frame.** One sentence: what are we deciding, and what does a good outcome
   look like (observable)? List hard constraints (must-haves) vs. preferences.

2. **Diverge — at least 2, ideally 3 options.** For each:
   - the core idea in 1–2 sentences
   - why it could be the right call
   - its main cost / risk / what it gives up
   Force genuinely different shapes (e.g. "do it in the hook" vs "do it in the
   lib" vs "don't do it, change the contract"). A list of near-identical options
   is not brainstorming.

3. **Pressure-test.** For the front-runner, ask: what breaks it? what's the
   failure mode at scale / under bad input / in cloud? Does it fit existing
   patterns or fight them?

4. **Recommend.** Name the choice and the 2–3 reasons. State what you're
   explicitly NOT doing.

5. **Hand to /plan.** Brainstorming decides *what*; `/plan` writes the design,
   success criteria, and the path set, and gets approval (which unlocks the
   ADR-021 gate). Do not start coding from here.

## Output shape

```
Deciding: <one line>
Constraints: <must-haves> | Preferences: <nice-to-haves>

Option A — <name>: <idea>. Pro: <…>. Cost: <…>.
Option B — <name>: <idea>. Pro: <…>. Cost: <…>.
Option C — <name>: <idea>. Pro: <…>. Cost: <…>.

Recommend: <A/B/C> because <reasons>.
Not doing: <…>.
Next: /plan
```
