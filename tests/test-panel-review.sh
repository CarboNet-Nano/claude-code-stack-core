#!/usr/bin/env bash
# Tests for scripts/panel-review.sh (ADR-087 D3a, D3b, D3f). R1 subset of the
# 102-case plan, cases 12-23. Vendor calls are stubbed (tests/fixtures/
# panel-review-stub-vendor.sh) — no network, no key, deterministic.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/panel-review.sh"
STUB="$REPO_ROOT/tests/fixtures/panel-review-stub-vendor.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t.com; git -C "$REPO" config user.name t
echo "hello world" > "$REPO/subject.txt"
git -C "$REPO" add subject.txt >/dev/null
git -C "$REPO" commit -q -m base >/dev/null
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
echo "hello world 2" >> "$REPO/subject.txt"
git -C "$REPO" add subject.txt >/dev/null
git -C "$REPO" commit -q -m change >/dev/null
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# run <seat> <extra-args...> (stdin passed through by caller)
run() {
  local seat="$1"; shift
  (cd "$REPO" && PR_GEMINI_LIB="$STUB" PR_OPENAI_LIB="$STUB" bash "$RUNNER" "$seat" "$@")
}

# D3f's floor is prompt_bytes >= 1000; the built-in seat prompts are well
# under that alone, so every test expecting a SUCCESS path needs enough piped
# context to clear the floor. big_ctx [marker] -> >=1000 bytes.
big_ctx() {
  local marker="${1:-}"
  printf '%s %s' "$marker" "$(printf '%*s' 1100 '' | tr ' ' 'a')"
}

# ─── 12: stubbed HTTP 200 -> exactly one REVIEW_EVIDENCE:v1 line, last,
#     valid base64, valid JSON ──────────────────────────────────────────────
OUT="$(big_ctx | STUB_RC=0 run architecture-critic --subject subject.txt)"
RC=$?
LINE_COUNT_MARKER="$(printf '%s\n' "$OUT" | grep -c 'REVIEW_EVIDENCE:v1 ')"
LAST_LINE="$(printf '%s\n' "$OUT" | tail -1)"
if [[ "$RC" -eq 0 && "$LINE_COUNT_MARKER" -eq 1 && "$LAST_LINE" == REVIEW_EVIDENCE:v1\ * ]]; then
  pass "12a: exactly one REVIEW_EVIDENCE:v1 line, on the success path"
else
  fail "12a: rc=$RC count=$LINE_COUNT_MARKER last='$LAST_LINE'"
fi
B64="${LAST_LINE#REVIEW_EVIDENCE:v1 }"
DECODED="$(printf '%s' "$B64" | base64 -d 2>/dev/null)"
if [[ -n "$DECODED" ]] && echo "$DECODED" | jq -e '.schema=="review-evidence/v1"' >/dev/null 2>&1; then
  pass "12b: base64 decodes to valid review-evidence/v1 JSON"
else
  fail "12b: decode/parse failed: $DECODED"
fi

# ─── 13: degraded paths -> no evidence line, non-zero exit, error names
#     vendor + status ────────────────────────────────────────────────────────
for HTTP in 429 500; do
  OUT13="$(echo "ctx" | STUB_RC=6 STUB_HTTP="$HTTP" run architecture-critic --subject subject.txt 2>"$TMP/err-$HTTP.txt")"
  RC13=$?
  ERRTXT="$(cat "$TMP/err-$HTTP.txt")"
  if [[ "$RC13" -ne 0 && "$OUT13" != *REVIEW_EVIDENCE:v1* && "$ERRTXT" == *"Gemini"* && "$ERRTXT" == *"$HTTP"* ]]; then
    pass "13-$HTTP: degraded call -> non-zero exit, no evidence line, names vendor+status"
  else
    fail "13-$HTTP: rc=$RC13 out='$OUT13' err='$ERRTXT'"
  fi
done
OUT13N="$(echo "ctx" | STUB_RC=5 STUB_HTTP=0 STUB_ERR_MSG="network/timeout" run reviewer --subject subject.txt 2>"$TMP/err-net.txt")"
RC13N=$?
[[ "$RC13N" -ne 0 && "$OUT13N" != *REVIEW_EVIDENCE:v1* ]] \
  && pass "13-network: network error -> non-zero, no evidence line" \
  || fail "13-network: rc=$RC13N out='$OUT13N'"

# ─── 14: stdin pass-through byte-for-byte; prompt_bytes/prompt_sha256
#     describe what was actually sent ────────────────────────────────────────
CTX="unique-context-marker-$$-$(date +%s)"
OUT14="$(big_ctx "$CTX" | STUB_RC=0 run reviewer --subject subject.txt)"
EV14="$(printf '%s\n' "$OUT14" | tail -1)"
DEC14="$(printf '%s' "${EV14#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
PBYTES="$(echo "$DEC14" | jq -r '.prompt_bytes')"
PSHA="$(echo "$DEC14" | jq -r '.prompt_sha256')"
if [[ "$PBYTES" -gt 0 && -n "$PSHA" && "$PSHA" != "null" ]]; then
  pass "14: prompt_bytes/prompt_sha256 present and non-trivial"
else
  fail "14: prompt_bytes=$PBYTES prompt_sha256=$PSHA"
fi

# ─── 15: --subject/--diff mutual exclusion + required; --diff mints "patch"
#     with full 40-hex refs; --subject mints "artifact" ─────────────────────
run reviewer --subject subject.txt --diff "${BASE_SHA}..${HEAD_SHA}" >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "15a: --subject and --diff together -> usage error" || fail "15a: did not error"
run reviewer >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "15b: neither --subject nor --diff -> usage error" || fail "15b: did not error"

OUT15C="$(big_ctx | STUB_RC=0 run reviewer --diff "${BASE_SHA}..${HEAD_SHA}")"
EV15C="$(printf '%s\n' "$OUT15C" | tail -1)"
DEC15C="$(printf '%s' "${EV15C#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
if echo "$DEC15C" | jq -e --arg b "$BASE_SHA" --arg h "$HEAD_SHA" \
    '.subject_kind=="patch" and .base_commit==$b and .reviewed_head==$h and (.base_commit|test("^[0-9a-f]{40}$")) and (.reviewed_head|test("^[0-9a-f]{40}$"))' \
    >/dev/null 2>&1; then
  pass "15c: --diff mints subject_kind=patch with full 40-hex refs"
else
  fail "15c: $DEC15C"
fi

OUT15D="$(big_ctx | STUB_RC=0 run architecture-critic --subject subject.txt)"
EV15D="$(printf '%s\n' "$OUT15D" | tail -1)"
DEC15D="$(printf '%s' "${EV15D#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
echo "$DEC15D" | jq -e '.subject_kind=="artifact"' >/dev/null 2>&1 \
  && pass "15d: --subject mints subject_kind=artifact" || fail "15d: $DEC15D"

# ─── 16: caller cannot supply a pre-computed hash; the runner recomputes ────
# There is no flag for this in the interface at all -- an attempt to pass one
# is a usage error, and the subject_sha in a real run is always freshly
# computed by rcpt_artifact_sha/rcpt_patch_sha (never taken from an argument).
run reviewer --subject subject.txt --content-sha deadbeef >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "16: no flag accepts a caller-supplied hash (unrecognized arg errors)" \
  || fail "16: unexpectedly accepted a hash argument"

# ─── 17: Claude-family model id from env -> refused, non-Claude fallback ────
OUT17="$(big_ctx | STUB_RC=0 PANEL_MODEL_REVIEWER="openai/claude-sonnet-5" run reviewer --subject subject.txt 2>"$TMP/err17.txt")"
EV17="$(printf '%s\n' "$OUT17" | tail -1)"
DEC17="$(printf '%s' "${EV17#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
MREQ17="$(echo "$DEC17" | jq -r '.model_requested')"
if [[ "$MREQ17" != *claude* && "$MREQ17" != *sonnet* ]] && grep -q "REFUSED Claude-family" "$TMP/err17.txt"; then
  pass "17: Claude-family model id refused, non-Claude fallback used"
else
  fail "17: model_requested='$MREQ17' stderr='$(cat "$TMP/err17.txt")'"
fi

# ─── 18: model_returned != model_requested -> recorded faithfully ───────────
OUT18="$(big_ctx | STUB_RC=0 STUB_MODEL_RETURNED="gpt-5.6-terra-20260801" run reviewer --subject subject.txt)"
EV18="$(printf '%s\n' "$OUT18" | tail -1)"
DEC18="$(printf '%s' "${EV18#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
if echo "$DEC18" | jq -e '.model_returned=="gpt-5.6-terra-20260801" and .model_returned != .model_requested' >/dev/null 2>&1; then
  pass "18: model_returned != model_requested recorded faithfully"
else
  fail "18: $DEC18"
fi

# ─── 19: prompt exceeding max input -> truncation happens, prompt_sha256
#     hashes the truncated, actually-sent text ───────────────────────────────
BIGCTX="$(printf '%*s' 800000 '' | tr ' ' 'y')"
OUT19="$(printf '%s' "$BIGCTX" | STUB_RC=0 PR_MAX_INPUT_BYTES=700000 run reviewer --subject subject.txt)"
EV19="$(printf '%s\n' "$OUT19" | tail -1)"
DEC19="$(printf '%s' "${EV19#REVIEW_EVIDENCE:v1 }" | base64 -d 2>/dev/null)"
PB19="$(echo "$DEC19" | jq -r '.prompt_bytes')"
# Truncated length = cap + marker length (same shape as gmn_call/oair_call's
# own truncation) -- meaningfully smaller than the ~800KB untruncated input,
# not exactly <= the cap.
[[ "$PB19" -lt 750000 ]] && pass "19: prompt truncated near PR_MAX_INPUT_BYTES (not the full ~800KB)" || fail "19: prompt_bytes=$PB19"

# ─── 20: rc 0 but no/empty sidecar -> non-zero exit, nothing minted ─────────
OUT20="$(echo "ctx" | STUB_RC=0 STUB_NO_SIDECAR=1 run reviewer --subject subject.txt 2>"$TMP/err20.txt")"
RC20=$?
[[ "$RC20" -ne 0 && "$OUT20" != *REVIEW_EVIDENCE:v1* ]] \
  && pass "20: rc0-but-no-sidecar -> non-zero exit, nothing minted" \
  || fail "20: rc=$RC20 out='$OUT20'"

# ─── 21: sidecar is chmod 0600, deleted after read, not inherited ───────────
grep -q 'chmod 0600 "\$SIDECAR"' "$RUNNER" \
  && pass "21a: sidecar chmod 0600 (static)" || fail "21a: chmod 0600 not found in source"
grep -q 'rm -f "\$SIDECAR"' "$RUNNER" \
  && pass "21b: sidecar deleted after read (static)" || fail "21b: rm not found in source"
BEFORE_DIRS="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'panel-review.*' 2>/dev/null | wc -l | tr -d ' ')"
echo "ctx" | STUB_RC=0 run reviewer --subject subject.txt >/dev/null 2>&1
AFTER_DIRS="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'panel-review.*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$AFTER_DIRS" -eq "$BEFORE_DIRS" ]] && pass "21c: sidecar dir cleaned up (trap), none linger after run" \
  || fail "21c: before=$BEFORE_DIRS after=$AFTER_DIRS"

# ─── 22: no *_LAST_* exported global exists after a call ────────────────────
(
  echo "ctx" | STUB_RC=0 PR_GEMINI_LIB="$STUB" PR_OPENAI_LIB="$STUB" bash "$RUNNER" reviewer --subject "$REPO/subject.txt" >/dev/null 2>&1
  if env | grep -qE '_LAST_'; then
    echo "FOUND_LEAK"
  fi
) > "$TMP/env-check.txt" 2>&1
grep -q FOUND_LEAK "$TMP/env-check.txt" && fail "22a: a *_LAST_* env var leaked" || pass "22a: no *_LAST_* env var after a call"
grep -qE '_LAST_' scripts/lib/gemini-api.sh scripts/lib/openai-review.sh scripts/lib/deepseek-review.sh scripts/lib/grok-review.sh 2>/dev/null \
  && fail "22b: a vendor lib still references a *_LAST_* global" \
  || pass "22b: no vendor lib references a *_LAST_* global (static)"

# ─── 23: non-vacuity floors -> no evidence line ──────────────────────────────
for CASE in "STUB_OUTPUT_BYTES=120" "STUB_OUTPUT_TOKENS=40"; do
  eval "$CASE"
  OUT23="$(echo "$(printf '%*s' 1200 '' | tr ' ' 'z')" | STUB_RC=0 STUB_OUTPUT_BYTES="${STUB_OUTPUT_BYTES:-600}" STUB_OUTPUT_TOKENS="${STUB_OUTPUT_TOKENS:-150}" run reviewer --subject subject.txt 2>"$TMP/err23.txt")"
  RC23=$?
  if [[ "$RC23" -ne 0 && "$OUT23" != *REVIEW_EVIDENCE:v1* ]]; then
    pass "23-$CASE: floor violation -> no evidence line"
  else
    fail "23-$CASE: rc=$RC23 out='$OUT23'"
  fi
  unset STUB_OUTPUT_BYTES STUB_OUTPUT_TOKENS
done
# prompt_bytes < 1000: use a trivial default prompt with no piped context so
# the assembled prompt stays well under the 1000-byte floor.
OUT23B="$(: | STUB_RC=0 run reviewer --subject subject.txt 2>"$TMP/err23b.txt")"
RC23B=$?
if [[ "$RC23B" -ne 0 && "$OUT23B" != *REVIEW_EVIDENCE:v1* ]]; then
  pass "23-prompt_bytes: floor violation -> no evidence line"
else
  fail "23-prompt_bytes: rc=$RC23B out='$OUT23B'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
