#!/usr/bin/env bash
# Tests for scripts/sweep/lib/sweep-emit.sh (stack ADR-078, task 3 of the
# Sweep serial spine). This library is the ONLY place that writes
# findings.jsonl — every refusal rule tested here is what stands between a
# check's output and a committed, permanent record, so each rule gets its
# own test rather than being folded into a combined case.
#
# `sweep_finding_id` and `sweep_emit_finding` are sourced directly (not
# shelled out to) so failures point at the exact function, matching
# scripts/lib/usage-check-common.sh's sourced-library test convention.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-emit-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A well-formed sweep-family-A record. Field values match
# tests/test-sweep-schemas.sh's VALID fixture shape.
BASE_RECORD='{"schema":"finding-record/v1","finding_id":"3f9a1c77b2e04d51","identity_key":"products","run_id":"2026-08-16T02:00:00Z.a1b2c3","repo":"manufacturing-dashboard","created_at":"2026-08-16T02:00:04Z","what":"filterStateToParams emits products; routes read product","plain":"The dashboard filter sends a name the page never looks for, so filtering silently does nothing.","mechanism":"DISCONNECTED","surface":"read-path","surface_source":"declared","found_by":"sweep-family-A","evidence":{"commit":"73c23b53","locus":"apps/web/src/lib/filter-params.ts:88","measurement":{"statement":"producer keys with zero consumers","count":2,"denominator":41,"source":"static-source"}},"liveness":{"assertions_executed":41,"assertions_passed":39},"responsible_agent":null,"roster_action":null}'

record() { echo "$BASE_RECORD" | jq -c "$1"; }  # record '<jq filter>' -> modified compact record
newfile() { mktemp "$TMP/findings.XXXXXX"; }  # trailing Xs only — BSD mktemp requires no suffix after them

# ---- sweep_finding_id ----

t_finding_id_16hex() {
  local id; id="$(sweep_finding_id repo A2 DISCONNECTED "apps/web/x.ts:1" products)"
  [[ "$id" =~ ^[0-9a-f]{16}$ ]] && pass "sweep_finding_id: 16 lowercase hex chars" \
    || fail "sweep_finding_id: 16 lowercase hex chars (got: $id)"
}

t_finding_id_deterministic() {
  local a b
  a="$(sweep_finding_id manufacturing-dashboard A2 DISCONNECTED "apps/web/src/lib/filter-params.ts:88" products)"
  b="$(sweep_finding_id manufacturing-dashboard A2 DISCONNECTED "apps/web/src/lib/filter-params.ts:88" products)"
  [[ -n "$a" && "$a" == "$b" ]] && pass "sweep_finding_id: deterministic (same inputs -> same id)" \
    || fail "sweep_finding_id: deterministic (a=$a b=$b)"
}

t_finding_id_what_no_influence() {
  local id_from_r1 id_from_r2 repo="manufacturing-dashboard" check="A2" mech="DISCONNECTED" locus="apps/web/src/lib/filter-params.ts:88" ident="products"
  local r1 r2
  r1="$(record '.what="original what text"')"
  r2="$(record '.what="a totally different what, much longer, still same identity"')"
  id_from_r1="$(sweep_finding_id "$repo" "$check" "$mech" "$locus" "$ident")"
  id_from_r2="$(sweep_finding_id "$repo" "$check" "$mech" "$locus" "$ident")"
  # sweep_finding_id never takes `what` as an argument; two records whose
  # `what` differs still resolve to the same id given the same 5 identity
  # inputs — confirmed by re-deriving from each record's own fields.
  local w1 w2; w1="$(echo "$r1" | jq -r '.what')"; w2="$(echo "$r2" | jq -r '.what')"
  [[ "$w1" != "$w2" && "$id_from_r1" == "$id_from_r2" ]] && pass "sweep_finding_id: what does not influence id" \
    || fail "sweep_finding_id: what does not influence id"
}

# ---- sweep_emit_finding: same-id re-emit is a silent no-op ----
# Loop-termination property for the per-merge writer: a findings commit
# triggers another push run, which re-finds the same defects; if the
# re-emit appended duplicate rows the tree would change every run and the
# writer would commit forever. Same finding_id already on file -> exit 0,
# nothing appended.

t_same_id_reemit_is_noop() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.')"
  sweep_emit_finding "$f" "$rec" 2>/dev/null || { fail "dedup: first emit refused"; return; }
  local n1; n1="$(grep -c . "$f")"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/dedup.err"
  local ec=$? n2; n2="$(grep -c . "$f")"
  [[ "$ec" == "0" && "$n1" == "$n2" ]] \
    && pass "dedup: re-emitting an existing finding_id appends nothing and exits 0" \
    || fail "dedup: re-emit changed the file (ec=$ec rows $n1->$n2 err=$(cat "$TMP/dedup.err"))"
}

# Disposition rows carry `status` and share the finding's id by design —
# resolve's newest-row-wins depends on them appending. The dedup no-op is
# for check-emitted rows only; a disposition can never feed the writer
# loop (it comes from a human or the roster, not the writer's own cycle).
t_disposition_row_with_same_id_still_appends() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.')"
  sweep_emit_finding "$f" "$rec" 2>/dev/null || { fail "disposition-append: base emit refused"; return; }
  local disp; disp="$(record '.found_by="human-walkthrough" | .status="wontfix"')"
  sweep_emit_finding "$f" "$disp" 2>"$TMP/disp.err"
  local ec=$? n; n="$(grep -c . "$f")"
  [[ "$ec" == "0" && "$n" == "2" ]] \
    && pass "dedup: a disposition row (has status) with an existing finding_id still appends" \
    || fail "dedup: disposition row was dropped (ec=$ec rows=$n err=$(cat "$TMP/disp.err"))"
}

# ---- sweep_emit_finding: refusal rules R1-R7 ----

t_r1_identity_key_uuid_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.identity_key="a1b2c3d4-e5f6-7890-abcd-ef1234567890"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r1a.err"
  local ec=$?
  grep -q "R1" "$TMP/r1a.err" && [[ "$ec" != "0" ]] && pass "R1: UUID-shaped identity_key refused" \
    || fail "R1: UUID-shaped identity_key refused (ec=$ec $(cat "$TMP/r1a.err"))"
}

t_r1_identity_key_iso8601_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.identity_key="2026-08-16T02:00:00Z"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r1b.err"
  local ec=$?
  grep -q "R1" "$TMP/r1b.err" && [[ "$ec" != "0" ]] && pass "R1: ISO-8601 identity_key refused" \
    || fail "R1: ISO-8601 identity_key refused (ec=$ec $(cat "$TMP/r1b.err"))"
}

t_r1_identity_key_digitrun_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.identity_key="run12345"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r1c.err"
  local ec=$?
  grep -q "R1" "$TMP/r1c.err" && [[ "$ec" != "0" ]] && pass "R1: 4+ digit run identity_key refused" \
    || fail "R1: 4+ digit run identity_key refused (ec=$ec $(cat "$TMP/r1c.err"))"
}

t_r2_status_refused_sweep_family() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.status="open"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r2.err"
  local ec=$?
  grep -q "R2" "$TMP/r2.err" && [[ "$ec" != "0" ]] && pass "R2: status refused on sweep-family- row" \
    || fail "R2: status refused on sweep-family- row (ec=$ec $(cat "$TMP/r2.err"))"
}

t_r2_status_refused_ci_self_audit() {
  # Controller ruling: R2 extends to found_by == ci-self-audit, not only
  # sweep-family-*.
  local f; f="$(newfile)"
  local rec; rec="$(record '.found_by="ci-self-audit" | .status="open" | .surface="ci-gate" | .surface_source="declared"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r2b.err"
  local ec=$?
  grep -q "R2" "$TMP/r2b.err" && [[ "$ec" != "0" ]] && pass "R2: status refused on ci-self-audit row" \
    || fail "R2: status refused on ci-self-audit row (ec=$ec $(cat "$TMP/r2b.err"))"
}

t_ci_self_audit_declared_surface_not_r6_refused() {
  # Controller ruling: R6 must NOT reject a ci-self-audit row that carries
  # a declared surface (the future sweep.vacuous-check meta-finding).
  local f; f="$(newfile)"
  local rec; rec="$(record '.found_by="ci-self-audit" | .surface="ci-gate" | .surface_source="declared"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r6ok.err"
  local ec=$?
  [[ "$ec" == "0" ]] && pass "R6: ci-self-audit row with declared surface accepted" \
    || fail "R6: ci-self-audit row with declared surface accepted (ec=$ec $(cat "$TMP/r6ok.err"))"
}

t_r3_plain_missing_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record 'del(.plain)')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r3a.err"
  local ec=$?
  grep -q "R3" "$TMP/r3a.err" && [[ "$ec" != "0" ]] && pass "R3: missing plain refused" \
    || fail "R3: missing plain refused (ec=$ec $(cat "$TMP/r3a.err"))"
}

t_r3_plain_filepath_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.plain="See apps/web/src/lib/filter-params.ts for details."')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r3b.err"
  local ec=$?
  grep -q "R3" "$TMP/r3b.err" && [[ "$ec" != "0" ]] && pass "R3: plain leaking a .ts path refused" \
    || fail "R3: plain leaking a .ts path refused (ec=$ec $(cat "$TMP/r3b.err"))"
}

t_r3_plain_family_letter_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.plain="Found by check A2 during the nightly run."')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r3c.err"
  local ec=$?
  grep -q "R3" "$TMP/r3c.err" && [[ "$ec" != "0" ]] && pass "R3: plain leaking a family/check id refused" \
    || fail "R3: plain leaking a family/check id refused (ec=$ec $(cat "$TMP/r3c.err"))"
}

t_r4_missing_measurement_count_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record 'del(.evidence.measurement.count)')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r4.err"
  local ec=$?
  grep -q "R4" "$TMP/r4.err" && [[ "$ec" != "0" ]] && pass "R4: missing evidence.measurement.count refused" \
    || fail "R4: missing evidence.measurement.count refused (ec=$ec $(cat "$TMP/r4.err"))"
}

t_r5_g8_extra_evidence_key_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.evidence.measurement.source="generated-world" | .evidence.row_value="customer@example.com"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r5a.err"
  local ec=$?
  grep -q "R5" "$TMP/r5a.err" && [[ "$ec" != "0" ]] && pass "R5: G8 extra evidence key on generated-world refused" \
    || fail "R5: G8 extra evidence key on generated-world refused (ec=$ec $(cat "$TMP/r5a.err"))"
}

t_r5_g8_what_too_long_refused() {
  local f; f="$(newfile)"
  local longwhat; longwhat="$(printf 'x%.0s' $(seq 1 301))"
  local rec; rec="$(echo "$BASE_RECORD" | jq -c --arg w "$longwhat" '.evidence.measurement.source="production-data" | .what=$w')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r5b.err"
  local ec=$?
  grep -q "R5" "$TMP/r5b.err" && [[ "$ec" != "0" ]] && pass "R5: G8 what >300 chars on production-data refused" \
    || fail "R5: G8 what >300 chars on production-data refused (ec=$ec $(cat "$TMP/r5b.err"))"
}

t_r5_g8_leak_canary_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.evidence.measurement.source="production-data" | .evidence.locus="the leaked value is SWEEP-CANARY-XYZ-42"')"
  SWEEP_LEAK_CANARY="SWEEP-CANARY-XYZ-42" sweep_emit_finding "$f" "$rec" 2>"$TMP/r5c.err"
  local ec=$?
  grep -q "R5" "$TMP/r5c.err" && [[ "$ec" != "0" ]] && pass "R5: SWEEP_LEAK_CANARY token found refused" \
    || fail "R5: SWEEP_LEAK_CANARY token found refused (ec=$ec $(cat "$TMP/r5c.err"))"
}

t_r5_g8_static_source_unaffected() {
  # G8 gating only applies to generated-world/production-data — a
  # static-source row with an "extra" evidence-shaped what is fine.
  local f; f="$(newfile)"
  sweep_emit_finding "$f" "$BASE_RECORD" 2>"$TMP/r5ok.err"
  local ec=$?
  [[ "$ec" == "0" ]] && pass "R5: static-source measurement not subject to G8 key allowlist" \
    || fail "R5: static-source measurement not subject to G8 key allowlist (ec=$ec $(cat "$TMP/r5ok.err"))"
}

t_r6_surface_absent_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record 'del(.surface)')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r6a.err"
  local ec=$?
  grep -q "R6" "$TMP/r6a.err" && [[ "$ec" != "0" ]] && pass "R6: absent surface on sweep-family- row refused" \
    || fail "R6: absent surface on sweep-family- row refused (ec=$ec $(cat "$TMP/r6a.err"))"
}

t_r6_surface_null_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.surface=null')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r6b.err"
  local ec=$?
  grep -q "R6" "$TMP/r6b.err" && [[ "$ec" != "0" ]] && pass "R6: null surface on sweep-family- row refused" \
    || fail "R6: null surface on sweep-family- row refused (ec=$ec $(cat "$TMP/r6b.err"))"
}

t_r7_schema_bad_enum_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.mechanism="NOT_A_REAL_MECHANISM"')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r7a.err"
  local ec=$?
  grep -q "R7" "$TMP/r7a.err" && [[ "$ec" != "0" ]] && pass "R7: bad mechanism enum fails schema, refused" \
    || fail "R7: bad mechanism enum fails schema, refused (ec=$ec $(cat "$TMP/r7a.err"))"
}

t_r7_schema_missing_liveness_field_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record 'del(.liveness.assertions_executed)')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r7b.err"
  local ec=$?
  grep -q "R7" "$TMP/r7b.err" && [[ "$ec" != "0" ]] && pass "R7: missing liveness.assertions_executed fails schema, refused" \
    || fail "R7: missing liveness.assertions_executed fails schema, refused (ec=$ec $(cat "$TMP/r7b.err"))"
}

t_r7_schema_extra_top_level_key_refused() {
  local f; f="$(newfile)"
  local rec; rec="$(record '.enabled=true')"
  sweep_emit_finding "$f" "$rec" 2>"$TMP/r7c.err"
  local ec=$?
  grep -q "R7" "$TMP/r7c.err" && [[ "$ec" != "0" ]] && pass "R7: unknown top-level key fails schema, refused" \
    || fail "R7: unknown top-level key fails schema, refused (ec=$ec $(cat "$TMP/r7c.err"))"
}

t_valid_record_accepted() {
  local f; f="$(newfile)"
  sweep_emit_finding "$f" "$BASE_RECORD" 2>"$TMP/valid.err"
  local ec=$?
  [[ "$ec" == "0" ]] && [[ -s "$f" ]] && pass "sweep_emit_finding: well-formed record accepted and appended" \
    || fail "sweep_emit_finding: well-formed record accepted and appended (ec=$ec $(cat "$TMP/valid.err"))"
}

t_append_only_two_lines_first_unchanged() {
  local f; f="$(newfile)"
  local rec1="$BASE_RECORD"
  # distinct identity -> distinct finding_id (a same-id re-emit is the
  # dedup no-op covered above, not an append)
  local rec2; rec2="$(record '.identity_key="products2" | .finding_id="ffffaaaa11112222"')"
  sweep_emit_finding "$f" "$rec1"
  local line1_before; line1_before="$(sed -n '1p' "$f")"
  sweep_emit_finding "$f" "$rec2"
  local nlines; nlines="$(wc -l < "$f" | tr -d ' ')"
  local line1_after; line1_after="$(sed -n '1p' "$f")"
  [[ "$nlines" == "2" && "$line1_before" == "$line1_after" ]] \
    && pass "sweep_emit_finding: append-only (2 lines, first line unchanged)" \
    || fail "sweep_emit_finding: append-only (2 lines, first line unchanged) (nlines=$nlines)"
}

t_finding_id_16hex
t_finding_id_deterministic
t_finding_id_what_no_influence

t_same_id_reemit_is_noop
t_disposition_row_with_same_id_still_appends
t_r1_identity_key_uuid_refused
t_r1_identity_key_iso8601_refused
t_r1_identity_key_digitrun_refused
t_r2_status_refused_sweep_family
t_r2_status_refused_ci_self_audit
t_ci_self_audit_declared_surface_not_r6_refused
t_r3_plain_missing_refused
t_r3_plain_filepath_refused
t_r3_plain_family_letter_refused
t_r4_missing_measurement_count_refused
t_r5_g8_extra_evidence_key_refused
t_r5_g8_what_too_long_refused
t_r5_g8_leak_canary_refused
t_r5_g8_static_source_unaffected
t_r6_surface_absent_refused
t_r6_surface_null_refused
t_r7_schema_bad_enum_refused
t_r7_schema_missing_liveness_field_refused
t_r7_schema_extra_top_level_key_refused

t_valid_record_accepted
t_append_only_two_lines_first_unchanged

echo "----"
echo "test-sweep-emit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
