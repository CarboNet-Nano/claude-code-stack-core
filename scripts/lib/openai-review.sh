#!/usr/bin/env bash
# OpenAI-family adversarial-review caller (ADR-030).
#
# WHY: the three adversarial roles (reviewer, security-auditor, product-critic)
# reach the non-Claude OpenAI/GPT-5.5 family (ADR-011). ADR-011 reached it via
# the `codex` CLI; ADR-015 named the OpenAI API as a fallback rung but never
# wired a helper for it, so the rung was aspirational. When the local `codex`
# binary is present on PATH but blocked at EXECUTION (OS malware/quarantine), the
# CLI path hard-failed and the "fall back to the API" rung — gated on "codex not
# on PATH" — never fired. ADR-030 makes the API the DEFAULT transport and keeps
# the CLI as an opt-in that ALWAYS falls back to the API, so a blocked CLI can
# never strand a PR.
#
# This helper is the single source of truth for that decision. The agent prompts
# do NOT branch transports or run `codex exec` themselves — they call `oair_call`
# and relay its output (the ADR-030 rework: no duplicated bash across three
# markdown files).
#
# TRANSPORT (setting `codex_transport`, values api|cli — ADR-030):
#   api (default) → POST the OpenAI Chat Completions API (oair_call never touches
#                   the CLI). Removes the malware-block failure class.
#   cli           → run `codex exec`; on ANY failure (non-zero, quarantine block,
#                   not-authenticated, missing) fall back to the API. Opt-in CLI
#                   must never dead-stop.
# Resolution (highest first): env REVIEW_CODEX_TRANSPORT > project
# .claude/stack-config.json .review.codex_transport > built-in default "api".
# An invalid value at any layer is ignored (falls through), never treated as a
# novel transport.
#
# OpenAI API (Chat Completions — matches the in-repo DeepSeek precedent,
# scripts/lib/deepseek-review.sh):
#   POST https://api.openai.com/v1/chat/completions
#   header  Authorization: Bearer <key>
#   body    {model, messages:[{role:user, content:<prompt+context>}], reasoning_effort?}
#   text    .choices[0].message.content
#
# KEY RESOLUTION (never logged): delegated to scripts/lib/openai-key.sh
#   (`oai_key`: env OPENAI_API_KEY → macOS Keychain `openai-api-key`, trimmed;
#   ADR-028). `set +x` guards xtrace so a caller's `set -x` can't echo the key.
#
# USAGE
#   source "$DIR/openai-review.sh"
#   oair_available                      # 0 if a key resolves
#   oair_transport                      # echoes "api" | "cli"
#   echo "<context>" | oair_call "<prompt>" [model] [effort]   # prints model text
#   oair_call "<prompt>"                # prompt only, no piped context
#
# Cross-family rule (ADR-011): OpenAI is non-Claude — this helper pins an
# OpenAI-only endpoint and REFUSES a Claude-family model id, so a stray
# base-URL/model override cannot silently point "cross-family" review at Claude.

set -uo pipefail
{ set +x; } 2>/dev/null   # never echo the key under a caller's xtrace (ADR-026 lesson)

# Key resolver (env → Keychain), shared with the preflight (ADR-028).
_oair_keylib="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib/openai-key.sh"
[[ -f "$_oair_keylib" ]] || _oair_keylib="$(dirname "${BASH_SOURCE[0]}")/openai-key.sh"
# shellcheck source=/dev/null
[[ -f "$_oair_keylib" ]] && source "$_oair_keylib"

# ADR-030 hardening: the base-URL override is honored ONLY when its host is the
# pinned vendor host. A stray/compromised OPENAI_BASE_URL pointing elsewhere is
# IGNORED (never receives the key+diff); we warn and fall back to the default so a
# misconfigured env can't strand the review. Host match is EXACT — scheme,
# userinfo (user@host) and :port are stripped first so `...@evil.com` can't sneak
# past. The override value is never echoed (it may carry embedded credentials).
OAIR_ALLOWED_HOST="api.openai.com"
_oair_url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"; printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
_oair_resolve_base() {
  local def="https://api.openai.com/v1" ov="${OPENAI_BASE_URL:-}"
  if [[ -n "$ov" ]]; then
    [[ "$(_oair_url_host "$ov")" == "$OAIR_ALLOWED_HOST" ]] && { printf '%s' "$ov"; return; }
    echo "[openai-review] IGNORING OPENAI_BASE_URL (host not on allowlist '${OAIR_ALLOWED_HOST}') — using the pinned default (ADR-030 hardening)." >&2
  fi
  printf '%s' "$def"
}
OAIR_API_BASE="$(_oair_resolve_base)"
OAIR_ENDPOINT="${OAIR_API_BASE%/}/chat/completions"
OAIR_MODEL="${OPENAI_REVIEW_MODEL:-gpt-5.5}"
OAIR_TIMEOUT="${OAIR_TIMEOUT:-420}"   # gpt-5.5@high on a real ~70KB diff exceeds 180s (ADR-030 dogfood); 420 is the observed headroom
OAIR_MAX_INPUT_BYTES="${OAIR_MAX_INPUT_BYTES:-700000}"   # bound prompt+context

# Model-family names that MUST NOT be used for adversarial review (ADR-011: the
# reviewer must be a DIFFERENT family than the Claude implementer). Belt-and-
# suspenders alongside review-router.sh's RR_CLAUDE_RE — a stray override here is
# refused, not silently honored.
OAIR_CLAUDE_RE='claude|anthropic|opus|sonnet|haiku|fable'

oair_available() { command -v oai_key >/dev/null 2>&1 && oai_key >/dev/null 2>&1; }

# oair_transport : echoes "api" | "cli". Precedence env > project stack-config >
# "api". Any non-{api,cli} value at any layer is skipped (never a novel transport).
# REVIEW_CODEX_TRANSPORT is a fixed name, so a plain ${var:-} read is zsh-safe
# (no ${!name} indirect expansion — the review-router bad-substitution lesson).
oair_transport() {
  local v="${REVIEW_CODEX_TRANSPORT:-}"
  case "$v" in api|cli) echo "$v"; return;; esac
  if command -v jq >/dev/null 2>&1; then
    local root cfg
    root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    cfg="$root/.claude/stack-config.json"
    if [[ -n "$root" && -f "$cfg" ]]; then
      v="$(jq -r '.review.codex_transport // empty' "$cfg" 2>/dev/null)"
      case "$v" in api|cli) echo "$v"; return;; esac
    fi
  fi
  echo "api"
}

# oair_guard_model <model> : return 0 if the model is a non-Claude family, else 1
# (and print a refusal to stderr). ADR-011 enforcement at the call site.
oair_guard_model() {
  local m="$1"
  if echo "$m" | grep -qiE "$OAIR_CLAUDE_RE"; then
    echo "[openai-review] REFUSED Claude-family model '$m' — ADR-011 requires a non-Claude reviewer." >&2
    return 1
  fi
  return 0
}

# Portable bounded run (macOS lacks coreutils `timeout`): SIGALRM via perl+exec.
# A quarantined codex can HANG (no output, no exit — observed on the ADR-030 box),
# so every codex invocation is time-bounded; otherwise a hung binary would block
# the cli→api fallback forever. Falls back to a direct run only if perl is absent.
_oair_timeout() {
  local s="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift @ARGV; alarm $s; exec @ARGV; exit 127' "$s" "$@" 2>/dev/null
    return $?
  fi
  # No perl: bound the command with a bash watchdog so the hang guard still holds
  # (do NOT fall through to an unbounded exec — that re-opens the ADR-030 hang).
  "$@" & local p=$!
  ( sleep "$s"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

# oair_cli_try <full-input> <model> <effort> : run `codex exec`; return its exit
# status. Uses a time-bounded `codex --version` (EXECUTABILITY, not just PATH
# presence) as the gate so a quarantined/blocked/HUNG binary is treated as
# unusable — the ADR-030 fix for the exact failure `command -v codex` masked. Any
# non-zero return sends oair_call on to the API fallback.
oair_cli_try() {
  local full="$1" model="$2" effort="$3"
  command -v codex >/dev/null 2>&1 || return 127
  _oair_timeout "${OAIR_CLI_PROBE_TIMEOUT:-8}" codex --version >/dev/null 2>&1 || return 126  # missing/quarantined/hung
  if [[ -n "$effort" && "$effort" != "n/a" ]]; then
    _oair_timeout "$OAIR_TIMEOUT" codex exec -m "$model" -c model_reasoning_effort="$effort" "$full"
  else
    _oair_timeout "$OAIR_TIMEOUT" codex exec -m "$model" "$full"
  fi
}

# oair_api_call <full-input> <model> <effort> : POST Chat Completions; print text.
# Exit-code contract mirrors gmn_call/dsr_run.
oair_api_call() {
  local full="$1" model="$2" effort="$3"
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== OpenAI API: UNAVAILABLE — curl/jq missing ==="; return 3
  fi
  local key
  if ! command -v oai_key >/dev/null 2>&1 || ! key="$(oai_key)"; then
    cat <<'EOF'
=== OpenAI API: UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s openai-api-key -w 'YOUR_KEY'
Or export OPENAI_API_KEY (cloud/CI). Get a key at https://platform.openai.com/api-keys
EOF
    return 2
  fi

  # jq builds the body so the prompt/context is safely encoded (no shell→JSON
  # interpolation). reasoning_effort is added only when meaningful.
  local body
  if [[ -n "$effort" && "$effort" != "n/a" ]]; then
    body="$(jq -nc --arg model "$model" --arg content "$full" --arg effort "$effort" \
      '{model:$model, messages:[{role:"user",content:$content}], reasoning_effort:$effort, stream:false}')"
  else
    body="$(jq -nc --arg model "$model" --arg content "$full" \
      '{model:$model, messages:[{role:"user",content:$content}], stream:false}')"
  fi

  # ADR-030 hardening: the auth header is piped in on stdin (-H @-), NOT passed on
  # the command line, so the key never lands in this curl's argv (visible to other
  # local users via `ps`/`/proc`). pipefail preserves curl's exit code (e.g. 28 on
  # --max-time) through the pipe, so the timeout/network branches below still fire.
  local resp http crc
  resp="$(printf 'Authorization: Bearer %s\n' "$key" \
    | curl -sS --max-time "$OAIR_TIMEOUT" -w '\n%{http_code}' \
      -H @- \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "$OAIR_ENDPOINT" 2>/dev/null)"; crc=$?
  if [[ $crc -ne 0 ]]; then
    # Distinguish a slow-but-working path (curl 28 = --max-time exceeded) from a
    # genuinely broken one, so a consuming agent doesn't misread a timeout as
    # "no key / blocked network" and walk graceful degradation (ADR-030 dogfood).
    if [[ $crc -eq 28 ]]; then
      echo "=== OpenAI API: UNAVAILABLE — request TIMED OUT after ${OAIR_TIMEOUT}s (the path is up; raise OAIR_TIMEOUT and retry — NOT a missing key or blocked network) ==="; return 4
    fi
    echo "=== OpenAI API: UNAVAILABLE — request failed (network; curl rc=${crc}) ==="; return 5
  fi
  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    echo "=== OpenAI API: UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi
  local content; content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  if [[ -z "$content" ]]; then
    echo "=== OpenAI API: UNAVAILABLE — empty response ==="; return 7
  fi
  printf '%s\n' "$content"
  return 0
}

# oair_call <prompt> [model] [effort]  — optional context on stdin is appended.
# Honors codex_transport: api → API only; cli → codex exec, then API fallback.
oair_call() {
  local prompt="${1:-}" model="${2:-$OAIR_MODEL}" effort="${3:-}"
  if [[ -z "$prompt" ]]; then echo "=== OpenAI API: ERROR — empty prompt ===" >&2; return 9; fi
  oair_guard_model "$model" || return 10

  # Append piped context (if any) under a divider, then cap total size.
  local context="" full="$prompt"
  if [[ ! -t 0 ]]; then context="$(cat)"; fi
  [[ -n "$context" ]] && full="${prompt}

--- context ---
${context}"
  if (( ${#full} > OAIR_MAX_INPUT_BYTES )); then
    full="${full:0:OAIR_MAX_INPUT_BYTES}
[...input truncated at ${OAIR_MAX_INPUT_BYTES} bytes for the review prompt...]"
  fi

  local transport; transport="$(oair_transport)"
  if [[ "$transport" == "cli" ]]; then
    local out rc
    if out="$(oair_cli_try "$full" "$model" "$effort")"; then
      printf '%s\n' "$out"; return 0
    fi
    rc=$?
    echo "=== codex CLI unusable (exit ${rc}) — falling back to the OpenAI API (ADR-030) ===" >&2
  fi
  oair_api_call "$full" "$model" "$effort"
}

# Allow direct execution for a manual/CI smoke of the transport resolver.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo "codex_transport: $(oair_transport)"
  oair_available && echo "key: resolves" || echo "key: none"
fi
