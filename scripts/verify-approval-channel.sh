#!/usr/bin/env bash
# verify-approval-channel.sh — D18 §6.6 install-time verification. Exit 0 only
# if every checkable property of the approval channel holds:
#
#   1. approval socket is srw------- owned root, group wheel/root
#   2. /etc/sudoers.d/stack-approve is root-owned 0440, parses under visudo -c,
#      and sets timestamp_timeout=0, requiretty, env_reset
#   3. /usr/local/libexec/stack-approve is root-owned 0755, NOT setuid, and its
#      sha256 matches the installed manifest
#   4. no NOPASSWD entry anywhere in /etc/sudoers* matches stack-approve
#   5. every file in /etc/sudoers.d/ is root-owned 0440
#
# No claim is made that the complete effective sudo policy for the agent uid is
# bounded — that is not machine-checkable across sudo implementations (§11
# O-R3-H4); this script checks the reduced set that IS complete.
#
# Path overrides (tests): STACK_BROKER_SYSTEM_CONFIG, STACK_VERIFY_SUDOERS_DIR,
# STACK_VERIFY_SUDOERS_MAIN, STACK_VERIFY_HELPER, STACK_VERIFY_MANIFEST.

set -uo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SYSTEM_CONFIG="${STACK_BROKER_SYSTEM_CONFIG:-/etc/stack-broker/config.json}"
SUDOERS_DIR="${STACK_VERIFY_SUDOERS_DIR:-/etc/sudoers.d}"
SUDOERS_MAIN="${STACK_VERIFY_SUDOERS_MAIN:-/etc/sudoers}"
HELPER="${STACK_VERIFY_HELPER:-/usr/local/libexec/stack-approve}"
MANIFEST="${STACK_VERIFY_MANIFEST:-/etc/stack-broker/manifest.sha256}"
DROPIN="$SUDOERS_DIR/stack-approve"

FAILED=0
ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; FAILED=1; }

# ── 0. the system config itself ────────────────────────────────────────────
# stack-approve runs as root and trusts this file to resolve the approval
# socket. If uid 501 can write it, it chooses where a root process connects
# and what summary the human is shown before approving.
if [[ ! -f "$SYSTEM_CONFIG" ]]; then
  bad "system config $SYSTEM_CONFIG missing"
else
  MODE="$(stat -c '%a' "$SYSTEM_CONFIG" 2>/dev/null || stat -f '%Lp' "$SYSTEM_CONFIG" 2>/dev/null)"
  OWNER="$(stat -c '%U' "$SYSTEM_CONFIG" 2>/dev/null || stat -f '%Su' "$SYSTEM_CONFIG" 2>/dev/null)"
  if [[ "$OWNER" == "root" && ( "$MODE" == "600" || "$MODE" == "644" ) ]]; then
    ok "system config root-owned $MODE"
  else
    bad "system config is $MODE $OWNER (need root-owned 0600/0644)"
  fi
fi

# ── 1. approval socket ─────────────────────────────────────────────────────
SOCK="$(jq -r '.approval_socket // empty' "$SYSTEM_CONFIG" 2>/dev/null)"
if [[ -z "$SOCK" ]]; then
  bad "cannot resolve approval socket from $SYSTEM_CONFIG"
elif [[ ! -S "$SOCK" ]]; then
  bad "approval socket $SOCK does not exist (daemon down?)"
else
  MODE="$(stat -c '%a' "$SOCK" 2>/dev/null || stat -f '%Lp' "$SOCK" 2>/dev/null)"
  OWNER="$(stat -c '%U' "$SOCK" 2>/dev/null || stat -f '%Su' "$SOCK" 2>/dev/null)"
  GROUP="$(stat -c '%G' "$SOCK" 2>/dev/null || stat -f '%Sg' "$SOCK" 2>/dev/null)"
  if [[ "$MODE" == "600" && "$OWNER" == "root" && ( "$GROUP" == "root" || "$GROUP" == "wheel" ) ]]; then
    ok "approval socket srw------- root:$GROUP"
  else
    bad "approval socket is $MODE $OWNER:$GROUP (need 600 root:wheel|root)"
  fi
fi

# ── 2. sudoers drop-in ─────────────────────────────────────────────────────
if [[ ! -f "$DROPIN" ]]; then
  bad "sudoers drop-in $DROPIN missing"
else
  MODE="$(stat -c '%a' "$DROPIN" 2>/dev/null || stat -f '%Lp' "$DROPIN" 2>/dev/null)"
  OWNER="$(stat -c '%U' "$DROPIN" 2>/dev/null || stat -f '%Su' "$DROPIN" 2>/dev/null)"
  [[ "$MODE" == "440" && "$OWNER" == "root" ]] \
    && ok "drop-in root-owned 0440" || bad "drop-in is $MODE $OWNER (need 0440 root)"
  if visudo -cf "$DROPIN" >/dev/null 2>&1; then
    ok "drop-in parses under visudo -c"
  else
    bad "drop-in fails visudo -c"
  fi
  for want in "timestamp_timeout=0" "requiretty" "env_reset"; do
    if grep -Eq "^Defaults!STACK_APPROVE.*\b${want}" "$DROPIN"; then
      ok "drop-in sets $want"
    else
      bad "drop-in does not set $want"
    fi
  done
fi

# ── 3. helper binary ───────────────────────────────────────────────────────
if [[ ! -f "$HELPER" ]]; then
  bad "helper $HELPER missing"
else
  MODE="$(stat -c '%a' "$HELPER" 2>/dev/null || stat -f '%Lp' "$HELPER" 2>/dev/null)"
  OWNER="$(stat -c '%U' "$HELPER" 2>/dev/null || stat -f '%Su' "$HELPER" 2>/dev/null)"
  [[ "$MODE" == "755" && "$OWNER" == "root" ]] \
    && ok "helper root-owned 0755" || bad "helper is $MODE $OWNER (need 0755 root)"
  if [[ -u "$HELPER" || -g "$HELPER" ]]; then
    bad "helper is setuid/setgid"
  else
    ok "helper is not setuid"
  fi
  if [[ -f "$MANIFEST" ]]; then
    WANT="$(awk '{print $1; exit}' "$MANIFEST")"
    HAVE="$( (sha256sum "$HELPER" 2>/dev/null || shasum -a 256 "$HELPER") | awk '{print $1}')"
    [[ -n "$WANT" && "$WANT" == "$HAVE" ]] \
      && ok "helper sha256 matches manifest" || bad "helper sha256 mismatch vs manifest"
  else
    bad "manifest $MANIFEST missing (cannot verify helper integrity)"
  fi
fi

# ── 4. no NOPASSWD matches stack-approve anywhere ──────────────────────────
NP=0
for f in "$SUDOERS_MAIN" "$SUDOERS_DIR"/*; do
  [[ -f "$f" ]] || continue
  if grep -E 'NOPASSWD' "$f" 2>/dev/null | grep -q 'stack-approve'; then
    bad "NOPASSWD entry matching stack-approve in $f"; NP=1
  fi
done
[[ $NP -eq 0 ]] && ok "no NOPASSWD entry matches stack-approve"

# ── 5. every file in sudoers.d is root-owned 0440 ──────────────────────────
BADF=0
for f in "$SUDOERS_DIR"/*; do
  [[ -f "$f" ]] || continue
  MODE="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
  OWNER="$(stat -c '%U' "$f" 2>/dev/null || stat -f '%Su' "$f" 2>/dev/null)"
  if [[ "$MODE" != "440" || "$OWNER" != "root" ]]; then
    bad "$f is $MODE $OWNER (need 0440 root)"; BADF=1
  fi
done
[[ $BADF -eq 0 ]] && ok "every sudoers.d file is root-owned 0440"

if [[ $FAILED -eq 0 ]]; then
  echo "verify-approval-channel: ALL CHECKS PASSED"
  exit 0
fi
echo "verify-approval-channel: FAILED"
exit 1
