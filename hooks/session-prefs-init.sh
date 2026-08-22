#!/usr/bin/env bash
# SessionStart hook: materialize the active session preferences into one file
# that everything else reads — hooks/brevity-drift.sh and the assistant itself.
#
# Resolves precedence (lowest -> highest): built-in defaults < ~/.claude
# stack-defaults.session_prefs_defaults < project stack-config.session_prefs.
# /session then overwrites this file with live, per-session choices (source
# "session"), which therefore win for the rest of the session. Because this
# runs at every SessionStart, per-session ad-hoc choices are ephemeral: a new
# session starts back at the configured defaults.
#
# Fail-safe: any problem -> exit 0, leaving whatever file already exists. The
# worst case is stale-but-valid prefs, never a broken turn.
# summary: Materializes the active session preferences into one file that other hooks and the assistant read.

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
OUT="$STATE_DIR/current-prefs.json"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Dedupe flags are session-scoped (passive_suggest.<session_id>.nudged), so a
# new session simply starts with no flag. Prune stale flags (>1 day) so they
# don't accumulate, and clear any legacy machine-global flag from older builds.
find "$STATE_DIR" -maxdepth 1 -name 'passive_suggest.*.nudged' -mtime +0 -delete 2>/dev/null || true
rm -f "$STATE_DIR/passive_suggest.nudged" 2>/dev/null || true

# ADR-033: model-fit-receipt.<session_id>.printed is the same per-session,
# ephemeral dedupe idiom — prune stale ones the same way.
find "$STATE_DIR" -maxdepth 1 -name 'model-fit-receipt.*.printed' -mtime +0 -delete 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$CWD" ] && CWD="$PWD"

# Built-in baseline (matches the schema defaults).
BUILTIN='{"communication_style":"balanced","model_effort":"balanced","explanation_verbosity":"normal","orchestration_mode":"main-thread","cost_alert_sensitivity":"normal","passive_suggest":true,"simple_talk":"off","model_fit_receipt":"on","auto_offer_loop":true,"auto_offer_advisor_pair":true}'

# Global defaults layer.
G='{}'
GLOBAL="$HOME/.claude/stack-defaults.json"
[ -f "$GLOBAL" ] && G="$(jq -c '.session_prefs_defaults // {}' "$GLOBAL" 2>/dev/null || echo '{}')"

# Project layer (nearest .claude/stack-config.json via the shared finder).
P='{}'
FINDER="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh"
if [ -x "$FINDER" ]; then
  CONFIG="$(bash "$FINDER" "$CWD" 2>/dev/null || true)"
  [ -n "$CONFIG" ] && [ -f "$CONFIG" ] && \
    P="$(jq -c '.session_prefs // {}' "$CONFIG" 2>/dev/null || echo '{}')"
fi

# Merge: built-in <- global <- project (later wins), then stamp provenance.
RESOLVED="$(jq -cn --argjson b "$BUILTIN" --argjson g "$G" --argjson p "$P" \
  '$b + $g + $p + {source:"config", set_at:(now|todateiso8601)}' 2>/dev/null)" || exit 0

printf '%s\n' "$RESOLVED" > "$OUT" 2>/dev/null || true
exit 0
