#!/usr/bin/env bash
# Shared library for the loop-engineering control plane.
# Sourced by the /loop-engineer skill helper and the loop hooks.
# All functions are fail-safe: errors never crash the caller.
set -uo pipefail

# ADR-053 D7/D8: domain_mode may be a scalar or an array; test membership
# only through dm_has_mode, never `==` against the raw value (an array
# silently never matches, which used to make this escalation check a
# no-op for a multi-mode config).
_DM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/domain-modes.sh"
[[ -f "$_DM_LIB" ]] || _DM_LIB="$HOME/.claude/lib/domain-modes.sh"
# shellcheck disable=SC1090
source "$_DM_LIB" 2>/dev/null || true

# Safe HOME fallback: avoid expanding $HOME when it may be unset under set -u.
_loop_home="${HOME:-/tmp}"
LOOP_STATE_DIR="${LOOP_STATE_DIR:-${_loop_home}/.claude/session-state}"

# Loop-state is per-session (ADR-020): two live sessions must not share one
# state file, or they fight over a single Stop-hook iteration counter and one
# session gets trapped by a loop another armed. The path is resolved lazily so
# the session id can be set after this lib is sourced (the Stop hook exports it
# from the hook payload before reading state).
#   precedence: LOOP_STATE_FILE override  >  per-session file  >  legacy file
_loop_state_file() {
  if [[ -n "${LOOP_STATE_FILE:-}" ]]; then
    printf '%s' "$LOOP_STATE_FILE"; return 0
  fi
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  sid="${sid//[^A-Za-z0-9._-]/_}"   # filename-safe; blocks path traversal
  if [[ -n "$sid" ]]; then
    printf '%s/loop-state.%s.json' "$LOOP_STATE_DIR" "$sid"
  else
    printf '%s/loop-state.json' "$LOOP_STATE_DIR"
  fi
}

loop_read_state() {
  local f; f="$(_loop_state_file)"
  if [[ -f "$f" ]]; then
    jq -c '.' "$f" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

loop_write_state() {
  # Default to empty object so zero-arg invocation is safe under set -u.
  # Two-step: bash closes ${1:-{}} at the first }, so use an intermediate var.
  local json tmp f
  json="${1:-}"
  [[ -z "$json" ]] && json="{}"
  f="$(_loop_state_file)"
  # All failure paths return 0 so set -e callers are not terminated.
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null || return 0
  # Use mktemp to avoid predictable PID-based tmp names (symlink attack).
  tmp="$(mktemp "${f}.tmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$json" | jq -c '.' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
}

# Hash of the working state: git HEAD + diff (content) + untracked names.
# Used by the no-progress detector. Stable when nothing changed.
loop_state_hash() {
  local cwd="${1:-$PWD}"
  # shasum is macOS; sha1sum is Linux. Try both, fallback to no-op.
  local _sha_cmd
  if command -v shasum >/dev/null 2>&1; then
    _sha_cmd="shasum"
  elif command -v sha1sum >/dev/null 2>&1; then
    _sha_cmd="sha1sum"
  else
    echo ""; return 0
  fi
  { git -C "$cwd" rev-parse HEAD 2>/dev/null
    git -C "$cwd" diff HEAD 2>/dev/null
    git -C "$cwd" status --porcelain 2>/dev/null
    # Phase-2 (d): include the byte-contents of untracked, non-ignored files so a
    # loop that only edits an untracked file is detected as making progress.
    # --exclude-standard honors .gitignore; -z + xargs -0 are filename-safe.
    git -C "$cwd" ls-files --others --exclude-standard -z 2>/dev/null \
      | (cd "$cwd" 2>/dev/null && xargs -0 cat 2>/dev/null)
  } | $_sha_cmd 2>/dev/null | awk '{print $1}'
}

# Validate a loop spec. rc 0 = ok, rc 2 = refuse.
# Rule: must have >=1 bound. If autonomy==bounded-autonomous, a
# success_criterion.command is mandatory UNLESS require_external_termination is
# explicitly "never". The schema default "auto" means required for
# bounded-autonomous, so "auto" triggers the gate just like "always".
loop_validate_spec() {
  local json="${1:-}"
  [[ -z "$json" ]] && return 2
  # Reject non-integer numeric bounds to prevent bash arithmetic errors downstream.
  local _mi _pb _to
  _mi="$(echo "$json" | jq -r '.bounds.max_iterations // empty' 2>/dev/null)"
  _pb="$(echo "$json" | jq -r '.bounds.per_run_budget_usd // empty' 2>/dev/null)"
  _to="$(echo "$json" | jq -r '.bounds.timeout_minutes // empty' 2>/dev/null)"
  # Integer bounds must be a positive integer (>= 1); 0 is rejected (schema minimum:1).
  [[ -n "$_mi" && ! "$_mi" =~ ^[1-9][0-9]*$ ]] && return 2
  # per_run_budget_usd allows decimal but must be a valid non-negative number.
  [[ -n "$_pb" && ! "$_pb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && return 2
  # timeout_minutes must also be a positive integer (>= 1).
  [[ -n "$_to" && ! "$_to" =~ ^[1-9][0-9]*$ ]] && return 2
  echo "$json" | jq -e '.bounds.max_iterations or .bounds.per_run_budget_usd or .bounds.timeout_minutes' >/dev/null 2>&1 || return 2
  local auto ext cmd
  auto="$(echo "$json" | jq -r '.autonomy // "checkpoint"' 2>/dev/null)"
  ext="$(echo "$json" | jq -r '.require_external_termination // "auto"' 2>/dev/null)"
  cmd="$(echo "$json" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
  # Require a success_criterion.command for bounded-autonomous unless the caller
  # explicitly opts out with "never". "auto" (the schema default) and "always"
  # and legacy boolean true all require the command.
  if [[ "$auto" == "bounded-autonomous" && "$ext" != "never" && -z "$cmd" ]]; then
    return 2
  fi
  return 0
}

# Return the first tripped bound, or "ok". Pure function of the state JSON.
loop_check_bounds() {
  local json="${1:-}"
  [[ -z "$json" ]] && { echo "ok"; return; }
  local iter cap cost budget npc npe started now elapsed timeout depth dcap
  iter="$(echo "$json"  | jq -r '.iteration // 0')"
  cap="$(echo "$json"   | jq -r '.bounds.max_iterations // 1000000')"
  # Phase-2 (c): recursion depth is now a hard bound (was advisory in Phase 1).
  # Callers increment .recursion_depth on fan-out; bound is .bounds.max_recursion_depth.
  depth="$(echo "$json" | jq -r '.recursion_depth // 0')"
  dcap="$(echo "$json"  | jq -r '.bounds.max_recursion_depth // empty')"
  cost="$(echo "$json"  | jq -r '.cost_so_far_usd // 0')"
  budget="$(echo "$json"| jq -r '.bounds.per_run_budget_usd // empty')"
  npc="$(echo "$json"   | jq -r '.no_progress_count // 0')"
  # Use explicit false-check: jq's // alternative treats false as falsy, so
  # '.no_progress_exit // true' returns true even when the field is false.
  npe="$(echo "$json" | jq -r 'if .no_progress_exit == false then "false" else "true" end' 2>/dev/null)"
  timeout="$(echo "$json" | jq -r '.bounds.timeout_minutes // empty')"
  started="$(echo "$json" | jq -r '.started_at // empty')"
  # Validate numeric fields before arithmetic to prevent injection or crash under set -u.
  # max_iterations and timeout_minutes must be integers; a float value is treated as
  # the bound already tripped (safe: trips the cap rather than silently ignoring it).
  [[ "$iter"  =~ ^[0-9]+$ ]] || iter=0
  if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
    # Non-integer cap (e.g. 2.5) — treat as bound tripped.
    echo "max_iterations"; return
  fi
  [[ "$npc"   =~ ^[0-9]+(\.[0-9]+)?$ ]] || npc=0
  [[ "$cost"  =~ ^[0-9]+(\.[0-9]+)?$ ]] || cost=0
  [[ -n "$budget"  && ! "$budget"  =~ ^[0-9]+(\.[0-9]+)?$ ]] && budget=""
  if [[ -n "$timeout" && ! "$timeout" =~ ^[0-9]+$ ]]; then
    # Non-integer timeout — treat as bound tripped.
    echo "timeout"; return
  fi
  # Recursion depth check (before iteration): a non-integer cap is treated as tripped.
  if [[ -n "$dcap" ]]; then
    [[ "$depth" =~ ^[0-9]+$ ]] || depth=0
    if [[ ! "$dcap" =~ ^[0-9]+$ ]]; then echo "max_recursion_depth"; return; fi
    [[ "$depth" -ge "$dcap" ]] && { echo "max_recursion_depth"; return; }
  fi
  [[ "$iter" -ge "$cap" ]] && { echo "max_iterations"; return; }
  # Use awk -v to pass values to avoid code injection via string interpolation.
  if [[ -n "$budget" ]] && awk -v c="$cost" -v b="$budget" 'BEGIN{exit !(c >= b)}'; then echo "budget_exceeded"; return; fi
  # Only trip no_progress when no_progress_exit is not explicitly false.
  [[ "$npe" != "false" ]] && [[ "$npc" -ge 2 ]] && { echo "no_progress"; return; }
  if [[ -n "$timeout" && -n "$started" ]]; then
    now="$(date -u +%s 2>/dev/null)"; started="$(date -u -d "$started" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null)"
    if [[ -n "$now" && -n "$started" ]]; then elapsed=$(( (now - started) / 60 )); [[ "$elapsed" -ge "$timeout" ]] && { echo "timeout"; return; }; fi
  fi
  echo "ok"
}

# Add an estimated USD delta to cost_so_far in loop-state (between-iteration).
# Also append a row to subagent-runs.jsonl so caps calibrate from real history.
loop_accrue_cost() {
  local delta="${1:-0}" state new_state
  # Reject negative deltas: they could drive cost_so_far_usd negative, permanently
  # bypassing the per_run_budget_usd cap.
  if ! awk -v d="$delta" 'BEGIN{exit !(d >= 0)}' 2>/dev/null; then
    return 1
  fi
  state="$(loop_read_state)"
  new_state="$(echo "$state" | jq -c --argjson d "$delta" '.cost_so_far_usd=((.cost_so_far_usd//0)+$d)' 2>/dev/null)" || return 0
  loop_write_state "$new_state" 2>/dev/null || return 1
  state="$new_state"
  local log="${_loop_home}/.claude/logs/subagent-runs.jsonl"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  jq -nc --argjson d "$delta" --arg lid "$(echo "$state" | jq -r '.loop_id // "loop"')" \
    '{event:"loop_iteration", loop_id:$lid, cost_usd:$d}' >>"$log" 2>/dev/null || true
}

# Phase-2 (b): live within-iteration cost for a loop. Sums cost_usd/cost across
# all subagent-runs.jsonl rows tagged with this loop_id (optionally only those at
# or after started_at when the row carries a .ts). This is the authoritative
# mid-flight figure the live monitor compares to the budget — unlike the
# between-iteration cost_so_far_usd snapshot, it does not wait for the Stop hook.
# Prints a number (0 when no data). Fail-safe.
#
# Event semantics (ADR-024): this intentionally sums ALL loop-tagged cost rows
# regardless of event. The two cost-bearing events are DISJOINT spend segments,
# never overlapping, so the sum is correct (not double-counted):
#   - loop_tool_cost  (loop-cost-accrual.sh) — real per-tool token cost, the only
#                       per-call cost source in normal operation.
#   - loop_iteration  (loop_accrue_cost)     — legacy between-iteration estimate,
#                       written only if a caller explicitly accrues one.
loop_live_cost() {
  local lid="${1:-}" since="${2:-}"
  local log="${_loop_home}/.claude/logs/subagent-runs.jsonl"
  [[ -z "$lid" || ! -f "$log" ]] && { echo 0; return 0; }
  jq -rs --arg lid "$lid" --arg since "$since" '
    [ .[]
      | select(.loop_id == $lid)
      | select( ($since == "") or ((.ts // "") == "") or (.ts >= $since) )
      | ((.cost_usd // .cost // 0) | tonumber? // 0)
    ] | add // 0
  ' "$log" 2>/dev/null || echo 0
}

# Phase-2 telemetry: record one finished loop run. Always appends a row to the
# local JSONL telemetry log (always-on); additionally POSTs to the Supabase
# stack.loop_runs table (004-loop-runs.sql) IFF both SUPABASE_URL and
# SUPABASE_SERVICE_KEY are set and curl exists. No-op-safe: missing creds, missing
# curl, or any network error never crash the caller (matches the cost-log pattern).
# Usage: loop_runs_record '<loop-state-json-with-terminal-status>'
loop_runs_record() {
  local state="${1:-}"
  [[ -z "$state" ]] && return 0
  # Phase-3 polish (ADR-024): record REAL spend. cost_so_far_usd is the
  # between-iteration snapshot; loop_live_cost sums the per-tool loop_tool_cost
  # rows accrued by loop-cost-accrual.sh. Take the larger so /loop-review's avg $
  # reflects actual per-tool cost, not just the snapshot. Fail-safe -> snapshot.
  local _lid _started _snap _live _cost
  _lid="$(echo "$state" | jq -r '.loop_id // empty' 2>/dev/null)"
  _started="$(echo "$state" | jq -r '.started_at // empty' 2>/dev/null)"
  _snap="$(echo "$state" | jq -r '.cost_so_far_usd // 0' 2>/dev/null)"
  [[ "$_snap" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _snap=0
  _live="$(loop_live_cost "$_lid" "$_started" 2>/dev/null || echo 0)"
  [[ "$_live" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _live=0
  _cost="$(awk -v a="$_snap" -v b="$_live" 'BEGIN{printf "%.6f", (a>b?a:b)}' 2>/dev/null)" || _cost="$_snap"
  # Build the row from loop-state fields.
  local row
  row="$(echo "$state" | jq -c --argjson cost "${_cost:-0}" '{
    loop_id:         (.loop_id // "loop"),
    session_id:      (env.CLAUDE_CODE_SESSION_ID // null),
    pattern:         (.pattern // null),
    autonomy:        (.autonomy // null),
    goal:            (.goal // null),
    status:          (.status // "unknown"),
    iterations:      (.iteration // 0),
    recursion_depth: (.recursion_depth // 0),
    cost_usd:        $cost,
    started_at:      (.started_at // null),
    ended_at:        (now | todateiso8601)
  }' 2>/dev/null)" || return 0
  [[ -z "$row" ]] && return 0

  # Always-on local telemetry.
  local log="${_loop_home}/.claude/logs/loop-runs.jsonl"
  mkdir -p "$(dirname "$log")" 2>/dev/null && printf '%s\n' "$row" >>"$log" 2>/dev/null || true

  # Optional Supabase rollup (Tier 3+). Graceful no-op without creds/curl.
  [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -sf -X POST "${SUPABASE_URL%/}/rest/v1/loop_runs" \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Content-Profile: stack" \
    -H "Prefer: return=minimal" \
    --data "$row" >/dev/null 2>&1 || true
  return 0
}

# Phase-3 (ADR-023): aggregate loop telemetry from the local loop-runs.jsonl into
# per-pattern stats. Prints a JSON array (one object per pattern). Empty/no log ->
# []. Fail-safe. Optional arg overrides the log path (for tests).
loop_stats() {
  local log="${1:-${_loop_home}/.claude/logs/loop-runs.jsonl}"
  [[ -f "$log" ]] || { echo '[]'; return 0; }
  jq -rs '
    def pct($p): (sort | if length==0 then 0 else .[ ([(((length * $p) | ceil) - 1), 0] | max) ] end);
    group_by(.pattern // "unknown")
    | map({
        pattern: (.[0].pattern // "unknown"),
        runs: length,
        met_pct:              ((map(select(.status=="met"))            | length) * 100 / length),
        budget_exceeded_pct:  ((map(select(.status=="budget_exceeded"))| length) * 100 / length),
        iter_cap_pct:         ((map(select(.status=="max_iterations")) | length) * 100 / length),
        p50_iterations:       ([ .[].iterations // 0 ] | pct(0.50)),
        p95_iterations:       ([ .[].iterations // 0 ] | pct(0.95)),
        avg_cost_usd:         (((map(.cost_usd // 0) | add) / length) | (.*1000000|round)/1000000)
      })
  ' "$log" 2>/dev/null || echo '[]'
}

# Phase-3 polish (ADR-024): render loop_stats as an aligned text table for
# /loop-review (so rendering is deterministic, not left to model discretion).
# Same source as loop_stats (optional log-path arg). Empty history -> prints
# nothing (the caller emits the "no history" message). Fail-safe: any error ->
# prints nothing.
# Rows recorded before this fix (session-id propagation + pre-increment
# telemetry ordering, both landed 2026-07-29) systematically read
# iterations:0 / cost_usd:0 regardless of real usage. Not backfillable
# (the real numbers were never captured) -- loop_stats_table flags their
# presence so a stale-zero average isn't mistaken for a real one.
_LOOP_TELEMETRY_FIX_TS="2026-07-29T18:00:00Z"

loop_stats_table() {
  local log="${1:-${_loop_home}/.claude/logs/loop-runs.jsonl}"
  local stats; stats="$(loop_stats "$log")"
  [[ -z "$stats" || "$stats" == "[]" ]] && return 0
  local fmt='%-14s %5s %6s %8s %8s %5s %5s %9s\n'
  {
    # shellcheck disable=SC2059
    printf "$fmt" PATTERN RUNS MET% BUDGET% ITERCAP% P50 P95 'AVG$'
    echo "$stats" | jq -r '
      def r1: (.*10|round)/10;
      .[] | [
        (.pattern // "unknown"),
        (.runs // 0),
        ((.met_pct // 0)             | r1),
        ((.budget_exceeded_pct // 0) | r1),
        ((.iter_cap_pct // 0)        | r1),
        (.p50_iterations // 0),
        (.p95_iterations // 0),
        (.avg_cost_usd // 0)
      ] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r pat runs met bud cap p50 p95 avg; do
        # shellcheck disable=SC2059
        printf "$fmt" "$pat" "$runs" "$met" "$bud" "$cap" "$p50" "$p95" "$avg"
      done
    if [[ -f "$log" ]]; then
      local stale; stale="$(jq -rs --arg cut "$_LOOP_TELEMETRY_FIX_TS" \
        '[.[] | select((.ended_at // "") != "" and .ended_at < $cut)] | length' "$log" 2>/dev/null || echo 0)"
      [[ "$stale" =~ ^[0-9]+$ ]] || stale=0
      if [[ "$stale" -gt 0 ]]; then
        echo
        echo "note: $stale row(s) predate the 2026-07-29 loop-hook telemetry fix (session-id propagation + pre-increment recording) and read iterations:0/cost:\$0 regardless of real usage -- not reliable for calibration, not backfillable."
      fi
    fi
  } 2>/dev/null || return 0
}

# Propose (print only — never auto-apply) a loop_policy.max_iterations bump per
# pattern: ceil(p95 * 1.2), floored at the current default. Reads loop_stats.
# Prints a JSON array of {pattern, observed_p95, proposed_max_iterations}.
loop_calibrate() {
  local current="${1:-25}" log="${2:-}"
  [[ "$current" =~ ^[0-9]+$ ]] || current=25
  local stats; stats="$(loop_stats "$log")"
  echo "$stats" | jq -c --argjson cur "$current" '
    map({
      pattern: .pattern,
      runs: .runs,
      observed_p95: .p95_iterations,
      proposed_max_iterations: ([ ($cur), (((.p95_iterations * 1.2) | ceil)) ] | max)
    })
  ' 2>/dev/null || echo '[]'
}

# Phase-3 (ADR-023): convert token usage to USD via the single audited price
# table (config/model-routing.json -> providers.*.models[id].pricing_per_million_*).
# Usage: loop_cost_from_usage <input_tokens> <output_tokens> [model_id]
# Prints a USD number (0 on any error / unknown model). Fail-safe.
loop_cost_from_usage() {
  local in_tok="${1:-0}" out_tok="${2:-0}" model="${3:-claude-opus-4-8}"
  [[ "$in_tok"  =~ ^[0-9]+$ ]] || in_tok=0
  [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
  # Resolve the price table: explicit override, then installed, then repo-relative.
  local pt="${LOOP_PRICE_TABLE:-}"
  if [[ -z "$pt" ]]; then
    if [[ -f "${_loop_home}/.claude/config/model-routing.json" ]]; then
      pt="${_loop_home}/.claude/config/model-routing.json"
    else
      local _here; _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
      [[ -f "${_here}/../../config/model-routing.json" ]] && pt="${_here}/../../config/model-routing.json"
    fi
  fi
  [[ -z "$pt" || ! -f "$pt" ]] && { echo 0; return 0; }
  jq -rn --slurpfile t "$pt" --arg m "$model" --argjson i "$in_tok" --argjson o "$out_tok" '
    ([ ($t[0].providers // {})[] | .models? // {} ] | add // {}) as $models
    | ($models[$m] // {}) as $mdl
    | ( (($mdl.pricing_per_million_input  // 0) * $i / 1000000)
      + (($mdl.pricing_per_million_output // 0) * $o / 1000000) )
  ' 2>/dev/null || echo 0
}

# Resolve the model-routing.json price table path (same precedence as
# loop_cost_from_usage: explicit override, then installed, then repo-relative).
# Prints the path, or empty if not found. Fail-safe.
_model_fit_price_table() {
  local pt="${LOOP_PRICE_TABLE:-}"
  if [[ -z "$pt" ]]; then
    if [[ -f "${_loop_home}/.claude/config/model-routing.json" ]]; then
      pt="${_loop_home}/.claude/config/model-routing.json"
    else
      # bash 3.2 (macOS default): BASH_SOURCE can be an empty array at this
      # call depth, and `${BASH_SOURCE[0]}` alone then trips `set -u` as an
      # unbound-parameter error. The `:-` default guards that.
      local _here; _here="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
      [[ -f "${_here}/../../config/model-routing.json" ]] && pt="${_here}/../../config/model-routing.json"
    fi
  fi
  [[ -n "$pt" && -f "$pt" ]] && printf '%s' "$pt"
  return 0
}

# ADR-033: post-session model-fit receipt. Shared ratio + cost calculator,
# called by both /handoff (Step: model-fit receipt) and the Stop-hook fallback
# (hooks/model-fit-turn.sh's companion read, at session end).
#
# Sums ONLY subagent-runs.jsonl rows with event=="main_turn" AND agent=="main"
# (the two structural tags that exclude all subagent/loop-cost rows — ADR-033
# blocker 3), scoped to this session's session_start + project. Computes
# gen_per_edit = total_out_tokens / max(edit_calls, 1) and walks the three
# bands (mechanical / mixed / reasoning) with a minimum-evidence gate and a
# tier-ladder clamp (never below Haiku, never above Opus).
#
# Usage: model_fit_receipt_line <session_start_iso> <project_path> [log_path]
# Prints one receipt line, or empty (insufficient evidence / no data / error).
# Fail-safe: any error -> empty, never crashes the caller.
model_fit_receipt_line() {
  local session_start="${1:-}" project="${2:-}" log="${3:-${_loop_home}/.claude/logs/subagent-runs.jsonl}"
  [[ -f "$log" ]] || { echo ""; return 0; }
  # An unresolved session_start must never silently widen the scope to
  # "all main_turn rows ever for this project" — that would print a receipt
  # that claims "this session" over an unbounded history. Stay silent instead;
  # callers should skip invoking this at all when they can't resolve their own
  # session_start (see hooks/model-fit-turn.sh), but this is the load-bearing
  # guard in case a future caller passes empty by mistake.
  [[ -z "$session_start" ]] && { echo ""; return 0; }

  local pt; pt="$(_model_fit_price_table)"
  [[ -z "$pt" ]] && { echo ""; return 0; }

  # Aggregate this session's main_turn rows into one JSON object.
  local agg
  agg="$(jq -rs --arg s "$session_start" --arg p "$project" '
    [ .[]
      | select(.event == "main_turn")
      | select(.agent == "main")
      | select( ($s == "") or ((.session_start // "") == $s) )
      | select( ($p == "") or ((.project // "") == $p) )
    ] as $rows
    | {
        total_turns:      ($rows | length),
        edit_calls:       ([ $rows[] | ((.tool_counts.edit // 0) + (.tool_counts.write // 0) + (.tool_counts.bash // 0)) ] | add // 0),
        total_out_tokens: ([ $rows[] | (.out_tokens // 0) ] | add // 0),
        total_in_tokens:  ([ $rows[] | (.in_tokens // 0) ] | add // 0),
        model:            (($rows | map(select(.model != null and .model != "")) | last // {}).model // "claude-opus-4-8")
      }
  ' "$log" 2>/dev/null)" || { echo ""; return 0; }
  [[ -z "$agg" ]] && { echo ""; return 0; }

  local total_turns edit_calls total_out total_in model
  total_turns="$(echo "$agg" | jq -r '.total_turns' 2>/dev/null)"
  edit_calls="$(echo "$agg" | jq -r '.edit_calls' 2>/dev/null)"
  total_out="$(echo "$agg" | jq -r '.total_out_tokens' 2>/dev/null)"
  total_in="$(echo "$agg" | jq -r '.total_in_tokens' 2>/dev/null)"
  model="$(echo "$agg" | jq -r '.model' 2>/dev/null)"
  [[ "$total_turns" =~ ^[0-9]+$ ]] || total_turns=0
  [[ "$edit_calls"  =~ ^[0-9]+$ ]] || edit_calls=0
  [[ "$total_out"   =~ ^[0-9]+$ ]] || total_out=0
  [[ "$total_in"    =~ ^[0-9]+$ ]] || total_in=0
  # Read-site sanitization (belt-and-suspenders with the hook's write-site
  # sanitization): model ids are always [A-Za-z0-9._-]. A row written before
  # this fix, or from any other writer, could still carry an unsanitized
  # string — strip anything else so it can never break out of the
  # <system-reminder> wrapper this string is later printed inside.
  model="$(printf '%s' "$model" | tr -cd 'A-Za-z0-9._-')"
  [[ -z "$model" || "$model" == "null" ]] && model="claude-opus-4-8"

  # No main_turn rows at all (e.g. all-subagent session) -> nothing to say.
  [[ "$total_turns" -eq 0 ]] && { echo ""; return 0; }

  # gen_per_edit = total_out_tokens / max(edit_calls, 1)
  local denom="$edit_calls"
  [[ "$denom" -lt 1 ]] && denom=1
  local gen_per_edit
  gen_per_edit="$(awk -v o="$total_out" -v d="$denom" 'BEGIN{printf "%.4f", o/d}' 2>/dev/null)" || gen_per_edit="0"

  local cur_cost
  cur_cost="$(loop_cost_from_usage "$total_in" "$total_out" "$model" 2>/dev/null || echo 0)"
  [[ "$cur_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] || cur_cost=0

  # Tier ladder walk (haiku -> sonnet -> opus).
  local ladder idx alt_model shape=""
  ladder="$(jq -r '.model_fit.tier_ladder[]?' "$pt" 2>/dev/null)"
  [[ -z "$ladder" ]] && ladder=$'claude-haiku-4-5-20251001\nclaude-sonnet-4-6\nclaude-opus-4-8'
  idx="$(printf '%s\n' "$ladder" | grep -nx "$model" | head -1 | cut -d: -f1)"
  [[ -z "$idx" ]] && idx=3   # unknown current model -> treat as top of ladder (never suggest "up")
  local ladder_len; ladder_len="$(printf '%s\n' "$ladder" | grep -c .)"

  # Minimum-evidence gate: total_turns >= 6 AND edit_calls + (total_out/500) >= 12.
  local mass
  mass="$(awk -v e="$edit_calls" -v o="$total_out" 'BEGIN{printf "%.4f", e + (o/500)}' 2>/dev/null)" || mass="0"
  local enough_evidence=1
  [[ "$total_turns" -lt 6 ]] && enough_evidence=0
  awk -v m="$mass" 'BEGIN{exit !(m < 12)}' 2>/dev/null && enough_evidence=0

  local direction=""   # "cheaper" | "up" | "stay" | ""
  if [[ "$enough_evidence" -eq 1 ]]; then
    if awk -v g="$gen_per_edit" 'BEGIN{exit !(g < 300)}' 2>/dev/null && [[ "$edit_calls" -ge 10 ]]; then
      shape="mostly mechanical editing (low prose-per-edit)"
      direction="cheaper"
    elif awk -v g="$gen_per_edit" 'BEGIN{exit !(g > 1200)}' 2>/dev/null; then
      shape="generation/reasoning-heavy"
      if [[ "$idx" -ge "$ladder_len" ]]; then
        direction="stay"
      else
        direction="up"
      fi
    else
      shape="mixed workload"
      direction=""
    fi
  fi

  # Resolve alt_model per direction, clamped to the ladder (never below Haiku,
  # never above Opus). idx is 1-based line number in $ladder.
  case "$direction" in
    cheaper)
      if [[ "$idx" -le 1 ]]; then
        direction=""   # already at the floor -> no cheaper tier to suggest
      else
        alt_model="$(printf '%s\n' "$ladder" | sed -n "$((idx-1))p")"
      fi
      ;;
    up)
      alt_model="$(printf '%s\n' "$ladder" | sed -n "$((idx+1))p")"
      ;;
  esac

  # alt_model comes from config/model-routing.json's tier_ladder, not the log,
  # but sanitize anyway (defense in depth — same allowlist, cheap, and it is
  # interpolated into the same reminder text as $model).
  [[ -n "${alt_model:-}" ]] && alt_model="$(printf '%s' "$alt_model" | tr -cd 'A-Za-z0-9._-')"

  local alt_cost=""
  if [[ -n "${alt_model:-}" ]]; then
    alt_cost="$(loop_cost_from_usage "$total_in" "$total_out" "$alt_model" 2>/dev/null || echo 0)"
    [[ "$alt_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] || alt_cost=0
  fi

  local cur_fmt alt_fmt
  cur_fmt="$(awk -v c="$cur_cost" 'BEGIN{printf "%.2f", c}' 2>/dev/null)" || cur_fmt="$cur_cost"

  case "$direction" in
    cheaper)
      alt_fmt="$(awk -v c="$alt_cost" 'BEGIN{printf "%.2f", c}' 2>/dev/null)" || alt_fmt="$alt_cost"
      printf 'Model-fit receipt — this session: ~$%s on %s across %s turns, %s. %s would'"'"'ve been ≈$%s. If sessions like this are common, consider defaulting to %s. (`model_fit_receipt: off` in `/session` to silence.)' \
        "$cur_fmt" "$model" "$total_turns" "$shape" "$alt_model" "$alt_fmt" "$alt_model"
      ;;
    up)
      alt_fmt="$(awk -v c="$alt_cost" 'BEGIN{printf "%.2f", c}' 2>/dev/null)" || alt_fmt="$alt_cost"
      printf 'Model-fit receipt — this session: ~$%s on %s, %s. %s (≈$%s) may be a better fit if quality mattered here.' \
        "$cur_fmt" "$model" "$shape" "$alt_model" "$alt_fmt"
      ;;
    stay)
      printf 'Model-fit receipt — this session: ~$%s on %s, %s. Already on the strongest tier — staying is the right call.' \
        "$cur_fmt" "$model" "$shape"
      ;;
    *)
      if [[ "$enough_evidence" -eq 1 ]]; then
        printf 'Model-fit receipt — this session: ~$%s on %s, %s. No clear cheaper/stronger fit. (`model_fit_receipt: off` in `/session` to silence.)' \
          "$cur_fmt" "$model" "${shape:-mixed workload}"
      else
        # Below the minimum-evidence gate: print the cost line only, no shape
        # and no recommendation (ADR-033 Signal section) — never fully silent
        # here (that's reserved for the zero-main_turn-rows case above).
        printf 'Model-fit receipt — this session: ~$%s on %s across %s turns. Not enough data yet for a workload read. (`model_fit_receipt: off` in `/session` to silence.)' \
          "$cur_fmt" "$model" "$total_turns"
      fi
      ;;
  esac
  return 0
}

# --- ADR-040: /advisor pair-escalation suggestion ---------------------------
#
# Deliberately a SEPARATE function, not folded into model_fit_receipt_line
# above: that function's suggestion (cheaper/up/stay) is gated behind the
# minimum-evidence check (total_turns>=6 AND mass>=12), and nesting the
# advisor line inside that case block would mean a session with real advisor
# usage but thin turn data prints nothing about it — exactly the case most
# worth surfacing. Keeping this independent means it always evaluates,
# regardless of whether the workload-shape read had enough evidence.
#
# What this can and cannot know, and why:
# - Advisor call COUNT is real, observable data: each advisor invocation is a
#   `server_tool_use` content block (name:"advisor") in the transcript, summed
#   per turn by model-fit-turn.sh into main_turn.advisor_calls, same "since
#   last human prompt" scoping as tool_counts and token sums.
# - Whether an advisor call actually HELPED is not observable: the tool
#   result is `advisor_tool_result` with `encrypted_content` — redacted at
#   the transcript level. This function reports frequency only. It does not,
#   and structurally cannot, judge advisor's usefulness.
# - The CURRENTLY ACTIVE pair (base model + advisor model) is read fresh at
#   Stop time, not derived from historical rows — a pair can change mid-
#   session via /model and /advisor, and only the current pair is actionable
#   advice. Base model comes from the aggregated rows (same $model
#   model_fit_receipt_line resolves); advisor model comes from
#   ~/.claude/settings.json's advisorModel, which /advisor writes there.
#
# _model_fit_ladder_pos <model_or_alias> -> an ORDINAL ladder position
# (1=haiku, 2=sonnet, 3=opus, 4=fable), or empty if unrecognized.
#
# This is NOT the advisor_rank number the `claude` binary uses internally
# (verified by grepping the binary 2026-07-26: haiku=1, sonnet=3, opus=4,
# fable=5, with no CLI-exposed way to query it live) — it is a small, stable
# ordinal over the four PUBLIC ALIASES this feature suggests between. Aliases
# are a stable product surface even as the dated ids they resolve to change
# (opus has meant 4.5, 4.8, 5, ...), which is why this maps on family/alias
# substring rather than exact id. It WILL go stale if Anthropic reorders the
# alias tiers themselves (unlikely) or adds a new tier between existing ones;
# there is no live query for this, so treat it as a periodically-reverified
# constant, not a computed fact.
_model_fit_ladder_pos() {
  local m="$1"
  case "$m" in
    *haiku*)  echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*)   echo 3 ;;
    *fable*)  echo 4 ;;
    *) return 1 ;;
  esac
}

# _model_fit_escalation_threshold <project> -> an integer call-count
# threshold. Uses ONLY static, already-declared per-repo config
# (stack_tier / domain_mode / sensitivity.level from stack-config.json) —
# deliberately NOT a live per-turn difficulty classifier, which is the exact
# design ADR-033's cross-family critique killed (fail-open token-band rule,
# blocker 1). A repo's own declared risk posture is a legitimate, static
# input; inferring "how hard is this turn" from turn content is not.
_model_fit_escalation_threshold() {
  local project="$1"
  local config tier sens
  config="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$project" 2>/dev/null)"
  if [[ -z "$config" ]]; then
    echo 3
    return 0
  fi
  tier="$(jq -r '.stack_tier // 0' "$config" 2>/dev/null)"
  [[ "$tier" =~ ^[0-9]+$ ]] || tier=0
  sens="$(jq -r '.sensitivity.level // "normal"' "$config" 2>/dev/null)"

  if [[ "$tier" -ge 4 ]] || dm_has_mode "$config" "financial-code" || dm_has_mode "$config" "schema-migration" || [[ "$sens" == "confidential" ]]; then
    echo 1
  else
    echo 3
  fi
}

# Usage: model_fit_advisor_line <session_start_iso> <project_path> [log_path]
# Prints one sentence, or empty (no advisor calls this session / error).
# Fail-safe: any error -> empty, never crashes the caller.
model_fit_advisor_line() {
  local session_start="${1:-}" project="${2:-}" log="${3:-${_loop_home}/.claude/logs/subagent-runs.jsonl}"
  [[ -f "$log" ]] || { echo ""; return 0; }
  [[ -z "$session_start" ]] && { echo ""; return 0; }

  local calls base_model
  calls="$(jq -rs --arg s "$session_start" --arg p "$project" '
    [ .[]
      | select(.event == "main_turn")
      | select(.agent == "main")
      | select( ($s == "") or ((.session_start // "") == $s) )
      | select( ($p == "") or ((.project // "") == $p) )
    ] as $rows
    | ([ $rows[] | (.advisor_calls // 0) ] | add // 0)
  ' "$log" 2>/dev/null)"
  [[ "$calls" =~ ^[0-9]+$ ]] || calls=0
  [[ "$calls" -eq 0 ]] && { echo ""; return 0; }

  base_model="$(jq -rs --arg s "$session_start" --arg p "$project" '
    [ .[]
      | select(.event == "main_turn")
      | select(.agent == "main")
      | select( ($s == "") or ((.session_start // "") == $s) )
      | select( ($p == "") or ((.project // "") == $p) )
      | select(.model != null and .model != "")
    ] | (last // {}).model // ""
  ' "$log" 2>/dev/null)"
  [[ -z "$base_model" ]] && base_model="unknown"

  # advisorModel is a global user setting (~/.claude/settings.json), read
  # fresh — this is the CURRENTLY active advisor, which may differ from
  # whatever was active during earlier turns this session if the user
  # switched mid-session. Reporting the current pair is the actionable one.
  local advisor_model=""
  local settings="$HOME/.claude/settings.json"
  [[ -f "$settings" ]] && advisor_model="$(jq -r '.advisorModel // empty' "$settings" 2>/dev/null)"
  [[ -z "$advisor_model" || "$advisor_model" == "null" ]] && advisor_model="none"

  local plural="calls"
  [[ "$calls" -eq 1 ]] && plural="call"

  if [[ "$advisor_model" == "none" ]]; then
    printf 'Advisor: %s %s this session (no advisor pair currently set).' "$calls" "$plural"
    return 0
  fi

  local base_line="pair: $base_model + $advisor_model advisor"
  local threshold; threshold="$(_model_fit_escalation_threshold "$project")"
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3

  if [[ "$calls" -lt "$threshold" ]]; then
    printf 'Advisor: %s %s this session, %s.' "$calls" "$plural" "$base_line"
    return 0
  fi

  # Threshold crossed — try to name the next rung. base_model may be a full
  # id (claude-sonnet-5) or an alias; _model_fit_ladder_pos matches either by
  # substring. advisor_model from settings.json is typically a bare alias
  # (e.g. "opus").
  local base_pos next_base next_advisor
  base_pos="$(_model_fit_ladder_pos "$base_model" 2>/dev/null)"
  if [[ -z "$base_pos" ]]; then
    printf 'Advisor: %s %s this session, %s — heavier use than typical. Consider whether a stronger pair would help.' \
      "$calls" "$plural" "$base_line"
    return 0
  fi

  local ladder_names=(haiku sonnet opus fable)
  local next_base_pos=$((base_pos + 1))
  local next_advisor_pos=$((base_pos + 2))
  if [[ "$next_base_pos" -gt 4 ]]; then
    printf 'Advisor: %s %s this session, %s — already at the top of the escalation ladder.' \
      "$calls" "$plural" "$base_line"
    return 0
  fi
  next_base="${ladder_names[$((next_base_pos-1))]}"
  if [[ "$next_advisor_pos" -gt 4 ]]; then
    next_advisor="$next_base"   # no rung above next_base -> advisor == base (equal rank still valid per binary's >= check)
  else
    next_advisor="${ladder_names[$((next_advisor_pos-1))]}"
  fi

  printf 'Advisor: %s %s this session, %s — consider escalating: `/model %s` then `/advisor %s`.' \
    "$calls" "$plural" "$base_line" "$next_base" "$next_advisor"
  return 0
}

# Phase-3 (spec §6.7): durable corrections. When a loop exits without meeting its
# goal (no_progress / escalated / a bound trip), append a structured note so the
# lesson compounds — /handoff folds unresolved corrections into the next session.
# Always-on local append; fail-safe (never crashes the Stop hook).
# Usage: loop_record_correction '<loop-state-json>' [hint]
loop_record_correction() {
  local state="${1:-}" hint="${2:-}"
  [[ -z "$state" ]] && return 0
  local project
  project="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local row
  row="$(echo "$state" | jq -c --arg hint "$hint" --arg project "$project" '{
    ts:       (now | todateiso8601),
    project:  $project,
    loop_id:  (.loop_id // "loop"),
    status:   (.status // "unknown"),
    goal:     (.goal // null),
    iteration:(.iteration // 0),
    hint:     (if $hint == "" then null else $hint end),
    resolved: false
  }' 2>/dev/null)" || return 0
  [[ -z "$row" ]] && return 0
  local f="${LOOP_STATE_DIR}/loop-corrections.jsonl"
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null && printf '%s\n' "$row" >>"$f" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Ultracode signal (Phase 2 / spec open-question 1)
# ---------------------------------------------------------------------------
# Ultracode is a session-scoped risk dial: when on, the loop autonomy ceiling is
# raised one level above the tier default (capped at bounded-autonomous). It is
# deliberately NOT persisted in stack-config — it is a per-session opt-in, set by
# env (CLAUDE_ULTRACODE) or the /ultracode skill's session-state flag.
# Returns rc 0 when active, rc 1 otherwise. Fail-safe: any error -> inactive.
loop_ultracode_active() {
  # Explicit per-session state (set by /ultracode) is AUTHORITATIVE and overrides
  # any ambient CLAUDE_ULTRACODE the harness/SDK may inject into the hook runtime,
  # so `/ultracode off` reliably disables the gate. But it is authoritative ONLY
  # when .active is an explicit boolean: a present-but-empty / malformed / no-.active
  # file is NOT authoritative and falls through to the env signal. This is
  # deliberate — the design-gate enforces only while ON, so treating a blank/garbage
  # file as OFF would silently disable enforcement (fail-open). Falling through to
  # env fails TOWARD enforcing. The env var is the fallback when no explicit state
  # exists. Fail-safe: any jq error -> not authoritative -> env fallback.
  local f="${LOOP_STATE_DIR:-${_loop_home}/.claude/session-state}/ultracode-state.json"
  if [[ -f "$f" ]]; then
    case "$(jq -r 'if (.active|type)=="boolean" then (.active|tostring) else "none" end' "$f" 2>/dev/null)" in
      true)  return 0 ;;
      false) return 1 ;;   # explicit /ultracode off -> OFF, overrides truthy env
      *)     : ;;          # empty/malformed/no boolean .active -> fall through to env
    esac
  fi
  # No authoritative state -> fall back to the env signal. Portable lowercase:
  # macOS default bash is 3.2, which lacks the ${v,,} expansion.
  case "$(printf '%s' "${CLAUDE_ULTRACODE:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes) return 0 ;;
  esac
  return 1
}

# Compute the effective autonomy ceiling given the tier ceiling and whether
# ultracode is active. Ultracode raises one level, capped at bounded-autonomous.
# Usage: loop_effective_ceiling <tier_ceiling> <true|false>
loop_effective_ceiling() {
  local base="${1:-checkpoint}" ultra="${2:-false}"
  if [[ "$ultra" != "true" ]]; then printf '%s' "$base"; return 0; fi
  case "$base" in
    checkpoint)          printf 'bounded-checkpoint' ;;
    bounded-checkpoint)  printf 'bounded-autonomous' ;;
    bounded-autonomous)  printf 'bounded-autonomous' ;;   # already at cap
    *)                   printf '%s' "$base" ;;            # unknown -> identity
  esac
}
