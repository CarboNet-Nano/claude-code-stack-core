#!/usr/bin/env bash
# Tests for scripts/lib/usage-check-common.sh and scripts/usage-check.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/usage-check-common.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

source "$LIB"

# --- 1. target normalization -------------------------------------------------
assert_eq "file target strips leading ./" "src/lib/foo.ts" "$(uc_normalize_target file './src/lib/foo.ts')"
assert_eq "file target strips trailing /" "src/lib" "$(uc_normalize_target file 'src/lib/')"
assert_eq "symbol target gets symbol: prefix" "symbol:FooProcessor" "$(uc_normalize_target symbol 'FooProcessor')"
assert_eq "symbol target is idempotent" "symbol:FooProcessor" "$(uc_normalize_target symbol 'symbol:FooProcessor')"

# --- 2. hashing is deterministic and matches manual shasum -------------------
MANUAL_REPO_HASH="$(shasum -a 256 <<<"/tmp/some/repo" | cut -c1-12)"
assert_eq "repo hash matches manual shasum" "$MANUAL_REPO_HASH" "$(uc_repo_hash /tmp/some/repo)"
MANUAL_TARGET_HASH="$(shasum -a 256 <<<"file:src/lib/foo.ts" | cut -c1-12)"
assert_eq "target hash matches manual shasum" "$MANUAL_TARGET_HASH" "$(uc_target_hash file 'src/lib/foo.ts')"

# --- 3. sid sanitization ------------------------------------------------------
assert_eq "sid strips unsafe chars" "abc_123_xyz" "$(uc_sanitize_sid 'abc/123:xyz')"
assert_eq "empty sid becomes nosession" "nosession" "$(uc_sanitize_sid '')"

# --- 4. timestamp round-trip --------------------------------------------------
NOW="$(uc_now_iso)"
echo "$NOW" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && pass "now_iso matches UTC-seconds-Z format" \
  || fail "now_iso format wrong: $NOW"
EPOCH1="$(uc_iso_to_epoch '2026-08-05T14:02:11Z')"
assert_eq "iso_to_epoch is deterministic for a fixed timestamp" "$EPOCH1" "$(uc_iso_to_epoch '2026-08-05T14:02:11Z')"
[[ -n "$EPOCH1" ]] && pass "iso_to_epoch returns a non-empty value for valid input" || fail "iso_to_epoch returned empty for valid input"
BAD_EPOCH="$(uc_iso_to_epoch 'not-a-timestamp')"
assert_eq "iso_to_epoch returns empty for unparseable input" "" "$BAD_EPOCH"

# --- 5. token path derivation --------------------------------------------------
TP="$(uc_token_path aaa111 bbb222 ccc333)"
echo "$TP" | grep -q "usage-check.aaa111.bbb222.ccc333.json" \
  && pass "token_path embeds all three hash components" \
  || fail "token_path malformed: $TP"

echo
echo "usage-check (lib): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

# ==============================================================================
# Checker tool tests
# ==============================================================================
CHECKER="$REPO_ROOT/scripts/usage-check.sh"
TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

build_repo() {
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main && git config user.email t@t.t && git config user.name t )
  echo "$R"
}

decode_result() { # <checker stdout> -> echoes decoded JSON
  grep '^USAGE_CHECK_RESULT:v1 ' <<<"$1" | sed 's/^USAGE_CHECK_RESULT:v1 //' | base64 -d
}

# --- 6. used verdict when references exist -----------------------------------
R="$(build_repo)"
mkdir -p "$R/src"
cat > "$R/src/foo.ts" <<'EOF'
export function foo() {}
EOF
cat > "$R/src/bar.ts" <<'EOF'
import { foo } from './foo';
foo();
EOF
( cd "$R" && git add -A && git commit -qm init )
OUT="$(cd "$R" && bash "$CHECKER" --target src/foo.ts)"
JSON="$(decode_result "$OUT")"
assert_eq "used verdict when a referencing file exists" "used" "$(echo "$JSON" | jq -r .verdict)"
MATCHES="$(echo "$JSON" | jq -r '.search.match_count')"
[[ "$MATCHES" -ge 1 ]] && pass "match_count >= 1 for a used file" || fail "match_count was $MATCHES, expected >=1"
EXCLUDED="$(echo "$JSON" | jq -r '.search.excluded_target')"
assert_eq "target file itself is recorded as excluded" "src/foo.ts" "$EXCLUDED"

# --- 7. unused verdict when nothing references the target --------------------
mkdir -p "$R/src"
cat > "$R/src/orphan.ts" <<'EOF'
export function totallyUnreferencedThing() {}
EOF
( cd "$R" && git add -A && git commit -qm orphan )
OUT="$(cd "$R" && bash "$CHECKER" --target src/orphan.ts)"
JSON="$(decode_result "$OUT")"
assert_eq "unused verdict when nothing references the file" "unused" "$(echo "$JSON" | jq -r .verdict)"

# --- 8. symbol target -----------------------------------------------------------
mkdir -p "$R/src"
cat > "$R/src/handler.ts" <<'EOF'
export function handleFooBarBaz() {}
EOF
cat > "$R/src/caller.ts" <<'EOF'
handleFooBarBaz();
EOF
( cd "$R" && git add -A && git commit -qm handler )
OUT="$(cd "$R" && bash "$CHECKER" --target symbol:handleFooBarBaz)"
JSON="$(decode_result "$OUT")"
assert_eq "symbol target records symbol: prefix" "symbol:handleFooBarBaz" "$(echo "$JSON" | jq -r .target)"
PATTERN="$(echo "$JSON" | jq -r '.search.pattern')"
echo "$PATTERN" | grep -q 'handleFooBarBaz' && pass "recorded pattern contains the symbol name" || fail "pattern missing symbol: $PATTERN"

# --- 8b. unused symbol verdict when symbol appears only in declaration --------
mkdir -p "$R/src"
cat > "$R/src/unused-symbol.ts" <<'EOF'
export function trulyUnusedSymbolXYZ() {}
EOF
( cd "$R" && git add -A && git commit -qm unused-symbol )
OUT="$(cd "$R" && bash "$CHECKER" --target symbol:trulyUnusedSymbolXYZ)"
JSON="$(decode_result "$OUT")"
assert_eq "unused symbol verdict when only declaration exists" "unused" "$(echo "$JSON" | jq -r .verdict)"
MATCHES="$(echo "$JSON" | jq -r '.search.match_count')"
[[ "$MATCHES" -eq 1 ]] && pass "match_count is 1 (only declaration)" || fail "match_count was $MATCHES, expected 1"

# --- 9. nonexistent file target errors, no result line ------------------------
# NOTE: this file runs `set -uo pipefail` WITHOUT -e on purpose — an assertion
# that fails must be counted and reported, not abort the run. Do not "restore"
# errexit here; an earlier version did (`set -e 2>/dev/null || true`) and it
# silently killed the suite mid-run on any host where a later command returned
# non-zero, producing no FAIL line and no summary — which reads as a mystery
# CI failure rather than a test result.
OUT="$(cd "$R" && bash "$CHECKER" --target src/does/not/exist.ts 2>/dev/null)"
RC=$?
assert_eq "nonexistent target exits 2" "2" "$RC"
echo "$OUT" | grep -q 'USAGE_CHECK_RESULT' && fail "result line emitted for nonexistent target" || pass "no result line for nonexistent target"

# --- 10. recorded pattern is replay-deterministic (the gate's re-run contract) ---
# Replay with the SAME tool the checker recorded, not a hardcoded `rg`: CI
# runners frequently lack ripgrep, and the checker falls back to grep there.
# Hardcoding rg made this compare a real grep count against an empty rg result.
OUT1="$(cd "$R" && bash "$CHECKER" --target src/foo.ts)"
JSON1="$(decode_result "$OUT1")"
PATTERN1="$(echo "$JSON1" | jq -r '.search.pattern')"
TOOL1="$(echo "$JSON1" | jq -r '.search.tool')"
if [[ "$TOOL1" == "rg" ]]; then
  REPLAYED_RAW="$(cd "$R" && rg -l --hidden --glob '!.git' -e "$PATTERN1" . 2>/dev/null)"
else
  REPLAYED_RAW="$(cd "$R" && grep -rlE --exclude-dir=.git -e "$PATTERN1" . 2>/dev/null)"
fi
REPLAYED_COUNT="$(echo "$REPLAYED_RAW" | grep -v -E '^(\./)?src/foo\.ts$' | sed '/^$/d' | wc -l | tr -d ' ')"
ORIGINAL_COUNT="$(echo "$JSON1" | jq -r '.search.match_count')"
assert_eq "hand-replayed pattern ($TOOL1) returns the same match count" "$ORIGINAL_COUNT" "$REPLAYED_COUNT"

# --- 11. human report caps the printed file list, JSON keeps the true total ---
# Regression test for the truncation bug: an uncapped human report on a
# heavily-referenced target can grow to tens of KB, risking truncation of the
# trailing USAGE_CHECK_RESULT:v1 line the minting hook depends on.
mkdir -p "$R/src/manyrefs"
cat > "$R/src/manyrefs/widgetfactory.ts" <<'EOF'
export function widgetfactory() {}
EOF
for i in $(seq 1 60); do
  printf 'widgetfactory();\n' > "$R/src/manyrefs/ref$i.ts"
done
( cd "$R" && git add -A && git commit -qm manyrefs )
OUT="$(cd "$R" && bash "$CHECKER" --target src/manyrefs/widgetfactory.ts)"
JSON="$(decode_result "$OUT")"
TRUE_COUNT="$(echo "$JSON" | jq -r '.search.match_count')"
[[ "$TRUE_COUNT" -ge 60 ]] && pass "JSON match_count reflects the true, uncapped total (>=60)" || fail "match_count was $TRUE_COUNT, expected >=60"
PRINTED_LINES="$(echo "$OUT" | grep -c '^  \./src/manyrefs/ref')"
[[ "$PRINTED_LINES" -le 50 ]] && pass "human report caps printed file list at 50" || fail "human report printed $PRINTED_LINES lines, expected <=50"
echo "$OUT" | grep -qE '^  \.\.\. and [0-9]+ more$' && pass "human report notes the truncated remainder count" || fail "human report missing '... and N more' note: $OUT"
RESULT_LINE_POS="$(echo "$OUT" | grep -n '^USAGE_CHECK_RESULT:v1 ' | cut -d: -f1)"
TOTAL_LINES="$(echo "$OUT" | wc -l | tr -d ' ')"
assert_eq "USAGE_CHECK_RESULT:v1 remains the last stdout line" "$TOTAL_LINES" "$RESULT_LINE_POS"

echo
echo "usage-check (checker): total $((PASS)) passed, $((FAIL)) failed so far"
[[ "$FAIL" -eq 0 ]]
