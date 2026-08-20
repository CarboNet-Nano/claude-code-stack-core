---
name: sensitivity
description: Shortcut to set the project's data sensitivity level. Three levels — normal (default), sensitive (PII present — extra logging), confidential (regulated data — local-ops routing required, cloud subagents restricted). /sensitivity <level> sets it. Downgrading is safety-relevant. /sensitivity (no arg) shows current and what it restricts.
---

# /sensitivity

Set the project's data sensitivity level.

**Sandbox network allowlist compiles from a hook, not from here (ADR-071
D9).** This skill writes `.claude/stack-config.json` via the Edit tool.
`hooks/sandbox-policy-recompile.sh` (`PostToolUse[Edit|Write]`) then
recompiles `sandbox.network.allowedDomains` automatically when it sees the
level actually changed — this skill never invokes
`scripts/sandbox-policy-compile.sh` itself, because a Bash-tool call cannot
write `.claude/settings.json` once the managed floor (ADR-071 D11) is
installed. Do not add a write-time compile step here; the P1/P2/P3 contract
below governs only `permissions.deny`/`ask` (ADR-044), a separate mechanism.

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
    - sensitive: subagent_runs logs PII-touched files; bulk-job-reminder fires more aggressively; sandbox network allowlist narrows to Anthropic + cleared vendors (ADR-071)
    - confidential: local-ops subagent required for data-touching tasks; cloud subagents restricted from reading these files; sandbox network allowlist narrows to Anthropic-direct only (ADR-071 D4)
  - Global default value
  - **At any level above `normal`**, print the ADR-070 D5a line verbatim:
    "this routes your data to fewer vendors; it does not remove anything from
    what is sent."
  - **At `confidential`**, also print the ADR-071 D4 line: "this level is not
    air-gapped — Anthropic's own endpoint stays reachable because the session
    runs on it."
  - Read `.claude/permissions.stack.json` `sandbox_policy.stashed_entries[]`
    (if the sidecar exists). For each entry not yet restored, print one line:
    `stashed: <value> (<scope>, was <owner>-owned, <stashed_on>) — reason: <reason>`.
    If any exist, print the one-line restore path: "restoring a stashed host
    is a human act — hand-edit .claude/settings.local.json (or
    .claude/settings.json) to add it back, then re-run this command; nothing
    here does it automatically (ADR-071 D14)." Never auto-restore, never offer
    an automated restore action.
  - Print the current sandbox-policy compile verdict, if a receipt exists at
    `~/.claude/session-state/sandbox-policy/<hash>.json` for this repo
    (`sha256(realpath(repo))[0:16]`): the `verdict` field, and — if
    `FLOOR_ABSENT` or `WALL_ABSENT` — a pointer to
    `docs/runbooks/managed-floor-install.md`.

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
e.g. the WebFetch/WebSearch exfiltration denies). The Edit tool write to
`stack-config.json` also fires `hooks/sandbox-policy-recompile.sh`
automatically (ADR-071 D9) — this may *widen* the sandbox vendor host
allowlist back toward `normal`, but it **never** re-adds a host from
`sandbox_policy.stashed_entries[]`; restoring a stash stays a human act
(D14). Print any newly-widened hosts from the hook's own output.

### 3. Set to sensitive or confidential (upgrade — no safety flow)

- Update `.claude/stack-config.json` `sensitivity.level: "<value>"`
- Append to change_history (no reason needed for upgrades)
- Print the ADR-070 D5a line: "this routes your data to fewer vendors; it
  does not remove anything from what is sent."
- If confidential: print "Confidential mode set. Local-ops subagent is now required for data-touching tasks. Cloud subagents (Anthropic/OpenAI/Google) restricted from reading files in: <list paths from sensitivity.notes>. This level is not air-gapped — Anthropic's own endpoint stays reachable because the session runs on it (ADR-071 D4)."
- Also prompt: "Add any specific paths to mark as confidential? (paths comma-separated, or empty)" — populates `sensitivity.notes`.
- Recompile the permissions boundary per the **P1/P2/P3 prune contract** below
  (confidential adds WebFetch/WebSearch identity denies — genuinely enforced, per
  D1). The Edit tool write also fires `hooks/sandbox-policy-recompile.sh`
  automatically (ADR-071 D9) — do not call `scripts/sandbox-policy-compile.sh`
  from this skill; it refuses outside a hook context by design. Print any new
  `sandbox_policy.stashed_entries[]` the hook reports, and the restore
  reminder from step 1.

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
