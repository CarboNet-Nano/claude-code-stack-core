# Vendored skill — provenance

`git-safety-net` is vendored from the `daymade/claude-code-skills` marketplace,
v1.7.0 (marketplace suite v1.86.0, commit `a127976`, 2026-07-22).

- Upstream: https://github.com/daymade/claude-code-skills/tree/main/git-safety-net
- Author: daymade (daymadev89@gmail.com)
- License: MIT (see ./LICENSE)

Vendored (not referenced as a plugin) so it ships through the stack's
copy-into-`~/.claude` install path and works in cloud sessions, which have no
plugin support. Re-sync manually from upstream when the plugin updates.

## What was vendored

Full skill directory as shipped upstream: `SKILL.md`, `agents/`, `references/`,
`scripts/*.sh` (chmod +x preserved), `tests/test_git_find_all_checkouts.py`.

## What was intentionally NOT vendored

- `.security-scan-passed` — an artifact of upstream's own gitleaks CI pass,
  keyed to a content hash of their tree. It does not apply to this fork and
  would be stale/misleading the moment either tree changes; omitted rather
  than carried forward silently. If a future re-sync includes it, it's safe
  to drop again.

## Adoption context

Closes get-lade/claude-code-stack#103. Registered at Tier 0
(`config/tier-manifests/tier-0.json`), parallel to the existing
`irreversible-deny` hook, per the librarian audit's Tier 0/1 conversion batch
(`docs/librarian-reports/2026-07-26-full-ecosystem-inventory-rank-tier.md`).
The issue itself flags Tier 1 as a defensible alternate reading; Tier 0 was
chosen as closer in kind to the existing destructive-action guardrail.
