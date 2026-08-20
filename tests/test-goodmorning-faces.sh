#!/usr/bin/env bash
# Static prose/structure assertions for ADR-084 (one boot skill, two faces —
# /carbonet becomes a promoted mode alias of /goodmorning).
#
# Every case here reads the REAL, committed repo files directly (same
# pattern as tests/test-bookend-docs.sh) — there is no HOME/repo fixture to
# build, because these are properties of skills/goodmorning/SKILL.md and
# config/aliases.json as shipped, not properties of a generated run.
#
# These are the "grepping a prompt proves nothing" half of D9's own
# argument — they catch a deleted clause instantly and cost nothing, but
# they do NOT prove a live model obeys any of it. That is
# tests/test-plain-face-live.sh's job (L1-L9, opt-in RUN_LIVE_FACE_TESTS=1).
#
# Case-to-plan map (architect-handoff.md "New — tests/test-goodmorning-
# faces.sh (static)" section, exact ids): K1-K9.
#
# Expected to FAIL until skills/goodmorning/SKILL.md gains its `## Display
# modes` section, 7P renderer, steps 6r/6s, the Access: line, and
# config/aliases.json + capability-registry.json + skills/carbonet/ reflect
# the migration (ADR-084's implementer side, files-to-touch "Part 2").

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOODMORNING_SKILL="$REPO_ROOT/skills/goodmorning/SKILL.md"
ALIASES_JSON="$REPO_ROOT/config/aliases.json"
CAP_REGISTRY="$REPO_ROOT/config/capability-registry.json"
SNAPSHOT="$REPO_ROOT/tests/fixtures/carbonet-capability-registry-snapshot.json"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not found — this suite cannot run"; exit 1; }

if [[ ! -f "$GOODMORNING_SKILL" ]]; then
  fail "skills/goodmorning/SKILL.md does not exist — every K case below is a hard FAIL, not a skip"
  echo ""
  echo "test-goodmorning-faces: $PASS passed, $FAIL failed"
  exit 1
fi

GM_RAW="$(cat "$GOODMORNING_SKILL")"
# Markdown-stripped, whitespace-collapsed copy for verbatim-clause matching —
# tolerates line-wrap and **bold**/`code` markup differences without
# tolerating actual content drift.
GM_FLAT="$(sed -E 's/\*\*//g; s/`//g' "$GOODMORNING_SKILL" | tr '\n\t' '  ' | tr -s ' ')"

has() { [[ "$GM_RAW" == *"$1"* ]]; }        # has <literal-substring>
has_flat() { [[ "$GM_FLAT" == *"$1"* ]]; }  # has_flat <literal-substring, markdown-stripped>
count_of() { grep -o -F -- "$1" "$GOODMORNING_SKILL" 2>/dev/null | wc -l | tr -d ' '; }

# ═══════════════════════════════════════════════════════════════════════
# K1 — `## Display modes` declares exactly `dev` and `plain`
# ═══════════════════════════════════════════════════════════════════════
if grep -q '^## Display modes' "$GOODMORNING_SKILL"; then
  pass "K1: '## Display modes' heading exists"
  DM_SECTION="$(awk '/^## Display modes/{f=1;next} /^## /{if(f)exit} f' "$GOODMORNING_SKILL")"
  DM_FLAT="$(tr '\n\t' '  ' <<<"$DM_SECTION" | tr -s ' ')"
  if grep -qE '`dev`|\bdev\b' <<<"$DM_SECTION" && grep -qE '`plain`|\bplain\b' <<<"$DM_SECTION"; then
    pass "K1: section names both dev and plain"
  else
    fail "K1: section does not clearly name both dev and plain modes"
  fi
  if grep -qi 'no third mode' <<<"$DM_FLAT"; then
    pass "K1: section states 'No third mode' (D1) — the exactly-two-modes closure"
  else
    fail "K1: section is missing the 'No third mode' closure (D1) — cannot prove 'exactly' two modes"
  fi
else
  fail "K1: '## Display modes' heading missing"
fi

# ═══════════════════════════════════════════════════════════════════════
# K2 — Step 6c's exception, then 7P's positive allowlist naming exactly
# six items in D4's order, "nothing else" (except 6c)
# ═══════════════════════════════════════════════════════════════════════
# Resolution (commit f33bab4, 2026-08-17 — "resolve plain face's 6c
# self-update contradiction", review blocker 5): the six-item list, the
# step table, and the rationale text used to disagree about whether Step
# 6c (stack self-update) runs on the plain face — the allowlist omitted
# it, the table said it "acts," the rationale said readiness runs "after
# 6c on both faces." Bill's decision: 6c always runs, first, on BOTH
# faces — an employee's stack must never go stale with no way to fix it —
# but on `plain` it is SILENT (no line, success or failure). The six
# items stay exhaustive of everything the face PRINTS; 6c is named as the
# one stated exception before them.
#
# A K2 that only checked the six-item list (the version that shipped
# before this fix) stayed green through the ENTIRE contradiction, because
# the six-item list itself never changed — the disagreement was between
# the list, the table, and the rationale, and nothing compared them. K2f
# below is the check that would have caught it: it asserts the table's 6c
# cell and the allowlist's own 6c exception statement do not contradict
# each other, so a future edit that reintroduces a mismatch (e.g. the
# table says 6c is silent but the prose starts promising a `Stack:`-style
# line on `plain`, or vice versa) fails here instead of staying invisible.

# K2a — the 6c exception statement exists, BEFORE the six-item list.
K2_6C_LINE="$(grep -n 'Step 6c' "$GOODMORNING_SKILL" | head -1 | cut -d: -f1)"
K2_SIX_TRIGGER_LINE="$(grep -niE 'exactly these six things|these six things.*nothing else' "$GOODMORNING_SKILL" | head -1 | cut -d: -f1)"
if [[ -n "$K2_6C_LINE" && -n "$K2_SIX_TRIGGER_LINE" && "$K2_6C_LINE" -lt "$K2_SIX_TRIGGER_LINE" ]]; then
  pass "K2a: Step 6c is named BEFORE the six-item allowlist"
else
  fail "K2a: Step 6c exception statement missing, or not positioned before the six-item list (6c line=$K2_6C_LINE, six-trigger line=$K2_SIX_TRIGGER_LINE)"
fi
# K2b — it says 6c runs on BOTH faces, first, always.
if has_flat 'always runs first' && has_flat 'both faces'; then
  pass "K2b: states Step 6c always runs first on both faces"
else
  fail "K2b: missing 'always runs first ... both faces' for Step 6c"
fi
# K2c — it says 6c is silent on plain (no line, success or failure).
if has_flat 'silent' && has_flat 'never adds a line'; then
  pass "K2c: states Step 6c is silent on the plain face (no line either way)"
else
  fail "K2c: missing the 'silent ... never adds a line' statement for Step 6c on plain"
fi

# K2d — the six items themselves, unchanged, same order.
K2_EXPECTED=(banner readiness since queue cost "suggested move")
if [[ -n "$K2_SIX_TRIGGER_LINE" ]]; then
  pass "K2d: found the six-item allowlist trigger line ('exactly these six things ... nothing else')"
  WINDOW="$(sed -n "${K2_SIX_TRIGGER_LINE},$((K2_SIX_TRIGGER_LINE+12))p" "$GOODMORNING_SKILL")"
  ORDER_OK=1
  LAST_LINE=0
  for item in "${K2_EXPECTED[@]}"; do
    LN="$(grep -niE "^[[:space:]]*[0-9]+[.)][[:space:]]*${item}" <<<"$WINDOW" | head -1 | cut -d: -f1)"
    if [[ -z "$LN" ]]; then
      fail "K2d: item '$item' not found as a numbered list entry in the allowlist window"
      ORDER_OK=0
    elif (( LN <= LAST_LINE )); then
      fail "K2d: item '$item' is out of D4's order (expected after the previous item)"
      ORDER_OK=0
    else
      pass "K2d: item '$item' present and in order"
      LAST_LINE=$LN
    fi
  done
  [[ "$ORDER_OK" == "1" ]] && pass "K2d: all six items present, in D4's order, unchanged by the 6c fix" || fail "K2d: allowlist order/completeness violated (see individual item failures above)"
  # A 7th numbered item immediately after item 6 would mean the list is not
  # closed at six.
  if grep -qE '^[[:space:]]*7[.)]' <<<"$WINDOW"; then
    fail "K2d: a 7th numbered item appears in the allowlist window — list is not closed at six"
  else
    pass "K2d: no 7th numbered item in the allowlist window"
  fi
else
  fail "K2d: six-item allowlist trigger line ('exactly these six things ... nothing else') not found at all"
fi

# K2e — the closing line, exact new wording (the "except Step 6c above"
# clause is what changed; the bare pre-fix wording is what silently
# passed through the contradiction).
if grep -qF 'No other step in this file runs in `plain` mode, except Step 6c above.' "$GOODMORNING_SKILL"; then
  pass "K2e: closing line is exactly 'No other step in this file runs in \`plain\` mode, except Step 6c above.'"
else
  fail "K2e: closing line missing or does not match exactly (want: 'No other step in this file runs in \`plain\` mode, except Step 6c above.')"
fi

# K2f — the table's 6c cell and the allowlist prose do NOT contradict each
# other. This is the check that would have caught the original bug: the
# table cell must itself say 6c is silent/acts-only (never "run" with a
# printed-line verdict the way `dev`'s cell does), matching K2c's prose
# assertion above. A table cell that regresses to something like "run —
# Stack: line" on `plain` while the prose above still says "silent" is
# exactly the shape of the original contradiction, and would be invisible
# to K2a-K2e alone (they only look at the prose, never at the table).
K2F_6C_ROW="$(awk -F'|' '{
  f2=$2; gsub(/^[ \t]+|[ \t]+$/, "", f2); gsub(/[`*]/, "", f2);
  if (f2 == "6c") print $0
}' "$GOODMORNING_SKILL")"
if [[ -z "$K2F_6C_ROW" ]]; then
  fail "K2f: could not find the 6c row in the step/face mapping table at all"
else
  K2F_PLAIN_CELL="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}' <<<"$K2F_6C_ROW")"
  if grep -qi 'silent' <<<"$K2F_PLAIN_CELL"; then
    pass "K2f: the table's 6c/plain cell says 'silent', agreeing with the allowlist prose (K2c) — no contradiction"
  else
    fail "K2f: the table's 6c/plain cell ('$K2F_PLAIN_CELL') does not say 'silent' — this is the exact class of table/prose contradiction the original bug was"
  fi
  if grep -qi '\brun\b' <<<"$K2F_PLAIN_CELL" && ! grep -qi 'act' <<<"$K2F_PLAIN_CELL"; then
    fail "K2f: the table's 6c/plain cell reads as a full 'run' verdict (like a step that prints its own labelled line), not 'act' — contradicts 6c being silent on plain"
  else
    pass "K2f: the table's 6c/plain cell is NOT phrased as a plain 'run' verdict — consistent with 'act, silently'"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# K3 — each of ADR-084 D5's thirteen clauses present verbatim
# ═══════════════════════════════════════════════════════════════════════
# Each check asserts the LOAD-BEARING literal content of the clause (the
# actual values that must not drift character-by-character) rather than the
# ADR's own connective prose, which the implementer is free to restate as
# documentation — matching the precedent in test-bookend-docs.sh (checks
# specific substrings copied from ADR text, not whole paragraphs).
check_clause() {  # check_clause <clause-number> <label> <token1> [token2] [token3]
  # Matched against GM_FLAT (markdown-stripped, whitespace-collapsed) since
  # these clauses wrap across multiple source lines at ~80 chars — matching
  # raw text would false-fail on a mid-phrase line break, not a content
  # regression.
  local n="$1" label="$2"; shift 2
  local ok=1
  for tok in "$@"; do
    has_flat "$tok" || { ok=0; fail "K3.$n ($label): missing verbatim token: '$tok'"; }
  done
  [[ "$ok" == "1" ]] && pass "K3.$n ($label): all verbatim tokens present"
}
check_clause 1  "byte-verbatim, nothing added"        "byte-verbatim" "org-check.sh" "nothing added"
check_clause 2  "fixed unavailable line + hard stop"  "carbonet check unavailable — ask your admin."
grep -qiE 'hard[- ]stop' "$GOODMORNING_SKILL" && pass "K3.2b: 'hard-stop'/'hard stop' wording present" || fail "K3.2b: missing hard-stop wording"
check_clause 3  "budget ≤26 / ≤10"                    "26 line" "10"
check_clause 4  "banned words list"                   "rebase, cherry-pick, HEAD, upstream, refspec, squash, stash, worktree, SHA"
has_flat 'as a noun' && pass "K3.4b: 'commit\" as a noun' banned-word clause present" || fail "K3.4b: missing '\"commit\" as a noun' clause"
check_clause 5  "pull request #164, never PR #164"    "pull request #164" "PR #164"
check_clause 6  "and N more small changes"            "and N more small changes" "counts.more_commits"
check_clause 7  "Since you were last here header"     "Since you were last here (<local weekday> <time>):"
check_clause 8  "omit W3 when none, never unknown"     "last_session_end_source" "since an unknown time"
has_flat 'unlabelled fence' && pass "K3.9: 'one unlabelled fence' clause present" || fail "K3.9: missing 'one unlabelled fence' clause"
check_clause 10 "never cost/queue unknown"             "cost: unknown" "queue: unknown"
check_clause 11 "commits/prs external content"         "commits[].subject" "prs_merged[].title" "external content"
check_clause 12 "translation is the skill's own model" "no subagent" "no API call" "no cost"
check_clause 13 "human phrasing example"               "Terms review finished" "feat(terms): add provider clearance table"

# ═══════════════════════════════════════════════════════════════════════
# K4 — every step id appears exactly once in the table with both verdicts
# ═══════════════════════════════════════════════════════════════════════
STEP_IDS=(0 1 1b 2 3 4 5 6 6c 6r 6d 6e 6e-2 6f 6i 6j 6k 6l 6m-a 6m-b 6n 6o 6p 6q 6c-bis 6s 7 7P 8)
TABLE="$(awk '/^\| *Step *\|/{f=1} f{print} /^$/{if(f && NR>1) exit}' "$GOODMORNING_SKILL")"
if [[ -z "$TABLE" ]]; then
  fail "K4: no step/face mapping table (header row '| Step | ... |') found"
else
  pass "K4: found the step/face mapping table"
  K4_ALL_OK=1
  for sid in "${STEP_IDS[@]}"; do
    # first column, exact match after trimming spaces/backticks/bold markers.
    # NOTE: gsub() on a field forces awk to rebuild $0 from OFS (a single
    # space), which would destroy the '|' delimiters in the printed row --
    # so the trimmed copy is held in a local var and $0 is printed untouched.
    ROWS="$(awk -F'|' -v want="$sid" '{
      f2=$2; gsub(/^[ \t]+|[ \t]+$/, "", f2); gsub(/[`*]/, "", f2);
      if (f2 == want) print $0
    }' <<<"$TABLE")"
    N="$(grep -c . <<<"$ROWS" 2>/dev/null || echo 0)"
    [[ -z "$ROWS" ]] && N=0
    if [[ "$N" != "1" ]]; then
      fail "K4: step '$sid' appears $N time(s) in the table (want exactly 1)"
      K4_ALL_OK=0
      continue
    fi
    # columns: | Step | What | dev | plain |  -> $3 dev, $4 plain (1-indexed with leading empty field)
    DEV_CELL="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}' <<<"$ROWS")"
    PLAIN_CELL="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}' <<<"$ROWS")"
    if [[ -z "$DEV_CELL" || -z "$PLAIN_CELL" ]]; then
      fail "K4: step '$sid' row has an empty dev or plain verdict cell"
      K4_ALL_OK=0
    fi
  done
  [[ "$K4_ALL_OK" == "1" ]] && pass "K4: all ${#STEP_IDS[@]} step ids appear exactly once with both verdicts populated" \
    || fail "K4: one or more step ids failed the exactly-once/both-verdicts check (see above)"
fi

# ═══════════════════════════════════════════════════════════════════════
# K5 — 6d and 6e are `skip` for `plain`
# ═══════════════════════════════════════════════════════════════════════
check_plain_skip() {  # check_plain_skip <step-id>
  local sid="$1"
  local row
  row="$(awk -F'|' -v want="$sid" '{
    f2=$2; gsub(/^[ \t]+|[ \t]+$/, "", f2); gsub(/[`*]/, "", f2);
    if (f2 == want) print $0
  }' <<<"$TABLE")"
  if [[ -z "$row" ]]; then
    fail "K5: step '$sid' row not found in the table"
    return
  fi
  local plain_cell
  plain_cell="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}' <<<"$row")"
  if grep -qi '^skip' <<<"$plain_cell"; then
    pass "K5: step '$sid' plain verdict is 'skip'"
  else
    fail "K5: step '$sid' plain verdict is '$plain_cell', expected 'skip'"
  fi
}
check_plain_skip "6d"
check_plain_skip "6e"

# ═══════════════════════════════════════════════════════════════════════
# K6 — the ADR-072 D4 prohibition present exactly once
# ═══════════════════════════════════════════════════════════════════════
if has "--task" && has "gh issue view"; then
  N_D4="$(count_of "gh issue view")"
  [[ "$N_D4" == "1" ]] && pass "K6: ADR-072 D4 hard prohibition ('gh issue view') appears exactly once (no duplicate copy left over from the merge)" \
    || fail "K6: ADR-072 D4 hard prohibition appears $N_D4 time(s), want exactly 1"
else
  fail "K6: ADR-072 D4 hard prohibition (--task / gh issue view) not found at all"
fi

# ═══════════════════════════════════════════════════════════════════════
# K7 — the `Access:` line documented as dev-only and failure-only
# ═══════════════════════════════════════════════════════════════════════
if has "Access:" && has "run /carbonet"; then
  pass "K7: 'Access: <N> problem(s) — run /carbonet' line documented"
else
  fail "K7: the D6 Access: line is not documented"
fi
if has_flat "omit entirely" || has_flat "same fail-open"; then
  pass "K7: the Access: line is documented as failure-only (omit entirely / fail-open on healthy)"
else
  fail "K7: missing the failure-only (omit-on-healthy) documentation for the Access: line"
fi

# ═══════════════════════════════════════════════════════════════════════
# K8 — skills/carbonet/ no longer exists; config/aliases.json declares it
# ═══════════════════════════════════════════════════════════════════════
if [[ -d "$REPO_ROOT/skills/carbonet" ]]; then
  fail "K8: skills/carbonet/ still exists — D7 requires it deleted from the repo"
else
  pass "K8: skills/carbonet/ no longer exists in the repo"
fi
if [[ -f "$ALIASES_JSON" ]] && jq -e '.aliases.carbonet' "$ALIASES_JSON" >/dev/null 2>&1; then
  CB="$(jq -c '.aliases.carbonet' "$ALIASES_JSON")"
  TARGET="$(jq -r '.target // empty' <<<"$CB")"
  MODE="$(jq -r '.mode // empty' <<<"$CB")"
  HELP="$(jq -r '.help // empty' <<<"$CB")"
  DESC="$(jq -r '.description // empty' <<<"$CB")"
  [[ "$TARGET" == "goodmorning" ]] && pass "K8: config/aliases.json carbonet.target == goodmorning" \
    || fail "K8: config/aliases.json carbonet.target == '$TARGET', want goodmorning"
  [[ "$MODE" == "plain" ]] && pass "K8: config/aliases.json carbonet.mode == plain" \
    || fail "K8: config/aliases.json carbonet.mode == '$MODE', want plain"
  [[ "$HELP" == "row" ]] && pass "K8: config/aliases.json carbonet.help == row (promoted alias)" \
    || fail "K8: config/aliases.json carbonet.help == '$HELP', want row"
  EXPECT_DESC="Check that everything is ready before you start working — that you're signed in, that your access is granted, that the stack is up to date, and that this folder is set up. Prints a plain-English ✅/❌ list with a fix for anything that's wrong, plus what changed since you were last here and a suggested first move, and never shows a key or password. Use at the start of a session, when something stops working, or when you're not sure whether your setup is right."
  [[ "$DESC" == "$EXPECT_DESC" ]] && pass "K8: carbonet.description is byte-identical to skills/carbonet/SKILL.md's original description (D7)" \
    || fail "K8: carbonet.description does not match the original SKILL.md description byte-for-byte"
else
  fail "K8: config/aliases.json declares no 'carbonet' entry"
fi

# ═══════════════════════════════════════════════════════════════════════
# K9 — carbonet registry entry matches a committed pre-change snapshot
#      (the byte-identity migration proof, D7)
# ═══════════════════════════════════════════════════════════════════════
if [[ ! -f "$SNAPSHOT" ]]; then
  fail "K9: snapshot fixture tests/fixtures/carbonet-capability-registry-snapshot.json is missing"
elif [[ ! -f "$CAP_REGISTRY" ]]; then
  fail "K9: config/capability-registry.json does not exist"
else
  LIVE="$(jq -cS '.capabilities[] | select(.id=="carbonet")' "$CAP_REGISTRY" 2>/dev/null)"
  WANT="$(jq -cS '.' "$SNAPSHOT" 2>/dev/null)"
  if [[ -z "$LIVE" ]]; then
    fail "K9: config/capability-registry.json has no 'carbonet' entry at all"
  elif [[ "$LIVE" == "$WANT" ]]; then
    pass "K9: capability-registry.json's carbonet entry is byte-identical (semantically) to the committed pre-change snapshot"
  else
    fail "K9: capability-registry.json's carbonet entry DIFFERS from the pre-change snapshot"
    echo "  --- snapshot ---"; echo "  $WANT"
    echo "  --- live ------"; echo "  $LIVE"
  fi
fi

echo ""
echo "test-goodmorning-faces: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
