---
name: domain-mode
description: Shortcut to set the project's domain mode(s). Domain modes enable extra safety rules (financial-code forces validator+red-team+security-auditor; schema-migration forces dry-run; deploy forces ops pre+post). ADR-053 -- accepts one or more modes at once (e.g. /domain-mode ui-design schema-migration), each independently scoped to touched paths via domain_mode_paths. /domain-mode none clears it (safety-relevant). /domain-mode (no arg) shows current. Domain modes are enforced by foreman skill on every dispatch.
---

# /domain-mode

Set the project's domain mode(s). Domain modes activate extra safety rules in foreman,
scoped to the files a change actually touches (ADR-053).

## Usage

```
/domain-mode                                    # status
/domain-mode status                             # status with history
/domain-mode financial-code                      # set (single mode)
/domain-mode ui-design schema-migration          # set (multiple modes at once)
/domain-mode none                                # clear (safety-relevant)
```

## Steps

### 1. No arg / status

Read `.claude/stack-config.json` `domain_mode` (may be `null`, a bare string, or an
array) and `domain_mode_paths`. Print, for every declared mode:

- The mode name, whether it is mapped in `domain_mode_paths` (and its globs) or
  UNMAPPED (always active), and what it enforces (from `config/domain-modes.json`).
- When last changed.
- Global default value (`default_domain_mode` in `stack-defaults.json`).

Render the mode list as a single comma-joined line (`ui-design, schema-migration`),
never pretty-printed JSON.

### 2. Set to one or more of: financial-code | schema-migration | deploy | ui-design | data-operation

Step 2a: Verify every named mode exists in `~/.claude/config/domain-modes.json`. If any
does not, refuse with "Unknown domain mode: <name>. Available: <list>." — refuse the
whole command, do not partially apply.

Step 2b: If any newly-declared mode is `financial-code` or `schema-migration` and was
not previously declared (escalation into a stricter mode): treat as safety-relevant
(full safety flow per `/strict-mode off` pattern).

Step 2c: If any newly-declared mode is `financial-code` or `schema-migration`: also
check `orchestration_mode`. If set to `agent-teams`, soft-warn:
> Note: orchestration_mode is currently agent-teams (experimental). Agent Teams is not recommended for <mode> work without deliberate acceptance.
> Continue? [y/N]

Step 2d: Apply (ADR-053 D6-revised — the three-invocation flow, replacing the old
single dry-run). This is the **only** consent mechanism; the compiler
(`scripts/permissions-compile.sh`) is the enforcement point and this skill never
re-derives its honor test.

1. **P0 — preflight, before anything is written.** Evaluate the mergeability
   predicate on `.claude/permissions.stack.json` (absent is mergeable; present must
   parse as JSON **and** have an object root):
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
   Use exactly this heredoc — never `jq`, never `python3 -m json.tool` (it exits 0
   on `[]`/`42`/`null`, which is the exact gap this predicate closes). If the file
   is absent, P0 passes trivially (absent is not `null` — never treat a missing
   file as a failure). On exit 3 or 4, **abort the entire flow**, write **nothing**
   (not the config, not the sidecar), and print:
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
   with `<reason>` = `file unreadable or not valid JSON` (exit 3) or
   `root is not a JSON object` (exit 4).

2. **Write `stack-config.json`.** Canonical form (D10): 0 modes → `domain_mode: null`;
   1 mode → a bare string; ≥2 modes → an array. Prune any `domain_mode_paths` orphan
   key (a known mode no longer declared) — but **never** prune a key whose *value*
   is malformed; that key stays, per the compiler's own rule (deleting it would
   widen the grant). Append to `change_history`.

3. **Run 1 — the report.**
   `permissions-compile.sh --scope project --repo-root . --dry-run --json`, parsing
   **stdout only** (warnings are on stderr). Missing / non-zero exit / stdout that
   does not parse as JSON → **abort the consent flow**: write no ack, delete no ack,
   print `consent check unavailable (<reason>); no acknowledgement written — the
   permission boundary keeps its static denies`. The config write from step 2
   already landed (see the named residual below) — this abort only stops the ack
   ritual, never rolls the config back.

4. **Prompt set** = every entry in `inputs.suppressions_withheld` whose `clause` is
   `consent` or `consent-stale`. Empty → no prompt, no ack written, no ritual —
   continue straight to run 2 with an empty y/N batch. Otherwise, for each entry:
   name the tool, its clause, and the fix; echo that entry's `deny_rules` **verbatim**
   as the exact rule strings that disappear on `y` (an empty list — missing
   live-capabilities snapshot — is echoed as "no MCP rule is currently emitted for
   this tool"); print the exact `multi_mode_suppression_ack` JSON block including
   the current `scope_hash` from `inputs.consent_scope_hash`; ask y/N. This
   **one batch of y/N answers is the single human decision point** in the whole
   flow. Never compose a rule string yourself.

5. **Run 2 — the drift gate.** Immediately after the last y/N, with **nothing yet
   written**, run the identical `--dry-run --json` invocation again. Abort
   (write nothing, delete nothing) if `run2.inputs != run1.inputs` (deep equality)
   or `run2.baseline_version != run1.baseline_version` or
   `run2.inputs.baseline_hash != run1.inputs.baseline_hash`. Name the **first**
   field that differs, in this order: `consent_scope_hash`, `mcp_servers`,
   `baseline_version`/`baseline_hash`, `acks_in_force`/`acks_prunable`,
   `suppressions_withheld`/`suppressions_honored`, any other field. Print:
   `configuration changed while the consent prompt was open (<field>); no
   acknowledgement written or deleted — re-run /domain-mode with the same
   arguments`. Missing / non-zero / unparseable run 2 → the same "consent check
   unavailable" abort as run 1.

6. **R2b — the reconcile's own read.** This is not a new step: it is the read half
   of the one durable sidecar write below. Evaluate the same mergeability predicate
   on `.claude/permissions.stack.json` again (mandatory whenever the file exists,
   even if the resulting write would be byte-identical). On failure, **abort before
   run 3**, write no sidecar, and print the mid-flow divergence message (not the
   P0 message — `stack-config.json` is already written, so this is a divergence,
   not a preflight refusal):
   ```
   .claude/permissions.stack.json became unreadable mid-flow (<reason>).
   stack-config.json HAS been written; .claude/settings.json has NOT been
   recompiled — the two planes now disagree. Fix or delete the sidecar and
   re-run this command to reconcile them.
   ```

7. **Reconcile — the one durable sidecar write.** `multi_mode_suppression_ack[]`
   becomes exactly the union of **(A)** every `(mode, tool)` pair answered **y** at
   this invocation, written with the current `scope_hash`, plus **(B)** every pair
   in run 1's `inputs.acks_in_force`, carried forward **byte-identical**
   (`reason`/`date`/`by` untouched). Everything else — including every pair in
   `inputs.acks_prunable`, fresh or stale — is deleted. Group survivors by the
   provenance tuple `(mode, date, by, reason)`; on a duplicate `(mode, tool)` claim
   across source entries, the lexicographically smallest `(date, by, reason)` wins.
   Never touch `waivers[]` or `pinned[]`. Never delete an ack inside an error
   handler.

8. **Run 3 — the apply.** The real compile (no `--dry-run`). Failure here is loud
   and never deletes an ack (the y/N was the final decision; the record stands).

9. **Verify**, against run 3's own plan JSON only (never an independent
   re-derivation of the honor test):
   - `inputs.acks_in_force == A ∪ B` (from step 7).
   - `inputs.acks_prunable == []`.
   - `inputs.consent_scope_hash`, `inputs.mcp_servers`, `baseline_version`,
     `inputs.baseline_hash` all equal run 2's (this is what catches a drift landing
     in the run-2-to-run-3 interval — a named, open residual, not a bug).
   - `⋃ withheld[*].deny_rules ⊆ compiled_deny` and
     `⋃ honored[*].deny_rules_removed ∩ compiled_deny == ∅`.

   Any mismatch → a loud error naming the assertion and the difference, pointing at
   `/domain-mode status`. Never roll back, never delete an ack in the handler.

10. Print "Domain mode(s) set to <list>. Foreman will now enforce: <rules>."

**Named residual — a drift-gate abort at step 5 leaves the step-2 config write in
place.** Fail-safe (the older, stronger `settings.json` stays in force until any
compile — CI, another session — recompiles it), but user-visible: re-running
`/domain-mode` with the same arguments is idempotent and converges.

### 3. none (clear all modes — safety-relevant if previously set)

Full safety flow per `/strict-mode off` pattern (reason capture + global default
offer), then run the **identical** step 2d sequence above (P0 → write `domain_mode:
null` → run 1 → prompt set is almost always empty at arity 0 → run 2 → R2b →
reconcile (keep-set is empty: every ack entry for a now-undeclared mode is deleted)
→ run 3 → verify). This is the case ADR-053's P0 preflight exists for: a `none`
whose *whole intent* is to strengthen the boundary back to full denies must never
half-land with the config cleared and the permission plane still weaker because an
unrelated sidecar typo made the apply refuse. Print "Domain mode cleared. Foreman
will use default routing without domain-specific safety rules."

### `/domain-mode status`

Never writes. Shows the same view as no-arg plus a brief history of recent changes.

## Validation

- Must be called inside a project directory.
- Every named mode value must exist in `domain-modes.json`; the whole command is
  refused (nothing written) if any one is unknown.
- Escalating into `financial-code` or `schema-migration` triggers the safety flow.
- The consent ritual (step 2d.4) is driven entirely by
  `permissions-compile.sh --dry-run --json`'s `inputs.suppressions_withheld` — this
  skill never computes `consent_scope_hash`, never re-derives the honor test, and
  never falls back to "skip silently" if the compiler is missing (that would be a
  fail-open; see ADR-025).
