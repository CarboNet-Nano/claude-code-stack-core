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
  local ov="$1" d; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
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
  local d; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
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

# --- gemini: ADR-071 sensitivity gate (gemini-paid-tier-precondition Option A,
# A4-A6, extended 2026-08-11 per reviewer BLOCKING 1). _gmn_policy_decision
# echoes exactly one of three tokens -- `denied` / `proceed` / `infra_error` --
# so gmn_call can distinguish "the policy says no" from "I couldn't ask the
# policy at all" (sibling lib missing/unreadable, `source` failing, etc.).
# infra_error is a REFUSAL (fail CLOSED), never silently collapsed into
# proceed, unless GEMINI_POLICY_GUARD=off is explicitly set. -----------------

CFP_LIB="$REPO_ROOT/scripts/lib/cross-family-preflight.sh"

_gmn_write_receipt() {  # _gmn_write_receipt <home> <repo-realpath> <json>
  local home="$1" repo="$2" json="$3" key dir
  key="$(printf '%s' "$repo" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
  dir="$home/.claude/session-state/sandbox-policy"
  mkdir -p "$dir"
  printf '%s' "$json" > "$dir/$key.json"
}

# gmn_policy_decision_case <label> <expect denied|proceed|infra_error> <receipt-json-or-empty> [no-git]
gmn_policy_decision_case() {
  local label="$1" expect="$2" receipt_json="$3" no_git="${4:-}"
  local home repo real out
  home="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  if [[ "$no_git" != "no-git" ]]; then
    git -C "$repo" init -q 2>/dev/null
    real="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
  else
    real="$repo"
  fi
  if [[ -n "$receipt_json" ]]; then
    _gmn_write_receipt "$home" "$real" "$receipt_json"
  fi
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    HOME="$home" bash -c '
      source "'"$GMN"'"
      _gmn_policy_decision
    '
  )"
  rm -rf "$home" "$repo"
  check "A4: $label" "$expect" "$out"
}

gmn_policy_decision_case "receipt says denied -> denied" "denied" \
  '{"level":"sensitive","verdict":"COMPILED","allowed_hosts":[],"denied_hosts":["generativelanguage.googleapis.com"]}'
gmn_policy_decision_case "receipt says allowed -> proceed" "proceed" \
  '{"level":"sensitive","verdict":"COMPILED","allowed_hosts":["generativelanguage.googleapis.com"],"denied_hosts":[]}'
gmn_policy_decision_case "receipt says neither (unknown) -> proceed (regression)" "proceed" \
  '{"level":"normal","verdict":"COMPILED","allowed_hosts":[],"denied_hosts":[]}'
gmn_policy_decision_case "no receipt at all -> proceed" "proceed" ""
gmn_policy_decision_case "no git repo -> proceed" "proceed" "" "no-git"
# A receipt that is syntactically valid JSON but has no fields cfp_vendor_policy
# can use reads as "unknown" (level defaults to "normal", verdict defaults to
# empty, so the untrustworthy-above-normal branch never trips) -- the
# behavior A4 calls "unparseable receipt" must not deny. NOTE: a receipt file
# whose JSON is genuinely malformed (unparseable syntax, every jq read fails)
# instead hits cfp_vendor_policy's existing, untouched, deliberately
# fail-closed "untrustworthy verdict above normal" branch and returns
# `denied` -- that is pre-existing shared behavior (also governs
# api.openai.com) and is not something this change may alter; recorded here
# rather than silently masked.
gmn_policy_decision_case "receipt with no usable fields (unparseable) -> proceed" "proceed" \
  '{"nonsense": true}'

# gmn_infra_missing_lib_case <label> <expect> <guard-off:yes|no> -- sources a
# COPY of gemini-api.sh in isolation, deliberately WITHOUT its sibling
# cross-family-preflight.sh, so BASH_SOURCE[0]-relative resolution genuinely
# fails to find the policy lib (not merely a stubbed-out function).
gmn_infra_missing_lib_case() {
  local label="$1" expect="$2" guard_off="$3"
  local isolated home repo out
  isolated="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  cp "$GMN" "$isolated/gemini-api.sh"
  home="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  git -C "$repo" init -q 2>/dev/null
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    HOME="$home" bash -c '
      [[ "'"$guard_off"'" == "yes" ]] && export GEMINI_POLICY_GUARD=off
      source "'"$isolated"'/gemini-api.sh"
      _gmn_policy_decision
    '
  )"
  rm -rf "$isolated" "$home" "$repo"
  check "A4: $label" "$expect" "$out"
}
gmn_infra_missing_lib_case "sibling policy lib missing -> infra_error (fail CLOSED)" "infra_error" "no"
gmn_infra_missing_lib_case "GEMINI_POLICY_GUARD=off with sibling lib missing -> proceed (documented bypass)" "proceed" "yes"

# A5 — gmn_call in a denied repo returns 4, prints the legible message, makes
# NO network call, and NEVER reads the key.
#
# PATH-invariance (reviewer NON-BLOCKING, 2026-08-11): DECLINED for now. The
# suggestion is to override `gmn_key` itself (post-source, with a test double)
# so the assertion is invariant to how gmn_key resolves a key, rather than
# relying on PATH-stubbed `curl`/`security`. Declined here because the stubs
# already intercept the ONLY two invocation paths gmn_key/gmn_call use today
# (curl for the network call, `security` for the Keychain fallback) --
# overriding gmn_key directly would test a different seam (whether gmn_call
# calls gmn_key at all) rather than the property this test cares about (no
# key material reaches curl's argv or a real credential store). Worth adding
# if gmn_key grows a third resolution path.
gmn_denied_repo_test() {
  local home repo bindir real
  home="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  bindir="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  git -C "$repo" init -q 2>/dev/null
  real="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
  _gmn_write_receipt "$home" "$real" \
    '{"level":"sensitive","verdict":"COMPILED","allowed_hosts":[],"denied_hosts":["generativelanguage.googleapis.com"]}'
  cat > "$bindir/curl" <<'SH'
#!/usr/bin/env bash
echo "CURL_INVOKED" >> "$CURL_LOG"
exit 1
SH
  chmod +x "$bindir/curl"
  cat > "$bindir/security" <<'SH'
#!/usr/bin/env bash
echo "SECURITY_INVOKED" >> "$SECURITY_LOG"
exit 1
SH
  chmod +x "$bindir/security"

  local out rc curl_hit sec_hit
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    HOME="$home" PATH="$bindir:$PATH" CURL_LOG="$bindir/curl.log" SECURITY_LOG="$bindir/security.log" bash -c '
      unset GEMINI_API_KEY
      source "'"$GMN"'"
      gmn_call "test prompt" </dev/null
    '
  )"
  rc=$?
  curl_hit="no"; [[ -f "$bindir/curl.log" ]] && curl_hit="yes"
  sec_hit="no"; [[ -f "$bindir/security.log" ]] && sec_hit="yes"
  rm -rf "$home" "$repo" "$bindir"

  [[ "$rc" == "4" ]] && pass "A5: gmn_call in a denied repo returns 4" || fail "A5: gmn_call in a denied repo returns 4" "rc=$rc"
  [[ "$out" == *"UNAVAILABLE"* && "$out" == *"not cleared at this repo's sensitivity level"* ]] \
    && pass "A5: legible denial message printed" || fail "A5: legible denial message printed" "$out"
  [[ "$curl_hit" == "no" ]] && pass "A5: no network call made" || fail "A5: no network call made" "curl was invoked"
  [[ "$sec_hit" == "no" ]] && pass "A5: key never read (security never invoked)" || fail "A5: key never read" "security was invoked"
}
gmn_denied_repo_test

# A5b (reviewer BLOCKING 1 fix) — gmn_call in a repo whose sibling policy lib
# is missing returns 5 (infra_error), prints a message DISTINCT from the
# `denied` message, and makes NO network call -- fails CLOSED on a broken
# install rather than silently proceeding.
gmn_infra_error_call_test() {
  local isolated bindir repo out rc curl_hit
  isolated="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  cp "$GMN" "$isolated/gemini-api.sh"
  bindir="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  git -C "$repo" init -q 2>/dev/null
  cat > "$bindir/curl" <<'SH'
#!/usr/bin/env bash
echo "CURL_INVOKED" >> "$CURL_LOG"
exit 1
SH
  chmod +x "$bindir/curl"
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    PATH="$bindir:$PATH" CURL_LOG="$bindir/curl.log" bash -c '
      unset GEMINI_API_KEY GEMINI_POLICY_GUARD
      source "'"$isolated"'/gemini-api.sh"
      gmn_call "test prompt" </dev/null
    '
  )"
  rc=$?
  curl_hit="no"; [[ -f "$bindir/curl.log" ]] && curl_hit="yes"
  rm -rf "$isolated" "$bindir" "$repo"
  [[ "$rc" == "5" ]] && pass "A5b: gmn_call with missing policy lib returns 5 (infra_error)" \
    || fail "A5b: gmn_call with missing policy lib returns 5" "rc=$rc"
  [[ "$out" == *"policy check unavailable"* ]] \
    && pass "A5b: infra-error message is distinct from the denied message" \
    || fail "A5b: infra-error message distinct from denied message" "$out"
  [[ "$curl_hit" == "no" ]] && pass "A5b: no network call made on infra_error" \
    || fail "A5b: no network call made on infra_error" "curl was invoked"
}
gmn_infra_error_call_test

# A5c — GEMINI_POLICY_GUARD=off with the SAME missing-lib fixture proceeds
# past the guard (the emergency bypass actually bypasses, and it fails open
# ONLY when explicitly set).
gmn_infra_guard_off_call_test() {
  local isolated d repo out rc
  isolated="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  cp "$GMN" "$isolated/gemini-api.sh"
  d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  git -C "$repo" init -q 2>/dev/null
  write_fake_curl "$d" '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    CURL_ARGV_OUT="$d/argv" CURL_STDIN_OUT="$d/stdin" PATH="$d:$PATH" GEMINI_API_KEY="SECRET-gm-guardoff" GEMINI_POLICY_GUARD=off bash -c '
      source "'"$isolated"'/gemini-api.sh"
      gmn_call "review this" </dev/null
    '
  )"
  rc=$?
  rm -rf "$isolated" "$d" "$repo"
  [[ "$rc" == "0" && "$out" == "ok" ]] \
    && pass "A5c: GEMINI_POLICY_GUARD=off proceeds past a missing policy lib" \
    || fail "A5c: GEMINI_POLICY_GUARD=off proceeds past a missing policy lib" "rc=$rc out='$out'"
}
gmn_infra_guard_off_call_test

# A6 — gmn_call in a repo with no receipt (the `normal` steady state) is
# byte-for-byte unaffected: the guard must not alter today's behaviour below
# `sensitive` (regression against the existing gmn_argv_test success path).
gmn_normal_repo_regression_test() {
  local d repo home; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  home="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  git -C "$repo" init -q 2>/dev/null
  write_fake_curl "$d" '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
  local out rc
  out="$(
    cd "$repo" 2>/dev/null || exit 1
    export CURL_ARGV_OUT="$d/argv" CURL_STDIN_OUT="$d/stdin" PATH="$d:$PATH" GEMINI_API_KEY="SECRET-gm-normal" HOME="$home"
    # shellcheck disable=SC1090
    source "$GMN"
    gmn_call "review this" </dev/null
  )"
  rc=$?
  rm -rf "$d" "$repo" "$home"
  [[ "$rc" == "0" && "$out" == "ok" ]] \
    && pass "A6: gmn_call unaffected in a normal/no-receipt repo (regression)" \
    || fail "A6: gmn_call unaffected in a normal/no-receipt repo" "rc=$rc out='$out'"
}
gmn_normal_repo_regression_test

# --- deepseek: base-URL allowlist --------------------------------------------
dsr_base() { # dsr_base <DEEPSEEK_BASE_URL-or-empty>  -> resolved DSR_ENDPOINT
  local ov="$1" d; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
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
  local d repo; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }; repo="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
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
