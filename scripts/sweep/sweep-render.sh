#!/usr/bin/env bash
# scripts/sweep/sweep-render.sh — the Sweep G7 plain-English renderer
# (stack ADR-078, spec S4.3/S5.4, task 5). Sourceable only; has no side
# effects when sourced (matches scripts/sweep/lib/sweep-emit.sh's
# convention).
#
# Two public functions:
#   sweep_resolve_status <findings.jsonl path>
#     -> one compact resolved finding-record JSON object per line, one
#     per distinct finding_id. findings.jsonl is append-only (spec
#     S4.3), so file order is chronological: every field takes the
#     value from the newest row that carries that field; `status`
#     defaults to "open" when no row carries it. This is the one
#     implementation of spec S4.3's resolution rule — exported so
#     nothing downstream re-derives it.
#   sweep_render <repo> [--run <run_id>]
#     -> a plain-English render on stdout. Two paths, chosen by whether
#     real coverage (not just flagged findings) is knowable:
#
#     RUN-BACKED PATH — `--run <run_id>` is given AND
#     <repo>/.claude/sweep/runs.jsonl (schema sweep-run/v1, written by
#     the runner's write_run_row, one row per run) carries a row for
#     that run_id, AND <repo>/.claude/sweep.config.json exists. N/M are
#     the SUM of that run's `checks[].universe_size`, grouped by each
#     check_id's declared surface (config's `surfaces` map) — the real
#     count of ui-route / scheduled-job+ci-gate units the run actually
#     evaluated, whether or not they produced a finding. Output is the
#     G7 fixed acceptance format (spec's verbatim template):
#       "Checked N screens and M background jobs. Found K things worth
#       your attention: <one plain sentence each>. Nothing else
#       changed." Zero open findings -> "...Found nothing worth your
#       attention. Nothing else changed."
#
#     FALLBACK PATH — no `--run`, or the given run_id has no row in
#     runs.jsonl (or runs.jsonl / sweep.config.json is absent). Real
#     coverage isn't knowable from findings.jsonl alone: it only ever
#     records units that HAD a finding, so a run that checked N clean
#     screens would silently read as 0 under the G7 template. N/M here
#     are therefore the count of distinct ui-route / scheduled-job+
#     ci-gate identity_keys that have EVER been flagged, worded to say
#     exactly that rather than borrowing G7's "Checked" coverage claim:
#       "N screens and M background jobs have a finding on record.
#       Found K things worth your attention: <sentences> Nothing else
#       changed." K==0 -> "...Found nothing worth your attention.
#       Nothing else changed."
#
#     Both paths read <repo>/.claude/sweep/findings.jsonl (missing file
#     = zero findings) and, if present, <repo>/.claude/sweep/
#     attributions.jsonl (joined read-only on finding_id — absence
#     tolerated; nothing in this initiative writes that file).

# sweep_resolve_status <findings.jsonl path>
sweep_resolve_status() {
  local findings_path="${1:-}"
  [[ -n "$findings_path" && -f "$findings_path" ]] || return 0
  jq -c -s '
    group_by(.finding_id)
    | map(reduce .[] as $row ({}; . * $row))
    | map(if has("status") then . else . + {status: "open"} end)
    | .[]
  ' "$findings_path"
}

# _sweep_scope_ids_json <findings.jsonl path> <run_id>
# -> compact JSON array of finding_ids that had a check-emitted (no
# `status` key) row carrying that run_id — the set --run scopes a
# render to. Disposition rows for those finding_ids are still resolved
# from full history (a disposition can land in a later run).
_sweep_scope_ids_json() {
  local findings_path="$1" run_id="$2"
  jq -c -s --arg run "$run_id" '
    [ .[] | select((has("status") | not) and .run_id == $run) | .finding_id ] | unique
  ' "$findings_path"
}

# _sweep_join_attributions <attributions.jsonl path>
# -> reads resolved records on stdin (one compact object per line),
# attaches the matching attributions.jsonl row (same newest-row-wins
# rule, joined on finding_id) under `.attribution` when one exists.
# Read-only; only ever called by sweep_render after confirming the
# file exists.
_sweep_join_attributions() {
  local attributions_path="$1"
  jq -c -s --slurpfile attrs "$attributions_path" '
    ( $attrs | group_by(.finding_id)
      | map(reduce .[] as $r ({}; . * $r))
      | map({(.finding_id): .})
      | add // {} ) as $amap
    | .[]
    | . + (if ($amap[.finding_id] // null) != null
           then {attribution: $amap[.finding_id]} else {} end)
  '
}

# _sweep_universe_from_run <repo> <run_id>
# -> "N M" (space-separated integers) — real coverage for that run,
# summing runs.jsonl's checks[].universe_size grouped by
# sweep.config.json's declared surfaces map. Prints nothing (caller
# falls back to findings-derived counts) when runs.jsonl is absent,
# sweep.config.json is absent, or no row in runs.jsonl carries this
# run_id. Read-only: never sources or modifies the runner or the
# config lib, just reads the two files at the paths they already
# publish (<repo>/.claude/sweep/runs.jsonl, <repo>/.claude/sweep.config.json).
_sweep_universe_from_run() {
  local repo="$1" run_id="$2"
  local runs_path="$repo/.claude/sweep/runs.jsonl"
  local config_path="$repo/.claude/sweep.config.json"
  [[ -f "$runs_path" && -f "$config_path" ]] || return 0

  local row
  row="$(jq -c --arg run "$run_id" 'select(.run_id == $run)' "$runs_path" | tail -1)"
  [[ -n "$row" ]] || return 0

  jq -r --slurpfile cfgs "$config_path" '
    ($cfgs[0].surfaces // {}) as $surfaces |
    (.checks // []) as $checks |
    ( [ $checks[] | select(($surfaces[.check_id] // "") == "ui-route")
        | (.universe_size // 0) ] | add // 0 ) as $n |
    ( [ $checks[] | select(($surfaces[.check_id] // "") == "scheduled-job"
                            or ($surfaces[.check_id] // "") == "ci-gate")
        | (.universe_size // 0) ] | add // 0 ) as $m |
    "\($n) \($m)"
  ' <<<"$row"
}

# sweep_render <repo> [--run <run_id>]
sweep_render() {
  local repo="${1:-}"
  [[ $# -ge 1 ]] && shift
  local run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) run_id="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local findings_path="$repo/.claude/sweep/findings.jsonl"
  local attributions_path="$repo/.claude/sweep/attributions.jsonl"

  local resolved=""
  if [[ -f "$findings_path" ]]; then
    resolved="$(sweep_resolve_status "$findings_path")"

    if [[ -n "$run_id" ]]; then
      local scope_ids
      scope_ids="$(_sweep_scope_ids_json "$findings_path" "$run_id")"
      resolved="$(jq -c --argjson ids "$scope_ids" 'select(.finding_id as $f | $ids | index($f) != null)' <<<"$resolved")"
    fi

    if [[ -n "$resolved" && -f "$attributions_path" ]]; then
      resolved="$(_sweep_join_attributions "$attributions_path" <<<"$resolved")"
    fi
  fi

  local k
  k="$(jq -s '[.[] | select(.status == "open")] | length' <<<"$resolved")"

  local sentences=""
  [[ "$k" != "0" ]] && sentences="$(jq -r -s '[.[] | select(.status == "open") | .plain] | join(" ")' <<<"$resolved")"

  local universe_line=""
  [[ -n "$run_id" ]] && universe_line="$(_sweep_universe_from_run "$repo" "$run_id")"

  if [[ -n "$universe_line" ]]; then
    local n m
    n="$(cut -d' ' -f1 <<<"$universe_line")"
    m="$(cut -d' ' -f2 <<<"$universe_line")"
    if [[ "$k" == "0" ]]; then
      printf 'Checked %s screens and %s background jobs. Found nothing worth your attention. Nothing else changed.\n' "$n" "$m"
    else
      printf 'Checked %s screens and %s background jobs. Found %s things worth your attention: %s Nothing else changed.\n' "$n" "$m" "$k" "$sentences"
    fi
    return 0
  fi

  # Fallback: no run-backed universe data. findings.jsonl only ever
  # records units that had a finding, so these counts undercount real
  # coverage whenever a checked unit passed clean — worded to say
  # exactly that instead of claiming "Checked".
  local n m
  n="$(jq -s '[.[] | select(.surface == "ui-route") | .identity_key] | unique | length' <<<"$resolved")"
  m="$(jq -s '[.[] | select(.surface == "scheduled-job" or .surface == "ci-gate") | .identity_key] | unique | length' <<<"$resolved")"

  if [[ "$k" == "0" ]]; then
    printf '%s screens and %s background jobs have a finding on record. Found nothing worth your attention. Nothing else changed.\n' "$n" "$m"
    return 0
  fi

  printf '%s screens and %s background jobs have a finding on record. Found %s things worth your attention: %s Nothing else changed.\n' "$n" "$m" "$k" "$sentences"
}
