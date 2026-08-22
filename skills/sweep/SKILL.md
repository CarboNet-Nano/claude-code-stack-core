---
name: sweep
description: Run the Sweep — pick a cadence (default manual), invoke ~/.claude/scripts/sweep/sweep-run.sh, render the G7 plain-English block via ~/.claude/scripts/sweep/sweep-render.sh. Exit code 2 (liveness failure) is always a hard stop reported in the same sentence, never treated as a flake. Reports only; does not fix findings.
---

# /sweep

Run these steps in order. The deliverable is the rendered plain-English block — do not start fixing findings after this skill, just print the report and wait.

## Steps

### 1. Pick cadence
Default: `manual`. If the user's request clearly implies a different cadence, use it instead (e.g. "run sweep before merging" → `pr`, "run the nightly sweep" → `nightly`). If genuinely ambiguous, ask:
> Which cadence?
> a) manual — default, ad hoc run right now
> b) pr — what a pull-request run would do (renders only, never writes findings)
> c) diff — scoped to changes since a given sha
> d) push-main / nightly / session-close — the cadences that actually write `findings.jsonl` (these normally run in CI, not by hand)
(free-text escape: name the cadence directly if none of these fit)

### 2. Run the runner
The Sweep scripts are installed with the stack, at `~/.claude/scripts/sweep/` — they are not files in the repo being swept. Run from the repo root (the runner's `--repo` defaults to the current directory):
```
~/.claude/scripts/sweep/sweep-run.sh --cadence <cadence> --json
```
Add `--changed-from <sha>` when cadence is `diff`, and `--families A1,A2,...` if the request scopes to specific families. Capture stdout (the `sweep-run/v1` JSON envelope, including its `.run_id` and `.sentence` fields) and the process exit code.

Exit codes: `0` pass/observe, `1` blocking findings, `2` liveness failure, `3` configuration invalid.

### 3. Render the G7 block
Source `~/.claude/scripts/sweep/sweep-render.sh` and call:
```
sweep_render <repo> [--run <run_id>]
```
using step 2's `.run_id`. This produces the fixed G7 plain-English acceptance format: "Checked N screens and M background jobs. Found K things worth your attention: <one plain sentence each>. Nothing else changed."

### 4. Exit code is 2 → hard stop, never a flake
If step 2's exit code is 2, the Sweep itself did not run, or ran only partially — this is a **hard stop**, not a transient failure to retry, ignore, or quietly re-run. Print step 2's `.sentence` field (or the `--plain` output's last line) verbatim, folded into the report you show the user, and stop there. Do not re-invoke the runner hoping for a clean pass, do not continue as though the rendered findings in step 3 are current, and do not describe this as flaky — spec §4.6/§5.4, and the roster's own `validator` role runs `/sweep` in-session and interprets exit 2 the exact same way: a hard stop, never a flake.

### 5. Exit code 0 or 1 → report normally
Print step 3's render. Exit 1 (blocking findings) is not itself a hard stop — it means findings exist at the current mode's blocking threshold. Surface them via the rendered sentence; the Sweep is not a fixer (spec §3) — remediation goes through the normal foreman → implementer path, not this skill.

### 6. Stop and wait
Do not start fixing findings, re-running checks, or asking follow-up questions beyond step 1's single cadence prompt. The rendered report is the deliverable — wait for the next user prompt.
