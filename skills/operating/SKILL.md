---
name: operating
description: Show how to operate Claude Code with the stack — what you actively do (/goodmorning, /carbonight, /project-init, /budget-guard), what happens automatically (foreman orchestration, domain-mode review, approval gates), the per-repo tier/domain table, and where ADRs/runbooks live. Use when the user asks "how does this work", "what do I do", "how is this set up", or wants the operating guide.
---

# /operating

Present the operating guide below to the user. It is the canonical answer to
"how do I run Claude Code with the stack." The source of truth is
`claude-code-stack/docs/OPERATING.md` — if that file is reachable and newer,
prefer reading and showing it; otherwise show this copy.

---

# Operating Claude Code with the Stack

You operate as the **architect**. Foreman + the subagents are the dev team.
You set direction and approve at gates; you do not micromanage routing.

For the generated, always-current list of every command you can run, see
`/stack-help`. This page is the narrative — how the machinery behaves.

## What you actively do

| When | Do this | Why |
|---|---|---|
| Start of a session | `/goodmorning` | Loads the last handoff, git state, open PRs, CI. |
| End of a session | `/carbonight` | Runs the touched tests, prints a cost receipt, then writes `.claude/next_prompt.md` so the next session resumes cleanly. The only close-out command. |
| Starting a new project | `/project-init` | Generates `.claude/stack-config.json`, scaffolds CLAUDE.md. Without it, foreman refuses to dispatch. |
| Before a bulk LLM job (>100 records) | `/budget-guard` or `/cost-gate` | Samples records, projects cost, refuses without your approval. Stops surprise bills. |
| Want to see config | `/default-settings` | Read-only view of global defaults + this project's stack-config. |
| Want this guide | `/operating` | Shows this. |

## What happens automatically

- **Foreman orchestrates** — reads the repo's `.claude/stack-config.json`,
  classifies the task, dispatches the right subagents. You don't pick them.
- **`domain_mode` enforces extra review:** `financial-code` → full review
  chain + validator cross-checks real numbers; `ui-design` → designer
  inventory + design-match diff; `data-operation` → mandatory coverage
  snapshots on bulk writes.
- **Approval gates** — Claude PAUSES for your OK at set points (after
  architect, after validator, before merge, …). The pause is the stack
  working, not a bug.
- **Native Checkpointing backs every gate** — Claude Code snapshots files
  before each edit; `/rewind` rolls back code + conversation to any prior
  point. On by default, no config needed. It's the rollback safety net for
  approved edits you want to undo, but it only covers Claude's own file
  edits — not Bash-driven writes (scripts, hooks, generated files) or git
  history. Git remains the undo path for those.
- **Caveman communication mode** is on by default.

## Per-repo configuration

| Repo (example) | Tier | domain_mode |
|---|---|---|
| a thin monitoring repo | 1 | — |
| an isolated service / MCP server | 2 | — |
| a delivery pipeline | 3 | financial-code |
| a complex application | 4 | financial-code |
| a bulk data pipeline | 5 | data-operation |
| a dashboard suite | 5 | ui-design |

## Where to look for detail

Every audited repo has: `docs/ADRs/` (why decisions were made),
`docs/runbooks/` (what to do when something breaks), `docs/ONBOARDING.md`
(a successor's first day), `docs/architecture/data-flow.md`.

## Rules that bite if forgotten

- No `stack-config.json` → foreman refuses. Run `/project-init`.
- Skipping `/carbonight` → the next session starts blind.
- Bulk LLM jobs without `/budget-guard` → surprise bills.
- An approval-gate pause is intentional — answer it, don't treat it as stuck.
- Naming collision: native `/rewind` **checkpointing** (file snapshots) is
  not the stack's `checkpoint` **loop-autonomy level** (governed loops
  pausing per iteration). Same word, different concept — don't conflate them.
