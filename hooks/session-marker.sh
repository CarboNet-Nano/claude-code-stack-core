#!/usr/bin/env bash
# SessionStart hook (ADR-072 D2) — write-once-per-logical-session marker.
#
# hooks/session-start-handoff.sh:26 stamps ~/.claude/state/session-start.txt
# on EVERY SessionStart fire, including resume/compact, which produces a
# documented-wrong "session start" figure (five handoffs record the
# undercount). This hook fixes that for new consumers (lib/session-scope.sh)
# WITHOUT touching session-start-handoff.sh or session-start.txt's existing
# semantics — /team-status and /carbonight's team block depend on those staying
# exactly as they are (tested by tests/test-merger-session-hooks.sh).
#
# stdin  : SessionStart hook JSON — { session_id, source, cwd, ... }
# stdout : nothing, ever (hook output is invisible to users anyway)
# exit   : 0, always
# writes : ~/.claude/state/session-markers/<repo-slug>/<session_id>.json
#
# Write-once rule (the entire fix): overwrite iff source is startup or clear
# (a new logical session). NEVER on resume or compact (same session
# continuing) — if a marker already exists for this session id, leave it.
#
# summary: Write-once-per-logical-session marker so session start time survives resume/compact, unlike session-start.txt.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# No session id -> nothing to key the marker on. Exit quietly (malformed or
# empty stdin lands here too).
[[ -z "$SESSION_ID" ]] && exit 0

GIT_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
[[ -z "$GIT_ROOT" ]] && exit 0   # not a git repo -- write nothing

# repo-slug: "/" -> "_", every char outside [A-Za-z0-9._-] -> "_", truncated
# to the last 100 chars. Not a hash: a debuggable filename beats a short one.
# Duplicated (not shared) in lib/session-scope.sh's _ss_repo_slug so the
# reader always agrees with the writer -- same precedent as
# hooks/sandbox-policy-session-start.sh duplicating git_root()/
# find_wrapped_repo() from session-start-handoff.sh ("extract to lib/ or
# duplicate with a comment; do not invent a third"). Keep both in sync.
SLUG="$(printf '%s' "$GIT_ROOT" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_')"
if [[ ${#SLUG} -gt 100 ]]; then
  SLUG="${SLUG: -100}"
fi

STATE_HOME="${HOME:-/tmp}/.claude/state"
MARKER_DIR="$STATE_HOME/session-markers/$SLUG"
mkdir -p "$MARKER_DIR" 2>/dev/null || exit 0

SAFE_SID="${SESSION_ID//[^A-Za-z0-9._-]/_}"
MARKER_FILE="$MARKER_DIR/$SAFE_SID.json"

case "$SOURCE" in
  startup|clear)
    : # new logical session -- fall through and (re)write
    ;;
  *)
    # resume, compact, or any unrecognized source: never overwrite an
    # existing marker for this session id. If none exists yet (e.g. this
    # hook was only just installed mid-session), write one so later rungs
    # of the resolution ladder have something exact to find.
    [[ -f "$MARKER_FILE" ]] && exit 0
    ;;
esac

BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null)"
HEAD_SHA="$(git -C "$GIT_ROOT" rev-parse --verify -q HEAD 2>/dev/null)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

TMP="$(mktemp "$MARKER_FILE.tmp.XXXXXX" 2>/dev/null)" || exit 0
jq -n \
  --arg sid "$SESSION_ID" --arg src "$SOURCE" --arg started "$STARTED_AT" \
  --arg repo "$GIT_ROOT" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" \
  '{version:1, session_id:$sid, source:$src, started_at:$started, repo:$repo,
    branch_at_start:$branch, head_sha_at_start:$sha}' \
  > "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
mv "$TMP" "$MARKER_FILE" 2>/dev/null || { rm -f "$TMP"; exit 0; }

# Prune: markers older than 30 days go first; if more than 200 remain,
# delete oldest-first down to 200. Best-effort, never fails the hook.
find "$MARKER_DIR" -maxdepth 1 -name '*.json' -mtime +30 -delete 2>/dev/null || true
COUNT="$(find "$MARKER_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT > 200 )); then
  ls -1t "$MARKER_DIR"/*.json 2>/dev/null | tail -n +201 | xargs -r rm -f 2>/dev/null || true
fi

exit 0
