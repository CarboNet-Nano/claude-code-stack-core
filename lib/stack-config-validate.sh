#!/usr/bin/env bash
# scv_validate <config-path> <schema-path>
#
# D7 structural check, extracted from scripts/stack-sync.sh:229-251 (ADR-068)
# so stack-sync.sh and org-check.sh (/carbonet, A-D8) share ONE validator —
# two validators that disagree about what a valid config is is a bug class
# this repo has already paid for. Changes versus the original inline block,
# all disclosed here rather than silently patched:
#
#  1. The original used `jq --argfile inp "$cfg" "$cfg"` to bind the whole
#     document to $inp for the required-fields check. `--argfile` is
#     unsupported by jq 1.7+ ("Unknown option --argfile") — on any such jq,
#     the whole `verr=$(jq ... 2>/dev/null)` capture silently produced EMPTY
#     output (jq errored, stderr was discarded), so the D7 check has been a
#     silent no-op — every config "validated" clean regardless of content —
#     on any machine running jq 1.7+. Replaced with `. as $inp |` at the top
#     of the filter, which needs no extra file argument. Real, pre-existing
#     bug fix: the check now does what it always claimed to do.
#  2. FAIL-OPEN BUG (reviewer finding, 2026-08-11, reproduced live): every
#     enum check piped the allowed-values array straight into `index(.field)`
#     — e.g. `["main-thread","agent-teams","hybrid"] | index(.orchestration_mode)`.
#     jq evaluates a builtin's argument against the value on the LEFT of the
#     pipe (the array), not the original document, so `.orchestration_mode`
#     was being read off an ARRAY — a jq runtime error ("Cannot index array
#     with string"). Combined with change 3 below (which used to just
#     swallow that error as "clean"), this meant `orchestration_mode:
#     "garbage"` (and any bad `sensitivity.level` / `default_autonomy`)
#     silently validated OK in both callers — defeating the entire point of
#     A-D8. Fixed by binding the field to a variable BEFORE the array
#     literal: `.field as $v | $v != null and (["a","b"] | index($v) | not)`.
#  3. FAIL-OPEN BY DESIGN BUG (reviewer finding, 2026-08-11): any jq runtime
#     failure (the bug above, a schema file that isn't valid JSON, or any
#     future bug of the same shape) was silently converted into "valid",
#     because `2>/dev/null` discarded jq's error and an empty $verr reads as
#     clean — contradicting this function's own documented contract. Fixed:
#     the schema is now checked for valid JSON up front, jq's stderr is
#     captured (not discarded) and its exit status is checked explicitly —
#     any failure to RUN the check is now reported as INVALID (fail closed),
#     never as a silent pass.
#  4. `active_subagents` was flagged invalid merely for being ABSENT (bare
#     `(.active_subagents | type) != "array"`, no presence guard), not just
#     for being present-and-wrong-type — harmless inside stack-sync.sh only
#     because its own reconcile() unconditionally sets active_subagents:[]
#     before this check ever runs (D5), but wrong once this validator is
#     also called on a RAW, non-reconciled repo config (org-check.sh's Check
#     4). Guarded with `has("active_subagents") and ...`, matching every
#     other optional-field check in this same block.
#  5. A `strict_mode` boolean check was ADDED, then REVERTED — worth
#     recording so it isn't reintroduced blind. `strict_mode` is in
#     stack-sync.sh's own KEEP_LIST (reconcile()'s `reconciled($k)`), whose
#     "keep" branch is `($c[$k])` unconditionally — for any repo config that
#     never set `strict_mode`, that is jq `null`, not "absent". Every fixture
#     in tests/test-stack-sync.sh omits `strict_mode`, so once the check
#     above ran for real (change 3 fixed the bug that had been masking it —
#     see the note below), EVERY reconciled config it validates carried
#     `strict_mode: null` and got discarded as FAILED, taking 14 of
#     tests/test-stack-sync.sh's 31 checks down with it. This is not a
#     scv_validate bug — it is a genuine incompatibility between "one shared
#     validator" (A-D8) and stack-sync.sh's existing, correct-for-its-purpose
#     keep-list behavior (preserving whatever a repo had, including
#     "never set" as null) — fixing it belongs to stack-sync.sh's
#     reconciliation logic, not to this extraction. Left unchecked here;
#     org-check.sh's Check 4 (`/carbonet`) does not currently catch a raw
#     `strict_mode: null` repo config either as a result — filed, not fixed.
#     NOTE on why this wasn't caught the first time this file was written:
#     bug #2 (enum-check array-scoping) made `scv_validate` jq-error on
#     nearly every reconciled config (orchestration_mode is templated to a
#     non-null default), and until bug #3 was also fixed that error was
#     silently swallowed as "clean" — so the validator was accidentally a
#     no-op for stack-sync.sh's own test fixtures the whole time strict_mode
#     was first added, masking this exact conflict. Fixing #2 and #3
#     together is what finally made the validator run for real and surface
#     it.
#
# Confirmed the current state of every change above leaves
# tests/test-stack-sync.sh's result at 31 passed, 0 failed, unchanged.
#
# The repo ships no jsonschema/ajv dependency (see tests/test-permissions-
# boundary.sh), so this is a structural check against the schema's own
# constraints — required fields, types, and every enum the schema
# constrains — not a full JSON-Schema library validation.
#
# Prints `; `-joined errors on stdout (empty when clean).
# Exit: 0 clean / 1 dirty. Dirty (never a silent clean) includes: either
# input file missing, the config OR the schema not being valid JSON, and any
# failure of the jq check itself to run to completion (fail closed).
#
# Usage:
#   source lib/stack-config-validate.sh
#   errors="$(scv_validate "$cfg" "$schema")" || echo "invalid: $errors"

set -uo pipefail

scv_validate() {
  local cfg="$1" schema="$2"

  if [[ ! -f "$cfg" ]]; then
    printf 'stack-config-validate: config file not found (%s)' "$cfg"
    return 1
  fi
  if [[ ! -f "$schema" ]]; then
    printf 'stack-config-validate: schema file not found (%s)' "$schema"
    return 1
  fi
  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    printf 'stack-config-validate: config is not valid JSON (%s)' "$cfg"
    return 1
  fi
  if ! jq -e . "$schema" >/dev/null 2>&1; then
    printf 'stack-config-validate: schema is not valid JSON (%s)' "$schema"
    return 1
  fi

  local verr jq_rc errfile jq_err
  errfile="$(mktemp 2>/dev/null)" || {
    printf 'stack-config-validate: could not run the schema check (no writable temp location)'
    return 1
  }

  verr="$(jq -r --slurpfile s "$schema" '
    . as $inp |
    ($s[0].required // ["stack_version","stack_tier","purpose","created"]) as $req |
    [ ($req[] | select((. as $k | $inp | has($k)) | not) | "missing required field \(.)") ]
    + [ select((.stack_tier | type) != "number" or .stack_tier < 0 or .stack_tier > 5)
        | "stack_tier out of range: \(.stack_tier)" ]
    + [ select(has("active_subagents") and (.active_subagents | type) != "array")
        | "active_subagents is not an array" ]
    + (.orchestration_mode as $om |
       if $om != null and (["main-thread","agent-teams","hybrid"] | index($om) | not)
       then ["bad orchestration_mode: \($om)"] else [] end)
    + (.sensitivity.level as $sl |
       if $sl != null and (["normal","sensitive","confidential"] | index($sl) | not)
       then ["bad sensitivity.level: \($sl)"] else [] end)
    + (.loop_policy.default_autonomy as $da |
       if $da != null and (["checkpoint","bounded-checkpoint","bounded-autonomous"] | index($da) | not)
       then ["bad default_autonomy: \($da)"] else [] end)
    + [ select(.loop_policy != null and .loop_policy.irreversible_actions_break_loop != true)
        | "loop invariant violated: irreversible_actions_break_loop is not true" ]
    + [ select(.cost_protection.per_session_hard_cap_usd != null and
               .cost_protection.per_session_alert_usd != null and
               .cost_protection.per_session_hard_cap_usd < .cost_protection.per_session_alert_usd)
        | "hard cap below session alert" ]
    | join("; ")' "$cfg" 2>"$errfile")"
  jq_rc=$?
  jq_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"

  if (( jq_rc != 0 )); then
    printf 'stack-config-validate: schema check failed to run: %s' "${jq_err:-jq error (no message)}"
    return 1
  fi

  printf '%s' "$verr"
  [[ -z "$verr" ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  scv_validate "${1:-}" "${2:-}"
  rc=$?
  [[ $rc -ne 0 ]] && echo >&2
  exit "$rc"
fi
