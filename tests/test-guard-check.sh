#!/usr/bin/env bash
# Tests for hooks/guard-check.sh (ADR-049).
#
# The 7 verification cases the ADR requires. Case 3 is the one that actually
# proves the path filter works -- without it, a clean tree makes every case
# look like a pass. Cases 2 and 4 prove the real guard script is invoked (via
# an invocation-count sentinel) rather than the hook faking a result.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard-check.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# make_repo <dir> [guards-json-or-empty]
# guards-json, if given, is the full value of the "guards" key (e.g.
# '{"script":"scripts/check.sh","paths":["app/**","middleware.ts"]}').
# Omit it to get a stack-config with no guards block at all (case 7).
make_repo() {
  local dir="$1" guards="${2:-}"
  mkdir -p "$dir/.claude" "$dir/app" "$dir/scripts"
  local json="{\"stack_tier\":2,\"stack_version\":\"1.0.0\",\"purpose\":\"test\",\"created\":\"2026-01-01\""
  [[ -n "$guards" ]] && json="$json,\"guards\":$guards"
  json="$json}"
  echo "$json" > "$dir/.claude/stack-config.json"

  # Reference guard: greps app/ for a FORBIDDEN marker, records every
  # invocation to .guard-invocations so tests can prove skip-vs-run.
  cat > "$dir/scripts/check.sh" <<'EOS'
#!/usr/bin/env bash
echo "invoked" >> .guard-invocations
if grep -rq "FORBIDDEN" app 2>/dev/null; then
  echo "rule: FORBIDDEN marker found in app/"
  exit 1
fi
exit 0
EOS
  chmod +x "$dir/scripts/check.sh"
}

invocations() { [[ -f "$1/.guard-invocations" ]] && wc -l < "$1/.guard-invocations" | tr -d ' ' || echo "0"; }

# run <project-dir> <file_path> -> {stdout, stderr, status} via globals
run() {
  local proj="$1" fp="$2"
  OUT=$(jq -nc --arg f "$fp" '{tool_input:{file_path:$f}}' \
    | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" 2>"$TMP/stderr")
  STATUS=$?
  ERR=$(cat "$TMP/stderr")
}

GUARDS='{"script":"scripts/check.sh","paths":["app/**","middleware.ts"]}'

# ─── 1: guarded path, clean tree → exit 0, silent ───────────────────────────
R="$TMP/1-clean"; make_repo "$R" "$GUARDS"
echo "clean" > "$R/app/foo.ts"
run "$R" "$R/app/foo.ts"
[[ "$STATUS" -eq 0 && -z "$OUT" && -z "$ERR" ]] \
  && pass "1: guarded path, clean tree -> exit 0 silent" \
  || fail "1: status=$STATUS out=$OUT err=$ERR"
[[ "$(invocations "$R")" == "1" ]] \
  && pass "1: guard was invoked" || fail "1: invocation count $(invocations "$R")"

# ─── 2: guarded path, genuine violation → exit 2, output relayed ───────────
R="$TMP/2-violation"; make_repo "$R" "$GUARDS"
echo "FORBIDDEN" > "$R/app/foo.ts"
run "$R" "$R/app/foo.ts"
[[ "$STATUS" -eq 2 && "$ERR" == *"FORBIDDEN marker found"* ]] \
  && pass "2: guarded path, violation -> exit 2, guard output relayed" \
  || fail "2: status=$STATUS err=$ERR"

# ─── 3: unguarded path, same dirty tree → exit 0, guard skipped ────────────
R="$TMP/3-unguarded"; make_repo "$R" "$GUARDS"
echo "FORBIDDEN" > "$R/app/foo.ts"   # dirty, but we edit a different file
echo "x" > "$R/other.ts"
run "$R" "$R/other.ts"
[[ "$STATUS" -eq 0 && -z "$OUT" ]] \
  && pass "3: unguarded path on dirty tree -> exit 0" \
  || fail "3: status=$STATUS out=$OUT"
[[ "$(invocations "$R")" == "0" ]] \
  && pass "3: guard never invoked (proves path filter, not a clean-tree fluke)" \
  || fail "3: invocation count $(invocations "$R") -- guard ran when it shouldn't have"

# ─── 4: exact-filename glob → exit 2 on the dirty tree ──────────────────────
R="$TMP/4-exactglob"; make_repo "$R" "$GUARDS"
echo "FORBIDDEN" > "$R/app/foo.ts"
echo "trigger" > "$R/middleware.ts"
run "$R" "$R/middleware.ts"
[[ "$STATUS" -eq 2 ]] \
  && pass "4: exact-filename glob (middleware.ts) -> exit 2" \
  || fail "4: status=$STATUS"

# ─── 5: relative file_path → exit 0 (clean tree, must not crash/misparse) ──
R="$TMP/5-relative"; make_repo "$R" "$GUARDS"
echo "clean" > "$R/app/foo.ts"
run "$R" "app/foo.ts"
[[ "$STATUS" -eq 0 && -z "$OUT" && -z "$ERR" ]] \
  && pass "5: relative file_path -> exit 0" \
  || fail "5: status=$STATUS out=$OUT err=$ERR"

# ─── 6: payload with no file_path → exit 0 ──────────────────────────────────
R="$TMP/6-nofile"; make_repo "$R" "$GUARDS"
OUT=$(echo '{}' | CLAUDE_PROJECT_DIR="$R" bash "$HOOK" 2>"$TMP/stderr6")
STATUS=$?
[[ "$STATUS" -eq 0 && -z "$OUT" ]] \
  && pass "6: no file_path in payload -> exit 0" \
  || fail "6: status=$STATUS out=$OUT"

# ─── 7: repo with no guards block → exit 0, guard never invoked ────────────
R="$TMP/7-noguards"; make_repo "$R"   # no guards arg
echo "FORBIDDEN" > "$R/app/foo.ts"
run "$R" "$R/app/foo.ts"
[[ "$STATUS" -eq 0 && -z "$OUT" ]] \
  && pass "7: repo with no guards block -> exit 0" \
  || fail "7: status=$STATUS out=$OUT"
[[ "$(invocations "$R")" == "0" ]] \
  && pass "7: guard never invoked" \
  || fail "7: invocation count $(invocations "$R")"

echo ""
echo "── guard-check: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
