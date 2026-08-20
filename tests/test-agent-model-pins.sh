#!/usr/bin/env bash
# Regression guard for issue #21 (F1 + F2): fully-qualified anthropic model
# pins in agents/*.md break every custom subagent when the parent Claude Code
# session runs in 1M-context mode — the harness appends the parent's `[1m]`
# suffix to the pinned id (`anthropic/claude-opus-4-8` -> invalid
# `anthropic/claude-opus-4-8[1m]`). Fixed in b9c9b37 (bare aliases) and
# dbc65b0 (PascalCase tools:); see docs/runbooks/stack-cloud-overrides.md.
#
# This is a static check only — it cannot reproduce the 1M-boot spawn bug
# (that requires a fresh Claude Code session per the runbook). It exists to
# stop a *new* agents/*.md file from reintroducing a fully-qualified pin or a
# lowercase tools: list.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"

[[ -d "$AGENTS_DIR" ]] || { echo "FAIL: agents/ not found at $AGENTS_DIR"; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

is_bare_alias() {
  # bare Claude Code alias (opus/sonnet/haiku/inherit) or an ollama/* id.
  # Anything else containing a slash is a fully-qualified provider/model id,
  # which is the shape that breaks under a 1M-context parent.
  case "$1" in
    ollama/*) return 0 ;;
    */*) return 1 ;;
    *) return 0 ;;
  esac
}

for f in "$AGENTS_DIR"/*.md; do
  name="$(basename "$f")"

  model_line="$(grep -m1 '^model:' "$f" | sed 's/^model: *//')"
  if [[ -n "$model_line" ]]; then
    if is_bare_alias "$model_line"; then
      pass "$name model: '$model_line' is a bare alias or ollama id"
    else
      fail "$name model: '$model_line' is a fully-qualified pin (1M-context parent will append [1m] and break the spawn)"
    fi
  fi

  esc_line="$(grep -m1 '^escalation_model:' "$f" | sed 's/^escalation_model: *//')"
  if [[ -n "$esc_line" ]]; then
    if is_bare_alias "$esc_line"; then
      pass "$name escalation_model: '$esc_line' is a bare alias or ollama id"
    else
      fail "$name escalation_model: '$esc_line' is a fully-qualified pin (1M-context parent will append [1m] and break the spawn)"
    fi
  fi

  # tools: must be a single-line CSV of PascalCase tool names, never a YAML
  # list (`- read`) or lowercase names — a lowercase/list tools: block
  # resolves to an empty toolset and the agent hallucinates instead of
  # calling real tools (F2, fixed in dbc65b0).
  tools_line_no="$(grep -n '^tools:' "$f" | head -1 | cut -d: -f1)"
  if [[ -n "$tools_line_no" ]]; then
    tools_val="$(sed -n "${tools_line_no}p" "$f" | sed 's/^tools: *//')"
    next_line_no=$((tools_line_no + 1))
    next_line="$(sed -n "${next_line_no}p" "$f")"

    if [[ -z "$tools_val" ]]; then
      fail "$name tools: has no inline value (YAML list style is not PascalCase-CSV; see F2 in the runbook)"
    elif [[ "$next_line" =~ ^[[:space:]]*-[[:space:]] ]]; then
      fail "$name tools: is followed by a YAML list item ('$next_line') instead of being a single CSV line"
    else
      bad_item=""
      IFS=',' read -ra items <<< "$tools_val"
      for item in "${items[@]}"; do
        trimmed="$(echo "$item" | sed 's/^ *//;s/ *$//')"
        if [[ ! "$trimmed" =~ ^[A-Z][A-Za-z]*$ ]]; then
          bad_item="$trimmed"
          break
        fi
      done
      if [[ -n "$bad_item" ]]; then
        fail "$name tools: contains non-PascalCase item '$bad_item'"
      else
        pass "$name tools: '$tools_val' is PascalCase CSV"
      fi
    fi
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
