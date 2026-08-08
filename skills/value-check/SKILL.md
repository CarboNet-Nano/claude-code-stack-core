---
name: value-check
description: Score a target repo's ratified business-value claims against reality (proposal docs/proposals/2026-07-30-business-value-real-build-v2.md). Runs scripts/value-check-gate.sh's deterministic scorer against a probe's stdout, never an LLM, and renders docs/value/ROLLUP.md. Phase 1 only — one claim, one probe, one reviewed verdict. Use when asked to check, score, or report on a repo's value claims, or to ratify/dispose/revise one.
---

# /value-check

Targets a **project repo**, never the stack repo (D18). All writes land under
`<repo>/docs/value/` — the gate script is the only writer of
`docs/value/.meta/**` (the `./docs/value/.meta/**` path rule blocks the Edit
and Write tools there; a gate script invoked through Bash is unaffected —
that is the design, D8/D9 Layer 3, not a bypass of it).

No LLM decides PASS/MISS. The deterministic scorer is
`tools/value-check/src/score.mjs`; `scripts/value-check-gate.sh` is the only
command surface this skill calls.

Usage:
```
/value-check                       # target = cwd (must be the project repo)
/value-check --repo <abs-path>
/value-check --report
/value-check --exec
/value-check ratify --claim <id>
/value-check dispose <id> --fix <issue-url> [--note <text>]
/value-check dispose <id> --retire --reason <text>
/value-check revise <id>
```

## Step 0 — Resolve the target repo (STOP on ambiguity — D18, two forms, no third)

- No `--repo` flag: target = `cwd`. Confirm `git rev-parse --show-toplevel`
  resolves and is **not** the stack repo itself. If it IS the stack repo,
  STOP: "`/value-check` targets a project repo, never the stack repo — pass
  `--repo <path>` or run this from inside the project."
- `--repo <path>`: use it as given; do not resolve relative to cwd.
- Refuse (do not silently skip) if `<repo>/docs/value/` does not exist —
  print: "No `docs/value/` in this repo. Phase 1 entry gates (proposal §7)
  are not met — nothing to score."

## Step 1 — Dispatch to the gate script

This skill is a thin dispatcher. Every verb below shells out to
`scripts/value-check-gate.sh` (relative to the installed stack root) and
relays its stdout/stderr verbatim — no paraphrasing of a verdict string, no
"looks healthy" softening (§4's consumer rule: only `PASS` is passing).

| Invocation | Gate call |
|---|---|
| `/value-check` (no args) | `value-check-gate.sh score --repo <repo>` |
| `/value-check --report` | `value-check-gate.sh report --repo <repo>` |
| `/value-check --report --json` | `value-check-gate.sh report --repo <repo> --json` |
| `/value-check --exec` | `value-check-gate.sh exec --repo <repo>` (also renders `ROLLUP.md`) |
| `/value-check ratify --claim <id>` | `value-check-gate.sh ratify --repo <repo> --claim <id>` |
| `/value-check dispose <id> --fix <url> [--note <t>]` | `value-check-gate.sh dispose <id> --repo <repo> --fix <url> [--note <t>]` |
| `/value-check dispose <id> --retire --reason <t>` | `value-check-gate.sh dispose <id> --repo <repo> --retire --reason <t>` |
| `/value-check revise <id>` | `value-check-gate.sh revise <id> --repo <repo>` |
| `/value-check render` | `value-check-gate.sh render --repo <repo>` |
| `/value-check bounds` | `value-check-gate.sh bounds` |

`ratify` makes exactly one model call to each of the two independent
reviewers (D11, amended §10.1: OpenAI **and** Gemini, both must `ACCEPT`).
Every other verb is deterministic and free.

## Step 2 — D18 credential is resolved by the gate, not this skill

If `score` reports "No probe DB URL" for a claim, the gate already printed
the exact provisioning command
(`security add-generic-password -s '<item>' -a "$USER" -w '<url>' -U`).
Relay it verbatim. **Do not** attempt to resolve or guess the URL yourself,
and never echo a resolved URL back to the user — the gate never prints it
either (D18: not even redacted-with-host).

## Step 3 — Relay the verdict honestly (§1.1, §4's consumer rule)

Never render `INSUFFICIENT-DATA`, `STALE-SOURCE`, `NOT-YET-DUE`,
`PROBE-CHANGED`, `CLAIM-CHANGED`, `CLAIM-ANCHOR-UNAVAILABLE`,
`PROBE-OUTPUT-REJECTED`, or `NOT-SCORABLE` as "on track," "green," or
"tracking well." Only `PASS` is passing. `NOT-ESTABLISHED` on the coverage
line is Phase 1's honest state (no ratified inventory yet, D3) — not a bug,
do not apologize for it or suppress it.

## What this skill does NOT do (Phase 1 scope — proposal §7)

No `/value-claim` (drafting claims is a human/Phase-2 action — claims are
hand-authored JSON at `docs/value/claims/<claimId>.json`, Contract A). No
`product-critic` value clause. No cadence/cron wiring, no hooks. No ratified
feature inventory (coverage stays `NOT-ESTABLISHED`). No `--trend`. If asked
for any of these, say they are out of Phase 1 scope per the design doc and
stop.
