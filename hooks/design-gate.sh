#!/usr/bin/env bash
# PreToolUse[Edit|Write] hook: superpowers design-before-code gate (ADR-021).
#
# When ultracode is ON, deny edits to SOURCE files unless an approved design
# marker exists. With ultracode OFF (the default) this hook is silent — it never
# blocks normal work. It always allows docs / config / tests so the spec, plan,
# and tests that satisfy the gate can be written freely.
#
# Reuses the ADR-019 §3 governance base: session-state read, the
# permissionDecision:deny shape, the same registration mechanism as
# irreversible-deny.sh. Fail-OPEN: any error allows the edit (a gate failure must
# never brick editing).
#
# Marker: ~/.claude/session-state/design-approved.json -> {"active": true},
# written by /plan or /loop-engineer on approval. The gate is the enforcement;
# /plan is the authoring path (ADR-021 reconciliation).
# summary: Denies Edit/Write on source files unless an approved design marker exists, only when ultracode is ON.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

# Gate is active only under ultracode (rides the autonomy risk dial).
loop_ultracode_active || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
FP="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
[[ -z "$FP" ]] && FP="${CLAUDE_TOOL_INPUT_file_path:-}"
[[ -z "$FP" ]] && exit 0

# Always allow docs and tests (you must be able to author the design + tests).
case "$FP" in
  */docs/*|docs/*|*/tests/*|tests/*|*/__tests__/*|__tests__/*|*.test.*|*.spec.*) exit 0 ;;
esac

# Only gate SOURCE files; allow everything else (markdown, config, data, ...).
case "$FP" in
  *.sh|*.bash|*.py|*.ts|*.tsx|*.js|*.jsx|*.go|*.rs|*.rb|*.java|*.c|*.h|*.cpp|*.php|*.sql) : ;;
  *) exit 0 ;;
esac

# Approved-design marker present? -> allow.
# Phase-3 (ADR-023): the marker may scope approval to paths via approved_paths
# (a glob array). Match rules:
#   - approved_paths present + non-empty -> allow only if the target matches a glob
#   - bare {"active":true} (no/empty approved_paths) -> allow all source (legacy)
STATE_DIR="${LOOP_STATE_DIR:-${HOME:-/tmp}/.claude/session-state}"
# Marker is per-session (ADR-020 pattern): concurrent sessions must not clobber
# each other's approval through one shared file. Resolve the session id from the
# hook payload (fallback to the in-session env) and sanitize it for use in a
# filename (blocks path traversal).
#
# When a session id resolves, the per-session marker is authoritative and the
# shared unscoped file is NOT consulted — otherwise one session's global approval
# would leak into another that never approved anything. The legacy unscoped file
# is honored only when no session id is resolvable (back-compat for markers
# written before per-session scoping, and for runtimes that pass no session_id).
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -z "$_SID" ]] && _SID="${CLAUDE_CODE_SESSION_ID:-}"
_SID="${_SID//[^A-Za-z0-9._-]/_}"
if [[ -n "$_SID" ]]; then
  MARKER="$STATE_DIR/design-approved.$_SID.json"
else
  MARKER="$STATE_DIR/design-approved.json"
fi
if [[ -f "$MARKER" ]] && [[ "$(jq -r '.active // false' "$MARKER" 2>/dev/null)" == "true" ]]; then
  _NPATHS="$(jq -r '(.approved_paths // []) | length' "$MARKER" 2>/dev/null)"
  if [[ -z "$_NPATHS" || "$_NPATHS" == "0" ]]; then
    exit 0   # legacy session-wide approval
  fi
  # Path-scoped: allow iff FP matches an approved glob (case-statement glob match).
  # Two silent never-match traps kept biting marker authors (SpecOps 2026-07-12):
  #   1. bare relative globs ("lib/data/readings.ts") never match the absolute
  #      paths hooks receive -> also try the glob with a "*/" prefix (a case
  #      pattern's "*" crosses "/", so this matches the path at any depth).
  #   2. "[deviceId]"-style Next.js segments are bash char classes -> escape
  #      "[" "]" by default; set {"glob_char_classes":true} in the marker to
  #      opt back into raw char-class matching.
  _RAWCC="$(jq -r '.glob_char_classes // false' "$MARKER" 2>/dev/null)"
  _ALMOST=""
  while IFS= read -r _glob; do
    [[ -z "$_glob" ]] && continue
    _pat="$_glob"
    if [[ "$_RAWCC" != "true" ]]; then
      _pat="${_pat//\[/\\[}"; _pat="${_pat//\]/\\]}"
    fi
    # shellcheck disable=SC2254
    case "$FP" in
      $_pat) exit 0 ;;
    esac
    if [[ "$_pat" != /* && "$_pat" != \** ]]; then
      # shellcheck disable=SC2254
      case "$FP" in
        */$_pat) exit 0 ;;
      esac
    fi
    # Near-miss diagnosis for the deny message: char-class opt-in is the one
    # normalization we skip, so name the glob that would match with [ ] literal.
    if [[ "$_RAWCC" == "true" && "$_glob" == *\[* ]]; then
      _esc="${_glob//\[/\\[}"; _esc="${_esc//\]/\\]}"
      # shellcheck disable=SC2254
      case "$FP" in
        $_esc|*/$_esc) _ALMOST="'$_glob' would match if [ ] were literal, but glob_char_classes is true" ;;
      esac
    fi
  done < <(jq -r '.approved_paths[]?' "$MARKER" 2>/dev/null)
  # Marker active but no glob matched -> deny with a scoped diagnostic (what was
  # tried against what) instead of the generic no-design message.
  _GLOBS="$(jq -r '[.approved_paths[]?] | join(", ")' "$MARKER" 2>/dev/null)"
  _WHY="design-before-code (ADR-021/023): approved design does not cover this file. target=$FP approved_paths=[$_GLOBS]."
  [[ -n "$_ALMOST" ]] && _WHY="$_WHY Near miss: $_ALMOST."
  _WHY="$_WHY Extend approved_paths in $MARKER — relative globs match at any depth, and [ ] are literal unless glob_char_classes=true."
  jq -nc --arg r "$_WHY" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}' 2>/dev/null || true
  exit 0
fi

# Ultracode on + source file + no approved design -> deny.
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
  permissionDecisionReason:"design-before-code (ADR-021): ultracode is ON and no approved design exists for this work. Write a spec/plan (docs/superpowers/specs|plans or an ADR) and approve it via /plan — which sets ~/.claude/session-state/design-approved.json — before editing source. Docs, tests, and config are always editable."}}' \
  2>/dev/null || true
exit 0
