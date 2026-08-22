---
name: tier
description: Shortcut to view or change the project's stack tier (0-5). Tier change is non-trivial — installs additional capabilities or removes them. /tier (no arg) shows current. /tier <N> changes it (always safety-relevant — triggers install/removal sequence).
---

# /tier

View or change project tier. Tier changes trigger install/removal of capabilities.

## Usage

```
/tier         # status — current tier, what's installed, what's available
/tier status  # status with last-change history
/tier <N>     # change to tier N (0-5). Always safety-relevant.
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `stack_tier` field
- Print:
  - Current tier with name (e.g., "Tier 2: Team")
  - What's installed at this tier (list capabilities from `~/.claude/config/tier-manifests/tier-<N>.json`)
  - What higher tiers would add
  - What lower tiers would remove
  - Global default tier value
  - Last tier change date (from change_history)

### 2. Set tier (always safety-relevant)

Tier changes are always safety-relevant because they install/remove capabilities. Full safety flow:

Step 2a: Determine direction (upgrade or downgrade)

Step 2b: Show diff
> Tier change: <current> → <new>
>
> UPGRADE: this will install:
>   <list new capabilities from tier manifests>
>
> DOWNGRADE: this will remove:
>   <list capabilities that won't run>
> (Files remain on disk; only manifest scope changes. Re-upgrading re-enables them.)

Step 2c: Prompt for reason (always required for tier changes)
> Reason for tier change? (one line)

Step 2d: Confirm
> Apply? [y/N]

Step 2e: Ask global default question
> Should new projects default to tier <new> from now on?

Step 2f: Apply
- Update `.claude/stack-config.json` `stack_tier: <N>`
- Append to change_history
- If upgrade: invoke install scripts for new tiers (calls install.sh with `--tier <N>`)
- If downgrade: no file removal (just manifest scope change)
- Print final state

## Validation

- N must be 0-5
- N must be compatible with installed Tier (can't set to higher than what's globally installed; warn user to run install.sh first)
- Downgrade preserves files on disk (reversible). Upgrade requires install step.
- Tier 5 set requires local-ops subagent — warn if Ollama not installed
