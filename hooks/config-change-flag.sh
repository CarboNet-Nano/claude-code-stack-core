#!/usr/bin/env bash
# ConfigChange hook (issue #112): fires when a configuration file changes
# during a session (docs matcher sources: user_settings, project_settings,
# local_settings, policy_settings, skills). Diffs the changed file's content
# against a locally-stored "last known-good" sha256 baseline
# (~/.claude/state/config-change-baseline/*.sha256 — same ~/.claude/state
# directory session-start-handoff.sh already writes into) and warns when the
# content changed since the last sighting.
#
# Sanctioned-edit signal: neither of this stack's two config-editing skills
# leaves a durable, checkable marker for THIS file. `default-edit`/
# `stack-config` only append `change_history` inside `.claude/stack-config.json`
# itself (a file ConfigChange never fires for — Claude Code's native event
# covers settings/policy/skill files, not this stack's own app-level config).
# `native-settings-edit` writes settings.json through `scripts/lib/
# settings_lock.py`'s `<settings>.lock`, but that lock file's mtime is only
# set once at first creation (never rewritten on subsequent locked updates),
# so it cannot distinguish "the sanctioned writer just ran" from "it ran
# once, years ago." Rather than invent a new marker, every flagged change is
# honestly logged as sanctioned:"unverified" — this hook's real value is the
# baseline-drift detection and audit trail, not a false claim of provenance.
#
# Pure observability (H3): ConfigChange has decision control (exit 2 /
# decision:"block") but this hook never blocks — always exit 0, no decision
# field.
# summary: Flags config-file drift against a stored sha256 baseline and logs an audit row; never blocks the change.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"
SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
SOURCE="$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null)"
FILE_PATH="$(echo "$INPUT" | jq -r '.file_path // empty' 2>/dev/null)"

# Nothing to diff without a concrete file.
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

hash_file() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

NEW_HASH="$(hash_file "$FILE_PATH")"
[[ -z "$NEW_HASH" ]] && exit 0

BASELINE_DIR="$HOME/.claude/state/config-change-baseline"
mkdir -p "$BASELINE_DIR" 2>/dev/null || exit 0
# Hash of the path (not a lexical substitution) so distinct paths can never
# collide on one baseline file — "${FILE_PATH//\//_}" let /a_b/c and /a/b_c
# share an entry (see security-report.md 2026-08-04, HIGH).
SAFE_NAME="$(hash_file <(printf '%s' "$FILE_PATH") 2>/dev/null)"
[[ -z "$SAFE_NAME" ]] && exit 0
BASELINE_FILE="$BASELINE_DIR/${SAFE_NAME}.sha256"

PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
LOG_DIR="$HOME/.claude/logs"

log_config_change_event() {
  local baseline_state="$1"
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  jq -nc \
    --arg ts "$TS" --arg project "$PROJECT" --arg sid "$SID" \
    --arg source "$SOURCE" --arg path "$FILE_PATH" --arg baseline "$baseline_state" \
    '{event:"config_change_flag", ts:$ts, project:$project, session_id:$sid,
      source:$source, file_path:$path, sanctioned:"unverified", baseline:$baseline}' \
    >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true
}

if [[ ! -f "$BASELINE_FILE" ]]; then
  # First sighting: still logged, so a malicious first edit can't become the
  # trusted baseline with zero audit trail (see security-report.md
  # 2026-08-04, HIGH). Nothing to diff against yet, so no stderr warning.
  log_config_change_event "first_sighting"
  echo "$NEW_HASH" > "$BASELINE_FILE" 2>/dev/null || true
  exit 0
fi

OLD_HASH="$(cat "$BASELINE_FILE" 2>/dev/null || echo '')"
[[ "$OLD_HASH" == "$NEW_HASH" ]] && exit 0

# Content actually changed since the last known-good baseline.
log_config_change_event "drift"

# Strip control chars (incl. ESC, which drives ANSI/OSC sequences) from the
# DISPLAY copy only — FILE_PATH/SOURCE above are untouched, so hashing and
# baseline lookup still see the real values (security-report.md 2026-08-04, LOW).
DISPLAY_PATH="$(printf '%s' "$FILE_PATH" | tr -d '[:cntrl:]')"
DISPLAY_SOURCE="$(printf '%s' "$SOURCE" | tr -d '[:cntrl:]')"
echo "Config change detected outside a verified path: $DISPLAY_PATH (source: $DISPLAY_SOURCE). If this wasn't via /default-edit, /stack-config, or /native-settings-edit, review it." >&2

echo "$NEW_HASH" > "$BASELINE_FILE" 2>/dev/null || true

exit 0
