---
name: project-init
description: Initialize a project for use with the Claude Code Stack. Asks which mode to use (quick or review), then either accepts defaults with one confirmation OR walks through every configurable setting group-by-group. Generates .claude/stack-config.json, scaffolds .claude/CLAUDE.md, ensures docs/ directories. Required before foreman will dispatch in strict mode (Tier 2+).
---

# /project-init

Two-mode project initialization. v1.3 (tenant-pack aware, ADR-034 §4).

## Steps

### 1. Detect existing state

**1a. Required checks**
- Check for `.claude/stack-config.json`. If present, ask if user wants to update (don't blindly overwrite).
- Check for `CLAUDE.md` at root. If present, note it.
- Check for a git repo: `git rev-parse --is-inside-work-tree`. If it returns
  false / errors (not a repo), ask once: "This isn't a git repo. Initialize
  one here? (yes/no)". If yes, run `git init`. If no, continue — but warn that
  `/handoff`, `/goodmorning`, and foreman features that read git state will be
  limited.
- Read `~/.claude/stack-defaults.json` for the user's personal defaults.
- **Stack freshness.** If `~/.claude/lib/stack-freshness.sh` exists, run
  `bash ~/.claude/lib/stack-freshness.sh` (exit code 10 = behind). If it
  reports the install is behind, surface it and offer to update before
  initializing — a stale local stack means you'd init against old routing /
  schema logic:
  > "Your installed stack is N commit(s) behind origin/<branch>. Update now
  > before initializing this project? [y/N]"
  - If yes: run `./scripts/update.sh --tier=<installed tier>` in the stack
    repo (path is in `~/.claude/.stack-install.json` → `source_repo`), then
    continue. Add `--skip-requirements` if the local box lacks codex/gemini.
  - If no: continue, but note in the final summary that the stack is stale.
  - Skip silently if the helper is absent or reports `current`/unknown.

**1b. Discovery pass (do this BEFORE asking the user anything)**

If the project already exists in any meaningful sense — git history,
deps, partial `.claude/` setup, prior handoffs — read it. Do not arrive
at the user's project blind and ask cold questions.

Read each of the following, silently, and tally what you find:

- `git log --oneline -20` — recent commits (shows velocity and themes)
- `git log --format="%an <%ae>" | sort -u` — contributors (1 person vs team)
- `git status -sb` — current branch + uncommitted state
- `git branch --show-current` — are we on a feature branch mid-work?
- `.claude/next_prompt.md` — prior session handoff, if present
- `docs/handoffs/` — count files, note latest filename + date
- `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `Gemfile` /
  `requirements.txt` — infer language + framework + key deps
- `README.md` first 50 lines — stated purpose / scope / audience
- `.claude/agents/`, `.claude/skills/`, `.claude/hooks/` — prior partial
  setup (someone may have copy-pasted bits of the stack)
- `supabase/`, `migrations/`, `db/` — schema work in progress
- `app/`, `src/`, `pages/` — UI work in progress
- `.github/workflows/` — CI maturity

**Print a 5-line discovery summary**, in the user's terminal, before
asking any questions. Example:

> Discovery: Vite+React+Supabase+Clerk. 47 commits on `master`, 1 author.
> Existing `CLAUDE.md` with project conventions (3 roles, RLS-bound).
> Prior handoff in `.claude/next_prompt.md` covers Supabase wire-up.
> No prior `stack-config.json`. No `docs/handoffs/` directory yet.
> Suggested: tier 2 + domain-mode `schema-migration`. Accept or override?

**Use the discovery to pre-fill defaults** for the tier and domain-mode
question (step 3). The user can accept the suggestion in one keystroke
or override. Never force the cold question when the answer is sitting in
the repo.

If the discovery surfaces a prior handoff or in-flight work, mention it
explicitly so the user knows nothing was lost.

**1c. Tenant-pack detection (M3, ADR-034 §4)**

If a tenant pack was installed globally (`install.sh --pack`), this project
should be initialized tenant-aware: stamped with the `tenant_id`, its CLAUDE.md
carrying the pack's org fragment, and the pack's `standards/` vendored in.

The helper `scripts/lib/project-pack-vendor.sh` is **bash** and sources
`pack-installer.sh` — sourcing it under the interactive **zsh** session shell
fails (a misleading `curl`/function error). Run every call below inside a single
`bash -c` block, never `source` it into the current shell.

Detect the pack (read-only) with:
```
bash -c 'source "<stack_repo>/scripts/lib/config-merger.sh"
         source "<stack_repo>/scripts/lib/pack-lint.sh"
         source "<stack_repo>/scripts/lib/project-pack-vendor.sh"
         resolve_installed_pack "$HOME/.claude"'
```
(`<stack_repo>` is `~/.claude/.stack-install.json` → `source_repo`.)
- **Nonzero / empty output** — no valid pack. This is the normal single-tenant
  case: continue with today's tenant-less behavior, skip the pack steps in 5 + 6.
- **`<tenant_id>|<pack_dir>`** — a pack is active. Note the `tenant_id` and
  `pack_dir`; surface it in the discovery summary ("Tenant pack: `acme` — will
  stamp tenant_id, apply org CLAUDE fragment, vendor standards/"). Use them in
  steps 5 and 6.

### 2. Ask which mode
Print:
> Two modes:
> - **quick** — accept all defaults from your stack-defaults.json with one confirmation
> - **review** — walk through every configurable setting group-by-group
> 
> Which? (quick/review)

Wait for answer. Default to asking; do not assume.

### 3a. Quick mode
- Show all defaults pulled from `~/.claude/stack-defaults.json`.
- Ask: "Accept all? (yes/edit-individual/cancel)"
- If yes: write stack-config.json with these values; jump to step 5.
- If edit-individual: name which settings to change; quick-edit those; write.
- If cancel: stop.

### 3b. Review mode

Walk through groups in order. For each setting: show default, ask user.

**Group 1: Tier and scope**
- Tier (0-5)
- Domain mode(s) — **multi-select** (ADR-053): none, or one or more of
  financial-code / schema-migration / deploy / ui-design / data-operation, all
  simultaneously active. For each mode selected, pre-fill `domain_mode_paths[<mode>]`
  from `config/domain-modes.json`'s `suggested_paths` (step 1b's discovery pass can
  suggest a tier + mode set, per its own example) and let the user accept, edit, or
  clear it (clearing leaves the mode UNMAPPED — always active, no permission
  consequence for `ui-design`/`financial-code`/`data-operation`, but `schema-migration`
  and `deploy` then keep their MCP tools statically denied — ADR-053 D3). Never
  pre-fill a glob the user did not see and approve.
- Sensitivity level (normal | sensitive | confidential)

**Group 2: Orchestration**
- Orchestration mode (main-thread | agent-teams | hybrid)
- Strict mode (on | off)
- Approval gates (configurable list)
- Codex review transport (api | cli) — `api` (default) reaches the OpenAI/GPT-5.5 adversarial-review family via the OpenAI API; `cli` uses the codex CLI with automatic API fallback (ADR-030). Tier 2+ only; writes `review.codex_transport`. Most users keep `api`.

**Group 3: Subagent activation**
- Active subagents (list, defaults from tier)
- Model overrides (per-subagent, optional)

**Group 4: Cost protection**
- Per-session cost alert threshold (default: $5)
- Per-day cost alert threshold (default: $50)
- Hard cost cap per session (default: none)

**Group 5: Project-specific**
- Purpose (one sentence)
- Repo family (related repos, if any)
- Known sensitive data paths (for local-ops routing)

### 4. Safety-relevant changes (both modes)

If user is changing safety-relevant flags from stack-shipped defaults (strict-mode off, domain-mode escape, sensitivity downgrade), prompt for a one-line reason. Append to stack-config.json `change_history`.

**Before asking, confirm the setting actually has a `default_*` (or `session_prefs_defaults.*`) counterpart in `stack-defaults-schema.json`** — the prompt below implies a write capability that does not exist for settings without one, and offering it anyway silently produces `also_updated_global: false` with no way to honor a "yes." `required_approvals` now has one (`default_required_approvals`, added alongside this note); `strict_mode`/`domain_mode`/`sensitivity` already did. If a future safety-relevant setting has no counterpart yet, skip this prompt for it and say so plainly rather than asking a question you can't act on.

Then ask: "Should this also become your default for new projects?"
- [a] Yes, change global default
- [b] No, just this project
- [c] Show me my recent overrides for this setting

### 5. Write stack-config.json

```json
{
  "stack_version": "1.1.5",
  "stack_tier": <chosen>,
  "purpose": "<one-line>",
  "created": "<YYYY-MM-DD>",
  "last_modified": "<YYYY-MM-DD>",
  "orchestration_mode": "<main-thread | agent-teams | hybrid>",
  "strict_mode": <true|false>,
  "domain_mode": "<null | bare string for one mode | array for 2+ modes (ADR-053, canonical write form D10)>",
  "domain_mode_paths": { "<mode>": ["<glob>", "..."] },
  "sensitivity": { "level": "<normal|sensitive|confidential>", "notes": "" },
  "active_subagents": [...],
  "required_approvals": [...],  // fresh project: read from stack-defaults.json's default_required_approvals (fall back to [] if absent); existing project being reconfigured: the user's Group 2 answer
  "model_overrides": {},
  "skill_overrides": {},
  "review": { "codex_transport": "api" },
  "cost_protection": {
    "per_session_alert_usd": 5.00,
    "per_day_alert_usd": 50.00,
    "per_session_hard_cap_usd": null
  },
  "change_history": []
}
```

**Tenant pack active (from step 1c) — stamp the `tenant_id`.** If 1c resolved a
pack, add `"tenant_id": "<tenant_id>"` to the JSON above (top level, after
`purpose`). If you are updating an existing config rather than writing fresh,
set it with the helper instead of hand-editing:
```
bash -c 'source "<stack_repo>/scripts/lib/config-merger.sh"
         source "<stack_repo>/scripts/lib/pack-lint.sh"
         source "<stack_repo>/scripts/lib/project-pack-vendor.sh"
         set_config_tenant_id ".claude/stack-config.json" "<tenant_id>" "$PWD"'
```
No pack → omit the field entirely (do not write `"tenant_id": null`).

**Tier ≥ 2 only — append a `loop_policy` block.** The base JSON above is
tier-agnostic. For Tier 0/1, write it as-is (no `loop_policy`). For **Tier ≥ 2**
(the tier that installs the loop Stop-hook + `/loop-engineer`), insert this block
between `cost_protection` and `change_history`, copied verbatim from
`templates/stack-config.template.json`:

```json
  "loop_policy": {
    "enabled": true,
    "default_autonomy": "checkpoint",
    "autonomy_ceiling": "checkpoint",
    "max_iterations": 25,
    "max_recursion_depth": 5,
    "per_run_budget_usd": 5,
    "timeout_minutes": 180,
    "no_progress_exit": true,
    "require_external_termination": "auto",
    "commit_per_iteration": false,
    "irreversible_actions_break_loop": true,
    "level": null
  },
```

This block is the safe floor and the **ceiling** `/loop-engineer` clamps every
loop to (see ADR-019); raising `autonomy_ceiling` is a safety-relevant change →
log a `change_history` entry. If run at Tier 0/1, `/loop-engineer` falls back to
schema defaults.

`level: null` ships as the out-of-the-box state for **every** new project —
this template's own `default_autonomy`/`autonomy_ceiling` stay at the safe
`checkpoint` value regardless of tier. A project reaches for a named,
higher-ceiling preset (L1-L4, see `config/loop-levels.json`) explicitly via
`/loop-level`, which materializes the preset's literal values into this same
block plus `cost_protection` (ADR-047). Do not hand-edit these fields to
match a level — use `/loop-level` so `level` and the literal values it
materializes never drift apart.

**`change_history` entry shape (v1.1):** Each entry is an object appended when settings are changed (especially safety-relevant ones). Shape:

```json
{
  "date": "<ISO-8601 timestamp>",
  "setting": "<dot-path: e.g. 'strict_mode', 'sensitivity.level', 'cost_protection.per_session_hard_cap_usd'>",
  "old_value": <previous value, any JSON type>,
  "new_value": <new value, any JSON type>,
  "reason": "<one-line reason from user, or 'init' for /project-init creation>",
  "scope": "<'project' or 'global'>",
  "also_updated_global": <true|false — whether user chose to update ~/.claude/stack-defaults.json too>,
  "invoked_via": "<'/project-init' | '/default-edit project' | '/default-edit global' | '/agent-teams' | '/strict-mode' | '/domain-mode' | '/sensitivity' | '/cost-cap' | '/tier'>"
}
```

Example entry after `/strict-mode off` with reason "quick prototype, not worth the project-init overhead":

```json
{
  "date": "2026-05-16T14:32:11Z",
  "setting": "strict_mode",
  "old_value": true,
  "new_value": false,
  "reason": "quick prototype, not worth the project-init overhead",
  "scope": "project",
  "also_updated_global": false,
  "invoked_via": "/strict-mode"
}
```

The librarian subagent (Tier 4) reads change_history across projects to spot patterns ("user overrides this 60% of the time — maybe the default is wrong"). The "show me my recent overrides" option in safety-change flows queries this same data.

### 5b. Compile the permissions boundary (ADR-044; ADR-053 for multi-mode consent)

Immediately after step 5 writes `stack-config.json` (and before the CLAUDE.md
scaffold in step 6), run the same P0 → run 1 → run 2 → reconcile → run 3 → verify
flow `/domain-mode` step 2d runs, with two differences: `/project-init` **always
re-decides** every ack (no carried-forward set B), and its reconcile is the
**only** durable sidecar write it performs — "delete every inherited entry" is the
*content* of that write, never a separate pass.

0. **P0 — preflight, before anything in this section runs.** Evaluate the
   mergeability predicate on `.claude/permissions.stack.json` (an inherited sidecar
   from a prior clone or a hand-edit is the realistic case here):
   ```
   python3 - ".claude/permissions.stack.json" <<'PY'
   import json, sys
   try:
       with open(sys.argv[1], "r", encoding="utf-8") as fh:
           data = json.load(fh)
   except (OSError, ValueError):
       print("file unreadable or not valid JSON", file=sys.stderr); sys.exit(3)
   if not isinstance(data, dict):
       print("root is not a JSON object", file=sys.stderr); sys.exit(4)
   PY
   ```
   Never `jq`, never `python3 -m json.tool`. Absent is mergeable (nothing to
   refuse). On exit 3/4, **abort this whole step** — `stack-config.json` from step
   5 is already written and stays as-is, but print, before continuing to step 6:
   ```
   .claude/permissions.stack.json cannot be merged into (<reason>).
   Refusing before any write: the sidecar is unchanged, and .claude/settings.json
   still holds the PREVIOUSLY compiled permission boundary — which may be WEAKER
   than the one you just asked for. Fix the file, or delete it. Deleting is
   PERMANENT: waivers[] and pinned[] are gone and every waived rule returns to
   deny, and the ADR-044 D8 ownership ledger restarts EMPTY — which strands every
   rule then in settings.json as human-owned, so no future compile can ever prune
   it. Fixing the file costs nothing. Then re-run /project-init or /domain-mode.
   ```
   No delete prompt is ever offered here — this skill's own keep-set rule promises
   `waivers[]`/`pinned[]` are never touched, and deleting the sidecar would break
   that promise.

1. Run `permissions-compile.sh --scope project --repo-root . --dry-run --json`
   (run 1) and parse stdout. Show the user the rule list **grouped by class with
   the class-A/B/C honesty labels** (identity/path = enforced boundary;
   bash-guardrail = never enforcement, raises the cost of an accidental action
   only).
2. **Prompt set** = `{entries in inputs.suppressions_withheld with clause ∈
   {consent, consent-stale}} ∪ inputs.acks_in_force`. A pair drawn from
   `acks_in_force` is shown with its `deny_rules_removed` — the rules that
   answering **n** puts back; a pair from `suppressions_withheld` is shown with its
   `deny_rules` verbatim and the current `scope_hash`. Empty set → no prompt.
3. **Run 2 — the drift gate.** Immediately after the last y/N, nothing yet
   written: re-run the identical `--dry-run --json` invocation and abort (write
   nothing) on any `inputs`/`baseline_version`/`inputs.baseline_hash` difference
   from run 1, naming the first differing field.
4. **R2b — the reconcile's own read.** Evaluate the mergeability predicate on the
   sidecar again (mandatory whenever it exists). On failure, abort before run 3,
   write no sidecar, print the mid-flow divergence message (naming both files),
   never the P0 message.
5. **Reconcile — the one durable sidecar write.** Keep-set is **A alone** (every
   pair answered **y** at this invocation, current `scope_hash`; the inherited
   `reason`/`date`/`by`, if any, offered only as default prompt text, never
   carried forward verbatim). Every existing entry is therefore dropped unless
   re-affirmed here — this is what "always re-decides" means, and it is not a
   separate delete pass preceding the write, it is what the write contains.
   `waivers[]`/`pinned[]` untouched.
6. **Run 3 — the apply** (no `--dry-run`).
7. **Verify**: `inputs.acks_in_force == A`; `inputs.acks_prunable == []`; hash /
   `mcp_servers` / `baseline_version` / `baseline_hash` equal run 2's; both
   report-truthfulness invariants hold. Mismatch → loud error, no rollback, no
   second reconcile.
8. Add `.claude/permissions.stack.json` to the suggested `git add` line below —
   like `stack-config.json` it is **tracked on purpose**, never `.gitignore`d.

If `permissions-compile.sh` is missing, exits non-zero, or emits stdout that does
not parse as JSON at run 1 or run 2: **abort the consent flow** — write no ack,
delete no ack — and print `consent check unavailable (<reason>); no
acknowledgement written — the permission boundary keeps its static denies`. Never
skip silently (that is a fail-open under ADR-025); this replaces the old
"skip silently if `permissions-compile.sh` is not found" clause.

### 6. Scaffold CLAUDE.md, ensure directories, update .gitignore, suggest commit

**Scaffold the project CLAUDE.md.** If no root `CLAUDE.md` exists, copy
`~/.claude/templates/PROJECT-CLAUDE.md.template` to `./CLAUDE.md` and fill in
the repo name, tier, and one-line purpose from the answers above. Leave the
`<...>` placeholder sections for the user to complete. If a `CLAUDE.md`
already exists, do not overwrite it — note that it should be reconciled with
the template by hand.

**Tenant pack active (from step 1c) — apply the org fragment + vendor standards
(M3, ADR-034 §4).** Skip this whole block if 1c found no pack. Run both calls in
one `bash -c` (bash-only lib; never `source` under zsh):
```
bash -c 'set -uo pipefail
  source "<stack_repo>/scripts/lib/config-merger.sh"
  source "<stack_repo>/scripts/lib/pack-lint.sh"
  source "<stack_repo>/scripts/lib/project-pack-vendor.sh"
  apply_project_claude_fragment "<pack_dir>" "./CLAUDE.md" "." || exit 1
  vendor_tenant_standards "<pack_dir>" "."                 || exit 1'
```
- `apply_project_claude_fragment` writes the pack's CLAUDE fragment into the
  project `CLAUDE.md` under its own `<!-- ORG_OVERLAY_MANAGED -->` region
  (idempotent; the core stack region is untouched). It runs even when a
  `CLAUDE.md` already existed — it only replaces the overlay region.
- `vendor_tenant_standards` copies each file in the pack's `standards` map into
  the repo as **committed files** (preserving the pack-relative path, e.g.
  `standards/security.md`), retiring the old symlink + LaunchAgent sync. It is
  fail-closed and all-or-nothing: every source and destination is
  realpath-containment + symlink checked before any write (a pack cannot escape
  its dir or write outside the repo), malformed `standards` schema data hard-
  fails, and a mid-copy failure rolls back the files already written — so a
  partial/half-vendored tree never survives.
- These vendored `standards/` files, plus the updated `CLAUDE.md`, are
  **tracked** — add them to the commit in the final step of this section.

**CI templates (`ci_templates` in `tenant.json`) require a separate human
review step before landing** (security-report.md 2026-08-04, HIGH — the
content is attacker-authored GitHub Actions YAML, not just a path).
`vendor_tenant_ci_templates` copies each `{source, dest}` pair to the
pack-declared destination (always inside `.github/workflows/` — enforced,
issue #123) with the same fail-closed/all-or-nothing/rollback discipline as
`vendor_tenant_standards`, but it will not write anything until a human has
seen the content. Run it once first, without a third argument:
```
bash -c 'set -uo pipefail
  source "<stack_repo>/scripts/lib/project-pack-vendor.sh"
  vendor_tenant_ci_templates "<pack_dir>" "."' 2>&1
```
- **Exit 0, no output:** the pack ships no `ci_templates` — nothing to do,
  skip the rest of this block.
- **Exit 1, output starts with `[pack-vendor-review-required]`:** the pack
  ships one or more CI template files. The output includes each one's
  destination and full content — show it to the user and ask them to
  confirm before it's written into `.github/workflows/`.
- **Exit 1, output starts with `[pack-vendor-fail]`:** a real validation
  failure (bad dest, traversal, etc.) — stop and report it, do not proceed.
- On explicit user approval, re-run with the literal third argument
  `"reviewed"`:
  ```
  bash -c 'set -uo pipefail
    source "<stack_repo>/scripts/lib/project-pack-vendor.sh"
    vendor_tenant_ci_templates "<pack_dir>" "." "reviewed"'
  ```
  The delivered file(s) are then **tracked** — add them to the commit in the
  final step of this section, same as the standards files above.
- If the user does not approve, skip vendoring the CI template(s) and say so
  in the final summary — do not proceed without approval.

**Ensure the docs directory tree.** Create any missing:
- `docs/ADRs/` — copy `~/.claude/templates/ADR.template.md` to
  `docs/ADRs/000-template.md` if absent.
- `docs/runbooks/` — copy `RUNBOOK.template.md` to `docs/runbooks/000-template.md`
  if absent.
- `docs/handoffs/` — the `/handoff` skill archives here.
- `docs/architecture/` — for `data-flow.md` and similar.

**Scaffold ONBOARDING.md.** If `docs/ONBOARDING.md` is absent, copy
`~/.claude/templates/PROJECT-ONBOARDING.md.template` to it.

**Set up cloud-session support (web + iOS).** Cloud sessions run in an
ephemeral container that never sees the user's laptop `~/.claude`, so the
stack's skills/commands aren't discoverable unless they travel with the repo
or are installed at session start. Offer a three-way choice once:
> "Enable the stack in Claude Code cloud sessions (web/iOS)?
>  [t] This repo only — commit a bootstrap hook + portable-core skills into
>      `.claude/` (no env config; travels with the repo).
>  [a] All repos — show the one-time setup-script to paste into the cloud
>      environment (covers every repo on that environment).
>  [b] Both.
>  [n] Skip.
>  (t/a/b/N)"

**If `t` or `b` (this repo):** do all of the following **idempotently — never
clobber existing files; merge or skip and warn instead**:

1. **Bootstrap hook.** If `.claude/hooks/cloud-bootstrap.sh` is absent, copy
   `~/.claude/scripts/cloud-bootstrap.sh` to it and `chmod +x`. If it already
   exists, leave it and note that it was kept.
2. **Wire SessionStart.** Merge the `SessionStart` entry from
   `~/.claude/templates/project-cloud-settings.template.json` into the repo's
   `.claude/settings.json` (the entry runs
   `$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-bootstrap.sh`). If
   `.claude/settings.json` exists, deep-merge — do **not** overwrite it; if an
   equivalent `cloud-bootstrap.sh` SessionStart entry is already present, skip.
   If absent, write the template as the new file.
3. **Portable-core skills.** Read the skill list from
   `~/.claude/config/portable-core-skills.json`. For each, copy
   `~/.claude/skills/<name>/` into `.claude/skills/<name>/` only if the
   destination is absent (skip + note any that already exist). These give the
   repo an offline-safe floor (e.g. `/goodmorning`, `/handoff`) even before the
   bootstrap clone finishes or if the environment's network policy blocks it.
4. **No token needed.** The stack repo is **public**, so the committed
   bootstrap clones anonymously — nothing to configure on the environment, no
   secret. (If the repo is ever made private again, set `CLAUDE_STACK_REPO_TOKEN`
   on the environment; the bootstrap will use it. Never write a token into any
   committed file.) See `docs/CLOUD.md`.

**If `a` or `b` (all repos):** you cannot set the cloud environment from here —
environment setup scripts live in the Claude Code web config, not in any repo.
So **run the `/cloud-setup` skill** (or print its output): it shows the
click-by-click steps and the exact one-liner to paste into the environment's
**Setup script** field, once per environment. Make clear this is a manual paste
the user does in the web UI; `/project-init` can't apply it for them.

If the user declines (`n`), skip this block — they can wire the bootstrap later
via `/project-init`, or run `/cloud-setup` anytime.

**Update `.gitignore`.** Ensure every entry below is present (append any
that are missing — match on the exact line so re-runs don't duplicate). This
block must cover **all** the runtime scratch paths the stack's skills write
under a project's `./.claude/`, otherwise that scratch shows up as untracked
noise in `git status` (one stacked project accumulated ~1,300 untracked lines
from this gap):
```
# Claude Code Stack — runtime scratch, never commit
.DS_Store
.claude/scratch/
.claude/worktrees/
.claude/plans/
.claude/sessions/
.claude/design-targets/
.claude/cost-projections/
.claude/coverage-snapshots/
.claude/reviews/
.claude/validations/
.claude/next_prompt.md
.claude/.automation-offered
.claude/.graphify-init-done
.claude/settings.local.json
.claude/graphify/
# graphify (ADR-054) — regenerable, large, contains source excerpts. Never commit.
graphify-out/
graph.json
```
What writes each path (keep this list in sync if a skill adds a new scratch
location): `scratch/` ad-hoc, `worktrees/` worktree dispatch, `plans/`
`/plan`, `sessions/` the foreman/architect→implementer→validator flow (the
architect-handoff packet lives at `.claude/sessions/<id>/architect-handoff.md`,
so `sessions/` already covers it), `design-targets/` `/design-match`,
`cost-projections/` `/cost-gate`, `coverage-snapshots/` `/coverage-snapshot`,
`reviews/` `/review-handoff`, `validations/` `/validate-output`,
`next_prompt.md` `/handoff`, `.automation-offered` the once-per-repo
automation-recommender offer in `/goodmorning` `/project-init` `/session`,
`.graphify-init-done` the once-per-repo graphify auto-setup marker written
by the graphify setup step below and `/goodmorning`'s catch-up step, the
last four lines above (ADR-054) the receipt directory and vendor-owned
output written by that same step.

**Do NOT ignore** the shared, tracked files: `.claude/stack-config.json`,
root `CLAUDE.md`, and `docs/handoffs/` — those are committed on purpose. (The
stack's own hooks also write to `~/.claude/logs/`, `~/.claude/state/`, and
`~/.claude/projects/`, but those live in `$HOME`, not the project, so they
don't need a project-level ignore.)

> Follow-up (not blocking): the scratch paths above could be consolidated
> under a single `.claude/scratch/` subtree so this becomes one ignore line.
> That's a cross-skill refactor (each skill would change its write path); fix
> the ignore block now, track the consolidation separately.

**Write personal permission-mode override.** Standard across every stack
repo: per-tool-call approval popups are suppressed by default
(`bypassPermissions`), since the real gates are enforced elsewhere (approval
gates, guard hooks, domain-mode review chains) rather than per-tool prompts.
This file is personal and gitignored — never committed, never shared across
machines or users.

1. If `.claude/settings.local.json` does not exist, write it:
   ```json
   {
     "permissions": {
       "defaultMode": "bypassPermissions"
     }
   }
   ```
2. If it already exists, leave it untouched — don't clobber a file the user
   may have customized — and note that it was kept.

**Offer session preferences.** Once, before suggesting the commit:
> "Set communication / working preferences now (style, effort, verbosity, governed-loop autonomy)? [y/N]"
- If yes: run the `/session` skill. Its "save as **project** default" writes
  the choices (incl. `loop_policy.default_autonomy` and
  `session_prefs.auto_offer_loop`) into this project's `stack-config.json`.
- If no: continue — defaults apply (`auto_offer_loop: true`), and `/session`
  can be run anytime. Either way, `loop-shape-nudge.sh` offers loop setup
  every session (not just once) when a prompt looks iterate-until-done —
  toggle `auto_offer_loop` off via `/session` if that nag isn't wanted.

**Offer the automation recommender.** Once, before suggesting the commit:
> "Scan this repo and recommend Claude Code automations (hooks, subagents, MCP servers)? [y/N]"
- If yes: run the `claude-automation-recommender` skill (read-only — it only
  prints recommendations), then continue.
- If no: continue.
- Either way, `touch .claude/.automation-offered` so `/goodmorning` won't
  re-offer on this machine.

**Offer project-status tracking.** Once, before suggesting the commit — this
closes the gap where multi-repo work (a stack merge, a cross-repo migration)
has no durable cross-session record and gets lost between sessions:

1. Read `~/.claude/session-state/live-capabilities.json`, `.plugins[]`. If
   absent/stale or `project-artifact` isn't in the list, print a one-line
   nudge and skip the rest of this block:
   > "Cross-project status tracking (`project-artifact`) isn't installed —
   > run `/plugin install project-artifact@claude-plugins-official` if you
   > want a shareable status page for multi-repo work. Skipping for now."
2. If it's installed, ask once:
   > "Track this project's status with `project-artifact`? [y/N]
   > If this repo is part of a multi-repo effort you're already tracking,
   > name that project/slug and this repo is added as another source. If
   > not, it gets its own status page. (y/N/slug)"
3. On `y` or a named slug: invoke the `project-artifact` skill (its own
   workflow resolves new-vs-existing config from what the user just said —
   no need to duplicate that logic here). On `n`/no answer: skip — nothing
   is lost, `/project-artifact` can be run standalone anytime later.
4. This step never blocks or fails init — a missing plugin, a `WebFetch`
   failure, or a declined offer all fall through to the commit step below.

**Wire the ADR drift check (Tier 2+, any repo with `docs/ADRs/`).** Once,
before suggesting the commit:

1. Detect: chosen tier is 2+ **and** `docs/ADRs/` exists **and**
   `~/.claude/tools/adr-drift/src/check.mjs` is present. If any check fails,
   skip this block silently — plenty of repos keep no ADRs.
2. Run it once to establish the baseline:
   `node ~/.claude/tools/adr-drift/src/check.mjs --json`. Read `count`.
3. Write `adrDrift: { dir, baseline: <count> }` into the repo's
   `package.json` (or note the number for the CI invocation if the repo has
   no `package.json`). **Baselining is deliberate**: an adopting repo almost
   always has pre-existing drift, and a check that fails on day one gets
   disabled rather than fixed. It then fails only when drift RISES.
4. Add it alongside the repo's other cheap CI checks:
   `- run: node scripts/check-adr-drift.mjs` (or the tools path).
5. Print one line: "ADR drift check wired, baseline N — fails only on new
   drift. Lower the baseline as records get corrected."

Why this is on by default at Tier 2+: agents read design documents as ground
truth, at scale, faster than a human notices an error. In carbonet-dashboards
a stale "not built" header on a shipped feature led an architecture review to
call it dead code and recommend replacing the core data model; a sweep then
found 14 more instances. This check costs nothing and catches both mechanisms
(stale status, dangling reference). See `tools/adr-drift/src/check.mjs`.

**Set up graphify (Tier 3+, ADR-054 D11, amended 2026-08-01).** Once,
before suggesting the commit:

1. Detect: chosen tier is 3+ **and**
   `~/.claude/tools/graphify/requirements.txt` is present. If either check
   fails, skip this block silently.
2. Run `/graphify-init` (free, setup-only per ADR-054 D3) — no confirmation
   prompt. Safe to run unconditionally: it's local-only, costs nothing, and
   sends no data anywhere — it only creates the pinned venv at
   `~/.claude/tools/graphify/.venv` (global, not repo state) and relies on
   the `.gitignore` lines already added above. It must never itself invoke
   `/graphify-extract` — building a graph stays a separate, always-manual,
   always-cost-gated call (ADR-054 D1/D12) — and since `/graphify-init`
   writes no CLAUDE.md region (ADR-054 D10), running it changes nothing a
   reader of the repo can see beyond those `.gitignore` lines.
3. Print one line reporting what happened: "graphify set up — index this
   repo anytime with /graphify-extract (costs money, asks first)." On any
   error from `/graphify-init` itself, print what failed instead.
4. `mkdir -p .claude && touch .claude/.graphify-init-done` so `/goodmorning`'s
   catch-up step (for repos initialized before this amendment) never
   re-runs this here. Skip the touch silently if `.claude/` can't be
   written.
5. This step never blocks or fails init — a missing prerequisite or any
   error `/graphify-init` itself surfaces falls through to the commit step
   below.

**Suggest the commit.** Do not commit automatically. Print the suggested
command for the user to run:
```
git add .claude/stack-config.json .claude/permissions.stack.json CLAUDE.md docs/ .gitignore
# if cloud-session support was set up, also stage:
git add .claude/settings.json .claude/hooks/cloud-bootstrap.sh .claude/skills/
# if a tenant pack vendored standards (step 1c / above), also stage:
git add standards/
# if a tenant pack vendored a CI template (step 1c / above), also stage its
# declared destination, e.g.:
git add .github/workflows/
git commit -m "chore: stack init at tier <N>"
```

The committed `.claude/skills/` portable-core set and `cloud-bootstrap.sh`
are **shared, tracked files** (like `stack-config.json`) — the `.gitignore`
block above ignores only runtime scratch, so these are not affected.

After this, foreman is unlocked for the project (strict mode satisfied).

**Point the user at the Setup Dashboard (final step — tier ≥2 only).** Users
won't discover `/stack-config` unless init shows it. After the commit suggestion,
offer once:
> "Setup complete. `/stack-config` (the Setup Dashboard) shows your whole setup —
> stack + native settings, scope-resolved — and safely changes the common ones.
> Want to see it now? [y/N]"
- If yes: run `/stack-config show-current` (read-only — no changes).
- If no / tier <2: continue (skip silently below tier 2, where the dashboard
  isn't installed).
