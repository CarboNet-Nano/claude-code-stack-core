#!/usr/bin/env bash
# PreToolUse hook (matchers: Bash + Supabase MCP apply tools): gate schema
# migrations and production deploys behind human approval. ADR-007 follow-up #1.
#
# Why this exists: a schema change or production deploy is irreversible-ish and
# the riskiest thing an agent does. The approval-gates.json policy already
# *declares* pre-schema-change / pre-deploy gates at Tier 2, but nothing
# enforced them mechanically. This hook is that enforcement.
#
# Two detection paths (the load-bearing design choice — see ADR-007 risk R1):
#   1. MCP apply tools — Lade applies migrations via the Supabase MCP running as
#      `postgres`, NOT via Bash. A Bash-only gate misses the real apply path.
#      Matches tool names: *__apply_migration, *__deploy_edge_function, and
#      *__execute_sql whose SQL is DDL (create|alter|drop|grant|revoke|truncate).
#   2. Bash apply/deploy verbs — owner apply scripts (*.owner.ts), apply-*,
#      supabase db push / migration up, psql -f *.sql, netlify deploy,
#      vercel --prod.
#
# Decision (per ADR-007 §#1 + the Gemini CRITICAL): an `ask` is useless inside
# an autonomous workflow — no human answers it, and an unanswered ask that hangs
# or auto-allows defeats the gate against its primary threat (an autonomous
# agent doing a schema change). So:
#   - inside a workflow context  -> permissionDecision: "deny"
#   - on the interactive main thread -> permissionDecision: "ask"
# Workflow context is detected from the hook's transcript_path containing
# "/workflows/" (verified harness convention, 2026-06-20 spike — see PR notes;
# durability tracked as ADR-007 R6).
#
# IMPORTANT (ADR-007 R5): this is tactical defense-in-depth, NOT a guarantee.
# Bash writes via psql heredocs, interpreter calls, aliases, etc. can evade the
# patterns. A real non-bypassable chokepoint is owed a separate ADR.
#
# Best-effort: any internal failure exits 0 (never blocks normal work on error).
# summary: Gates schema migrations and production deploys behind human approval.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Only fence stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

# Respect an explicit off switch in stack-config.
RAW_MODE="$(jq -r '.schema_deploy_gate // "on"' "$CONFIG" 2>/dev/null)"
[[ "$RAW_MODE" == "off" ]] && exit 0

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
[[ -z "$TOOL_NAME" ]] && exit 0

# ── Detect whether this invocation is a schema-change / deploy ───────────────
TRIGGER=""   # set to a short reason string when a gated action is detected
KIND=""      # "schema" | "deploy"

is_ddl() {
  # True if the SQL text contains a DDL / privilege verb (not a plain read).
  printf '%s' "$1" | grep -qiE '\b(create|alter|drop|grant|revoke|truncate)\b'
}

case "$TOOL_NAME" in
  *__apply_migration)
    TRIGGER="Supabase MCP apply_migration (schema migration)"
    KIND="schema" ;;
  *__deploy_edge_function)
    TRIGGER="Supabase MCP deploy_edge_function (production deploy)"
    KIND="deploy" ;;
  *__execute_sql)
    SQL="$(echo "$INPUT" | jq -r '.tool_input.query // .tool_input.sql // empty' 2>/dev/null)"
    if [[ -n "$SQL" ]] && is_ddl "$SQL"; then
      TRIGGER="Supabase MCP execute_sql with DDL (schema change)"
      KIND="schema"
    fi ;;
  Bash)
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -z "$CMD" ]] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
    if [[ -n "$CMD" ]]; then
      # Schema-apply verbs. Owner apply scripts, apply-*, supabase migration up /
      # db push, psql -f <file>.sql. Deliberately verb-anchored so a plain read
      # (cat migration.sql, Read, psql -c "SELECT ...", list_migrations) is NOT
      # caught.
      if printf '%s' "$CMD" | grep -qiE '(\.owner\.ts\b|(^|[[:space:];&|])apply-[a-z0-9_-]+|supabase[[:space:]]+(db[[:space:]]+push|migration[[:space:]]+up)|psql[^|]*-f[[:space:]]+[^[:space:]]+\.sql)'; then
        TRIGGER="Bash schema-apply command"
        KIND="schema"
      # Deploy verbs.
      elif printf '%s' "$CMD" | grep -qiE '(netlify[[:space:]]+deploy|vercel([[:space:]]+[^|]*)?[[:space:]]--prod|supabase[[:space:]]+functions[[:space:]]+deploy)'; then
        TRIGGER="Bash production-deploy command"
        KIND="deploy"
      fi
    fi ;;
esac

[[ -z "$TRIGGER" ]] && exit 0

# ── Confirm the relevant approval gate is enabled ────────────────────────────
# Read approval-gates.json (installed copy preferred, repo copy as fallback).
GATES="$HOME/.claude/config/approval-gates.json"
[[ -f "$GATES" ]] || GATES="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/config/approval-gates.json"
if [[ -f "$GATES" ]]; then
  GATE_KEY="pre-schema-change"
  [[ "$KIND" == "deploy" ]] && GATE_KEY="pre-deploy"
  GATE_TIER="$(jq -r --arg k "$GATE_KEY" '.gates[$k].default_enabled_at_tier // 99' "$GATES" 2>/dev/null)"
  [[ "$GATE_TIER" =~ ^[0-9]+$ ]] || GATE_TIER=99
  [[ "$TIER" -lt "$GATE_TIER" ]] && exit 0
fi

# ── Determine workflow context from transcript_path (the discriminator) ──────
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
IN_WORKFLOW=0
[[ "$TRANSCRIPT" == */workflows/* ]] && IN_WORKFLOW=1

# ── ADR-044 D6b / Contract F helper: is this call already covered by a
# static permissions.deny rule? Project-sidecar only (the user-scope floor is
# class A/B path rules and never covers these tools). Reads `emitted.deny`,
# not `ledger` -- `emitted` is the last-compiled LIVE set; the ledger retains
# `removed:` entries that are no longer in force, and reading it would
# over-block. Best-effort: sidecar unreadable/unparseable/absent -> not
# covered (never fail closed on a missing file); a jq failure means "not
# covered", not "crash".
COVERING_RULE=""
if [[ -n "$CONFIG" ]]; then
  SIDECAR="$(dirname "$CONFIG")/permissions.stack.json"
  if [[ -f "$SIDECAR" ]]; then
    while IFS= read -r _s; do
      [[ -z "$_s" ]] && continue
      if [[ "$_s" == "$TOOL_NAME" ]]; then COVERING_RULE="$_s"; break; fi
      if [[ "$_s" == mcp__* && "$TOOL_NAME" == "${_s}__"* ]]; then COVERING_RULE="$_s"; break; fi
      if [[ "$_s" =~ ^Bash\((.*):\*\)$ ]]; then
        _prefix="${BASH_REMATCH[1]}"
        if [[ -n "${CMD:-}" && "$CMD" == "$_prefix"* ]]; then COVERING_RULE="$_s"; break; fi
      fi
    done < <(jq -r '.emitted.deny[]? // empty' "$SIDECAR" 2>/dev/null)
  fi
fi

if [[ "$IN_WORKFLOW" -eq 1 ]]; then
  DECISION="deny"
  REASON="stack schema-deploy-gate: $TRIGGER detected inside an autonomous workflow. A schema change or production deploy from an unattended workflow has no human to approve it, so the stack denies it (ADR-007 #1). Run this on the interactive main thread via /foreman, where the approval gate prompts a human. To disable this gate for the project, set schema_deploy_gate to \"off\" in .claude/stack-config.json."

  # Gap telemetry (ADR-044 D6): a deny here that no static rule would have
  # caught is coverage telemetry, not a gate. A mirrored deny (below) is NOT
  # a gap by definition and must never be logged here.
  if [[ -z "$COVERING_RULE" ]]; then
    mkdir -p "$HOME/.claude/logs" 2>/dev/null
    RULE_CANDIDATE="$TOOL_NAME"
    if [[ "$TOOL_NAME" == "Bash" && -n "${CMD:-}" ]]; then
      # Never log raw arguments -- a command like `psql "postgres://u:p@host/db"`
      # or `curl https://...?key=sk_live_...` must not leak the URL/credential
      # into the gap log. Only the leading verb token is used, and only if it
      # looks like a command name (no `=`, `/`, `:`, quotes) -- otherwise fall
      # back to a fixed placeholder so nothing arg-shaped is ever written to disk.
      _verb="$(printf '%s' "$CMD" | awk '{print $1}')"
      if [[ "$_verb" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        RULE_CANDIDATE="Bash(${_verb}:*)"
      else
        RULE_CANDIDATE="Bash(<unrecognized>:*)"
      fi
    fi
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "schema-deploy-gate" \
      --arg tool "$TOOL_NAME" --arg class_hint "identity" --arg rule "$RULE_CANDIDATE" \
      '{ts:$ts, hook:$hook, tool:$tool, class_hint:$class_hint, rule_candidate:$rule}' \
      >> "$HOME/.claude/logs/permissions-gap.jsonl" 2>/dev/null || true
  fi
else
  # D6b / Contract F: never ask for something a static permissions.deny rule
  # already covers -- deny-mirror instead, with the hook's own explanatory
  # reason preserved. This is NOT a gap: a mirror is, by definition, already
  # covered, so it is never appended to permissions-gap.jsonl.
  if [[ -n "$COVERING_RULE" ]]; then
    DECISION="deny"
    REASON="stack schema-deploy-gate: $TRIGGER. This is a gated action ($KIND). Confirm a human intends this change before it runs. A static permissions.deny rule ($COVERING_RULE) already blocks this, so approving here would not let it run. Do it outside the agent session, or add a waivers[] entry in .claude/permissions.stack.json and recompile."
  else
    DECISION="ask"
    REASON="stack schema-deploy-gate: $TRIGGER. This is a gated action ($KIND). Confirm a human intends this change before it runs."
  fi
fi

jq -nc --arg d "$DECISION" --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}' \
  2>/dev/null || true

exit 0
