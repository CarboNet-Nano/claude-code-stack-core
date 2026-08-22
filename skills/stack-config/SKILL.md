---
name: stack-config
description: Setup Dashboard — one read-first front door for your whole Claude Code setup (stack settings + native settings.json). Four operations — show current setup, get AI-ranked recommendations, change one setting, or guided setup by goal. Invoked as /stack-config or via natural language ("show my settings", "what should I configure", "set up this repo for X"). Read-first; the only writable native settings are a small curated allowlist routed through native-settings-edit. Never writes settings.json, stack-config.json, hooks, env, or permissions directly.
user-invocable: true
model-invocable: true
recommendable: false
tier_min: 2
tools: Read, Bash
---

# /stack-config — Setup Dashboard

One front door to understand and (safely) adjust your Claude Code setup. It spans
**two settings universes**:

- **Stack settings** — `stack-config.json` + session prefs (tier, modes, caps).
- **Native settings** — Claude Code's own `settings.json` (model, output style,
  status line, plugin/MCP toggles, and the security boundary: hooks/env/permissions).

The dashboard is **read-first**. Writes are a small, hard-enforced safe surface;
everything risky is read-only or diff-only. `/config` (no `stack-`) is Claude
Code's built-in — this skill does not shadow it.

## Security spine

### Three row states (every known setting is exactly one)
- **`[edit]`** — in the curated write-allowlist below. Changed through an owning
  skill (stack) or `native-settings-edit` (native). Never written here directly.
- **`[review]`** — read/summarize/redact, **never written**: env names,
  permissions summary, hooks inventory, MCP `command`/`args`/`env`, secrets.
- **`[native]`** — open Claude Code's own command: `/model`, `/permissions`,
  `/agents`, `/hooks`, `/config`. The dashboard prints the command; it does not run it.

### Write-allowlist (deny-by-default)

**Stack (mechanism = owning skill; file = `stack-config.json` / prefs):**

| Setting | Owning skill |
|---|---|
| `stack_tier` | `tier` |
| `orchestration_mode` | `agent-teams` |
| `strict_mode` | `strict-mode` |
| `domain_mode` (scalar or array, ADR-053) | `domain-mode` |
| `domain_mode_paths` (ADR-053) | `domain-mode` |
| `sensitivity.level` | `sensitivity` |
| `session_prefs.{communication_style,model_effort,explanation_verbosity,orchestration_mode,cost_alert_sensitivity,passive_suggest}` | `session` |
| `cost_protection.per_session_alert_usd` / `per_day_alert_usd` | `cost-cap` |

**Native (mechanism = `native-settings-edit`; default scope = project):**

| Pointer | Constraint |
|---|---|
| `/model` | shipped model preset (string) |
| `/outputStyle` | installed style; else diff-only |
| `/statusLine` | audited preset **name** (`static`/`minimal`); object refused |
| `/enabledPlugins/<key>` | boolean; existing key only |
| `/mcpServers/<name>/disabled` | boolean; existing server only |
| `/sandbox/network/strictAllowlist` | boolean; **user scope only** (ADR-063 D5/phase 3). Offer it only after the sandbox has baked in with no unexpected domain prompts; the write runs `--scope user --confirm-global` after an explicit user confirm. Turning it on converts prompt-on-new-domain into deny-on-new-domain — warn that a missing host then fails loudly instead of prompting. |

### Denylist / review-only (NEVER written, NEVER recommended, NEVER in a recipe)
- **Stack:** `required_approvals`, `cost_protection.per_session_hard_cap_usd`,
  `providers`, any secret/key/token/password/keychain/supabase_ref field.
- **Native:** `hooks`, `env` values, `permissions`, MCP `command`/`args`/`env`.
  `permissions` is still never written by the dashboard itself (ADR-018
  Contract C, amended by ADR-044 D7): its two legitimate writers are the
  deterministic `scripts/permissions-compile.sh` (invoked by `/project-init`,
  `/domain-mode`, `/sensitivity` — never by an LLM-authored rule string) and
  the native `/permissions` command for ad-hoc human edits. The dashboard
  shows the row and points at both; it constructs neither.

### Write routing (deterministic)
1. **Stack `[edit]`** → invoke the owning stack-skill (runs its own confirm/reason).
2. **Native `[edit]`** → `native-settings-edit` (the ONLY `settings.json` writer);
   always `--dry-run` first, show the diff, get the user's confirm, then apply.
3. **Direct dashboard writes** → none. The dashboard reads and orchestrates only.

### Enforcement (the dashboard self-enforces — it does NOT assume callees do)
- Before routing ANY automated change (op2/op4), check the target against the
  denylist AND reject any change whose owning skill is `default-edit`. On a match,
  refuse: "that setting can't be changed through /stack-config."
- For native `[edit]`, the dashboard decomposes the change into a plain-language
  confirmation ("This will DISABLE plugin X. Confirm?"). The model proposes; the
  user confirms; `native-settings-edit` validates. The dashboard never builds or
  passes a value object — only a scalar/preset-name; the script refuses the rest.
- Cloud: `show-current` only; all write paths are disabled (and `native-settings-edit`
  re-enforces this itself).

## Entry — no arg

Present one `AskUserQuestion`:

> What do you want to do with your setup?
>
> a) Show current setup — stack + native, scope-resolved, with row tags (no changes)
> b) Recommended changes — AI-ranked stack suggestions for your context/goal
> c) Change one setting — pick from a menu and route to its owner
> d) Guided setup by goal — describe your goal, get a matched stack change set

Natural-language entry: infer the op (goal-like → op4; "show me…" → op1); ask the
menu when ambiguous.

## Op 1 — show-current

**No mutation. No questions beyond entry.** Reads across scopes, redacts, tags rows.

### Step 1 — Load
- Stack: `.claude/stack-config.json` (project; if absent note "run /project-init")
  and `~/.claude/session-state/current-prefs.json` (live prefs).
- Native (Contract B scope order, lowest→highest precedence):
  `~/.claude/settings.json` (user) < `<project>/.claude/settings.json` (project)
  < `<project>/.claude/settings.local.json` (local). A missing/unparseable scope
  file is skipped with a note — never fail the whole view. Use `Bash` + `python3`/`jq`
  to read; do not echo raw file contents.

### Step 2 — Print stack settings
For each, show: current value | default | source. Groups exactly as before:

```
Tier:              <stack_tier>   (default: 2)   [source]   [edit /tier]
Orchestration:     <orchestration_mode>   (default: main-thread)   [source]   [edit /agent-teams]
Strict mode:       <strict_mode>   (default: true)   [source]   [edit /strict-mode]
Domain mode:       <comma-joined list or "none">   (default: none)   [source]   [edit /domain-mode]
Domain mode paths: <mode: globs, ... or "unmapped (always active)">   [edit /domain-mode]
Sensitivity:       <sensitivity.level>   (default: normal)   [source]   [edit /sensitivity]
Cost alert/session: $<per_session_alert_usd or "none">   [edit /cost-cap]
Cost alert/day:    $<per_day_alert_usd or "none">   [edit /cost-cap]
Hard cap/session:  <"set"|"not set">   [review — change via /cost-cap directly]
```
```
Communication:     <communication_style>   (default: balanced)   [edit /session]
Model effort:      <model_effort>   (default: balanced)   [edit /session]
Verbosity:         <explanation_verbosity>   (default: normal)   [edit /session]
Cost alerts:       <cost_alert_sensitivity>   (default: normal)   [edit /session]
Passive suggest:   <passive_suggest>   (default: true)   [edit /session]
```

### Step 3 — Print native settings (scope-resolved, redacted, tagged)
```
Model:             <effective>   (source: user|project|local)   [edit → /model preset]
Output style:      <effective>   (source)   [edit]
Status line:       <preset name if matched, else "custom">   [edit preset only]
Plugins:           <N enabled> / <M total>   [edit toggle]
MCP servers:       <N enabled> / <M total>   [edit disable-toggle]
Hooks:             <count by event> (matchers + paths, commands truncated)   [review → /hooks]
Permissions:       <N deny / M ask> — A identity / B path / C bash-guardrail (ADR-044; bash-guardrail is NEVER enforcement) — <shallow conflict flag if any>   [edit → permissions compiler; review → /permissions]
Env:               <NAME, NAME, …>  values [redacted]   [review]
```

**Multi-mode consent (ADR-053) — [review], sourced from
`permissions-compile.sh --dry-run --json`'s `inputs`, never recomputed here:**
```
Suppressions honored:   <tool (by: modes), ...  or "none">
Suppressions withheld:  <tool (clause; fix), ...  or "none">
Prunable acks:          <mode/tool (why), ...  or "none — healthy">
Domain paths ignored:   <mode, ...  or "none">
Consent scope hash:     <inputs.consent_scope_hash>
```
Plus open-native rows: `Subagents → /agents`, `Built-in config → /config`.

### Step 4 — Redaction (Contract C — mandatory)
NEVER print: `providers`; any secret/key/token/password/keychain/supabase_ref
field; `sensitivity.notes`; `model_overrides`/`skill_overrides`; **any native `env`
value** (names only); raw hook command strings (truncate); raw MCP `command`/`args`/`env`.
If a redacted block is present, print one line: `[providers / secrets / env values: redacted]`.

### Step 5 — Done
Print: "Run /stack-config again to change a setting." Offer nothing else.

## Op 2 — recommended-changes (stack settings)

Automated recommendations cover **stack** settings only (native `[edit]` changes
are made via op3 or the native command, to keep the automated path off the
native surface). Unchanged from the shipped router:

1. Ask one optional `AskUserQuestion` for `goal` (Enter/"skip" → context only).
2. Call `recommend-capabilities` with `mode: "settings"`, `thread_context`,
   `last_user_ask`, `goal`, and the current `session_settings` block; `max_results: 5`.
3. If empty, print the engine's `note` and return. Else present the ranked
   candidates via `AskUserQuestion` (`<setting>: <current> → <proposed> — <reason>
   [confidence]`, plus a skip).
4. **Guard first:** if the chosen change's `setting` is denylisted, or its
   `owning_skill` is `default-edit`, REFUSE ("that setting can't be changed
   through /stack-config") and return to the list. On a valid pick, invoke the
   **owning skill** (the user's selection is the consent gate). Re-offer until skip.

## Op 3 — change-one-setting

### Step 1 — Pick
Present one `AskUserQuestion` (allowlisted only; denylist/review never appear):

> Which setting do you want to change?
>
> Stack:
> a) Stack tier (/tier)   b) Orchestration (/agent-teams)   c) Strict mode (/strict-mode)
> d) Domain mode (/domain-mode)   e) Sensitivity (/sensitivity)   f) Session prefs (/session)
> g) Cost caps & alerts (/cost-cap)
> Native:
> h) Model   i) Output style   j) Status line preset   k) Enable/disable a plugin
> l) Enable/disable an MCP server

### Step 2 — Route
- **Stack (a–g):** hand off to the chosen skill verbatim — its full surface, its
  own confirm/reason flow (op3 is explicit user intent, equivalent to invoking it
  directly). Do not add or filter prompts.
- **Native (h–l):** resolve the single pointer + scalar/preset:
  - h `/model` (preset list) · i `/outputStyle` · j `/statusLine` (preset name)
    · k `/enabledPlugins/<key>` (existing key) · l `/mcpServers/<name>/disabled`.
  - Confirm scope (default **project**; `~/.claude` user scope needs an explicit
    "apply globally?" confirm → pass `--scope user --confirm-global`).
  - Run `native-settings-edit … --dry-run`, show the diff, get the user's confirm,
    then run without `--dry-run`. Relay the script's exit line. On a refusal
    (rc 2) relay the reason — do not retry to "get around" it.

### Step 3 — Done
Print: "Done. Run /stack-config again to change another setting or view current setup."

## Op 4 — guided-setup-by-goal (stack recipes)

Unchanged hardcoded recipe table (the LLM must not author alternative recipes;
recipes reference only Contract-A stack paths — a non-allowlisted target becomes
a diff-only step, never an automated write):

> What are you setting this repo up for?
> a) Ship fast / low ceremony   b) High-assurance security/finance
> c) Sensitive/regulated data   d) Cost-controlled experimentation

**a — ship fast:** `strict_mode→false` (/strict-mode off) · `orchestration_mode→main-thread` (/agent-teams off) · `session_prefs.passive_suggest→false` (/session)
**b — security/finance:** `domain_mode→financial-code` (/domain-mode financial-code) · `strict_mode→true` (/strict-mode on) · `session_prefs.model_effort→max` (/session)
**c — sensitive data:** `sensitivity.level→sensitive` (/sensitivity sensitive) · `strict_mode→true` (/strict-mode on) · `session_prefs.passive_suggest→false` (/session)
**d — cost-controlled:** `cost_protection.per_session_alert_usd→2.00` (/cost-cap session 2.00) · `cost_protection.per_day_alert_usd→10.00` (/cost-cap day 10.00) · `session_prefs.model_effort→fast` (/session)

**Verify no recipe change touches the denylist.** If a future edit adds one, refuse
and escalate. Read current values, skip already-correct entries, present the
remaining set via `AskUserQuestion` (apply all / pick individually / skip), then
route each confirmed change to its owning skill in sequence. Print a summary.

## What /stack-config NEVER does

- Write `settings.json`, `stack-config.json`, or `stack-defaults.json` directly
  (stack → owning skill; native → `native-settings-edit`).
- Touch native `hooks`, `env`, `permissions`, or MCP `command`/`args`/`env`.
- Construct or pass a native value object — only a scalar / preset name.
- Print any `providers`/secret value, or any native `env` value.
- Propose or apply denylisted settings, or route automated changes via `default-edit`.
- Write anything in a cloud session.
- Author free-form config mutations outside the op4 recipe table.
