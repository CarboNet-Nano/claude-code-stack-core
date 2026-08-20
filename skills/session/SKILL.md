---
name: session
description: Set your communication and working preferences for this session via a multiple-choice menu. Picks communication style (terse/balanced/thorough), model effort, explanation verbosity, orchestration mode, and cost-alert sensitivity, then writes them to the session-state file that the brevity hook and the assistant read. Optionally saves the choices as your global or project default. Offered (not forced) at the top of /goodmorning and /project-init; run directly anytime with /session.
---

# /session

Set per-session preferences. Session-scoped by default; persistence is opt-in.

## Steps

### 1. Load current + last choices (for menu defaults)

- Live session value: `~/.claude/session-state/current-prefs.json` (if present).
- Last explicit pick: `~/.claude/session-state/last-prefs.json` (if present) —
  use this to **pre-select** the menu (the "remember last" behavior).
- Fall back to built-ins: style `balanced`, effort `balanced`, verbosity
  `normal`, cost-alert `normal`, orchestration from project `stack-config.json`.

### 2. Ask (multiple-choice menu)

Use the `AskUserQuestion` tool. One question per preference; put the current/last
value first (marked "(current)"). Keep it to these:

| Pref | Options |
|---|---|
| **Communication style** | terse · balanced · thorough |
| **Simple talk** (plainness) | off · plain · caveman — off = normal; plain = plain words, no jargon; caveman = terse caveman phrasing. Orthogonal to communication style (length); injected each turn by `simple-talk.sh` (ADR-032). |
| **Model effort** | minimal · fast · balanced · thorough · max |
| **Explanation verbosity** | minimal · normal · teaching |
| **Orchestration mode** | main-thread · hybrid · agent-teams · dynamic-workflows |
| **Cost-alert sensitivity** | relaxed · normal · strict |
| **Governed loops** | off · checkpoint · bounded-checkpoint · bounded-autonomous (clamped to tier ceiling) |
| **Auto-offer loop ask** (ADR-047) | on (default) · off — when on, `loop-shape-nudge.sh` asks (via AskUserQuestion) every session a loop-shaped prompt appears; this is the assistant asking, never auto-starting a loop. off silences the ask entirely. For a numeric ceiling higher than the tier default, use `/loop-level` (L1-L4), separate from this toggle. |
| **Passive capability suggestions** | on (default) · off — controls whether the dispatch nudge appends a pointer to the recommend-capabilities engine; the routing nudge itself always shows |
| **Model-fit receipt** | off · on (default) — at session end, print one retrospective line naming actual cost/model, the session's workload shape (mechanical/mixed/reasoning-heavy), and a cheaper/stronger alternative if the signal is clear. Surfaced by `/carbonight` and, once per session, by `hooks/model-fit-turn.sh` (ADR-033). |
| **Codex review transport** (Tier 2+) | api (default) · cli — `api` reaches the OpenAI/GPT-5.5 adversarial-review family via the OpenAI API; `cli` uses the codex CLI with automatic API fallback (ADR-030). Only offer this row at Tier ≥ 2. |

Style → brevity budget (what the user is really choosing): terse ≈ 70 words /
4 sentences, balanced ≈ 120 / 6, thorough ≈ 320 / 16. Mention this inline.

### 3. Write the session value

Write the merged object to **both**:
- `~/.claude/session-state/current-prefs.json` (active for this session)
- `~/.claude/session-state/last-prefs.json` (so next session can pre-select)

Shape (stamp `source:"session"` and an ISO `set_at`):
```json
{
  "communication_style": "...",
  "model_effort": "...",
  "explanation_verbosity": "...",
  "orchestration_mode": "...",
  "cost_alert_sensitivity": "...",
  "passive_suggest": true,
  "simple_talk": "off",
  "model_fit_receipt": "on",
  "auto_offer_loop": true,
  "source": "session",
  "set_at": "<iso8601>"
}
```
Write `passive_suggest` as a JSON boolean from the menu choice: **on → `true`,
off → `false`** (unquoted — the hook compares the literal `false`; a quoted
`"off"`/`"on"` string would silently leave nudging enabled).
`mkdir -p ~/.claude/session-state` first. This takes effect immediately:
`brevity-drift.sh` reads `communication_style` on the next turn, and you (the
assistant) honor effort/verbosity/orchestration directly for the session.

**Codex review transport (ADR-030).** If the user changed it from the default,
also `export REVIEW_CODEX_TRANSPORT=<api|cli>` — that env var is the session-layer
override the review helper (`scripts/lib/openai-review.sh`, `oair_transport`)
reads first. Because a Bash-tool `export` does not persist across dispatched
subagent shells, for a **durable** per-project choice tell the user to run
`/project-init` (writes `review.codex_transport` to `.claude/stack-config.json`,
which the helper reads next). Do NOT write `codex_transport` into
`current-prefs.json` — the helper does not read that file.

**Governed loops (ADR-023):** the loop choice sets `loop_policy.default_autonomy`
(via `/stack-config`; `off` ⇒ checkpoint floor). **Auto-offer loop ask
(ADR-047)** is a separate boolean (`auto_offer_loop`, default `true`) — it does
not gate whether loops can run, only whether `loop-shape-nudge.sh` keeps
asking each session. Write it as a JSON boolean, same rule as
`passive_suggest`. This replaces the old one-time `loop-onboarded.json`
marker: the ask now recurs every session by design, and `auto_offer_loop` is
the only durable off-switch.

### 4. Offer to persist (opt-in)

Ask once via `AskUserQuestion`: "Save these as a default?"
- **No, this session only** (default) — done.
- **Global default** — write the fields to `~/.claude/stack-defaults.json`
  under `session_prefs_defaults` (reuse `/default-edit global` conventions;
  append a `change_history` entry, `invoked_via: "/session"`).
- **Project default** — write to the nearest `.claude/stack-config.json` under
  `session_prefs` (append a `change_history` entry). Skip if no stack-config
  exists; suggest `/project-init` instead.

### 5. Confirm

Print a 2-line confirmation of the active prefs and where they were saved
(session only / global / project). Do not start other work.

### 6. Offer the automation recommender (once per repo)

After confirming prefs, offer a one-time repo scan — but only when it's useful:

- Gate: skip silently if `.claude/.automation-offered` exists, OR if no project
  signal (`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` /
  `pom.xml` at root).
- Otherwise ask **once** via `AskUserQuestion`:
  > "Scan this repo and recommend Claude Code automations (hooks, subagents, MCP servers)?"
  - If yes: run the `claude-automation-recommender` skill (read-only).
  - If no: continue.
- Either way, `mkdir -p .claude && touch .claude/.automation-offered` so it
  isn't re-offered here or in `/goodmorning`. Skip the touch if `.claude/`
  can't be written.

## Notes

- Precedence at session start (handled by `hooks/session-prefs-init.sh`):
  built-in < global `session_prefs_defaults` < project `session_prefs`. `/session`
  overrides all of them for the live session.
- Per-session choices are ephemeral: a new session resets to the configured
  defaults unless you saved them in step 4.
- **For everything beyond session prefs, use `/stack-config`** — the Setup
  Dashboard. `/session` only covers the per-session communication/effort/verbosity
  prefs; `/stack-config show-current` shows the whole setup (tier, modes, caps,
  native model/output-style/plugins), scope-resolved, and safely changes the
  common ones. Mention this once at the end of the `/session` flow so users
  discover the dashboard. (Tier ≥2; absent below tier 2.)
