---
name: handbook
description: Read the stack handbook, or build its generated pages from source. No-arg reads what's present (hand-written README + chapters, or a generated-only landing, or a pointer to build one); `build` regenerates the agent pages, skills glossary, and deck from the installed roster. Use when the user asks for the handbook, the docs, how the stack is organized end to end, or wants to regenerate the handbook after a roster change.
user-invocable: true
model-invocable: true
tier_min: 0
tools: Bash, Read, Write
---

# /handbook

No argument → reader mode (below). `build` → builder mode (below). Any other
argument → print one line: `Usage: /handbook [build]` and stop.

Every reader-mode branch ends with this line, verbatim, no matter which
branch fired:

`/stack-help = command index · /handbook = the handbook · /operating = how the machinery behaves`

## Reader mode (no argument)

Check in this order, take the first branch that matches:

1. `docs/handbook/README.md` exists → read and present it: show the index
   (table of contents) and the reader routing it already contains (the
   per-role reading paths — new teammate, daily user, reviewer/lead,
   maintainer). Offer to open whichever path the user's role suggests.
2. Else `docs/handbook/agents/` or `docs/handbook/skills-glossary.md`
   exists → this repo has **generated reference only**. Print a synthesized
   landing: list which generated sections actually exist (agent pages,
   skills glossary, whichever are present); state plainly that the
   hand-written chapters (executive summary, start-here, decision guide,
   workflows, trust and safety, talk track, machinery) are authored, not
   generated, and are absent here; note that the stack's own full handbook
   lives in the stack repo.
3. Else → print one line: no handbook yet in this repo; `/handbook build`
   creates the generated reference.

Then print the positioning line above.

## Builder mode (`build`)

**Resolve the generator, repo-first:**
1. `<repo-root>/tools/handbook/gen.mjs` if it exists.
2. Else `~/.claude/tools/handbook/gen.mjs` if it exists.
3. Neither → print one line: `stack update needed — tools/handbook/gen.mjs not found` and stop.

Repo-first is load-bearing: if you're a stack maintainer editing the
generator itself, you must run your edit, not a stale installed copy.

**Resolve the tools dir the same way** (used for the npm remedy below):
`<repo-root>/tools/handbook` if it exists, else `~/.claude/tools/handbook`.

**Then, in order:**

1. Run `node <gen> --repo-root <repo-root> --deck`.
   - Nonzero exit → print the failure output and **STOP**. Do not run `--check`.
   - `NOT-EXECUTED:` lines (pptx toolchain absent, or no executive summary to
     slide-ify) are exit 0 — they do not stop the flow, keep going.
2. Run `node <gen> --repo-root <repo-root> --check` and print its result.
3. Print a human summary:
   - Changed/untracked files under `docs/handbook/`: run
     `git status --short -- docs/handbook/` and show the output (or "no
     changes" if empty).
   - Whether the deck and pptx were built or were `NOT-EXECUTED:` (per step
     1's output). If not executed because the pptx toolchain is missing,
     print the remedy: `npm ci --prefix <resolved tools dir>`.
   - A commit hint: if step 1 produced changes, remind the user to review
     and commit `docs/handbook/**`.
   - If this repo's `.gitignore` does NOT already contain the stack's
     handbook build-output rules, note that `docs/handbook/deck/index.html`
     and `*.pptx` are build outputs, not committed sources, and print the
     two lines to add:
     ```
     docs/handbook/deck/*
     !docs/handbook/deck/slides.json
     ```
