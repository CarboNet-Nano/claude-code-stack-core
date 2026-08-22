---
name: loop-engineer
description: Set up a governed autonomous loop. Use when the user wants an agent to iterate toward a verifiable goal until done (run-until-tests-pass, babysit-PRs, eval-until-threshold, long refactor) rather than a one-shot task. Validates a loop spec, applies the stack-config loop_policy ceiling, and writes loop-state so the Stop-hook enforces caps. Refuses unbounded loops.
tier_min: 2
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read, Monitor, PushNotification
---

# /loop-engineer

Set up a **bounded, governed loop**. You are the front door; the `Stop` hook
(`loop-stop.sh`) does the enforcing. Your job: build a valid loop spec, clamp it
to the project's `loop_policy` ceiling, and write `loop-state.json`. **Refuse to
start an unbounded or unverifiable autonomous loop.**

## Steps

1. **Read the policy.** From `.claude/stack-config.json`, read `loop_policy`
   (ceiling, caps, `require_external_termination`). If absent, use the schema
   defaults (safe floor).

2. **Establish the goal + verification.** Ask the user (or infer) the goal and a
   **machine-checkable success criterion** — a shell command that exits 0 when
   done (e.g. `npm test && npm run lint`, an eval threshold script). This is the
   #1 lever; a loop without it is only as good as its iteration cap.

3. **Pick autonomy, clamp to ceiling.** Never exceed `autonomy_ceiling`. Default
   to `checkpoint` unless the user opts up and the tier/ultracode ceiling allows.

4. **Validate.** Build the spec JSON (see contract) and run:
   `bash skills/loop-engineer/loop_lib.sh` is sourced; call
   `loop_validate_spec "$SPEC"`. If it returns 2, **STOP** and tell the user what
   is missing (a bound, or — for `bounded-autonomous` — a success criterion).

5. **Write loop-state and announce the pattern.** On valid spec, source the lib
   and `loop_write_state "$SPEC_WITH_ACTIVE_TRUE"`. Print
   `pattern selected: <pattern> (<why>)` so a misroute is visible.
   Loop-state is **per session** (ADR-020): it is keyed by `CLAUDE_CODE_SESSION_ID`,
   so a loop you arm here never blocks another session's stops.

6. **Hand to the loop.** Begin the work. The Stop-hook will block stops until the
   criterion passes or a bound trips. To stop early, the user runs
   `/loop-engineer clear` (sets `active=false`).

   **Per-iteration self-check.** A loop has no human reviewing each step, so run
   the *Loop & Self-Check Discipline* (rules 5–10 in the global CLAUDE.md) as the
   gate every iteration: reproduce-with-test before any fix (5), keep the goal
   machine-verifiable (6), debug in one disciplined pass (7), justify every new
   dependency (8), report uncertainty honestly rather than bluff (9), and **stop
   immediately** on a named failure mode — Kitchen Sink, Wrong Abstraction,
   Optimistic Path, Runaway Refactor (10). A wrong direction with no reviewer
   compounds fast; these six are what catch it before the cap does.

7. **Watch a spawned background loop/subagent by event, not just by polling.**
   If the loop's per-iteration work is a background command or a dispatched
   subagent, prefer `Monitor` to watch it: it feeds output back as the
   background task produces it, instead of you re-checking status on a timer.
   This is additive, not a replacement — the Stop-hook's own bound/criterion
   checks still run on every Stop event exactly as before; `Monitor` only
   changes how *you* notice progress between those checks.

8. **Notify a human at real blocking points, not proactively everywhere.**
   Call `PushNotification` at exactly two moments (needs `agentPushNotifEnabled`
   live in `settings.json` — see ADR-018 registry note; already the case on a
   Remote-Control-connected machine):
   - **Loop terminal state.** When the Stop-hook has resolved this loop to a
     terminal `status` (`met`, `escalated`, `no_progress`, `max_iterations`,
     `budget_exceeded`, `timeout` — read via `loop_read_state`), send one
     notification summarizing the outcome before ending the turn.
     A `block` decision (loop continues) is not terminal — do not notify on it.
   - **Blocked on human input mid-loop.** Approval-gate hooks (e.g.
     `schema-deploy-gate.sh`, `migration-guard.sh`) return `permissionDecision:
     deny` — not `ask` — specifically when the transcript is a **workflow
     context** (`transcript_path` containing `/workflows/`); that is the
     branch that reaches you as a denied tool result instead of a native
     prompt to a human. When a tool call you just issued inside a
     workflow-context governed loop comes back denied by one of these gates
     (the reason names the gate), the loop cannot proceed without a human
     relaxing the gate. Send one notification saying what is blocked and why,
     then stop iterating rather than retrying the same denied call.
   Never fire on the interactive main thread's own routine "ask" prompts —
   those already put a human in front of a native permission prompt before
   your turn ever sees a reason, so there is nothing for you to notify on;
   a push notification is only useful for a background/unattended session.

## Spec contract

See `docs/superpowers/specs/2026-06-20-loop-engineering-design.md` §3 for the
`loop-state.json` shape. Required to start: `bounds` (>=1) and — for
`bounded-autonomous` with `require_external_termination` — `success_criterion.command`.

## Headless children (belt-and-suspenders, not a replacement)

`/loop-engineer` itself never shells out to a headless `-p` Claude Code
process — the loop runs as the *current* session, and the Stop hook
(`loop-stop.sh`) enforces `bounds.max_iterations` by counting transcript
turns for that session (ADR-020/023). There is currently no code path in
this repo that spawns a headless child for a governed loop (ADR-051's
`fenced-run.sh` would be that path — it is PARKED and unimplemented; see
`docs/ADRs/051-fenced-invocation-profiles-v2.md` D10, which already reserves
`--max-turns` for exactly this once built).

If you script a headless (`claude -p`) invocation to drive loop-spawned
work yourself, pass `--max-turns` set to the same number as this loop's
`bounds.max_iterations` — the identical ceiling the Stop-hook already
counts against, as a second, CLI-enforced layer on the same number, not a
separate or looser one. `--max-turns` is print/`-p` mode only.

## Clearing a loop

`/loop-engineer clear` → source the lib, write `{"active":false,"status":"cleared"}`.

## What you do NOT do

- Do NOT write loop-state without passing `loop_validate_spec`.
- Do NOT raise autonomy above `autonomy_ceiling`.
- Do NOT run irreversible actions inside the loop (the deny hook blocks them).
