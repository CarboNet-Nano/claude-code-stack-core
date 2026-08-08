---
name: handoff
description: Write a handoff doc to .claude/next_prompt.md so the next Claude Code session can resume cleanly. Captures branch state, what shipped this session, what's blocked, exact next steps, and gotchas (env/auth/sandbox). The SessionStart hook reads this file at the start of the next session. Also archives a copy to docs/handoffs/<date>.md, then commits + pushes BOTH files to the default branch so cloud / fresh-clone sessions can resume via /goodmorning (not just the machine that wrote it).
---

# /handoff

Run at the end of a working session. Writes `.claude/next_prompt.md` (the "live" handoff for the next session) and `docs/handoffs/<YYYY-MM-DD-HHMM>.md` (the permanent archive).

## Steps

### 1. Ensure directories exist
- `mkdir -p .claude`
- `mkdir -p docs/handoffs`

### 2. Ensure the live handoff is TRACKED (not gitignored)
- Both files must reach Git so a cloud / fresh-clone session can find the handoff via `/goodmorning` — not just the machine that wrote it.
- If `.gitignore` contains `.claude/next_prompt.md`, **remove that line** (older versions of this skill ignored it).
- The live handoff is not secret, but Step 6 scans it before committing — never commit credentials.

### 3. Gather state
- `git branch --show-current`
- `git status --short`
- `git log --oneline -10`
- `git diff --stat HEAD~5..HEAD 2>/dev/null`
- `gh pr list --author @me --state open 2>/dev/null`
- `gh pr checks 2>/dev/null` (if PR exists for current branch)
- **Team utilization this session** (skip block if `~/.claude/logs/subagent-runs.jsonl` is missing):
  - `SESSION_START=$(cat ~/.claude/state/session-start.txt 2>/dev/null)`
  - `PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)`
  - Counts (direct dispatches only — exclude `agent:"workflow"` sentinel; use `// "dispatch"` guard for old rows lacking the `event` field): `jq -r --arg s "$SESSION_START" --arg p "$PROJECT" 'select(.ts >= $s) | select(.project == $p) | select((.event // "dispatch") == "dispatch") | select(.agent != "workflow") | .agent' ~/.claude/logs/subagent-runs.jsonl | sort | uniq -c | sort -rn`
  - In-play set: union the above agent names with all names in `(.roster_agents // [])` from `event=="workflow_dispatch"` rows (same session/project filter) — roles exercised via rostered workflows count as active.
  - Unrostered write-heavy workflows: count `event=="workflow_dispatch"` rows where `write_heavy==true` and `(.roster_agents // []) == []` and `(.uses_roster != true)`.
  - Misses: apply rules from `/team-status` Step 4 (financial-code → validator; schema-migration → data-engineer; deploy → ops; any-dispatch → architect-first).
- **Durable corrections (loop-eng Phase 3, skip if file missing):** read unresolved
  loop corrections **scoped to this project** so a goal-unmet loop's lesson carries
  forward only into the repo it actually belongs to (not every repo on the machine) —
  `jq -c --arg p "$PROJECT" 'select(.resolved != true) | select(.project == $p)' ~/.claude/session-state/loop-corrections.jsonl 2>/dev/null`.
  Entries written before the `project` field existed have no `.project` and will no
  longer surface anywhere via this filter — that's expected, not a regression; resolve
  or re-file them by hand if still relevant.
  Summarize each as `loop <loop_id> exited <status> — <hint>` under a **Loop corrections**
  bullet in *What's blocked & why* (or *Gotchas*). If none, omit.
- **Model-fit receipt (ADR-033, skip if pref is `off` or the lib is missing):**
  Read `session_prefs.model_fit_receipt` from `~/.claude/session-state/current-prefs.json`
  (default `on`). If not `off` and `skills/loop-engineer/loop_lib.sh` exists, source it and call:
  `model_fit_receipt_line "$SESSION_START" "$PROJECT" ~/.claude/logs/subagent-runs.jsonl`
  (same `$SESSION_START`/`$PROJECT` as the team-utilization block above). Print
  the returned line verbatim under a **Model-fit receipt** heading. Empty
  result (insufficient evidence, or an all-subagent session with zero
  `main_turn` rows) → omit the section entirely, no placeholder text.

### 4a. PM close-out (run before composing the handoff)

Only applies when this repo is a member of a PM portfolio (`config/portfolio.json` lists it under some portfolio's `members`, matched by repo basename) **and** the session's work maps to a track under `.claude/tracks/*.md`. If either isn't true, skip straight to Step 4.

- **Identify the active track.** If exactly one `.claude/tracks/*.md` file matches this session's work, use it. If more than one exists and it's ambiguous which one this session belongs to, ASK the user:
  > Which track does this session's work belong to?
  > a) `<track-a>` — <one-line goal from its frontmatter>
  > b) `<track-b>` — <one-line goal from its frontmatter>
  > c) None of these — skip PM close-out
- **Identify the portfolio.** Read `config/portfolio.json`; find the portfolio whose `members` include this repo. If this repo isn't listed in any portfolio, skip PM close-out.
- **Gather closeout inputs:**
  - `--state "<one-line current state>"` — required. Becomes the track file's `## Current state` section (the session's actual state, not a copy of the old one). No absolute paths (`/Users/...`, `/home/...`) or secrets in `--state` — journal validation now runs before any file/issue mutation and refuses the whole close-out on a hit (nothing gets written), so a path- or secret-shaped state fails clean but still fails.
  - `--done <repo>#<number>:<comment>` — repeatable, one per issue this session closed. `comment` is required per entry (closeout refuses a `--done` entry with an empty comment). Omit entirely if nothing was closed this session.
  - `--next '<json>'` — a JSON array of `{ "repo": "...", "title": "...", "body": "..." }` objects, one per issue to file for the next session to pick up. Omit (or pass `'[]'`) if there's nothing to hand off.
- **Run:**
  ```
  node ~/.claude/tools/pm/bin.mjs closeout --track <track> --portfolio <portfolio> --state "<state>" --done <repo#num:comment>... --next '<json>'
  ```
- **This step is FAIL-FAST.** On any failure it prints `FAILED closeout`, the list of already-completed steps, and the failed step, then exits non-zero. **STOP immediately on a non-zero exit** — do not continue composing the handoff as if close-out succeeded. Surface the printed completed/failed output to the user, resolve the underlying issue (or get explicit sign-off to proceed without PM close-out), and only then continue.
- On success (`closeout complete: ...`), note the track file's path and the repo#number of every issue filed via `--next` — Step 4's "Exact next steps" section points to these instead of restating the plan.

### 4. Compose the handoff content

Use this exact structure:

```markdown
# Next-session handoff

_Written: <YYYY-MM-DD HH:MM PT>_

## Branch & state
- Branch: `<branch-name>` (worktree: `<path-or-N/A>`)
- Uncommitted: <N files, list paths or "clean">
- Behind/ahead of origin: <e.g., "up to date" / "2 ahead, 1 behind">
- Cost: run `/usage` (alias `/cost`) for this session's token/cost breakdown

## What shipped this session
- <commit-sha> — <subject>
- <commit-sha> — <subject>
(top 3–5 commits relevant to today's work; link PR# if applicable)

## What's blocked & why
- <blocker, with the specific obstacle — auth token expired / waiting on review / unclear requirement>
(omit if nothing blocked)

## Exact next steps
- Track: `.claude/tracks/<track>.md` — full plan lives there, not duplicated here
- Filed: <repo>#<num> — <title>
- Filed: <repo>#<num> — <title>
(if Step 4a ran: track file link + every issue filed via its `--next`, no other prose. If Step 4a was skipped — repo not in a PM portfolio, or no track applies — fall back to a freeform numbered list of concrete actions, each with a file path or command.)

## Gotchas
- <env var that needs rotating, e.g., "SUPABASE_ACCESS_TOKEN expires Friday">
- <sandbox limit, e.g., "this branch needs `gh pr create` from your terminal — sandbox can't push">
- <MCP issue, e.g., "Supabase MCP returns 401; rotate via keychain item">
(omit if none)

## Cross-repo references
- <If this work depends on or affects other repos, note them with specific files/PRs>
(omit if standalone)

## Team this session
- Used: <comma list of agents with counts, e.g., "architect ×2, reviewer ×1">
- Unrostered write-heavy workflows: <N> (omit line if 0)
- Benched (should-have-fired):
  - <agent>: <rule that flagged it, e.g., "domain_mode=financial-code, no validator dispatched">
(omit "Benched" subsection if no misses; omit whole section if no log file yet)

## Model-fit receipt
<one line from model_fit_receipt_line, verbatim>
(omit whole section if pref is off, or the line is empty)
```

### 5. Write BOTH files
- Write to `.claude/next_prompt.md` (overwrites previous). This is the session pointer, not a plan doc — it links to track files (per Step 4's "Exact next steps") rather than restating their content.
- Write to `docs/handoffs/$(date +%Y-%m-%d-%H%M).md` (new file each session).

### 6. Commit + push the handoff (and track file) to Git (so cloud/fresh sessions can find them)

The handoff is useless to another environment if it only lives on this machine.
Always land these files on the **default branch** (`main`/`master`) — the next
`/goodmorning` pulls from there, not from a feature branch. If Step 4a ran,
the track file it wrote (`.claude/tracks/<track>.md`) travels with the
handoff in every substep below — it's the thing "Exact next steps" points
to, so it must land in the same commit or the link is dead for anyone else.

1. **Secrets scan — refuse on hit.** Grep `.claude/next_prompt.md`, the `docs/handoffs/<file>.md` archive, **and** the track file (if Step 4a ran — its `## Current state` is session-derived text, not template boilerplate) for `secret|password|token|api[_-]?key|service_role|bearer|ey[A-Za-z0-9_-]{20,}`. If anything matches in any of them, do NOT commit — surface it and ask the user to scrub first.
2. **Stage + commit:** `git add .claude/next_prompt.md docs/handoffs/<file>.md` — and if Step 4a ran, also `git add .claude/tracks/<track>.md` — then commit (`docs(handoff): <YYYY-MM-DD> session handoff + archive`).
3. **Get it onto the default branch:**
   - Try a direct push: `git push origin HEAD:<default>` only if you're on `<default>` and it's not protected.
   - Otherwise (you're on a feature branch, or push is rejected by branch protection): create `chore/handoff-<YYYY-MM-DD-HHMM>` off `origin/<default>`, move these files (handoff + archive + track file, if any) onto it, commit, push, and `gh pr create --base <default>`. Repos with auto-merge land it on green; otherwise tell the user to merge it.
   - If there's no remote / no `gh`: commit locally and tell the user it's local-only (cloud won't see it until pushed).
4. Don't let session work-in-progress ride along — commit ONLY the two handoff files plus the track file Step 4a wrote (if any) — no other work-in-progress.

### 7. Confirm
- Print absolute paths of both handoff files (and the track file, if committed) + the branch/PR they landed on (and merge state).
- Print first 5 lines of each as sanity check.
- Stop. Do not run further commands.
