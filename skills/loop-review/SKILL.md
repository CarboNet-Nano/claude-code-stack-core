---
name: loop-review
description: Review governed-loop telemetry and propose cap calibration. Reads the loop-runs history (local loop-runs.jsonl + the Supabase stack.loop_runs view when present), shows per-pattern outcomes (met %, budget-exceeded %, iteration-cap %, p50/p95 iterations, avg cost), and proposes loop_policy.max_iterations bumps. Proposals are print-only — applying is a human step via /stack-config. Use to tune loop caps from real run history or audit how loops are behaving.
tier_min: 2
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read
---

# /loop-review

Turn loop telemetry into tuning decisions. You report; the human applies.

## Steps

1. **Source the lib.**
   ```bash
   source ~/.claude/skills/loop-engineer/loop_lib.sh
   ```

2. **Show per-pattern stats.**
   ```bash
   loop_stats_table
   ```
   This prints an aligned table with columns: pattern · runs · met% · budget% ·
   iter_cap% · p50 · p95 · avg $. If it prints **nothing**, say "No loop history
   yet — run some governed loops first" and stop. (`loop_stats | jq .` remains
   available for the raw JSON.)

3. **Propose calibration.** Read the current ceiling from
   `.claude/stack-config.json` (`loop_policy.max_iterations`, default 25), then:
   ```bash
   CUR=$(jq -r '.loop_policy.max_iterations // 25' .claude/stack-config.json 2>/dev/null)
   loop_calibrate "$CUR" | jq .
   ```
   For each pattern, show `observed_p95 → proposed_max_iterations`
   (= max(current, ceil(p95 × 1.2))). Flag patterns with high
   `budget_exceeded_pct` (chronic over-budget) or high `iter_cap_pct` (caps too
   tight) as the ones worth acting on.

4. **Hand off — do NOT auto-apply.** Print the one-liner the user can run to
   apply, e.g. "raise `loop_policy.max_iterations` to N via `/stack-config`."
   Never write `stack-config.json` from here.

## Notes

- Local `~/.claude/logs/loop-runs.jsonl` is always-on; the Supabase
  `stack.loop_runs_30d` view (Tier 3+) is the cross-machine rollup when creds are
  configured.
- Calibration is advisory by design (ADR-023): a loop never rewrites its own caps.
