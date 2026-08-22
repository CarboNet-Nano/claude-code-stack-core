---
name: walkthrough
description: Family G2 human-instrument skill (the Sweep, stack ADR-078). Generates a checklist from the E1 route manifest plus surfaces touched since the last walkthrough, asks the user plain-English per-surface questions (multiple choice with a free-text escape), and transcribes answers into finding-records via sweep_emit_finding ONLY. NEVER asks the user for attribution — that belongs to roster-keeper.
---

# /walkthrough

Run these steps in order. This is a structured interview, not a check process (spec §4.6 G2) — there is no envelope, no separate check id to dispatch; you ask the user, the user answers, you write the answer via `sweep_emit_finding`.

## Steps

### 1. Resolve the route manifest
Read `<repo>/.claude/sweep.config.json`. Get `.families.E1.route_manifest_cmd`. Run that command from the repo root — it prints one route per line, and that list is the checklist's universe (the same adapter E1's own check uses, e.g. `sweep-adapters/nextjs-app-router.sh`).

### 2. Scope to surfaces touched since the last walkthrough
Read `<repo>/.claude/sweep/last-walkthrough.json` if it exists (`{ "sha": "<git sha>", "at": "<iso8601>" }`).
- Absent → this is the first walkthrough: the checklist is every route from step 1. **This resolves spec §9 Q5** (scope of the first `/walkthrough`, left open by the design doc) — first run = whole app, every run after that scopes down via this marker file.
- Present → run `git diff --name-only <that sha>..HEAD` and keep only routes from step 1 whose path overlaps a changed file (best-effort match on path segments). If nothing overlaps, fall back to the full route list rather than asking the user nothing.

### 3. Ask the user, one surface at a time
For every surface on the checklist, ask exactly this (spec §4.6 G2 wording — do not paraphrase it):
> Does every number on this screen match what you expect? Is any column labelled something it is not?
> a) Yes — everything matches, no issue here
> b) No — a number looks wrong
> c) No — a column is labelled something it is not
> d) Something else looks wrong (free-text escape — describe it)

Every question to the user is multiple choice with a free-text escape (standing preference) — never open-ended.

### 4. Transcribe answers into finding-records — sweep_emit_finding is the ONLY way to write a finding
For every answer other than (a), source `~/.claude/scripts/sweep/lib/sweep-emit.sh` (the Sweep libraries are installed with the stack, not files in the repo being swept) and build one `finding-record/v1` object, then append it with:
```
sweep_emit_finding "<repo>/.claude/sweep/findings.jsonl" "<record>"
```
`sweep_emit_finding` is the ONLY way to write a finding. Never use `Write`, `Edit`, a shell redirect, or any other tool to append to or edit `findings.jsonl` directly — findings.jsonl is written exclusively through this function, by every family including this one.

A record built by following this list literally must satisfy every field `sweep_emit_finding`'s R7 schema check requires — `schema`, `finding_id`, `identity_key`, `run_id`, `repo`, `created_at`, `what`, `plain`, `mechanism`, `surface`, `surface_source`, `found_by`, `evidence`, `liveness`, `responsible_agent`, `roster_action`. None of these are optional; a record missing any one of them is refused, every time.

- `schema`: the literal string `"finding-record/v1"`
- `identity_key`: the route/surface path — stable, never a timestamp or run id. **R1 caveat:** `identity_key` must not contain a run of 4+ consecutive digits (a year, a build number, a timestamp fragment reads as run identity, not finding identity, and `sweep_emit_finding` refuses it). A route like `/report/2026` has one — group it the same way E1 does: break every 4+ digit run into groups of 3 digits joined by a dash (`/report/2026` → `/report/202-6`). The raw, ungrouped route is never lost — that is what `evidence.locus`, `what`, and `plain` say; only `identity_key` needs grouping.
- `finding_id`: source `~/.claude/scripts/sweep/lib/sweep-emit.sh` and compute it — never invent one — via:
  ```
  sweep_finding_id "<repo>" G2 "<mechanism>" "" "<identity_key>"
  ```
  (repo name, the fixed check id `G2`, this record's `mechanism`, an **empty locus**, and this record's grouped `identity_key`.)

  **The empty locus is deliberate and must stay empty.** It is NOT the same convention `sweep-run.sh` uses: `stamp_finding` there hashes `evidence.locus` into `finding_id`, and these records *do* set `evidence.locus` to the route. That divergence is on purpose and must not be "aligned". `identity_key` already carries the route, so the locus would add no distinctness — it would only add instability: the same screen re-reported with a differently-written route (`/report/2026` vs `report/2026`, a renamed segment, a trailing slash) would mint a fresh `finding_id` and orphan every disposition attached to the old one. Pass the empty string here, every time.
- `run_id`: `` `date -u +%Y-%m-%dT%H:%M:%SZ`.<short suffix> `` — the same shape `sweep-run.sh`'s own `RUN_ID` uses (UTC timestamp, a literal `.`, then a few random hex characters), so a walkthrough run is identifiable the same way any other Sweep run is.
- `repo`: the repo name (e.g. the basename of the repo root)
- `created_at`: UTC now, `date -u +%Y-%m-%dT%H:%M:%SZ`
- `what`: a technical restatement of `plain`, 300 characters or fewer
- `plain`: one plain-English sentence naming the screen and what looks wrong — no check ids, no file paths (spec §4.6 G2)
- `found_by: "human-walkthrough"`
- `surface: null`
- `surface_source: "unset"`
- `mechanism`: the closest fit from the finding-record enum given the user's answer — `WRONG VALUE` for "a number looks wrong", `CONTRACT DRIFT` for "a column is labelled something it is not", best judgment from the enum for the free-text case
- `evidence.locus`: the route/surface path, raw and ungrouped; `evidence.measurement`: `{statement, count: 1, denominator: 1, source: "human"}`
- `liveness: {assertions_executed: 1, assertions_passed: 0}` — one question asked, and it surfaced an issue
- `responsible_agent: null`, `roster_action: null` — `/walkthrough` never fills these in (spec §4.4); triage is roster-keeper's job, written into `attributions.jsonl`, not here

### 5. NEVER ask the user for attribution
Do not ask who is responsible for a finding, which agent should own it, or anything about roster assignment — that prompt belongs to the roster-keeper initiative, and its spec owns it (decision 7). `/walkthrough` writes the finding and nothing else.

### 6. Update the walkthrough marker
Write `<repo>/.claude/sweep/last-walkthrough.json` with the current git sha and an ISO-8601 timestamp, so the next `/walkthrough` scopes step 2 correctly.

### 7. Stop and wait
Print a one-line summary (surfaces checked, findings emitted) and stop. `/walkthrough` transcribes; it does not remediate.
