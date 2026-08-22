#!/usr/bin/env bash
# ADR-086 R3 — the consent path end to end: hooks/stack-update-apply.sh's
# consent lifecycle (T45-T49) and skills/stack-update/SKILL.md hygiene (T60).
#
# Kept separate from tests/test-stack-self-update-hook.sh (ADR-086's
# "Changes, per file" table): this suite's fixture is a UserPromptSubmit
# payload, not a SessionStart one. House style matches that file: pass/fail
# counters, fixture HOME, a temp git repo as the fake source repo, a fake
# scripts/update.sh in that repo recording its argv/env, a git shim on PATH
# that records every subcommand, no network, no real installs. Fixture
# helpers below are deliberately duplicated from that file rather than
# extracted into a shared lib -- the same house-style call the applier hook
# itself makes in its own header comment.
#
# T57 (no network at apply) and T61 (applier fast path) are already covered
# in tests/test-stack-self-update-hook.sh (R1/R2) and are not repeated here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGER="$REPO_ROOT/hooks/stack-self-update.sh"
APPLIER="$REPO_ROOT/hooks/stack-update-apply.sh"
SKILL="$REPO_ROOT/skills/stack-update/SKILL.md"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }

ORIG_HOME="$HOME"
HAD_CCD=0
if [[ -n "${CLAUDE_CONFIG_DIR+x}" ]]; then HAD_CCD=1; ORIG_CCD="$CLAUDE_CONFIG_DIR"; fi

ALL_TMP_DIRS=()
cleanup_all() {
  for d in "${ALL_TMP_DIRS[@]:-}"; do rm -rf "$d" 2>/dev/null; done
  export HOME="$ORIG_HOME"
  if [[ "$HAD_CCD" -eq 1 ]]; then export CLAUDE_CONFIG_DIR="$ORIG_CCD"; else unset CLAUDE_CONFIG_DIR; fi
}
trap cleanup_all EXIT

canon() { ( cd "$1" 2>/dev/null && pwd -P ); }
iso_ago() {  # iso_ago <seconds>
  local s="$1"
  date -u -v-"${s}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-$s seconds" +%Y-%m-%dT%H:%M:%SZ
}

run_stager() {  # run_stager <payload-json> [env assignments...]
  local payload="$1"; shift
  printf '%s' "$payload" | env "$@" bash "$STAGER" >/dev/null 2>&1
}
run_applier() {  # run_applier <session_id> [env assignments...]
  local sid="$1"; shift
  APPLIER_OUT="$(printf '{"session_id":"%s"}' "$sid" | env "$@" bash "$APPLIER" 2>/dev/null)"
  APPLIER_RC=$?
}

receipt_field() { jq -r "$1" "$CONF_DIR/state/stack-update/receipt.json" 2>/dev/null; }

wait_for_status() {  # wait_for_status <status> [timeout-s]
  local want="$1" timeout="${2:-15}" waited=0
  while (( waited < timeout )); do
    [[ "$(receipt_field '.status')" == "$want" ]] && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

# ─────────────────────────────────────────────────────────────────────────
# Fixture: fresh fixture HOME, bare "origin" remote, a working clone as the
# fake source repo (with a fake scripts/update.sh), and a matching stamp+pin.
# Byte-identical to tests/test-stack-self-update-hook.sh's setup_fixture.
# ─────────────────────────────────────────────────────────────────────────
setup_fixture() {
  FIXTURE_HOME="$(mktemp -d)"
  ALL_TMP_DIRS+=("$FIXTURE_HOME")
  export HOME="$FIXTURE_HOME"
  unset CLAUDE_CONFIG_DIR
  CONF_DIR="$HOME/.claude"
  mkdir -p "$CONF_DIR/hooks" "$CONF_DIR/state" "$CONF_DIR/lib"
  cp "$REPO_ROOT/lib/profile-resolver.sh" "$CONF_DIR/lib/"
  cp "$REPO_ROOT/lib/stack-freshness.sh" "$CONF_DIR/lib/"

  local remote_parent; remote_parent="$(mktemp -d)"; ALL_TMP_DIRS+=("$remote_parent")
  REMOTE_DIR="$(canon "$remote_parent")/origin.git"
  git init --quiet --bare -b main "$REMOTE_DIR" >/dev/null 2>&1

  local src_parent; src_parent="$(mktemp -d)"; ALL_TMP_DIRS+=("$src_parent")
  git clone --quiet "$REMOTE_DIR" "$src_parent/src" >/dev/null 2>&1
  SOURCE_REPO="$(canon "$src_parent/src")"
  git -C "$SOURCE_REPO" config user.email "test@example.com"
  git -C "$SOURCE_REPO" config user.name "Test"
  git -C "$SOURCE_REPO" checkout -q -B main 2>/dev/null || true

  mkdir -p "$SOURCE_REPO/scripts"
  cat > "$SOURCE_REPO/scripts/update.sh" <<'FAKEEOF'
#!/usr/bin/env bash
OUT="${STACK_UPDATE_FAKE_RECORD:-/dev/null}"
{
  echo "ARGV: $*"
  echo "STACK_INSESSION=${STACK_INSESSION:-}"
  echo "STACK_UPDATE_MODE=${STACK_UPDATE_MODE:-}"
  echo "STACK_UPDATE_VIA_HOOK=${STACK_UPDATE_VIA_HOOK:-}"
  echo "STACK_UPDATE_NO_PULL=${STACK_UPDATE_NO_PULL:-}"
} >> "$OUT" 2>/dev/null
exit "${STACK_UPDATE_FAKE_RC:-0}"
FAKEEOF
  chmod +x "$SOURCE_REPO/scripts/update.sh"
  echo "seed" > "$SOURCE_REPO/README.md"
  git -C "$SOURCE_REPO" add -A >/dev/null 2>&1
  git -C "$SOURCE_REPO" commit --quiet -m "seed" >/dev/null 2>&1
  git -C "$SOURCE_REPO" push --quiet -u origin main >/dev/null 2>&1

  HEAD_SHA="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
  ACTUAL_REMOTE="$(git -C "$SOURCE_REPO" remote get-url origin)"

  FAKE_RECORD="$FIXTURE_HOME/fake-update-record.log"
  export STACK_UPDATE_FAKE_RECORD="$FAKE_RECORD"

  cat > "$CONF_DIR/.stack-install.json" <<EOF
{"stack_version":"test","tier":1,"source_sha":"$HEAD_SHA","source_branch":"main","source_repo":"$SOURCE_REPO","installed_at":"2020-01-01T00:00:00Z"}
EOF
  cat > "$CONF_DIR/hooks/stack-update.pin.json" <<EOF
{"schema":"stack-update-pin/v2","source_repo":"$SOURCE_REPO","remote_url":"$ACTUAL_REMOTE","tier":1}
EOF
}

# advance_remote <n> [prefix] — a "second developer" pushes n commits, so the
# fixture's own SOURCE_REPO working clone becomes behind without ever
# touching it directly.
advance_remote() {
  local n="$1" prefix="${2:-commit}"
  local other; other="$(mktemp -d)"
  git clone --quiet "$REMOTE_DIR" "$other" >/dev/null 2>&1
  git -C "$other" config user.email "t2@example.com"
  git -C "$other" config user.name "T2"
  local i
  for (( i=1; i<=n; i++ )); do
    echo "line $i $RANDOM $$" >> "$other/README.md"
    git -C "$other" commit --quiet -am "$prefix $i" >/dev/null 2>&1
  done
  git -C "$other" push --quiet origin main >/dev/null 2>&1
  rm -rf "$other"
}

write_consent() {  # write_consent <staged_sha> <session_id> [granted_at_iso] [door]
  mkdir -p "$CONF_DIR/state/stack-consent"
  local granted="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local door="${4:-goodmorning}"
  jq -n --arg s "$1" --arg sid "$2" --arg g "$granted" --arg d "$door" \
    '{schema:"stack-update-consent/v1", staged_sha:$s, granted_at:$g, session_id:$sid, door:$d}' \
    > "$CONF_DIR/state/stack-consent/stack-update.json"
}

PAYLOAD_STARTUP='{"hook_event_name":"SessionStart","source":"startup","session_id":"sess-1"}'

# stage_one_commit — setup_fixture + advance_remote 1 + run_stager, leaving
# a `staged` receipt with a real 40-hex staged_sha. Every T45-T49 case starts
# from this.
stage_one_commit() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
}

# ═══════════════════════════════════════════════════════════════════════════
# T45-T49 — consent lifecycle (ADR-086 D15)
# ═══════════════════════════════════════════════════════════════════════════

t45() {
  stage_one_commit
  local ssha scount; ssha="$(receipt_field '.staged_sha')"; scount="$(receipt_field '.staged_count')"
  write_consent "$ssha" "sess-45"
  run_applier "sess-45" STACK_UPDATE_APPLY_BUDGET_S=20
  wait_for_status updated 20 || true

  local consent_gone=0 used_present=0
  [[ ! -f "$CONF_DIR/state/stack-consent/stack-update.json" ]] && consent_gone=1
  [[ -f "$CONF_DIR/state/stack-consent/stack-update.json.used" ]] && used_present=1

  local status to_sha; status="$(receipt_field '.status')"; to_sha="$(receipt_field '.to_sha')"

  local applies_count=0
  applies_count="$(grep -c '^ARGV:' "$FAKE_RECORD" 2>/dev/null || echo 0)"

  local expected_line; expected_line="$(printf '[stack-update] applied — now at %s (%s changes).' "${ssha:0:7}" "$scount")"

  [[ "$consent_gone" == "1" && "$used_present" == "1" && "$status" == "updated" \
     && "$to_sha" == "$ssha" && "$applies_count" == "1" \
     && "$APPLIER_OUT" == "$expected_line" ]] \
    && pass "T45: valid consent -- apply runs exactly once, consent renamed .used, receipt updated, exact one-line output" \
    || fail "T45: consent_gone=$consent_gone used_present=$used_present status=$status to_sha=$to_sha(want $ssha) applies=$applies_count out='$APPLIER_OUT' want='$expected_line'"
}

t46() {
  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-46" "$(iso_ago 1200)"
  run_applier "sess-46" STACK_UPDATE_APPLY_BUDGET_S=20

  local status reason; status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  local consent_gone=0 used_present=0
  [[ ! -f "$CONF_DIR/state/stack-consent/stack-update.json" ]] && consent_gone=1
  [[ -f "$CONF_DIR/state/stack-consent/stack-update.json.used" ]] && used_present=1
  local applied=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied=1

  [[ "$status" == "blocked" && "$reason" == "consent-expired" \
     && "$consent_gone" == "1" && "$used_present" == "1" && "$applied" == "0" \
     && "$APPLIER_OUT" == "[stack-update] not applied — consent expired." ]] \
    && pass "T46: granted_at 20 minutes old -- blocked/consent-expired, nothing applied, consent still consumed" \
    || fail "T46: status=$status reason=$reason consent_gone=$consent_gone used_present=$used_present applied=$applied out='$APPLIER_OUT'"
}

t47() {
  # (a) consent staged_sha != receipt's staged_sha
  stage_one_commit
  local real_ssha; real_ssha="$(receipt_field '.staged_sha')"
  local wrong_ssha="0000000000000000000000000000000000dead"
  write_consent "$wrong_ssha" "sess-47a"
  run_applier "sess-47a" STACK_UPDATE_APPLY_BUDGET_S=20
  local status1 reason1 applied1; status1="$(receipt_field '.status')"; reason1="$(receipt_field '.reason')"
  applied1=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied1=1
  local ok1=0
  [[ "$status1" == "blocked" && "$reason1" == "consent-stale" && "$applied1" == "0" ]] && ok1=1

  # (b) receipt status is not "staged" (nothing behind -> current)
  setup_fixture
  run_stager "$PAYLOAD_STARTUP"
  local cur_status; cur_status="$(receipt_field '.status')"
  local fake_ssha="1111111111111111111111111111111111beef"
  write_consent "$fake_ssha" "sess-47b"
  run_applier "sess-47b" STACK_UPDATE_APPLY_BUDGET_S=20
  local status2 reason2 applied2; status2="$(receipt_field '.status')"; reason2="$(receipt_field '.reason')"
  applied2=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied2=1
  local ok2=0
  [[ "$cur_status" == "current" && "$status2" == "blocked" && "$reason2" == "consent-stale" && "$applied2" == "0" ]] && ok2=1

  (( ok1 == 1 && ok2 == 1 )) \
    && pass "T47: consent staged_sha mismatch, and receipt status != staged -> blocked/consent-stale in both, nothing applied" \
    || fail "T47: (a) status=$status1 reason=$reason1 applied=$applied1; (b) receipt_status=$cur_status status=$status2 reason=$reason2 applied=$applied2"
}

t48() {
  local git_shim_dir; git_shim_dir="$(mktemp -d)"; ALL_TMP_DIRS+=("$git_shim_dir")
  local call_log="$git_shim_dir/git-calls.log"
  cat > "$git_shim_dir/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$git_shim_dir/git"

  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"

  # "Forged" consent: written by an unprivileged fixture process (a plain
  # subshell with no relation to the hook or the model) naming the correct
  # staged SHA. The applier cannot and must not distinguish this from a
  # legitimate write -- that is the whole point of D15's harmless-by-
  # construction claim.
  ( write_consent "$ssha" "sess-48" )

  : > "$call_log"
  PATH="$git_shim_dir:$PATH" run_applier "sess-48" STACK_UPDATE_APPLY_BUDGET_S=20
  wait_for_status updated 20 || true

  local net_calls
  net_calls="$(grep -Ec '(^| )(fetch|pull|clone)( |$)' "$call_log" 2>/dev/null)"
  [[ "$net_calls" =~ ^[0-9]+$ ]] || net_calls=0

  local status to_sha; status="$(receipt_field '.status')"; to_sha="$(receipt_field '.to_sha')"

  [[ "$net_calls" -eq 0 && "$status" == "updated" && "$to_sha" == "$ssha" ]] \
    && pass "T48: forged consent naming the correct staged SHA -- applies exactly that SHA, zero fetch/pull/clone calls" \
    || fail "T48: net_calls=$net_calls status=$status to_sha=$to_sha(want $ssha); calls: $(cat "$call_log" 2>/dev/null)"
}

t49() {
  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-granted-by"
  run_applier "sess-49-actual" STACK_UPDATE_APPLY_BUDGET_S=20

  local status reason applied
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  applied=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied=1

  [[ "$status" == "blocked" && "$reason" == "consent-stale" && "$applied" == "0" ]] \
    && pass "T49: consent session_id differs from the payload's -- blocked/consent-stale, nothing applied" \
    || fail "T49: status=$status reason=$reason applied=$applied"
}

# ═══════════════════════════════════════════════════════════════════════════
# T65-T67 — cross-family code review fixes (2026-08-19): finding #5 (consent
# TTL must reject a future granted_at, not just an old one), finding #6
# (session binding must refuse when either session id is empty), finding #10
# (install.sh's hook-mode pack/purge deferral markers must reach the FINAL
# receipt after a successful apply).
# ═══════════════════════════════════════════════════════════════════════════

t65() {
  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"
  # A forged consent with a far-future granted_at: under the old
  # `NOW - GRANTED <= 900` check, a negative delta always satisfied the
  # comparison, so a future timestamp never expired.
  local future
  future="$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  write_consent "$ssha" "sess-65" "$future"
  run_applier "sess-65" STACK_UPDATE_APPLY_BUDGET_S=20

  local status reason applied
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  applied=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied=1

  [[ "$status" == "blocked" && "$reason" == "consent-expired" && "$applied" == "0" ]] \
    && pass "T65: granted_at 2 hours in the future -- blocked/consent-expired (not accepted indefinitely), nothing applied" \
    || fail "T65: status=$status reason=$reason applied=$applied"
}

t66() {
  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" ""
  run_applier "" STACK_UPDATE_APPLY_BUDGET_S=20

  local status reason applied
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  applied=0; [[ -s "${FAKE_RECORD:-/dev/null}" ]] && applied=1

  [[ "$status" == "blocked" && "$reason" == "consent-stale" && "$applied" == "0" ]] \
    && pass "T66: empty session_id on both sides of the comparison -- blocked/consent-stale, nothing applied (an empty string must never read as 'bound')" \
    || fail "T66: status=$status reason=$reason applied=$applied"
}

t67() {
  stage_one_commit
  local ssha; ssha="$(receipt_field '.staged_sha')"
  # Simulate what install.sh (STACK_UPDATE_MODE=hook, ADR-086 D11) and
  # gen-alias-stubs.sh leave on disk when they defer a confirmation-class
  # pack change / alias purge -- this fixture's fake update.sh does not
  # shell out to the real installer, so plant the exact marker files the
  # real one would leave, and confirm the applier worker threads them into
  # the FINAL receipt after a successful apply.
  mkdir -p "$CONF_DIR/state"
  jq -n '{pack_pending:true, source:"test", ref:"test", deferred_at:"2020-01-01T00:00:00Z"}' \
    > "$CONF_DIR/state/pack-pending.json"
  jq -n '{pending_purge:["old-word-one","old-word-two"]}' \
    > "$CONF_DIR/state/alias-pending-purge.json"
  write_consent "$ssha" "sess-67a"
  run_applier "sess-67a" STACK_UPDATE_APPLY_BUDGET_S=20
  wait_for_status updated 20 || true
  local pp1 pu1
  pp1="$(receipt_field '.pack_pending')"
  pu1="$(receipt_field '.purges_pending')"
  local ok1=0
  [[ "$pp1" == "true" && "$pu1" == "2" ]] && ok1=1

  # Second cycle, same fixture, markers now cleared -- pack_pending/
  # purges_pending must be RECOMPUTED fresh from what's on disk, not carried
  # forward from the true/2 this run just wrote. (The actual bug:
  # init_receipt_defaults' carry-forward default never re-read these files
  # at all, so a stale value -- or a stale absence -- just repeated forever.)
  rm -f "$CONF_DIR/state/pack-pending.json" "$CONF_DIR/state/alias-pending-purge.json"
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_COOLDOWN_S=0
  local ssha2; ssha2="$(receipt_field '.staged_sha')"
  write_consent "$ssha2" "sess-67b"
  run_applier "sess-67b" STACK_UPDATE_APPLY_BUDGET_S=20
  wait_for_status updated 20 || true
  local pp2 pu2
  pp2="$(receipt_field '.pack_pending')"
  pu2="$(receipt_field '.purges_pending')"
  local ok2=0
  [[ "$pp2" == "false" && "$pu2" == "0" ]] && ok2=1

  (( ok1 == 1 && ok2 == 1 )) \
    && pass "T67: install.sh's hook-mode pack-pending/alias-purge markers reach the FINAL receipt after a successful apply (finding #10), and clear again once the markers are gone -- never carried forward" \
    || fail "T67: markers-present pack_pending=$pp1 purges_pending=$pu1; markers-cleared pack_pending=$pp2 purges_pending=$pu2"
}

# ═══════════════════════════════════════════════════════════════════════════
# T60 — skills/stack-update/SKILL.md hygiene
# ═══════════════════════════════════════════════════════════════════════════

t60() {
  local ok=1
  if [[ ! -f "$SKILL" ]]; then
    fail "T60: skills/stack-update/SKILL.md is missing"
    return
  fi
  head -1 "$SKILL" | grep -q '^---$' || { ok=0; echo "  (T60: frontmatter does not open with ---)"; }
  grep -q '^name: stack-update$' "$SKILL" || { ok=0; echo "  (T60: name: stack-update missing)"; }
  grep -q '^description:' "$SKILL" || { ok=0; echo "  (T60: description missing)"; }
  grep -q '^user-invocable: true$' "$SKILL" || { ok=0; echo "  (T60: user-invocable: true missing)"; }
  grep -q '^model-invocable: false$' "$SKILL" || { ok=0; echo "  (T60: model-invocable: false missing)"; }

  # No fenced code block instructs the model to run update.sh, install.sh,
  # git fetch, or stack-freshness.sh -- those may only appear in prose (the
  # prohibition, and D14's terminal-remedy sentence naming update.sh as
  # something a HUMAN runs from a terminal, mirroring T20's precedent for
  # skills/goodmorning/SKILL.md).
  local fenced
  fenced="$(awk '/^```/{f=!f; next} f' "$SKILL" 2>/dev/null)"
  local pat
  for pat in 'update\.sh' 'install\.sh' 'git[[:space:]]+fetch' 'stack-freshness\.sh'; do
    if printf '%s\n' "$fenced" | grep -Eq "$pat"; then
      ok=0; echo "  (T60: a fenced code block mentions '$pat')"
    fi
  done

  (( ok == 1 )) \
    && pass "T60: skills/stack-update/SKILL.md exists, has expected frontmatter, no fenced instruction to run update.sh/install.sh/git-fetch/stack-freshness.sh" \
    || fail "T60: see notes above"
}

# ═══════════════════════════════════════════════════════════════════════════

for t in t45 t46 t47 t48 t49 t60 t65 t66 t67; do
  "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
