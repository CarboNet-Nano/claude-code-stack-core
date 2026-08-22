#!/usr/bin/env bash
# tests/test-sweep-w1-manifest.sh — W1's pure manifest layer: the closed
# verb list, walk-manifest parsing, and R1-safe identity keys. No browser,
# no network, no fixtures beyond strings.
#
# W1 is split this way on purpose. Every rule that can be decided without a
# rendered page lives here so it is testable on any machine, including one
# where chromium cannot launch; only the four assertion verbs and the DOM
# scrape need a browser, and those are tested in tests/test-sweep-w1.sh
# behind a live launch probe.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/sweep/lib/w1-manifest.mjs"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available — w1-manifest.mjs is a node module"; exit 0; }
[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }

# run_node <js> -> stdout of an inline module importing the lib.
run_node() {
  node --input-type=module -e "import { ASSERTION_VERBS, parseWalkManifest, identityKeyFor, coverageDiff, INTERACTIVE_ROLES } from '$LIB'; $1"
}

# ---- the closed verb list -------------------------------------------

t_verbs_are_exactly_the_four_spec_verbs() {
  local got
  got="$(run_node 'process.stdout.write(ASSERTION_VERBS.join(","))' 2>&1)"
  [ "$got" = "navigates,opens-menu-adjacent-to-anchor,shows-pending,persists-after-reload" ] \
    && pass "ASSERTION_VERBS is exactly the four spec verbs, in spec order" \
    || fail "ASSERTION_VERBS is '$got'"
}

t_verb_list_is_frozen() {
  local got
  got="$(run_node 'try { ASSERTION_VERBS.push("wiggles"); process.stdout.write(String(ASSERTION_VERBS.length)) } catch (e) { process.stdout.write("4") }' 2>&1)"
  [ "$got" = "4" ] \
    && pass "ASSERTION_VERBS is frozen — a caller cannot widen the closed list at runtime" \
    || fail "ASSERTION_VERBS was mutated to length '$got'"
}

# ---- parsing ---------------------------------------------------------

t_parses_a_wellformed_manifest() {
  local got
  got="$(run_node 'const m = parseWalkManifest(JSON.stringify({screens:[{screen:"/process",controls:[{find:"Save",assert:"persists-after-reload"}]}]})); process.stdout.write(m.screens[0].controls[0].find)' 2>&1)"
  [ "$got" = "Save" ] \
    && pass "a well-formed manifest parses to screens[].controls[]" \
    || fail "well-formed parse produced '$got'"
}

t_unknown_verb_throws_and_names_it() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[{screen:"/a",controls:[{find:"X",assert:"wiggles"}]}]})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write(e.message) }' 2>&1)"
  case "$out" in
    NO-THROW) fail "an unknown assertion verb did not throw" ;;
    *wiggles*) pass "an unknown assertion verb throws and names the offending verb" ;;
    *) fail "unknown verb threw without naming it: '$out'" ;;
  esac
}

t_unknown_verb_message_lists_the_legal_verbs() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[{screen:"/a",controls:[{find:"X",assert:"wiggles"}]}]})) } catch (e) { process.stdout.write(e.message) }' 2>&1)"
  case "$out" in
    *navigates*persists-after-reload*) pass "the unknown-verb message lists the legal verbs, so the fix needs no source reading" ;;
    *) fail "unknown-verb message does not list the legal verbs: '$out'" ;;
  esac
}

t_malformed_json_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest("{not json"); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write("THREW") }' 2>&1)"
  [ "$out" = "THREW" ] \
    && pass "malformed JSON throws rather than yielding an empty universe" \
    || fail "malformed JSON produced '$out'"
}

t_empty_screens_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[]})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write("THREW") }' 2>&1)"
  [ "$out" = "THREW" ] \
    && pass "an empty screens array throws — a walk with no universe is a config error, not a pass" \
    || fail "empty screens produced '$out'"
}

t_missing_screens_key_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write("THREW") }' 2>&1)"
  [ "$out" = "THREW" ] \
    && pass "a manifest with no screens key at all throws" \
    || fail "missing screens key produced '$out'"
}

t_screen_with_no_controls_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[{screen:"/a",controls:[]}]})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write(e.message) }' 2>&1)"
  case "$out" in
    NO-THROW) fail "a screen declaring no controls did not throw" ;;
    */a*) pass "a screen declaring no controls throws and names the screen" ;;
    *) fail "empty-controls threw without naming the screen: '$out'" ;;
  esac
}

t_control_with_no_find_text_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[{screen:"/a",controls:[{assert:"navigates"}]}]})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write("THREW") }' 2>&1)"
  [ "$out" = "THREW" ] \
    && pass "a control with no find text throws — W1 would have nothing to locate" \
    || fail "control with no find produced '$out'"
}

t_blank_screen_path_throws() {
  local out
  out="$(run_node 'try { parseWalkManifest(JSON.stringify({screens:[{screen:"",controls:[{find:"X",assert:"navigates"}]}]})); process.stdout.write("NO-THROW") } catch (e) { process.stdout.write("THREW") }' 2>&1)"
  [ "$out" = "THREW" ] \
    && pass "a blank screen path throws" \
    || fail "blank screen path produced '$out'"
}

t_every_legal_verb_parses() {
  local got
  got="$(run_node 'const cs = ASSERTION_VERBS.map((v,i) => ({find:"c"+i, assert:v})); const m = parseWalkManifest(JSON.stringify({screens:[{screen:"/a",controls:cs}]})); process.stdout.write(String(m.screens[0].controls.length))' 2>&1)"
  [ "$got" = "4" ] \
    && pass "every verb in ASSERTION_VERBS is accepted by the parser — the list and the check cannot drift apart" \
    || fail "parsing all four verbs produced '$got' controls"
}

# ---- R1-safe identity keys ------------------------------------------

t_identity_key_regroups_long_digit_runs() {
  local got
  got="$(run_node 'process.stdout.write(identityKeyFor("/reports/2026","Save"))' 2>&1)"
  [ "$got" = "/reports/202-6#Save" ] \
    && pass "identityKeyFor breaks a 4+ digit run into 3-digit groups (R1-safe)" \
    || fail "identityKeyFor gave '$got', expected '/reports/202-6#Save'"
}

t_identity_key_leaves_short_runs_alone() {
  local got
  got="$(run_node 'process.stdout.write(identityKeyFor("/v2/list","Add"))' 2>&1)"
  [ "$got" = "/v2/list#Add" ] \
    && pass "identityKeyFor leaves runs under 4 digits untouched" \
    || fail "identityKeyFor gave '$got', expected '/v2/list#Add'"
}

t_identity_key_regroups_a_run_in_the_control_name() {
  local got
  got="$(run_node 'process.stdout.write(identityKeyFor("/a","Order 12345"))' 2>&1)"
  [ "$got" = "/a#Order 123-45" ] \
    && pass "identityKeyFor regroups a long digit run in the control name too, not just the path" \
    || fail "identityKeyFor gave '$got', expected '/a#Order 123-45'"
}

t_identity_key_output_has_no_4plus_digit_run() {
  local got
  got="$(run_node 'const k = identityKeyFor("/reports/20260819","Batch 99999"); process.stdout.write(/[0-9]{4,}/.test(k) ? "R1-UNSAFE" : "R1-SAFE")' 2>&1)"
  [ "$got" = "R1-SAFE" ] \
    && pass "identityKeyFor output never contains a 4+ digit run — sweep-emit.sh's R1 cannot refuse it" \
    || fail "identityKeyFor produced an R1-unsafe key"
}

t_identity_key_is_deterministic() {
  local a b
  a="$(run_node 'process.stdout.write(identityKeyFor("/reports/2026","Save"))' 2>&1)"
  b="$(run_node 'process.stdout.write(identityKeyFor("/reports/2026","Save"))' 2>&1)"
  [ "$a" = "$b" ] && [ -n "$a" ] \
    && pass "identityKeyFor is deterministic across runs — the same finding keeps one identity" \
    || fail "identityKeyFor is not stable ('$a' vs '$b')"
}

t_identity_key_distinguishes_controls_on_one_screen() {
  local a b
  a="$(run_node 'process.stdout.write(identityKeyFor("/a","Save"))' 2>&1)"
  b="$(run_node 'process.stdout.write(identityKeyFor("/a","Delete"))' 2>&1)"
  [ "$a" != "$b" ] \
    && pass "two controls on one screen get distinct identity keys" \
    || fail "identityKeyFor collided on '$a'"
}

# ---- the control universe and the coverage diff ----------------------
# Spec Decision 4: the denominator comes from the live DOM, never from the
# manifest. The manifest cannot grade itself.

t_interactive_roles_is_a_closed_nonempty_list() {
  local n
  n="$(run_node 'process.stdout.write(String(INTERACTIVE_ROLES.length))' 2>&1)"
  case "$n" in
    ''|*[!0-9]*) fail "INTERACTIVE_ROLES length is '$n'" ;;
    *) [ "$n" -ge 5 ] \
         && pass "INTERACTIVE_ROLES is a non-empty closed list ($n roles)" \
         || fail "INTERACTIVE_ROLES has only $n roles" ;;
  esac
}

t_interactive_roles_is_frozen() {
  local got
  got="$(run_node 'const n = INTERACTIVE_ROLES.length; try { INTERACTIVE_ROLES.push("banana") } catch (e) {} process.stdout.write(String(INTERACTIVE_ROLES.length === n))' 2>&1)"
  [ "$got" = "true" ] \
    && pass "INTERACTIVE_ROLES is frozen — widening coverage is an edit, never a runtime accident" \
    || fail "INTERACTIVE_ROLES was mutated at runtime"
}

t_coverage_reports_undeclared_controls() {
  local got
  got="$(run_node 'process.stdout.write(coverageDiff(["Save"], ["Save","Delete","Export"]).undeclared.join(","))' 2>&1)"
  [ "$got" = "Delete,Export" ] \
    && pass "controls found in the DOM but absent from the manifest are reported, sorted" \
    || fail "undeclared list is '$got', expected 'Delete,Export'"
}

t_coverage_counts_both_sides() {
  local got
  got="$(run_node 'const d = coverageDiff(["Save","Assign"], ["Save","Delete"]); process.stdout.write(d.declared + "/" + d.discovered)' 2>&1)"
  [ "$got" = "2/2" ] \
    && pass "declared and discovered are counted independently" \
    || fail "counts are '$got', expected '2/2'"
}

t_coverage_dedupes_repeated_controls() {
  local got
  got="$(run_node 'process.stdout.write(coverageDiff([], ["Save","Save","Save"]).undeclared.join(","))' 2>&1)"
  [ "$got" = "Save" ] \
    && pass "a control rendered many times is reported once" \
    || fail "dedupe gave '$got', expected 'Save'"
}

t_coverage_full_declaration_reports_no_gap() {
  local got
  got="$(run_node 'process.stdout.write(String(coverageDiff(["Save","Delete"], ["Delete","Save"]).undeclared.length))' 2>&1)"
  [ "$got" = "0" ] \
    && pass "a manifest naming every discovered control reports no gap, whatever the order" \
    || fail "full declaration gave '$got' undeclared, expected 0"
}

t_coverage_ignores_declared_but_absent() {
  local got
  got="$(run_node 'process.stdout.write(coverageDiff(["Save","Ghost"], ["Save"]).undeclared.join("|"))' 2>&1)"
  [ -z "$got" ] \
    && pass "a declared control that does not render is not a coverage gap — its assertion verb reports that, and counting it here would double-report one defect" \
    || fail "declared-but-absent leaked into undeclared as '$got'"
}

t_coverage_empty_dom_is_not_a_silent_pass() {
  local got
  got="$(run_node 'const d = coverageDiff(["Save"], []); process.stdout.write(d.discovered + "/" + d.undeclared.length)' 2>&1)"
  [ "$got" = "0/0" ] \
    && pass "an empty DOM yields a zero denominator, which the readiness bar must not read as full coverage" \
    || fail "empty DOM gave '$got', expected '0/0'"
}

t_verbs_are_exactly_the_four_spec_verbs
t_verb_list_is_frozen
t_parses_a_wellformed_manifest
t_unknown_verb_throws_and_names_it
t_unknown_verb_message_lists_the_legal_verbs
t_malformed_json_throws
t_empty_screens_throws
t_missing_screens_key_throws
t_screen_with_no_controls_throws
t_control_with_no_find_text_throws
t_blank_screen_path_throws
t_every_legal_verb_parses
t_identity_key_regroups_long_digit_runs
t_identity_key_leaves_short_runs_alone
t_identity_key_regroups_a_run_in_the_control_name
t_identity_key_output_has_no_4plus_digit_run
t_identity_key_is_deterministic
t_identity_key_distinguishes_controls_on_one_screen
t_interactive_roles_is_a_closed_nonempty_list
t_interactive_roles_is_frozen
t_coverage_reports_undeclared_controls
t_coverage_counts_both_sides
t_coverage_dedupes_repeated_controls
t_coverage_full_declaration_reports_no_gap
t_coverage_ignores_declared_but_absent
t_coverage_empty_dom_is_not_a_silent_pass

echo ""
echo "test-sweep-w1-manifest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
