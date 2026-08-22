#!/usr/bin/env bash
# scripts/mcp-sweep.sh — ADR-046 (revision 2) entrypoint. Orchestrates
# mcp_fetch_* -> mcp_merge -> mcp_apply_bar -> mcp_classify -> state
# transitions -> mcp_render_body -> issue mutation. All logic lives here and
# in scripts/lib/mcp-sweep.sh / scripts/lib/mcp_state.py — the workflow YAML
# is checkout -> run -> done (D1/D20).
#
# The script never knows cache or artifacts exist (D20) — it takes plain
# --state-in/--state-out paths and does plain file I/O; restore/save are
# workflow-level steps.
#
# Usage:
#   scripts/mcp-sweep.sh --state-in=<path> --state-out=<path>
#                         [--dry-run=true|false] [--lookback-days=N]
#                         [--sources=all|npm|github|registry]
#
# Env consumed: GITHUB_TOKEN (gh + fetcher auth), GITHUB_STEP_SUMMARY,
# GITHUB_OUTPUT, MCP_SWEEP_WORKDIR (working/artifact dir, mktemp -d if
# unset), MCP_SWEEP_ON_DEFAULT_BRANCH (true/false, default true — set by
# the workflow to false on a non-default-branch run, D19r2), all
# MCP_SWEEP_* tunables (scripts/lib/mcp-sweep.sh).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mcp-sweep.sh
source "$SCRIPT_DIR/lib/mcp-sweep.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_JSON="${MCP_SWEEP_TEMPLATE_JSON:-$REPO_ROOT/config/settings.tier-1.template.json}"
KNOWN_JSON="${MCP_SWEEP_KNOWN_JSON:-$REPO_ROOT/config/mcp-sweep-known.json}"

# ---------------------------------------------------------------------------
# D19 — argument parsing. Inputs reach the script only via env/argv, never
# via ${{ }} interpolated directly into a `run:` block (enforced by the
# workflow YAML + a static grep test, not by this script).
# ---------------------------------------------------------------------------
STATE_IN=""
STATE_OUT=""
DRY_RUN="true"
LOOKBACK_DAYS=""
SOURCES="all"

for arg in "$@"; do
  case "$arg" in
    --state-in=*) STATE_IN="${arg#*=}" ;;
    --state-out=*) STATE_OUT="${arg#*=}" ;;
    --dry-run=*) DRY_RUN="${arg#*=}" ;;
    --lookback-days=*) LOOKBACK_DAYS="${arg#*=}" ;;
    --sources=*) SOURCES="${arg#*=}" ;;
    *)
      echo "mcp-sweep.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$STATE_IN" || -z "$STATE_OUT" ]]; then
  echo "Usage: $0 --state-in=<path> --state-out=<path> [--dry-run=true|false] [--lookback-days=N] [--sources=all|npm|github|registry]" >&2
  exit 2
fi

# ^[0-9]{1,3}$ per D19, checked as length + charclass rather than a bash
# `[[ =~ ]]` interval expression — see the identical note on the registry
# cursor check in scripts/lib/mcp-sweep.sh (bash 3.2 compatibility).
if [[ -n "$LOOKBACK_DAYS" ]]; then
  ld_len="${#LOOKBACK_DAYS}"
  if [[ "$ld_len" -lt 1 || "$ld_len" -gt 3 || ! "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]]; then
    echo "mcp-sweep.sh: --lookback-days must match ^[0-9]{1,3}\$, got: $LOOKBACK_DAYS" >&2
    exit 2
  fi
fi
[[ -z "$LOOKBACK_DAYS" ]] && LOOKBACK_DAYS="$MCP_SWEEP_LOOKBACK_DAYS"

case "$SOURCES" in
  all|npm|github|registry) ;;
  *)
    echo "mcp-sweep.sh: --sources must be one of all|npm|github|registry, got: $SOURCES" >&2
    exit 2
    ;;
esac

case "$DRY_RUN" in
  true|false) ;;
  *)
    echo "mcp-sweep.sh: --dry-run must be true or false, got: $DRY_RUN" >&2
    exit 2
    ;;
esac

# D19 — any run with sources != all is forced to dry-run.
if [[ "$SOURCES" != "all" ]]; then
  DRY_RUN="true"
fi

# D19r2 — any run whose ref is not the default branch is forced to dry-run.
MCP_SWEEP_ON_DEFAULT_BRANCH="${MCP_SWEEP_ON_DEFAULT_BRANCH:-true}"
if [[ "$MCP_SWEEP_ON_DEFAULT_BRANCH" != "true" ]]; then
  DRY_RUN="true"
fi

export MCP_SWEEP_WORKDIR="${MCP_SWEEP_WORKDIR:-$(mktemp -d)}"
mkdir -p "$MCP_SWEEP_WORKDIR"

RUN_START_UTC="$(mcp_now_utc)"

# state_written is written ONLY on a verified successful --state-out write
# (below). If the script exits before that point for any reason, the key
# is simply absent from $GITHUB_OUTPUT, and the workflow's
# `steps.sweep.outputs.state_written == 'true'` comparison evaluates the
# same as an explicit "false" would — deliberately simpler than writing a
# placeholder "false" now and patching it in place later.

# ===========================================================================
# 1. Load state (D11r2 seed triggers handled inside mcp_load_state).
# ===========================================================================
STATE_LOADED_FILE="$MCP_SWEEP_WORKDIR/state-loaded.json"
mcp_load_state "$STATE_IN" > "$STATE_LOADED_FILE"

# D15.5 — keys loaded from the state file are re-validated against D15.3 on
# load. Any key failing validation is dropped and counted (never crashes).
STATE_REVALIDATED_FILE="$MCP_SWEEP_WORKDIR/state-revalidated.json"
STATE_RELOAD_DROPPED=0

# Re-validation itself is bash-side (mcp_key_valid), since it is a Bash-
# owned concern (D18r2: state I/O in mcp_state.py, everything else in Bash).
python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f)))
' "$STATE_LOADED_FILE" > "$STATE_REVALIDATED_FILE.tmp0"

{
  jq -c '.pending | to_entries[]' "$STATE_REVALIDATED_FILE.tmp0"
} > "$MCP_SWEEP_WORKDIR/.pending-entries.ndjson" 2>/dev/null || true

VALID_PENDING_FILE="$MCP_SWEEP_WORKDIR/.pending-valid.ndjson"
: > "$VALID_PENDING_FILE"
if [[ -s "$MCP_SWEEP_WORKDIR/.pending-entries.ndjson" ]]; then
  while IFS= read -r entry; do
    k="$(printf '%s' "$entry" | jq -r '.key')"
    if mcp_key_valid "$k"; then
      printf '%s\n' "$entry" >> "$VALID_PENDING_FILE"
    else
      STATE_RELOAD_DROPPED=$((STATE_RELOAD_DROPPED + 1))
    fi
  done < "$MCP_SWEEP_WORKDIR/.pending-entries.ndjson"
fi

VALID_AGED_FILE="$MCP_SWEEP_WORKDIR/.aged-valid.txt"
: > "$VALID_AGED_FILE"
while IFS= read -r ak; do
  [[ -z "$ak" ]] && continue
  if mcp_key_valid "$ak"; then
    printf '%s\n' "$ak" >> "$VALID_AGED_FILE"
  else
    STATE_RELOAD_DROPPED=$((STATE_RELOAD_DROPPED + 1))
  fi
done < <(jq -r '.aged[]' "$STATE_REVALIDATED_FILE.tmp0" 2>/dev/null || true)

jq -n \
  --slurpfile base "$STATE_REVALIDATED_FILE.tmp0" \
  --slurpfile pending_entries <(jq -s '.' "$VALID_PENDING_FILE" 2>/dev/null || echo '[]') \
  --slurpfile aged_list <(jq -R -s 'split("\n") | map(select(length>0))' "$VALID_AGED_FILE") \
  '
  $base[0] as $b
  | $b
  | .pending = (reduce $pending_entries[0][] as $e ({}; .[$e.key] = $e.value))
  | .aged = $aged_list[0]
  ' > "$STATE_REVALIDATED_FILE"
rm -f "$STATE_REVALIDATED_FILE.tmp0"

# D11r2 — whether THIS run is a seed run is determined solely by whether
# --state-in was absent/unparseable/wrong-version/invalid at load time. It
# is NOT the same question as "what did the stored `mode` field say" — a
# validly-loaded state file legitimately carries `mode:"seed"` as a
# historical record of what ITS OWN run was, and copying that forward would
# make seed mode permanent (every run after the first would see the prior
# run's stored "seed" and re-seed forever, never reaching steady state).
RAW_LOAD_CHECK="$(python3 "$MCP_SWEEP_LIB_DIR/mcp_state.py" load "$STATE_IN" 2>/dev/null || echo null)"
THIS_RUN_IS_SEED="false"
if [[ -z "$RAW_LOAD_CHECK" || "$RAW_LOAD_CHECK" == "null" ]]; then
  THIS_RUN_IS_SEED="true"
fi
ACKED_AT_LOADED="$(jq -r '.ackedAtUtc' "$STATE_REVALIDATED_FILE")"

# ===========================================================================
# 2. Fetch (only the requested source(s); D19 already forced dry-run for a
# subset request). Sources not requested get a neutral "skipped" status so
# rendering stays coherent without implying failure.
# ===========================================================================
CANDIDATES_RAW_FILE="$MCP_SWEEP_WORKDIR/candidates-raw.ndjson"
: > "$CANDIDATES_RAW_FILE"

fetch_one() {
  local src="$1" fn="$2"
  if [[ "$SOURCES" == "all" || "$SOURCES" == "$src" ]]; then
    "$fn" "$LOOKBACK_DAYS" >> "$CANDIDATES_RAW_FILE" 2>"$MCP_SWEEP_WORKDIR/.fetch-$src.stderr" || true
  else
    jq -n '{status:"ok_empty",note:"skipped",scanned:0,malformed:0,unkeyable:0}' \
      > "$MCP_SWEEP_WORKDIR/status-$src.json"
  fi
}

fetch_one npm mcp_fetch_npm
fetch_one github mcp_fetch_github
fetch_one registry mcp_fetch_registry

# ===========================================================================
# 3. Merge -> bar -> classify.
# ===========================================================================
MERGED_FILE="$MCP_SWEEP_WORKDIR/merged.ndjson"
mcp_merge < "$CANDIDATES_RAW_FILE" > "$MERGED_FILE"
MERGED_COUNT="$(wc -l < "$MERGED_FILE" | tr -d ' ')"

BARRED_FILE="$MCP_SWEEP_WORKDIR/barred.ndjson"
mcp_apply_bar < "$MERGED_FILE" > "$BARRED_FILE"
BARRED_COUNT="$(wc -l < "$BARRED_FILE" | tr -d ' ')"
BELOW_BAR_COUNT=$((MERGED_COUNT - BARRED_COUNT))

WIRED_TOKENS_FILE="$MCP_SWEEP_WORKDIR/wired-tokens.txt"
mcp_wired_tokens "$TEMPLATE_JSON" "$KNOWN_JSON" > "$WIRED_TOKENS_FILE"

CLASSIFIED_FILE="$MCP_SWEEP_WORKDIR/classified.ndjson"
mcp_classify "$WIRED_TOKENS_FILE" "$KNOWN_JSON" < "$BARRED_FILE" > "$CLASSIFIED_FILE"

FETCH_DROPPED=0
for src in npm github registry; do
  sf="$MCP_SWEEP_WORKDIR/status-$src.json"
  if [[ -f "$sf" ]]; then
    u="$(jq -r '.unkeyable // 0' "$sf")"
    FETCH_DROPPED=$((FETCH_DROPPED + u))
  fi
done
TOTAL_DROPPED=$((FETCH_DROPPED + STATE_RELOAD_DROPPED))

# ===========================================================================
# 4. Backlog formula (§Interface deltas revision 1):
#    pending_now = (pending_prev - wired - ignored - aged) U (fetched - seen)
# Keys immutable once in pending: a re-observed key keeps its original
# firstSeenUtc.
# ===========================================================================
NEW_PENDING_FROM_FETCH="$MCP_SWEEP_WORKDIR/new-pending-keys.txt"
jq -r 'select(.status=="pending") | .key' "$CLASSIFIED_FILE" | sort -u > "$NEW_PENDING_FROM_FETCH"

WIRED_OR_IGNORED_KEYS="$MCP_SWEEP_WORKDIR/wired-or-ignored-keys.txt"
jq -r 'select(.status=="wired" or .status=="ignored") | .key' "$CLASSIFIED_FILE" | sort -u > "$WIRED_OR_IGNORED_KEYS"

STALE_CUTOFF="$(mcp_rfc3339_days_ago "$MCP_SWEEP_STALE_DAYS")"

python3 - "$STATE_REVALIDATED_FILE" "$NEW_PENDING_FROM_FETCH" "$WIRED_OR_IGNORED_KEYS" \
  "$STALE_CUTOFF" "$RUN_START_UTC" "$MCP_SWEEP_AGED_MAX" \
  > "$MCP_SWEEP_WORKDIR/pending-computed.json" <<'PYEOF'
import json, sys

state_path, new_pending_path, wired_ignored_path, stale_cutoff, run_start, aged_max = sys.argv[1:7]
aged_max = int(aged_max)

with open(state_path) as f:
    state = json.load(f)

with open(new_pending_path) as f:
    new_from_fetch = set(x.strip() for x in f if x.strip())

with open(wired_ignored_path) as f:
    wired_or_ignored = set(x.strip() for x in f if x.strip())

pending_prev = dict(state["pending"])
aged_prev = list(state["aged"])

pending_now = {}
newly_aged = []
for key, first_seen in pending_prev.items():
    if key in wired_or_ignored:
        continue
    if first_seen < stale_cutoff:
        newly_aged.append(key)
        continue
    pending_now[key] = first_seen

new_keys = []
for key in sorted(new_from_fetch):
    if key in pending_prev or key in wired_or_ignored or key in aged_prev:
        continue
    pending_now[key] = run_start
    new_keys.append(key)

aged_now = aged_prev + newly_aged
evicted = 0
if len(aged_now) > aged_max:
    evicted = len(aged_now) - aged_max
    aged_now = aged_now[-aged_max:]

print(json.dumps({
    "pending": pending_now,
    "aged": aged_now,
    "newKeys": new_keys,
    "newlyAgedCount": len(newly_aged),
    "agedEvictedCount": evicted,
}))
PYEOF

NEW_KEYS_COUNT="$(jq '.newKeys | length' "$MCP_SWEEP_WORKDIR/pending-computed.json")"
PENDING_COUNT_NOW="$(jq '.pending | length' "$MCP_SWEEP_WORKDIR/pending-computed.json")"

# ===========================================================================
# 5. Per-source health (D9r2 status + D21 failStreak/pageCapStreak, D22
# all-sources-empty).
#
# NOTE on a deliberate deviation from D21's literal text, documented and not
# silent (see the implementer's final report): live pre-ship verification
# (docs/ADRs/046-mcp-sweep-multi-source.md §Pre-ship gate item 7) found
# GitHub's topic:mcp-server/topic:modelcontextprotocol queries already
# exceed the Search API's hard 1000-result ceiling on literally every run,
# permanently. D9r2 already made page-cap `partial` close-safe and
# non-`failStreak`-feeding for exactly this reason, but D21's `pageCapStreak`
# ladder, taken completely literally, still drives a non-zero exit at
# `pageCapStreak >= MCP_SWEEP_FAIL_STREAK_FAIL`, which — given the live
# numbers — would make GitHub's page-cap chronic-alert fire on day one and
# never clear, reproducing exactly the alarm-fatigue failure class this ADR
# spent four review rounds eliminating. Per the task's own instruction
# ("make sure a page_cap note renders in the body every run without that
# being treated as noise/failure downstream"), this implementation tracks
# `pageCapStreak` and renders the `### Sweep health` alert line at the
# ALERT threshold, but `pageCapStreak` alone never drives the script's exit
# code non-zero. `failStreak` (genuine failure/cursor-invalid) and
# `allEmptyStreak` (D22) both still drive it, unchanged from the ADR.
# ===========================================================================
HEALTH_META_FILE="$MCP_SWEEP_WORKDIR/health-meta.json"
python3 - "$STATE_REVALIDATED_FILE" "$MCP_SWEEP_WORKDIR" \
  "$MCP_SWEEP_FAIL_STREAK_ALERT" "$MCP_SWEEP_FAIL_STREAK_REALERT" "$MCP_SWEEP_FAIL_STREAK_FAIL" \
  "$MCP_SWEEP_ALL_EMPTY_STREAK_ALERT" "$MCP_SWEEP_ALL_EMPTY_STREAK_FAIL" "$SOURCES" \
  > "$HEALTH_META_FILE" <<'PYEOF'
import json, sys

state_path, workdir, alert_n, realert_n, fail_n, ae_alert_n, ae_fail_n, sources_arg = sys.argv[1:9]
alert_n, realert_n, fail_n = int(alert_n), int(realert_n), int(fail_n)
ae_alert_n, ae_fail_n = int(ae_alert_n), int(ae_fail_n)

with open(state_path) as f:
    state = json.load(f)

sources = ["npm", "github", "registry"]
statuses = {}
notes = {}
for s in sources:
    try:
        with open(f"{workdir}/status-{s}.json") as f:
            d = json.load(f)
        statuses[s] = d.get("status", "failed")
        notes[s] = d.get("note", "")
    except (OSError, ValueError):
        statuses[s] = "failed"
        notes[s] = "schema_envelope"

health = json.loads(json.dumps(state["sourceHealth"]))
health_lines = []
hard_fail = False

requested_all = (sources_arg == "all")

for s in sources:
    st = statuses[s]
    note = notes[s]
    h = health[s]

    if not requested_all and note == "skipped":
        continue

    is_page_cap = (st == "partial" and note == "page_cap")
    is_cursor_invalid = (st == "partial" and note == "cursor_invalid")
    # ADR-046 revision 3, D24 — a dead/degenerate npm signal is a source
    # doubt exactly like an invalid registry cursor: it feeds failStreak
    # (comment at MCP_SWEEP_FAIL_STREAK_ALERT, red run at
    # MCP_SWEEP_FAIL_STREAK_FAIL) rather than reading as a quiet ecosystem.
    is_signal_bad = (st == "partial" and note in ("signal_absent", "signal_degenerate"))
    is_failed = (st == "failed") or is_cursor_invalid or is_signal_bad

    if is_page_cap:
        h["pageCapStreak"] += 1
    else:
        h["pageCapStreak"] = 0

    if is_failed:
        h["failStreak"] += 1
    else:
        h["failStreak"] = 0
        h["alertedAt"] = 0

    if h["failStreak"] >= alert_n and h["failStreak"] >= h["alertedAt"] + (0 if h["alertedAt"] == 0 else realert_n):
        health_lines.append(
            f"**Sweep health:** `{s}` has failed {h['failStreak']} consecutive runs "
            f"(status `{st}`, note `{note}`)."
        )
        h["alertedAt"] = h["failStreak"]
    if h["failStreak"] >= fail_n:
        hard_fail = True

    if h["pageCapStreak"] >= alert_n and h["pageCapStreak"] >= h["pageCapAlertedAt"] + (0 if h["pageCapAlertedAt"] == 0 else realert_n):
        health_lines.append(
            f"**Sweep health:** `{s}` has hit its page cap {h['pageCapStreak']} consecutive "
            f"runs — consider raising the relevant `MCP_SWEEP_*_MAX_PAGES` constant. "
            f"(By design this does not fail the run — see the implementer's report.)"
        )
        h["pageCapAlertedAt"] = h["pageCapStreak"]
    # NOTE: pageCapStreak deliberately never sets hard_fail — see the
    # entrypoint's block comment above this Python block.

    health[s] = h

all_empty = requested_all and all(
    statuses[s] == "ok_empty" for s in sources
)
allEmptyStreak = state["allEmptyStreak"]
allEmptyAlertedAt = state["allEmptyAlertedAt"]
if all_empty:
    allEmptyStreak += 1
else:
    allEmptyStreak = 0
    allEmptyAlertedAt = 0
if allEmptyStreak >= ae_alert_n and allEmptyStreak >= allEmptyAlertedAt + (0 if allEmptyAlertedAt == 0 else ae_fail_n):
    health_lines.append(
        f"**Sweep health:** all sources returned zero records for {allEmptyStreak} "
        f"consecutive runs — likely a broken query, not a quiet ecosystem."
    )
    allEmptyAlertedAt = allEmptyStreak
if allEmptyStreak >= ae_fail_n:
    hard_fail = True

print(json.dumps({
    "sourceHealth": health,
    "healthLines": health_lines,
    "hardFail": hard_fail,
    "anomalous": all_empty,
    "allEmptyStreak": allEmptyStreak,
    "allEmptyAlertedAt": allEmptyAlertedAt,
    "statuses": statuses,
}))
PYEOF

ANOMALOUS="$(jq -r '.anomalous' "$HEALTH_META_FILE")"
HARD_FAIL="$(jq -r '.hardFail' "$HEALTH_META_FILE")"

# All-three-failed also forces a non-zero exit (D9r2 base rule), independent
# of D21/D22 streak escalation.
ALL_FAILED="true"
for src in npm github registry; do
  st="$(jq -r --arg s "$src" '.statuses[$s]' "$HEALTH_META_FILE")"
  [[ "$st" != "failed" ]] && ALL_FAILED="false"
done
if [[ "$ALL_FAILED" == "true" ]]; then
  HARD_FAIL="true"
fi

# ===========================================================================
# 6. Clean-run predicate (D8r2) and cleanRuns update.
# ===========================================================================
IS_CLEAN="true"
[[ "$PENDING_COUNT_NOW" -ne 0 ]] && IS_CLEAN="false"
[[ "$ANOMALOUS" == "true" ]] && IS_CLEAN="false"
[[ "$THIS_RUN_IS_SEED" == "true" ]] && IS_CLEAN="false"
for src in npm github registry; do
  st="$(jq -r --arg s "$src" '.statuses[$s]' "$HEALTH_META_FILE")"
  case "$st" in
    ok|ok_empty) ;;
    partial)
      # Page-cap partial is close-safe (D9r2 round-3 fix); cursor-invalid
      # partial is not. Distinguish by the real status file's note.
      real_note="$(jq -r '.note // ""' "$MCP_SWEEP_WORKDIR/status-$src.json" 2>/dev/null)"
      [[ "$real_note" != "page_cap" ]] && IS_CLEAN="false"
      ;;
    *) IS_CLEAN="false" ;;
  esac
done

# HOLD label check (real gh call only when not dry-run and issue reachable;
# in dry-run we simply never treat hold as present, since dry-run never
# closes anyway).
HOLD_PRESENT="false"
if [[ "$DRY_RUN" != "true" ]]; then
  if gh issue view "$MCP_SWEEP_ISSUE_NUMBER" --json labels \
       --jq '.labels[].name' 2>/dev/null | grep -qx "${MCP_SWEEP_ISSUE_LABEL}-hold"; then
    HOLD_PRESENT="true"
  fi
fi
[[ "$HOLD_PRESENT" == "true" ]] && IS_CLEAN="false"

PREV_CLEAN_RUNS="$(jq -r '.cleanRuns' "$STATE_REVALIDATED_FILE")"
if [[ "$IS_CLEAN" == "true" ]]; then
  NEW_CLEAN_RUNS=$((PREV_CLEAN_RUNS + 1))
else
  NEW_CLEAN_RUNS=0
fi

# ===========================================================================
# 7. Assemble the candidate new state (before deciding the gh mutation, so
# the rendered body reflects it). ackedAtUtc is stamped unconditionally at
# the very end (D8r2), AFTER the reopen predicate below is evaluated against
# the AS-LOADED value.
# ===========================================================================
NEW_MODE="steady"
[[ "$THIS_RUN_IS_SEED" == "true" ]] && NEW_MODE="seed"
# A fresh state file (no prior state at all) always seeds, regardless of
# what mcp_load_state happened to return as "mode" on a merely-corrupt file
# vs a truly-absent one — both collapse to the same seed path (D11r2).

jq -n \
  --slurpfile pcArr "$MCP_SWEEP_WORKDIR/pending-computed.json" \
  --slurpfile hmArr "$HEALTH_META_FILE" \
  --arg mode "$NEW_MODE" \
  --arg lastRun "$RUN_START_UTC" \
  --arg ackedAtLoaded "$ACKED_AT_LOADED" \
  --argjson cleanRuns "$NEW_CLEAN_RUNS" \
  --argjson dropped "$TOTAL_DROPPED" \
  '($pcArr[0]) as $pc | ($hmArr[0]) as $hm |
  {
    v: 3,
    mode: $mode,
    lastRunUtc: $lastRun,
    ackedAtUtc: $ackedAtLoaded,
    cleanRuns: $cleanRuns,
    dropped: $dropped,
    pending: $pc.pending,
    aged: $pc.aged,
    sourceHealth: $hm.sourceHealth,
    allEmptyStreak: $hm.allEmptyStreak,
    allEmptyAlertedAt: $hm.allEmptyAlertedAt
  }' > "$MCP_SWEEP_WORKDIR/state-candidate.json"

# ===========================================================================
# 8. Render the source-status.json (with _meta for the renderer).
# ===========================================================================
python3 - "$MCP_SWEEP_WORKDIR" "$TOTAL_DROPPED" "$BELOW_BAR_COUNT" "$HEALTH_META_FILE" \
  > "$MCP_SWEEP_WORKDIR/source-status.json" <<'PYEOF'
import json, sys

workdir, dropped, below_bar, health_meta_path = sys.argv[1:5]
dropped, below_bar = int(dropped), int(below_bar)

with open(health_meta_path) as f:
    hm = json.load(f)

out = {}
for s in ("npm", "github", "registry"):
    try:
        with open(f"{workdir}/status-{s}.json") as f:
            out[s] = json.load(f)
    except (OSError, ValueError):
        out[s] = {"status": "failed", "note": "schema_envelope", "scanned": 0}

out["_meta"] = {
    "anomalous": hm["anomalous"],
    "healthLines": hm["healthLines"],
    "droppedCount": dropped,
    "belowBarCount": below_bar,
}
print(json.dumps(out))
PYEOF

# ===========================================================================
# 9. Render body (with the D18r2 defensive byte-budget fallback rung).
# ===========================================================================
BODY_FILE="$MCP_SWEEP_WORKDIR/body.md"
mcp_render_body "$MCP_SWEEP_WORKDIR/state-candidate.json" "$CLASSIFIED_FILE" \
  "$MCP_SWEEP_WORKDIR/source-status.json" > "$BODY_FILE"

BODY_BYTES="$(wc -c < "$BODY_FILE" | tr -d ' ')"
if [[ "$BODY_BYTES" -ge "$MCP_SWEEP_BODY_MAX_BYTES" ]]; then
  mcp_render_minimal_body "$MCP_SWEEP_WORKDIR/state-candidate.json" > "$BODY_FILE"
  BODY_BYTES="$(wc -c < "$BODY_FILE" | tr -d ' ')"
  if [[ "$BODY_BYTES" -ge "$MCP_SWEEP_BODY_MAX_BYTES" ]]; then
    echo "mcp-sweep.sh: minimal body still exceeds MCP_SWEEP_BODY_MAX_BYTES; aborting with zero gh calls." >&2
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "mcp-sweep aborted: even the minimal body exceeded the byte budget." >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
  fi
fi

# ===========================================================================
# 10. Dry-run: render to step summary + artifact, make zero gh calls,
# never write --state-out, always exit 0 (D21: "escalation fully suppressed
# in dry-run").
# ===========================================================================
if [[ "$DRY_RUN" == "true" ]]; then
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$BODY_FILE" >> "$GITHUB_STEP_SUMMARY"
  fi
  cp "$BODY_FILE" "$MCP_SWEEP_WORKDIR/body-dry-run.md"
  echo "mcp-sweep.sh: dry-run — zero gh calls made, --state-out not written."
  exit 0
fi

# ===========================================================================
# 11. Author guard (D12r2) — a config-sanity assertion, run once before any
# mutation. Skipped in dry-run (already exited above) per the resolution
# recorded in the implementer's report: test 27/D19 requires dry-run to make
# zero gh calls, and this guard's own check IS a gh call.
#
# Implemented via `gh api graphql` rather than `gh issue view --json author`
# — live-verified 2026-07-28 that gh's default JSON serialization omits
# `id` entirely for Bot-typed authors (returns {"is_bot":true,"login":
# "app/github-actions"}), while it IS present for User-typed authors. This
# is a real gap in gh's CLI (confirmed against gh 2.96.0), not a design
# change: the GraphQL query below fetches the exact same immutable node-ID
# string D12r2 specifies, via explicit `... on Bot`/`... on User` fragments.
# ===========================================================================
AUTHOR_GUARD_QUERY='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      locked
      state
      authorAssociation
      author {
        login
        __typename
        ... on Bot { id }
        ... on User { id }
        ... on Organization { id }
      }
    }
  }
}'

REPO_OWNER="${GITHUB_REPOSITORY_OWNER:-}"
REPO_FULL="${GITHUB_REPOSITORY:-}"
REPO_NAME="${REPO_FULL#*/}"
if [[ -z "$REPO_OWNER" && -n "$REPO_FULL" ]]; then
  REPO_OWNER="${REPO_FULL%%/*}"
fi

GUARD_JSON="$MCP_SWEEP_WORKDIR/author-guard.json"
if ! gh api graphql -f query="$AUTHOR_GUARD_QUERY" \
     -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F number="$MCP_SWEEP_ISSUE_NUMBER" \
     > "$GUARD_JSON" 2>"$MCP_SWEEP_WORKDIR/.author-guard.stderr"; then
  echo "mcp-sweep.sh: author guard — gh api graphql call failed; refusing to mutate." >&2
  exit 1
fi

# "not a PR, not locked" — issue()'s GraphQL selector already returns null
# for a number that only resolves to a PR, so $i == null covers "not an
# issue" too.
GUARD_OK="$(jq -r '
  .data.repository.issue as $i
  | if $i == null then "false"
    elif $i.locked then "false"
    else "true"
    end
' "$GUARD_JSON" 2>/dev/null || echo "false")"

GUARD_ASSOC="$(jq -r '.data.repository.issue.authorAssociation // ""' "$GUARD_JSON")"
GUARD_AUTHOR_ID="$(jq -r '.data.repository.issue.author.id // ""' "$GUARD_JSON")"

ALLOW_MATCH="false"
for allowed in $MCP_SWEEP_ISSUE_AUTHOR_ALLOW; do
  [[ "$GUARD_AUTHOR_ID" == "$allowed" ]] && ALLOW_MATCH="true"
done

if [[ "$GUARD_OK" != "true" ]]; then
  echo "mcp-sweep.sh: author guard — issue #$MCP_SWEEP_ISSUE_NUMBER is not a valid, unlocked issue. Zero mutations." >&2
  exit 1
fi
if [[ "$GUARD_ASSOC" != "OWNER" && "$GUARD_ASSOC" != "MEMBER" && "$GUARD_ASSOC" != "COLLABORATOR" && "$ALLOW_MATCH" != "true" ]]; then
  echo "mcp-sweep.sh: author guard — author association '$GUARD_ASSOC' / id '$GUARD_AUTHOR_ID' not authorized. Zero mutations." >&2
  exit 1
fi

ISSUE_WAS_CLOSED="false"
CURRENT_ISSUE_STATE="$(jq -r '.data.repository.issue.state' "$GUARD_JSON")"
[[ "$CURRENT_ISSUE_STATE" == "CLOSED" ]] && ISSUE_WAS_CLOSED="true"

# ===========================================================================
# 12. Reopen predicate — evaluated BEFORE stamping ackedAtUtc, against the
# AS-LOADED value (D8r2, normative ordering: evaluate, mutate, then stamp).
# ===========================================================================
REOPEN_FIRES="false"
if [[ "$ISSUE_WAS_CLOSED" == "true" && "$NEW_MODE" != "seed" ]]; then
  if jq -e --arg acked "$ACKED_AT_LOADED" \
       '.pending | to_entries | any(.value > $acked)' \
       "$MCP_SWEEP_WORKDIR/pending-computed.json" >/dev/null 2>&1; then
    REOPEN_FIRES="true"
  fi
fi

# ===========================================================================
# 13. Body edit (always first, D7r2/D17r2).
# ===========================================================================
if ! gh issue edit "$MCP_SWEEP_ISSUE_NUMBER" --body-file "$BODY_FILE" >/dev/null; then
  echo "mcp-sweep.sh: gh issue edit failed; no state written, next run retries from identical restored state." >&2
  exit 1
fi

# D17r2 — state.ackedAtUtc is stamped unconditionally at end-of-run, AFTER
# the reopen predicate above was evaluated against the as-loaded value.
jq --arg now "$RUN_START_UTC" '.ackedAtUtc = $now' \
  "$MCP_SWEEP_WORKDIR/state-candidate.json" > "$MCP_SWEEP_WORKDIR/state-final.json"

# ===========================================================================
# 14. Write-then-verify state (D18r2), then --state-out + state_written.
# Written only after the edit above succeeded, never in dry-run (already
# exited if dry-run).
# ===========================================================================
if ! python3 "$MCP_SWEEP_LIB_DIR/mcp_state.py" dump "$STATE_OUT" \
     < "$MCP_SWEEP_WORKDIR/state-final.json"; then
  echo "mcp-sweep.sh: write-then-verify failed for --state-out; state_written stays false." >&2
  exit 1
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "state_written=true" >> "$GITHUB_OUTPUT"
fi

# ===========================================================================
# 15. Close / reopen+comment / new-candidates-or-health comment / nothing.
# Mode==seed: never closes, reopens, or comments (D11r2), but the body edit
# and state write above already happened, which is correct and required.
# ===========================================================================
MUTATION_RC=0
if [[ "$NEW_MODE" != "seed" ]]; then
  if [[ "$ISSUE_WAS_CLOSED" == "false" ]]; then
    if [[ "$IS_CLEAN" == "true" && "$NEW_CLEAN_RUNS" -ge "$MCP_SWEEP_CLEAN_RUNS_TO_CLOSE" ]]; then
      AGED_UNTRIAGED="$(jq -r '.newlyAgedCount' "$MCP_SWEEP_WORKDIR/pending-computed.json")"
      CLOSE_REASON="Auto-closed: backlog empty, all sources healthy for ${NEW_CLEAN_RUNS} consecutive runs. ${AGED_UNTRIAGED} entr$([ "$AGED_UNTRIAGED" = "1" ] && echo y || echo ies) aged out untriaged since the previous close."
      gh issue close "$MCP_SWEEP_ISSUE_NUMBER" --comment "$CLOSE_REASON" >/dev/null \
        || { echo "mcp-sweep.sh: gh issue close failed after state write." >&2; MUTATION_RC=1; }
    else
      HAS_HEALTH_LINES="$(jq '.healthLines | length > 0' "$HEALTH_META_FILE")"
      if [[ "$NEW_KEYS_COUNT" -gt 0 || "$HAS_HEALTH_LINES" == "true" ]]; then
        COMMENT_FILE="$MCP_SWEEP_WORKDIR/comment.md"
        {
          if [[ "$NEW_KEYS_COUNT" -gt 0 ]]; then
            echo "### New candidates"
            echo
            while IFS= read -r nk; do
              url="$(mcp_derive_url "$nk" 2>/dev/null || echo "")"
              name="$(_mcp_key_last_segment "$nk")"
              if [[ -n "$url" ]]; then echo "- [${name}](${url})"; else echo "- ${name}"; fi
            done < <(jq -r '.newKeys[]' "$MCP_SWEEP_WORKDIR/pending-computed.json")
            echo
          fi
          if [[ "$HAS_HEALTH_LINES" == "true" ]]; then
            jq -r '.healthLines[]' "$HEALTH_META_FILE"
          fi
        } > "$COMMENT_FILE"
        gh issue comment "$MCP_SWEEP_ISSUE_NUMBER" --body-file "$COMMENT_FILE" >/dev/null \
          || { echo "mcp-sweep.sh: gh issue comment failed." >&2; MUTATION_RC=1; }
      fi
    fi
  else
    # Issue currently closed.
    HAS_HEALTH_LINES="$(jq '.healthLines | length > 0' "$HEALTH_META_FILE")"
    if [[ "$REOPEN_FIRES" == "true" ]]; then
      if gh issue reopen "$MCP_SWEEP_ISSUE_NUMBER" >/dev/null; then
        COMMENT_FILE="$MCP_SWEEP_WORKDIR/comment.md"
        {
          echo "### New candidates"
          echo
          jq -r '.newKeys[]' "$MCP_SWEEP_WORKDIR/pending-computed.json" | while IFS= read -r nk; do
            url="$(mcp_derive_url "$nk" 2>/dev/null || echo "")"
            name="$(_mcp_key_last_segment "$nk")"
            if [[ -n "$url" ]]; then echo "- [${name}](${url})"; else echo "- ${name}"; fi
          done
          echo
          if [[ "$HAS_HEALTH_LINES" == "true" ]]; then
            jq -r '.healthLines[]' "$HEALTH_META_FILE"
          fi
        } > "$COMMENT_FILE"
        gh issue comment "$MCP_SWEEP_ISSUE_NUMBER" --body-file "$COMMENT_FILE" >/dev/null \
          || { echo "mcp-sweep.sh: gh issue comment failed after reopen." >&2; MUTATION_RC=1; }
      else
        echo "mcp-sweep.sh: gh issue reopen failed." >&2
        MUTATION_RC=1
      fi
    elif [[ "$HAS_HEALTH_LINES" == "true" ]]; then
      # D21 — escalation never reopens; must fire even while closed.
      COMMENT_FILE="$MCP_SWEEP_WORKDIR/comment.md"
      jq -r '.healthLines[]' "$HEALTH_META_FILE" > "$COMMENT_FILE"
      gh issue comment "$MCP_SWEEP_ISSUE_NUMBER" --body-file "$COMMENT_FILE" >/dev/null \
        || { echo "mcp-sweep.sh: gh issue comment (health, closed issue) failed." >&2; MUTATION_RC=1; }
    fi
  fi
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$BODY_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$MUTATION_RC" -ne 0 ]]; then
  exit 1
fi
if [[ "$HARD_FAIL" == "true" ]]; then
  exit 1
fi
exit 0
