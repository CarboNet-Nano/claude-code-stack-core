---
name: default-edit
description: Interactive editor for stack configuration. Two scopes — 'global' edits ~/.claude/stack-defaults.json (affects all NEW projects, doesn't change existing); 'project' edits current project's stack-config.json. Confirms each change. For safety-relevant settings, prompts for reason and asks whether to also update global default.
---

> **Note:** `/stack-config` (the Setup Dashboard) is now the single front door for changing settings — `change-one-setting` and `guided-setup-by-goal` supersede this skill with better discoverability and a goal-oriented flow. This skill remains functional and is still invoked by `/stack-config`'s routing; prefer `/stack-config` for interactive use.

# /default-edit

## Usage

- `/default-edit global` — edit personal defaults
- `/default-edit project` — edit current project
- `/default-edit project --setting=<name> --value=<value>` — non-interactive (used by shortcut skills)

## Steps (interactive)

### 1. Load the appropriate config file

### 2. Show grouped settings (same groups as /project-init)
Highlight which have been customized from defaults.

### 3. User picks setting to change

### 4. Show current value, ask for new

### 5. Validate
- Setting exists in schema?
- Value is valid for that setting?
- Are there dependencies? (e.g., orchestration_mode=agent-teams requires Claude Code v2.1.32+ and Opus 4.6+)

### 6. If safety-relevant: ask why
For: strict_mode → off, domain_mode → none (when previously set), sensitivity → normal (downgrade)
- Prompt for one-line reason
- Append to change_history

### 7. If global change of safety-relevant: ask "also project-by-project?"
Default behavior: changing global default only affects NEW projects. If user wants to retroactively apply, list affected projects.

### 8. Apply, log, confirm

### 9. Print "restart session for changes to take effect" if applicable
(Orchestration mode change requires Claude Code restart to pick up env var.)
