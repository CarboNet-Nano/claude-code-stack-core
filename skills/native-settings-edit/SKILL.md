---
name: native-settings-edit
description: The ONLY writer of Claude Code native settings.json. Sets exactly one allowlisted scalar leaf (model, outputStyle, statusLine preset, an enabledPlugins toggle, or an mcpServers disabled flag) via a hardened script — set-at-path, deny-by-default, atomic, cloud-gated. Invoked only by the /stack-config dashboard after a user confirmation; never edits hooks, env, permissions, or raw MCP command/args. Not for stack-config.json (that is /stack-config + the owning setting-skills).
user-invocable: false
model-invocable: true
recommendable: false
tier_min: 2
tools: Bash
---

# native-settings-edit

The single audited writer of Claude Code's native `settings.json` (ADR-018). It
does **not** decide *what* to change — the `/stack-config` dashboard proposes a
change, the user confirms it, and this skill applies exactly that one change by
invoking the hardened script. The script — not this prose, not the model — is the
enforcement boundary (the 12-item security contract lives in code).

## What it can write (the entire surface)

| Pointer | Value |
|---|---|
| `/model` | a shipped model preset (string) |
| `/outputStyle` | an installed output style (else diff-only) |
| `/statusLine` | an audited preset **name** (`static`, `minimal`) |
| `/enabledPlugins/<key>` | `true`/`false` — existing key only |
| `/mcpServers/<name>/disabled` | `true`/`false` — existing server only |

Everything else native (`hooks`, `env`, `permissions`, MCP `command`/`args`/`env`,
secrets) is **unreachable** — the script hard-refuses it.

## How to invoke

Run the script. Never hand-edit `settings.json` yourself; never construct a
value object — pass a scalar (or a preset name).

```bash
python3 ~/.claude/skills/native-settings-edit/native_settings_edit.py \
  --path <json-pointer> --value <scalar-or-preset> \
  [--scope project|user] [--confirm-global] [--dry-run] [--repo-root <path>]
```

- **Default scope is `project`** (`<repo>/.claude/settings.json`). Writing the
  user file (`~/.claude/settings.json`, affects every project) requires
  `--scope user --confirm-global`.
- **`--dry-run`** prints the diff and writes nothing — use it to show the user
  the exact before/after, then re-run without `--dry-run` to apply.
- Cloud sessions are **read-only**: any real write is refused by the script.

## Required flow (the model proposes, the UI gates, the script validates)

1. The dashboard has already decided the single `--path`/`--value` and shown the
   user a plain-language confirmation ("This will DISABLE plugin X. Confirm?").
2. Run with `--dry-run` first; show the diff.
3. On the user's confirmation, run again without `--dry-run`.
4. Report the script's exit:
   - `0` applied (or diff-only shown) — relay the printed line.
   - `2` refused — relay the one-line reason; **do not** retry with a different
     path to "get around" it. A refusal is the contract working.
   - `3` I/O/parse error — the message is already sanitized; surface it as-is.

## What this skill NEVER does

- Write any path outside the table above (deny-by-default in the script).
- Merge a value blob, or accept an object/array value (set-at-path only).
- Create a new `enabledPlugins` or `mcpServers` key (only flips existing ones).
- Touch `hooks`, `env`, `permissions`, or MCP `command`/`args`/`env`.
- Write anything in a cloud session.
- Echo raw `settings.json` contents (which may hold the `env`/secrets block).

## Maintenance

`MODEL_PRESETS`, `OUTPUT_STYLE_BUILTINS`, and `STATUSLINE_PRESETS` are audited
constants in `native_settings_edit.py`. As Claude Code adds models/styles, update
them there. A value not in a preset list is refused (model/statusLine) or falls
through to diff-only (outputStyle) — never free-typed onto disk.
`tests/test-native-settings-edit.sh` is the contract's regression suite.
