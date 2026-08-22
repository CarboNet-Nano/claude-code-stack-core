#!/usr/bin/env bash
# scripts/fleet-report.sh — Phase-1 fleet rollout board (ADR-087 D8).
#
# Usage: fleet-report.sh [--roster <p>] [--json]
#
# Expected universe = config/rollouts.json's declared rollouts x
# config/fleet-roster.json's declared config dirs (committed) PLUS every
# ~/.claude / ~/.claude-* directory discovered on THIS machine. Expected
# comes from the ROSTER, not from what was found -- an install that never
# reports is invisible, the exact defect this ADR closes. A discovered dir
# absent from the roster is UNROSTERED (an OBSERVED row). A rostered dir not
# present locally is NOT-CHECKED / not-on-this-machine.
#
# Every cell renders in ADR-085 D4's four-state vocabulary:
#   confirmed -> CLEAN       (checked, the rollout is live)
#   absent    -> OBSERVED    (ran, found a gap -- does not block; a fact)
#   not-checked -> NOT-CHECKED
#   n/a       -> SKIPPED     (this rollout's applies_to excludes this dir)
#
# Exit: 0 all-confirmed, 1 gaps, 2 any not-checked. A prober that could not
# look exits WORSE than one that found a gap -- a found gap is knowledge.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLOUT_VERIFY="$SCRIPT_DIR/rollout-verify.sh"
ROSTER="$SCRIPT_DIR/../config/fleet-roster.json"
# RV_ROLLOUTS_DECL: same test-only override this script forwards to
# rollout-verify.sh -- must read the SAME declared universe that script uses,
# or the row ids here would never match rollout-verify's per-column output.
ROLLOUTS_DECL="${RV_ROLLOUTS_DECL:-$SCRIPT_DIR/../config/rollouts.json}"

JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --roster) ROSTER="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    *) echo "Usage: $0 [--roster <p>] [--json]" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fleet-report.sh: jq required" >&2; exit 2; }
[[ -f "$ROSTER" ]] || { echo "fleet-report.sh: roster not found: $ROSTER" >&2; exit 2; }
jq -e . "$ROSTER" >/dev/null 2>&1 || { echo "fleet-report.sh: roster is not valid JSON: $ROSTER" >&2; exit 2; }
[[ -f "$ROLLOUTS_DECL" ]] || { echo "fleet-report.sh: rollouts declaration not found: $ROLLOUTS_DECL" >&2; exit 2; }

# ── expected universe (roster) ──────────────────────────────────────────────
declare -a COL_LABELS=() COL_PATHS=() COL_UNROSTERED=()
N_EXPECTED="$(jq -r '.config_dirs | length' "$ROSTER")"
for (( i=0; i<N_EXPECTED; i++ )); do
  L="$(jq -r ".config_dirs[$i].label" "$ROSTER")"
  P="$(jq -r ".config_dirs[$i].path" "$ROSTER")"
  P="${P/#\~/$HOME}"
  COL_LABELS+=("$L"); COL_PATHS+=("$P"); COL_UNROSTERED+=("0")
done

# ── discovered dirs on this machine, not already in the roster -> UNROSTERED
DISCOVERED=()
[[ -d "$HOME/.claude" ]] && DISCOVERED+=("$HOME/.claude")
for d in "$HOME"/.claude-*; do
  [[ -d "$d" ]] && DISCOVERED+=("$d")
done
for d in "${DISCOVERED[@]:-}"; do
  [[ -z "$d" ]] && continue
  KNOWN=0
  for p in "${COL_PATHS[@]:-}"; do [[ "$p" == "$d" ]] && KNOWN=1; done
  if [[ "$KNOWN" -eq 0 ]]; then
    LABEL="$(basename "$d")"
    COL_LABELS+=("$LABEL (unrostered)"); COL_PATHS+=("$d"); COL_UNROSTERED+=("1")
  fi
done

N_COLS="${#COL_LABELS[@]}"

# ── rollout row ids (declared universe) ─────────────────────────────────────
ROLLOUT_IDS=()
N_ROLLOUTS="$(jq -r '.rollouts | length' "$ROLLOUTS_DECL")"
for (( i=0; i<N_ROLLOUTS; i++ )); do
  ROLLOUT_IDS+=("$(jq -r ".rollouts[$i].id" "$ROLLOUTS_DECL")")
done

# ── probe every locally-present column; NOT-CHECKED/not-on-this-machine for
# every rollout in a column that isn't present on this machine at all ───────
PROBED_LOCALLY=0
NOT_ON_MACHINE=0
declare -a COL_STATE_JSON=()   # one jq object per column: {id: state, ...}
declare -a COL_PRESENT=()

d4_map() { # <rv_state> -> D4 vocabulary
  case "$1" in
    confirmed) echo "CLEAN" ;;
    absent) echo "OBSERVED" ;;
    n/a) echo "SKIPPED" ;;
    *) echo "NOT-CHECKED" ;;
  esac
}

for (( c=0; c<N_COLS; c++ )); do
  P="${COL_PATHS[$c]}"
  if [[ -d "$P" ]]; then
    PROBED_LOCALLY=$((PROBED_LOCALLY+1))
    COL_PRESENT+=("1")
    RV_OUT="$(bash "$ROLLOUT_VERIFY" --config-dir "$P" --json 2>/dev/null)"
    ROWS="$(echo "$RV_OUT" | jq -c '.evidence.rollouts // []' 2>/dev/null)"
    [[ -z "$ROWS" || "$ROWS" == "null" ]] && ROWS="[]"
    MAP="{}"
    for (( i=0; i<N_ROLLOUTS; i++ )); do
      RID="${ROLLOUT_IDS[$i]}"
      RSTATE="$(echo "$ROWS" | jq -r --arg id "$RID" '.[] | select(.id==$id) | .state // empty' 2>/dev/null)"
      [[ -z "$RSTATE" ]] && RSTATE="not-checked"
      RREASON="$(echo "$ROWS" | jq -r --arg id "$RID" '.[] | select(.id==$id) | .reason // empty' 2>/dev/null)"
      D4STATE="$(d4_map "$RSTATE")"
      MAP="$(echo "$MAP" | jq --arg id "$RID" --arg s "$D4STATE" --arg rv "$RSTATE" --arg reason "$RREASON" \
        '. + {($id): {state:$s, rv_state:$rv, reason:(if $reason=="" then null else $reason end)}}')"
    done
    COL_STATE_JSON+=("$MAP")
  else
    NOT_ON_MACHINE=$((NOT_ON_MACHINE+1))
    COL_PRESENT+=("0")
    MAP="{}"
    for (( i=0; i<N_ROLLOUTS; i++ )); do
      RID="${ROLLOUT_IDS[$i]}"
      MAP="$(echo "$MAP" | jq --arg id "$RID" \
        '. + {($id): {state:"NOT-CHECKED", rv_state:"not-checked", reason:"not-on-this-machine"}}')"
    done
    COL_STATE_JSON+=("$MAP")
  fi
done

NOTE_SENTENCE="A missing row is NOT a pass."
CLAIM_SENTENCE="Rows marked (claim) are self-reported and unverified."

# ── aggregate gap / not-checked counts (for exit code + summary line) ──────
GAP_COUNT=0
NOTCHECKED_COUNT=0
for (( c=0; c<N_COLS; c++ )); do
  for (( i=0; i<N_ROLLOUTS; i++ )); do
    RID="${ROLLOUT_IDS[$i]}"
    S="$(echo "${COL_STATE_JSON[$c]}" | jq -r --arg id "$RID" '.[$id].state')"
    [[ "$S" == "OBSERVED" ]] && GAP_COUNT=$((GAP_COUNT+1))
    [[ "$S" == "NOT-CHECKED" ]] && NOTCHECKED_COUNT=$((NOTCHECKED_COUNT+1))
  done
done

if [[ "$JSON_MODE" -eq 1 ]]; then
  COLS_JSON="[]"
  for (( c=0; c<N_COLS; c++ )); do
    COLS_JSON="$(echo "$COLS_JSON" | jq --arg label "${COL_LABELS[$c]}" --arg path "${COL_PATHS[$c]}" \
      --argjson unrostered "$([[ "${COL_UNROSTERED[$c]}" == "1" ]] && echo true || echo false)" \
      --argjson present "$([[ "${COL_PRESENT[$c]}" == "1" ]] && echo true || echo false)" \
      --argjson rows "${COL_STATE_JSON[$c]}" \
      '. + [{label:$label, path:$path, unrostered:$unrostered, present_on_this_machine:$present, rollouts:$rows}]')"
  done
  jq -nc --arg schema "stack-fleet-report/v1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson expected "$N_COLS" --argjson probed "$PROBED_LOCALLY" --argjson missing "$NOT_ON_MACHINE" \
    --arg note "$NOTE_SENTENCE" --arg claim_note "$CLAIM_SENTENCE" --argjson columns "$COLS_JSON" \
    --argjson gap_count "$GAP_COUNT" --argjson notchecked_count "$NOTCHECKED_COUNT" \
    '{schema:$schema, as_of:$ts, expected_config_dirs:$expected, probed_locally:$probed,
      not_on_this_machine:$missing, note:$note, claim_note:$claim_note,
      gap_count:$gap_count, not_checked_count:$notchecked_count, columns:$columns,
      upload: [ $columns[] | {config_dir_label: .label, rollouts: [.rollouts | to_entries[] | {id: .key, state: .value.state}]} ]
    }'
else
  echo "FLEET ROLLOUT BOARD — $(date -u +%Y-%m-%dT%H:%M)Z"
  echo "Expected: ${N_COLS} config dir(s) (roster: $(basename "$ROSTER"))"
  echo "Probed locally: ${PROBED_LOCALLY}   |   Not on this machine: ${NOT_ON_MACHINE}"
  echo "$CLAIM_SENTENCE"
  echo ""
  HEADER="rollout"
  for (( c=0; c<N_COLS; c++ )); do
    LBL="${COL_LABELS[$c]}"
    [[ "${COL_PRESENT[$c]}" == "0" ]] && LBL="${LBL} (claim)"
    HEADER="$HEADER	${LBL}"
  done
  echo "$HEADER"
  for (( i=0; i<N_ROLLOUTS; i++ )); do
    RID="${ROLLOUT_IDS[$i]}"
    LINE="$RID"
    for (( c=0; c<N_COLS; c++ )); do
      S="$(echo "${COL_STATE_JSON[$c]}" | jq -r --arg id "$RID" '.[$id].state')"
      LINE="$LINE	${S}"
    done
    echo "$LINE"
    for (( c=0; c<N_COLS; c++ )); do
      S="$(echo "${COL_STATE_JSON[$c]}" | jq -r --arg id "$RID" '.[$id].state')"
      RSN="$(echo "${COL_STATE_JSON[$c]}" | jq -r --arg id "$RID" '.[$id].reason // empty')"
      if [[ "$S" != "CLEAN" && "$S" != "SKIPPED" ]]; then
        echo "  └ ${COL_LABELS[$c]}: ${S}$([[ -n "$RSN" ]] && echo " — ${RSN}")"
      fi
    done
  done
  echo ""
  echo "${GAP_COUNT} gap(s), ${NOTCHECKED_COUNT} not-checked. ${NOTE_SENTENCE}"
fi

if (( NOTCHECKED_COUNT > 0 )); then exit 2; fi
if (( GAP_COUNT > 0 )); then exit 1; fi
exit 0
