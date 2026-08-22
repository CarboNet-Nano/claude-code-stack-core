#!/usr/bin/env bash
# credential-distinctness.sh — D18 P3's gate (§7.3).
#
# P-II: the broker's vendor identities are DISTINCT from the agent's. Asserted
# mechanically: read each vendor's identity endpoint once as the agent and once
# through the broker, and require, for every surface, that the two principal
# ids differ and the broker's is non-empty.
#
# Exit 0 only when that holds for every surface probed. A surface where either
# side cannot be resolved is reported with resolvable:false — and jq gates on
# it failing, never passing (ADR-085: couldn't-look is never looked).
#
# Usage: credential-distinctness.sh [--json] [--surface <name>]

set -uo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

JSON=0; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1 ;;
    --surface) ONLY="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }

# Bearer token via curl's stdin config, never argv: a token passed as -H lands
# in the process command line, readable by any same-uid process for the life of
# the call — the exact leak class this script's own scan hunts for elsewhere.
auth_get() { # auth_get <token> <url> -> response body
  printf 'silent\nshow-error\nmax-time = 10\nheader = "Authorization: Bearer %s"\nurl = "%s"\n' \
    "$1" "$2" | curl --config - 2>/dev/null
}

agent_identity() { # agent_identity <surface> -> id or empty
  local tok="" url="" expr=""
  case "$1" in
    github)
      tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
      [[ -z "$tok" ]] && command -v gh >/dev/null 2>&1 && tok="$(gh auth token 2>/dev/null || true)"
      url="https://api.github.com/user"; expr='"\(.login):\(.id)"' ;;
    cloudflare)
      tok="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"
      url="https://api.cloudflare.com/client/v4/user/tokens/verify"; expr='.result.id // empty' ;;
    neon)
      tok="${NEON_API_KEY:-}"
      url="https://console.neon.tech/api/v2/users/me"; expr='.id // empty' ;;
    supabase)
      tok="${SUPABASE_ACCESS_TOKEN:-}"
      [[ -z "$tok" && -f "$HOME/.supabase/access-token" ]] && tok="$(cat "$HOME/.supabase/access-token" 2>/dev/null)"
      url="https://api.supabase.com/v1/organizations"; expr='if type=="array" and length>0 then .[0].id else empty end' ;;
    netlify)
      tok="${NETLIFY_AUTH_TOKEN:-}"
      url="https://api.netlify.com/api/v1/user"; expr='.id // empty' ;;
  esac
  [[ -z "$tok" ]] && return 0
  auth_get "$tok" "$url" | jq -r "$expr" 2>/dev/null
}

broker_identity() { # broker_identity <surface> -> id or empty
  command -v stack-broker >/dev/null 2>&1 || return 0
  stack-broker identity --surface "$1" --json 2>/dev/null | jq -r '.principal_id // empty' 2>/dev/null
}

SURFACES=(github cloudflare neon supabase netlify)
[[ -n "$ONLY" ]] && SURFACES=("$ONLY")

ROWS="[]"
for s in "${SURFACES[@]}"; do
  A="$(agent_identity "$s")"
  B="$(broker_identity "$s")"
  RESOLVABLE=true
  [[ -z "$A" || -z "$B" ]] && RESOLVABLE=false
  ROWS="$(echo "$ROWS" | jq --arg s "$s" --arg a "$A" --arg b "$B" \
    --argjson r "$RESOLVABLE" \
    '. + [{surface:$s, agent_principal_id:$a, broker_principal_id:$b, resolvable:$r}]')"
done

OUT="$(jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(hostname)" \
  --argjson surfaces "$ROWS" \
  '{schema:"credential-distinctness/v1", generated_at:$now, host:$host, surfaces:$surfaces}')"

if (( JSON )); then
  echo "$OUT"
else
  echo "$OUT" | jq -r '.surfaces[] | "  \(.surface): agent=\(if .agent_principal_id=="" then "(unresolved)" else .agent_principal_id end) broker=\(if .broker_principal_id=="" then "(unresolved)" else .broker_principal_id end) distinct=\(.resolvable and (.agent_principal_id != .broker_principal_id))"'
fi

# the P3 gate: every surface resolvable, distinct, broker id non-empty
echo "$OUT" | jq -e 'all(.surfaces[];
    .resolvable and .agent_principal_id != .broker_principal_id
    and (.broker_principal_id|length) > 0)' >/dev/null
