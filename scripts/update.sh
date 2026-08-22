#!/usr/bin/env bash
# Claude Code Stack — Updater
# Pulls the latest stack, then re-runs install.sh in merge mode (which
# preserves your customizations). An update is always a merge — for a clean
# reinstall use `install.sh --mode=fresh` directly.
#
# ADR-086 D7 (amends ADR-071 D15 #3): TWO sanctioned entry points, and a
# third that is FORBIDDEN.
#   Sanctioned: (a) a human in a real terminal; (b) hooks/stack-update-apply.sh,
#   the post-consent applier, which runs outside the Bash sandbox because
#   hooks are separate host processes (ADR-071 C7).
#   Forbidden: the Bash tool. This script writes ~/.claude/hooks, scripts,
#   config, agents, skills, and lib — every path the managed floor's
#   `denyWrite` protects (docs/runbooks/managed-floor-install.md). Deliberately
#   NOT added to any `excludedCommands` list — that would exempt an arbitrary
#   ~/.claude/** write from the sandbox entirely, a wider hole than the
#   problem it would solve.
#
# The advisory guard below refuses (exit 3) when a Claude Code session
# marker env is present and STACK_UPDATE_VIA_HOOK != 1. It is trivially
# spoofable (the model can export STACK_UPDATE_VIA_HOOK=1 itself) — the ADR
# claims nothing stronger for it. The real boundary is the write-denial
# layer (the managed floor, or Claude Code's built-in config-dir
# self-protection), which denies these writes regardless of what env vars
# the process carries. The guard's entire value is legibility: a refusal
# naming this ADR instead of a partially-applied write with a confusing
# rsync EPERM.
#
# Usage: ./update.sh --tier=N [--include-ollama=laptop] [--skip-requirements]
#
# Env read here (set by hooks/stack-update-apply.sh, ADR-086 D2 — not for
# manual use; a human terminal run needs none of these):
#   STACK_UPDATE_VIA_HOOK=1  satisfies the advisory guard below.
#   STACK_UPDATE_NO_PULL=1   skip `git pull --ff-only` entirely — the applier
#                            has already fast-forwarded from staged,
#                            pin-verified local objects (ADR-086 D13), so
#                            this run makes no network call of its own.
#   STACK_INSESSION=1, STACK_UPDATE_MODE=hook are read by install.sh, not
#   here — see that script's own header.

set -euo pipefail

# ADR-086 D7 — advisory legibility guard. Fires only when a Claude Code
# session marker is present and the applier hasn't identified itself.
if [[ ( -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ) && "${STACK_UPDATE_VIA_HOOK:-}" != "1" ]]; then
  echo "Refused: update.sh cannot run from inside a Claude Code session's Bash tool." >&2
  echo "ADR-071 D15 #3 / ADR-086 D7: the only sanctioned entry points are a human" >&2
  echo "in a real terminal, or hooks/stack-update-apply.sh (the post-consent" >&2
  echo "applier, which runs outside the sandbox). Run this from a real terminal." >&2
  exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIER=""
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
  esac
done

if [[ -z "$TIER" ]]; then
  echo "Usage: $0 --tier=N [--include-ollama=laptop] [--skip-requirements]"
  exit 1
fi

cd "$REPO_ROOT"

# A dirty tree means local edits to stack files — `git pull` could conflict,
# and a merge install could mistake those edits for stack content. Stop and
# let the user decide.
#
# TRACKED changes only (`-uno`). The original check counted untracked files
# too, which is broader than the reason above: an untracked file cannot
# conflict with a fetch, and it is not a local edit to stack content. What it
# CAN do is silently freeze updates forever — one stray generated file
# (a compiled permissions sidecar, an editor scratch file) and this repo
# never updates again, on every machine that has one. Reported by the
# maintainer 2026-08-21 after exactly that: two generated files, weeks of
# missed updates, and nothing that looked like an error.
#
# The residual case is an untracked file sitting where an incoming commit
# wants to create one. Git refuses that merge on its own with a clear
# message, so it surfaces as a loud failure at apply time rather than as
# silence at every boot. Loud-and-rare beats silent-and-permanent.
#
# The checks below mirror hooks/stack-self-update.sh exactly. They must agree:
# the stager decides whether it is safe to PREPARE an update, this decides
# whether it is safe to CHANGE the checkout. A cross-family review found the
# original pair could diverge, and that "empty porcelain output" is not the
# same as "safe to fast-forward".

# A failed status is not a clean status. `$(...)` swallows the exit code, so a
# locked index or unreadable worktree produced empty output and read as clean.
if ! DIRTY_STATUS="$(git status --porcelain -uno 2>&1)"; then
  echo "Could not determine whether claude-code-stack is clean:" >&2
  printf '%s\n' "$DIRTY_STATUS" | sed -e 's/^/  /' >&2
  echo "Refusing to update until git can report the repository's state." >&2
  exit 1
fi
if [[ -n "$DIRTY_STATUS" ]]; then
  echo "claude-code-stack has uncommitted changes to tracked files."
  echo "Commit or stash them before updating, then re-run."
  echo "(Untracked files no longer block the update — only edits to stack files do.)"
  exit 1
fi

# A clean tree can still be mid-operation; git would refuse the fast-forward.
for _op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if git rev-parse -q --verify "$_op" >/dev/null 2>&1; then
    echo "claude-code-stack has an unfinished ${_op%_HEAD} in progress." >&2
    echo "Finish or abort it, then re-run." >&2
    exit 1
  fi
done
_GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null || echo "")"
if [[ -n "$_GITDIR" && ( -d "$_GITDIR/rebase-merge" || -d "$_GITDIR/rebase-apply" || -e "$_GITDIR/sequencer" ) ]]; then
  echo "claude-code-stack has an unfinished rebase or cherry-pick sequence in progress." >&2
  echo "Finish or abort it, then re-run." >&2
  exit 1
fi

# Tracked edits hidden by assume-unchanged / skip-worktree index bits.
if git ls-files -v 2>/dev/null | grep -qE '^[a-z]'; then
  echo "claude-code-stack has tracked files marked assume-unchanged or skip-worktree." >&2
  echo "Those hide local edits from git status. Clear them with:" >&2
  echo "  git update-index --no-assume-unchanged <path>   (or --no-skip-worktree)" >&2
  exit 1
fi

# ADR-086 D2 — STACK_UPDATE_NO_PULL=1: the applier hook already promoted the
# staged, pin-verified SHA with a local `git merge --ff-only` (ADR-086
# D13 apply step 4) before this script ever runs, so a network pull here
# would be redundant at best and a second, unverified fetch at worst. This
# is what makes the never-killed apply phase network-free (ADR-086 D18).
if [[ "${STACK_UPDATE_NO_PULL:-}" == "1" ]]; then
  echo "[1/2] Skipping git pull (STACK_UPDATE_NO_PULL=1 — already fast-forwarded from staged, pin-verified objects)."
else
  echo "[1/2] Pulling latest claude-code-stack..."
  git pull --ff-only
fi

echo "[2/2] Re-running install (merge mode)..."
"$SCRIPT_DIR/install.sh" "$@" --mode=merge

# Overlay model: master just updated above — every registered profile's
# per-entry links may now be stale (new master entries need links, removed
# ones need pruning). Best-effort: skip silently if there's no registry yet
# or jq is unavailable.
REGISTRY="$HOME/.claude/.profiles.json"
if [[ -f "$REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
  source "$SCRIPT_DIR/lib/profile-overlay.sh"
  source "$SCRIPT_DIR/lib/config-merger.sh"
  source "$REPO_ROOT/lib/profile-resolver.sh"
  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    # Registry entries are untrusted input (IMPORTANT 4) — a hand-edited or
    # corrupted .profiles.json must not get interpolated straight into a
    # filesystem path. Validate the name, then re-run the same safety gate
    # install.sh itself uses on every profile target before touching it.
    if ! pr_validate_name "$profile_name"; then
      echo "  [skip] invalid profile name in registry: $profile_name" >&2
      continue
    fi
    profile_dir="$HOME/.claude-$profile_name"
    if ! pr_assert_safe_target "$profile_dir"; then
      echo "  [skip] unsafe profile target: $(pr_display_path "$profile_dir")" >&2
      continue
    fi
    echo "  Refreshing profile overlay: $profile_name"
    po_refresh_links "$HOME/.claude" "$profile_dir"
    po_merge_settings_fragments "$REPO_ROOT" "$TIER" "$profile_dir"
  done < <(jq -r '.profiles[]? // empty' "$REGISTRY")
fi

# ADR-086 D10/D16 — write/refresh the stack-update-pin/v2 pin at the
# successful end of this run, the same moment install.sh writes its own
# copy (both scripts are sanctioned pin authors, so update.sh stays correct
# standalone rather than relying on install.sh's write as an implementation
# detail). `hooks/` is a shared, profile-overlaid directory (scripts/
# lib/profile-overlay.sh's PO_CONTENT_DIRS), so there is exactly one
# physical pin file regardless of --profile — always under master
# ~/.claude. Best-effort: skip silently if there's no `origin` remote
# (e.g. a repo cloned without one) rather than leave a malformed pin.
if command -v jq >/dev/null 2>&1; then
  PIN_SOURCE_REPO="$(cd "$REPO_ROOT" && pwd -P)"
  PIN_REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
  if [[ -n "$PIN_SOURCE_REPO" && -n "$PIN_REMOTE_URL" ]]; then
    mkdir -p "$HOME/.claude/hooks" 2>/dev/null || true
    jq -n \
      --arg repo "$PIN_SOURCE_REPO" \
      --arg remote "$PIN_REMOTE_URL" \
      --argjson tier "$TIER" \
      '{schema: "stack-update-pin/v2", source_repo: $repo, remote_url: $remote, tier: $tier}' \
      > "$HOME/.claude/hooks/stack-update.pin.json"
  fi
fi
