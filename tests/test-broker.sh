#!/usr/bin/env bash
# tests/test-broker.sh — D18 P1 done-test: daemon, request socket, op registry,
# receipts — no principals yet. The 15 numbered cases are §8 P0->P1's list.
#
# Needs root (creates the _stackbroker user, binds sockets, checks kernel
# ACLs from a second, unprivileged user). Everything happens under a mktemp
# state root; system users are created if absent and left in place.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/broker/stack_broker_daemon.py"
CLIENT="$REPO_ROOT/broker/stack-broker"
REGISTRY="$REPO_ROOT/config/broker-ops.json"

[[ $(id -u) -eq 0 ]] || { echo "SKIP: test-broker.sh needs root (kernel-ACL assertions)"; exit 0; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── users/groups ───────────────────────────────────────────────────────────
getent group _stackbroker-clients >/dev/null || groupadd -r _stackbroker-clients
getent passwd _stackbroker >/dev/null || useradd -r -g _stackbroker-clients -s /usr/sbin/nologin -M _stackbroker
getent passwd stackbrkclient >/dev/null || useradd -r -G _stackbroker-clients -s /bin/bash -M stackbrkclient
CLIENT_UID="$(id -u stackbrkclient)"

TMP="$(mktemp -d)"; chmod 755 "$TMP"
STATE="$TMP/state"
STUB="$TMP/stub"; mkdir -p "$STUB"
DPIDS=()
cleanup() { for p in "${DPIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

mkcfg() { # mkcfg <path> <state_root> <req_sock> <app_sock> <registry> [extra-json]
  local extra="${6:-{\}}"
  jq -n --arg sr "$2" --arg rq "$3" --arg apq "$4" --arg reg "$5" \
        --argjson uid "$CLIENT_UID" --argjson extra "$extra" \
    '{state_root:$sr, request_socket:$rq, approval_socket:$apq,
      ops_registry:$reg, client_uids:[$uid],
      run_user:"_stackbroker", clients_group:"_stackbroker-clients",
      vendor_stub_dir:null} + $extra' > "$1"
  chown root:root "$1"; chmod 600 "$1"
}

start_daemon() { # start_daemon <cfg> -> pid; waits for socket
  python3 "$DAEMON" --config "$1" >>"$TMP/daemon.out" 2>&1 &
  local pid=$!
  DPIDS+=("$pid")
  local sock; sock="$(jq -r '.request_socket' "$1")"
  for _ in $(seq 1 100); do [[ -S "$sock" ]] && break; sleep 0.1; done
  [[ -S "$sock" ]] || { echo "FATAL: daemon did not bind $sock"; cat "$TMP/daemon.out"; exit 1; }
  echo "$pid"
}

as_client() { # as_client <client-cfg> <args...>
  local ccfg="$1"; shift
  sudo -u stackbrkclient env STACK_BROKER_CONFIG="$ccfg" STACK_BROKER_REPO="test/repo" \
    python3 "$CLIENT" "$@"
}

raw_send() { # raw_send <sock> <raw-line> — as the client user, prints response
  local sock="$1" line="$2"
  sudo -u stackbrkclient python3 - "$sock" "$line" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(30)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
buf = b""
while b"\n" not in buf:
    c = s.recv(65536)
    if not c: break
    buf += c
sys.stdout.write(buf.decode())
PY
}

# ── main daemon ────────────────────────────────────────────────────────────
CFG="$TMP/config.json"
REQ="$TMP/req.sock"; APP="$TMP/app.sock"
mkcfg "$CFG" "$STATE" "$REQ" "$APP" "$REGISTRY" "{\"vendor_stub_dir\": \"$STUB\"}"
MAIN_PID="$(start_daemon "$CFG")"

CCFG="$TMP/client.json"
jq -n --arg ep "unix://$REQ" --arg rd "$STATE/receipts" \
  '{schema:"broker-client/v1", endpoint:$ep, receipts_dir:$rd}' > "$CCFG"
chmod 644 "$CCFG"

receipt_count() { find "$STATE/receipts" -name '*.json' 2>/dev/null | wc -l; }

# ── 1: unknown op -> exit 3 unknown_op, receipt minted ─────────────────────
N0="$(receipt_count)"
OUT="$(as_client "$CCFG" no.such.op --json 2>&1)"; RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="unknown_op"' >/dev/null 2>&1 \
   && [[ "$(receipt_count)" -eq $((N0+1)) ]]; then
  pass "1: unknown op -> 3 unknown_op + receipt"
else
  fail "1: rc=$RC out=$OUT"
fi

# ── 2: known read op -> exit 3 not_provisioned, receipt minted ─────────────
N0="$(receipt_count)"
OUT="$(as_client "$CCFG" cloudflare.worker.list --json 2>&1)"; RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="not_provisioned"' >/dev/null 2>&1 \
   && [[ "$(receipt_count)" -eq $((N0+1)) ]]; then
  pass "2: read op unprovisioned -> 3 not_provisioned + receipt"
else
  fail "2: rc=$RC out=$OUT"
fi

# ── 3: unknown param key / pattern failure / duplicate JSON key ────────────
OUT="$(as_client "$CCFG" neon.database.describe --project ok-name --bogus x --json 2>&1)"; RC=$?
[[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="param_rejected"' >/dev/null 2>&1 \
  && pass "3a: unknown param key -> 3 param_rejected" || fail "3a: rc=$RC out=$OUT"

OUT="$(as_client "$CCFG" neon.database.describe --project 'BAD NAME!!' --json 2>&1)"; RC=$?
[[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="param_rejected"' >/dev/null 2>&1 \
  && pass "3b: pattern failure -> 3 param_rejected" || fail "3b: rc=$RC out=$OUT"

DUP='{"schema":"broker-request/v1","op":"cloudflare.worker.list","op":"neon.database.describe","params":{},"reason":"","claimed":{"repo":"test/repo"}}'
OUT="$(raw_send "$REQ" "$DUP")"
echo "$OUT" | jq -e '.status=="refused" and .reason_code=="param_rejected"' >/dev/null 2>&1 \
  && pass "3c: duplicate JSON key -> refused at parse, never last-wins" || fail "3c: $OUT"

# ── 4: registry hygiene — no command/sql/url/path param types ──────────────
if jq -e '[.ops[].params[]?.type] | all(. != "command" and . != "sql" and . != "url" and . != "path")' "$REGISTRY" >/dev/null; then
  pass "4a: registry has no passthrough param types"
else
  fail "4a: forbidden param type present in registry"
fi
# and the daemon refuses a registry that contains one (fails closed)
BADREG="$TMP/badreg.json"
jq '.ops += [{"id":"evil.exec","class":"read","surface":"github","params":{"cmd":{"type":"command"}},"result_schema":[]}]' "$REGISTRY" > "$BADREG"
CFG4="$TMP/config4.json"; REQ4="$TMP/req4.sock"; APP4="$TMP/app4.sock"
mkcfg "$CFG4" "$TMP/state4" "$REQ4" "$APP4" "$BADREG"
start_daemon "$CFG4" >/dev/null
CCFG4="$TMP/client4.json"
jq -n --arg ep "unix://$REQ4" '{schema:"broker-client/v1", endpoint:$ep}' > "$CCFG4"; chmod 644 "$CCFG4"
OUT="$(as_client "$CCFG4" cloudflare.worker.list --json 2>&1)"; RC=$?
[[ $RC -eq 7 ]] && pass "4b: registry with passthrough type -> daemon fails closed (7)" || fail "4b: rc=$RC out=$OUT"

# ── 5: receipts from 1-3 validate stack-receipt/v1 kind=broker ─────────────
ALL_VALID=1
while IFS= read -r f; do
  jq -e '
    .schema=="stack-receipt/v1" and .kind=="broker"
    and (.writer|type=="string") and (.as_of|type=="string")
    and (.subject.kind=="operation")
    and (.subject.repo_hash|test("^[0-9a-f]{16}$"))
    and (.verdict|IN("executed","refused","pending","error","unknown"))
    and (.evidence.broker.verified.uid|type=="number")
    and has("needs_human") and has("error")
  ' "$f" >/dev/null 2>&1 || { ALL_VALID=0; echo "  invalid receipt: $f"; }
done < <(find "$STATE/receipts" -name '*.json')
[[ $ALL_VALID -eq 1 ]] && pass "5: every receipt validates (kind=broker, closed sets)" || fail "5: invalid receipt(s)"

# ── 6: socket perms; agent cannot stat principals; cannot write receipts ───
PERM="$(stat -c '%a %U %G' "$REQ")"
[[ "$PERM" == "660 root _stackbroker-clients" ]] \
  && pass "6a: request socket 0660 root:_stackbroker-clients" || fail "6a: got '$PERM'"
if sudo -u stackbrkclient stat "$STATE/private/principals" >/dev/null 2>&1; then
  fail "6b: client uid could stat principals dir"
else
  pass "6b: client uid cannot stat private/principals (EACCES)"
fi
if sudo -u stackbrkclient touch "$STATE/receipts/x" >/dev/null 2>&1; then
  fail "6c: client uid could write into receipts dir"
else
  pass "6c: client uid cannot write receipts (EACCES)"
fi

# ── 7: approval socket unreachable from client uid ─────────────────────────
OUT="$(sudo -u stackbrkclient python3 - "$APP" <<'PY' 2>&1
import socket, sys, errno
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sys.argv[1])
    print("CONNECTED")
except PermissionError:
    print("EACCES")
except OSError as e:
    print("OSERR:%s" % e.errno)
PY
)"
[[ "$OUT" == "EACCES" ]] && pass "7: approval socket connect from client uid -> EACCES" || fail "7: got $OUT"

# ── 8: unparseable registry -> exit 7, generic message, no vendor call ─────
CFG8="$TMP/config8.json"; REQ8="$TMP/req8.sock"; APP8="$TMP/app8.sock"
echo '{ this is not json' > "$TMP/broken-reg.json"
mkcfg "$CFG8" "$TMP/state8" "$REQ8" "$APP8" "$TMP/broken-reg.json"
start_daemon "$CFG8" >/dev/null
CCFG8="$TMP/client8.json"
jq -n --arg ep "unix://$REQ8" '{schema:"broker-client/v1", endpoint:$ep}' > "$CCFG8"; chmod 644 "$CCFG8"
GENERIC_MSG='stack-broker: request could not be processed. Run `stack-broker ops` to see what is available.'
OUT="$(as_client "$CCFG8" cloudflare.worker.list --json 2>&1)"; RC=$?
if [[ $RC -eq 7 ]] && echo "$OUT" | jq -e --arg m "$GENERIC_MSG" '.message==$m' >/dev/null 2>&1; then
  pass "8: unparseable registry -> 7, generic machinery message"
else
  fail "8: rc=$RC out=$OUT"
fi

# ── 9: result is allowlist-built + redactor second net ─────────────────────
mkdir -p "$STATE/private/principals"
jq -n '{surface:"cloudflare", token_ref:"dummy", issued_at:"2026-08-21T00:00:00Z", max_age_days:90}' \
  > "$STATE/private/principals/cloudflare.json"
chown _stackbroker:_stackbroker-clients "$STATE/private/principals/cloudflare.json" 2>/dev/null
chmod 600 "$STATE/private/principals/cloudflare.json"
# 9a: extra field with a signed URL the regex does NOT match -> absent by construction
jq -n '{status_code:200, body:{result:[{id:"w1", created_on:"2026-01-01",
        presigned_download:"https://blobs.example/download/abcdef0123456789abcdef0123456789abcdef012345"}]}}' \
  > "$STUB/cloudflare.worker.list.json"
OUT="$(as_client "$CCFG" cloudflare.worker.list --json 2>&1)"; RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | jq -e '.result.result[0] | has("presigned_download") | not' >/dev/null 2>&1 \
   && echo "$OUT" | jq -e '.result.result[0].id=="w1"' >/dev/null 2>&1; then
  pass "9a: unanticipated field absent because never copied"
else
  fail "9a: rc=$RC out=$OUT"
fi
# 9b: allowlisted field whose value DOES match the redactor -> machinery, empty result
jq -n '{status_code:200, body:{result:[{id:"ghp_AAAAAAAAAAAAAAAAAAAAAAAA", created_on:"2026-01-01"}]}}' \
  > "$STUB/cloudflare.worker.list.json"
OUT="$(as_client "$CCFG" cloudflare.worker.list --json 2>&1)"; RC=$?
if [[ $RC -eq 7 ]] && echo "$OUT" | jq -e '.reason_code=="machinery" and (.result=={})' >/dev/null 2>&1; then
  pass "9b: redactor match -> downgraded to machinery, empty result"
else
  fail "9b: rc=$RC out=$OUT"
fi
rm -f "$STUB/cloudflare.worker.list.json"

# ── 10: daemon stopped -> exit 6, distinct from 3 ──────────────────────────
CCFGDOWN="$TMP/clientdown.json"
jq -n '{schema:"broker-client/v1", endpoint:"unix:///nonexistent/broker.sock"}' > "$CCFGDOWN"; chmod 644 "$CCFGDOWN"
as_client "$CCFGDOWN" cloudflare.worker.list >/dev/null 2>&1; RC=$?
[[ $RC -eq 6 ]] && pass "10: daemon down -> exit 6" || fail "10: rc=$RC"

# ── 11: history returns the refusals newest first ──────────────────────────
OUT="$(as_client "$CCFG" history --json 2>&1)"
if echo "$OUT" | jq -e 'length >= 3 and ([.[].verdict] | index("refused") != null)' >/dev/null 2>&1 \
   && echo "$OUT" | jq -e '[.[].as_of] as $a | $a == ($a | sort | reverse)' >/dev/null 2>&1; then
  pass "11: history lists refusals, newest first"
else
  fail "11: $OUT"
fi

# ── 14: repo_hash is daemon-computed; traversal-shaped claim goes nowhere ──
RAW14='{"schema":"broker-request/v1","op":"no.such.op","params":{},"reason":"","claimed":{"repo":"../../etc"}}'
raw_send "$REQ" "$RAW14" >/dev/null
NEW="$(find "$STATE/receipts" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | grep -Ev '^[0-9a-f]{16}$' || true)"
if [[ -z "$NEW" ]] && [[ ! -e "$STATE/../etc" ]]; then
  pass "14: claimed.repo=../../etc lands under a 16-hex dir, nothing outside receipts root"
else
  fail "14: non-hex receipt dir or traversal artifact: $NEW"
fi

# ── 15: staging — drop-only for the client; swap-after-check is closed ─────
STG="$STATE/staging/$CLIENT_UID"
PERM="$(stat -c '%a' "$STG")"
[[ "$PERM" == "1730" ]] || fail "15-pre: staging dir mode $PERM (expected 1730)"
if sudo -u stackbrkclient bash -c "echo hello > '$STG/probe.bundle'"; then
  pass "15a: client can create-and-write in staging"
else
  fail "15a: client cannot create in staging"
fi
sudo -u stackbrkclient ls "$STG" >/dev/null 2>&1 && fail "15b: client could list staging" || pass "15b: client cannot list staging"
touch "$STG/daemon-owned"; chmod 600 "$STG/daemon-owned"
sudo -u stackbrkclient cat "$STG/daemon-owned" >/dev/null 2>&1 && fail "15c: client read a daemon-owned staged file" || pass "15c: client cannot read a daemon-staged file"
sudo -u stackbrkclient rm -f "$STG/daemon-owned" >/dev/null 2>&1
[[ -e "$STG/daemon-owned" ]] && pass "15d: client cannot unlink a daemon-staged file (sticky)" || fail "15d: client unlinked a daemon-owned staged file"
# hash mismatch: stage bytes under a wrong name -> param_rejected
WRONG="$(printf 'x%.0s' $(seq 1 64) | head -c 64 | tr 'x' 'a')"
sudo -u stackbrkclient bash -c "printf 'not-a-bundle' > '$STG/$WRONG.bundle'"
OUT="$(as_client "$CCFG" github.branch.push --repo test/repo --branch feat/x \
        --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --bundle "$WRONG" \
        --reason t --json 2>&1)"; RC=$?
[[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="param_rejected"' >/dev/null 2>&1 \
  && pass "15e: name/hash mismatch -> refused (the hash is the fact)" || fail "15e: rc=$RC out=$OUT"
# correct hash: passes staging, consumed (src unlinked), then stops at not_provisioned
BYTES='real-bundle-bytes-v1'
GOOD="$(printf '%s' "$BYTES" | sha256sum | cut -d' ' -f1)"
sudo -u stackbrkclient bash -c "printf '%s' '$BYTES' > '$STG/$GOOD.bundle'"
OUT="$(as_client "$CCFG" github.branch.push --repo test/repo --branch feat/x \
        --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --bundle "$GOOD" \
        --reason t --json 2>&1)"; RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | jq -e '.reason_code=="not_provisioned"' >/dev/null 2>&1 \
   && [[ ! -e "$STG/$GOOD.bundle" ]]; then
  pass "15f: valid blob verified on the daemon's own copy and consumed"
else
  fail "15f: rc=$RC out=$OUT src-still-present=$([[ -e "$STG/$GOOD.bundle" ]] && echo yes || echo no)"
fi

# ── 13: store bounds — flood + fake low-free-space ─────────────────────────
# The flood runs against its OWN daemon instance so the drained token bucket
# cannot bleed into later cases.
CFG13A="$TMP/config13a.json"; REQ13A="$TMP/req13a.sock"; APP13A="$TMP/app13a.sock"
mkcfg "$CFG13A" "$TMP/state13a" "$REQ13A" "$APP13A" "$REGISTRY"
start_daemon "$CFG13A" >/dev/null
SIZE_BEFORE="$(du -sk "$TMP/state13a/receipts" 2>/dev/null | cut -f1)"; SIZE_BEFORE="${SIZE_BEFORE:-0}"
sudo -u stackbrkclient python3 - "$REQ13A" <<'PY'
import socket, sys
sock = sys.argv[1]
for i in range(10000):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(sock)
        s.sendall(b"this is not json\n")
        s.recv(65536)
    except OSError:
        pass
    finally:
        s.close()
PY
SIZE_AFTER="$(du -sk "$TMP/state13a/receipts" | cut -f1)"
GROWTH_K=$((SIZE_AFTER - SIZE_BEFORE))
INDIV="$(find "$TMP/state13a/receipts" -name '*.json' ! -name '*-agg-*' | wc -l)"
AGG="$(find "$TMP/state13a/receipts" -name '*-agg-*' | wc -l)"
if [[ $GROWTH_K -lt 5120 ]] && [[ $INDIV -le 200 ]] && [[ $AGG -ge 1 ]]; then
  pass "13a: 10k malformed -> +${GROWTH_K}KiB (<5MiB), $INDIV individual receipts (<=200), $AGG aggregate(s)"
else
  fail "13a: growth=${GROWTH_K}KiB individual=$INDIV agg=$AGG"
fi
CFG13="$TMP/config13.json"; REQ13="$TMP/req13.sock"; APP13="$TMP/app13.sock"
mkcfg "$CFG13" "$TMP/state13" "$REQ13" "$APP13" "$REGISTRY" '{"fake_free_bytes": 1048576}'
start_daemon "$CFG13" >/dev/null
CCFG13="$TMP/client13.json"
jq -n --arg ep "unix://$REQ13" '{schema:"broker-client/v1", endpoint:$ep}' > "$CCFG13"; chmod 644 "$CCFG13"
OUT="$(as_client "$CCFG13" github.pr.create --repo t/r --head feat/x --base main --title t --body b --reason r --json 2>&1)"; RC=$?
R1=$RC; C1="$(echo "$OUT" | jq -r '.reason_code' 2>/dev/null)"
OUT="$(as_client "$CCFG13" cloudflare.worker.list --json 2>&1)"; RC=$?
if [[ $R1 -eq 7 && "$C1" == "store_full" && $RC -eq 3 ]]; then
  pass "13b: low free space -> propose/write store_full (7), read still served"
else
  fail "13b: propose rc=$R1 code=$C1, read rc=$RC"
fi

# ── 12: crash safety — kill -9 between intent and outcome ──────────────────
jq -n '{status_code:200, delay_ms:4000, body:{result:[{id:"w1", created_on:"x"}]}}' \
  > "$STUB/cloudflare.worker.list.json"
as_client "$CCFG" cloudflare.worker.list --json >/dev/null 2>&1 &
BG=$!
sleep 1.2
kill -9 "$MAIN_PID" 2>/dev/null
wait "$BG" 2>/dev/null
INTENT="$(grep -l '"outcome_recorded": *false' -r "$STATE/receipts" 2>/dev/null | head -1)"
[[ -z "$INTENT" ]] && INTENT="$(for f in $(find "$STATE/receipts" -name '*.json'); do jq -e '.evidence.broker.outcome_recorded==false' "$f" >/dev/null 2>&1 && { echo "$f"; break; }; done)"
if [[ -n "$INTENT" ]] && jq -e '.verdict=="unknown"' "$INTENT" >/dev/null 2>&1; then
  pass "12a: kill -9 leaves an intent-only record, verdict unknown"
else
  fail "12a: no intent-only record found"
fi
# age it past 10 minutes and confirm history renders unknown, never failed
if [[ -n "$INTENT" ]]; then
  OLD="$(date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg t "$OLD" '.as_of=$t' "$INTENT" > "$INTENT.tmp" && mv "$INTENT.tmp" "$INTENT"
  OUT="$(as_client "$CCFG" history --json 2>&1)"
  if echo "$OUT" | jq -e '[.[] | select(.verdict=="unknown")] | length >= 1' >/dev/null 2>&1 \
     && ! echo "$OUT" | jq -e '[.[] | select(.verdict=="failed")] | length > 0' >/dev/null 2>&1; then
    pass "12b: history renders outcome unknown, never failed"
  else
    fail "12b: $OUT"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
