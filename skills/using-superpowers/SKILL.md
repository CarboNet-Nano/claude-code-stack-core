---
name: using-superpowers
description: The design-before-code operating discipline the ADR-021 gate enforces. Use at the start of any non-trivial change — it routes you through brainstorming → /plan → approved design → code, so you never edit source before a design exists. Explains the loop (understand → design → get approval → implement → verify) and which stack skill owns each step. Read this when ultracode is on and the design-gate blocks an edit, or whenever you want the disciplined path.
tier_min: 0
user-invocable: true
model-invocable: true
recommendable: true
tools: Read
---

# using-superpowers

The stack's design-before-code discipline. The ADR-021 gate (`hooks/design-gate.sh`)
enforces it under ultracode: **source edits are blocked until an approved design
exists.** This skill is the map of how to satisfy that — and why it's worth doing
even when the gate is off.

## The loop

1. **Understand** — restate the problem, the constraints, the success criterion
   in observable terms. If the request is ambiguous, ask before designing.
2. **Brainstorm** — `/brainstorming`: diverge on approaches before converging.
   Name 2+ options with tradeoffs. Cheap to throw away ideas here.
3. **Design + plan** — `/plan`: write the chosen approach, success criteria, and
   the file/path set it touches. On approval `/plan` writes
   `~/.claude/session-state/design-approved.json` (with `approved_paths`), which
   unlocks the gate for exactly those paths.
4. **Implement** — now edit source. Match surrounding code; minimum change that
   satisfies the plan; nothing speculative.
5. **Verify** — run it against the success criterion (tests / `/validate-output`),
   not just shape checks. Loop back if it doesn't hold.

## Which skill owns each step

| Step | Skill |
|---|---|
| diverge on approaches | `/brainstorming` |
| converge + get approval | `/plan` |
| run as a bounded loop | `/loop-engineer` |
| raise autonomy for the session | `/ultracode` |
| verify output values | `/validate-output` |

## When the gate blocks you

If an `Edit`/`Write` is denied with "design-before-code (ADR-021)": ultracode is
on and no approved design covers that path. Run `/plan` for the work (it writes
the marker), then retry. Docs, tests, and config are always editable — write the
spec and tests first.

## Why bother when the gate is off

The wrong-approach-first failure (the stack's #1 friction) is paid in rework, not
prevented by enthusiasm. A few minutes of design routinely saves multi-commit
churn. The gate just makes the discipline non-optional when autonomy is highest.
