#!/usr/bin/env bash
# scripts/lib/detection-cadence-issue.sh — duplicate-branch logic for
# .github/workflows/detection-cadence.yml (stack ADR-082 spec P1e). Sourced,
# not executed (same pattern as resolve-migrations-dir.sh / gate-vacuity.sh):
# functions only, callers own `set -uo pipefail`.
#
# The workflow itself invokes scripts/improvement-queue.sh add with the
# literal flags the spec pins (kept inline in the YAML, not hidden behind
# this function, so the exact call is grep-checkable in the workflow file).
# This function only does what happens AFTER that call returns — the LB-D
# idempotency branch: rely on the writer's own dedup (_iq_find_dup) rather
# than inventing a second title-prefix dedup key. Every tick after the first
# collides by design; this is where that collision turns into a comment
# instead of a second issue.

# dc_handle_writer_result <rc> <writer-stdout> <owner-repo> <label>
#   <assignee> <date>
# -> branches on `improvement-queue.sh add`'s own result:
#   - rc != 0 (usage/validation error, or backend/cap failure): the add
#     itself failed. Prints the writer's own output to stderr and returns
#     rc unchanged — the workflow step, and the job, fail (spec: "workflow
#     fails if the add/comment fails").
#   - "dup:<id>"  — an open cadence issue for this (where, kind) already
#     exists. Comments the fixed tick sentence on it via `gh`.
#   - "spooled:<uuid>" — GitHub was unreachable at write time; the entry is
#     safely queued for the next successful add/flush. Nothing to label yet
#     (there is no issue id) — not a failure, just deferred.
#   - anything else — the writer's created-issue JSON ({"id":...,...}).
#     Labels the new issue `detection-cadence` and assigns `assignee`.
# A `gh` failure on the comment/label/assign path returns its own nonzero
# rc, which the caller must also treat as a workflow failure.
dc_handle_writer_result() {
  local rc="$1" out="$2" owner_repo="$3" label="$4" assignee="$5" date="$6"

  if [[ "$rc" != "0" ]]; then
    printf 'detection-cadence: improvement-queue.sh add failed (rc=%s): %s\n' "$rc" "$out" >&2
    return "$rc"
  fi

  case "$out" in
    dup:*)
      local id="${out#dup:}"
      gh issue comment "$id" --repo "$owner_repo" --body "cadence tick $date - still open"
      return $?
      ;;
    spooled:*)
      printf 'detection-cadence: entry spooled (GitHub unreachable at write time) — will post on the next successful add: %s\n' "$out"
      return 0
      ;;
    *)
      local id; id="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)"
      if [[ -z "$id" ]]; then
        printf 'detection-cadence: could not parse an issue id from writer output: %s\n' "$out" >&2
        return 1
      fi
      gh issue edit "$id" --repo "$owner_repo" --add-label "$label" --add-assignee "$assignee"
      return $?
      ;;
  esac
}
