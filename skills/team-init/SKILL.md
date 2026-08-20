---
name: team-init
description: Scaffold the org admin repo that auto-installs the Claude Code Stack cloud bootstrap across a GitHub org/team. Run once per org by an admin. Creates a repo from templates/team-admin (reconciler GitHub Action + config), captures org/topic/tier, and prints the token-secret + enable steps. Use when an admin wants every repo in their org (existing and new) to get the stack in cloud sessions automatically, or asks how to roll the stack out org-wide.
---

# /team-init

Set up **org-wide** auto-install of the stack's cloud bootstrap. Run once per
org, by someone who can create a repo and a secret in that org. This automates
Path B (per-repo bootstrap) across every tagged repo — see `docs/CLOUD.md`.

This is an **admin** action, distinct from `/project-init` (one repo) and the
per-user local install. It cannot configure cloud *environments* (Path A) —
those are Anthropic-side and stay manual (`/cloud-setup`).

## Steps

### 1. Gather inputs
Ask (with defaults):
- **org** — the GitHub org/user that owns the repos (required).
- **topic** — GitHub topic that opts a repo in (default `claude-stack`).
- **tier** — stack tier the bootstrap installs (default `2`).
- **admin repo name** — where the reconciler lives (default `claude-stack-admin`).

### 2. Scaffold the admin repo
- Create a working dir (or `gh repo create <org>/<name> --private` then clone).
- Copy the template tree from `~/.claude/templates/team-admin/` into it:
  `README.md`, `config.yml`, `.github/workflows/reconcile.yml`,
  `scripts/reconcile.sh` (keep it executable).
- Fill `config.yml`: set `org`, `topic`, `tier`. Leave `enabled: false`
  (the safety gate — do **not** flip it here).
- Commit and push.

### 3. Print the finish-by-hand steps (cannot be automated)
Tell the user clearly to do these in the GitHub UI:

1. **Add the token secret.** Create a fine-grained PAT with, across the repos to
   manage: **Contents: Read and write**, **Pull requests: Read and write**,
   **Metadata: Read**. Add it to the admin repo as Actions secret
   **`STACK_RECONCILE_TOKEN`**. (The default `GITHUB_TOKEN` can't write to other
   repos, so a PAT is required.) Never commit the token.
2. **Tag repos.** Add the `topic` to each repo to enroll (About → ⚙ → Topics).
3. **Dry run.** Actions → *Claude Stack reconcile* → Run workflow (leave
   `dry_run` checked) → read the log of repos it *would* change.
4. **Go live.** Set `enabled: true` in `config.yml`, commit. Hourly cron + live
   runs then open one PR per tagged repo; review and merge.

### 4. Summarize
Print: admin repo URL, chosen org/topic/tier, and the 4 manual steps as a
checklist. Make explicit that **no repos are touched until** `enabled: true`
**and** the secret exists.

## Notes
- Idempotent: the reconciler skips repos already at the current bootstrap
  version and refreshes stale ones; it deep-merges (never overwrites) an
  existing `.claude/settings.json`.
- New repos are picked up on the next hourly run once tagged.
- For a single repo instead of the whole org, use `/project-init` → cloud
  support. For a cloud environment, use `/cloud-setup`.
