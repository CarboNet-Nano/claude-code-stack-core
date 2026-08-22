#!/usr/bin/env bash
# Tests for scripts/lib/openai-mini-review.sh (2026-08-04 PILOT, fifth voice).
# No network calls — key resolution and oair_call are stubbed by overriding the
# sourced functions, so the real Keychain/API is never touched.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/openai-mini-review.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 (got: '${2:-}')"; FAIL=$((FAIL+1)); }
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2')" "$3"; fi
}

# --- a throwaway git repo: one commit on main, nothing uncommitted -----------
build_clean_repo() {
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  ( cd "$R"; git init -q -b main; git config user.email t@t.t; git config user.name t
    echo base > README.md; git add -A; git commit -qm base )
  echo "$R"
}

# build_repo <changed_file> : base commit + a feature commit changing the path
build_repo() {
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
model_default="$(bash -c "source '$LIB'; echo \$OMR_MODEL")"
assert_eq "default model = gpt-5.1-codex-mini" "gpt-5.1-codex-mini" "$model_default"

model_override="$(OPENAI_MINI_REVIEW_MODEL=gpt-5-mini bash -c "source '$LIB'; echo \$OMR_MODEL")"
assert_eq "OPENAI_MINI_REVIEW_MODEL overrides the default" "gpt-5-mini" "$model_override"

# --- 2. omr_available reflects the underlying oair_available (stubbed) -------
avail_yes="$(bash -c "source '$LIB'; oair_available() { return 0; }; omr_available && echo yes || echo no")"
assert_eq "omr_available -> yes when key resolves" "yes" "$avail_yes"

avail_no="$(bash -c "source '$LIB'; oair_available() { return 1; }; omr_available && echo yes || echo no")"
assert_eq "omr_available -> no when key missing" "no" "$avail_no"

# --- 3. omr_run degrades cleanly (never crashes, never exits the caller) when
# no key resolves — advisory-only contract.
R="$(build_repo docs/notes.md)"
out="$( cd "$R"; bash -c "source '$LIB'; oair_available() { return 1; }; omr_run reviewer main HEAD" )"
rc=$?
case "$out" in
  *"UNAVAILABLE"*"no key"*) pass "omr_run: no key -> UNAVAILABLE banner" ;;
  *) fail "omr_run: no key -> UNAVAILABLE banner" "$out" ;;
esac
[[ "$rc" -ne 0 ]] && pass "omr_run: no key -> non-zero (degraded) exit" \
  || fail "omr_run: no key -> non-zero (degraded) exit" "$rc"

# --- 4. omr_run on an empty diff: nothing to review, exit 0 (not a failure) --
R="$(build_clean_repo)"
out="$( cd "$R"; bash -c "source '$LIB'; oair_available() { return 0; }; omr_run reviewer main HEAD" )"
rc=$?
case "$out" in
  *"empty diff"*) pass "omr_run: empty diff -> labeled, not treated as a failure" ;;
  *) fail "omr_run: empty diff -> labeled, not treated as a failure" "$out" ;;
esac
assert_eq "omr_run: empty diff -> exit 0" "0" "$rc"

# --- 5. omr_run relays oair_call's content and never sets a blocking result on
# a successful call (advisory framing, findings present).
R="$(build_repo src/auth/login.ts)"
out="$( cd "$R"; bash -c "source '$LIB'; oair_available() { return 0; }; oair_call() { echo 'BLOCKING: fake finding at file.ts:1 — test'; return 0; }; omr_run reviewer main HEAD" )"
rc=$?
if echo "$out" | grep -q "fifth voice (PILOT)" \
   && echo "$out" | grep -q "BLOCKING: fake finding" \
   && echo "$out" | grep -q "advisory; does not block"; then
  pass "omr_run: relays findings, labeled advisory"
else
  fail "omr_run: relays findings, labeled advisory" "$out"
fi
assert_eq "omr_run: successful call -> exit 0" "0" "$rc"

# --- 6. cross-family invariant: the pinned model is never a Claude family id -
if echo "$model_default$model_override" | grep -qiE 'claude|anthropic|opus|sonnet|haiku|fable'; then
  fail "cross-family invariant (pinned model is a Claude family)" "$model_default / $model_override"
else
  pass "cross-family invariant (pinned model is non-Claude)"
fi

# --- 7. syntax sanity ---------------------------------------------------------
bash -n "$LIB" && pass "bash -n syntax check" || fail "bash -n syntax check" "non-zero"

echo "----------------------------------------"
echo "openai-mini-review: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
