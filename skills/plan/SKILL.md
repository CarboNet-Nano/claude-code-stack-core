---
name: plan
description: Use BEFORE writing any code for non-trivial tasks (anything beyond a 1-line fix). Forces architect-style thinking — state assumptions, propose 2+ approaches with tradeoffs, define success criteria, get explicit user approval. Targets the Wrong Approach friction pattern (the #1 friction in May 2026 Insights). Output is a written plan in .claude/plans/<date>-<topic>.md. Wait for "proceed" before any implementation.
---

# /plan

Halt the impulse to code. Produce a plan, get approval, then code.

## When to use

- New feature
- Refactor touching >2 files
- Anything where you're tempted to start with "First, let me edit X..."
- Anything you're not 100% sure about
- Anything financial / auth / schema-related (always plan)

## When NOT to use

- 1-line bug fix in a single file
- Adding a console.log
- Formatting / typo
- User explicitly says "just do X"

## Steps

### 1. Restate the task

Read the user's request. Restate it in your own words. If the request is ambiguous, list interpretations and ask.

### 2. Surface assumptions

Write a list:
- What are you assuming about the existing code?
- What are you assuming about the user's intent?
- What are you assuming about constraints (perf, security, backward compatibility)?

### 3. Price the do-nothing baseline (MANDATORY — write this before any approach)

Before comparing solutions, answer what happens if you build **nothing**:

> **If we do nothing:** what breaks, who notices it, and when.

Rules:
- **Verify in the code, not from a design doc.** Read the failure path. Does it already
  error, retry, or degrade gracefully? "The docs say it's missing" is not evidence.
- If the honest answer is *"nothing user-visible breaks, and the gap already surfaces an
  error,"* then do-nothing is a serious candidate — say so, don't bury it.
- **Effort already spent is NOT a reason to continue.** A stale branch, a closed PR, a
  half-built feature: "it's already written and reviewed" is sunk cost, not value. Code
  depreciates against a moving architecture; the *design* is the durable asset.

**For work that already exists but never landed** (stale branch, closed PR, orphaned
design doc), answer all three before recommending it be shipped:

1. **What breaks if we never ship it?** — verified in code.
2. **What does integration actually cost?** — measured. Trial-merge it, inventory the
   conflicts, check migration ordering. Never assert "just rebase and run CI."
3. **If deferring: who owns it, and by when?** — with no owner and no date, "deferred" is
   a fiction. The real options are ship-now or kill. Write **DEAD** when it's dead; a
   clear kill with recorded reasoning beats an optimistic "later" nobody owns.

Where a rewrite from the design costs about what the merge costs, prefer the rewrite —
it fits the architecture as it now is.

### 4. Propose 2+ approaches

Each approach gets:
- One-line description
- Tradeoffs (pros AND cons; if you can't think of cons, you haven't thought hard enough)
- Estimated effort (S/M/L)
- Risks specific to this approach
- A pointer to the simpler approach if this one is the chosen one (so user knows what they're not getting)

### 5. Recommend one

Pick one. Justify in 2-3 sentences — **against the do-nothing baseline**, not just against
the other approaches. If it does not clearly beat doing nothing, recommend doing nothing.

### 6. Define success criteria

In observable terms:
- What test will pass?
- What value will match?
- What screenshot will diff cleanly?
- What command will exit 0?

### 7. Write the plan

Save to `.claude/plans/<YYYY-MM-DD>-<short-slug>.md`:

```markdown
# Plan: <Title>

_Written: <date> by /plan_

## Task
<restated>

## Assumptions
- <...>
- <...>

## If we do nothing
<What breaks, who notices, when — verified in code, not inferred from docs.
For already-built-but-unlanded work, also: what integration actually costs (measured),
and who owns it if deferred. "Already written" is sunk cost, not a reason.>

## Approaches considered
### A: <name>
- Description
- Pros / Cons
- Effort: S/M/L
- Risk: <specific>

### B: <name>
- ...

## Recommended approach
**<A or B, or DO NOTHING>** because <2-3 sentences, measured against the do-nothing
baseline above — not only against the other approaches>.

## Success criteria
- <observable>
- <observable>

## Implementation outline
1. <step>
2. <step>

## What I'm explicitly NOT doing
- <thing the user might expect but isn't in scope>
```

### 8. Stop and wait

Print the path to the plan + the recommended approach in one line. End with:
> "Type 'proceed' to implement, or tell me what to change."

Do NOT start implementing. Do NOT background it. Wait for the word.

### 9. On approval — clear the design-before-code gate (ADR-021)

When the user approves (says "proceed" or equivalent), write the approval marker
the design gate reads, so subsequent source edits are unblocked under ultracode:

Scope the approval to the paths this plan touches (Phase-3, ADR-023) so the gate
stays precise — only the planned files unlock, not all source:

```bash
mkdir -p ~/.claude/session-state
# Per-session marker (ADR-020 pattern): two live sessions must not clobber one
# shared approval file. Key the filename by the (sanitized) session id; the gate
# reads design-approved.<sid>.json for this session, else the legacy file.
SID="${CLAUDE_CODE_SESSION_ID:-}"; SID="${SID//[^A-Za-z0-9._-]/_}"
FILE=~/.claude/session-state/design-approved.json
[[ -n "$SID" ]] && FILE=~/.claude/session-state/design-approved."$SID".json
# approved_paths = shell globs for the files/dirs this plan covers.
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan "<plan-path>" \
  --argjson paths '["<glob1>","<glob2>"]' \
  '{active:true, approved_at:$at, plan:$plan, approved_paths:$paths}' \
  > "$FILE"
```

If you cannot enumerate paths, write `approved_paths: []` (or omit it) for a
session-wide approval (legacy behavior). This is a no-op when ultracode is off
(the gate is inactive then). `/plan` writes the marker; `hooks/design-gate.sh`
enforces it.

Also emit a decision event (best-effort) via `pm decision`, only if this repo
is a member of a PM portfolio (`config/portfolio.json`) and a
`.claude/tracks/*.md` track applies — the approved plan is exactly the
question-and-choice this journals (REQ-147):

```
node ~/.claude/tools/pm/bin.mjs decision --portfolio <portfolio> --track <track> \
  --question "<task, restated>" --choice "<recommended approach's name>" \
  --option "<Approach A>" --option "<Approach B>" [--option "<Approach C>"] \
  --rationale "<Recommended approach's 2-3 sentence justification>" \
  [--ref adr:<path>] --author skill
```

Best-effort only: if `pm` tools are missing, or the portfolio/track can't be
resolved, or the command errors, note it and continue — never brick `/plan`
approval over this.
