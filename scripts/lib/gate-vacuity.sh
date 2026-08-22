#!/usr/bin/env bash
# scripts/lib/gate-vacuity.sh — non-vacuity meta-gate (testing doctrine v2,
# P1b: docs/superpowers/specs/2026-08-16-testing-doctrine-redesign.md).
# Sourceable only; no side effects when sourced, no arg dispatch — house
# style for scripts/lib (scripts/sweep/lib/sweep-config.sh).
#
# Reuses the Sweep's vacuity vocabulary
# (scripts/sweep/sweep-run.sh's envelope_liveness_violation): a check that
# reports nothing established nothing. Here the "check" is a test file and
# the assertion protocol is the house convention — a conforming test prints
# one line per assertion starting `PASS:` or `FAIL:` (the pass()/fail()
# helper most tests already use, or an equivalent inline echo). A test file
# that prints ZERO such lines is `vacuous` — a green exit with no assertion
# behind it — unless it is named in the exemption list, because those files
# use a different (pre-existing) reporting convention, not because they
# don't run.
#
# One public function:
#   gv_run_suite <glob>
#     -> runs every file matching <glob>, streams its output, counts
#        ^PASS:/^FAIL: lines, treats an unexempted vacuous file as a
#        failure, and prints a totals summary line. Returns 0 only when
#        every file exited 0 AND no file was vacuous.
#
# GV_EXEMPTIONS overrides the exemption list path (test seam).

GV_EXEMPTIONS="${GV_EXEMPTIONS:-config/gate-vacuity-exemptions.txt}"

# gv_is_exempt <path> -> 0 when <path> (as passed to gv_run_suite's glob,
# e.g. "tests/test-foo.sh") appears in the exemption list. Exemption lines
# are "<path>" or "<path> # <reason>"; blank lines and lines starting with
# `#` are comments.
gv_is_exempt() {
  local path="$1" line entry
  [[ -f "$GV_EXEMPTIONS" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    entry="${line%%#*}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ "$entry" == "$path" ]] && return 0
  done < "$GV_EXEMPTIONS"
  return 1
}

# gv_run_suite <glob>
gv_run_suite() {
  local glob="$1" t rc pass_count fail_count out
  local total_pass=0 total_fail=0 total_vacuous=0 suite_fail=0

  for t in $glob; do
    [[ -f "$t" ]] || continue
    echo "=== $t ==="
    out="$(mktemp "${TMPDIR:-/tmp}/gate-vacuity.XXXXXX")" || {
      echo "gate-vacuity: mktemp failed" >&2
      return 1
    }
    bash "$t" 2>&1 | tee "$out"
    rc="${PIPESTATUS[0]}"
    if [[ "$rc" -ne 0 ]]; then
      echo "FAIL: $t exited non-zero"
      suite_fail=1
    fi

    pass_count="$(grep -cE '^PASS:' "$out" || true)"
    fail_count="$(grep -cE '^FAIL:' "$out" || true)"
    total_pass=$((total_pass + pass_count))
    total_fail=$((total_fail + fail_count))

    if [[ "$pass_count" -eq 0 && "$fail_count" -eq 0 ]]; then
      if gv_is_exempt "$t"; then
        echo "gate-vacuity: $t is exempt from the PASS:/FAIL: protocol ($GV_EXEMPTIONS)"
      else
        echo "FAIL: $t is vacuous — reported a result without printing a single PASS:/FAIL: assertion line, and carries no exemption"
        total_vacuous=$((total_vacuous + 1))
        suite_fail=1
      fi
    fi
    rm -f "$out"
  done

  echo "----"
  echo "gate-vacuity: $total_pass passed, $total_fail failed, $total_vacuous vacuous"
  return "$suite_fail"
}
