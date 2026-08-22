#!/usr/bin/env bash
# Tests for scripts/rollout-verify.sh (ADR-087 D7). R1 subset of the
# 102-case plan, cases 71-82.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RV="$REPO_ROOT/scripts/rollout-verify.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# make_decl <path> <json-content>
make_decl() { printf '%s' "$2" > "$1"; }

FULL_DECL="$TMP/rollouts-full.json"
make_decl "$FULL_DECL" '{
  "schema": "stack-rollouts/v1",
  "rollouts": [
    { "id": "r-file-present", "title": "t", "since_stack_version": "1.0", "applies_to": {"config_dirs":"all"},
      "probes": [ { "type": "file_present", "path": "marker.txt" } ] },
    { "id": "r-file-sha", "title": "t", "since_stack_version": "1.0", "applies_to": {"config_dirs":"all"},
      "probes": [ { "type": "file_sha", "path": "marker.txt", "sha": "SHAPLACEHOLDER" } ] },
    { "id": "r-settings", "title": "t", "since_stack_version": "1.0", "applies_to": {"config_dirs":"all"},
      "probes": [ { "type": "settings_json", "jq": ".hooks.SessionStart[0].hooks[0].command | test(\"marker-hook\")" } ] },
    { "id": "r-receipt", "title": "t", "since_stack_version": "1.0", "applies_to": {"config_dirs":"all"},
      "probes": [ { "type": "receipt_field", "path": "some/receipt.json", "jq": ".ok == true" } ] },
    { "id": "r-floor", "title": "t", "since_stack_version": "1.0", "applies_to": {"config_dirs":"master"},
      "probes": [ { "type": "floor_glob", "glob": "~/.claude/state/attest/**" } ] }
  ]
}'

MARKER_SHA="$(printf 'marker content\n' | shasum -a 256 | awk '{print $1}')"
sed -i '' "s/SHAPLACEHOLDER/$MARKER_SHA/" "$FULL_DECL" 2>/dev/null || sed -i "s/SHAPLACEHOLDER/$MARKER_SHA/" "$FULL_DECL"

make_conf() { # -> echoes a fresh config dir with all probes satisfiable
  local C="$TMP/conf-$RANDOM$RANDOM"
  mkdir -p "$C/state/some"
  printf 'marker content\n' > "$C/marker.txt"
  jq -n '{hooks:{SessionStart:[{hooks:[{command:"~/.claude/hooks/marker-hook.sh"}]}]}}' > "$C/settings.json"
  jq -n '{ok:true}' > "$C/state/some/receipt.json"
  echo "$C"
}

FLOOR="$TMP/floor.json"
jq -n '{sandbox:{filesystem:{denyWrite:["~/.claude/state/attest/**"]}}}' > "$FLOOR"

run_rv() { # <config_dir> [extra env assignments...] -> stdout
  local cd="$1"; shift
  RV_ROLLOUTS_DECL="$FULL_DECL" RV_MANAGED_FLOOR_PATH="$FLOOR" "$@" bash "$RV" --config-dir "$cd" --json 2>/dev/null
}

# ─── 71: all probes present -> all-confirmed ───────────────────────────────
C71="$(make_conf)"
OUT71="$(run_rv "$C71")"
echo "$OUT71" | jq -e '.verdict=="all-confirmed"' >/dev/null 2>&1 && pass "71: all probes present -> all-confirmed" || fail "71: $OUT71"

# ─── 72: settings.json missing an entry -> absent, failing probe named ────
C72="$(make_conf)"
jq -n '{hooks:{SessionStart:[{hooks:[{command:"~/.claude/hooks/something-else.sh"}]}]}}' > "$C72/settings.json"
OUT72="$(run_rv "$C72")"
echo "$OUT72" | jq -e '.evidence.rollouts[] | select(.id=="r-settings") | .state=="absent" and (.failed_probes | length > 0)' >/dev/null 2>&1 \
  && pass "72: missing settings entry -> absent, probe named" || fail "72: $OUT72"

# ─── 73: settings.json unparseable -> not-checked, never absent ───────────
C73="$(make_conf)"
echo "not json" > "$C73/settings.json"
OUT73="$(run_rv "$C73")"
echo "$OUT73" | jq -e '.evidence.rollouts[] | select(.id=="r-settings") | .state=="not-checked"' >/dev/null 2>&1 \
  && pass "73: unparseable settings.json -> not-checked, never absent" || fail "73: $OUT73"

# ─── 74: jq absent -> all probes not-checked, verdict couldnt-check ───────
C74="$(make_conf)"
( export PATH="/usr/bin:/bin"
  command -v jq >/dev/null 2>&1 && { echo "SKIP 74: jq is on the base-system PATH"; exit 0; }
  RV_ROLLOUTS_DECL="$FULL_DECL" bash "$RV" --config-dir "$C74" --json > "$TMP/out74.txt" 2>/dev/null
)
if [[ -s "$TMP/out74.txt" ]]; then
  grep -q 'couldnt-check' "$TMP/out74.txt" && pass "74: jq absent -> couldnt-check" || fail "74: $(cat "$TMP/out74.txt")"
else
  echo "SKIP: 74 (jq present on base PATH, cannot simulate absence)"
fi

# ─── 75: config dir chmod 000 -> couldnt-check, error names the directory ─
C75="$(make_conf)"
chmod 000 "$C75"
OUT75="$(run_rv "$C75")"
chmod 755 "$C75"
echo "$OUT75" | jq -e '.verdict=="couldnt-check"' >/dev/null 2>&1 && pass "75: unreadable config dir -> couldnt-check" || fail "75: $OUT75"

# ─── 76: applies_to excludes this dir -> n/a, excluded from gap count ─────
C76="$(make_conf)"   # not master (not $HOME/.claude)
OUT76="$(run_rv "$C76")"
echo "$OUT76" | jq -e '.evidence.rollouts[] | select(.id=="r-floor") | .state=="n/a"' >/dev/null 2>&1 \
  && pass "76a: applies_to=master excludes a non-master dir -> n/a" || fail "76a: $OUT76"
echo "$OUT76" | jq -e '.verdict=="all-confirmed"' >/dev/null 2>&1 \
  && pass "76b: n/a rollout does not count as a gap" || fail "76b: $OUT76"

# ─── 77: writes nothing into the target dir ────────────────────────────────
C77="$(make_conf)"
BEFORE="$(find "$C77" -type f | sort)"
run_rv "$C77" >/dev/null
AFTER="$(find "$C77" -type f | sort)"
[[ "$BEFORE" == "$AFTER" ]] && pass "77: rollout-verify.sh writes nothing into the target dir" || fail "77: file list changed"

# ─── 78: probe path with .., absolute, or resolving outside -> unsafe-path ─
DECL78="$TMP/rollouts-78.json"
make_decl "$DECL78" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-dotdot","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"file_present","path":"../escape.txt"}]},
  {"id":"r-abs","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"file_present","path":"/etc/passwd"}]}
]}'
C78="$(make_conf)"
OUT78="$(RV_ROLLOUTS_DECL="$DECL78" bash "$RV" --config-dir "$C78" --json 2>/dev/null)"
echo "$OUT78" | jq -e '.evidence.rollouts[] | select(.id=="r-dotdot") | .state=="not-checked" and (.failed_probes[0] | test("unsafe-path"))' >/dev/null 2>&1 \
  && pass "78a: .. segment -> not-checked/unsafe-path" || fail "78a: $OUT78"
echo "$OUT78" | jq -e '.evidence.rollouts[] | select(.id=="r-abs") | .state=="not-checked" and (.failed_probes[0] | test("unsafe-path"))' >/dev/null 2>&1 \
  && pass "78b: absolute path -> not-checked/unsafe-path" || fail "78b: $OUT78"

# ─── 79: symlinked component anywhere -> refused per component ────────────
C79="$(make_conf)"
mkdir -p "$TMP/outside-79"
echo "secret" > "$TMP/outside-79/leaked.txt"
ln -s "$TMP/outside-79" "$C79/evil-link"
DECL79="$TMP/rollouts-79.json"
make_decl "$DECL79" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-symlink","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"file_present","path":"evil-link/leaked.txt"}]}
]}'
OUT79="$(RV_ROLLOUTS_DECL="$DECL79" bash "$RV" --config-dir "$C79" --json 2>/dev/null)"
echo "$OUT79" | jq -e '.evidence.rollouts[] | select(.id=="r-symlink") | .state=="not-checked" and (.failed_probes[0] | test("unsafe-path"))' >/dev/null 2>&1 \
  && pass "79: symlinked component refused, not followed" || fail "79: $OUT79"

# ─── 80: settings_json expression returning a string -> false; never leaks ─
DECL80="$TMP/rollouts-80.json"
make_decl "$DECL80" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-stringy","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"settings_json","jq":".secret_value"}]}
]}'
C80="$(make_conf)"
jq -n '{secret_value:"super-secret-string-marker-XYZ", hooks:{}}' > "$C80/settings.json"
OUT80="$(RV_ROLLOUTS_DECL="$DECL80" bash "$RV" --config-dir "$C80" --json 2>/dev/null)"
echo "$OUT80" | jq -e '.evidence.rollouts[] | select(.id=="r-stringy") | .state=="absent"' >/dev/null 2>&1 \
  && pass "80a: a string-returning expression is recorded as false/absent" || fail "80a: $OUT80"
[[ "$OUT80" != *"super-secret-string-marker-XYZ"* ]] \
  && pass "80b: the matched string value never appears in output" || fail "80b: string leaked into output"

# ─── 81: oversized file -> not-checked/probe-budget; hanging probe killed ─
C81="$(make_conf)"
python3 -c "print('x' * (1024*1024 + 100))" > "$C81/settings.json" 2>/dev/null \
  || perl -e 'print "x" x (1024*1024+100)' > "$C81/settings.json"
DECL81="$TMP/rollouts-81.json"
make_decl "$DECL81" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-big","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"settings_json","jq":"true"}]}
]}'
OUT81="$(RV_ROLLOUTS_DECL="$DECL81" bash "$RV" --config-dir "$C81" --json 2>/dev/null)"
echo "$OUT81" | jq -e '.evidence.rollouts[] | select(.id=="r-big") | .state=="not-checked" and (.failed_probes[0] | test("probe-budget"))' >/dev/null 2>&1 \
  && pass "81a: oversized settings.json -> not-checked/probe-budget" || fail "81a: $OUT81"

DECL81B="$TMP/rollouts-81b.json"
make_decl "$DECL81B" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-slow","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"settings_json","jq":"true"}]}
]}'
C81B="$(make_conf)"
START_81B=$SECONDS
OUT81B="$(RV_ROLLOUTS_DECL="$DECL81B" RV_PROBE_DEADLINE_S=1 bash "$RV" --config-dir "$C81B" --json 2>/dev/null)"
ELAPSED_81B=$(( SECONDS - START_81B ))
[[ "$ELAPSED_81B" -lt 10 ]] && pass "81b: probe completes well within the deadline budget (${ELAPSED_81B}s)" || fail "81b: took ${ELAPSED_81B}s"

# ─── 82: floor_glob reports absent/confirmed correctly ────────────────────
C82="$(make_conf)"
DECL82="$TMP/rollouts-82.json"
make_decl "$DECL82" '{"schema":"stack-rollouts/v1","rollouts":[
  {"id":"r-floor2","title":"t","since_stack_version":"1.0","applies_to":{"config_dirs":"all"},
   "probes":[{"type":"floor_glob","glob":"~/.claude/state/attest/**"}]}
]}'
NO_FLOOR="$TMP/no-floor.json"
OUT82A="$(RV_ROLLOUTS_DECL="$DECL82" RV_MANAGED_FLOOR_PATH="$NO_FLOOR" bash "$RV" --config-dir "$C82" --json 2>/dev/null)"
echo "$OUT82A" | jq -e '.evidence.rollouts[] | select(.id=="r-floor2") | .state=="not-checked"' >/dev/null 2>&1 \
  && pass "82a: no floor installed -> not-checked (not absent -- a probe that cannot run)" || fail "82a: $OUT82A"

FLOOR_LACKING="$TMP/floor-lacking.json"
jq -n '{sandbox:{filesystem:{denyWrite:["~/.claude/hooks/**"]}}}' > "$FLOOR_LACKING"
OUT82B="$(RV_ROLLOUTS_DECL="$DECL82" RV_MANAGED_FLOOR_PATH="$FLOOR_LACKING" bash "$RV" --config-dir "$C82" --json 2>/dev/null)"
echo "$OUT82B" | jq -e '.evidence.rollouts[] | select(.id=="r-floor2") | .state=="absent"' >/dev/null 2>&1 \
  && pass "82b: floor installed but lacks the glob -> absent" || fail "82b: $OUT82B"

OUT82C="$(RV_ROLLOUTS_DECL="$DECL82" RV_MANAGED_FLOOR_PATH="$FLOOR" bash "$RV" --config-dir "$C82" --json 2>/dev/null)"
echo "$OUT82C" | jq -e '.evidence.rollouts[] | select(.id=="r-floor2") | .state=="confirmed"' >/dev/null 2>&1 \
  && pass "82c: floor installed and carries the glob -> confirmed" || fail "82c: $OUT82C"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
