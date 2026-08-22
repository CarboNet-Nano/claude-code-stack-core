---
name: dispatch
description: Manually dispatch a task to a specific subagent team. Override for the foreman's default routing. Use when you want explicit control over which subagents run, or when foreman misroutes. Format — /dispatch <team-name-or-list> for <task>. Available team names match subagent names from config/model-routing.json.
---

# /dispatch

Manual override for foreman routing. Use sparingly — foreman should handle 90% of dispatches automatically.

## Steps

### 0. Usage check (ADR-057, required before dispatching architect/red-team/reviewer)

Run `scripts/usage-check.sh --target <path-or-symbol>` for each building-block
the plan touches. Include a `Usage-check-target: <target>` line per target in
the subagent's dispatch prompt. The gate denies dispatch without this.

### 1. Parse the dispatch request
User says: `/dispatch architect,implementer,reviewer for refactor the digest formatter`
Parse:
- Team: [architect, implementer, reviewer]
- Task: "refactor the digest formatter"

If team is unparseable, list available subagents and ask.

### 2. Confirm
Print the parsed dispatch and ask confirmation:

> "About to dispatch: architect → implementer → reviewer. Task: 'refactor the digest formatter'. Proceed? [y/N]"

### 3. Invoke
Hand off to foreman with explicit team override. Foreman runs through the team in order.

### 4. Compose and report
Same composition format as foreman's default.

## Anti-patterns

- ❌ Using /dispatch to skip approval gates. (Gates still apply.)
- ❌ Using /dispatch for routine work. (Foreman handles it.)
- ❌ Dispatching subagents that conflict (e.g., implementer without architect for a non-trivial change).
- ❌ **Giving an execution task to a read-only role.** `architect`, `reviewer`,
  `architecture-critic`, `red-team` and `estimator` are deliberately read-only —
  architect has no Write by design ("refuses to write code"). A task that must *run*
  something (spin up a container, run a migration, execute a script, take a dump) needs
  a role with Bash — `general-purpose`, `validator`, or `ops`. Cost of getting this
  wrong is a wasted cycle: the agent correctly reports BLOCKED and nothing is lost, but
  check the role fits the verb before dispatching. Likewise, a read-only role asked to
  produce a file should be told to **return the content as its final text** so the
  caller writes it.
