#!/usr/bin/env bash
# tests/test-sweep-portable-drift.sh — tests for
# scripts/sweep/checks/pc1-portable-drift.sh (2026-08-18 new-user-setup-rev2
# plan, task 6 of the Sweep serial spine).
#
# The task-6 brief sketched a `SWEEP_REPO` env var and bare `echo` lines as
# the check's interface. Neither exists: the real contract (verified
# against scripts/sweep/checks/b4-merge-run.sh and scripts/sweep/lib/) is a
# sweep-job/v1 object on stdin and one `SWEEP_RESULT:v1 <base64>` line as
# the LAST line of stdout, decoding to a sweep-result/v1 envelope. This
# file drives the check that way.
#
# Manifest hash format: the check reuses lib/portable-core.sh's
# pc_classify (same classifier the self-heal hook, scripts/audit-repos.sh
# and scripts/stack-sync.sh already use) rather than reimplementing
# manifest lookup — see pc1-portable-drift.sh's own header for why. To
# keep this test independent of the real, ever-changing
# config/portable-core-manifest.json content, it points pc_classify at a
# SYNTHETIC manifest by exporting CLAUDE_PLUGIN_ROOT to a throwaway
# directory before invoking the check — pc_manifest_path() checks
# "$CLAUDE_PLUGIN_ROOT/config/portable-core-manifest.json" before falling
# back to the real one, and pc1-portable-drift.sh does not itself read
# CLAUDE_PLUGIN_ROOT (only lib/portable-core.sh does once sourced), so
# this is a legitimate, unmodified use of the library's own lookup order,
# not a special-cased test hook.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
CHECK="$REPO_ROOT/scripts/sweep/checks/pc1-portable-drift.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-pc1-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- synthetic manifest + fixture repo -------------------------------------
#
# One managed skill (goodmorning/SKILL.md) with a known "current" hash and
# one known "old" hash, computed with the same sha256 command
# lib/portable-core.sh's _pc_sha256 uses.
_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

CURRENT_CONTENT="current content"
OLD_CONTENT="old content"
DIVERGED_CONTENT="hand edited content, never published by the stack"

CURRENT_HASH="sha256:$(printf '%s' "$CURRENT_CONTENT" | _sha256)"
OLD_HASH="sha256:$(printf '%s' "$OLD_CONTENT" | _sha256)"

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/config"
jq -n --arg cur "$CURRENT_HASH" --arg old "$OLD_HASH" '
  {generated_at:"2026-08-18T00:00:00Z", stack_version:"test", source_sha:"deadbeef", source_repo:"test/test",
   files: {"skills/goodmorning/SKILL.md": {current:$cur, known:[$cur,$old], known_count:2}}}' \
  > "$FAKE_HOME/config/portable-core-manifest.json"

mkdir -p "$TMP/repo/.claude/skills/goodmorning" "$TMP/repo/.claude/skills/myskill"
printf '%s' "$CURRENT_CONTENT" > "$TMP/repo/.claude/skills/goodmorning/SKILL.md"
printf '%s\n' "project thing" > "$TMP/repo/.claude/skills/myskill/SKILL.md"   # not portable-core -> never checked

job() {
  jq -nc --arg repo "$TMP/repo" '{schema:"sweep-job/v1", run_id:"test.abcdef", check_id:"PC1",
    repo_root:$repo, cadence:"manual", writes_findings:false, evidence_basis:"static-source",
    surface:"docs", config:{}, changed_paths:null, connection:null, budget_ms:120000}'
}

run_check() {
  CLAUDE_PLUGIN_ROOT="$FAKE_HOME" bash "$CHECK" <<<"$(job)"
}

decode_envelope() {
  grep '^SWEEP_RESULT:v1 ' <<<"$1" | tail -1 | sed 's/^SWEEP_RESULT:v1 //' | base64 -d
}

# --- case 1: current copy -> silent, status pass ----------------------------
OUT1="$(run_check)"; RC1=$?
ENV1="$(decode_envelope "$OUT1")"
[[ $RC1 -eq 0 ]] && ok "check exits 0 on a current copy" || bad "check exits 0 on a current copy (rc=$RC1)"
[[ -n "$(grep -i stale <<<"$OUT1")" ]] && bad "current copy silent (STALE found unexpectedly)" || ok "current copy silent (no STALE)"
[[ -n "$(grep -i diverged <<<"$OUT1")" ]] && bad "current copy silent (DIVERGED found unexpectedly)" || ok "current copy silent (no DIVERGED)"
[[ "$(jq -r '.status' <<<"$ENV1")" == "pass" ]] && ok "envelope status pass on a current copy" || bad "envelope status pass on a current copy (got: $(jq -r '.status' <<<"$ENV1"))"
[[ "$(jq -r '.schema' <<<"$ENV1")" == "sweep-result/v1" ]] && ok "envelope schema is sweep-result/v1" || bad "envelope schema is sweep-result/v1"
[[ "$(jq -r '.check_id' <<<"$ENV1")" == "PC1" ]] && ok "envelope check_id echoes job's PC1" || bad "envelope check_id echoes job's PC1"
[[ "$(jq -r '.surface' <<<"$ENV1")" == "docs" ]] && ok "envelope surface echoes job's surface" || bad "envelope surface echoes job's surface"
[[ "$(jq -r '.evidence_basis' <<<"$ENV1")" == "static-source" ]] && ok "envelope evidence_basis echoes job's basis" || bad "envelope evidence_basis echoes job's basis"
[[ "$(jq -r '.assertions_executed' <<<"$ENV1")" -gt 0 ]] && ok "non-vacuous: assertions_executed > 0" || bad "non-vacuous: assertions_executed > 0"
[[ "$(jq -r '.findings | length' <<<"$ENV1")" == "0" ]] && ok "no findings on a current copy" || bad "no findings on a current copy"

# --- case 2: stale copy (hash in known, not current) -> flagged ------------
printf '%s' "$OLD_CONTENT" > "$TMP/repo/.claude/skills/goodmorning/SKILL.md"
OUT2="$(run_check)"; RC2=$?
ENV2="$(decode_envelope "$OUT2")"
grep -q "STALE" <<<"$OUT2" && ok "stale copy flagged (STALE in output)" || bad "stale copy flagged (STALE in output)"
grep -q "goodmorning" <<<"$OUT2" && ok "stale finding names goodmorning" || bad "stale finding names goodmorning"
# Controller ruling (task-6 review): the escalation clause is the reader's
# only signal that a RECURRING stale finding means the self-heal hook
# itself is broken, not just that one refresh hasn't happened yet. A
# header comment saying so never reaches a reader looking at a finding or
# a run's stdout, so both must carry it verbatim.
ESCALATION="if it persists, the portable-core hook is not running in this repo's profile"
grep -qF "$ESCALATION" <<<"$OUT2" && ok "stale stdout line carries the escalation clause" || bad "stale stdout line carries the escalation clause"
grep -q "myskill" <<<"$OUT2" && bad "project skill (myskill) never flagged" || ok "project skill (myskill) never flagged"
[[ "$(jq -r '.status' <<<"$ENV2")" == "fail" ]] && ok "envelope status fail on a stale copy" || bad "envelope status fail on a stale copy"
[[ "$(jq -r '.findings | length' <<<"$ENV2")" == "1" ]] && ok "exactly one finding for one stale copy" || bad "exactly one finding for one stale copy"
[[ "$(jq -r '.findings[0].mechanism' <<<"$ENV2")" == "CONTRACT DRIFT" ]] && ok "stale finding mechanism is CONTRACT DRIFT" || bad "stale finding mechanism is CONTRACT DRIFT"
[[ "$(jq -r '.findings[0].found_by' <<<"$ENV2")" == "sweep-family-B" ]] && ok "stale finding found_by is sweep-family-B" || bad "stale finding found_by is sweep-family-B"
[[ "$(jq -r '.findings[0].identity_key' <<<"$ENV2")" == "goodmorning/SKILL.md" ]] && ok "stale finding identity_key names the skill file" || bad "stale finding identity_key names the skill file"
[[ "$(jq -r '.findings[0].evidence.locus' <<<"$ENV2")" == ".claude/skills/goodmorning/SKILL.md" ]] && ok "stale finding locus is the vendored copy path" || bad "stale finding locus is the vendored copy path"
[[ "$(jq -r '.findings[0].evidence.measurement.count' <<<"$ENV2")" == "1" ]] && ok "stale finding measurement.count is 1" || bad "stale finding measurement.count is 1"
grep -qF "$ESCALATION" <<<"$(jq -r '.findings[0].what' <<<"$ENV2")" && ok "stale finding's what carries the escalation clause" || bad "stale finding's what carries the escalation clause"
[[ "$(jq -r '.findings[0] | has("status")' <<<"$ENV2")" == "false" ]] && ok "check-emitted finding never carries a status key (R2)" || bad "check-emitted finding never carries a status key (R2)"
grep -qE '\.(ts|tsx|js|mjs|sh|py)\b' <<<"$(jq -r '.findings[0].plain' <<<"$ENV2")" && bad "plain leaks no file extension (R3)" || ok "plain leaks no file extension (R3)"
grep -qE '\bPC1\b' <<<"$(jq -r '.findings[0].plain' <<<"$ENV2")" && bad "plain leaks no check id (R3)" || ok "plain leaks no check id (R3)"

# --- case 3: diverged copy (hash unknown) -> flagged, left alone -----------
printf '%s' "$DIVERGED_CONTENT" > "$TMP/repo/.claude/skills/goodmorning/SKILL.md"
OUT3="$(run_check)"; RC3=$?
ENV3="$(decode_envelope "$OUT3")"
grep -q "DIVERGED" <<<"$OUT3" && ok "diverged copy flagged (DIVERGED in output)" || bad "diverged copy flagged (DIVERGED in output)"
[[ "$(jq -r '.findings[0].mechanism' <<<"$ENV3")" == "CONTRACT DRIFT" ]] && ok "diverged finding mechanism is CONTRACT DRIFT" || bad "diverged finding mechanism is CONTRACT DRIFT"
[[ "$(jq -r '.status' <<<"$ENV3")" == "fail" ]] && ok "envelope status fail on a diverged copy" || bad "envelope status fail on a diverged copy"

# --- schema conformance: run every finding through sweep_emit_finding ------
# The library's own refusal rules (R1-R7) are the real emit contract; a
# finding this check produces must actually survive them, not just look
# plausible by eye.
source "$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"
EMIT_OUT="$TMP/emit-test-findings.jsonl"; : > "$EMIT_OUT"
EMIT_FAIL=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # finding_id is computed by the REAL sweep_finding_id, exactly as the
  # writer does it in production. An earlier version of this test stamped
  # one hardcoded id onto every finding, so sweep_emit_finding's dedup --
  # working correctly -- dropped the second, and the line-count assertion
  # below failed. Reusing the shipped id function makes the ids distinct
  # for the right reason AND puts one more real function under test.
  _mech="$(jq -r '.mechanism' <<<"$f")"
  _loc="$(jq -r '.evidence.locus // .identity_key' <<<"$f")"
  _ident="$(jq -r '.identity_key' <<<"$f")"
  _fid="$(sweep_finding_id "fixture" "PC1" "$_mech" "$_loc" "$_ident")"
  STAMPED="$(jq -c --arg fid "$_fid" --arg run "test.abcdef" --arg repo "fixture" --arg now "2026-08-18T00:00:00Z" \
    '.schema="finding-record/v1" | .finding_id=$fid | .run_id=$run | .repo=$repo | .created_at=$now' <<<"$f")"
  sweep_emit_finding "$EMIT_OUT" "$STAMPED" || EMIT_FAIL=$((EMIT_FAIL+1))
done < <(jq -c '.findings[]' <<<"$ENV2"; jq -c '.findings[]' <<<"$ENV3")
[[ "$EMIT_FAIL" -eq 0 ]] && ok "every finding survives sweep_emit_finding's real refusal rules" || bad "every finding survives sweep_emit_finding's real refusal rules ($EMIT_FAIL refused)"
# Both cases above describe the SAME file (goodmorning) with the same
# mechanism and the same locus, so sweep_finding_id gives them one id and
# sweep_emit_finding correctly collapses them to a single row. That is the
# contract -- a finding identifies a thing, not a run, so observing the
# same drifted file twice must not produce two rows. Asserting "2" here
# would be asserting that dedup is broken.
#
# The original version of this assertion stamped one hardcoded finding_id
# on every finding, so it demanded 2 rows from input that could only ever
# produce 1, and failed for a reason that had nothing to do with the code
# under test.
EMIT_LINES="$(wc -l < "$EMIT_OUT" | tr -d ' ')"
[[ "$EMIT_LINES" == "1" ]] && ok "the two same-file findings collapse to one row -- dedup keys on the thing, not the run" || bad "expected 1 deduped row in findings.jsonl, got $EMIT_LINES"

# ...and dedup must not be collapsing EVERYTHING. A finding about a
# different file has to survive alongside it, or the assertion above would
# also pass on a writer that drops every row after the first.
OTHER="$(jq -c '.identity_key="handoff" | .evidence.locus=".claude/skills/handoff"' <<<"$(jq -c '.findings[0]' <<<"$ENV3")")"
OTHER_FID="$(sweep_finding_id "fixture" "PC1" "$(jq -r '.mechanism' <<<"$OTHER")" ".claude/skills/handoff" "handoff")"
OTHER_STAMPED="$(jq -c --arg fid "$OTHER_FID" --arg run "test.abcdef" --arg repo "fixture" --arg now "2026-08-18T00:00:00Z" \
  '.schema="finding-record/v1" | .finding_id=$fid | .run_id=$run | .repo=$repo | .created_at=$now' <<<"$OTHER")"
sweep_emit_finding "$EMIT_OUT" "$OTHER_STAMPED" || true
EMIT_LINES2="$(wc -l < "$EMIT_OUT" | tr -d ' ')"
[[ "$EMIT_LINES2" == "2" ]] && ok "a finding about a DIFFERENT file is written alongside it -- dedup is not swallowing everything" || bad "expected 2 rows after a distinct finding, got $EMIT_LINES2"

echo "----"
echo "sweep-portable-drift: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
