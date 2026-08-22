---
name: grilling
description: Grill the user one question at a time about a plan, decision, or idea — each as multiple choice with a recommendation. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases. Interrogate BEFORE writing a plan, not after — a critic can only find what a plan already says, while this finds what it never asked.
user-invocable: true
model-invocable: true
tier_min: 0
upstream: https://github.com/mattpocock/skills (skills/productivity/grilling)
vendored: 2026-08-14
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree **one question at a time**. The **frontier** is every decision whose prerequisites are already settled — the questions you could ask _now_ without guessing at answers you haven't heard yet. Compute the whole frontier, then ask only its **single most load-bearing question**: the one whose answer changes the most about everything downstream. Wait for the answer. Recompute. Ask the next one.

> **Local override, not upstream.** Upstream asks the entire frontier in one round. This stack asks one question per turn, because a wall of simultaneous questions gets skimmed and answered shallowly — which produces exactly the unexamined assumptions this skill exists to prevent. Never batch. A second question in the same turn is a bug, even when the two look independent.

**Every question is multiple choice, and you always recommend one.** Use the `AskUserQuestion` tool — one call, one question, two to four concrete options. Never open-ended ("what would you prefer?"), never implicit ("either works"). Put your recommendation first and mark it `(Recommended)`. If you cannot recommend one, you have not done enough work to earn the question — go find the facts first.

Each option needs a one-line consequence, not a restatement: what becomes true if this is chosen, and what it costs. "Graded, not pass/fail — catches 'correct but I'd have written it differently', which pass/fail hides" is an option. "Use grading" is not.

If the tool is unavailable, fall back to this shape — still one question per turn:

```
❓ **<question title>**: <one or two sentences of context>

  a) <option> — <consequence and cost>  ← recommended
  b) <option> — <consequence and cost>
  c) <option> — <consequence and cost>

➡️ <why you recommend (a), in one sentence>
```

Each answer reshapes the tree — settled decisions push the frontier outward and unblock questions that depended on them. A question whose answer depends on a question you have not asked yet belongs later, never now.

**Ask only what is genuinely yours to ask.** Before each question, check it against two tests. Would a competent colleague just decide this? Then decide it, say you decided it, and move on. Does the answer exist somewhere you can look? Then look — see the facts rule below. What remains is the real frontier: decisions where two reasonable people would choose differently and the choice is expensive to reverse.

**Track what has been settled.** Restate the settled decisions in one compact line before each new question, so the user can see the shape forming and correct a wrong turn early rather than at the end.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a sub-agent to find it — don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report — ask the rest of the frontier now. The _decisions_ are the user's — put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding.
