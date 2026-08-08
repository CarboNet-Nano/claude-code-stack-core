---
name: team-status
description: Show which subagents have been getting work, which are benched, and (with --replan) propose how to bring benched roles into the current work. Reads ~/.claude/logs/subagent-runs.jsonl (populated by the PreToolUse Agent hook). Use when starting a session, before a handoff, or when you suspect foreman is under-using parts of the team.
---

# /team-status

Surface utilization across the subagent roster: who got called, who didn't, who probably should have. The point is to keep the whole team active and catch foreman misroutes.

## Args

- `/team-status` — default: 14-day window, scoped to **current project**.
- `/team-status --global` — same window, across all projects.
- `/team-status --window <N>d` — custom window, e.g., `7d`, `30d`. Default `14d`.
- `/team-status --session` — counts since this session's start (uses `~/.claude/state/session-start.txt`).
- `/team-status --replan` — adds a foreman-style "how to bring benched roles in" section, based on the current branch's uncommitted changes and recent commits.

## Steps

### 1. Resolve inputs
- Log file: `~/.claude/logs/subagent-runs.jsonl`. If missing, print `No subagent log yet — hook may not have fired yet. Run any /Agent dispatch, then retry.` and exit.
- Roster: agents defined in `~/.claude/agents/*.md` (global) plus `.claude/agents/*.md` (project override, if any). Each agent file's filename (minus `.md`) is the agent name.
- Project: `git rev-parse --show-toplevel 2>/dev/null || pwd`.
- Window cutoff: now minus N days (default 14). For `--session`, read `~/.claude/state/session-start.txt`.

### 2. Aggregate counts
- jq query (adjust filters for `--global` / `--session`):
  ```
  jq -r --arg cutoff "$CUTOFF" --arg project "$PROJECT" '
    select(.ts >= $cutoff) | select(.project == $project) | select((.event // "dispatch") == "dispatch") | select(.agent != "workflow") | .agent
  ' ~/.claude/logs/subagent-runs.jsonl | sort | uniq -c | sort -rn
  ```
- For `--global`, drop the project filter.
- **In-play set** = agents named in `event=="dispatch"` rows **union** all names in `(.roster_agents // [])` from `event=="workflow_dispatch"` rows (same window/project filter). Use the union as the active set for benched math (so a roster role exercised only via a Workflow still counts as in-play).
- **Unrostered write-heavy workflows**: count `event=="workflow_dispatch"` rows where `write_heavy==true` and `(.roster_agents // []) == []` and `(.uses_roster != true)`. Print as `Workflows: N write-heavy run(s) with no roster role` (omit line if count is 0).

### 3. Compute benched
- Benched = roster member with **zero** invocations in the window.
- Skip purely-meta roles that shouldn't always fire (e.g., `historian`, `librarian`, `incident-commander`, `agent-performance-review`-only) — only flag if the roster file marks them as routine. (Simple heuristic for Phase 1: flag everything benched; user can mute later.)

### 4. (Optional) Compute should-have-fired misses

Only when `--replan` is set OR called from /handoff. Use these simple rules:

- If `.claude/stack-config.json` has `domain_mode = financial-code` AND no `validator` invocations in window → miss.
- If `domain_mode = schema-migration` AND no `data-engineer` invocations in window → miss.
- If `domain_mode = deploy` AND no `ops` invocations in window → miss.
- If any subagent was dispatched in window AND no `architect` dispatched first in the same window → miss (foreman skipped planning).

For each miss, note the rule that fired.

### 5. Print summary

Caveman tone, fenced code block, no language tag. Compact:

```
Team status (<window>, <scope>)
Used: <agent ×N>, <agent ×N>, ...
Benched: <agent>, <agent>, ... (or "none")
Misses: <rule-name>: <one-line> (omit section if empty)
```

If `--replan` and there are benched roles:
- After the fence, add 1–3 bullets: "To use <agent>: <concrete suggestion tied to current branch state>".
- Keep each suggestion to one line; reference an actual file or commit when possible.

### 6. Stop
Skill is read-only — no writes, no further actions. The deliverable is the summary.
