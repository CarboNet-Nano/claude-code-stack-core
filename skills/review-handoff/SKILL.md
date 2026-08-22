---
name: review-handoff
description: Use BEFORE declaring any multi-artifact deliverable done. Walks through structured review — cross-artifact consistency, hardcoded values, live-verification needs, gaps relative to requirements, Liu's test on new markdown. Output is a structured review report; next step is approve or revise. Required for any handoff, spec, design doc, audit report.
---

# /review-handoff

Don't trust your first draft. Review before declaring done.

## When to use

- Multi-artifact deliverables (handoffs, design docs, ADR sets, audit reports)
- Anything that will be read by future readers (humans or AI)
- Anything authoritative that downstream work depends on

## When NOT to use

- Code changes (use reviewer/red-team/security-auditor instead)
- Throwaway notes
- Single-paragraph responses

## Steps

### 1. Inventory the deliverable
- List every artifact / file involved.
- Note the requirements they were produced against (which conversation, which prompt, which prior decisions).

### 2. Cross-artifact consistency check
For each cross-reference:
- Does the reference resolve? ("See Artifact 5 Section J" — does that exist?)
- Is terminology consistent? (Don't say "subagent" in one and "agent" in another for the same concept.)
- Is structure parallel where it should be? (If artifacts 2-5 all have a "manifest" section, is the format the same?)

### 3. Hardcoded values audit
Grep for:
- User-specific paths (`/Users/<name>/`, `~<name>/`)
- Project IDs (Supabase refs, AWS account IDs, GitHub orgs)
- API keys or token patterns
- Email addresses, phone numbers
- IP addresses, internal URLs

For each found: should this be parameterized? If yes, fix it.

### 4. Live-verification audit
List every assumption that could be wrong because the world has changed since training data:
- Model identifier strings
- API pricing
- Vendor capabilities ("X supports Y")
- Documentation URLs
- Feature availability

For each: WebSearch to verify. Fix or flag.

### 5. Gap audit
Compare against the original requirements:
- What did the user ask for that isn't addressed?
- What decisions were made that aren't documented?
- What's mentioned as deferred that isn't captured in a backlog or follow-up?

### 6. Liu's test
For any new markdown content created:
- Would removing this line cause a mistake Claude couldn't recover from?
- If no, cut it.

### 7. Write review report

`.claude/reviews/<YYYY-MM-DD-HHMM>-<deliverable>.md`:

```markdown
# Review: <deliverable name>

## Status
APPROVE / REVISE / NEEDS_DISCUSSION

## Cross-artifact consistency
- ...

## Hardcoded values found
- ...

## Live-verification needed
- ...

## Gaps relative to requirements
- ...

## Liu's test failures
- ...

## Specific changes proposed
| Artifact | Section | Change |
|---|---|---|
| ... | ... | ... |
```

### 8. Hand to user
If REVISE: list the changes; wait for approval to make them, then revise.
If APPROVE: deliverable is done.
If NEEDS_DISCUSSION: surface the ambiguity, wait for user input.
