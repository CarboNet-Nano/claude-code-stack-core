---
name: suggest
description: Suggest which stack skills or subagents apply to the current task. Use when you want to know what to use, what skills apply here, suggest what I should use, what can you do for this, or what capabilities fit my current work. Gather-delegate-render — assembles context, calls recommend-capabilities, renders 3–5 results. Tier 2+.
user-invocable: true
model-invocable: true
tier_min: 2
tools: Read
---

# /suggest

Suggest relevant stack capabilities for the current task.

**Natural language triggers:** "what skills apply here", "suggest what to use", "what can you do for this", "what capabilities fit my current work", "what should I use right now", "recommend a skill"

## Steps

### 1. Gather session settings

Read the two sources **independently** — a missing prefs file must NOT zero out real `stack-config.json` values (and vice versa).

From `.claude/stack-config.json` (repo root). If the file is absent, use the per-field defaults shown:
- `stack_tier` (default `0`)
- `orchestration_mode` (default `"main-thread"`)
- `strict_mode` (default `false`)
- `domain_mode` (default `null`)
- `sensitivity.level` → `sensitivity_level` (default `"normal"`)

From `~/.claude/session-state/current-prefs.json`. If the file is absent:
- `communication_style` (default `"balanced"`)

Apply a default only for the specific field whose source file is missing — never collapse all settings to defaults because one file is absent.

### 2. Assemble thread context

- `last_user_ask`: the user's most recent message verbatim.
- `thread_context`: a 1–2 sentence summary of the last 3–5 turns (what the user has been working on). If this is the first turn, leave empty.

### 3. Delegate to recommend-capabilities

Call the `recommend-capabilities` skill with:

```
mode: "discovery"
thread_context: <assembled above>
last_user_ask: <assembled above>
session_settings:
  stack_tier: <from step 1>
  orchestration_mode: <from step 1>
  strict_mode: <from step 1>
  domain_mode: <from step 1>
  sensitivity_level: <from step 1>
  communication_style: <from step 1>
max_results: 5
```

**No ranking logic here.** The engine returns up to `max_results` ranked by relevance (typically 3–5), or an empty `results` list plus a `note` when nothing clears its relevance floor. Render whatever comes back.

### 4. Render results

If `results` is empty: print the `note` from the engine response. Done.

Otherwise, render compactly (honor `communication_style`):

**terse** — one line per result:
```
• /handoff (or: "write a session handoff") — capture session state before closing. [high]
```

**balanced** (default) — one line per result with a brief reason:
```
• /handoff — write a session handoff
  Reason: you are ending a working session. Invoke: /handoff or say "write a session handoff"
  Confidence: high
```

**thorough** — same as balanced; no extra prose (the results speak for themselves).

Always show:
- `id` with slash if present, else the natural_language phrase
- one-line reason from engine
- how to invoke: slash command if `invocation.slash` is set, else the `invocation.natural_language` phrase
- confidence label
- if `origin` is `"live"`, append the suffix `(installed on this machine — not part of the stack)` to the result line (ADR-043)

Cap display at 5. Do not add preamble or trailing summary beyond the results block.

## What this skill does NOT do

- No ranking. Delegate everything to `recommend-capabilities`.
- No follow-up questions.
- No writing files.
- No executing the recommended capability.
