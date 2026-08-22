#!/usr/bin/env bash
# Tests for scripts/fleet-report.sh (ADR-087 D8). R1 subset of the 102-case
# plan, cases 83-88.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FR="$REPO_ROOT/scripts/fleet-report.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME"

# One rollout, so board rows are simple and deterministic.
DECL="$TMP/rollouts.json"
jq -n '{schema:"stack-rollouts/v1", rollouts:[
  {id:"r-one", title:"t", since_stack_version:"1.0", applies_to:{config_dirs:"all"},
   probes:[{type:"file_present", path:"marker.txt"}]}
]}' > "$DECL"

# Roster names THREE dirs: master, second (present), missing (absent from
# this machine).
ROSTER="$TMP/roster.json"
jq -n --arg h "$HOME" '{schema:"stack-fleet-roster/v1", config_dirs:[
  {label:"master", path:($h+"/.claude")},
  {label:"second", path:($h+"/.claude-second")},
  {label:"missing", path:($h+"/.claude-missing")}
]}' > "$ROSTER"

mkdir -p "$HOME/.claude"
printf 'marker content\n' > "$HOME/.claude/marker.txt"
mkdir -p "$HOME/.claude-second"
printf 'marker content\n' > "$HOME/.claude-second/marker.txt"
# .claude-missing intentionally does not exist.

# An UNROSTERED discovered profile.
mkdir -p "$HOME/.claude-stray"
# no marker.txt here -> its rollout state will be "absent" (a real gap, not
# a permission/probe failure) once discovered.

run_fr() { RV_ROLLOUTS_DECL="$DECL" bash "$FR" --roster "$ROSTER" "$@"; }

# ─── 83: 3 rostered dirs, 2 present -> 3 rows; the absent one is
#     NOT-CHECKED/not-on-this-machine, never omitted, never a pass ─────────
OUT83="$(run_fr --json 2>/dev/null)"
echo "$OUT83" | jq -e '[.columns[] | select(.label=="master" or .label=="second" or .label=="missing")] | length == 3' >/dev/null 2>&1 \
  && pass "83a: all 3 rostered dirs appear as columns" || fail "83a: $(echo "$OUT83" | jq -c '[.columns[].label]')"
echo "$OUT83" | jq -e '.columns[] | select(.label=="missing") | .present_on_this_machine == false and (.rollouts["r-one"].state=="NOT-CHECKED") and (.rollouts["r-one"].reason=="not-on-this-machine")' >/dev/null 2>&1 \
  && pass "83b: the not-on-this-machine dir is NOT-CHECKED, never a pass, never omitted" || fail "83b: $OUT83"

# ─── 84: discovered ~/.claude-* absent from the roster -> UNROSTERED ──────
echo "$OUT83" | jq -e '.columns[] | select(.label | test("stray")) | .unrostered == true' >/dev/null 2>&1 \
  && pass "84: discovered .claude-stray profile marked unrostered" || fail "84: $(echo "$OUT83" | jq -c '[.columns[] | {label,unrostered}]')"

# ─── 85: exit codes 0/1/2; both a gap and a not-checked -> exits 2 ────────
run_fr --json >/dev/null 2>&1
RC85=$?
[[ "$RC85" -eq 2 ]] && pass "85: gap + not-checked present -> exit 2" || fail "85: rc=$RC85"

# All-confirmed scenario: roster names only "master" (present, satisfied).
ROSTER_OK="$TMP/roster-ok.json"
jq -n --arg h "$HOME" '{schema:"stack-fleet-roster/v1", config_dirs:[{label:"master", path:($h+"/.claude")}]}' > "$ROSTER_OK"
HOME2="$TMP/home2"; mkdir -p "$HOME2/.claude"
printf 'marker content\n' > "$HOME2/.claude/marker.txt"
ROSTER_OK2="$TMP/roster-ok2.json"
jq -n --arg h "$HOME2" '{schema:"stack-fleet-roster/v1", config_dirs:[{label:"master", path:($h+"/.claude")}]}' > "$ROSTER_OK2"
( export HOME="$HOME2"; RV_ROLLOUTS_DECL="$DECL" bash "$FR" --roster "$ROSTER_OK2" --json >/dev/null 2>&1 )
RC85B=$?
[[ "$RC85B" -eq 0 ]] && pass "85b: all-confirmed scenario -> exit 0" || fail "85b: rc=$RC85B"

# ─── 86: fixed trailing sentence + (claim) header present in every rendering
TEXT_OUT="$(run_fr 2>/dev/null)"
[[ "$TEXT_OUT" == *"A missing row is NOT a pass."* ]] && pass "86a: text board carries the fixed trailing sentence" || fail "86a: missing in text board"
[[ "$TEXT_OUT" == *"(claim)"* ]] && pass "86b: text board marks the not-on-this-machine column (claim)" || fail "86b: no (claim) marker"
echo "$OUT83" | jq -e '.note == "A missing row is NOT a pass."' >/dev/null 2>&1 \
  && pass "86c: --json carries the fixed sentence in .note" || fail "86c: $OUT83"
echo "$OUT83" | jq -e '.claim_note | test("self-reported")' >/dev/null 2>&1 \
  && pass "86d: --json carries the (claim) explanation in .claim_note" || fail "86d: $OUT83"

# ─── 87: --json is schema-valid and carries the same rows as the text board
echo "$OUT83" | jq -e '.schema and .columns and .gap_count != null and .not_checked_count != null' >/dev/null 2>&1 \
  && pass "87a: --json has the expected top-level shape" || fail "87a: $OUT83"
TEXT_GAPCOUNT="$(echo "$TEXT_OUT" | tail -1 | grep -oE '^[0-9]+' )"
JSON_GAPCOUNT="$(echo "$OUT83" | jq -r '.gap_count')"
[[ "$TEXT_GAPCOUNT" == "$JSON_GAPCOUNT" ]] && pass "87b: text and --json report the same gap count" || fail "87b: text=$TEXT_GAPCOUNT json=$JSON_GAPCOUNT"

# ─── 88: --json's upload projection carries no absolute path, hostname,
#     username, or repo name ────────────────────────────────────────────────
UPLOAD="$(echo "$OUT83" | jq -c '.upload')"
[[ "$UPLOAD" != *"$HOME"* ]] && pass "88a: upload projection carries no absolute path" || fail "88a: leaked \$HOME: $UPLOAD"
[[ "$UPLOAD" != *"$(hostname 2>/dev/null)"* ]] && pass "88b: upload projection carries no hostname" || fail "88b: leaked hostname"
[[ "$UPLOAD" != *"$(whoami 2>/dev/null)"* ]] && pass "88c: upload projection carries no username" || fail "88c: leaked username"
[[ "$UPLOAD" != *"claude-code-stack"* ]] && pass "88d: upload projection carries no repo name" || fail "88d: leaked repo name"
echo "$UPLOAD" | jq -e '.[0] | has("config_dir_label") and has("rollouts") and (has("path") | not)' >/dev/null 2>&1 \
  && pass "88e: upload rows carry only config_dir_label + rollout states, no path field" || fail "88e: $UPLOAD"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
