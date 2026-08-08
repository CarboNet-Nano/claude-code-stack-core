---
name: auto-merge
description: Per-repo opt-in for GitHub auto-merge gated on a required `run-tests` status check. /auto-merge on <repo> ensures a run-tests CI check exists (scaffolds one if missing), enables allow_auto_merge, creates a per-repo ruleset requiring run-tests, and installs an auto-enable workflow so PRs merge themselves once tests pass. /auto-merge off <repo> reverts. /auto-merge status <repo> shows current state. Use when a repo's PRs should merge automatically on green CI instead of waiting for a manual merge.
---

# /auto-merge

Turn auto-merge on or off for a single repo. **Always per-repo and opt-in** — never org-wide. Auto-merge only fires when a *required* status check is pending, so this skill wires together:

1. A **`run-tests` CI check** (the gate). If the repo doesn't have one, `on` scaffolds it first.
2. `allow_auto_merge = true` on the repo (makes the button available).
3. A **per-repo ruleset** requiring the `run-tests` check (gives auto-merge something to gate on).
4. An **auto-enable workflow** (`.github/workflows/auto-merge.yml`) that clicks "Enable auto-merge" on every PR, so merging is truly hands-off.

Without a required check, GitHub merges immediately and never offers auto-merge. A required check that never reports would lock every PR forever — so `on` guarantees `run-tests` exists and is green on `main` *before* it creates the ruleset.

## `on` is two-phase

The `run-tests` workflow must be on `main` **before** the ruleset requires it, or open PRs lock. So `on` runs in two phases across two invocations:

- **Phase 1 — repo has no `run-tests` check.** Detect the repo's test command, generate `run-tests.yml`, open a PR, and **stop**. The user merges it (after confirming it's green), then re-runs `/auto-merge on`.
- **Phase 2 — `run-tests` is live on `main`.** Enable the flag, create the ruleset, open the bootstrap auto-enable PR.

A repo that already has `run-tests` goes straight to Phase 2.

## Usage

```
/auto-merge status <repo>     # show current state (default action if arg omitted)
/auto-merge on <repo>         # enable auto-merge gated on run-tests (scaffolds run-tests if missing)
/auto-merge off <repo>        # revert ruleset + flag + workflow
```

`<repo>` may be `name` or `owner/name`. A bare `name` resolves to the active tenant pack's GitHub org (`tenant.json → github.org`, via `~/.claude/stack-defaults.json → tenant_pack`); if no pack is configured, error and ask for `owner/name`. Resolve to `OWNER/REPO` before any API call.

## Required check contract

The gate is the status check named **`run-tests`** — a workflow job named `run-tests` (its check context equals the job name). Deliberate: auto-merge should wait on a real test job, not CodeQL/Dependabot noise. Rulesets match by exact context string, so `Analyze (python)` etc. do **not** satisfy it.

## Steps

### 1. Resolve + status

- Resolve `<repo>` to `OWNER/REPO`.
- Read and print current state:
  - `allow_auto_merge`: `gh api repos/OWNER/REPO --jq '.allow_auto_merge'`
  - ruleset present: `gh api repos/OWNER/REPO/rulesets --jq '[.[]|select(.name=="auto-merge-required-checks")]|length'`
  - auto-enable workflow present: `gh api repos/OWNER/REPO/contents/.github/workflows/auto-merge.yml --jq '.path' 2>/dev/null`
  - `run-tests` present (see step 2 detection)
- For bare `/auto-merge` or `status`, stop here.

### 2. `on` — detect `run-tests` (decides the phase)

`run-tests` counts as present if **either** the workflow file exists on the default branch **or** the check reported on the default-branch HEAD:

```
gh api repos/OWNER/REPO/contents/.github/workflows/run-tests.yml --jq '.path' 2>/dev/null
DB=$(gh api repos/OWNER/REPO --jq '.default_branch')
SHA=$(gh api repos/OWNER/REPO/commits/$DB --jq '.sha')
gh api repos/OWNER/REPO/commits/$SHA/check-runs --jq '[.check_runs[].name] | index("run-tests")'
```

- **Present →** go to step 4 (Phase 2).
- **Absent →** go to step 3 (Phase 1).

### 3. Phase 1 — scaffold `run-tests`, then stop

Detect the repo's test command, **confirm the generated workflow with the user**, open a PR, and stop.

**3a. Detect the test command.** Inspect the repo (read files via `gh api repos/OWNER/REPO/contents/<path> --jq '.content' | base64 -d`):

| Signal | Generated install + test |
|---|---|
| root `package.json` has `scripts.test` + `pnpm-workspace.yaml` | pnpm: `pnpm install --frozen-lockfile` → `pnpm -r test` |
| root `package.json` has `scripts.test`, no workspace | detect pm from lockfile (`pnpm-lock.yaml`/`package-lock.json`/`yarn.lock`) → `<pm> install` → `<pm> test` |
| `pyproject.toml`/`setup.cfg` with pytest, or `tests/` + `requirements*.txt` | `pip install -r requirements.txt` (or `pip install -e .`) → `pytest` |

Match the toolchain to existing workflows in the repo (Node version, pnpm version via `packageManager`) — read another `.github/workflows/*.yml` for the versions already in use.

**3b. No real tests → REFUSE.** If no `test` script and no Python test setup is found, do **not** scaffold a placeholder. Print:
> Repo OWNER/REPO has no test suite. A required `run-tests` check that tests nothing is a meaningless gate. Add real tests first, then re-run `/auto-merge on`.
Stop.

**3c. Generate + confirm.** Build `run-tests.yml` from `<skill-dir>/templates/run-tests.node.yml` (Node/pnpm) or `<skill-dir>/templates/run-tests.python.yml` (Python), substituting the detected commands/versions. The job **must** be named `run-tests`. Show the user the full file and the detected command. Open the PR only after they confirm.

**3d. Open the PR + stop.** Branch `chore/add-run-tests-check`, commit the file at `.github/workflows/run-tests.yml`, open a PR. Then print:
> Phase 1 done. Merge PR #<n> once `run-tests` is green, then re-run `/auto-merge on OWNER/REPO` to finish (flag + ruleset + auto-enable workflow).
Do **not** proceed to Phase 2 in the same invocation — the check must be on `main` first.

### 4. Phase 2 — enable the flag

```
gh api -X PATCH repos/OWNER/REPO -f allow_auto_merge=true -f allow_squash_merge=true -f delete_branch_on_merge=true
```

### 5. Phase 2 — create the per-repo ruleset

Sits beside the org-level `main-branch-protection` ruleset (rulesets compose). Send a **JSON body via stdin** — `gh`'s `-f`/`-F` flags cannot build the nested `required_status_checks[]` array and return HTTP 422:

```
gh api -X POST repos/OWNER/REPO/rulesets --input - <<'JSON'
{
  "name": "auto-merge-required-checks",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "run-tests" } ]
      }
    }
  ]
}
JSON
```

If a ruleset named `auto-merge-required-checks` already exists, PUT it (`gh api -X PUT repos/OWNER/REPO/rulesets/<id> --input -`) instead of creating a duplicate. `~DEFAULT_BRANCH` is GitHub's literal token — pass it verbatim.

### 6. Phase 2 — install the auto-enable workflow (via PR)

`.github/workflows/auto-merge.yml` **cannot be pushed to the default branch directly** (org ruleset requires a PR; sandbox can't push to main / `gh pr create` may be blocked — see CLAUDE.md). So:

1. Copy `<skill-dir>/templates/auto-merge.yml`.
2. Branch `chore/auto-merge-bootstrap`, commit the file.
3. Open a PR. **This first PR is merged manually** (the auto-enable workflow isn't on `main` yet). Every PR after it auto-merges once `run-tests` passes.

If the sandbox can't open the PR, **hand off**: print the file path, branch name, and exact `git`/`gh` commands.

### 7. `off` — revert

- Delete the ruleset:
  ```
  ID=$(gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name=="auto-merge-required-checks") | .id')
  [ -n "$ID" ] && gh api -X DELETE repos/OWNER/REPO/rulesets/$ID
  ```
- Disable the flag: `gh api -X PATCH repos/OWNER/REPO -F allow_auto_merge=false`
- Remove the auto-enable workflow: open a PR deleting `.github/workflows/auto-merge.yml` (same push constraint — hand off if needed).
- Leave `run-tests.yml` in place (it's a useful CI check regardless of auto-merge).
- Note: queued auto-merges on open PRs cancel when the flag flips off.

### 8. Confirm

Print a 2-line summary: repo, what changed (run-tests PR# / flag / ruleset / bootstrap PR#), and the next manual step if a PR awaits a manual merge.

## Gotchas

- **`on` may take two invocations.** Phase 1 (scaffold run-tests) and Phase 2 (enable) are separated by a manual merge — the required check must be on `main` before the ruleset references it, or open PRs lock.
- **First bootstrap PR merges manually.** The auto-enable workflow only takes effect once it's on the default branch.
- **`run-tests` must be the exact check context.** Rulesets match by context string.
- **Org ruleset still applies.** `main-branch-protection` (linear history, no force-push, PR required) composes with this one — don't duplicate those rules.
- **GITHUB_TOKEN PRs** don't trigger downstream workflows, so the auto-enable workflow uses `pull_request` events from real authors / Dependabot.
