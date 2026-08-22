#!/usr/bin/env bash
# Tests for hooks/review-gate.sh (ADR-087 D4, D5). R1 subset of the 102-case
# plan. This file covers the G1 mount (Agent|Task, implementer dispatch) and
# every mount-agnostic case (disable file, jq/config machinery, deny-message
# hygiene). G2-mount-specific cases (46-50: gh pr create matching, ref-
# rewrite, telemetry candidates) are added in the commit that ships G2.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/review-gate.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset CLAUDE_CONFIG_DIR

# make_repo <mode> -> echoes repo path. Fresh git repo, stack-config.json
# with guards.review_gate=<mode>, one file committed on main so HEAD exists.
make_repo() {
  local mode="$1"
  local R="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$R/.claude"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  echo base > "$R/README.md"
  jq -nc --arg m "$mode" '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01", guards:{review_gate:$m}}' > "$R/.claude/stack-config.json"
  git -C "$R" add -A; git -C "$R" commit -qm base >/dev/null
  # rr_default_base() resolves to "main" when there's no origin remote; G1's
  # class is computed as rr_default_base()..HEAD, so every subject commit
  # must land on a FEATURE branch, never directly on main, or base==head
  # produces an empty diff -> unconditionally "high" by design (the
  # ref-rewrite/empty-diff rule), which is not what these tests exercise.
  git -C "$R" checkout -q -b feat
  echo "$R"
}

repo_hash_of() {
  local realroot; realroot="$(git -C "$1" rev-parse --show-toplevel)"
  shasum -a 256 <<<"$realroot" | cut -c1-12
}

# write_receipt <repo_hash> <kind> <sha> <seat> <family> [jq-overrides] [subject_path]
write_receipt() {
  local rh="$1" kind="$2" sha="$3" seat="$4" family="$5" overrides="${6:-.}" subject_path="${7:-subject.txt}"
  local dir="$HOME/.claude/state/attest/reviews/${rh}/${kind}/${sha}"
  mkdir -p "$dir"
  jq -nc --arg family "$family" --arg kind "$kind" --arg sha "$sha" --arg as_of "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg spath "$subject_path" '{
    schema:"stack-receipt/v1", kind:"review", writer:"review-receipt-mint.sh@1",
    as_of:$as_of, max_age_s:604800,
    subject:{kind:$kind, path:(if $kind=="artifact" then $spath else null end),
             content_sha:(if $kind=="artifact" then $sha else null end),
             patch_sha:(if $kind=="patch" then $sha else null end),
             base_commit:null, reviewed_head:null, repo_root:"/x", repo_hash:"y", mint_head_commit:"z"},
    verdict:"reviewed", reason:null, needs_human:false,
    evidence:{family:$family, http_status:200, prompt_bytes:1200, output_bytes:600, usage:{output_tokens:150}},
    error:null
  }' | jq -c "$overrides" > "$dir/${seat}.json"
}

# dispatch_payload <cwd> <subagent> <prompt>
dispatch_payload() {
  jq -nc --arg cwd "$1" --arg agent "$2" --arg prompt "$3" \
    '{cwd:$cwd, tool_name:"Agent", tool_input:{subagent_type:$agent, prompt:$prompt}}'
}

# run_gate <payload> -> stdout of the hook. The hook ALWAYS exits 0 (a
# PreToolUse hook communicates deny/allow via the permissionDecision field
# in its JSON stdout, never via process exit code) -- so this helper does
# not track $? at all; only output content distinguishes pass/deny/would-deny.
run_gate() {
  echo "$1" | bash "$HOOK" 2>/dev/null
}

decision_is_deny() { [[ "$1" == *'"permissionDecision":"deny"'* ]]; }

commit_artifact() { # <repo> <path> <content> -> content_sha of the resulting blob
  local R="$1" p="$2" c="$3"
  mkdir -p "$(dirname "$R/$p")"
  printf '%s\n' "$c" > "$R/$p"
  ( cd "$R" && git add -A && git commit -qm "add $p" >/dev/null )
  git -C "$R" hash-object -w --no-filters "$R/$p"
}

# ─── 32: guards.review_gate off -> exit 0 ───────────────────────────────────
R32="$(make_repo off)"
OUT32="$(run_gate "$(dispatch_payload "$R32" implementer "no subject line here")")"
[[ -z "$OUT32" ]] && pass "32: off -> exit 0, no output" || fail "32: out='$OUT32'"

# ─── 33: unreadable/invalid stack-config.json -> mode forces on ───────────
R33="$(make_repo warn)"
echo "not json" > "$R33/.claude/stack-config.json"
OUT33="$(run_gate "$(dispatch_payload "$R33" implementer "no subject")")"
decision_is_deny "$OUT33" && pass "33: invalid config forces mode=on -> real deny" || fail "33: out='$OUT33'"

# ─── 34: jq absent -> static jq-free deny; unparseable stdin -> deny ───────
R34="$(make_repo warn)"
( export PATH="/usr/bin:/bin"
  command -v jq >/dev/null 2>&1 && { echo "SKIP 34a: jq on base-system PATH"; exit 0; }
  OUT="$(dispatch_payload "$R34" implementer "x" | bash "$HOOK" 2>/dev/null)"
  if [[ "$OUT" == *"reason=machinery"* ]]; then echo "34a-pass"; else echo "34a-fail:$OUT"; fi
) | { read -r LINE; case "$LINE" in
  "34a-pass") pass "34a: jq absent -> machinery deny" ;;
  SKIP*) echo "$LINE" ;;
  *) fail "34a: $LINE" ;;
esac; }

OUT34B="$(printf 'not json at all' | bash "$HOOK" 2>/dev/null)"
[[ "$OUT34B" == *"reason=machinery"* ]] && pass "34b: unparseable stdin -> machinery deny" || fail "34b: out='$OUT34B'"

# ─── 35: non-stack-enabled repo -> exit 0 ──────────────────────────────────
R35="$TMP/nostack"; mkdir -p "$R35"; git -C "$R35" init -q -b main
git -C "$R35" config user.email t@t.t; git -C "$R35" config user.name t
echo x > "$R35/f"; git -C "$R35" add -A; git -C "$R35" commit -qm x >/dev/null
OUT35="$(run_gate "$(dispatch_payload "$R35" implementer "x")")"
[[ -z "$OUT35" ]] && pass "35: non-stack-enabled -> exit 0" || fail "35: out='$OUT35'"

# ─── 36: low class -> exit 0, pass row ─────────────────────────────────────
R36="$(make_repo on)"
commit_artifact "$R36" "docs/plan.md" "a design doc" >/dev/null
OUT36="$(run_gate "$(dispatch_payload "$R36" implementer "Review-subject: docs/plan.md")")"
[[ -z "$OUT36" ]] && pass "36: low-class subject -> exit 0" || fail "36: out='$OUT36'"
grep -q '"event":"change_class"' "$HOME/.claude/logs/review-gate.jsonl" 2>/dev/null \
  && pass "36b: change_class telemetry row logged before the low-class exit" || fail "36b: no change_class row"

# ─── 37: med -- one non-Claude receipt passes; Claude receipt -> wrong_family;
#     zero receipts -> deny (proves med is live) ───────────────────────────
R37="$(make_repo on)"
SHA37="$(commit_artifact "$R37" "src/tool.sh" "#!/bin/bash
echo med-class-source-file")"
RH37="$(repo_hash_of "$R37")"
write_receipt "$RH37" artifact "$SHA37" reviewer openai
OUT37A="$(run_gate "$(dispatch_payload "$R37" implementer "Review-subject: src/tool.sh")")"
[[ -z "$OUT37A" ]] && pass "37a: med + one non-Claude receipt -> pass" || fail "37a: out='$OUT37A'"

rm -rf "$HOME/.claude/state/attest/reviews/${RH37}"
write_receipt "$RH37" artifact "$SHA37" reviewer claude
OUT37B="$(run_gate "$(dispatch_payload "$R37" implementer "Review-subject: src/tool.sh")")"
[[ "$OUT37B" == *"reason=wrong_family"* ]] && pass "37b: med + Claude-family receipt -> deny wrong_family" || fail "37b: out='$OUT37B'"

rm -rf "$HOME/.claude/state/attest/reviews/${RH37}"
OUT37C="$(run_gate "$(dispatch_payload "$R37" implementer "Review-subject: src/tool.sh")")"
[[ "$OUT37C" == *"reason=no_receipt"* ]] && pass "37c: med + zero receipts -> deny (med is live)" || fail "37c: out='$OUT37C'"

# ─── 38: high + two receipts, same family -> deny same_family_twice ───────
R38="$(make_repo on)"
SHA38="$(commit_artifact "$R38" "src/auth/login.ts" "high stakes auth code")"
RH38="$(repo_hash_of "$R38")"
write_receipt "$RH38" artifact "$SHA38" architecture-critic gemini
write_receipt "$RH38" artifact "$SHA38" red-team gemini
OUT38="$(run_gate "$(dispatch_payload "$R38" implementer "Review-subject: src/auth/login.ts")")"
[[ "$OUT38" == *"reason=same_family_twice"* ]] && pass "38: high + same family twice -> deny same_family_twice" || fail "38: out='$OUT38'"

# ─── 39: high + Gemini + OpenAI, both fresh, both matching -> pass ─────────
R39="$(make_repo on)"
SHA39="$(commit_artifact "$R39" "src/auth/token.ts" "high stakes auth code 2")"
RH39="$(repo_hash_of "$R39")"
write_receipt "$RH39" artifact "$SHA39" architecture-critic gemini
write_receipt "$RH39" artifact "$SHA39" reviewer openai
OUT39="$(run_gate "$(dispatch_payload "$R39" implementer "Review-subject: src/auth/token.ts")")"
[[ -z "$OUT39" ]] && pass "39: high + gemini + openai -> pass" || fail "39: out='$OUT39'"

# ─── 40: artifact edited substantially -> deny subject_moved ──────────────
# NOTE: with D12's ancestor-plus-low-delta hatch also live in this same gate
# function, a TRIVIAL edit (a byte, a typo) now legitimately PASSES here --
# that is exactly D12's case 55, tested in test-review-gate-iteration.sh. To
# stay a genuine "no hatch available" case, this edit must exceed D12's
# low-delta threshold (adds real new lines -- the D12 case-56 shape, "adds a
# function"), not merely change one existing line.
R40="$(make_repo on)"
SHA40_OLD="$(commit_artifact "$R40" "src/util.sh" "#!/bin/bash
echo v1")"
RH40="$(repo_hash_of "$R40")"
write_receipt "$RH40" artifact "$SHA40_OLD" reviewer openai . "src/util.sh"
cat > "$R40/src/util.sh" <<'EOF'
#!/bin/bash
echo v1
new_function() {
  echo "line one"
  echo "line two"
  echo "line three"
}
new_function
EOF
( cd "$R40" && git add -A && git commit -qm "edit util.sh" >/dev/null )
OUT40="$(run_gate "$(dispatch_payload "$R40" implementer "Review-subject: src/util.sh")")"
[[ "$OUT40" == *"reason=subject_moved"* ]] && pass "40: substantially edited artifact (beyond D12's low-delta threshold) -> deny subject_moved" || fail "40: out='$OUT40'"

# ─── 41: receipt past max_age_s -> deny stale, not no_receipt ─────────────
R41="$(make_repo on)"
SHA41="$(commit_artifact "$R41" "src/thing.sh" "#!/bin/bash
echo stale-test")"
RH41="$(repo_hash_of "$R41")"
OLD_TS="$(date -u -v-8d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)"
write_receipt "$RH41" artifact "$SHA41" reviewer openai ".as_of=\"$OLD_TS\""
OUT41="$(run_gate "$(dispatch_payload "$R41" implementer "Review-subject: src/thing.sh")")"
[[ "$OUT41" == *"reason=stale"* ]] && pass "41: stale receipt -> deny stale, not no_receipt" || fail "41: out='$OUT41'"

# ─── 42: http_status:500 or truncated evidence -> deny invalid_receipt ────
R42="$(make_repo on)"
SHA42="$(commit_artifact "$R42" "src/other.sh" "#!/bin/bash
echo invalid-receipt-test")"
RH42="$(repo_hash_of "$R42")"
write_receipt "$RH42" artifact "$SHA42" reviewer openai '.evidence.http_status=500'
OUT42="$(run_gate "$(dispatch_payload "$R42" implementer "Review-subject: src/other.sh")")"
[[ "$OUT42" == *"reason=invalid_receipt"* ]] && pass "42: http_status:500 -> deny invalid_receipt" || fail "42: out='$OUT42'"

# ─── 43: hand-forged receipt claiming a different content hash -> deny ────
R43="$(make_repo on)"
SHA43="$(commit_artifact "$R43" "src/forge.sh" "#!/bin/bash
echo forge-test")"
RH43="$(repo_hash_of "$R43")"
write_receipt "$RH43" artifact "$SHA43" reviewer openai '.subject.content_sha="0000000000000000000000000000000000dead"'
OUT43="$(run_gate "$(dispatch_payload "$R43" implementer "Review-subject: src/forge.sh")")"
decision_is_deny "$OUT43" && pass "43: forged internal hash claim -> deny" || fail "43: out='$OUT43'"

# ─── 44: no Review-subject: -> deny no_subject_declared; dispatch to tester -> exit 0
R44="$(make_repo on)"
OUT44A="$(run_gate "$(dispatch_payload "$R44" implementer "no subject line at all")")"
[[ "$OUT44A" == *"reason=no_subject_declared"* ]] && pass "44a: no Review-subject line -> deny no_subject_declared" || fail "44a: out='$OUT44A'"
OUT44B="$(run_gate "$(dispatch_payload "$R44" tester "no subject either")")"
[[ -z "$OUT44B" ]] && pass "44b: dispatch to tester (not implementer) -> exit 0" || fail "44b: out='$OUT44B'"

# ─── 45 (G1 half): G1 presented only with a patch receipt -> deny ─────────
R45="$(make_repo on)"
SHA45="$(commit_artifact "$R45" "src/g1only.sh" "#!/bin/bash
echo g1-only-patch-receipt-test")"
RH45="$(repo_hash_of "$R45")"
write_receipt "$RH45" patch "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" reviewer openai
OUT45="$(run_gate "$(dispatch_payload "$R45" implementer "Review-subject: src/g1only.sh")")"
decision_is_deny "$OUT45" && pass "45: G1 with only a patch receipt on file -> deny (kind mismatch, invisible to artifact scan)" || fail "45: out='$OUT45'"

# ─── 51: warn mode reproduces every deny as would-deny, exit 0, no permissionDecision
R51="$(make_repo warn)"
OUT51="$(run_gate "$(dispatch_payload "$R51" implementer "no subject")")"
[[ -z "$OUT51" ]] && pass "51a: warn mode -> exit 0, no permissionDecision" || fail "51a: out='$OUT51'"
grep -q '"decision":"would-deny"' "$HOME/.claude/logs/review-gate.jsonl" 2>/dev/null \
  && pass "51b: would-deny row logged in warn mode" || fail "51b: no would-deny row"

# ─── 52: deny messages never contain the sensitive strings ────────────────
FORBIDDEN=("review-gate.disabled" "repo-once" "state/attest/override" "guards.review_gate")
ALL_DENIES="$OUT33
$OUT34B
$OUT37B
$OUT37C
$OUT38
$OUT40
$OUT41
$OUT42
$OUT43
$OUT44A"
LEAK=0
for s in "${FORBIDDEN[@]}"; do
  [[ "$ALL_DENIES" == *"$s"* ]] && LEAK=1
done
[[ "$LEAK" -eq 0 ]] && pass "52: no deny text contains the forbidden strings" || fail "52: a forbidden string leaked"

# ─── 53: empty-disable case emits the generic deny, byte-identical to jq-missing
DISABLE_DIR="$HOME/.claude/state/attest/override"
mkdir -p "$DISABLE_DIR"
: > "$DISABLE_DIR/review-gate.disabled"
R53="$(make_repo on)"
OUT53="$(run_gate "$(dispatch_payload "$R53" implementer "x")")"
rm -f "$DISABLE_DIR/review-gate.disabled"
if [[ "$OUT53" == "$OUT34B" ]]; then
  pass "53: empty-disable deny byte-identical to jq-missing/unparseable-stdin deny"
else
  fail "53: mismatch: '$OUT53' vs '$OUT34B'"
fi

# ─── 54: machinery vs evidence-missing distinguishable in jsonl, not in deny text
grep -q '"reason":"machinery"' "$HOME/.claude/logs/review-gate.jsonl" 2>/dev/null
HAS_MACHINERY_ROW=$?
# (machinery paths return before any log_row call in this implementation --
# they short-circuit before jq/mode are known -- so the distinguishing signal
# for machinery is its OWN unconditional-deny code path, never a jsonl row
# shared with evidence-missing rows. Assert the two decision TEXTS share the
# same generic shape while their triggering CONDITIONS are code-distinct.)
[[ "$OUT53" == *"reason=machinery"* && "$OUT44A" == *"reason=no_subject_declared"* ]] \
  && pass "54: machinery and evidence-missing use different reason codes, same generic deny shape" \
  || fail "54: reason codes not distinguishable"

# ════════════════════════════════════════════════════════════════════════════
# G2 mount (Bash, `gh pr create`) — cases 45 (patch half), 46-50.
# ════════════════════════════════════════════════════════════════════════════

bash_payload() { # <cwd> <command>
  jq -nc --arg cwd "$1" --arg cmd "$2" '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}}'
}

# make_repo_with_remote <mode> -> echoes repo path. Same shape as make_repo,
# but ALSO fakes an origin/main remote-tracking ref (no real remote needed --
# refs/remotes/origin/main just needs to exist locally for merge-base to work).
make_repo_with_remote() {
  local mode="$1"
  local R="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$R/.claude"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  echo base > "$R/README.md"
  jq -nc --arg m "$mode" '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01", guards:{review_gate:$m}}' > "$R/.claude/stack-config.json"
  git -C "$R" add -A; git -C "$R" commit -qm base >/dev/null
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  git -C "$R" checkout -q -b feat
  echo "$R"
}

commit_on() { # <repo> <path> <content>
  local R="$1" p="$2" c="$3"
  mkdir -p "$(dirname "$R/$p")"
  printf '%s\n' "$c" > "$R/$p"
  ( cd "$R" && git add -A && git commit -qm "add $p" >/dev/null )
}

# ─── 45 (G2 half): G2 presented only with an artifact receipt -> deny ──────
R45B="$(make_repo_with_remote on)"
commit_on "$R45B" "src/g2only.sh" "#!/bin/bash
echo g2-only-artifact-receipt-test"
RH45B="$(repo_hash_of "$R45B")"
write_receipt "$RH45B" artifact "0000000000000000000000000000000000dead" reviewer openai
OUT45B="$(run_gate "$(bash_payload "$R45B" "gh pr create --title x --body y")")"
decision_is_deny "$OUT45B" && pass "45b: G2 with only an artifact receipt on file -> deny (kind mismatch)" || fail "45b: out='$OUT45B'"

# ─── 46: G2 happy path end-to-end -- panel-review.sh --diff mints a genuine
#     patch receipt (stubbed vendor), gh pr create on that exact branch passes
R46="$(make_repo_with_remote on)"
commit_on "$R46" "src/feature.sh" "#!/bin/bash
echo happy-path-source-change"
BASE_46="$(cd "$R46" && bash -c "source '$REPO_ROOT/scripts/lib/review-router.sh'; rr_default_base")"
STUB="$REPO_ROOT/tests/fixtures/panel-review-stub-vendor.sh"
BIGCTX="$(printf '%*s' 1200 '' | tr ' ' 'a')"
# Real panel-review.sh run (stubbed vendor) mints its evidence marker line on
# stdout; this test then feeds that exact output through review-receipt-
# mint.sh -- the PostToolUse[Bash] hook that a real Bash-tool call would
# trigger automatically -- so the receipt on disk is genuinely produced by
# the two-hook pipeline, not hand-written.
PR46_OUT="$(cd "$R46" && echo "$BIGCTX" | PR_GEMINI_LIB="$STUB" PR_OPENAI_LIB="$STUB" STUB_RC=0 \
    bash "$REPO_ROOT/scripts/panel-review.sh" reviewer --diff "${BASE_46}..HEAD")"
MINT_PAYLOAD="$(jq -nc --arg cwd "$R46" --arg cmd "bash scripts/panel-review.sh reviewer --diff ${BASE_46}..HEAD" --arg out "$PR46_OUT" \
  '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:$out}')"
echo "$MINT_PAYLOAD" | bash "$REPO_ROOT/hooks/review-receipt-mint.sh" >/dev/null 2>&1
OUT46="$(run_gate "$(bash_payload "$R46" "gh pr create --title x --body y")")"
[[ -z "$OUT46" ]] && pass "46: G2 end-to-end -- genuine panel-review.sh receipt satisfies a med-class PR" || fail "46: out='$OUT46'"

# ─── 47: gh pr list -> exit 0. gh   pr  create (extra whitespace) -> deny ──
R47="$(make_repo_with_remote on)"
commit_on "$R47" "src/whatever.sh" "#!/bin/bash
echo whitespace-matcher-test"
OUT47A="$(run_gate "$(bash_payload "$R47" "gh pr list")")"
[[ -z "$OUT47A" ]] && pass "47a: gh pr list -> exit 0 (not the intercepted command)" || fail "47a: out='$OUT47A'"
OUT47B="$(run_gate "$(bash_payload "$R47" "gh   pr  create --title x")")"
decision_is_deny "$OUT47B" && pass "47b: gh   pr  create (extra whitespace) -> still caught, denies" || fail "47b: out='$OUT47B'"

# ─── 48: unresolvable origin/main at G2 -> high -> deny ────────────────────
R48="$TMP/repo-nobase-$RANDOM"
mkdir -p "$R48/.claude"
git -C "$R48" init -q -b feat
git -C "$R48" config user.email t@t.t; git -C "$R48" config user.name t
jq -nc '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01", guards:{review_gate:"on"}}' > "$R48/.claude/stack-config.json"
echo base > "$R48/README.md"
git -C "$R48" add -A; git -C "$R48" commit -qm base >/dev/null
# No origin/main, no origin/HEAD, no upstream, no local "main" branch at all --
# every D4 candidate fails to resolve.
OUT48="$(run_gate "$(bash_payload "$R48" "gh pr create --title x --body y")")"
[[ "$OUT48" == *"classifies as high"* ]] && decision_is_deny "$OUT48" \
  && pass "48: unresolvable bases at G2 -> high (fail-safe), deny" || fail "48: out='$OUT48'"

# ─── 49: ref-rewrite attack -- still high after rewriting one ref, still
#     high after rewriting ALL FOUR (empty-diff rule) ──────────────────────
R49="$(make_repo_with_remote on)"
commit_on "$R49" "src/attack.sh" "#!/bin/bash
echo ref-rewrite-attack-test"
git -C "$R49" update-ref refs/remotes/origin/main HEAD
OUT49A="$(run_gate "$(bash_payload "$R49" "gh pr create --title x --body y")")"
[[ "$OUT49A" == *"classifies as high"* ]] && pass "49a: origin/main rewritten to HEAD -> still high (empty-diff rule)" || fail "49a: out='$OUT49A'"
git -C "$R49" branch -f main HEAD >/dev/null 2>&1 || true
OUT49B="$(run_gate "$(bash_payload "$R49" "gh pr create --title x --body y")")"
[[ "$OUT49B" == *"classifies as high"* ]] && pass "49b: every candidate rewritten to HEAD -> still high" || fail "49b: out='$OUT49B'"

# ─── 50: telemetry row records the chosen base and every candidate ────────
grep '"event":"change_class"' "$HOME/.claude/logs/review-gate.jsonl" 2>/dev/null | grep -q '"mount":"G2"' \
  && pass "50a: G2 change_class rows logged" || fail "50a: no G2 change_class row"
LAST_G2_ROW="$(grep '"event":"change_class"' "$HOME/.claude/logs/review-gate.jsonl" 2>/dev/null | grep '"mount":"G2"' | tail -1)"
echo "$LAST_G2_ROW" | jq -e 'has("base") and has("candidates")' >/dev/null 2>&1 \
  && pass "50b: row carries both the chosen base and the candidate list" || fail "50b: row='$LAST_G2_ROW'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
