#!/usr/bin/env bash
# PreToolUse hook (matcher: Workflow): warn or block when a Workflow run
# bypasses the named subagent roster. Mode controlled by workflow_roster in
# stack-config.json: "warn" (default) | "block" | "off".
#
# Why this exists: the Workflow tool spawns generic worktree-parallel agents that
# do NOT carry the roster's cross-model wiring (reviewer/security-auditor → Codex,
# red-team/architecture-critic → Gemini). foreman's `dynamic-workflows` mode is
# documented read-only + /cost-gate-first + "not for write-heavy work", but
# nothing enforced it. A write-heavy Workflow that skips `agentType` silently
# loses the cross-family adversarial review the stack is built around.
#
# This hook fires only in stack-initialized Tier 2+ projects, and only when the
# script looks write-heavy AND names no roster agentType. It also appends a row
# to the subagent log so Workflow runs stop being invisible unknowns.
#
# Decision (per maintainer, 2026-06-18): WARN + convention, not block (default).
# Block is opt-in via workflow_roster:"block" in stack-config.json.
# "off" disables warn/deny but still logs. ADR-016.
# summary: Warns or blocks when a Workflow run bypasses the named subagent roster, per the workflow_roster setting.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Resolve script body: prefer inline, then file contents at scriptPath, then name.
# Saved-name workflows can't be inspected (known limitation — body not available at hook time).
SCRIPT_SOURCE="none"
SCRIPT="$(echo "$INPUT" | jq -r '.tool_input.script // empty' 2>/dev/null)"
if [[ -n "$SCRIPT" ]]; then
  SCRIPT_SOURCE="inline"
else
  SCRIPT_PATH="$(echo "$INPUT" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null)"
  if [[ -n "$SCRIPT_PATH" ]]; then
    # Resolve relative paths against CWD.
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$CWD/$SCRIPT_PATH"
    if [[ -r "$SCRIPT_PATH" ]]; then
      SCRIPT="$(cat "$SCRIPT_PATH" 2>/dev/null)"
      SCRIPT_SOURCE="scriptPath"
    else
      SCRIPT_SOURCE="scriptPath"
    fi
  else
    WORKFLOW_NAME="$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null)"
    [[ -n "$WORKFLOW_NAME" ]] && SCRIPT_SOURCE="name"
  fi
fi

# Only fence stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

# Resolve mode from config; coerce invalid values to "warn".
RAW_MODE="$(jq -r '.workflow_roster // "warn"' "$CONFIG" 2>/dev/null)"
case "$RAW_MODE" in
  warn|block|off) MODE="$RAW_MODE" ;;
  *) MODE="warn" ;;
esac

ROSTER='architect|implementer|validator|reviewer|security-auditor|red-team|tester|data-engineer|designer|architecture-critic|product-critic|performance-engineer|documenter|integration-specialist|accessibility-auditor|user-docs-writer|ops|local-ops|estimator|foreman-team-lead|historian|incident-commander|librarian|scribe'

# Extract distinct roster agent names from agentType declarations.
# Handles all four forms:
#   agentType: 'reviewer'       (unquoted key, single-quoted value)
#   agentType:"reviewer"        (unquoted key, double-quoted value)
#   "agentType":"reviewer"      (double-quoted key — confirmed grep miss without the optional-quote fix)
#   'agentType':'reviewer'      (single-quoted key)
NAMES="$(echo "$SCRIPT" | grep -oE "[\"']?agentType[\"']?[[:space:]]*[:=][[:space:]]*[\"'][a-z-]+[\"']" | grep -oE "[\"'][a-z-]+[\"']$" | tr -d "\"'")"
if [[ -n "$NAMES" ]]; then
  ROSTER_AGENTS_JSON="$(echo "$NAMES" | grep -xE "$ROSTER" | sort -u | jq -R . | jq -sc .)"
else
  ROSTER_AGENTS_JSON="[]"
fi
[[ "$ROSTER_AGENTS_JSON" == "[]" ]] && HAS_ROSTER=0 || HAS_ROSTER=1

# Does the workflow write to the tree (worktree isolation, or build/edit verbs)?
WRITE_HEAVY=0
if echo "$SCRIPT" | grep -qiE "isolation['\"[:space:]]*[:=]['\"[:space:]]*worktree|\b(implement|refactor|scaffold|migrat|build the|edit |write the|apply the fix|create .*file|grant|revoke|drop|alter table|deploy|push)\b"; then
  WRITE_HEAVY=1
fi

# Saved-name workflows can't be inspected (body not available at hook time), so
# SCRIPT is empty and the write-verb scan above can never fire. Treat them as
# worst-case: an un-inspectable saved workflow should be denied in block mode
# rather than waved through. ADR-007 follow-up #4.
if [[ "$SCRIPT_SOURCE" == "name" ]]; then
  WRITE_HEAVY=1
fi

# Compute decision before logging so the row matches stdout.
DECISION="quiet"
if [[ "$MODE" == "off" ]]; then
  DECISION="quiet"
elif [[ "$WRITE_HEAVY" -eq 1 && "$HAS_ROSTER" -eq 0 ]]; then
  if [[ "$MODE" == "block" ]]; then
    DECISION="deny"
  else
    DECISION="warn"
  fi
fi

# Log the run so Workflow dispatches are visible (mirrors subagent-log.sh schema).
LOG_DIR="$HOME/.claude/logs"; mkdir -p "$LOG_DIR"
PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if command -v jq &>/dev/null; then
  jq -nc \
    --arg ts "$TS" \
    --arg project "$PROJECT" \
    --argjson roster_agents "$ROSTER_AGENTS_JSON" \
    --argjson write "$WRITE_HEAVY" \
    --arg mode "$MODE" \
    --arg decision "$DECISION" \
    --arg script_source "$SCRIPT_SOURCE" \
    '{event:"workflow_dispatch", ts:$ts, project:$project, agent:"workflow",
      uses_roster:($roster_agents|length>0), write_heavy:($write==1),
      roster_agents:$roster_agents, mode:$mode, decision:$decision,
      script_source:$script_source}' \
    >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true
fi

# Branch on decision.
if [[ "$DECISION" == "quiet" ]]; then
  exit 0
fi

if [[ "$DECISION" == "deny" ]]; then
  DENY_REASON="stack workflow-roster-check (block mode): write-heavy Workflow run names no roster agentType — cross-model review (Codex/Gemini) would be skipped. Pass agentType: <roster-name> to your agent() calls, or run file-writing work on the main-thread critical path via /foreman (architect → implementer → validator → reviewer). To allow unrostered write-heavy workflows in this project, set workflow_roster to \"warn\" or \"off\" in .claude/stack-config.json."
  jq -nc --arg r "$DENY_REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}' \
    2>/dev/null || true
  exit 0
fi

# Warn path: write-heavy Workflow that names no roster agentType. Non-blocking.
REASON="Write-heavy Workflow run names no roster agentType — cross-model review (Codex/Gemini) will be skipped, and this is the case foreman's dynamic-workflows guardrail flags (read-only only). Either keep file-writing work on the main-thread critical path via /foreman (architect → implementer → validator → reviewer), or pass agentType: <roster-name> to your agent() calls so the named roles (and their Codex/Gemini wiring) run. Proceeding either way."

jq -nc --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", permissionDecisionReason:"stack workflow-roster-check", additionalContext:("<system-reminder>"+$r+"</system-reminder>")}}' \
  2>/dev/null || true

exit 0
