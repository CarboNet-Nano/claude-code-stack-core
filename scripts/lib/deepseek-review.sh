#!/usr/bin/env bash
# DeepSeek-v4 third-voice adversarial reviewer (ADR-026).
#
# WHY: adversarial review (ADR-011) is delegated to a NON-Claude family so it
# carries different blind spots than the Claude implementer. Today that is Codex
# (OpenAI/GPT-5.5) on high stakes and local Qwen (Alibaba) on routine. ADR-026
# adds DeepSeek-v4 (DeepSeek) as a THIRD, INDEPENDENT advisory voice on
# HIGH-stakes diffs only — three distinct families catch more than two, at the
# cost of one extra cloud call per high-stakes review.
#
# This voice is ADVISORY and ADDITIVE: it never replaces the Codex pass and never
# auto-blocks. The orchestrating agent relays its findings as a distinct voice
# alongside Codex's. A missing key or unreachable API degrades to "voice
# unavailable" (exit non-zero) — it does NOT fail the overall review (the Codex
# pass remains the mandated cross-family gate).
#
# DeepSeek's API is OpenAI-compatible: base https://api.deepseek.com, endpoint
# /chat/completions, model deepseek-v4-pro (top reasoning/agentic tier). Verified
# 2026-06-30 (api-docs.deepseek.com). The older deepseek-chat/reasoner ids retire
# 2026-07-24 — pin v4 ids.
#
# KEY RESOLUTION (never hardcoded, never logged) — CHINA-HOSTED, named -cn (ADR-029):
#   1. $DEEPSEEK_CN_API_KEY         (cloud / CI — the intended cloud mechanism)
#   2. macOS Keychain item 'deepseek-cn-api-key' via `security find-generic-password`
#      (local default; the -cn suffix flags the China data-residency class)
#
# USAGE
#   source "$DIR/deepseek-review.sh"
#   dsr_available                 # 0 if a key resolves, non-zero otherwise
#   dsr_run <agent> [base] [head] # prints the DeepSeek voice block; exit 0 ok / non-zero degraded
#
# Cross-family rule (ADR-011): DeepSeek is non-Claude — it MUST NOT be pointed at
# a Claude model. The model id is pinned below and to a DeepSeek-only base URL.

set -uo pipefail
# Self-audit (DeepSeek, 2026-06-30): defeat xtrace key leakage. If a caller has
# `set -x` active when this is sourced/run, the curl line (Bearer <key>) would be
# echoed to the terminal. Disable xtrace for this script's scope.
{ set +x; } 2>/dev/null

# ADR-030 hardening: honor DEEPSEEK_BASE_URL ONLY when its host is the pinned
# vendor host; a stray/compromised value pointing elsewhere is IGNORED (never
# receives the key+diff), warned, and replaced by the default. Doubly important
# here — the -cn key is China-hosted (ADR-029) and must not be redirected to an
# arbitrary host. Host match is EXACT — scheme, userinfo and :port are stripped so
# `...@evil.com` can't sneak past. The override value is never echoed.
DSR_ALLOWED_HOST="api.deepseek.com"
_dsr_url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"; printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
_dsr_resolve_base() {
  local def="https://api.deepseek.com" ov="${DEEPSEEK_BASE_URL:-}"
  if [[ -n "$ov" ]]; then
    [[ "$(_dsr_url_host "$ov")" == "$DSR_ALLOWED_HOST" ]] && { printf '%s' "$ov"; return; }
    echo "[deepseek-review] IGNORING DEEPSEEK_BASE_URL (host not on allowlist '${DSR_ALLOWED_HOST}') — using the pinned default (ADR-030 hardening)." >&2
  fi
  printf '%s' "$def"
}
DSR_API_BASE="$(_dsr_resolve_base)"
DSR_ENDPOINT="${DSR_API_BASE%/}/chat/completions"
DSR_MODEL="${DEEPSEEK_REVIEW_MODEL:-deepseek-v4-pro}"
DSR_TIMEOUT="${DSR_TIMEOUT:-120}"
DSR_MAX_DIFF_BYTES="${DSR_MAX_DIFF_BYTES:-200000}"   # bound the prompt; oversized diffs are truncated with a marker

# --- key resolution (no echo of the secret anywhere) --------------------------
# Keep ONLY API-key charset bytes (ADR-029). A whitespace-only strip let a pasted
# control byte (e.g. \x03) survive and corrupt the auth header → 400/401 with a
# valid key (2026-06-30 incident). All real keys live in [A-Za-z0-9._-].
dsr_trim() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._-'; }

# DeepSeek-CN is the CHINA-HOSTED api.deepseek.com. The key is named with a -cn
# suffix so its data-residency class is obvious at the call site (ADR-029).
dsr_key() {
  if [[ -n "${DEEPSEEK_CN_API_KEY:-}" ]]; then
    local k; k="$(dsr_trim "$DEEPSEEK_CN_API_KEY")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  if command -v security >/dev/null 2>&1; then
    local k; k="$(security find-generic-password -s deepseek-cn-api-key -w 2>/dev/null)" || return 1
    k="$(dsr_trim "$k")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

dsr_available() { dsr_key >/dev/null 2>&1; }

# --- data-residency guard (ADR-029) -------------------------------------------
# DeepSeek-CN is China-hosted. It must NEVER receive high-stakes or sensitive
# code. This is DEFENSE-IN-DEPTH inside the helper: even if a caller invokes it on
# the wrong tier, the send is refused fail-closed. Blocks when ANY of:
#   - STACK_SENSITIVITY=high
#   - STACK_DOMAIN_MODE in {security, schema-migration}
#   - the diff (changed paths OR added content) matches the high-stakes regex
# Changed-file names come from `git diff --name-only`; content from the diff body.
DSR_BLOCK_RE='(auth|login|oauth|sso|saml|session|token|jwt|passwd|password|secret|credential|crypto|encrypt|decrypt|cipher|hmac|private[_-]?key|mnemonic|seed|vault|kms|totp|mfa|2fa|payment|billing|charge|stripe|payroll|/migrations/|\.sql|rls|policy|\.env|api[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)'

# dsr_residency_block <diff-text> <base> <head> — echoes a reason if blocked, else empty.
dsr_residency_block() {
  local diff="$1" base="$2" head="$3"
  [[ "${STACK_SENSITIVITY:-}" == "high" ]] && { echo "sensitivity=high"; return 0; }
  case "${STACK_DOMAIN_MODE:-}" in security|schema-migration) echo "domain-mode=${STACK_DOMAIN_MODE}"; return 0;; esac
  local files hit
  files="$(git diff --name-only "$base..$head" 2>/dev/null || true)"
  hit="$(printf '%s\n' "$files" | grep -iE "$DSR_BLOCK_RE" | head -1)"
  [[ -n "$hit" ]] && { echo "high-stakes path: ${hit}"; return 0; }
  printf '%s' "$diff" | grep -iEq "$DSR_BLOCK_RE" && { echo "high-stakes content in diff"; return 0; }
  return 1   # not blocked
}

# --- diff resolution (mirrors review-router.sh defaults) ----------------------

dsr_default_base() {
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

DSR_PROMPT='Adversarially review the diff below. Read the code COLD — you do NOT have the architect plan, the implementer commentary, or the other reviewers findings; you are an independent third voice whose value is the blind spots the others share. Check: correctness, edge cases (empty/null/boundary/malformed), security (injection, auth bypass, secret leakage, RLS holes), error handling, performance (N+1, unbounded loops, missing indexes), concurrency/idempotency, and dependency risk. Output findings as BLOCKING / NON-BLOCKING / NIT with file:line and a one-line why. If you find nothing material, say so plainly — do not invent findings.'

# --- run ----------------------------------------------------------------------

dsr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(dsr_default_base)}"
  local head="${3:-HEAD}"

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — curl/jq missing ==="; return 3
  fi

  local key
  if ! key="$(dsr_key)"; then
    cat <<'EOF'
=== DeepSeek-CN voice (ADR-026/029): UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s deepseek-cn-api-key -w 'YOUR_KEY'
Or export DEEPSEEK_CN_API_KEY (cloud/CI). Advisory — the Codex pass remains the gate.
EOF
    return 2
  fi

  # Resolve diff; any git failure → degrade (advisory voice, never aborts the review).
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — unresolved refs ${base}..${head} ==="; return 4
  fi
  local mb diff
  mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — merge-base failed ==="; return 4; }
  diff="$(git diff "$mb..$head" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — git diff failed ==="; return 4; }
  if [[ -z "$diff" ]]; then
    echo "=== DeepSeek third voice (ADR-026): empty diff ${base}..${head} — nothing to review ==="; return 0
  fi
  if (( ${#diff} > DSR_MAX_DIFF_BYTES )); then
    diff="${diff:0:DSR_MAX_DIFF_BYTES}
[...diff truncated at ${DSR_MAX_DIFF_BYTES} bytes for the review prompt...]"
  fi

  # DATA-RESIDENCY GUARD (ADR-029): refuse to send high-stakes / sensitive code to
  # the China-hosted endpoint, regardless of how the caller invoked us. Fail-closed.
  local _blk; _blk="$(dsr_residency_block "$diff" "$mb" "$head")"
  if [[ -n "$_blk" ]]; then
    echo "=== DeepSeek-CN voice (ADR-029): BLOCKED — data-residency (${_blk}) ==="
    echo "High-stakes/sensitive code is not sent to the China-hosted DeepSeek API. Codex+Gemini cover this diff."
    return 8
  fi

  # jq builds the JSON body so the diff is safely encoded (no shell interpolation into JSON).
  local body
  body="$(jq -nc \
    --arg model "$DSR_MODEL" \
    --arg sys "$DSR_PROMPT" \
    --arg diff "$diff" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:("Diff under review:\n\n"+$diff)}], temperature:0, stream:false}')"

  # ADR-030 hardening: the auth header is piped in on stdin (-H @-), NOT on the
  # command line, so the key never lands in this curl's argv (visible via
  # `ps`/`/proc`). pipefail preserves curl's exit status through the pipe for the
  # || branch below.
  local resp http
  resp="$(printf 'Authorization: Bearer %s\n' "$key" \
    | curl -sS --max-time "$DSR_TIMEOUT" -w '\n%{http_code}' \
      -H @- \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "$DSR_ENDPOINT" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — request failed (network/timeout) ==="; return 5; }
  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    # Surface status only — never the key. Body may carry a provider error message.
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi

  local content; content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  if [[ -z "$content" ]]; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — empty response ==="; return 7
  fi

  cat <<EOF
=== DeepSeek third voice (ADR-026) — ${DSR_MODEL} ===
agent : $agent
diff  : ${base}..${head}
--- findings (advisory; does not block) ---
$content
==============================================
EOF
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  dsr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
