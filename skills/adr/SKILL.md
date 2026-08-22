---
name: adr
description: Create or update an Architecture Decision Record. Captures decisions worth more than 5 minutes of thinking, in a format successors can read cold. Use when architect (or user) makes a non-trivial design decision. Output goes to docs/ADRs/<NNN>-<slug>.md.
---

# /adr

Document an architectural decision.

## Steps

### 1. Find next ADR number
- List `docs/ADRs/`. Find the highest 3-digit prefix. Increment.

### 2. Gather inputs
Ask user (or read from architect-handoff if invoked by architect):
- Title (short, 2-6 words)
- Context (what's the situation, what forces are at play)
- Decision (what you decided to do)
- Status (proposed | accepted | shipped | dead | deprecated | superseded)
- **Ships-when** — the observable artifact whose existence proves this shipped: a file
  path, a function/RPC name, a route, a migration. One line. See "Keep the status
  honest" below for why this is required.
- Consequences (positive, negative, neutral — what happens because of this)
- Alternatives considered (what else you looked at and why you didn't pick it)

### 3. Generate slug
From title: lowercase, hyphenated, max 5 words.
Example: "Use Pipedream Connect for Slack delivery" → `use-pipedream-connect-slack`

### 4. Write file
`docs/ADRs/<NNN>-<slug>.md`:

```markdown
# ADR <NNN>: <title>

Date: <YYYY-MM-DD>
Status: <status>
Ships-when: <the artifact whose existence proves this shipped — path / function / route>
Author: <user>

## Context

<paragraph: what's the situation, what forces, what constraints>

## Decision

<paragraph: what we decided, in active voice>

## Consequences

### Positive
- <bullet>
- <bullet>

### Negative
- <bullet>
- <bullet>

### Neutral
- <bullet>

## Alternatives considered

### <Alternative A>
<one paragraph: what it was, why we didn't pick it>

### <Alternative B>
<one paragraph>

## References
- <link to related ADR>
- <link to spec/doc>
- <link to discussion>
```

### 5. Commit
- `git add docs/ADRs/<NNN>-<slug>.md`
- `git commit -m "docs: add ADR <NNN> — <title>"`

### 6. Confirm
Print the path. Ask if any cross-references in other ADRs / docs need updating.


## Keep the status honest

An ADR's status is the field most likely to be wrong, and the most expensive when it is.

**Why it matters more than it used to.** Agents read design records as ground truth, at
scale, faster than a human notices an error. A person skimming a doc that says "not built"
about live code gets suspicious; an agent does not. In carbonet-dashboards (2026-08-05) a
stale "PROPOSED — design only; not built" header on a feature that had shipped three weeks
earlier led an architecture review to call it orphaned dead code and recommend replacing
the project's core data model. A sweep then found 14 more records disagreeing with reality.

**Two mechanisms produce this, both mechanical:**

1. **Stale status.** The design loop ends at "converged/approved". Implementation lands
   0-2 days later via PR. Nobody returns to flip the header, so it fossilizes at whatever
   the last review round wrote. This is the common case.
2. **Orphaned record.** The ADR is authored on a feature branch. The branch closes
   unmerged — superseded, or blocked by review — and the *document* dies even when the
   *decision* shipped another way. Recover with:
   `git log --all --diff-filter=A --name-only -- 'docs/ADRs/NNN*'`

**Three rules:**

- **`Ships-when` is mandatory.** Name the artifact that proves the decision landed. It
  makes the status checkable instead of a claim, and gives `tools/adr-drift/` something
  concrete to verify. "Ships when `packages/api/src/lib/foo.ts` exports `applyFoo`" beats
  any amount of prose.
- **Update the status in the PR that ships the work**, not later. Later does not happen —
  that is the entire finding above.
- **Write `dead` when it is dead.** A clear kill with recorded reasoning is worth far more
  than an optimistic "deferred" nobody owns. If a decision is abandoned, say so, say why,
  and name what survives (usually the reasoning, rarely the code).

`tools/adr-drift/src/check.mjs` catches both mechanisms mechanically; `/project-init`
wires it at Tier 2+. It is a backstop, not a substitute for updating the status.
