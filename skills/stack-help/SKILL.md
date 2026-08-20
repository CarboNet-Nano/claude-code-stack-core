---
name: stack-help
description: Print the task-ordered map of every stack command available at this repo's tier — start a session, plan work, ship work, end a session, configure, diagnose. Generated from the installed capability registry, so it never drifts from what is actually installed. Use when the user asks what commands exist, what can I run, what do I do now, show me the commands, or is new to the stack.
user-invocable: true
model-invocable: true
tools: Bash, Read
---

# /stack-help

Resolve the script: `~/.claude/scripts/stack-help.sh` if it exists, else
`<repo-root>/scripts/stack-help.sh`.

Run it with no extra flags and print its stdout verbatim, inside one
unlabelled fence. Add nothing else — no prose, no follow-up questions.

If the script cannot be resolved or exits non-zero, print its stderr (if
any) and one line: `stack-help unavailable — run update.sh`.
