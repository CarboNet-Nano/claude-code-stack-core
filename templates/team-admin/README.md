# Claude Code Stack — org admin repo

This repo auto-installs the [Claude Code Stack](https://github.com/bschonbrun/claude-code-stack)
cloud bootstrap into every repo in your org tagged with a GitHub topic. Once a
repo has the bootstrap, its Claude Code **cloud** sessions (web + iOS)
self-install the stack — so `/goodmorning`, `/handoff`, etc. just work.

It runs entirely on GitHub Actions — **no server to host**. A reconciler opens
one pull request per repo, idempotently (skips repos already current).

## What it does

- **Scope:** repos in your org tagged with the topic in `config.yml`
  (default `claude-stack`).
- **Action:** adds `.claude/hooks/cloud-bootstrap.sh` + a `SessionStart` hook +
  a portable-core skill set + a default `.claude/stack-config.json` (so the repo
  is initialized for foreman at the configured tier without a manual
  `/project-init`), via a PR. An existing `stack-config.json` is never
  overwritten.
- **When:** hourly cron + a manual **Run workflow** button. New tagged repos are
  picked up on the next run.

## One-time setup

1. **Create this repo** from the template (the easiest path is to run
   `/team-init` from a local Claude Code session with the stack installed; it
   scaffolds and pushes everything). Or copy the `templates/team-admin/`
   contents into a new repo by hand.

2. **Add the token secret.** Create a GitHub **fine-grained PAT** with access to
   the repos you want managed and these permissions: **Contents: Read and
   write**, **Pull requests: Read and write**, **Metadata: Read**. In this repo:
   *Settings → Secrets and variables → Actions → New repository secret*:
   - Name: `STACK_RECONCILE_TOKEN`
   - Value: the PAT

3. **Edit `config.yml`:** set `org`, confirm `topic`/`tier`, list any `exclude`.

4. **Tag your repos.** On each repo you want managed: *About → ⚙ → Topics* → add
   `claude-stack` (or your chosen topic).

5. **Dry run first.** Actions tab → *Claude Stack reconcile* → **Run workflow**
   (leave *dry_run* checked). Read the log — it lists repos it *would* change.

6. **Go live.** Set `enabled: true` in `config.yml` and commit. The hourly cron
   (and live manual runs) now open PRs. Review + merge them per repo.

## Safety

- **`enabled: false`** (default) forces dry-run — nothing is written until you
  flip it.
- Manual runs default to **dry-run**.
- The reconciler **never overwrites** a repo's existing `.claude/settings.json`
  — it deep-merges only the `SessionStart` entry — and skips portable-core
  skills that already exist.
- Changes land as **pull requests**, so branch protection and review apply.
- A `.claude/.stack-bootstrap-version` stamp lets it skip up-to-date repos and
  refresh stale ones.

## Job B — tenant pack distribution (optional)

Job A above delivers the **stack bootstrap**. Job B delivers a **tenant pack's
`standards/`** to that tenant's app repos when the pack bumps `pack_version`
(ADR-034 §5). It runs in the same Action, after Job A.

- **Opt-in.** Set `pack_repo` (the tenant pack's git URL) + `pack_topic` (the
  topic tagging that tenant's app repos, e.g. `lade-tenant-carbonet`) in
  `config.yml`. Empty `pack_repo` = Job B disabled; Job A still runs.
- **Action:** re-vendors the pack's `standards/` into each tagged repo (reusing
  `vendor_tenant_standards`) and stamps `.claude/.pack-version`.
- Same guards as Job A: `enabled: false` forces dry-run, changes land as PRs, a
  repo already on the current `pack_version` is skipped.

## Operating runbook

Day-to-day tasks once it's live. All config edits are in `config.yml` on `main`;
commit and the next run picks them up.

| I want to… | Do this |
|---|---|
| **Enroll a new repo** | Add the topic `claude-stack` to it (repo → About ⚙ → Topics). It gets a PR on the next hourly run, or run the workflow manually to do it now. |
| **Stop managing a repo** | Remove the `claude-stack` topic, **or** add its name to `exclude:` in `config.yml` (comma-separated). Already-merged bootstrap files stay until you delete them. |
| **See what it *would* do (no writes)** | Actions → *Claude Stack reconcile* → Run workflow → leave **dry_run checked**. Read the log. |
| **Run it now (open PRs)** | Same, but **uncheck dry_run**. (Scheduled runs are always live.) |
| **Pause everything** | Set `enabled: false` in `config.yml`. The reconciler then only ever dry-runs — no PRs — until you set it back to `true`. |
| **Push a stack update to all repos** | Nothing — when the stack repo advances, the version stamp differs, so the reconciler reopens/updates each repo's PR automatically. Just merge them. |
| **Rotate the PAT** | Regenerate the fine-grained PAT (same perms: Contents RW, Pull requests RW, Metadata R, owner = the org, scoped to enrolled repos). Update the `STACK_RECONCILE_TOKEN` repo secret. Nothing else changes. |
| **A run failed on the token** | The PAT expired, lost a permission, or doesn't cover a newly-tagged repo. Regenerate/extend it and update the secret. |

**What runs automatically:** the hourly cron reconciles every tagged repo;
new tags are picked up within the hour; merged PRs are skipped on later runs
(idempotent via the `.claude/.stack-bootstrap-version` stamp).

**Where things live:** scope/enable/exclude → `config.yml`; the token →
repo secret `STACK_RECONCILE_TOKEN`; the logic → `scripts/reconcile.sh`;
schedule/trigger → `.github/workflows/reconcile.yml`.

## Reference

- Cloud distribution model + paths: <https://github.com/bschonbrun/claude-code-stack/blob/main/docs/CLOUD.md>
