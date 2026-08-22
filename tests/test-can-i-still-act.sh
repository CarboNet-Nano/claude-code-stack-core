#!/usr/bin/env bash
# Tests for scripts/can-i-still-act.sh (D18 P0) and the credential-inventory
# no-value-leak rule. The classification cases run against a local stub HTTP
# server so no vendor is touched and every status transition is deterministic.
#
# The load-bearing case is 1: a stubbed 500 must classify UNKNOWN, never
# DENIED — a server error is not evidence the credential is dead (ADR-085).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/can-i-still-act.sh"
INV="$REPO_ROOT/scripts/credential-inventory.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
STUB_PID=""
trap '[[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Stub server: path decides the status code ──────────────────────────────
# /s500 -> 500, /a401 -> 401, /a403 -> 403, /ok -> 200
python3 - "$TMP/port" <<'PY' &
import http.server, socketserver, sys, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = {"/s500": 500, "/a401": 401, "/a403": 403, "/ok": 200}.get(self.path, 404)
        self.send_response(code)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    with open(sys.argv[1], "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
STUB_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"
[[ -n "$PORT" ]] || { echo "FATAL: stub server did not start" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT"

mkconf() { # mkconf <name> <url1> <url2>
  jq -n --arg u1 "$2" --arg u2 "$3" \
    '{surfaces:[{surface:"stub", class:"write",
                 endpoints:[{url:$u1, auth:"none"},{url:$u2, auth:"none"}]}]}' \
    > "$TMP/$1.json"
}

run_probe() { # run_probe <conf> [extra args...] -> status of surface "stub"
  local conf="$1"; shift
  STACK_PROBE_CONFIG="$TMP/$conf.json" STACK_PROBE_BACKOFF_MS=10 STACK_PROBE_TIMEOUT_S=5 \
    bash "$SCRIPT" --json "$@" | jq -r '.surfaces[0].status'
}

# ── 1: stubbed 500 -> UNKNOWN, never DENIED ────────────────────────────────
mkconf s500 "$BASE/s500" "$BASE/s500"
ST="$(run_probe s500)"
[[ "$ST" == "UNKNOWN" ]] && pass "1: 500 -> UNKNOWN" || fail "1: 500 gave $ST (must be UNKNOWN, never DENIED)"

# ── 2: two endpoints both auth-class -> DENIED_BY_AUTH ─────────────────────
mkconf auth "$BASE/a401" "$BASE/a403"
ST="$(run_probe auth)"
[[ "$ST" == "DENIED_BY_AUTH" ]] && pass "2: 401+403 on 2 endpoints -> DENIED_BY_AUTH" || fail "2: got $ST"

# ── 3: one auth + one 500 -> UNKNOWN (single endpoint is not enough) ───────
mkconf mixed "$BASE/a401" "$BASE/s500"
ST="$(run_probe mixed)"
[[ "$ST" == "UNKNOWN" ]] && pass "3: 401+500 mixed -> UNKNOWN" || fail "3: got $ST"

# ── 4: any 200 -> REACHABLE ────────────────────────────────────────────────
mkconf ok "$BASE/ok" "$BASE/a401"
ST="$(run_probe ok)"
[[ "$ST" == "REACHABLE" ]] && pass "4: 200 anywhere -> REACHABLE" || fail "4: got $ST"

# ── 5: connection refused on both -> DENIED_BY_SANDBOX ─────────────────────
DEAD_PORT=1
mkconf refused "http://127.0.0.1:$DEAD_PORT/x" "http://127.0.0.1:$DEAD_PORT/y"
ST="$(run_probe refused)"
[[ "$ST" == "DENIED_BY_SANDBOX" ]] && pass "5: connect refused -> DENIED_BY_SANDBOX" || fail "5: got $ST"

# ── 6: --expect matching and non-matching exit codes ───────────────────────
if STACK_PROBE_CONFIG="$TMP/auth.json" STACK_PROBE_BACKOFF_MS=10 STACK_PROBE_TIMEOUT_S=5 \
     bash "$SCRIPT" --json --expect denied_by_auth >/dev/null; then
  pass "6a: --expect denied_by_auth exits 0 on match"
else
  fail "6a: --expect denied_by_auth should exit 0"
fi
if STACK_PROBE_CONFIG="$TMP/auth.json" STACK_PROBE_BACKOFF_MS=10 STACK_PROBE_TIMEOUT_S=5 \
     bash "$SCRIPT" --json --expect reachable >/dev/null; then
  fail "6b: --expect reachable should exit 1 on mismatch"
else
  pass "6b: --expect mismatch exits 1"
fi

# ── 7: --surface filters; unknown surface probes nothing and --expect fails ─
N="$(STACK_PROBE_CONFIG="$TMP/ok.json" STACK_PROBE_BACKOFF_MS=10 bash "$SCRIPT" --json --surface nope | jq '.surfaces|length')"
[[ "$N" == "0" ]] && pass "7a: --surface filter excludes non-matching" || fail "7a: got $N surfaces"
if STACK_PROBE_CONFIG="$TMP/ok.json" STACK_PROBE_BACKOFF_MS=10 bash "$SCRIPT" --json --surface nope --expect reachable >/dev/null; then
  fail "7b: zero probed surfaces must fail --expect (never-run is UNKNOWN, not a pass)"
else
  pass "7b: zero probed surfaces fails --expect"
fi

# ── 8: retry on network error happens (attempts > 1 on refused) ────────────
AT="$(STACK_PROBE_CONFIG="$TMP/refused.json" STACK_PROBE_BACKOFF_MS=10 STACK_PROBE_TIMEOUT_S=5 \
  bash "$SCRIPT" --json | jq '.surfaces[0].endpoints[0].attempts')"
[[ "$AT" == "3" ]] && pass "8: network error retried twice (3 attempts)" || fail "8: attempts=$AT, expected 3"

# ── 9: inventory never prints a value: plant a token, expect last-4 only ───
PLANT_ROOT="$TMP/plantroot"; mkdir -p "$PLANT_ROOT"
# assembled at runtime so the mirror scrub-guard's secret-shape grep never
# matches this file's own source
FAKE="ghp_$(printf 'FAKE%.0s' 1 2 3 4 5 6 7 8)ZZ99"
printf 'export GH_TOKEN=%s\n' "$FAKE" > "$PLANT_ROOT/.envrc"
jq -n --arg r "$PLANT_ROOT" '{schema:"broker-inventory/v1", scan_roots:[$r]}' > "$TMP/inv.json"
OUT="$(HOME="$TMP/nohome" STACK_INVENTORY_CONFIG="$TMP/inv.json" bash "$INV" --json 2>/dev/null)"
if echo "$OUT" | grep -q "$FAKE"; then
  fail "9a: inventory output leaked a planted token value"
else
  pass "9a: planted token value absent from output"
fi
if echo "$OUT" | jq -e '[.findings[] | select(.kind=="env-file-assignment" and (.note|contains("GH_TOKEN")))] | length >= 1' >/dev/null; then
  pass "9b: planted assignment is reported (location 2)"
else
  fail "9b: planted GH_TOKEN assignment not reported"
fi

# ── 10: inventory principals object always carries the five surfaces ───────
if echo "$OUT" | jq -e '.principals | has("github") and has("cloudflare") and has("neon") and has("supabase") and has("netlify")' >/dev/null; then
  pass "10: principals enumerates all five surfaces"
else
  fail "10: principals missing a surface key"
fi

# ── 11: undeclared scan root is reported not-scanned, never clean ──────────
jq -n '{schema:"broker-inventory/v1", scan_roots:["/nonexistent/declared/root"]}' > "$TMP/inv2.json"
OUT2="$(HOME="$TMP/nohome" STACK_INVENTORY_CONFIG="$TMP/inv2.json" bash "$INV" --json 2>/dev/null)"
if echo "$OUT2" | jq -e '.scan_roots[0].scanned == false' >/dev/null; then
  pass "11: missing declared root -> scanned:false, never silently clean"
else
  fail "11: missing declared root not reported as unscanned"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
