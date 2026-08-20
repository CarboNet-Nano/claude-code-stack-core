---
name: strict-mode
description: Shortcut to toggle foreman's strict mode for the current project. /strict-mode on (default for new projects) means foreman refuses to dispatch in projects without stack-config.json. /strict-mode off allows dispatch without project init. /strict-mode (no arg) or /strict-mode status shows current state. Safety-relevant — turning OFF prompts for reason and offers to update global default.
---

# /strict-mode

Toggle whether foreman requires `/project-init` before dispatching work.

## Usage

```
/strict-mode          # status
/strict-mode status   # status with history
/strict-mode on       # enable (foreman refuses without stack-config.json)
/strict-mode off      # disable (safety-relevant: prompts for reason)
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `strict_mode` field
- Print:
  - Current state (on/off)
  - When last changed (from change_history)
  - What's affected: "Foreman will/will-not refuse to dispatch in projects missing stack-config.json"
  - Global default value for comparison

### 2. on
- Update `.claude/stack-config.json` `strict_mode: true`
- Append to change_history with reason "user invoked /strict-mode on"
- Confirm: "Strict mode ON. Foreman will require /project-init before dispatching."

### 3. off (safety-relevant — full safety flow)

Step 3a: Prompt for reason
> Safety check: you're turning strict-mode OFF in project <name>.
> Strict mode prevents foreman from dispatching in projects without stack-config.json.
> Without it, foreman will dispatch in any project, even uninitialized ones.
>
> Reason for this change? (one line)

Wait for response. Append to change_history with reason.

Step 3b: Ask about global default
> Should this also become your default for new projects?
> Currently your global default is: strict_mode <on|off>
>
> [a] Yes, change global default to OFF
> [b] No, just this project
> [c] Show me my recent overrides for this setting

If [a]: call `/default-edit global --setting=default_strict_mode --value=false`
If [b]: no global change
If [c]: read change_history across all known stack-config.json files; show pattern; re-ask

### 4. Apply
- Update `.claude/stack-config.json` `strict_mode: false`
- Print "Strict mode OFF. Foreman will dispatch in any project. Use deliberately."

## Validation

- Must be called inside a project directory (need .claude/stack-config.json)
- If no stack-config exists: refuse with "Run /project-init first."
