#!/usr/bin/env bash
# ADR-086 R1 — hooks/stack-self-update.sh (SessionStart stager) and
# hooks/stack-update-apply.sh (UserPromptSubmit applier). House style: pass/
# fail counters, fixture HOME, a temp git repo as the fake source repo, a
# fake scripts/update.sh in that repo recording its argv/env, no network, no
# real installs.
#
# Test IDs below cite the ADR's R1 row: T01-T19, T24-T26, T28-T38, T42-T44,
# T50-T53, T55-T59, T61, T63. Consent-lifecycle tests (T45-T49, T60) and
# goodmorning/org-check tests (T20-T23, T40, T54, T62) are out of R1 scope
# per the implementer's handoff and are not present here.
#
# R2 adds T27 (scripts/update.sh's D7 advisory guard) and completes the
# real-scripts/update.sh half of T57 (R1 only exercised the fixture's fake
# update.sh; update.sh itself wasn't touched until R2).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGER="$REPO_ROOT/hooks/stack-self-update.sh"
APPLIER="$REPO_ROOT/hooks/stack-update-apply.sh"
SCHEMA_RECEIPT="$REPO_ROOT/schemas/stack-update-receipt.json"

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

STDOUT_LEAK=0
run_stager() {  # run_stager <payload-json> [env assignments...]
  local payload="$1"; shift
  local out
  out="$(printf '%s' "$payload" | env "$@" bash "$STAGER" 2>/tmp/.stager-stderr.$$)"
  RUN_RC=$?
  RUN_STDERR="$(cat "/tmp/.stager-stderr.$$" 2>/dev/null)"
  rm -f "/tmp/.stager-stderr.$$" 2>/dev/null
  if [[ -n "$out" ]]; then STDOUT_LEAK=$((STDOUT_LEAK+1)); fi
  STDOUT_CAPTURE="$out"
}
run_applier() {  # run_applier <session_id> [env assignments...]
  local sid="$1"; shift
  APPLIER_OUT="$(printf '{"session_id":"%s"}' "$sid" | env "$@" bash "$APPLIER" 2>/dev/null)"
  APPLIER_RC=$?
}

receipt_field() { jq -r "$1" "$CONF_DIR/state/stack-update/receipt.json" 2>/dev/null; }
receipt_raw() { cat "$CONF_DIR/state/stack-update/receipt.json" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────
# Fixture: fresh fixture HOME, bare "origin" remote, a working clone as the
# fake source repo (with a fake scripts/update.sh), and a matching stamp+pin.
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
SLEEP="${STACK_UPDATE_FAKE_SLEEP:-0}"
[[ "$SLEEP" != "0" ]] && sleep "$SLEEP"
if [[ -n "${STACK_UPDATE_FAKE_STDERR:-}" ]]; then
  printf '%s\n' "${STACK_UPDATE_FAKE_STDERR}"
fi
if [[ -n "${STACK_UPDATE_FAKE_SIGNAL:-}" ]]; then
  kill -"${STACK_UPDATE_FAKE_SIGNAL}" $$
  sleep 5
fi
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

# ─────────────────────────────────────────────────────────────────────────
# schemas/stack-update-receipt.json — minimal structural validator (no
# jsonschema/ajv dependency ships in this repo; Karpathy rule 8).
# ─────────────────────────────────────────────────────────────────────────
receipt_validates_against_schema() {
  local receipt_json="$1"
  python3 - "$SCHEMA_RECEIPT" <<PYEOF
import json, sys
schema = json.load(open(sys.argv[1]))
try:
    data = json.loads('''$receipt_json''')
except Exception as e:
    sys.exit(1)
errors = []
for req in schema.get("required", []):
    if req not in data:
        errors.append(f"missing {req}")
props = schema.get("properties", {})
for k, v in data.items():
    if k not in props:
        errors.append(f"unknown field {k}")
        continue
    p = props[k]
    enum = p.get("enum")
    if enum is not None and v not in enum:
        errors.append(f"{k}={v!r} not in enum")
STATUS_ENUM = set(schema["properties"]["status"]["enum"])
REASON_ENUM = set(x for x in schema["properties"]["reason"]["enum"] if x is not None)
if data.get("status") not in STATUS_ENUM:
    errors.append("status outside closed enum")
if data.get("reason") is not None and data.get("reason") not in REASON_ENUM:
    errors.append("reason outside closed enum")
sys.exit(1 if errors else 0)
PYEOF
}

# ═══════════════════════════════════════════════════════════════════════════
# T01-T19 — hooks/stack-self-update.sh core behaviour
# ═══════════════════════════════════════════════════════════════════════════

t01() {
  if [[ -x "$STAGER" ]] && grep -q '^# summary:' "$STAGER"; then
    setup_fixture
    printf '' | bash "$STAGER"
    local rc=$?
    [[ "$rc" -eq 0 ]] && pass "T01: hook executable, has summary line, exits 0 on empty stdin" \
      || fail "T01: exit rc=$rc on empty stdin"
  else
    fail "T01: not executable or missing # summary: line"
  fi
}

t02() {
  (( STDOUT_LEAK == 0 )) && pass "T02: stager stdout empty in every case exercised in this suite" \
    || fail "T02: $STDOUT_LEAK stager invocation(s) produced stdout (D1 silence rule)"
}

t03() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local status; status="$(receipt_field '.status')"
  local record; record="$(cat "$FAKE_RECORD" 2>/dev/null)"
  [[ "$status" == "staged" && -z "$record" ]] \
    && pass "T03: behind+clean -> stages; fake updater NOT invoked (rev 3)" \
    || fail "T03: status=$status record='$record'"
}

t04() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local before; before="$(receipt_raw)"
  local ok=1 src
  for src in resume compact clear; do
    run_stager "{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\",\"session_id\":\"s\"}"
    local after; after="$(receipt_raw)"
    [[ "$after" == "$before" ]] || { ok=0; echo "  (T04: source=$src mutated the receipt)"; }
  done
  run_stager '{}'
  local after2; after2="$(receipt_raw)"
  [[ "$after2" == "$before" ]] || { ok=0; echo "  (T04: missing hook_event_name mutated the receipt)"; }
  (( ok == 1 )) && pass "T04: resume/compact/clear/missing hook_event_name -> receipt byte-identical" \
    || fail "T04: at least one non-startup source mutated the receipt"
}

t05() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local r="$CONF_DIR/state/stack-update/receipt.json"
  jq --arg t "$(iso_ago 60)" '.as_of=$t' "$r" > "$r.tmp2" && mv "$r.tmp2" "$r"
  local before; before="$(cat "$r")"
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local after; after="$(cat "$r")"
  [[ "$after" == "$before" ]] && pass "T05: as_of 60s old -> within cooldown, receipt unchanged" \
    || fail "T05: receipt changed within the 600s cooldown"
}

t06() {
  setup_fixture
  run_stager "$PAYLOAD_STARTUP"
  local st0; st0="$(receipt_field '.status')"
  if [[ "$st0" != "current" ]]; then fail "T06: fixture setup expected current, got $st0"; return; fi
  local r="$CONF_DIR/state/stack-update/receipt.json"
  jq --arg t "$(iso_ago 1200)" '.as_of=$t' "$r" > "$r.tmp2" && mv "$r.tmp2" "$r"
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local status; status="$(receipt_field '.status')"
  [[ "$status" == "staged" ]] && pass "T06: as_of 20min old -> past cooldown, probes normally" \
    || fail "T06: status=$status"
}

t07() {
  setup_fixture
  run_stager "$PAYLOAD_STARTUP"
  local status ssha
  status="$(receipt_field '.status')"; ssha="$(receipt_field '.staged_sha')"
  [[ "$status" == "current" && ( "$ssha" == "null" || -z "$ssha" ) ]] \
    && pass "T07: freshness current -> status:current, no staging fetch" \
    || fail "T07: status=$status staged_sha=$ssha"
}

t08() {
  setup_fixture
  advance_remote 1
  echo "dirty" >> "$SOURCE_REPO/README.md"
  run_stager "$PAYLOAD_STARTUP"
  local status reason nh
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"; nh="$(receipt_field '.needs_human')"
  [[ "$status" == "blocked" && "$reason" == "dirty" && "$nh" == "true" ]] \
    && pass "T08: dirty source repo -> blocked/dirty, needs_human:true" \
    || fail "T08: status=$status reason=$reason needs_human=$nh"
}

t08b() {
  # An UNTRACKED file must not block. Counting untracked files froze
  # auto-update permanently on any machine carrying a stray generated file —
  # silently, because this hook reports only through a receipt row. Reported
  # 2026-08-21 after two generated files cost weeks of missed updates.
  setup_fixture
  advance_remote 1
  echo "generated junk" > "$SOURCE_REPO/some-generated-file.tmp"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" != "blocked" || "$reason" != "dirty" ]] \
    && pass "T08b: an untracked file does NOT block the update" \
    || fail "T08b: untracked file still blocks (status=$status reason=$reason)"
}

t08c() {
  # The other half: a real edit to a TRACKED stack file must still block.
  # Narrowing the check must not disarm it.
  setup_fixture
  advance_remote 1
  echo "a real local edit" >> "$SOURCE_REPO/README.md"
  echo "generated junk" > "$SOURCE_REPO/another-generated-file.tmp"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "blocked" && "$reason" == "dirty" ]] \
    && pass "T08c: a tracked edit still blocks, even beside untracked files" \
    || fail "T08c: tracked edit no longer blocks (status=$status reason=$reason)"
}

t08d() {
  # A clean tree does not mean the repository is idle. An unfinished merge
  # leaves the index clean once paths resolve, but git then refuses the
  # fast-forward every boot, forever — reported only as a receipt row.
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" rev-parse HEAD \
    > "$(git -C "$SOURCE_REPO" rev-parse --absolute-git-dir)/MERGE_HEAD"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "blocked" && "$reason" == "operation-in-progress" ]] \
    && pass "T08d: an unfinished merge blocks as operation-in-progress" \
    || fail "T08d: status=$status reason=$reason"
}

t08e() {
  # "Could not look" must never be recorded as "looked and it was fine".
  # Reading only stdout meant a broken index produced empty output and read
  # as clean — the same silent-freeze shape as the bug being fixed.
  setup_fixture
  advance_remote 1
  printf 'not a git index' > "$(git -C "$SOURCE_REPO" rev-parse --absolute-git-dir)/index"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  if [[ "$status" == "blocked" && "$reason" == "status-unknown" ]]; then
    pass "T08e: an unreadable repo blocks as status-unknown, never as clean"
  elif [[ "$status" == "blocked" || "$status" == "failed" ]]; then
    pass "T08e: an unreadable repo blocks (as $status/$reason), never as clean"
  else
    fail "T08e: broken index did not block — status=$status reason=$reason"
  fi
}

t09() {
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" checkout -q -b feature >/dev/null 2>&1
  run_stager "$PAYLOAD_STARTUP"
  local status reason br sbr
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  br="$(receipt_field '.branch')"; sbr="$(receipt_field '.source_branch')"
  [[ "$status" == "blocked" && "$reason" == "branch" && "$br" == "feature" && "$sbr" == "main" ]] \
    && pass "T09: feature branch != source_branch -> blocked/branch, both names recorded" \
    || fail "T09: status=$status reason=$reason branch=$br source_branch=$sbr"
}

t10() {
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" checkout -q --detach HEAD >/dev/null 2>&1
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "blocked" && "$reason" == "detached" ]] \
    && pass "T10: detached HEAD -> blocked/detached" || fail "T10: status=$status reason=$reason"
}

t11() {
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" branch --unset-upstream >/dev/null 2>&1
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "blocked" && "$reason" == "no-upstream" ]] \
    && pass "T11: branch with no upstream -> blocked/no-upstream" || fail "T11: status=$status reason=$reason"
}

t12() {
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" config protocol.ext.allow always
  local hang_url='ext::sleep 30'
  git -C "$SOURCE_REPO" remote set-url origin "$hang_url"
  local pinf="$CONF_DIR/hooks/stack-update.pin.json"
  jq --arg u "$hang_url" '.remote_url=$u' "$pinf" > "$pinf.tmp2" && mv "$pinf.tmp2" "$pinf"
  local t0=$SECONDS
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=8
  local elapsed=$(( SECONDS - t0 ))
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "skipped" && "$reason" == "offline" && "$elapsed" -lt 12 ]] \
    && pass "T12: unreachable remote -> skipped/offline within the 8s deadline (${elapsed}s wall)" \
    || fail "T12: status=$status reason=$reason elapsed=${elapsed}s"
}

t13() {
  setup_fixture
  rm -f "$CONF_DIR/.stack-install.json"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "skipped" && "$reason" == "no-stamp" ]] \
    && pass "T13: no install stamp, master dir -> skipped/no-stamp" || fail "T13: status=$status reason=$reason"
}

t14() {
  setup_fixture
  local profile_dir="$HOME/.claude-fixture"
  mkdir -p "$profile_dir/hooks" "$profile_dir/state" "$profile_dir/lib"
  cp "$REPO_ROOT/lib/profile-resolver.sh" "$profile_dir/lib/"
  cp "$REPO_ROOT/lib/stack-freshness.sh" "$profile_dir/lib/"
  run_stager "$PAYLOAD_STARTUP" CLAUDE_CONFIG_DIR="$profile_dir"
  local pr="$profile_dir/state/stack-update/receipt.json"
  local status reason pdir
  status="$(jq -r '.status' "$pr" 2>/dev/null)"
  reason="$(jq -r '.reason' "$pr" 2>/dev/null)"
  pdir="$(jq -r '.profile_dir' "$pr" 2>/dev/null)"
  [[ "$status" == "skipped" && "$reason" == "unstamped-profile" && "$pdir" == "$profile_dir" ]] \
    && pass "T14: unstamped profile dir -> skipped/unstamped-profile, receipt under the profile dir" \
    || fail "T14: status=$status reason=$reason profile_dir=$pdir"
}

t15() {
  setup_fixture
  advance_remote 1
  rm -rf "$SOURCE_REPO"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "skipped" && "$reason" == "repo-missing" ]] \
    && pass "T15: source_repo path deleted -> skipped/repo-missing" || fail "T15: status=$status reason=$reason"
}

t16() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-16"
  run_applier "sess-16" STACK_UPDATE_FAKE_RC=1 \
    STACK_UPDATE_FAKE_STDERR="line one error
line two error" \
    STACK_UPDATE_APPLY_BUDGET_S=20
  local status reason err nh
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  err="$(receipt_field '.error')"; nh="$(receipt_field '.needs_human')"
  local log_ok=0
  grep -q "line one error" "$CONF_DIR/state/stack-update/last-update.log" 2>/dev/null \
    && grep -q "line two error" "$CONF_DIR/state/stack-update/last-update.log" 2>/dev/null && log_ok=1
  [[ "$status" == "failed" && "$reason" == "exit-nonzero" && "$err" == "line one error" \
     && "$nh" == "true" && "$log_ok" == "1" ]] \
    && pass "T16: fake updater exit 1, two stderr lines -> failed/exit-nonzero, error is first line, log has both" \
    || fail "T16: status=$status reason=$reason error='$err' needs_human=$nh log_ok=$log_ok"
}

t17() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-17"
  local t0=$SECONDS
  run_applier "sess-17" STACK_UPDATE_APPLY_BUDGET_S=3 STACK_UPDATE_FAKE_SLEEP=8 STACK_UPDATE_FAKE_RC=0
  local elapsed=$(( SECONDS - t0 ))
  local status1; status1="$(receipt_field '.status')"
  local waited=0 status2="$status1"
  while (( waited < 20 )); do
    status2="$(receipt_field '.status')"
    [[ "$status2" == "updated" ]] && break
    sleep 1; waited=$((waited+1))
  done
  [[ "$status1" == "running" && "$elapsed" -le 9 && "$status2" == "updated" ]] \
    && pass "T17: apply exceeds budget -> running, then detached writer finalizes to updated" \
    || fail "T17: first=$status1 (elapsed=${elapsed}s) final=$status2"
}

t18() {
  setup_fixture
  advance_remote 1
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( sleep 30 ) &
  local livepid=$!
  echo "$livepid" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "stage" > "$CONF_DIR/state/stack-update/lock/phase"
  local before; before="$( [[ -f "$CONF_DIR/state/stack-update/receipt.json" ]] && receipt_raw || echo MISSING)"
  run_stager "$PAYLOAD_STARTUP"
  local after; after="$( [[ -f "$CONF_DIR/state/stack-update/receipt.json" ]] && receipt_raw || echo MISSING)"
  kill "$livepid" 2>/dev/null; wait "$livepid" 2>/dev/null
  local ok1=0
  [[ "$before" == "$after" ]] && ok1=1

  rm -rf "$CONF_DIR/state/stack-update/lock"
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( exit 0 ) &
  local deadpid=$!
  wait "$deadpid" 2>/dev/null
  echo "$deadpid" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "apply" > "$CONF_DIR/state/stack-update/lock/phase"
  run_stager "$PAYLOAD_STARTUP"
  local status1 reason1 nh1
  status1="$(receipt_field '.status')"; reason1="$(receipt_field '.reason')"; nh1="$(receipt_field '.needs_human')"
  local lock_gone=0
  [[ ! -d "$CONF_DIR/state/stack-update/lock" ]] && lock_gone=1
  local graveyard_gone=0
  [[ -z "$(find "$CONF_DIR/state/stack-update" -maxdepth 1 -name 'lock.reclaimed.*' 2>/dev/null)" ]] && graveyard_gone=1

  # Cross-family review finding #4: reclaiming a dead APPLY-phase lock must
  # record failed/partial and STOP -- never proceed to stage a fresh receipt
  # over it in the SAME invocation, which would hide a half-applied install.
  # A later, uncontended fire is what actually proceeds to stage.
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_COOLDOWN_S=0
  local status2; status2="$(receipt_field '.status')"

  [[ "$ok1" == "1" && "$status1" == "failed" && "$reason1" == "partial" && "$nh1" == "true" \
     && "$lock_gone" == "1" && "$graveyard_gone" == "1" && "$status2" == "staged" ]] \
    && pass "T18: live lock left untouched; dead+apply lock reclaim STOPS this run at failed/partial (never hidden by a same-run staged overwrite); the next fire proceeds cleanly" \
    || fail "T18: ok1=$ok1 reclaim-run status=$status1/$reason1 needs_human=$nh1 lock_gone=$lock_gone graveyard_gone=$graveyard_gone next-run status=$status2"
}

t19() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"      # staged
  local ok=1
  receipt_validates_against_schema "$(receipt_raw)" || { ok=0; echo "  (T19: 'staged' receipt failed schema)"; }

  setup_fixture
  run_stager "$PAYLOAD_STARTUP"      # current
  receipt_validates_against_schema "$(receipt_raw)" || { ok=0; echo "  (T19: 'current' receipt failed schema)"; }

  setup_fixture
  advance_remote 1
  echo dirty >> "$SOURCE_REPO/README.md"
  run_stager "$PAYLOAD_STARTUP"      # blocked/dirty
  receipt_validates_against_schema "$(receipt_raw)" || { ok=0; echo "  (T19: 'blocked/dirty' receipt failed schema)"; }

  local stray; stray="$(find "$CONF_DIR/state/stack-update" -maxdepth 1 -name '*.tmp*' -o -name '.receipt.*' 2>/dev/null)"
  [[ -z "$stray" ]] || { ok=0; echo "  (T19: stray temp file(s) left: $stray)"; }

  (( ok == 1 )) && pass "T19: every receipt validates against the schema; no *.tmp left behind" \
    || fail "T19: schema or atomicity violation (see above)"
}

# ═══════════════════════════════════════════════════════════════════════════
# T24-T26 — wiring
# ═══════════════════════════════════════════════════════════════════════════

t24() {
  local tpl="$REPO_ROOT/config/settings.global.template.json"
  local ok=1
  jq -e '.hooks.SessionStart[0].hooks | map(.command) | index("~/.claude/hooks/stack-self-update.sh")' "$tpl" >/dev/null 2>&1 || ok=0
  jq -e '.hooks.UserPromptSubmit[0].hooks | map(.command) | index("~/.claude/hooks/stack-update-apply.sh")' "$tpl" >/dev/null 2>&1 || ok=0
  local t1 t2
  t1="$(jq -r '.hooks.SessionStart[0].hooks[] | select(.command=="~/.claude/hooks/stack-self-update.sh") | .timeout' "$tpl" 2>/dev/null)"
  t2="$(jq -r '.hooks.UserPromptSubmit[0].hooks[] | select(.command=="~/.claude/hooks/stack-update-apply.sh") | .timeout' "$tpl" 2>/dev/null)"
  [[ "$t1" =~ ^[0-9]+$ && "$t1" -ge 90 ]] || ok=0
  [[ "$t2" =~ ^[0-9]+$ && "$t2" -ge 90 ]] || ok=0
  (( ok == 1 )) && pass "T24: settings.global.template.json wires both hooks with timeout >= 90s" \
    || fail "T24: wiring or timeout missing (SessionStart timeout=$t1 UserPromptSubmit timeout=$t2)"
}

t25() {
  local tm="$REPO_ROOT/config/tier-manifests/tier-0.json"
  local ok=1
  jq -e '.files.global | map(.from) | index("hooks/stack-self-update.sh")' "$tm" >/dev/null 2>&1 || ok=0
  jq -e '.files.global | map(.from) | index("hooks/stack-update-apply.sh")' "$tm" >/dev/null 2>&1 || ok=0
  jq -e '.smoke_tests | index("test -x ~/.claude/hooks/stack-self-update.sh")' "$tm" >/dev/null 2>&1 || ok=0
  jq -e '.smoke_tests | index("test -x ~/.claude/hooks/stack-update-apply.sh")' "$tm" >/dev/null 2>&1 || ok=0
  (( ok == 1 )) && pass "T25: tier-0.json ships both hooks and smoke-tests both" \
    || fail "T25: tier-0.json missing a hook file entry or smoke test"
}

t26() {
  local hj="$REPO_ROOT/hooks/hooks.json"
  local found
  found="$(grep -c "stack-self-update.sh\|stack-update-apply.sh" "$hj" 2>/dev/null)"
  [[ "$found" =~ ^[0-9]+$ ]] || found=0
  [[ "$found" -eq 0 ]] && pass "T26: hooks/hooks.json wires NEITHER hook (D9 — plugin distribution has no pin/stamp)" \
    || fail "T26: hooks.json unexpectedly references one of the two hooks"
}

# ═══════════════════════════════════════════════════════════════════════════
# T27 — scripts/update.sh's D7 advisory legibility guard
# ═══════════════════════════════════════════════════════════════════════════

t27() {
  local UPDATE_SH="$REPO_ROOT/scripts/update.sh"
  local ok=1

  # A session-marker env present, STACK_UPDATE_VIA_HOOK absent -> refuse
  # (exit 3) before anything else runs (no --tier needed to prove this --
  # the guard is the very first thing in the script).
  local out rc
  out="$(env CLAUDECODE=1 bash "$UPDATE_SH" --tier=1 2>&1)"; rc=$?
  { [[ "$rc" -eq 3 ]] && [[ "$out" == *"ADR-086 D7"* ]]; } \
    || { ok=0; echo "  (T27: CLAUDECODE=1 case rc=$rc out='$out')"; }

  out="$(env CLAUDE_CODE_ENTRYPOINT=cli bash "$UPDATE_SH" --tier=1 2>&1)"; rc=$?
  { [[ "$rc" -eq 3 ]] && [[ "$out" == *"ADR-086 D7"* ]]; } \
    || { ok=0; echo "  (T27: CLAUDE_CODE_ENTRYPOINT=cli case rc=$rc out='$out')"; }

  # Neither marker set -> proceeds past the guard (no --tier here, so it
  # exits 1 at the usage check next -- never touches the real repo's git
  # state -- but it must NOT be the guard's exit 3).
  out="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT bash "$UPDATE_SH" 2>&1)"; rc=$?
  [[ "$rc" -ne 3 ]] || { ok=0; echo "  (T27: neither-set case unexpectedly refused with rc=3)"; }

  # Both a session marker AND STACK_UPDATE_VIA_HOOK=1 -> the applier's own
  # shape (ADR-086 D2) -- proceeds past the guard.
  out="$(env CLAUDECODE=1 STACK_UPDATE_VIA_HOOK=1 bash "$UPDATE_SH" 2>&1)"; rc=$?
  [[ "$rc" -ne 3 ]] || { ok=0; echo "  (T27: both-set case unexpectedly refused with rc=3)"; }

  (( ok == 1 )) \
    && pass "T27: update.sh refuses (exit 3, names ADR-086 D7) when a session marker is set without STACK_UPDATE_VIA_HOOK; runs normally when neither or both are set" \
    || fail "T27: see notes above"
}

t28() {
  if bash "$REPO_ROOT/tests/test-capability-registry.sh" --check >/tmp/.t28-out.$$ 2>&1; then
    pass "T28: tests/test-capability-registry.sh --check passes with the regenerated registry"
  else
    fail "T28: test-capability-registry.sh --check failed: $(tail -5 /tmp/.t28-out.$$)"
  fi
  rm -f /tmp/.t28-out.$$
}

# ═══════════════════════════════════════════════════════════════════════════
# T29-T38 — rev 2 (pin, lock liveness, fetch-error/offline distinction, kill signals)
# ═══════════════════════════════════════════════════════════════════════════

t29() {
  setup_fixture
  advance_remote 1
  rm -f "$CONF_DIR/hooks/stack-update.pin.json"
  run_stager "$PAYLOAD_STARTUP"
  local status reason record
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  record="$(cat "$FAKE_RECORD" 2>/dev/null)"
  [[ "$status" == "skipped" && "$reason" == "no-pin" && -z "$record" ]] \
    && pass "T29: pin absent -> skipped/no-pin, nothing runs" || fail "T29: status=$status reason=$reason record='$record'"
}

t30() {
  setup_fixture
  advance_remote 1
  local stamp="$CONF_DIR/.stack-install.json"
  jq '.source_repo = "/tmp/not-the-pinned-repo"' "$stamp" > "$stamp.tmp2" && mv "$stamp.tmp2" "$stamp"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  local ok1=0; [[ "$status" == "blocked" && "$reason" == "pin-mismatch" ]] && ok1=1

  setup_fixture
  advance_remote 1
  local stamp2="$CONF_DIR/.stack-install.json"
  jq '.tier = 9' "$stamp2" > "$stamp2.tmp2" && mv "$stamp2.tmp2" "$stamp2"
  run_stager "$PAYLOAD_STARTUP"
  local status2 reason2
  status2="$(receipt_field '.status')"; reason2="$(receipt_field '.reason')"
  local ok2=0; [[ "$status2" == "blocked" && "$reason2" == "pin-mismatch" ]] && ok2=1

  (( ok1 == 1 && ok2 == 1 )) && pass "T30: pin/stamp disagree on source_repo and (separately) tier -> blocked/pin-mismatch, needs_human -- pin wins" \
    || fail "T30: repo-mismatch ok=$ok1 ($status/$reason) tier-mismatch ok=$ok2 ($status2/$reason2)"
}

t31() {
  setup_fixture
  advance_remote 1
  local attacker_parent; attacker_parent="$(mktemp -d)"; ALL_TMP_DIRS+=("$attacker_parent")
  local attacker_repo="$attacker_parent/attacker"
  mkdir -p "$attacker_repo/scripts"
  git -C "$attacker_repo" init -q -b main >/dev/null 2>&1 || { mkdir -p "$attacker_repo"; git -C "$attacker_repo" init -q >/dev/null 2>&1; }
  local attacker_record="$FIXTURE_HOME/attacker-record.log"
  cat > "$attacker_repo/scripts/update.sh" <<EOF
#!/usr/bin/env bash
echo "ATTACKER RAN: \$*" >> "$attacker_record"
exit 0
EOF
  chmod +x "$attacker_repo/scripts/update.sh"
  git -C "$attacker_repo" config user.email a@example.com; git -C "$attacker_repo" config user.name A
  git -C "$attacker_repo" add -A >/dev/null 2>&1
  git -C "$attacker_repo" commit -q -m attacker >/dev/null 2>&1

  local stamp="$CONF_DIR/.stack-install.json"
  jq --arg r "$(canon "$attacker_repo")" '.source_repo = $r' "$stamp" > "$stamp.tmp2" && mv "$stamp.tmp2" "$stamp"

  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  local record; record="$(cat "$attacker_record" 2>/dev/null)"
  [[ "$status" == "blocked" && "$reason" == "pin-mismatch" && -z "$record" ]] \
    && pass "T31: stamp repointed at attacker repo, pin unchanged -> attacker's update.sh NEVER executed" \
    || fail "T31: status=$status reason=$reason attacker_record='$record'"
}

t32() {
  setup_fixture
  advance_remote 1
  local pin="$CONF_DIR/hooks/stack-update.pin.json"
  local overall_ok=1

  printf 'not json' > "$pin"
  run_stager "$PAYLOAD_STARTUP"
  { [[ "$(receipt_field '.status')" == "failed" && "$(receipt_field '.reason')" == "malformed-stamp" ]] && [[ -z "$RUN_STDERR" || "$RUN_STDERR" != *"unbound variable"* ]]; } \
    || { overall_ok=0; echo "  (T32: bad JSON case failed)"; }

  jq 'del(.tier)' "$CONF_DIR/hooks/stack-update.pin.json" 2>/dev/null > "$pin.tmp2" 2>/dev/null || echo '{"schema":"stack-update-pin/v2","source_repo":"'"$SOURCE_REPO"'","remote_url":"'"$ACTUAL_REMOTE"'"}' > "$pin.tmp2"
  mv "$pin.tmp2" "$pin"
  run_stager "$PAYLOAD_STARTUP"
  [[ "$(receipt_field '.status')" == "failed" && "$(receipt_field '.reason')" == "malformed-stamp" ]] \
    || { overall_ok=0; echo "  (T32: missing tier field case failed)"; }

  echo "{\"schema\":\"stack-update-pin/v2\",\"source_repo\":\"$SOURCE_REPO\",\"remote_url\":\"$ACTUAL_REMOTE\",\"tier\":\"1; rm -rf\"}" > "$pin"
  run_stager "$PAYLOAD_STARTUP"
  [[ "$(receipt_field '.status')" == "failed" && "$(receipt_field '.reason')" == "malformed-stamp" ]] \
    || { overall_ok=0; echo "  (T32: tier metacharacter case failed)"; }

  echo "{\"schema\":\"stack-update-pin/v2\",\"source_repo\":\"$SOURCE_REPO; rm -rf ~\",\"remote_url\":\"$ACTUAL_REMOTE\",\"tier\":1}" > "$pin"
  run_stager "$PAYLOAD_STARTUP"
  [[ "$(receipt_field '.status')" == "failed" && "$(receipt_field '.reason')" == "malformed-stamp" ]] \
    || { overall_ok=0; echo "  (T32: source_repo metacharacter case failed)"; }

  (( overall_ok == 1 )) && pass "T32: malformed pin variants -> failed/malformed-stamp, nothing runs, no shell errors leak" \
    || fail "T32: at least one malformed-pin variant misbehaved"
}

t33() {
  setup_fixture
  advance_remote 1
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( sleep 30 ) &
  local livepid=$!
  echo "$livepid" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "stage" > "$CONF_DIR/state/stack-update/lock/phase"
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_LOCK_STUCK_S=1
  sleep 2
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_LOCK_STUCK_S=1
  local status reason nh
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"; nh="$(receipt_field '.needs_human')"
  local lock_intact=0
  [[ -d "$CONF_DIR/state/stack-update/lock" ]] && lock_intact=1
  kill "$livepid" 2>/dev/null; wait "$livepid" 2>/dev/null
  [[ "$status" == "failed" && "$reason" == "stuck" && "$nh" == "true" && "$lock_intact" == "1" ]] \
    && pass "T33: live pid, lock aged past the stuck threshold -> failed/stuck, needs_human, lock left in place" \
    || fail "T33: status=$status reason=$reason needs_human=$nh lock_intact=$lock_intact"
}

t34() {
  setup_fixture
  advance_remote 1
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( exit 0 ) &
  local deadpid=$!
  wait "$deadpid" 2>/dev/null
  echo "$deadpid" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "apply" > "$CONF_DIR/state/stack-update/lock/phase"
  # Cross-family review finding #4, split into its two real invariants:
  #
  # (a) Within ONE invocation: the reclaimer of a dead apply-phase lock
  #     records failed/partial and STOPS -- it must never overwrite that
  #     partial with a fresh "staged" in the same run.
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "failed" && "$reason" == "partial" ]] \
    || { fail "T34a: single reclaimer must record failed/partial and stop (status=$status reason=$reason)"; return; }
  # (b) Concurrent contenders: exactly one wins the atomic mv; nobody
  #     leaves a graveyard dir or a lock behind. The FINAL receipt may be
  #     failed/partial (overlapping race: loser saw contention and exited)
  #     or staged (serialized on a fast machine: the second invocation
  #     found no lock and legitimately re-staged AFTER the partial was
  #     recorded -- the failure matrix allows a later run to stage). What
  #     is never legal is a graveyard, a leftover lock, or a receipt in
  #     any state other than those two.
  # Backdate part (a)'s receipt past the cooldown and clear its backoff,
  # otherwise D6 gates 2/2c correctly exit both contenders before they
  # ever look at the lock.
  local rcpt="$CONF_DIR/state/stack-update/receipt.json"
  jq '.as_of = "2000-01-01T00:00:00Z" | del(.retry_after) | del(.fail_sha)' "$rcpt" > "$rcpt.t" && mv "$rcpt.t" "$rcpt"
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( exit 0 ) &
  local deadpid2=$!
  wait "$deadpid2" 2>/dev/null
  echo "$deadpid2" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "apply" > "$CONF_DIR/state/stack-update/lock/phase"
  run_stager "$PAYLOAD_STARTUP" &
  local p1=$!
  run_stager "$PAYLOAD_STARTUP" &
  local p2=$!
  wait "$p1" 2>/dev/null
  wait "$p2" 2>/dev/null
  local leftover_graveyards
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  leftover_graveyards="$(find "$CONF_DIR/state/stack-update" -maxdepth 1 -name 'lock.reclaimed.*' 2>/dev/null)"
  local lock_gone=0
  [[ ! -d "$CONF_DIR/state/stack-update/lock" ]] && lock_gone=1
  local end_ok=0
  { [[ "$status" == "failed" && "$reason" == "partial" ]] || [[ "$status" == "staged" ]]; } && end_ok=1
  [[ "$end_ok" == "1" && -z "$leftover_graveyards" && "$lock_gone" == "1" ]] \
    && pass "T34: dead+apply lock -- single reclaimer records failed/partial and stops; concurrent contenders leave no graveyard and no lock (final: $status/${reason:-n-a})" \
    || fail "T34: status=$status reason=$reason leftover_graveyards='$leftover_graveyards' lock_gone=$lock_gone"
}

t35() {
  setup_fixture
  advance_remote 1
  mkdir -p "$CONF_DIR/state/stack-update/lock"
  ( sleep 30 ) &
  local livepid=$!
  echo "$livepid" > "$CONF_DIR/state/stack-update/lock/pid"
  echo "stage" > "$CONF_DIR/state/stack-update/lock/phase"
  local before; before="$( [[ -f "$CONF_DIR/state/stack-update/receipt.json" ]] && receipt_raw || echo MISSING)"
  run_stager "$PAYLOAD_STARTUP"
  local after; after="$( [[ -f "$CONF_DIR/state/stack-update/receipt.json" ]] && receipt_raw || echo MISSING)"
  kill "$livepid" 2>/dev/null; wait "$livepid" 2>/dev/null
  [[ "$before" == "$after" ]] && pass "T35: live lock, fresh (<30min) -> exit 0, receipt byte-identical" \
    || fail "T35: receipt mutated despite a fresh live lock"
}

t36() {
  # Fixture-local swap of the PROBE dependency (not the real repo file) so we
  # can force "N behind" while controlling exactly how the STAGE fetch fails.
  fake_freshness_behind() {
    cat > "$CONF_DIR/lib/stack-freshness.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--oneline" ]]; then echo "1 behind"; else echo "1 commit(s) behind"; fi
exit 10
EOF
  }

  setup_fixture
  fake_freshness_behind
  git -C "$SOURCE_REPO" remote set-url origin "$REMOTE_DIR/does-not-exist.git"
  local pinf="$CONF_DIR/hooks/stack-update.pin.json"
  jq --arg u "$REMOTE_DIR/does-not-exist.git" '.remote_url=$u' "$pinf" > "$pinf.tmp2" && mv "$pinf.tmp2" "$pinf"
  run_stager "$PAYLOAD_STARTUP"
  local status1 reason1
  status1="$(receipt_field '.status')"; reason1="$(receipt_field '.reason')"
  local ok1=0
  [[ "$status1" == "failed" && "$reason1" == "fetch-error" ]] && ok1=1

  setup_fixture
  fake_freshness_behind
  git -C "$SOURCE_REPO" config protocol.ext.allow always
  local hang_url='ext::sleep 30'
  git -C "$SOURCE_REPO" remote set-url origin "$hang_url"
  local pinf2="$CONF_DIR/hooks/stack-update.pin.json"
  jq --arg u "$hang_url" '.remote_url=$u' "$pinf2" > "$pinf2.tmp2" && mv "$pinf2.tmp2" "$pinf2"
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=8
  local status2 reason2
  status2="$(receipt_field '.status')"; reason2="$(receipt_field '.reason')"
  local ok2=0
  [[ "$status2" == "skipped" && "$reason2" == "offline" ]] && ok2=1

  (( ok1 == 1 && ok2 == 1 )) \
    && pass "T36: stage-fetch auth-style failure -> failed/fetch-error; stage-fetch timeout -> skipped/offline (distinguished)" \
    || fail "T36: fast-fail=$status1/$reason1 hang=$status2/$reason2"
}

t37() {
  setup_fixture
  advance_remote 1
  git -C "$SOURCE_REPO" config protocol.ext.allow always
  git -C "$SOURCE_REPO" remote set-url origin 'ext::sleep 30'
  local pinf="$CONF_DIR/hooks/stack-update.pin.json"
  jq '.remote_url = "ext::sleep 30"' "$pinf" > "$pinf.tmp2" && mv "$pinf.tmp2" "$pinf"
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=2
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=2 STACK_UPDATE_COOLDOWN_S=0
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=2 STACK_UPDATE_COOLDOWN_S=0
  local co3; co3="$(receipt_field '.consecutive_offline')"
  local ok1=0; [[ "$co3" == "3" ]] && ok1=1

  git -C "$SOURCE_REPO" remote set-url origin "$REMOTE_DIR"
  jq --arg u "$ACTUAL_REMOTE" '.remote_url = $u' "$pinf" > "$pinf.tmp2" && mv "$pinf.tmp2" "$pinf"
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_COOLDOWN_S=0
  local co4; co4="$(receipt_field '.consecutive_offline')"
  (( ok1 == 1 && co4 == 0 )) \
    && pass "T37: three consecutive offline fires -> consecutive_offline reaches 3, resets to 0 on success" \
    || fail "T37: after 3 offline fires co=$co3, after recovery co=$co4"
}

t38() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-38"
  run_applier "sess-38" STACK_UPDATE_FAKE_SIGNAL=KILL STACK_UPDATE_APPLY_BUDGET_S=20
  local waited=0 status err
  while (( waited < 15 )); do
    status="$(receipt_field '.status')"
    [[ "$status" == "failed" ]] && break
    sleep 1; waited=$((waited+1))
  done
  err="$(receipt_field '.error')"
  [[ "$status" == "failed" && "$err" == "killed or crashed (exit 137)" ]] \
    && pass "T38: fake updater SIGKILLed -> error is 'killed or crashed (exit 137)', never empty" \
    || fail "T38: status=$status error='$err'"
}

# ═══════════════════════════════════════════════════════════════════════════
# T42-T44 — rev 3 staging, remote pin, pre-rev-3 pin migration
# ═══════════════════════════════════════════════════════════════════════════

dir_fingerprint() {  # everything under $1 EXCEPT state/stack-update/**
  ( cd "$1" && find . -path './state/stack-update' -prune -o -type f -print0 2>/dev/null \
      | xargs -0 -I{} sh -c 'echo "{}"; cat "{}" 2>/dev/null' 2>/dev/null | shasum -a 256 2>/dev/null | cut -d' ' -f1 )
}

t42() {
  setup_fixture
  advance_remote 1
  local before; before="$(dir_fingerprint "$CONF_DIR")"
  run_stager "$PAYLOAD_STARTUP"
  local after; after="$(dir_fingerprint "$CONF_DIR")"
  local status ssha scount subjects record
  status="$(receipt_field '.status')"
  ssha="$(receipt_field '.staged_sha')"
  scount="$(receipt_field '.staged_count')"
  subjects="$(receipt_field '.staged_subjects | length')"
  record="$(cat "$FAKE_RECORD" 2>/dev/null)"
  local expected_count; expected_count="$(git -C "$SOURCE_REPO" rev-list --count "HEAD..refs/remotes/origin/main" 2>/dev/null)"
  [[ "$status" == "staged" && "$ssha" =~ ^[0-9a-f]{40}$ && "$scount" == "$expected_count" \
     && "$subjects" -le 5 && "$before" == "$after" && -z "$record" ]] \
    && pass "T42: stage-only -- 40-hex staged_sha, staged_count matches rev-list, ~/.claude byte-identical, no updater run" \
    || fail "T42: status=$status ssha=$ssha scount=$scount(expected $expected_count) subjects=$subjects before==after:$([[ "$before" == "$after" ]] && echo yes || echo no) record='$record'"
}

t43() {
  setup_fixture
  advance_remote 1
  local attacker_parent; attacker_parent="$(mktemp -d)"; ALL_TMP_DIRS+=("$attacker_parent")
  git init --quiet --bare "$attacker_parent/attacker.git" >/dev/null 2>&1
  git -C "$SOURCE_REPO" remote set-url origin "$attacker_parent/attacker.git"
  run_stager "$PAYLOAD_STARTUP"
  local status reason nh
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"; nh="$(receipt_field '.needs_human')"
  [[ "$status" == "blocked" && "$reason" == "remote-mismatch" && "$nh" == "true" ]] \
    && pass "T43: origin repointed to an attacker remote -> blocked/remote-mismatch, needs_human, before any fetch" \
    || fail "T43: status=$status reason=$reason needs_human=$nh"
}

t44() {
  setup_fixture
  advance_remote 1
  local pin="$CONF_DIR/hooks/stack-update.pin.json"
  echo "{\"schema\":\"stack-update-pin/v1\",\"source_repo\":\"$SOURCE_REPO\",\"tier\":1}" > "$pin"
  run_stager "$PAYLOAD_STARTUP"
  local status reason
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  [[ "$status" == "skipped" && "$reason" == "pin-outdated" ]] \
    && pass "T44: pre-rev-3 stack-update-pin/v1 (no remote_url) -> skipped/pin-outdated, no fetch" \
    || fail "T44: status=$status reason=$reason"
}

# ═══════════════════════════════════════════════════════════════════════════
# T50-T53 — D17 symlink refusal, D18 pgroup kill, D19 sanitizer
# ═══════════════════════════════════════════════════════════════════════════

t50() {
  setup_fixture
  local scratch; scratch="$(mktemp -d)"; ALL_TMP_DIRS+=("$scratch")
  echo "sentinel" > "$scratch/sentinel.txt"
  local before_mtime before_content
  before_mtime="$(stat -c '%Y' "$scratch/sentinel.txt" 2>/dev/null || stat -f '%m' "$scratch/sentinel.txt")"
  before_content="$(cat "$scratch/sentinel.txt")"
  rm -rf "$CONF_DIR/state/stack-update"
  ln -s "$scratch" "$CONF_DIR/state/stack-update"
  run_stager "$PAYLOAD_STARTUP"
  local after_mtime after_content
  after_mtime="$(stat -c '%Y' "$scratch/sentinel.txt" 2>/dev/null || stat -f '%m' "$scratch/sentinel.txt")"
  after_content="$(cat "$scratch/sentinel.txt")"
  local uf="$CONF_DIR/state/stack-update-unsafe.json"
  local status reason nh
  status="$(jq -r '.status' "$uf" 2>/dev/null)"
  reason="$(jq -r '.reason' "$uf" 2>/dev/null)"
  nh="$(jq -r '.needs_human' "$uf" 2>/dev/null)"
  [[ "$status" == "failed" && "$reason" == "unsafe-state-dir" && "$nh" == "true" \
     && "$before_mtime" == "$after_mtime" && "$before_content" == "$after_content" ]] \
    && pass "T50: symlinked state dir -> failed/unsafe-state-dir on the fallback leaf; symlink target untouched" \
    || fail "T50: status=$status reason=$reason needs_human=$nh mtime $before_mtime->$after_mtime"
}

t51() {
  setup_fixture
  advance_remote 1
  mkdir -p "$CONF_DIR/state/stack-update"
  local sentinel; sentinel="$(mktemp)"; ALL_TMP_DIRS+=("$sentinel")
  echo "sentinel-log" > "$sentinel"
  local before; before="$(cat "$sentinel")"
  ln -sf "$sentinel" "$CONF_DIR/state/stack-update/last-update.log"
  run_stager "$PAYLOAD_STARTUP"
  local after; after="$(cat "$sentinel")"
  [[ "$before" == "$after" ]] \
    && pass "T51: pre-placed log symlink -> sentinel target untouched (rotated away, never written through)" \
    || fail "T51: sentinel content changed: '$before' -> '$after'"
}

t52() {
  setup_fixture
  advance_remote 1
  cat > "$CONF_DIR/lib/stack-freshness.sh" <<'EOF'
#!/usr/bin/env bash
( sleep 60 & echo $! > "${GRANDCHILD_PID_FILE:-/dev/null}"; wait ) &
wait
echo "1 behind"
exit 10
EOF
  local pidfile; pidfile="$(mktemp)"; ALL_TMP_DIRS+=("$pidfile")
  local t0=$SECONDS
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_PROBE_DEADLINE_S=2 GRANDCHILD_PID_FILE="$pidfile"
  local elapsed=$(( SECONDS - t0 ))
  sleep 1
  local gpid grandchild_dead=1
  gpid="$(cat "$pidfile" 2>/dev/null)"
  [[ -n "$gpid" ]] && kill -0 "$gpid" 2>/dev/null && grandchild_dead=0
  [[ "$elapsed" -le 4 && "$grandchild_dead" == "1" ]] \
    && pass "T52: process-group kill terminates a sleeping grandchild within deadline+2s" \
    || fail "T52: elapsed=${elapsed}s grandchild_dead=$grandchild_dead"
}

t53() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-53"
  # A real NUL byte cannot survive an `env VAR=value` boundary (POSIX env is
  # NUL-terminated C strings) nor a bash `[[ *$'\x00'* ]]` glob test (bash
  # collapses $'\x00' to the empty string, which would make the pattern
  # tautologically match everything) -- so NUL-stripping is exercised at the
  # unit level via sanitize_text directly, and this end-to-end case covers
  # ESC/CSI/OSC-52, a bare CR, non-ASCII bytes and >200 raw characters.
  local nasty
  nasty=$'\x1b]52;c;AAAA\x07bad line\rafter-cr caf\xc3\xa9'
  local padded; padded="$(printf '%0.s x' $(seq 1 60))"
  run_applier "sess-53" STACK_UPDATE_FAKE_RC=1 STACK_UPDATE_FAKE_STDERR="${nasty}${padded}"
  local err
  err="$(receipt_field '.error')"
  local ok=1
  [[ "${#err}" -le 200 ]] || ok=0
  printf '%s' "$err" | LC_ALL=C grep -qP '[^\x20-\x7e]' 2>/dev/null && ok=0
  [[ "$err" != *$'\x1b'* && "$err" != *$'\r'* ]] || ok=0
  [[ "$err" == "]52;c;AAAAbad line" ]] || ok=0

  # sanitize_text is a plain shell function; unit-test it directly for the
  # rc>=128 fallback text (the one case a real NUL-adjacent crash can hit).
  killed_text="$(bash -c '
    sanitize_text() {
      local raw="${1:-}" maxlen="${2:-200}" rc="${3:-}"
      local firstline="${raw%%$'"'"'\n'"'"'*}"
      firstline="${firstline%%$'"'"'\r'"'"'*}"
      local cleaned
      cleaned="$(printf "%s" "$firstline" | LC_ALL=C tr -cd '"'"'\40-\176'"'"')"
      cleaned="$(printf "%s" "$cleaned" | LC_ALL=C sed -e '"'"'s/  */ /g'"'"' -e '"'"'s/^ *//'"'"' -e '"'"'s/ *$//'"'"')"
      cleaned="${cleaned:0:$maxlen}"
      if [[ -z "$cleaned" ]]; then
        if [[ "$rc" =~ ^[0-9]+$ ]] && (( rc >= 128 )); then
          cleaned="killed or crashed (exit $rc)"
        else
          cleaned="no error text"
        fi
      fi
      printf "%s" "$cleaned"
    }
    sanitize_text "" 200 137
  ')"
  [[ "$killed_text" == "killed or crashed (exit 137)" ]] || ok=0

  (( ok == 1 )) && pass "T53: sanitizer strips ESC/CSI/OSC-52/CR/non-ASCII, first line only, exact match, killed-fallback text" \
    || fail "T53: error='$err' (len ${#err}) killed_text='$killed_text'"
}

# ═══════════════════════════════════════════════════════════════════════════
# T55-T59, T61, T63
# ═══════════════════════════════════════════════════════════════════════════

t55() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  local deltas=()
  local i
  local r="$CONF_DIR/state/stack-update/receipt.json"
  for i in 1 2 3; do
    # Simulate "the same broken SHA got staged again" (what a real boot's
    # gate-2c-cleared re-stage would do) so each attempt actually reaches
    # the apply path instead of being refused as consent-stale.
    jq --arg s "$ssha" '.status="staged" | .staged_sha=$s' "$r" > "$r.tmp2" 2>/dev/null && mv "$r.tmp2" "$r"
    write_consent "$ssha" "sess-55-$i"
    run_applier "sess-55-$i" STACK_UPDATE_FAKE_RC=1 STACK_UPDATE_FAKE_STDERR="boom $i" STACK_UPDATE_APPLY_BUDGET_S=20
    local waited=0
    while (( waited < 15 )); do
      [[ "$(receipt_field '.status')" == "failed" ]] && break
      sleep 1; waited=$((waited+1))
    done
    local cf ra now delta
    cf="$(receipt_field '.consecutive_failures')"
    ra="$(receipt_field '.retry_after')"
    now="$(date -u +%s)"
    delta=$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ra" +%s 2>/dev/null || date -u -d "$ra" +%s) - now ))
    deltas+=("$cf:$delta")
  done
  jq --arg s "$ssha" '.consecutive_failures=20 | .fail_sha=$s | .status="staged" | .staged_sha=$s' "$r" > "$r.tmp2" && mv "$r.tmp2" "$r"
  write_consent "$ssha" "sess-55-cap"
  run_applier "sess-55-cap" STACK_UPDATE_FAKE_RC=1 STACK_UPDATE_FAKE_STDERR="boom cap" STACK_UPDATE_APPLY_BUDGET_S=20
  local waited2=0
  while (( waited2 < 15 )); do
    [[ "$(receipt_field '.status')" == "failed" ]] && break
    sleep 1; waited2=$((waited2+1))
  done
  local ra_cap delta_cap
  ra_cap="$(receipt_field '.retry_after')"
  delta_cap=$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ra_cap" +%s 2>/dev/null || date -u -d "$ra_cap" +%s) - $(date -u +%s) ))

  # D6 gate 2c is a purely local check (no fetch, by design -- backoff must
  # not re-tax the network). "The remote tip differs" therefore becomes
  # visible to the hook only once something already updated the LOCAL
  # remote-tracking ref -- simulate that directly (a human running `git
  # fetch`, or a peer process) rather than expecting the backoff gate itself
  # to discover a push it deliberately avoids fetching for.
  advance_remote 1
  git -C "$SOURCE_REPO" fetch --quiet origin main >/dev/null 2>&1
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_COOLDOWN_S=0
  local reset_cf reset_fs reset_ra
  reset_cf="$(receipt_field '.consecutive_failures')"; reset_fs="$(receipt_field '.fail_sha')"; reset_ra="$(receipt_field '.retry_after')"

  local ok=1
  [[ "${deltas[0]}" == 1:600 || "${deltas[0]}" == "1:599" ]] || { ok=0; echo "  (T55: delta1=${deltas[0]}, want ~1:600)"; }
  [[ "${deltas[1]}" == 2:1200 || "${deltas[1]}" == "2:1199" ]] || { ok=0; echo "  (T55: delta2=${deltas[1]}, want ~2:1200)"; }
  [[ "${deltas[2]}" == 3:2400 || "${deltas[2]}" == "3:2399" ]] || { ok=0; echo "  (T55: delta3=${deltas[2]}, want ~3:2400)"; }
  (( delta_cap <= 86400 && delta_cap >= 86390 )) || { ok=0; echo "  (T55: capped delta=$delta_cap, want ~86400)"; }
  [[ "$reset_cf" == "0" && ( "$reset_fs" == "null" || -z "$reset_fs" ) && ( "$reset_ra" == "null" || -z "$reset_ra" ) ]] \
    || { ok=0; echo "  (T55: reset fields cf=$reset_cf fail_sha=$reset_fs retry_after=$reset_ra)"; }
  (( ok == 1 )) && pass "T55: backoff growth 600/1200/2400s, cap at 86400s, reset on a new remote tip" \
    || fail "T55: see notes above"
}

t56() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-56"
  run_applier "sess-56" STACK_UPDATE_FAKE_RC=1 STACK_UPDATE_FAKE_STDERR="persistent failure" STACK_UPDATE_APPLY_BUDGET_S=20
  local waited=0
  while (( waited < 15 )); do
    [[ "$(receipt_field '.status')" == "failed" ]] && break
    sleep 1; waited=$((waited+1))
  done
  run_stager "$PAYLOAD_STARTUP" STACK_UPDATE_COOLDOWN_S=0
  local status reason err nh
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"
  err="$(receipt_field '.error')"; nh="$(receipt_field '.needs_human')"
  [[ "$status" == "skipped" && "$reason" == "backoff" && "$err" == "persistent failure" && "$nh" == "true" ]] \
    && pass "T56: backoff is not silence -- the receipt keeps the last failure's error and needs_human while retry_after is future" \
    || fail "T56: status=$status reason=$reason error='$err' needs_human=$nh"
}

t57() {
  local git_shim_dir; git_shim_dir="$(mktemp -d)"; ALL_TMP_DIRS+=("$git_shim_dir")
  local call_log="$git_shim_dir/git-calls.log"
  cat > "$git_shim_dir/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$git_shim_dir/git"

  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-57"
  : > "$call_log"
  PATH="$git_shim_dir:$PATH" run_applier "sess-57" STACK_UPDATE_APPLY_BUDGET_S=20
  local waited=0
  while (( waited < 15 )); do
    [[ "$(receipt_field '.status')" == "updated" ]] && break
    sleep 1; waited=$((waited+1))
  done
  local net_calls
  net_calls="$(grep -Ec '(^| )(fetch|pull|clone|ls-remote)( |$)' "$call_log" 2>/dev/null)"
  [[ "$net_calls" =~ ^[0-9]+$ ]] || net_calls=0
  local ok=1
  [[ "$net_calls" -eq 0 ]] || { ok=0; echo "  (T57: apply path invoked $net_calls network-shaped git subcommand(s): $(cat "$call_log"))"; }

  # ─── R2 completion: the REAL scripts/update.sh, not the fixture's fake
  # one, under STACK_UPDATE_NO_PULL=1, makes no `git pull` call of its own.
  # A standalone fixture (bare origin + working clone), independent of
  # setup_fixture's SOURCE_REPO, with a real HOME override -- update.sh
  # writes ~/.claude, so this must not touch this developer checkout's own
  # ~/.claude or its own git state.
  : > "$call_log"
  local real_home; real_home="$(mktemp -d)"; ALL_TMP_DIRS+=("$real_home")
  local remote_parent2; remote_parent2="$(mktemp -d)"; ALL_TMP_DIRS+=("$remote_parent2")
  local remote_dir2; remote_dir2="$(canon "$remote_parent2")/origin.git"
  git init --quiet --bare -b main "$remote_dir2" >/dev/null 2>&1
  local src_parent2; src_parent2="$(mktemp -d)"; ALL_TMP_DIRS+=("$src_parent2")
  git clone --quiet "$remote_dir2" "$src_parent2/src" >/dev/null 2>&1
  local fixture_repo; fixture_repo="$(canon "$src_parent2/src")"
  git -C "$fixture_repo" config user.email "test@example.com"
  git -C "$fixture_repo" config user.name "Test"

  # The REAL update.sh (it calls "$SCRIPT_DIR/install.sh" -- give it a
  # minimal recording stub for install.sh so this exercises only update.sh's
  # own pull-skip and pin-write behaviour, not the full installer).
  mkdir -p "$fixture_repo/scripts"
  cp "$REPO_ROOT/scripts/update.sh" "$fixture_repo/scripts/update.sh"
  chmod +x "$fixture_repo/scripts/update.sh"
  local install_record="$real_home/install-record.log"
  cat > "$fixture_repo/scripts/install.sh" <<EOF
#!/usr/bin/env bash
echo "ARGV: \$*" >> "$install_record"
exit 0
EOF
  chmod +x "$fixture_repo/scripts/install.sh"
  echo "seed" > "$fixture_repo/README.md"
  git -C "$fixture_repo" add -A >/dev/null 2>&1
  git -C "$fixture_repo" commit --quiet -m seed >/dev/null 2>&1
  git -C "$fixture_repo" push --quiet -u origin main >/dev/null 2>&1

  local real_update_rc=0
  (
    cd "$fixture_repo" && \
    HOME="$real_home" PATH="$git_shim_dir:$PATH" \
    STACK_UPDATE_VIA_HOOK=1 STACK_UPDATE_NO_PULL=1 STACK_INSESSION=1 STACK_UPDATE_MODE=hook \
    bash "$fixture_repo/scripts/update.sh" --tier=1 < /dev/null > "$real_home/update-out.log" 2>&1
  ) || real_update_rc=$?

  local real_net_calls
  real_net_calls="$(grep -Ec '(^| )pull( |$)' "$call_log" 2>/dev/null)"
  [[ "$real_net_calls" =~ ^[0-9]+$ ]] || real_net_calls=0
  local installed_ok=0
  grep -q -- "--tier=1" "$install_record" 2>/dev/null && installed_ok=1
  local pin_ok=0
  local pin_file="$real_home/.claude/hooks/stack-update.pin.json"
  if [[ -f "$pin_file" ]]; then
    [[ "$(jq -r '.schema' "$pin_file" 2>/dev/null)" == "stack-update-pin/v2" \
       && "$(jq -r '.remote_url' "$pin_file" 2>/dev/null)" == "$remote_dir2" \
       && "$(jq -r '.tier' "$pin_file" 2>/dev/null)" == "1" ]] && pin_ok=1
  fi

  if [[ "$real_update_rc" -ne 0 || "$real_net_calls" -ne 0 || "$installed_ok" -ne 1 || "$pin_ok" -ne 1 ]]; then
    ok=0
    echo "  (T57 real update.sh: rc=$real_update_rc net_calls=$real_net_calls installed_ok=$installed_ok pin_ok=$pin_ok; tail: $(tail -5 "$real_home/update-out.log" 2>/dev/null))"
  fi

  (( ok == 1 )) \
    && pass "T57: zero fetch/pull/clone/ls-remote in the applier's apply path, AND the real scripts/update.sh under STACK_UPDATE_NO_PULL=1 makes zero git-pull calls of its own (still runs install.sh, still writes its own pin)" \
    || fail "T57: see notes above"
}

t58() {
  # Sub-case A: the staged objects are gone by the time consent is acted on
  # (deleting the ref alone is not enough -- git keeps the commit reachable
  # until gc -- so actually prune it, matching a real "someone force-pushed
  # and gc'd the source repo" scenario).
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  git -C "$SOURCE_REPO" update-ref -d "refs/remotes/origin/main"
  : > "$SOURCE_REPO/.git/FETCH_HEAD" 2>/dev/null || true
  git -C "$SOURCE_REPO" reflog expire --expire=now --all >/dev/null 2>&1
  git -C "$SOURCE_REPO" gc --prune=now --quiet >/dev/null 2>&1
  write_consent "$ssha" "sess-58a"
  run_applier "sess-58a" STACK_UPDATE_APPLY_BUDGET_S=20
  local status1 reason1 record1
  status1="$(receipt_field '.status')"; reason1="$(receipt_field '.reason')"
  record1="$(cat "$FAKE_RECORD" 2>/dev/null)"
  local ok1=0
  [[ "$status1" == "failed" && "$reason1" == "stage-mismatch" && -z "$record1" ]] && ok1=1

  # Sub-case B: the source repo becomes dirty in the gap between staging and
  # consent (an untracked file appears). D13 apply step2's re-verify catches
  # this before any merge is attempted -- "nothing is trusted across the
  # consent gap" applies to cleanliness too, not just object presence.
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha2; ssha2="$(receipt_field '.staged_sha')"
  echo "untracked" > "$SOURCE_REPO/untracked-surprise.txt"
  write_consent "$ssha2" "sess-58b"
  run_applier "sess-58b" STACK_UPDATE_APPLY_BUDGET_S=20
  local status2 reason2 record2
  status2="$(receipt_field '.status')"; reason2="$(receipt_field '.reason')"
  record2="$(cat "$FAKE_RECORD" 2>/dev/null)"
  local ok2=0
  [[ "$status2" == "failed" && "$reason2" == "stage-mismatch" && -z "$record2" ]] && ok2=1

  (( ok1 == 1 && ok2 == 1 )) \
    && pass "T58: pruned staged objects, or a dirty tree after the ff-merge -> failed/stage-mismatch, install.sh never invoked" \
    || fail "T58: pruned-objects case status=$status1 reason=$reason1 record='$record1'; dirty-after-merge case status=$status2 reason=$reason2 record='$record2'"
}

t59() {
  local floor="$REPO_ROOT/config/managed-settings.floor.json"
  local ok=1
  for entry in \
    '~/.claude/.stack-install.json' \
    '**/.claude/.stack-install.json' \
    '~/.claude/state/stack-update/**' \
    '**/.claude/state/stack-update/**' \
    '~/.claude-*/state/stack-update/**'
  do
    jq -e --arg e "$entry" '.sandbox.filesystem.denyWrite | index($e)' "$floor" >/dev/null 2>&1 || { ok=0; echo "  (T59: missing $entry)"; }
  done
  for entry in \
    '**/.claude/settings.json' '**/.claude/settings.local.json' '**/.claude/stack-config.json' \
    '~/.claude/settings.json' '~/.claude/stack-defaults.json' '~/.claude/hooks/**' \
    '~/.claude/scripts/**' '~/.claude/config/**' '~/.claude/agents/**' '~/.claude/skills/**' '~/.claude/lib/**'
  do
    jq -e --arg e "$entry" '.sandbox.filesystem.denyWrite | index($e)' "$floor" >/dev/null 2>&1 || { ok=0; echo "  (T59: original entry missing: $entry)"; }
  done
  jq -e '.sandbox.filesystem.denyWrite | index("~/.claude/state/**")' "$floor" >/dev/null 2>&1 && { ok=0; echo "  (T59: blanket ~/.claude/state/** must NOT be present)"; }
  jq -e '.sandbox.filesystem.denyWrite[] | select(test("stack-consent"))' "$floor" >/dev/null 2>&1 && { ok=0; echo "  (T59: an entry matching state/stack-consent must NOT be present)"; }
  (( ok == 1 )) && pass "T59: floor has all 5 new denyWrite entries + original 11, no blanket state/**, no stack-consent entry" \
    || fail "T59: see notes above"
}

t61() {
  setup_fixture
  local before; before="$(dir_fingerprint "$CONF_DIR/state")"
  local out
  out="$(printf '{"session_id":"sess-61"}' | bash "$APPLIER" 2>/dev/null)"
  local rc=$?
  local after; after="$(dir_fingerprint "$CONF_DIR/state")"
  [[ "$rc" -eq 0 && -z "$out" && "$before" == "$after" ]] \
    && pass "T61: applier fast path -- no consent file -> exit 0, no stdout, no filesystem writes" \
    || fail "T61: rc=$rc out='$out' before==after:$([[ "$before" == "$after" ]] && echo yes || echo no)"
}

t63() {
  setup_fixture
  advance_remote 1
  echo "local-only-change" >> "$SOURCE_REPO/local.txt"
  git -C "$SOURCE_REPO" add -A >/dev/null 2>&1
  git -C "$SOURCE_REPO" commit --quiet -m "local commit not on origin" >/dev/null 2>&1
  run_stager "$PAYLOAD_STARTUP"
  local status reason ssha
  status="$(receipt_field '.status')"; reason="$(receipt_field '.reason')"; ssha="$(receipt_field '.staged_sha')"
  [[ "$status" == "blocked" && "$reason" == "not-ff" && ( "$ssha" == "null" || -z "$ssha" ) ]] \
    && pass "T63: local commit not on origin (diverged) -> blocked/not-ff, nothing staged" \
    || fail "T63: status=$status reason=$reason staged_sha=$ssha"
}

# ═══════════════════════════════════════════════════════════════════════════
# T64-T65 — cross-family code review fixes (2026-08-19): finding #1 (repo-
# local git hooks must never fire during a privileged git op) and finding #2
# (the apply lock must record the detached worker's pid, not the foreground
# hook's own $$).
# ═══════════════════════════════════════════════════════════════════════════

t64() {
  setup_fixture
  advance_remote 1
  local marker="$FIXTURE_HOME/git-hook-fired.marker"
  mkdir -p "$SOURCE_REPO/.git/hooks"
  local h
  for h in post-merge post-checkout reference-transaction post-rewrite; do
    cat > "$SOURCE_REPO/.git/hooks/$h" <<EOF
#!/usr/bin/env bash
echo "FIRED:$h \$*" >> "$marker"
exit 0
EOF
    chmod +x "$SOURCE_REPO/.git/hooks/$h"
  done

  # Stage (git fetch into .git/) then apply (git merge --ff-only via the
  # real applier + its detached worker) -- every privileged git invocation
  # in both hooks must run with core.hooksPath=/dev/null (finding #1).
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-64"
  run_applier "sess-64" STACK_UPDATE_APPLY_BUDGET_S=20
  local waited=0
  while (( waited < 15 )); do
    [[ "$(receipt_field '.status')" == "updated" ]] && break
    sleep 1; waited=$((waited+1))
  done

  local fired=0
  [[ -s "$marker" ]] && fired=1
  (( fired == 0 )) \
    && pass "T64: planted post-merge/post-checkout/reference-transaction/post-rewrite hooks in the source repo NEVER fire across stage (fetch) + apply (merge --ff-only) (finding #1)" \
    || fail "T64: a repo-local git hook fired during a privileged git operation: $(cat "$marker" 2>/dev/null)"
}

t65() {
  setup_fixture
  advance_remote 1
  run_stager "$PAYLOAD_STARTUP"
  local ssha; ssha="$(receipt_field '.staged_sha')"
  write_consent "$ssha" "sess-65"
  # A short budget + a slow fake updater forces the foreground applier to
  # return "running" and exit WHILE the detached worker is still sleeping.
  run_applier "sess-65" STACK_UPDATE_APPLY_BUDGET_S=3 STACK_UPDATE_FAKE_SLEEP=8 STACK_UPDATE_FAKE_RC=0
  local status1; status1="$(receipt_field '.status')"
  local lockpid; lockpid="$(cat "$CONF_DIR/state/stack-update/lock/pid" 2>/dev/null)"
  # By the time run_applier's command substitution returns, the FOREGROUND
  # process has already exited. If lock/pid still named the foreground's own
  # $$ (finding #2's bug), it would already be dead here. It must instead
  # name the still-sleeping detached worker.
  local pid_alive_at_running=0
  [[ -n "$lockpid" ]] && kill -0 "$lockpid" 2>/dev/null && pid_alive_at_running=1

  local waited=0 status2="$status1"
  while (( waited < 20 )); do
    status2="$(receipt_field '.status')"
    [[ "$status2" == "updated" ]] && break
    sleep 1; waited=$((waited+1))
  done

  [[ "$status1" == "running" && -n "$lockpid" && "$pid_alive_at_running" == "1" && "$status2" == "updated" ]] \
    && pass "T65: apply lock records the DETACHED WORKER's pid (still alive right after the foreground returns 'running'), not the already-exited foreground's (finding #2)" \
    || fail "T65: status1=$status1 lockpid=$lockpid pid_alive_at_running=$pid_alive_at_running status2=$status2"
}

# ═══════════════════════════════════════════════════════════════════════════

# T02 ("stager stdout is empty in every case") is a suite-wide invariant
# checked against every run_stager call made below -- it runs LAST so its
# STDOUT_LEAK counter reflects the whole suite, not just t01.
for t in t01 t03 t04 t05 t06 t07 t08 t08b t08c t08d t08e t09 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 \
         t24 t25 t26 t27 t28 \
         t29 t30 t31 t32 t33 t34 t35 t36 t37 t38 \
         t42 t43 t44 \
         t50 t51 t52 t53 \
         t55 t56 t57 t58 t59 t61 t63 t64 t65 \
         t02; do
  "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
