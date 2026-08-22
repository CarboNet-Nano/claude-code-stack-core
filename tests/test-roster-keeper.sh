#!/usr/bin/env bash
# Tests for scripts/roster-keeper.sh phases 2-3 (stack ADR-079, spec
# 2026-08-15-roster-keeper-design.md §5.3, decision 8 scope: stamp,
# validate, pull with stamp-at-read, run, attribute --human, pending,
# gaps + the R3 blind adjudication). The gmn_call transport is stubbed via
# ROSTER_KEEPER_GEMINI_LIB — a fake lib whose behavior each test controls
# with FAKE_GMN_MODE (agree | disagree:<agent> | unavailable) and whose
# received payloads land in FAKE_GMN_PAYLOAD_LOG for the blindness proofs.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RK="$REPO_ROOT/scripts/roster-keeper.sh"
MAP="$REPO_ROOT/config/roster-ownership.json"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$RK" ] || { echo "FATAL: $RK not found"; echo "test-roster-keeper: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/roster-keeper-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---- fixtures ---------------------------------------------------------

# finding <id> <mechanism> <surface|null> <source> -> one finding-record line
finding() {
  jq -cn --arg id "$1" --arg mech "$2" --arg surf "$3" --arg src "$4" '
    {schema:"finding-record/v1", finding_id:$id, identity_key:("k-"+$id),
     run_id:"2026-08-15T00:00:00Z.t01", repo:"fixture-repo",
     created_at:"2026-08-15T00:00:00Z",
     what:("defect "+$id), plain:"plain sentence", mechanism:$mech,
     surface:(if $surf=="null" then null else $surf end),
     surface_source:(if $surf=="null" then "unset" else "check" end),
     found_by:"sweep-family-A",
     evidence:{commit:null, locus:null,
               measurement:{statement:"s", count:1, denominator:1, source:$src}},
     liveness:{assertions_executed:1, assertions_passed:0},
     responsible_agent:null, roster_action:null}'
}

# a repo dir with findings under .claude/sweep/
mkrepo() {
  local r="$TMP/$1"; mkdir -p "$r/.claude/sweep"
  ( cd "$r" && git init -q -b main )
  echo "$r"
}

# fake gemini lib: behavior via FAKE_GMN_MODE, payload log via FAKE_GMN_PAYLOAD_LOG
FAKE_GMN="$TMP/fake-gemini-api.sh"
cat > "$FAKE_GMN" <<'EOF'
gmn_available() { [[ "${FAKE_GMN_MODE:-agree}" != "unavailable" ]]; }
gmn_call() {
  local ctx; ctx="$(cat 2>/dev/null || true)"
  [[ -n "${FAKE_GMN_PAYLOAD_LOG:-}" ]] && printf '%s\n---PROMPT---\n%s\n---END---\n' "$ctx" "$1" >> "$FAKE_GMN_PAYLOAD_LOG"
  case "${FAKE_GMN_MODE:-agree}" in
    unavailable) return 1 ;;
    disagree:*) echo "${FAKE_GMN_MODE#disagree:}" ;;
    echo:*) echo "${FAKE_GMN_MODE#echo:}" ;;
    agree) echo "${FAKE_GMN_AGREE_WITH:?FAKE_GMN_AGREE_WITH must be set for agree mode}" ;;
  esac
}
EOF

# env -u CI: the suite simulates an operator machine — on GitHub Actions
# the ambient CI=true would otherwise make every pull/adjudicate/run case
# hit decision 3's refusal instead of the behaviour under test. The two
# refusal cases opt back in via run_rk_in_ci.
run_rk() { env -u CI ROSTER_KEEPER_GEMINI_LIB="$FAKE_GMN" bash "$RK" "$@"; }
run_rk_in_ci() { env CI=1 ROSTER_KEEPER_GEMINI_LIB="$FAKE_GMN" bash "$RK" "$@"; }

# ---- stamp ------------------------------------------------------------

R1="$(mkrepo r1)"
F1="$R1/.claude/sweep/findings.jsonl"
A1="$R1/.claude/sweep/attributions.jsonl"
{ finding f001 "MISSING GUARD" "write-path" "static-source"
  finding f002 "DISCONNECTED" "read-path" "static-source"
  finding f003 "CONTRACT DRIFT" "schema" "static-source"
  finding f004 "WRONG VALUE" "null" "static-source"
} > "$F1"

run_rk stamp "$F1" --map "$MAP" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "stamp: exits 0 on a clean findings file" || fail "stamp: nonzero on clean file"
[[ -f "$A1" ]] && pass "stamp: writes the sibling attributions.jsonl" || fail "stamp: no attributions file"

N_STAMPED="$(jq -s '[.[] | select(.stage=="stamped")] | length' "$A1" 2>/dev/null)"
[[ "$N_STAMPED" == "4" ]] && pass "stamp: one stamped record per finding" || fail "stamp: expected 4 stamped, got $N_STAMPED"

C1="$(jq -s -r '[.[] | select(.finding_id=="f001")][0].responsible_agent_candidates | join(",")' "$A1")"
[[ "$C1" == "reviewer,red-team" ]] && pass "stamp: wildcard-surface cell candidates applied (MISSING GUARD x *)" \
  || fail "stamp: f001 candidates wrong: $C1"
C2="$(jq -s -r '[.[] | select(.finding_id=="f002")][0].responsible_agent_candidates | length' "$A1")"
[[ "$C2" == "0" ]] && pass "stamp: known-gap cell stamps empty candidates (DISCONNECTED)" || fail "stamp: f002 candidates: $C2"
C3="$(jq -s -r '[.[] | select(.finding_id=="f003")][0].responsible_agent_candidates | join(",")' "$A1")"
[[ "$C3" == "data-engineer" ]] && pass "stamp: exact-surface cell beats wildcard (CONTRACT DRIFT x schema)" \
  || fail "stamp: f003 candidates: $C3"
U4="$(jq -s -r '[.[] | select(.finding_id=="f004")][0] | "\(.responsible_agent_candidates|length):\(.surface_source)"' "$A1")"
[[ "$U4" == "0:unset" ]] && pass "stamp: unset surface stamps [] candidates + surface_source unset, never inferred" \
  || fail "stamp: f004: $U4"
# RD5 seam: a finding whose surface_source is the Sweep's "declared"
# spelling stamps as attribution-record's "check".
RD5="$(mkrepo rd5)"; FRD5="$RD5/.claude/sweep/findings.jsonl"
finding rd51 "WRONG VALUE" "read-path" "static-source" | jq -c '.surface_source="declared"' > "$FRD5"
run_rk stamp "$FRD5" --map "$MAP" >/dev/null 2>&1
SS5="$(jq -s -r '.[0].surface_source' "$RD5/.claude/sweep/attributions.jsonl")"
[[ "$SS5" == "check" ]] && pass "stamp: RD5 seam — finding surface_source declared stamps as check" \
  || fail "stamp: declared did not translate to check: $SS5"

V1="$(jq -s -r '.[0].ownership_map_version' "$A1")"
[[ "$V1" == "1" ]] && pass "stamp: records the ownership map version" || fail "stamp: map version: $V1"

run_rk stamp "$F1" --map "$MAP" >/dev/null 2>&1
N_AFTER="$(jq -s 'length' "$A1")"
[[ "$N_AFTER" == "4" ]] && pass "stamp: idempotent on finding_id (second run appends nothing)" \
  || fail "stamp: second run changed row count to $N_AFTER"

BADMAP="$TMP/bad-map.json"; echo "{not json" > "$BADMAP"
run_rk stamp "$F1" --map "$BADMAP" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "stamp: unparseable map exits 2 (fail-closed)" || fail "stamp: bad map did not exit 2"

# ---- the §0.3 distribution proof over the 29 seeds --------------------
# Stamping the 29 (mechanism,surface) pairs from the audit must reproduce
# the map's shape ±0: the known-gap mechanisms (DISCONNECTED 8, WRONG
# SCOPE 2, NEVER RAN x scheduled-job 2) stamp empty candidate sets.
R29="$(mkrepo r29)"
F29="$R29/.claude/sweep/findings.jsonl"
seed29() { # id mech surf
  finding "$1" "$2" "$3" "static-source"
}
{ seed29 s01 "WRONG SCOPE" "read-path";      seed29 s02 "DISCONNECTED" "write-path"
  seed29 s03 "MISSING GUARD" "docs";          seed29 s04 "DISCONNECTED" "write-path"
  seed29 s05 "DISCONNECTED" "read-path";      seed29 s06 "WRONG VALUE" "read-path"
  seed29 s07 "DISCONNECTED" "write-path";     seed29 s08 "CONTRACT DRIFT" "schema"
  seed29 s09 "MISSING GUARD" "write-path";    seed29 s10 "CONTRACT DRIFT" "ui-route"
  seed29 s11 "CONTRACT DRIFT" "schema";       seed29 s12 "MISSING GUARD" "write-path"
  seed29 s13 "MISSING GUARD" "write-path";    seed29 s14 "MISSING GUARD" "write-path"
  seed29 s15 "MISSING GUARD" "write-path";    seed29 s16 "MISSING GUARD" "write-path"
  seed29 s17 "WRONG SCOPE" "ui-route";        seed29 s18 "DATA STATE" "scale"
  seed29 s19 "DISCONNECTED" "ci-gate";        seed29 s20 "DISCONNECTED" "scheduled-job"
  seed29 s21 "NEVER RAN" "ci-gate";           seed29 s22 "NEVER RAN" "ci-gate"
  seed29 s23 "DISCONNECTED" "external-integration"; seed29 s24 "CONTRACT DRIFT" "schema"
  seed29 s25 "NEVER RAN" "scheduled-job";     seed29 s26 "WRONG VALUE" "read-path"
  seed29 s27 "CONTRACT DRIFT" "schema";       seed29 s28 "CONTRACT DRIFT" "schema"
  seed29 s29 "WRONG VALUE" "write-path"
} > "$F29"
run_rk stamp "$F29" --map "$MAP" >/dev/null 2>&1
A29="$R29/.claude/sweep/attributions.jsonl"
TOTAL29="$(jq -s 'length' "$A29" 2>/dev/null)"
EMPTY29="$(jq -s '[.[] | select(.responsible_agent_candidates == [])] | length' "$A29" 2>/dev/null)"
[[ "$TOTAL29" == "29" ]] && pass "distribution: 29 stamped" || fail "distribution: stamped $TOTAL29"
# Hand-computed for THIS fixture (cell granularity, the map's own key):
# DISCONNECTED rows s02/04/05/07/19/20/23 (7) + WRONG SCOPE s01/s17 (2)
# + NEVER RAN x scheduled-job s25 (1) + CONTRACT DRIFT x ui-route s10 (1,
# audit row #10 — the cell §0.3 uses to argue two keys) = 11. The proof is
# ±0 against this hand count, which is what validates the SCRIPT (risk 6).
[[ "$EMPTY29" == "11" ]] && pass "distribution: 11/29 stamp empty candidates — matches the hand-computed cell-level gap ±0" \
  || fail "distribution: empty-candidate count $EMPTY29 (want 11)"

# ---- validate ---------------------------------------------------------

VREC="$TMP/rec.json"
mkrec() { jq -cn "$1" > "$VREC"; }

mkrec '{schema:"attribution-record/v1", finding_id:"f1", repo:"r", stage:"stamped", seq:1,
  created_at:"2026-08-15T00:00:00Z", responsible_agent_candidates:["reviewer"],
  ownership_map_version:1, cell_provisional:false, surface_source:"check"}'
run_rk validate "$VREC" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "validate: a clean stamped record passes" || fail "validate: clean stamped record rejected"

mkrec '{schema:"attribution-record/v1", finding_id:"f1", repo:"r", stage:"attributed", seq:2,
  created_at:"2026-08-15T00:00:00Z", responsible_agent_candidates:[],
  ownership_map_version:1, cell_provisional:false, surface_source:"check",
  responsible_agent:"roster-keeper", attributed_by:"roster-keeper", attribution_route:"normal",
  roster_action:"new-check", roster_action_ref:"sweep:A1"}'
run_rk validate "$VREC" >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "validate: R2 — responsible_agent roster-keeper is invalid" || fail "validate: R2 not enforced"

mkrec '{schema:"attribution-record/v1", finding_id:"f1", repo:"r", stage:"attributed", seq:2,
  created_at:"2026-08-15T00:00:00Z", responsible_agent_candidates:[],
  ownership_map_version:1, cell_provisional:false, surface_source:"check",
  responsible_agent:"none", none_reason:null, attributed_by:"human", attribution_route:"normal",
  roster_action:"new-check", roster_action_ref:"sweep:A1"}'
run_rk validate "$VREC" >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "validate: none without none_reason is invalid" || fail "validate: none_reason rule not enforced"

mkrec '{schema:"attribution-record/v1", finding_id:"f1", repo:"r", stage:"attributed", seq:2,
  created_at:"2026-08-15T00:00:00Z", responsible_agent_candidates:[],
  ownership_map_version:1, cell_provisional:false, surface_source:"check",
  responsible_agent:"none", none_reason:"unowned", attributed_by:"human", attribution_route:"normal",
  roster_action:"none", roster_action_ref:null}'
run_rk validate "$VREC" >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "validate: none + roster_action none is invalid (an unowned class demands an answer)" \
  || fail "validate: none/none accepted"

mkrec '{schema:"attribution-record/v1", finding_id:"f1", repo:"r", stage:"attributed", seq:2,
  created_at:"2026-08-15T00:00:00Z", responsible_agent_candidates:["validator"],
  ownership_map_version:1, cell_provisional:false, surface_source:"check",
  responsible_agent:"validator", attributed_by:"human", attribution_route:"normal",
  roster_action:"prompt-change", roster_action_ref:"agents/validator.md"}'
run_rk validate "$VREC" --measurement-source production-data >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "validate: production-data fence — prompt-change is schema-invalid" \
  || fail "validate: production-data fence not enforced"

run_rk validate "$TMP/does-not-exist.json" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "validate: unreadable input exits 2 and callers treat it as failure" \
  || fail "validate: missing file did not exit 2"

# ---- pull -------------------------------------------------------------

ROOTS="$TMP/roots"; mkdir -p "$ROOTS"
RP="$ROOTS/prod-a"; mkdir -p "$RP/.claude/sweep"; ( cd "$RP" && git init -q -b main )
finding p001 "WRONG VALUE" "read-path" "static-source" > "$RP/.claude/sweep/findings.jsonl"

run_rk_in_ci pull --roots "$ROOTS" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "pull: refuses under CI (exit 2)" || fail "pull: ran under CI"

EMPTY_ROOTS="$TMP/empty-roots"; mkdir -p "$EMPTY_ROOTS"
run_rk pull --roots "$EMPTY_ROOTS" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "pull: zero repos discovered exits 2" || fail "pull: zero-repo run did not exit 2"

PULL_OUT="$(run_rk pull --roots "$ROOTS" 2>&1)"; PULL_RC=$?
[[ $PULL_RC -eq 0 ]] && pass "pull: clean run exits 0" || fail "pull: clean run rc=$PULL_RC ($PULL_OUT)"
printf '%s' "$PULL_OUT" | grep -q "repos_discovered=1" && pass "pull: prints repos_discovered" || fail "pull: counters missing: $PULL_OUT"
# stamp-at-read: the CI-written findings file (never touched by a local session)
# now has a stamped attribution record, written by pull alone (seam RD4).
NP="$(jq -s '[.[] | select(.stage=="stamped")] | length' "$RP/.claude/sweep/attributions.jsonl" 2>/dev/null)"
[[ "$NP" == "1" ]] && pass "pull: stamp-at-read stamped the CI-written findings file" || fail "pull: no stamp from pull ($NP)"

# ---- attribute --human (cohort-zero replay via --from) ----------------

ANS="$TMP/answers.jsonl"
jq -cn '{finding_id:"f001", responsible_agent:"reviewer", roster_action:"prompt-change",
         roster_action_ref:"agents/reviewer.md", note:"quotable sentence exists", attributed_by:"human"}' > "$ANS"
jq -cn '{finding_id:"f002", responsible_agent:"none", none_reason:"unowned", roster_action:"new-check",
         roster_action_ref:"sweep:A1", note:"no owner", attributed_by:"human"}' >> "$ANS"

run_rk attribute --human --findings "$F1" --from "$ANS" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "attribute --human --from: replay of recorded human answers succeeds" || fail "attribute --from failed"
NA="$(jq -s '[.[] | select(.stage=="attributed" and .attributed_by=="human")] | length' "$A1")"
[[ "$NA" == "2" ]] && pass "attribute: writes attributed-stage records with attributed_by human" || fail "attribute: rows $NA"
SEQ="$(jq -s -r '[.[] | select(.finding_id=="f001")] | sort_by(.seq) | last | .seq' "$A1")"
[[ "$SEQ" == "2" ]] && pass "attribute: appends a complete new record with bumped seq (never a patch)" || fail "attribute: seq $SEQ"

( run_rk attribute --human --findings "$F1" </dev/null >/dev/null 2>&1 )
[[ $? -eq 2 ]] && pass "attribute --human: refuses to run non-interactively without --from" \
  || fail "attribute: non-interactive run without --from accepted"

# ---- adjudicate (R3 blind pass) ---------------------------------------

PLOG="$TMP/payloads.log"; : > "$PLOG"
FAKE_GMN_MODE=agree FAKE_GMN_AGREE_WITH=reviewer FAKE_GMN_PAYLOAD_LOG="$PLOG" \
  run_rk adjudicate --findings "$F1" --map "$MAP" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "adjudicate: agreeing blind pass exits 0" || fail "adjudicate: agree run failed"
NADJ="$(jq -s '[.[] | select(.stage=="adjudicated" and .finding_id=="f001")] | length' "$A1")"
[[ "$NADJ" == "1" ]] && pass "adjudicate: writes an adjudicated-stage record" || fail "adjudicate: rows $NADJ"
BLIND="$(jq -s -r '[.[] | select(.stage=="adjudicated" and .finding_id=="f001")][0] | "\(.adjudication_blind):\(.attributed_by)"' "$A1")"
[[ "$BLIND" == "true:cross-family:gemini" ]] && pass "adjudicate: marks adjudication_blind true and attributed_by cross-family (R1)" || fail "adjudicate: blind/provenance=$BLIND"
grep -q "reviewer,red-team\|reviewer" "$PLOG" && true
if grep -q "prompt-change\|quotable sentence exists" "$PLOG"; then
  fail "adjudicate: BLINDNESS LEAK — the payload contains the first answer's fields"
else
  pass "adjudicate: payload never contains the first pass's answer (blind, red-team #12)"
fi

# disagreement -> R4: none / disagreement / new-check, disagreement recorded
R2D="$(mkrepo r2d)"; F2D="$R2D/.claude/sweep/findings.jsonl"; A2D="$R2D/.claude/sweep/attributions.jsonl"
finding d001 "MISSING GUARD" "write-path" "static-source" > "$F2D"
run_rk stamp "$F2D" --map "$MAP" >/dev/null 2>&1
jq -cn '{finding_id:"d001", responsible_agent:"reviewer", roster_action:"prompt-change",
         roster_action_ref:"agents/reviewer.md", note:"n", attributed_by:"human"}' > "$TMP/d-ans.jsonl"
run_rk attribute --human --findings "$F2D" --from "$TMP/d-ans.jsonl" >/dev/null 2>&1
FAKE_GMN_MODE=disagree:red-team run_rk adjudicate --findings "$F2D" --map "$MAP" >/dev/null 2>&1
DREC="$(jq -s '[.[] | select(.stage=="adjudicated" and .finding_id=="d001")][0]' "$A2D")"
[[ "$(jq -r '.responsible_agent' <<<"$DREC")" == "none" ]] \
  && [[ "$(jq -r '.none_reason' <<<"$DREC")" == "disagreement" ]] \
  && [[ "$(jq -r '.roster_action' <<<"$DREC")" == "new-check" ]] \
  && [[ "$(jq -r '.disagreement.agent' <<<"$DREC")" == "red-team" ]] \
  && pass "adjudicate: disagreement resolves by R4 (none/disagreement/new-check, both answers recorded)" \
  || fail "adjudicate: R4 resolution wrong: $DREC"

# Off-ballot human pick (cross-family-required): the blind ballot widens
# to the FULL roster, so an adjudicator that genuinely agrees CAN say so.
R4B="$(mkrepo r4b)"; F4B="$R4B/.claude/sweep/findings.jsonl"; A4B="$R4B/.claude/sweep/attributions.jsonl"
finding ob01 "DISCONNECTED" "read-path" "static-source" > "$F4B"
run_rk stamp "$F4B" --map "$MAP" >/dev/null 2>&1
jq -cn '{finding_id:"ob01", responsible_agent:"tester", roster_action:"prompt-change",
         roster_action_ref:"agents/tester.md", note:"n", attributed_by:"human"}' > "$TMP/ob-ans.jsonl"
run_rk attribute --human --findings "$F4B" --from "$TMP/ob-ans.jsonl" >/dev/null 2>&1
RT4B="$(jq -s -r '[.[] | select(.stage=="attributed")][0].attribution_route' "$A4B")"
[[ "$RT4B" == "cross-family-required" ]] && pass "attribute: off-ballot pick routes cross-family-required" \
  || fail "attribute: off-ballot route: $RT4B"
OBLOG="$TMP/ob-payload.log"; : > "$OBLOG"
FAKE_GMN_MODE=echo:tester FAKE_GMN_PAYLOAD_LOG="$OBLOG" run_rk adjudicate --findings "$F4B" --map "$MAP" >/dev/null 2>&1
OBREC="$(jq -s '[.[] | select(.stage=="adjudicated")][0]' "$A4B")"
[[ "$(jq -r '.responsible_agent' <<<"$OBREC")" == "tester" && "$(jq -r '.disagreement' <<<"$OBREC")" == "null" ]] \
  && pass "adjudicate: full-roster ballot lets a genuine agreement on an off-ballot pick stand" \
  || fail "adjudicate: off-ballot agreement mangled: $OBREC"
grep -q '"tester"' "$OBLOG" && grep -q '"architect"' "$OBLOG" \
  && pass "adjudicate: cross-family-required ballot contains the full roster (not just cell candidates)" \
  || fail "adjudicate: full roster missing from ballot payload"

# unavailable -> HELD, nothing written
R3H="$(mkrepo r3h)"; F3H="$R3H/.claude/sweep/findings.jsonl"; A3H="$R3H/.claude/sweep/attributions.jsonl"
finding h001 "WRONG VALUE" "read-path" "static-source" > "$F3H"
run_rk stamp "$F3H" --map "$MAP" >/dev/null 2>&1
jq -cn '{finding_id:"h001", responsible_agent:"validator", roster_action:"none",
         roster_action_ref:null, note:"n", attributed_by:"human"}' > "$TMP/h-ans.jsonl"
run_rk attribute --human --findings "$F3H" --from "$TMP/h-ans.jsonl" >/dev/null 2>&1
HOUT="$(FAKE_GMN_MODE=unavailable run_rk adjudicate --findings "$F3H" --map "$MAP" 2>&1)"; HRC=$?
[[ $HRC -ne 0 ]] && printf '%s' "$HOUT" | grep -qi "held" \
  && pass "adjudicate: gmn unavailable -> record HELD, never downgraded to a Claude-only opinion" \
  || fail "adjudicate: unavailable handling (rc=$HRC out=$HOUT)"
NH="$(jq -s '[.[] | select(.stage=="adjudicated")] | length' "$A3H")"
[[ "$NH" == "0" ]] && pass "adjudicate: HELD writes no adjudicated record" || fail "adjudicate: held wrote $NH"

# ---- pending / gaps ---------------------------------------------------

PEND="$(run_rk pending --findings "$F29" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$PEND" == "29" ]] && pass "pending: emits findings with no attributed record" || fail "pending: $PEND (want 29)"

GAPS_OUT="$(run_rk gaps --findings "$F2D" 2>&1)"
printf '%s' "$GAPS_OUT" | grep -q "records_examined=" && pass "gaps: prints records_examined (non-vacuity)" \
  || fail "gaps: no records_examined: $GAPS_OUT"
printf '%s' "$GAPS_OUT" | grep -q "disagreement" && pass "gaps: none_reason split includes disagreement (unowned kept separate)" \
  || fail "gaps: no none_reason split: $GAPS_OUT"

# ---- run --------------------------------------------------------------

run_rk_in_ci run --roots "$ROOTS" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "run: refuses under CI" || fail "run: ran under CI"
RUN_OUT="$(run_rk run --roots "$ROOTS" 2>&1)"; RRC=$?
[[ $RRC -eq 0 ]] && printf '%s' "$RUN_OUT" | grep -q "repos_discovered=1" \
  && pass "run: ad-hoc whole pass works and prints the pull counters" \
  || fail "run: rc=$RRC out=$RUN_OUT"

echo "test-roster-keeper: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
exit 0
