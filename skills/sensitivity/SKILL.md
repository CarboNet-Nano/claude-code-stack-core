---
name: sensitivity
description: Shortcut to set the project's data sensitivity level. Three levels — normal (default), sensitive (PII present — extra logging), confidential (regulated data — local-ops routing required, cloud subagents restricted). /sensitivity <level> sets it. Downgrading is safety-relevant. /sensitivity (no arg) shows current and what it restricts.
---

# /sensitivity

Set the project's data sensitivity level.

## Usage

```
/sensitivity                  # status
/sensitivity status           # status with history
/sensitivity normal           # default — no restrictions
/sensitivity sensitive        # PII may be present (safety-relevant if upgrading from normal? no — only downgrades trigger safety)
/sensitivity confidential     # regulated/restricted (local-ops routing required)
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `sensitivity.level` field
- Print:
  - Current level
  - When last changed
  - What's restricted at this level:
    - normal: no restrictions
    - sensitive: subagent_runs logs PII-touched files; bulk-job-reminder fires more aggressively
    - confidential: local-ops subagent required for data-touching tasks; cloud subagents restricted from reading these files
  - Global default value

### 2. Set to normal (downgrade — safety-relevant)

If current level is sensitive or confidential, this is a DOWNGRADE. Full safety flow per /strict-mode off pattern:

Step 2a: Prompt
> Safety check: you're downgrading sensitivity from <current> to NORMAL.
> This will:
> - Stop logging PII-touched files (if was sensitive or higher)
> - Allow cloud subagents to access previously restricted files (if was confidential)
>
> Reason for this change? (one line)

Step 2b: Reason capture + global default offer (same pattern)

Step 2c: Apply, then recompile the permissions boundary per the **P1/P2/P3 prune
contract** below (a downgrade may prune rules the `confidential` overlay added,
e.g. the WebFetch/WebSearch exfiltration denies).

### 3. Set to sensitive or confidential (upgrade — no safety flow)

- Update `.claude/stack-config.json` `sensitivity.level: "<value>"`
- Append to change_history (no reason needed for upgrades)
- If confidential: print "Confidential mode set. Local-ops subagent is now required for data-touching tasks. Cloud subagents (Anthropic/OpenAI/Google) restricted from reading files in: <list paths from sensitivity.notes>."
- Also prompt: "Add any specific paths to mark as confidential? (paths comma-separated, or empty)" — populates `sensitivity.notes`.
- Recompile the permissions boundary per the **P1/P2/P3 prune contract** below
  (confidential adds WebFetch/WebSearch identity denies — genuinely enforced, per
  D1).

## Recompiling — the P1/P2/P3 prune contract (ADR-053)

`/sensitivity` writes `stack-config.json` and recompiles but **asks no consent
question** — it is not a `domain_mode` writer — so it gets its own three-step
sequence, deliberately with **no drift gate and no prompt**. This is the only
`stack-config.json` writer allowed to skip the `/domain-mode`-style flow, because
its prune is a pure deletion (monotone toward the stronger boundary) rather than a
human decision.

- **P0 — preflight, before this section writes anything.** Evaluate the
  mergeability predicate on `.claude/permissions.stack.json`:
  ```
  python3 - ".claude/permissions.stack.json" <<'PY'
  import json, sys
  try:
      with open(sys.argv[1], "r", encoding="utf-8") as fh:
          data = json.load(fh)
  except (OSError, ValueError):
      print("file unreadable or not valid JSON", file=sys.stderr); sys.exit(3)
  if not isinstance(data, dict):
      print("root is not a JSON object", file=sys.stderr); sys.exit(4)
  PY
  ```
  Never `jq`, never `python3 -m json.tool`. Absent is mergeable. On exit 3/4,
  **abort the whole flow**, write nothing, and print:
  ```
  .claude/permissions.stack.json cannot be merged into (<reason>).
  Refusing before any write: stack-config.json is unchanged, the sidecar is
  unchanged, and .claude/settings.json still holds the PREVIOUSLY compiled
  permission boundary — which may be WEAKER than the one you just asked for.
  Fix the file, or delete it. Deleting is PERMANENT: waivers[] and pinned[]
  are gone and every waived rule returns to deny, and the ADR-044 D8
  ownership ledger restarts EMPTY — which strands every rule then in
  settings.json as human-owned, so no future compile can ever prune it.
  Fixing the file costs nothing. Then re-run.
  ```
- **P1 — write.** Write `stack-config.json` as steps 2/3 above describe. The
  prune (P2) must come **after** this write, never before — a prune computed
  against the pre-write config cannot see pairs the write itself made dormant.
  This ordering is the whole mechanism; do not invert it.
- **P2 — report and prune.** Run
  `permissions-compile.sh --scope project --repo-root . --dry-run --json`.
  - Missing / non-zero exit / stdout that does not parse as JSON, **or** a
    parsed document that fails the plan-shape check (root not an object;
    `inputs` not an object; `inputs.acks_prunable` **absent** — a missing key is
    NOT an empty prune; or any element of `inputs.acks_prunable` whose `mode`/
    `tool` is missing, non-string, or empty) → **abort the prune**: delete
    nothing, print `consent check unavailable (<reason>); no acknowledgement
    pruned`, and continue to P3 anyway (the apply still runs).
  - Otherwise, delete exactly the `(mode, tool)` pairs named in
    `inputs.acks_prunable`, regrouped by the provenance rule (drop pairs from
    their entry, remove an entry that empties). `acks_prunable == []` → **no
    sidecar write at all** — an unrelated `/sensitivity` edit must not rewrite a
    file it has nothing to prune from. Never touch `waivers[]`/`pinned[]`, and
    never touch a pair that is in force or promptable.
  - **P2b — the sidecar must still parse.** This catches only the file becoming
    unparseable *between P0 and P2* (a concurrent writer). If the sidecar exists
    and fails the mergeability predicate here: **abort the prune AND abort
    before P3**, printing the mid-flow divergence message:
    ```
    .claude/permissions.stack.json became unreadable mid-flow (<reason>).
    stack-config.json HAS been written; .claude/settings.json has NOT been
    recompiled — the two planes now disagree. Fix or delete the sidecar and
    re-run this command to reconcile them.
    ```
- **P3 — apply.** The real compile. Then assert `inputs.acks_prunable == []` in
  P3's own plan. Mismatch → loud error, no rollback, no second deletion pass.

This replaces the old "skip silently if `permissions-compile.sh` is not found"
clause — under ADR-025 that was a fail-open.

## Validation

- Must be called inside a project directory
- Setting to confidential requires Tier 5 (local-ops) to be installed; warn if not
- Confidential mode + orchestration_mode=agent-teams = warn (Agent Teams is experimental for sensitive work)
