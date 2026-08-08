# Claude Code Stack

A tiered, opinionated configuration of Anthropic's Claude Code, designed for technical users who want a multi-agent development team rather than a single AI assistant.

**Status:** Proprietary Lade IP (ADR-034/036). Being taken private; distributed to licensees under written agreement only. No support commitments.

## What this is

21 specialized subagents covering the full software development lifecycle, multi-provider model routing (Anthropic, OpenAI, Google, optional local Ollama), self-improving via monthly audits, and 5 installation tiers from "stop repeating mistakes" to "set it and forget it" enterprise.

## Quick start

```bash
git clone git@github.com:bschonbrun/claude-code-stack.git
cd claude-code-stack
./scripts/install.sh --tier=0   # foundation only
# or
./scripts/install.sh --tier=5 --include-ollama=laptop   # everything
```

## Tiers

| Tier | Name | Time | Adds |
|---|---|---|---|
| 0 | Foundation | 5 min | Friction-killer hooks + handoff skills |
| 1 | Discipline | 30 min | Plan/cost-gate/validate-output skills |
| 2 | Team | 2-3 hr | 12 subagents + foreman + cost log |
| 3 | Specialist Bench | 1-2 hr | 9 more subagents + multi-provider |
| 4 | Self-Improving | 1 hr | Monthly audits + perf reviews |
| 5 | Local + Offline | varies | Ollama integration |

Each tier is fully functional standalone. See `docs/INSTALL.md` for details.

## What's NOT in this repo — what you must supply

This repo is a configuration layer, not a product with a backend. It ships
parameterized; you bring your own accounts and fill in the placeholders:

- **Anthropic API access** — required for Claude Code itself (all tiers).
- **Codex CLI** (Tier 2+) and **Gemini CLI** (Tier 3+) — installed and
  authenticated locally; see `docs/PROVIDERS.md`.
- **A Supabase project** (Tier 2+) for the cost log and run history. The
  docs use the placeholder `<your-supabase-ref>`; set `SUPABASE_URL` in your
  environment to point at your own project.
- **Keychain items** for API keys — names listed in `docs/SECURITY.md` and
  `docs/PROVIDERS.md`. No key values are committed anywhere in this repo.
- **Your own repo roster** — examples in the docs use generic repo names and
  tiers. Your real tiers live in each project's `.claude/stack-config.json`.

## Documentation

- `docs/PHILOSOPHY.md` — why this exists, what it optimizes for
- `docs/CLOUD.md` — make custom skills/commands work in Claude Code cloud sessions (web + iOS)
- `docs/ARCHITECTURE.md` — system architecture
- `docs/ROUTING.md` — hook vs skill vs CLAUDE.md decision rule
- `config/model-routing.json` — which model does what and why (rationale in `docs/ADRs/004-multi-provider-strategy.md`)
- `docs/HARDWARE.md` — laptop sizing for Tier 5
- `docs/PROVIDERS.md` — API setup per provider
- `docs/ADRs/` — architecture decision records

## Contributing

See `CONTRIBUTING.md`. PRs welcome but not actively solicited — this is a personal stack first.

## License

Proprietary — all rights reserved. See `LICENSE`. Versions published on or before 2026-07-26 were Apache 2.0 (rationale in `docs/ADRs/001-license-apache-2.md`); that grant is irrevocable for copies obtained while it was in effect. This and later versions require a written license from Lade.
