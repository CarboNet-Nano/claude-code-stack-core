#!/usr/bin/env bash
# summary: Refreshes per-repo copies of portable-core skills whose bytes are provably an older stack version, so a repo initialised before a stack change stops being a silently stale fork (ADR-075).
#
# SessionStart hook. The four skills in config/portable-core-skills.json are
# COPIED into other repos' .claude/skills/, and both copiers only ever write
# when the file is absent. Nothing refreshed them, so every repo initialised
# before any change kept its copy forever.
#
# This rewrites ONLY files whose current bytes are one the stack itself
# published in the past (lib/portable-core.sh does the classifying). Anything a
# human touched has bytes the stack never published and is never written.
#
# NOT `set -e`, and it ALWAYS exits 0. This runs at boot in every repo on the
# machine: a fail-closed refresher converts a documentation-staleness problem
# into an inability to start a session, in 26+ repos at once (ADR-075 D11).
#
# It must NOT gate on `[ -t 0 ]`. Whether a SessionStart hook ever gets a TTY is
# not established, and because this prints only when it acted, a wrong guess
# there disables the whole mechanism with no output at all — a silent, total,
# signal-free failure. See ADR-075 D3b.

set -uo pipefail

_PCR_HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_PCR_HOOKDIR/../lib/profile-resolver.sh" ]] && source "$_PCR_HOOKDIR/../lib/profile-resolver.sh"
CLAUDE_HOME="${CLAUDE_PLUGIN_ROOT:-$(command -v pr_resolve_dir_or_default >/dev/null && pr_resolve_dir_or_default 2>/dev/null || echo "$HOME/.claude")}"

# Every early return below is a documented fail-open condition (D11).
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$GIT_ROOT" ]] || exit 0

# The stack source repo owns the originals; refreshing there is meaningless and
# would fight the maintainer's own edits.
[[ -f "$GIT_ROOT/config/portable-core-skills.json" ]] && exit 0

# Nothing to reconcile if this repo has no copies at all.
[[ -d "$GIT_ROOT/.claude/skills" ]] || exit 0

LIB="$CLAUDE_HOME/lib/portable-core.sh"
[[ -f "$LIB" ]] || exit 0
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

declare -F pc_reconcile >/dev/null 2>&1 || exit 0
[[ -n "$(pc_manifest_path)" ]] || exit 0

RESULT="$(pc_reconcile "$GIT_ROOT" 1 2>/dev/null)"
if ! printf '%s' "$RESULT" | jq -e . >/dev/null 2>&1; then
  pc_receipt_write "$GIT_ROOT" "$(jq -n --arg e "pc_reconcile produced no usable output" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" '{as_of:$now, error:$e}')" 2>/dev/null
  exit 0
fi

pc_receipt_write "$GIT_ROOT" "$RESULT" 2>/dev/null

# Print ONLY when something was actually written. A refresher that narrates
# every quiet boot trains the user to skip the one boot that mattered.
N_REFRESHED="$(printf '%s' "$RESULT" | jq -r '.refreshed | length' 2>/dev/null)"
N_CREATED="$(printf '%s' "$RESULT" | jq -r '.created | length' 2>/dev/null)"
[[ "$N_REFRESHED" =~ ^[0-9]+$ ]] || N_REFRESHED=0
[[ "$N_CREATED" =~ ^[0-9]+$ ]] || N_CREATED=0
(( N_REFRESHED + N_CREATED > 0 )) || exit 0

_plural() { (( $1 == 1 )) && printf '%s' "$2" || printf '%ss' "$2"; }

{
  if (( N_REFRESHED > 0 )); then
    printf '♻️  Stack self-heal — refreshed %d stale skill %s in this repo:\n' \
      "$N_REFRESHED" "$(_plural "$N_REFRESHED" copy)"
    printf '%s' "$RESULT" | jq -r '.refreshed[] | "   \(.)  (was from an older stack version)"' 2>/dev/null
  fi
  if (( N_CREATED > 0 )); then
    printf '♻️  Stack self-heal — added %d missing skill %s:\n' \
      "$N_CREATED" "$(_plural "$N_CREATED" file)"
    printf '%s' "$RESULT" | jq -r '.created[] | "   \(.)"' 2>/dev/null
  fi
  printf '   Tracked and now uncommitted. Revert with:\n'
  printf '%s' "$RESULT" | jq -r '(.refreshed + .created) | "     git checkout -- \(.[0])"' 2>/dev/null
  printf '   This session may still be using the previous copy; restart if it matters.\n'
} 2>/dev/null

exit 0
