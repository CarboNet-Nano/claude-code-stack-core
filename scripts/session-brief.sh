#!/usr/bin/env bash
# scripts/session-brief.sh — the shared boot-side mechanics behind /carbonet
# and /goodmorning (ADR-072 D1). One implementation, called by both skills
# (ADR-066 D1) — never two prose copies in two SKILL.md files.
#
# Stage 2 (ADR-072 D13): W1 (banner), W3's mechanical half (since), W6
# (cost), G3 (alerts), G4 (todos). Stage 3 adds `running` (G2) — it
# RE-DERIVES live state (loops/pids/rescue branches) from the session
# log's `to_recheck` identifiers; it never reads a status back out of the
# log (D8a). NOT implemented yet, by design, not by omission:
#   - `queue` (W4/G1) — the improvement queue itself is Stage 4. No queue
#     code of any kind lives here; the boot skills simply have nothing to
#     call yet, so the Queue: section is absent by construction.
#
# Every subcommand prints text by default, `--json` on request, EXITS 0
# ALWAYS, and prints EMPTY STDOUT when there is nothing honest to say — the
# caller's cue to omit the line entirely (the /goodmorning 6c/6f pattern,
# generalized). Never mutates anything, never makes an irreversible call.
#
# Usage:
#   session-brief.sh banner  [--format box|line] [--repo PATH] [--plain]
#   session-brief.sh since   [--json] [--max-commits 12]
#   session-brief.sh cost    [--since-days 1] [--json] [--plain]
#   session-brief.sh alerts  [--json]
#   session-brief.sh todos   [--json]
#   session-brief.sh running [--json]
#   session-brief.sh all     --json
#
# Global flags: --repo PATH, --plain, --timeout SECS (default 4s connect /
# 6s total, matching scripts/org-check.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_HOME="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}"

resolve_lib() {
  local rel="$1" installed="$CLAUDE_HOME/$1" repo="$REPO_ROOT_SRC/$1"
  [[ -f "$installed" ]] && { printf '%s' "$installed"; return; }
  printf '%s' "$repo"
}

# Unlike scripts/org-check.sh (a real readiness gate, entitled to exit 2 on
# a tool failure) and scripts/session-close.sh, this script's whole contract
# is "EXITS 0 ALWAYS, empty stdout when there is nothing honest to say" —
# it is purely advisory boot content and must never brick a boot. A missing
# `jq` degrades every subcommand to empty output below, not a hard failure.
JQ_MISSING=0
command -v jq >/dev/null 2>&1 || JQ_MISSING=1

# _sb_safe_source <lib-path> <fn1> [<fn2> ...] — same contract as
# scripts/org-check.sh's _scv_safe_source (not shared: each caller already
# needs its own copy for sourcing OTHER libs too, per that file's own note).
_sb_safe_source() {
  local lib="$1"; shift
  # shellcheck disable=SC1090
  source "$lib" 2>/dev/null
  local rc=$?
  (( rc == 0 )) || return 1
  local fn
  for fn in "$@"; do
    declare -f "$fn" >/dev/null 2>&1 || return 1
  done
  return 0
}

# shellcheck disable=SC1090
source "$(resolve_lib lib/session-scope.sh)" 2>/dev/null || true
# shellcheck disable=SC1090
source "$(resolve_lib skills/loop-engineer/loop_lib.sh)" 2>/dev/null || true

# ADR-072 D10: fail-SAFE degradation, same as org-check.sh. If the guard lib
# is unresolvable or fails partway, sanitize_field/sanitize_path become
# unconditional placeholders here too — no second copy of the detection
# logic (there is no detection in that mode, which is why it's safe).
GUARD_DEGRADED=0
if ! _sb_safe_source "$(resolve_lib lib/plain-text-guard.sh)" sanitize_field sanitize_path; then
  GUARD_DEGRADED=1
  sanitize_field() { printf '%s' "${3:-(from your settings)}"; }
  sanitize_path()  { printf '%s' "${3:-(path hidden)}"; }
fi

REPO_PATH=""
PLAIN=0
TIMEOUT_CONNECT=4
TIMEOUT_TOTAL=6

usage() {
  cat <<'EOF'
session-brief.sh banner  [--format box|line] [--repo PATH] [--plain]
session-brief.sh since   [--json] [--max-commits 12]
session-brief.sh cost    [--since-days 1] [--json] [--plain]
session-brief.sh alerts  [--json]
session-brief.sh todos   [--json]
session-brief.sh running [--json]
session-brief.sh all     --json
EOF
}

_sb_root() {
  local p="${REPO_PATH:-$PWD}"
  git -C "$p" rev-parse --show-toplevel 2>/dev/null
}

# ------------------------------------------------------------------- banner
cmd_banner() {
  local fmt="box"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) fmt="${2:-box}"; shift 2 ;;
      --format=*) fmt="${1#*=}"; shift ;;
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --plain) PLAIN=1; shift ;;
      *) echo "session-brief: banner: unknown argument: $1" >&2; return 2 ;;
    esac
  done

  local root; root="$(_sb_root)"
  local dateline; dateline="$(date '+%A %b %-d' 2>/dev/null)"
  [[ -z "$dateline" ]] && dateline="$(date '+%A %b %d' 2>/dev/null)"

  if [[ -z "$root" ]]; then
    if [[ "$fmt" == "line" ]]; then
      printf '%s\n' "$dateline"
    else
      printf '  ╭──────────────────────────────────────────────╮\n'
      printf '  │  %-46s│\n' "$dateline"
      printf '  ╰──────────────────────────────────────────────╯\n'
    fi
    return 0
  fi

  local repo_base; repo_base="$(basename "$root")"
  local branch; branch="$(git -C "$root" branch --show-current 2>/dev/null)"
  [[ -z "$branch" ]] && branch="(detached)"

  if [[ "$fmt" == "line" ]]; then
    local dirty; dirty="$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$dirty" =~ ^[0-9]+$ ]] || dirty=0

    local tier_mode=""
    local stack_config; stack_config="$(bash "$(resolve_lib lib/find-stack-config.sh)" "$root" 2>/dev/null)"
    if [[ -n "$stack_config" && -f "$stack_config" ]]; then
      local tier strict
      tier="$(jq -r '.stack_tier // empty' "$stack_config" 2>/dev/null)"
      strict="$(jq -r 'if .strict_mode then "strict" else "permissive" end' "$stack_config" 2>/dev/null)"
      [[ -n "$tier" ]] && tier_mode="tier ${tier}/${strict}"
    fi
    [[ -z "$tier_mode" ]] && tier_mode="uninit — run /project-init"

    local pr_clause=""
    if command -v gh >/dev/null 2>&1; then
      local pr_json; pr_json="$(cd "$root" && timeout_call gh pr list --head "$branch" --state open --json number,statusCheckRollup --limit 1 2>/dev/null)"
      if [[ -n "$pr_json" ]] && printf '%s' "$pr_json" | jq -e 'length > 0' >/dev/null 2>&1; then
        local num state_glyph rollup
        num="$(printf '%s' "$pr_json" | jq -r '.[0].number')"
        rollup="$(printf '%s' "$pr_json" | jq -r '[.[0].statusCheckRollup[]?.conclusion // .[0].statusCheckRollup[]?.state // "PENDING"] | if length==0 then "NONE" elif (map(select(. != "SUCCESS")) | length) == 0 then "GREEN" else "RED" end' 2>/dev/null)"
        case "$rollup" in
          GREEN) state_glyph="✓" ;;
          RED) state_glyph="✗" ;;
          *) state_glyph="…" ;;
        esac
        pr_clause="PR#${num} ${state_glyph}"
      fi
    fi

    local safe_branch; safe_branch="$(sanitize_path "$branch" 100 "(branch hidden)")"
    if [[ ${#safe_branch} -gt 60 ]]; then safe_branch="${safe_branch:0:59}…"; fi

    local line="$repo_base · $dateline · $safe_branch"
    (( dirty > 0 )) && line="$line · ${dirty} dirty"
    [[ -n "$pr_clause" ]] && line="$line · $pr_clause"
    line="$line · $tier_mode"
    printf '%s\n' "$line"
    return 0
  fi

  # box format (W1, /carbonet)
  local org_display="this org"
  local org_config="$CLAUDE_HOME/config/org.json"
  if [[ -f "$org_config" ]]; then
    local raw; raw="$(jq -r '.org.display_name // empty' "$org_config" 2>/dev/null)"
    [[ -n "$raw" ]] && org_display="$(sanitize_field "$raw" 40)"
  fi

  local safe_branch2; safe_branch2="$(sanitize_path "$branch" 100 "(branch hidden)")"
  local line2="$org_display · $repo_base"
  local line3="$dateline · branch $safe_branch2"

  # Inner content field is 46 chars (2 leading spaces + 46 + border = 48
  # total between the two │ characters, matching the 48-dash top border).
  # Truncate BEFORE printf, not after: `%-46s` only PADS shorter strings,
  # it never truncates longer ones, so a too-long line would blow the box.
  _sb_box_line() {
    local s="$1"
    if [[ ${#s} -gt 46 ]]; then s="${s:0:45}…"; fi
    printf '  │  %-46s│\n' "$s"
  }

  printf '  ╭──────────────────────────────────────────────╮\n'
  _sb_box_line "$line2"
  _sb_box_line "$line3"
  printf '  ╰──────────────────────────────────────────────╯\n'
  return 0
}

# ADR-074 D5. Prefers lib/session-scope.sh's resolver; falls back to an
# identical inline scan when that lib failed to source (this script degrades
# rather than dies when a lib is missing — same discipline as everywhere else).
_sb_resolve_log() {
  local root="${1:-}"
  [[ -z "$root" ]] && { echo ""; return 0; }
  if declare -f ss_resolve_log_path >/dev/null 2>&1; then
    ss_resolve_log_path "$root"
    return 0
  fi
  local newest="" f
  for f in "$root/.claude/session-logs"/*.json "$root/.claude/session-log.json"; do
    [[ -f "$f" ]] || continue
    [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"
  done
  echo "${newest:-}"
  return 0
}

# ---------------------------------------------------------------- since
cmd_since() {
  local max_commits=12
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-commits) max_commits="${2:-12}"; shift 2 ;;
      --max-commits=*) max_commits="${1#*=}"; shift ;;
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --json) shift ;;
      *) echo "session-brief: since: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [[ "$max_commits" =~ ^[0-9]+$ ]] || max_commits=12

  local root; root="$(_sb_root)"
  [[ -z "$root" ]] && return 0

  local last_end="" source_kind="none"
  # ADR-074 D5: scalar question -> newest log document across both locations.
  local log; log="$(_sb_resolve_log "$root")"
  if [[ -n "$log" && -f "$log" ]]; then
    local closed; closed="$(jq -r '.closed_at // empty' "$log" 2>/dev/null)"
    [[ -n "$closed" ]] && { last_end="$closed"; source_kind="session-log"; }
  fi
  if [[ -z "$last_end" ]]; then
    local handoff="$root/.claude/next_prompt.md"
    if [[ -f "$handoff" ]]; then
      local ts; ts="$(grep -m1 '^_Written:' "$handoff" 2>/dev/null | sed -E 's/^_Written:[[:space:]]*//; s/_[[:space:]]*$//')"
      [[ -n "$ts" ]] && { last_end="$ts"; source_kind="handoff"; }
    fi
  fi
  if [[ -z "$last_end" ]]; then
    local slug; slug="$(printf '%s' "$root" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_')"
    [[ ${#slug} -gt 100 ]] && slug="${slug: -100}"
    local mdir="${HOME:-/tmp}/.claude/state/session-markers/$slug"
    if [[ -d "$mdir" ]]; then
      local second; second="$(ls -1t "$mdir"/*.json 2>/dev/null | sed -n '2p')"
      if [[ -n "$second" ]]; then
        local ts; ts="$(jq -r '.started_at // empty' "$second" 2>/dev/null)"
        [[ -n "$ts" ]] && { last_end="$ts"; source_kind="marker"; }
      fi
    fi
  fi

  if [[ -z "$last_end" ]]; then
    jq -n '{last_session_end:"", last_session_end_source:"none", counts:{commits:0,files:0,prs_merged:0,more_commits:0}, commits:[], prs_merged:[]}'
    return 0
  fi

  local base_sha; base_sha="$(git -C "$root" rev-list -1 --before="$last_end" HEAD 2>/dev/null)"
  local range="HEAD"
  [[ -n "$base_sha" ]] && range="$base_sha..HEAD"

  local total_commits; total_commits="$(git -C "$root" rev-list --count "$range" 2>/dev/null)"
  [[ "$total_commits" =~ ^[0-9]+$ ]] || total_commits=0
  local files_touched; files_touched="$(git -C "$root" diff --name-only "$range" -- . 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  [[ "$files_touched" =~ ^[0-9]+$ ]] || files_touched=0

  local commits_json
  # Strip control chars but NOT the newline (\012) separating one commit
  # subject from the next -- git log's %s already excludes the body, so the
  # only newlines here are the ones separating commits.
  commits_json="$(git -C "$root" log -n "$max_commits" --pretty=format:%s "$range" 2>/dev/null | \
    tr -d '\000-\011\013-\037\177' | \
    jq -Rn '[inputs | select(length>0) | .[0:120]] | map({subject:.})' 2>/dev/null)"
  [[ -z "$commits_json" ]] && commits_json='[]'

  local more_commits=0
  (( total_commits > max_commits )) && more_commits=$((total_commits - max_commits))

  local prs_json='[]' prs_count=0
  if command -v gh >/dev/null 2>&1; then
    prs_json="$(cd "$root" && timeout_call gh pr list --state merged --search "merged:>=$(printf '%s' "$last_end" | cut -c1-10)" --json number,title --limit 20 2>/dev/null)"
    printf '%s' "$prs_json" | jq -e . >/dev/null 2>&1 || prs_json='[]'
    prs_count="$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null)"
    [[ "$prs_count" =~ ^[0-9]+$ ]] || { prs_count=0; prs_json='[]'; }
  fi

  jq -n --arg end "$last_end" --arg src "$source_kind" \
        --argjson commits_n "$total_commits" --argjson files "$files_touched" \
        --argjson prs "$prs_count" --argjson more "$more_commits" \
        --argjson commits "$commits_json" --argjson pr_list "$prs_json" \
    '{last_session_end:$end, last_session_end_source:$src,
      counts:{commits:$commits_n, files:$files, prs_merged:$prs, more_commits:$more},
      commits:$commits, prs_merged:$pr_list}'
  return 0
}

# ------------------------------------------------------------------- cost
cmd_cost() {
  local since_days=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since-days) since_days="${2:-1}"; shift 2 ;;
      --since-days=*) since_days="${1#*=}"; shift ;;
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --plain) PLAIN=1; shift ;;
      --json) shift ;;
      *) echo "session-brief: cost: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [[ "$since_days" =~ ^[0-9]+$ ]] || since_days=1

  local root; root="$(_sb_root)"
  [[ -z "$root" ]] && return 0

  local log="$HOME/.claude/logs/subagent-runs.jsonl"
  [[ -f "$log" ]] || return 0
  local pt; pt="$(_model_fit_price_table 2>/dev/null)"
  [[ -z "$pt" ]] && return 0

  local cutoff
  cutoff="$(date -u -v-${since_days}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  [[ -z "$cutoff" ]] && cutoff="$(date -u -d "-${since_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  [[ -z "$cutoff" ]] && return 0

  local agg
  agg="$(jq -rs --arg p "$root" --arg cutoff "$cutoff" '
    [ .[] | select(.event=="main_turn") | select(.agent=="main") | select(.project==$p)
      | select((.ts // "") >= $cutoff) ] as $rows
    | { total_turns: ($rows|length),
        by_model: ( $rows | group_by(.model // "unknown")
          | map({model: (.[0].model // "unknown"),
                 in: ([.[]|(.in_tokens//0)]|add // 0),
                 out: ([.[]|(.out_tokens//0)]|add // 0)})) }
  ' "$log" 2>/dev/null)"
  [[ -z "$agg" ]] && return 0
  local turns; turns="$(printf '%s' "$agg" | jq -r '.total_turns' 2>/dev/null)"
  [[ "$turns" =~ ^[0-9]+$ ]] || turns=0
  (( turns == 0 )) && return 0

  local total_usd=0 rows n
  n="$(printf '%s' "$agg" | jq -r '.by_model | length' 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  local i
  for (( i=0; i<n; i++ )); do
    local m in_t out_t usd present
    m="$(printf '%s' "$agg" | jq -r ".by_model[$i].model")"
    in_t="$(printf '%s' "$agg" | jq -r ".by_model[$i].in")"
    out_t="$(printf '%s' "$agg" | jq -r ".by_model[$i].out")"
    # loop_cost_from_usage returns 0 both for "genuinely free" and for
    # "model not in the table" -- those must not be indistinguishable here.
    # If ANY model in this window is unpriced, skip the whole line rather
    # than report a partial/misleading total (design: "model absent from
    # the table" is a skip-silently case, not a $0.00-shaped line).
    present="$(jq -rn --slurpfile t "$pt" --arg m "$m" '
      ([$t[0].providers // {} | .[] | .models? // {}] | add // {}) as $models
      | if ($models[$m] // null) != null then "yes" else "no" end
    ' 2>/dev/null)"
    [[ "$present" != "yes" ]] && return 0
    usd="$(loop_cost_from_usage "$in_t" "$out_t" "$m" 2>/dev/null)"
    [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd=0
    total_usd="$(awk -v a="$total_usd" -v b="$usd" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)"
  done

  local root_confidence="exact"
  local scope; scope="$(ss_scope_json "$root" 2>/dev/null)"
  [[ -n "$scope" ]] && root_confidence="$(printf '%s' "$scope" | jq -r '.confidence // "exact"' 2>/dev/null)"
  local approximate="false"
  [[ "$root_confidence" != "exact" ]] && approximate="true"

  if (( PLAIN )); then
    [[ "$approximate" == "true" ]] && return 0   # never show a plain reader a hedged number
    local fmt; fmt="$(awk -v u="$total_usd" 'BEGIN{ if (u<0.01) print "penny"; else printf "%.2f", u }')"
    if [[ "$fmt" == "penny" ]]; then
      printf 'Yesterday'"'"'s sessions cost less than a penny.\n'
    else
      printf 'Yesterday'"'"'s sessions cost about $%s.\n' "$fmt"
    fi
    return 0
  fi

  local fmt2; fmt2="$(awk -v u="$total_usd" 'BEGIN{ if (u<0.01) print "less than a penny"; else printf "$%.2f", u }')"
  local approx_suffix=""
  [[ "$approximate" == "true" ]] && approx_suffix=" (approximate)"
  printf 'Cost: ~%s over %s day(s) (%s turns)%s\n' "$fmt2" "$since_days" "$turns" "$approx_suffix"
  return 0
}

# ------------------------------------------------------------------ alerts
_sb_owner_repo() {
  local root="$1" url
  url="$(git -C "$root" remote get-url origin 2>/dev/null)"
  [[ -z "$url" ]] && { echo ""; return 0; }
  url="${url%.git}"
  case "$url" in
    git@*:*) url="${url#*:}" ;;
    https://*|http://*) url="$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/##')" ;;
    ssh://*) url="$(printf '%s' "$url" | sed -E 's#^ssh://[^/]+/##')" ;;
  esac
  printf '%s' "$url"
}

# _sb_wait_pid <pid> <secs> -> rc 0 if <pid> exited on its own within
# <secs>, rc 1 if it had to be killed for running past the deadline. Shared
# poll/kill/wait loop behind both `timeout_call` and `_sb_ls_remote_ok`,
# which differ only in what they do with that outcome (discard vs. report
# it as their own exit status).
_sb_wait_pid() {
  local pid="$1" secs="$2" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= secs )); then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
  done
  return 0
}

timeout_call() {
  # Portable poll-based timeout for `gh`/network calls (no timeout(1) on
  # stock macOS). Bounded at TIMEOUT_TOTAL seconds.
  local secs="$TIMEOUT_TOTAL"
  local outfile; outfile="$(mktemp 2>/dev/null)" || { "$@"; return $?; }
  "$@" > "$outfile" 2>/dev/null &
  local pid=$!
  if _sb_wait_pid "$pid" "$secs"; then
    wait "$pid" 2>/dev/null
    cat "$outfile" 2>/dev/null
  fi
  rm -f "$outfile"
  return 0
}

# _sb_ls_remote_ok <root> <branch> -> rc 0 iff the ref exists on origin,
# bounded by $TIMEOUT_TOTAL. Unlike `timeout_call` (which always returns 0
# and is meant for capturing text output), this preserves the wrapped
# command's real exit status -- `running`'s rescue-branch check needs the
# actual found/not-found result, not just bounded output.
_sb_ls_remote_ok() {
  local root="$1" branch="$2"
  ( git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 ) &
  local pid=$!
  _sb_wait_pid "$pid" "$TIMEOUT_TOTAL" || return 1
  wait "$pid"
  return $?
}

cmd_alerts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --json) shift ;;
      *) echo "session-brief: alerts: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  command -v gh >/dev/null 2>&1 || return 0
  local root; root="$(_sb_root)"
  [[ -z "$root" ]] && return 0
  local owner_repo; owner_repo="$(_sb_owner_repo "$root")"
  [[ -z "$owner_repo" ]] && return 0

  local count; count="$(timeout_call gh api "repos/${owner_repo}/dependabot/alerts?state=open&per_page=100" --jq 'length')"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  (( count == 0 )) && return 0
  if (( count >= 100 )); then
    printf 'Alerts: 100+ open dependency alerts\n'
  else
    local word="alert"; (( count != 1 )) && word="alerts"
    printf 'Alerts: %s open dependency %s\n' "$count" "$word"
  fi
  return 0
}

# ------------------------------------------------------------------- todos
cmd_todos() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --json) shift ;;
      *) echo "session-brief: todos: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  local root; root="$(_sb_root)"
  [[ -z "$root" ]] && return 0

  local base; base="$(ss_last_close_sha "$root" 2>/dev/null)"
  if [[ -z "$base" ]]; then
    local scope; scope="$(ss_scope_json "$root" 2>/dev/null)"
    base="$(printf '%s' "$scope" | jq -r '.start_sha // empty' 2>/dev/null)"
  fi
  [[ -z "$base" ]] && return 0

  local committed uncommitted total
  committed="$(git -C "$root" diff -U0 "$base"..HEAD -- . 2>/dev/null | grep -cE '^\+.*(TODO|FIXME)' || true)"
  uncommitted="$(git -C "$root" diff -U0 -- . 2>/dev/null | grep -cE '^\+.*(TODO|FIXME)' || true)"
  [[ "$committed" =~ ^[0-9]+$ ]] || committed=0
  [[ "$uncommitted" =~ ^[0-9]+$ ]] || uncommitted=0
  total=$((committed + uncommitted))
  (( total == 0 )) && return 0
  local shown="$total"
  (( total > 99 )) && shown="99+"
  printf 'TODOs: %s new since last session\n' "$shown"
  return 0
}

# --------------------------------------------------------------------- running
# G2 (ADR-072 §5.2, Stage 3). Re-derives every status LIVE — the session
# log's `to_recheck` holds only bare identifiers (loop ids, pids, rescue
# branch names), never a status, and this function never reads a status
# back out of the log (D8a). A doctored/stale log claiming a loop is still
# active must lose to whatever the loop-state file says NOW.
cmd_running() {
  local json_out=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --json) json_out=1; shift ;;
      *) echo "session-brief: running: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  local root; root="$(_sb_root)"
  [[ -z "$root" ]] && return 0

  local log; log="$(_sb_resolve_log "$root")"

  if [[ -z "$log" || ! -f "$log" ]]; then
    # Degrade: no reconciliation possible. Fall back to last night's
    # handoff section, DISPLAY-ONLY, clearly labelled as unverified.
    local handoff="$root/.claude/next_prompt.md"
    [[ -f "$handoff" ]] || return 0
    local section
    section="$(awk '/^## Running work/{flag=1; next} /^## /{flag=0} flag' "$handoff" 2>/dev/null | \
      grep -E '^- ' | sed -E 's/^- //' | tr -d '\r')"
    [[ -z "$section" ]] && return 0
    # Bash-native join (no `paste` dependency -- keep this portable to a
    # minimal PATH, same discipline as the rest of this script).
    local joined="" line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ -n "$joined" ]] && joined="$joined · $line" || joined="$line"
    done <<< "$section"
    local text; text="$(printf "Running (from last night's handoff, not verified): %s" "$joined")"
    if (( json_out )); then
      jq -n --arg line "$text" '{line:$line}'
    else
      printf '%s\n' "$text"
    fi
    return 0
  fi

  # ADR-074 D5 / round-2 Concern 4: running work is a UNION across every
  # session log in the window, not just the newest. A rescue branch belonging
  # to a concurrent session is real work — showing only the newest session's
  # would hide it, which is exactly the failure ADR-072 D8 forbids.
  local to_recheck=""
  local sc; sc="$(resolve_lib scripts/session-close.sh)"
  if [[ -f "$sc" ]]; then
    to_recheck="$(bash "$sc" __collect-to-recheck --repo "$root" 2>/dev/null)"
  fi
  printf '%s' "$to_recheck" | jq -e . >/dev/null 2>&1 || \
    to_recheck="$(jq -c '.to_recheck // {}' "$log" 2>/dev/null)"
  [[ -z "$to_recheck" ]] && to_recheck='{}'

  # Entries whose source is not the newest document, for the display label.
  local foreign_count
  foreign_count="$(printf '%s' "$to_recheck" | jq -r '(.foreign // []) | length' 2>/dev/null)"
  [[ "$foreign_count" =~ ^[0-9]+$ ]] || foreign_count=0

  local clauses=""
  _rn_add() { [[ -n "$clauses" ]] && clauses="$clauses · $1" || clauses="$1"; }

  # Loops: re-read each loop-state.*.json NOW. Never trust anything the log
  # itself might claim about whether a loop is active.
  local loop_dir="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"
  local still_going=0
  local lid
  while IFS= read -r lid; do
    [[ -z "$lid" ]] && continue
    local sf="" f
    for f in "$loop_dir"/loop-state.*.json "$loop_dir"/loop-state.json; do
      [[ -f "$f" ]] || continue
      [[ "$(jq -r '.loop_id // empty' "$f" 2>/dev/null)" == "$lid" ]] && { sf="$f"; break; }
    done
    [[ -z "$sf" ]] && continue
    if [[ "$(jq -r '.active // false' "$sf" 2>/dev/null)" == "true" ]]; then
      still_going=$((still_going + 1))
    else
      local st; st="$(jq -r '.status // "unknown"' "$sf" 2>/dev/null)"
      _rn_add "1 finished (${st})"
    fi
  done < <(printf '%s' "$to_recheck" | jq -r '.loop_ids[]? // empty' 2>/dev/null)
  (( still_going > 0 )) && _rn_add "${still_going} loop$( (( still_going != 1 )) && printf s ) still going"

  # Pid-file-backed processes: `kill -0` NOW.
  local alive_count=0 dead_count=0 pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then alive_count=$((alive_count + 1)); else dead_count=$((dead_count + 1)); fi
  done < <(printf '%s' "$to_recheck" | jq -r '.pids[]? // empty' 2>/dev/null)
  (( alive_count > 0 )) && _rn_add "${alive_count} background process$( (( alive_count != 1 )) && printf es ) still alive"
  (( dead_count > 0 )) && _rn_add "${dead_count} background process$( (( dead_count != 1 )) && printf es ) finished"

  # Rescue branches: `git ls-remote` NOW -- still on the remote, or already
  # merged/gone. The session log is explicitly untrusted (a doctored log is
  # the whole reason this function re-derives everything live), so the
  # identifier is validated against the shape this script itself generates
  # (rescue/<YYYY-MM-DD-HHMM>-<slug>) BEFORE it is ever used as an
  # `ls-remote` ref pattern -- otherwise a value like "*" could match
  # arbitrary remote refs and produce a false positive. Bounded by
  # $TIMEOUT_TOTAL so a broken/slow remote can't block boot reconciliation
  # indefinitely (matches the `gh` calls elsewhere in this file, which
  # already go through `timeout_call`).
  local open_branches=0 branch
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    case "$branch" in
      rescue/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-*) ;;
      *) continue ;;
    esac
    _sb_ls_remote_ok "$root" "$branch" && open_branches=$((open_branches + 1))
  done < <(printf '%s' "$to_recheck" | jq -r '.rescue_branches[]? // empty' 2>/dev/null)
  if (( open_branches > 0 )); then
    local branch_clause="${open_branches} rescue branch$( (( open_branches != 1 )) && printf es ) open"
    (( foreign_count > 0 )) && branch_clause="$branch_clause (from another session)"
    _rn_add "$branch_clause"
  fi

  # Overnight PR ids (Stage 6 doesn't populate this field yet, so this
  # clause is normally empty in practice -- the wiring is here so Stage 6
  # is additive). `gh` missing -> drop this clause only, per design.
  if command -v gh >/dev/null 2>&1; then
    local item_ids; item_ids="$(printf '%s' "$to_recheck" | jq -r '.overnight_item_ids[]? // empty' 2>/dev/null)"
    if [[ -n "$item_ids" ]]; then
      local pr_json; pr_json="$(cd "$root" && timeout_call gh pr list --label overnight-queue --json number,state 2>/dev/null)"
      if printf '%s' "$pr_json" | jq -e . >/dev/null 2>&1; then
        local pr_count; pr_count="$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null)"
        [[ "$pr_count" =~ ^[0-9]+$ ]] && (( pr_count > 0 )) && _rn_add "${pr_count} overnight PR$( (( pr_count != 1 )) && printf s ) open"
      fi
    fi
  fi

  # A night that produced NOTHING has to be as visible as one that produced
  # a PR. The overnight job's failures are all refusals by design -- a patch
  # touching a file outside the approved one, a secret-shaped string, an item
  # whose wording changed after approval -- and each currently shows up only
  # as a red run in Actions that nobody opens. Reported read-only, from the
  # run list; nothing is written back to the queue (ADR-072 D11).
  if command -v gh >/dev/null 2>&1; then
    local on_json; on_json="$(cd "$root" && timeout_call gh run list --workflow=overnight-queue.yml --limit 5 --json conclusion,createdAt 2>/dev/null)"
    if printf '%s' "$on_json" | jq -e . >/dev/null 2>&1; then
      local on_failed
      on_failed="$(printf '%s' "$on_json" | jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null)"
      [[ "$on_failed" =~ ^[0-9]+$ ]] && (( on_failed > 0 )) \
        && _rn_add "${on_failed} overnight run$( (( on_failed != 1 )) && printf s ) refused -- see the Actions log for which guard"
    fi
  fi

  [[ -z "$clauses" ]] && return 0
  local text; text="$(printf 'Running: %s' "$clauses")"
  if (( json_out )); then
    jq -n --arg line "$text" '{line:$line}'
  else
    printf '%s\n' "$text"
  fi
  return 0
}

# ---------------------------------------------------------------------- all
cmd_all() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_PATH="${2:-}"; shift 2 ;;
      --repo=*) REPO_PATH="${1#*=}"; shift ;;
      --json) shift ;;
      *) echo "session-brief: all: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  local banner_line; banner_line="$(cmd_banner --format line 2>/dev/null)"
  local since_json; since_json="$(cmd_since 2>/dev/null)"
  [[ -z "$since_json" ]] && since_json='{}'
  local cost_line; cost_line="$(cmd_cost 2>/dev/null)"
  local alerts_line; alerts_line="$(cmd_alerts 2>/dev/null)"
  local todos_line; todos_line="$(cmd_todos 2>/dev/null)"
  local running_line; running_line="$(cmd_running 2>/dev/null)"

  jq -n --arg banner "$banner_line" --argjson since "$since_json" \
        --arg cost "$cost_line" --arg alerts "$alerts_line" --arg todos "$todos_line" \
        --arg running "$running_line" \
    '{banner:$banner, since:$since, cost:$cost, alerts:$alerts, todos:$todos, running:$running}'
  return 0
}

# ------------------------------------------------------------------- dispatch
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
SUBCOMMAND="$1"; shift

# Parse global flags out of the remaining argv so subcommand parsers don't
# each need to know about them.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT_TOTAL="${2:-6}"; shift 2 ;;
    --timeout=*) TIMEOUT_TOTAL="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ "$TIMEOUT_TOTAL" =~ ^[0-9]+$ ]] || TIMEOUT_TOTAL=6

case "$SUBCOMMAND" in
  banner|since|cost|alerts|todos|running|all)
    (( JQ_MISSING )) && exit 0   # fail-open: no jq -> empty stdout, never a partial line
    ;;
esac

case "$SUBCOMMAND" in
  banner) cmd_banner "${ARGS[@]+"${ARGS[@]}"}" ;;
  since) cmd_since "${ARGS[@]+"${ARGS[@]}"}" ;;
  cost) cmd_cost "${ARGS[@]+"${ARGS[@]}"}" ;;
  alerts) cmd_alerts "${ARGS[@]+"${ARGS[@]}"}" ;;
  todos) cmd_todos "${ARGS[@]+"${ARGS[@]}"}" ;;
  running) cmd_running "${ARGS[@]+"${ARGS[@]}"}" ;;
  all) cmd_all "${ARGS[@]+"${ARGS[@]}"}" ;;
  -h|--help) usage ;;
  *) echo "session-brief: unknown subcommand: $SUBCOMMAND" >&2; usage >&2; exit 2 ;;
esac
