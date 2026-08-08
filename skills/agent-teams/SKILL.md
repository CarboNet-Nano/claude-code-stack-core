---
name: agent-teams
description: Shortcut to flip orchestration mode. /agent-teams on enables agent-teams mode (sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in .claude/settings.json and orchestration_mode=agent-teams in stack-config.json). /agent-teams off reverts. /agent-teams hybrid enables hybrid mode. /agent-teams (no arg) or /agent-teams status shows current state.
---

# /agent-teams

Shortcut for orchestration mode changes. Always project-scoped.

## Usage

```
/agent-teams          # status (same as /agent-teams status)
/agent-teams status   # detailed status
/agent-teams on       # enable agent-teams mode
/agent-teams off      # revert to main-thread mode
/agent-teams hybrid   # enable hybrid mode
```

## Steps

### 1. No arg / status
- Read current mode from stack-config.json
- Read recent runs from subagent_runs (if Tier 4)
- Print:
  - Current mode
  - When last changed
  - Recent task counts per mode (helpful for /agent-performance-review reasoning)
  - Whether any flags or warnings apply

### 2. on / off / hybrid

Verify pre-requisites:
- Claude Code v2.1.32+ required for agent-teams or hybrid
- Opus 4.6+ access required for agent-teams or hybrid
- Print warning if missing.

For safety-relevant scenarios (domain_mode is financial-code, schema-migration, or sensitivity is confidential):
- Soft-warn: "This project is in <mode>. Agent Teams is experimental and not recommended for <work type> without deliberate acceptance. Continue?"
- Wait for "override: I accept the risk" if user wants to proceed.

Apply change:
- Update `.claude/settings.json` env block: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` = "1" or remove
- Update `.claude/stack-config.json` orchestration_mode field
- Append to change_history with reason ("user invoked /agent-teams <X>")

Ask: "Also update global default for new projects? (y/n/show-recent-overrides)"

Print: "Restart Claude Code session for changes to take effect."
