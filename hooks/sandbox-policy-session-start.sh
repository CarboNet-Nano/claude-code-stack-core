#!/usr/bin/env bash
# SessionStart hook — ADR-071 D9. Compiles this repo's sensitivity.level +
# config/vendor-hosts.json into the sandbox network allowlist by invoking
# scripts/sandbox-policy-compile.sh (this hook is the ONLY context, besides
# hooks/sandbox-policy-recompile.sh, that sets CLAUDE_HOOK_EVENT — hooks run
# unconstrained on the host, so they can write what the managed floor's
# denyWrite makes unwritable from Bash; ADR-071 C7).
#
# MUST exit 0 on every path — a SessionStart hook must never break a
# session. No network call. Registered in
# config/settings.global.template.json BEFORE session-start-handoff.sh.
#
# summary: Compiles the repo's sensitivity level into the sandbox network allowlist at session start (ADR-071).
set -uo pipefail

[[ "${SANDBOX_POLICY_COMPILE:-}" == "off" ]] && exit 0

# git_root() / find_wrapped_repo() — duplicated verbatim from
# hooks/session-start-handoff.sh:28-49 per ADR-071 D9's explicit instruction
# ("extract to lib/ or duplicate with a comment; do not invent a third").
# Keep these two functions in sync with that file if either changes.
git_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

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
if [[ -z "$GIT_ROOT" ]]; then
  GIT_ROOT="$(find_wrapped_repo)"
fi
[[ -z "$GIT_ROOT" ]] && exit 0   # not in a git repo, no nested stack repo — silent

COMPILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/sandbox-policy-compile.sh"
[[ -f "$COMPILE" ]] || COMPILE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/sandbox-policy-compile.sh"
[[ -f "$COMPILE" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

export CLAUDE_HOOK_EVENT="SessionStart"
PLAN_JSON="$(bash "$COMPILE" --repo-root "$GIT_ROOT" --json 2>/dev/null)" || exit 0
[[ -n "$PLAN_JSON" ]] || exit 0
echo "$PLAN_JSON" | jq -e . >/dev/null 2>&1 || exit 0

VERDICT="$(echo "$PLAN_JSON" | jq -r '.verdict // "NOT_GOVERNED"')"

if [[ "$VERDICT" != "COMPILED" && "$VERDICT" != "NOT_GOVERNED" ]]; then
  echo "sandbox-policy: $VERDICT"
fi

if [[ "$VERDICT" == "FLOOR_ABSENT" ]]; then
  echo "  Managed floor not installed — see docs/runbooks/managed-floor-install.md"
fi

echo "$PLAN_JSON" | jq -r '
  (.result.new_stashes // [])[]?
  | "  stashed: " + .value + " (" + .scope + ", was " + .owner + "-owned) — restore is a human act; see /sensitivity status"
' 2>/dev/null

MCP_LIST="$(echo "$PLAN_JSON" | jq -r '(.leaks.mcp_unreviewed // []) | join(", ")' 2>/dev/null)"
[[ -n "$MCP_LIST" ]] && echo "  MCP servers with no recorded filesystem-write review: $MCP_LIST"

exit 0
