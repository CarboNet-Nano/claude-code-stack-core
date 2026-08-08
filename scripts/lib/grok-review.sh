#!/usr/bin/env bash
# Grok 4.5 fourth-voice adversarial reviewer (2026-07-15 model audit, PILOT).
#
# WHY: adversarial review (ADR-011) is delegated to NON-Claude families so it
# carries different blind spots than the Claude implementer. The routine tier
# already has Codex/local-Qwen (gate) and DeepSeek-v4 (third advisory voice,
# ADR-026). This adds Grok 4.5 (xAI) as a FOURTH, INDEPENDENT advisory voice on
# ROUTINE diffs — a fourth model family catches what the other three share.
#
# This voice is ADVISORY and ADDITIVE: it never replaces the gate pass and never
# auto-blocks. A missing key or unreachable API degrades to "voice unavailable"
# (exit non-zero) — it does NOT fail the overall review.
#
# Unlike deepseek-review.sh there is NO data-residency guard: api.x.ai is
# US-hosted, so no ADR-029-style hard-block applies.
#
# PILOT status (docs/model-audits/2026-07-15.md): 2-week shadow + ADR-040
# silent-corruption bake-off before any promotion to escalation or red-team.
#
# xAI's API is OpenAI-compatible: base https://api.x.ai/v1, endpoint
# /chat/completions, model grok-4.5 (dot form — the live id, verified
# 2026-07-15 against /v1/models; 'grok-4-5' does not resolve).
#
# KEY RESOLUTION (never hardcoded, never logged):
#   1. $GROK_API_KEY                (cloud / CI)
#   2. macOS Keychain item 'GROK_API_KEY' via `security find-generic-password`
#
# USAGE
#   source "$DIR/grok-review.sh"
#   gkr_available                 # 0 if a key resolves, non-zero otherwise
#   gkr_run <agent> [base] [head] # prints the Grok voice block; exit 0 ok / non-zero degraded
#
# Cross-family rule (ADR-011): Grok is non-Claude — it MUST NOT be pointed at
# a Claude model. The model id is pinned below and to an xAI-only base URL.

set -uo pipefail
# Defeat xtrace key leakage: if a caller has `set -x` active when this is
# sourced/run, the auth material could be echoed. Disable xtrace for this scope.
{ set +x; } 2>/dev/null

# ADR-030 hardening: honor GROK_BASE_URL ONLY when its host is the pinned vendor
# host; a stray/compromised value pointing elsewhere is IGNORED (never receives
# the key+diff), warned, and replaced by the default. Host match is EXACT —
# scheme, userinfo and :port are stripped so `...@evil.com` can't sneak past.
# The override value is never echoed.
GKR_ALLOWED_HOST="api.x.ai"
_gkr_url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"; printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
_gkr_resolve_base() {
  local def="https://api.x.ai/v1" ov="${GROK_BASE_URL:-}"
  if [[ -n "$ov" ]]; then
    [[ "$(_gkr_url_host "$ov")" == "$GKR_ALLOWED_HOST" ]] && { printf '%s' "$ov"; return; }
    echo "[grok-review] IGNORING GROK_BASE_URL (host not on allowlist '${GKR_ALLOWED_HOST}') — using the pinned default (ADR-030 hardening)." >&2
  fi
  printf '%s' "$def"
}
GKR_API_BASE="$(_gkr_resolve_base)"
GKR_ENDPOINT="${GKR_API_BASE%/}/chat/completions"
GKR_MODEL="${GROK_REVIEW_MODEL:-grok-4.5}"
GKR_TIMEOUT="${GKR_TIMEOUT:-120}"
GKR_MAX_DIFF_BYTES="${GKR_MAX_DIFF_BYTES:-200000}"   # bound the prompt; oversized diffs are truncated with a marker

# --- key resolution (no echo of the secret anywhere) --------------------------
# Keep ONLY API-key charset bytes (ADR-029 lesson): a whitespace-only strip let a
# pasted control byte survive and corrupt the auth header → 400/401 with a valid
# key (2026-06-30 DeepSeek incident). All real keys live in [A-Za-z0-9._-].
gkr_trim() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._-'; }

gkr_key() {
  if [[ -n "${GROK_API_KEY:-}" ]]; then
    local k; k="$(gkr_trim "$GROK_API_KEY")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  if command -v security >/dev/null 2>&1; then
    local k; k="$(security find-generic-password -s GROK_API_KEY -w 2>/dev/null)" || return 1
    k="$(gkr_trim "$k")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

gkr_available() { gkr_key >/dev/null 2>&1; }

# --- diff resolution (mirrors review-router.sh defaults) ----------------------

gkr_default_base() {
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

GKR_PROMPT='Adversarially review the diff below. Read the code COLD — you do NOT have the architect plan, the implementer commentary, or the other reviewers findings; you are an independent fourth voice whose value is the blind spots the others share. Check: correctness, edge cases (empty/null/boundary/malformed), security (injection, auth bypass, secret leakage, RLS holes), error handling, performance (N+1, unbounded loops, missing indexes), concurrency/idempotency, and dependency risk. Output findings as BLOCKING / NON-BLOCKING / NIT with file:line and a one-line why. If you find nothing material, say so plainly — do not invent findings.'

# --- run ----------------------------------------------------------------------

gkr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(gkr_default_base)}"
  local head="${3:-HEAD}"

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== Grok fourth voice (PILOT): UNAVAILABLE — curl/jq missing ==="; return 3
  fi

  local key
  if ! key="$(gkr_key)"; then
    cat <<'EOF'
=== Grok fourth voice (PILOT): UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s GROK_API_KEY -w 'YOUR_KEY'
Or export GROK_API_KEY (cloud/CI). Advisory — the gate pass remains mandatory.
EOF
    return 2
  fi

  # Resolve diff; any git failure → degrade (advisory voice, never aborts the review).
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1; then
    echo "=== Grok fourth voice (PILOT): UNAVAILABLE — unresolved refs ${base}..${head} ==="; return 4
  fi
  local mb diff
  mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "=== Grok fourth voice: UNAVAILABLE — merge-base failed ==="; return 4; }
  diff="$(git diff "$mb..$head" 2>/dev/null)" || { echo "=== Grok fourth voice: UNAVAILABLE — git diff failed ==="; return 4; }
  if [[ -z "$diff" ]]; then
    echo "=== Grok fourth voice (PILOT): empty diff ${base}..${head} — nothing to review ==="; return 0
  fi
  if (( ${#diff} > GKR_MAX_DIFF_BYTES )); then
    diff="${diff:0:GKR_MAX_DIFF_BYTES}
[...diff truncated at ${GKR_MAX_DIFF_BYTES} bytes for the review prompt...]"
  fi

  # jq builds the JSON body so the diff is safely encoded (no shell interpolation into JSON).
  local body
  body="$(jq -nc \
    --arg model "$GKR_MODEL" \
    --arg sys "$GKR_PROMPT" \
    --arg diff "$diff" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:("Diff under review:\n\n"+$diff)}], temperature:0, stream:false}')"

  # ADR-030 hardening: the auth header is piped in on stdin (-H @-), NOT on the
  # command line, so the key never lands in this curl's argv (visible via
  # `ps`/`/proc`). pipefail preserves curl's exit status through the pipe for the
  # || branch below.
  local resp http
  resp="$(printf 'Authorization: Bearer %s\n' "$key" \
    | curl -sS --max-time "$GKR_TIMEOUT" -w '\n%{http_code}' \
      -H @- \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "$GKR_ENDPOINT" 2>/dev/null)" || { echo "=== Grok fourth voice: UNAVAILABLE — request failed (network/timeout) ==="; return 5; }
  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    # Surface status only — never the key. Body may carry a provider error message.
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // .error // empty' 2>/dev/null)"
    echo "=== Grok fourth voice (PILOT): UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi

  local content; content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  if [[ -z "$content" ]]; then
    echo "=== Grok fourth voice (PILOT): UNAVAILABLE — empty response ==="; return 7
  fi

  cat <<EOF
=== Grok fourth voice (PILOT) — ${GKR_MODEL} ===
agent : $agent
diff  : ${base}..${head}
--- findings (advisory; does not block) ---
$content
==============================================
EOF
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  gkr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
