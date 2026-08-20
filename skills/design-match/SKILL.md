---
name: design-match
description: Match UI implementation to a design prototype. Front-loads what was happening at the end of 21-commit cycles — enumerate every visual element from the prototype BEFORE coding, confirm against screenshot, propose changes, then diff after. Use for any UI-parity task or pixel-precise dashboard work.
---

# /design-match

Front-load design parity. The pattern of "ship → screenshot → flag mismatch → fix → repeat" wastes cycles. Catalog the target state first.

## Steps

### 1. Identify target
- Get the prototype source: Figma URL, screenshot file, design system doc, or existing implementation to match.
- Save reference image to `.claude/design-targets/<feature>-<date>.png` if not already there.

### 2. Enumerate the visual elements

Read the prototype. For each visible element, record:
- Element name (from design system if applicable)
- Type (button, card, table, scrubber, header, etc.)
- Variant (primary/secondary/ghost, default/loading/empty, etc.)
- Position (top-left, header, sidebar, etc.)
- Spacing (estimated from prototype)
- States visible in prototype (default, hover, etc.)

Write to `.claude/design-targets/<feature>-inventory.md`:

```markdown
# Design inventory — <feature>
Source: <prototype reference>

| Element | Type | Variant | Position | Notes |
|---|---|---|---|---|
| Header icon button (settings) | HeaderIconButton | ghost | top-right | uses standard component |
| Date scrubber | DateScrubber | variant=B (compact) | below header | NOT variant A — confirmed |
| ... |
```

### 3. Confirm with user

Show the inventory. Ask: "Does this match what you want me to build? Any elements I missed or got wrong?"

WAIT for confirmation before any code.

### 4. Map to implementation

For each inventory element:
- Which existing component implements it (from design system)?
- Does the existing component support the needed variant?
- If a new component is needed, flag for architect.

Write to `.claude/design-targets/<feature>-mapping.md`:

```markdown
# Mapping inventory → code
| Inventory item | Component | Path | Notes |
|---|---|---|---|
| Header icon button | HeaderIconButton | components/ui/HeaderIconButton.tsx | exists, supports ghost variant |
| Date scrubber variant B | DateScrubber | components/charts/DateScrubber.tsx | variant B NOT supported — needs work |
```

### 5. Identify gaps

Flag any inventory items where:
- No matching component exists (need new one)
- Component exists but needs new variant
- Multiple components could match (need to pick)

For each gap, write a question to user OR hand off to architect.

### 6. Hand off

Once inventory + mapping is approved, hand off to implementer with:
- Reference image path
- Inventory doc path
- Mapping doc path
- List of gaps to address

### 7. After implementation

Validator (or you, if running standalone) takes a screenshot of the implementation. Compare to reference image visually. Catalog any deltas.

If deltas exist, write them to `.claude/design-targets/<feature>-diff.md` and hand back to implementer.

## What you do NOT do

- Skip the inventory step "for time." (The inventory IS the time saver.)
- Write production code.
- Approve final pixel parity (user does — they have the design eye).
