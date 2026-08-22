#!/usr/bin/env bash
# scripts/roster-keeper.sh — the roster-keeper's mechanical half (stack
# ADR-079, spec docs/superpowers/specs/2026-08-15-roster-keeper-design.md
# §5.3; decision 8 scope: Phases 2-3).
#
# Subcommands built this cycle: stamp, validate, pull (stamp-at-read),
# run, attribute --human, adjudicate (the R3 blind pass), pending, gaps.
# summary / concentration / effectiveness are Phase 4-5 and deliberately
# absent — building them now would render numbers no gate has earned.
#
# Pure bash + jq. The ONLY network egress is gmn_call inside `adjudicate`
# (the architecture-critic transport, scripts/lib/gemini-api.sh); if that
# family is unreachable the item is HELD, never downgraded to a
# Claude-only opinion (R3, stack ADR-012/015 posture). Every subcommand
# that could run unattended refuses under $CI (decision 3: this component
# never runs in CI — a stack CI job can see no product repo).
#
# Append semantics (spec §5.5): each stage appends a COMPLETE new record
# with a bumped per-finding seq, never a patch; readers take the highest
# seq per finding_id.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_MAP="$SCRIPT_DIR/../config/roster-ownership.json"
AGENTS_DIR="$SCRIPT_DIR/../agents"
GEMINI_LIB="${ROSTER_KEEPER_GEMINI_LIB:-$SCRIPT_DIR/lib/gemini-api.sh}"

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_die2() { echo "roster-keeper: $*" >&2; exit 2; }

_map_ok() { jq -e '.version and .cells' "$1" >/dev/null 2>&1; }

# _cell_lookup <map> <mechanism> <surface> -> {candidates,provisional} JSON.
# Exact (mechanism,surface) beats (mechanism,"*"); no match -> empty cell.
_cell_lookup() {
  jq -c --arg m "$2" --arg s "$3" '
    (.cells | map(select(.mechanism==$m and .surface==$s)) | .[0]) //
    (.cells | map(select(.mechanism==$m and .surface=="*")) | .[0]) //
    {candidates:[], provisional:false}
    | {candidates:(.candidates // []), provisional:(.provisional // false)}' "$1"
}

# _max_seq <attr-file> <finding_id> -> highest seq (0 if none)
_max_seq() {
  [[ -f "$1" ]] || { echo 0; return; }
  jq -s --arg id "$2" '[.[] | select(.finding_id==$id) | .seq] | max // 0' "$1" 2>/dev/null || echo 0
}

# _latest <attr-file> <finding_id> [stage] -> highest-seq record (optionally
# filtered to a stage), or empty
_latest() {
  [[ -f "$1" ]] || { echo ""; return; }
  jq -c -s --arg id "$2" --arg st "${3:-}" '
    [.[] | select(.finding_id==$id) | select($st=="" or .stage==$st)]
    | sort_by(.seq) | last // empty' "$1" 2>/dev/null
}

# ------------------------------------------------------------------ stamp
cmd_stamp() {
  local findings="${1:-}"; shift || true
  local map="$DEFAULT_MAP" attrs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --map) map="${2:-}"; shift 2 ;;
      --attributions) attrs="${2:-}"; shift 2 ;;
      *) _die2 "stamp: unknown argument: $1" ;;
    esac
  done
  [[ -f "$findings" ]] || _die2 "stamp: findings file not found: $findings"
  _map_ok "$map" || _die2 "stamp: ownership map unparseable: $map"
  [[ -z "$attrs" ]] && attrs="$(dirname "$findings")/attributions.jsonl"

  local map_version; map_version="$(jq -r '.version' "$map")"
  local stamped=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local fid mech surf ssrc repo
    fid="$(jq -r '.finding_id // empty' <<<"$line")"
    [[ -z "$fid" ]] && continue
    [[ -n "$(_latest "$attrs" "$fid" stamped)" ]] && continue
    mech="$(jq -r '.mechanism // ""' <<<"$line")"
    surf="$(jq -r '.surface // ""' <<<"$line")"
    ssrc="$(jq -r '.surface_source // ""' <<<"$line")"
    repo="$(jq -r '.repo // ""' <<<"$line")"
    local cell candidates provisional
    if [[ -z "$surf" || "$surf" == "null" ]]; then
      # surface absent => empty candidates, surface_source unset. Never guessed.
      candidates='[]'; provisional=false; ssrc="unset"
    else
      cell="$(_cell_lookup "$map" "$mech" "$surf")"
      candidates="$(jq -c '.candidates' <<<"$cell")"
      provisional="$(jq -r '.provisional' <<<"$cell")"
      # RD5 seam: finding-record's enum says "declared" (a check declared
      # it); attribution-record's says "check". Same fact, two spellings —
      # translate here, at the one read point, never in the shared schema.
      case "$ssrc" in
        declared|"") ssrc="check" ;;
        human|unset) ;;
        *) ssrc="unset" ;;
      esac
    fi
    local seq; seq=$(( $(_max_seq "$attrs" "$fid") + 1 ))
    jq -cn --arg fid "$fid" --arg repo "$repo" --arg now "$(_now)" --arg ssrc "$ssrc" \
      --argjson seq "$seq" --argjson cands "$candidates" \
      --argjson prov "$provisional" --argjson v "$map_version" '
      {schema:"attribution-record/v1", finding_id:$fid, repo:$repo,
       stage:"stamped", seq:$seq, created_at:$now,
       responsible_agent_candidates:$cands, ownership_map_version:$v,
       cell_provisional:$prov, surface_source:$ssrc}' >> "$attrs"
    stamped=$((stamped+1))
  done < "$findings"
  echo "stamped=$stamped attributions=$attrs"
  return 0
}

# --------------------------------------------------------------- validate
# _validate_json <record-json> [measurement-source] -> 0 valid / 1 invalid
_validate_json() {
  local rec="$1" msrc="${2:-}"
  local why
  why="$(jq -r --arg msrc "$msrc" '
    def bad(msg): msg;
    if .schema != "attribution-record/v1" then bad("schema is not attribution-record/v1")
    elif (.stage | IN("stamped","attributed","adjudicated","applied") | not) then bad("bad stage")
    elif (.surface_source | IN("check","human","unset") | not) then bad("surface_source must be check|human|unset (never roster-keeper)")
    elif .responsible_agent == "roster-keeper" then bad("R2: no agent attributes a finding to itself; roster-keeper may never be the responsible_agent")
    elif (.responsible_agent == "none" and (.none_reason == null or .none_reason == "")) then bad("responsible_agent none requires none_reason")
    elif (.responsible_agent != "none" and .responsible_agent != null and .none_reason != null) then bad("none_reason only accompanies responsible_agent none")
    elif (.none_reason != null and (.none_reason | IN("unowned","nearest-fit","disagreement") | not)) then bad("bad none_reason")
    elif (.roster_action != null and (.roster_action | IN("none","prompt-change","new-check","new-agent") | not)) then bad("bad roster_action")
    elif (.roster_action == "none" and .roster_action_ref != null) then bad("roster_action none requires a null ref")
    elif (.responsible_agent == "none" and .roster_action == "none") then bad("an unowned class always demands some answer: none/none is invalid")
    elif (.disagreement != null and (.responsible_agent != "none" or .none_reason != "disagreement")) then bad("disagreement implies responsible_agent none / none_reason disagreement")
    elif ($msrc == "production-data" and .roster_action != null and (.roster_action | IN("new-check","none") | not)) then bad("production-data fence: roster_action must be new-check or none")
    elif (.none_reason != null and (.none_reason | IN("nearest-fit","disagreement")) and .roster_action != null
          and (.roster_action | IN("new-check","none") | not)) then bad("nearest-fit/disagreement force roster_action new-check (or none under the production-data fence)")
    elif (.responsible_agent != null and .responsible_agent != "none"
          and ((.responsible_agent_candidates // []) | index(.responsible_agent) | not)
          and .attribution_route != "cross-family-required") then bad("an off-ballot responsible_agent requires attribution_route cross-family-required")
    else empty end' <<<"$rec" 2>/dev/null)"
  if [[ -n "$why" ]]; then
    echo "roster-keeper: validate: invalid: $why" >&2
    return 1
  fi
  return 0
}

cmd_validate() {
  local file="${1:-}"; shift || true
  local msrc=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --measurement-source) msrc="${2:-}"; shift 2 ;;
      *) _die2 "validate: unknown argument: $1" ;;
    esac
  done
  [[ -f "$file" ]] || _die2 "validate: record file not found: $file"
  jq -e . "$file" >/dev/null 2>&1 || _die2 "validate: unparseable record: $file"
  _validate_json "$(cat "$file")" "$msrc"
}

# ------------------------------------------------------------------- pull
cmd_pull() {
  local roots="" map="$DEFAULT_MAP" emit=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --roots) roots="${2:-}"; shift 2 ;;
      --map) map="${2:-}"; shift 2 ;;
      --emit) emit=1; shift ;;
      *) _die2 "pull: unknown argument: $1" ;;
    esac
  done
  [[ -n "${CI:-}" ]] && _die2 "pull: refusing to run under CI — this component runs on an operator's machine only (decision 3)"
  [[ -n "$roots" ]] || _die2 "pull: --roots is required"

  local repos=0 files=0 records=0 stamped=0 root d
  local IFS_SAVE="$IFS"
  IFS=','
  for root in $roots; do
    IFS="$IFS_SAVE"
    [[ -d "$root" ]] || continue
    for d in "$root"/*/; do
      d="${d%/}"
      [[ -d "$d/.git" && -f "$d/.claude/sweep/findings.jsonl" ]] || continue
      repos=$((repos+1))
      # stamp-at-read: the load-bearing invoker — CI-written findings are
      # stamped here or nowhere (seam RD4).
      local sout; sout="$(cmd_stamp "$d/.claude/sweep/findings.jsonl" --map "$map" 2>/dev/null)" || continue
      stamped=$((stamped + $(sed -n 's/^stamped=\([0-9]*\).*/\1/p' <<<"$sout") ))
      files=$((files+1))
      records=$((records + $(grep -c . "$d/.claude/sweep/findings.jsonl" 2>/dev/null || echo 0) ))
      if (( emit )); then
        cat "$d/.claude/sweep/findings.jsonl"
        [[ -f "$d/.claude/sweep/attributions.jsonl" ]] && cat "$d/.claude/sweep/attributions.jsonl"
      fi
    done
    IFS=','
  done
  IFS="$IFS_SAVE"

  echo "repos_discovered=$repos files_read=$files records=$records records_stamped=$stamped"
  # Sweep-B1 non-vacuity applied to this script: a silent zero is the
  # failure mode this whole design exists to catch.
  (( repos == 0 )) && { echo "roster-keeper: pull: zero repos discovered under: $roots" >&2; return 2; }
  (( files == 0 )) && { echo "roster-keeper: pull: $repos repo(s) discovered but zero findings files read" >&2; return 2; }
  return 0
}

# -------------------------------------------------------------- attribute
cmd_attribute() {
  local human=0 findings="" from="" attrs="" limit=0 map="$DEFAULT_MAP"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --human) human=1; shift ;;
      --findings) findings="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      --attributions) attrs="${2:-}"; shift 2 ;;
      --limit) limit="${2:-0}"; shift 2 ;;
      --map) map="${2:-}"; shift 2 ;;
      *) _die2 "attribute: unknown argument: $1" ;;
    esac
  done
  (( human )) || _die2 "attribute: only the --human route exists this cycle (Phase 4 is not authorised)"
  [[ -f "$findings" ]] || _die2 "attribute: --findings file not found: $findings"
  [[ -z "$attrs" ]] && attrs="$(dirname "$findings")/attributions.jsonl"

  if [[ -z "$from" ]]; then
    # The live question loop requires a human at a terminal. Never fills an
    # answer on the user's behalf, never batches an unanswered finding into
    # a default (spec §5.3).
    [[ -t 0 ]] || _die2 "attribute --human: no terminal and no --from answers file — refusing to run non-interactively"
    _die2 "attribute --human: interactive question loop not yet wired; pass --from <answers.jsonl> (the cohort-zero replay path)"
  fi
  [[ -f "$from" ]] || _die2 "attribute: --from file not found: $from"

  local n=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    (( limit > 0 && n >= limit )) && break
    local fid; fid="$(jq -r '.finding_id // empty' <<<"$line")"
    [[ -z "$fid" ]] && _die2 "attribute: answer row without finding_id"
    [[ "$(jq -r '.attributed_by // empty' <<<"$line")" == "human" ]] \
      || _die2 "attribute --human: every answer row must carry attributed_by: human (R1 — provenance recorded at answer time)"
    jq -e -s --arg id "$fid" 'any(.[]; .finding_id == $id)' "$findings" >/dev/null 2>&1 \
      || _die2 "attribute: answer references unknown finding: $fid"
    local stamped; stamped="$(_latest "$attrs" "$fid" stamped)"
    [[ -n "$stamped" ]] || _die2 "attribute: finding $fid has no stamped record — run stamp first"

    local agent note action ref nreason route
    agent="$(jq -r '.responsible_agent // empty' <<<"$line")"
    nreason="$(jq -r '.none_reason // empty' <<<"$line")"
    action="$(jq -r '.roster_action // empty' <<<"$line")"
    ref="$(jq -r '.roster_action_ref // empty' <<<"$line")"
    note="$(jq -r '(.note // .attribution_note // "") | .[0:200]' <<<"$line")"
    # An off-ballot pick is the escape hatch taken: recorded, routed to the
    # cross-family-required lane, never coerced onto the ballot (§4.5a rule 3).
    route="normal"
    if [[ -n "$agent" && "$agent" != "none" ]]; then
      jq -e --arg a "$agent" '.responsible_agent_candidates | index($a)' <<<"$stamped" >/dev/null 2>&1 || route="cross-family-required"
    fi
    local seq; seq=$(( $(_max_seq "$attrs" "$fid") + 1 ))
    local rec
    rec="$(jq -cn --arg fid "$fid" --arg now "$(_now)" --arg agent "$agent" \
      --arg nreason "$nreason" --arg action "$action" --arg ref "$ref" \
      --arg note "$note" --arg route "$route" --argjson seq "$seq" \
      --argjson stamped "$stamped" '
      {schema:"attribution-record/v1", finding_id:$fid, repo:$stamped.repo,
       stage:"attributed", seq:$seq, created_at:$now,
       responsible_agent_candidates:$stamped.responsible_agent_candidates,
       ownership_map_version:$stamped.ownership_map_version,
       cell_provisional:$stamped.cell_provisional,
       surface_source:$stamped.surface_source,
       responsible_agent:(if $agent=="" then null else $agent end),
       none_reason:(if $nreason=="" then null else $nreason end),
       attribution_note:(if $note=="" then null else $note end),
       attributed_by:"human", attribution_route:$route,
       adjudication_blind:null, disagreement:null,
       roster_action:(if $action=="" then null else $action end),
       roster_action_ref:(if $ref=="" then null else $ref end),
       roster_action_applied_sha:null, roster_action_applied_at:null}')"
    local msrc; msrc="$(grep "\"finding_id\":\"$fid\"" "$findings" | head -1 | jq -r '.evidence.measurement.source // ""')"
    _validate_json "$rec" "$msrc" || _die2 "attribute: answer for $fid produces an invalid record (see above)"
    printf '%s\n' "$rec" >> "$attrs"
    n=$((n+1))
  done < "$from"
  echo "attributed=$n attributions=$attrs"
  return 0
}

# -------------------------------------------------------------- adjudicate
# The R3 blind pass. The payload piped to gmn_call is {finding + candidate
# list + the candidates' charters + the glossary} and NEVER the first
# pass's answer — an adjudication prompt that shows the answer and asks
# for a check is a request for a signature, not a second opinion.
cmd_adjudicate() {
  local findings="" attrs="" map="$DEFAULT_MAP"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --findings) findings="${2:-}"; shift 2 ;;
      --attributions) attrs="${2:-}"; shift 2 ;;
      --map) map="${2:-}"; shift 2 ;;
      *) _die2 "adjudicate: unknown argument: $1" ;;
    esac
  done
  [[ -n "${CI:-}" ]] && _die2 "adjudicate: refusing to run under CI"
  [[ -f "$findings" ]] || _die2 "adjudicate: --findings file not found: $findings"
  [[ -z "$attrs" ]] && attrs="$(dirname "$findings")/attributions.jsonl"
  [[ -f "$attrs" ]] || _die2 "adjudicate: no attributions file at $attrs"

  # shellcheck source=/dev/null
  source "$GEMINI_LIB" 2>/dev/null || _die2 "adjudicate: cannot source gemini lib at $GEMINI_LIB"
  if ! gmn_available; then
    echo "roster-keeper: adjudicate: cross-family transport unavailable — every pending item is HELD, not downgraded to a Claude-only opinion (R3)" >&2
    exit 3
  fi

  local glossary; glossary="$(jq -c '{mechanism_glossary, surface_glossary}' "$map" 2>/dev/null)"
  local held=0 done_n=0 fid
  for fid in $(jq -s -r '[.[] | select(.stage=="attributed") | .finding_id] | unique | .[]' "$attrs"); do
    [[ -n "$(_latest "$attrs" "$fid" adjudicated)" ]] && continue
    local first; first="$(_latest "$attrs" "$fid" attributed)"
    local frec; frec="$(grep "\"finding_id\":\"$fid\"" "$findings" | head -1)"
    [[ -z "$frec" ]] && continue

    # Blind payload: strip the answer-bearing fields from the finding too.
    local blind_finding; blind_finding="$(jq -c 'del(.responsible_agent, .roster_action)' <<<"$frec")"
    # Ballot: the map's candidates for a normal record; the FULL roster for
    # a cross-family-required one. An off-ballot human pick (§4.5a rule 3)
    # can only be confirmed or refuted by an adjudicator allowed to name
    # any roster agent — a candidates-only ballot would be rigged to
    # disagree with every such pick, which is a vote, not a review. The
    # full roster reveals nothing about which member the human chose.
    local cands charters="" c
    if [[ "$(jq -r '.attribution_route // "normal"' <<<"$first")" == "cross-family-required" ]]; then
      cands="$(ls "$AGENTS_DIR"/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | jq -R . | jq -c -s .)"
      for c in $(jq -r '.[]' <<<"$cands"); do
        charters="$charters
$c: $(awk '/^description:/{sub(/^description: */,""); print; exit}' "$AGENTS_DIR/$c.md" 2>/dev/null)"
      done
    else
      cands="$(jq -c '.responsible_agent_candidates' <<<"$first")"
      for c in $(jq -r '.[]' <<<"$cands"); do
        [[ -f "$AGENTS_DIR/$c.md" ]] && charters="$charters
--- charter: $c ---
$(head -40 "$AGENTS_DIR/$c.md")"
      done
    fi
    local payload="finding: $blind_finding
candidates: $cands
glossary: $glossary
$charters"
    local answer
    answer="$(printf '%s' "$payload" | gmn_call "Which of these roles' charters covers this class of defect, or none? Answer with exactly one word: a role name from the candidates list, or 'none'." 2>/dev/null)" || { held=$((held+1)); continue; }
    answer="$(printf '%s' "$answer" | head -1 | tr -d ' ' | tr 'A-Z' 'a-z')"
    [[ -z "$answer" ]] && { held=$((held+1)); continue; }

    local first_agent; first_agent="$(jq -r '.responsible_agent // "none"' <<<"$first")"
    local msrc; msrc="$(jq -r '.evidence.measurement.source // ""' <<<"$frec")"
    local seq; seq=$(( $(_max_seq "$attrs" "$fid") + 1 ))
    local rec
    if [[ "$answer" == "$first_agent" ]]; then
      rec="$(jq -c --argjson seq "$seq" --arg now "$(_now)" '
        .stage="adjudicated" | .seq=$seq | .created_at=$now
        | .attributed_by="cross-family:gemini"
        | .adjudication_blind=true | .disagreement=null' <<<"$first")"
    else
      # R4: two families that cannot agree have demonstrated the class has
      # no clear owner. Both answers recorded; the cell still renders.
      local forced_action="new-check"
      [[ "$msrc" == "production-data" ]] && forced_action="new-check"
      rec="$(jq -c --argjson seq "$seq" --arg now "$(_now)" --arg other "$answer" --arg act "$forced_action" '
        .stage="adjudicated" | .seq=$seq | .created_at=$now
        | .attributed_by="cross-family:gemini"
        | .responsible_agent="none" | .none_reason="disagreement"
        | .roster_action=$act | .roster_action_ref=null
        | .adjudication_blind=true
        | .disagreement={family:"gemini", agent:$other}' <<<"$first")"
    fi
    _validate_json "$rec" "$msrc" || _die2 "adjudicate: produced an invalid record for $fid"
    printf '%s\n' "$rec" >> "$attrs"
    done_n=$((done_n+1))
  done
  echo "adjudicated=$done_n held=$held"
  (( held > 0 )) && return 3
  return 0
}

# ---------------------------------------------------------------- pending
cmd_pending() {
  local findings="" attrs="" limit=0 unset_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --findings) findings="${2:-}"; shift 2 ;;
      --attributions) attrs="${2:-}"; shift 2 ;;
      --limit) limit="${2:-0}"; shift 2 ;;
      --unset) unset_only=1; shift ;;
      *) _die2 "pending: unknown argument: $1" ;;
    esac
  done
  [[ -f "$findings" ]] || _die2 "pending: --findings file not found: $findings"
  [[ -z "$attrs" ]] && attrs="$(dirname "$findings")/attributions.jsonl"
  local n=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    (( limit > 0 && n >= limit )) && break
    local fid; fid="$(jq -r '.finding_id // empty' <<<"$line")"
    [[ -z "$fid" ]] && continue
    (( unset_only )) && [[ "$(jq -r '.surface_source // ""' <<<"$line")" != "unset" ]] && continue
    [[ -n "$(_latest "$attrs" "$fid" attributed)" ]] && continue
    printf '%s\n' "$line"
    n=$((n+1))
  done < "$findings"
  return 0
}

# ------------------------------------------------------------------- gaps
cmd_gaps() {
  local findings="" attrs="" window="30d"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --findings) findings="${2:-}"; shift 2 ;;
      --attributions) attrs="${2:-}"; shift 2 ;;
      --window) window="${2:-30d}"; shift 2 ;;
      *) _die2 "gaps: unknown argument: $1" ;;
    esac
  done
  [[ -f "$findings" ]] || _die2 "gaps: --findings file not found: $findings"
  [[ -z "$attrs" ]] && attrs="$(dirname "$findings")/attributions.jsonl"
  local examined=0
  [[ -f "$attrs" ]] && examined="$(grep -c . "$attrs" 2>/dev/null || echo 0)"
  # Latest record per finding joined to the finding's cell; none counts
  # split by none_reason. Provisional cells are included — they were the
  # ones being buried (red-team #7). cross-family-required records are
  # excluded until adjudicated (§5.5 invariant).
  local joined
  joined="$(jq -c -s '
    group_by(.finding_id) | map(sort_by(.seq) | last)
    | map(select(.responsible_agent=="none"))
    | map(select(.attribution_route != "cross-family-required" or (.attributed_by // "" | startswith("cross-family:"))))' "$attrs" 2>/dev/null)"
  local cells
  cells="$(while IFS= read -r fl; do
    [[ -z "$fl" ]] && continue
    jq -r '"\(.finding_id)\t\(.mechanism)\t\(.surface // "unset")"' <<<"$fl"
  done < "$findings")"
  echo "records_examined=$examined"
  jq -r --arg cells "$cells" '
    ($cells | split("\n") | map(select(length>0) | split("\t") | {fid:.[0], cell:"\(.[1])|\(.[2])"})) as $cm
    | group_by(.finding_id) | map(sort_by(.seq)|last)
    | map(. as $r | {cell:(($cm[] | select(.fid==$r.finding_id) | .cell) // "unknown|unknown"),
                     reason:(.none_reason // "unattributed"),
                     none:(.responsible_agent=="none"), prov:.cell_provisional})
    | group_by(.cell)
    | .[]
    | "cell=\(.[0].cell) provisional=\(.[0].prov) none_unowned=\([.[] | select(.none and .reason=="unowned")] | length) none_nearest_fit=\([.[] | select(.none and .reason=="nearest-fit")] | length) none_disagreement=\([.[] | select(.none and .reason=="disagreement")] | length) threshold=\(([.[] | select(.none)] | length) >= 3) renderable=true"
    ' -s "$attrs" 2>/dev/null || true
  return 0
}

# -------------------------------------------------------------------- run
cmd_run() {
  local roots=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --roots) roots="${2:-}"; shift 2 ;;
      *) _die2 "run: unknown argument: $1" ;;
    esac
  done
  [[ -n "${CI:-}" ]] && _die2 "run: refusing to run under CI (decision 3)"
  [[ -z "$roots" ]] && roots="$HOME/Antigravity"
  echo "== roster-keeper run ($(_now)) =="
  cmd_pull --roots "$roots" || return $?
  local root d
  local IFS_SAVE="$IFS"; IFS=','
  for root in $roots; do
    IFS="$IFS_SAVE"
    for d in "$root"/*/; do
      d="${d%/}"
      [[ -f "$d/.claude/sweep/findings.jsonl" ]] || continue
      local pend; pend="$(cmd_pending --findings "$d/.claude/sweep/findings.jsonl" 2>/dev/null | grep -c . || echo 0)"
      echo "repo=$(basename "$d") pending_attribution=$pend"
      cmd_gaps --findings "$d/.claude/sweep/findings.jsonl" 2>/dev/null | sed "s/^/repo=$(basename "$d") /"
    done
    IFS=','
  done
  IFS="$IFS_SAVE"
  return 0
}

# ------------------------------------------------------------------- main
case "${1:-}" in
  stamp) shift; cmd_stamp "$@" ;;
  validate) shift; cmd_validate "$@" ;;
  pull) shift; cmd_pull "$@" ;;
  attribute) shift; cmd_attribute "$@" ;;
  adjudicate) shift; cmd_adjudicate "$@" ;;
  pending) shift; cmd_pending "$@" ;;
  gaps) shift; cmd_gaps "$@" ;;
  run) shift; cmd_run "$@" ;;
  *)
    cat >&2 <<'USAGE'
roster-keeper.sh stamp <findings.jsonl> [--map M] [--attributions A]
roster-keeper.sh validate <record.json> [--measurement-source S]
roster-keeper.sh pull --roots <dir>[,<dir>...] [--map M] [--emit]
roster-keeper.sh attribute --human --findings F --from <answers.jsonl> [--limit N]
roster-keeper.sh adjudicate --findings F [--attributions A] [--map M]
roster-keeper.sh pending --findings F [--limit N] [--unset]
roster-keeper.sh gaps --findings F [--window 30d]
roster-keeper.sh run [--roots <dir>[,<dir>...]]
USAGE
    exit 2 ;;
esac
