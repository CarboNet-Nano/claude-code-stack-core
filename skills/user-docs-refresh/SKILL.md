---
name: user-docs-refresh
description: Check committed user guides against the live app by replaying their Playwright docs-tests, then classify any changed screenshots with a dedicated freshness prompt. Reports STALE / NEEDS-RECAPTURE / AUTH-EXPIRED / RUNNER-UNAVAILABLE, and updates step text via user-docs-writer when a change invalidates instructions. Also runs logic-unit freshness (ADR-050): LOGIC-STALE / EXEC-DRIFT / HARNESS-CHANGED / HARNESS-UNRUNNABLE / STALE-CHECK-UNAVAILABLE. Use before a release, on a /goodmorning nudge, or when UI paths changed since the last refresh marker.
---

# /user-docs-refresh

Usage: `/user-docs-refresh <guide-slug>` · `/user-docs-refresh --all` ·
`/user-docs-refresh logic <unit-slug>` · `/user-docs-refresh logic --all`

The `logic` subcommand (below) checks logic-unit receipts, not screenshot
guides — it never touches the browser or the Playwright runner.

## Step 0 — Preflight

Same browser-server resolution and runner bootstrap as `/user-docs` step 0. A failed
bootstrap is `RUNNER-UNAVAILABLE` — never reported as STALE.

## Step 1 — Cost gate (`--all` only)

`--all` is dispatched with `task_type: bulk_job`, which puts it behind the existing
`pre-bulk-job` gate in `config/approval-gates.json` (default-enabled at Tier 2+).
Before the gate prompt:

1. Run `/cost-gate` on a **10-capture sample**: replay + vision-compare ten captures,
   measure actual input/output tokens.
2. Write the projection to `.claude/cost-projections/<date>-user-docs-refresh.md`.
3. Stop for explicit approval.

Single-guide refreshes are bounded (a handful of vision calls) and run **ungated** —
do not prompt for them. Hard-breakage detection is free either way: assertions fail
before any vision call.

## Step 2 — Replay, per `docsMeta.replay` (scope c)

| Mode | Runner behavior (this build) |
|---|---|
| `auto` | Replay freely, including in `--all` sweeps. |
| `reset-required` | **Refused.** Report `NEEDS-RECAPTURE (reset-required, not yet automated)`. Reset-command execution is a follow-up phase, not built here. |
| `manual` | Never auto-replayed. Report `NEEDS-RECAPTURE (manual)`; the remedy is a human running `/user-docs <guide> --recapture`. |

Signals, each with one meaning and one remedy:
- **STALE** — an `auto` replay ran and a native assertion failed: the UI genuinely
  changed under the doc. Zero vision cost.
- **NEEDS-RECAPTURE** — non-idempotent flow (reset-required or manual), human-triggered recapture.
- **AUTH-EXPIRED** — login redirect on first `goto`; re-run the auth bootstrap.
- **RUNNER-UNAVAILABLE** — npm/browser bootstrap failed; fix tooling, then re-run.

## Step 3 — Compare captures

For each successful `auto` replay, compare each new PNG to the committed one.
**Byte-identical → skip vision entirely.** Send only differing pairs to the vision
call, with this prompt verbatim:

> Image 1 is the screenshot currently published in a user guide (a historical
> record — NOT a desired state). Image 2 is a fresh capture of the same step today.
> Did the user-visible steps, labels, control locations, or outcomes change in a way
> that invalidates the written instructions? Answer: `unchanged` | `cosmetic`
> (visual drift, instructions still accurate) | `invalidating` (documented
> steps/labels no longer match), with the specific instruction-affecting changes.
> Do not evaluate which version looks better and do not suggest changes to the
> application.

**Do not reuse `/screenshot-diff`'s prompt.** That prompt frames image 1 as the
TARGET design and asks how to make the actual match it — under that framing a
genuine UI improvement reads as a regression from the old doc screenshot and the
tool recommends reverting product improvements. Freshness asks the opposite
question. Shared vision plumbing is fine; the prompt is not.

## Step 4 — Outcomes

| Verdict | Action |
|---|---|
| `unchanged` | Keep the committed PNG. No pixel-churn commits. |
| `cosmetic` | Stage the new PNG. Guide text untouched. |
| `invalidating` | Stage the new PNG **and** dispatch `user-docs-writer` to update the affected steps, then **re-run the fresh-eyes gate** (`/user-docs` step 5). |
| `STALE` / `NEEDS-RECAPTURE` / `AUTH-EXPIRED` / `RUNNER-UNAVAILABLE` | Report loudly with the named remedy. Never auto-"fix" by deleting a guide. |

## Step 5 — Report

Write `.claude/sessions/<session-id>/user-docs-refresh-report.md`: per guide, its
status, capture counts (identical / cosmetic / invalidating), vision calls made, and
any dispatch triggered. End with the single loudest unresolved signal. If logic
mode (below) also ran this invocation, its results go in the same report under a
`## Logic units` heading.

## Logic mode (ADR-050) — `/user-docs-refresh logic <unit-slug>` · `--all`

Checks the freshness of a logic unit's receipts. Zero LLM tokens, zero vision,
zero browser — a single-unit run is **ungated** (runtime-only cost); `--all`
still declares `task_type: bulk_job` and goes through the same `pre-bulk-job`
gate as the screenshot `--all` sweep above (Step 1) when it fans out across
many units.

1. **Stale check (Contract B):**
   `scripts/logic-stale-check.sh docs/user/.meta/<unit>.receipts.json <repo-root>`
   - exit 0 `FRESH` — no cited span overlaps a change since extraction.
   - exit 1 `LOGIC-STALE: <file>:<start>-<end> (rule <n>)` — re-run
     `/user-docs-logic <unit> --refresh` (re-extraction, not this skill).
   - exit 2 `STALE-CHECK-UNAVAILABLE: <reason>` — **surface to the user as
     unresolved, never report as fresh** (ADR-025). Remedy: re-extract to
     re-anchor `extraction.commit`.
2. **Exec recheck (Contract C):** runs regardless of the stale-check result
   (§7 red-team #4 — untracked config/DB/flag drift has no tracked-file
   footprint for Contract B to see):
   `scripts/logic-exec-recheck.sh docs/user/.meta/<unit>.receipts.json <repo-root>`
   - exit 0 `EXEC-FRESH` — receipts `execution.lastRunAt`/`lastRunCommit`
     updated automatically by the script.
   - exit 1 `HARNESS-CHANGED: ...` — the committed harness itself was edited;
     remedy is a full `/user-docs-logic <unit> --refresh` gate re-run, **not**
     a recheck retry.
   - exit 1 `EXEC-DRIFT: <id> expected <json> got <json>` — investigate
     untracked state (DB thresholds, feature flags, config) before
     re-extracting; this is a distinct signal from `LOGIC-STALE` with its own
     remedy, never conflated with it (ADR-045 D8, ADR-050 D5).
   - exit 2 `HARNESS-UNRUNNABLE: <reason>` — a tooling fault (missing dep,
     broken env), never reported as `EXEC-DRIFT`. Fix the environment and
     re-run; the logic itself is unproven either way, not disproven.
3. **Routing:** any of `LOGIC-STALE` / `HARNESS-CHANGED` / `STALE-CHECK-UNAVAILABLE`
   routes to `/user-docs-logic <unit> --refresh` — **not** to `user-docs-writer`,
   which owns screenshot captures, not formulas. `EXEC-DRIFT` alone does not
   require re-extraction; report it and let a human investigate first.
