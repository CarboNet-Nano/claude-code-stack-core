#!/usr/bin/env bash
# broker-install.sh — install the stack-broker daemon, client, approval helper,
# sudoers drop-in, and system config (D18 P1/P2). Idempotent. Needs root.
#
# Usage: broker-install.sh [--client-uid <uid>] [--no-start]
#
# Rollback (design §9 P1/P2): stop the daemon, then
#   rm -f /usr/local/bin/stack-broker /usr/local/libexec/stack-approve \
#         /usr/local/libexec/stack_broker_daemon.py /etc/sudoers.d/stack-approve
#   rm -rf /etc/stack-broker /var/db/stack-broker
#   userdel _stackbroker; groupdel _stackbroker-clients
#
# macOS: this script creates the launchd plist but the daemon user creation
# uses sysadminctl/dscl paths that MUST be reviewed on the Mac before running;
# built and tested on Linux (see docs/reports/2026-08-22-overnight-d18-build.md).

set -euo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

[[ $(id -u) -eq 0 ]] || { echo "broker-install: needs root" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_UID="501"
START=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-uid) CLIENT_UID="$2"; shift ;;
    --no-start) START=0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

OS="$(uname -s)"

# ── users/groups ───────────────────────────────────────────────────────────
if [[ "$OS" == "Linux" ]]; then
  getent group _stackbroker-clients >/dev/null || groupadd -r _stackbroker-clients
  getent passwd _stackbroker >/dev/null || useradd -r -g _stackbroker-clients -s /usr/sbin/nologin -M _stackbroker
  # the client uid joins the clients group (socket + staging access)
  CLIENT_NAME="$(getent passwd "$CLIENT_UID" | cut -d: -f1 || true)"
  [[ -n "$CLIENT_NAME" ]] && usermod -aG _stackbroker-clients "$CLIENT_NAME" 2>/dev/null || true
else
  echo "broker-install: macOS user creation not automated here — create _stackbroker" >&2
  echo "and _stackbroker-clients with sysadminctl/dscl, then re-run." >&2
  dscl . -read /Groups/_stackbroker-clients >/dev/null 2>&1 || exit 1
fi

# ── files ──────────────────────────────────────────────────────────────────
install -d -m 755 /usr/local/bin /usr/local/libexec /etc/stack-broker
install -o root -g root -m 755 "$REPO_ROOT/broker/stack-broker" /usr/local/bin/stack-broker 2>/dev/null \
  || install -o root -m 755 "$REPO_ROOT/broker/stack-broker" /usr/local/bin/stack-broker
install -o root -m 755 "$REPO_ROOT/broker/stack_broker_daemon.py" /usr/local/libexec/stack_broker_daemon.py
install -o root -m 755 "$REPO_ROOT/broker/stack-approve" /usr/local/libexec/stack-approve

# registry: floor-denied config location, root-owned copy for the daemon
install -o root -m 644 "$REPO_ROOT/config/broker-ops.json" /etc/stack-broker/broker-ops.json

# system config (root-owned; test-only knobs need root to set)
if [[ ! -f /etc/stack-broker/config.json ]]; then
  jq -n --argjson uid "$CLIENT_UID" \
    '{state_root:"/var/db/stack-broker",
      request_socket:"/var/run/stack-broker.sock",
      approval_socket:"/var/run/stack-broker-approve.sock",
      ops_registry:"/etc/stack-broker/broker-ops.json",
      client_uids:[$uid],
      run_user:"_stackbroker", clients_group:"_stackbroker-clients"}' \
    > /etc/stack-broker/config.json
fi
chown root:root /etc/stack-broker/config.json 2>/dev/null || chown root /etc/stack-broker/config.json
chmod 600 /etc/stack-broker/config.json

# ── sudoers drop-in ────────────────────────────────────────────────────────
TMPS="$(mktemp)"
cp "$REPO_ROOT/broker/sudoers-stack-approve" "$TMPS"
if ! visudo -cf "$TMPS" >/dev/null; then
  echo "broker-install: sudoers drop-in fails visudo -c; NOT installed" >&2
  rm -f "$TMPS"; exit 1
fi
GRP=root; [[ "$OS" == "Darwin" ]] && GRP=wheel
install -o root -g "$GRP" -m 440 "$TMPS" /etc/sudoers.d/stack-approve
rm -f "$TMPS"

# ── integrity manifest for verify-approval-channel.sh ──────────────────────
sha256sum /usr/local/libexec/stack-approve 2>/dev/null | awk '{print $1"  /usr/local/libexec/stack-approve"}' \
  > /etc/stack-broker/manifest.sha256 \
  || shasum -a 256 /usr/local/libexec/stack-approve | awk '{print $1"  /usr/local/libexec/stack-approve"}' \
  > /etc/stack-broker/manifest.sha256
chmod 644 /etc/stack-broker/manifest.sha256

# ── start ──────────────────────────────────────────────────────────────────
if [[ $START -eq 1 ]]; then
  if [[ "$OS" == "Darwin" ]]; then
    echo "broker-install: install broker/com.stack.broker.plist into /Library/LaunchDaemons and launchctl bootstrap it" >&2
  else
    pkill -f 'stack_broker_daemon.py --config /etc/stack-broker/config.json' 2>/dev/null || true
    sleep 0.3
    nohup python3 /usr/local/libexec/stack_broker_daemon.py --config /etc/stack-broker/config.json \
      >/var/log/stack-broker.boot.log 2>&1 &
    for _ in $(seq 1 50); do [[ -S /var/run/stack-broker.sock ]] && break; sleep 0.1; done
    [[ -S /var/run/stack-broker.sock ]] || { echo "broker-install: daemon did not come up" >&2; exit 1; }
  fi
fi
echo "broker-install: done (client_uid=$CLIENT_UID)"
