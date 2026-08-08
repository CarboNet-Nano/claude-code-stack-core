#!/usr/bin/env bash
# Tests for ADR-050 (docs-agent pipeline Phase 5b — logic extraction
# generalizes as a skill, not a roster seat): scripts/logic-receipt.sh
# (Contract A), scripts/logic-stale-check.sh (Contract B),
# scripts/logic-exec-recheck.sh (Contract C), the DEFERRED state machine
# (Contract D, headless auto-run branch explicitly NOT built), foreman
# routing (Contract E), tier-3 installability (Contract F), and the
# permissions-baseline self-protection rule (Contract G).
#
# Case ids map to the session handoff's test plan, in document order. Cases
# that genuinely require a live Gemini call (Phase 5a's own exit suite) run
# only when a key is reachable; otherwise they report NOT-EXECUTED with the
# missing precondition — never silently skipped, never counted as a pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECEIPT="$REPO_ROOT/scripts/logic-receipt.sh"
STALE_CHECK="$REPO_ROOT/scripts/logic-stale-check.sh"
EXEC_RECHECK="$REPO_ROOT/scripts/logic-exec-recheck.sh"
LOGIC_SKILL="$REPO_ROOT/skills/user-docs-logic/SKILL.md"
REFRESH_SKILL="$REPO_ROOT/skills/user-docs-refresh/SKILL.md"
FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
GOODMORNING="$REPO_ROOT/skills/goodmorning/SKILL.md"
TIER3="$REPO_ROOT/config/tier-manifests/tier-3.json"
BASELINE="$REPO_ROOT/config/permissions-baseline.json"
COMPILE="$REPO_ROOT/scripts/permissions-compile.sh"
ADR003="$REPO_ROOT/docs/ADRs/003-21-subagents.md"
PHASE5A="$REPO_ROOT/scripts/check-docs-pipeline-phase5a.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
for f in "$RECEIPT" "$STALE_CHECK" "$EXEC_RECHECK"; do
  [[ -x "$f" ]] || { echo "FAIL: prerequisite missing/not executable: $f"; exit 1; }
done

PASS=0
FAIL=0
NOTRUN=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
notrun() { echo "NOT-EXECUTED: $1 — requires $2"; NOTRUN=$((NOTRUN+1)); }
assert_eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: '$2' | actual: '$3')"; fi; }
assert_grep() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (not found in $2: '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in: $2)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Fixture repo: a small git repo with a 20-line source file, used by every
# Contract B (stale-check) case below.
# ═══════════════════════════════════════════════════════════════════════════
STALE_REPO="$TMP/stale-repo"
mkdir -p "$STALE_REPO/apps"
git -C "$STALE_REPO" init -q
git -C "$STALE_REPO" config user.email "test@example.com"
git -C "$STALE_REPO" config user.name "test"
python3 -c "
lines = [f'line{i}' for i in range(1, 21)]
open('$STALE_REPO/apps/route.ts', 'w').write('\n'.join(lines) + '\n')
"
git -C "$STALE_REPO" add -A
git -C "$STALE_REPO" commit -qm "base"
BASE_COMMIT="$(git -C "$STALE_REPO" rev-parse HEAD)"

make_stale_receipts() {
  # make_stale_receipts <file> <commit>
  cat > "$1" <<JSON
{
  "schemaVersion": 1,
  "unit": "test-unit",
  "extraction": {
    "commit": "$2",
    "spans": [
      { "file": "apps/route.ts", "start": 5, "end": 7, "rule": 1 },
      { "file": "apps/route.ts", "start": 15, "end": 16, "rule": 2 }
    ]
  }
}
JSON
}

echo "--- Contract B: logic-stale-check.sh ---"

# Case: FRESH — no changes since extraction.
R1="$TMP/r1.json"; make_stale_receipts "$R1" "$BASE_COMMIT"
OUT="$(bash "$STALE_CHECK" "$R1" "$STALE_REPO")"; RC=$?
assert_eq "B1: no changes since extraction -> FRESH" "FRESH" "$OUT"
assert_eq "B1: exit 0" "0" "$RC"

# Case: change OUTSIDE every cited span -> note only, still FRESH/exit 0.
python3 -c "
p = '$STALE_REPO/apps/route.ts'
lines = open(p).read().splitlines()
lines[0] = 'line1-CHANGED'
open(p, 'w').write('\n'.join(lines) + '\n')
"
git -C "$STALE_REPO" add -A
git -C "$STALE_REPO" commit -qm "change line1 (outside every span)"
OUT="$(bash "$STALE_CHECK" "$R1" "$STALE_REPO")"; RC=$?
assert_contains "B2: change outside every span -> note: line printed" "$OUT" "note:"
assert_contains "B2: change outside every span -> FRESH still reported" "$OUT" "FRESH"
assert_eq "B2: exit 0 (no LOGIC-STALE from an out-of-span change)" "0" "$RC"

# Case: single-line change INSIDE a span, via the comma-omitted hunk header
# git emits for a 1-line change (`@@ -6 +6 @@`, not `@@ -6,1 +6,1 @@`) — the
# exact shape a naive "always expect a comma" regex would silently drop.
python3 -c "
p = '$STALE_REPO/apps/route.ts'
lines = open(p).read().splitlines()
lines[5] = 'line6-CHANGED'  # line 6, inside span 5-7
open(p, 'w').write('\n'.join(lines) + '\n')
"
git -C "$STALE_REPO" add -A
git -C "$STALE_REPO" commit -qm "change line6 (inside span 5-7, comma-omitted hunk)"
HUNK="$(git -C "$STALE_REPO" diff --unified=0 HEAD~1..HEAD -- apps/route.ts | grep '^@@')"
assert_eq "B3 precondition: git really did emit a comma-omitted single-line hunk" "@@ -6 +6 @@ line5" "$HUNK"
OUT="$(bash "$STALE_CHECK" "$R1" "$STALE_REPO")"; RC=$?
assert_contains "B3: comma-omitted single-line hunk inside a span -> LOGIC-STALE" "$OUT" "LOGIC-STALE: apps/route.ts:5-7 (rule 1)"
assert_eq "B3: exit 1" "1" "$RC"

# Case: pure-insertion hunk (`@@ -a,0 +c,d @@`) touching the boundary of a
# span — must overlap span2 (15-16), not be silently ignored.
python3 -c "
p = '$STALE_REPO/apps/route.ts'
lines = open(p).read().splitlines()
lines.insert(15, 'INSERTED-A')
lines.insert(16, 'INSERTED-B')
open(p, 'w').write('\n'.join(lines) + '\n')
"
git -C "$STALE_REPO" add -A
git -C "$STALE_REPO" commit -qm "pure insertion after line 15 (span2 boundary)"
HUNK="$(git -C "$STALE_REPO" diff --unified=0 HEAD~1..HEAD -- apps/route.ts | grep '^@@')"
assert_eq "B4 precondition: git really did emit a b=0 pure-insertion hunk" "@@ -15,0 +16,2 @@ line15" "$HUNK"
OUT="$(bash "$STALE_CHECK" "$R1" "$STALE_REPO")"; RC=$?
assert_contains "B4: pure-insertion hunk at span2's boundary -> LOGIC-STALE for rule 2" "$OUT" "LOGIC-STALE: apps/route.ts:15-16 (rule 2)"
assert_eq "B4: exit 1" "1" "$RC"

# Case: span file deleted -> LOGIC-STALE (fail-safe), for every span in it.
git -C "$STALE_REPO" rm -q apps/route.ts
git -C "$STALE_REPO" commit -qm "delete route.ts"
OUT="$(bash "$STALE_CHECK" "$R1" "$STALE_REPO")"; RC=$?
assert_contains "B5: span file deleted -> LOGIC-STALE, fail-safe" "$OUT" "span file deleted or renamed"
assert_eq "B5: exit 1" "1" "$RC"

# Case: unreachable extraction.commit -> STALE-CHECK-UNAVAILABLE, exit 2,
# NEVER "FRESH" (ADR-025 — an unavailable check must never look fresh).
R2="$TMP/r2.json"; make_stale_receipts "$R2" "0000000000000000000000000000000000000000"
OUT="$(bash "$STALE_CHECK" "$R2" "$STALE_REPO" 2>&1)"; RC=$?
assert_contains "B6: unreachable extraction.commit -> STALE-CHECK-UNAVAILABLE" "$OUT" "STALE-CHECK-UNAVAILABLE"
assert_eq "B6: exit 2" "2" "$RC"
case "$OUT" in *FRESH*) fail "B6: must never report FRESH when the commit is unreachable" ;;
               *) pass "B6: never reports FRESH when the commit is unreachable" ;; esac

# Case: absent/schema-invalid receipts -> never "fresh".
OUT="$(bash "$STALE_CHECK" "$TMP/does-not-exist.json" "$STALE_REPO" 2>&1)"; RC=$?
assert_eq "B7: absent receipts file -> exit 2 (STALE-CHECK-UNAVAILABLE class, never fresh)" "2" "$RC"
echo '{"not":"a receipts file"}' > "$TMP/bad-receipts.json"
OUT="$(bash "$STALE_CHECK" "$TMP/bad-receipts.json" "$STALE_REPO" 2>&1)"; RC=$?
assert_eq "B7b: schema-invalid receipts (no extraction.commit) -> exit 2" "2" "$RC"
assert_contains "B7b: reason names the missing extraction section" "$OUT" "STALE-CHECK-UNAVAILABLE"

# Zero-token constraint, machine-checked (not just documented).
if grep -qiE 'gemini|gmn_call|curl' "$STALE_CHECK"; then
  fail "B8: logic-stale-check.sh must be zero LLM tokens (no gemini/gmn_call/curl)"
else
  pass "B8: logic-stale-check.sh contains no gemini/gmn_call/curl reference"
fi

echo "--- Contract C: logic-exec-recheck.sh ---"

EXEC_REPO="$TMP/exec-repo"
mkdir -p "$EXEC_REPO"
git -C "$EXEC_REPO" init -q
git -C "$EXEC_REPO" config user.email "test@example.com"
git -C "$EXEC_REPO" config user.name "test"
cat > "$EXEC_REPO/harness.sh" <<'EOF'
#!/usr/bin/env bash
echo 'LOGIC-EXAMPLE {"id":"ex1","input":{"subtotal":100},"output":{"total":90,"rate":33.33}}'
echo 'LOGIC-EXAMPLE {"id":"ex2","input":{"subtotal":50},"output":{"total":45}}'
EOF
chmod +x "$EXEC_REPO/harness.sh"
git -C "$EXEC_REPO" add -A
git -C "$EXEC_REPO" commit -qm "init"
HARNESS_HASH="$(git -C "$EXEC_REPO" hash-object harness.sh)"

make_exec_receipts() {
  # make_exec_receipts <file> <hash> <command> <ex1-total> <ex1-rate>
  cat > "$1" <<JSON
{
  "schemaVersion": 1,
  "unit": "test-unit",
  "harness": { "path": "harness.sh", "hash": "$2", "command": "$3", "targetCheck": "PASS" },
  "execution": {
    "status": "executed",
    "lastRunAt": "2026-01-01T00:00:00Z",
    "lastRunCommit": "0000000000000000000000000000000000000000",
    "examples": [
      { "id": "ex1", "input": { "subtotal": 100 }, "output": { "total": $4, "rate": $5 } },
      { "id": "ex2", "input": { "subtotal": 50 }, "output": { "total": 45 } }
    ]
  }
}
JSON
}

# Case: identical re-run -> EXEC-FRESH, exit 0, lastRunAt/lastRunCommit updated.
R3="$TMP/r3.json"; make_exec_receipts "$R3" "$HARNESS_HASH" "bash harness.sh" "90" "33.33"
LAST_RUN_BEFORE="$(jq -r '.execution.lastRunAt' "$R3")"
OUT="$(bash "$EXEC_RECHECK" "$R3" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C1: identical re-run -> EXEC-FRESH" "$OUT" "EXEC-FRESH"
assert_eq "C1: exit 0" "0" "$RC"
LAST_RUN_AFTER="$(jq -r '.execution.lastRunAt' "$R3")"
if [[ "$LAST_RUN_AFTER" != "$LAST_RUN_BEFORE" ]]; then
  pass "C1b: execution.lastRunAt was updated by the recheck"
else
  fail "C1b: execution.lastRunAt was NOT updated (expected a fresh timestamp)"
fi
LAST_RUN_COMMIT_AFTER="$(jq -r '.execution.lastRunCommit' "$R3")"
EXEC_HEAD="$(cd "$EXEC_REPO" && git rev-parse HEAD)"
assert_eq "C1c: execution.lastRunCommit updated to the repo's real HEAD" "$EXEC_HEAD" "$LAST_RUN_COMMIT_AFTER"

# Case: float example compared at published precision, exact deep-equality
# (D6 — no epsilon tolerance). 33.33 == 33.33 passes (already shown by C1);
# 33.34 != 33.33 must drift, proving there is no silent float slop.
R3B="$TMP/r3b.json"; make_exec_receipts "$R3B" "$HARNESS_HASH" "bash harness.sh" "90" "33.34"
OUT="$(bash "$EXEC_RECHECK" "$R3B" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C2: a 0.01 float difference at published precision -> EXEC-DRIFT (no epsilon)" "$OUT" "EXEC-DRIFT: ex1"
assert_eq "C2: exit 1" "1" "$RC"

# Case: EXEC-DRIFT on an integer field.
R4="$TMP/r4.json"; make_exec_receipts "$R4" "$HARNESS_HASH" "bash harness.sh" "999" "33.33"
OUT="$(bash "$EXEC_RECHECK" "$R4" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C3: mismatched example -> EXEC-DRIFT names the id" "$OUT" "EXEC-DRIFT: ex1"
assert_eq "C3: exit 1" "1" "$RC"

# Case: harness edited (hash mismatch) -> HARNESS-CHANGED, NOT EXEC-DRIFT.
R5="$TMP/r5.json"; make_exec_receipts "$R5" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "bash harness.sh" "90" "33.33"
OUT="$(bash "$EXEC_RECHECK" "$R5" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C4: harness hash mismatch -> HARNESS-CHANGED" "$OUT" "HARNESS-CHANGED"
case "$OUT" in *EXEC-DRIFT*) fail "C4: must not be reported as EXEC-DRIFT" ;;
               *) pass "C4: not conflated with EXEC-DRIFT" ;; esac
assert_eq "C4: exit 1" "1" "$RC"

# Case: harness command fails outright -> HARNESS-UNRUNNABLE, exit 2, not EXEC-DRIFT.
R6="$TMP/r6.json"; make_exec_receipts "$R6" "$HARNESS_HASH" "bash does-not-exist.sh" "90" "33.33"
OUT="$(bash "$EXEC_RECHECK" "$R6" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C5: harness command fails -> HARNESS-UNRUNNABLE" "$OUT" "HARNESS-UNRUNNABLE"
case "$OUT" in *EXEC-DRIFT*) fail "C5: must not be reported as EXEC-DRIFT" ;;
               *) pass "C5: not conflated with EXEC-DRIFT" ;; esac
assert_eq "C5: exit 2" "2" "$RC"

# Case: harness runs clean but emits zero LOGIC-EXAMPLE lines -> HARNESS-UNRUNNABLE,
# never a silent pass.
R7="$TMP/r7.json"; make_exec_receipts "$R7" "$HARNESS_HASH" "echo no-examples-here" "90" "33.33"
OUT="$(bash "$EXEC_RECHECK" "$R7" "$EXEC_REPO" 2>&1)"; RC=$?
assert_contains "C6: zero LOGIC-EXAMPLE lines -> HARNESS-UNRUNNABLE" "$OUT" "HARNESS-UNRUNNABLE"
case "$OUT" in *EXEC-FRESH*) fail "C6: must never be silently reported fresh" ;;
               *) pass "C6: never silently reported fresh" ;; esac
assert_eq "C6: exit 2" "2" "$RC"

# Zero-token constraint, machine-checked.
if grep -qiE 'gemini|gmn_call|curl' "$EXEC_RECHECK"; then
  fail "C7: logic-exec-recheck.sh must be zero LLM tokens (no gemini/gmn_call/curl)"
else
  pass "C7: logic-exec-recheck.sh contains no gemini/gmn_call/curl reference"
fi

echo "--- Contract A: receipts ownership ---"

# The recheck scripts call logic-receipt.sh rather than writing JSON
# themselves. logic-stale-check.sh never writes the receipts file at all.
if grep -q 'json\.dump\|> *"\$RECEIPTS_FILE"' "$STALE_CHECK"; then
  fail "A1: logic-stale-check.sh must never write the receipts file"
else
  pass "A1: logic-stale-check.sh never writes the receipts file"
fi
assert_grep "A2: logic-exec-recheck.sh updates execution via logic-receipt.sh, not directly" "$EXEC_RECHECK" "logic-receipt.sh"
# os.replace(...) is logic-receipt.sh's atomic-write marker (its only writer,
# per Contract A). Its presence in the recheck script would mean it writes
# the receipts file directly instead of delegating.
if grep -q 'os\.replace' "$EXEC_RECHECK"; then
  fail "A2b: logic-exec-recheck.sh must not write the receipts file itself (found an os.replace atomic-write)"
else
  pass "A2b: logic-exec-recheck.sh does not write the receipts file itself"
fi

# DEFERRED forces checker: null regardless of a caller-supplied --checker.
R8="$TMP/r8.json"
bash "$RECEIPT" set-parity "$R8" --verdict DEFERRED --checker "should-be-nulled" >/dev/null 2>&1
CHECKER="$(jq -r '.parity.checker' "$R8")"
VERDICT="$(jq -r '.parity.verdict' "$R8")"
assert_eq "A3: DEFERRED verdict is recorded" "DEFERRED" "$VERDICT"
assert_eq "A3b: DEFERRED forces checker to null, ignoring any --checker argument" "null" "$CHECKER"

# Schema validity check: a well-formed receipts write round-trips every
# Contract-A top-level key.
R9="$TMP/r9.json"
bash "$RECEIPT" init "$R9" --unit u --entry-point "GET /x" --entry-file apps/route.ts --dispatched-by human --repo-root "$STALE_REPO" >/dev/null 2>&1
KEYS="$(jq -r 'keys | sort | join(",")' "$R9")"
assert_eq "A4: init writes exactly the Contract-A top-level shape" "closure,dispatch,execution,extraction,harness,parity,schemaVersion,signals,unit" "$KEYS"

echo "--- Contract D: DEFERRED state machine (auto-run branch NOT built) ---"

assert_grep "D1: skill states DEFERRED is a non-passing verdict everywhere" "$LOGIC_SKILL" "non-passing verdict everywhere"
assert_grep "D2: skill states this procedure does not run unattended" "$LOGIC_SKILL" "does not run unattended"
assert_grep "D3: foreman's headless branch is the literal pending-MCQ marker, not an implementation" "$FOREMAN" "<!-- ADR-050 Contract D: headless policy pending maintainer MCQ -->"
assert_grep "D4: /goodmorning surfaces a DEFERRED unit with the exact phrasing" "$GOODMORNING" "logic drafted, parity gate deferred"
assert_grep "D4b: /goodmorning reads docs/user/.meta/*.receipts.json" "$GOODMORNING" "docs/user/.meta/*.receipts.json"

echo "--- Contract E: foreman routing (additive only) ---"

assert_grep "E1: foreman task-type list includes logic-docs" "$FOREMAN" "\`logic-docs\` — explain how a user-visible computed value is derived (ADR-050)"
assert_grep "E2: foreman team table has a logic-docs row routing to /user-docs-logic" "$FOREMAN" "| logic-docs (ADR-050) | /user-docs-logic"
assert_grep "E3: LOGIC-STALE/EXEC-DRIFT routes to /user-docs-logic, never user-docs-writer" "$FOREMAN" "Route to \`/user-docs-logic\`, **never** to"
assert_grep "E4: STALE-CHECK-UNAVAILABLE is surfaced, never treated as fresh" "$FOREMAN" "never silently treated as fresh (ADR-025)"
assert_grep "E5: composition template has a Logic-doc status section" "$FOREMAN" "## Logic-doc status (ADR-050)"

# Step 4b (Role 1's headless auto-decline) must be byte-identical to before
# this ADR's edits. Two checks: (a) no diff hunk REMOVES any line anywhere in
# the file since the pre-ADR-050 base commit (a pure-addition diff never
# does this); (b) the block's own known literal text — the same strings
# tests/test-user-docs.sh's T26a-d already pin — is intact and precedes the
# new 4c heading, proving the insertion landed after step 4b, not inside it.
#
# E6a is anchored to a fixed base commit (cfc606e — the tip this
# implementation branched from, before any ADR-050 edits) rather than a bare
# `git diff`, which would go vacuous (always empty) the moment this work is
# committed. If that commit is ever unreachable (shallow clone, rebase),
# this degrades to NOT-EXECUTED rather than a false pass — E6b/E6c/E6d below
# are the durable checks either way, since they pin literal text regardless
# of commit history.
#
# Scoped to the step 4b/4c block only (ADR-053, round 2 of this file's own
# history): the check's real invariant, per the comment above, was always
# "step 4b is byte-identical," never "nothing in this file ever changes."
# ADR-053 legitimately rewrites step 6 (a routing-plane restructure, not a
# doc-freshness regression) elsewhere in the same file; comparing the WHOLE
# file against a base commit that predates that rewrite would flag every
# future legitimate edit to any other step as a false "additive-only"
# violation. Diffing only the named block keeps the check meaningful.
FOREMAN_BASE_COMMIT="cfc606e"
B4_BLOCK="$(awk '/^4b\. \*\*User-docs tail step/,/^5\. \*\*Apply project overrides/' "$FOREMAN")"
if git -C "$REPO_ROOT" cat-file -e "${FOREMAN_BASE_COMMIT}^{commit}" 2>/dev/null; then
  FOREMAN_BLOCK_BASE="$(git -C "$REPO_ROOT" show "$FOREMAN_BASE_COMMIT:skills/foreman/SKILL.md" 2>/dev/null \
    | awk '/^4b\. \*\*User-docs tail step/,/^5\. \*\*Apply project overrides/' || true)"
  FOREMAN_DIFF="$(diff <(printf '%s\n' "$FOREMAN_BLOCK_BASE") <(printf '%s\n' "$B4_BLOCK") 2>/dev/null || true)"
  REMOVED_LINES="$(printf '%s\n' "$FOREMAN_DIFF" | grep -E '^<' || true)"
  if [[ -z "$REMOVED_LINES" ]]; then
    pass "E6a: no line removed from step 4b/4c of skills/foreman/SKILL.md since $FOREMAN_BASE_COMMIT (pure-addition edit)"
  else
    fail "E6a: a line was removed from step 4b/4c since $FOREMAN_BASE_COMMIT — the handoff requires additive-only edits: $REMOVED_LINES"
  fi
else
  notrun "E6a: diff-since-base removed-line check" "base commit $FOREMAN_BASE_COMMIT reachable in this checkout (shallow clone or history rewrite) — E6b/E6c/E6d below still run"
fi
assert_contains "E6b: step 4b's headless-context rule text is intact" "$B4_BLOCK" "Headless contexts — auto-decline + record. Never prompt, never dispatch,"
assert_contains "E6c: step 4b's literal receipt line is intact" "$B4_BLOCK" "user-docs: suggested, auto-declined (headless) — <task> @ <iso>"
assert_contains "E6d: step 4c was inserted AFTER step 4b's content, not inside it" "$B4_BLOCK" "4c. **Logic-doc tail step"

echo "--- Contract F: tier-3 installability ---"

for f in "skills/user-docs-logic/SKILL.md" "scripts/logic-receipt.sh" "scripts/logic-stale-check.sh" \
         "scripts/logic-exec-recheck.sh" "scripts/logic-parity-gate.sh" \
         "tools/user-docs/src/logic-evidence.mjs" "tools/user-docs/src/check-harness-target.mjs"; do
  assert_grep "F1: tier-3 manifests $f" "$TIER3" "\"from\": \"$f\""
done
t3_absent=""
while read -r p; do
  [[ -e "$REPO_ROOT/$p" ]] || t3_absent="$t3_absent $p"
done < <(python3 -c "
import json
m = json.load(open('$TIER3'))
for g in m.get('files', {}).values():
    for f in g:
        if 'from' in f:
            print(f['from'])
")
assert_eq "F2 (T30e): every tier-3 manifest 'from' path exists in the repo" "" "$t3_absent"
npm_req="$(python3 -c "
import json
m = json.load(open('$TIER3'))
print(sum(1 for r in m.get('requirements', []) if r.get('name') in ('npm','gemini') and not r.get('advisory')))
")"
assert_eq "F3: no new hard command requirement was added for logic extraction" "0" "$npm_req"

echo "--- Contract G: permissions-baseline self-protection ---"

assert_grep "G1: baseline appends the docs/user/.meta self-protection rule" "$BASELINE" "./docs/user/.meta/**"
BASELINE_VALID="$(python3 -c "
import json
d = json.load(open('$BASELINE'))
rules = [r for r in d['floor']['path_rules'] if r['path'] == './docs/user/.meta/**']
print('ok' if len(rules) == 1 and rules[0]['class'] == 'path' else 'bad')
")"
assert_eq "G2: the new path_rule has class 'path' per ADR-044's honesty-class enum" "ok" "$BASELINE_VALID"

if [[ -f "$COMPILE" ]] && command -v jq >/dev/null 2>&1; then
  G_HOME="$(mktemp -d)"; mkdir -p "$G_HOME/.claude/session-state" "$G_HOME/.claude/config" "$G_HOME/.claude/logs"
  G_REPO="$(mktemp -d)"; mkdir -p "$G_REPO/.claude"
  jq -n '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01",
          domain_mode:null, sensitivity:{level:"normal"}, required_approvals:[]}' \
    > "$G_REPO/.claude/stack-config.json"
  HOME="$G_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$G_REPO" >/dev/null 2>&1
  DENY_1="$(jq -r '.permissions.deny[]?' "$G_REPO/.claude/settings.json" 2>/dev/null)"
  assert_contains "G3: compiler emits Edit(./docs/user/.meta/**)" "$DENY_1" "Edit(./docs/user/.meta/**)"
  assert_contains "G3b: compiler emits Write(./docs/user/.meta/**)" "$DENY_1" "Write(./docs/user/.meta/**)"
  SETTINGS_1="$(cat "$G_REPO/.claude/settings.json")"
  HOME="$G_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$G_REPO" >/dev/null 2>&1
  SETTINGS_2="$(cat "$G_REPO/.claude/settings.json")"
  assert_eq "G4 (ADR-044 T4): settings.json byte-identical across two compiles" "$SETTINGS_1" "$SETTINGS_2"
  rm -rf "$G_HOME" "$G_REPO"
else
  notrun "G3/G4: permissions-compile.sh emission + idempotency" "jq and an executable scripts/permissions-compile.sh"
fi

echo "--- Roster ceiling (D1/D2): no seat taken ---"

assert_eq "R1: agents/ still holds 24 agent files" "24" "$(ls "$REPO_ROOT"/agents/*.md | wc -l | tr -d ' ')"
# Anchored to the same fixed base commit as E6a (see note above) — a bare
# `git diff` goes vacuously true the moment this work is committed.
# tests/test-user-docs.sh's T31b/T31c already pin ADR-003's content durably
# regardless of commit state; this is the "nothing changed at all" proxy.
if git -C "$REPO_ROOT" cat-file -e "${FOREMAN_BASE_COMMIT}^{commit}" 2>/dev/null; then
  if git -C "$REPO_ROOT" diff --quiet "$FOREMAN_BASE_COMMIT" -- docs/ADRs/003-21-subagents.md 2>/dev/null; then
    pass "R2: docs/ADRs/003-21-subagents.md is unmodified since $FOREMAN_BASE_COMMIT (no seat taken)"
  else
    fail "R2: docs/ADRs/003-21-subagents.md was modified since $FOREMAN_BASE_COMMIT — ADR-050 D1/D2 says no seat is taken"
  fi
else
  notrun "R2: diff-since-base ADR-003 unmodified check" "base commit $FOREMAN_BASE_COMMIT reachable in this checkout"
fi
if [[ -f "$REPO_ROOT/agents/logic-extractor.md" ]]; then
  fail "R3: agents/logic-extractor.md must not exist"
else
  pass "R3: agents/logic-extractor.md does not exist"
fi

echo "--- Phase 5a regression + full suite ---"

if [[ -x "$PHASE5A" ]]; then
  if [[ -n "${GEMINI_API_KEY:-}" ]] || security find-generic-password -s gemini-api-key -w >/dev/null 2>&1; then
    if bash "$PHASE5A" >/tmp/phase5a-out.$$ 2>&1; then
      pass "P1: Phase 5a exit tests (scripts/check-docs-pipeline-phase5a.sh) are green"
    else
      fail "P1: Phase 5a exit tests failed — see /tmp/phase5a-out.$$"
    fi
  else
    notrun "P1: Phase 5a exit tests" "a reachable GEMINI_API_KEY (env or macOS Keychain gemini-api-key)"
  fi
else
  fail "P1: scripts/check-docs-pipeline-phase5a.sh missing or not executable"
fi

if bash "$REPO_ROOT/tests/test-user-docs.sh" >/tmp/test-user-docs-out.$$ 2>&1; then
  pass "P2: tests/test-user-docs.sh is green (including T31f/T31g)"
else
  fail "P2: tests/test-user-docs.sh failed — see /tmp/test-user-docs-out.$$"
fi

echo
echo "Results: $PASS passed, $FAIL failed, $NOTRUN not executed"
[[ "$FAIL" -eq 0 ]]
