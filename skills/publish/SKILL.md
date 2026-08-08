---
name: publish
description: Deploy the current project to Cloudflare, binding the tenant's Secrets Store secrets into wrangler.toml first so a missing/misconfigured secret hard-aborts the deploy instead of shipping without it (ADR-035). Use when asked to deploy, publish, or ship a project to Cloudflare Workers/Pages. Resolves the tenant strictly from .claude/stack-config.json — never accepts a free-typed tenant.
---

# /publish

Bind-then-deploy for a tenant's Cloudflare Workers/Pages project. Wraps
`scripts/publish.sh`, which runs the bind and the deploy in one bash process
so a bind failure stops the deploy before it starts.

## Critical: how to invoke this — bash vs zsh

`scripts/publish.sh` sources `scripts/lib/secret-binder.sh`, which is a
**bash** script. The interactive session shell on this machine is **zsh**.

- **Always run the whole thing with `bash <path-to-publish.sh> ...`** (one
  Bash-tool call, one process). This is what the Steps below do.
- **Never** `source scripts/lib/secret-binder.sh` (or `publish.sh`) directly
  into the current shell, and never run it under a bare `zsh -c`. Sourcing a
  bash script into a zsh session has previously misreported as
  `curl: command not found` — a red herring; the real fault is running bash
  syntax under zsh, not a missing `curl`. If you ever see that error while
  working on deploy tooling, suspect this before suspecting curl.
- `scripts/publish.sh` itself is safe to invoke from *any* calling shell
  (zsh, bash, a Pipedream exec step) as long as you invoke it as
  `bash publish.sh ...` and don't source it.

## Steps

### 1. Resolve the stack repo location
Read `~/.claude/.stack-install.json` → `.source_repo`. This is the
claude-code-stack checkout that holds `scripts/publish.sh` and
`scripts/lib/secret-binder.sh`. If the file or the field is missing, stop and
report: the stack isn't installed the normal way, so the publish path can't
be located — do not guess a path.

### 2. Resolve the tenant
Read `.claude/stack-config.json` at the project root (this repo, the one
being deployed).

- If `.tenant_id` is present and matches `^[a-z][a-z0-9-]{1,62}$`, use it —
  this is the ONLY source of truth. Never accept a tenant id typed in chat or
  inferred from the repo name.
- If `.tenant_id` is absent, list the landed packs under
  `~/.claude/packs/*/tenant.json` and ask the user which tenant this project
  belongs to:
  > No tenant_id in .claude/stack-config.json. Which tenant?
  > a) <tenant-a> — from ~/.claude/packs/<tenant-a>
  > b) <tenant-b> — from ~/.claude/packs/<tenant-b>
  > c) None of these — stop, I need to run /project-init first
  On an answer other than (c), write `.tenant_id` into
  `.claude/stack-config.json` before continuing (so the next `/publish` run
  doesn't ask again). On (c), stop.

### 3. Confirm with the user
Print, then wait:
```
About to deploy: <project dir name>
Tenant: <tenant_id>
Wrangler config: <project root>/wrangler.toml
Proceed? [y/N]
```

### 4. Run publish.sh — bind then deploy, one process
Run exactly one Bash-tool call:
```
bash "<source_repo>/scripts/publish.sh" --repo="<project root>"
```
`publish.sh` re-derives the tenant_id from `.claude/stack-config.json` itself
(step 2's resolution is for the confirmation prompt and the case where it's
missing — the script is the enforcement point). It:
1. Resolves `tenant.json` at `~/.claude/packs/<tenant_id>/tenant.json`.
2. Calls `bind_tenant_secrets <tenant_json> <project-root>/wrangler.toml`.
   On failure, the script exits non-zero immediately — `wrangler deploy`
   never runs.
3. On bind success, runs `wrangler deploy` in the project root.

### 5. Report
```
Publish: <project dir name> (tenant <tenant_id>)
Bind: <SUCCESS | FAILED — reason>
Deploy: <SUCCESS | FAILED | SKIPPED (bind failed)>
```
If bind failed, do not retry automatically — surface the exact `[bind-fail]`/
`[requirement-fail]` lines from the script output (they name the missing
secret, permission, or config) and stop.
