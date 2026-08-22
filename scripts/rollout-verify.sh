#!/usr/bin/env bash
# scripts/rollout-verify.sh — sole producer of rollout evidence (ADR-087 D7).
# Read-only against the target config dir (asserted by the test suite via a
# full `find` listing before/after). Reads the declared universe from
# config/rollouts.json (repo-local, next to this script) and probes ONE
# config dir for each declared rollout's five-probe-type-and-no-more set.
#
# Usage: rollout-verify.sh --config-dir <p> [--json]
#
# D7 hardening (closes audit findings 6/14 -- the confused-deputy class):
#   - Path discipline: a probe's `path` must be relative, no `..` segment,
#     not absolute. Every EXISTING component from config-dir down is refused
#     if it is a symlink. A symlinked ~/.claude-evil is a refusal, not a
#     silent redirection.
#   - Boolean-only outputs: settings_json/receipt_field expressions are
#     wrapped `if (<expr>) then true else false end` -- only true/false is
#     ever recorded, never the matched value.
#   - Resource bounds: any probed file > 1 MiB -> not-checked/probe-budget.
#     Every probe runs under a 2s process-group deadline (D18's helper).
#   - A probe that cannot run returns not-checked -- never absent, never
#     confirmed (ADR-085's thesis applied to the fleet).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RV_ROLLOUTS_DECL: test-only override for the declared-universe file. Real
# callers never set this -- it always resolves to the repo-local (then
# machine-wide) config/rollouts.json.
ROLLOUTS_DECL="${RV_ROLLOUTS_DECL:-}"
if [[ -z "$ROLLOUTS_DECL" ]]; then
  ROLLOUTS_DECL="$SCRIPT_DIR/../config/rollouts.json"
  [[ -f "$ROLLOUTS_DECL" ]] || ROLLOUTS_DECL="$HOME/.claude/config/rollouts.json"
fi

CONFIG_DIR=""
JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    *) echo "Usage: $0 --config-dir <p> [--json]" >&2; exit 2 ;;
  esac
done
if [[ -z "$CONFIG_DIR" ]]; then
  echo "Usage: $0 --config-dir <p> [--json]" >&2
  exit 2
fi

MANAGED_FLOOR_PATH="${RV_MANAGED_FLOOR_PATH:-/Library/Application Support/ClaudeCode/managed-settings.json}"
PROBE_DEADLINE_S="${RV_PROBE_DEADLINE_S:-2}"
PROBE_MAX_BYTES=1048576
DEADLINE_DEGRADED=0

# ── D18: process-group deadline, reused verbatim from hooks/stack-self-update.sh
run_with_deadline() {
  local secs="$1" outfile="$2"; shift 2
  local pgroup=1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$outfile" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'setpgrp(0,0); exec @ARGV' -- "$@" >"$outfile" 2>&1 &
  else
    pgroup=0
    DEADLINE_DEGRADED=1
    "$@" >"$outfile" 2>&1 &
  fi
  local pid=$! start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= secs )); then
      if (( pgroup == 1 )); then kill -TERM -- "-$pid" 2>/dev/null; else kill -TERM "$pid" 2>/dev/null; fi
      local kstart=$SECONDS
      while kill -0 "$pid" 2>/dev/null && (( SECONDS - kstart < 2 )); do sleep 0.2; done
      if kill -0 "$pid" 2>/dev/null; then
        if (( pgroup == 1 )); then kill -KILL -- "-$pid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
      fi
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
  done
  wait "$pid"
}

# ── path discipline ─────────────────────────────────────────────────────────
_rv_path_syntactically_safe() {
  local rel="$1"
  [[ -z "$rel" ]] && return 1
  [[ "$rel" == /* ]] && return 1
  local IFS='/' seg
  for seg in $rel; do [[ "$seg" == ".." ]] && return 1; done
  return 0
}
# A single EXISTING component is unsafe if it is a symlink, not owned by the
# invoking uid, or group-/other-writable (D7's full discipline — the ADR
# promises ownership + writability checks per component, not symlinks alone;
# cross-family review finding). rc 0 = unsafe.
_rv_component_unsafe() {
  local p="$1" perms
  [[ -L "$p" ]] && return 0
  [[ -e "$p" ]] || return 1
  [[ -O "$p" ]] || return 0
  perms="$(stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null)"
  [[ -n "$perms" ]] || return 0
  local last2="${perms: -2}"
  local gdigit="${last2:0:1}" odigit="${last2:1:1}"
  (( (8#$gdigit) & 2 )) && return 0
  (( (8#$odigit) & 2 )) && return 0
  return 1
}
# Refuse if any EXISTING path component from config-dir down is unsafe.
_rv_no_symlink_in_chain() {
  local base="$1" rel="$2"
  local IFS='/' seg cur="$base"
  for seg in $rel; do
    [[ -z "$seg" ]] && continue
    cur="$cur/$seg"
    _rv_component_unsafe "$cur" && return 1
  done
  return 0
}
# resolved_target <config_dir> <rel> -> echoes abs path if safe, rc 1 if not.
rv_resolved_target() {
  local base="$1" rel="$2"
  _rv_path_syntactically_safe "$rel" || return 1
  _rv_no_symlink_in_chain "$base" "$rel" || return 1
  printf '%s/%s' "$base" "$rel"
}

_rv_file_too_big() {
  local f="$1" sz
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  [[ "$sz" =~ ^[0-9]+$ ]] || return 1
  (( sz > PROBE_MAX_BYTES ))
}

# ── probes. Each echoes exactly "state|reason" (state in
# confirmed|absent|not-checked). Boolean-only for settings_json/receipt_field.
probe_file_present() {
  local base="$1" rel="$2" target
  target="$(rv_resolved_target "$base" "$rel")" || { echo "not-checked|unsafe-path"; return; }
  if [[ -L "$target" ]]; then echo "not-checked|unsafe-path"; return; fi
  if [[ -f "$target" ]]; then echo "confirmed|"; else echo "absent|"; fi
}

probe_file_sha() {
  local base="$1" rel="$2" want_sha="$3" target got
  target="$(rv_resolved_target "$base" "$rel")" || { echo "not-checked|unsafe-path"; return; }
  [[ -L "$target" ]] && { echo "not-checked|unsafe-path"; return; }
  [[ -f "$target" ]] || { echo "absent|"; return; }
  _rv_file_too_big "$target" && { echo "not-checked|probe-budget"; return; }
  got="$(shasum -a 256 "$target" 2>/dev/null | awk '{print $1}')"
  [[ -n "$got" ]] || { echo "not-checked|read-failed"; return; }
  [[ "$got" == "$want_sha" ]] && echo "confirmed|" || echo "absent|"
}

probe_settings_json() {
  local base="$1" expr target out rc outfile
  target="$base/settings.json"
  [[ -L "$target" ]] && { echo "not-checked|unsafe-path"; return; }
  [[ -f "$target" ]] || { echo "absent|"; return; }
  _rv_file_too_big "$target" && { echo "not-checked|probe-budget"; return; }
  expr="$2"
  outfile="$(mktemp)"
  # Strict boolean wrap: ONLY a literal `true` result counts as confirmed.
  # jq's own truthy coercion (any non-null/non-false value, including a
  # non-empty STRING, is "truthy" in an if/then) would let a probe whose
  # expression accidentally returns a string still read as confirmed --
  # case 80's exact regression.
  run_with_deadline "$PROBE_DEADLINE_S" "$outfile" jq -e "((${expr}) == true)" "$target"
  rc=$?
  out="$(cat "$outfile" 2>/dev/null)"; rm -f "$outfile"
  if [[ "$rc" -eq 124 ]]; then echo "not-checked|deadline"; return; fi
  case "$(printf '%s' "$out" | tr -d '[:space:]')" in
    true) echo "confirmed|" ;;
    false) echo "absent|" ;;
    *) echo "not-checked|malformed-json" ;;
  esac
}

probe_receipt_field() {
  local base="$1" rel="$2" expr="$3" target out rc outfile
  target="$(rv_resolved_target "$base" "state/$rel")" || { echo "not-checked|unsafe-path"; return; }
  [[ -L "$target" ]] && { echo "not-checked|unsafe-path"; return; }
  [[ -f "$target" ]] || { echo "absent|"; return; }
  _rv_file_too_big "$target" && { echo "not-checked|probe-budget"; return; }
  outfile="$(mktemp)"
  # Strict boolean wrap: ONLY a literal `true` result counts as confirmed.
  # jq's own truthy coercion (any non-null/non-false value, including a
  # non-empty STRING, is "truthy" in an if/then) would let a probe whose
  # expression accidentally returns a string still read as confirmed --
  # case 80's exact regression.
  run_with_deadline "$PROBE_DEADLINE_S" "$outfile" jq -e "((${expr}) == true)" "$target"
  rc=$?
  out="$(cat "$outfile" 2>/dev/null)"; rm -f "$outfile"
  if [[ "$rc" -eq 124 ]]; then echo "not-checked|deadline"; return; fi
  case "$(printf '%s' "$out" | tr -d '[:space:]')" in
    true) echo "confirmed|" ;;
    false) echo "absent|" ;;
    *) echo "not-checked|malformed-json" ;;
  esac
}

probe_floor_glob() {
  local glob="$1"
  [[ -f "$MANAGED_FLOOR_PATH" ]] || { echo "not-checked|no-floor-installed"; return; }
  _rv_file_too_big "$MANAGED_FLOOR_PATH" && { echo "not-checked|probe-budget"; return; }
  local found
  found="$(jq -e --arg g "$glob" '[.sandbox.filesystem.denyWrite[]?] | index($g) != null' "$MANAGED_FLOOR_PATH" 2>/dev/null)"
  case "$found" in
    true) echo "confirmed|" ;;
    false) echo "absent|" ;;
    *) echo "not-checked|malformed-json" ;;
  esac
}

# ── main ─────────────────────────────────────────────────────────────────
STACK_VERSION="unknown"
[[ -f "$SCRIPT_DIR/../VERSION" ]] && STACK_VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null)"

command -v jq >/dev/null 2>&1 || { echo '{"schema":"stack-receipt/v1","kind":"rollout","verdict":"couldnt-check","error":"jq missing"}'; exit 0; }

# The config dir ITSELF being a symlink is a refusal, not a silent
# redirection (D7: "a symlinked ~/.claude-evil pointing outside the tree is
# a refusal"; cross-family review finding — realpath alone followed it).
if [[ -L "${CONFIG_DIR%/}" ]]; then
  jq -nc --arg cd "$CONFIG_DIR" '{schema:"stack-receipt/v1", kind:"rollout", verdict:"couldnt-check", needs_human:true, error:"config-dir-symlink", evidence:{config_dir:$cd, rollouts:[]}}'
  exit 0
fi
RESOLVED_DIR="$(realpath -P "$CONFIG_DIR" 2>/dev/null || realpath "$CONFIG_DIR" 2>/dev/null || echo "$CONFIG_DIR")"
if [[ ! -d "$RESOLVED_DIR" ]]; then
  jq -nc --arg cd "$CONFIG_DIR" '{schema:"stack-receipt/v1", kind:"rollout", verdict:"couldnt-check", needs_human:true, error:"config-dir-not-found", evidence:{config_dir:$cd, rollouts:[]}}'
  exit 0
fi
# Unreadable (not merely absent): a probe that cannot even list the config
# dir must not silently report every file as "absent" (ADR-085's thesis --
# case 75). -r/-x on the dir itself catches the chmod-000 case; individual
# probes below still guard their own per-file reads too.
if [[ ! -r "$RESOLVED_DIR" || ! -x "$RESOLVED_DIR" ]]; then
  jq -nc --arg cd "$RESOLVED_DIR" '{schema:"stack-receipt/v1", kind:"rollout", verdict:"couldnt-check", needs_human:true, error:"config-dir-unreadable", evidence:{config_dir:$cd, rollouts:[]}}'
  exit 0
fi

CONFIG_DIR_LABEL="profile"
[[ "$RESOLVED_DIR" == "$HOME/.claude" ]] && CONFIG_DIR_LABEL="master"
IS_MASTER=0
[[ "$CONFIG_DIR_LABEL" == "master" ]] && IS_MASTER=1

# Deterministic, read-only host_id (no write to the target dir is permitted,
# so a persisted random token is impossible here by construction).
#
# Derived from the HOSTNAME ALONE. Folding the config dir in made it a
# per-profile id wearing a per-install name, so one machine with three
# profiles looked like three machines on the board (cross-family review
# finding). The config dir is already its own field; it does not belong
# inside this one too.
HOST_ID="h_$(printf '%s' "$(hostname 2>/dev/null)" | shasum -a 256 | cut -c1-12)"

if [[ ! -f "$ROLLOUTS_DECL" ]]; then
  jq -nc --arg cd "$RESOLVED_DIR" '{schema:"stack-receipt/v1", kind:"rollout", verdict:"couldnt-check", needs_human:true, error:"no-rollouts-declaration", evidence:{config_dir:$cd, rollouts:[]}}'
  exit 0
fi
jq -e . "$ROLLOUTS_DECL" >/dev/null 2>&1 || {
  jq -nc --arg cd "$RESOLVED_DIR" '{schema:"stack-receipt/v1", kind:"rollout", verdict:"couldnt-check", needs_human:true, error:"rollouts-declaration-invalid", evidence:{config_dir:$cd, rollouts:[]}}'
  exit 0
}

ROLLOUT_COUNT="$(jq -r '.rollouts | length' "$ROLLOUTS_DECL" 2>/dev/null)"
[[ "$ROLLOUT_COUNT" =~ ^[0-9]+$ ]] || ROLLOUT_COUNT=0

ANY_GAP=0
ANY_NOT_CHECKED=0
ROWS_JSON="[]"

for (( i=0; i<ROLLOUT_COUNT; i++ )); do
  RID="$(jq -r ".rollouts[$i].id" "$ROLLOUTS_DECL")"
  APPLIES="$(jq -r ".rollouts[$i].applies_to.config_dirs // \"all\"" "$ROLLOUTS_DECL")"
  if [[ "$APPLIES" == "master" && "$IS_MASTER" -ne 1 ]]; then
    ROWS_JSON="$(echo "$ROWS_JSON" | jq --arg id "$RID" '. + [{id:$id, state:"n/a", failed_probes:[], reason:null}]')"
    continue
  fi

  PROBE_COUNT="$(jq -r ".rollouts[$i].probes | length" "$ROLLOUTS_DECL")"
  ROLLOUT_STATE="confirmed"
  declare -a FAILED_PROBES=()
  ROLLOUT_REASON=""
  for (( j=0; j<PROBE_COUNT; j++ )); do
    PTYPE="$(jq -r ".rollouts[$i].probes[$j].type" "$ROLLOUTS_DECL")"
    RESULT=""
    case "$PTYPE" in
      file_present)
        PPATH="$(jq -r ".rollouts[$i].probes[$j].path" "$ROLLOUTS_DECL")"
        RESULT="$(probe_file_present "$RESOLVED_DIR" "$PPATH")" ;;
      file_sha)
        PPATH="$(jq -r ".rollouts[$i].probes[$j].path" "$ROLLOUTS_DECL")"
        PSHA="$(jq -r ".rollouts[$i].probes[$j].sha" "$ROLLOUTS_DECL")"
        RESULT="$(probe_file_sha "$RESOLVED_DIR" "$PPATH" "$PSHA")" ;;
      settings_json)
        PJQ="$(jq -r ".rollouts[$i].probes[$j].jq" "$ROLLOUTS_DECL")"
        RESULT="$(probe_settings_json "$RESOLVED_DIR" "$PJQ")" ;;
      receipt_field)
        PPATH="$(jq -r ".rollouts[$i].probes[$j].path" "$ROLLOUTS_DECL")"
        PJQ="$(jq -r ".rollouts[$i].probes[$j].jq" "$ROLLOUTS_DECL")"
        RESULT="$(probe_receipt_field "$RESOLVED_DIR" "$PPATH" "$PJQ")" ;;
      floor_glob)
        PGLOB="$(jq -r ".rollouts[$i].probes[$j].glob" "$ROLLOUTS_DECL")"
        RESULT="$(probe_floor_glob "$PGLOB")" ;;
      *)
        RESULT="not-checked|unknown-probe-type" ;;
    esac
    PSTATE="${RESULT%%|*}"
    PREASON="${RESULT#*|}"
    if [[ "$PSTATE" == "not-checked" ]]; then
      ROLLOUT_STATE="not-checked"
      [[ -z "$ROLLOUT_REASON" ]] && ROLLOUT_REASON="$PREASON"
      FAILED_PROBES+=("$PTYPE:$PREASON")
    elif [[ "$PSTATE" == "absent" ]]; then
      [[ "$ROLLOUT_STATE" == "confirmed" ]] && ROLLOUT_STATE="absent"
      FAILED_PROBES+=("$PTYPE")
    fi
  done

  FAILED_JSON="$(printf '%s\n' "${FAILED_PROBES[@]:-}" | jq -R 'select(length>0)' | jq -sc .)"
  ROWS_JSON="$(echo "$ROWS_JSON" | jq --arg id "$RID" --arg state "$ROLLOUT_STATE" --argjson failed "$FAILED_JSON" \
    --arg reason "$ROLLOUT_REASON" \
    '. + [{id:$id, state:$state, failed_probes:$failed, reason:(if $reason=="" then null else $reason end)}]')"

  [[ "$ROLLOUT_STATE" == "not-checked" ]] && ANY_NOT_CHECKED=1
  [[ "$ROLLOUT_STATE" == "absent" ]] && ANY_GAP=1
  unset FAILED_PROBES
done

VERDICT="all-confirmed"
[[ "$ANY_GAP" -eq 1 ]] && VERDICT="gaps"
[[ "$ANY_NOT_CHECKED" -eq 1 ]] && VERDICT="couldnt-check"
NEEDS_HUMAN=true
[[ "$VERDICT" == "all-confirmed" ]] && NEEDS_HUMAN=false

OUT_JSON="$(jq -nc \
  --arg schema "stack-receipt/v1" --arg as_of "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg version "$STACK_VERSION" --arg cd "$RESOLVED_DIR" --arg label "$CONFIG_DIR_LABEL" \
  --arg host "$HOST_ID" --argjson rollouts "$ROWS_JSON" --arg verdict "$VERDICT" --argjson needs_human "$NEEDS_HUMAN" \
  --argjson degraded "$([[ "$DEADLINE_DEGRADED" -eq 1 ]] && echo true || echo false)" \
  '{schema:$schema, kind:"rollout", writer:"rollout-verify.sh@1", as_of:$as_of, max_age_s:604800,
    subject:{kind:"config-dir", path:null, content_sha:null, patch_sha:null, base_commit:null, reviewed_head:null,
             repo_root:$cd, repo_hash:$host, mint_head_commit:null},
    verdict:$verdict, reason:null, needs_human:$needs_human,
    evidence:{stack_version:$version, config_dir:$cd, config_dir_label:$label, host_id:$host,
              rollouts:$rollouts, deadline_degraded:$degraded},
    error:null}')"

if [[ "$JSON_MODE" -eq 1 ]]; then
  printf '%s\n' "$OUT_JSON"
else
  printf '%s\n' "$OUT_JSON" | jq .
fi

case "$VERDICT" in
  all-confirmed) exit 0 ;;
  gaps) exit 1 ;;
  *) exit 2 ;;
esac
