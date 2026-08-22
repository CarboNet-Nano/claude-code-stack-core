#!/usr/bin/env bash
# Tests for hooks/review-receipt-mint.sh (ADR-087 D3d). R1 subset of the
# 102-case plan, cases 24-31.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/review-receipt-mint.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
# The hook resolves its receipt dir via ${CLAUDE_CONFIG_DIR:-$HOME/.claude} --
# unset any inherited CLAUDE_CONFIG_DIR (e.g. a .claude-lade dev profile) so
# every write in this test lands under the synthetic $HOME above, never a
# real profile on the machine running the suite.
unset CLAUDE_CONFIG_DIR

REPO="$TMP/target-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t.com; git -C "$REPO" config user.name t
echo "hello" > "$REPO/subject.txt"
git -C "$REPO" add subject.txt >/dev/null
git -C "$REPO" commit -q -m base >/dev/null
CONTENT_SHA="$(git -C "$REPO" hash-object -w --no-filters "$REPO/subject.txt")"

# The hook derives repo_root from `git -C "$CWD" rev-parse --show-toplevel`,
# which resolves through macOS's /var -> /private/var symlink -- hash the
# SAME resolved path here, not the raw $REPO string, or repo_hash mismatches.
REPO_REALROOT="$(git -C "$REPO" rev-parse --show-toplevel)"
REPO_HASH="$(shasum -a 256 <<<"$REPO_REALROOT" | cut -c1-12)"

# make_evidence <seat> [overrides-jq-filter] -> prints base64 evidence
make_evidence() {
  local seat="$1" overrides="${2:-.}"
  jq -nc --arg seat "$seat" --arg path "subject.txt" --arg sha "$CONTENT_SHA" '{
    schema:"review-evidence/v1", seat:$seat, vendor:"google", family:"gemini",
    model_requested:"gemini-3.1-pro-preview", model_returned:"gemini-3.1-pro-preview",
    http_status:200, response_id:"resp-1",
    usage:{input_tokens:500, output_tokens:150},
    subject_kind:"artifact", subject_path:$path, subject_sha:$sha,
    base_commit:null, reviewed_head:null,
    prompt_sha256:"abc", prompt_bytes:1200, output_sha256:"def", output_bytes:600,
    called_at:"2026-08-20T00:00:00Z"
  }' | jq -c "$overrides" | base64 | tr -d '\n'
}

# payload <command> <stdout-string> -> jq-built PostToolUse payload (bare-string tool_response)
payload_string() {
  jq -nc --arg cwd "$1" --arg cmd "$2" --arg out "$3" \
    '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:$out}'
}
payload_field() {
  local cwd="$1" cmd="$2" out="$3" field="$4"
  jq -nc --arg cwd "$cwd" --arg cmd "$cmd" --arg out "$out" --arg field "$field" \
    '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:{($field):$out}}'
}

receipt_path() {
  local seat="$1" kind="$2" sha="$3"
  echo "$HOME/.claude/state/attest/reviews/${REPO_HASH}/${kind}/${sha}/${seat}.json"
}

# ─── 24: tool_response shapes -> mints in all five ──────────────────────────
run_shape() {
  local shape="$1" seat="$2" payload="$3"
  rm -f "$(receipt_path "$seat" artifact "$CONTENT_SHA")"
  echo "$payload" | bash "$HOOK" >/dev/null 2>&1
  [[ -f "$(receipt_path "$seat" artifact "$CONTENT_SHA")" ]] \
    && pass "24-$shape: mints from tool_response.$shape" \
    || fail "24-$shape: no receipt written"
}

EV="$(make_evidence architecture-critic)"
OUT_STR="the critique text
REVIEW_EVIDENCE:v1 $EV"

run_shape "bare-string" architecture-critic "$(payload_string "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT_STR")"
run_shape "stdout" architecture-critic "$(payload_field "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT_STR" stdout)"
run_shape "output" architecture-critic "$(payload_field "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT_STR" output)"
run_shape "content" architecture-critic "$(payload_field "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT_STR" content)"

# marker-only-in-raw-JSON shape: nested structure the direct probes miss but
# the raw-scan fallback catches.
RAW_NESTED="$(jq -nc --arg cwd "$REPO" --arg cmd "bash scripts/panel-review.sh architecture-critic --subject subject.txt" --arg out "$OUT_STR" \
  '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:{nested:{deep:$out}}}')"
run_shape "raw-scan" architecture-critic "$RAW_NESTED"

# ─── 25: two marker lines in one payload -> two receipts ───────────────────
EV_A="$(make_evidence reviewer)"
EV_B="$(make_evidence security-auditor)"
rm -f "$(receipt_path reviewer artifact "$CONTENT_SHA")" "$(receipt_path security-auditor artifact "$CONTENT_SHA")"
TWO_LINES="critique A
REVIEW_EVIDENCE:v1 $EV_A
critique B
REVIEW_EVIDENCE:v1 $EV_B"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh reviewer --subject subject.txt" "$TWO_LINES")" | bash "$HOOK" >/dev/null 2>&1
if [[ -f "$(receipt_path reviewer artifact "$CONTENT_SHA")" && -f "$(receipt_path security-auditor artifact "$CONTENT_SHA")" ]]; then
  pass "25: two marker lines -> two receipts"
else
  fail "25: missing one or both receipts"
fi

# ─── 26: marker present but command does not name panel-review.sh -> nothing
EV26="$(make_evidence product-critic)"
rm -f "$(receipt_path product-critic artifact "$CONTENT_SHA")"
echo "$(payload_string "$REPO" "bash some-other-script.sh" "REVIEW_EVIDENCE:v1 $EV26")" | bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$(receipt_path product-critic artifact "$CONTENT_SHA")" ]] \
  && pass "26: command not naming panel-review.sh -> nothing minted" \
  || fail "26: minted despite missing provenance"

# ─── 27: malformed base64 / valid-base64-not-json -> nothing, exit 0, no partial file
rm -f "$(receipt_path architecture-critic artifact "$CONTENT_SHA")"
OUT27="REVIEW_EVIDENCE:v1 ###not-valid-base64###"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT27")" | bash "$HOOK" >/dev/null 2>&1
RC27=$?
[[ "$RC27" -eq 0 && ! -f "$(receipt_path architecture-critic artifact "$CONTENT_SHA")" ]] \
  && pass "27a: malformed base64 -> exit 0, nothing minted" \
  || fail "27a: rc=$RC27"

NOTJSON_B64="$(printf 'not json at all' | base64 | tr -d '\n')"
OUT27B="REVIEW_EVIDENCE:v1 $NOTJSON_B64"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh architecture-critic --subject subject.txt" "$OUT27B")" | bash "$HOOK" >/dev/null 2>&1
RC27B=$?
[[ "$RC27B" -eq 0 && ! -f "$(receipt_path architecture-critic artifact "$CONTENT_SHA")" ]] \
  && pass "27b: valid base64, not JSON -> exit 0, nothing minted" \
  || fail "27b: rc=$RC27B"
NO_STRAY_FILES="$(find "$HOME/.claude/state/attest" -type f 2>/dev/null | grep -c 'architecture-critic.json' || true)"
[[ "$NO_STRAY_FILES" -eq 0 ]] && pass "27c: no partial file left behind" || fail "27c: found $NO_STRAY_FILES stray file(s)"

# ─── 28: hook always exits 0 — jq absent, HOME unset, receipt dir unwritable
EV28="$(make_evidence reviewer)"
OUT28="REVIEW_EVIDENCE:v1 $EV28"
PAYLOAD28="$(payload_string "$REPO" "bash scripts/panel-review.sh reviewer --subject subject.txt" "$OUT28")"

# jq lives outside the macOS base system (/usr/bin:/bin) -- a curated PATH
# with only the base system directories keeps bash/git/cat/grep usable while
# making jq genuinely unresolvable, unlike a temporary prefix assignment on
# one pipeline command (which would not affect PATH resolution for `bash`
# itself, invoked as a separate command in the same pipeline).
( export PATH="/usr/bin:/bin"
  command -v jq >/dev/null 2>&1 && { echo "SKIP: jq is on the base-system PATH on this machine" >&2; exit 0; }
  echo "$PAYLOAD28" | bash "$HOOK" >/dev/null 2>&1 )
RC28A=$?
[[ "$RC28A" -eq 0 ]] && pass "28a: exits 0 even with jq unreachable on PATH" || fail "28a: rc=$RC28A"

( unset HOME; echo "$PAYLOAD28" | bash "$HOOK" >/dev/null 2>&1 )
RC28B=$?
[[ "$RC28B" -eq 0 ]] && pass "28b: exits 0 with HOME unset" || fail "28b: rc=$RC28B"

RO_HOME="$TMP/ro-home"
mkdir -p "$RO_HOME/.claude"
chmod 000 "$RO_HOME/.claude"
( export HOME="$RO_HOME"; echo "$PAYLOAD28" | bash "$HOOK" >/dev/null 2>&1 )
RC28C=$?
chmod 755 "$RO_HOME/.claude"
[[ "$RC28C" -eq 0 ]] && pass "28c: exits 0 with an unwritable receipt dir" || fail "28c: rc=$RC28C"

# ─── 29: pre-mint attack — subject_sha names content that does not exist ───
FAKE_SHA="0000000000000000000000000000000000dead"
EV29="$(make_evidence architecture-critic ".subject_path=\"ghost.txt\" | .subject_sha=\"$FAKE_SHA\"")"
rm -f "$(receipt_path architecture-critic artifact "$FAKE_SHA")"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh architecture-critic --subject ghost.txt" "REVIEW_EVIDENCE:v1 $EV29")" | bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$(receipt_path architecture-critic artifact "$FAKE_SHA")" ]] \
  && pass "29a: subject naming nonexistent content -> nothing minted" \
  || fail "29a: minted for nonexistent content"

echo "unrelated content" > "$REPO/ghost.txt"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh architecture-critic --subject ghost.txt" "REVIEW_EVIDENCE:v1 $EV29")" | bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$(receipt_path architecture-critic artifact "$FAKE_SHA")" ]] \
  && pass "29b: replay after creating mismatched content -> still nothing minted" \
  || fail "29b: minted on replay"

# ─── 30: payload claims sha X for a file that hashes to Y -> nothing ───────
REAL_GHOST_SHA="$(git -C "$REPO" hash-object -w --no-filters "$REPO/ghost.txt")"
rm -f "$(receipt_path reviewer artifact "$REAL_GHOST_SHA")"
EV30="$(make_evidence reviewer '.subject_path="ghost.txt" | .subject_sha="ffffffffffffffffffffffffffffffffffffff"')"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh reviewer --subject ghost.txt" "REVIEW_EVIDENCE:v1 $EV30")" | bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$(receipt_path reviewer artifact "$REAL_GHOST_SHA")" && ! -f "$(receipt_path reviewer artifact ffffffffffffffffffffffffffffffffffffff)" ]] \
  && pass "30: claimed sha != actual file hash -> nothing minted" \
  || fail "30: minted despite hash mismatch"

# ─── 31: payload below any D3f floor -> nothing minted ─────────────────────
rm -f "$(receipt_path reviewer artifact "$CONTENT_SHA")"
EV31="$(make_evidence reviewer '.output_bytes=100')"
echo "$(payload_string "$REPO" "bash scripts/panel-review.sh reviewer --subject subject.txt" "REVIEW_EVIDENCE:v1 $EV31")" | bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$(receipt_path reviewer artifact "$CONTENT_SHA")" ]] \
  && pass "31: below-floor payload -> nothing minted" \
  || fail "31: minted despite floor violation"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
