---
name: cost-cap
description: Shortcut to set per-session and per-day cost protection. /cost-cap session <usd> sets session alert. /cost-cap day <usd> sets day alert. /cost-cap hard-cap <usd> sets per-session hard limit (cost-gate refuses above this). /cost-cap (no arg) shows current values. /cost-cap clear removes a cap.
---

# /cost-cap

Set cost protection thresholds.

## Usage

```
/cost-cap                                  # status
/cost-cap status                           # status with recent history
/cost-cap session <usd>                    # set per-session alert threshold
/cost-cap day <usd>                        # set per-day alert threshold
/cost-cap hard-cap <usd>                   # set per-session hard limit (refuse work above)
/cost-cap clear session|day|hard-cap       # remove a specific cap
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `cost_protection.*` fields
- Read `cost_log` (Tier 2+) for current session-to-date spending if available
- Print:
  - per_session_alert_usd: $X (current session: $Y)
  - per_day_alert_usd: $X (today so far: $Y)
  - per_session_hard_cap_usd: $X (or "none")
  - Global default values for comparison
  - When each was last changed

### 2. Set session / day / hard-cap

Step 2a: Validate input is positive number; reject if not.

Step 2b: If setting hard-cap, warn:
> Hard caps cause cost-gate to REFUSE work above this amount, requiring explicit override.
> This is a safety guardrail, not just an alert. Continue? [y/N]

Step 2c: Apply
- Update `.claude/stack-config.json` `cost_protection.<field>: <value>`
- Append to change_history
- Print confirmation + global default question (per standard safety flow if applicable)

### 3. Clear (safety-relevant — full safety flow)

If clearing hard-cap: explicit safety flow with reason capture. Other clears: just confirm.

- Update field to null
- Print "<cap> cleared. cost-gate will no longer enforce this limit."

## Validation

- Inputs must be positive numbers (dollars, may have decimals)
- hard-cap must be >= session_alert if both are set (else warn)
- session_alert must be <= day_alert (else warn — unusual but allowed)
