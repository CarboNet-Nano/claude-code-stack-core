#!/usr/bin/env bash
# ADR-030 hardening for the cross-family review helpers gemini-api.sh and
# deepseek-review.sh (openai-review.sh carries the same guards — covered in
# test-openai-review.sh). Two properties, uniform across the trio:
#   1. the API key/secret is fed to curl on STDIN (-H @-), never on argv (a `ps`
#      /`/proc` reader must not see it);
#   2. the *_BASE_URL override is honored ONLY when its host is the pinned vendor
#      host — a foreign host is ignored and the pinned default is used instead.
# No real network calls: a fake `curl` on PATH records argv + stdin and replies 200.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GMN="$REPO_ROOT/scripts/lib/gemini-api.sh"
DSR="$REPO_ROOT/scripts/lib/deepseek-review.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 (got: '${2:-}')"; FAIL=$((FAIL+1)); }
check() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "$3"; }

# Write a fake `curl` that records its argv + stdin, then prints <json-body>\n200
# (matching the helpers' `-w '\n%{http_code}'` parse). Unquoted heredoc so the
# body ($2) is baked in now; \$@ / \$CURL_* stay literal for fake-curl runtime.
write_fake_curl() { # write_fake_curl <dir> <json-body>
  cat > "$1/curl" <<SH
#!/usr/bin/env bash
{ printf '%s ' "\$@"; } > "\$CURL_ARGV_OUT"
cat > "\$CURL_STDIN_OUT"
printf '%s\n%s' '$2' '200'
SH
  chmod +x "$1/curl"
}

# --- gemini: base-URL allowlist ----------------------------------------------
gmn_base() { # gmn_base <GEMINI_BASE_URL-or-empty>  -> resolved GMN_API_BASE
  local ov="$1" d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    if [[ -n "$ov" ]]; then export GEMINI_BASE_URL="$ov"; else unset GEMINI_BASE_URL; fi
    # shellcheck disable=SC1090
    source "$GMN" 2>/dev/null
    printf '%s' "$GMN_API_BASE"
  )
  rm -rf "$d"
}
check "gemini base: default"                 "https://generativelanguage.googleapis.com/v1beta" "$(gmn_base '')"
check "gemini base: same-host honored"       "https://generativelanguage.googleapis.com/v1"     "$(gmn_base 'https://generativelanguage.googleapis.com/v1')"
check "gemini base: foreign ignored"         "https://generativelanguage.googleapis.com/v1beta" "$(gmn_base 'https://evil.example.com')"
check "gemini base: userinfo trick ignored"  "https://generativelanguage.googleapis.com/v1beta" "$(gmn_base 'https://generativelanguage.googleapis.com@evil.example.com')"

# --- gemini: key off argv -----------------------------------------------------
gmn_argv_test() {
  local d; d="$(mktemp -d)"
  write_fake_curl "$d" '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
  (
    export CURL_ARGV_OUT="$d/argv" CURL_STDIN_OUT="$d/stdin" PATH="$d:$PATH" GEMINI_API_KEY="SECRET-gm-42"
    # shellcheck disable=SC1090
    source "$GMN"
    gmn_call "review this" </dev/null >/dev/null 2>&1
  )
  local a s; a="$(cat "$d/argv" 2>/dev/null || true)"; s="$(cat "$d/stdin" 2>/dev/null || true)"
  rm -rf "$d"
  if [[ "$a" != *SECRET-gm-42* && "$s" == *"x-goog-api-key: SECRET-gm-42"* ]]; then
    pass "gemini key off argv (fed via -H @- on stdin)"
  else
    fail "gemini key off argv" "argv_has_key=$([[ "$a" == *SECRET-gm-42* ]] && echo yes || echo no); stdin_has_key=$([[ "$s" == *SECRET-gm-42* ]] && echo yes || echo no)"
  fi
}
gmn_argv_test

# --- deepseek: base-URL allowlist --------------------------------------------
dsr_base() { # dsr_base <DEEPSEEK_BASE_URL-or-empty>  -> resolved DSR_ENDPOINT
  local ov="$1" d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    if [[ -n "$ov" ]]; then export DEEPSEEK_BASE_URL="$ov"; else unset DEEPSEEK_BASE_URL; fi
    # shellcheck disable=SC1090
    source "$DSR" 2>/dev/null
    printf '%s' "$DSR_ENDPOINT"
  )
  rm -rf "$d"
}
check "deepseek base: default"                "https://api.deepseek.com/chat/completions"    "$(dsr_base '')"
check "deepseek base: same-host honored"      "https://api.deepseek.com/v9/chat/completions" "$(dsr_base 'https://api.deepseek.com/v9')"
check "deepseek base: foreign ignored"        "https://api.deepseek.com/chat/completions"    "$(dsr_base 'https://evil.example.com')"
check "deepseek base: userinfo trick ignored" "https://api.deepseek.com/chat/completions"    "$(dsr_base 'https://api.deepseek.com@evil.example.com')"

# --- deepseek: key off argv (needs a benign, non-high-stakes temp-repo diff) --
dsr_argv_test() {
  local d repo; d="$(mktemp -d)"; repo="$(mktemp -d)"
  write_fake_curl "$d" '{"choices":[{"message":{"content":"ok"}}]}'
  (
    cd "$repo" || exit 1
    git init -q; git config user.email t@t; git config user.name t
    printf 'hello\n' > hello.txt; git add hello.txt; git commit -qm base
    printf 'hello\nworld\n' > hello.txt; git add hello.txt; git commit -qm change
    export CURL_ARGV_OUT="$d/argv" CURL_STDIN_OUT="$d/stdin" PATH="$d:$PATH" DEEPSEEK_CN_API_KEY="SECRET-ds-77"
    unset STACK_SENSITIVITY STACK_DOMAIN_MODE
    # shellcheck disable=SC1090
    source "$DSR"
    dsr_run cli HEAD~1 HEAD >/dev/null 2>&1
  )
  local a s; a="$(cat "$d/argv" 2>/dev/null || true)"; s="$(cat "$d/stdin" 2>/dev/null || true)"
  rm -rf "$d" "$repo"
  if [[ "$a" != *SECRET-ds-77* && "$s" == *"Authorization: Bearer SECRET-ds-77"* ]]; then
    pass "deepseek key off argv (fed via -H @- on stdin)"
  else
    fail "deepseek key off argv" "argv_has_key=$([[ "$a" == *SECRET-ds-77* ]] && echo yes || echo no); stdin_has_key=$([[ "$s" == *SECRET-ds-77* ]] && echo yes || echo no)"
  fi
}
dsr_argv_test

echo
echo "cross-family-hardening: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
