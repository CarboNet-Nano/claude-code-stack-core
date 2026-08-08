#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): log subagent dispatches made while the
# project is in a high-sensitivity context, so safety-relevant dispatches are
# auditable. ADR-007 follow-up #5. Best-effort observability (H3) — NEVER a
# gate; always exits 0 and never emits a permissionDecision.
#
# "High-sensitivity context" = the project's stack-config has any of:
#   - domain_mode == "financial-code"   (money/AR/AP/revenue code)
#   - domain_mode == "schema-migration" (one-way-door DB changes)
#   - sensitivity.level == "confidential"
#
# Each such dispatch appends an `override_context` row to subagent-runs.jsonl
# (same log subagent-log.sh writes) capturing the agent, orchestration_mode,
# and which context flag(s) made this a logged dispatch. /agent-performance-
# review and /handoff can then surface "N dispatches under <context>".
#
# This complements subagent-log.sh's plain `dispatch` row — that one logs every
# dispatch; this one tags the safety-relevant subset with WHY it mattered.
#
# ── Sourceable (ADR-037 D-1) ────────────────────────────────────────────────
# ovlog_append() below is a generic single-row JSONL writer other guard hooks
# can call after `source`-ing this file, so guard-override logging reuses one
# log file and one schema instead of duplicating the append logic. Sourcing
# has NO side effects: the Agent-dispatch logic only runs when this file is
# executed directly (the BASH_SOURCE guard at the bottom), so
# `source hooks/override-log.sh` from another hook does not itself write a
# row or consume stdin.
# summary: Logs subagent dispatches made in high-sensitivity project contexts for audit purposes.

set -uo pipefail

# ADR-053 D7/D8: domain_mode may now be a scalar or an array; read it only
# through the shared reader so a multi-mode config is never string-compared
# against a bare value (silent fail-open) or fed to `jq -r` for a bare-string
# echo (corrupts to pretty-printed multi-line JSON on an array).
_DM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/domain-modes.sh"
[[ -f "$_DM_LIB" ]] || _DM_LIB="$HOME/.claude/lib/domain-modes.sh"
# shellcheck disable=SC1090
source "$_DM_LIB" 2>/dev/null || true

# ovlog_append <event> <cwd> [extra_json_object]
# Appends one JSONL row to ~/.claude/logs/subagent-runs.jsonl:
#   {event, ts, project, orchestration_mode} + <extra_json_object>
# extra_json_object must be valid JSON (default "{}"); its keys are merged in,
# so callers add whatever their event needs (hook name, file path, ...)
# without this function knowing about them. Best-effort: a logging failure
# must never fail the caller's hook, so all errors are swallowed.
ovlog_append() {
  local event="$1" cwd="$2"
  # NOTE: deliberately not "${3:-{}}" — bash's parameter-expansion default
  # terminates at the FIRST unescaped "}", so a "{}" default silently
  # truncates there and leaves a stray "}" appended after the real $3 value,
  # producing malformed JSON no caller would catch without tracing it. Two
  # statements sidesteps the parser trap entirely.
  local extra_json="${3:-}"
  [[ -n "$extra_json" ]] || extra_json='{}'
  local config mode project ts log_dir

  config="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$cwd" 2>/dev/null)"
  mode="main-thread"
  [[ -n "$config" ]] && mode="$(jq -r '.orchestration_mode // "main-thread"' "$config" 2>/dev/null)"
  [[ -n "$mode" ]] || mode="main-thread"

  project="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log_dir="$HOME/.claude/logs"
  mkdir -p "$log_dir" 2>/dev/null || return 0

  jq -nc \
    --arg ev "$event" --arg ts "$ts" --arg project "$project" --arg mode "$mode" \
    --argjson extra "$extra_json" \
    '{event:$ev, ts:$ts, project:$project, orchestration_mode:$mode} + $extra' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# ovlog_main — the original Agent-dispatch logging behavior, unchanged.
ovlog_main() {
  local INPUT CWD CONFIG TIER SENS MODE
  local -a CONTEXTS
  local AGENT DESC DESC_TRIMMED PROJECT TS CONTEXTS_JSON LOG_DIR

  INPUT="$(cat 2>/dev/null || echo '{}')"

  CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "$CWD" ]] && CWD="$PWD"

  # Only in stack-initialized Tier 2+ projects.
  CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
  [[ -z "$CONFIG" ]] && return 0
  TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
  [[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
  [[ "$TIER" -lt 2 ]] && return 0

  SENS="$(jq -r '.sensitivity.level // "normal"' "$CONFIG" 2>/dev/null)"
  MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG" 2>/dev/null)"

  # Build the list of context flags that make this a logged dispatch.
  CONTEXTS=()
  if dm_has_mode "$CONFIG" "financial-code"; then
    CONTEXTS+=("financial-code")
  fi
  if dm_has_mode "$CONFIG" "schema-migration"; then
    CONTEXTS+=("schema-migration")
  fi
  if [[ "$SENS" == "confidential" ]]; then
    CONTEXTS+=("sensitivity:confidential")
  fi

  # Nothing high-sensitivity → silent (subagent-log.sh still logs the plain row).
  [[ "${#CONTEXTS[@]}" -eq 0 ]] && return 0

  AGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // env.CLAUDE_TOOL_INPUT_subagent_type // "unknown"' 2>/dev/null)"
  DESC="$(echo "$INPUT" | jq -r '.tool_input.description // env.CLAUDE_TOOL_INPUT_description // empty' 2>/dev/null)"
  DESC_TRIMMED="${DESC:0:200}"

  PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  CONTEXTS_JSON="$(printf '%s\n' "${CONTEXTS[@]}" | jq -R . | jq -sc .)"

  LOG_DIR="$HOME/.claude/logs"; mkdir -p "$LOG_DIR"
  if command -v jq &>/dev/null; then
    jq -nc \
      --arg ts "$TS" \
      --arg project "$PROJECT" \
      --arg agent "$AGENT" \
      --arg desc "$DESC_TRIMMED" \
      --arg mode "$MODE" \
      --argjson contexts "$CONTEXTS_JSON" \
      '{event:"override_context", ts:$ts, project:$project, agent:$agent,
        desc:$desc, orchestration_mode:$mode, contexts:$contexts}' \
      >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true
  fi

  return 0
}

# Only run as a hook when executed directly, never when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ovlog_main
  exit 0
fi
