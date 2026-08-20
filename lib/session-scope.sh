#!/usr/bin/env bash
# lib/session-scope.sh — sourceable library resolving "when did this session
# start" (ADR-072 D2). Every function is fail-safe: never crashes the caller,
# prints empty (or an honest "unknown" object) on any error — loop_lib.sh's
# contract, ADR-066 D1's "one shared implementation" convention.
#
# ss_session_id                      -> resolved session id, or empty
# ss_marker_path [<repo_root>]       -> newest marker path for the repo, or empty
# ss_scope_json  [<repo_root>]       -> the scope object below (never fails)
# ss_diff_range  [<repo_root>]       -> "<sha>..HEAD", or empty
# ss_last_close_sha [<repo_root>]    -> head_sha_at_close from the last session log
#
# Resolution ladder for ss_scope_json (first hit wins), each rung below
# "exact" carries an honest note wherever its number is printed:
#   1. marker            exact        newest session-marker for this repo
#   2. session-start-ts  approximate  ~/.claude/state/session-start.txt -> rev-list
#   3. handoff-ts        approximate  .claude/next_prompt.md's `_Written:` line -> rev-list
#   4. reflog            approximate  HEAD@{1}, else HEAD~5
#   5. none              unknown      nothing resolvable

set -uo pipefail

_SS_HOME="${HOME:-/tmp}"

# Repo-slug: duplicated (not shared) from hooks/session-marker.sh, per the
# session-start-handoff.sh / sandbox-policy-session-start.sh precedent
# ("extract to lib/ or duplicate with a comment; do not invent a third") --
# keep this in sync with that file if either changes.
_ss_repo_slug() {
  local root="$1" slug
  slug="$(printf '%s' "$root" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_')"
  if [[ ${#slug} -gt 100 ]]; then
    slug="${slug: -100}"
  fi
  printf '%s' "$slug"
}

_ss_repo_root() {
  local root="${1:-$PWD}"
  git -C "$root" rev-parse --show-toplevel 2>/dev/null
  return 0
}

# Newest marker file for a repo. Prefers one matching $CLAUDE_CODE_SESSION_ID
# when that env var is set (best-effort; hooks export it, never assumed).
ss_marker_path() {
  local root; root="$(_ss_repo_root "${1:-$PWD}")"
  [[ -z "$root" ]] && { echo ""; return 0; }
  local slug; slug="$(_ss_repo_slug "$root")"
  local dir="$_SS_HOME/.claude/state/session-markers/$slug"
  [[ -d "$dir" ]] || { echo ""; return 0; }

  if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    local safe_sid="${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9._-]/_}"
    local want="$dir/$safe_sid.json"
    [[ -f "$want" ]] && { echo "$want"; return 0; }
  fi

  local newest
  newest="$(ls -1t "$dir"/*.json 2>/dev/null | head -1)"
  echo "${newest:-}"
  return 0
}

ss_session_id() {
  if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
    return 0
  fi
  local m; m="$(ss_marker_path "${1:-$PWD}")"
  [[ -z "$m" ]] && { echo ""; return 0; }
  jq -r '.session_id // empty' "$m" 2>/dev/null
  return 0
}

# Portable ISO-8601 UTC -> epoch seconds. Empty on any failure.
_ss_iso_to_epoch() {
  local ts="${1:-}"
  [[ -z "$ts" ]] && { echo ""; return 0; }
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null && return 0
  echo ""
  return 0
}

# Portable file-mtime -> ISO-8601 UTC. Empty on any failure.
_ss_mtime_iso() {
  local f="${1:-}"
  [[ -f "$f" ]] || { echo ""; return 0; }
  date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$f" 2>/dev/null && return 0
  echo ""
  return 0
}

ss_scope_json() {
  local root; root="$(_ss_repo_root "${1:-$PWD}")"

  if [[ -z "$root" ]]; then
    jq -n '{source:"none", confidence:"unknown", session_id:"", repo:"",
            started_at:"", start_sha:"", branch_at_start:"",
            note:"not a git repository"}'
    return 0
  fi

  # Rung 1: marker.
  local marker; marker="$(ss_marker_path "$root")"
  if [[ -n "$marker" && -f "$marker" ]]; then
    local sid started sha branch
    sid="$(jq -r '.session_id // empty' "$marker" 2>/dev/null)"
    started="$(jq -r '.started_at // empty' "$marker" 2>/dev/null)"
    sha="$(jq -r '.head_sha_at_start // empty' "$marker" 2>/dev/null)"
    branch="$(jq -r '.branch_at_start // empty' "$marker" 2>/dev/null)"
    if [[ -n "$sha" ]]; then
      jq -n --arg sid "$sid" --arg repo "$root" --arg started "$started" \
            --arg sha "$sha" --arg branch "$branch" \
        '{source:"marker", confidence:"exact", session_id:$sid, repo:$repo,
          started_at:$started, start_sha:$sha, branch_at_start:$branch, note:""}'
      return 0
    fi
  fi

  # Rung 2: session-start.txt (known-stale on resume/compact -- approximate).
  local sst="$_SS_HOME/.claude/state/session-start.txt"
  if [[ -f "$sst" ]]; then
    local ts sha
    ts="$(tr -d '[:space:]' < "$sst" 2>/dev/null)"
    if [[ -n "$ts" ]]; then
      sha="$(git -C "$root" rev-list -1 --before="$ts" HEAD 2>/dev/null)"
      if [[ -n "$sha" ]]; then
        jq -n --arg repo "$root" --arg started "$ts" --arg sha "$sha" \
          '{source:"session-start-ts", confidence:"approximate", session_id:"",
            repo:$repo, started_at:$started, start_sha:$sha, branch_at_start:"",
            note:"session start time may be stale (known issue)"}'
        return 0
      fi
    fi
  fi

  # Rung 3: the last handoff's `_Written:` line, else its mtime.
  local handoff="$root/.claude/next_prompt.md"
  if [[ -f "$handoff" ]]; then
    local ts sha
    ts="$(grep -m1 '^_Written:' "$handoff" 2>/dev/null | sed -E 's/^_Written:[[:space:]]*//; s/_[[:space:]]*$//')"
    [[ -z "$ts" ]] && ts="$(_ss_mtime_iso "$handoff")"
    if [[ -n "$ts" ]]; then
      sha="$(git -C "$root" rev-list -1 --before="$ts" HEAD 2>/dev/null)"
      if [[ -n "$sha" ]]; then
        jq -n --arg repo "$root" --arg started "$ts" --arg sha "$sha" \
          '{source:"handoff-ts", confidence:"approximate", session_id:"",
            repo:$repo, started_at:$started, start_sha:$sha, branch_at_start:"",
            note:"measured from the last handoff, not this session'"'"'s start"}'
        return 0
      fi
    fi
  fi

  # Rung 4: reflog. `--verify -q` is required here: plain `git rev-parse
  # <ref>` echoes an unresolvable ref back LITERALLY instead of failing
  # (a real git quirk), which would otherwise leak the string "HEAD~5" out
  # as if it were a resolved sha.
  local sha
  sha="$(git -C "$root" rev-parse --verify -q 'HEAD@{1}' 2>/dev/null)"
  [[ -z "$sha" ]] && sha="$(git -C "$root" rev-parse --verify -q 'HEAD~5' 2>/dev/null)"
  if [[ -n "$sha" ]]; then
    jq -n --arg repo "$root" --arg sha "$sha" \
      '{source:"reflog", confidence:"approximate", session_id:"", repo:$repo,
        started_at:"", start_sha:$sha, branch_at_start:"",
        note:"start point guessed from git history"}'
    return 0
  fi

  # Rung 5: nothing resolvable.
  jq -n --arg repo "$root" \
    '{source:"none", confidence:"unknown", session_id:"", repo:$repo,
      started_at:"", start_sha:"", branch_at_start:"",
      note:"session start unknown — reviewing uncommitted changes only"}'
  return 0
}

ss_diff_range() {
  local root="${1:-$PWD}"
  local scope; scope="$(ss_scope_json "$root" 2>/dev/null)"
  local sha; sha="$(printf '%s' "$scope" | jq -r '.start_sha // empty' 2>/dev/null)"
  [[ -z "$sha" ]] && { echo ""; return 0; }
  printf '%s..HEAD' "$sha"
  return 0
}

# ADR-074 D5: logs are per-session under .claude/session-logs/, with the
# pre-D5 single file still honoured. This is a scalar question, so the newest
# document wins — see _scl_resolve_log_path in scripts/session-close.sh, which
# resolves identically.
# Sub-second mtime — whole seconds tie when two sessions close inside the same
# second, which silently resolves "newest" to whichever the glob yielded first.
_ss_mtime_precise() {
  local f="${1:-}" m
  [[ -f "$f" ]] || { echo "0"; return 0; }
  m="$(stat -f '%Fm' "$f" 2>/dev/null)" && [[ -n "$m" ]] && { printf '%s' "$m"; return 0; }
  m="$(stat -c '%.9Y' "$f" 2>/dev/null)" && [[ -n "$m" ]] && { printf '%s' "$m"; return 0; }
  m="$(date -u -r "$f" +%s 2>/dev/null)" && [[ -n "$m" ]] && { printf '%s' "$m"; return 0; }
  echo "0"
  return 0
}

ss_resolve_log_path() {
  local root; root="$(_ss_repo_root "${1:-$PWD}")"
  [[ -z "$root" ]] && { echo ""; return 0; }
  local newest="" newest_m="" f m
  for f in "$root/.claude/session-logs"/*.json "$root/.claude/session-log.json"; do
    [[ -f "$f" ]] || continue
    m="$(_ss_mtime_precise "$f")"
    if [[ -z "$newest" ]] || awk -v a="$m" -v b="$newest_m" 'BEGIN{exit !(a>b)}'; then
      newest="$f"; newest_m="$m"
    fi
  done
  echo "${newest:-}"
  return 0
}

ss_last_close_sha() {
  local log; log="$(ss_resolve_log_path "${1:-$PWD}")"
  [[ -n "$log" && -f "$log" ]] || { echo ""; return 0; }
  jq -r '.head_sha_at_close // empty' "$log" 2>/dev/null
  return 0
}
