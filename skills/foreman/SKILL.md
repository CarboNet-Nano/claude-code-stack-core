---
name: foreman
description: The orchestrator. Read at the start of any non-trivial task. Reads stack-config.json (refuses in strict mode if missing), classifies the task, determines the right subagent team and sequence, surfaces approval gates, composes results. The main Claude Code thread invokes the actual subagents based on this skill's guidance. In agent-teams orchestration mode, foreman-team-lead subagent takes over; this skill stays the source of truth for routing logic.
---

# /foreman

You orchestrate the team. You don't write code, design, test, or review yourself — you decide who does what, in what order, and you compose the results. The main thread (or, in agent-teams mode, the team-lead session) follows this skill's guidance to invoke subagents.

## Boot sequence (every invocation)

1. **Read `.claude/stack-config.json`.**
   - If missing AND project is Tier 2+: **STOP.** Tell user: "This project doesn't have stack-config.json. Run `/project-init` first."
   - If present, read tier, active_subagents, required_approvals, model_overrides, domain_mode, orchestration_mode.

2. **Check orchestration mode.**
   - `main-thread` (default): you (the main thread) invoke subagents sequentially. This skill guides which and in what order.
   - `agent-teams`: spawn an Agent Team via "create an agent team for <task>". The foreman-team-lead subagent uses this same skill as its routing logic. **Experimental** — parallelize read-only work (review, audit, adversarial investigation) only; keep all file-writing work sequential. See *Parallel-mode safety* below.
   - `hybrid` (recommended over pure agent-teams): the **critical write path runs main-thread** (architect → implementer → validator → reviewer); only **parallel review/audit/exploration** fans out to Agent Teams. Never parallelize implementers.
   - `dynamic-workflows` (Opus 4.8 research preview): for large **read-only fan-out** — codebase-wide audits, multi-angle research, bug hunts. Gated behind `/cost-gate` and **read-only by default**. See *Dynamic-workflows guardrails* below. Not for write-heavy work.

3. **Classify the task.** Based on user's request, pick one:
   - `feature` — new functionality
   - `bug` — fixing broken behavior
   - `refactor` — restructuring without behavior change
   - `migration` — schema change
   - `deploy` — pushing code to production
   - `audit` — read-only review
   - `incident` — production is broken
   - `meta` — stack/config changes
   - `triage` — figure out what to do
   - `documentation` — handoff, spec, ADR set, design doc (v1.1: explicit type)
   - `user-docs` — end-user documentation: onboarding guides, feature walkthroughs (ADR-045)
   - `logic-docs` — explain how a user-visible computed value is derived (ADR-050)

3b. **Detect loop-shape (ADR-019).** If the task is iterate-until-verified
    (run-until-tests-pass, babysit-PRs, eval-until-threshold, long unattended
    refactor/migration), route it to a loop pattern and hand to `/loop-engineer`
    instead of a one-shot dispatch:

    | Task shape | Pattern |
    |---|---|
    | long refactor / migration | ralph |
    | skill / prompt / eval improvement | eval-driven |
    | review / audit gate | generator-critic |
    | recurring / scheduled | scheduled |
    | ad-hoc "until X" | /goal |
    | (default / unclear) | react |

    Tiebreak: most-specific shape wins; ties → `react`. **Always print
    `pattern selected: <pattern> (<why>)`** so a misroute is visible. Emit the
    `success_criterion` + `bounds` into the loop spec for `/loop-engineer`. If the
    task is a normal one-shot, skip this step.

4. **Match the team.** For each task type, the default team is:

   | Task type | Default team |
   |---|---|
   | feature | product-critic → architect → architecture-critic (optional) → implementer + tester + documenter (parallel) → validator → reviewer → red-team (if high-stakes) → scribe |
   | bug | architect (mini) → implementer → validator → reviewer → documenter → scribe |
   | refactor | architect → implementer → validator → reviewer → scribe |
   | migration | data-engineer → architect → implementer → validator (with dry-run on prod clone) → security-auditor → reviewer → scribe |
   | deploy | ops (pre-check) → deploy via /deploy-edge → ops (post-check) → scribe |
   | audit | (read-only relevant specialists) → scribe |
   | incident | incident-commander → relevant specialists → scribe |
   | meta | (skill or hook directly) |
   | triage | product-critic → return to user |
   | documentation (v1.1) | architect → documenter (with /review-handoff gate) → reviewer (optional) → scribe |
   | user-docs (ADR-045) | user-docs-writer (fresh-eyes gate + /review-handoff) → reviewer (optional) → scribe |
   | logic-docs (ADR-050) | /user-docs-logic (parity gate + receipts) → reviewer (optional) → scribe |

4b. **User-docs tail step (ADR-045) — offer, never force.**

    After `validator` passes on a change that is **user-facing** (touches routes,
    pages, or components a signed-in user can reach), foreman OFFERS the docs step.
    It is never added silently and never runs before validation — guides must show
    working software.

    Interactive contexts — ask exactly once:

    > This change is user-facing. Write/update the user guide with
    > `user-docs-writer`? [y/N]

    **Headless contexts — auto-decline + record. Never prompt, never dispatch,
    never block.** A context is headless when ANY of these hold:
    - a loop-state file is active for this session
      (`~/.claude/session-state/loop-state[.<session-id>].json`, ADR-020),
    - the run is scheduled/cron-driven,
    - the work is a `dynamic-workflows` or `agent-teams` fan-out with no
      interactive user.

    In a headless context, append this literal line to the run report AND to
    `.claude/sessions/<session-id>/user-docs-suggested.md` (create if absent):

        user-docs: suggested, auto-declined (headless) — <task> @ <iso>

    then continue the pipeline. Rationale: doc authoring is vision-token expensive
    and its output is human-reviewed prose, so silently auto-accepting inside an
    autonomous loop violates the stack's cost-gate discipline — while skipping
    silently would hide the gap. Auto-decline-with-receipt fails safe and leaves a
    trail.

    Backend-only changes get no offer at all.

4c. **Logic-doc tail step (ADR-050) — offer, never force.**

    After `validator` passes on a change touching a **user-visible computed
    value** (a formula, a pricing/savings/scoring calculation, an aggregation
    shown in the UI), ask exactly once:

    > This change alters a user-visible computed value. Extract/refresh the
    > logic doc with `/user-docs-logic`? [y/N]

    <!-- ADR-050 Contract D: headless policy pending maintainer MCQ -->

    Routing: if a prior `/user-docs-refresh logic` run reported `LOGIC-STALE`
    or `EXEC-DRIFT` for a unit touched by this change, route straight to
    `/user-docs-logic <unit> --refresh` instead of asking — the signal already
    named the remedy. Route to `/user-docs-logic`, **never** to
    `user-docs-writer` — that agent owns screenshot captures, not formulas.
    `STALE-CHECK-UNAVAILABLE` is surfaced to the user as an unresolved
    signal, never silently treated as fresh (ADR-025).

5. **Apply project overrides.** If stack-config.json disables a subagent, skip it. If it forces additional gates, add them.

6. **Apply domain modes (ADR-053 — path-scoped, multi-valued).** Source
   `~/.claude/lib/domain-modes.sh` (fails open — a missing lib means step 6 is a
   no-op, never a dispatch blocker). Then, in order:

   6a. `ACTIVE = dm_active_modes(stack-config.json)`. Empty → skip the rest of
       step 6 entirely.

   6b. Gather the touched-file list, unioned from all available sources,
       normalized to project-relative paths: `git status --porcelain` + `git
       diff --name-only HEAD` (staged + unstaged + untracked) at the project
       root; files this dispatch has already Edited/Written; literal
       path-shaped tokens in the user's own request; for a review-of-an-
       existing-change dispatch naming a base, `git diff --name-only
       <base>...HEAD`.
       - **SCOPED** (union non-empty): `SCOPED_MODES = dm_scoped_modes(config,
         files...)` — every declared mode with a matching glob, plus every
         declared mode with no `domain_mode_paths` mapping (an unmapped mode is
         always active).
       - **UNSCOPED** (union empty, not a git repo, git errors, or `jq`
         missing): **all** declared modes are active, marked **provisional**
         (see 6g). Print `domain scoping: unavailable — all N declared modes
         apply` so this expensive path is never silent.

   6c. Print one line: `domain modes: <all declared> | active for this change:
       <scoped> (<why: matched glob | unmapped -> always active |
       unscoped>)`.

   6d. Union the `required_subagents_for_change`, `required_skills`,
       `approval_gates` of every mode in `SCOPED_MODES` (set-union;
       `validator_must_cross_check` / `require_adr` / `require_rollback_plan`
       are logical-OR, `true` wins). `approval_gates` — the domain-mode review
       checkpoints. Stop and ask the user at each checkpoint as it is reached
       (e.g. `after_architect`, `after_validator`, `before_merge`,
       `after_data_engineer`, `before_apply`, `before_deploy`,
       `after_deploy_verify`, `after_designer_inventory`).

   6e. **Merge forced subagents into the step-4 task-type chain `C`**, using
       `config/domain-modes.json`'s `stage_order` — never reordering `C`'s
       existing members: for each forced agent `a` not already in `C`, insert
       it immediately after the last element of `C` whose `stage_order` index
       is `<= index(a)`; an agent absent from `stage_order` is inserted
       immediately before `scribe` (append if `C` has no `scribe`) and a
       warning is printed.

   6f. Quick reference (authoritative source is `domain-modes.json`):
       - `financial-code`: validator + red-team + security-auditor on any
         merge; validator cross-checks real values.
       - `schema-migration`: dry-run-against-prod-clone before approval;
         architect + data-engineer + reviewer + ops; ADR + rollback plan
         required.
       - `deploy`: ops pre+post; verifies branch != main without explicit
         approval.
       - `ui-design`: designer inventory before build; `/design-match` before
         merge.
       - `data-operation`: `/cost-gate` + `/coverage-snapshot` mandatory.

   6g. **Re-resolve at each of three points** — after the request is
       understood, after the implementer reports, and immediately before each
       approval gate — **add-only** (a mode a real path match activates stays
       active for the rest of the dispatch even if a later resolution no
       longer matches it). The one exception: modes active only because the
       dispatch was **UNSCOPED are provisional, not sticky** — the provisional
       set collapses to the matched set at the first SCOPED resolution; if no
       SCOPED resolution ever occurs before the first gate, the provisional
       (all-modes) set is enforced as-is. Lifetime is **one foreman
       dispatch** — held in working context, no new state file, reset on the
       next `/foreman`.

   **On the permission plane** (`scripts/permissions-compile.sh`, never this
   skill): a suppression `domain_mode_paths` would otherwise buy is withheld
   unless config shape proves scope coherence and, for 2+ modes, a
   hash-bound consent record exists. This is enforced independently of
   foreman's routing above — do not re-derive it here, and do not assume
   mapping a mode is free on the permission plane (`schema-migration` and
   `deploy` have suppressible overlays; mapping either has a permission
   consequence, ADR-053 D3).

7. **Apply tier approval gates.** The `required_approvals` field in
   stack-config.json lists project-specific tier gates (see
   `~/.claude/config/approval-gates.json`). Stop and ask the user before:
   - Pre-merge (if `pre-merge` in `required_approvals`)
   - Pre-deploy (if `pre-deploy` in `required_approvals`)
   - Pre-schema-change (if `pre-schema-change` in `required_approvals`)
   - Pre-bulk-job (if `pre-bulk-job` in `required_approvals`)

   An empty `required_approvals` means "use tier defaults" — the gates in
   `approval-gates.json` are `default_enabled_at_tier: 2`, so at Tier 2+ treat
   the relevant gates as on. The domain-mode checkpoints from step 6 apply
   independently of this field.

8. **Review-pass gate (v1.1).** For any task whose primary output is documentation (handoffs, specs, ADR sets, design docs, audit reports): invoke `/review-handoff` BEFORE signaling completion. This applies regardless of orchestration mode. Documenter subagent owns this responsibility.

## Dispatch protocol

For each subagent in the team:
1. Tell the user which subagent you're invoking and why.
2. **Look up its reasoning-effort baseline** (ADR-056): read `subagent_assignments.<name>.effort` from `config/model-routing.json` (fall back to `~/.claude/config/model-routing.json` per the usual resolution order). If `escalation_triggers` is present, scan it in array order; a trigger "matches" when its `domain_mode` string equals `stack-config.json`'s `domain_mode` (bare-string form) or appears in it (array form, ADR-053) — use the **first** trigger that matches, otherwise use the baseline.

   A matching trigger may raise **two** things, and you must honor both:
   - **`effort`** — the reasoning-effort directive (below). Prompt-injected hint only.
   - **`primary`** — the *model* for this dispatch, overriding
     `subagent_assignments.<name>.primary`. Pass it as the `Agent` tool's `model`
     parameter. Unlike effort, this is **real enforcement**, not a hint.

   A trigger carrying `primary` exists because effort alone did not fix the problem it
   was written for. `implementer` is the worked example: on `financial-code`,
   `sonnet-5/medium → sonnet-5/high` left a check-then-write race in exactly-once
   payment code untouched, while `opus-5/high` closed it in 3 of 3 runs (evidence in
   `docs/model-eval/2026-08-07-implementer-webhook-reverification.md`, and cited in the
   trigger's own `evidence` field). **Raising effort without raising the model would
   silently under-serve that trigger** — the config would look applied while changing
   nothing that mattered.

   Append a one-line directive to the dispatch prompt: `Reasoning effort: <LEVEL> — <brief guidance>` (e.g. `HIGH — verify edge cases and check assumptions before concluding` for high/xhigh, `LOW — favor speed, this is templated/routine work` for low). This is a best-effort hint, not a hard parameter — the `Agent` tool has no native effort control, unlike `Workflow`'s `agent()` (see point 6 below).
3. **If dispatching `architect`, `red-team`, or `reviewer`, declare the usage-checked targets** (ADR-057). For each code building-block the review covers, run
   `~/.claude/scripts/usage-check.sh --target <repo-relative-path|symbol:Name>`
   (a real search — free, local, seconds), then include one line per target in
   the dispatch prompt:

   ```
   Usage-check-target: src/lib/foo.ts
   ```

   The `usage-check-gate` hook validates each declared target against a token
   minted from that run and independently re-runs the check before allowing the
   dispatch. **Currently ships in `warn` mode — it logs, it never blocks.** A
   missing line today produces a telemetry row, not a denial.

   Surface a `unused`/`indeterminate` verdict to the user BEFORE dispatching:
   review spent on code nothing calls is the waste this exists to prevent, and
   catching it here costs seconds instead of a full review cycle.

   Do not improvise searches merely to satisfy the gate, and never paper over a
   deny — if the gate refuses a dispatch, surface it.

4. Invoke the subagent with a clear scope (link to architect-handoff.md, validator-report.md, etc.).
5. Wait for completion.
6. Read the subagent's report.
7. Move to next subagent (parallel where the team is parallel).

### Parallel-mode safety (agent-teams / hybrid / dynamic-workflows)

Anthropic's docs warn: **two teammates editing the same file leads to overwrites.** When any work runs in parallel, enforce these rules. (Note: a Workflow whose `agent()` calls pass `agentType: <roster-name>` is a sanctioned parallel route — it keeps the named roles and their cross-model wiring in play.)

1. **No two parallel agents may write the same file.** Before dispatching a parallel batch, partition the work by file/path ownership and state each agent's owned paths in its scope. If two agents would touch the same file, serialize them (run on main-thread) instead.
2. **Only read-only roles parallelize freely.** reviewer, red-team, security-auditor, accessibility-auditor, validator (read-only checks), and audit-task specialists can run concurrently — they don't write source.
3. **Writers stay sequential.** implementer, data-engineer, and any subagent that edits files run one-at-a-time on the critical path, even in `agent-teams`/`hybrid` mode. Parallelism buys you faster *review and investigation*, not faster *editing*.
4. **On overlap detected mid-run** (two teammates report touching the same file): stop, surface to user, prefer the main-thread result, discard/redo the conflicting one.

### Dynamic-workflows guardrails

`dynamic-workflows` mode uses Opus 4.8's research-preview workflow runtime (fans out up to 16 concurrent / 1,000 total subagents). Its biggest risk is **uncapped token spend** (launch-window incident: ~1.7M tokens burned in a runaway loop, no built-in spend cap, no refunds), and its subagents **auto-approve file edits regardless of session permission mode**. Treat it as experimental and only enter this mode when ALL of these hold:

1. **Read-only by default.** Use it for audits, research sweeps, and bug hunts — not write-heavy tasks. If a workflow must write, it stays out of this mode (route to main-thread).
2. **`/cost-gate` first, every time.** Before launching a workflow, run `/cost-gate` on a scoped sample and get the explicit "proceed". A workflow launch counts as a bulk job — the `pre-bulk-job` gate applies.
3. **Never headless without a sandbox.** Do not run dynamic workflows under `claude -p` / Agent SDK on a writable tree (no interactive edit confirmation there).
4. **Kill-switch known.** If anything looks runaway, stop the run; org-level disable is `disableWorkflows` in settings / `CLAUDE_CODE_DISABLE_WORKFLOWS=1`.
5. **Honor domain modes.** `financial-code`, `schema-migration`, and `sensitivity: confidential` require explicit user override (log it, same as agent-teams).
6. **Use the roster, not generic agents.** A Workflow's default `agent()` spawns a *generic* worker — it does NOT carry the named roster's cross-model wiring (reviewer/security-auditor → Codex, red-team/architecture-critic → Gemini). When a workflow does review/audit/security/architecture work, pass `agentType: '<roster-name>'` to each `agent()` call so the real role (and its non-Claude pass) runs. A workflow is never a reason to drop cross-family review. Write-heavy workflows that name no roster `agentType` trip the `workflow-roster-check` PreToolUse hook: under `workflow_roster:"warn"` (default) it emits an advisory system-reminder (non-blocking); under `workflow_roster:"block"` the run is denied; `workflow_roster:"off"` disables warn/deny but the run is still logged. The `agentType` convention applies across `agent-teams`, `hybrid`, and `dynamic-workflows` — any `agent()` call doing review/audit/security/architecture work should pass a roster name. A Workflow whose `agent()` calls pass `agentType: <roster-name>` is the sanctioned multi-agent write path. **Effort (ADR-056):** when an `agent()` call passes a roster `agentType`, also pass `opts.effort` set to that agent's `subagent_assignments.<name>.effort` (with `escalation_triggers` applied, same lookup as point 2 above) — `Workflow`'s `agent()` supports a real `effort` option, unlike the bare `Agent` tool, so this is genuine enforcement, not just a prompt hint.

## Composition

After all subagents in the team complete, compose a final report:

```markdown
# Task: <user's request>
Date: <iso>

## Team dispatched
- architect (Opus): <one-line outcome>
- implementer (Sonnet): <one-line outcome>
- validator (Sonnet): <one-line outcome>
- reviewer (GPT-5.5): <one-line outcome>
- ...

## Decision required from user
<approval gate question, if any>

## Files changed
<from implementer report>

## Issues found
<aggregated from validator + reviewer + red-team>

## Review-pass status (v1.1, for doc deliverables)
<approve / revise / needs_discussion + path to review report>

## User-docs suggestion (ADR-045)
<none | offered and accepted | offered and declined | "user-docs: suggested, auto-declined (headless)" + receipt path>

## Logic-doc status (ADR-050)
<none | offered and accepted | offered and declined | routed from LOGIC-STALE/EXEC-DRIFT + unit | parity verdict PASSED/FAILED/DEFERRED>

## Recommendation
<one of: "Merge", "Merge with fixes: <list>", "Block — return to architect", "Block — return to user for decision">
```

## What you do NOT do

- Make subagents do work outside their charter.
- Skip approval gates because the task seems routine.
- Dispatch in projects without stack-config.json (strict mode rule).
- Pick model providers — those are in model-routing.json.
- **(v1.1) Declare doc deliverables done without /review-handoff.**

## Failure modes you handle

- **Subagent fails to produce output**: retry once with more explicit scope. If still fails, escalate to user.
- **Capability reported "unavailable" in a cloud session**: before relaying any "X is unavailable" — especially the critic gate (reviewer / security-auditor / product-critic / red-team / architecture-critic / historian) — verify it yourself. A missing CLI is **not** a missing capability. Check the environment: `printenv OPENAI_API_KEY` / `printenv GEMINI_API_KEY` and `command -v codex` / `command -v gemini` (PATH). Confirm the agent actually walked its CLI → key → API/ad-hoc-install fallback ladder. "CLI missing" ≠ "capability missing." In cloud, keys live in the environment's variables — that is the intended mechanism. For the Codex critics, the canonical check is the preflight probe `bash scripts/lib/cross-family-preflight.sh` (ADR-022). **Never let a Codex critic dead-stop**: when the probe returns `BLOCKED_NETWORK`/`BLOCKED_NOCREDS` (key not in the subagent shell, or `api.openai.com` denied by the network policy — neither fixable from inside the session), the agent emits a labeled Claude-only **deviation** + a structured decision. `BLOCKED_MODEL` is different — the key works but the configured review model 404s; that IS fixable in-session (`OPENAI_REVIEW_MODEL=<working alternate from the FIX line>`, then re-probe) and should be retried before any deviation (`re-run-with-key` / `proceed-with-deviation` / `merge-with-tracked-follow-up`). Surface that decision to the user — do **not** auto-merge, and do **not** report the PR as simply "stuck." Fix steps: `docs/runbooks/cross-family-review-cloud.md`.
- **Subagent recommends block**: pass to next subagent only if foreman judges the block to be addressable inline; otherwise stop and ask user.
- **Approval gate hit with user unavailable**: stop, scribe writes handoff with the pending decision, end session.
- **Cross-model check disagreement** (e.g., reviewer says merge, red-team says block): show both, ask user.
- **Review-pass fails (v1.1)**: revise per review report; don't override.

## Strict mode

If `.claude/stack-config.json` is missing AND the user is asking for non-trivial work:
- Print: "Strict mode: this project needs `/project-init` before I can dispatch work. Run it now? [y/N]"
- If yes, invoke project-init skill.
- If no, refuse the task and explain why.

Trivial work that doesn't require strict mode:
- Read-only questions ("explain this file")
- Single one-line edits where user already specified exactly what to change

Anything else: strict mode applies.
