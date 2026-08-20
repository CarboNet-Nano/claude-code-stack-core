#!/usr/bin/env bash
# Shared: report whether the installed stack (~/.claude) is behind the source
# repo it was installed from. Reads ~/.claude/.stack-install.json, the stamp
# written by install.sh (source_sha, source_branch, source_repo).
#
# Everything here is best-effort and non-fatal: a missing stamp, missing jq,
# an unreachable repo, or no network all resolve to a benign status. Callers
# (/goodmorning, /project-init) branch on stdout and/or exit code.
#
# Usage:
#   bash ~/.claude/lib/stack-freshness.sh            # human-readable line
#   bash ~/.claude/lib/stack-freshness.sh --oneline  # compact token for the
#                                                    # /goodmorning summary fence
#
# Exit codes:
#   0  current, or status could not be determined (treat as "don't nag")
#   10 behind — an update is available. /goodmorning applies it itself at a
#      clean session start; callers should NOT tell a human to run update.sh
#      (it refuses on a dirty tree, so the instruction can be unfollowable).

set -uo pipefail

_SF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_SF_DIR/profile-resolver.sh" ]] && source "$_SF_DIR/profile-resolver.sh"
CONF_DIR="$(command -v pr_resolve_dir_or_default >/dev/null 2>&1 && pr_resolve_dir_or_default 2>/dev/null || echo "$HOME/.claude")"
STAMP="$CONF_DIR/.stack-install.json"
MODE="${1:-}"

# Print compact token (--oneline) or human line.
emit() {
  if [[ "$MODE" == "--oneline" ]]; then echo "$1"; else echo "$2"; fi
}

command -v jq >/dev/null 2>&1 || { emit "unknown" "jq not available — cannot check stack freshness"; exit 0; }
if [[ ! -f "$STAMP" ]]; then
  if [[ "$CONF_DIR" != "$HOME/.claude" ]]; then
    emit "unstamped-profile $(pr_display_path "$CONF_DIR")" \
         "profile $(pr_display_path "$CONF_DIR") has no install stamp — run install.sh --migrate-profile=${CONF_DIR##*/.claude-} (or --profile=... to create it)"
    exit 0
  fi
  emit "unstamped" "no install stamp (pre-stamp install) — reinstall to enable freshness checks"
  exit 0
fi

REPO="$(jq -r '.source_repo // empty' "$STAMP")"
SHA="$(jq -r '.source_sha // empty' "$STAMP")"
BRANCH="$(jq -r '.source_branch // "main"' "$STAMP")"

[[ -n "$REPO" && -d "$REPO/.git" ]] || { emit "repo-not-found" "stack source repo not reachable (${REPO:-unset}) — clone present?"; exit 0; }
[[ -n "$SHA" ]] || { emit "unknown" "install stamp missing source_sha"; exit 0; }

# Refresh remote refs; tolerate offline.
git -C "$REPO" fetch --quiet origin "$BRANCH" 2>/dev/null || true
# --verify --quiet prints nothing and fails cleanly if the ref doesn't exist
# (plain rev-parse echoes the unresolved ref name to stdout on failure).
REMOTE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "origin/$BRANCH" 2>/dev/null || echo "")"
[[ -n "$REMOTE_SHA" ]] || { emit "current" "could not reach origin/$BRANCH (offline?) — skipping"; exit 0; }

if [[ "$SHA" == "$REMOTE_SHA" ]]; then
  emit "current" "stack is current (origin/$BRANCH @ ${SHA:0:7})"
  exit 0
fi

# How many commits is the installed SHA behind the remote tip?
BEHIND="$(git -C "$REPO" rev-list --count "$SHA..origin/$BRANCH" 2>/dev/null || echo "?")"
TIER="$(jq -r '.tier // "?"' "$STAMP")"
# Differing SHAs with nothing to catch up on means the install is AHEAD of the
# remote — a maintainer installed from a local commit before pushing it. There
# is no update to apply, so this must not read as "behind" (callers render any
# "N behind" token as a failure, and "0 versions behind" is unfixable advice).
# A recorded install point that this repository has never heard of -- a fresh
# clone, a rebased branch, a stamp copied from another machine -- makes the
# range invalid and `rev-list` fails, leaving BEHIND as "?". Falling through
# with that produces "stack is ? commit(s) behind", which callers render as a
# failure and which no reader can act on. It is not a distance; it is a
# stamp we cannot place, which is what the `unknown` token already means.
if [[ "$BEHIND" == "?" ]]; then
  emit "unknown" "the recorded install point ${SHA:0:7} is not in this repo's history — reinstall to re-stamp it"
  exit 0
fi

if [[ "$BEHIND" == "0" ]]; then
  emit "current" "stack is current (installed ${SHA:0:7} is ahead of origin/$BRANCH — nothing to apply)"
  exit 0
fi
# The token used to read "N behind — run update.sh". It no longer tells the
# reader to run anything: `update.sh` refuses on a dirty tree, so that text
# could be printed at a moment when following it was impossible, and the
# obvious workaround (stash, update, unstash) is how in-flight work gets
# lost. /goodmorning applies the update itself at boot, when the tree is
# clean and there is nothing to lose. This just reports distance.
emit "${BEHIND} behind" \
     "stack is ${BEHIND} commit(s) behind origin/$BRANCH (tier ${TIER}, ${REPO}) — applied automatically at the next clean session start"
exit 10
