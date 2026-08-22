#!/usr/bin/env bash
# Tests for ADR-087 D9 — review-gate overrides (hooks/review-gate.sh's
# override handling + scripts/review-gate-override.sh). R1 subset of the
# 102-case plan, cases 62-70.
#
# Cases NOT executable in a unit-test sandbox, printed as NOT-EXECUTED rather
# than silently skipped or falsely passed:
#   68 — the ADR-057 amendment (hooks/usage-check-gate.sh's own override files
#        moving under state/attest/override/) is OUT OF SCOPE for this R1
#        session (see implementer handoff) -- there is no legacy ADR-057
#        override path to test yet.
#   69 — requires the managed floor actually INSTALLED at
#        /Library/Application Support/ClaudeCode/managed-settings.json
#        (a sudo, human, out-of-band step per docs/runbooks/managed-floor-
#        install.md). R0 answered this empirically for denyWrite generally
#        (YES, binds tool-spawned scripts) but installing the floor here
#        would mutate a real machine file outside this test's sandbox.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/review-gate.sh"
OVERRIDE_SCRIPT="$REPO_ROOT/scripts/review-gate-override.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
NOTRUN=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
notrun() { echo "NOT-EXECUTED: $1"; NOTRUN=$((NOTRUN+1)); }

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset CLAUDE_CONFIG_DIR

make_repo() {
  local R="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$R/.claude"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  echo base > "$R/README.md"
  jq -nc '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01", guards:{review_gate:"on"}}' > "$R/.claude/stack-config.json"
  git -C "$R" add -A; git -C "$R" commit -qm base >/dev/null
  git -C "$R" checkout -q -b feat
  echo x > "$R/x"; git -C "$R" add -A; git -C "$R" commit -qm x >/dev/null
  echo "$R"
}

dispatch_payload() {
  jq -nc --arg cwd "$1" --arg agent "$2" --arg prompt "$3" --arg transcript "${4:-}" \
    '{cwd:$cwd, tool_name:"Agent", tool_input:{subagent_type:$agent, prompt:$prompt}, transcript_path:$transcript}'
}
run_gate() { echo "$1" | bash "$HOOK" 2>/dev/null; }
repo_hash_of() {
  local realroot; realroot="$(git -C "$1" rev-parse --show-toplevel)"
  shasum -a 256 <<<"$realroot" | cut -c1-12
}

DISABLE_FILE="$HOME/.claude/state/attest/override/review-gate.disabled"
OVLOG_DIR="$HOME/.claude/state/attest/override/log"

# ─── 62: disable file with a reason -> gate exits 0 before reading stdin;
#     protected-copy log row exists with the sanitized reason ─────────────
mkdir -p "$(dirname "$DISABLE_FILE")"
printf 'planned maintenance window\n' > "$DISABLE_FILE"
R62="$(make_repo)"
OUT62="$(run_gate "$(dispatch_payload "$R62" implementer "no subject")")"
[[ -z "$OUT62" ]] && pass "62a: disable file with a reason -> exit 0 (no output at all)" || fail "62a: out='$OUT62'"
FOUND62=0
for f in "$OVLOG_DIR"/*.json; do
  [[ -f "$f" ]] || continue
  jq -e '.tier=="machine" and .reason=="planned maintenance window"' "$f" >/dev/null 2>&1 && FOUND62=1
done
[[ "$FOUND62" -eq 1 ]] && pass "62b: protected-copy log row exists with the sanitized reason" || fail "62b: no matching protected log row"
rm -f "$DISABLE_FILE"; rm -rf "$OVLOG_DIR"

# ─── 63 (light -- full coverage in test-review-gate.sh:53): empty disable
#     file -> does not disable, generic machinery deny ─────────────────────
: > "$DISABLE_FILE"
R63="$(make_repo)"
OUT63="$(run_gate "$(dispatch_payload "$R63" implementer "no subject")")"
rm -f "$DISABLE_FILE"
[[ "$OUT63" == *"reason=machinery"* ]] && pass "63: empty disable file -> does not disable, generic machinery deny" || fail "63: out='$OUT63'"

# ─── 64: reason with ANSI/OSC/CR bytes -> sanitized in the protected copy ──
RAW=$'\x1b]52;c;ZXZpbA==\x07malicious\rreason\x1b[31m'
printf '%s\n' "$RAW" > "$DISABLE_FILE"
R64="$(make_repo)"
run_gate "$(dispatch_payload "$R64" implementer "no subject")" >/dev/null
rm -f "$DISABLE_FILE"
CLEAN64=0
for f in "$OVLOG_DIR"/*.json; do
  [[ -f "$f" ]] || continue
  RSN="$(jq -r '.reason // empty' "$f" 2>/dev/null)"
  [[ "$RSN" != *$'\x1b'* && "$RSN" != *$'\x07'* && "$RSN" != *$'\r'* ]] && CLEAN64=1
done
[[ "$CLEAN64" -eq 1 ]] && pass "64: ANSI/OSC/CR bytes sanitized in the protected copy" || fail "64: raw control bytes survived"
rm -rf "$OVLOG_DIR"

# ─── 65: per-repo repo-once override, consumed exactly once ───────────────
R65="$(make_repo)"
RH65="$(repo_hash_of "$R65")"
# Simulate a real terminal (this test suite itself runs inside a Claude Code
# session, where CLAUDECODE is set) for the write-logic assertions below --
# the guard itself is covered separately by case 70.
( cd "$R65" && unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  bash "$OVERRIDE_SCRIPT" --reason "fixing a flaky test" >/dev/null )
OVFILE65="$HOME/.claude/state/attest/override/repo-once/${RH65}.json"
[[ -f "$OVFILE65" ]] && pass "65a: review-gate-override.sh wrote the repo-once file" || fail "65a: no override file written"
OUT65A="$(run_gate "$(dispatch_payload "$R65" implementer "no subject")")"
[[ -z "$OUT65A" ]] && pass "65b: first denied dispatch after the override -> bypassed (exit clean)" || fail "65b: out='$OUT65A'"
[[ -f "${OVFILE65}.used" && ! -f "$OVFILE65" ]] && pass "65c: override consumed exactly once (renamed to .used)" || fail "65c: override file state wrong"
OUT65B="$(run_gate "$(dispatch_payload "$R65" implementer "no subject")")"
[[ "$OUT65B" == *"reason=no_subject_declared"* ]] && pass "65d: second dispatch denies normally (override not reusable)" || fail "65d: out='$OUT65B'"

# ─── 66: no code path anywhere reads <repo>/.claude/.review-gate-override-once
if grep -rq '\.review-gate-override-once' "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" "$REPO_ROOT/lib" 2>/dev/null; then
  fail "66: a rev-2-style repo-local override path still exists somewhere"
else
  pass "66: no code path reads a repo-local .review-gate-override-once file"
fi

# ─── 67: override under workflow context -> refused ────────────────────────
R67="$(make_repo)"
RH67="$(repo_hash_of "$R67")"
mkdir -p "$HOME/.claude/state/attest/override/repo-once"
jq -nc --arg reason "workflow bypass attempt" '{reason:$reason}' > "$HOME/.claude/state/attest/override/repo-once/${RH67}.json"
OUT67="$(run_gate "$(dispatch_payload "$R67" implementer "no subject" "/some/path/workflows/run-123/transcript.jsonl")")"
[[ "$OUT67" == *"reason=no_subject_declared"* ]] && pass "67: override under workflow context is refused, real deny happens" || fail "67: out='$OUT67'"
[[ -f "$HOME/.claude/state/attest/override/repo-once/${RH67}.json" ]] && pass "67b: workflow-context override file left unconsumed" || fail "67b: override file was consumed despite workflow context"

notrun "68: ADR-057 legacy override amendment -- out of R1 scope this session"
notrun "69: floor-installed denyWrite proof -- requires a real sudo floor install, not reproducible in this sandbox"

# ─── 70: review-gate-override.sh under CLAUDECODE -> refusal + exit 3 ─────
OUT70="$(CLAUDECODE=1 bash "$OVERRIDE_SCRIPT" --reason "should be refused" 2>&1)"
RC70=$?; [[ $RC70 -eq 3 ]] && [[ "$OUT70" == *"Refused"* ]] && pass "70a: CLAUDECODE=1 -> refusal + exit 3" || fail "70a: rc=$RC70 out='$OUT70'"
grep -qi "HUMAN-ONLY" "$OVERRIDE_SCRIPT" && pass "70b: header declares HUMAN-ONLY" || fail "70b: no HUMAN-ONLY declaration found"

echo ""
echo "Results: $PASS passed, $FAIL failed, $NOTRUN not-executed"
[[ "$FAIL" -eq 0 ]]
