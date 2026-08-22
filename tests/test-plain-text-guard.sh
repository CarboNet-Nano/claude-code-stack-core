#!/usr/bin/env bash
# Tests for lib/plain-text-guard.sh (ADR-072 D10, Stage 2) — the vocabulary
# gate extracted from scripts/org-check.sh. This suite is additive to
# tests/test-carbonet-check.sh, which is the extraction's own acceptance gate
# (it must keep passing unchanged — asserted here too, by re-running it).
#
# Isolated-repo precedent for "lib truly absent everywhere" (both the
# installed AND repo-fallback resolution paths) is copied from
# tests/test-carbonet-check.sh's R5 case: resolve_lib's repo-fallback would
# otherwise just find this checkout's own committed lib/ and mask the bug,
# so org-check.sh has to run from a COPY relocated outside the real repo.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_LIB="$REPO_ROOT/lib/plain-text-guard.sh"
ORG_CHECK="$REPO_ROOT/scripts/org-check.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/plain-text-guard-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------- 1. carbonet-check gate
if bash "$REPO_ROOT/tests/test-carbonet-check.sh" >"$TMP/carbonet-check.out" 2>&1; then
  pass "test-carbonet-check.sh passes unchanged after the extraction (acceptance gate)"
else
  fail "test-carbonet-check.sh regressed: $(tail -5 "$TMP/carbonet-check.out")"
fi

# ------------------------------------------------------- 2. reproduced bypasses
( source "$GUARD_LIB"
  fails=0
  check() {  # check <label> <input> <should-be-placeholder: yes|no>
    local label="$1" input="$2" want="$3" got
    got="$(sanitize_field "$input")"
    if [[ "$want" == "yes" && "$got" == "(from your settings)" ]]; then
      echo "PASS: $label"
    elif [[ "$want" == "no" && "$got" == "$input" ]]; then
      echo "PASS: $label"
    else
      echo "FAIL: $label (got '$got')"
      fails=$((fails+1))
    fi
  }
  check "mixed case (TokEn)" "my TokEn value" yes
  check "mixed case (CrEdEnTiAl)" "a CrEdEnTiAl here" yes
  check "separator-obfuscated (A-P-I)" "the A-P-I key" yes
  check "separator-obfuscated (cre-dential)" "a cre-dential value" yes
  check "separator-obfuscated (4-0-1)" "status 4-0-1" yes
  check "bare env" "set via env" yes
  check "homoglyph (Cyrillic а in token)" "$(printf 'a t\xd0\xbeken value')" yes
  check "honest value passes through" "Terms review finished" no
  exit "$fails"
) && pass "guard: every reproduced bypass from org-check.sh's comments is caught" \
  || fail "guard: at least one reproduced bypass leaked through"

# ------------------------------------------------- 3. sanitize_path / tmpdir
( source "$GUARD_LIB"
  got="$(sanitize_path "/var/folders/mp/qf1s7k_x3dlgpr38f5wr6nt40000gq/T/tmp.40000gq/session.diff")"
  [[ "$got" == "/var/folders/mp/qf1s7k_x3dlgpr38f5wr6nt40000gq/T/tmp.40000gq/session.diff" ]]
) && pass "sanitize_path: does not false-positive on an incidental 3-digit run in \$TMPDIR" \
  || fail "sanitize_path: false-positived on a normal tmpdir path"

# ------------------------------------------------- 4. Finding 8: lib absent
mkworld_min() {  # mkworld_min <name> -> isolated repo + fake home, org-check runnable
  local name="$1"
  local w="$TMP/w-$name"
  mkdir -p "$w/home/.claude/config" "$w/isolated-repo/scripts" "$w/isolated-repo/lib" "$w/proj/.claude"
  cat > "$w/home/.claude/config/org.json" <<'EOF'
{"version":1,"org":{"id":"t","display_name":"Test Org","access_url":"https://example.test","support_contact":"admin"}}
EOF
  cat > "$w/proj/.claude/stack-config.json" <<'EOF'
{"stack_version":"1.0.0","stack_tier":0,"purpose":"p","created":"2026-01-01"}
EOF
  cp "$ORG_CHECK" "$w/isolated-repo/scripts/org-check.sh"
  printf '%s' "$w"
}

W4="$(mkworld_min absent)"
OUT4="$(cd "$W4/proj" && HOME="$W4/home" bash "$W4/isolated-repo/scripts/org-check.sh" \
  --org-config "$W4/home/.claude/config/org.json" --stack-config "$W4/proj/.claude/stack-config.json" --no-network 2>&1)"
RC4=$?
if [[ "$RC4" != "2" ]]; then
  pass "Finding 8: lib absent -> normal verdict code ($RC4), not exit 2"
else
  fail "Finding 8: lib absent -> exit 2 (bricked)"
fi
if printf '%s' "$OUT4" | grep -q "✅\|❌\|⚠️"; then
  pass "Finding 8: lib absent -> the ✅/❌/⚠️ rows still print"
else
  fail "Finding 8: lib absent -> no check rows printed"
fi
if printf '%s' "$OUT4" | grep -q "(from your settings)"; then
  pass "Finding 8: lib absent -> config-derived value replaced with the placeholder"
else
  fail "Finding 8: lib absent -> no placeholder seen (unexpected unless nothing needed sanitizing)"
fi
if printf '%s' "$OUT4" | grep -q "some details hidden — your setup is mid-update"; then
  pass "Finding 8: lib absent -> disclosure line printed, degradation not silent"
else
  fail "Finding 8: lib absent -> missing disclosure line"
fi
if printf '%s' "$OUT4" | grep -qi "Test Org"; then
  fail "Finding 8: an unsanitized value ('Test Org') leaked through in degraded mode"
else
  pass "Finding 8: no unsanitized value leaked through in degraded mode"
fi

OUT4_JSON="$(cd "$W4/proj" && HOME="$W4/home" bash "$W4/isolated-repo/scripts/org-check.sh" \
  --org-config "$W4/home/.claude/config/org.json" --stack-config "$W4/proj/.claude/stack-config.json" --no-network --json 2>&1)"
if printf '%s' "$OUT4_JSON" | jq -e '.guard_degraded == true' >/dev/null 2>&1; then
  pass "Finding 8: --json marks guard_degraded:true"
else
  fail "Finding 8: --json missing guard_degraded:true: $OUT4_JSON"
fi

# --------------------------------------- 5. lib fails halfway through sourcing
W5="$(mkworld_min halfway)"
cat > "$W5/isolated-repo/lib/plain-text-guard.sh" <<'EOF'
#!/usr/bin/env bash
_scv_has_non_ascii() { return 1; }
this is not valid bash and will abort sourcing right here
sanitize_field() { printf '%s' "$1"; }
sanitize_path() { printf '%s' "$1"; }
EOF
OUT5="$(cd "$W5/proj" && HOME="$W5/home" bash "$W5/isolated-repo/scripts/org-check.sh" \
  --org-config "$W5/home/.claude/config/org.json" --stack-config "$W5/proj/.claude/stack-config.json" --no-network 2>&1)"
RC5=$?
if [[ "$RC5" != "2" ]] && printf '%s' "$OUT5" | grep -q "some details hidden — your setup is mid-update"; then
  pass "A lib that fails halfway through sourcing -> the same untrusted-everything mode"
else
  fail "Halfway-sourcing case did not degrade safely (rc=$RC5): $OUT5"
fi
if printf '%s' "$OUT5" | grep -qi "Test Org"; then
  fail "Halfway-sourcing case leaked an unsanitized value"
else
  pass "Halfway-sourcing case: no unsanitized value leaked"
fi

# --------------------------------------- 6. pre-existing tool failures unchanged
W6="$(mkworld_min tool-fail)"
rm -f "$W6/home/.claude/config/org.json"
OUT6="$(cd "$W6/proj" && HOME="$W6/home" bash "$ORG_CHECK" \
  --org-config "$W6/home/.claude/config/org.json" --stack-config "$W6/proj/.claude/stack-config.json" 2>&1)"
RC6=$?
[[ "$RC6" == "2" ]] && pass "org-check.sh still exits 2 for missing org.json (unrelated to the guard)" \
  || fail "org-check.sh: missing org.json should exit 2, got $RC6"

W7="$(mkworld_min bad-url)"
cat > "$W7/home/.claude/config/org.json" <<'EOF'
{"version":1,"org":{"id":"t","display_name":"Test Org","access_url":"http://example.test","support_contact":"admin"}}
EOF
OUT7="$(cd "$W7/proj" && HOME="$W7/home" bash "$ORG_CHECK" \
  --org-config "$W7/home/.claude/config/org.json" --stack-config "$W7/proj/.claude/stack-config.json" 2>&1)"
RC7=$?
[[ "$RC7" == "2" ]] && pass "org-check.sh still exits 2 for non-https access_url (unrelated to the guard)" \
  || fail "org-check.sh: non-https access_url should exit 2, got $RC7"

echo "test-plain-text-guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
