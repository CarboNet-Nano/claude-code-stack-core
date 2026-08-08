#!/usr/bin/env bash
# Regression suite for the PreCompact/PostCompact loop-state protection pair
# (ADR-020, issues #113/#114). Covers: snapshot written pre-compact, verify
# catches a real mismatch, verify passes clean when nothing changed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/skills/loop-engineer/loop_lib.sh"
PRE="$REPO_ROOT/hooks/pre-compact-snapshot.sh"
POST="$REPO_ROOT/hooks/post-compact-verify.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$LIB" ]] || { echo "FAIL: loop_lib.sh not found at $LIB"; exit 1; }
[[ -f "$PRE" ]] || { echo "FAIL: pre-compact-snapshot.sh not found at $PRE"; exit 1; }
[[ -f "$POST" ]] || { echo "FAIL: post-compact-verify.sh not found at $POST"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; printf '%s\n' "$1" >>"$_fail_log"; }

_tmp_home="$(mktemp -d)" || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$_tmp_home"' EXIT
export HOME="$_tmp_home"
_fail_log="$_tmp_home/.faillog"; : >"$_fail_log"
unset CLAUDE_CODE_SESSION_ID LOOP_STATE_FILE 2>/dev/null || true
# shellcheck disable=SC1090
source "$LIB"

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

run_pre()  { echo "$1" | LOOP_STATE_DIR="$STATE_DIR" bash "$PRE"; }
run_post() { echo "$1" | LOOP_STATE_DIR="$STATE_DIR" bash "$POST"; }

# --- no active loop-state -> pre-compact snapshot is a silent no-op ---
rm -f "$STATE_DIR"/loop-state.*.json "$STATE_DIR"/loop-state.json "$STATE_DIR"/*.precompact-snapshot 2>/dev/null
out="$(run_pre '{"session_id":"noneSess","hook_event_name":"PreCompact","trigger":"auto"}')"
[[ -z "$out" ]] && ok "pre: no state -> silent no-op" || bad "pre: no state produced output: $out"
[[ ! -f "$STATE_DIR/loop-state.noneSess.json.precompact-snapshot" ]] \
  && ok "pre: no state -> no snapshot file created" || bad "pre: no state created a snapshot file"

# --- snapshot gets written before compact (real state present) ---
( export CLAUDE_CODE_SESSION_ID="sessA"; LOOP_STATE_DIR="$STATE_DIR" loop_write_state '{"active":true,"iteration":3,"loop_id":"loopA"}' )
STATE_FILE_A="$STATE_DIR/loop-state.sessA.json"
SNAP_A="$STATE_FILE_A.precompact-snapshot"
[[ -f "$STATE_FILE_A" ]] || bad "setup: sessA state file missing before pre-compact"
out="$(run_pre '{"session_id":"sessA","hook_event_name":"PreCompact","trigger":"auto"}')"
[[ -z "$out" ]] && ok "pre: silent stdout on success (must never leak into compaction instructions)" || bad "pre: unexpected stdout: $out"
[[ -f "$SNAP_A" ]] && ok "pre: snapshot file written" || bad "pre: snapshot file missing at $SNAP_A"
[[ "$(jq -cS '.' "$SNAP_A" 2>/dev/null)" == "$(jq -cS '.' "$STATE_FILE_A" 2>/dev/null)" ]] \
  && ok "pre: snapshot content matches state at snapshot time" || bad "pre: snapshot content mismatch"

# --- verify passes clean when nothing changed ---
out="$(run_post '{"session_id":"sessA","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"n/a"}')"
[[ -z "$out" ]] && ok "post: unchanged state -> silent (clean pass)" || bad "post: unchanged state produced output: $out"
[[ ! -f "$SNAP_A" ]] && ok "post: snapshot cleaned up after clean pass" || bad "post: snapshot left behind after clean pass"

# --- verify catches a real mismatch ---
( export CLAUDE_CODE_SESSION_ID="sessB"; LOOP_STATE_DIR="$STATE_DIR" loop_write_state '{"active":true,"iteration":1,"loop_id":"loopB"}' )
STATE_FILE_B="$STATE_DIR/loop-state.sessB.json"
SNAP_B="$STATE_FILE_B.precompact-snapshot"
run_pre '{"session_id":"sessB","hook_event_name":"PreCompact","trigger":"auto"}' >/dev/null
[[ -f "$SNAP_B" ]] || bad "setup: sessB snapshot missing before mismatch test"
# Simulate something writing to loop-state between PreCompact and PostCompact.
( export CLAUDE_CODE_SESSION_ID="sessB"; LOOP_STATE_DIR="$STATE_DIR" loop_write_state '{"active":true,"iteration":99,"loop_id":"loopB"}' )
out="$(run_post '{"session_id":"sessB","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"n/a"}')"
[[ -n "$out" ]] && ok "post: real mismatch produces a warning" || bad "post: mismatch produced no output"
echo "$out" | grep -qi "WARNING" && ok "post: warning is loud (contains WARNING)" || bad "post: warning text missing WARNING marker, out=$out"
echo "$out" | grep -q "sessB" && ok "post: warning identifies the session" || bad "post: warning missing session id, out=$out"
[[ "$(jq -r '.iteration' "$STATE_FILE_B" 2>/dev/null)" == "99" ]] \
  && ok "post: mismatch is NOT auto-reverted (state left as-is)" || bad "post: state was reverted, should not have been"
[[ ! -f "$SNAP_B" ]] && ok "post: snapshot cleaned up after mismatch" || bad "post: snapshot left behind after mismatch"

# --- deleted state file between pre and post is also caught ---
( export CLAUDE_CODE_SESSION_ID="sessC"; LOOP_STATE_DIR="$STATE_DIR" loop_write_state '{"active":true,"iteration":1,"loop_id":"loopC"}' )
STATE_FILE_C="$STATE_DIR/loop-state.sessC.json"
run_pre '{"session_id":"sessC","hook_event_name":"PreCompact","trigger":"auto"}' >/dev/null
rm -f "$STATE_FILE_C"
out="$(run_post '{"session_id":"sessC","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"n/a"}')"
[[ -n "$out" ]] && echo "$out" | grep -qi "WARNING" && ok "post: deleted state file is flagged" || bad "post: deleted state file not flagged, out=$out"

# --- no snapshot ever written -> post-compact is silent (nothing to verify) ---
( export CLAUDE_CODE_SESSION_ID="sessD"; LOOP_STATE_DIR="$STATE_DIR" loop_write_state '{"active":true,"iteration":1,"loop_id":"loopD"}' )
out="$(run_post '{"session_id":"sessD","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"n/a"}')"
[[ -z "$out" ]] && ok "post: no prior snapshot -> silent no-op" || bad "post: no prior snapshot produced output: $out"

# --- fail-safe: neither hook crashes on empty stdin ---
out="$(printf '' | LOOP_STATE_DIR="$STATE_DIR" bash "$PRE" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "pre: empty stdin does not crash (exit 0)" || bad "pre: empty stdin exit=$rc out=$out"
out="$(printf '' | LOOP_STATE_DIR="$STATE_DIR" bash "$POST" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "post: empty stdin does not crash (exit 0)" || bad "post: empty stdin exit=$rc out=$out"

# --- hooks.json registration ---
HOOKS="$REPO_ROOT/hooks/hooks.json"
jq -e '.hooks.PreCompact[]?.hooks[]?.command | select(test("pre-compact-snapshot.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: pre-compact-snapshot registered under PreCompact" || bad "hooks.json: pre-compact-snapshot missing"
jq -e '.hooks.PostCompact[]?.hooks[]?.command | select(test("post-compact-verify.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: post-compact-verify registered under PostCompact" || bad "hooks.json: post-compact-verify missing"

FAIL="$(wc -l <"$_fail_log" | tr -d '[:space:]')"
echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
