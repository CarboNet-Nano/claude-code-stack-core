#!/usr/bin/env bash
# PostToolUse[Edit|Write] hook — ADR-071 D9. Replaces rev 1's write-time
# compile (the managed floor's denyWrite makes a Bash-invoked compile of
# .claude/settings.json impossible; only the Edit/Write tool can still
# change .claude/stack-config.json, and this hook is what re-compiles when
# it does). Fires ONLY when the edited path is .claude/stack-config.json
# AND the sensitivity level actually changed — an unrelated edit, or an
# edit to any other file, costs nothing.
#
# Matcher shape follows hooks/post-tool-tsc.sh (PostToolUse, matcher
# "Edit|Write|MultiEdit" in the hooks config; this hook self-filters on the
# file path from the tool_input payload, the same pattern
# hooks/migration-guard.sh uses).
#
# summary: Recompiles the sandbox vendor-host policy when an Edit/Write actually changes sensitivity.level in stack-config.json (ADR-071 D9).
set -uo pipefail

[[ "${SANDBOX_POLICY_COMPILE:-}" == "off" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[[ -z "$FILE_PATH" ]] && exit 0

# Only .claude/stack-config.json, by suffix (the file may be named via a
# relative or absolute path depending on caller).
case "$FILE_PATH" in
  */.claude/stack-config.json|.claude/stack-config.json) : ;;
  *) exit 0 ;;
esac

[[ -f "$FILE_PATH" ]] || exit 0
REPO_ROOT="$(cd "$(dirname "$FILE_PATH")/.." && pwd -P 2>/dev/null)" || exit 0
[[ -f "$REPO_ROOT/.claude/stack-config.json" ]] || exit 0

CURRENT_LEVEL="$(jq -r '.sensitivity.level // "normal"' "$REPO_ROOT/.claude/stack-config.json" 2>/dev/null)"
[[ -z "$CURRENT_LEVEL" || "$CURRENT_LEVEL" == "null" ]] && CURRENT_LEVEL="normal"

RECEIPT_KEY="$(printf '%s' "$REPO_ROOT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])' 2>/dev/null)"
[[ -z "$RECEIPT_KEY" ]] && exit 0
RECEIPT="$HOME/.claude/session-state/sandbox-policy/$RECEIPT_KEY.json"
PREV_LEVEL="$(jq -r '.level // empty' "$RECEIPT" 2>/dev/null)"

# No prior receipt at all: only worth compiling if the level is non-default
# (a repo that has never compiled and is still at "normal" gains nothing
# from a recompile here — the next SessionStart will do it for free).
if [[ -z "$PREV_LEVEL" ]]; then
  [[ "$CURRENT_LEVEL" == "normal" ]] && exit 0
elif [[ "$PREV_LEVEL" == "$CURRENT_LEVEL" ]]; then
  exit 0   # level did not actually change — no-op, per D9
fi

COMPILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/sandbox-policy-compile.sh"
[[ -f "$COMPILE" ]] || COMPILE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/sandbox-policy-compile.sh"
[[ -f "$COMPILE" ]] || exit 0

export CLAUDE_HOOK_EVENT="PostToolUse"
PLAN_JSON="$(bash "$COMPILE" --repo-root "$REPO_ROOT" --json 2>/dev/null)" || exit 0
[[ -n "$PLAN_JSON" ]] || exit 0

VERDICT="$(echo "$PLAN_JSON" | jq -r '.verdict // empty' 2>/dev/null)"
[[ -n "$VERDICT" && "$VERDICT" != "COMPILED" ]] && echo "sandbox-policy recompiled (level $PREV_LEVEL -> $CURRENT_LEVEL): $VERDICT"

echo "$PLAN_JSON" | jq -r '
  (.result.new_stashes // [])[]?
  | "  stashed: " + .value + " (" + .scope + ", was " + .owner + "-owned) — restore is a human act; see /sensitivity status"
' 2>/dev/null

exit 0
