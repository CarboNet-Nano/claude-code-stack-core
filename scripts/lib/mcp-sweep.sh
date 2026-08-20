#!/usr/bin/env bash
# scripts/lib/mcp-sweep.sh — ADR-046 (revision 2): fetch/merge/classify/render
# functions for the multi-source MCP sweep. Sourced by scripts/mcp-sweep.sh
# and by tests/test-mcp-sweep.sh (which PATH-shims `curl` and `gh`, per D3 —
# no test in this file ever touches the real network).
#
# Functions only — callers own `set -euo pipefail`. All network I/O funnels
# through mcp_http_get (D3, D16). Date math is `date -u` for "now" and
# python3 for arithmetic only (D14r1) — both runners (ubuntu-latest for the
# real job, macos-latest for the hermetic test suite) ship both.

# ---------------------------------------------------------------------------
# Tunables — named constants, env-overridable, none hardcoded inline (per
# §Interfaces "Tunables"). Values below reflect the pre-ship verification
# gate's live findings (docs/ADRs/046-mcp-sweep-multi-source.md, item 7):
# GitHub topic:mcp-server/topic:modelcontextprotocol and npm text=mcp-server
# already exceed the ADR's original page caps on literally every run, so the
# caps here are raised to each source's real, live-verified ceiling rather
# than the ADR's original starting guesses. See MCP_SWEEP_*_MAX_PAGES below
# for the specific live numbers each ceiling is derived from.
# ---------------------------------------------------------------------------

MCP_SWEEP_LOOKBACK_DAYS="${MCP_SWEEP_LOOKBACK_DAYS:-7}"
# ADR-046 revision 3 (D23) — npm's search-API relevance field turned out to
# be text relevance, not a quality score (live-verified 2026-08-02: a
# 44-download demo package scored higher than the official SDK at ~181M
# downloads). The old npm quality tunable is deleted; the npm OR-branch now
# gates on monthly downloads instead.
MCP_SWEEP_NPM_MIN_DOWNLOADS_MONTHLY="${MCP_SWEEP_NPM_MIN_DOWNLOADS_MONTHLY:-1000}"
# D24 signal-integrity tripwire tunables.
MCP_SWEEP_NPM_SIGNAL_MIN_SAMPLE="${MCP_SWEEP_NPM_SIGNAL_MIN_SAMPLE:-20}"
MCP_SWEEP_NPM_MAX_SIGNAL_MISSING_RATIO="${MCP_SWEEP_NPM_MAX_SIGNAL_MISSING_RATIO:-0.50}"
MCP_SWEEP_GH_MIN_STARS="${MCP_SWEEP_GH_MIN_STARS:-25}"
MCP_SWEEP_STALE_DAYS="${MCP_SWEEP_STALE_DAYS:-30}"
MCP_SWEEP_MAX_RENDER="${MCP_SWEEP_MAX_RENDER:-25}"

MCP_SWEEP_NPM_PAGE_SIZE="${MCP_SWEEP_NPM_PAGE_SIZE:-250}"
# Live-verified 2026-07-28: registry.npmjs.org/-/v1/search silently WRAPS
# back to page 0 once `from` exceeds 5000 (from=5000 still advances
# correctly; from=5001 returns the same objects as from=0, with HTTP 200 —
# no error, just silently wrong data). 20 pages * 250 = 5000 is therefore
# the true safe ceiling for this endpoint, not an arbitrary raise.
MCP_SWEEP_NPM_MAX_PAGES="${MCP_SWEEP_NPM_MAX_PAGES:-20}"

MCP_SWEEP_GH_PER_PAGE="${MCP_SWEEP_GH_PER_PAGE:-100}"
# Live-verified 2026-07-28: GitHub's Search API hard-caps at 1000 results
# per query regardless of per_page/page (page 11 at per_page=100 returns
# HTTP 422 "Only the first 1000 search results are available"). 10 pages *
# 100 = 1000 is the API's actual maximum obtainable, not a guess — going
# higher would only produce 422s, going lower would leave reachable results
# unfetched.
MCP_SWEEP_GH_MAX_PAGES="${MCP_SWEEP_GH_MAX_PAGES:-10}"

MCP_SWEEP_REGISTRY_LIMIT="${MCP_SWEEP_REGISTRY_LIMIT:-100}"
# Live-verified 2026-07-28: registry.modelcontextprotocol.io/v0.1/servers
# paginates cleanly via nextCursor with no observed hard ceiling; live
# enumeration found ~600-700 total records. 50 pages * 100 = 5000 is
# generous headroom over the observed total, sized for organic growth (the
# registry is bar-exempt and the highest-signal source — D9r2).
MCP_SWEEP_REGISTRY_MAX_PAGES="${MCP_SWEEP_REGISTRY_MAX_PAGES:-50}"
# Pinned per §Pre-ship verification gate item 1 (live-verified 2026-07-28):
# both /v0.1/servers and /v0/servers answer 200 with identical content;
# /v0.1/servers is pinned per the documented API freeze.
MCP_SWEEP_REGISTRY_PATH="${MCP_SWEEP_REGISTRY_PATH:-/v0.1/servers}"
MCP_SWEEP_REGISTRY_PATH_FALLBACK="${MCP_SWEEP_REGISTRY_PATH_FALLBACK:-/v0/servers}"

MCP_SWEEP_ISSUE_LABEL="${MCP_SWEEP_ISSUE_LABEL:-mcp-sweep}"
MCP_SWEEP_ISSUE_NUMBER="${MCP_SWEEP_ISSUE_NUMBER:-58}"
# Opaque author node-ID strings (D12 revision 2) — compared as exact opaque
# strings, never parsed or cast to a number. Space-separated set.
# Live-verified 2026-07-28 (see implementer report): issue #58's actual
# author is github-actions[bot], node id "MDM6Qm90NDE4OTgyODI=" on this repo
# (fetched via `gh api graphql` with an explicit `... on Bot { id }`
# fragment — `gh issue view --json author` omits `id` entirely for
# Bot-typed authors on this gh version, a real gap documented in
# mcp_author_guard_check below).
MCP_SWEEP_ISSUE_AUTHOR_ALLOW="${MCP_SWEEP_ISSUE_AUTHOR_ALLOW:-MDM6Qm90NDE4OTgyODI=}"

MCP_SWEEP_BODY_MAX_BYTES="${MCP_SWEEP_BODY_MAX_BYTES:-60000}"
MCP_SWEEP_AGED_MAX="${MCP_SWEEP_AGED_MAX:-5000}"
MCP_SWEEP_AGED_RENDER="${MCP_SWEEP_AGED_RENDER:-50}"
MCP_SWEEP_MAX_RESPONSE_BYTES="${MCP_SWEEP_MAX_RESPONSE_BYTES:-10485760}"
MCP_SWEEP_MAX_MALFORMED_RATIO="${MCP_SWEEP_MAX_MALFORMED_RATIO:-0.20}"
MCP_SWEEP_CLEAN_RUNS_TO_CLOSE="${MCP_SWEEP_CLEAN_RUNS_TO_CLOSE:-2}"
MCP_SWEEP_KEY_MAX_CHARS="${MCP_SWEEP_KEY_MAX_CHARS:-100}"
MCP_SWEEP_FAIL_STREAK_ALERT="${MCP_SWEEP_FAIL_STREAK_ALERT:-3}"
MCP_SWEEP_FAIL_STREAK_REALERT="${MCP_SWEEP_FAIL_STREAK_REALERT:-7}"
MCP_SWEEP_FAIL_STREAK_FAIL="${MCP_SWEEP_FAIL_STREAK_FAIL:-7}"
MCP_SWEEP_ALL_EMPTY_STREAK_ALERT="${MCP_SWEEP_ALL_EMPTY_STREAK_ALERT:-3}"
MCP_SWEEP_ALL_EMPTY_STREAK_FAIL="${MCP_SWEEP_ALL_EMPTY_STREAK_FAIL:-7}"

MCP_SWEEP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# D16 — the only place curl is invoked. Host allowlist, no redirects, hard
# caps. Body on stdout; exit 0 on 2xx, 3 otherwise. A closed-vocabulary
# token is printed on stderr describing the failure (used by fetchers to
# populate source-status.json's `note`, D9r2).
# ---------------------------------------------------------------------------
mcp_http_get() {
  local url="$1"
  shift
  local -a headers=("$@")

  if [[ ! "$url" =~ ^https://(registry\.npmjs\.org|api\.github\.com|registry\.modelcontextprotocol\.io)/ ]]; then
    echo "HOST_DENIED" >&2
    return 3
  fi

  local body_file status_file header_file cfg_file
  body_file="$(mktemp)"
  status_file="$(mktemp)"
  header_file="$(mktemp)"
  cfg_file="$(mktemp)"

  # Bash 3.2 (macos-latest's /bin/bash) treats "${arr[@]}" as an unbound
  # variable under `set -u` when arr has zero elements — guard the
  # expansion on length rather than relying on a version-dependent idiom.
  if [[ "${#headers[@]}" -gt 0 ]]; then
    local h
    for h in "${headers[@]}"; do
      printf 'header = "%s"\n' "$h" >> "$cfg_file"
    done
  fi

  local had_xtrace=0
  [[ $- == *x* ]] && had_xtrace=1
  { set +x; } 2>/dev/null

  curl -sS \
    --config "$cfg_file" \
    --proto '=https' \
    --max-redirs 0 \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-max-time 60 \
    --max-filesize "$MCP_SWEEP_MAX_RESPONSE_BYTES" \
    -D "$header_file" \
    -o "$body_file" \
    -w '%{http_code}' \
    "$url" > "$status_file" 2>/dev/null
  local curl_rc=$?

  [[ "$had_xtrace" == 1 ]] && set -x

  local token="" rc=3 http_code
  http_code="$(cat "$status_file" 2>/dev/null || true)"

  local size
  size="$(wc -c < "$body_file" 2>/dev/null | tr -d ' ')"

  if [[ "$curl_rc" -ne 0 ]]; then
    case "$curl_rc" in
      28) token="TIMEOUT" ;;
      7) token="CONNFAIL" ;;
      63) token="SIZE_CAP" ;;
      47) token="REDIRECT" ;;
      *) token="CONNFAIL" ;;
    esac
  elif [[ -n "$size" && "$size" -gt "$MCP_SWEEP_MAX_RESPONSE_BYTES" ]]; then
    token="SIZE_CAP"
  elif [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    if grep -qi '^x-ratelimit-remaining: *0' "$header_file" 2>/dev/null; then
      token="RATE_LIMITED"
    else
      cat "$body_file"
      rc=0
    fi
  elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
    token="RATE_LIMITED"
  elif [[ "$http_code" =~ ^3[0-9][0-9]$ ]]; then
    token="REDIRECT_${http_code}"
  elif [[ "$http_code" =~ ^[0-9][0-9][0-9]$ ]]; then
    token="HTTP_${http_code}"
  else
    token="CONNFAIL"
  fi

  rm -f "$body_file" "$status_file" "$header_file" "$cfg_file"

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  echo "$token" >&2
  return 3
}

# ---------------------------------------------------------------------------
# D14 (revision 1) — portable date math. `date -u` for "now" (portable on
# both ubuntu-latest and macos-latest); python3 for arithmetic only, UTC
# explicit. Never `date -d` (GNU-only), never `date -v` (BSD-only).
# ---------------------------------------------------------------------------
mcp_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

mcp_rfc3339_days_ago() {
  local days="$1"
  python3 -c '
import sys, datetime
days = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
then = now - datetime.timedelta(days=days)
print(then.strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$days"
}

# D19 — query params always via constants + jq's @uri, never hand-built
# string concatenation of an untrusted value into a URL.
mcp_uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# ---------------------------------------------------------------------------
# D15 (revision 2) — key grammar. Length first, then grammar (normative
# order). DOTSAFE forbids all-dots components (`.`, `..`, `...`) in every
# path-position component: owner, repo, npm scope, npm package, registry
# namespace, registry name, and every fragment segment.
# ---------------------------------------------------------------------------

# _mcp_dotsafe <str> <max_len> -> 0 if str matches DOTSAFE and len<=max_len
_mcp_dotsafe() {
  local s="$1" max_len="$2"
  [[ -z "$s" ]] && return 1
  [[ "${#s}" -gt "$max_len" ]] && return 1
  [[ "$s" =~ ^[a-z0-9._-]+$ ]] || return 1
  local stripped="${s//./}"
  [[ -n "$stripped" ]] || return 1
  return 0
}

# _mcp_dotsafe_sub <str> <max_len> -> 0 if every "/"-separated segment of
# str is DOTSAFE and the whole fragment is <= max_len.
_mcp_dotsafe_sub() {
  local s="$1" max_len="$2"
  [[ -z "$s" ]] && return 1
  [[ "${#s}" -gt "$max_len" ]] && return 1
  local seg
  local IFS_OLD="$IFS"
  local had_noglob=0
  [[ $- == *f* ]] && had_noglob=1
  set -f
  IFS='/'
  # shellcheck disable=SC2206 # intentional split; globbing disabled above
  local -a segs=($s)
  IFS="$IFS_OLD"
  [[ "$had_noglob" == 0 ]] && set +f
  [[ "${#segs[@]}" -eq 0 ]] && return 1
  for seg in "${segs[@]}"; do
    _mcp_dotsafe "$seg" 64 || return 1
  done
  return 0
}

# mcp_key_valid <key> -> 0 if key matches the D15.3 grammar (length first,
# then productions), 1 otherwise. Never crashes on adversarial input.
mcp_key_valid() {
  local key="$1"
  [[ "${#key}" -gt "$MCP_SWEEP_KEY_MAX_CHARS" ]] && return 1

  if [[ "$key" == gh:* ]]; then
    local rest="${key#gh:}"
    local frag="" ownerrepo="$rest"
    if [[ "$rest" == *"#"* ]]; then
      frag="${rest#*#}"
      ownerrepo="${rest%%#*}"
    fi
    [[ "$ownerrepo" == */* ]] || return 1
    local owner="${ownerrepo%%/*}" repo="${ownerrepo#*/}"
    [[ "$repo" == *"/"* ]] && return 1
    _mcp_dotsafe "$owner" 39 || return 1
    _mcp_dotsafe "$repo" 100 || return 1
    if [[ -n "$frag" ]]; then
      _mcp_dotsafe_sub "$frag" 64 || return 1
    fi
    return 0
  fi

  if [[ "$key" == npm:* ]]; then
    local rest="${key#npm:}"
    if [[ "$rest" == @*/* ]]; then
      local scope="${rest#@}"
      scope="${scope%%/*}"
      local pkg="${rest#*/}"
      _mcp_dotsafe "$scope" 64 || return 1
      _mcp_dotsafe "$pkg" 100 || return 1
      return 0
    fi
    _mcp_dotsafe "$rest" 100 || return 1
    return 0
  fi

  if [[ "$key" == mcp:* ]]; then
    local rest="${key#mcp:}"
    [[ "$rest" == */* ]] || return 1
    local ns="${rest%%/*}" name="${rest#*/}"
    [[ "$name" == *"/"* ]] && return 1
    _mcp_dotsafe "$ns" 80 || return 1
    _mcp_dotsafe "$name" 80 || return 1
    return 0
  fi

  return 1
}

# mcp_derive_url <key> -> URL on stdout, exit 1 on assertion failure (D15.4
# revision 2). Belt-and-suspenders over the grammar: asserts the output
# lands on an allowlisted host with no traversal sequence, regardless of how
# it was constructed.
mcp_derive_url() {
  local key="$1"
  local url=""

  # D15.3 grammar first (this is the primary defense — D15.4's checks below
  # are belt-and-suspenders over it, not a substitute). Without this, a
  # traversal sequence in a query-string position (e.g. `mcp:../x` ->
  # `?search=../x`) has no leading `/` for the literal-substring checks
  # below to catch.
  mcp_key_valid "$key" || return 1

  if [[ "$key" == gh:* ]]; then
    local rest="${key#gh:}"
    local frag="" ownerrepo="$rest"
    if [[ "$rest" == *"#"* ]]; then
      frag="${rest#*#}"
      ownerrepo="${rest%%#*}"
    fi
    if [[ -n "$frag" ]]; then
      url="https://github.com/${ownerrepo}/tree/HEAD/${frag}"
    else
      url="https://github.com/${ownerrepo}"
    fi
  elif [[ "$key" == npm:* ]]; then
    url="https://www.npmjs.com/package/${key#npm:}"
  elif [[ "$key" == mcp:* ]]; then
    url="https://registry.modelcontextprotocol.io/?search=${key#mcp:}"
  else
    return 1
  fi

  [[ "$url" =~ ^https://(github\.com|www\.npmjs\.com|registry\.modelcontextprotocol\.io)/ ]] || return 1
  [[ "$url" == *"/../"* ]] && return 1
  [[ "$url" == *"/./"* ]] && return 1
  [[ "$url" == *".."* && "$url" == *"npmjs.com/package/.."* ]] && return 1
  local host_and_rest="${url#https://}"
  local path="${host_and_rest#*/}"
  [[ "$path" == *"//"* ]] && return 1
  [[ "$url" == */..  ]] && return 1

  echo "$url"
  return 0
}

# mcp_normalize_key <url> <source> <sourceId> -> key on stdout, exit 1 if
# underivable. Ladder (first that succeeds): (1) if <url> resolves to a
# github.com repo shape, key = gh:owner/repo[#sub] regardless of <source> —
# this is what unifies a server observed via all three sources under one
# key (test 10). (2) source==npm -> npm:<package-name>. (3) source==registry
# -> mcp:<reverse-dns-name>. (4) drop (never emit a truncated key).
mcp_normalize_key() {
  local url="$1" source="$2" source_id="$3"

  local gh_key
  gh_key="$(_mcp_derive_gh_key_from_url "$url")"
  if [[ -n "$gh_key" ]] && mcp_key_valid "$gh_key"; then
    echo "$gh_key"
    return 0
  fi

  case "$source" in
    npm)
      local npm_key
      npm_key="$(_mcp_derive_npm_key "$source_id")"
      if [[ -n "$npm_key" ]] && mcp_key_valid "$npm_key"; then
        echo "$npm_key"
        return 0
      fi
      ;;
    registry)
      local mcp_key
      mcp_key="$(_mcp_derive_registry_key "$source_id")"
      if [[ -n "$mcp_key" ]] && mcp_key_valid "$mcp_key"; then
        echo "$mcp_key"
        return 0
      fi
      ;;
  esac

  return 1
}

_mcp_derive_npm_key() {
  local pkg_lower
  pkg_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$pkg_lower" ]] && return 1
  echo "npm:${pkg_lower}"
}

_mcp_derive_registry_key() {
  local name_lower
  name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$name_lower" ]] && return 1
  echo "mcp:${name_lower}"
}

# _mcp_derive_gh_key_from_url <url> -> "gh:owner/repo[#sub]" on stdout, or
# empty (not an error — caller falls through the ladder) if <url> doesn't
# resolve to a github.com repo shape. Handles: bare https URLs, `git+`/
# `git://`/`ssh://` prefixes, `git@github.com:owner/repo.git` scp syntax,
# trailing `.git`, and `/tree/<ref>/<sub>` or `/blob/<ref>/<sub>` subpaths
# (single-segment ref only — see the note below on the slashed-ref
# limitation, an accepted, documented gap per §Interface deltas revision 1).
_mcp_derive_gh_key_from_url() {
  local raw="$1"
  [[ -z "$raw" ]] && return 0

  local s
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  # scp-style ssh syntax: git@github.com:owner/repo(.git)?
  if [[ "$s" =~ ^git@github\.com:(.+)$ ]]; then
    s="github.com/${BASH_REMATCH[1]}"
  else
    s="${s#git+}"
    s="${s#git://}"
    s="${s#ssh://}"
    s="${s#https://}"
    s="${s#http://}"
    # strip userinfo (user@ or user:pass@) if present before the host
    if [[ "$s" == *"@"* && "$s" == *"github.com"* ]]; then
      local before_at="${s%%@*}"
      if [[ "$before_at" != *"/"* ]]; then
        s="${s#*@}"
      fi
    fi
  fi

  [[ "$s" == github.com/* ]] || return 0
  s="${s#github.com/}"

  # strip query and real URL fragment (not the derived key's #sub)
  s="${s%%\?*}"

  s="${s%.git}"
  s="${s%/}"

  [[ -z "$s" || "$s" != */* ]] && return 0

  local owner="${s%%/*}"
  local remainder="${s#*/}"
  local repo="$remainder"
  local sub=""

  if [[ "$remainder" == */* ]]; then
    repo="${remainder%%/*}"
    local after_repo="${remainder#*/}"
    if [[ "$after_repo" == tree/* || "$after_repo" == blob/* ]]; then
      local after_kind="${after_repo#*/}"
      if [[ "$after_kind" == */* ]]; then
        sub="${after_kind#*/}"
      fi
    fi
  fi

  repo="${repo%.git}"

  if [[ -n "$sub" ]]; then
    echo "gh:${owner}/${repo}#${sub}"
  else
    echo "gh:${owner}/${repo}"
  fi
  return 0
}

# mcp_derive_gh_key_from_repo_directory <owner> <repo> <directory> -> key.
# Used by the npm fetcher when a package's `repository.directory` is
# present — the unambiguous alternative to guessing a slashed-ref boundary
# from a bare /tree/<ref>/<sub> URL (§Interface deltas revision 1).
mcp_derive_gh_key_from_repo_directory() {
  local owner="$1" repo="$2" directory="$3"
  directory="${directory#/}"
  directory="${directory%/}"
  owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
  repo="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$directory" ]]; then
    echo "gh:${owner}/${repo}"
  else
    directory="$(printf '%s' "$directory" | tr '[:upper:]' '[:lower:]')"
    echo "gh:${owner}/${repo}#${directory}"
  fi
}

# ---------------------------------------------------------------------------
# Fetch helpers shared by all three sources.
# ---------------------------------------------------------------------------

_mcp_note_from_http_token() {
  local token="$1"
  case "$token" in
    HTTP_*) printf '%s' "$token" | tr '[:upper:]' '[:lower:]' ;;
    REDIRECT_*) echo "redirect_${token#REDIRECT_}" ;;
    REDIRECT) echo "redirect_0" ;;
    RATE_LIMITED) echo "rate_limited" ;;
    TIMEOUT) echo "timeout" ;;
    SIZE_CAP) echo "size_cap" ;;
    # No dedicated closed-vocabulary token exists for a raw connection
    # failure (CONNFAIL) or a denied host (HOST_DENIED, which should never
    # fire in practice — every URL this file builds is host-allowlisted by
    # construction). "timeout" is the closest existing bucket for a network-
    # level failure that never produced an HTTP status; documented here
    # rather than inventing a fifth vocabulary word.
    CONNFAIL) echo "timeout" ;;
    HOST_DENIED) echo "schema_envelope" ;;
    "") echo "schema_envelope" ;;
    *) echo "schema_envelope" ;;
  esac
}

_mcp_valid_rfc3339() {
  python3 -c '
import sys, datetime
v = sys.argv[1]
try:
    s = v.replace("Z", "+00:00") if v.endswith("Z") else v
    dt = datetime.datetime.fromisoformat(s)
    sys.exit(0 if dt.tzinfo is not None else 1)
except Exception:
    sys.exit(1)
' "$1"
}

_mcp_key_last_segment() {
  local key="$1"
  local rest="${key#*:}"
  if [[ "$rest" == *"#"* ]]; then
    rest="${rest##*#}"
  fi
  echo "${rest##*/}"
}

# _mcp_emit_ndjson_row <key> <name> <source> <sourceId> <updatedUtc> <stars> <npmDownloadsMonthly> <registryStatus>
# (ADR-046 revision 3, D23: positional arg 7 changed meaning to
# npmDownloadsMonthly, replacing the old npm relevance-score arg.
# mcp_fetch_github and mcp_fetch_registry keep passing literal 0 there.)
_mcp_emit_ndjson_row() {
  jq -cn \
    --arg key "$1" --arg name "$2" --arg source "$3" --arg sourceId "$4" \
    --arg updatedUtc "$5" --argjson stars "${6:-0}" --argjson npmDownloadsMonthly "${7:-0}" \
    --arg registryStatus "$8" \
    '{key:$key,name:$name,source:$source,sourceId:$sourceId,updatedUtc:$updatedUtc,
      signal:{stars:$stars,npmDownloadsMonthly:$npmDownloadsMonthly,registryStatus:$registryStatus}}'
}

# _mcp_write_status_file <path> <status> <note> <scanned> <malformed> <unkeyable> [signalMissing=0] [signalEligible=0]
# (ADR-046 revision 3, D24: optional args 7/8 default to 0, so github and
# registry status files keep an identical shape and pass nothing.)
_mcp_write_status_file() {
  jq -n \
    --arg status "$2" --arg note "$3" \
    --argjson scanned "$4" --argjson malformed "$5" --argjson unkeyable "$6" \
    --argjson signalMissing "${7:-0}" --argjson signalEligible "${8:-0}" \
    '{status:$status,note:$note,scanned:$scanned,malformed:$malformed,unkeyable:$unkeyable,
      signalMissing:$signalMissing,signalEligible:$signalEligible}' \
    > "$1"
}

# _mcp_malformed_ratio_status <scanned> <malformed> -> "fail" | "" on stdout
_mcp_malformed_ratio_status() {
  local scanned="$1" malformed="$2"
  if [[ "$scanned" -le 0 ]]; then
    echo ""
    return 0
  fi
  if [[ "$scanned" -lt 5 ]]; then
    if [[ "$malformed" -gt 0 ]]; then echo "fail"; else echo ""; fi
    return 0
  fi
  python3 -c "
import sys
scanned=$scanned
malformed=$malformed
ratio = malformed/scanned
print('fail' if ratio > $MCP_SWEEP_MAX_MALFORMED_RATIO else '')
"
}

_mcp_ratio_pct() {
  python3 -c "
scanned=$1
malformed=$2
print(round((malformed/scanned)*100) if scanned>0 else 0)
"
}

# _mcp_signal_missing_ratio_exceeds <signalMissing> <signalEligible> <maxRatio>
# -> "yes"/"no" on stdout (D24 signal-integrity tripwire).
_mcp_signal_missing_ratio_exceeds() {
  python3 -c "
missing=$1
eligible=$2
max_ratio=$3
print('yes' if eligible > 0 and (missing/eligible) > max_ratio else 'no')
"
}

# ---------------------------------------------------------------------------
# D2 — fetchers. Every fetcher emits NDJSON on stdout (nothing if the final
# status is `failed` — D9r2's "records used: no" for failed sources) and
# writes $MCP_SWEEP_WORKDIR/status-<source>.json (D9r2's four-value enum +
# closed-vocabulary note). Exit 0 unless status==failed (exit 3).
#
# Design simplification, documented: within one fetcher, multiple query
# variants (npm's three text= queries; GitHub's two topic: queries) are not
# cross-query-deduplicated before emission — mcp_merge (the next pipeline
# stage) already deduplicates by key across every record from every source,
# so a duplicate seen twice within one fetcher collapses there exactly as a
# duplicate seen across sources does. The only cost is that `scanned`/
# `malformed` can be mildly inflated by cross-query overlap, which does not
# change the malformed-ratio ballpark for any real query set.
# ---------------------------------------------------------------------------

mcp_fetch_npm() {
  local lookback_days="${1:-$MCP_SWEEP_LOOKBACK_DAYS}"
  : "${MCP_SWEEP_WORKDIR:?MCP_SWEEP_WORKDIR must be set}"
  # npm's public search API documents no server-side date filter (verified
  # against §Context's source research) — `lookback_days` is accepted for
  # interface consistency but intentionally unused here. D4: "every date
  # filter is an optimization; the seen-set diff is authoritative." For npm
  # specifically there is no filter to apply, so the diff carries the full
  # weight, which is correct and was anticipated by D4's own text.
  : "$lookback_days"

  local -a queries=("text=mcp-server" "text=keywords%3Amcp" "text=modelcontextprotocol")
  local scanned=0 malformed=0 unkeyable=0 hit_page_cap=0
  local hard_fail=0 fail_note=""
  local signal_missing=0 signal_eligible=0
  local records_file present_values_file
  records_file="$(mktemp)"
  present_values_file="$(mktemp)"

  local q
  for q in "${queries[@]}"; do
    [[ "$hard_fail" -eq 1 ]] && break
    local page=0
    while [[ "$page" -lt "$MCP_SWEEP_NPM_MAX_PAGES" ]]; do
      local from=$((page * MCP_SWEEP_NPM_PAGE_SIZE))
      local url="https://registry.npmjs.org/-/v1/search?${q}&size=${MCP_SWEEP_NPM_PAGE_SIZE}&from=${from}"
      local err_file body
      err_file="$(mktemp)"
      if ! body="$(mcp_http_get "$url" 2>"$err_file")"; then
        fail_note="$(_mcp_note_from_http_token "$(cat "$err_file")")"
        rm -f "$err_file"
        hard_fail=1
        break
      fi
      rm -f "$err_file"

      if ! printf '%s' "$body" | jq -e '(.objects|type)=="array" and (.total|type)=="number"' >/dev/null 2>&1; then
        fail_note="schema_envelope"
        hard_fail=1
        break
      fi

      local n
      n="$(printf '%s' "$body" | jq '.objects | length')"
      scanned=$((scanned + n))

      local obj name url_field date key
      while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        name="$(printf '%s' "$obj" | jq -r '.package.name // empty')"
        if [[ -z "$name" ]]; then
          malformed=$((malformed + 1))
          continue
        fi

        # D23 extraction — one added jq call per object, run for every
        # record that reached this point (signalEligible per D24). `-1` is
        # the sentinel for absent/non-numeric/negative; it is coerced to `0`
        # before ever reaching --argjson so a string can never satisfy a
        # numeric bar (jq sorts strings above all numbers).
        signal_eligible=$((signal_eligible + 1))
        local dl_raw downloads
        # `|| dl_raw=""` is load-bearing, not defensive style: under the
        # entrypoint's `set -e`, an assignment via a failing command
        # substitution (e.g. a runtime type error inside the jq filter on
        # an unexpected shape) terminates the whole script immediately,
        # silently dropping every remaining record in this fetch. The
        # `[[ ... ]]` re-validation below still applies regardless of which
        # branch set dl_raw, so both a jq failure and a jq success that
        # somehow prints something non-numeric collapse to the same -1
        # sentinel.
        dl_raw="$(printf '%s' "$obj" | jq -r '
          (.downloads.monthly // .package.downloads.monthly) as $d
          | if ($d|type)=="number" and $d >= 0 then ($d|floor) else -1 end
        ' 2>/dev/null)" || dl_raw=""
        if [[ -z "$dl_raw" || ! "$dl_raw" =~ ^-?[0-9]+$ ]]; then
          dl_raw=-1
        fi
        downloads=0
        if [[ "$dl_raw" == "-1" ]]; then
          signal_missing=$((signal_missing + 1))
        else
          downloads="$dl_raw"
          printf '%s\n' "$downloads" >> "$present_values_file"
        fi

        url_field="$(printf '%s' "$obj" | jq -r '.package.links.repository // empty')"
        date="$(printf '%s' "$obj" | jq -r '.package.date // empty')"

        key=""
        key="$(mcp_normalize_key "$url_field" npm "$name" 2>/dev/null)" || key=""
        if [[ -z "$key" || -z "$date" ]] || ! _mcp_valid_rfc3339 "$date"; then
          unkeyable=$((unkeyable + 1))
          continue
        fi

        _mcp_emit_ndjson_row "$key" "$(_mcp_key_last_segment "$key")" npm "$name" "$date" 0 "$downloads" "" >> "$records_file"
      done < <(printf '%s' "$body" | jq -c '.objects[]')

      if [[ "$n" -lt "$MCP_SWEEP_NPM_PAGE_SIZE" ]]; then
        break
      fi
      page=$((page + 1))
      if [[ "$page" -ge "$MCP_SWEEP_NPM_MAX_PAGES" ]]; then
        hit_page_cap=1
        break
      fi
    done
  done

  # D24 signal-integrity tripwire — degenerate check computed only over
  # present-and-numeric values, so a fully-absent field (which already
  # satisfies signal_absent) can never also satisfy signal_degenerate.
  local present_count=0 distinct_count=0
  present_count="$(wc -l < "$present_values_file" 2>/dev/null | tr -d ' ')"
  [[ -z "$present_count" ]] && present_count=0
  if [[ "$present_count" -gt 0 ]]; then
    distinct_count="$(sort -u "$present_values_file" | wc -l | tr -d ' ')"
  fi

  local status note
  if [[ "$hard_fail" -eq 1 ]]; then
    status="failed"
    note="$fail_note"
  else
    local ratio_verdict
    ratio_verdict="$(_mcp_malformed_ratio_status "$scanned" "$malformed")"
    if [[ "$ratio_verdict" == "fail" ]]; then
      status="failed"
      note="schema_ratio_$(_mcp_ratio_pct "$scanned" "$malformed")"
    elif [[ "$signal_eligible" -ge "$MCP_SWEEP_NPM_SIGNAL_MIN_SAMPLE" ]] \
      && [[ "$(_mcp_signal_missing_ratio_exceeds "$signal_missing" "$signal_eligible" "$MCP_SWEEP_NPM_MAX_SIGNAL_MISSING_RATIO")" == "yes" ]]; then
      status="partial"
      note="signal_absent"
    elif [[ "$present_count" -ge "$MCP_SWEEP_NPM_SIGNAL_MIN_SAMPLE" && "$distinct_count" -eq 1 ]]; then
      status="partial"
      note="signal_degenerate"
    elif [[ "$scanned" -eq 0 ]]; then
      status="ok_empty"
      note=""
    elif [[ "$hit_page_cap" -eq 1 ]]; then
      status="partial"
      note="page_cap"
    else
      status="ok"
      note=""
    fi
  fi

  _mcp_write_status_file "$MCP_SWEEP_WORKDIR/status-npm.json" "$status" "$note" "$scanned" "$malformed" "$unkeyable" "$signal_missing" "$signal_eligible"

  if [[ "$status" != "failed" ]]; then
    cat "$records_file"
  fi
  rm -f "$records_file" "$present_values_file"

  [[ "$status" == "failed" ]] && return 3
  return 0
}

mcp_fetch_github() {
  local lookback_days="${1:-$MCP_SWEEP_LOOKBACK_DAYS}"
  : "${MCP_SWEEP_WORKDIR:?MCP_SWEEP_WORKDIR must be set}"

  local since
  since="$(mcp_rfc3339_days_ago "$lookback_days")"
  local since_date="${since%%T*}"

  local -a headers=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers=("Authorization: token ${GITHUB_TOKEN}")
  fi

  local -a topics=("topic:mcp-server" "topic:modelcontextprotocol")
  local scanned=0 malformed=0 unkeyable=0 hit_page_cap=0
  local hard_fail=0 fail_note=""
  local records_file
  records_file="$(mktemp)"

  local topic
  for topic in "${topics[@]}"; do
    [[ "$hard_fail" -eq 1 ]] && break
    local q_raw="${topic} pushed:>=${since_date}"
    local q
    q="$(mcp_uri_encode "$q_raw")"
    local page=1
    while [[ "$page" -le "$MCP_SWEEP_GH_MAX_PAGES" ]]; do
      local url="https://api.github.com/search/repositories?q=${q}&sort=stars&per_page=${MCP_SWEEP_GH_PER_PAGE}&page=${page}"
      local err_file body get_rc
      err_file="$(mktemp)"
      # See mcp_http_get's own comment: nounset-safe empty-array guard.
      if [[ "${#headers[@]}" -gt 0 ]]; then
        body="$(mcp_http_get "$url" "${headers[@]}" 2>"$err_file")"
      else
        body="$(mcp_http_get "$url" 2>"$err_file")"
      fi
      get_rc=$?
      if [[ "$get_rc" -ne 0 ]]; then
        fail_note="$(_mcp_note_from_http_token "$(cat "$err_file")")"
        rm -f "$err_file"
        hard_fail=1
        break
      fi
      rm -f "$err_file"

      if ! printf '%s' "$body" | jq -e '(.items|type)=="array" and (.total_count|type)=="number"' >/dev/null 2>&1; then
        fail_note="schema_envelope"
        hard_fail=1
        break
      fi

      local n
      n="$(printf '%s' "$body" | jq '.items | length')"
      scanned=$((scanned + n))

      local obj full_name html_url pushed_at stars key
      while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        full_name="$(printf '%s' "$obj" | jq -r '.full_name // empty')"
        if [[ -z "$full_name" ]]; then
          malformed=$((malformed + 1))
          continue
        fi
        html_url="$(printf '%s' "$obj" | jq -r '.html_url // empty')"
        pushed_at="$(printf '%s' "$obj" | jq -r '.pushed_at // empty')"
        stars="$(printf '%s' "$obj" | jq -r '.stargazers_count // 0')"

        key=""
        key="$(mcp_normalize_key "$html_url" github "$full_name" 2>/dev/null)" || key=""
        if [[ -z "$key" || -z "$pushed_at" ]] || ! _mcp_valid_rfc3339 "$pushed_at"; then
          unkeyable=$((unkeyable + 1))
          continue
        fi

        _mcp_emit_ndjson_row "$key" "$(_mcp_key_last_segment "$key")" github "$full_name" "$pushed_at" "$stars" 0 "" >> "$records_file"
      done < <(printf '%s' "$body" | jq -c '.items[]')

      if [[ "$n" -lt "$MCP_SWEEP_GH_PER_PAGE" ]]; then
        break
      fi
      if [[ "$page" -ge "$MCP_SWEEP_GH_MAX_PAGES" ]]; then
        hit_page_cap=1
        break
      fi
      page=$((page + 1))
    done
  done

  local status note
  if [[ "$hard_fail" -eq 1 ]]; then
    status="failed"
    note="$fail_note"
  else
    local ratio_verdict
    ratio_verdict="$(_mcp_malformed_ratio_status "$scanned" "$malformed")"
    if [[ "$ratio_verdict" == "fail" ]]; then
      status="failed"
      note="schema_ratio_$(_mcp_ratio_pct "$scanned" "$malformed")"
    elif [[ "$scanned" -eq 0 ]]; then
      status="ok_empty"
      note=""
    elif [[ "$hit_page_cap" -eq 1 ]]; then
      status="partial"
      note="page_cap"
    else
      status="ok"
      note=""
    fi
  fi

  _mcp_write_status_file "$MCP_SWEEP_WORKDIR/status-github.json" "$status" "$note" "$scanned" "$malformed" "$unkeyable"

  if [[ "$status" != "failed" ]]; then
    cat "$records_file"
  fi
  rm -f "$records_file"

  [[ "$status" == "failed" ]] && return 3
  return 0
}

# _mcp_registry_fetch_page <base_path> <cursor_or_empty> -> body on stdout,
# curl's exit semantics via mcp_http_get (0 ok / 3 fail, token on stderr).
_mcp_registry_fetch_page() {
  local path="$1" cursor="$2"
  local url="https://registry.modelcontextprotocol.io${path}?limit=${MCP_SWEEP_REGISTRY_LIMIT}"
  if [[ -n "$cursor" ]]; then
    local encoded
    encoded="$(mcp_uri_encode "$cursor")"
    url="${url}&cursor=${encoded}"
  fi
  mcp_http_get "$url"
}

mcp_fetch_registry() {
  local lookback_days="${1:-$MCP_SWEEP_LOOKBACK_DAYS}"
  : "${MCP_SWEEP_WORKDIR:?MCP_SWEEP_WORKDIR must be set}"

  local since
  since="$(mcp_rfc3339_days_ago "$lookback_days")"

  local effective_path="$MCP_SWEEP_REGISTRY_PATH"
  local scanned=0 malformed=0 unkeyable=0 hit_page_cap=0 cursor_invalid=0
  local hard_fail=0 fail_note=""
  local records_file
  records_file="$(mktemp)"

  # First page, with D6's one-alternate-path-attempt fallback on any doubt.
  local err_file body page_ok=0
  err_file="$(mktemp)"
  if body="$(_mcp_registry_fetch_page "$effective_path" "" 2>"$err_file")" \
     && printf '%s' "$body" | jq -e '(.servers|type)=="array" and (.metadata|type)=="object"' >/dev/null 2>&1; then
    page_ok=1
  else
    rm -f "$err_file"
    effective_path="$MCP_SWEEP_REGISTRY_PATH_FALLBACK"
    err_file="$(mktemp)"
    if body="$(_mcp_registry_fetch_page "$effective_path" "" 2>"$err_file")" \
       && printf '%s' "$body" | jq -e '(.servers|type)=="array" and (.metadata|type)=="object"' >/dev/null 2>&1; then
      page_ok=1
    else
      local tok
      tok="$(cat "$err_file")"
      if [[ -n "$tok" ]]; then
        fail_note="$(_mcp_note_from_http_token "$tok")"
      else
        fail_note="schema_envelope"
      fi
      hard_fail=1
    fi
  fi
  rm -f "$err_file"

  local cursor=""
  local page_count=0
  while [[ "$hard_fail" -eq 0 && "$page_ok" -eq 1 ]]; do
    page_count=$((page_count + 1))

    local n
    n="$(printf '%s' "$body" | jq '.servers | length')"
    scanned=$((scanned + n))

    local obj name repo_url updated_at published_at status ts key
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      name="$(printf '%s' "$obj" | jq -r '.server.name // empty')"
      if [[ -z "$name" ]]; then
        malformed=$((malformed + 1))
        continue
      fi
      repo_url="$(printf '%s' "$obj" | jq -r '.server.repository.url // empty')"
      updated_at="$(printf '%s' "$obj" | jq -r '._meta["io.modelcontextprotocol.registry/official"].updatedAt // empty')"
      published_at="$(printf '%s' "$obj" | jq -r '._meta["io.modelcontextprotocol.registry/official"].publishedAt // empty')"
      status="$(printf '%s' "$obj" | jq -r '._meta["io.modelcontextprotocol.registry/official"].status // empty')"

      ts="$updated_at"
      [[ -z "$ts" ]] && ts="$published_at"

      key=""
      key="$(mcp_normalize_key "$repo_url" registry "$name" 2>/dev/null)" || key=""
      if [[ -z "$key" || -z "$ts" ]] || ! _mcp_valid_rfc3339 "$ts"; then
        unkeyable=$((unkeyable + 1))
        continue
      fi

      _mcp_emit_ndjson_row "$key" "$(_mcp_key_last_segment "$key")" registry "$name" "$ts" 0 0 "$status" >> "$records_file"
    done < <(printf '%s' "$body" | jq -c '.servers[]')

    local next_cursor
    next_cursor="$(printf '%s' "$body" | jq -r '.metadata.nextCursor // empty')"

    if [[ -z "$next_cursor" ]]; then
      break
    fi

    # D6r1: cursor validated against ^[A-Za-z0-9._~=-]{1,256}$. Length and
    # charclass checked separately rather than as a `{1,256}` interval
    # inside `[[ =~ ]]` — bash 3.2 (macos-latest's /bin/bash) does not
    # reliably support interval expressions there (live-verified: a plain
    # `{1,256}` quantifier silently fails to match even trivially
    # conforming input on that runtime).
    cursor_len="${#next_cursor}"
    if [[ "$cursor_len" -lt 1 || "$cursor_len" -gt 256 || ! "$next_cursor" =~ ^[A-Za-z0-9._~=-]+$ ]]; then
      cursor_invalid=1
      break
    fi

    if [[ "$page_count" -ge "$MCP_SWEEP_REGISTRY_MAX_PAGES" ]]; then
      hit_page_cap=1
      break
    fi

    cursor="$next_cursor"
    local page_err_file
    page_err_file="$(mktemp)"
    if ! body="$(_mcp_registry_fetch_page "$effective_path" "$cursor" 2>"$page_err_file")"; then
      fail_note="$(_mcp_note_from_http_token "$(cat "$page_err_file")")"
      rm -f "$page_err_file"
      hard_fail=1
      break
    fi
    rm -f "$page_err_file"
    if ! printf '%s' "$body" | jq -e '(.servers|type)=="array" and (.metadata|type)=="object"' >/dev/null 2>&1; then
      fail_note="schema_envelope"
      hard_fail=1
      break
    fi
  done

  local status note
  if [[ "$hard_fail" -eq 1 ]]; then
    status="failed"
    note="$fail_note"
  else
    local ratio_verdict
    ratio_verdict="$(_mcp_malformed_ratio_status "$scanned" "$malformed")"
    if [[ "$ratio_verdict" == "fail" ]]; then
      status="failed"
      note="schema_ratio_$(_mcp_ratio_pct "$scanned" "$malformed")"
    elif [[ "$cursor_invalid" -eq 1 ]]; then
      status="partial"
      note="cursor_invalid"
    elif [[ "$scanned" -eq 0 ]]; then
      status="ok_empty"
      note="path=${effective_path}"
    elif [[ "$hit_page_cap" -eq 1 ]]; then
      status="partial"
      note="page_cap"
    else
      status="ok"
      note="path=${effective_path}"
    fi
  fi

  _mcp_write_status_file "$MCP_SWEEP_WORKDIR/status-registry.json" "$status" "$note" "$scanned" "$malformed" "$unkeyable"

  if [[ "$status" != "failed" ]]; then
    cat "$records_file"
  fi
  rm -f "$records_file"

  [[ "$status" == "failed" ]] && return 3
  return 0
}

# ---------------------------------------------------------------------------
# D14/monorepo — mcp_merge. Reads NDJSON on stdin (the union of all three
# fetchers' output, duplicates across queries/sources included — see the
# fetchers' own "design simplification" note). Disambiguates same-run
# monorepo collisions (npm-sourced records sharing one coarse `gh:owner/repo`
# key under >1 distinct npm package name get split by sanitized package
# name — github/registry members of the same coarse key are left alone, as
# they represent the umbrella repo itself), then dedupes by final key,
# unions `sources`, takes the per-key max `updatedUtc` and max signal.
#
# Known limitation (documented, not hidden): `updatedUtc` max-selection uses
# lexicographic string comparison, which is chronologically correct only
# when every contributing timestamp uses the same fractional-seconds
# convention (all three live sources verified 2026-07-28 to emit whole-
# second `...Z` timestamps with no fractional component, so this holds in
# practice; a future source emitting fractional seconds could reorder
# against a same-second whole-second value from another source).
# ---------------------------------------------------------------------------
mcp_merge() {
  local raw_file merged_file
  raw_file="$(mktemp)"
  cat > "$raw_file"

  merged_file="$(mktemp)"
  jq -cs '
    def sanitize: ascii_downcase | ltrimstr("@") | gsub("/"; "-") | gsub("[^a-z0-9._-]"; "-");

    . as $all
    | ( $all
        | map(select(.source=="npm" and (.key|startswith("gh:")) and (.key|contains("#")|not)))
        | group_by(.key)
        | map(select((map(.sourceId) | unique | length) > 1))
        | map(.[0].key)
      ) as $ambiguous_keys
    | map(
        if (.source=="npm") and (.key as $k | ($ambiguous_keys | index($k)) != null)
        then .key = (.key + "#pkg/" + (.sourceId | sanitize))
        else .
        end
      )
    | group_by(.key)
    | map({
        key: .[0].key,
        sources: (map(.source) | unique | sort),
        sourceIds: (reduce .[] as $r ({}; .[$r.source] = $r.sourceId)),
        updatedUtc: (map(.updatedUtc) | sort | .[-1]),
        signal: {
          stars: (map(.signal.stars) | max),
          npmDownloadsMonthly: (map(.signal.npmDownloadsMonthly) | max),
          registryStatus: ([.[] | .signal.registryStatus | select(length > 0)] | .[0] // "")
        }
      })
    | sort_by(.key)
    | .[]
  ' "$raw_file" > "$merged_file"

  local line key name
  while IFS= read -r line; do
    key="$(printf '%s' "$line" | jq -r '.key')"
    name="$(_mcp_key_last_segment "$key")"
    printf '%s' "$line" | jq -c --arg name "$name" '. + {name: $name}'
  done < "$merged_file"

  rm -f "$raw_file" "$merged_file"
}

# ---------------------------------------------------------------------------
# mcp_apply_bar — registry-sourced records are exempt (D9r2). Otherwise a
# record passes if EITHER contributing signal independently clears its own
# bar: stars >= MCP_SWEEP_GH_MIN_STARS OR npmDownloadsMonthly >=
# MCP_SWEEP_NPM_MIN_DOWNLOADS_MONTHLY (ADR-046 revision 3, D23 — the old npm
# relevance field is deleted; it was text-relevance, not quality, and gated
# nothing at ~570x over its own threshold).
# ---------------------------------------------------------------------------
mcp_apply_bar() {
  jq -c \
    --argjson gh_min "$MCP_SWEEP_GH_MIN_STARS" \
    --argjson npm_min_downloads "$MCP_SWEEP_NPM_MIN_DOWNLOADS_MONTHLY" \
    'select(
       (.sources | index("registry") != null)
       or ((.signal.stars // 0) >= $gh_min)
       or (((.signal.npmDownloadsMonthly // 0) | if type=="number" then . else 0 end) >= $npm_min_downloads)
     )'
}

# ---------------------------------------------------------------------------
# mcp_wired_tokens <template.json> <known.json> -> newline token set
# (lowercased, sorted, deduped). Auto-derived from the template (server key
# name; URL host with `mcp.` prefix stripped; npx package arg with trailing
# `@<version>` stripped) UNION every value in known.json's `wiredAliases`.
# ---------------------------------------------------------------------------
mcp_wired_tokens() {
  local template_json="$1" known_json="$2"
  {
    jq -r '
      .mcpServers // {} | to_entries[] | (
        .key,
        (if .value.type == "http" then
           (.value.url | capture("https?://(?<h>[^/]+)"; "i").h | sub("^mcp\\."; ""))
         else empty end),
        (if .value.command == "npx" then
           ((.value.args // []) | last // "" | sub("@[^@/]+$"; ""))
         else empty end)
      )
    ' "$template_json" 2>/dev/null

    if [[ -f "$known_json" ]]; then
      jq -r '.wiredAliases // {} | .[] | .[]' "$known_json" 2>/dev/null
    fi
  } | grep -v '^$' | tr '[:upper:]' '[:lower:]' | sort -u
}

# ---------------------------------------------------------------------------
# mcp_classify < merged -> merged + {"status":"pending|wired|ignored"}.
# Wired matching checks the merged key AND every sourceId AND every
# per-source "<source>:<sourceId>" form (§Interface deltas revision 1 —
# extends alias reach to sourceIds and per-source keys, not just the
# merged key). Ignored matching is exact-key against config/mcp-sweep-
# known.json's `ignored` map (keyed by the same canonical key shape).
# ---------------------------------------------------------------------------
mcp_classify() {
  local wired_file="$1" known_json="$2"
  local ignored_json
  ignored_json="$(jq -c '(.ignored // {}) | keys' "$known_json" 2>/dev/null || echo '[]')"

  jq -c \
    --rawfile wired_raw "$wired_file" \
    --argjson ignored "$ignored_json" \
    '
    ($wired_raw | split("\n") | map(select(length > 0))) as $wired
    | . as $r
    | ($r.sourceIds // {}) as $sids
    | ( [$r.key]
        + ($sids | to_entries | map(.value))
        + ($sids | to_entries | map(.key + ":" + .value))
      | map(ascii_downcase)
      ) as $candidates
    | (($ignored | index($r.key)) != null) as $is_ignored
    | (any($candidates[]; . as $c | ($wired | index($c)) != null)) as $is_wired
    | $r + { status: (if $is_ignored then "ignored" elif $is_wired then "wired" else "pending" end) }
    '
}

# ---------------------------------------------------------------------------
# mcp_load_state <path> -> state JSON on stdout; seed-mode JSON on absent/
# unparseable/wrong-version/invalid (D11 revision 2 — all four collapse to
# the same recovery path, mcp_state.py's load() already treats them
# identically).
# ---------------------------------------------------------------------------
mcp_load_state() {
  local path="$1"
  local loaded
  loaded="$(python3 "$MCP_SWEEP_LIB_DIR/mcp_state.py" load "$path" 2>/dev/null || echo "null")"

  if [[ -z "$loaded" || "$loaded" == "null" ]]; then
    local now
    now="$(mcp_now_utc)"
    jq -n --arg now "$now" '{
      v: 3, mode: "seed", lastRunUtc: $now, ackedAtUtc: $now,
      cleanRuns: 0, dropped: 0, pending: {}, aged: [],
      sourceHealth: {
        npm: {failStreak:0,alertedAt:0,pageCapStreak:0,pageCapAlertedAt:0},
        github: {failStreak:0,alertedAt:0,pageCapStreak:0,pageCapAlertedAt:0},
        registry: {failStreak:0,alertedAt:0,pageCapStreak:0,pageCapAlertedAt:0}
      },
      allEmptyStreak: 0, allEmptyAlertedAt: 0
    }'
  else
    printf '%s' "$loaded"
  fi
}

# mcp_source_status <source> -> one of ok|ok_empty|partial|failed. Reads
# $MCP_SWEEP_WORKDIR/status-<source>.json (D9r2's four-value enum).
mcp_source_status() {
  local source="$1"
  : "${MCP_SWEEP_WORKDIR:?MCP_SWEEP_WORKDIR must be set}"
  jq -r '.status // "failed"' "$MCP_SWEEP_WORKDIR/status-${source}.json" 2>/dev/null || echo "failed"
}

# ---------------------------------------------------------------------------
# mcp_render_body <state.json> <candidates.ndjson> <source-status.json>
# -> markdown on stdout. `candidates.ndjson` is accepted per the interface
# contract but unused directly by rendering (D15.2: every rendered value is
# derived from a validated key, never from fetched record text) — pending
# rows come entirely from state.json's key->firstSeenUtc map, resolved
# through mcp_derive_url. `source-status.json` may carry an optional `_meta`
# object (`anomalous`, `healthLines`, `droppedCount`, `belowBarCount`) that
# the entrypoint pre-computes from state-machine transitions the renderer
# itself has no business knowing about.
#
# No hidden block, no marker, no HTML comment of any kind (revision 2 —
# machine state lives in --state-out, not here).
# ---------------------------------------------------------------------------
mcp_render_body() {
  local state_file="$1" candidates_file="$2" source_status_file="$3"
  : "$candidates_file"

  local mode last_run pending_count
  mode="$(jq -r '.mode' "$state_file")"
  last_run="$(jq -r '.lastRunUtc' "$state_file")"
  pending_count="$(jq '.pending | length' "$state_file")"

  echo "## MCP server sweep (rolling)"
  echo
  echo "Multi-source scripted sweep (npm registry, GitHub topic search, the"
  echo "official MCP registry). Body is regenerated every run — human"
  echo "decisions live in \`config/mcp-sweep-known.json\` (PR-reviewed) or the"
  echo "\`${MCP_SWEEP_ISSUE_LABEL}-hold\` label, never in this body."
  echo

  if [[ "$mode" == "seed" ]]; then
    echo "**Seed run.** First observation of the current backlog (state was"
    echo "absent, unreadable, or from a prior schema version). No comment"
    echo "posted, issue not closed or reopened this run."
    echo
  fi

  local anomalous
  anomalous="$(jq -r '._meta.anomalous // false' "$source_status_file" 2>/dev/null)"
  if [[ "$anomalous" == "true" ]]; then
    echo "**Anomaly:** every enabled source returned zero records this run."
    echo "Treated as suspicious, not clean — does not count toward auto-close"
    echo "(D22)."
    echo
  fi

  echo "**Pending: ${pending_count}**"
  echo
  if [[ "$pending_count" -gt 0 ]]; then
    echo "| Server | First seen |"
    echo "|---|---|"
    local rows_shown=0 k fs url name
    while IFS=$'\t' read -r k fs; do
      [[ "$rows_shown" -ge "$MCP_SWEEP_MAX_RENDER" ]] && break
      url="$(mcp_derive_url "$k" 2>/dev/null || echo "")"
      name="$(_mcp_key_last_segment "$k")"
      if [[ -n "$url" ]]; then
        echo "| [${name}](${url}) | ${fs} |"
      else
        echo "| ${name} | ${fs} |"
      fi
      rows_shown=$((rows_shown + 1))
    done < <(jq -r '.pending | to_entries | sort_by(.value)[] | [.key, .value] | @tsv' "$state_file")

    if [[ "$pending_count" -gt "$MCP_SWEEP_MAX_RENDER" ]]; then
      echo
      echo "_...and $((pending_count - MCP_SWEEP_MAX_RENDER)) more pending (full list in the run artifact)._"
    fi
  fi
  echo

  echo "### Source status"
  echo
  echo "| Source | Status | Scanned | Note |"
  echo "|---|---|---|---|"
  local src st sc note
  for src in npm github registry; do
    st="$(jq -r --arg s "$src" '.[$s].status // "failed"' "$source_status_file" 2>/dev/null)"
    sc="$(jq -r --arg s "$src" '.[$s].scanned // 0' "$source_status_file" 2>/dev/null)"
    note="$(jq -r --arg s "$src" '.[$s].note // ""' "$source_status_file" 2>/dev/null)"
    echo "| ${src} | ${st} | ${sc} | ${note} |"
  done
  echo

  local health_line
  while IFS= read -r health_line; do
    [[ -z "$health_line" ]] && continue
    echo "$health_line"
    echo
  done < <(jq -r '._meta.healthLines // [] | .[]' "$source_status_file" 2>/dev/null)

  local aged_count
  aged_count="$(jq '.aged | length' "$state_file")"
  if [[ "$aged_count" -gt 0 ]]; then
    echo "<details><summary>Aged out (${aged_count}, no longer re-reported by"
    echo "default; permanent suppression is \`ignored\` in"
    echo "\`config/mcp-sweep-known.json\`)</summary>"
    echo
    local shown=0 ak
    while IFS= read -r ak; do
      [[ "$shown" -ge "$MCP_SWEEP_AGED_RENDER" ]] && break
      echo "- \`${ak}\`"
      shown=$((shown + 1))
    done < <(jq -r '.aged[-'"$MCP_SWEEP_AGED_RENDER"':][]' "$state_file" 2>/dev/null)
    if [[ "$aged_count" -gt "$MCP_SWEEP_AGED_RENDER" ]]; then
      echo
      echo "_...and $((aged_count - MCP_SWEEP_AGED_RENDER)) more (full list in the run artifact)._"
    fi
    echo "</details>"
    echo
  fi

  local dropped_count below_bar_count
  dropped_count="$(jq -r '._meta.droppedCount // 0' "$source_status_file" 2>/dev/null)"
  below_bar_count="$(jq -r '._meta.belowBarCount // 0' "$source_status_file" 2>/dev/null)"
  echo "Dropped (unkeyable/malformed, count-only per D15): ${dropped_count}."
  echo "Below bar: ${below_bar_count}."
  echo
  echo "mcpmarket.com publishes a daily list but serves a JS challenge to"
  echo "headless clients and cannot be swept: <https://mcpmarket.com/server>"
  echo "(browse manually)."
  echo
  echo "_Last run: ${last_run}_"
}

# mcp_render_minimal_body <state.json> -> markdown. D18r2's second (and
# final) fallback rung: counts only, zero rows, zero aged list, one line
# saying the full rendering was suppressed. Used only when the normal
# render exceeds MCP_SWEEP_BODY_MAX_BYTES.
mcp_render_minimal_body() {
  local state_file="$1"
  local pending_count aged_count last_run
  pending_count="$(jq '.pending | length' "$state_file")"
  aged_count="$(jq '.aged | length' "$state_file")"
  last_run="$(jq -r '.lastRunUtc' "$state_file")"

  echo "## MCP server sweep (rolling)"
  echo
  echo "**Full rendering suppressed** — the assembled body exceeded"
  echo "${MCP_SWEEP_BODY_MAX_BYTES} bytes. Counts only; see the run artifact"
  echo "for the full backlog."
  echo
  echo "Pending: ${pending_count}. Aged: ${aged_count}."
  echo
  echo "_Last run: ${last_run}_"
}
