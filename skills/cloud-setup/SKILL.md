---
name: cloud-setup
description: Print the one-time setup script that enables the stack's skills/commands in Claude Code cloud sessions (web + iOS) for a given environment. Cloud environments are configured individually in the Claude Code web UI and cannot be set from a repo, so this skill emits the exact one-liner to paste plus the click-by-click steps. Use when the user asks how to enable the stack in cloud, why /goodmorning etc. are missing in a web/iOS session, or wants to set up a new cloud environment.
---

# /cloud-setup

Enable the stack in Claude Code **cloud** sessions for one environment.

## Why this is manual

Cloud environments (network policy, env vars, **setup script**) are stored in
the Claude Code web environment config — Anthropic's side, **not** reachable
from any repo, API, or this stack. So the setup script must be pasted in once
per environment by hand. This skill makes that a single copy-paste.

The stack repo is **public**, so the clone needs no token and no env var.

## What to output

Print exactly the block below to the user (verbatim — it is the deliverable).
Do not run anything; this is a copy-paste handoff.

---

**One-time: enable the stack in a cloud environment**

1. Open <https://claude.ai/code>. Click the **environment name** (cloud icon,
   bottom-left of the prompt box) → the environment selector opens.
2. Hover the environment you want → click its **gear / settings** icon
   (or **Add cloud environment…** to make a new one).
3. Find the **Setup script** field. Paste this, then **Save**:

   ```bash
   rm -rf /tmp/ccs && git clone --depth 1 https://github.com/bschonbrun/claude-code-stack /tmp/ccs && bash /tmp/ccs/scripts/install.sh --tier=2 --skip-requirements
   ```

4. Make sure **Network access** allows GitHub (the default allowlist does).
5. Start a **fresh** cloud session on that environment. The setup script runs
   `install.sh` (you'll see the install log). Then `/goodmorning`, `/handoff`,
   `/project-init`, etc. resolve.

Repeat per environment — cloud environments are configured individually.

Optional tier override: change `--tier=2` (0 = foundation, 1 = + discipline
skills, 2 = + subagents/foreman).

---

## Notes

- **Idempotent.** `install.sh --mode=merge` (the default) backs up `~/.claude`
  and deep-merges, so re-running on each session boot is safe.
- **Verify:** in the cloud session run
  `ls ~/.claude/skills/goodmorning/SKILL.md` — present means it worked.
- **Per-repo alternative.** Instead of (or in addition to) the env setup
  script, run `/project-init` in a repo and accept cloud-session support — that
  commits the bootstrap into the repo's `.claude/`, so the repo self-enables in
  cloud with no environment config. See `docs/CLOUD.md`.
- If skills install but don't appear in the `/` menu, they may be hidden by
  `skillOverrides`; run `/skills` to toggle visibility (they still work when
  typed in full).
