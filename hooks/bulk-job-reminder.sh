#!/usr/bin/env bash
# PreToolUse Bash hook: reminds about bulk-job safety.
# Points to /cost-gate and /coverage-snapshot skills if Tier 1+ installed.
# summary: Reminds about bulk-job safety and points to /cost-gate and /coverage-snapshot when Tier 1+ is installed.

set -uo pipefail

# stdin: PreToolUse JSON with tool_input.command. The CLAUDE_TOOL_INPUT_* env
# vars are not populated by Claude Code — kept only as a fallback.
input="$(cat 2>/dev/null || echo '{}')"
cmd="$(echo "$input" | jq -r '.tool_input.command // env.CLAUDE_TOOL_INPUT_command // ""' 2>/dev/null)"
[[ -z "$cmd" || "$cmd" == "null" ]] && exit 0

# Patterns that indicate a bulk job
pattern='scripts/(enrich|backfill|rescue|bulk-|brave-|serp-|seed-|migrate-)|--batch|--bulk'

if echo "$cmd" | grep -qE "$pattern"; then
  printf "\n[bulk-job guardrail] About to run: %s\n" "$cmd"
  printf "  - Confirm script MERGES with existing data, does NOT overwrite valid rows.\n"
  printf "  - For >100 rows or any LLM-per-row job: run /cost-gate first.\n"
  printf "  - For data-modifying scripts: run /coverage-snapshot first.\n\n"
fi

exit 0
