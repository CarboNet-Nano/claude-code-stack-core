#!/usr/bin/env bash
# Regression suite for handoff-guard.sh (queue item #179, ADR-074 D16):
# direct Write/Edit of the handoff files is denied for every agent; the only
# writer is `session-close.sh handoff-write` (a Bash path this hook never
# sees). Guards deny-shape, path forms, traversal, and the non-handoff
# fast path.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/hooks/handoff-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$GUARD" ]] || { echo "FAIL: handoff-guard.sh not found at $GUARD"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

run_guard() { bash "$GUARD" <<< "$1"; }
payload() { jq -nc --arg fp "$1" '{tool_input:{file_path:$fp}}'; }
allows() { [[ -z "$(run_guard "$(payload "$1")")" ]]; }
denies() { run_guard "$(payload "$1")" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

REPO="/Users/someone/Code/project"

denies "$REPO/.claude/next_prompt.md" && ok "denies absolute .claude/next_prompt.md" || bad "absolute next_prompt.md allowed"
denies ".claude/next_prompt.md" && ok "denies relative .claude/next_prompt.md" || bad "relative next_prompt.md allowed"
denies "$REPO/docs/handoffs/2026-08-15-1804.md" && ok "denies a file under docs/handoffs/" || bad "docs/handoffs write allowed"
denies "docs/handoffs/archive/old.md" && ok "denies nested docs/handoffs paths" || bad "nested handoffs write allowed"
denies "$REPO/.claude/worktrees/x/.claude/next_prompt.md" && ok "denies worktree-prefixed next_prompt.md" || bad "worktree next_prompt.md allowed"
denies "$REPO/docs/../docs/handoffs/x.md" && ok "denies a ..-path aimed at docs/handoffs/" || bad "traversal path allowed"

allows "$REPO/.claude/scratch/scribe-handoff.md" && ok "allows the scratch body file (--body-file source)" || bad "scratch body file denied"
allows "$REPO/.claude/open-threads.md" && ok "allows .claude/open-threads.md (scribe's thread notes)" || bad "open-threads denied"
allows "$REPO/docs/handoff-notes.md" && ok "allows docs/handoff-notes.md (not under docs/handoffs/)" || bad "lookalike path denied"
allows "$REPO/src/next_prompt.md.example" && ok "allows a suffixed lookalike filename" || bad "suffixed lookalike denied"

DENY_MSG="$(run_guard "$(payload "$REPO/.claude/next_prompt.md")" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
printf '%s' "$DENY_MSG" | grep -q "handoff-write" && ok "deny reason names the legitimate writer" || bad "deny reason missing handoff-write: $DENY_MSG"

[[ -z "$(printf '{}' | bash "$GUARD")" ]] && ok "empty payload exits silently (fail-open)" || bad "empty payload produced output"
[[ -z "$(printf 'not json' | bash "$GUARD")" ]] && ok "malformed payload exits silently (fail-open)" || bad "malformed payload produced output"

WIRED="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Edit|Write|MultiEdit") | .hooks[].command' "$REPO_ROOT/hooks/hooks.json" 2>/dev/null)"
printf '%s' "$WIRED" | grep -q "handoff-guard.sh" && ok "hooks.json wires handoff-guard on Edit|Write|MultiEdit" || bad "handoff-guard not wired in hooks.json"

echo "test-handoff-guard: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
exit 0
