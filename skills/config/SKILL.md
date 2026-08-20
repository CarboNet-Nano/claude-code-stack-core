---
name: config
description: Forwarding stub. /config is Claude Code's own built-in settings command; the stack's Setup Dashboard moved to /stack-config. This stub only points you there and is not model-invocable.
user-invocable: true
model-invocable: false
recommendable: false
tier_min: 2
tools: Read
---

# /config → see /stack-config

`/config` is **Claude Code's built-in** settings command — the stack no longer
uses this name. The stack's Setup Dashboard (view + safely change your whole
setup) is now **`/stack-config`**.

When invoked, print exactly:

> `/config` is Claude Code's built-in command. The stack Setup Dashboard is now
> **`/stack-config`** — view stack + native settings, scope-resolved, with safe
> edits. Opening it now…

Then delegate to **`/stack-config show-current`** (op1 — read-only).

This stub is `model-invocable: false` so no subagent or automated flow can reach
a write path through the old name. It never reads or writes any settings itself.
