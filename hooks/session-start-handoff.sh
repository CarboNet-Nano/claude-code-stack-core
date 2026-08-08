#!/usr/bin/env bash
# SessionStart hook:
# - Show ✅ banner with current stack settings + edit shortcuts if initialized.
# - Show ⚠️ warn if in a git repo without .claude/stack-config.json.
# - Auto-load .claude/next_prompt.md handoff if present.
# - Print a one-line key-commands footer.
# Stays silent outside git repos and inside the stack source repo itself.
# Wrapper-folder fallback: if cwd isn't a git repo, scan immediate subdirs
# for a single stack-initialized repo and use that (handles Desktop workspaces
# that open at `~/foo/` containing the actual repo at `~/foo/foo/`).
# summary: Shows the stack status banner, warns if uninitialized, and auto-loads a pending session handoff at SessionStart.

set -euo pipefail

# ADR-053 D7/D8: domain_mode may be a scalar or an array; render it only
# through dm_display (always returns 0, safe under set -e) so an array
# never round-trips through a bare `jq -r` filter.
_DM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/domain-modes.sh"
[[ -f "$_DM_LIB" ]] || _DM_LIB="$HOME/.claude/lib/domain-modes.sh"
# shellcheck disable=SC1090
source "$_DM_LIB" 2>/dev/null || true

# Stamp the session start time so /team-status (and the team-utilization section
# in /handoff) can scope counts to "this session". Cheap and side-effect-free.
mkdir -p "$HOME/.claude/state"
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.claude/state/session-start.txt"

git_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

# Look one level down for a single stack-initialized git repo.
# Echoes path only if exactly one match (avoid ambiguity).
find_wrapped_repo() {
  local candidate=""
  local count=0
  local d
  for d in "$PWD"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}.claude/stack-config.json" ]] || continue
    git -C "$d" rev-parse --show-toplevel &>/dev/null || continue
    candidate="${d%/}"
    count=$((count + 1))
  done
  if [[ $count -eq 1 ]]; then
    echo "$candidate"
  fi
  return 0
}

GIT_ROOT="$(git_root)"
WRAPPED_FROM=""

if [[ -z "$GIT_ROOT" ]]; then
  WRAPPED_FROM="$(find_wrapped_repo)"
  if [[ -n "$WRAPPED_FROM" ]]; then
    GIT_ROOT="$WRAPPED_FROM"
  else
    # Not in a git repo and no nested stack repo — silent.
    exit 0
  fi
fi

STACK_CONFIG="$GIT_ROOT/.claude/stack-config.json"
HANDOFF="$GIT_ROOT/.claude/next_prompt.md"

# Detect "this IS the stack source repo" by structural markers.
# Prevents banners from firing on the stack itself or forks of it.
is_stack_source_repo() {
  [[ -d "$GIT_ROOT/agents" ]] && \
  [[ -d "$GIT_ROOT/skills" ]] && \
  [[ -f "$GIT_ROOT/scripts/install.sh" ]]
}

# Read a JSON field from stack-config.json, with a fallback string.
# Args: <jq filter> <fallback>
read_cfg() {
  if command -v jq &>/dev/null && [[ -f "$STACK_CONFIG" ]]; then
    jq -r "$1 // \"$2\"" "$STACK_CONFIG" 2>/dev/null || echo "$2"
  else
    echo "$2"
  fi
}

if is_stack_source_repo; then
  # Stack source repo — skip both banners
  :
elif [[ -f "$STACK_CONFIG" ]]; then
  # Initialized — show ✅ banner with current settings + edit shortcuts
  TIER=$(read_cfg '.stack_tier' '?')
  DOMAIN=$(dm_display "$STACK_CONFIG" 2>/dev/null || echo none)
  STRICT=$(read_cfg 'if .strict_mode then "strict" else "permissive" end' '?')
  SENSITIVITY=$(read_cfg '.sensitivity.level' 'normal')
  MODE=$(read_cfg '.orchestration_mode' 'main-thread')

  echo ""
  echo "✅ Stack active — $MODE · Tier $TIER · $DOMAIN · $STRICT · sensitivity:$SENSITIVITY"
  echo "   Change settings: /tier · /domain-mode · /strict-mode · /sensitivity · /cost-cap"
  echo "   Re-run init: /project-init (asks before overwriting)"
  if [[ "$TIER" =~ ^[0-9]+$ && "$TIER" -ge 2 ]]; then
    echo "   Run a governed loop: /loop-engineer (bounded, Stop-hook enforced)"
  fi
  if [[ -n "$WRAPPED_FROM" ]]; then
    echo "   (detected nested repo at $WRAPPED_FROM — cd in for git commands)"
  fi
  echo ""
else
  # Uninitialized git repo — soft warn
  echo ""
  echo "⚠️  ──────────────────────────────────────────"
  echo "This repo is not stack-initialized."
  echo "  Path: $GIT_ROOT"
  echo "  Missing: .claude/stack-config.json"
  echo ""
  echo "Run /project-init to enable foreman + skills + cost gates."
  echo "(project-init now has a discovery pass — it reads your git"
  echo " history, deps, and existing CLAUDE.md to pre-fill defaults.)"
  echo "──────────────────────────────────────────────"
  echo ""
fi

# Handoff if present, otherwise a brief reminder.
if [[ -f "$HANDOFF" ]]; then
  echo "──────────────────────────────────────────────"
  echo "Handoff from previous session:"
  echo "──────────────────────────────────────────────"
  cat "$HANDOFF"
  echo "──────────────────────────────────────────────"
  echo "Run /goodmorning for full bootup (git state, PRs, CI)."
elif ! is_stack_source_repo; then
  echo "No handoff from previous session. Run /goodmorning for context, or just start working."
fi

# Condensed one-line footer (skip on stack source repo)
if ! is_stack_source_repo; then
  echo ""
  echo "── /goodmorning · /handoff · /project-init · /budget-guard · /operating ──"
fi
