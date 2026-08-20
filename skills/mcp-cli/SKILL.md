---
name: mcp-cli
description: On-demand MCP tool discovery — enumerate configured MCP servers and load only the tools a task needs, instead of preloading every server's full tool/resource/prompt set into context. Use when 7+ MCP servers are configured (context7, exa, figma, playwright, sentry, tavily, supabase, computer-use, devonthink, etc.) and you don't yet know which one a task needs, or when context feels crowded with unused tool schemas. Vendored text-core (ADR-023 pattern) from obra/superpowers-lab's `mcp-cli` concept — no external binary installed; the discipline runs on this environment's native `claude mcp` CLI and `ToolSearch`.
tier_min: 1
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read
---

# /mcp-cli

The on-demand discovery discipline behind obra/superpowers-lab's `mcp-cli`:
**discover, then load** — never preload every configured MCP server's full
tool/resource/prompt surface into context just because it's connected.

## Why this exists

MCP server count grows over a project's life (this machine already runs
context7, exa, figma, playwright, sentry, tavily, supabase, plus
computer-use/devonthink). Each server can register many tools; loading all of
them up front burns context on schemas you won't use this session. The fix
is on-demand discovery: find out what's available, load the one server's
tools you actually need, and stop there.

## What's vendored vs. what's native

This skill vendors the **discipline**, not the `mcp-cli` binary. The issue's
own suggested next step was to evaluate vendoring before committing to it —
this environment already has native mechanisms that do the same job, so the
external binary isn't installed:

- `claude mcp list` — enumerate configured servers without loading their tools.
- `claude mcp get <server>` — inspect one server's config/status.
- `/mcp` (in-session slash command) — list connected servers and their
  connection state.
- `ToolSearch` — load a specific server's tools into context on demand, by
  keyword/server-name, instead of having them all preloaded.

If a task later shows these are insufficient (e.g. resource/prompt discovery
`mcp-cli` handles that `claude mcp` doesn't), re-open the vendoring question
with a concrete gap, not in the abstract.

## Steps

1. **Enumerate without loading.** Run `claude mcp list` (or read `/mcp` output)
   to see which servers are configured and connected. This costs no tool-schema
   context — it's server names and status only.

2. **Identify the one server the task needs.** Match the task to a server by
   name/purpose (e.g. "look up a library's API" → context7; "search the web"
   → exa/tavily; "inspect a Figma file" → figma). Don't guess broadly — name
   the single server, or the smallest set, the task actually requires.

3. **Load in bulk, not one-by-one.** If that server's tools are deferred
   (not yet in context), call `ToolSearch` once with the server-name substring
   and a generous `max_results` — one query returns the whole toolkit, since
   tool names are namespaced by server (`mcp__<server>__*`). Don't call
   `ToolSearch` per individual tool; that's one round-trip per tool for no
   benefit.

4. **Don't load what you won't use this session.** If the task turns out not
   to need a server after all, don't load it "just in case." Re-run step 2
   when the next task arrives instead of holding a large tool surface loaded
   speculatively.

## What's verified vs. not

- **Documented, not yet exercised in this environment:** `claude mcp list` and
  `claude mcp get <server>` are documented Claude Code CLI subcommands. They
  have not been run and confirmed working in this session — verify they
  behave as expected before relying on them, and fall back to the in-session
  `/mcp` slash command if they don't.
- **Verified:** the `ToolSearch` bulk-load-by-keyword pattern in step 3 is
  directly observed in this environment — see the computer-use MCP server's
  own instructions, which document and rely on exactly that pattern.
- **Not verified:** a quantified context-overhead reduction from following
  this discipline vs. preloading. The originating issue asked to confirm that
  before committing further — that measurement is still open. Don't cite a
  specific token-savings number until it's been measured.

## When NOT to use this

- Fewer than ~3 MCP servers configured — the preload cost is small enough
  that discovery overhead (extra `ToolSearch` round-trips) can cost more than
  it saves.
- A task that's known up front to need most of a server's tools anyway
  (e.g. a long computer-use session) — load it once at the start rather than
  discovering piecemeal.
