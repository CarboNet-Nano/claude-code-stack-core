---
name: user-docs
description: Author screenshot-backed end-user guides. Resolves scope, verifies the browser MCP server and dev server, bootstraps auth and the vendored runner, dispatches user-docs-writer, enforces the editorial + replay-mode checklist, and runs the fresh-eyes acceptance gate. Use when asked to document a user flow, write onboarding/walkthrough docs, or when foreman's post-validator user-docs offer is accepted. Not for README/runbooks (documenter).
---

# /user-docs

Author a user-facing guide from the live app. The agent does the writing; this
skill owns the preconditions and the gates.

Usage: `/user-docs <flow or feature>` · `/user-docs <guide> --recapture`

## Step 0 — Preflight (STOP on any failure; never assume)

1. **Browser server resolution.** Determine which Playwright MCP server is live
   and record the prefix for this session:
   - prefer `mcp__playwright__*` (declared in `config/settings.tier-1.template.json`),
   - else `mcp__plugin_playwright_playwright__*` (official plugin install),
   - else STOP: "No Playwright MCP server is live. Enable the `playwright` server
     in settings, or install the playwright plugin, then re-run."
   Never hardcode a prefix in a guide, a docs-test, or the agent's scope.
2. **Runner bootstrap** (idempotent, first use only). If
   `~/.claude/tools/user-docs/node_modules` is missing, ask once:
   "The docs runner needs a one-time install (`npm install` + Chromium, ~<size>).
   Proceed? [y/N]". On yes run both in `~/.claude/tools/user-docs/`. On failure or
   decline, report `RUNNER-UNAVAILABLE` and stop — do not fall back to ad-hoc
   captures.
3. **Project config.** Read `.claude/user-docs.json` (contract below). If absent,
   scaffold it by asking for: base URL, documented roles, demo persona set, and an
   optional reset command. Never guess a base URL and never point at production.
4. **Server reachability.** Ask (do not assume) whether the dev/staging server at
   the configured base URL is running; verify with one navigation before dispatch.

## Step 1 — Auth bootstrap (first authoring session per role)

Ask MCQ — never assume:

> How should the docs agent log in to <app>?
> a) Existing Playwright storage state — point me at the file
> b) Test-account credentials in env vars (`<PROJECT>_DOCS_USER` / `<PROJECT>_DOCS_PASS`,
>    per the env-var company-prefix rule) — the agent performs the login form once
> c) Human-assisted: I open the headed browser, you log in yourself (SSO/MFA),
>    then the agent takes over

All three end by exporting storage state to
`.claude/docs-capture/auth/<role>.json`, one file per documented role. Scaffold the
`.gitignore` entry for `.claude/docs-capture/` if absent. Credentials never appear
in chat, guides, docs-tests, or screenshots.

## Step 2 — Dispatch `user-docs-writer`

Scope must name: the flow, the base URL, the role + storage-state path, the resolved
browser tool prefix, the demo persona set, and the output paths
(`docs/user/flows/`, `docs/user/media/`, `docs/user/captures/`).

## Step 3 — Editorial checklist (block on any miss)

- [ ] `feature: <slug>` front matter present
- [ ] Audience & prerequisites header names role / permission / plan-tier, with
      code-verified gates called out
- [ ] 3–5 screenshots typical; each justified in its alt text; no screenshot carpet
- [ ] Captures are locator/clip-framed, not full-page-by-default
- [ ] Demo persona data only — no `Test User 1`, no `asdf@`, no real customer data
- [ ] UI labels verbatim; imperative mood; second person; one term per concept
- [ ] One action per numbered step, stable ordering, expected-result line each
- [ ] Troubleshooting built from error strings grepped from this flow's code
- [ ] Followable with images off; alt text on every image; no color-only references

## Step 4 — Replay-mode verification

Compare `docsMeta.replay` against the side effects actually observed while walking:
- any real mutation → `reset-required` (and `docsMeta.reset` must be set) or `manual`
- destructive/externally-visible (real email, billing, deletion) → `manual`
- `auto` is permitted only for read-only or safely-repeatable flows

A side-effecting step left as `auto` is a blocking defect.

**Scope (c) note:** `reset-required` docs-tests are valid to author, but the
runner in this build refuses to auto-replay them (reports NEEDS-RECAPTURE).
That's expected, not a bug — reset-command execution is a follow-up.

## Step 5 — Fresh-eyes gate (permanent, not optional)

Dispatch a **general-purpose** subagent whose prompt contains the rendered guide
markdown **inline**, plus the base URL and the role's storage-state path — and
nothing else. Give it no repo path, so repo access is structurally absent rather
than merely discouraged. It attempts the flow live via the browser tools and
reports per step: `completed` / `stuck` / `ambiguous`, with what it tried.

**Pass condition: every step `completed`, zero `stuck`, zero `ambiguous`.**
Any `stuck`/`ambiguous` step returns to `user-docs-writer` as a defect and the gate
re-runs. A guide that has not passed is not done and must not be reported as done.

## Step 6 — Finish

Apply `/review-handoff`, then commit guide + media + docs-test together. Report the
agent's handoff path and the gate result.

## `.claude/user-docs.json` contract

```json
{
  "baseUrl": "http://localhost:3000",
  "roles": [
    { "name": "workspace-admin", "authState": ".claude/docs-capture/auth/workspace-admin.json" }
  ],
  "personas": [
    { "name": "Alex Rivera", "email": "alex@demo.example", "org": "Northwind Freight" }
  ],
  "reset": "npm run seed:demo",
  "captureBaseUrlAllowlist": ["http://localhost:3000", "https://staging.example.com"]
}
```

`captureBaseUrlAllowlist` is a safety fence: the runner refuses any base URL not in
it, so no replay can ever hit production.

## What this skill does NOT do

- Reuse `/screenshot-diff`'s vision prompt (it frames image 1 as the desired target
  and would recommend reverting genuine product improvements). Freshness has its own
  prompt, in `/user-docs-refresh`.
- Write dev/ops docs, judge visual design, or diff against design targets.
- Produce logic docs (`/user-docs-logic`, ADR-050) or synthesized per-feature
  docs — Role 3 (synthesis) is still unbuilt.
