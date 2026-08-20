#!/usr/bin/env bash
# Tests for scripts/org-check.sh (/carbonet) — architect handoff §A.6, C01-C31.
#
# Every test builds an isolated fixture "world": a fake $HOME (with its own
# ~/.claude tree), a fake PATH (containing only tools this suite explicitly
# allows), and its own org.json + .claude/stack-config.json. No test makes a
# real network call, reads the real Keychain, or touches the real $HOME —
# PATH excludes the system's real `claude`/`curl`/`security` entirely, so
# this dev box's real Claude session / Keychain items can never leak in.
#
# Deviations from the literal C01/C09-style "four ✅ rows" wording are noted
# inline where they exist — see the C01 comment below.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORG_CHECK="$REPO_ROOT/scripts/org-check.sh"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/carbonet-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------- real tools
# A curated PATH of real, unmodified tools org-check.sh legitimately needs
# (jq, bash, date, coreutils...) with NO fallback to the system PATH — so a
# fixture's deliberately-absent `claude` stays absent even though this dev
# box has the real Claude Code CLI on its PATH.
REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"
for t in jq bash date mktemp grep sed tr wc basename dirname cat mkdir rm ls \
         head tail sort uniq cut awk expr true false env printf; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$REALBIN/$t"
done

# ---------------------------------------------------------------- fixtures
mkworld() {
  local name="$1"
  local w="$TMP/w-$name-$$-$RANDOM"
  mkdir -p "$w/home/.claude/scripts/lib" "$w/home/.claude/lib" "$w/home/.claude/config" \
           "$w/home/.claude/schemas" "$w/bin" "$w/proj/.claude" "$w/curl-ctl"

  cp "$REPO_ROOT/scripts/lib/openai-key.sh" "$w/home/.claude/scripts/lib/openai-key.sh"
  cp "$REPO_ROOT/scripts/lib/gemini-api.sh" "$w/home/.claude/scripts/lib/gemini-api.sh"
  cp "$REPO_ROOT/scripts/lib/cross-family-preflight.sh" "$w/home/.claude/scripts/lib/cross-family-preflight.sh"
  cp "$REPO_ROOT/lib/find-stack-config.sh" "$w/home/.claude/lib/find-stack-config.sh"
  cp "$REPO_ROOT/schemas/stack-config-schema.json" "$w/home/.claude/schemas/stack-config-schema.json"
  if [[ -f "$REPO_ROOT/lib/stack-config-validate.sh" ]]; then
    cp "$REPO_ROOT/lib/stack-config-validate.sh" "$w/home/.claude/lib/stack-config-validate.sh"
  fi

  cat > "$w/home/.claude/lib/stack-freshness.sh" << 'EOF'
#!/usr/bin/env bash
# test stub — the token is controlled entirely by $STUB_FRESHNESS_TOKEN
printf '%s\n' "${STUB_FRESHNESS_TOKEN:-current}"
EOF
  chmod +x "$w/home/.claude/lib/stack-freshness.sh"

  cat > "$w/home/.claude/.stack-install.json" << 'EOF'
{"stack_version":"1.3.1","tier":4,"source_sha":"deadbeef","source_branch":"main","source_repo":"/nowhere","installed_at":"2026-08-11T00:00:00Z"}
EOF

  cat > "$w/home/.claude/config/org.json" << 'EOF'
{
  "version": 1,
  "org": {
    "id": "carbonet",
    "display_name": "CarboNet",
    "access_url": "https://access.carbonet.app",
    "support_contact": "ask Bill in #eng-help",
    "required_providers": ["anthropic", "openai", "gemini"]
  }
}
EOF

  cat > "$w/proj/.claude/stack-config.json" << 'EOF'
{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01"}
EOF

  # Always-fail security by default: the real Keychain must never be
  # consulted (this dev box carries real openai-api-key/gemini-api-key
  # items — a leak here would be the ADR-026 class of bug).
  cat > "$w/bin/security" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$w/bin/security"

  printf '%s' "$w"
}

write_fake_claude() {  # write_fake_claude <world> <true|false|absent>
  local w="$1" val="$2"
  [[ "$val" == "absent" ]] && { rm -f "$w/bin/claude"; return; }
  cat > "$w/bin/claude" << EOF
#!/usr/bin/env bash
if [[ "\$1" == "auth" && "\$2" == "status" ]]; then
  echo '{"loggedIn": $val}'
  exit 0
fi
exit 1
EOF
  chmod +x "$w/bin/claude"
}

write_fake_curl() {  # written once per world; behavior driven by $CURL_CTL_DIR files
  local w="$1"
  cat > "$w/bin/curl" << 'EOF'
#!/usr/bin/env bash
CTL="${CURL_CTL_DIR:-/nonexistent}"
url=""
for a in "$@"; do
  case "$a" in http*://*) url="$a" ;; esac
done
: >> "$CTL/../curl-log" 2>/dev/null || true
printf '%s\n' "$url" >> "$CTL/../curl-log" 2>/dev/null || true
has_stdin=no
for a in "$@"; do [[ "$a" == "@-" ]] && has_stdin=yes; done
[[ "$has_stdin" == yes ]] && cat > /dev/null
resp=""
case "$url" in
  *api.openai.com/v1/models*)   resp="$CTL/openai_models" ;;
  *v1/chat/completions*)        resp="$CTL/openai_chat" ;;
  *generateContent*)            resp="$CTL/gemini_generate" ;;
  *generativelanguage*/models*) resp="$CTL/gemini_models" ;;
  *access.carbonet.app*)        resp="$CTL/access" ;;
esac
if [[ -f "$resp" ]] && grep -qx "REFUSED" "$resp" 2>/dev/null; then
  exit 7
fi
if [[ -f "$resp" ]]; then
  printf '%s' "$(cat "$resp")"
else
  printf '000'
fi
EOF
  chmod +x "$w/bin/curl"
}

set_curl() {  # set_curl <world> <key> <code-or-REFUSED>
  local w="$1" key="$2" val="$3"
  mkdir -p "$w/curl-ctl"
  printf '%s' "$val" > "$w/curl-ctl/$key"
}

# run_check <world> [ENV=val ...] -- [extra org-check.sh args...]
run_check() {
  local w="$1"; shift
  local -a envs=()
  while [[ "${1:-}" != "--" ]]; do envs+=("$1"); shift; done
  shift
  (
    unset OPENAI_API_KEY GEMINI_API_KEY STUB_FRESHNESS_TOKEN
    if (( ${#envs[@]} )); then
      for kv in "${envs[@]}"; do export "$kv"; done
    fi
    export HOME="$w/home"
    export PATH="$w/bin:$REALBIN"
    export CURL_CTL_DIR="$w/curl-ctl"
    mkdir -p "$CURL_CTL_DIR"
    cd "$w/proj"
    bash "$ORG_CHECK" --org-config "$w/home/.claude/config/org.json" \
      --stack-config "$w/proj/.claude/stack-config.json" "$@"
  )
}

curl_log_of() { cat "$1/curl-log" 2>/dev/null || true; }

VOCAB_RE='API|credential|keychain|Keychain|\bexport\b|\b[45][0-9][0-9]\b|exit code'
assert_vocab_clean() {  # assert_vocab_clean <label> <text>
  if grep -qE -- "$VOCAB_RE" <<<"$2"; then
    fail "$1 (vocabulary gate violated)"
  else
    pass "$1"
  fi
}
assert_no_token_word() {
  if grep -qw "token" <<<"$2"; then
    fail "$1 (contains the word 'token')"
  else
    pass "$1"
  fi
}

REASON_ENUM="missing rejected unreachable not-signed-in not-checkable-from-cli behind unstamped unstamped-profile no-source-repo helper-missing no-config bad-json invalid-config version-behind offline no-quota"
reason_in_enum() {
  local r="$1" e
  [[ -z "$r" || "$r" == "null" ]] && return 0
  for e in $REASON_ENUM; do [[ "$r" == "$e" ]] && return 0; done
  return 1
}

echo "=== carbonet (org-check.sh) ==="

# --- C01 (adapted — see note) -------------------------------------------
# The literal handoff text asks for "four ✅ rows" on an all-green fixture.
# That is unreachable under this design: A-D5 + the Check-2 spec are
# explicit that Access has NO ✅ path until MCQ A2's phase 2 ships ("There
# is no ✅ path for this check until MCQ A2 is answered"), and C11 below
# tests exactly that invariant. Implemented instead as the best CURRENTLY
# reachable state: Keys/Stack/Repo all ✅, Access reachable (⚠️) — verdict
# ALMOST READY, never READY, exit 20. This resolves a genuine contradiction
# in the handoff in favor of the more load-bearing, repeated constraint
# ("must never print READY while any check is unknown").
W="$(mkworld c01)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access 200
STACK_FRESHNESS_TOKEN=current
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN=current -- )"
rc=$?
if grep -qc '✅' <<<"$out"; then :; fi
n_ok="$(grep -o '✅' <<<"$out" | wc -l | tr -d ' ')"
[[ "$n_ok" == "3" ]] && pass "C01(adapted): 3 ✅ rows (Keys/Stack/Repo) on the best-case fixture" \
  || fail "C01(adapted): expected 3 ✅ rows, got $n_ok"
grep -q "ALMOST READY — 1 thing could not be checked." <<<"$out" \
  && pass "C01(adapted): verdict is ALMOST READY (Access can never be ✅ yet)" \
  || fail "C01(adapted): verdict line wrong"
[[ "$rc" == "20" ]] && pass "C01(adapted): exit 20" || fail "C01(adapted): exit was $rc, want 20"

# --- C02 -----------------------------------------------------------------
W="$(mkworld c02)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" gemini_models 200
out="$(run_check "$W" GEMINI_API_KEY=sk-test -- )"
rc=$?
grep -q "❌ Keys" <<<"$out" && pass "C02: Keys row is ❌" || fail "C02: Keys row not ❌"
grep -q "NOT READY — 1 thing needs fixing." <<<"$out" && pass "C02: verdict text" || fail "C02: verdict text wrong"
[[ "$rc" == "10" ]] && pass "C02: exit 10" || fail "C02: exit was $rc"
grep -q "project-init" <<<"$out" && fail "C02: fix line should be project-init-free" \
  || pass "C02: fix line is project-init-free"

# --- C03 -------------------------------------------------------------------
W="$(mkworld c03)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 401
set_curl "$W" gemini_models 200
out_json="$(run_check "$W" OPENAI_API_KEY=sk-dead GEMINI_API_KEY=sk-test -- --json)"
reason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .reason' <<<"$out_json")"
[[ "$reason" == "rejected" ]] && pass "C03: OpenAI 401 => reason rejected (never missing)" \
  || fail "C03: OpenAI 401 reason was '$reason'"

# --- C04 ---------------------------------------------------------------
W="$(mkworld c04a)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 403
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-dead -- --json)"
reason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .reason' <<<"$out_json")"
[[ "$reason" == "rejected" ]] && pass "C04a: Gemini 403 => rejected" || fail "C04a: got '$reason'"

W="$(mkworld c04b)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models REFUSED
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
reason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .reason' <<<"$out_json")"
status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .status' <<<"$out_json")"
[[ "$reason" == "unreachable" && "$status" == "warn" ]] \
  && pass "C04b: Gemini connection-refused (key present) => warn/unreachable, not fail" \
  || fail "C04b: got status=$status reason=$reason"

# --- C05 -----------------------------------------------------------------
W="$(mkworld c05)"
write_fake_claude "$W" false
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
grep -q "❌ Keys" <<<"$out" && pass "C05: Claude loggedIn:false => Keys ❌" || fail "C05: Keys not ❌"
log="$(curl_log_of "$W")"
# Access is checked unconditionally (Check 2 always runs); what must NOT
# happen is a provider (openai/gemini) probe.
if grep -q "api.openai.com\|generativelanguage" <<<"$log"; then
  fail "C05: a provider probe was attempted: $log"
else
  pass "C05: no provider probe attempted (openai/gemini curl never invoked)"
fi

# --- C06 -------------------------------------------------------------------
W="$(mkworld c06)"
write_fake_claude "$W" absent
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
rc=$?
grep -q "⚠️  Keys" <<<"$out" && pass "C06: claude absent => Keys ⚠️" || fail "C06: Keys row wrong: $(grep Keys <<<"$out")"
grep -q "^ALMOST READY" <<<"$out" && pass "C06: verdict ALMOST" || fail "C06: verdict not ALMOST"
[[ "$rc" == "20" ]] && pass "C06: exit 20" || fail "C06: exit was $rc"

# --- C07 ---------------------------------------------------------------
W="$(mkworld c07)"
write_fake_claude "$W" true
write_fake_curl "$W"
jq '.stack_tier = 1' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
keys_row="$(grep 'Keys' <<<"$out")"
if grep -qi "openai" <<<"$keys_row" || grep -qi "gemini" <<<"$keys_row"; then
  fail "C07: tier-1 Keys row still mentions OpenAI/Gemini: $keys_row"
else
  pass "C07: tier-1 Keys row shows only Claude"
fi
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
skipped="$(jq -r '[.checks[] | select(.id=="keys") | .items[] | select(.provider!="anthropic") | .status] | unique | join(",")' <<<"$out_json")"
[[ "$skipped" == "skipped" ]] && pass "C07: openai/gemini items are status skipped, not fail/warn" \
  || fail "C07: openai/gemini item statuses were '$skipped'"

# --- C08 -----------------------------------------------------------------
W="$(mkworld c08)"
write_fake_claude "$W" true
write_fake_curl "$W"
jq '.stack_tier = 4' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
jq '.tier = 1' "$W/home/.claude/.stack-install.json" > "$W/home/.claude/.stack-install.json.tmp" \
  && mv "$W/home/.claude/.stack-install.json.tmp" "$W/home/.claude/.stack-install.json"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
keys_row="$(grep 'Keys' <<<"$out")"
if grep -qi "openai" <<<"$keys_row" || grep -qi "gemini" <<<"$keys_row"; then
  fail "C08: min(4,1)=1 still checked tier-2 providers: $keys_row"
else
  pass "C08: min(repo_tier=4, installed_tier=1)=1 => tier-2 providers skipped"
fi

# --- C09 -------------------------------------------------------------------
W="$(mkworld c09)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access 200
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
areason="$(jq -r '.checks[] | select(.id=="access") | .reason' <<<"$out_json")"
verdict="$(jq -r '.verdict' <<<"$out_json")"
[[ "$areason" == "not-checkable-from-cli" ]] && pass "C09: access 200 => not-checkable-from-cli" \
  || fail "C09: access reason was '$areason'"
[[ "$verdict" == "ALMOST" ]] && pass "C09: verdict ALMOST" || fail "C09: verdict was '$verdict'"

# --- C10 -------------------------------------------------------------------
W="$(mkworld c10)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access REFUSED
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
rc=$?
areason="$(jq -r '.checks[] | select(.id=="access") | .reason' <<<"$out_json")"
verdict="$(jq -r '.verdict' <<<"$out_json")"
[[ "$areason" == "unreachable" ]] && pass "C10: access refused => unreachable" || fail "C10: got '$areason'"
[[ "$verdict" == "ALMOST" ]] && pass "C10: verdict ALMOST, never NOT_READY" || fail "C10: verdict was '$verdict'"
run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json >/dev/null
rc="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- ; echo $?)"
[[ "${rc##*$'\n'}" == "20" ]] && pass "C10: exit 20" || fail "C10: exit was ${rc##*$'\n'}"

# --- C11 -------------------------------------------------------------------
W="$(mkworld c11)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access REFUSED
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
if grep -q "READY — everything's good." <<<"$out"; then
  fail "C11: printed READY while Access is unknown"
else
  pass "C11: never claims READY while Access is blind"
fi

# --- C12 -------------------------------------------------------------------
W="$(mkworld c12)"
write_fake_claude "$W" true
write_fake_curl "$W"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN=repo-not-found -- )"
grep -q "Can't tell if the stack is current on this machine" <<<"$out" \
  && pass "C12: repo-not-found is printed (not suppressed, unlike /goodmorning)" \
  || fail "C12: repo-not-found line missing"

# --- C13 -------------------------------------------------------------------
W="$(mkworld c13)"
write_fake_claude "$W" true
write_fake_curl "$W"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="3 behind — run update.sh" -- )"
rc=$?
grep -q "❌ Stack" <<<"$out" && pass "C13: N-behind => Stack ❌" || fail "C13: Stack row: $(grep Stack <<<"$out")"
[[ "$rc" == "10" ]] && pass "C13: exit 10" || fail "C13: exit was $rc"

# --- C13a2: an install point this repo has never heard of --------------------
# A fresh clone, a rebased branch, or a stamp copied from another machine
# makes the rev-list range invalid, and the count came back as "?" -- which
# fell through and printed "stack is ? commit(s) behind". Callers render any
# N-behind token as a failure, so that read as broken with no way to act.
# It is not a distance; it is a stamp we cannot place.
W="$(mkworld c13a2)"
write_fake_claude "$W" true
write_fake_curl "$W"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="unknown" -- )"
rc=$?
grep -q "? commit" <<<"$out" && fail "C13a2: printed a question mark as a distance" "$out" \
  || pass "C13a2: an unplaceable install point never prints '? commit(s) behind'"
grep -q "❌ Stack" <<<"$out" && fail "C13a2: an unplaceable stamp must not read as out of date" "$(grep Stack <<<"$out")" \
  || pass "C13a2: an unplaceable stamp is reported as can't-tell, not as behind"

# --- C13b: the CURRENT token shape ------------------------------------------
# stack-freshness.sh used to emit "N behind — run update.sh". It now emits a
# bare "N behind": /goodmorning applies the update itself at a clean boot, so
# the token no longer tells anyone to run anything. Both shapes must work --
# a machine can be running an installed stack older than this script.
W="$(mkworld c13b)"
write_fake_claude "$W" true
write_fake_curl "$W"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="3 behind" -- )"
rc=$?
grep -q "❌ Stack" <<<"$out" && pass "C13b: the bare 'N behind' token also reports Stack ❌" \
  || fail "C13b: Stack row: $(grep Stack <<<"$out")"
grep -q "3 versions behind" <<<"$out" && pass "C13b: the count survives the new token shape" \
  || fail "C13b: count missing: $(grep Stack <<<"$out")"
[[ "$rc" == "10" ]] && pass "C13b: exit 10" || fail "C13b: exit was $rc"

# --- C13c: nothing tells a human to run update.sh ---------------------------
# The instruction is a dead end: update.sh refuses on a dirty tree, so being
# told to run it can arrive at a moment when it cannot be obeyed, and the
# obvious workaround (stash, update, unstash) is how in-flight work gets lost.
# /goodmorning applies the update itself at a clean start instead.
REAL_FRESH="$REPO_ROOT/lib/stack-freshness.sh"
if [[ -f "$REAL_FRESH" ]]; then
  # Code only -- the comments explain why the instruction was removed, and
  # matching those would make the guard unwritable.
  grep -vE '^\s*#' "$REAL_FRESH" | grep -q 'run update\.sh' \
    && fail "C13c: stack-freshness.sh still tells the reader to run update.sh" \
    || pass "C13c: stack-freshness.sh reports distance, never an instruction to run update.sh"
else
  pass "C13c: stack-freshness.sh not present in this checkout (nothing to assert)"
fi

# --- C14 -------------------------------------------------------------------
W="$(mkworld c14)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
out="$(run_check "$W" OPENAI_API_KEY=ZZSENTINELZZ GEMINI_API_KEY=sk-test -- 2>&1)"
if grep -q "ZZSENTINELZZ" <<<"$out"; then
  fail "C14: key sentinel leaked into output"
else
  pass "C14: key sentinel never appears in stdout+stderr"
fi

# --- C15 -------------------------------------------------------------------
W="$(mkworld c15)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
manifest() { find "$1" -type f -print0 | sort -z | xargs -0 -I{} sh -c 'echo {}; wc -c < {}' 2>/dev/null; }
before="$(manifest "$W/home")"
run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- >/dev/null 2>&1
run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --deep >/dev/null 2>&1
after="$(manifest "$W/home")"
[[ "$before" == "$after" ]] && pass "C15: fixture \$HOME unchanged after a full run + --deep" \
  || fail "C15: fixture \$HOME was modified"

# --- C16 -------------------------------------------------------------------
W="$(mkworld c16)"
write_fake_claude "$W" true
write_fake_curl "$W"
rm -f "$W/proj/.claude/stack-config.json"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
grep -q "❌ Repo" <<<"$out" && pass "C16: missing config => Repo ❌" || fail "C16: Repo row: $(grep Repo <<<"$out")"
grep -q "project-init" <<<"$out" && pass "C16: fix names /project-init" || fail "C16: fix missing /project-init"

# --- C17 -------------------------------------------------------------------
W="$(mkworld c17-badjson)"
write_fake_claude "$W" true
write_fake_curl "$W"
printf 'not json' > "$W/proj/.claude/stack-config.json"
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
rreason="$(jq -r '.checks[] | select(.id=="repo") | .reason' <<<"$out_json")"
[[ "$rreason" == "bad-json" ]] && pass "C17: malformed JSON => bad-json" || fail "C17: got '$rreason'"

if [[ ! -f "$REPO_ROOT/lib/stack-config-validate.sh" ]]; then
  skip "C17: schema-invalid config => invalid-config (lib/stack-config-validate.sh not yet landed — owned by a parallel implementer, A-D8)"
else
  # NOTE: uses orchestration_mode, not strict_mode. strict_mode is in
  # stack-sync.sh's KEEP_LIST, whose reconciliation legitimately leaves it
  # `null` for any repo that never set it — checking strict_mode's type in
  # the SHARED validator broke 14 of tests/test-stack-sync.sh's 31 checks
  # (reviewer-review follow-up, 2026-08-11); see lib/stack-config-
  # validate.sh's header for the full story. orchestration_mode is NOT
  # keep-listed (reconcile() always fills it from the template when unset),
  # so it proves the same "scv_validate is wired in" point without that
  # conflict.
  W="$(mkworld c17-invalid)"
  write_fake_claude "$W" true
  write_fake_curl "$W"
  jq '.orchestration_mode = "garbage"' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
    && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
  out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
  rreason="$(jq -r '.checks[] | select(.id=="repo") | .reason' <<<"$out_json")"
  [[ "$rreason" == "invalid-config" ]] && pass "C17: schema-invalid (orchestration_mode:garbage) => invalid-config (scv_validate wired in)" \
    || fail "C17: got '$rreason'"
fi

# --- C18 -------------------------------------------------------------------
W="$(mkworld c18)"
write_fake_claude "$W" true
write_fake_curl "$W"
jq '.stack_version = "1.1.5"' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
grep -q "❌ Repo" <<<"$out" && grep -q "1.1.5" <<<"$out" && grep -q "1.3.1" <<<"$out" \
  && pass "C18: version-behind => ❌ Repo, both versions in the detail line" \
  || fail "C18: Repo row: $(grep Repo <<<"$out")"

# --- C19 -------------------------------------------------------------------
W="$(mkworld c19)"
write_fake_claude "$W" true
write_fake_curl "$W"
out_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json --no-network)"
rc=$?
log="$(curl_log_of "$W")"
[[ -z "$log" ]] && pass "C19: --no-network => curl stub never invoked" || fail "C19: curl was invoked: $log"
areason="$(jq -r '.checks[] | select(.id=="access") | .reason' <<<"$out_json")"
oreason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .reason' <<<"$out_json")"
[[ "$areason" == "offline" ]] && pass "C19: access => offline" || fail "C19: access reason '$areason'"
[[ "$oreason" == "offline" ]] && pass "C19: provider-liveness => offline" || fail "C19: openai reason '$oreason'"
verdict="$(jq -r '.verdict' <<<"$out_json")"
[[ "$verdict" != "READY" ]] && pass "C19: verdict never READY under --no-network" || fail "C19: verdict was READY"
[[ "$rc" == "20" ]] && pass "C19: exit 20" || fail "C19: exit was $rc"

# --- C20 -------------------------------------------------------------------
# Re-derive reasons from the JSON captured across the fixtures already run
# above by re-running a representative sample with --json.
declare -a REASON_SAMPLES=()
collect_reasons() {
  local j="$1"
  while IFS= read -r r; do REASON_SAMPLES+=("$r"); done < <(jq -r '.. | .reason? // empty' <<<"$j" 2>/dev/null)
}
W="$(mkworld c20a)"; write_fake_claude "$W" true; write_fake_curl "$W"
set_curl "$W" openai_models 401; set_curl "$W" gemini_models 400; set_curl "$W" access 200
collect_reasons "$(run_check "$W" OPENAI_API_KEY=sk-dead GEMINI_API_KEY=sk-dead -- --json)"
W="$(mkworld c20b)"; write_fake_claude "$W" false; write_fake_curl "$W"
collect_reasons "$(run_check "$W" -- --json)"
W="$(mkworld c20c)"; write_fake_claude "$W" absent; write_fake_curl "$W"
collect_reasons "$(run_check "$W" -- --json)"
W="$(mkworld c20d)"; write_fake_claude "$W" true; write_fake_curl "$W"
rm -f "$W/proj/.claude/stack-config.json"
collect_reasons "$(run_check "$W" -- --json --no-network)"
bad=0
for r in "${REASON_SAMPLES[@]}"; do
  reason_in_enum "$r" || { bad=1; echo "  unexpected reason: $r"; }
done
[[ "$bad" == "0" ]] && pass "C20: every observed reason is in the closed set" || fail "C20: an out-of-set reason appeared"

# --- C21 / C22 ---------------------------------------------------------------
declare -a VOCAB_SAMPLES=()
VOCAB_SAMPLES+=("$out")  # C19's output (most recent $out, reused for coverage)
W="$(mkworld c21a)"; write_fake_claude "$W" true; write_fake_curl "$W"
set_curl "$W" openai_models 401; set_curl "$W" gemini_models 400; set_curl "$W" access REFUSED
VOCAB_SAMPLES+=("$(run_check "$W" OPENAI_API_KEY=sk-dead GEMINI_API_KEY=sk-dead -- )")
W="$(mkworld c21b)"; write_fake_claude "$W" false; write_fake_curl "$W"
VOCAB_SAMPLES+=("$(run_check "$W" -- )")
W="$(mkworld c21c)"; write_fake_claude "$W" absent; write_fake_curl "$W"
VOCAB_SAMPLES+=("$(run_check "$W" -- )")
W="$(mkworld c21d)"; write_fake_claude "$W" true; write_fake_curl "$W"
set_curl "$W" openai_models 429
VOCAB_SAMPLES+=("$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --deep)")
idx=0
for s in "${VOCAB_SAMPLES[@]}"; do
  idx=$((idx+1))
  assert_vocab_clean "C21.$idx: vocabulary gate" "$s"
  assert_no_token_word "C22.$idx: no literal 'token' in output" "$s"
done
# also assert on a --json sample (C22 covers every output mode)
assert_no_token_word "C22.json: no literal 'token' in --json output" "$out_json"

# --- C23 -------------------------------------------------------------------
W="$(mkworld c23)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_chat 200
out_deep="$(run_check "$W" OPENAI_API_KEY=sk-test -- --deep)"
log="$(curl_log_of "$W")"
grep -q "chat/completions" <<<"$log" && pass "C23: --deep invoked the quota probe (cfp_run ran)" \
  || fail "C23: chat/completions was never hit"
grep -q "(deep check — costs about a penny)" <<<"$out_deep" && pass "C23: --deep footer changes" \
  || fail "C23: deep footer missing"
W="$(mkworld c23b)"; write_fake_claude "$W" true; write_fake_curl "$W"
set_curl "$W" openai_models 200
out_default="$(run_check "$W" OPENAI_API_KEY=sk-test -- )"
grep -q "(spending limits not checked — /carbonet --deep checks those)" <<<"$out_default" \
  && pass "C23: default footer is the free-check disclaimer" || fail "C23: default footer wrong"

# --- C24 -------------------------------------------------------------------
W="$(mkworld c24)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_chat 429
out_deep="$(run_check "$W" OPENAI_API_KEY=sk-zero-quota -- --deep --json)"
kstatus="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .status' <<<"$out_deep")"
kreason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .reason' <<<"$out_deep")"
[[ "$kstatus" == "fail" && "$kreason" == "no-quota" ]] && pass "C24: --deep zero-quota (429) => fail/no-quota" \
  || fail "C24: got status=$kstatus reason=$kreason"
set_curl "$W" openai_models 200
out_free="$(run_check "$W" OPENAI_API_KEY=sk-zero-quota -- --json)"
kstatus_free="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .status' <<<"$out_free")"
[[ "$kstatus_free" == "ok" ]] && pass "C24: same fixture, default (non-deep) run => ok (depths genuinely differ)" \
  || fail "C24: default-mode status was '$kstatus_free'"

# --- C25 -------------------------------------------------------------------
W="$(mkworld c25)"
BAD_ORG="$W/bad-org.json"
printf 'not json' > "$BAD_ORG"
out="$(run_check "$W" -- --org-config "$BAD_ORG" 2>&1)"
rc=$?
[[ "$rc" == "2" ]] && pass "C25: malformed org.json => exit 2" || fail "C25: exit was $rc"
[[ "$rc" != "10" ]] && pass "C25: not NOT_READY (tool failure != user failure)" || fail "C25: exit was NOT_READY-shaped"
grep -q "$BAD_ORG" <<<"$out" && pass "C25: message names the file" || fail "C25: message doesn't name the file"

W="$(mkworld c25b)"
MISSING_ORG="$W/does-not-exist.json"
out="$(run_check "$W" -- --org-config "$MISSING_ORG" 2>&1)"
rc=$?
[[ "$rc" == "2" ]] && pass "C25b: missing org.json => exit 2" || fail "C25b: exit was $rc"

# --- C26 -------------------------------------------------------------------
W="$(mkworld c26)"
write_fake_curl "$W"
HTTP_ORG="$W/http-org.json"
jq '.org.access_url = "http://access.carbonet.app"' "$W/home/.claude/config/org.json" > "$HTTP_ORG"
out="$(run_check "$W" -- --org-config "$HTTP_ORG" 2>&1)"
rc=$?
[[ "$rc" == "2" ]] && pass "C26: http:// access_url => exit 2, refuse" || fail "C26: exit was $rc"
log="$(curl_log_of "$W")"
[[ -z "$log" ]] && pass "C26: no request made" || fail "C26: a request was made: $log"

# --- C27 -------------------------------------------------------------------
W="$(mkworld c27)"
BAD_PROV_ORG="$W/badprov-org.json"
jq '.org.required_providers = ["anthropic","deepseek"]' "$W/home/.claude/config/org.json" > "$BAD_PROV_ORG"
out="$(run_check "$W" -- --org-config "$BAD_PROV_ORG" 2>&1)"
rc=$?
[[ "$rc" == "2" ]] && pass "C27: unknown provider 'deepseek' => exit 2" || fail "C27: exit was $rc"
grep -q "deepseek" <<<"$out" && pass "C27: message names the unknown provider" || fail "C27: message doesn't name it"

# --- C28 -------------------------------------------------------------------
W="$(mkworld c28)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
out1="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
out2="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- )"
body1="$(tail -n +3 <<<"$out1")"
body2="$(tail -n +3 <<<"$out2")"
[[ "$body1" == "$body2" ]] && pass "C28: two runs are byte-identical apart from the timestamp line" \
  || fail "C28: runs diverged beyond the timestamp"

# --- C29 -------------------------------------------------------------------
# ADR-084 D7 (one boot skill, two faces): skills/carbonet/SKILL.md is
# deleted from the repo and its files.global COPY ROW is deliberately
# removed from tier-0.json (ADR-083 D12 — it is now a generated alias stub,
# not a hand-authored file to copy). The `test -f
# ~/.claude/skills/carbonet/SKILL.md` SMOKE line stays -- D7: "it now
# asserts generation ran." So this case now checks three files.global
# entries (org-check.sh, stack-config-validate.sh, org.json — still real
# copied files) plus the same four smoke tests as before, not four
# files.global entries. Fixed here (tests/ ownership) rather than left
# failing: ADR-084's architect handoff asked this file be "confirmed, no
# edit needed" on the assumption it only tests scripts/org-check.sh, which
# holds for 105 of its 106 assertions but not this one.
TM="$REPO_ROOT/config/tier-manifests/tier-0.json"
have_from() { jq -e --arg f "$1" '.files.global[] | select(.from == $f)' "$TM" >/dev/null 2>&1; }
have_smoke() { jq -e --arg s "$1" '.smoke_tests[] | select(. == $s)' "$TM" >/dev/null 2>&1; }
ok29=1
have_from "skills/carbonet/SKILL.md" && { fail "C29: tier-0.json still lists skills/carbonet/SKILL.md in files.global -- ADR-084 D7 requires this copy row removed (carbonet is now a generated stub, not a copied file)"; ok29=0; }
have_from "scripts/org-check.sh" || ok29=0
have_from "lib/stack-config-validate.sh" || ok29=0
have_from "config/org.json" || ok29=0
have_smoke "test -f ~/.claude/skills/carbonet/SKILL.md" || ok29=0
have_smoke "test -x ~/.claude/scripts/org-check.sh" || ok29=0
have_smoke "test -x ~/.claude/lib/stack-config-validate.sh" || ok29=0
have_smoke "test -f ~/.claude/config/org.json" || ok29=0
[[ "$ok29" == "1" ]] && pass "C29: tier-0.json has the three post-ADR-084 files.global entries + all four smoke tests (carbonet copy row correctly absent)" \
  || fail "C29: tier-0.json is missing one or more entries/smoke tests (see above)"

# --- C30 -------------------------------------------------------------------
REG="$REPO_ROOT/config/capability-registry.json"
if [[ -f "$REG" ]] && jq -e '.capabilities[] | select(.id=="carbonet")' "$REG" >/dev/null 2>&1; then
  if bash "$REPO_ROOT/scripts/gen-capability-registry.sh" --check >"$TMP/c30-out" 2>&1; then
    pass "C30: gen-capability-registry.sh --check exits 0"
  else
    fail "C30: gen-capability-registry.sh --check found drift"
  fi
else
  skip "C30: config/capability-registry.json not yet regenerated with the carbonet entry (owned outside this implementer's file scope — run scripts/gen-capability-registry.sh once every skill from this change is in place)"
fi

# --- C31 -------------------------------------------------------------------
if bash "$REPO_ROOT/tests/test-stack-sync.sh" > "$TMP/c31-out" 2>&1; then
  if grep -q " 0 failed" "$TMP/c31-out"; then
    pass "C31: tests/test-stack-sync.sh still reports 0 failed (no regression)"
  else
    fail "C31: tests/test-stack-sync.sh passed but summary line unexpected"
  fi
else
  fail "C31: tests/test-stack-sync.sh regressed"
fi

# --- A7/A8: gemini-paid-tier-precondition Option A (docs/plans/2026-08-11-
# gemini-paid-tier-precondition.md) -- the new advisory `gemini-tier` item,
# reusing the SAME --deep generateContent probe as the pre-existing `gemini`
# item (no second network call). -------------------------------------------

FREE_TIER_BODY='{"error":{"code":429,"message":"Resource exhausted","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateContentFreeTierRequests","quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests_per_model_per_day"}]}]}}'

# A7a: 429 + QuotaFailure violation with a free_tier marker -> gemini-tier
# warn/free-tier, AND the pre-existing gemini item is unchanged (fail/no-quota).
W="$(mkworld a7a)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" gemini_generate "$(printf '%s\n429' "$FREE_TIER_BODY")"
out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --deep --json)"
tier_status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier") | .status' <<<"$out_json")"
tier_reason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier") | .reason' <<<"$out_json")"
gemini_status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .status' <<<"$out_json")"
gemini_reason="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .reason' <<<"$out_json")"
[[ "$tier_status" == "warn" && "$tier_reason" == "free-tier" ]] \
  && pass "A7a: 429-with-free_tier marker => gemini-tier warn/free-tier" \
  || fail "A7a: got status=$tier_status reason=$tier_reason"
[[ "$gemini_status" == "fail" && "$gemini_reason" == "no-quota" ]] \
  && pass "A7a: pre-existing gemini item unchanged by the classifier extension (429 => fail/no-quota)" \
  || fail "A7a: gemini item changed: status=$gemini_status reason=$gemini_reason"

# A7b: 200 -> gemini-tier ok, and the pre-existing gemini item is unchanged (ok).
W="$(mkworld a7b)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" gemini_generate "$(printf '{}\n200')"
out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --deep --json)"
tier_status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier") | .status' <<<"$out_json")"
gemini_status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .status' <<<"$out_json")"
[[ "$tier_status" == "ok" ]] && pass "A7b: 200 => gemini-tier ok" || fail "A7b: got status=$tier_status"
[[ "$gemini_status" == "ok" ]] && pass "A7b: pre-existing gemini item unchanged (200 => ok)" \
  || fail "A7b: gemini item changed: status=$gemini_status"

# A7c/A7d: 400/500 -> NO gemini-tier item at all (never guess, finding 4).
for code in 400 500; do
  W="$(mkworld "a7-$code")"
  write_fake_claude "$W" true
  write_fake_curl "$W"
  set_curl "$W" gemini_generate "$(printf '{}\n%s' "$code")"
  out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --deep --json)"
  tier_present="no"
  jq -e '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier")' <<<"$out_json" >/dev/null 2>&1 && tier_present="yes"
  [[ "$tier_present" == "no" ]] && pass "A7c/d: HTTP $code => no gemini-tier item" \
    || fail "A7c/d: gemini-tier item unexpectedly present for HTTP $code"
done

# A7e: connection refused -> NO gemini-tier item.
W="$(mkworld a7-refused)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" gemini_generate "REFUSED"
out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --deep --json)"
tier_present="no"
jq -e '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier")' <<<"$out_json" >/dev/null 2>&1 && tier_present="yes"
[[ "$tier_present" == "no" ]] && pass "A7e: connection refused => no gemini-tier item" \
  || fail "A7e: gemini-tier item unexpectedly present for REFUSED"

# A8a: org-check WITHOUT --deep never emits a gemini-tier item (guards C05).
W="$(mkworld a8a)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" gemini_models 200
out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --json)"
tier_present="no"
jq -e '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier")' <<<"$out_json" >/dev/null 2>&1 && tier_present="yes"
[[ "$tier_present" == "no" ]] && pass "A8a: non-deep run emits no gemini-tier item" \
  || fail "A8a: gemini-tier item present without --deep"

# A8b: tier < 2 skips gemini's probe entirely -> no gemini-tier item (guards
# C07/C08's tier gate).
W="$(mkworld a8b)"
write_fake_claude "$W" true
write_fake_curl "$W"
jq '.stack_tier = 1' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
out_json="$(run_check "$W" GEMINI_API_KEY=sk-test -- --deep --json)"
tier_present="no"
jq -e '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini-tier")' <<<"$out_json" >/dev/null 2>&1 && tier_present="yes"
[[ "$tier_present" == "no" ]] && pass "A8b: tier<2 skips gemini entirely => no gemini-tier item" \
  || fail "A8b: gemini-tier item present at tier<2"

# --- R1-R4: reviewer regression tests (2026-08-11 codex review, BLOCKING) --

# R1 — enum checks used to fail OPEN: `["a","b","c"] | index(.field)` reads
# .field off the ARRAY (jq argument-scoping), errors, stderr is discarded,
# and an invalid orchestration_mode/sensitivity.level/default_autonomy
# silently validated as clean. Must now be rejected.
if [[ -f "$REPO_ROOT/lib/stack-config-validate.sh" ]]; then
  T_R1="$TMP/r1.json"
  jq '.orchestration_mode = "garbage"' "$REPO_ROOT/templates/stack-config.template.json" \
    | jq '.stack_version = "1.3.1" | .stack_tier = 4' > "$T_R1" 2>/dev/null \
    || printf '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","orchestration_mode":"garbage"}' > "$T_R1"
  verr_r1="$(bash -c 'source "'"$REPO_ROOT"'/lib/stack-config-validate.sh"; scv_validate "'"$T_R1"'" "'"$REPO_ROOT"'/schemas/stack-config-schema.json"')"
  rc_r1=$?
  [[ "$rc_r1" != "0" ]] && grep -q "orchestration_mode" <<<"$verr_r1" \
    && pass "R1: bad orchestration_mode is rejected (enum fail-open fixed)" \
    || fail "R1: bad orchestration_mode was NOT rejected (rc=$rc_r1, verr='$verr_r1')"

  T_R1B="$TMP/r1b.json"
  jq '.sensitivity = {"level":"garbage"}' "$REPO_ROOT/templates/stack-config.template.json" \
    | jq '.stack_version = "1.3.1" | .stack_tier = 4' > "$T_R1B" 2>/dev/null
  verr_r1b="$(bash -c 'source "'"$REPO_ROOT"'/lib/stack-config-validate.sh"; scv_validate "'"$T_R1B"'" "'"$REPO_ROOT"'/schemas/stack-config-schema.json"')"
  rc_r1b=$?
  [[ "$rc_r1b" != "0" ]] && pass "R1b: bad sensitivity.level is rejected" \
    || fail "R1b: bad sensitivity.level was NOT rejected"
else
  skip "R1/R1b: lib/stack-config-validate.sh not present"
fi

# R2 — any jq/schema failure must read as INVALID (fail closed), never valid.
if [[ -f "$REPO_ROOT/lib/stack-config-validate.sh" ]]; then
  BAD_SCHEMA="$TMP/r2-bad-schema.json"
  printf 'not json' > "$BAD_SCHEMA"
  GOOD_CFG="$TMP/r2-good.json"
  printf '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01"}' > "$GOOD_CFG"
  verr_r2="$(bash -c 'source "'"$REPO_ROOT"'/lib/stack-config-validate.sh"; scv_validate "'"$GOOD_CFG"'" "'"$BAD_SCHEMA"'"')"
  rc_r2=$?
  [[ "$rc_r2" != "0" && -n "$verr_r2" ]] && pass "R2: a corrupted schema fails CLOSED (invalid), never silently clean" \
    || fail "R2: corrupted schema returned rc=$rc_r2 verr='$verr_r2' (should be non-zero, non-empty)"
else
  skip "R2: lib/stack-config-validate.sh not present"
fi

# R3 — --org-config / --stack-config with a missing trailing value must exit
# 2, never hang. Bounded with a perl alarm (no `timeout` on macOS) — a
# regression here would make this test itself hang, which is the point.
r3_out="$(perl -e 'alarm 8; exec @ARGV' bash "$ORG_CHECK" --org-config 2>&1)"
r3_rc=$?
[[ "$r3_rc" == "2" ]] && pass "R3: --org-config with no value exits 2 (does not hang)" \
  || fail "R3: --org-config with no value exited $r3_rc"
r3b_out="$(perl -e 'alarm 8; exec @ARGV' bash "$ORG_CHECK" --stack-config 2>&1)"
r3b_rc=$?
[[ "$r3b_rc" == "2" ]] && pass "R3b: --stack-config with no value exits 2 (does not hang)" \
  || fail "R3b: --stack-config with no value exited $r3b_rc"

# R4 — a crafted org.json must not defeat the vocabulary gate via
# display_name/support_contact interpolation, in text AND --json.
W="$(mkworld r4)"
write_fake_claude "$W" true
write_fake_curl "$W"
CRAFTED_ORG="$W/crafted-org.json"
jq -n '{version:1, org:{
  id:"carbonet", display_name:"a token leak here",
  access_url:"https://access.carbonet.app",
  support_contact:"API key: sk-ant-secret, exit code 500 via the keychain",
  required_providers:["anthropic"]}}' > "$CRAFTED_ORG"
r4_text="$(run_check "$W" -- --org-config "$CRAFTED_ORG")"
r4_json="$(run_check "$W" -- --org-config "$CRAFTED_ORG" --json)"
assert_vocab_clean "R4: crafted org.json, text mode vocabulary gate" "$r4_text"
assert_no_token_word "R4: crafted org.json, text mode, no literal 'token'" "$r4_text"
assert_vocab_clean "R4: crafted org.json, --json mode vocabulary gate" "$r4_json"
assert_no_token_word "R4: crafted org.json, --json mode, no literal 'token'" "$r4_json"

# --- R5-R6: re-review regression tests (2026-08-11 codex re-verification) --

# R5 — fail-open reintroduced one layer up: if lib/stack-config-validate.sh
# or the schema is unavailable ANYWHERE (installed location AND the repo-
# fallback), Repo must never read "ok". Needs an org-check.sh copy running
# from an isolated location, or resolve_lib's repo-fallback would just find
# the real, committed copies in this checkout and mask the bug.
W="$(mkworld r5)"
write_fake_claude "$W" true
write_fake_curl "$W"
ISOLATED_REPO="$W/isolated-repo"
mkdir -p "$ISOLATED_REPO/scripts"
cp "$ORG_CHECK" "$ISOLATED_REPO/scripts/org-check.sh"
rm -f "$W/home/.claude/lib/stack-config-validate.sh" "$W/home/.claude/schemas/stack-config-schema.json"
r5_json="$(
  unset OPENAI_API_KEY GEMINI_API_KEY
  export HOME="$W/home"
  export PATH="$W/bin:$REALBIN"
  export CURL_CTL_DIR="$W/curl-ctl"
  mkdir -p "$CURL_CTL_DIR"
  cd "$W/proj"
  bash "$ISOLATED_REPO/scripts/org-check.sh" \
    --org-config "$W/home/.claude/config/org.json" \
    --stack-config "$W/proj/.claude/stack-config.json" --json
)"
r5_status="$(jq -r '.checks[] | select(.id=="repo") | .status' <<<"$r5_json")"
r5_reason="$(jq -r '.checks[] | select(.id=="repo") | .reason' <<<"$r5_json")"
[[ "$r5_status" != "ok" ]] && pass "R5: missing validator lib+schema (nowhere to resolve) never reads Repo=ok" \
  || fail "R5: Repo read 'ok' with no validator available anywhere"
[[ "$r5_status" == "warn" && "$r5_reason" == "helper-missing" ]] \
  && pass "R5: reads as warn/helper-missing (can't-verify), not fail (no false alarm either)" \
  || fail "R5: expected warn/helper-missing, got status=$r5_status reason=$r5_reason"

# R6 — sanitizer bypass regression: mixed case, separator-obfuscated words,
# and bare "env" (all live-reproduced bypasses of the prior blacklist
# sanitizer), plus a raw access_url in the invalid-scheme error path.
W="$(mkworld r6)"
write_fake_claude "$W" true
write_fake_curl "$W"
CRAFTED_R6="$W/crafted-r6-org.json"
jq -n '{version:1, org:{
  id:"carbonet", display_name:"TokEn leaked here",
  access_url:"https://access.carbonet.app",
  support_contact:"mIxEd CrEdEnTiAl case, A-P-I key exposed, cre-dential stolen, status 4-0-1 seen, reached via the env",
  required_providers:["anthropic"]}}' > "$CRAFTED_R6"
r6_text="$(run_check "$W" -- --org-config "$CRAFTED_R6")"
r6_json="$(run_check "$W" -- --org-config "$CRAFTED_R6" --json)"
assert_vocab_clean "R6: mixed-case/separator/bare-env bypass, text mode" "$r6_text"
assert_no_token_word "R6: mixed-case/separator/bare-env bypass, text, no 'token'" "$r6_text"
assert_vocab_clean "R6: mixed-case/separator/bare-env bypass, --json mode" "$r6_json"
assert_no_token_word "R6: mixed-case/separator/bare-env bypass, --json, no 'token'" "$r6_json"
if /usr/bin/grep -qi "TokEn\|CrEdEnTiAl\|A-P-I\|cre-dential" <<<"$r6_text$r6_json"; then
  fail "R6: a reproduced bypass string leaked verbatim"
else
  pass "R6: none of the specific reproduced bypass strings leak verbatim"
fi

W="$(mkworld r6b)"
CRAFTED_URL_ORG="$W/crafted-url-org.json"
jq -n '{version:1, org:{id:"carbonet", display_name:"CarboNet",
  access_url:"http://TokEn-leak-test.example",
  support_contact:"ask Bill", required_providers:[]}}' > "$CRAFTED_URL_ORG"
r6b_out="$(run_check "$W" -- --org-config "$CRAFTED_URL_ORG" 2>&1)"
if /usr/bin/grep -qi "TokEn" <<<"$r6b_out"; then
  fail "R6b: access_url leaked raw in the invalid-scheme error message"
else
  pass "R6b: access_url is sanitized in the invalid-scheme error message"
fi

# --- R7-R9: round-3 regression tests (2026-08-11 reviewer re-verification) -

# R7 — sanitizer-before-comparison regression: two DIFFERENT versions that
# both happen to contain a 4xx/5xx-shaped digit run (so they'd sanitize to
# the identical placeholder) must still compare as different and report
# version-behind — never a false ✅. Live-reproduced by the reviewer with
# 4.0.1 vs 4.0.2.
W="$(mkworld r7)"
write_fake_claude "$W" true
write_fake_curl "$W"
jq '.stack_version = "4.0.2"' "$W/home/.claude/.stack-install.json" > "$W/home/.claude/.stack-install.json.tmp" \
  && mv "$W/home/.claude/.stack-install.json.tmp" "$W/home/.claude/.stack-install.json"
jq '.stack_version = "4.0.1"' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
r7_json="$(run_check "$W" -- --json)"
r7_status="$(jq -r '.checks[] | select(.id=="repo") | .status' <<<"$r7_json")"
r7_reason="$(jq -r '.checks[] | select(.id=="repo") | .reason' <<<"$r7_json")"
[[ "$r7_status" == "fail" && "$r7_reason" == "version-behind" ]] \
  && pass "R7: 4.0.1 vs 4.0.2 (both placeholder-colliding after sanitization) still reports version-behind" \
  || fail "R7: got status=$r7_status reason=$r7_reason (compare-after-sanitize regression)"
[[ "$r7_status" != "ok" ]] && pass "R7: never reads ok for genuinely different versions" \
  || fail "R7: read ok for 4.0.1 vs 4.0.2"

# R8 — a validator/provider-key library that exists but fails to load
# part-way (truncated/corrupted, defines none of the functions it should)
# must fail closed, never read as available.
W="$(mkworld r8)"
write_fake_claude "$W" true
write_fake_curl "$W"
cat > "$W/home/.claude/scripts/lib/openai-key.sh" << 'EOF'
#!/usr/bin/env bash
# R8 fixture: deliberately truncated — defines nothing oai_* related.
EOF
r8_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
r8_status="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="openai") | .status' <<<"$r8_json")"
[[ "$r8_status" != "ok" ]] \
  && pass "R8: partially-loaded openai-key.sh (missing oai_export/oai_available) never reads openai=ok" \
  || fail "R8: openai read 'ok' despite a broken/corrupted lib"

# R9 — Unicode homoglyph bypass: a lookalike character (Greek omicron 'ο' in
# place of Latin 'o' inside "token") must not slip past an ASCII-only
# normalizer. The field must be rejected outright (placeholder), not passed
# through unsanitized.
W="$(mkworld r9)"
write_fake_claude "$W" true
write_fake_curl "$W"
CRAFTED_R9="$W/crafted-r9-org.json"
jq -n '{version:1, org:{id:"carbonet", display_name:"CarboNet",
  access_url:"https://access.carbonet.app",
  support_contact:"reached via the tοken leak",
  required_providers:["anthropic"]}}' > "$CRAFTED_R9"
r9_text="$(run_check "$W" -- --org-config "$CRAFTED_R9")"
r9_json="$(run_check "$W" -- --org-config "$CRAFTED_R9" --json)"
if /usr/bin/grep -q "tοken" <<<"$r9_text$r9_json"; then
  fail "R9: Unicode homoglyph ('tοken', Greek omicron) leaked through the sanitizer unsanitized"
else
  pass "R9: Unicode homoglyph field never passes through unsanitized"
fi
if /usr/bin/grep -q "(from your settings)" <<<"$r9_text"; then
  pass "R9: homoglyph field is replaced with the placeholder"
else
  fail "R9: no placeholder shown for the homoglyph field"
fi

# R10 — round-4 reviewer repro, reproduced at the EXACT original site: Check
# 4's scv_validate caller. A validator lib whose `source` itself fails
# (non-zero exit) but which still defines a stub scv_validate (bash keeps
# function definitions that already executed before a later command in the
# same file errors) must never let an invalid config read ✅ — checking
# `declare -f scv_validate` alone is not enough; `source`'s own exit status
# must be checked too.
W="$(mkworld r10)"
write_fake_claude "$W" true
write_fake_curl "$W"
cat > "$W/home/.claude/lib/stack-config-validate.sh" << 'EOF'
#!/usr/bin/env bash
# R10 fixture: a stub that always reports "clean", followed by a command
# that fails — `source` returns non-zero even though scv_validate is defined.
scv_validate() { printf ''; return 0; }
false
EOF
jq '.orchestration_mode = "garbage"' "$W/proj/.claude/stack-config.json" > "$W/proj/.claude/stack-config.json.tmp" \
  && mv "$W/proj/.claude/stack-config.json.tmp" "$W/proj/.claude/stack-config.json"
r10_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test -- --json)"
r10_status="$(jq -r '.checks[] | select(.id=="repo") | .status' <<<"$r10_json")"
[[ "$r10_status" != "ok" ]] \
  && pass "R10: stub scv_validate + failed source (original repro site) never reads Repo=ok" \
  || fail "R10: Repo read 'ok' despite a failed source with a stub scv_validate"

# --- SP1/SP2 (rev-2 §3): unstamped-profile renders loud, as its own
# `stack-profile` item -- never a second `stack` item. Task 8.
W="$(mkworld sp1)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access 200
sp_json="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="unstamped-profile ~/.claude-team" -- --json)"
sp_status="$(jq -r '.checks[] | select(.id=="stack-profile") | .status' <<<"$sp_json")"
sp_reason="$(jq -r '.checks[] | select(.id=="stack-profile") | .reason' <<<"$sp_json")"
sp_dir="$(jq -r '.checks[] | select(.id=="stack-profile") | .detail.dir' <<<"$sp_json")"
[[ "$sp_status" == "warn" ]] && pass "SP1: stack-profile item status is warn" || fail "SP1: got status=$sp_status"
[[ "$sp_reason" == "unstamped-profile" ]] && pass "SP1: stack-profile reason is unstamped-profile" || fail "SP1: got reason=$sp_reason"
[[ "$sp_dir" == "~/.claude-team" ]] && pass "SP1: stack-profile detail.dir is ~/.claude-team" || fail "SP1: got dir=$sp_dir"

stack_status="$(jq -r '.checks[] | select(.id=="stack") | .status' <<<"$sp_json")"
stack_reason="$(jq -r '.checks[] | select(.id=="stack") | .reason' <<<"$sp_json")"
[[ "$stack_status" == "warn" && "$stack_reason" == "unstamped" ]] \
  && pass "SP1: the generic Stack check is unchanged (warn/unstamped), not replaced" \
  || fail "SP1: Stack check changed unexpectedly (status=$stack_status reason=$stack_reason)"

stack_count="$(jq '[.checks[] | select(.id=="stack")] | length' <<<"$sp_json")"
[[ "$stack_count" == "1" ]] && pass "SP1: exactly one 'stack' item (never a second one)" \
  || fail "SP1: found $stack_count 'stack' items"

n_keys_items="$(jq '.checks[] | select(.id=="keys") | .items | length' <<<"$sp_json")"
[[ "$n_keys_items" == "3" ]] \
  && pass "SP1: keys check still has exactly 3 provider items (anthropic/openai/gemini) -- gemini selector at :257/:267 unaffected" \
  || fail "SP1: keys items count changed to $n_keys_items"
gemini_reason_after="$(jq -r '.checks[] | select(.id=="keys") | .items[] | select(.provider=="gemini") | .reason' <<<"$sp_json")"
[[ "$gemini_reason_after" == "null" || -z "$gemini_reason_after" ]] \
  && pass "SP1: gemini item reason unaffected (ok, no reason)" \
  || fail "SP1: gemini item reason unexpectedly '$gemini_reason_after'"

# --- SP2: plain-English text rendering + fix line + verdict count -------
sp_text="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="unstamped-profile ~/.claude-team" -- )"
grep -q "This machine's ~/.claude-team profile is empty — Claude tools won't load from repos that use it" <<<"$sp_text" \
  && pass "SP2: plain-English Stack row for the empty profile" \
  || fail "SP2: profile row text missing or wrong: $(grep 'profile is empty' <<<"$sp_text")"
grep -q "install.sh --migrate-profile=team" <<<"$sp_text" \
  && pass "SP2: fix line names install.sh --migrate-profile=team" \
  || fail "SP2: fix line missing/wrong: $(grep 'migrate-profile' <<<"$sp_text")"
grep -q "(secondary)" <<<"$sp_text" \
  && fail "SP2: profile line marked (secondary) with no rehome detector present" \
  || pass "SP2: profile line not marked secondary (no rehome detector on this fixture)"
assert_vocab_clean "SP2: vocabulary gate clean on the stack-profile row" "$sp_text"
assert_no_token_word "SP2: no 'token' word in the stack-profile row" "$sp_text"

# --- SP3: rehome (ADR-067) wins ordering when its detector is present ----
# lib/rehome-check.sh may not exist yet in a real install; this fixture
# simulates it existing and firing (exit 10) to prove org-check.sh's
# ordering/marking logic without depending on the real tool being built.
W="$(mkworld sp3)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access 200
cat > "$W/home/.claude/lib/rehome-check.sh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "home path moved (~/old -> ~/new) — run /rehome to repair your other repos"
exit 10
EOF
chmod +x "$W/home/.claude/lib/rehome-check.sh"
sp3_text="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="unstamped-profile ~/.claude-team" -- )"
rehome_lineno="$(grep -n "run /rehome" <<<"$sp3_text" | head -1 | cut -d: -f1)"
profile_lineno="$(grep -n "profile is empty" <<<"$sp3_text" | head -1 | cut -d: -f1)"
if [[ -n "$rehome_lineno" && -n "$profile_lineno" && "$rehome_lineno" -lt "$profile_lineno" ]]; then
  pass "SP3: rehome line prints before the stack-profile line"
else
  fail "SP3: ordering wrong (rehome@${rehome_lineno:-none} profile@${profile_lineno:-none})"
fi
grep -q "(secondary)" <<<"$sp3_text" \
  && pass "SP3: profile line marked (secondary) when rehome wins ordering" \
  || fail "SP3: profile line not marked secondary despite a firing rehome detector"

# --- SP4: absence tolerance -- rehome-check.sh missing entirely (the normal
# case today, since it is not built yet) must never error or print anything
# rehome-shaped. Covered implicitly by SP1/SP2 (no lib/rehome-check.sh in
# that fixture) but asserted explicitly here for the "tolerate absence"
# interface contract.
W="$(mkworld sp4)"
write_fake_claude "$W" true
write_fake_curl "$W"
set_curl "$W" openai_models 200
set_curl "$W" gemini_models 200
set_curl "$W" access 200
sp4_out="$(run_check "$W" OPENAI_API_KEY=sk-test GEMINI_API_KEY=sk-test STUB_FRESHNESS_TOKEN="unstamped-profile ~/.claude-team" -- )"
sp4_rc=$?
if grep -q "run /rehome" <<<"$sp4_out"; then
  fail "SP4: a rehome line appeared with no lib/rehome-check.sh present"
else
  pass "SP4: no rehome line when the detector lib is absent"
fi
[[ "$sp4_rc" == "20" ]] && pass "SP4: exit 20 (ALMOST READY, no crash on absent rehome helper)" \
  || fail "SP4: exit was $sp4_rc"

echo
echo "carbonet: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
