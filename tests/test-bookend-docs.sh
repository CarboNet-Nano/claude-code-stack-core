#!/usr/bin/env bash
# Static prose + tier-manifest assertions for ADR-072's session bookends.
#
# Stage 1 only. Assertions about later-stage behavior (the improvement
# queue's §3.5 anchors-only resolution prohibition, per-file dispositions,
# the stash-is-gone rule, N1's "findings never applied" rule) belong to
# those stages' own carbonight SKILL.md content and are added when that
# content lands — asserting them now against text that doesn't exist yet
# would be testing nothing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------- tier-manifest coverage
# Every Stage-1 file must appear in BOTH config/tier-manifests/tier-0.json's
# files list AND its smoke_tests list — a file landing in only one is exactly
# the drift this assertion exists to catch.
TIER0="$REPO_ROOT/config/tier-manifests/tier-0.json"

check_in_manifest() {  # check_in_manifest <repo-relative-path> <smoke-test-substring>
  local path="$1" smoke_substr="$2"
  if jq -e --arg p "$path" '.files.global[] | select(.from == $p)' "$TIER0" >/dev/null 2>&1; then
    pass "tier-0.json: $path is listed in files.global"
  else
    fail "tier-0.json: $path is MISSING from files.global"
  fi
  if jq -e --arg s "$smoke_substr" '.smoke_tests[] | select(contains($s))' "$TIER0" >/dev/null 2>&1; then
    pass "tier-0.json: $path has a matching smoke test"
  else
    fail "tier-0.json: $path has NO matching smoke test (substring '$smoke_substr')"
  fi
}

check_in_manifest "hooks/session-marker.sh" "hooks/session-marker.sh"
check_in_manifest "lib/session-scope.sh" "lib/session-scope.sh"
check_in_manifest "scripts/session-close.sh" "scripts/session-close.sh"
check_in_manifest "skills/carbonight/SKILL.md" "skills/carbonight/SKILL.md"
check_in_manifest "lib/plain-text-guard.sh" "lib/plain-text-guard.sh"
check_in_manifest "scripts/session-brief.sh" "scripts/session-brief.sh"

# A file cannot land in one list only: files.global count of Stage-1/2
# entries must equal the smoke_tests count of matching entries (both
# computed above via check_in_manifest, so this is a second, coarser
# cross-check).
FILES_COUNT="$(jq '[.files.global[].from] | map(select(
  . == "hooks/session-marker.sh" or . == "lib/session-scope.sh" or
  . == "scripts/session-close.sh" or . == "skills/carbonight/SKILL.md" or
  . == "lib/plain-text-guard.sh" or . == "scripts/session-brief.sh"
)) | length' "$TIER0")"
SMOKE_COUNT="$(jq '[.smoke_tests[]] | map(select(
  contains("session-marker.sh") or contains("session-scope.sh") or
  contains("session-close.sh") or contains("carbonight/SKILL.md") or
  contains("plain-text-guard.sh") or contains("session-brief.sh")
)) | length' "$TIER0")"
if [[ "$FILES_COUNT" == "6" && "$SMOKE_COUNT" == "6" ]]; then
  pass "tier-0.json: files count (6) matches smoke_tests count (6) for Stage-1/2 additions"
else
  fail "tier-0.json: count mismatch (files=$FILES_COUNT smoke=$SMOKE_COUNT, want 6/6)"
fi

# ------------------------------------------------------------- capability registry
if command -v python3 >/dev/null 2>&1 && [[ -f "$REPO_ROOT/config/capability-registry.json" ]]; then
  if jq -e '.capabilities[] | select(.id == "carbonight")' "$REPO_ROOT/config/capability-registry.json" >/dev/null 2>&1; then
    pass "capability-registry.json: carbonight is registered"
  else
    fail "capability-registry.json: carbonight is missing — run scripts/gen-capability-registry.sh"
  fi
fi

# --------------------------------------------------- portable-core-skills.json
# D12: carbonight is deliberately NOT part of the offline-safe floor.
if grep -q '"carbonight"' "$REPO_ROOT/config/portable-core-skills.json" 2>/dev/null; then
  fail "portable-core-skills.json: carbonight must NOT be listed (D12)"
else
  pass "portable-core-skills.json: carbonight correctly absent (D12)"
fi

# ---------------------------------------------------- carbonight SKILL.md prose
CARBONIGHT_SKILL="$REPO_ROOT/skills/carbonight/SKILL.md"
if [[ -f "$CARBONIGHT_SKILL" ]]; then
  if grep -qi "model-invocable: false" "$CARBONIGHT_SKILL"; then
    pass "carbonight SKILL.md: model-invocable: false"
  else
    fail "carbonight SKILL.md: missing model-invocable: false"
  fi
  # ADR-074: carbonight now DOES commit and push — in Step 10d, and only ever
  # through handoff-write. The invariant that survives is that it never
  # hand-rolls git for the handoff, because handoff-write is the single code
  # path carrying the secrets gate and the local-only disclosure.
  if grep -q "handoff-write" "$CARBONIGHT_SKILL" && \
     ! grep -qE '^[^|#]*`?git (add|commit|push)`? ' "$CARBONIGHT_SKILL"; then
    pass "carbonight SKILL.md: commits only via handoff-write, never a hand-rolled git command"
  else
    fail "carbonight SKILL.md: contains a direct git add/commit/push instruction — it must go through handoff-write"
  fi
  if grep -q "cost-log.jsonl" "$CARBONIGHT_SKILL" && grep -q "never.*cost-log.jsonl\|not.*cost-log.jsonl" "$CARBONIGHT_SKILL"; then
    pass "carbonight SKILL.md: names cost-log.jsonl as NOT the cost source"
  else
    fail "carbonight SKILL.md: missing the cost-log.jsonl exclusion note"
  fi
else
  fail "skills/carbonight/SKILL.md does not exist"
fi

# ------------------------------------------------------------------- handoff
# ADR-074: the handoff is no longer its own command. The H3 push-verification
# contract and the never-say-pushed-unverified rule moved into /carbonight.
HANDOFF_SKILL="$REPO_ROOT/skills/handoff/SKILL.md"
if grep -q "verify-push\|push.verified" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: references the push verification contract (H3)"
else
  fail "carbonight SKILL.md: missing the H3 push-verification wiring"
fi
if grep -qi "only.*when .push.verified. is\|never say \"pushed\"\|never invent a verification" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: states the word 'pushed' is never printed unverified"
else
  fail "carbonight SKILL.md: missing the never-print-pushed-unverified rule"
fi

# ------------------------------------------------------------- carbonet/goodmorning
# ADR-084: /carbonet was folded into /goodmorning as its `plain` display
# face (skills/carbonet/SKILL.md no longer exists — it is now a generated,
# promoted mode-alias stub). These three greps used to target the standalone
# carbonet file; they are re-pointed at GOODMORNING_SKILL, which is now
# where W1-W6's content actually lives (7P / the D5 non-regression clauses).
# Deeper coverage of the merged content lives in
# tests/test-goodmorning-faces.sh (K1-K9) and tests/test-plain-face-live.sh
# (L1-L9) — this block only guards that the migration didn't silently drop
# the three anchors this file already checked before ADR-084.
GOODMORNING_SKILL="$REPO_ROOT/skills/goodmorning/SKILL.md"
if grep -q "session-brief.sh" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: wires session-brief.sh (carbonet's W1/W3/W6, ADR-084)"
else
  fail "goodmorning SKILL.md: missing session-brief.sh wiring"
fi
if grep -qi "byte-verbatim" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: still requires org-check.sh output byte-verbatim (carbonet's W2, ADR-084 D5 clause 1)"
else
  fail "goodmorning SKILL.md: missing the byte-verbatim requirement"
fi
if grep -q "improvement-queue.sh list --top 3" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: W4 wires improvement-queue.sh list --top 3 (carbonet's W4, ADR-084)"
else
  fail "goodmorning SKILL.md: missing the W4 queue wiring"
fi

if grep -q "Label-block cap: 7 → 10\|cap: 7 .. 10\|7 → 10" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: documents the label cap as 10"
else
  fail "goodmorning SKILL.md: missing the 10-label cap documentation"
fi
if grep -q "improvement-queue.sh list --top 3" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: G1 wires improvement-queue.sh list --top 3"
else
  fail "goodmorning SKILL.md: missing the G1 queue wiring"
fi
if grep -q "session-brief.sh running" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: Running (G2) is wired to session-brief.sh running"
else
  fail "goodmorning SKILL.md: missing the Running (G2) wiring"
fi
if grep -q "skip silently if session-brief.sh absent\|skip.*silently.*session-brief" "$GOODMORNING_SKILL" 2>/dev/null; then
  pass "goodmorning SKILL.md: new steps fail open when session-brief.sh is absent"
else
  fail "goodmorning SKILL.md: missing the fail-open note for the new steps"
fi

# --------------------------------------------------------------- Stage 3 (N3b)
if grep -qi "no stash option" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: states there is no stash option"
else
  fail "carbonight SKILL.md: missing the no-stash-option statement"
fi
if grep -qi "no \"discard\" option\|no discard option" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: states there is no discard option"
else
  fail "carbonight SKILL.md: missing the no-discard-option statement"
fi
if grep -q "no default on silence\|No default on silence" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: states no default disposition on silence"
else
  fail "carbonight SKILL.md: missing the no-default-on-silence rule"
fi
if grep -q -- "--per-file" "$CARBONIGHT_SKILL" 2>/dev/null && grep -q -- "--by-class" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: documents --per-file and --by-class overrides"
else
  fail "carbonight SKILL.md: missing --per-file/--by-class documentation"
fi
if grep -q "10 dirty files\|>10\|\\\\>10" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: documents the >10-file per-class fallback threshold"
else
  fail "carbonight SKILL.md: missing the 10-file fallback threshold"
fi

# ADR-074 D6: the disclosure is GENERATED by handoff-write, not composed. The
# skill's job is to pass the paths and to state that it must not write it.
if grep -q "Local-only work" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: names the mandatory Local-only work disclosure"
else
  fail "carbonight SKILL.md: missing the Local-only work disclosure text"
fi
if grep -q "local-only-path" "$REPO_ROOT/scripts/session-close.sh" 2>/dev/null; then
  pass "session-close.sh: handoff-write takes --local-only-path (D6 generates the block)"
else
  fail "session-close.sh: --local-only-path missing"
fi

if grep -q "dispose" "$REPO_ROOT/scripts/session-close.sh" 2>/dev/null; then
  pass "session-close.sh: the dispose subcommand exists"
else
  fail "session-close.sh: dispose subcommand missing"
fi

if grep -q "running" "$REPO_ROOT/scripts/session-brief.sh" 2>/dev/null; then
  pass "session-brief.sh: the running subcommand exists (G2)"
else
  fail "session-brief.sh: running subcommand missing"
fi

# ------------------------------------------------- dispose-review-round-2
# 2026-08-12 cross-family review, 5 BLOCKING findings, all accepted.
if grep -q -- '--path <path answered' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: documents the repeatable --path convention (not the removed --paths word-splitting form)"
else
  fail "carbonight SKILL.md: missing the repeatable --path documentation"
fi
if grep -qE -- '--paths "<' "$CARBONIGHT_SKILL" 2>/dev/null; then
  fail "carbonight SKILL.md: still instructs the removed space-joined --paths form somewhere"
else
  pass "carbonight SKILL.md: no leftover instruction to use the removed --paths form"
fi
if grep -qi "exit code is meaningful\|exit 1" "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "carbonight SKILL.md: documents dispose's exit-1 (unresolved) case"
else
  fail "carbonight SKILL.md: missing dispose's exit-1 documentation"
fi
if grep -q -- "--path " "$REPO_ROOT/scripts/session-close.sh" 2>/dev/null && ! grep -q -- '--paths"' "$REPO_ROOT/scripts/session-close.sh" 2>/dev/null; then
  pass "session-close.sh: dispose accepts repeatable --path, not the removed --paths flag"
else
  fail "session-close.sh: expected --path (repeatable), found a stale --paths reference"
fi
if grep -q "session-close-dispose.lock" "$REPO_ROOT/scripts/session-close.sh" 2>/dev/null; then
  pass "session-close.sh: the crash-recovery marker exists"
else
  fail "session-close.sh: missing the crash-recovery marker mechanism"
fi

# ------------------------------------------------------------------- Stage 4
# The improvement queue (ADR-072 §3, maintainer §12=(a): GitHub issues ONLY).
if grep -q -- "^scripts/improvement-queue.sh$\|from.*scripts/improvement-queue.sh" "$TIER0" 2>/dev/null || \
   jq -e '.files.global[] | select(.from == "scripts/improvement-queue.sh")' "$TIER0" >/dev/null 2>&1; then
  pass "tier-0.json: scripts/improvement-queue.sh is listed in files.global"
else
  fail "tier-0.json: scripts/improvement-queue.sh is MISSING from files.global"
fi
if jq -e '.smoke_tests[] | select(contains("improvement-queue.sh"))' "$TIER0" >/dev/null 2>&1; then
  pass "tier-0.json: scripts/improvement-queue.sh has a matching smoke test"
else
  fail "tier-0.json: scripts/improvement-queue.sh has no matching smoke test"
fi

if grep -q "queue-spool.jsonl" "$REPO_ROOT/.gitignore" 2>/dev/null; then
  pass ".gitignore: the offline spool is gitignored"
else
  fail ".gitignore: missing the .queue-spool.jsonl entry"
fi

# D4 hard prohibition must be stated in every surface that could resolve
# "do item N" — /goodmorning (both faces, dev and carbonet's plain face,
# ADR-084) and /carbonight. /handoff is exempt (LOOP4 asserts it contains no
# improvement-queue reference at all — it resolves nothing).
#
# ADR-084 drops carbonet from this loop: skills/carbonet/SKILL.md no longer
# exists (it is now a generated mode-alias stub, not hand-authored prose),
# and its content — including this exact prohibition — now lives inside
# GOODMORNING_SKILL, already checked in the same loop. Keeping the stale
# path here would not be a vacuous pass (grep on a missing file exits
# non-zero, so the `fail` branch fires) — it would be a permanent, false
# FAIL for content that genuinely still exists, just moved file. Dropping
# it is the correct migration, not a weakened check.
for f in "$GOODMORNING_SKILL" "$CARBONIGHT_SKILL"; do
  name="$(basename "$(dirname "$f")")"
  if grep -q -- "--task" "$f" 2>/dev/null && grep -q "gh issue view" "$f" 2>/dev/null; then
    pass "$name/SKILL.md: states the D4 hard prohibition (show --task only, never cat/Read/gh issue view)"
  else
    fail "$name/SKILL.md: missing the D4 hard prohibition"
  fi
done

# No local-file queue backend anywhere (maintainer §12=(a): GitHub ONLY).
if grep -qE "improvement-queue\.md" "$REPO_ROOT/scripts/improvement-queue.sh" 2>/dev/null; then
  fail "improvement-queue.sh: references the local-file backend, which was explicitly not built"
else
  pass "improvement-queue.sh: no local-file backend anywhere (GitHub-only, per §12=(a))"
fi
if grep -q "IMPROVEMENT_QUEUE_BACKEND" "$REPO_ROOT/scripts/improvement-queue.sh" 2>/dev/null; then
  fail "improvement-queue.sh: implements the dual-backend auto-detect env override, which was explicitly not built"
else
  pass "improvement-queue.sh: no dual-backend auto-detect (single GitHub backend, per §12=(a))"
fi

# No similarity-matching FUNCTION exists anywhere (ADR-057) -- only byte
# equality on (where, kind). (Explanatory comments legitimately use the
# word "similarity" to document its absence, so this checks for an actual
# fuzzy-matching primitive, not the word itself.)
if grep -qE "levenshtein|jaro.?winkler|soundex|fuzzy_match|similarity_score" "$REPO_ROOT/scripts/improvement-queue.sh" 2>/dev/null; then
  fail "improvement-queue.sh: implements an actual fuzzy-matching primitive, which ADR-057 forbids"
else
  pass "improvement-queue.sh: no fuzzy-matching primitive anywhere (byte equality only)"
fi

# ------------------------------------------------------------------- Stage 6
# N10, the overnight queue agent (ADR-072 D11, design §7) -- three-job CI
# split, PR-only, opt-in per item. Deep behavioral coverage (pick,
# assert-branch, check-diff, secrets-scan, the workflow-lint structural
# assertions) lives in tests/test-overnight-queue-guards.sh; this file only
# checks the tier-manifest wiring and file existence, matching this file's
# own "static, stages 1-6" charter.
check_in_manifest "scripts/overnight-guard.sh" "scripts/overnight-guard.sh"

if [[ -f "$REPO_ROOT/.github/workflows/overnight-queue.yml" ]]; then
  pass ".github/workflows/overnight-queue.yml exists"
else
  fail ".github/workflows/overnight-queue.yml is MISSING"
fi
if [[ -f "$REPO_ROOT/.github/workflows/overnight-verify.yml" ]]; then
  pass ".github/workflows/overnight-verify.yml exists (job B, split out so secrets: {} is a real platform guarantee)"
else
  fail ".github/workflows/overnight-verify.yml is MISSING"
fi

# The workflow files are deliberately NOT added to tier-manifests --
# they're this repo's own CI, not something a member repo gets copied at
# install time (same as .github/workflows/mcp-market-sweep.yml, which also
# never appears there).
if jq -e '.files.global[] | select(.from | test("^\\.github/workflows/overnight"))' "$TIER0" >/dev/null 2>&1; then
  fail "tier-0.json: the overnight-queue workflow files must NOT be listed in files.global (they are this repo's own CI, not distributed)"
else
  pass "tier-0.json: the overnight-queue workflow files are correctly absent from files.global"
fi

# ==================================================== ADR-074 — the collapse
#
# LOOP1-5 are the structural guarantee. The cycle this ADR removes is
# /handoff -> /carbonight -> /handoff, which becomes infinite the moment
# `handoff` is aliased to `carbonight`. A name is the edge; these assert no
# name exists in either direction.

if grep -nE '/handoff([^s/-]|$)' "$CARBONIGHT_SKILL" >/dev/null 2>&1; then
  fail "LOOP1: skills/carbonight/SKILL.md still names the handoff command: $(grep -nE '/handoff([^s/-]|$)' "$CARBONIGHT_SKILL" | head -3 | tr '\n' ' ')"
else
  pass "LOOP1: carbonight names no handoff command anywhere"
fi
if grep -n 'skills/handoff' "$CARBONIGHT_SKILL" >/dev/null 2>&1; then
  fail "LOOP2: carbonight still points at skills/handoff"
else
  pass "LOOP2: carbonight does not reference skills/handoff"
fi
if grep -nE '/handoff([^s/-]|$)' "$REPO_ROOT/scripts/session-close.sh" >/dev/null 2>&1; then
  fail "LOOP3: session-close.sh still names the handoff command: $(grep -nE '/handoff([^s/-]|$)' "$REPO_ROOT/scripts/session-close.sh" | head -3 | tr '\n' ' ')"
else
  pass "LOOP3: session-close.sh names no handoff command"
fi

STUB_LINES="$(wc -l < "$HANDOFF_SKILL" 2>/dev/null | tr -d ' ')"
if [[ "$STUB_LINES" =~ ^[0-9]+$ ]] && (( STUB_LINES <= 20 )); then
  pass "LOOP4: the handoff stub is $STUB_LINES lines (mechanism-free)"
else
  fail "LOOP4: the handoff stub is $STUB_LINES lines — it should carry no mechanism"
fi
if grep -q 'handoff-redirect' "$HANDOFF_SKILL" 2>/dev/null; then
  pass "LOOP4: the stub calls handoff-redirect (the circuit breaker)"
else
  fail "LOOP4: the stub does not call handoff-redirect"
fi
STUB_BAD=""
for needle in 'next_prompt.md' 'docs/handoffs/' 'git push' 'git add' 'improvement-queue'; do
  grep -q -- "$needle" "$HANDOFF_SKILL" 2>/dev/null && STUB_BAD="$STUB_BAD $needle"
done
if [[ -z "$STUB_BAD" ]]; then
  pass "LOOP4: the stub carries none of the old mechanism"
else
  fail "LOOP4: the stub still contains:$STUB_BAD"
fi

# LOOP5 — the pair rule, both directions, over the real files.
LOOP5_FAIL=0
grep -qE '/handoff([^s/-]|$)' "$CARBONIGHT_SKILL" 2>/dev/null && LOOP5_FAIL=1
grep -qE '/carbonight([^-]|$)' "$HANDOFF_SKILL" 2>/dev/null && {
  grep -qE 'Run that|points back|close-out is' "$HANDOFF_SKILL" 2>/dev/null || LOOP5_FAIL=1
}
if (( LOOP5_FAIL == 0 )); then
  pass "LOOP5: the (handoff, carbonight) pair has no mutual invocation — the cycle is unrepresentable"
else
  fail "LOOP5: handoff and carbonight still invoke each other"
fi

# --------------------------------------------------------------- scribe (D16)
SCRIBE="$REPO_ROOT/agents/scribe.md"
if grep -q 'handoff-write' "$SCRIBE" 2>/dev/null && grep -q -- '--no-push' "$SCRIBE" 2>/dev/null; then
  pass "SCR1: scribe routes through handoff-write with --no-push"
else
  fail "SCR1: scribe does not route through handoff-write --no-push"
fi
if grep -qE '^[^#]*(git add|git commit)' "$SCRIBE" 2>/dev/null && \
   ! grep -q 'Run .git add. or .git commit. on handoff content' "$SCRIBE" 2>/dev/null; then
  fail "SCR2: scribe still instructs a direct git commit of handoff content"
else
  pass "SCR2: scribe has no direct git add/commit instruction for handoff content"
fi
if grep -qi 'Exit 1 means STOP\|exit 1.*stop' "$SCRIBE" 2>/dev/null; then
  pass "SCR3: scribe states that exit 1 means STOP"
else
  fail "SCR3: scribe does not say exit 1 means STOP"
fi

# --------------------------------------------------------------- wiring
TIER0="$REPO_ROOT/config/tier-manifests/tier-0.json"
if grep -q 'skills/handoff/SKILL.md' "$TIER0" 2>/dev/null; then
  pass "STUB1: tier-0.json still installs skills/handoff/SKILL.md (this is what overwrites the old 230-line copy)"
else
  fail "STUB1: tier-0.json no longer installs the handoff stub — old copies would be stranded forever"
fi
PORTABLE="$REPO_ROOT/config/portable-core-skills.json"
if jq -e '.skills | index("handoff") != null' "$PORTABLE" >/dev/null 2>&1; then
  pass "STUB3: portable-core-skills.json still lists handoff"
else
  fail "STUB3: handoff was removed from portable-core-skills.json"
fi
if jq -e '.skills | index("carbonight") == null' "$PORTABLE" >/dev/null 2>&1; then
  pass "STUB3: portable-core-skills.json still omits carbonight (load-bearing for ADR-074 fact 8)"
else
  fail "STUB3: carbonight was added to portable-core-skills.json — ADR-074 fact 8 depends on its absence"
fi

for needle in handoff-gather handoff-write; do
  if grep -q "$needle" "$CARBONIGHT_SKILL" 2>/dev/null; then
    pass "FOLD1: carbonight names $needle"
  else
    fail "FOLD1: carbonight does not name $needle"
  fi
done
if grep -q 'd5a-duplicate-disclosure' "$CARBONIGHT_SKILL" 2>/dev/null && \
   grep -q 'queue-section-in-body' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "FOLD2: carbonight documents handoff-write's exit-1 refusal reasons"
else
  fail "FOLD2: carbonight does not document the refusal reasons"
fi
if grep -q 'FAIL-FAST' "$CARBONIGHT_SKILL" 2>/dev/null && grep -q 'STOP' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "FOLD3: carbonight states PM close-out is FAIL-FAST and says STOP"
else
  fail "FOLD3: carbonight does not state the PM close-out FAIL-FAST rule"
fi
if grep -q 'Do NOT write these two sections yourself' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "FOLD4: carbonight Step 10c forbids writing the two generated sections"
else
  fail "FOLD4: carbonight does not forbid writing the generated sections"
fi
if grep -q 'degraded' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "FOLD5: carbonight surfaces handoff-gather's degraded[] entries"
else
  fail "FOLD5: carbonight does not surface degraded[]"
fi
if grep -q 'Step 11 still runs' "$CARBONIGHT_SKILL" 2>/dev/null; then
  pass "FLAG1: carbonight states the session is still recorded under --no-handoff"
else
  fail "FLAG1: carbonight does not state that Step 11 runs under --no-handoff"
fi

echo "test-bookend-docs: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
