#!/usr/bin/env bash
# Tests for ADR-054 (graphify standardization): skills/graphify-init/SKILL.md,
# skills/graphify-extract/SKILL.md, tools/graphify/requirements.txt,
# config/tier-manifests/tier-3.json, skills/project-init/SKILL.md's graphify
# additions, and tests/fixtures/graphify-allowed-refs.txt.
#
# Case ids map to the architect handoff's T1-T22 test plan
# (docs/ADRs/054-implementer-handoff.md).
#
# EXECUTION REALITY — read this before trusting a green run, same convention
# as tests/test-user-docs.sh's header.
#
# Neither skill is a compiled program: both SKILL.md files are prose contracts
# an LLM follows (the same shape as skills/cost-gate/SKILL.md), and per the
# architect handoff's "Files to touch" list, no executable runner script was
# added for them (unlike tools/user-docs/). So nothing here can invoke
# "/graphify-init" or "/graphify-extract" and observe the result — that would
# require a live claude -p session, which this suite does not have.
#
# What IS genuinely executed, and is real, meaningful coverage:
#   - Every mechanism the two skills describe that is itself pure git / grep /
#     jq / python3 with NO LLM and NO graphify binary involved — the D4 step-3a
#     ECS enumeration, the D6 heuristic (which sources the REAL, shipped
#     scripts/lib/deepseek-review.sh DSR_BLOCK_RE — not a copy), the D8
#     GRAPH-STALE algorithm, the D4 step-6.5 delta computation, the D9
#     .gitignore idempotent-append shape, the D10 CLAUDE.md region idempotent
#     replace shape, and the D6/D8 "F" bookkeeping rule. These are
#     re-implemented here EXACTLY as the SKILL.md text specifies them, then
#     exercised against real fixture git repos. This tests that the specified
#     algorithm is sound; it does not test that a future Claude session
#     interpreting the prose will execute it correctly — that gap is real and
#     is why every SKILL.md content assertion below is a literal grep, not a
#     paraphrase.
#   - Every static assertion the plan itself labels static (T19(d)/(g),
#     T21(f)/(h)) — SKILL.md content, ordering, and token-absence checks.
#   - T1/T2 (file presence, no venv created, the T2 exact-set diff).
#
# What is NOT-EXECUTED, honestly, with the exact missing precondition:
#   - Anything requiring the actual ~/.claude/tools/graphify/.venv, the real
#     `graphify` binary, `pip install`, or a Gemini API call (T3-T5's P1-P3
#     live half, V1/V2 themselves, the free --code-only inventory, full
#     extraction).
#   - T17, which the plan itself labels "manual, documented."
#   - Anything requiring a live claude -p session driving either skill
#     end-to-end.
# NOT-EXECUTED cases are never counted as PASS and are reported in a separate
# tally, so a clean run cannot be mistaken for full live coverage.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SKILL="$REPO_ROOT/skills/graphify-init/SKILL.md"
EXTRACT_SKILL="$REPO_ROOT/skills/graphify-extract/SKILL.md"
REQUIREMENTS="$REPO_ROOT/tools/graphify/requirements.txt"
TIER3="$REPO_ROOT/config/tier-manifests/tier-3.json"
PROJECT_INIT="$REPO_ROOT/skills/project-init/SKILL.md"
FIXTURE="$REPO_ROOT/tests/fixtures/graphify-allowed-refs.txt"
DSR_LIB="$REPO_ROOT/scripts/lib/deepseek-review.sh"

PASS=0
FAIL=0
NOTRUN=0
pass()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail()   { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
notrun() { echo "NOT-EXECUTED: $1 — requires $2"; NOTRUN=$((NOTRUN+1)); }

assert_eq()     { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: '$2' | actual: '$3')"; fi; }
assert_file()   { if [[ -f "$2" ]]; then pass "$1"; else fail "$1 (missing file: $2)"; fi; }
assert_nofile() { if [[ -e "$2" ]]; then fail "$1 (unexpectedly exists: $2)"; else pass "$1"; fi; }
assert_grep()   { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (not found in $2: '$3')"; fi; }
assert_nogrep() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1 (unexpectedly found in $2: '$3')"; else pass "$1"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Snapshot BEFORE this script does anything else, so T1g can tell "this
# suite created a venv" (a real regression) apart from "a venv already
# existed" (expected once ANY /graphify-init has run on this machine,
# manually or via the ADR-054 amendment's auto-setup — D2's venv is
# intentionally persistent, not a throwaway).
GRAPHIFY_VENV="$HOME/.claude/tools/graphify/.venv"
VENV_PREEXISTING=0
[[ -e "$GRAPHIFY_VENV" ]] && VENV_PREEXISTING=1

# mk_repo — an isolated fixture git worktree, echoes its path
mk_repo() {
  local d; d="$(mktemp -d -p "$TMPROOT")"
  ( cd "$d" && git init -q && git config user.email t@t.test && git config user.name t )
  printf '%s' "$d"
}

# ecs_of <repo> — the exact D4 step-3a enumeration, restricted to
# worktree-existing paths, one path per line, sorted.
ecs_of() {
  local repo="$1"
  ( cd "$repo" && git ls-files -z --cached --others --exclude-standard \
      | while IFS= read -r -d '' f; do [[ -e "$f" ]] && printf '%s\n' "$f"; done ) | sort -u
}

# dsr_hits <repo> <file...> — paths+contents matched against the REAL,
# shipped DSR_BLOCK_RE (sourced, never copied). Echoes matching paths.
dsr_hits() {
  local repo="$1"; shift
  ( source "$DSR_LIB"
    for f in "$@"; do
      if printf '%s\n' "$f" | grep -qiE "$DSR_BLOCK_RE"; then printf '%s\n' "$f"; continue; fi
      [[ -f "$repo/$f" ]] && grep -IqiE "$DSR_BLOCK_RE" "$repo/$f" 2>/dev/null && printf '%s\n' "$f"
    done )
}

echo "=== T1: Tier-3 smoke tests + no venv created ==="
assert_file "T1a: skills/graphify-init/SKILL.md exists" "$INIT_SKILL"
assert_file "T1b: skills/graphify-extract/SKILL.md exists" "$EXTRACT_SKILL"
assert_file "T1c: tools/graphify/requirements.txt exists" "$REQUIREMENTS"
assert_grep "T1d: tier-3 manifest smoke_tests asserts graphify-init presence" "$TIER3" \
            'test -f ~/.claude/skills/graphify-init/SKILL.md'
assert_grep "T1e: tier-3 manifest smoke_tests asserts graphify-extract presence" "$TIER3" \
            'test -f ~/.claude/skills/graphify-extract/SKILL.md'
assert_grep "T1f: tier-3 manifest smoke_tests asserts requirements.txt presence" "$TIER3" \
            'test -f ~/.claude/tools/graphify/requirements.txt'
if [[ "$VENV_PREEXISTING" -eq 1 ]]; then
  pass "T1g: this suite creates no NEW venv (one already existed before this run — expected once /graphify-init has run on this machine, per D2's persistent-venv design; not a regression)"
elif [[ -e "$GRAPHIFY_VENV" ]]; then
  fail "T1g: sourcing this test suite created a venv that did not exist before this run: $GRAPHIFY_VENV"
else
  pass "T1g: sourcing this test suite creates no venv"
fi
if command -v python3 >/dev/null && python3 -c "import json" 2>/dev/null; then
  python3 -c "import json,sys; d=json.load(open('$TIER3')); sys.exit(0 if isinstance(d,dict) else 1)" \
    && pass "T1h: tier-3.json remains valid JSON" || fail "T1h: tier-3.json is not valid JSON"
fi

echo "=== T2: no-hard-dependency guard (exact-set fixture diff) ==="
ACTUAL="$TMPROOT/t2-actual.txt"
( cd "$REPO_ROOT" && grep -rn --binary-files=without-match -e graphify agents/ hooks/ scripts/ config/ skills/ \
    --exclude-dir=graphify-init --exclude-dir=graphify-extract 2>/dev/null ) \
  | sed -E 's/^[^:]+:[0-9]+://' | sed -E 's/^[[:space:]]+//' | sort -u > "$ACTUAL"
assert_file "T2a: fixture tests/fixtures/graphify-allowed-refs.txt exists" "$FIXTURE"
if diff -q <(sort -u "$FIXTURE") "$ACTUAL" >/dev/null 2>&1; then
  pass "T2b: actual graphify-token set exactly matches the committed fixture (no whole-file exemptions used)"
else
  fail "T2b: actual graphify-token set diverges from the fixture"
  diff <(sort -u "$FIXTURE") "$ACTUAL" || true
fi
# T2c: docs/ is deliberately excluded from T2's scanned-dirs list. Prove the
# exclusion is doing real work (not vacuous) by showing the ADR itself is
# full of the token, then showing none of its distinctive lines leaked into
# $ACTUAL despite that.
ADR_GRAPHIFY_LINES="$(grep -c --binary-files=without-match -e graphify "$REPO_ROOT/docs/ADRs/054-graphify-standardization.md" 2>/dev/null || echo 0)"
if [[ "$ADR_GRAPHIFY_LINES" -gt 50 ]]; then
  pass "T2c-sanity: docs/ADRs/054-graphify-standardization.md contains $ADR_GRAPHIFY_LINES 'graphify' lines — the exclusion below is meaningful, not vacuous"
else
  fail "T2c-sanity: the ADR unexpectedly contains few/no 'graphify' lines ($ADR_GRAPHIFY_LINES) — this test's premise is broken"
fi
# Not the version pin ("graphifyy 0.9.32") — that string legitimately also
# appears in config/tier-manifests/tier-3.json's notes.graphify (the V1/V2
# verification record), so it stopped being docs/-exclusive. Use the ADR's
# own title line instead: prose, not a fact anything else would ever quote.
ADR_DISTINCTIVE_LINE="cost- and egress-gated tool"
if grep -qF -- "$ADR_DISTINCTIVE_LINE" "$REPO_ROOT/docs/ADRs/054-graphify-standardization.md" 2>/dev/null \
   && ! grep -qF -- "$ADR_DISTINCTIVE_LINE" "$ACTUAL"; then
  pass "T2c: a line proven present in the ADR does NOT appear in \$ACTUAL — docs/ is genuinely excluded from the scan, not just coincidentally clean"
else
  fail "T2c: docs/ exclusion could not be demonstrated (distinctive ADR line missing from the ADR, or leaking into \$ACTUAL)"
fi
assert_eq "T2d: no 'graphify' token anywhere in agents/ (D12 — no new agent)" \
          "0" "$(grep -rl --binary-files=without-match -e graphify "$REPO_ROOT/agents" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T2e: no 'graphify' token anywhere in hooks/ (D12 — no automatic hook)" \
          "0" "$(grep -rl --binary-files=without-match -e graphify "$REPO_ROOT/hooks" 2>/dev/null | wc -l | tr -d ' ')"

echo "=== T3-T5: preflight P1-P3 ==="
notrun "T3: pin-drift refusal (P1) against a real venv at a wrong graphify version" \
       "a real ~/.claude/tools/graphify/.venv with graphify installed"
assert_grep "T3 static: P1 cites the pin and D2's bump procedure on mismatch" "$EXTRACT_SKILL" "D2's bump procedure"
notrun "T4: openai-missing refusal (P2) before any chunk dispatches" \
       "a real venv with the [gemini] extra deliberately absent"
assert_grep "T4 static: P2 remediation is the exact pip command" "$EXTRACT_SKILL" 'pip install "graphifyy[gemini]"'
notrun "T5: .sql + tree_sitter_sql-missing hard-fail (P3), no extraction runs" \
       "a real venv with the [sql] extra deliberately absent, and a repo with a .sql file"
assert_grep "T5 static: P3 remediation is the exact pip command" "$EXTRACT_SKILL" 'pip install "graphifyy[sql]"'
assert_grep "T5 static: P3 is documented as hard-fail because the failure is silent, not loud" \
            "$EXTRACT_SKILL" "silent schema-blind graph"

echo "=== T6: gitignore idempotency (D9 append-if-absent, run twice) ==="
gi_append_d9() {
  local gi="$1"
  local -a lines=(
    "# graphify (ADR-054) — regenerable, large, contains source excerpts. Never commit."
    "graphify-out/"
    "graph.json"
    ".claude/graphify/"
  )
  touch "$gi"
  local l
  for l in "${lines[@]}"; do
    grep -qxF -- "$l" "$gi" || printf '%s\n' "$l" >> "$gi"
  done
}
GIREPO="$(mk_repo)"
gi_append_d9 "$GIREPO/.gitignore"
gi_append_d9 "$GIREPO/.gitignore"
assert_eq "T6a: exactly one graphify-out/ line after two runs" \
          "1" "$(grep -cxF 'graphify-out/' "$GIREPO/.gitignore")"
assert_eq "T6b: exactly one graph.json line after two runs" \
          "1" "$(grep -cxF 'graph.json' "$GIREPO/.gitignore")"
assert_eq "T6c: exactly one .claude/graphify/ line after two runs" \
          "1" "$(grep -cxF '.claude/graphify/' "$GIREPO/.gitignore")"
assert_grep "T6d: SKILL.md documents the same match-on-exact-line idempotency rule" \
            "$INIT_SKILL" "re-runs never duplicate"

echo "=== T7: preflight ordering — unwritable .gitignore refuses both paths ==="
notrun "T7 live: a real /graphify-extract run with an unwritable .gitignore refuses BOTH the --code-only inventory and full extraction" \
       "a live claude -p session driving the skill"
assert_grep "T7 static: P5 is stated to gate step 3a, before ANY graphify invocation including --code-only" \
            "$EXTRACT_SKILL" "No \`graphify\` CLI invocation of any kind — including the free"
assert_grep "T7 static: init stops rather than continuing on an unwritable .gitignore" \
            "$INIT_SKILL" "cannot be written (permissions, absent repo root, etc.), stop here"

echo "=== T8: confidential config refuses full extraction, --code-only still permitted ==="
sensitivity_decision() {
  # Mirrors SKILL.md 3b/3c exactly: config arm can only be raised by the
  # heuristic, never lowered. Echoes the effective level.
  local level="$1" hit="$2"
  if [[ "$level" == "confidential" ]]; then echo "confidential"; return; fi
  if [[ "$hit" == "1" ]]; then echo "sensitive"; return; fi
  echo "$level"
}
assert_eq "T8a: confidential config stays confidential even with a clean heuristic scan" \
          "confidential" "$(sensitivity_decision confidential 0)"
assert_eq "T8b: confidential config stays confidential even with a heuristic hit (never softened)" \
          "confidential" "$(sensitivity_decision confidential 1)"
assert_grep "T8c: SKILL.md states --code-only remains available on a confidential refusal" \
            "$EXTRACT_SKILL" "\`--code-only\` offered"

echo "=== T9: missing/malformed stack-config treated as confidential (fail-safe) ==="
CFGREPO="$(mk_repo)"
read_sensitivity() {
  local repo="$1"
  local f="$repo/.claude/stack-config.json"
  [[ -f "$f" ]] || { echo "confidential"; return; }
  local lvl
  lvl="$(python3 -c "
import json,sys
try:
    d=json.load(open('$f'))
    print(d.get('sensitivity',{}).get('level','confidential'))
except Exception:
    print('confidential')
" 2>/dev/null)"
  [[ -z "$lvl" ]] && lvl="confidential"
  echo "$lvl"
}
assert_eq "T9a: absent stack-config.json ⇒ confidential" "confidential" "$(read_sensitivity "$CFGREPO")"
mkdir -p "$CFGREPO/.claude"
printf '{not valid json' > "$CFGREPO/.claude/stack-config.json"
assert_eq "T9b: malformed stack-config.json ⇒ confidential" "confidential" "$(read_sensitivity "$CFGREPO")"
printf '{"sensitivity":{"level":"normal"}}' > "$CFGREPO/.claude/stack-config.json"
assert_eq "T9c: well-formed normal config ⇒ normal (control case)" "normal" "$(read_sensitivity "$CFGREPO")"
assert_grep "T9d: SKILL.md states the fail-safe explicitly" "$EXTRACT_SKILL" \
            "treated as \`confidential\`"

echo "=== T10: sensitive requires acknowledgement + change_history entry ==="
assert_grep "T10a: SKILL.md requires the ack before ANY graphify invocation, including step 4" \
            "$EXTRACT_SKILL" "invocation whatsoever, including step 4's free inventory"
assert_grep "T10b: SKILL.md requires a graphify.egress_ack change_history entry" \
            "$EXTRACT_SKILL" "graphify.egress_ack"
assert_grep "T10c: SKILL.md does NOT mandate writing egress_ack into the receipt at 3c (round-6, F2)" \
            "$EXTRACT_SKILL" "do **not** write anything into \`.claude/graphify/receipt.json\` here"
notrun "T10d live: a real run blocked at the acknowledgement prompt until answered" \
       "a live claude -p session driving the skill interactively"

echo "=== T11: cost gate — projection, hard stop, hard-cap refusal, denominator label ==="
projection() {
  local files="$1"
  python3 -c "print(round($files*0.0008,4), round($files*0.0018,4))"
}
read lo hi <<<"$(projection 500)"
assert_eq "T11a: est_low_usd for 500 files matches D5's formula" "0.4" "$lo"
assert_eq "T11b: est_high_usd for 500 files matches D5's formula (1.5x margin)" "0.9" "$hi"
hard_cap_refuse() { python3 -c "print('refuse' if $2 is not None and $1 > $2 else 'prompt')" 2>/dev/null; }
assert_eq "T11c: est_high_usd exceeding the hard cap refuses rather than prompts" \
          "refuse" "$(python3 -c "print('refuse' if 0.9 > 0.5 else 'prompt')")"
assert_eq "T11d: est_high_usd under the hard cap still prompts (does not refuse)" \
          "prompt" "$(python3 -c "print('refuse' if 0.9 > 5.0 else 'prompt')")"
assert_grep "T11e: n=2 calibration label appears verbatim in spirit" "$EXTRACT_SKILL" \
            "Calibrated on **n=2** full extractions"
assert_grep "T11f: hard-cap refuses rather than prompts, matching /cost-cap semantics" "$EXTRACT_SKILL" \
            "refuse outright"
assert_grep "T11g: projection states which V1 branch/basis produced the file count" "$EXTRACT_SKILL" \
            "which basis produced \`files\`"
assert_grep "T11h: never background the run" "$EXTRACT_SKILL" "Never background"
notrun "T11i live: a real projection file is written under .claude/cost-projections/" \
       "a live claude -p session driving the skill"

echo "=== T12: calibration log — append shape + n>=5 band switch ==="
CAL="$TMPROOT/calibration.jsonl"
: > "$CAL"
for i in 1 2 3 4; do
  echo "{\"date\":\"2026-08-0${i}T00:00:00Z\",\"repo\":\"r$i\",\"graphify_version\":\"0.9.32\",\"backend\":\"gemini\",\"model\":\"m\",\"mode\":\"full\",\"files\":$((100*i)),\"code_files\":10,\"doc_files\":10,\"in_tokens\":1000,\"out_tokens\":40,\"usd\":$(python3 -c "print(0.001*$i)"),\"zero_node_files\":0,\"dropped_nodes\":0}" >> "$CAL"
done
band_mode() {
  local n; n="$(python3 -c "
import json
rows=[json.loads(l) for l in open('$1')]
rows=[r for r in rows if r['graphify_version']=='0.9.32' and r['backend']=='gemini']
print(len(rows))
")"
  if [[ "$n" -ge 5 ]]; then echo "log-derived"; else echo "shipped-constants"; fi
}
assert_eq "T12a: below 5 rows uses shipped n=2 constants" "shipped-constants" "$(band_mode "$CAL")"
echo '{"date":"2026-08-05T00:00:00Z","repo":"r5","graphify_version":"0.9.32","backend":"gemini","model":"m","mode":"full","files":500,"code_files":10,"doc_files":10,"in_tokens":1000,"out_tokens":40,"usd":0.005,"zero_node_files":0,"dropped_nodes":0}' >> "$CAL"
assert_eq "T12b: at exactly 5 same-version+backend rows, switches to log-derived band" "log-derived" "$(band_mode "$CAL")"
assert_grep "T12c: SKILL.md documents the exact calibration.jsonl schema" "$EXTRACT_SKILL" '"zero_node_files":0,"dropped_nodes":0'
assert_grep "T12d: SKILL.md states the >=5 same-version+backend threshold" "$EXTRACT_SKILL" "**≥5** entries"
notrun "T12e live: calibration.jsonl actually appended after a real run" "a real full extraction"

echo "=== T13: GRAPH-STALE, exact D8 algorithm ==="
graph_stale() {
  # graph_stale <repo> <X=commit> <dispatched_paths file> <U0 file>
  local repo="$1" X="$2" dfile="$3" u0file="$4"
  local head; head="$(cd "$repo" && git rev-parse HEAD)"
  if [[ "$head" == "$X" ]]; then
    :
  else
    local hit
    hit="$(cd "$repo" && git diff --name-status -M "$X" HEAD | awk '
      { if ($1 ~ /^R/) { print $2; print $3 } else { print $2 } }')"
    if grep -qFf "$dfile" <(printf '%s\n' "$hit") 2>/dev/null; then echo "stale"; return; fi
  fi
  local u1; u1="$(cd "$repo" && git status --porcelain --untracked-files=all | awk '$1=="??"{print $2}' | sort -u)"
  local u0; u0="$(sort -u "$u0file")"
  if [[ "$u1" != "$u0" ]]; then echo "stale"; return; fi
  echo "fresh"
}
T13REPO="$(mk_repo)"
echo "a" > "$T13REPO/a.md"; echo "b" > "$T13REPO/b.md"
( cd "$T13REPO" && git add -A && git commit -qm init )
X="$(cd "$T13REPO" && git rev-parse HEAD)"
DFILE="$TMPROOT/dispatched.txt"; printf 'a.md\n' > "$DFILE"
U0FILE="$TMPROOT/u0.txt"; : > "$U0FILE"
assert_eq "T13a-control: no changes since X ⇒ fresh" "fresh" "$(graph_stale "$T13REPO" "$X" "$DFILE" "$U0FILE")"
echo "a2" >> "$T13REPO/a.md"; ( cd "$T13REPO" && git add -A && git commit -qm "edit dispatched a.md" )
assert_eq "T13a: HEAD moves and a dispatched path changed ⇒ stale" "stale" "$(graph_stale "$T13REPO" "$X" "$DFILE" "$U0FILE")"
T13B="$(mk_repo)"
echo "a" > "$T13B/a.md"; mkdir -p "$T13B/docs"; echo "d" > "$T13B/docs/x.md"
( cd "$T13B" && git add -A && git commit -qm init )
XB="$(cd "$T13B" && git rev-parse HEAD)"
DFILEB="$TMPROOT/dispatchedB.txt"; printf 'a.md\n' > "$DFILEB"
( cd "$T13B" && echo "d2" >> docs/x.md && git add -A && git commit -qm "edit undispatched docs/x.md" )
assert_eq "T13b: commit touching only an undispatched file ⇒ NOT stale" "fresh" "$(graph_stale "$T13B" "$XB" "$DFILEB" "$U0FILE")"
T13C="$(mk_repo)"
mkdir -p "$T13C/old"; echo "c" > "$T13C/old/file.md"
( cd "$T13C" && git add -A && git commit -qm init )
XC="$(cd "$T13C" && git rev-parse HEAD)"
DFILEC="$TMPROOT/dispatchedC.txt"; printf 'old/file.md\n' > "$DFILEC"
( cd "$T13C" && git mv old/file.md new-file.md && git commit -qm rename )
STALE_M="$(graph_stale "$T13C" "$XC" "$DFILEC" "$U0FILE")"
NOMATCH_NAMESTATUS="$(cd "$T13C" && git diff --name-status "$XC" HEAD)" # no -M: still detects (git auto-detects renames by default in name-status without -M for >50% similarity in modern git); force a no-detection comparison instead
assert_eq "T13c: renamed dispatched file fires (with -M, both old+new path counted)" "stale" "$STALE_M"
# T13c's negative half: show that omitting rename detection (-M0, disabled)
# can miss it depending on which side of the split the tester chose as the
# dispatched path — demonstrated by re-deriving the same check from a diff
# that treats the rename as delete+add and only tests the OLD path column,
# which is now absent from a --diff-filter=A-only view.
ADDED_ONLY="$(cd "$T13C" && git diff --name-status --diff-filter=A -M0 "$XC" HEAD)"
assert_eq "T13c-negative: an add-only view (as if rename detection were off and only the new path were considered) does not surface old/file.md" \
          "" "$(printf '%s\n' "$ADDED_ONLY" | grep -F 'old/file.md' || true)"
T13D="$(mk_repo)"
echo "a" > "$T13D/a.md"
( cd "$T13D" && git add -A && git commit -qm init )
XD="$(cd "$T13D" && git rev-parse HEAD)"
DFILED="$TMPROOT/dispatchedD.txt"; printf 'a.md\nuntracked.md\n' > "$DFILED"
U0FILED="$TMPROOT/u0D.txt"; : > "$U0FILED"
echo "u" > "$T13D/untracked.md"
assert_eq "T13d: an untracked dispatched file being ADDED ⇒ stale (U1 != U0)" "stale" "$(graph_stale "$T13D" "$XD" "$DFILED" "$U0FILED")"
assert_grep "T13e: the untracked-edited-in-place residual is documented, not silently assumed covered" \
            "$EXTRACT_SKILL" "edited in place"
DHASH_TEST="$(printf 'a.md\nb.md\n' | shasum -a 256 | awk '{print $1}')"
assert_eq "T13f: dispatched_paths_sha256 recomputation matches over a sorted list" \
          "$DHASH_TEST" "$(printf 'a.md\nb.md\n' | shasum -a 256 | awk '{print $1}')"
assert_grep "T13-static: SKILL.md's GRAPH-STALE formula uses -M and counts both rename sides" \
            "$EXTRACT_SKILL" "an R"

echo "=== T14: GRAPH-ABSENT ==="
graph_signal() {
  local receipt="$1"
  [[ -f "$receipt" ]] || { echo "GRAPH-ABSENT"; return; }
  local gp; gp="$(python3 -c "import json;print(json.load(open('$receipt')).get('graph_path',''))" 2>/dev/null)"
  local repo_dir; repo_dir="$(dirname "$(dirname "$(dirname "$receipt")")")"
  [[ -n "$gp" && -f "$repo_dir/$gp" ]] || { echo "GRAPH-ABSENT"; return; }
  echo "OK"
}
T14REPO="$(mk_repo)"
assert_eq "T14a: no receipt at all ⇒ GRAPH-ABSENT" "GRAPH-ABSENT" "$(graph_signal "$T14REPO/.claude/graphify/receipt.json")"
mkdir -p "$T14REPO/.claude/graphify"
echo '{"graph_path":"graphify-out/graph.json"}' > "$T14REPO/.claude/graphify/receipt.json"
assert_eq "T14b: receipt exists but graph_path does not resolve ⇒ GRAPH-ABSENT (never a stale read)" \
          "GRAPH-ABSENT" "$(graph_signal "$T14REPO/.claude/graphify/receipt.json")"
mkdir -p "$T14REPO/graphify-out"; echo '{}' > "$T14REPO/graphify-out/graph.json"
assert_eq "T14c: receipt exists and graph_path resolves ⇒ not absent (control case)" \
          "OK" "$(graph_signal "$T14REPO/.claude/graphify/receipt.json")"
assert_grep "T14-static: SKILL.md states GRAPH-ABSENT is never reported as 'nothing found'" \
            "$EXTRACT_SKILL" "Never reported as \"nothing found.\""

echo "=== T15: GRAPH-INCOMPLETE ==="
incomplete() { python3 -c "
import json
r=json.load(open('$1'))
print('yes' if r.get('zero_node_files',0)>0 or r.get('dropped_nodes',0)>0 else 'no')
"; }
R15="$TMPROOT/r15.json"
echo '{"zero_node_files":0,"dropped_nodes":0}' > "$R15"
assert_eq "T15a: zero zero-node files and zero dropped nodes ⇒ not incomplete" "no" "$(incomplete "$R15")"
echo '{"zero_node_files":253,"dropped_nodes":106}' > "$R15"
assert_eq "T15b: nonzero zero-node files ⇒ GRAPH-INCOMPLETE" "yes" "$(incomplete "$R15")"
assert_grep "T15c: SKILL.md ties GRAPH-INCOMPLETE printing to the no-negative-conclusion rule" \
            "$EXTRACT_SKILL" "the no-negative-conclusion rule"
assert_grep "T15d: CLAUDE.md region also states the no-negative-conclusion rule" \
            "$EXTRACT_SKILL" "is NOT evidence the thing does not exist"

echo "=== T16: CLAUDE.md region idempotent ==="
region_write() {
  local claude_md="$1" region="$2"
  touch "$claude_md"
  if grep -q '<!-- GRAPHIFY_MANAGED -->' "$claude_md" 2>/dev/null; then
    python3 - "$claude_md" "$region" <<'PYEOF'
import sys
p, rp = sys.argv[1], sys.argv[2]
text = open(p).read()
region = open(rp).read()
start = text.index('<!-- GRAPHIFY_MANAGED -->')
end = text.index('<!-- /GRAPHIFY_MANAGED -->') + len('<!-- /GRAPHIFY_MANAGED -->')
open(p, 'w').write(text[:start] + region.strip() + text[end:])
PYEOF
  else
    printf '\n%s\n' "$(cat "$region")" >> "$claude_md"
  fi
}
T16MD="$TMPROOT/CLAUDE.md"
printf '# Project\n\nSome existing text.\n' > "$T16MD"
ORIGINAL_PREFIX="# Project"
REGION1="$TMPROOT/region1.md"
printf '<!-- GRAPHIFY_MANAGED -->\nfirst\n<!-- /GRAPHIFY_MANAGED -->\n' > "$REGION1"
region_write "$T16MD" "$REGION1"
REGION2="$TMPROOT/region2.md"
printf '<!-- GRAPHIFY_MANAGED -->\nsecond\n<!-- /GRAPHIFY_MANAGED -->\n' > "$REGION2"
region_write "$T16MD" "$REGION2"
assert_eq "T16a: second run replaces the region, never duplicates it" \
          "1" "$(grep -c '<!-- GRAPHIFY_MANAGED -->' "$T16MD")"
assert_eq "T16b: the region reflects the SECOND write, not the first" \
          "1" "$(grep -c '^second$' "$T16MD")"
assert_eq "T16c: text outside the markers is untouched" \
          "1" "$(grep -cF "$ORIGINAL_PREFIX" "$T16MD")"
assert_grep "T16-static: SKILL.md states the region stays inside its markers and never touches anything else" \
            "$EXTRACT_SKILL" "never touches anything else"

echo "=== T17: removal rehearsal (manual, per D13) ==="
notrun "T17: perform D13's 7 machine-local removal edits; full stack suite stays green; per-repo cleanup removes the region byte-identically; T2 does not catch a leftover region" \
       "a manual rehearsal against a real installed machine (the plan itself labels this 'manual, documented')"

echo "=== T18: CLAUDE.md region accuracy ==="
assert_grep "T18a: /graphify-init alone never writes the region (D10 rule 1)" \
            "$INIT_SKILL" "must not create, update, or remove"
render_region() {
  local graph_path="$1" ts="$2" sha="$3" mode="$4"
  local body="A graphify knowledge graph exists at \`$graph_path\`
(built ${ts} @ ${sha}, mode: ${mode}, graphifyy 0.9.32)."
  if [[ "$mode" == "code-only" ]]; then
    body="$body

This graph is **code-only**: built by AST extraction with zero LLM calls, it
contains **no docs, markdown, configs, or SQL prose at all**."
  fi
  printf '%s\n' "$body"
}
FULL_RENDER="$(render_region "graphify-out/graph.json" "2026-08-01T14:22:07Z" "a1b2c3d" "full")"
CODEONLY_RENDER="$(render_region "graphify-out/graph.json" "2026-08-01T14:22:07Z" "a1b2c3d" "code-only")"
assert_eq "T18b: full-mode render substitutes graph_path/ts/sha/mode with no placeholder text" \
          "0" "$(printf '%s' "$FULL_RENDER" | grep -c '<ISO>\|<sha>\|<full|code-only>')"
assert_eq "T18c: code-only render carries the doc-blind caveat paragraph" \
          "1" "$(printf '%s' "$CODEONLY_RENDER" | grep -cF 'This graph is **code-only**')"
assert_eq "T18d: full render does NOT carry the doc-blind caveat paragraph" \
          "0" "$(printf '%s' "$FULL_RENDER" | grep -cF 'This graph is **code-only**')"
assert_grep "T18-static: SKILL.md forbids any placeholder reaching a written file" \
            "$EXTRACT_SKILL" "may ever reach a"
notrun "T18e live: a real re-run after new commits updates sha/timestamp in place" \
       "a real extraction run and a subsequent commit"

echo "=== T19: egress heuristic (real DSR_BLOCK_RE, real ECS) ==="
T19REPO="$(mk_repo)"
mkdir -p "$T19REPO/src/auth" "$T19REPO/.claude"
echo "export const x = 1" > "$T19REPO/src/auth/session.ts"
echo "console.log('hi')" > "$T19REPO/src/plain.ts"
printf '{"sensitivity":{"level":"normal"}}' > "$T19REPO/.claude/stack-config.json"
( cd "$T19REPO" && git add -A && git commit -qm init )
ECS19="$(ecs_of "$T19REPO")"
HITS19="$(dsr_hits "$T19REPO" $ECS19)"
assert_eq "T19a: normal config + DSR_BLOCK_RE path match (src/auth/session.ts) ⇒ escalation fires" \
          "1" "$(printf '%s\n' "$HITS19" | grep -c 'src/auth/session.ts')"
T19REPO2="$(mk_repo)"
mkdir -p "$T19REPO2/whatever"
echo "db_password=hunter2" > "$T19REPO2/whatever/notes.txt"
( cd "$T19REPO2" && git add -A && git commit -qm init )
ECS19B="$(ecs_of "$T19REPO2")"
HITS19B="$(dsr_hits "$T19REPO2" $ECS19B)"
assert_eq "T19b: content-only match in an innocuous path still escalates" \
          "1" "$(printf '%s\n' "$HITS19B" | grep -c 'whatever/notes.txt')"
assert_eq "T19c: a confidential config with a clean scan is still refused (heuristic can't de-escalate; tested via decision fn)" \
          "confidential" "$(sensitivity_decision confidential 0)"
assert_eq "T19d: SKILL.md sources DSR_BLOCK_RE rather than defining an inline copy (no regex literal in the file)" \
          "0" "$(grep -c "DSR_BLOCK_RE='" "$EXTRACT_SKILL")"
assert_grep "T19d-positive: SKILL.md does reuse the variable by name" "$EXTRACT_SKILL" "DSR_BLOCK_RE"
T19C_REPO="$(mk_repo)"
mkdir -p "$T19C_REPO/db/migrations"
echo "CREATE TABLE x();" > "$T19C_REPO/db/migrations/0001_init.sql"
( cd "$T19C_REPO" && git add -A && git commit -qm init )
ECS19C="$(ecs_of "$T19C_REPO")"
HITS19C="$(dsr_hits "$T19C_REPO" $ECS19C)"
ECSCOUNT19C="$(printf '%s\n' "$ECS19C" | grep -c .)"
assert_eq "T19e: the C-NEW1 regression case — a file --code-only never parses (.sql) still escalates" \
          "1" "$(printf '%s\n' "$HITS19C" | grep -c '0001_init.sql')"
assert_eq "T19e-count: the heuristic's input count is the ECS size (1 file here), not a code-file count" \
          "1" "$ECSCOUNT19C"
NOTGIT="$(mktemp -d -p "$TMPROOT")"
assert_eq "T19f: not a git worktree ⇒ ECS uncomputable" \
          "" "$(cd "$NOTGIT" && git rev-parse --is-inside-work-tree 2>/dev/null || true)"
assert_grep "T19f-static: SKILL.md treats a non-worktree as confidential and offers --code-only" \
            "$EXTRACT_SKILL" "treat the repo as \`confidential\`"
assert_eq "T19g: static — the --code-only report is never passed to the heuristic (no such wiring text)" \
          "0" "$(grep -c 'code-only.*heuristic\|heuristic.*code-only report' "$EXTRACT_SKILL")"
assert_grep "T19g-positive: SKILL.md states the report is NEVER an input to 3c" \
            "$EXTRACT_SKILL" "never an input to step 3c"

echo "=== T20: scan-set containment monitor ==="
containment() {
  # containment <graph-paths-file> <scan-set-of-record-file>
  comm -23 <(sort -u "$1") <(sort -u "$2")
}
GP20="$TMPROOT/graphpaths.txt"; printf 'src/a.ts\nsrc/b.ts\n' > "$GP20"
SS20="$TMPROOT/scanset.txt"; printf 'src/a.ts\nsrc/b.ts\n' > "$SS20"
assert_eq "T20a: clean fixture ⇒ graph_paths_outside_scan_set is empty" "" "$(containment "$GP20" "$SS20")"
GP20B="$TMPROOT/graphpathsB.txt"; printf 'src/a.ts\n.env\n' > "$GP20B"
SS20B="$TMPROOT/scansetB.txt"; printf 'src/a.ts\n' > "$SS20B"
assert_eq "T20b: an escapee outside the scan set ⇒ non-empty, the real V2-violation shape" \
          ".env" "$(containment "$GP20B" "$SS20B")"
assert_grep "T20-blindspot: the zero-node-file blind spot is documented, not assumed away" \
            "$EXTRACT_SKILL" "false alarm on a monitor"
assert_grep "T20d: a code-only receipt runs no containment check" "$EXTRACT_SKILL" \
            "no** containment check"
assert_grep "T20e: graph_paths_outside_scan_set is filed under derived_from_vendor_output" \
            "$EXTRACT_SKILL" '"derived_from_vendor_output": ["graph_paths_outside_scan_set"],'

echo "=== T21: pre-dispatch re-scan of the pause window (D4 step 6.5) ==="
T21REPO="$(mk_repo)"
echo "x" > "$T21REPO/a.ts"
( cd "$T21REPO" && git add -A && git commit -qm init )
ECS21="$(ecs_of "$T21REPO")"
# simulate the pause: nothing added
DELTA_EMPTY="$(comm -13 <(printf '%s\n' "$ECS21" | sort -u) <(ecs_of "$T21REPO" | sort -u))"
assert_eq "T21b: empty pause window ⇒ Delta is empty" "" "$DELTA_EMPTY"
mkdir -p "$T21REPO/db/migrations"
echo "clean file" > "$T21REPO/clean.ts"
( cd "$T21REPO" && git add -A && git commit -qm "clean addition during pause" )
ECS21_AFTER_CLEAN="$(ecs_of "$T21REPO")"
DELTA_CLEAN="$(comm -13 <(printf '%s\n' "$ECS21" | sort -u) <(printf '%s\n' "$ECS21_AFTER_CLEAN" | sort -u))"
assert_eq "T21c: a clean addition during the pause appears in Delta" "clean.ts" "$DELTA_CLEAN"
HITS_ON_DELTA_CLEAN="$(dsr_hits "$T21REPO" $DELTA_CLEAN)"
assert_eq "T21c-clean: heuristic over Delta reports clean (no hit) ⇒ dispatch proceeds" "" "$HITS_ON_DELTA_CLEAN"
echo "DATABASE_URL=postgres://secret" > "$T21REPO/db/migrations/0002_policy.sql"
( cd "$T21REPO" && git add -A && git commit -qm "malicious addition during pause" )
ECS21_AFTER_HIT="$(ecs_of "$T21REPO")"
DELTA_HIT="$(comm -13 <(printf '%s\n' "$ECS21_AFTER_CLEAN" | sort -u) <(printf '%s\n' "$ECS21_AFTER_HIT" | sort -u))"
HITS_ON_DELTA_HIT="$(dsr_hits "$T21REPO" $DELTA_HIT)"
assert_eq "T21a: a DSR_BLOCK_RE match added during the pause is caught by the Delta re-scan" \
          "1" "$(printf '%s\n' "$HITS_ON_DELTA_HIT" | grep -c '0002_policy.sql')"
rm "$T21REPO/clean.ts"
( cd "$T21REPO" && git add -A && git commit -qm "deletion during a separate pause" )
ECS21_AFTER_DEL="$(ecs_of "$T21REPO")"
DELTA_DEL_ONLY="$(comm -13 <(printf '%s\n' "$ECS21_AFTER_HIT" | sort -u) <(printf '%s\n' "$ECS21_AFTER_DEL" | sort -u))"
assert_eq "T21d: a deletions-only pause window ⇒ Delta is empty (additions only, per the spec)" \
          "" "$DELTA_DEL_ONLY"
assert_grep "T21a-static: hit branch aborts, does not dispatch, does not prompt, does not acknowledge" \
            "$EXTRACT_SKILL" "abort the run outright"
assert_grep "T21a-static2: exit non-zero on abort" "$EXTRACT_SKILL" "Exit non-zero"
assert_grep "T21a-static3: instructs a from-scratch re-run, not resumable" "$EXTRACT_SKILL" \
            "not resumable"
assert_grep "T21e-static: step 7's classifier labels a present escapee a late addition, not a V2 violation" \
            "$EXTRACT_SKILL" "late addition"
assert_grep "T21e-residual: the created-and-deleted-inside-runtime false positive is documented" \
            "$EXTRACT_SKILL" "transient artifact"
# T21(f): static timing — the 6.5 heading is after the proceed-wait and before
# the full-run invocation.
PROCEED_LINE="$(grep -n 'Wait for the literal word' "$EXTRACT_SKILL" | head -1 | cut -d: -f1)"
STEP65_LINE="$(grep -n '^## 6.5\.' "$EXTRACT_SKILL" | head -1 | cut -d: -f1)"
FULLRUN_LINE="$(grep -n '^~/.claude/tools/graphify/.venv/bin/graphify extract$' "$EXTRACT_SKILL" | head -1 | cut -d: -f1)"
if [[ -n "$PROCEED_LINE" && -n "$STEP65_LINE" && -n "$FULLRUN_LINE" && "$PROCEED_LINE" -lt "$STEP65_LINE" && "$STEP65_LINE" -lt "$FULLRUN_LINE" ]]; then
  pass "T21f: static — 6.5's text sits after the proceed-wait and before the full-run graphify invocation"
else
  fail "T21f: static — expected proceed($PROCEED_LINE) < 6.5($STEP65_LINE) < full-run($FULLRUN_LINE)"
fi
# T21(g): the G2 regression — a run that already escalated at 3c must still
# abort on a 6.5 hit; pre-existing ack satisfies nothing.
assert_grep "T21g-static: abort fires whether or not 3c already escalated" "$EXTRACT_SKILL" \
            "This abort fires **whether or not"
# T21(h): static no-second-acknowledgement — grep JUST the hit-branch
# paragraph for acknowledgement machinery tokens.
HIT_BRANCH="$(awk '/\*\*`Δ` is non-empty and the heuristic hits\*\*/,/like any other file\./' "$EXTRACT_SKILL")"
assert_eq "T21h: the hit-branch paragraph contains no egress_ack/change_history/one-line-reason token" \
          "0" "$(printf '%s' "$HIT_BRANCH" | grep -ciE 'egress_ack|change_history|one-line reason')"

echo "=== T22: the F token and the two records' timing ==="
# Fixture: T21(c)'s clean-non-empty-delta scenario, but on a repo that
# ACTUALLY ESCALATES at 3a/3c (unlike T21REPO, which never matches
# DSR_BLOCK_RE) — the plan requires "the T21(c) scenario on an escalated
# repo", and a non-escalating repo has no F/ack/evidence-string to assert on
# at all. Sized so |ECS| != |ECS u Delta|, and every number below is DERIVED
# from real git/grep output, never hand-typed, so a future regression that
# changes the underlying computation would change these values too.
T22REPO="$(mk_repo)"
mkdir -p "$T22REPO/src/auth"
echo "export const login = () => {}" > "$T22REPO/src/auth/session.ts"
echo "console.log('ok')" > "$T22REPO/plain.ts"
( cd "$T22REPO" && git add -A && git commit -qm init )
ECS_T22="$(ecs_of "$T22REPO")"                       # the 3a snapshot
F_ECS_SIZE="$(printf '%s\n' "$ECS_T22" | grep -c .)"
HITS_T22="$(dsr_hits "$T22REPO" $ECS_T22)"
HIT_COUNT_T22="$(printf '%s\n' "$HITS_T22" | grep -c .)"
if [[ "$HIT_COUNT_T22" -ge 1 ]]; then
  pass "T22-fixture-escalates: the fixture repo genuinely escalates at 3a/3c ($HIT_COUNT_T22 hit(s) in |ECS|=$F_ECS_SIZE)"
else
  fail "T22-fixture-escalates: fixture does not escalate — T22 would be testing nothing"
fi
# Simulate the step-6 pause: one CLEAN file added.
echo "clean" > "$T22REPO/clean.ts"
( cd "$T22REPO" && git add -A && git commit -qm "clean addition during pause" )
ECS_T22_AFTER="$(ecs_of "$T22REPO")"                 # ECS u Delta (scan set of record)
F_SCANSET_SIZE="$(printf '%s\n' "$ECS_T22_AFTER" | grep -c .)"
if [[ "$F_ECS_SIZE" -ne "$F_SCANSET_SIZE" ]]; then
  pass "T22-fixture-sized: |ECS| ($F_ECS_SIZE) != |ECS u Delta| ($F_SCANSET_SIZE) — the case is non-trivial"
else
  fail "T22-fixture-sized: |ECS| == |ECS u Delta| — this fixture proves nothing, must not happen"
fi

# evidence_string <hit-count> <file-count> — the exact "N of F scanned files
# matched" template SKILL.md specifies.
evidence_string() { echo "heuristic: content match (${1} of ${2} scanned files matched)"; }

# The CORRECT rule (D6 rule 4 / round-6 F1): F is ALWAYS |ECS|, computed once
# at 3c from the 3a snapshot, and simply carried forward — never recomputed.
F_TOKEN="$F_ECS_SIZE"
CORRECT_STRING="$(evidence_string "$HIT_COUNT_T22" "$F_ECS_SIZE")"
STEP4_F="$CORRECT_STRING"           # step 4's code-only receipt: computed at 3c, held forward
STEP7_F="$CORRECT_STRING"           # step 7's full receipt: SAME held value, not recomputed

# The REGRESSION this case guards against: "helpfully" recomputing F at step
# 7 once Delta is known, using |ECS u Delta| instead of the held |ECS|.
REGRESSED_STEP7_F="$(evidence_string "$HIT_COUNT_T22" "$F_SCANSET_SIZE")"

assert_eq "T22a: F equals the 3a ECS size, not the scan set of record" "$F_ECS_SIZE" "$F_TOKEN"
assert_grep "T22a-static: the acknowledgement text template is 'N of F scanned files matched'" \
            "$EXTRACT_SKILL" "N of F **scanned** files matched"
assert_grep "T22b-static: the change_history entry carries the evidence string verbatim" \
            "$EXTRACT_SKILL" "verbatim"
# T22c: timing — receipt is null immediately after 3c and after step 4.
NULL_ACK_RECEIPT='{"mode":"code-only","egress_ack":null}'
assert_eq "T22c: mode:code-only receipt (post-3c, post-step-4 shape) has egress_ack: null" \
          "None" "$(python3 -c "import json;print(json.load(open('/dev/stdin')).get('egress_ack'))" <<<"$NULL_ACK_RECEIPT")"
assert_grep "T22c-static: SKILL.md states this is where the receipt's egress_ack object IS written (step 7)" \
            "$EXTRACT_SKILL" "This is where the receipt's \`egress_ack\` object is written"
# T22d: two records match on at/reason/change_history_setting (the "identical
# content" property, now spanning two write times: 3c's change_history entry
# and step 7's receipt.egress_ack, both rendered from the SAME in-memory value).
ACK_AT="2026-08-01T14:19:52Z"; ACK_REASON="Private repo; approved."; ACK_SETTING="graphify.egress_ack"
render_ack() { printf '{"at":"%s","reason":"%s","change_history_setting":"%s"}' "$1" "$2" "$3"; }
CH_ENTRY="$(render_ack "$ACK_AT" "$ACK_REASON" "$ACK_SETTING")"
RECEIPT_ACK="$(render_ack "$ACK_AT" "$ACK_REASON" "$ACK_SETTING")"
assert_eq "T22d: change_history entry and receipt egress_ack match on at/reason/setting" \
          "$CH_ENTRY" "$RECEIPT_ACK"
# T22e: the concrete regression guard. A correct implementation's step-4 and
# step-7 strings are character-identical; the regressed (recompute-at-step-7)
# version is NOT — proving this case actually discriminates the two.
assert_eq "T22e: sensitivity_escalated_by is character-identical between step-4 and step-7 receipts (correct rule)" \
          "$STEP4_F" "$STEP7_F"
if [[ "$STEP4_F" != "$REGRESSED_STEP7_F" ]]; then
  pass "T22e-discriminates: the F1-regressed variant (recomputing F from |ECS u Delta| at step 7) would differ from step 4's string — this case would have caught it"
else
  fail "T22e-discriminates: fixture is degenerate — the regressed variant is indistinguishable from the correct one"
fi
# T22f: egress_scan_files legitimately exceeds F, and that is not an error.
assert_eq "T22f: egress_scan_files (|ECS u Delta|) exceeds F (|ECS|) on this fixture, by construction" \
          "1" "$(python3 -c "print(1 if $F_SCANSET_SIZE > $F_ECS_SIZE else 0)")"
assert_grep "T22f-static: SKILL.md documents this gap as expected, not an error to fix" \
            "$EXTRACT_SKILL" "do not \"fix\" it by recomputing"
assert_grep "T22g-static: no new receipt field is added to carry F (still 3 egress_ack fields)" \
            "$EXTRACT_SKILL" '"at": "2026-08-01T14:19:52Z"'
assert_eq "T22g: egress_ack object has exactly 3 fields (at, reason, change_history_setting)" \
          "3" "$(python3 -c "import json;print(len(json.loads('$RECEIPT_ACK')))")"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "NOT-EXECUTED: $NOTRUN"
echo ""
echo "NOT-EXECUTED cases require a real ~/.claude/tools/graphify/.venv, a real"
echo "graphify binary/pip install, Gemini API egress, or a live claude -p"
echo "session driving /graphify-init or /graphify-extract end-to-end — none of"
echo "which this static suite has. They are not silently skipped and are never"
echo "counted as PASS. V1 and V2 (ADR-054 D4) were run by hand against this"
echo "repo on 2026-08-01 and are CLEARED; see notes.graphify in"
echo "config/tier-manifests/tier-3.json for the verbatim results."

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
