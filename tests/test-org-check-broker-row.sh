#!/usr/bin/env bash
# tests/test-org-check-broker-row.sh — D18 P4 step 6: the org-check Broker row.
#   - absent where the broker is not installed (pre-D18 machines unchanged)
#   - ❌ daemon down / approval-channel broken / a broker-only surface directly
#     reachable
#   - ⚠️ pending approvals
#   - ✅ otherwise
# Asserted through org-check's --json output (.checks[] id=="broker").

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG_CHECK="$REPO_ROOT/scripts/org-check.sh"
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
DPIDS=()
cleanup() { for p in "${DPIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# a client config whose uid is ROOT so org-check (running as root here) is a
# legal request-socket client
STATE="$TMP/state"; REQ="$TMP/req.sock"; APP="$TMP/app.sock"
CFG="$TMP/daemon-config.json"
jq -n --arg sr "$STATE" --arg rq "$REQ" --arg apq "$APP" --arg reg "$REGISTRY" \
  '{state_root:$sr, request_socket:$rq, approval_socket:$apq, ops_registry:$reg,
    client_uids:[0], run_user:"_stackbroker", clients_group:"_stackbroker-clients"}' > "$CFG"
chown root:root "$CFG"; chmod 600 "$CFG"

CCFG="$TMP/client.json"
jq -n --arg ep "unix://$REQ" '{schema:"broker-client/v1", endpoint:$ep}' > "$CCFG"; chmod 644 "$CCFG"

# probe stub: both endpoints refuse connection -> DENIED_BY_SANDBOX
PROBE_DENIED="$TMP/probe-denied.json"
jq -n '{surfaces:[
  {surface:"cloudflare", class:"write", endpoints:[{url:"http://127.0.0.1:1/x",auth:"none"},{url:"http://127.0.0.1:1/y",auth:"none"}]},
  {surface:"neon", class:"write", endpoints:[{url:"http://127.0.0.1:1/x",auth:"none"},{url:"http://127.0.0.1:1/y",auth:"none"}]}]}' > "$PROBE_DENIED"

broker_row() { # broker_row <extra env...> — prints "status reason" or "ABSENT"
  local out
  out="$(env "$@" bash "$ORG_CHECK" --json 2>/dev/null \
    | jq -r '[.checks[] | select(.id=="broker")] | if length==0 then "ABSENT" else "\(.[0].status) \(.[0].reason // "-")" end' 2>/dev/null)"
  echo "${out:-ERROR}"
}

COMMON=(STACK_BROKER_CONFIG="$CCFG" STACK_PROBE_CONFIG="$PROBE_DENIED" STACK_PROBE_BACKOFF_MS=10)

# ── 1: broker not installed -> no row ──────────────────────────────────────
R="$(broker_row "${COMMON[@]}" STACK_BROKER_SYSTEM_CONFIG=/nonexistent/broker.json)"
[[ "$R" == "ABSENT" ]] && pass "1: no system config -> row absent" || fail "1: got '$R'"

# ── 2: daemon down -> fail daemon-down ─────────────────────────────────────
R="$(broker_row "${COMMON[@]}" STACK_BROKER_SYSTEM_CONFIG="$CFG")"
[[ "$R" == "fail daemon-down" ]] && pass "2: daemon down -> ❌ daemon-down" || fail "2: got '$R'"

# start the daemon for the remaining cases
python3 "$DAEMON" --config "$CFG" >>"$TMP/daemon.out" 2>&1 &
DPIDS+=($!)
for _ in $(seq 1 100); do [[ -S "$REQ" ]] && break; sleep 0.1; done
[[ -S "$REQ" ]] || { echo "FATAL: daemon did not bind"; exit 1; }

# ── 3: approval channel broken -> fail approval-channel ────────────────────
R="$(broker_row "${COMMON[@]}" STACK_BROKER_SYSTEM_CONFIG="$CFG" \
      STACK_VERIFY_HELPER=/nonexistent/helper)"
[[ "$R" == "fail approval-channel" ]] && pass "3: verify fails -> ❌ approval-channel" || fail "3: got '$R'"

# ── 4: a surface directly reachable -> fail direct-path-open ───────────────
PORTF="$TMP/port"
python3 - "$PORTF" <<'PY' &
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length","2"); self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    open(sys.argv[1], "w").write(str(srv.server_address[1]))
    srv.serve_forever()
PY
DPIDS+=($!)
for _ in $(seq 1 50); do [[ -s "$PORTF" ]] && break; sleep 0.1; done
PORT="$(cat "$PORTF")"
PROBE_OPEN="$TMP/probe-open.json"
jq -n --arg u "http://127.0.0.1:$PORT/ok" '{surfaces:[
  {surface:"cloudflare", class:"write", endpoints:[{url:$u,auth:"none"},{url:$u,auth:"none"}]},
  {surface:"neon", class:"write", endpoints:[{url:"http://127.0.0.1:1/x",auth:"none"},{url:"http://127.0.0.1:1/y",auth:"none"}]}]}' > "$PROBE_OPEN"
R="$(broker_row STACK_BROKER_CONFIG="$CCFG" STACK_PROBE_CONFIG="$PROBE_OPEN" \
      STACK_PROBE_BACKOFF_MS=10 STACK_BROKER_SYSTEM_CONFIG="$CFG")"
[[ "$R" == "fail direct-path-open" ]] && pass "4: surface reachable -> ❌ direct-path-open" || fail "4: got '$R'"

# ── 5: pending approvals -> warn ───────────────────────────────────────────
ACC="00000000000000000000000000000000"
BSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
env STACK_BROKER_CONFIG="$CCFG" STACK_BROKER_REPO=test/repo python3 "$CLIENT" \
  cloudflare.worker.deploy --account-id "$ACC" --worker w --bundle-sha "$BSHA" \
  --reason pending-row-test --json >/dev/null 2>&1
R="$(broker_row "${COMMON[@]}" STACK_BROKER_SYSTEM_CONFIG="$CFG")"
[[ "$R" == "warn pending-approvals" ]] && pass "5: pending approval -> ⚠️ pending-approvals" || fail "5: got '$R'"

# clear the pending queue by expiring it server-side
for f in "$STATE"/private/pending/*.json; do
  [[ -f "$f" ]] || continue
  python3 - "$f" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); p["created_at"] -= 10000
json.dump(p, open(sys.argv[1], "w"))
PY
done

# ── 6: everything good -> ok ───────────────────────────────────────────────
R="$(broker_row "${COMMON[@]}" STACK_BROKER_SYSTEM_CONFIG="$CFG")"
[[ "$R" == "ok -" ]] && pass "6: all good -> ✅" || fail "6: got '$R'"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
