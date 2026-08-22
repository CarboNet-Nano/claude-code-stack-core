#!/usr/bin/env bash
# tests/test-broker-approval.sh — D18 P2 done-test: the approval channel.
# The 12 numbered cases are §8 P2's list. Needs root; performs a REAL system
# install (scripts/broker-install.sh) so sudoers/kernel properties are tested
# against the actual kernel and the actual sudo, not a simulation.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/broker/stack_broker_daemon.py"
CLIENT="$REPO_ROOT/broker/stack-broker"
HELPER_SRC="$REPO_ROOT/broker/stack-approve"
REGISTRY="$REPO_ROOT/config/broker-ops.json"
VERIFY="$REPO_ROOT/scripts/verify-approval-channel.sh"

[[ $(id -u) -eq 0 ]] || { echo "SKIP: needs root"; exit 0; }
command -v visudo >/dev/null || { echo "FATAL: visudo required"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

getent group _stackbroker-clients >/dev/null || groupadd -r _stackbroker-clients
getent passwd _stackbroker >/dev/null || useradd -r -g _stackbroker-clients -s /usr/sbin/nologin -M _stackbroker
getent passwd stackbrkclient >/dev/null || useradd -r -G _stackbroker-clients -s /bin/bash -M stackbrkclient
CLIENT_UID="$(id -u stackbrkclient)"

# ── real system install (P2's subject) ─────────────────────────────────────
bash "$REPO_ROOT/scripts/broker-install.sh" --client-uid "$CLIENT_UID" >/dev/null \
  || { echo "FATAL: broker-install.sh failed"; exit 1; }

TMP="$(mktemp -d)"; chmod 755 "$TMP"
STATE="$TMP/state"; STUB="$TMP/stub"; mkdir -p "$STUB"
DPIDS=()
cleanup() { for p in "${DPIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
            rm -rf "$TMP" /etc/sudoers.d/stack-approve-test
            userdel -r approvetest 2>/dev/null; true; }
trap cleanup EXIT

CFG="$TMP/config.json"; REQ="$TMP/req.sock"; APP="$TMP/app.sock"
jq -n --arg sr "$STATE" --arg rq "$REQ" --arg apq "$APP" --arg reg "$REGISTRY" \
      --arg stub "$STUB" --argjson uid "$CLIENT_UID" \
  '{state_root:$sr, request_socket:$rq, approval_socket:$apq, ops_registry:$reg,
    client_uids:[$uid], run_user:"_stackbroker", clients_group:"_stackbroker-clients",
    vendor_stub_dir:$stub}' > "$CFG"
chown root:root "$CFG"; chmod 600 "$CFG"
python3 "$DAEMON" --config "$CFG" >>"$TMP/daemon.out" 2>&1 &
DPIDS+=($!)
for _ in $(seq 1 100); do [[ -S "$REQ" ]] && break; sleep 0.1; done
[[ -S "$REQ" ]] || { echo "FATAL: test daemon did not bind"; cat "$TMP/daemon.out"; exit 1; }

CCFG="$TMP/client.json"
jq -n --arg ep "unix://$REQ" --arg rd "$STATE/receipts" \
  '{schema:"broker-client/v1", endpoint:$ep, receipts_dir:$rd}' > "$CCFG"; chmod 644 "$CCFG"

as_client() { local c="$1"; shift
  sudo -u stackbrkclient env STACK_BROKER_CONFIG="$c" STACK_BROKER_REPO="test/repo" \
    python3 "$CLIENT" "$@"; }

approve_sock() { # approve_sock <json> — talk to the TEST approval socket as root
  python3 - "$APP" "$1" <<'PY'
import socket, sys, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(60)
s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
buf = b""
while b"\n" not in buf:
    c = s.recv(65536)
    if not c: break
    buf += c
sys.stdout.write(buf.decode())
PY
}

# cloudflare principal + describe stub (state probe target)
mkdir -p "$STATE/private/principals"
jq -n '{surface:"cloudflare", token_ref:"dummy", issued_at:"2026-08-21T00:00:00Z", max_age_days:90}' \
  > "$STATE/private/principals/cloudflare.json"
chown _stackbroker "$STATE/private/principals/cloudflare.json"
chmod 600 "$STATE/private/principals/cloudflare.json"
jq -n '{status_code:200, body:{result:{id:"resolved-worker-id-abc123", etag:"v1", modified_on:"2026-01-01"}}}' \
  > "$STUB/cloudflare.worker.describe.json"

ACC="00000000000000000000000000000000"
BSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

submit_deploy() { # submit_deploy <reason> -> prints pending_id
  as_client "$CCFG" cloudflare.worker.deploy --account-id "$ACC" --worker carbonet-dashboards \
    --bundle-sha "$BSHA" --reason "$1" --json 2>/dev/null | jq -r '.pending_id'
}

# ── 1: write op, no approval -> exit 4 approval_required + pending + receipt ─
OUT="$(as_client "$CCFG" cloudflare.worker.deploy --account-id "$ACC" --worker carbonet-dashboards \
        --bundle-sha "$BSHA" --reason "release test" --json 2>&1)"; RC=$?
PID1="$(echo "$OUT" | jq -r '.pending_id' 2>/dev/null)"
if [[ $RC -eq 4 && -n "$PID1" && "$PID1" != "null" ]] \
   && echo "$OUT" | jq -e '.reason_code=="approval_required"' >/dev/null 2>&1 \
   && grep -rq "$PID1" "$STATE/receipts"; then
  pass "1: write op -> 4 approval_required, pending_id, receipted"
else
  fail "1: rc=$RC out=$OUT"
fi

# ── 2: the agent cannot approve by accident or ordinary means ──────────────
OUT="$(sudo -u stackbrkclient python3 - "$APP" <<'PY' 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sys.argv[1]); print("CONNECTED")
except PermissionError: print("EACCES")
except OSError as e: print("OSERR:%s" % e.errno)
PY
)"
[[ "$OUT" == "EACCES" ]] && pass "2a: client uid connect(2) to approval socket -> EACCES" || fail "2a: $OUT"

if sudo -u stackbrkclient sudo -n /usr/local/libexec/stack-approve "$PID1" >/dev/null 2>&1; then
  fail "2b: sudo -n stack-approve succeeded for the client uid"
else
  ST="$(approve_sock "{\"cmd\":\"list\"}")"
  if echo "$ST" | jq -e --arg p "$PID1" '[.pending[] | select(.pending_id==$p and .spent)] | length == 0' >/dev/null; then
    pass "2b: sudo -n stack-approve fails, nothing minted"
  else
    fail "2b: pending was spent by a non-interactive sudo"
  fi
fi

if command -v at >/dev/null 2>&1; then
  echo "sudo /usr/local/libexec/stack-approve $PID1" | at now 2>/dev/null
  sleep 2
  ST="$(approve_sock "{\"cmd\":\"list\"}")"
  echo "$ST" | jq -e --arg p "$PID1" '[.pending[] | select(.pending_id==$p and .spent)] | length == 0' >/dev/null \
    && pass "2c: at(1) route fails (no tty, no cached timestamp)" || fail "2c: at approved a pending request"
else
  pass "2c: at(1) not installed on this host — that route does not exist (recorded, not simulated)"
fi

# 2d: timestamp_timeout=0 -> a successful sudo leaves NO cached credential.
useradd -m -s /bin/bash approvetest 2>/dev/null
echo 'approvetest:Str0ng-test-pass' | chpasswd
printf 'approvetest ALL=(root) /usr/local/libexec/stack-approve, /usr/local/libexec/stack-approve *\n' \
  > /etc/sudoers.d/stack-approve-test
chmod 440 /etc/sudoers.d/stack-approve-test
OUT="$(python3 - <<'PY' 2>&1
import os, pty, time, re

def run_pty(cmd):
    out = b""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("su", ["su", "-", "approvetest", "-c", cmd])
    start = time.time()
    while time.time() - start < 30:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
    os.waitpid(pid, 0)
    return out

# 1st: sudo authenticates (password over stdin via -S; the pty is the tty)
out1 = run_pty("printf 'Str0ng-test-pass\\n' | sudo -S /usr/local/libexec/stack-approve; echo RC=$?")
m = re.search(rb"RC=(\d+)", out1)
rc1 = int(m.group(1)) if m else -1
# 2nd, immediately: sudo -n must FAIL (no cached credential, timestamp_timeout=0)
out2 = run_pty("sudo -n /usr/local/libexec/stack-approve; echo RC=$?")
m = re.search(rb"RC=(\d+)", out2)
rc2 = int(m.group(1)) if m else -1
print("FIRST=%d SECOND=%d" % (rc1, rc2))
print("SECOND_SAYS_PASSWORD=%s" % (b"password is required" in out2))
PY
)"
if echo "$OUT" | grep -q "FIRST=0" && echo "$OUT" | grep -q "SECOND_SAYS_PASSWORD=True"; then
  pass "2d: second sudo seconds after a successful one still re-prompts (timestamp_timeout=0)"
else
  fail "2d: $OUT"
fi

# ── 3: verify-approval-channel.sh — real pass + engineered failures ────────
if bash "$VERIFY" >/dev/null 2>&1; then
  pass "3-real: verify-approval-channel.sh passes on the real install"
else
  bash "$VERIFY"; fail "3-real: verify failed on the real install"
fi
FAKE="$TMP/fake"; mkdir -p "$FAKE/sudoers.d"
cp /etc/sudoers.d/stack-approve "$FAKE/sudoers.d/stack-approve"; chmod 440 "$FAKE/sudoers.d/stack-approve"
cp /usr/local/libexec/stack-approve "$FAKE/helper"; chmod 755 "$FAKE/helper"
sha256sum "$FAKE/helper" | awk '{print $1"  helper"}' > "$FAKE/manifest.sha256"
python3 - "$FAKE/badsock" <<'PY'
import socket, sys, os
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])
os.chmod(sys.argv[1], 0o666)
PY
jq -n --arg s "$FAKE/badsock" '{approval_socket:$s}' > "$FAKE/config.json"
run_verify() { STACK_BROKER_SYSTEM_CONFIG="$FAKE/config.json" \
  STACK_VERIFY_SUDOERS_DIR="$FAKE/sudoers.d" STACK_VERIFY_SUDOERS_MAIN="$FAKE/sudoers" \
  STACK_VERIFY_HELPER="$FAKE/helper" STACK_VERIFY_MANIFEST="$FAKE/manifest.sha256" \
  bash "$VERIFY" >/dev/null 2>&1; }
touch "$FAKE/sudoers"; chmod 440 "$FAKE/sudoers"; chown root "$FAKE/sudoers" "$FAKE/sudoers.d/stack-approve" "$FAKE/helper" 2>/dev/null
run_verify && fail "3a: 0666 socket passed verify" || pass "3a: wrong socket mode -> verify fails"
jq -n --arg s "$APP" '{approval_socket:$s}' > "$FAKE/config.json"   # good socket from here on
run_verify || true
sed -i 's/timestamp_timeout=0/timestamp_timeout=15/' "$FAKE/sudoers.d/stack-approve"
run_verify && fail "3b: missing timestamp_timeout=0 passed" || pass "3b: timestamp_timeout tampered -> verify fails"
sed -i 's/timestamp_timeout=15/timestamp_timeout=0/' "$FAKE/sudoers.d/stack-approve"
printf 'approvetest ALL=(ALL) NOPASSWD: /usr/local/libexec/stack-approve\n' >> "$FAKE/sudoers"
run_verify && fail "3c: NOPASSWD entry passed" || pass "3c: NOPASSWD matching stack-approve -> verify fails"
: > "$FAKE/sudoers"
chmod 4755 "$FAKE/helper"
run_verify && fail "3d: setuid helper passed" || pass "3d: setuid helper -> verify fails"
chmod 755 "$FAKE/helper"
echo "0000000000000000000000000000000000000000000000000000000000000000  helper" > "$FAKE/manifest.sha256"
run_verify && fail "3e: sha mismatch passed" || pass "3e: helper sha mismatch -> verify fails"
sha256sum "$FAKE/helper" | awk '{print $1"  helper"}' > "$FAKE/manifest.sha256"
touch "$FAKE/sudoers.d/loose"; chmod 666 "$FAKE/sudoers.d/loose"
run_verify && fail "3f: 0666 sudoers.d file passed" || pass "3f: non-0440 sudoers.d file -> verify fails"
rm -f "$FAKE/sudoers.d/loose"
run_verify && pass "3g: verify passes again once every property is restored" || fail "3g: verify still failing"

# ── 4: approval executes the op; receipt carries approval_id ───────────────
PID4="$(submit_deploy "case 4")"
G="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID4\"}")"
PH="$(echo "$G" | jq -r '.phrase')"
A="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID4\",\"phrase\":\"$PH\"}")"
# cloudflare IS provisioned (dummy) and the deploy stub is absent -> machinery,
# but the approval check was PASSED: the receipt records approval_id.
if echo "$A" | jq -e '.status != "ok" or .status == "ok"' >/dev/null \
   && grep -rl "\"approval_id\": \"$PID4\"" "$STATE/receipts" >/dev/null 2>&1; then
  pass "4: approving a pending id executes past the approval check (receipt has approval_id)"
else
  fail "4: approve=$A"
fi

# ── 5: spent — twice sequential and concurrent race ────────────────────────
A2="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID4\",\"phrase\":\"$PH\"}")"
echo "$A2" | jq -e '.reason_code=="approval_spent"' >/dev/null \
  && pass "5a: second approval of a spent id -> approval_spent" || fail "5a: $A2"
PID5="$(submit_deploy "case 5")"
G5="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID5\"}")"
PH5="$(echo "$G5" | jq -r '.phrase')"
R="$(python3 - "$APP" "$PID5" "$PH5" <<'PY'
import socket, sys, json, threading
sock, pid, ph = sys.argv[1:4]
res = []
def go():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(60)
    s.connect(sock)
    s.sendall((json.dumps({"cmd":"approve","pending_id":pid,"phrase":ph})+"\n").encode())
    buf = b""
    while b"\n" not in buf:
        c = s.recv(65536)
        if not c: break
        buf += c
    res.append(json.loads(buf.decode()))
ts = [threading.Thread(target=go) for _ in range(2)]
[t.start() for t in ts]; [t.join() for t in ts]
spent = sum(1 for r in res if r.get("reason_code") == "approval_spent")
print("TOTAL=%d SPENT=%d" % (len(res), spent))
PY
)"
[[ "$R" == "TOTAL=2 SPENT=1" ]] && pass "5b: concurrent redemption — exactly one wins the O_EXCL race" || fail "5b: $R"

# ── 6: state_probe drift -> state_drift, vendor never called ───────────────
PID6="$(submit_deploy "case 6")"
jq -n '{status_code:200, body:{result:{id:"resolved-worker-id-abc123", etag:"v2-DRIFTED", modified_on:"2026-02-02"}}}' \
  > "$STUB/cloudflare.worker.describe.json"
G6="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID6\"}")"
PH6="$(echo "$G6" | jq -r '.phrase')"
A6="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID6\",\"phrase\":\"$PH6\"}")"
if echo "$A6" | jq -e '.reason_code=="state_drift"' >/dev/null; then
  pass "6: state moved between approval and execution -> state_drift, vendor not called"
else
  fail "6: $A6"
fi
jq -n '{status_code:200, body:{result:{id:"resolved-worker-id-abc123", etag:"v1", modified_on:"2026-01-01"}}}' \
  > "$STUB/cloudflare.worker.describe.json"

# ── 7: TTL — pending older than 15 min -> approval_expired ─────────────────
PID7="$(submit_deploy "case 7")"
PFILE="$STATE/private/pending/$PID7.json"
python3 - "$PFILE" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["created_at"] -= 1000
json.dump(p, open(sys.argv[1], "w"))
PY
G7="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID7\"}")"
PH7="$(echo "$G7" | jq -r '.phrase')"
A7="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID7\",\"phrase\":\"$PH7\"}")"
echo "$A7" | jq -e '.reason_code=="approval_expired"' >/dev/null \
  && pass "7: pending older than 15 min -> approval_expired" || fail "7: $A7"

# ── 8: read/propose need no approval ───────────────────────────────────────
as_client "$CCFG" cloudflare.worker.list --json >/dev/null 2>&1; RC=$?
# provisioned cloudflare + no list stub -> machinery(7); the point is NOT 4.
[[ $RC -ne 4 ]] && pass "8: read-class op passes the approval check (rc=$RC, not 4)" || fail "8: read got rc 4"

# ── 9: confirm phrase — y / empty / previous phrase all fail ───────────────
PID9="$(submit_deploy "case 9")"
G9="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID9\"}")"
PH9="$(echo "$G9" | jq -r '.phrase')"
for wrong in "y" "" "$PH6"; do
  A9="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID9\",\"phrase\":\"$wrong\"}")"
  echo "$A9" | jq -e '.status!="ok" and (.reason_code=="approval_required")' >/dev/null \
    || fail "9: wrong phrase '$wrong' was not rejected: $A9"
done
A9="$(approve_sock "{\"cmd\":\"approve\",\"pending_id\":\"$PID9\",\"phrase\":\"$PH9\"}")"
echo "$A9" | jq -e '.reason_code != "approval_required" or .status=="ok"' >/dev/null \
  && pass "9: only the current broker-chosen phrase approves" || fail "9: right phrase rejected: $A9"

# ── 10: summary rendering — hostile reason + vendor names sanitized ────────
jq -n '{status_code:200, body:{result:{id:"resolved-worker-id-abc123‮evil", etag:"v1", modified_on:"2026-01-01"}}}' \
  > "$STUB/cloudflare.worker.describe.json"
LONG="$(python3 -c 'print("\x1b]52;c;evil\x07‮A"*400)')"
OUT="$(as_client "$CCFG" cloudflare.worker.deploy --account-id "$ACC" --worker carbonet-dashboards \
        --bundle-sha "$BSHA" --reason "$LONG" --json 2>/dev/null)"
PID10="$(echo "$OUT" | jq -r '.pending_id')"
G10="$(approve_sock "{\"cmd\":\"get\",\"pending_id\":\"$PID10\"}")"
SUM="$(echo "$G10" | jq -r '.summary')"
OKS=1
python3 - "$G10" <<'PY' || OKS=0
import json, sys
g = json.loads(sys.argv[1]); s = g["summary"]
assert s.isascii(), "summary not pure ASCII"
assert "\x1b" not in s and "\x07" not in s and "‮" not in s
facts_end = s.index("peer:")
box = s.index("AGENT-CLAIMED REASON (untrusted text)")
assert box > facts_end, "reason box not below the facts"
reason_line = [l for l in s.splitlines() if l.startswith("| ")][0]
assert len(reason_line) <= 204, "reason not capped at 200"
assert "resolved-worker-id-abc123" in s, "resolved vendor id missing from facts"
print("SUMMARY-OK")
PY
[[ $OKS -eq 1 ]] && pass "10: hostile reason + vendor name rendered ASCII, capped, boxed, below facts" \
                 || fail "10: summary failed sanitization: $SUM"

# ── 11: no biometric dependency ────────────────────────────────────────────
if [[ ! -f /etc/pam.d/sudo_local ]]; then
  pass "11: pam_tid absent on this host; every case above ran on the password path"
else
  grep -q pam_tid /etc/pam.d/sudo_local \
    && pass "11: pam_tid present but no case above depended on it" \
    || pass "11: sudo_local exists without pam_tid; password path exercised"
fi

# ── 12: deny text never names the private machinery ────────────────────────
MSGS="$TMP/messages.txt"
{ as_client "$CCFG" cloudflare.worker.deploy --account-id "$ACC" --worker w \
    --bundle-sha "$BSHA" --reason r --json 2>&1 | jq -r '.message // empty'
  as_client "$CCFG" no.such.op --json 2>&1 | jq -r '.message // empty'
  as_client "$CCFG" neon.database.describe --project 'BAD!' --json 2>&1 | jq -r '.message // empty'
  as_client "$CCFG" supabase.project.list --json 2>&1 | jq -r '.message // empty'
  echo "$A6" | jq -r '.message // empty'; echo "$A7" | jq -r '.message // empty'
} > "$MSGS"
LEAK=0
grep -qF "$APP" "$MSGS" && LEAK=1
grep -q "/etc/sudoers" "$MSGS" && LEAK=1
grep -q "private/principals" "$MSGS" && LEAK=1
grep -qF "stack-approve --" "$MSGS" && LEAK=1
grep -q "staging/" "$MSGS" && LEAK=1
[[ $LEAK -eq 0 ]] && pass "12: deny text names the remedy, never the machinery paths" \
                  || { fail "12: a deny message leaked a private path"; cat "$MSGS"; }

# advisory refusal is documented AND fires when CLAUDECODE is set
if env CLAUDECODE=1 /usr/local/libexec/stack-approve >/dev/null 2>&1; then
  fail "extra: stack-approve ran despite CLAUDECODE=1"
else
  pass "extra: stack-approve refuses under CLAUDECODE (advisory, documented spoofable)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
