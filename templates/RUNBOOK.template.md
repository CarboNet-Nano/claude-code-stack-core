# Runbook: <When X happens>

Last updated: <YYYY-MM-DD>
Severity: <critical | high | medium | low>

## Quick start

[Open Claude Code with a diagnostic prompt](claude-cli://open?repo=<owner>/<repo>&q=<url-encoded-diagnostic-prompt>)

`claude-cli://` deep links open a new Claude Code session in the given repo with the prompt pre-filled — nothing runs until Enter is pressed. Encode the prompt with `encodeURIComponent`. GitHub strips this URL scheme in rendered Markdown, so on GitHub the link above shows as plain text — copy this URL into your browser's address bar instead:

```text
claude-cli://open?repo=<owner>/<repo>&q=<url-encoded-diagnostic-prompt>
```

See [deep links docs](https://code.claude.com/docs/en/deep-links).

## Symptom

<What does the user / monitoring observe?>

## Diagnosis

```bash
# Commands to run for diagnosis
```

What to look for:
- <pattern>
- <pattern>

## Fix

### Immediate (stop the bleeding)

1. <step>

### Full recovery

1. <step>
2. <step>

## Prevention

- <change to prevent recurrence>
- <monitoring to add>

## Related

- ADR: <link>
- Other runbooks: <link>
- Postmortem: <link if applicable>
