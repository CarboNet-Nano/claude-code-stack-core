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
#   10 behind — an update is available (callers may offer to run update.sh)

set -uo pipefail

STAMP="$HOME/.claude/.stack-install.json"
MODE="${1:-}"

# Print compact token (--oneline) or human line.
emit() {
  if [[ "$MODE" == "--oneline" ]]; then echo "$1"; else echo "$2"; fi
}

command -v jq >/dev/null 2>&1 || { emit "unknown" "jq not available — cannot check stack freshness"; exit 0; }
[[ -f "$STAMP" ]] || { emit "unstamped" "no install stamp (pre-stamp install) — reinstall to enable freshness checks"; exit 0; }

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
emit "${BEHIND} behind — run update.sh" \
     "stack is ${BEHIND} commit(s) behind origin/$BRANCH — run ./scripts/update.sh --tier=${TIER} in ${REPO}"
exit 10
