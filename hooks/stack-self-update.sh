#!/usr/bin/env bash
# summary: SessionStart hook — probes stack freshness and stages (fetch-only) a pin-verified update into the source repo's refs; NEVER applies, NEVER writes into ~/.claude (ADR-086 D1-D6, D13, D16-D20).
#
# This is the ONLY sanctioned in-session entry point to the staging phase.
# It writes exactly one file the model cannot forge into anything dangerous:
# <conf>/state/stack-update/receipt.json (denyWrite-protected, ADR-086 D17).
#
# It never runs update.sh, never runs install.sh, never touches the working
# tree of the source repo beyond a `git fetch` into .git/, and never touches
# ~/.claude. The apply step (hooks/stack-update-apply.sh) is a SEPARATE hook
# that only runs after a human has consented (ADR-086 D14/D15).
#
# stdin  : SessionStart hook JSON — { hook_event_name, source, session_id, ... }
# stdout : NOTHING, ever (D1 — hook stdout can leak into the plain face).
# exit   : 0, always (a self-updater that can block a session start has
#          converted a staleness problem into an inability to work).
#
# lib/stack-freshness.sh is NOT modified by this hook and is treated as a
# read-only dependency — its --oneline tokens are the contract (ADR-086,
# "Files NOT to touch").
set -uo pipefail

# Finding #1 (cross-family review): a repo-local hook planted in the source
# repo's .git/hooks/ (post-merge, reference-transaction, ...) must never
# execute during a privileged git operation this hook performs, independent
# of pin/stamp validation. Every direct `git` call below also carries an
# explicit `-c core.hooksPath=/dev/null` (belt-and-suspenders), but this
# process-wide env-var form is what closes the gap for `lib/stack-
# freshness.sh` too: that file runs its own `git fetch` internally and is
# NOT modified by this ADR ("Files NOT to touch"), yet it is invoked as a
# child process (`bash "$FRESHNESS_LIB" --oneline` below) that inherits this
# exported environment — so its git calls get the same protection without
# touching the file.
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=core.hooksPath
GIT_CONFIG_VALUE_0=/dev/null
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

_HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

PROBE_DEADLINE_S="${STACK_UPDATE_PROBE_DEADLINE_S:-8}"
LOCK_STUCK_S="${STACK_UPDATE_LOCK_STUCK_S:-1800}"
COOLDOWN_S="${STACK_UPDATE_COOLDOWN_S:-600}"

DEADLINE_DEGRADED_FLAG=0
SESSION_ID=""
RECEIPT_JSON="{}"

# ─────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# Portable epoch parser: GNU `date -d`, then BSD `date -j -f`.
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

# D19(a) — sanitize free text at write time. sanitize_text <raw> <maxlen> [rc]
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

# D18 — run a command under a process-group deadline. Writes combined
# stdout+stderr to $2. Sets DEADLINE_DEGRADED_FLAG=1 if no pgroup tool is
# available. Returns 124 on timeout, else the command's own exit code.
run_with_deadline() {
  local secs="$1" outfile="$2"; shift 2
  local pgroup=1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$outfile" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'setpgrp(0,0); exec @ARGV' -- "$@" >"$outfile" 2>&1 &
  else
    pgroup=0
    DEADLINE_DEGRADED_FLAG=1
    "$@" >"$outfile" 2>&1 &
  fi
  local pid=$! start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= secs )); then
      if (( pgroup == 1 )); then kill -TERM -- "-$pid" 2>/dev/null; else kill -TERM "$pid" 2>/dev/null; fi
      local kstart=$SECONDS
      while kill -0 "$pid" 2>/dev/null && (( SECONDS - kstart < 2 )); do sleep 0.2; done
      if kill -0 "$pid" 2>/dev/null; then
        if (( pgroup == 1 )); then kill -KILL -- "-$pid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
      fi
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

# ─────────────────────────────────────────────────────────────────────────
# D17(2) — ownership/symlink discipline. Verified before the log is opened,
# before the lock is taken, before the receipt is written.
# ─────────────────────────────────────────────────────────────────────────

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
  jq -n --arg now "$(now_iso)" --arg sid "$SESSION_ID" '
    {schema:"stack-update/v1", hook_version:3, as_of:$now, status:"failed",
     reason:"unsafe-state-dir", session_id:$sid, needs_human:true}' > "$tmp" 2>/dev/null
  mv -f "$tmp" "$UNSAFE_RECEIPT" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────
# Receipt bookkeeping — incremental merge onto a bash variable, atomic write.
# ─────────────────────────────────────────────────────────────────────────

init_receipt_defaults() {
  local base="{}"
  if [[ -f "$RECEIPT" ]]; then
    base="$(cat "$RECEIPT" 2>/dev/null)"
    printf '%s' "$base" | jq -e . >/dev/null 2>&1 || base="{}"
  fi
  RECEIPT_JSON="$(printf '%s' "$base" | jq '{
    schema: "stack-update/v1",
    hook_version: 3,
    as_of: null,
    status: null,
    reason: null,
    session_id: null,
    repo: null,
    remote_url: null,
    tier: null,
    branch: null,
    source_branch: null,
    behind_before: null,
    behind_after: null,
    staged_sha: null,
    staged_at: null,
    staged_count: null,
    staged_subjects: [],
    from_sha: null,
    to_sha: null,
    duration_ms: null,
    log: (.log // null),
    error: null,
    needs_human: false,
    profile_dir: null,
    consecutive_offline: (.consecutive_offline // 0),
    pack_pending: (.pack_pending // false),
    purges_pending: (.purges_pending // 0),
    fail_sha: (.fail_sha // null),
    consecutive_failures: (.consecutive_failures // 0),
    retry_after: (.retry_after // null),
    deadline_degraded: false
  }')"
}

rset() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --arg v "$2" '.[$k] = $v')"; }
rset_null() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" '.[$k] = null')"; }
rset_bool() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k] = $v')"; }
rset_num() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k] = $v')"; }
rset_raw() { RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k] = $v')"; }

commit_receipt() {
  RECEIPT_JSON="$(printf '%s' "$RECEIPT_JSON" | jq --arg now "$(now_iso)" '.as_of = $now')"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.receipt.XXXXXX" 2>/dev/null)" || return 1
  printf '%s' "$RECEIPT_JSON" > "$tmp"
  mv -f "$tmp" "$RECEIPT"
}

# D17 leaf-file rule — rotate .log -> .log.1 with `mv` (moves a symlink
# rather than following it), then create a fresh regular .log with `set -C`
# (O_CREAT|O_EXCL — fails on any pre-existing path, including a symlink).
_open_fresh_log() {
  if [[ -e "$LOG" || -L "$LOG" ]]; then
    mv -f "$LOG" "$STATE_DIR/last-update.log.1" 2>/dev/null
  fi
  ( set -C; : > "$LOG" ) 2>/dev/null
}
append_log() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────
# Single-flight lock (D4 rev 2/3). acquire_lock <phase> sets $LOCK_RC:
#   0 = acquired.  2 = contended (live, fresh) — caller exits 0, untouched.
#   3 = stuck (live, >=30min) — caller writes failed/stuck.
#   4 = reclaimed (dead pid) — $RECLAIMED_PHASE tells the caller whether the
#       interrupted run needs to be recorded as failed/partial.
# ─────────────────────────────────────────────────────────────────────────

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
  if [[ -z "$held_pid" ]]; then
    return 2   # window between owner's mkdir and pid write — treat as live
  fi
  if kill -0 "$held_pid" 2>/dev/null; then
    local mtime now age
    mtime="$(stat -c '%Y' "$LOCK_DIR" 2>/dev/null || stat -f '%m' "$LOCK_DIR" 2>/dev/null)"
    now="$(date -u +%s)"
    age=$(( now - ${mtime:-now} ))
    if (( age >= LOCK_STUCK_S )); then return 3; fi
    return 2
  fi
  local graveyard="$STATE_DIR/lock.reclaimed.$$.$(date -u +%s)"
  if mv "$LOCK_DIR" "$graveyard" 2>/dev/null; then
    RECLAIMED_PHASE="$held_phase"
    RECLAIMED_DIR="$graveyard"
    return 4
  fi
  return 2
}

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────
# D6 gate 1 — payload gate. Also the anti-invocation control (D7): invoked
# without a SessionStart payload on stdin, this hook does nothing and exits 0.
# ─────────────────────────────────────────────────────────────────────────

INPUT="$(cat 2>/dev/null || echo '{}')"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

[[ "$HOOK_EVENT" == "SessionStart" && "$SOURCE" == "startup" ]] || exit 0

# ─────────────────────────────────────────────────────────────────────────
# D3 row 0 / D17(1) — state dir safety, before anything else in the eligible
# path (log, lock, receipt all live under it).
# ─────────────────────────────────────────────────────────────────────────

state_dir_safe || { write_unsafe_receipt; exit 0; }

# ─────────────────────────────────────────────────────────────────────────
# D6 gates 2/2b/2c — cooldown, already-staged, backoff. Read the existing
# receipt (safe now) before doing any work.
# ─────────────────────────────────────────────────────────────────────────

EX_STATUS="" EX_AS_OF="" EX_STAGED_SHA="" EX_REPO="" EX_SRC_BRANCH="" EX_FAIL_SHA="" EX_RETRY_AFTER=""
if [[ -f "$RECEIPT" ]]; then
  EX_JSON="$(cat "$RECEIPT" 2>/dev/null)"
  if printf '%s' "$EX_JSON" | jq -e . >/dev/null 2>&1; then
    EX_STATUS="$(printf '%s' "$EX_JSON" | jq -r '.status // empty')"
    EX_AS_OF="$(printf '%s' "$EX_JSON" | jq -r '.as_of // empty')"
    EX_STAGED_SHA="$(printf '%s' "$EX_JSON" | jq -r '.staged_sha // empty')"
    EX_REPO="$(printf '%s' "$EX_JSON" | jq -r '.repo // empty')"
    EX_SRC_BRANCH="$(printf '%s' "$EX_JSON" | jq -r '.source_branch // empty')"
    EX_FAIL_SHA="$(printf '%s' "$EX_JSON" | jq -r '.fail_sha // empty')"
    EX_RETRY_AFTER="$(printf '%s' "$EX_JSON" | jq -r '.retry_after // empty')"
  fi
fi

NOW_EPOCH="$(date -u +%s)"

# gate 2 — cooldown
if [[ -n "$EX_AS_OF" ]]; then
  AS_OF_EPOCH="$(_to_epoch "$EX_AS_OF" || true)"
  if [[ -n "${AS_OF_EPOCH:-}" ]] && (( NOW_EPOCH - AS_OF_EPOCH < COOLDOWN_S )); then
    exit 0
  fi
fi

# gate 2b — already staged at the current local tip
if [[ "$EX_STATUS" == "staged" && -n "$EX_STAGED_SHA" && -n "$EX_REPO" && -n "$EX_SRC_BRANCH" ]]; then
  if [[ -d "$EX_REPO/.git" ]]; then
    LOCAL_TIP="$(git -c core.hooksPath=/dev/null -C "$EX_REPO" rev-parse -q --verify "refs/remotes/origin/$EX_SRC_BRANCH" 2>/dev/null)"
    [[ -n "$LOCAL_TIP" && "$LOCAL_TIP" == "$EX_STAGED_SHA" ]] && exit 0
  fi
fi

# gate 2c — backoff (D20)
if [[ -n "$EX_RETRY_AFTER" && "$EX_RETRY_AFTER" != "null" && -n "$EX_FAIL_SHA" && -n "$EX_REPO" && -n "$EX_SRC_BRANCH" ]]; then
  RETRY_EPOCH="$(_to_epoch "$EX_RETRY_AFTER" || true)"
  if [[ -n "${RETRY_EPOCH:-}" ]] && (( NOW_EPOCH < RETRY_EPOCH )) && [[ -d "$EX_REPO/.git" ]]; then
    LOCAL_TIP2="$(git -c core.hooksPath=/dev/null -C "$EX_REPO" rev-parse -q --verify "refs/remotes/origin/$EX_SRC_BRANCH" 2>/dev/null)"
    if [[ "$LOCAL_TIP2" == "$EX_FAIL_SHA" ]]; then
      init_receipt_defaults
      rset status skipped
      rset reason backoff
      rset_bool needs_human "$(printf '%s' "$EX_JSON" | jq '.needs_human // false')"
      rset session_id "$SESSION_ID"
      # The last real failure keeps rendering while in backoff (D8/ADR-085):
      # carry its context forward rather than resetting to nulls.
      EX_ERROR="$(printf '%s' "$EX_JSON" | jq -r '.error // empty')"
      [[ -n "$EX_ERROR" ]] && rset error "$EX_ERROR"
      rset repo "$EX_REPO"
      rset source_branch "$(sanitize_text "$EX_SRC_BRANCH" 200)"
      commit_receipt
      exit 0
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Begin the real run.
# ─────────────────────────────────────────────────────────────────────────

init_receipt_defaults
rset session_id "$SESSION_ID"
rset log "$LOG"

# LOCK_HELD tracks whether THIS process currently owns $LOCK_DIR. It starts
# false; the D4/D13 lock acquisition below (taken before the probe, the log
# rotation, and every receipt write from that point on — cross-family review
# finding #3) flips it true only once this process's own `mkdir` has
# succeeded. finish() below release_locks iff LOCK_HELD is true — never
# unconditionally, since a "contended" or "stuck" caller does NOT own the
# lock and must not delete someone else's live one.
LOCK_HELD=0

finish() {  # finish <status> <reason-or-empty> <needs_human 0|1>
  rset status "$1"
  [[ -n "${2:-}" ]] && rset reason "$2" || rset_null reason
  rset_bool needs_human "$([[ "${3:-0}" == "1" ]] && echo true || echo false)"
  (( LOCK_HELD == 1 )) && release_lock
  commit_receipt
  exit 0
}

# D3 rows 2/3 — stamp presence (existence only; content is read after the
# pin is confirmed present so the pin — never the stamp — locates the repo).
IS_PROFILE=0
[[ "$CONF_DIR" != "$HOME/.claude" ]] && IS_PROFILE=1
if [[ ! -f "$STAMP" ]]; then
  if (( IS_PROFILE == 1 )); then
    rset profile_dir "$CONF_DIR"
    finish skipped unstamped-profile 0
  fi
  finish skipped no-stamp 0
fi

# D3 row 4 — pin presence.
[[ -f "$PIN" ]] || finish skipped no-pin 0

PIN_JSON="$(cat "$PIN" 2>/dev/null)"
printf '%s' "$PIN_JSON" | jq -e . >/dev/null 2>&1 || finish failed malformed-stamp 1

PIN_SCHEMA="$(printf '%s' "$PIN_JSON" | jq -r '.schema // empty')"
if [[ "$PIN_SCHEMA" == "stack-update-pin/v1" ]]; then
  finish skipped pin-outdated 0
fi
[[ "$PIN_SCHEMA" == "stack-update-pin/v2" ]] || finish failed malformed-stamp 1

PIN_TIER="$(printf '%s' "$PIN_JSON" | jq -r '.tier // empty')"
PIN_REPO="$(printf '%s' "$PIN_JSON" | jq -r '.source_repo // empty')"
PIN_REMOTE="$(printf '%s' "$PIN_JSON" | jq -r '.remote_url // empty')"

[[ -n "$PIN_TIER" && "$PIN_TIER" =~ ^[0-9]+$ ]] || finish failed malformed-stamp 1
[[ -n "$PIN_REPO" && "$PIN_REPO" == /* ]] || finish failed malformed-stamp 1
[[ "$PIN_REPO" =~ ^[A-Za-z0-9._/\ -]+$ ]] || finish failed malformed-stamp 1
_has_dotdot_segment "$PIN_REPO" && finish failed malformed-stamp 1
[[ -n "$PIN_REMOTE" ]] || finish failed malformed-stamp 1

# D3 row 5 — stamp must also parse with required fields.
STAMP_JSON="$(cat "$STAMP" 2>/dev/null)"
printf '%s' "$STAMP_JSON" | jq -e . >/dev/null 2>&1 || finish failed malformed-stamp 1
STAMP_REPO="$(printf '%s' "$STAMP_JSON" | jq -r '.source_repo // empty')"
STAMP_TIER="$(printf '%s' "$STAMP_JSON" | jq -r '.tier // empty')"
STAMP_SRC_BRANCH="$(printf '%s' "$STAMP_JSON" | jq -r '.source_branch // "main"')"
[[ -n "$STAMP_REPO" ]] || finish failed malformed-stamp 1

# D3 row 6 — pin vs stamp cross-check. The pin wins; disagreement refuses.
{ [[ "$STAMP_REPO" != "$PIN_REPO" ]] || [[ -n "$STAMP_TIER" && "$STAMP_TIER" != "$PIN_TIER" ]]; } \
  && finish blocked pin-mismatch 1

# D3 row 7 / D10 rev-3 path identity.
[[ -e "$PIN_REPO" ]] || finish skipped repo-missing 0
CANON_REPO="$(_canon_path "$PIN_REPO")"
[[ -n "$CANON_REPO" && "$CANON_REPO" == "$PIN_REPO" ]] || finish failed malformed-stamp 1
TOPLEVEL="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$TOPLEVEL" ]] || finish failed malformed-stamp 1
TOPLEVEL_CANON="$(_canon_path "$TOPLEVEL")"
[[ "$TOPLEVEL_CANON" == "$CANON_REPO" ]] || finish failed malformed-stamp 1

# D3 row 6a / D16 — remote identity, byte-exact, before ANY network call.
ACTUAL_REMOTE="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" remote get-url origin 2>/dev/null)"
[[ "$ACTUAL_REMOTE" == "$PIN_REMOTE" ]] || finish blocked remote-mismatch 1

rset repo "$CANON_REPO"
rset remote_url "$(sanitize_text "$PIN_REMOTE" 200)"
rset_num tier "$PIN_TIER"
rset source_branch "$(sanitize_text "$STAMP_SRC_BRANCH" 200)"

# ─────────────────────────────────────────────────────────────────────────
# D4/D13 — single-flight lock, taken HERE: before the freshness probe, the
# log rotation, and every receipt write downstream of it (current/offline/
# dirty/branch/staged, all of it) — never after. This is the fix for the
# cross-family review's finding #3 ("the stager checks the lock too late,
# can trample a live apply's receipt"): the same lock instance now covers
# the probe, the preconditions and the staging fetch below, so a stage can
# never start — and can never write a byte — while an apply is running.
# ─────────────────────────────────────────────────────────────────────────

acquire_lock stage
LOCK_RC=$?
case "$LOCK_RC" in
  2) exit 0 ;;  # contended, receipt (and log) untouched (row 15)
  3) finish failed stuck 1 ;;
  4)
    if [[ "$RECLAIMED_PHASE" == "apply" ]]; then
      # A half-applied install is the highest-risk failure state (finding
      # #4) -- record it and STOP this run rather than proceeding to stage
      # a fresh receipt over it in the same invocation, which would hide
      # it. The next fire gets a clean, unlocked state and reports normally.
      init_receipt_defaults
      rset session_id "$SESSION_ID"
      rset repo "$CANON_REPO"
      rset remote_url "$(sanitize_text "$PIN_REMOTE" 200)"
      rset_num tier "$PIN_TIER"
      rset source_branch "$(sanitize_text "$STAMP_SRC_BRANCH" 200)"
      rset status failed
      rset reason partial
      rset_bool needs_human true
      commit_receipt
      rm -rf "$RECLAIMED_DIR" 2>/dev/null
      exit 0
    fi
    # A reclaimed STAGE-phase lock is recorded as nothing at all — a killed
    # fetch mutated nothing (D4) — so this run proceeds normally below.
    rm -rf "$RECLAIMED_DIR" 2>/dev/null
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then exit 0; fi
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    printf 'stage' > "$LOCK_DIR/phase" 2>/dev/null
    LOCK_HELD=1
    ;;
  0) LOCK_HELD=1 ;;
esac

_open_fresh_log
append_log "=== stack-self-update run $(now_iso) (session $SESSION_ID) ==="

# ─────────────────────────────────────────────────────────────────────────
# D1 step 5 — probe freshness under an 8s process-group deadline.
# ─────────────────────────────────────────────────────────────────────────

GIT_TERMINAL_PROMPT=0
GIT_ASKPASS=/usr/bin/true
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5"
export GIT_TERMINAL_PROMPT GIT_ASKPASS GIT_SSH_COMMAND

PROBE_OUT="$(mktemp 2>/dev/null || echo /dev/null)"
# ─────────────────────────────────────────────────────────────────────────
# Repo-health preconditions, checked BEFORE the freshness probe.
#
# They sit here, ahead of the probe, for one reason: T08e proved that a repo
# with a broken index reports `current` and stops — the freshness lib returns
# the token "current", the stager trusts it, and the machine records "up to
# date" about a repository git cannot even read. That is the silent-freeze
# bug in its purest form, and it happens before the preconditions below ever
# run. The lib is a read-only dependency (ADR-086, "Files NOT to touch"), so
# the fix is to refuse earlier rather than to change what it returns.
#
# Only the two "this repo is not in a fit state to reason about" cases move
# up. The `dirty` check stays in its original position further down, so its
# behaviour and ordering relative to the probe are unchanged.
#
# Both are local and cheap — no network, no fetch.
# ─────────────────────────────────────────────────────────────────────────

# "Could not look" is never "looked and it was fine" (ADR-085).
if ! git -c core.hooksPath=/dev/null -C "$CANON_REPO" status --porcelain -uno >/dev/null 2>&1; then
  finish blocked status-unknown 1
fi

# A clean tree can still be mid-operation; git would refuse the fast-forward
# every boot, forever, reported only as a receipt row.
for _su_op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse -q --verify "$_su_op" >/dev/null 2>&1; then
    finish blocked operation-in-progress 1
  fi
done
_SU_GITDIR="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
if [[ -n "$_SU_GITDIR" ]]; then
  if [[ -d "$_SU_GITDIR/rebase-merge" || -d "$_SU_GITDIR/rebase-apply" || -e "$_SU_GITDIR/sequencer" ]]; then
    finish blocked operation-in-progress 1
  fi
fi

FRESHNESS_LIB="$CONF_DIR/lib/stack-freshness.sh"
if [[ -f "$FRESHNESS_LIB" ]]; then
  run_with_deadline "$PROBE_DEADLINE_S" "$PROBE_OUT" bash "$FRESHNESS_LIB" --oneline
  PROBE_RC=$?
else
  run_with_deadline "$PROBE_DEADLINE_S" "$PROBE_OUT" git -c core.hooksPath=/dev/null -C "$CANON_REPO" fetch --quiet --no-tags origin "$STAMP_SRC_BRANCH"
  PROBE_RC=$?
fi
PROBE_TOKEN="$(head -n1 "$PROBE_OUT" 2>/dev/null | tr -d '\r\n')"
rm -f "$PROBE_OUT" 2>/dev/null

CUR_BRANCH="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" branch --show-current 2>/dev/null)"
rset branch "$(sanitize_text "$CUR_BRANCH" 200)"

if (( PROBE_RC == 124 )); then
  NEW_OFFLINE=$(( $(printf '%s' "$EX_JSON" | jq '.consecutive_offline // 0' 2>/dev/null) + 1 ))
  rset_num consecutive_offline "$NEW_OFFLINE"
  rset_bool deadline_degraded "$([[ "$DEADLINE_DEGRADED_FLAG" == "1" ]] && echo true || echo false)"
  finish skipped offline 0
fi

case "$PROBE_TOKEN" in
  current)
    rset_num consecutive_offline 0
    rset_num behind_before 0
    finish current "" 0
    ;;
  unstamped*|repo-not-found)
    # Redundant with our own checks above — treated as a benign skip.
    finish skipped repo-missing 0
    ;;
  unknown)
    NEW_OFFLINE=$(( $(printf '%s' "$EX_JSON" | jq '.consecutive_offline // 0' 2>/dev/null) + 1 ))
    rset_num consecutive_offline "$NEW_OFFLINE"
    finish skipped offline 0
    ;;
esac

BEHIND_BEFORE="${PROBE_TOKEN%% behind}"
if [[ ! "$BEHIND_BEFORE" =~ ^[0-9]+$ ]]; then
  # Unrecognized token — fail closed to a benign skip rather than guessing.
  finish skipped offline 0
fi
rset_num behind_before "$BEHIND_BEFORE"
rset_num consecutive_offline 0

# ─────────────────────────────────────────────────────────────────────────
# D3 rows 11-14 — preconditions on the source repo.
# ─────────────────────────────────────────────────────────────────────────

# TRACKED changes only (`-uno`) — see scripts/update.sh for the full reasoning.
# In short: an untracked file cannot conflict with a fetch and is not a local
# edit to stack content, but counting it here froze auto-update permanently on
# any machine that had one. Because this runs at every boot and reports only
# through a receipt row, the failure was silent: the stack simply stopped
# updating and nothing looked broken. Real edits to tracked stack files still
# block, which is what this precondition is actually for.
#
# The three checks below exist because "empty porcelain output" is NOT the
# same as "safe to fast-forward" (cross-family review, 2026-08-21). Each was a
# way for this guard to say yes when it should have said no, or to stay silent
# when it could not tell — the same shape as the bug being fixed.

# (1) A FAILED status is not a clean status. Reading only stdout meant a
# locked index, an unreadable worktree, or a broken index produced empty
# output and read as clean, then failed later somewhere less legible. It gets
# its own reason rather than being folded into `dirty`: "could not look" must
# never be recorded as "looked and it was fine" (ADR-085).
if ! _SU_STATUS="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" status --porcelain -uno 2>/dev/null)"; then
  finish blocked status-unknown 1
fi
if [[ -n "$_SU_STATUS" ]]; then
  finish blocked dirty 1
fi

# (2) A clean tree can still be mid-operation. An unfinished merge,
# cherry-pick or revert leaves the index clean once paths are resolved, but
# git then refuses to fast-forward with "you have not concluded your merge" —
# every boot, forever, reported only as a receipt row.
for _su_op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse -q --verify "$_su_op" >/dev/null 2>&1; then
    finish blocked operation-in-progress 1
  fi
done
_SU_GITDIR="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
if [[ -n "$_SU_GITDIR" ]]; then
  if [[ -d "$_SU_GITDIR/rebase-merge" || -d "$_SU_GITDIR/rebase-apply" || -e "$_SU_GITDIR/sequencer" ]]; then
    finish blocked operation-in-progress 1
  fi
fi

# (3) Tracked edits can be hidden from status entirely by the index bits
# `assume-unchanged` and `skip-worktree` — lowercase flags in `ls-files -v`.
# That is a hidden local edit to tracked stack content, which is exactly what
# this precondition protects, and worse than the accepted untracked-collision
# residual because nothing surfaces it at all.
if git -c core.hooksPath=/dev/null -C "$CANON_REPO" ls-files -v 2>/dev/null | grep -qE '^[a-z]'; then
  finish blocked dirty 1
fi

if ! git -c core.hooksPath=/dev/null -C "$CANON_REPO" symbolic-ref -q HEAD >/dev/null 2>&1; then
  finish blocked detached 1
fi
if [[ "$CUR_BRANCH" != "$STAMP_SRC_BRANCH" ]]; then
  finish blocked branch 1
fi
if ! git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  finish blocked no-upstream 1
fi

# ─────────────────────────────────────────────────────────────────────────
# D13 — stage (fetch-only, no materialized tree). The lock was already
# acquired above (finding #3 — before the probe and preconditions, not here).
# ─────────────────────────────────────────────────────────────────────────

STAGE_OUT="$(mktemp 2>/dev/null || echo /dev/null)"
run_with_deadline "$PROBE_DEADLINE_S" "$STAGE_OUT" git -c core.hooksPath=/dev/null -C "$CANON_REPO" fetch --quiet --no-tags origin "$STAMP_SRC_BRANCH"
STAGE_RC=$?
STAGE_ERR="$(cat "$STAGE_OUT" 2>/dev/null)"
rm -f "$STAGE_OUT" 2>/dev/null
append_log "=== stage fetch rc=$STAGE_RC ==="
[[ -n "$STAGE_ERR" ]] && append_log "$STAGE_ERR"

if (( STAGE_RC == 124 )); then
  NEW_OFFLINE=$(( $(printf '%s' "$EX_JSON" | jq '.consecutive_offline // 0' 2>/dev/null) + 1 ))
  rset_num consecutive_offline "$NEW_OFFLINE"
  rset_bool deadline_degraded "$([[ "$DEADLINE_DEGRADED_FLAG" == "1" ]] && echo true || echo false)"
  finish skipped offline 0
fi
if (( STAGE_RC != 0 )); then
  FIRST_ERR="$(sanitize_text "$STAGE_ERR" 200 "$STAGE_RC")"
  rset error "$FIRST_ERR"
  finish failed fetch-error 1
fi

STAGED_SHA="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-parse -q --verify "refs/remotes/origin/$STAMP_SRC_BRANCH" 2>/dev/null)"
if [[ -z "$STAGED_SHA" ]]; then
  finish failed fetch-error 1
fi

if ! git -c core.hooksPath=/dev/null -C "$CANON_REPO" merge-base --is-ancestor HEAD "$STAGED_SHA" 2>/dev/null; then
  finish blocked not-ff 1
fi

STAGED_COUNT="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" rev-list --count "HEAD..$STAGED_SHA" 2>/dev/null || echo 0)"
SUBJECTS_JSON="$(git -c core.hooksPath=/dev/null -C "$CANON_REPO" log --format='%s' "HEAD..$STAGED_SHA" -n 5 2>/dev/null | \
  while IFS= read -r line; do sanitize_text "$line" 100; printf '\n'; done | \
  jq -R -s 'split("\n") | map(select(length > 0))')"
[[ -z "$SUBJECTS_JSON" ]] && SUBJECTS_JSON="[]"

rset staged_sha "$STAGED_SHA"
rset staged_at "$(now_iso)"
rset_num staged_count "$STAGED_COUNT"
rset_raw staged_subjects "$SUBJECTS_JSON"

# D20 — a new remote tip resets any in-progress backoff immediately.
if [[ -n "$EX_FAIL_SHA" && "$EX_FAIL_SHA" != "null" && "$STAGED_SHA" != "$EX_FAIL_SHA" ]]; then
  rset_null fail_sha
  rset_num consecutive_failures 0
  rset_null retry_after
fi

finish staged "" 0
