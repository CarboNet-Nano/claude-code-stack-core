# Onboarding — <Project name>

For a new human contributor (or me, after a long break).

## In order

### 1. Read these (15 min)
- `README.md` — what this is.
- `CLAUDE.md` — how the AI assistant works in this repo.
- `docs/ARCHITECTURE.md` — system overview.

### 2. Set up your environment (30 min)
- `<install commands>`
- API keys (in your Keychain): <list of Keychain items needed>
- Verify: `<command>` should output `<expected>`.

### 3. Run something (10 min)
- Local dev: `<command>`
- Smoke test: `<command>`
- Expected behavior: `<description>`

### 4. Look at recent changes (20 min)
- `git log --oneline -30` — last 30 commits.
- `gh pr list --state merged --limit 10` — last 10 merged PRs.
- `docs/handoffs/` — last few handoff docs to see what was being worked on.

### 5. Understand the decisions (30 min)
- `docs/ADRs/` — read them all if it's a small set; otherwise read the latest 5 and any tagged "important".

### 6. Know where to look when things break
- `docs/runbooks/` — operational runbooks for deployed components.
- Past incidents in `docs/incidents/` if any.

## Project-specific quirks

<List the genuinely surprising things. E.g., "Migrations live in `acme/api` repo even though they affect this repo — historical reason.">

## Who to ask

<If others are involved: name + scope. If solo: "ask the maintainer; if the maintainer is unreachable, the docs above should cover most cases.">

## When you're ready to make a change

1. Run `/project-init` if you're using Claude Code with the stack.
2. Use `/plan` for anything beyond a trivial fix.
3. Follow the foreman's dispatch for the task type.
4. PR includes: code change, test, doc update (parallel via documenter), ADR if architectural.
