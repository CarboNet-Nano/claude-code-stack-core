#!/usr/bin/env bash
# Tests for scripts/lib/cross-family-preflight.sh (ADR-022).
# Covers the verdict matrix (READY / BLOCKED_NETWORK / BLOCKED_NOCREDS /
# BLOCKED_MODEL) and the deviation logger. Network reachability is stubbed so
# the suite never makes a real outbound call.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/cross-family-preflight.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Stub HOME so the deviation log goes to a temp location.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# --- helper: run cfp_run with stubbed checks, echo the verdict ---------------
# Args: have_cli(yes/no) have_key(yes/no) reachable(yes/no/unknown)
run_verdict() {
  # Use distinct names — cfp_run declares `local cli/key/reach`, which would
  # shadow same-named stub vars under bash dynamic scoping.
  # Arg 4 (transport, default api) pins REVIEW_CODEX_TRANSPORT so cfp_run resolves
  # deterministically without reading a project stack-config (ADR-030).
  local t_cli="$1" t_key="$2" t_reach="$3" t_transport="${4:-api}"
  (
    export REVIEW_CODEX_TRANSPORT="$t_transport"
    # shellcheck disable=SC1090
    source "$LIB"
    cfp_have_cli() { echo "$t_cli"; }
    cfp_have_key() { echo "$t_key"; }
    cfp_api_reachable() { echo "$t_reach"; }
    cfp_run >/dev/null
    echo "$CFP_VERDICT"
  )
}

# --- api mode (default, ADR-030): a runnable CLI does NOT count — key + API only ---

# 1. api: CLI runnable but NO key => BLOCKED_NOCREDS  (THE malware-block regression guard)
[[ "$(run_verdict yes no yes api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: CLI-only (no key) => BLOCKED_NOCREDS" || fail "api: CLI-only (no key) => BLOCKED_NOCREDS"

# 2. api: key present + reachable => READY
[[ "$(run_verdict no yes yes api)" == "READY" ]] \
  && pass "api: key + reachable => READY" || fail "api: key + reachable => READY"

# 3. api: key present but NOT reachable => BLOCKED_NETWORK
[[ "$(run_verdict no yes no api)" == "BLOCKED_NETWORK" ]] \
  && pass "api: key + blocked => BLOCKED_NETWORK" || fail "api: key + blocked => BLOCKED_NETWORK"

# 4. api: CLI runnable, no key, unreachable => BLOCKED_NOCREDS (key is the only path)
[[ "$(run_verdict yes no no api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: CLI-only unreachable => BLOCKED_NOCREDS" || fail "api: CLI-only unreachable => BLOCKED_NOCREDS"

# 5. api: neither CLI nor key => BLOCKED_NOCREDS
[[ "$(run_verdict no no no api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: no creds => BLOCKED_NOCREDS" || fail "api: no creds => BLOCKED_NOCREDS"

# 6. api: key present, probe unknown (no curl) => PROBE_SKIPPED
[[ "$(run_verdict no yes unknown api)" == "PROBE_SKIPPED" ]] \
  && pass "api: unknown reach => PROBE_SKIPPED" || fail "api: unknown reach => PROBE_SKIPPED"

# --- cli mode: a runnable CLI counts (ADR-022 behavior preserved) ---

# 6a. cli: runnable CLI, no key, reachable => READY
[[ "$(run_verdict yes no yes cli)" == "READY" ]] \
  && pass "cli: runnable CLI + reachable => READY" || fail "cli: runnable CLI + reachable => READY"

# 6b. cli: key fallback (no runnable CLI), reachable => READY
[[ "$(run_verdict no yes yes cli)" == "READY" ]] \
  && pass "cli: key fallback => READY" || fail "cli: key fallback => READY"

# 6c. cli: neither runnable CLI nor key => BLOCKED_NOCREDS
[[ "$(run_verdict no no no cli)" == "BLOCKED_NOCREDS" ]] \
  && pass "cli: no creds => BLOCKED_NOCREDS" || fail "cli: no creds => BLOCKED_NOCREDS"

# 6d. default (transport unset) behaves as api => CLI-only, no key => BLOCKED_NOCREDS
[[ "$(run_verdict yes no yes)" == "BLOCKED_NOCREDS" ]] \
  && pass "default transport = api (CLI-only => BLOCKED_NOCREDS)" || fail "default transport = api"

# 7. cfp_have_key reads the real env (empty => no, set => yes)
( source "$LIB"; OPENAI_API_KEY=""; [[ "$(cfp_have_key)" == "no" ]] ) \
  && pass "empty key => no" || fail "empty key => no"
( source "$LIB"; export OPENAI_API_KEY="sk-test"; [[ "$(cfp_have_key)" == "yes" ]] ) \
  && pass "set key => yes" || fail "set key => yes"

# 8. cfp_log_deviation appends a well-formed row
(
  source "$LIB"
  cd "$TMP"
  cfp_log_deviation reviewer BLOCKED_NETWORK proceed-with-deviation "design already cross-family reviewed"
)
if [[ -s "$LOG" ]] && jq -e 'select(.event=="cross_family_deviation" and .agent=="reviewer" and .decision=="proceed-with-deviation")' "$LOG" >/dev/null 2>&1; then
  pass "deviation row logged"
else
  fail "deviation row logged"
fi

# 9. Verdict block is human-readable (VERDICT + FIX + transport line, ADR-030)
out="$(
  export REVIEW_CODEX_TRANSPORT=api
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_have_key() { echo yes; }
  cfp_api_reachable() { echo no; }
  cfp_run
)"
grep -q "VERDICT" <<<"$out" && grep -q "FIX" <<<"$out" && grep -q "codex_transport" <<<"$out" \
  && pass "verdict block formatted (+transport line)" || fail "verdict block formatted (+transport line)"

# --- quota-probe outcome tests (cfp_api_reachable, authed branch) ------------
# The authed path POSTs a quota-sensitive request to /v1/chat/completions —
# NEVER the free /v1/models list (BLOCKING #1: a zero-credit key returns 200
# there and would prove nothing). curl is faked as a shell function; -o
# /dev/null means the stub's only observable output is the status code it
# echoes, matching the real -w '%{http_code}' capture.

# 10. key set, curl returns 200 (authenticated AND has quota) => yes
out="$(
  curl() { echo -n "200"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "yes" ]] && pass "cfp_api_reachable: key + HTTP 200 => yes" \
  || fail "cfp_api_reachable: key + HTTP 200 => yes"

# 11. key set, curl returns 401 (dead/revoked key) => unauthorized, never yes
out="$(
  curl() { echo -n "401"; }
  export OPENAI_API_KEY="sk-dead-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "unauthorized" ]] && pass "cfp_api_reachable: key + HTTP 401 => unauthorized" \
  || fail "cfp_api_reachable: key + HTTP 401 => unauthorized"

# 11b. same, 403 => unauthorized
out="$(
  curl() { echo -n "403"; }
  export OPENAI_API_KEY="sk-dead-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "unauthorized" ]] && pass "cfp_api_reachable: key + HTTP 403 => unauthorized" \
  || fail "cfp_api_reachable: key + HTTP 403 => unauthorized"

# 12. key set, curl fails to connect (refused/timeout) => no
out="$(
  curl() { return 7; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "no" ]] && pass "cfp_api_reachable: key + connection refused => no" \
  || fail "cfp_api_reachable: key + connection refused => no"

# 13. no key set (unauthenticated /v1/models probe), curl returns 401 => still
#     "yes" — no key sent, so a 401 proves nothing about a key we didn't send
#     (no regression on the pre-existing unauthenticated-reachability path).
out="$(
  curl() { echo -n "401"; }
  unset OPENAI_API_KEY
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "yes" ]] && pass "cfp_api_reachable: no key + HTTP 401 => yes (unauthenticated reachability unaffected)" \
  || fail "cfp_api_reachable: no key + HTTP 401 => yes (unauthenticated reachability unaffected)"

# 13b. no key set, curl emits garbage (not a 3-digit code) => no (fail closed,
#      never guess reachable from unparseable -w output)
out="$(
  curl() { echo -n "garbage"; }
  unset OPENAI_API_KEY
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "no" ]] && pass "cfp_api_reachable: no key + garbage curl output => no (fail closed)" \
  || fail "cfp_api_reachable: no key + garbage curl output => no (fail closed)"

# 14. key set, curl returns 429 (authenticated, no quota/credits) => quota
out="$(
  curl() { echo -n "429"; }
  export OPENAI_API_KEY="sk-zero-credit-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "quota" ]] && pass "cfp_api_reachable: key + HTTP 429 => quota" \
  || fail "cfp_api_reachable: key + HTTP 429 => quota"

# 15. key set, curl returns 500/503 (transient upstream) => transient, not
#     unauthorized/quota — a blip must not be read as a dead/exhausted key.
out="$(
  curl() { echo -n "500"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "transient" ]] && pass "cfp_api_reachable: key + HTTP 500 => transient" \
  || fail "cfp_api_reachable: key + HTTP 500 => transient"
out="$(
  curl() { echo -n "503"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "transient" ]] && pass "cfp_api_reachable: key + HTTP 503 => transient" \
  || fail "cfp_api_reachable: key + HTTP 503 => transient"

# 16. key set, curl returns an unexpected status (e.g. 418) => unexpected:418,
#     fail closed rather than falling through to "yes" (BLOCKING #2).
out="$(
  curl() { echo -n "418"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "unexpected:418" ]] && pass "cfp_api_reachable: key + HTTP 418 (unexpected) => unexpected:418" \
  || fail "cfp_api_reachable: key + HTTP 418 (unexpected) => unexpected:418"

# 16b. key set, curl emits garbage (not a 3-digit code) => no (fail closed)
out="$(
  curl() { echo -n "garbage"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "no" ]] && pass "cfp_api_reachable: key + garbage curl output => no (fail closed)" \
  || fail "cfp_api_reachable: key + garbage curl output => no (fail closed)"

# --- token-limit param regression (2026-08-04 false BLOCKED_NOCREDS) ---------
# gpt-5.5 rejects legacy max_tokens with 400 ("use max_completion_tokens"),
# which the probe read as unexpected:400 => BLOCKED_NOCREDS on a WORKING key.
# The probe must send max_completion_tokens first and only fall back to
# max_tokens on a 400 (older/proxy endpoints); 400 on both stays fail-closed.

# 16c. gpt-5.5-style endpoint: 400 for max_tokens, 200 for max_completion_tokens
#      => yes. The stub also proves the FIRST request already carries
#      max_completion_tokens (no wasted 400 round-trip on current models) AND
#      that the cap is 16 — reasoning models 400 ("output limit reached") on a
#      cap of 1 even with the right param, so a regression to cap=1 must fail.
# NOTE: the case patterns use the balanced "(pat)" form — bash 3.2 (macOS
# /bin/bash) cannot parse an unbalanced ")" case pattern inside "$(...)".
out="$(
  curl() {
    local a
    for a in "$@"; do
      case "$a" in
        (*'"max_completion_tokens":16'*) echo -n "200"; return ;;
        (*max_completion_tokens*)        echo -n "400"; return ;;  # wrong cap value
        (*max_tokens*)                   echo -n "400"; return ;;
      esac
    done
    echo -n "400"
  }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "yes" ]] && pass "cfp_api_reachable: gpt-5.5-style 400-on-max_tokens endpoint => yes (regression guard, 2026-08-04)" \
  || fail "cfp_api_reachable: gpt-5.5-style 400-on-max_tokens endpoint => yes (regression guard, 2026-08-04)"

# 16d. older/proxy endpoint: 400 for max_completion_tokens, 200 for legacy
#      max_tokens => yes via the one-shot fallback retry.
out="$(
  curl() {
    local a
    for a in "$@"; do
      case "$a" in
        (*max_completion_tokens*) echo -n "400"; return ;;
        (*max_tokens*)            echo -n "200"; return ;;
      esac
    done
    echo -n "400"
  }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)" 2>/dev/null
[[ "$out" == "yes" ]] && pass "cfp_api_reachable: legacy endpoint (400 on max_completion_tokens) => yes via max_tokens fallback" \
  || fail "cfp_api_reachable: legacy endpoint (400 on max_completion_tokens) => yes via max_tokens fallback"

# 16e. genuine 400 (both params rejected) => unexpected:400, fail closed —
#      the fallback must not soften real request errors.
out="$(
  curl() { echo -n "400"; }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)" 2>/dev/null
[[ "$out" == "unexpected:400" ]] && pass "cfp_api_reachable: 400 on both token params => unexpected:400 (fail closed preserved)" \
  || fail "cfp_api_reachable: 400 on both token params => unexpected:400 (fail closed preserved)"

# 16f. 400 on max_completion_tokens then 404 on the legacy retry => the pair's
#      FINAL status (404) wins, every candidate is exhausted the same way, and
#      the verdict is model_unavailable — documented-intentional discard of the
#      earlier 400 (the status-only probe can't tell "unsupported param" from a
#      genuine bad request; the same-model 404 is the stronger signal).
out="$(
  curl() {
    local a
    for a in "$@"; do
      case "$a" in
        (*max_completion_tokens*) echo -n "400"; return ;;
        (*max_tokens*)            echo -n "404"; return ;;
      esac
    done
    echo -n "404"
  }
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_api_reachable
)" 2>/dev/null
[[ "$out" == "model_unavailable:gpt-5.5" ]] && pass "cfp_api_reachable: 400 then 404 per model => model_unavailable (final status wins, never READY)" \
  || fail "cfp_api_reachable: 400 then 404 per model => model_unavailable (final status wins, never READY)"

# --- end-to-end (cfp_run, real cfp_api_reachable + real cfp_have_key) --------

# 17. valid key (HTTP 200) => READY
out="$(
  curl() { echo -n "200"; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "READY" ]] && pass "cfp_run: valid key (200) => READY" || fail "cfp_run: valid key (200) => READY"

# 18. dead key (HTTP 401) => BLOCKED_NOCREDS, never READY
out="$(
  curl() { echo -n "401"; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-dead-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NOCREDS" ]] && pass "cfp_run: dead key (401) => BLOCKED_NOCREDS, never READY" \
  || fail "cfp_run: dead key (401) => BLOCKED_NOCREDS, never READY"

# 19. key present, connection refused => BLOCKED_NETWORK
out="$(
  curl() { return 7; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NETWORK" ]] && pass "cfp_run: key + connection refused => BLOCKED_NETWORK" \
  || fail "cfp_run: key + connection refused => BLOCKED_NETWORK"

# 20. THE literal case named in BLOCKING #1: a zero-credit key returns 200 on
#     the free GET /v1/models endpoint but 429 on a real (quota-sensitive)
#     call. The fake curl branches on which endpoint was actually requested,
#     simulating exactly that real-world split. cfp_run must land on
#     BLOCKED_NOCREDS, not READY.
out="$(
  curl() {
    local a url="" has_stdin=no
    for a in "$@"; do
      [[ "$a" == http*://* ]] && url="$a"
      [[ "$a" == "@-" ]] && has_stdin=yes
    done
    [[ "$has_stdin" == yes ]] && cat >/dev/null   # drain the piped Authorization header
    # if/elif, not case: macOS system bash (3.2) cannot parse a case statement
    # whose source text sits literally inline inside a command substitution
    # (reproduced on this box), so every fake-curl stub in this file avoids
    # case for that reason. The real cross-family-preflight.sh case statements
    # are all inside top-level function bodies in a separate sourced file, and
    # are unaffected by this.
    if [[ "$url" == */v1/models ]]; then
      echo -n "200"              # free endpoint: 200 even for a zero-credit key
    elif [[ "$url" == */v1/chat/completions ]]; then
      echo -n "429"              # quota-sensitive endpoint: the real signal
    else
      echo -n "000"
    fi
  }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-zero-credit-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NOCREDS" ]] \
  && pass "cfp_run: zero-credit key (200 on /v1/models, 429 on /v1/chat/completions) => BLOCKED_NOCREDS, never READY (BLOCKING #1 regression guard)" \
  || fail "cfp_run: zero-credit key (200 on /v1/models, 429 on /v1/chat/completions) => BLOCKED_NOCREDS, never READY (BLOCKING #1 regression guard)"

# 21. key + 5xx transient => BLOCKED_NETWORK, not BLOCKED_NOCREDS
out="$(
  curl() { echo -n "502"; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NETWORK" ]] && pass "cfp_run: key + HTTP 502 (transient) => BLOCKED_NETWORK" \
  || fail "cfp_run: key + HTTP 502 (transient) => BLOCKED_NETWORK"

# 22. key + unexpected status => BLOCKED_NOCREDS (fail closed, BLOCKING #2)
out="$(
  curl() { echo -n "418"; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NOCREDS" ]] && pass "cfp_run: key + HTTP 418 (unexpected) => BLOCKED_NOCREDS (fail closed)" \
  || fail "cfp_run: key + HTTP 418 (unexpected) => BLOCKED_NOCREDS (fail closed)"

# --- base-URL allowlist (BLOCKING #3: refuse an unverified OPENAI_BASE_URL) --

# 23. OPENAI_BASE_URL points at an untrusted host with a key present => the
#     probe refuses BEFORE any network call — cfp_run lands on BLOCKED_NETWORK.
out="$(
  curl() { echo "SHOULD NOT BE CALLED" >&2; echo -n "200"; }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="https://evil.example.com"
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_NETWORK" ]] && pass "cfp_run: untrusted OPENAI_BASE_URL => BLOCKED_NETWORK (refused, never READY)" \
  || fail "cfp_run: untrusted OPENAI_BASE_URL => BLOCKED_NETWORK (refused, never READY)"

# 23b. plain http (not https) to the RIGHT host is also refused — scheme must
#      be https too, not just the host.
out="$(
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="http://api.openai.com"
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "blocked_base_url" ]] && pass "cfp_api_reachable: http (not https) to the right host => blocked_base_url" \
  || fail "cfp_api_reachable: http (not https) to the right host => blocked_base_url"

# 24. curl is never invoked when the base URL is refused (proves this is a
#     pre-network gate, not just a post-hoc verdict relabeling).
CURL_CALLED="$TMP/curl-called.flag"
rm -f "$CURL_CALLED"
(
  curl() { touch "$CURL_CALLED"; echo -n "200"; }
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="https://evil.example.com"
  source "$LIB"
  cfp_api_reachable >/dev/null
)
[[ ! -e "$CURL_CALLED" ]] && pass "cfp_api_reachable: refused base URL never invokes curl" \
  || fail "cfp_api_reachable: refused base URL never invokes curl"

# 25. CFP_ALLOW_CUSTOM_BASE=1 is an explicit opt-in — the probe proceeds (curl
#     IS invoked) against the otherwise-untrusted host.
CURL_CALLED2="$TMP/curl-called2.flag"
rm -f "$CURL_CALLED2"
out="$(
  curl() { touch "$CURL_CALLED2"; echo -n "200"; }
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="https://mirror.internal.example.com"
  export CFP_ALLOW_CUSTOM_BASE=1
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "yes" && -e "$CURL_CALLED2" ]] \
  && pass "cfp_api_reachable: CFP_ALLOW_CUSTOM_BASE=1 opts into a custom host" \
  || fail "cfp_api_reachable: CFP_ALLOW_CUSTOM_BASE=1 opts into a custom host"

# 25b. ADR-063 D6.1 leash: the opt-in no longer bypasses the https requirement.
out="$(
  curl() { echo -n "200"; }
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="http://mirror.internal.example.com"
  export CFP_ALLOW_CUSTOM_BASE=1
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "blocked_base_url" ]] \
  && pass "cfp_api_reachable: CFP_ALLOW_CUSTOM_BASE=1 still refuses plain http (D6.1)" \
  || fail "cfp_api_reachable: CFP_ALLOW_CUSTOM_BASE=1 still refuses plain http (D6.1)"

# 25c. ADR-063 D6.1 leash: every custom-base use leaves an audit row.
LOG_HOME="$TMP/leash-home"
mkdir -p "$LOG_HOME"
(
  curl() { echo -n "200"; }
  export HOME="$LOG_HOME"
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_BASE_URL="https://mirror.internal.example.com"
  export CFP_ALLOW_CUSTOM_BASE=1
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if jq -e 'select(.event=="cfp_custom_base" and .host=="mirror.internal.example.com")' \
     "$LOG_HOME/.claude/logs/subagent-runs.jsonl" >/dev/null 2>&1; then
  pass "cfp_api_reachable: custom-base use logs a cfp_custom_base event (D6.1)"
else
  fail "cfp_api_reachable: custom-base use logs a cfp_custom_base event (D6.1)"
fi

# 26. the default (unset OPENAI_BASE_URL) is unaffected — api.openai.com
#     itself must still pass the allowlist.
out="$(
  curl() { echo -n "200"; }
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_BASE_URL
  source "$LIB"
  cfp_api_reachable
)"
[[ "$out" == "yes" ]] && pass "cfp_api_reachable: default base URL (api.openai.com) passes the allowlist" \
  || fail "cfp_api_reachable: default base URL (api.openai.com) passes the allowlist"

# --- stub-strengthening: assert what curl was actually invoked with ---------

# 27. authed path: argv contains -H @- and --max-time, the key never appears
#     in argv, and stdin actually carries "Authorization: Bearer <key>".
ARGV_LOG="$TMP/argv27.log"; STDIN_LOG="$TMP/stdin27.log"
: > "$ARGV_LOG"; : > "$STDIN_LOG"
(
  curl() {
    printf '%s\n' "$@" >> "$ARGV_LOG"
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    if [[ "$has_stdin" == yes ]]; then cat > "$STDIN_LOG"; fi
    echo -n "200"
  }
  export OPENAI_API_KEY="sk-argv-guard-fake"
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if [[ -s "$ARGV_LOG" ]] \
  && grep -qx -- "@-" "$ARGV_LOG" \
  && grep -qx -- "--max-time" "$ARGV_LOG" \
  && ! grep -q "sk-argv-guard-fake" "$ARGV_LOG" \
  && grep -q "^Authorization: Bearer sk-argv-guard-fake$" "$STDIN_LOG"; then
  pass "cfp_api_reachable: authed path uses -H @-/--max-time, key absent from argv, present on stdin"
else
  fail "cfp_api_reachable: authed path uses -H @-/--max-time, key absent from argv, present on stdin"
fi

# 28. no-key path: no Authorization header is sent at all (no stdin pipe, no
#     -H @- in argv) — the unauthenticated GET really is unauthenticated.
ARGV_LOG2="$TMP/argv28.log"
: > "$ARGV_LOG2"
(
  curl() { printf '%s\n' "$@" >> "$ARGV_LOG2"; echo -n "200"; }
  unset OPENAI_API_KEY
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if [[ -s "$ARGV_LOG2" ]] && ! grep -qx -- "@-" "$ARGV_LOG2" && ! grep -q "Authorization" "$ARGV_LOG2"; then
  pass "cfp_api_reachable: no-key path sends no Authorization header"
else
  fail "cfp_api_reachable: no-key path sends no Authorization header"
fi

# 29. the authed path hits /v1/chat/completions, never /v1/models (BLOCKING #1)
ARGV_LOG3="$TMP/argv29.log"
: > "$ARGV_LOG3"
(
  curl() {
    printf '%s\n' "$@" >> "$ARGV_LOG3"
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "200"
  }
  export OPENAI_API_KEY="sk-endpoint-guard-fake"
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if grep -q "/v1/chat/completions" "$ARGV_LOG3" && ! grep -q "/v1/models" "$ARGV_LOG3"; then
  pass "cfp_api_reachable: authed probe targets /v1/chat/completions, not /v1/models"
else
  fail "cfp_api_reachable: authed probe targets /v1/chat/completions, not /v1/models"
fi

# 30. CR/LF in the key is stripped before it reaches curl's stdin (header-
#     injection guard) — the captured Authorization line must be a single
#     clean line with the CR/LF characters removed, not split into two lines.
STDIN_LOG4="$TMP/stdin30.log"
: > "$STDIN_LOG4"
(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    if [[ "$has_stdin" == yes ]]; then cat > "$STDIN_LOG4"; fi
    echo -n "200"
  }
  export OPENAI_API_KEY=$'sk-crlf\r\nX-Injected: evil'
  source "$LIB"
  cfp_api_reachable >/dev/null
)
LINES4="$(wc -l < "$STDIN_LOG4" | tr -d ' ')"
if [[ "$LINES4" == "1" ]] && grep -q "sk-crlfX-Injected: evil" "$STDIN_LOG4" && ! grep -q "^X-Injected" "$STDIN_LOG4"; then
  pass "cfp_api_reachable: CR/LF stripped from the key before it reaches curl's stdin (no header injection)"
else
  fail "cfp_api_reachable: CR/LF stripped from the key before it reaches curl's stdin (no header injection)"
fi

# --- probe model & 404 handling (model-404 ≠ no-credentials regression) ------
# The probe must use the model the review will actually use
# (OPENAI_REVIEW_MODEL, default gpt-5.5 — kept in sync with openai-review.sh's
# OAIR_MODEL), and a 404 (model not found) must read as MODEL trouble
# (BLOCKED_MODEL), never credential trouble: the old pinned probe-only model
# (gpt-5.5-mini) was retired by OpenAI and turned a WORKING key into a false
# BLOCKED_NOCREDS (observed 2026-08-03).

# 31. the probe body carries OPENAI_REVIEW_MODEL — and never the retired
#     gpt-5.5-mini pin.
BODY_LOG31="$TMP/body31.log"
: > "$BODY_LOG31"
(
  curl() {
    local a prev="" has_stdin=no
    for a in "$@"; do
      if [[ "$prev" == "-d" ]]; then printf '%s\n' "$a" >> "$BODY_LOG31"; fi
      [[ "$a" == "@-" ]] && has_stdin=yes
      prev="$a"
    done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "200"
  }
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_REVIEW_MODEL="gpt-5.4"
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if grep -q '"model":"gpt-5.4"' "$BODY_LOG31" && ! grep -q "gpt-5.5-mini" "$BODY_LOG31"; then
  pass "cfp_api_reachable: probe body uses OPENAI_REVIEW_MODEL (never a pinned probe-only model)"
else
  fail "cfp_api_reachable: probe body uses OPENAI_REVIEW_MODEL (never a pinned probe-only model)"
fi

# 31b. a Claude-family OPENAI_REVIEW_MODEL is ignored (ADR-011: the probe must
#      stay cross-family) — the pinned default gpt-5.5 is used instead.
BODY_LOG31B="$TMP/body31b.log"
: > "$BODY_LOG31B"
(
  curl() {
    local a prev="" has_stdin=no
    for a in "$@"; do
      if [[ "$prev" == "-d" ]]; then printf '%s\n' "$a" >> "$BODY_LOG31B"; fi
      [[ "$a" == "@-" ]] && has_stdin=yes
      prev="$a"
    done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "200"
  }
  export OPENAI_API_KEY="sk-live-fake"
  export OPENAI_REVIEW_MODEL="claude-opus-5"
  source "$LIB"
  cfp_api_reachable >/dev/null
)
if grep -q '"model":"gpt-5.5"' "$BODY_LOG31B" && ! grep -q "claude" "$BODY_LOG31B"; then
  pass "cfp_api_reachable: Claude-family OPENAI_REVIEW_MODEL ignored — probe stays cross-family (gpt-5.5)"
else
  fail "cfp_api_reachable: Claude-family OPENAI_REVIEW_MODEL ignored — probe stays cross-family (gpt-5.5)"
fi

# 32. primary model 404s, first alternate answers 200 => model_fallback:… —
#     credentials + quota are proven, only the review model is missing.
CNT32="$TMP/cnt32"
rm -f "$CNT32"
out="$(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    if [[ -e "$CNT32" ]]; then echo -n "200"; else : > "$CNT32"; echo -n "404"; fi
  }
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_REVIEW_MODEL
  source "$LIB"
  cfp_api_reachable 2>/dev/null
)"
[[ "$out" == "model_fallback:gpt-5.5:gpt-5.4" ]] \
  && pass "cfp_api_reachable: primary 404 + alternate 200 => model_fallback:gpt-5.5:gpt-5.4" \
  || fail "cfp_api_reachable: primary 404 + alternate 200 => model_fallback:gpt-5.5:gpt-5.4 (got '$out')"

# 33. every candidate model 404s => model_unavailable:<primary>, never
#     unauthorized/unexpected.
out="$(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "404"
  }
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_REVIEW_MODEL
  source "$LIB"
  cfp_api_reachable 2>/dev/null
)"
[[ "$out" == "model_unavailable:gpt-5.5" ]] \
  && pass "cfp_api_reachable: all models 404 => model_unavailable:gpt-5.5" \
  || fail "cfp_api_reachable: all models 404 => model_unavailable:gpt-5.5 (got '$out')"

# 34. THE observed regression, end-to-end: a WORKING key whose probe model
#     404s must land on BLOCKED_MODEL — never BLOCKED_NOCREDS.
out="$(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "404"
  }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_REVIEW_MODEL
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run >/dev/null 2>&1
  echo "$CFP_VERDICT"
)"
[[ "$out" == "BLOCKED_MODEL" ]] \
  && pass "cfp_run: model 404 on a working key => BLOCKED_MODEL, never BLOCKED_NOCREDS (regression guard)" \
  || fail "cfp_run: model 404 on a working key => BLOCKED_MODEL, never BLOCKED_NOCREDS (got '$out')"

# 35. 404-then-200 end-to-end: BLOCKED_MODEL, and the FIX names
#     OPENAI_REVIEW_MODEL + the working alternate so the operator can act.
CNT35="$TMP/cnt35"
rm -f "$CNT35"
out="$(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    if [[ -e "$CNT35" ]]; then echo -n "200"; else : > "$CNT35"; echo -n "404"; fi
  }
  export REVIEW_CODEX_TRANSPORT=api
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_REVIEW_MODEL
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_run 2>/dev/null
)"
if grep -q "VERDICT           : BLOCKED_MODEL" <<<"$out" \
  && grep -q "OPENAI_REVIEW_MODEL" <<<"$out" \
  && grep -q "gpt-5.4" <<<"$out"; then
  pass "cfp_run: primary 404 + alternate 200 => BLOCKED_MODEL, FIX names OPENAI_REVIEW_MODEL and the working alternate"
else
  fail "cfp_run: primary 404 + alternate 200 => BLOCKED_MODEL, FIX names OPENAI_REVIEW_MODEL and the working alternate"
fi

# 36. a 404 mid-probe emits a WARN on stderr (the operator sees the retry).
err="$(
  curl() {
    local a has_stdin=no
    for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
    [[ "$has_stdin" == yes ]] && cat >/dev/null
    echo -n "404"
  }
  export OPENAI_API_KEY="sk-live-fake"
  unset OPENAI_REVIEW_MODEL
  source "$LIB"
  cfp_api_reachable 2>&1 >/dev/null
)"
grep -q "404" <<<"$err" && grep -qi "model" <<<"$err" \
  && pass "cfp_api_reachable: 404 warns on stderr before trying the alternate" \
  || fail "cfp_api_reachable: 404 warns on stderr before trying the alternate"

echo
echo "cross-family-preflight: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
