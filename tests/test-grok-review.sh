#!/usr/bin/env bash
# Tests for scripts/lib/grok-review.sh (2026-07-15 audit, PILOT, wired 2026-08-04).
# No real network calls — the key and `curl` are stubbed, so the real Keychain
# and api.x.ai are never touched.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/grok-review.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 (got: '${2:-}')"; FAIL=$((FAIL+1)); }
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2')" "$3"; fi
}

build_clean_repo() {
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  ( cd "$R"; git init -q -b main; git config user.email t@t.t; git config user.name t
    echo base > README.md; git add -A; git commit -qm base )
  echo "$R"
}
build_repo() { # <changed_file>
  local changed="$1"
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  ( cd "$R"; git init -q -b main; git config user.email t@t.t; git config user.name t
    echo base > README.md; git add -A; git commit -qm base
    git checkout -q -b feat
    mkdir -p "$(dirname "$changed")"; echo change > "$changed"
    git add -A; git commit -qm feat )
  echo "$R"
}

# --- 1. model pin: default and env override ----------------------------------
model_default="$(bash -c "source '$LIB'; echo \$GKR_MODEL")"
assert_eq "default model = grok-4.5" "grok-4.5" "$model_default"

model_override="$(GROK_REVIEW_MODEL=grok-4.5-fast bash -c "source '$LIB'; echo \$GKR_MODEL")"
assert_eq "GROK_REVIEW_MODEL overrides the default" "grok-4.5-fast" "$model_override"

# --- 2. base-URL host allowlist (ADR-030 hardening) --------------------------
base_default="$(bash -c "source '$LIB'; echo \$GKR_API_BASE")"
assert_eq "default base = https://api.x.ai/v1" "https://api.x.ai/v1" "$base_default"

base_good="$(GROK_BASE_URL='https://api.x.ai/v1' bash -c "source '$LIB'; echo \$GKR_API_BASE")"
assert_eq "matching-host override honored" "https://api.x.ai/v1" "$base_good"

base_bad="$(GROK_BASE_URL='https://evil.example.com/v1' bash -c "source '$LIB'; echo \$GKR_API_BASE" 2>/dev/null)"
assert_eq "off-allowlist override ignored -> falls to default" "https://api.x.ai/v1" "$base_bad"

# --- 3. gkr_available reflects key resolution (stubbed, no real Keychain) ----
avail_yes="$(bash -c "source '$LIB'; gkr_key() { echo fakekey; }; gkr_available && echo yes || echo no")"
assert_eq "gkr_available -> yes when key resolves" "yes" "$avail_yes"

avail_no="$(bash -c "source '$LIB'; gkr_key() { return 1; }; gkr_available && echo yes || echo no")"
assert_eq "gkr_available -> no when key missing" "no" "$avail_no"

# --- 4. gkr_run degrades cleanly (never crashes) when no key resolves --------
R="$(build_repo docs/notes.md)"
out="$( cd "$R"; bash -c "source '$LIB'; gkr_key() { return 1; }; gkr_run reviewer main HEAD" )"
rc=$?
case "$out" in
  *"UNAVAILABLE"*"no key"*) pass "gkr_run: no key -> UNAVAILABLE banner" ;;
  *) fail "gkr_run: no key -> UNAVAILABLE banner" "$out" ;;
esac
[[ "$rc" -ne 0 ]] && pass "gkr_run: no key -> non-zero (degraded) exit" \
  || fail "gkr_run: no key -> non-zero (degraded) exit" "$rc"

# --- 5. gkr_run on an empty diff: nothing to review, exit 0 (not a failure) --
R="$(build_clean_repo)"
out="$( cd "$R"; bash -c "source '$LIB'; gkr_key() { echo fakekey; }; gkr_run reviewer main HEAD" )"
rc=$?
case "$out" in
  *"empty diff"*) pass "gkr_run: empty diff -> labeled, not treated as a failure" ;;
  *) fail "gkr_run: empty diff -> labeled, not treated as a failure" "$out" ;;
esac
assert_eq "gkr_run: empty diff -> exit 0" "0" "$rc"

# --- 6. gkr_run relays a successful call's findings, labeled advisory --------
# `curl` is stubbed as a shell function (bash prefers a function over PATH for
# an unqualified call) so no real HTTP request is ever made.
R="$(build_repo src/auth/login.ts)"
out="$( cd "$R"; bash -c "
  curl() { printf '{\"choices\":[{\"message\":{\"content\":\"BLOCKING: fake finding at file.ts:1 — test\"}}]}\n200'; }
  source '$LIB'
  gkr_key() { echo fakekey; }
  gkr_run reviewer main HEAD
" )"
rc=$?
if echo "$out" | grep -q "fourth voice (PILOT)" \
   && echo "$out" | grep -q "BLOCKING: fake finding" \
   && echo "$out" | grep -q "advisory; does not block"; then
  pass "gkr_run: relays findings, labeled advisory"
else
  fail "gkr_run: relays findings, labeled advisory" "$out"
fi
assert_eq "gkr_run: successful call -> exit 0" "0" "$rc"

# --- 7. cross-family invariant: the pinned model is never a Claude family id -
if echo "$model_default$model_override" | grep -qiE 'claude|anthropic|opus|sonnet|haiku|fable'; then
  fail "cross-family invariant (pinned model is a Claude family)" "$model_default / $model_override"
else
  pass "cross-family invariant (pinned model is non-Claude)"
fi

# --- 8. syntax sanity ---------------------------------------------------------
bash -n "$LIB" && pass "bash -n syntax check" || fail "bash -n syntax check" "non-zero"

echo "----------------------------------------"
echo "grok-review: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
