#!/usr/bin/env bash
# Gemini API caller (ADR-012 revised 2026-06-30 — CLI is dead, use the API).
#
# WHY: the Gemini CLI free tier returns IneligibleTierError ("client no longer
# supported … migrate to Antigravity") as of 2026-06-30, so the CLI rung of the
# ADR-012 ladder is gone. The non-Claude Gemini family is now reached ONLY via
# the REST API. This helper is that path for the three Gemini roles (red-team,
# architecture-critic, historian).
#
# KEY DIFFERENCE FROM THE CLI: the API has NO filesystem access. The CLI used to
# read the repo itself (`gemini --skip-trust -p`). The orchestrating agent must
# now ASSEMBLE the context (diff, files, archived docs) and pipe it in on stdin;
# the helper appends stdin to the prompt before sending.
#
# Gemini 3.1 Pro API (verified 2026-06-30, ai.google.dev):
#   POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
#   header  x-goog-api-key: <key>
#   body    {contents:[{parts:[{text:<prompt>}]}]}
#   text    .candidates[0].content.parts[0].text
# Model id: gemini-3.1-pro-preview. /model-audit 2026-07-31 claimed a GA id
# "gemini-3.1-pro" from a web search, but live ListModels + a live generateContent
# call both proved that id 404s — no GA id exists yet, still preview. Reverted;
# don't trust a "GA promotion" claim again without a live API check like this one.
#
# KEY RESOLUTION (never logged): $GEMINI_API_KEY, else macOS Keychain item
# 'gemini-api-key'. All whitespace is stripped (a trailing newline / paste wrap
# would corrupt the header — the DeepSeek 401 lesson, ADR-026).
#
# USAGE
#   source "$DIR/gemini-api.sh"
#   gmn_available                      # 0 if a key resolves
#   echo "<context>" | gmn_call "<prompt>"   # prints model text; exit 0 ok / non-zero degraded
#   gmn_call "<prompt>"                # prompt only, no piped context
#
# Cross-family rule (ADR-011/012): Gemini is non-Claude — never point this at a
# Claude model. The model id + Google-only endpoint are pinned here.

set -uo pipefail
{ set +x; } 2>/dev/null   # never echo the key under a caller's xtrace (ADR-026 lesson)

# ADR-030 hardening: honor GEMINI_BASE_URL ONLY when its host is the pinned
# vendor host; a stray/compromised value pointing elsewhere is IGNORED (never
# receives the key+context), warned, and replaced by the default so a
# misconfigured env can't strand the review. Host match is EXACT — scheme,
# userinfo and :port are stripped so `...@evil.com` can't sneak past. The
# override value is never echoed (it may carry embedded credentials).
GMN_ALLOWED_HOST="generativelanguage.googleapis.com"
_gmn_url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"; printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
_gmn_resolve_base() {
  local def="https://generativelanguage.googleapis.com/v1beta" ov="${GEMINI_BASE_URL:-}"
  if [[ -n "$ov" ]]; then
    [[ "$(_gmn_url_host "$ov")" == "$GMN_ALLOWED_HOST" ]] && { printf '%s' "$ov"; return; }
    echo "[gemini-api] IGNORING GEMINI_BASE_URL (host not on allowlist '${GMN_ALLOWED_HOST}') — using the pinned default (ADR-030 hardening)." >&2
  fi
  printf '%s' "$def"
}
GMN_API_BASE="$(_gmn_resolve_base)"
GMN_MODEL="${GEMINI_API_MODEL:-gemini-3.1-pro-preview}"
GMN_TIMEOUT="${GMN_TIMEOUT:-180}"
GMN_MAX_INPUT_BYTES="${GMN_MAX_INPUT_BYTES:-700000}"   # bound the prompt+context

# Keep ONLY API-key charset bytes. A whitespace-only strip let a pasted control
# byte (e.g. \x03) survive and corrupt the header → HTML 400 (2026-06-30 incident).
# All real keys (sk-…, sk-ant-…, sk-proj-…, AIza…, AQ.…) live in [A-Za-z0-9._-].
gmn_trim() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._-'; }

gmn_key() {
  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    local k; k="$(gmn_trim "$GEMINI_API_KEY")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  if command -v security >/dev/null 2>&1; then
    local k; k="$(security find-generic-password -s gemini-api-key -w 2>/dev/null)" || return 1
    k="$(gmn_trim "$k")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

gmn_available() { gmn_key >/dev/null 2>&1; }

# ADR-071 amendment (docs/plans/2026-08-11-gemini-paid-tier-precondition.md,
# Option A / A-D19): a read-only policy check, consulting the ADR-071 receipt
# via cross-family-preflight.sh's cfp_vendor_policy. No network, no key
# access. Lib path resolved relative to THIS file (BASH_SOURCE[0]), not CWD,
# so it works from a copied/installed location as well as this repo -- IFF
# cross-family-preflight.sh is copied alongside it.
#
# Echoes exactly one of three tokens (2026-08-11 reviewer fix, BLOCKING 1):
#   denied      -- cfp_vendor_policy says `denied`. Refuse the call.
#   proceed     -- cfp_vendor_policy successfully returned `allowed` or
#                  `unknown` (no receipt yet, e.g. a `normal` repo). The
#                  design's "unknown must not deny" rule stands: this is a
#                  legitimate "I asked and there's no signal" answer, not a
#                  failure to ask.
#   infra_error -- the lookup itself could not be performed: the sibling lib
#                  is missing/unreadable, `source` fails, cfp_vendor_policy is
#                  undefined after sourcing, or the call errors (non-zero
#                  exit) or returns something other than the three tokens
#                  cfp_vendor_policy's contract promises. This must NOT
#                  collapse into `proceed` -- a broken/missing policy library
#                  would otherwise silently become authorization to call
#                  Gemini even at `sensitive`. Refuse.
# GEMINI_POLICY_GUARD=off (default: on/unset) is a documented, explicit
# emergency bypass for exactly the infra_error case -- a broken install must
# be loud, not a hard strand, but the escape hatch is opt-in and named for
# what it does.
# Locate this file's directory in bash OR zsh.
#
# `${BASH_SOURCE[0]}` bare is a trap: under zsh with `set -u` it does not
# evaluate to empty, it ABORTS — "BASH_SOURCE[0]: parameter not set" — before
# any `||` handler can run. Subagents on this machine source these libs from an
# interactive zsh, so the whole call reported "policy unavailable" and every
# cross-family review silently fell back, twice in one day, with the real cause
# invisible. Guard the expansion, then use zsh's own `%x` so the fallback
# resolves to the right directory rather than merely failing quietly ($0 under
# a sourced zsh is "zsh", whose dirname is ".").
_gmn_self_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" && -n "${ZSH_VERSION:-}" ]]; then
    src="${(%):-%x}"
  fi
  [[ -z "$src" ]] && src="${0:-}"
  [[ -z "$src" || "$src" == "zsh" || "$src" == "-zsh" || "$src" == "bash" ]] && { echo ""; return 1; }
  ( cd "$(dirname "$src")" 2>/dev/null && pwd ) || return 1
}

_gmn_policy_decision() {
  [[ "${GEMINI_POLICY_GUARD:-on}" == "off" ]] && { echo proceed; return; }
  local lib_dir
  lib_dir="$(_gmn_self_dir)" || lib_dir=""
  # Last resort: the installed location, so a shell that cannot self-locate
  # still finds the policy rather than reporting it unavailable.
  [[ -z "$lib_dir" ]] && lib_dir="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib"
  [[ -d "$lib_dir" ]] || { echo infra_error; return; }
  [[ -r "$lib_dir/cross-family-preflight.sh" ]] || { echo infra_error; return; }
  # shellcheck disable=SC1091
  source "$lib_dir/cross-family-preflight.sh" 2>/dev/null || { echo infra_error; return; }
  declare -F cfp_vendor_policy >/dev/null 2>&1 || { echo infra_error; return; }
  local verdict rc
  verdict="$(cfp_vendor_policy generativelanguage.googleapis.com 2>/dev/null)"; rc=$?
  (( rc != 0 )) && { echo infra_error; return; }
  case "$verdict" in
    denied) echo denied ;;
    allowed|unknown) echo proceed ;;
    *) echo infra_error ;;  # cfp_vendor_policy's contract is exactly these three tokens
  esac
}

# gmn_call <prompt>  — optional context on stdin is appended to the prompt.
gmn_call() {
  local prompt="${1:-}"
  # ADR-071 D15 #6 / gemini-paid-tier-precondition Option A: fail comprehensibly,
  # not opaquely, when the host is closed at this repo's sensitivity level —
  # before the key is ever read.
  case "$(_gmn_policy_decision)" in
    denied)
      cat <<'EOF'
=== Gemini API: UNAVAILABLE — not cleared at this repo's sensitivity level ===
This repo is marked `sensitive`. The Gemini API host is not cleared there: the
free and paid tiers share one host and one key shape, the free tier trains on
your data and has humans read it, and its terms forbid sensitive content.
Use an OpenAI-family reviewer instead (reviewer / security-auditor /
product-critic), or run this review from a repo at `normal`.
See docs/ADRs/071-sandbox-vendor-host-compile.md D15 #6.
EOF
      return 4
      ;;
    infra_error)
      cat <<'EOF'
=== Gemini API: UNAVAILABLE — policy check unavailable ===
cross-family-preflight.sh is missing or unreadable, so the ADR-071
sensitivity gate could not be evaluated. Reinstall the stack (update.sh), or
set GEMINI_POLICY_GUARD=off to bypass this check in an emergency (this FAILS
OPEN -- only do this if you have independently verified this repo is not
`sensitive` or above).
See docs/ADRs/071-sandbox-vendor-host-compile.md D15 #6.
EOF
      return 5
      ;;
  esac
  if [[ -z "$prompt" ]]; then echo "=== Gemini API: ERROR — empty prompt ===" >&2; return 9; fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== Gemini API: UNAVAILABLE — curl/jq missing ==="; return 3
  fi

  local key
  if ! key="$(gmn_key)"; then
    cat <<'EOF'
=== Gemini API: UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s gemini-api-key -w 'YOUR_KEY'
Or export GEMINI_API_KEY (cloud/CI). Get a key at https://aistudio.google.com/apikey
EOF
    return 2
  fi

  # Append piped context (if any) so the agent can feed repo content the API can't read itself.
  local ctx=""
  if [[ ! -t 0 ]]; then ctx="$(cat)"; fi
  local full="$prompt"
  [[ -n "$ctx" ]] && full="${prompt}"$'\n\n--- context ---\n'"${ctx}"
  if (( ${#full} > GMN_MAX_INPUT_BYTES )); then
    full="${full:0:GMN_MAX_INPUT_BYTES}"$'\n[...input truncated for the request...]'
  fi

  local body resp http
  body="$(jq -nc --arg t "$full" '{contents:[{parts:[{text:$t}]}]}')"
  # ADR-030 hardening: the API key is piped in on stdin (-H @-), NOT on the command
  # line, so it never lands in this curl's argv (visible via `ps`/`/proc`).
  # pipefail preserves curl's exit status through the pipe for the || branch below.
  resp="$(printf 'x-goog-api-key: %s\n' "$key" \
    | curl -sS --max-time "$GMN_TIMEOUT" -w '\n%{http_code}' \
      -H @- \
      -H 'Content-Type: application/json' \
      -d "$body" \
      "${GMN_API_BASE%/}/models/${GMN_MODEL}:generateContent" 2>/dev/null)" \
    || { echo "=== Gemini API: UNAVAILABLE — request failed (network/timeout) ==="; return 5; }
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    echo "=== Gemini API: UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi
  local text; text="$(printf '%s' "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)"
  if [[ -z "$text" ]]; then echo "=== Gemini API: UNAVAILABLE — empty response (check safety blocks) ==="; return 7; fi
  printf '%s\n' "$text"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  gmn_call "${1:-Reply OK.}"
fi
