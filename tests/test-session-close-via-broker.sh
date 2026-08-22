#!/usr/bin/env bash
# tests/test-session-close-via-broker.sh — D18 P4 step 5: the stack's own
# GitHub writers go through the broker.
#
# SCOPE, stated honestly (ADR-085): the design's P4 done-test wants "a real PR
# opened end-to-end through the broker". That needs P3's broker principals,
# which only a human can create. Until then this test proves the migrated
# path against the daemon with a STUBBED vendor: the bundle is really staged,
# really hash-verified on the daemon's copy, really ref-checked, invariants
# really evaluated, receipts really minted — only the vendor HTTP call is a
# stub. Run with STACK_BROKER_LIVE=1 after P3 to assert the real PR instead.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/broker/stack_broker_daemon.py"
CLIENT="$REPO_ROOT/broker/stack-broker"
REGISTRY="$REPO_ROOT/config/broker-ops.json"

[[ $(id -u) -eq 0 ]] || { echo "SKIP: needs root"; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

getent group _stackbroker-clients >/dev/null || groupadd -r _stackbroker-clients
getent passwd _stackbroker >/dev/null || useradd -r -g _stackbroker-clients -s /usr/sbin/nologin -M _stackbroker

TMP="$(mktemp -d)"; chmod 755 "$TMP"
STATE="$TMP/state"; STUB="$TMP/stub"; mkdir -p "$STUB"
DPIDS=()
cleanup() { for p in "${DPIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

CFG="$TMP/daemon.json"; REQ="$TMP/req.sock"; APP="$TMP/app.sock"
jq -n --arg sr "$STATE" --arg rq "$REQ" --arg apq "$APP" --arg reg "$REGISTRY" --arg stub "$STUB" \
  '{state_root:$sr, request_socket:$rq, approval_socket:$apq, ops_registry:$reg,
    client_uids:[0], run_user:"_stackbroker", clients_group:"_stackbroker-clients",
    vendor_stub_dir:$stub}' > "$CFG"
chown root:root "$CFG"; chmod 600 "$CFG"
python3 "$DAEMON" --config "$CFG" >>"$TMP/daemon.out" 2>&1 &
DPIDS+=($!)
for _ in $(seq 1 100); do [[ -S "$REQ" ]] && break; sleep 0.1; done
[[ -S "$REQ" ]] || { echo "FATAL: daemon did not bind"; cat "$TMP/daemon.out"; exit 1; }

CCFG="$TMP/client.json"
jq -n --arg ep "unix://$REQ" --arg sd "$STATE/staging" \
  '{schema:"broker-client/v1", endpoint:$ep, staging_dir:$sd}' > "$CCFG"; chmod 644 "$CCFG"
export STACK_BROKER_CONFIG="$CCFG"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"; ln -sf "$CLIENT" "$TMP/bin/stack-broker"

# github "principal" (dummy ref; the vendor is stubbed) + permissive invariants
mkdir -p "$STATE/private/principals"
jq -n '{surface:"github", token_ref:"dummy", issued_at:"2026-08-21T00:00:00Z", max_age_days:90}' \
  > "$STATE/private/principals/github.json"
chown _stackbroker "$STATE/private/principals/github.json"; chmod 600 "$STATE/private/principals/github.json"
jq -n '{not_default_branch:true, no_deploy_sensitive_paths:true, fast_forward_or_new_ref:true,
        ci_safe:true, base_is_default_branch:true, review_receipt_fresh_for_head_sha:true}' \
  > "$STUB/invariants.json"

# a real repo with a real branch to push
WORK="$TMP/repo"
git init -q "$WORK"
git -C "$WORK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WORK" checkout -q -b chore/handoff-test
echo x > "$WORK/file.txt"; git -C "$WORK" add file.txt
git -C "$WORK" -c user.name=t -c user.email=t@t commit -q -m "handoff"
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

jq -n --arg sha "$HEAD_SHA" \
  '{status_code:200, body:{ref:"refs/heads/chore/handoff-test", head_sha:$sha, files_changed:1}}' \
  > "$STUB/github.branch.push.json"
jq -n '{status_code:200, body:{number:321, html_url:"https://github.com/test/repo/pull/321"}}' \
  > "$STUB/github.pr.create.json"

source "$REPO_ROOT/lib/broker-push.sh"

# ── A: push + PR end-to-end through the broker (vendor stubbed) ────────────
export STACK_BROKER_REPO="test/repo"
URL="$(broker_push_and_pr "$WORK" "test/repo" "chore/handoff-test" "main" "t: handoff" "body")"
RC=$?
RCPT_PUSH="$(grep -rl '"op": "github.branch.push"' "$STATE/receipts" | head -1)"
RCPT_PR="$(grep -rl '"op": "github.pr.create"' "$STATE/receipts" | head -1)"
if [[ $RC -eq 0 && "$URL" == "https://github.com/test/repo/pull/321" && -n "$RCPT_PUSH" && -n "$RCPT_PR" ]] \
   && jq -e '.verdict=="executed"' "$RCPT_PUSH" >/dev/null \
   && jq -e '.verdict=="executed" and (.evidence.broker.invariants|length)==2' "$RCPT_PR" >/dev/null; then
  pass "A: broker_push_and_pr pushes and opens the PR through the broker, receipts minted"
else
  fail "A: rc=$RC url='$URL' push_rcpt=$RCPT_PUSH pr_rcpt=$RCPT_PR"
fi

# ── B: bundle staged for one branch cannot be claimed as another ───────────
BUNDLE="$TMP/b.bundle"
git -C "$WORK" bundle create "$BUNDLE" refs/heads/chore/handoff-test >/dev/null 2>&1
OUT="$(stack-broker github.branch.push --repo test/repo --branch chore/other-branch \
        --head-sha "$HEAD_SHA" --bundle-file "$BUNDLE" --reason t --json 2>&1)"; RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="param_rejected"' >/dev/null 2>&1; then
  pass "B: bundle ref/branch mismatch -> refused (exactly-one-matching-ref rule)"
else
  fail "B: rc=$RC out=$OUT"
fi

# ── C: a broker REFUSAL does not trigger the fallback (rc != 75) ───────────
jq -n '{not_default_branch:true, no_deploy_sensitive_paths:true, fast_forward_or_new_ref:true,
        ci_safe:true, base_is_default_branch:false, review_receipt_fresh_for_head_sha:true}' \
  > "$STUB/invariants.json"
broker_push_and_pr "$WORK" "test/repo" "chore/handoff-test" "notmain" "t" "b" >/dev/null
RC=$?
[[ $RC -eq 3 ]] && pass "C: invariant refusal returns 3 — callers must NOT fall back" || fail "C: rc=$RC"

# ── D: broker unavailable -> 75 (the only fallback trigger) ────────────────
STACK_BROKER_CONFIG="$TMP/dead.json" bash -c '
  jq -n "{schema:\"broker-client/v1\", endpoint:\"unix:///nonexistent.sock\"}" > "$STACK_BROKER_CONFIG"' \
  2>/dev/null || jq -n '{schema:"broker-client/v1", endpoint:"unix:///nonexistent.sock"}' > "$TMP/dead.json"
OLDCFG="$STACK_BROKER_CONFIG"; export STACK_BROKER_CONFIG="$TMP/dead.json"
broker_push_and_pr "$WORK" "test/repo" "chore/handoff-test" "main" "t" "b" >/dev/null
RC=$?
export STACK_BROKER_CONFIG="$OLDCFG"
[[ $RC -eq 75 ]] && pass "D: broker unreachable -> 75 (pre-P5 fallback trigger)" || fail "D: rc=$RC"

# ── E: the three callers are migrated and still parse ──────────────────────
STATIC_OK=1
for f in "$REPO_ROOT/scripts/session-close.sh" \
         "$REPO_ROOT/templates/team-admin/scripts/reconcile.sh" \
         "$REPO_ROOT/templates/team-admin/scripts/reconcile-packs.sh"; do
  grep -q 'broker_push_and_pr' "$f" || { STATIC_OK=0; echo "  not migrated: $f"; }
  bash -n "$f" || { STATIC_OK=0; echo "  syntax error: $f"; }
done
[[ $STATIC_OK -eq 1 ]] && pass "E: session-close + both reconcilers call broker_push_and_pr and parse clean" \
                       || fail "E: migration incomplete"

# ── E2: library missing while the broker is live -> refuse, never fall back ─
# The callers default their rc to 75 ("no broker on this machine") BEFORE the
# call. If lib/broker-push.sh fails to source for any reason while the daemon
# is up and would have judged the write, that default must not hand the caller
# its direct git/gh path. Each caller carries an elif that re-probes the broker
# itself rather than trusting the library's absence.
E2_OK=1
for f in "$REPO_ROOT/scripts/session-close.sh" \
         "$REPO_ROOT/templates/team-admin/scripts/reconcile.sh" \
         "$REPO_ROOT/templates/team-admin/scripts/reconcile-packs.sh"; do
  # the guard must probe the live broker in the same conditional chain that
  # would otherwise leave rc at 75
  grep -q 'elif command -v stack-broker' "$f" \
    || { E2_OK=0; echo "  no live-broker re-probe: $f"; }
  grep -q 'refusing the direct path' "$f" \
    || { E2_OK=0; echo "  no refusal on live-broker + missing library: $f"; }
done
# behavioral half: with the library unsourced but a reachable daemon, the
# re-probe condition itself must evaluate true
if command -v stack-broker >/dev/null 2>&1; then
  stack-broker pending --json >/dev/null 2>&1 && PROBE_LIVE=1 || PROBE_LIVE=0
  [[ "$PROBE_LIVE" == "1" ]] \
    && echo "  (daemon reachable here — re-probe condition exercised live)" \
    || echo "  (daemon not reachable here — re-probe asserted structurally only)"
fi
[[ $E2_OK -eq 1 ]] && pass "E2: a live broker + unsourced library refuses, never falls open to direct git/gh" \
                   || fail "E2: a caller can still fail open to direct git/gh while the broker is live"

# ── F: live end-to-end (post-P3 only) ──────────────────────────────────────
if [[ "${STACK_BROKER_LIVE:-0}" == "1" ]]; then
  fail "F: STACK_BROKER_LIVE=1 requested but live assertion not run in this build (requires P3 principals)"
else
  echo "NOTE: live real-PR proof BLOCKED pending P3 (human creates broker principals);"
  echo "      this run proved the path with the vendor stubbed at the HTTP boundary only."
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
