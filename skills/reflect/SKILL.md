---
name: reflect
description: Post-task retrospective. What was planned vs. what shipped, what worked, what didn't, patterns to carry forward. Distinct from /handoff (state transfer) — /reflect is about learning. Run after completing a significant piece of work or at end of session.
---

# /reflect

Produce a brief retrospective on the work just completed. Print to screen AND write to `docs/retros/` if the directory exists or can be created.

## Steps

### 1. Scope the session

- `git log --oneline -10` — what actually shipped.
- `git diff --stat HEAD~5..HEAD 2>/dev/null` — scale of changes.
- Read `.claude/next_prompt.md` if present — what was planned vs. what happened.

### 2. Assess outcomes

Answer these four questions (fragments OK, be honest):

1. **Planned vs. shipped** — what was scoped, what actually landed, what got cut or deferred?
2. **What worked** — approach, tools, agents, decisions that paid off.
3. **What didn't** — friction, wrong turns, rework, surprises.
4. **Carry forward** — one concrete thing to do differently next time (process, tooling, order of operations).

### 3. Surface patterns (skip if no prior retros)

- `ls docs/retros/ 2>/dev/null | tail -5` — any recent retros?
- If yes, scan the last 2-3 for recurring themes. Note if this session repeats a previous pattern.

### 4. Write output

**Print to screen** (always):

Emit inside a single ``` fenced code block. Caveman tone, ≤8 lines:

```
Shipped: <comma list of key things that landed>
Cut/deferred: <what didn't make it, or "nothing">
Worked: <what paid off>
Didn't: <what caused friction>
Pattern: <recurring theme from prior retros, or "first retro">
Carry forward: <one concrete action>
```

**Write to file** (if project has a git root):

```
docs/retros/YYYY-MM-DD-<slug>.md
```

File format — full sentences, not caveman:

```markdown
# Retro: <one-line session description>
_Date: YYYY-MM-DD_

## Shipped
<bullet list>

## Cut / Deferred
<bullet list, or "Nothing cut.">

## What worked
<2-3 sentences>

## What didn't
<2-3 sentences>

## Carry forward
<one concrete action item>
```

Create `docs/retros/` if it doesn't exist. If the directory can't be written (permissions, no git root), skip the file silently — the screen output is the deliverable.

### 5. Stop and wait

Do not start new work. The retro is the deliverable.
