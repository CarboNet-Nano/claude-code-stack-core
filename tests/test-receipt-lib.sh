#!/usr/bin/env bash
# Tests for lib/receipt.sh (ADR-087 D1, D3e). R1 subset of the 102-case plan,
# cases 1-11.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/lib/receipt.sh"
# shellcheck source=/dev/null
source "$LIB" || { echo "FATAL: could not source $LIB" >&2; exit 1; }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

valid_receipt_json() {
  local as_of="${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  jq -nc --arg as_of "$as_of" '{
    schema:"stack-receipt/v1", kind:"review", writer:"test@1",
    as_of:$as_of, max_age_s:604800,
    subject:{kind:"artifact", path:"foo.txt", content_sha:"3f9a000000000000000000000000000000000a",
             base_commit:null, reviewed_head:null, repo_root:"/tmp/repo", repo_hash:"abc123",
             mint_head_commit:"0833c3e00000000000000000000000000000ab"},
    verdict:"reviewed", reason:null, needs_human:false,
    evidence:{seat:"architecture-critic"}, error:null
  }'
}

# ─── 1: valid envelope round-trips ────────────────────────────────────────
P1="$TMP/1.json"
rcpt_write "$P1" "$(valid_receipt_json)"
OUT="$(rcpt_read "$P1")"
if [[ -n "$OUT" ]] && echo "$OUT" | jq -e '.schema=="stack-receipt/v1"' >/dev/null 2>&1; then
  pass "1: valid envelope round-trips"
else
  fail "1: round-trip failed: $OUT"
fi

# ─── 2: missing/wrong schema, unknown kind -> rc 1 ────────────────────────
P2A="$TMP/2a.json"
rcpt_write "$P2A" "$(valid_receipt_json | jq '.schema = "bogus/v1"')"
rcpt_read "$P2A" >/dev/null 2>&1 && fail "2a: wrong schema should rc 1" || pass "2a: wrong schema rc 1"

P2B="$TMP/2b.json"
rcpt_write "$P2B" "$(valid_receipt_json | jq 'del(.schema)')"
rcpt_read "$P2B" >/dev/null 2>&1 && fail "2b: missing schema should rc 1" || pass "2b: missing schema rc 1"

P2C="$TMP/2c.json"
rcpt_write "$P2C" "$(valid_receipt_json | jq '.kind = "bogus"')"
rcpt_read "$P2C" >/dev/null 2>&1 && fail "2c: unknown kind should rc 1" || pass "2c: unknown kind rc 1"

# ─── 3: ANSI/OSC-52 bytes in error -> sanitized at write time ─────────────
RAW=$'\x1b]52;c;ZXZpbA==\x07evil text\x1b[31mred\x1b[0m'
SAN="$(rcpt_sanitize "$RAW" 200)"
if [[ "$SAN" != *$'\x1b'* && "$SAN" != *$'\x07'* ]]; then
  pass "3: ANSI/OSC-52 bytes stripped"
else
  fail "3: raw control bytes survived sanitize: $(printf '%q' "$SAN")"
fi

# ─── 4: over-length truncated; multi-line -> first line only ─────────────
LONG="$(printf 'x%.0s' $(seq 1 300))"
SAN4="$(rcpt_sanitize "$LONG" 50)"
[[ "${#SAN4}" -le 50 ]] && pass "4a: over-length truncated to maxlen" || fail "4a: length ${#SAN4} > 50"

MULTI=$'first line\nsecond line\nthird line'
SAN4B="$(rcpt_sanitize "$MULTI" 200)"
[[ "$SAN4B" == "first line" ]] && pass "4b: multi-line -> first line only" || fail "4b: got '$SAN4B'"

# ─── 5: concurrent writes to one path -> always complete, valid JSON ─────
P5="$TMP/5.json"
for i in 1 2 3 4 5 6 7 8; do
  ( rcpt_write "$P5" "$(valid_receipt_json | jq --arg i "$i" '.writer = ("writer-"+$i)')" ) &
done
wait
if [[ -f "$P5" ]] && jq -e . "$P5" >/dev/null 2>&1; then
  pass "5: concurrent writes leave valid JSON"
else
  fail "5: concurrent writes corrupted the file"
fi

# ─── 6: rcpt_state -> NOT-CHECKED for absent/invalid/stale, never CLEAN ───
[[ "$(rcpt_state "$TMP/absent.json")" == "NOT-CHECKED" ]] \
  && pass "6a: absent -> NOT-CHECKED" || fail "6a: absent -> $(rcpt_state "$TMP/absent.json")"

P6B="$TMP/6b.json"
echo "not json" > "$P6B"
[[ "$(rcpt_state "$P6B")" == "NOT-CHECKED" ]] \
  && pass "6b: invalid -> NOT-CHECKED" || fail "6b: invalid -> $(rcpt_state "$P6B")"

P6C="$TMP/6c.json"
OLD_TS="$(date -u -v-8d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)"
rcpt_write "$P6C" "$(valid_receipt_json "$OLD_TS")"
[[ "$(rcpt_state "$P6C" 604800)" == "NOT-CHECKED" ]] \
  && pass "6c: past max_age_s -> NOT-CHECKED, never CLEAN" || fail "6c: stale -> $(rcpt_state "$P6C" 604800)"

P6D="$TMP/6d.json"
rcpt_write "$P6D" "$(valid_receipt_json)"
[[ "$(rcpt_state "$P6D")" == "CLEAN" ]] \
  && pass "6d: fresh valid receipt -> CLEAN" || fail "6d: fresh -> $(rcpt_state "$P6D")"

# ─── 7: symlinked destination -> write replaces, does not follow ─────────
REAL_TARGET="$TMP/7-outside.json"
echo '{"sentinel":"do-not-touch"}' > "$REAL_TARGET"
LINK="$TMP/7-link.json"
ln -s "$REAL_TARGET" "$LINK"
rcpt_write "$LINK" "$(valid_receipt_json)"
if [[ ! -L "$LINK" ]] && jq -e '.schema=="stack-receipt/v1"' "$LINK" >/dev/null 2>&1 \
   && jq -e '.sentinel=="do-not-touch"' "$REAL_TARGET" >/dev/null 2>&1; then
  pass "7: symlinked destination replaced, target untouched"
else
  fail "7: symlink handling wrong (link is_symlink=$([[ -L "$LINK" ]] && echo yes || echo no))"
fi

# ─── 8: both content_sha and patch_sha present -> invalid ────────────────
P8="$TMP/8.json"
rcpt_write "$P8" "$(valid_receipt_json | jq '.subject.patch_sha = "b71e000000000000000000000000000000000b"')"
rcpt_read "$P8" >/dev/null 2>&1 && fail "8: both subject kinds should be invalid" || pass "8: both subject kinds -> invalid"

# ─── 9: rcpt_artifact_sha refuses a symlink and a directory ──────────────
REPO9="$TMP/repo9"
mkdir -p "$REPO9/adir"
git -C "$REPO9" init -q 2>/dev/null
echo "content" > "$REPO9/file.txt"
ln -s "$REPO9/file.txt" "$REPO9/link.txt"
rcpt_artifact_sha "$REPO9" "link.txt" >/dev/null 2>&1
RC_LINK=$?
rcpt_artifact_sha "$REPO9" "adir" >/dev/null 2>&1
RC_DIR=$?
[[ "$RC_LINK" -ne 0 ]] && pass "9a: symlink refused (rc $RC_LINK)" || fail "9a: symlink accepted"
[[ "$RC_DIR" -ne 0 ]] && pass "9b: directory refused (rc $RC_DIR)" || fail "9b: directory accepted"

# ─── 10: stable across .gitattributes change (--no-filters); blob retrievable ─
REPO10="$TMP/repo10"
mkdir -p "$REPO10"
git -C "$REPO10" init -q 2>/dev/null
git -C "$REPO10" config user.email test@test.com; git -C "$REPO10" config user.name test
printf 'line1\r\nline2\r\n' > "$REPO10/crlf.txt"
git -C "$REPO10" add crlf.txt >/dev/null 2>&1
git -C "$REPO10" commit -q -m init >/dev/null 2>&1
SHA_BEFORE="$(rcpt_artifact_sha "$REPO10" "crlf.txt")"
echo "*.txt text eol=lf" > "$REPO10/.gitattributes"
SHA_AFTER="$(rcpt_artifact_sha "$REPO10" "crlf.txt")"
if [[ "$SHA_BEFORE" == "$SHA_AFTER" && -n "$SHA_BEFORE" ]]; then
  pass "10a: --no-filters keeps the hash stable across a .gitattributes change"
else
  fail "10a: hash changed ($SHA_BEFORE vs $SHA_AFTER) -- --no-filters not honored"
fi
if git -C "$REPO10" cat-file -e "$SHA_BEFORE" 2>/dev/null; then
  pass "10b: blob retrievable via git cat-file -e (-w honored)"
else
  fail "10b: blob not retrievable"
fi

# ─── 11: rcpt_patch_sha identical on repeat, differs when a commit changes ─
REPO11="$TMP/repo11"
mkdir -p "$REPO11"
git -C "$REPO11" init -q 2>/dev/null
git -C "$REPO11" config user.email test@test.com; git -C "$REPO11" config user.name test
echo "v1" > "$REPO11/f.txt"; git -C "$REPO11" add f.txt >/dev/null 2>&1
git -C "$REPO11" commit -q -m base >/dev/null 2>&1
BASE_SHA="$(git -C "$REPO11" rev-parse HEAD)"
echo "v2" > "$REPO11/f.txt"; git -C "$REPO11" add f.txt >/dev/null 2>&1
git -C "$REPO11" commit -q -m change1 >/dev/null 2>&1
HEAD1_SHA="$(git -C "$REPO11" rev-parse HEAD)"
PS1="$(rcpt_patch_sha "$REPO11" "$BASE_SHA" "$HEAD1_SHA")"
PS2="$(rcpt_patch_sha "$REPO11" "$BASE_SHA" "$HEAD1_SHA")"
[[ "$PS1" == "$PS2" && -n "$PS1" ]] && pass "11a: rcpt_patch_sha identical across two runs" || fail "11a: $PS1 vs $PS2"

echo "v3" > "$REPO11/f.txt"; git -C "$REPO11" add f.txt >/dev/null 2>&1
git -C "$REPO11" commit -q -m change2 >/dev/null 2>&1
HEAD2_SHA="$(git -C "$REPO11" rev-parse HEAD)"
PS3="$(rcpt_patch_sha "$REPO11" "$BASE_SHA" "$HEAD2_SHA")"
[[ "$PS3" != "$PS1" ]] && pass "11b: rcpt_patch_sha differs when a commit changes" || fail "11b: unchanged hash across different diffs"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
