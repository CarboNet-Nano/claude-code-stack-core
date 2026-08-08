---
name: loop-level
description: Shortcut to view or change the project's loop autonomy level (L1-L4). Each level materializes a preset from config/loop-levels.json into stack-config.json's loop_policy and cost_protection blocks — higher levels raise max_iterations/per_run_budget_usd/timeout_minutes for longer unattended runs. /loop-level (no arg) shows current level and the full ladder. /loop-level <L1-L4> changes it (always safety-relevant). Distinct from /tier (capability roster) and /ultracode (session-only, one notch, not persisted).
tier_min: 2
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read
---

# /loop-level

View or change the project's loop autonomy level. Each level is a named,
literal-value preset — not a formula computed at loop-run time. Setting a
level writes concrete numbers into `.claude/stack-config.json`; nothing else
in the loop system (`loop-engineer`, `loop_lib.sh`, `loop-stop.sh`,
`loop-cost-monitor.sh`) needs to know levels exist, because they only ever
read the resulting literal `loop_policy` fields, same as before this skill
existed.

## Usage

```
/loop-level          # status — current level, its values, the full L1-L4 ladder
/loop-level status   # status with change history
/loop-level <L1-L4>  # change level. Always safety-relevant.
```

## Steps

### 1. No arg / status

- Read `config/loop-levels.json` (in the stack repo; resolve via the same
  `find-stack-config.sh`-style lookup other shortcut skills use, or fall back
  to `~/.claude/config/loop-levels.json`).
- Read `.claude/stack-config.json` `loop_policy.level` (may be `null` if never
  set — older projects or a project that predates this skill).
- Print:
  - Current level (or "none set — using literal loop_policy fields as-is")
  - Its live values: `default_autonomy` / `autonomy_ceiling` / `max_iterations`
    / `per_run_budget_usd` / `timeout_minutes`, plus the paired
    `cost_protection` values
  - The full L1→L4 ladder from `loop-levels.json`, one line each, with the
    current level marked
  - Last level change (from `change_history`, if any)

### 2. Set a level (always safety-relevant, always confirm before writing)

Step 2a: Look up the target level's preset in `loop-levels.json`. Reject
anything not in `{L1, L2, L3, L4}`.

Step 2b: Show the diff before writing anything:
> Loop level: `<current or "none">` → `<new>`
>
> loop_policy: max_iterations `<old>` → `<new>`, per_run_budget_usd `<old>` →
> `<new>`, timeout_minutes `<old>` → `<new>`
> cost_protection: per_session_alert_usd `<old>` → `<new>`, per_day_alert_usd
> `<old>` → `<new>`, per_session_hard_cap_usd `<old>` → `<new>`
>
> `irreversible_actions_break_loop` stays `true` — pushes/merges/deploys/
> deletes remain gated at every level.

Step 2c: Prompt for a one-line reason (required, same as `/tier`/`/cost-cap`).

Step 2d: Confirm: `Apply? [y/N]`

Step 2e: Apply
- Write `loop_policy.level`, and materialize every field from the preset's
  `loop_policy` block directly into `.claude/stack-config.json`'s
  `loop_policy` (same keys, literal values — do not leave the old numbers in
  place next to the new `level` tag).
- Materialize the preset's `cost_protection` block the same way.
- **Never** write `irreversible_actions_break_loop: false`, regardless of
  level or what the preset says (the preset never sets it; if a future edit
  to `loop-levels.json` ever adds it, still refuse — this is a hardcoded
  invariant in this skill, not something the data file can override).
- **Never** write a `null` `per_session_hard_cap_usd` when applying L3 or L4 —
  both presets ship a non-null value; if a user asks to null it out while at
  L3/L4, refuse and explain a hard cap is required at that autonomy level.
- Append a `change_history` entry (setting: `loop_policy.level`, old/new
  values, reason, `invoked_via: "/loop-level"`).
- Print confirmation + the standard "apply to global default for new
  projects too?" question is **not** asked here — loop levels are
  intentionally per-project, never a silent global default (see the L1-vs-
  template design note below).

### 3. Design note — this never touches the template default

`templates/stack-config.template.json` ships `loop_policy.level: null` and
keeps its historical safe `checkpoint`/`checkpoint` default untouched. L1-L4
are an **opt-in ladder a project reaches for**, not a replacement for the
safe-by-default new-project experience. Do not add a "make this the new
project default" prompt to this skill.

## Validation

- Level must be exactly one of `L1`, `L2`, `L3`, `L4` (case-insensitive input
  is fine, normalize to uppercase on write).
- Refuse if `loop_policy.enabled` is `false` — say so and point at
  `loop_policy.enabled` first (a level on a disabled policy is a no-op that
  would look like it worked).
- If the project's `stack_tier` is below 2 (where `loop_policy` itself isn't
  installed), refuse and point at `/tier` first.
