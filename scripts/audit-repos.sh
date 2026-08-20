#!/usr/bin/env bash
# Walk a repo through the audit checklist.
# Usage: ./audit-repos.sh <repo-path>

set -euo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "Usage: $0 <repo-path>"; exit 1; }
[[ ! -d "$REPO" ]] && { echo "Not a directory: $REPO"; exit 1; }

cd "$REPO"

echo "==============================================="
echo "Audit pass: $REPO"
echo "==============================================="

# Step 1: Determine current state
echo ""
echo "Current state:"
echo "  CLAUDE.md present: $([[ -f CLAUDE.md ]] && echo yes || echo no)"
echo "  .claude/ present: $([[ -d .claude ]] && echo yes || echo no)"
echo "  stack-config.json: $([[ -f .claude/stack-config.json ]] && echo yes || echo no)"
echo "  docs/ADRs/: $([[ -d docs/ADRs ]] && echo yes || echo no)"
echo "  docs/runbooks/: $([[ -d docs/runbooks ]] && echo yes || echo no)"
echo "  docs/handoffs/: $([[ -d docs/handoffs ]] && echo yes || echo no)"
echo "  docs/ONBOARDING.md: $([[ -f docs/ONBOARDING.md ]] && echo yes || echo no)"

# ADR-075: report the state of this repo's portable-core skill copies. The
# earlier version of this check counted lines in the handoff skill and called
# anything over 12 stale — which knew about only one of the four managed
# skills, and could not tell an older stack version from a file someone
# deliberately edited. The classifier hashes each copy against every version
# the stack ever published, so the two get different answers.
PC_LIB=""
for _c in "$HOME/.claude/lib/portable-core.sh" "$(dirname "$0")/../lib/portable-core.sh"; do
  [[ -f "$_c" ]] && { PC_LIB="$_c"; break; }
done
if [[ -n "$PC_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PC_LIB" 2>/dev/null || true
  if declare -F pc_classify >/dev/null 2>&1 && [[ -n "$(pc_manifest_path 2>/dev/null)" ]]; then
    echo ""
    echo "Portable-core skill copies:"
    _pc_any=0
    while IFS=$'\t' read -r _rel _class _reason _hash; do
      [[ -z "$_rel" ]] && continue
      case "$_class" in
        stale)    echo "  ⚠️  ${_rel#skills/} — an older stack version; self-heals at next session start"; _pc_any=1 ;;
        diverged) echo "  ✋ ${_rel#skills/} — edited here; the stack will never overwrite it"; _pc_any=1 ;;
        blocked)  echo "  ⏸  ${_rel#skills/} — cannot refresh right now ($_reason)"; _pc_any=1 ;;
        absent)   echo "  ➕ ${_rel#skills/} — missing; will be added at next session start"; _pc_any=1 ;;
      esac
    done < <(pc_classify "$PWD" 2>/dev/null)
    (( _pc_any == 0 )) && echo "  ✅ all up to date"
  fi
fi

# Step 2: Walk the maintainer through tier choice
echo ""
echo "Pick a tier for this repo (see docs/AUDIT-PASS.md for the heuristic):"
echo "  Tier 1 — thin monitoring / utility repo"
echo "  Tier 2 — isolated service (e.g. an MCP server)"
echo "  Tier 3 — delivery pipeline / integrations"
echo "  Tier 4 — complex application"
echo "  Tier 5 — highest-complexity / multi-surface repo"

echo ""
echo "This script does NOT execute the audit — it surfaces the state."
echo "Run /project-init in this directory via Claude Code to perform the audit."
