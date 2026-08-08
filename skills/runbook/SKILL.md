---
name: runbook
description: Create or update an operational runbook. Format is "When X happens" → symptom → diagnosis → fix → prevention. Use for every deployed function and every recurring failure mode. Output goes to docs/runbooks/<slug>.md.
---

# /runbook

Create a runbook for an operational scenario.

## Steps

### 1. Identify the scenario
Ask user (or read from incident-commander report if invoked from incident):
- Title (the failure mode, e.g., "MCP authentication expires")
- When does this happen? (symptoms — what you observe)
- How to diagnose? (commands, log locations, what to look for)
- How to fix? (step-by-step recovery)
- How to prevent? (what change would stop this recurring)
- One-click entry point? (repo `owner/name` slug + a short diagnostic prompt — becomes a `claude-cli://` deep link in the Quick start section, so triaging this runbook can open a pre-filled Claude Code session with one click)

### 2. Generate slug
Same convention as ADRs.

### 3. Write file
`docs/runbooks/<slug>.md`:

```markdown
# Runbook: <title>

Last updated: <YYYY-MM-DD>

## Quick start

[Open Claude Code with a diagnostic prompt](claude-cli://open?repo=<owner>/<repo>&q=<url-encoded-diagnostic-prompt>)

GitHub strips `claude-cli://` links in rendered Markdown, so on GitHub the link above shows as plain text. Copy this URL into your browser's address bar instead:

```text
claude-cli://open?repo=<owner>/<repo>&q=<url-encoded-diagnostic-prompt>
```

See [deep links docs](https://code.claude.com/docs/en/deep-links).

## Symptom

<what the user / monitoring sees>

## Severity

<one of: critical (prod down) | high (degraded) | medium (manual workaround) | low (annoyance)>

## Diagnosis

```bash
# Commands to run
<command 1>
<command 2>
```

What to look for:
- <pattern in output>
- <pattern in logs>
- <metric threshold>

## Fix

### Immediate (stop the bleeding)

1. <step>
2. <step>

### Full recovery

1. <step>
2. <step>

## Prevention

- <change to prevent recurrence>
- <monitoring to add>

## Related

- <ADR # if applicable>
- <Other runbooks>
- <Incident postmortem if applicable>
```

### 4. Commit
- `git add docs/runbooks/<slug>.md`
- `git commit -m "docs: runbook — <title>"`
