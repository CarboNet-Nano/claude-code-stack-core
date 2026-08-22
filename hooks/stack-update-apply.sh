#!/usr/bin/env bash
# summary: UserPromptSubmit hook — the applier. Validates a human-authored consent file and promotes an already-staged, pin-verified SHA with NO network call (ADR-086 D2, D13 apply, D15, D17).
#
# The skill is the button; this hook is the muscle. The model cannot write
# ~/.claude/**, so it cannot apply anything. What it CAN do is write one small
# file in a deliberately unprotected place (state/stack-consent/), which this
# unsandboxed hook then validates and acts on. Forgery is harmless by
# construction (ADR-086 D15): the only thing a forged consent can cause is
# the org's own, already-staged, pin-verified update being applied — nothing
# else is reachable.
#
# This hook runs on EVERY user prompt. The no-consent path is one `stat` and
# an exit — it must be indistinguishable from free on every turn where
# nothing is staged.
#
# stdin  : UserPromptSubmit hook JSON — { session_id, prompt, ... }
# stdout : exactly one line, drawn from a closed vocabulary (D15), ONLY when
#          a consent file was present. Otherwise nothing.
# exit   : 0, always.
set -uo pipefail

# Finding #1 (cross-family review): a repo-local hook planted in the source
# repo's .git/hooks/ must never execute during a privileged git operation
# this hook (or anything it shells out to) performs. Every direct `git` call
# below also carries an explicit `-c core.hooksPath=/dev/null` (belt-and-
# suspenders), but this process-wide env-var form additionally covers the
# `scripts/update.sh` -> `install.sh` subprocess chain launched by the
# internal apply worker below, without editing either of those files.
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=core.hooksPath
GIT_CONFIG_VALUE_0=/dev/null
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

_HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SELF="${BASH_SOURCE[0]}"

# ─────────────────────────────────────────────────────────────────────────
# Shared helpers (deliberately duplicated from hooks/stack-self-update.sh —
# no shared lib file is in this ADR's plan; see that hook's session-marker.sh
# precedent for why duplication over extraction is the house style here).
# ─────────────────────────────────────────────────────────────────────────

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

_to_epoch() {
  local ts="${1:-}"
  [[ -z "$ts" || "$ts" == "null" ]] && return 1
  date -u -d "$ts" '+%s' 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null
}

_canon_path() {
  local p="$1"
  realpath -P "$p" 2>/dev/null && return 0
  realpath "$p" 2>/dev/null && return 0
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null
}

_has_dotdot_segment() {
  local p="$1" seg
  local IFS='/'
  # shellcheck disable=SC2086
  for seg in $p; do
    [[ "$seg" == ".." ]] && return 0
  done
  return 1
}

sanitize_text() {
  local raw="${1:-}" maxlen="${2:-200}" rc="${3:-}"
  local firstline="${raw%%$'\n'*}"
  firstline="${firstline%%$'\r'*}"
  local cleaned
  cleaned="$(printf '%s' "$firstline" | LC_ALL=C tr -cd '\40-\176')"
  cleaned="$(printf '%s' "$cleaned" | LC_ALL=C sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//')"
  cleaned="${cleaned:0:$maxlen}"
  if [[ -z "$cleaned" ]]; then
    if [[ "$rc" =~ ^[0-9]+$ ]] && (( rc >= 128 )); then
      cleaned="killed or crashed (exit $rc)"
    else
      cleaned="no error text"
    fi
  fi
  printf '%s' "$cleaned"
}

_component_safe() {
  local d="$1"
  [[ -L "$d" ]] && return 1
  [[ -d "$d" ]] || return 1
  [[ -O "$d" ]] || return 1
  local perms
  perms="$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)"
  [[ -n "$perms" ]] || return 1
  local last2="${perms: -2}"
  local gdigit="${last2:0:1}" odigit="${last2:1:1}"
  (( (8#$gdigit) & 2 )) && return 1
  (( (8#$odigit) & 2 )) && return 1
  return 0
}

# shellcheck disable=SC1091
[[ -f "$_HOOKDIR/../lib/profile-resolver.sh" ]] && source "$_HOOKDIR/../lib/profile-resolver.sh"
CONF_DIR="${CLAUDE_PLUGIN_ROOT:-$(command -v pr_resolve_dir_or_default >/dev/null 2>&1 && pr_resolve_dir_or_default 2>/dev/null || echo "$HOME/.claude")}"

STATE_DIR="$CONF_DIR/state/stack-update"
RECEIPT="$STATE_DIR/receipt.json"
UNSAFE_RECEIPT="$CONF_DIR/state/stack-update-unsafe.json"
LOG="$STATE_DIR/last-update.log"
LOCK_DIR="$STATE_DIR/lock"
PIN="$CONF_DIR/hooks/stack-update.pin.json"
STAMP="$CONF_DIR/.stack-install.json"
CONSENT="$CONF_DIR/state/stack-consent/stack-update.json"
CONSENT_USED="$CONSENT.used"

APPLY_BUDGET_S="${STACK_UPDATE_APPLY_BUDGET_S:-90}"

state_dir_safe() {
  # Walk $CONF_DIR down to $STATE_DIR ONE COMPONENT AT A TIME, verifying each
  # before creating (or descending into) the next. `mkdir -p` across the
  # whole path was the bug (finding #7): if a parent (e.g. $CONF_DIR/state)
  # was ALREADY a symlink, `mkdir -p` would silently create the leaf through
  # it before this function's own checks ever ran. Because every parent is
  # confirmed to be a real, safely-owned directory before its child is
  # created, a plain (non -p) `mkdir` on that child can never follow an
  # attacker's symlink — there is nothing left to follow.
  local d
  for d in "$CONF_DIR" "$CONF_DIR/state" "$STATE_DIR"; do
    if [[ ! -e "$d" && ! -L "$d" ]]; then
      mkdir "$d" 2>/dev/null
    fi
    _component_safe "$d" || return 1
  done
  return 0
}

write_unsafe_receipt() {
  _component_safe "$CONF_DIR/state" || return 0
  local tmp
  tmp="$(mktemp "$CONF_DIR/state/.stack-update-unsafe.XXXXXX" 2>/dev/null)" || return 0
  jq -n --arg now "$(now_iso)" --arg sid "${SESSION_ID:-}" '
    {schema:"stack-update/v1", hook_version:3, as_of:$now, status:"failed",
     reason:"unsafe-state-dir", session_id:$sid, needs_human:true}' > "$tmp" 2>/dev/null
  mv -f "$tmp" "$UNSAFE_RECEIPT" 2>/dev/null
}

RECEIPT_JSON="{}"
init_receipt_defaults() {
  local base="{}"
  if [[ -f "$RECEIPT" ]]; then
    base="$(cat "$RECEIPT" 2>/dev/null)"
    printf '%s' "$base" | jq -e . >/dev/null 2>&1 || base="{}"
  fi
  RECEIPT_JSON="$(printf '%s' "$base" | jq '{
    schema: "stack-update/v1", hook_version: 3, as_of: null, status: null,
    reason: null, session_id: null, repo: null, remote_url: null, tier: null,
    branch: null, source_branch: null, behind_before: null, behind_after: null,
    staged_sha: (.staged_sha // null), staged_at: (.staged_at // null),
    staged_count: (.staged_count // null), staged_subjects: (.staged_subjects // []),
    from_sha: null, to_sha: null, duration_ms: null, log: (.log // null),
    error: null, needs_human: false, profile_dir: null,
    consecutive_offline: (.consecutive_offline // 0), pack_pending: (.pack_pending // false),
    purges_pending: (.purges_pending // 0), fail_sha: (.fail_sha // null),
    consecutive_failures: (.consecutive_failures // 0), retry_after: (.retry_after // null),
    deadline_degraded: false
  }')"
}
rset() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --arg v "$2" '.[$k] = $v')"; }
rset_null() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" '.[$k] = null')"; }
rset_bool() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k] = $v')"; }
rset_num() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k] = $v')"; }
commit_receipt() {
  RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg now "$(now_iso)" '.as_of = $now')"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.receipt.XXXXXX" 2>/dev/null)" || return 1
  printf '%s' "$RECEIPT_JSON" > "$tmp"
  mv -f "$tmp" "$RECEIPT"
}

_open_fresh_log() {
  if [[ -e "$LOG" || -L "$LOG" ]]; then
    mv -f "$LOG" "$STATE_DIR/last-update.log.1" 2>/dev/null
  fi
  ( set -C; : > "$LOG" ) 2>/dev/null
}
append_log() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null; }

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null; }

acquire_lock() {
  local phase="$1"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    printf '%s' "$phase" > "$LOCK_DIR/phase" 2>/dev/null
    return 0
  fi
  local held_pid held_phase
  held_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  held_phase="$(cat "$LOCK_DIR/phase" 2>/dev/null)"
  [[ -z "$held_pid" ]] && return 2
  if kill -0 "$held_pid" 2>/dev/null; then
    local mtime now age
    mtime="$(stat -c '%Y' "$LOCK_DIR" 2>/dev/null || stat -f '%m' "$LOCK_DIR" 2>/dev/null)"
    now="$(date -u +%s)"
    age=$(( now - ${mtime:-now} ))
    (( age >= 1800 )) && return 3
    return 2
  fi
  local graveyard="$STATE_DIR/lock.reclaimed.$$.$(date -u +%s)"
  if mv "$LOCK_DIR" "$graveyard" 2>/dev/null; then
    RECLAIMED_PHASE="$held_phase"; RECLAIMED_DIR="$graveyard"
    return 4
  fi
  return 2
}

# Re-validate the pin and locate the canonical source repo (ADR-086 D10/D16).
# Sets PIN_TIER/PIN_REPO/PIN_REMOTE/CANON_REPO/STAMP_SRC_BRANCH on success.
# Returns 0 on success; on failure sets REVALIDATE_REASON and returns 1.
revalidate_pin() {
  REVALIDATE_REASON="malformed-stamp"
  [[ -f "$PIN" ]] || { REVALIDATE_REASON="no-pin"; return 1; }
  local pin_json
  pin_json="$(cat "$PIN" 2>/dev/null)"
  printf '%s' "$pin_json" | jq -e . >/dev/null 2>&1 || return 1
  [[ "$(printf '%s' "$pin_json" | jq -r '.schema // empty')" == "stack-update-pin/v2" ]] || return 1
  PIN_TIER="$(printf '%s' "$pin_json" | jq -r '.tier // empty')"
  PIN_REPO="$(printf '%s' "$pin_json" | jq -r '.source_repo // empty')"
  PIN_REMOTE="$(printf '%s' "$pin_json" | jq -r '.remote_url // empty')"
  [[ "$PIN_TIER" =~ ^[0-9]+$ ]] || return 1
  [[ "$PIN_REPO" == /* ]] || return 1
  [[ "$PIN_REPO" =~ ^[A-Za-z0-9._/\ -]+$ ]] || return 1
  _has_dotdot_segment "$PIN_REPO" && return 1
  [[ -n "$PIN_REMOTE" ]] || return 1
  [[ -f "$STAMP" ]] || { REVALIDATE_REASON="no-stamp"; return 1; }
  local stamp_json
  stamp_json="$(cat "$STAMP" 2>/dev/null)"
  printf '%s' "$stamp_json" | jq -e . >/dev/null 2>&1 || return 1
  local stamp_repo stamp_tier
  stamp_repo="$(printf '%s' "$stamp_json" | jq -r '.source_repo // empty')"
  stamp_tier="$(printf '%s' "$stamp_json" | jq -r '.tier // empty')"
  STAMP_SRC_BRANCH="$(printf '%s' "$stamp_json" | jq -r '.source_branch // "main"')"
  if [[ "$stamp_repo" != "$PIN_REPO" ]] || { [[ -n "$stamp_tier" ]] && [[ "$stamp_tier" != "$PIN_TIER" ]]; }; then
    REVALIDATE_REASON="pin-mismatch"; return 1
  fi
  [[ -e "$PIN_REPO" ]] || { REVALIDATE_REASON="repo-missing"; return 1; }
  CANON_REPO="$(_canon_path "$PIN_REPO")"
  [[ -n "$CANON_REPO" && "$CANON_REPO" == "$PIN_REPO" ]] || return 1
  local toplevel toplevel_canon
  toplevel="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$toplevel" ]] || return 1
  toplevel_canon="$(_canon_path "$toplevel")"
  [[ "$toplevel_canon" == "$CANON_REPO" ]] || return 1
  local actual_remote
  actual_remote="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" remote get-url origin 2>/dev/null)"
  if [[ "$actual_remote" != "$PIN_REMOTE" ]]; then
    REVALIDATE_REASON="remote-mismatch"; return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Internal worker mode — re-invocation of this same script, detached into
# its own process group, that performs the never-killed apply sequence
# (D13 apply steps 4-7) and writes the FINAL receipt when done. Everything
# it needs travels via environment variables exported by the foreground
# before it backgrounds this.
# ─────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--internal-apply-worker" ]]; then
  # D17 re-check across the detached-process boundary (finding #8). The
  # foreground validated state_dir_safe before launching this worker, but
  # that validation does not carry over a fork/exec into a new process
  # group -- a symlink swap timed to land in the gap would otherwise bypass
  # D17 entirely for every byte this worker writes.
  state_dir_safe || { write_unsafe_receipt; exit 0; }

  CANON_REPO="$_SU_APPLY_REPO"
  PIN_TIER="$_SU_APPLY_TIER"
  STAMP_SRC_BRANCH="$_SU_APPLY_SRC_BRANCH"
  STAGED_SHA="$_SU_APPLY_STAGED_SHA"

  printf '=== apply worker start %s (staged %s) ===\n' "$(now_iso)" "$STAGED_SHA" >>"$LOG" 2>&1

  rset_run_context() {
    rset repo "$CANON_REPO"
    rset remote_url "$(sanitize_text "$_SU_APPLY_REMOTE_URL" 200)"
    rset_num tier "$PIN_TIER"
    rset source_branch "$(sanitize_text "$STAMP_SRC_BRANCH" 200)"
  }

  finalize_and_release() {  # finalize_and_release <status> <reason-or-empty> <needs_human>
    init_receipt_defaults
    rset_run_context
    rset status "$1"
    [[ -n "${2:-}" ]] && rset reason "$2" || rset_null reason
    rset_bool needs_human "$([[ "${3:-0}" == "1" ]] && echo true || echo false)"
    commit_receipt
    release_lock
  }

  if ! git -c core.hooksPath=/dev/null -C "$CANON_REPO" merge --ff-only "$STAGED_SHA" >>"$LOG" 2>&1; then
    finalize_and_release failed stage-mismatch 1
    exit 0
  fi
  ACTUAL_HEAD="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse HEAD 2>/dev/null)"
  DIRTY_AFTER="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" status --porcelain 2>/dev/null)"
  if [[ "$ACTUAL_HEAD" != "$STAGED_SHA" || -n "$DIRTY_AFTER" ]]; then
    finalize_and_release failed stage-mismatch 1
    exit 0
  fi

  UPD_OUT="$(mktemp 2>/dev/null || echo /dev/null)"
  START_MS=$(( $(date -u +%s) * 1000 ))
  STACK_INSESSION=1 STACK_UPDATE_MODE=hook STACK_UPDATE_VIA_HOOK=1 STACK_UPDATE_NO_PULL=1 \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" \
    bash "$CANON_REPO/scripts/update.sh" --tier="$PIN_TIER" < /dev/null >"$UPD_OUT" 2>&1
  UPDATE_RC=$?
  END_MS=$(( $(date -u +%s) * 1000 ))
  {
    printf '=== update.sh output (rc=%s) ===\n' "$UPDATE_RC"
    cat "$UPD_OUT" 2>/dev/null
  } >>"$LOG" 2>&1

  init_receipt_defaults
  rset_run_context
  rset_num duration_ms $(( END_MS - START_MS ))

  if (( UPDATE_RC == 0 )); then
    rset from_sha "$_SU_APPLY_FROM_SHA"
    rset to_sha "$STAGED_SHA"
    rset_num behind_after 0
    rset status updated
    rset_null reason
    rset_bool needs_human false
    rset_null fail_sha
    rset_num consecutive_failures 0
    rset_null retry_after

    # Finding #10: thread install.sh's hook-mode deferral markers into the
    # FINAL receipt. install.sh (STACK_UPDATE_MODE=hook, ADR-086 D11) writes
    # state/pack-pending.json when a pack change needed a confirmation it
    # could not ask for, and removes it when a pack composes cleanly;
    # gen-alias-stubs.sh writes state/alias-pending-purge.json's
    # pending_purge array for deferred alias purges. init_receipt_defaults'
    # carry-forward default (.pack_pending // false) only ever repeats the
    # PRIOR receipt's value -- it never re-reads these files, so a deferral
    # from THIS run stayed invisible until now. Compute both fresh, from
    # what update.sh/install.sh actually left on disk this run.
    PACK_PENDING_NOW="false"
    [[ -f "$CONF_DIR/state/pack-pending.json" ]] && PACK_PENDING_NOW="true"
    rset_bool pack_pending "$PACK_PENDING_NOW"
    PURGES_PENDING_NOW="$(jq -r '.pending_purge | length' "$CONF_DIR/state/alias-pending-purge.json" 2>/dev/null)"
    [[ "$PURGES_PENDING_NOW" =~ ^[0-9]+$ ]] || PURGES_PENDING_NOW=0
    rset_num purges_pending "$PURGES_PENDING_NOW"

    commit_receipt
    release_lock
  else
    FIRST_ERR_LINE="$(head -n1 "$UPD_OUT" 2>/dev/null)"
    ERR_SANITIZED="$(sanitize_text "$FIRST_ERR_LINE" 200 "$UPDATE_RC")"
    rset error "$ERR_SANITIZED"
    rset status failed
    rset reason exit-nonzero
    rset_bool needs_human true
    PREV_FAIL_SHA="$(printf '%s' "$RECEIPT_JSON" | jq -r '.fail_sha // empty')"
    PREV_CONSEC="$(printf '%s' "$RECEIPT_JSON" | jq -r '.consecutive_failures // 0')"
    if [[ "$PREV_FAIL_SHA" == "$STAGED_SHA" ]]; then
      NEW_CONSEC=$(( PREV_CONSEC + 1 ))
    else
      NEW_CONSEC=1
    fi
    (( NEW_CONSEC > 20 )) && NEW_CONSEC=20
    DELTA=$(( 600 * (1 << (NEW_CONSEC - 1)) ))
    (( DELTA > 86400 )) && DELTA=86400
    RETRY_EPOCH=$(( $(date -u +%s) + DELTA ))
    RETRY_AFTER_ISO="$(date -u -r "$RETRY_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$RETRY_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    rset fail_sha "$STAGED_SHA"
    rset_num consecutive_failures "$NEW_CONSEC"
    rset retry_after "$RETRY_AFTER_ISO"
    commit_receipt
    release_lock
  fi
  rm -f "$UPD_OUT" 2>/dev/null
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# Fast path (T61) — one stat, one exit, on every turn with nothing staged.
# ─────────────────────────────────────────────────────────────────────────
[[ -f "$CONSENT" ]] || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

state_dir_safe || { write_unsafe_receipt; exit 0; }

# Consume first, act second (D15 step3): a crashing/failing apply cannot
# re-fire on every subsequent prompt, and an invalid consent cannot linger.
mv -f "$CONSENT" "$CONSENT_USED" 2>/dev/null || exit 0
CONSENT_JSON="$(cat "$CONSENT_USED" 2>/dev/null)"

not_applied() {  # not_applied <reason> <display-text>
  init_receipt_defaults
  rset status blocked
  rset reason "$1"
  rset session_id "$SESSION_ID"
  rset_bool needs_human false
  commit_receipt
  printf '[stack-update] not applied — %s.\n' "$2"
  exit 0
}

# D13 apply step1/step2 re-verify failures (ADR-086): unlike D15 step4's
# consent-shape checks (blocked/consent-stale), these are a specifically
# named receipt reason with needs_human:true -- "nothing is trusted across
# the consent gap" and a human should look, not just wait for the next boot.
stage_mismatch_refuse() {
  init_receipt_defaults
  rset status failed
  rset reason stage-mismatch
  rset session_id "$SESSION_ID"
  rset_bool needs_human true
  commit_receipt
  printf "[stack-update] not applied — staged content didn't verify.\n"
  exit 0
}

printf '%s' "$CONSENT_JSON" | jq -e . >/dev/null 2>&1 || not_applied consent-stale "nothing staged"
[[ "$(printf '%s' "$CONSENT_JSON" | jq -r '.schema // empty')" == "stack-update-consent/v1" ]] \
  || not_applied consent-stale "nothing staged"

CONSENT_STAGED_SHA="$(printf '%s' "$CONSENT_JSON" | jq -r '.staged_sha // empty')"
CONSENT_SESSION="$(printf '%s' "$CONSENT_JSON" | jq -r '.session_id // empty')"
CONSENT_GRANTED="$(printf '%s' "$CONSENT_JSON" | jq -r '.granted_at // empty')"
CONSENT_DOOR="$(printf '%s' "$CONSENT_JSON" | jq -r '.door // empty')"

[[ "$CONSENT_STAGED_SHA" =~ ^[0-9a-f]{40}$ ]] || not_applied consent-stale "nothing staged"
# Finding #6: both sides must be non-empty before comparing -- an empty
# consent session_id compared against an empty payload session_id (e.g. a
# non-interactive or malformed UserPromptSubmit payload) would otherwise
# pass as "bound," which is not actually bound to anything.
[[ -n "$CONSENT_SESSION" && -n "$SESSION_ID" && "$CONSENT_SESSION" == "$SESSION_ID" ]] \
  || not_applied consent-stale "nothing staged"

GRANTED_EPOCH="$(_to_epoch "$CONSENT_GRANTED" || true)"
[[ -n "${GRANTED_EPOCH:-}" ]] || not_applied consent-stale "nothing staged"
NOW_EPOCH="$(date -u +%s)"
CONSENT_AGE_S=$(( NOW_EPOCH - GRANTED_EPOCH ))
# Finding #5: a forged/malformed future granted_at must not pass forever --
# require 0 <= age <= 900, not just age <= 900 (a negative delta from a
# future timestamp always satisfied the old upper-bound-only check).
(( CONSENT_AGE_S >= 0 && CONSENT_AGE_S <= 900 )) || not_applied consent-expired "consent expired"

[[ -f "$RECEIPT" ]] || not_applied consent-stale "nothing staged"
R_JSON="$(cat "$RECEIPT" 2>/dev/null)"
printf '%s' "$R_JSON" | jq -e . >/dev/null 2>&1 || not_applied consent-stale "nothing staged"
R_STATUS="$(printf '%s' "$R_JSON" | jq -r '.status // empty')"
R_STAGED_SHA="$(printf '%s' "$R_JSON" | jq -r '.staged_sha // empty')"
[[ "$R_STATUS" == "staged" ]] || not_applied consent-stale "nothing staged"
[[ "$R_STAGED_SHA" == "$CONSENT_STAGED_SHA" ]] || not_applied consent-stale "nothing staged"
R_FROM_SHA="$(printf '%s' "$R_JSON" | jq -r '(.to_sha // .staged_sha // empty)')"
R_FROM_SHA_ORIG="$(git -c core.hooksPath=/dev/null -C "$(printf '%s' "$R_JSON" | jq -r '.repo // empty')" rev-parse HEAD 2>/dev/null)"
[[ -n "$R_FROM_SHA_ORIG" ]] && R_FROM_SHA="$R_FROM_SHA_ORIG"

# D13 apply step1 — re-verify D17 (already done), D10, D16. Nothing is
# trusted across the consent gap.
if ! revalidate_pin; then
  stage_mismatch_refuse
fi
[[ "$CANON_REPO" == "$(printf '%s' "$R_JSON" | jq -r '.repo // empty')" ]] || stage_mismatch_refuse

# D13 apply step2 — re-verify clean, on source_branch, staged_sha still a
# local descendant.
[[ -z "$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" status --porcelain 2>/dev/null)" ]] || stage_mismatch_refuse
[[ "$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" branch --show-current 2>/dev/null)" == "$STAMP_SRC_BRANCH" ]] || stage_mismatch_refuse
git -c core.hooksPath=/dev/null -C "$CANON_REPO" cat-file -e "$CONSENT_STAGED_SHA" 2>/dev/null || stage_mismatch_refuse
git -c core.hooksPath=/dev/null -C "$CANON_REPO" merge-base --is-ancestor HEAD "$CONSENT_STAGED_SHA" 2>/dev/null || stage_mismatch_refuse

# D13 apply step3 — take the lock, phase: apply.
acquire_lock apply
LOCK_RC=$?
case "$LOCK_RC" in
  2) exit 0 ;;
  3)
    init_receipt_defaults
    rset status failed; rset reason stuck; rset_bool needs_human true
    commit_receipt
    exit 0
    ;;
  4)
    if [[ "$RECLAIMED_PHASE" == "apply" ]]; then
      # A half-applied install is the highest-risk failure state (finding
      # #4) -- record it and STOP this run rather than proceeding to a
      # fresh apply that could overwrite it with updated/failed in the same
      # invocation, hiding it. The consumed consent is spent either way (D15
      # step3, "consume first"); the next staged offer starts clean.
      init_receipt_defaults
      rset repo "$CANON_REPO"; rset remote_url "$(sanitize_text "$PIN_REMOTE" 200)"; rset_num tier "$PIN_TIER"
      rset source_branch "$(sanitize_text "$STAMP_SRC_BRANCH" 200)"; rset session_id "$SESSION_ID"
      rset status failed; rset reason partial; rset_bool needs_human true
      commit_receipt
      rm -rf "$RECLAIMED_DIR" 2>/dev/null
      exit 0
    fi
    # A reclaimed STAGE-phase lock is recorded as nothing at all — a killed
    # fetch mutated nothing (D4) — so this run proceeds normally below.
    rm -rf "$RECLAIMED_DIR" 2>/dev/null
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then exit 0; fi
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    printf 'apply' > "$LOCK_DIR/phase" 2>/dev/null
    ;;
esac

# D15 step5 — set status:"applying", then run D13's apply sequence.
init_receipt_defaults
rset status applying
rset_null reason
rset session_id "$SESSION_ID"
rset repo "$CANON_REPO"
rset remote_url "$(sanitize_text "$PIN_REMOTE" 200)"
rset_num tier "$PIN_TIER"
rset source_branch "$(sanitize_text "$STAMP_SRC_BRANCH" 200)"
rset_bool needs_human false
rset log "$LOG"
commit_receipt
_open_fresh_log
append_log "=== stack-update-apply run $(now_iso) (session $SESSION_ID, staged $CONSENT_STAGED_SHA) ==="

export _SU_APPLY_REPO="$CANON_REPO"
export _SU_APPLY_TIER="$PIN_TIER"
export _SU_APPLY_SRC_BRANCH="$STAMP_SRC_BRANCH"
export _SU_APPLY_STAGED_SHA="$CONSENT_STAGED_SHA"
export _SU_APPLY_FROM_SHA="$R_FROM_SHA"
export _SU_APPLY_REMOTE_URL="$PIN_REMOTE"

if command -v setsid >/dev/null 2>&1; then
  setsid "$_SELF" --internal-apply-worker >>"$LOG" 2>&1 &
elif command -v perl >/dev/null 2>&1; then
  perl -e 'setpgrp(0,0); exec @ARGV' -- "$_SELF" --internal-apply-worker >>"$LOG" 2>&1 &
else
  "$_SELF" --internal-apply-worker >>"$LOG" 2>&1 &
fi
WORKER_PID=$!
disown "$WORKER_PID" 2>/dev/null || true

# ADR-086 D4/D15 fix (cross-family review finding #2): the lock must record
# the DETACHED WORKER's pid, not the foreground hook's own $$ (written by
# acquire_lock above before the worker existed). Liveness checks (kill -0)
# and the stuck-lock age check both key off lock/pid -- if it still named
# the foreground process, a contender could see it die (when the foreground
# exits after the wait budget below) and reclaim a lock whose apply worker
# is still alive, racing a second writer into the same install.
printf '%s' "$WORKER_PID" > "$LOCK_DIR/pid" 2>/dev/null

WAIT_START=$SECONDS
while kill -0 "$WORKER_PID" 2>/dev/null; do
  if (( SECONDS - WAIT_START >= APPLY_BUDGET_S )); then
    init_receipt_defaults
    rset status running
    rset_null reason
    rset_bool needs_human false
    commit_receipt
    printf '[stack-update] still running — it will finish in the background.\n'
    exit 0
  fi
  sleep 0.3
done
wait "$WORKER_PID" 2>/dev/null

FINAL_JSON="$(cat "$RECEIPT" 2>/dev/null)"
FINAL_STATUS="$(printf '%s' "$FINAL_JSON" | jq -r '.status // empty')"
FINAL_TO_SHA="$(printf '%s' "$FINAL_JSON" | jq -r '.to_sha // empty')"
FINAL_ERROR="$(printf '%s' "$FINAL_JSON" | jq -r '.error // empty')"

case "$FINAL_STATUS" in
  updated)
    printf '[stack-update] applied — now at %s (%s changes).\n' \
      "${FINAL_TO_SHA:0:7}" "$(printf '%s' "$R_JSON" | jq -r '.staged_count // 0')"
    ;;
  failed)
    printf '[stack-update] failed — "%s". See %s.\n' "$FINAL_ERROR" "$LOG"
    ;;
  *)
    printf '[stack-update] not applied — staged content did'"'"'t verify.\n'
    ;;
esac
exit 0
