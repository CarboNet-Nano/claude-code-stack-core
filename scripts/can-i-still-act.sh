#!/usr/bin/env bash
# can-i-still-act.sh — the writer-independent oracle for D18 P4/P5 (ADR-088 D7).
#
# It does NOT read the broker's config or the settings files to form a verdict:
# it attempts the action and reports what happened. Per surface it probes >=2
# distinct endpoints, retries each twice with backoff on network error, and
# classifies into the closed set:
#
#   REACHABLE          — an authenticated-or-open call got a non-auth 2xx/3xx
#   DENIED_BY_SANDBOX  — the network layer refused (proxy CONNECT 403, DNS,
#                        connect refused/timeout) before any vendor answered
#   DENIED_BY_AUTH     — >=2 distinct endpoints returned an auth-class status
#                        (401/403 from the vendor itself) across >=2 attempts
#   DENIED_BY_HOOK     — a PreToolUse hook denied the probing command itself
#   UNKNOWN            — anything else (5xx, mixed evidence, never-run)
#
# UNKNOWN always fails a gate; a never-run probe is UNKNOWN, never DENIED
# (ADR-085). DENIED_BY_AUTH is deliberately hard to earn: one 401 on one
# endpoint is not a dead credential.
#
# Usage:
#   can-i-still-act.sh [--json] [--surface <name>] [--via-broker]
#                      [--outside-sandbox] [--expect <status>]
#
# --expect <status>  exit 0 iff every probed surface's status == <status>
#                    (case-insensitive); otherwise exit 1.
# --via-broker       probe each surface through `stack-broker` read ops
#                    instead of direct vendor calls.
# --outside-sandbox  assert this run is NOT inside the Claude Code sandbox.
#                    A network-blocked key looks dead from inside; that exact
#                    false-green is what P5 must not accept. If sandbox markers
#                    are present the run refuses and reports UNKNOWN.
#
# Test hooks (config only, never credentials):
#   STACK_PROBE_CONFIG      JSON file overriding the endpoint table
#   STACK_PROBE_BACKOFF_MS  backoff unit in ms (default 1000)
#   STACK_PROBE_TIMEOUT_S   per-attempt timeout (default 10)

set -uo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

JSON=0; SURFACE=""; VIA_BROKER=0; OUTSIDE=0; EXPECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1 ;;
    --surface) SURFACE="${2:-}"; shift ;;
    --via-broker) VIA_BROKER=1 ;;
    --outside-sandbox) OUTSIDE=1 ;;
    --expect) EXPECT="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

BACKOFF_MS="${STACK_PROBE_BACKOFF_MS:-1000}"
TIMEOUT_S="${STACK_PROBE_TIMEOUT_S:-10}"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl required" >&2; exit 2; }

# ── Endpoint table ──────────────────────────────────────────────────────────
# Two distinct endpoints per surface. Auth headers are attached only when the
# corresponding credential is present in the environment the agent would use;
# an unauthenticated attempt is still an attempt (a 401 is an honest answer to
# "can I act?").
default_probe_config() {
  jq -n '
  { surfaces: [
    { surface: "github", class: "write",
      endpoints: [
        { url: "https://api.github.com/user",       auth: "github" },
        { url: "https://api.github.com/rate_limit", auth: "github" } ] },
    { surface: "cloudflare", class: "write",
      endpoints: [
        { url: "https://api.cloudflare.com/client/v4/user/tokens/verify", auth: "cloudflare" },
        { url: "https://api.cloudflare.com/client/v4/accounts",           auth: "cloudflare" } ] },
    { surface: "neon", class: "write",
      endpoints: [
        { url: "https://console.neon.tech/api/v2/users/me",  auth: "neon" },
        { url: "https://console.neon.tech/api/v2/projects",  auth: "neon" } ] },
    { surface: "supabase", class: "write",
      endpoints: [
        { url: "https://api.supabase.com/v1/projects",      auth: "supabase" },
        { url: "https://api.supabase.com/v1/organizations", auth: "supabase" } ] },
    { surface: "netlify", class: "write",
      endpoints: [
        { url: "https://api.netlify.com/api/v1/user",     auth: "netlify" },
        { url: "https://api.netlify.com/api/v1/accounts", auth: "netlify" } ] }
  ] }'
}

if [[ -n "${STACK_PROBE_CONFIG:-}" ]]; then
  PROBE_CONFIG="$(cat "$STACK_PROBE_CONFIG" 2>/dev/null)" || { echo "FATAL: cannot read STACK_PROBE_CONFIG" >&2; exit 2; }
  echo "$PROBE_CONFIG" | jq -e . >/dev/null 2>&1 || { echo "FATAL: STACK_PROBE_CONFIG is not JSON" >&2; exit 2; }
else
  PROBE_CONFIG="$(default_probe_config)"
fi

# ── Credential lookup (headers only; values never printed) ─────────────────
auth_header_for() {
  local kind="$1" tok=""
  case "$kind" in
    github)
      tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
      [[ -z "$tok" ]] && command -v gh >/dev/null 2>&1 && tok="$(gh auth token 2>/dev/null || true)"
      [[ -n "$tok" ]] && printf 'Authorization: Bearer %s' "$tok" ;;
    cloudflare)
      tok="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"
      [[ -n "$tok" ]] && printf 'Authorization: Bearer %s' "$tok" ;;
    neon)
      tok="${NEON_API_KEY:-}"
      [[ -n "$tok" ]] && printf 'Authorization: Bearer %s' "$tok" ;;
    supabase)
      tok="${SUPABASE_ACCESS_TOKEN:-}"
      [[ -z "$tok" && -f "$HOME/.supabase/access-token" ]] && tok="$(cat "$HOME/.supabase/access-token" 2>/dev/null)"
      [[ -n "$tok" ]] && printf 'Authorization: Bearer %s' "$tok" ;;
    netlify)
      tok="${NETLIFY_AUTH_TOKEN:-}"
      [[ -n "$tok" ]] && printf 'Authorization: Bearer %s' "$tok" ;;
    none|"") : ;;
  esac
}

# ── One attempt: prints "<class> <http_code> <curl_exit>" ──────────────────
# class: ok | auth | sandbox | server | other
attempt_one() {
  local url="$1" auth_kind="$2"
  local hdr; hdr="$(auth_header_for "$auth_kind")"
  local code exit_code err
  local errfile; errfile="$(mktemp)"
  if [[ -n "$hdr" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT_S" -H "$hdr" "$url" 2>"$errfile")"
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT_S" "$url" 2>"$errfile")"
  fi
  exit_code=$?
  err="$(head -c 300 "$errfile" 2>/dev/null | tr -d '\n')"; rm -f "$errfile"
  if [[ $exit_code -eq 0 ]]; then
    case "$code" in
      2*|3*) echo "ok $code 0" ;;
      401|403) echo "auth $code 0" ;;
      5*) echo "server $code 0" ;;
      *) echo "other $code 0" ;;
    esac
    return 0
  fi
  # curl failed. Distinguish proxy/network denial from everything else.
  case "$exit_code" in
    5|6|7|28|35)
      echo "sandbox 000 $exit_code" ;;   # proxy/DNS/connect/timeout/TLS-to-proxy
    56)
      if [[ "$err" == *"CONNECT tunnel failed"* ]]; then
        echo "sandbox 000 56"            # proxy refused the tunnel
      else
        echo "other 000 56"
      fi ;;
    *) echo "other 000 $exit_code" ;;
  esac
}

# net-error retry: retry (twice, backoff) only when the failure could be
# transient network, i.e. class sandbox/other with curl exit != 0. A clean
# HTTP answer is final.
probe_endpoint() {
  local url="$1" auth_kind="$2"
  local out cls attempts=0
  while :; do
    out="$(attempt_one "$url" "$auth_kind")"
    cls="${out%% *}"
    attempts=$((attempts+1))
    local curl_exit="${out##* }"
    if [[ "$curl_exit" == "0" || $attempts -ge 3 ]]; then
      echo "$out $attempts"; return 0
    fi
    sleep "$(awk -v ms="$BACKOFF_MS" -v n="$attempts" 'BEGIN{printf "%.3f", ms*n/1000}')"
  done
}

# ── Surface classification ─────────────────────────────────────────────────
classify_surface() {
  # args: newline-joined endpoint classes (one per endpoint)
  local classes="$1"
  local n_ok=0 n_auth=0 n_sandbox=0 n_other=0 total=0
  local c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    total=$((total+1))
    case "$c" in
      ok) n_ok=$((n_ok+1)) ;;
      auth) n_auth=$((n_auth+1)) ;;
      sandbox) n_sandbox=$((n_sandbox+1)) ;;
      *) n_other=$((n_other+1)) ;;
    esac
  done <<< "$classes"
  if (( n_ok > 0 )); then echo "REACHABLE"; return; fi
  # DENIED_BY_AUTH only on >=2 distinct endpoints agreeing (>=2 attempts).
  if (( n_auth >= 2 && n_auth == total )); then echo "DENIED_BY_AUTH"; return; fi
  if (( n_sandbox >= 2 && n_sandbox == total )); then echo "DENIED_BY_SANDBOX"; return; fi
  echo "UNKNOWN"
}

# ── Sandbox detection for --outside-sandbox ────────────────────────────────
inside_claude_sandbox() {
  [[ -n "${CLAUDECODE:-}" ]] && return 0
  [[ -n "${CLAUDE_CODE_SSE_PORT:-}" ]] && return 0
  [[ -n "${HTTPS_PROXY:-}" && "${HTTPS_PROXY:-}" == *agentproxy* ]] && return 0
  [[ -f /root/.ccr/ca-bundle.crt ]] && return 0
  return 1
}

# ── Broker path ────────────────────────────────────────────────────────────
broker_probe_surface() {
  local surface="$1" op=""
  case "$surface" in
    cloudflare) op="cloudflare.worker.list" ;;
    neon) op="neon.database.describe" ;;
    github|github-read) op="github.repo.describe" ;;
    supabase) op="supabase.project.list" ;;
    netlify) op="netlify.site.list" ;;
    *) echo "UNKNOWN no-broker-op-mapped"; return ;;
  esac
  local rc=0
  if ! command -v stack-broker >/dev/null 2>&1; then
    echo "UNKNOWN stack-broker-not-installed"; return
  fi
  stack-broker "$op" --json >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "REACHABLE broker-exit-0" ;;
    3) echo "DENIED_BY_AUTH broker-refused-rc3" ;;   # not_provisioned et al: cannot act
    6) echo "UNKNOWN broker-unreachable" ;;
    *) echo "UNKNOWN broker-exit-$rc" ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTN="$(hostname 2>/dev/null || echo unknown)"

OUTSIDE_VIOLATION=0
if (( OUTSIDE )) && inside_claude_sandbox; then
  OUTSIDE_VIOLATION=1
fi

RESULTS="[]"
SURFACE_FILTER="$SURFACE"

while IFS= read -r s_json; do
  s_name="$(echo "$s_json" | jq -r '.surface')"
  s_class="$(echo "$s_json" | jq -r '.class // "write"')"
  if [[ -n "$SURFACE_FILTER" && "$s_name" != "$SURFACE_FILTER" ]]; then continue; fi

  if (( OUTSIDE_VIOLATION )); then
    status="UNKNOWN"
    detail="refused: --outside-sandbox requested but Claude Code sandbox markers present; run from a real terminal"
    endpoints_json="[]"
  elif (( VIA_BROKER )); then
    read -r status detail <<< "$(broker_probe_surface "$s_name")"
    endpoints_json="[]"
  else
    classes=""
    endpoints_json="[]"
    while IFS= read -r ep_json; do
      url="$(echo "$ep_json" | jq -r '.url')"
      auth="$(echo "$ep_json" | jq -r '.auth // "none"')"
      read -r cls code curl_exit attempts <<< "$(probe_endpoint "$url" "$auth")"
      classes+="$cls"$'\n'
      endpoints_json="$(echo "$endpoints_json" | jq --arg url "$url" --arg cls "$cls" \
        --arg code "$code" --arg ce "$curl_exit" --arg at "$attempts" \
        '. + [{url:$url, class:$cls, http_code:$code, curl_exit:($ce|tonumber), attempts:($at|tonumber)}]')"
    done < <(echo "$s_json" | jq -c '.endpoints[]')
    status="$(classify_surface "$classes")"
    detail=""
  fi

  RESULTS="$(echo "$RESULTS" | jq --arg s "$s_name" --arg c "$s_class" --arg st "$status" \
    --arg d "$detail" --argjson eps "$endpoints_json" \
    '. + [{surface:$s, class:$c, status:$st, detail:(if $d=="" then null else $d end), endpoints:$eps}]')"
done < <(echo "$PROBE_CONFIG" | jq -c '.surfaces[]')

FINAL="$(jq -n --arg now "$NOW" --arg host "$HOSTN" \
  --argjson via_broker "$VIA_BROKER" --argjson outside "$OUTSIDE" \
  --argjson surfaces "$RESULTS" \
  '{schema:"can-i-still-act/v1", generated_at:$now, host:$host,
    via_broker:($via_broker==1), outside_sandbox_requested:($outside==1),
    surfaces:$surfaces}')"

if (( JSON )); then
  echo "$FINAL"
else
  echo "can-i-still-act @ $NOW on $HOSTN"
  echo "$FINAL" | jq -r '.surfaces[] | "  \(.surface): \(.status)\(if .detail then " (" + .detail + ")" else "" end)"'
fi

if [[ -n "$EXPECT" ]]; then
  want="$(echo "$EXPECT" | tr '[:lower:]' '[:upper:]')"
  echo "$FINAL" | jq -e --arg w "$want" '(.surfaces|length) > 0 and all(.surfaces[]; .status == $w)' >/dev/null || exit 1
fi
exit 0
