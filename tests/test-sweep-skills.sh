#!/usr/bin/env bash
# Tests for skills/sweep/SKILL.md + skills/walkthrough/SKILL.md (stack
# ADR-078, task 10 of the Sweep serial spine). Structural, grep-able
# assertions only — no LLM (house style: tests/test-sweep-workflows.sh's
# assert_contains/assert_not_contains convention, extended here with
# line-scoped greps for the two negative-instruction checks that a plain
# substring match can't safely express).
#
# Binding contracts asserted here (architect dispatch, task 10):
#   - Both SKILL.md files exist with valid frontmatter (name, description).
#   - /sweep's body references sweep-run.sh and sweep-render.sh, and
#     documents exit 2 as a hard stop, never a flake.
#   - /walkthrough's body references sweep_emit_finding and contains NO
#     instruction to Write/append findings.jsonl directly.
#   - /walkthrough contains no attribution question to the user.
#   - Regression pin (fix round 1, reviewer-verified CRITICAL): a record
#     built by following /walkthrough's documented field recipe
#     literally — not just the fields it happens to mention, all of the
#     schema's required fields — survives the REAL sweep_emit_finding
#     (schema, finding_id, run_id, repo, created_at and what are
#     computed exactly as the recipe says, not hand-waved).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP_SKILL="$REPO_ROOT/skills/sweep/SKILL.md"
WALKTHROUGH_SKILL="$REPO_ROOT/skills/walkthrough/SKILL.md"
SWEEP_EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

[[ -f "$SWEEP_SKILL" ]] || { echo "FATAL: $SWEEP_SKILL not found"; echo "----"; echo "test-sweep-skills: 0 passed, 1 failed"; exit 1; }
[[ -f "$WALKTHROUGH_SKILL" ]] || { echo "FATAL: $WALKTHROUGH_SKILL not found"; echo "----"; echo "test-sweep-skills: 0 passed, 1 failed"; exit 1; }

SWEEP_CONTENT="$(cat "$SWEEP_SKILL")"
WALKTHROUGH_CONTENT="$(cat "$WALKTHROUGH_SKILL")"

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "expected to contain [$needle]"; fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else fail "$name" "expected NOT to contain [$needle]"; fi
}

# frontmatter <file> -> the YAML frontmatter block between the two `---`
# fences, or empty if the file doesn't open with one.
frontmatter() {
  awk 'NR==1 && $0!="---" { exit } NR==1 { f=1; next } f && $0=="---" { exit } f { print }' "$1"
}

# ---------------------------------------------------------------------
# 1. Frontmatter: both files open with a `---` fence carrying non-empty
#    `name:` and `description:` keys.
# ---------------------------------------------------------------------
for pair in "sweep:$SWEEP_SKILL" "walkthrough:$WALKTHROUGH_SKILL"; do
  skillname="${pair%%:*}"
  file="${pair#*:}"
  fm="$(frontmatter "$file")"
  if [[ -z "$fm" ]]; then
    fail "${skillname}-has-frontmatter-fence" "no --- ... --- block at top of $file"
    continue
  fi
  pass "${skillname}-has-frontmatter-fence"
  assert_contains "${skillname}-frontmatter-has-name" "$fm" "name: $skillname"
  NAME_LINE="$(grep -m1 '^name:' <<<"$fm" || true)"
  DESC_LINE="$(grep -m1 '^description:' <<<"$fm" || true)"
  [[ -n "$NAME_LINE" ]] && pass "${skillname}-frontmatter-name-nonblank" || fail "${skillname}-frontmatter-name-nonblank"
  if [[ -n "$DESC_LINE" && "${DESC_LINE#description:}" =~ [^[:space:]] ]]; then
    pass "${skillname}-frontmatter-description-nonblank"
  else
    fail "${skillname}-frontmatter-description-nonblank" "no non-empty description: line"
  fi
done

# ---------------------------------------------------------------------
# 2. /sweep: references sweep-run.sh and sweep-render.sh, documents
#    exit 2 as a hard stop, never a flake.
# ---------------------------------------------------------------------
assert_contains "sweep-references-sweep-run-sh" "$SWEEP_CONTENT" "sweep-run.sh"
assert_contains "sweep-references-sweep-render-sh" "$SWEEP_CONTENT" "sweep-render.sh"
assert_contains "sweep-documents-exit-2" "$SWEEP_CONTENT" "exit code is 2"
assert_contains "sweep-documents-hard-stop" "$SWEEP_CONTENT" "hard stop"
assert_contains "sweep-documents-never-a-flake" "$SWEEP_CONTENT" "never a flake"
assert_contains "sweep-cadence-default-manual" "$SWEEP_CONTENT" "Default: \`manual\`"

# ---------------------------------------------------------------------
# 3. /walkthrough: references sweep_emit_finding, sets the fixed record
#    fields, and contains NO instruction to Write/append findings.jsonl
#    directly. Scoped per-line so the prohibition sentence itself (which
#    names findings.jsonl and the word "never") doesn't false-positive.
# ---------------------------------------------------------------------
assert_contains "walkthrough-references-sweep-emit-finding" "$WALKTHROUGH_CONTENT" "sweep_emit_finding"
assert_contains "walkthrough-documents-only-write-path" "$WALKTHROUGH_CONTENT" "ONLY way to write a finding"
assert_contains "walkthrough-sets-found-by-human-walkthrough" "$WALKTHROUGH_CONTENT" 'found_by: "human-walkthrough"'
assert_contains "walkthrough-sets-surface-null" "$WALKTHROUGH_CONTENT" "surface: null"
assert_contains "walkthrough-sets-surface-source-unset" "$WALKTHROUGH_CONTENT" 'surface_source: "unset"'
assert_contains "walkthrough-g2-wording" "$WALKTHROUGH_CONTENT" "Does every number on this screen match what you expect? Is any column labelled something it is not?"
assert_contains "walkthrough-mcq-free-text-escape" "$WALKTHROUGH_CONTENT" "free-text escape"

DIRECT_WRITE_LINES="$(grep -n "findings.jsonl" "$WALKTHROUGH_SKILL" \
  | grep -E '>>|Write\(|[Ww]rite tool|[Ee]dit tool' \
  | grep -v "sweep_emit_finding" \
  | grep -vi "never\|only\|ONLY" || true)"
if [[ -z "$DIRECT_WRITE_LINES" ]]; then
  pass "walkthrough-no-direct-findings-write-instruction"
else
  fail "walkthrough-no-direct-findings-write-instruction" "$DIRECT_WRITE_LINES"
fi

# ---------------------------------------------------------------------
# 4. /walkthrough: no attribution question posed to the user. Scoped to
#    lines that both ask a question (`?`) and mention attribution/agent
#    vocabulary, excluding the documented prohibition sentence itself.
# ---------------------------------------------------------------------
assert_contains "walkthrough-documents-never-ask-attribution" "$WALKTHROUGH_CONTENT" "NEVER ask the user for attribution"
assert_not_contains "walkthrough-no-literal-who-is-responsible-question" "$WALKTHROUGH_CONTENT" "responsible for this finding?"
assert_not_contains "walkthrough-no-literal-who-owns-question" "$WALKTHROUGH_CONTENT" "who owns this"

ATTRIBUTION_QUESTION_LINES="$(grep -nE '\?' "$WALKTHROUGH_SKILL" \
  | grep -iE 'responsible|attribut|which agent|who (owns|caused)|roster_action' \
  | grep -vi 'never\|do not ask\|NEVER' || true)"
if [[ -z "$ATTRIBUTION_QUESTION_LINES" ]]; then
  pass "walkthrough-no-attribution-question-line"
else
  fail "walkthrough-no-attribution-question-line" "$ATTRIBUTION_QUESTION_LINES"
fi

# ---------------------------------------------------------------------
# 4b. Fix round 2, IMPORTANT: script paths are what the skill's reader
#     types. Both skills quoted `scripts/sweep/...` — repo-relative, which
#     resolves only when the CWD happens to be a checkout of the STACK
#     repo, not the repo being swept. The installed reality is
#     ~/.claude/scripts/sweep/..., which is the house convention already
#     used by skills/foreman/SKILL.md and skills/graphify-extract/SKILL.md.
#     A repo-relative path here is a `No such file or directory` for every
#     reader outside this repo — i.e. the skill never runs.
# ---------------------------------------------------------------------
assert_contains "sweep-uses-installed-script-path" "$SWEEP_CONTENT" "~/.claude/scripts/sweep/sweep-run.sh"
assert_contains "sweep-render-uses-installed-script-path" "$SWEEP_CONTENT" "~/.claude/scripts/sweep/sweep-render.sh"
assert_contains "walkthrough-uses-installed-script-path" "$WALKTHROUGH_CONTENT" "~/.claude/scripts/sweep/lib/sweep-emit.sh"

# No bare repo-relative `scripts/sweep/` left anywhere in either skill:
# blank out every correctly-prefixed occurrence first, then anything still
# matching is a path the reader would type and have fail.
for pair in "sweep:$SWEEP_SKILL" "walkthrough:$WALKTHROUGH_SKILL"; do
  skillname="${pair%%:*}"
  file="${pair#*:}"
  BARE_PATHS="$(sed 's#~/\.claude/scripts/sweep/#@INSTALLED@#g' "$file" | grep -n 'scripts/sweep/' || true)"
  if [[ -z "$BARE_PATHS" ]]; then
    pass "${skillname}-no-bare-repo-relative-scripts-sweep-path"
  else
    fail "${skillname}-no-bare-repo-relative-scripts-sweep-path" "$BARE_PATHS"
  fi
done

# ---------------------------------------------------------------------
# 4c. Fix round 2, IMPORTANT: /walkthrough's empty-locus note used to
#     justify itself as "matching stamp_finding's convention". It does not
#     match it — stamp_finding hashes evidence.locus, and walkthrough
#     records DO set evidence.locus. The empty locus is a deliberate
#     divergence kept for finding_id stability, and the skill must say so,
#     or the next reader "aligns" the two and orphans every disposition.
# ---------------------------------------------------------------------
assert_not_contains "walkthrough-no-false-stamp-finding-convention-claim" \
  "$WALKTHROUGH_CONTENT" "matching \`stamp_finding\`'s convention"
assert_contains "walkthrough-empty-locus-is-documented-as-deliberate" \
  "$WALKTHROUGH_CONTENT" "must stay empty"
assert_contains "walkthrough-empty-locus-note-names-stamp-finding-difference" \
  "$WALKTHROUGH_CONTENT" "hashes \`evidence.locus\`"

# ---------------------------------------------------------------------
# 5. Regression pin: a record built by following /walkthrough's field
#    recipe LITERALLY (scripted transcription of SKILL.md step 4, not a
#    markdown parse) survives the real sweep_emit_finding. This is the
#    exact failure the reviewer caught in fix round 1 — a record built
#    from the field list omitted schema/finding_id/run_id/repo/
#    created_at/what and R7-refused every time.
# ---------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — walkthrough-record-recipe regression pin not run."
elif [[ ! -f "$SWEEP_EMIT_LIB" ]]; then
  fail "walkthrough-record-recipe-survives-sweep-emit-finding" "$SWEEP_EMIT_LIB not found"
else
  # shellcheck source=/dev/null
  source "$SWEEP_EMIT_LIB"

  RECIPE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-recipe.XXXXXX")"
  trap 'rm -rf "$RECIPE_TMP"' EXIT
  RECIPE_FINDINGS="$RECIPE_TMP/findings.jsonl"

  # group_4plus_digits <s> -> step 4's R1 caveat, in pure bash (portable,
  # no GNU-sed dependency): every run of 4+ consecutive digits is broken
  # into groups of 3 joined by a dash, mirroring E1's identityKeyForRoute.
  group_4plus_digits() {
    local s out i n
    s="$1"; out=""; i=0; n=${#s}
    while (( i < n )); do
      if [[ "${s:i}" =~ ^([0-9]{4,}) ]]; then
        local run groups j
        run="${BASH_REMATCH[1]}"; groups=(); j=0
        while (( j < ${#run} )); do groups+=("${run:j:3}"); j=$((j+3)); done
        local joined; joined="$(IFS=-; echo "${groups[*]}")"
        out+="$joined"; i=$((i + ${#run}))
      else
        out+="${s:i:1}"; i=$((i+1))
      fi
    done
    printf '%s' "$out"
  }

  RECIPE_REPO="demo-repo"
  RECIPE_ROUTE="/report/2026"                          # step 4's worked example
  # identity_key: step 4's R1 caveat — group every 4+ digit run into 3s.
  RECIPE_IDENTITY_KEY="$(group_4plus_digits "$RECIPE_ROUTE")"
  RECIPE_MECHANISM="WRONG VALUE"
  # finding_id: step 4's exact recipe — empty locus, G2 check id.
  RECIPE_FINDING_ID="$(sweep_finding_id "$RECIPE_REPO" G2 "$RECIPE_MECHANISM" "" "$RECIPE_IDENTITY_KEY")"
  # run_id: step 4's exact recipe — UTC timestamp + short suffix.
  RECIPE_RUN_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ).$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
  RECIPE_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RECIPE_PLAIN="The report screen shows a number that does not match what the user expects."
  RECIPE_WHAT="A user reported during a walkthrough that a figure on the report screen looked wrong."

  RECIPE_RECORD="$(jq -cn \
    --arg fid "$RECIPE_FINDING_ID" --arg ik "$RECIPE_IDENTITY_KEY" --arg run "$RECIPE_RUN_ID" \
    --arg repo "$RECIPE_REPO" --arg created "$RECIPE_CREATED_AT" --arg what "$RECIPE_WHAT" \
    --arg plain "$RECIPE_PLAIN" --arg mech "$RECIPE_MECHANISM" --arg locus "$RECIPE_ROUTE" '
    {schema:"finding-record/v1", finding_id:$fid, identity_key:$ik, run_id:$run, repo:$repo,
     created_at:$created, what:$what, plain:$plain, mechanism:$mech,
     surface:null, surface_source:"unset", found_by:"human-walkthrough",
     evidence:{locus:$locus, measurement:{statement:"user-reported number mismatch",
       count:1, denominator:1, source:"human"}},
     liveness:{assertions_executed:1, assertions_passed:0},
     responsible_agent:null, roster_action:null}')"

  EMIT_ERR="$RECIPE_TMP/emit.err"
  if sweep_emit_finding "$RECIPE_FINDINGS" "$RECIPE_RECORD" 2>"$EMIT_ERR"; then
    if [[ -f "$RECIPE_FINDINGS" ]] && [[ "$(wc -l < "$RECIPE_FINDINGS" | tr -d ' ')" == "1" ]] \
      && jq -e --arg fid "$RECIPE_FINDING_ID" '.finding_id == $fid' "$RECIPE_FINDINGS" >/dev/null 2>&1; then
      pass "walkthrough-record-recipe-survives-sweep-emit-finding"
    else
      fail "walkthrough-record-recipe-survives-sweep-emit-finding" "emit reported success but findings.jsonl doesn't hold the expected record"
    fi
  else
    fail "walkthrough-record-recipe-survives-sweep-emit-finding" "sweep_emit_finding refused: $(cat "$EMIT_ERR")"
  fi

  # The identity_key grouping itself: /report/2026 must not survive
  # verbatim (R1 would refuse it) — confirm the recipe's grouping
  # actually changed the digit run.
  assert_not_contains "walkthrough-recipe-identity-key-is-grouped-not-raw" "$RECIPE_IDENTITY_KEY" "2026"
fi

echo "----"
echo "test-sweep-skills: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
