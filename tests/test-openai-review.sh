#!/usr/bin/env bash
# Tests for scripts/lib/openai-review.sh (ADR-030): codex_transport resolution +
# precedence (env > project stack-config > default api) and the ADR-011
# Claude-family model guard. No network calls — oair_call itself is not invoked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/openai-review.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 (got: '${2:-}')"; FAIL=$((FAIL+1)); }

# transport <env-or-empty> [project-transport-or-empty]
# Resolves oair_transport in an ISOLATED temp git repo so the project-config
# layer is controllable and the real repo's config never leaks in.
transport() {
  local envval="$1" proj="${2:-}"
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    local root; root="$(git rev-parse --show-toplevel)"
    if [[ -n "$proj" ]]; then
      mkdir -p "$root/.claude"
      printf '{"review":{"codex_transport":"%s"}}\n' "$proj" > "$root/.claude/stack-config.json"
    fi
    if [[ -n "$envval" ]]; then export REVIEW_CODEX_TRANSPORT="$envval"; else unset REVIEW_CODEX_TRANSPORT; fi
    # shellcheck disable=SC1090
    source "$LIB"
    oair_transport
  )
  rm -rf "$d"
}

check() { # check <label> <expected> <actual>
  [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "$3"
}

# --- precedence + defaults ---------------------------------------------------
check "default (no env, no project) => api"        api "$(transport '' '')"
check "env=cli => cli"                             cli "$(transport cli '')"
check "project=cli (no env) => cli"                cli "$(transport '' cli)"
check "project=api (no env) => api"                api "$(transport '' api)"
check "env=api BEATS project=cli"                  api "$(transport api cli)"
check "env=cli BEATS project=api"                  cli "$(transport cli api)"

# --- invalid values fall through, never a novel transport --------------------
check "invalid env => api"                          api "$(transport grpc '')"
check "invalid project => api"                      api "$(transport '' bogus)"
check "invalid env, valid project => project"       cli "$(transport grpc cli)"

# --- ADR-011 Claude-family model guard ---------------------------------------
( source "$LIB"; oair_guard_model claude-opus-4-8 2>/dev/null ) \
  && fail "guard refuses claude model" "allowed" || pass "guard refuses claude model"
( source "$LIB"; oair_guard_model claude-sonnet-5 2>/dev/null ) \
  && fail "guard refuses sonnet" "allowed" || pass "guard refuses sonnet"
( source "$LIB"; oair_guard_model gpt-5.5 2>/dev/null ) \
  && pass "guard allows gpt-5.5" || fail "guard allows gpt-5.5" "refused"

# --- oair_call refuses a Claude model up front (exit 10, no network) ---------
( source "$LIB"; oair_call "review this" claude-opus-4-8 </dev/null >/dev/null 2>&1 )
[[ "$?" -eq 10 ]] && pass "oair_call refuses claude model (exit 10)" || fail "oair_call refuses claude model" "exit $?"

# --- empty prompt => exit 9 --------------------------------------------------
( source "$LIB"; oair_call "" </dev/null >/dev/null 2>&1 )
[[ "$?" -eq 9 ]] && pass "oair_call empty prompt => exit 9" || fail "oair_call empty prompt" "exit $?"

# --- bounded run: a hanging command is killed non-zero within the timeout ----
# (guards the cli→api fallback against a quarantined codex that HANGS, ADR-030)
( source "$LIB"; _oair_timeout 1 sleep 5 )
[[ "$?" -ne 0 ]] && pass "_oair_timeout kills a hang (non-zero)" || fail "_oair_timeout kills a hang"

# --- zsh portability of the resolver (the review-router bad-substitution class)
if command -v zsh >/dev/null 2>&1; then
  z="$(zsh -c "unset REVIEW_CODEX_TRANSPORT; source '$LIB'; oair_transport" 2>/dev/null)"
  check "zsh: default => api" api "$z"
else
  echo "SKIP: zsh not available"
fi

# --- ADR-030: base-URL allowlist (honor override only for the pinned vendor host)
# OAIR_ENDPOINT is computed at source time, so we source with OPENAI_BASE_URL set.
base_endpoint() { # base_endpoint <OPENAI_BASE_URL-or-empty>
  local ov="$1" d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    if [[ -n "$ov" ]]; then export OPENAI_BASE_URL="$ov"; else unset OPENAI_BASE_URL; fi
    # shellcheck disable=SC1090
    source "$LIB" 2>/dev/null
    printf '%s' "$OAIR_ENDPOINT"
  )
  rm -rf "$d"
}
check "base: default => api.openai.com"          "https://api.openai.com/v1/chat/completions"  "$(base_endpoint '')"
check "base: same-host override honored"         "https://api.openai.com/v2/chat/completions"  "$(base_endpoint 'https://api.openai.com/v2')"
check "base: foreign host ignored => default"    "https://api.openai.com/v1/chat/completions"  "$(base_endpoint 'https://evil.example.com/v1')"
check "base: userinfo trick ignored => default"  "https://api.openai.com/v1/chat/completions"  "$(base_endpoint 'https://api.openai.com@evil.example.com/v1')"

# --- ADR-030: the API key is fed to curl on stdin (-H @-), NEVER on argv --------
# A fake `curl` on PATH records its argv and its stdin so we can assert the secret
# lands only on the piped header line, not in the process command line.
argv_off_test() {
  local d; d="$(mktemp -d)"
  cat > "$d/curl" <<'SH'
#!/usr/bin/env bash
{ printf '%s ' "$@"; } > "$CURL_ARGV_OUT"
cat > "$CURL_STDIN_OUT"
printf '%s\n%s' '{"choices":[{"message":{"content":"ok"}}]}' '200'
SH
  chmod +x "$d/curl"
  (
    export CURL_ARGV_OUT="$d/argv" CURL_STDIN_OUT="$d/stdin"
    export PATH="$d:$PATH"
    export OPENAI_API_KEY="SECRET-abc123"
    # shellcheck disable=SC1090
    source "$LIB"
    oair_api_call "review this" gpt-5.5 "" </dev/null >/dev/null 2>&1
  )
  local argv stdin
  argv="$(cat "$d/argv" 2>/dev/null || true)"
  stdin="$(cat "$d/stdin" 2>/dev/null || true)"
  rm -rf "$d"
  if [[ "$argv" != *SECRET-abc123* && "$stdin" == *"Authorization: Bearer SECRET-abc123"* ]]; then
    pass "auth key off argv, fed via -H @- on stdin"
  else
    fail "auth key off argv" "argv_has_key=$([[ "$argv" == *SECRET-abc123* ]] && echo yes || echo no); stdin_has_key=$([[ "$stdin" == *SECRET-abc123* ]] && echo yes || echo no)"
  fi
}
argv_off_test

echo
echo "openai-review: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
