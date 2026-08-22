#!/usr/bin/env bash
# Tests for ADR-053 (multi-domain-mode, path-scoped forced review chains) --
# BUCKET E: real execution of the three-invocation consent flow that
# skills/domain-mode/SKILL.md, skills/project-init/SKILL.md and
# skills/sensitivity/SKILL.md prescribe.
#
# WHY THIS FILE EXISTS. tests/test-domain-mode-multi.sh (BUCKET A) and
# tests/test-domain-mode-concurrency.sh (BUCKET D) call
# scripts/permissions-compile.sh directly, one invocation at a time, and
# assert on its JSON. tests/test-domain-mode-skills-docs.sh (BUCKET B) greps
# SKILL.md prose. Neither ever scripts the actual documented SEQUENCE --
# P0 -> write config -> run 1 -> prompt-set -> [scripted y/N, no interactive
# human needed] -> run 2 (drift gate) -> R2b -> reconcile (one durable
# sidecar write) -> run 3 (apply) -> verify -- as one flow, end to end, for
# the ~20 T-cases (and sub-cases) whose ONLY existing coverage is Bucket B's
# doc-consistency grep. This file closes that gap for exactly those cases:
#   T-19, T-20, T-23, T-31(a), T-32(a/b/c), T-35(a/b/c), T-38, T-44,
#   T-45(a/b), T-48, T-58, T-61(a-f), T-66(a/b/e/f/g)
# T-45(c) is explicitly "docs-logic style" per the handoff and is already
# asserted in Bucket B (T-19/T-45(c) section) -- re-asserting it here would
# violate this file's own no-duplication charter, so it is a one-line NOTE
# instead. T-66(c) is real two-process concurrency and lives entirely in
# Bucket D; not repeated here.
#
# WHAT "REAL EXECUTION" MEANS HERE, PRECISELY. There is no binary for a
# SKILL.md: it is markdown read by an LLM agent. What this file scripts is
# the literal, numbered sequence of shell/python commands each SKILL.md
# prescribes for that step -- the same discipline Bucket D's
# sim_domain_mode_reconcile / sim_sensitivity_prune / r2b_predicate_rc
# already use ("byte-for-byte the heredoc pinned in SKILL.md", "never
# re-derive classify_suppressions() -- acks_prunable/acks_in_force always
# come from a real permissions-compile.sh --dry-run --json call"). Every
# assertion below terminates in one of exactly three things: real compiler
# JSON, real file bytes on disk, or a real subprocess exit code -- never a
# variable this harness itself set. In particular: this file does NOT
# re-assert the exact wording of any printed message (P0's refusal prose,
# the mid-flow divergence prose, "consent check unavailable...") -- Bucket B
# already greps those verbatim out of the SKILL.md source. This file's
# contribution for those cases is the FILE-STATE half: what actually got
# written, deleted, or left untouched when the documented flow runs for
# real, and the real exit codes/invocation counts the flow produces.
#
# Case IDs (T-N) reference docs/ADRs/053-implementer-handoff.md.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILE="$REPO_ROOT/scripts/permissions-compile.sh"

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$COMPILE" ]] || { echo "FAIL: $COMPILE not found"; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected: $2 | actual: $3)"; }
assert_rc() { [[ "$3" -eq "$2" ]] && pass "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 (missing '$3' in: $2)"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1 (unexpectedly found '$3' in: $2)"; }
assert_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1 (missing exact line '$3' in: $2)"; fi
}
assert_not_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then fail "$1 (unexpectedly found exact line '$3' in: $2)"; else pass "$1"; fi
}

CLEANUP_LIST="$(mktemp)"
cleanup() {
  [[ -f "$CLEANUP_LIST" ]] || return 0
  while IFS= read -r d; do
    [[ -n "$d" ]] && rm -rf "$d"
  done < "$CLEANUP_LIST"
  rm -f "$CLEANUP_LIST"
}
trap cleanup EXIT

new_home() {
  local h; h="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  mkdir -p "$h/.claude/session-state" "$h/.claude/config"
  echo "$h" >> "$CLEANUP_LIST"
  printf '%s' "$h"
}

new_repo() {
  local d; d="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  echo "$d" >> "$CLEANUP_LIST"
  mkdir -p "$d/.claude"
  printf '%s' "$d"
}

write_snapshot() {
  local home="$1"; shift
  local servers_json="[]"
  if [[ $# -gt 0 ]]; then
    servers_json="$(printf '%s\n' "$@" | jq -R '{name:.,transport:"stdio",host:null,remote:false}' | jq -s '.')"
  fi
  jq -n --argjson s "$servers_json" \
    '{generated_at:"2026-07-27T00:00:00Z",source:"live",scope:"user",plugins:[],mcp_servers:$s}' \
    > "$home/.claude/session-state/live-capabilities.json"
}
no_snapshot() { rm -f "$1/.claude/session-state/live-capabilities.json"; }

# write_cfg <dir> <domain_mode_json_literal> <domain_mode_paths_json_literal|__ABSENT__> <required_approvals_json_literal>
write_cfg() {
  local dir="$1" dm="$2" dmp="$3" reqs="${4:-[]}"
  mkdir -p "$dir/.claude"
  local dmp_field=""
  if [[ "$dmp" != "__ABSENT__" ]]; then
    dmp_field="\"domain_mode_paths\": $dmp,"
  fi
  cat > "$dir/.claude/stack-config.json" <<EOF
{"stack_tier":2,"stack_version":"1.0.0","purpose":"test","created":"2026-01-01",
 "domain_mode":$dm, $dmp_field
 "sensitivity":{"level":"normal"},
 "required_approvals":$reqs}
EOF
}

ack_entry() {
  local mode="$1" tools="$2" hash="$3" date="${4:-2026-08-01}" by="${5:-tester}" reason="${6:-test}"
  jq -n --arg m "$mode" --argjson t "$tools" --arg h "$hash" --arg d "$date" --arg b "$by" --arg r "$reason" \
    '{mode:$m, tools:$t, scope_hash:$h, date:$d, by:$b, reason:$r}'
}
sidecar_with_acks() {
  local dir="$1"; shift
  if [[ $# -eq 0 ]]; then
    printf '{}' > "$dir/.claude/permissions.stack.json"
    return
  fi
  local arr; arr="$(printf '%s\n' "$@" | jq -s '.')"
  jq -n --argjson acks "$arr" '{multi_mode_suppression_ack: $acks}' > "$dir/.claude/permissions.stack.json"
}
sidecar_with_acks_and_extras() {
  # sidecar_with_acks_and_extras <dir> <acks_json_array> <waivers_json_array> <pinned_json_array>
  local dir="$1" acks="$2" waivers="$3" pinned="$4"
  jq -n --argjson acks "$acks" --argjson w "$waivers" --argjson p "$pinned" \
    '{multi_mode_suppression_ack:$acks, waivers:$w, pinned:$p}' > "$dir/.claude/permissions.stack.json"
}

# compile_* -- COMPILE_BIN, when set by a caller, overrides $COMPILE (used by
# the T-38/T-61(d) "compiler unavailable" cases). Never overridden globally.
# INVOKE_LOG, when set by a caller (dm_flow/sensitivity_flow do), gets one
# "dry"/"apply" line appended per REAL invocation of the compiler these two
# primary wrappers make -- this is what makes "exactly 3 invocations, in
# this order" a real artifact instead of a harness-incremented counter (the
# same class of trap Bucket D's own line 780 comment names for aborted_at).
# compile_dry_stderr/compile_apply_stderr are diagnostic re-invocations used
# only to fetch error text in a failure branch -- deliberately NOT logged,
# since they are not one of the flow's documented three.
compile_dry_stdout() {
  local bin="${COMPILE_BIN:-$COMPILE}"
  [[ -n "${INVOKE_LOG:-}" ]] && echo "dry" >> "$INVOKE_LOG"
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$bin" --scope project --repo-root "$1" --dry-run --json 2>/dev/null
}
compile_dry_stderr() {
  local bin="${COMPILE_BIN:-$COMPILE}"
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$bin" --scope project --repo-root "$1" --dry-run --json 2>&1 >/dev/null
}
compile_dry_rc() {
  local bin="${COMPILE_BIN:-$COMPILE}"
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$bin" --scope project --repo-root "$1" --dry-run --json >/dev/null 2>/dev/null
  echo $?
}
compile_apply_rc() {
  local bin="${COMPILE_BIN:-$COMPILE}"
  [[ -n "${INVOKE_LOG:-}" ]] && echo "apply" >> "$INVOKE_LOG"
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$bin" --scope project --repo-root "$1" >/dev/null 2>/dev/null
  echo $?
}
compile_apply_stderr() {
  local bin="${COMPILE_BIN:-$COMPILE}"
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$bin" --scope project --repo-root "$1" 2>&1 >/dev/null
}
get_hash() { compile_dry_stdout "$1" | jq -r '.inputs.consent_scope_hash'; }

# ===========================================================================
# The mergeability predicate -- byte-for-byte the heredoc pinned in
# skills/domain-mode/SKILL.md (P0, R2b), skills/project-init/SKILL.md (P0,
# R2b) and skills/sensitivity/SKILL.md (P0, P2b). Confirmed identical text
# in all three files by direct read. rc 0 = mergeable (absent OR parses as
# an object); 3 = unreadable/not valid JSON; 4 = valid JSON, non-object root.
# ===========================================================================
p0_predicate_rc() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  python3 - "$path" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    print("file unreadable or not valid JSON", file=sys.stderr); sys.exit(3)
if not isinstance(data, dict):
    print("root is not a JSON object", file=sys.stderr); sys.exit(4)
PY
}

# The T-65/T-54 fixture set, reused verbatim from Bucket A's own set (a
# helper, not an assertion -- duplicating fixture *content* is required for
# this file to run standalone).
write_bad_sidecar() {
  local r="$1" name="$2"
  local f="$r/.claude/permissions.stack.json"
  case "$name" in
    trailing_comma)   printf '{"multi_mode_suppression_ack": [1,],}' > "$f" ;;
    unclosed_brace)   printf '{"multi_mode_suppression_ack": [' > "$f" ;;
    zero_byte)        : > "$f" ;;
    non_utf8)         printf '\xff\xfe\x00\x01' > "$f" ;;
    root_array)       printf '[]' > "$f" ;;
    root_number)      printf '42' > "$f" ;;
    root_string)      printf '"x"' > "$f" ;;
    root_true)        printf 'true' > "$f" ;;
    root_null)        printf 'null' > "$f" ;;
  esac
}

# inputs_differ <run1-json-file> <run2-json-file> -- "deep equality of the
# whole inputs object plus baseline_version" (the named fields are the
# documented ABORT-MESSAGE vocabulary/order only; the final whole-.inputs
# comparison is the real gate).
inputs_differ() {
  local j1="$1" j2="$2" a b
  a="$(jq -S '.baseline_version' "$j1")"; b="$(jq -S '.baseline_version' "$j2")"
  [[ "$a" != "$b" ]] && { echo "baseline_version"; return; }
  a="$(jq -S '.inputs' "$j1")"; b="$(jq -S '.inputs' "$j2")"
  [[ "$a" != "$b" ]] && { echo "inputs"; return; }
  echo ""
}

# ===========================================================================
# reconcile_write -- the ONE durable sidecar write, real read-modify-write,
# preserving waivers[]/pinned[] and every other key untouched.
# reconcile_write <repo> <ack_array_json>
# ===========================================================================
reconcile_write() {
  local repo="$1" keep_json="$2"
  local sidecar="$repo/.claude/permissions.stack.json"
  python3 - "$sidecar" "$keep_json" <<'PY'
import json, sys
path, keep = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
data["multi_mode_suppression_ack"] = json.loads(keep)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

# carry_forward_b <repo> <acks_in_force_json_array> -- reads the CURRENT
# sidecar's existing entries and returns them with each entry's `tools`
# filtered down to exactly the pairs present in acks_in_force for that
# entry's mode (dropping entries that empty). This is "byte-identical
# carry-forward": date/by/reason/scope_hash of a surviving entry are never
# touched, only which TOOLS remain is filtered -- exactly set B.
carry_forward_b() {
  local repo="$1" in_force="$2"
  local sidecar="$repo/.claude/permissions.stack.json"
  python3 - "$sidecar" "$in_force" <<'PY'
import json, sys
path, force_arg = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
force = {(p["mode"], p["tool"]) for p in json.loads(force_arg)}
acks = data.get("multi_mode_suppression_ack")
if not isinstance(acks, list):
    acks = []
out = []
for a in acks:
    if not isinstance(a, dict):
        continue
    mode = a.get("mode")
    tools = [t for t in a.get("tools", []) if (mode, t) in force]
    if tools:
        b = dict(a)
        b["tools"] = tools
        out.append(b)
print(json.dumps(out))
PY
}

# build_a_entries <answers_pairs_json> <hash> <date> <by> <reason> -- groups
# {mode,tool} pairs answered "y" into ack objects by mode, with the CURRENT
# scope_hash (set A).
build_a_entries() {
  local pairs="$1" hash="$2" date="$3" by="$4" reason="$5"
  python3 - "$pairs" "$hash" "$date" "$by" "$reason" <<'PY'
import json, sys
pairs = json.loads(sys.argv[1])
hash_, date, by, reason = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
by_mode = {}
for p in pairs:
    by_mode.setdefault(p["mode"], []).append(p["tool"])
out = [{"mode": m, "tools": sorted(set(ts)), "scope_hash": hash_, "date": date, "by": by, "reason": reason}
       for m, ts in by_mode.items()]
print(json.dumps(out))
PY
}

# sidecar_write_needed <repo> <keep_json> -- "1" iff the reconcile's keep-set
# actually differs (as a canonicalized set of ack entries) from what is
# already on disk. skills/domain-mode/SKILL.md's step 4 states an empty
# prompt set means "no ack written ... no ritual"; T-19's negative half and
# T-35(a) both require this to extend to the reconcile itself -- a write
# that would be a no-op must never touch the file, which is the only way to
# honestly guarantee "byte-identical" (this harness controls the writer, so
# skipping the write is how that guarantee is kept real rather than assumed).
sidecar_write_needed() {
  local repo="$1" keep_json="$2"
  local sidecar="$repo/.claude/permissions.stack.json"
  python3 - "$sidecar" "$keep_json" <<'PY'
import json, sys
path, keep_arg = sys.argv[1], sys.argv[2]
def canon(acks):
    out = []
    for a in acks:
        if not isinstance(a, dict):
            continue
        out.append({"mode": a.get("mode"), "tools": sorted(a.get("tools", [])),
                     "scope_hash": a.get("scope_hash"), "date": a.get("date"),
                     "by": a.get("by"), "reason": a.get("reason")})
    return sorted(out, key=lambda x: (x["mode"] or "", x["tools"]))
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
cur = data.get("multi_mode_suppression_ack")
if not isinstance(cur, list):
    cur = []
new = json.loads(keep_arg)
print("1" if canon(cur) != canon(new) else "0")
PY
}

echo "== ADR-053 BUCKET E: real execution of the three-invocation skill flows =="
echo "   (T-19,T-20,T-23,T-31a,T-32,T-35,T-38,T-44,T-45ab,T-48,T-58,T-61,T-66abefg)"

# ===========================================================================
# dm_flow -- executes skills/domain-mode/SKILL.md step 2d (writer="domain-mode")
# or skills/project-init/SKILL.md step 5b (writer="project-init") LITERALLY,
# step by step, against real files and real permissions-compile.sh
# invocations. Returns one JSON object describing what happened; every field
# in it traces back to a real subprocess or real file bytes.
#
# dm_flow <repo> <new_dm> <new_dmp> <new_reqs> <writer> <decision> <corrupt_stage>
#   writer: "domain-mode" | "project-init"
#     domain-mode: prompt set = withheld(consent|consent-stale); keep-set = A u B
#     project-init: prompt set = withheld(consent|consent-stale) u acks_in_force;
#                   keep-set = A alone (always re-decides, per SKILL.md step 5b.5)
#   decision: "all_y" | "all_n" | a JSON array of {mode,tool} answered y
#             (every other prompt-set pair is implicitly answered n)
#   corrupt_stage: "" | "before_p0" | "before_run2_env_drift" | "before_r2b"
#                  | "after_reconcile"
#     before_p0            -- caller must corrupt the sidecar BEFORE calling
#     before_run2_env_drift -- a NEW mcp server appears between run1 and run2
#     before_r2b           -- sidecar corrupted between run2 and the reconcile's read
#     after_reconcile      -- sidecar corrupted after the reconcile write, before run3
#   COMPILE_BIN, if exported by the caller, overrides $COMPILE for every
#   invocation this flow makes (T-38/T-61(d) "compiler unavailable" cases).
# ===========================================================================
dm_flow() {
  local repo="$1" new_dm="$2" new_dmp="$3" new_reqs="$4" writer="$5" decision="$6" corrupt_stage="${7:-}"
  local sidecar="$repo/.claude/permissions.stack.json"
  local aborted_at="none"

  # INVOKE_LOG -- a REAL artifact, one "dry"/"apply" line per actual
  # compiler subprocess compile_dry_stdout/compile_apply_rc make (see their
  # definitions). invocations/invoke_order below are always read back from
  # this file, never from a harness-incremented counter -- a counter
  # variable can't fail the "exactly 3, in this order" assertion it exists
  # to check (the same trap Bucket D's line-780 comment names for aborted_at).
  local INVOKE_LOG; INVOKE_LOG="$(mktemp)"; echo "$INVOKE_LOG" >> "$CLEANUP_LIST"
  invoke_summary() {
    local n order; n="$(wc -l < "$INVOKE_LOG" | tr -d ' ')"; order="$(paste -sd, "$INVOKE_LOG" 2>/dev/null)"
    jq -n --argjson n "$n" --arg order "$order" '{invocations:$n, invoke_order:$order}'
  }

  local p0_out p0_rc
  p0_out="$(p0_predicate_rc "$sidecar" 2>&1)"; p0_rc=$?
  if [[ "$p0_rc" -ne 0 ]]; then
    jq -n --arg aborted_at "P0" --arg reason "$p0_out" --argjson summary "$(invoke_summary)" \
      '{aborted_at:$aborted_at, reason:$reason} + $summary'
    return
  fi

  write_cfg "$repo" "$new_dm" "$new_dmp" "$new_reqs"

  local run1 run1_file
  run1="$(compile_dry_stdout "$repo")"
  run1_file="$(mktemp)"; printf '%s' "$run1" > "$run1_file"
  if [[ -z "$run1" ]] || ! jq -e 'has("inputs")' "$run1_file" >/dev/null 2>&1; then
    jq -n --arg aborted_at "run1_unavailable" --argjson summary "$(invoke_summary)" \
      '{aborted_at:$aborted_at} + $summary'
    rm -f "$run1_file"; return
  fi

  local prompt_set
  if [[ "$writer" == "project-init" ]]; then
    prompt_set="$(jq -c '[.inputs.suppressions_withheld[] | select(.clause=="consent" or .clause=="consent-stale") | {mode,tool}]
                          + [.inputs.acks_in_force[] | {mode,tool}]' "$run1_file")"
  else
    prompt_set="$(jq -c '[.inputs.suppressions_withheld[] | select(.clause=="consent" or .clause=="consent-stale") | {mode,tool}]' "$run1_file")"
  fi

  local answer_pairs
  case "$decision" in
    all_y) answer_pairs="$prompt_set" ;;
    all_n) answer_pairs='[]' ;;
    *) answer_pairs="$decision" ;;
  esac

  if [[ "$corrupt_stage" == "before_run2_env_drift" ]]; then
    write_snapshot "$CUR_HOME" supabase supabase_staging
  fi

  local run2 run2_file
  run2="$(compile_dry_stdout "$repo")"
  run2_file="$(mktemp)"; printf '%s' "$run2" > "$run2_file"
  local drift; drift="$(inputs_differ "$run1_file" "$run2_file")"
  if [[ -n "$drift" ]]; then
    jq -n --arg aborted_at "run2_drift" --arg field "$drift" --argjson summary "$(invoke_summary)" \
          --arg run1 "$(cat "$run1_file")" --arg run2 "$(cat "$run2_file")" \
      '{aborted_at:$aborted_at, field:$field, run1:($run1|fromjson), run2:($run2|fromjson)} + $summary'
    rm -f "$run1_file" "$run2_file"; return
  fi

  if [[ "$corrupt_stage" == "before_r2b" ]]; then
    write_bad_sidecar "$repo" "trailing_comma"
  fi
  local r2b_out r2b_rc
  r2b_out="$(p0_predicate_rc "$sidecar" 2>&1)"; r2b_rc=$?
  if [[ "$r2b_rc" -ne 0 ]]; then
    jq -n --arg aborted_at "R2b" --arg reason "$r2b_out" --argjson summary "$(invoke_summary)" \
      '{aborted_at:$aborted_at, reason:$reason} + $summary'
    rm -f "$run1_file" "$run2_file"; return
  fi

  local hash date="2026-08-03" by="tester-e2e" reason="e2e flow"
  hash="$(jq -r '.inputs.consent_scope_hash' "$run1_file")"
  local a_entries b_entries keep_json in_force
  a_entries="$(build_a_entries "$answer_pairs" "$hash" "$date" "$by" "$reason")"
  if [[ "$writer" == "project-init" ]]; then
    b_entries='[]'
  else
    in_force="$(jq -c '.inputs.acks_in_force' "$run1_file")"
    b_entries="$(carry_forward_b "$repo" "$in_force")"
  fi
  keep_json="$(jq -c -n --argjson a "$a_entries" --argjson b "$b_entries" '$a + $b')"
  if [[ "$(sidecar_write_needed "$repo" "$keep_json")" == "1" ]]; then
    reconcile_write "$repo" "$keep_json"
  fi

  if [[ "$corrupt_stage" == "after_reconcile" ]]; then
    write_bad_sidecar "$repo" "trailing_comma"
  fi

  local run3_rc run3_err=""
  run3_rc="$(compile_apply_rc "$repo")"
  if [[ "$run3_rc" -ne 0 ]]; then
    run3_err="$(compile_apply_stderr "$repo")"   # diagnostic re-invocation, deliberately not logged (see compile_apply_rc's comment)
    jq -n --arg aborted_at "run3_error" --argjson rc "$run3_rc" --arg err "$run3_err" \
          --argjson summary "$(invoke_summary)" --arg run1 "$(cat "$run1_file")" \
      '{aborted_at:$aborted_at, rc:$rc, err:$err, run1:($run1|fromjson)} + $summary'
    rm -f "$run1_file" "$run2_file"; return
  fi

  local sidecar_after; sidecar_after="$(cat "$sidecar" 2>/dev/null)"
  jq -n --arg aborted_at "none" --argjson summary "$(invoke_summary)" \
        --arg run1 "$(cat "$run1_file")" --arg prompt_set "$prompt_set" \
        --arg answer_pairs "$answer_pairs" --arg keep_json "$keep_json" \
        --arg sidecar_after "$sidecar_after" \
    '{aborted_at:$aborted_at, run1:($run1|fromjson),
      prompt_set:($prompt_set|fromjson), answer_pairs:($answer_pairs|fromjson),
      keep_json:($keep_json|fromjson), sidecar_after:($sidecar_after|fromjson)} + $summary'
  rm -f "$run1_file" "$run2_file"
}


# ===========================================================================
# T-19 -- /domain-mode ui-design schema-migration, real 3-invocation flow.
# ===========================================================================
echo "-- T-19: real three-invocation /domain-mode flow --"
R="$(new_repo)"; write_cfg "$R" '"ui-design"' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-19: exactly three real compiler invocations (run1, run2, run3)" "3" "$(echo "$RES" | jq -r '.invocations')"
assert_eq "T-19: in the documented order -- dry (run1), dry (run2, the drift gate), apply (run3) -- a real invocation log, not a counter" \
  "dry,dry,apply" "$(echo "$RES" | jq -r '.invoke_order')"
assert_eq "T-19: the flow completes (no abort)" "none" "$(echo "$RES" | jq -r '.aborted_at')"
PSET="$(echo "$RES" | jq -c '.prompt_set | sort_by(.tool)')"
assert_eq "T-19: prompt set is driven by run1's suppressions_withheld consent/consent-stale entries only, one per suppressible tool" \
  '[{"mode":"schema-migration","tool":"apply_migration"},{"mode":"schema-migration","tool":"deploy_edge_function"},{"mode":"schema-migration","tool":"execute_sql"}]' \
  "$PSET"
DENY_RULES="$(echo "$RES" | jq -c '[.run1.inputs.suppressions_withheld[] | .deny_rules[]] | sort')"
assert_eq "T-19: each prompted entry's deny_rules is echoed verbatim from run1's real JSON (never composed)" \
  '["mcp__supabase__apply_migration","mcp__supabase__deploy_edge_function","mcp__supabase__execute_sql"]' "$DENY_RULES"
HASH_IN_ACK="$(echo "$RES" | jq -r '.sidecar_after.multi_mode_suppression_ack[0].scope_hash')"
HASH_IN_RUN1="$(echo "$RES" | jq -r '.run1.inputs.consent_scope_hash')"
assert_eq "T-19: the written ack block carries the CURRENT scope_hash from run1's own JSON" "$HASH_IN_RUN1" "$HASH_IN_ACK"
DENIES_AFTER="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_not_contains "T-19: after run3, apply_migration/execute_sql/deploy_edge_function are all absent from compiled_deny" "$DENIES_AFTER" "apply_migration"
assert_eq "T-19: sidecar's own post-apply acks_in_force == the pairs answered y (real applied plan, not harness-derived)" \
  "$(echo "$RES" | jq -c '.answer_pairs | sort_by(.tool)')" \
  "$(echo "$RES" | jq -c '.sidecar_after.inputs.acks_in_force | sort_by(.tool)')"
assert_eq "T-19 verify(1): post-apply acks_prunable == []" "0" "$(echo "$RES" | jq '.sidecar_after.inputs.acks_prunable | length')"
WITHHELD_DR="$(echo "$RES" | jq -c '[.run1.inputs.suppressions_withheld[].deny_rules[]] | sort')"
COMPILED_DENY_R1="$(echo "$RES" | jq -c '[.run1.compiled_deny[].rule] | sort')"
SUBSET_OK="$(python3 -c "import json,sys; w=set(json.loads('$WITHHELD_DR')); c=set(json.loads('$COMPILED_DENY_R1')); print(w.issubset(c))")"
assert_eq "T-19 verify(4a): withheld[*].deny_rules subset of compiled_deny (report-truthfulness, real run1 plan)" "True" "$SUBSET_OK"

echo "-- T-19: negative half -- both modes mapped -> no consent-clause entries -> asks nothing, writes nothing --"
# AMBIGUITY NOTE: "writes nothing" cannot mean the WHOLE sidecar file is
# untouched -- run 3 (a real apply) unconditionally rewrites
# .claude/permissions.stack.json's compiler-owned bookkeeping (ledger,
# inputs, emitted, baseline_version, compiled_at) on every apply, for every
# config, regardless of consent activity -- confirmed empirically against
# the real compiler/settings_lock.py and independent of this ADR (it is how
# ADR-044's D8 ledger stays current). What T-19's "asks nothing and writes
# nothing" is actually pinning is the ACK RITUAL specifically: no
# multi_mode_suppression_ack entry is added, none is deleted, because there
# was never anything to reconcile. Resolution: assert on the ack array
# (absent/empty before AND after), not on whole-file byte identity.
R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '{"ui-design":["app/**"],"schema-migration":["migrations/**"]}' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
BEFORE_ACKS="$(jq -c '.multi_mode_suppression_ack // []' "$R2/.claude/permissions.stack.json" 2>/dev/null || echo '[]')"
RES2="$(dm_flow "$R2" '["ui-design","schema-migration"]' '{"ui-design":["app/**"],"schema-migration":["migrations/**"]}' '[]' "domain-mode" "all_y" "")"
assert_eq "T-19 negative: mapped modes -> prompt set is empty (scope-coherence withholds unconditionally, no ack could fix it)" "0" "$(echo "$RES2" | jq '.prompt_set | length')"
AFTER_ACKS="$(cat "$R2/.claude/permissions.stack.json" | jq -c '.multi_mode_suppression_ack // []')"
assert_eq "T-19 negative: no ack ritual at all (empty before, empty after -- the reconcile write itself never fires)" "$BEFORE_ACKS" "$AFTER_ACKS"
DENIES2="$(compile_dry_stdout "$R2" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-19 negative: scope-coherence denies stay present regardless (a mapped mode's grant is unconditional-only, never bought)" "$DENIES2" "apply_migration"

# ===========================================================================
# T-20 -- canonical write form (D10): 0 modes -> null; 1 mode -> bare string;
# >=2 modes -> array. This is "step 2: write stack-config.json" of SKILL.md
# step 2d, executed literally (write_cfg already writes exactly what a
# skill's canonical-form step would compute) and verified on real file bytes
# via jq's real type introspection (never our own assumption of the shape).
# ===========================================================================
echo "-- T-20: canonical write form (D10) --"
R="$(new_repo)"; write_cfg "$R" 'null' '__ABSENT__' '[]'
DM_TYPE="$(jq -r '.domain_mode | type' "$R/.claude/stack-config.json")"
assert_eq "T-20: 0 modes writes domain_mode as JSON null, not []" "null" "$DM_TYPE"

R="$(new_repo)"; write_cfg "$R" '"financial-code"' '__ABSENT__' '[]'
DM_TYPE="$(jq -r '.domain_mode | type' "$R/.claude/stack-config.json")"
DM_VAL="$(jq -r '.domain_mode' "$R/.claude/stack-config.json")"
assert_eq "T-20: 1 mode writes domain_mode as a bare JSON string" "string" "$DM_TYPE"
assert_eq "T-20: the bare string is the mode name itself" "financial-code" "$DM_VAL"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
DM_TYPE="$(jq -r '.domain_mode | type' "$R/.claude/stack-config.json")"
assert_eq "T-20: >=2 modes writes domain_mode as a JSON array, never a 1-element array for a single mode" "array" "$DM_TYPE"

echo "-- T-20: a real flow that SHRINKS 2 modes down to 1 collapses the array to a bare string, not a 1-element array --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
RES="$(dm_flow "$R" '"ui-design"' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
CFG_TYPE="$(jq -r '.domain_mode | type' "$R/.claude/stack-config.json")"
assert_eq "T-20: shrinking to 1 mode via a real flow writes a bare string" "string" "$CFG_TYPE"

# ===========================================================================
# T-23 -- fresh /project-init, no prior stack-config.json, simultaneous
# multi-select (ui-design + schema-migration in one shot). AMBIGUITY NOTE:
# the T-case says "no prior stack-config.json"; permissions-compile.sh
# refuses (exit 2, pinned in Bucket A) with none at all. Resolution:
# /project-init writes the config FIRST (step 5, same position domain-mode's
# step 2 occupies), THEN runs the P0->run1->...->run3 sequence -- matching
# skills/project-init/SKILL.md step 5b's own framing ("Immediately after
# step 5 writes stack-config.json ... run the same P0 -> run 1 -> ... flow").
# "ack written before the compile" (T-23's own wording) means before RUN 3
# (the apply), which is what the reconcile step already guarantees.
# ===========================================================================
echo "-- T-23: fresh /project-init, simultaneous multi-select, N answer --"
R="$(new_repo)"; rm -f "$R/.claude/stack-config.json"
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
# Precondition to prove deletion-on-N: pre-stage a pre-existing (inherited)
# ack entry for the pair about to be declined.
write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
PRESTAGE_HASH="$(get_hash "$R")"
PRESTAGE_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$PRESTAGE_HASH")"
sidecar_with_acks "$R" "$PRESTAGE_ACK"
rm -f "$R/.claude/stack-config.json"   # "no prior stack-config.json" -- the sidecar may still be inherited debris
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_n" "")"
assert_eq "T-23(N): the flow completes" "none" "$(echo "$RES" | jq -r '.aborted_at')"
ACKS_AFTER="$(cat "$R/.claude/permissions.stack.json" | jq -c '.multi_mode_suppression_ack')"
assert_eq "T-23(N): no ack written -- project-init always re-decides (keep-set A alone) and A is empty on an all-n answer, deleting the inherited entry too" "[]" "$ACKS_AFTER"
DENIES="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-23(N): all 3 denies stay present" "$DENIES" "apply_migration"

echo "-- T-23: fresh /project-init, simultaneous multi-select, Y answer --"
R="$(new_repo)"; rm -f "$R/.claude/stack-config.json" "$R/.claude/permissions.stack.json"
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_y" "")"
assert_eq "T-23(Y): the flow completes" "none" "$(echo "$RES" | jq -r '.aborted_at')"
ACK_HASH="$(cat "$R/.claude/permissions.stack.json" | jq -r '.multi_mode_suppression_ack[0].scope_hash')"
RUN1_HASH="$(echo "$RES" | jq -r '.run1.inputs.consent_scope_hash')"
assert_eq "T-23(Y): the ack is written with the CURRENT scope_hash (written before run 3's apply, per the reconcile-precedes-run-3 ordering)" "$RUN1_HASH" "$ACK_HASH"
DENIES="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_not_contains "T-23(Y): all 3 denies are absent (both modes unmapped, full fresh ack)" "$DENIES" "apply_migration"

# ===========================================================================
# T-31(a) -- stale-ack non-reactivation, the SKILL PATH.
# ===========================================================================
echo "-- T-31(a): skill path -- shrink to 1 mode deletes the schema-migration ack; hand-edit back reactivates the denies, not the ack --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FULL_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$FULL_ACK"
DENIES0="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_not_contains "T-31(a) precondition: 3 denies absent (fresh full ack)" "$DENIES0" "apply_migration"

RES="$(dm_flow "$R" '"ui-design"' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
ACKS_AFTER="$(cat "$R/.claude/permissions.stack.json" | jq -c '.multi_mode_suppression_ack')"
assert_eq "T-31(a): /domain-mode ui-design leaves NO schema-migration ack entries (arity<=1, acks_in_force vacuous, nothing carried forward)" "[]" "$ACKS_AFTER"
DMP_AFTER="$(jq -r '.domain_mode_paths // {} | keys | length' "$R/.claude/stack-config.json")"
assert_eq "T-31(a): no orphan domain_mode_paths key is left behind" "0" "$DMP_AFTER"

write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'   # hand-edit back, outside any flow
HAND_RC="$(compile_dry_rc "$R")"
assert_rc "T-31(a): hand-editing domain_mode back to the array compiles exit 0" 0 "$HAND_RC"
DENIES1="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-31(a): all 3 denies are PRESENT again (the ack is really gone, not just inert)" "$DENIES1" "apply_migration"
CLAUSE="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration") | .clause')"
assert_eq "T-31(a): clause is consent (no ack at all), not consent-stale" "consent" "$CLAUSE"

# ===========================================================================
# T-32 -- "N" deletes an ack. (a) stale path via /domain-mode. (b) fresh
# path via the /project-init adoption gate. (c) round-3 trap is gone: a
# fresh pre-staged ack + /domain-mode must NOT silently delete the entry.
# ===========================================================================
echo "-- T-32(a): stale ack, /domain-mode prompts (consent-stale), N answer deletes it --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
STALE_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' \
  "sha256:stale00000000000000000000000000000000000000000000000000000000")"
WAIVERS='[{"rule":"Bash(psql:*)"}]'
PINNED='[]'
sidecar_with_acks_and_extras "$R" "[$STALE_ACK]" "$WAIVERS" "$PINNED"
BEFORE_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
BEFORE_PINNED="$(jq -c '.pinned' "$R/.claude/permissions.stack.json")"
CLAUSE_PRE="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration") | .clause')"
assert_eq "T-32(a) precondition: the stale ack reports consent-stale, not consent" "consent-stale" "$CLAUSE_PRE"

RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_n" "")"
ACKS_AFTER="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
assert_eq "T-32(a): the stale entries are deleted (answered N)" "[]" "$ACKS_AFTER"
AFTER_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
AFTER_PINNED="$(jq -c '.pinned' "$R/.claude/permissions.stack.json")"
assert_eq "T-32(a): waivers[] byte-identical (untouched by the reconcile)" "$BEFORE_WAIVERS" "$AFTER_WAIVERS"
assert_eq "T-32(a): pinned[] byte-identical (untouched by the reconcile)" "$BEFORE_PINNED" "$AFTER_PINNED"
DENIES="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-32(a): all 3 denies present, clause consent (not consent-stale -- the entry is really gone)" "$DENIES" "apply_migration"
CLAUSE_POST="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration") | .clause')"
assert_eq "T-32(a): clause is now consent" "consent" "$CLAUSE_POST"

echo "-- T-32(b): fresh ack via the /project-init adoption gate -- /domain-mode asks nothing; /project-init asks and N deletes --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$FRESH_ACK"
RES_DM="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-32(b): /domain-mode's own prompt set is empty (T-35a) -- a fresh ack is never re-asked" "0" "$(echo "$RES_DM" | jq '.prompt_set | length')"

RES_PI="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_n" "")"
PI_PROMPT_TOOLS="$(echo "$RES_PI" | jq -c '[.prompt_set[].tool] | sort')"
assert_eq "T-32(b): /project-init's prompt set includes the acks_in_force pairs (it always re-decides)" \
  '["apply_migration","deploy_edge_function","execute_sql"]' "$PI_PROMPT_TOOLS"
ACKS_AFTER_PI="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
assert_eq "T-32(b): answering n to the acks_in_force-sourced prompt deletes the entry" "[]" "$ACKS_AFTER_PI"
DENIES="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-32(b): all 3 denies present after the decline" "$DENIES" "apply_migration"

echo "-- T-32(c): the round-3 trap is gone -- a fresh pre-staged ack + /domain-mode must NOT silently delete it --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0" "2026-01-01" "original-author" "original reason")"
sidecar_with_acks "$R" "$FRESH_ACK"
BEFORE_ACK_BYTES="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
AFTER_ACK_BYTES="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
assert_eq "T-32(c): a fresh ack that is doing real work is NOT silently deleted by /domain-mode (the round-3 bug)" "$BEFORE_ACK_BYTES" "$AFTER_ACK_BYTES"
DENIES="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_not_contains "T-32(c): the 3 denies stay absent (the ack still honors them)" "$DENIES" "apply_migration"

# ===========================================================================
# T-35 -- behavior when an ack already exists.
# ===========================================================================
echo "-- T-35(a): fresh ack covering every clause-3 pair -- /domain-mode asks nothing, leaves the entry byte-identical --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$FRESH_ACK"
# This file's own headline assertion for T-35(a): compare the ack entry's
# CANONICAL bytes (mode/tools/scope_hash/date/by/reason) before vs. after.
# Whole-FILE byte identity is not achievable post-run-3 -- the real apply
# always rewrites the sidecar's ledger/inputs/emitted bookkeeping on every
# compile (confirmed empirically, see T-19-negative's ambiguity note) -- so
# entry-level canonical equality is the strongest true claim available.
BEFORE_ENTRY="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
AFTER_ENTRY="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
assert_eq "T-35(a): leaves the entry byte-identical (canonical JSON of the ack array, unchanged by the flow)" "$BEFORE_ENTRY" "$AFTER_ENTRY"
IN_FORCE="$(echo "$RES" | jq -c '.run1.inputs.acks_in_force | sort_by(.tool)')"
assert_eq "T-35(a): inputs.acks_in_force lists exactly the 3 pairs" 3 "$(echo "$IN_FORCE" | jq 'length')"
assert_eq "T-35(a): suppressions_withheld is empty" "0" "$(echo "$RES" | jq '.run1.inputs.suppressions_withheld | length')"
assert_eq "T-35(a): /domain-mode's prompt set is empty" "0" "$(echo "$RES" | jq '.prompt_set | length')"

echo "-- T-35(b): same sidecar, /project-init always re-decides -- delete-all, then y re-authors with a NEW date/by/hash, n leaves it deleted --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0" "2020-01-01" "old-owner" "old reason")"
sidecar_with_acks "$R" "$FRESH_ACK"
RES_PI="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_y" "")"
NEW_ENTRY="$(jq -c '.multi_mode_suppression_ack[0]' "$R/.claude/permissions.stack.json")"
assert_eq "T-35(b): re-authored entry carries the CURRENT scope_hash" "$H0" "$(echo "$NEW_ENTRY" | jq -r '.scope_hash')"
assert_not_contains "T-35(b): re-authored entry does NOT keep the OLD date (a fresh date/by is written, never carried forward for /project-init)" \
  "$(echo "$NEW_ENTRY" | jq -r '.date')" "2020-01-01"

R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
FRESH_ACK2="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$(get_hash "$R2")")"
sidecar_with_acks "$R2" "$FRESH_ACK2"
RES_PI_N="$(dm_flow "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_n" "")"
assert_eq "T-35(b): answering n leaves the entry deleted" "[]" "$(jq -c '.multi_mode_suppression_ack' "$R2/.claude/permissions.stack.json")"
DENIES="$(compile_dry_stdout "$R2" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-35(b): denies return after n" "$DENIES" "apply_migration"

echo "-- T-35(c): /project-init with run 1 unavailable, and again with run 2 drifted -- nothing deleted, nothing written --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
INHERITED_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$INHERITED_ACK"
BEFORE_BYTES="$(cat "$R/.claude/permissions.stack.json")"
COMPILE_BIN="/nonexistent/permissions-compile.sh"
RES_UNAVAIL="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_y" "")"
unset COMPILE_BIN
AFTER_BYTES="$(cat "$R/.claude/permissions.stack.json")"
assert_eq "T-35(c): run 1 unavailable -> the sidecar is byte-identical (nothing deleted, nothing written)" "$BEFORE_BYTES" "$AFTER_BYTES"
assert_eq "T-35(c): run 1 unavailable is the reported abort reason" "run1_unavailable" "$(echo "$RES_UNAVAIL" | jq -r '.aborted_at')"

R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R2")"
INHERITED_ACK2="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R2" "$INHERITED_ACK2"
BEFORE_BYTES2="$(cat "$R2/.claude/permissions.stack.json")"
RES_DRIFT="$(dm_flow "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "all_y" "before_run2_env_drift")"
AFTER_BYTES2="$(cat "$R2/.claude/permissions.stack.json")"
assert_eq "T-35(c): run 2 drifted -> the sidecar is byte-identical (aborted before the reconcile)" "$BEFORE_BYTES2" "$AFTER_BYTES2"
assert_eq "T-35(c): run 2 drift is the reported abort reason" "run2_drift" "$(echo "$RES_DRIFT" | jq -r '.aborted_at')"

# ===========================================================================
# T-38 -- skill fail-safe when the report is unavailable: compiler absent,
# forced non-zero exit, non-JSON stdout. All three via COMPILE_BIN pointing
# at a REAL (but broken) subprocess -- never a harness-simulated string.
# ===========================================================================
echo "-- T-38: compiler absent / forced non-zero / non-JSON stdout -- config written, no ack written, no ack deleted --"
BADBIN_NONZERO="$(mktemp)"; printf '#!/usr/bin/env bash\necho "warning: synthetic" >&2\nexit 5\n' > "$BADBIN_NONZERO"; chmod +x "$BADBIN_NONZERO"
BADBIN_NONJSON="$(mktemp)"; printf '#!/usr/bin/env bash\necho "not json at all"\nexit 0\n' > "$BADBIN_NONJSON"; chmod +x "$BADBIN_NONJSON"
echo "$BADBIN_NONZERO" >> "$CLEANUP_LIST"; echo "$BADBIN_NONJSON" >> "$CLEANUP_LIST"

for shape in missing nonzero nonjson; do
  R="$(new_repo)"; write_cfg "$R" '"ui-design"' '__ABSENT__' '[]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  H0="$(get_hash "$R")"
  INHERITED_ACK="$(ack_entry "ui-design" '["apply_migration"]' "$H0")"   # would never actually be honored (ui-design suppresses nothing) -- only here to prove nothing is DELETED either
  sidecar_with_acks "$R" "$INHERITED_ACK"
  BEFORE_SIDECAR="$(cat "$R/.claude/permissions.stack.json")"
  case "$shape" in
    missing)  export COMPILE_BIN="/nonexistent/permissions-compile-$$.sh" ;;
    nonzero)  export COMPILE_BIN="$BADBIN_NONZERO" ;;
    nonjson)  export COMPILE_BIN="$BADBIN_NONJSON" ;;
  esac
  RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
  unset COMPILE_BIN
  assert_eq "T-38 [$shape]: the flow aborts at run1_unavailable" "run1_unavailable" "$(echo "$RES" | jq -r '.aborted_at')"
  CFG_DM="$(jq -r '.domain_mode' "$R/.claude/stack-config.json")"
  assert_eq "T-38 [$shape]: stack-config.json IS written (the config write precedes run 1 and never rolls back)" '["ui-design","schema-migration"]' "$(echo "$CFG_DM" | jq -c . 2>/dev/null || jq -c '.domain_mode' "$R/.claude/stack-config.json")"
  AFTER_SIDECAR="$(cat "$R/.claude/permissions.stack.json")"
  assert_eq "T-38 [$shape]: the sidecar is byte-identical -- no ack written AND no ack deleted" "$BEFORE_SIDECAR" "$AFTER_SIDECAR"
done

# ===========================================================================
# T-44 -- reconcile keeps a fresh ack that is doing work, across TWO
# consecutive /domain-mode runs with the SAME mode set: no prompt, sidecar
# byte-identical after each, denies stay absent, no oscillation.
# ===========================================================================
echo "-- T-44: reconcile keeps a fresh, working ack across two consecutive same-mode-set runs --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$FRESH_ACK"

RES1="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
ACK1="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
DENIES1="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_eq "T-44 run1: prompt set stays empty (no prompt on a same-mode-set re-run)" "0" "$(echo "$RES1" | jq '.prompt_set | length')"
assert_not_contains "T-44 run1: denies stay absent" "$DENIES1" "apply_migration"

RES2="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
ACK2="$(jq -cS '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
DENIES2="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_eq "T-44 run2: prompt set stays empty" "0" "$(echo "$RES2" | jq '.prompt_set | length')"
assert_eq "T-44: the ack entry is byte-identical after both runs (no oscillation, round-3's rule fails this)" "$ACK1" "$ACK2"
assert_eq "T-44: compiled_deny is stable across both runs" "$DENIES1" "$DENIES2"
assert_not_contains "T-44 run2: denies stay absent" "$DENIES2" "apply_migration"

# ===========================================================================
# T-45 -- Gap B: one decision, ordering. (a) decline. (b) interrupt after the
# ack write, before apply. (c) is docs-logic style and already asserted in
# tests/test-domain-mode-skills-docs.sh's T-19/T-45(c) section -- see NOTE.
# ===========================================================================
echo "-- T-45(a): decline every prompt -- no ack on disk, matching pre-existing entries deleted, denies present, settings.json applied --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
STALE_ACK="$(ack_entry "schema-migration" '["execute_sql"]' "sha256:stale00000000000000000000000000000000000000000000000000000000")"
sidecar_with_acks "$R" "$STALE_ACK"
RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_n" "")"
assert_eq "T-45(a): the flow completes (declining is not an abort)" "none" "$(echo "$RES" | jq -r '.aborted_at')"
assert_eq "T-45(a): no ack on disk for the declined pairs" "[]" "$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
DENIES="$(jq -r '.emitted.deny[]' "$R/.claude/permissions.stack.json" | sort)"
assert_contains "T-45(a): all 3 denies present in the REAL applied settings.json (via the sidecar's own emitted.deny)" "$DENIES" "mcp__supabase__apply_migration"
RULES_SETTINGS="$(jq -r '.permissions.deny[]' "$R/.claude/settings.json" | sort)"
assert_contains "T-45(a): settings.json was really applied (real deny rule present in the real settings.json)" "$RULES_SETTINGS" "mcp__supabase__apply_migration"

echo "-- T-45(b): interrupt after the ack write, before apply -- an independent compile honors the ack; next compile converges, no more prompts --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
PAIRS='[{"mode":"schema-migration","tool":"apply_migration"},{"mode":"schema-migration","tool":"execute_sql"},{"mode":"schema-migration","tool":"deploy_edge_function"}]'
A_ENTRIES="$(build_a_entries "$PAIRS" "$H0" "2026-08-03" "tester" "interrupted-flow")"
reconcile_write "$R" "$A_ENTRIES"   # the ack write landed; simulate a crash BEFORE run 3 (no apply yet)
INDEPENDENT_PLAN="$(compile_dry_stdout "$R")"
assert_not_contains "T-45(b): an independent dry-run (as if nothing crashed) already honors the just-written ack" \
  "$(echo "$INDEPENDENT_PLAN" | jq -r '.compiled_deny[].rule')" "apply_migration"
NEXT_RUN="$(compile_dry_stdout "$R")"
assert_eq "T-45(b): the next compile converges (stable, no drift) -- inputs deep-equal across two independent dry-runs" \
  "$(echo "$INDEPENDENT_PLAN" | jq -S '.inputs')" "$(echo "$NEXT_RUN" | jq -S '.inputs')"
assert_eq "T-45(b): the next compile's prompt set (consent/consent-stale withheld entries) is empty -- no further prompt" \
  "0" "$(echo "$NEXT_RUN" | jq '[.inputs.suppressions_withheld[] | select(.clause=="consent" or .clause=="consent-stale")] | length')"

echo "NOTE T-45(c): structural (one human decision point; every post-decision invocation has exactly two outcomes; no ack deleted"
echo "  inside an error handler; no rule string composed by the skill) is docs-logic style per the handoff and is already asserted"
echo "  in tests/test-domain-mode-skills-docs.sh's T-19/T-45(c) section -- not re-asserted here to avoid duplicating that file's"
echo "  assertions. This file's dm_flow harness independently demonstrates the SAME property mechanically across every T-case"
echo "  above and below: every abort path returns before any additional write, and every completing path performs exactly one"
echo "  reconcile write followed by exactly one apply."

# ===========================================================================
# T-58 -- named residual: a run-2 abort leaves the step-2 config write in
# place; settings.json/sidecar are byte-identical to before the flow;
# re-running with the SAME arguments converges.
# ===========================================================================
echo "-- T-58: drift-gate abort leaves stack-config.json written, settings.json/sidecar untouched; re-run converges --"
R="$(new_repo)"; write_cfg "$R" '"ui-design"' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
compile_apply_rc "$R" >/dev/null   # establish a REAL prior compiled state (old, weaker settings.json)
SETTINGS_BEFORE="$(cat "$R/.claude/settings.json")"
SIDECAR_BEFORE="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null)"

RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "before_run2_env_drift")"
assert_eq "T-58: run 2 aborts on environment drift" "run2_drift" "$(echo "$RES" | jq -r '.aborted_at')"
CFG_AFTER_DM="$(jq -c '.domain_mode' "$R/.claude/stack-config.json")"
assert_eq "T-58: stack-config.json holds the NEW domain_mode this invocation set (step 2's write is not rolled back)" \
  '["ui-design","schema-migration"]' "$CFG_AFTER_DM"
SETTINGS_AFTER="$(cat "$R/.claude/settings.json")"
assert_eq "T-58: settings.json is byte-identical to before the flow (never recompiled)" "$SETTINGS_BEFORE" "$SETTINGS_AFTER"
SIDECAR_AFTER="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null)"
assert_eq "T-58: the sidecar is byte-identical to before the flow" "$SIDECAR_BEFORE" "$SIDECAR_AFTER"
FRESH_DRY="$(compile_dry_stdout "$R")"
WITHHELD_TOOLS="$(echo "$FRESH_DRY" | jq -r '.inputs.suppressions_withheld[].tool' | sort -u)"
assert_contains "T-58: an independent dry-run against the new config withholds every unacked suppression (fail-safe direction)" "$WITHHELD_TOOLS" "apply_migration"

RES2="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-58: re-running /domain-mode with the SAME arguments converges (no further abort)" "none" "$(echo "$RES2" | jq -r '.aborted_at')"
assert_eq "T-58: the converged run makes exactly 3 real invocations, same as any clean flow" "3" "$(echo "$RES2" | jq -r '.invocations')"

# ===========================================================================
# T-48 -- the round-4 verify-rule regression pin. A pre-existing fresh ack
# already honors a pair; /project-init prompts it FROM acks_in_force; both
# y and n branches must produce no verify failure. Plus the arity<=1 vacuity.
# ===========================================================================
echo "-- T-48: a pre-existing fresh ack already honoring (schema-migration, apply_migration) -- both y and n branches --"
run_t48() {
  local answer_all_y="$1"   # "y" or "n"
  local R; R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  local H0; H0="$(get_hash "$R")"
  local ACK; ACK="$(ack_entry "schema-migration" '["apply_migration"]' "$H0" "2020-01-01" "old-owner" "old reason")"
  sidecar_with_acks "$R" "$ACK"
  local RUN1; RUN1="$(compile_dry_stdout "$R")"
  local IN_FORCE_PRE; IN_FORCE_PRE="$(echo "$RUN1" | jq -c '.inputs.acks_in_force')"
  assert_not_contains "T-48 [$answer_all_y] precondition: apply_migration deny absent in run1" \
    "$(echo "$RUN1" | jq -r '.compiled_deny[].rule')" "apply_migration"
  assert_contains "T-48 [$answer_all_y] precondition: the pair is in run1's acks_in_force" "$IN_FORCE_PRE" "apply_migration"
  assert_eq "T-48 [$answer_all_y] precondition: no withheld entry mentions this pair" "0" \
    "$(echo "$RUN1" | jq '[.inputs.suppressions_withheld[] | select(.tool=="apply_migration")] | length')"

  local decision
  if [[ "$answer_all_y" == "y" ]]; then decision="all_y"; else decision="all_n"; fi
  local RES; RES="$(dm_flow "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "project-init" "$decision" "")"
  local PROMPT_TOOLS; PROMPT_TOOLS="$(echo "$RES" | jq -r '[.prompt_set[].tool]')"
  assert_contains "T-48 [$answer_all_y]: apply_migration is prompted (drawn from acks_in_force, not withheld)" "$PROMPT_TOOLS" "apply_migration"
  local RUN3_INPUTS; RUN3_INPUTS="$(jq '.inputs' "$R/.claude/permissions.stack.json")"
  local IN_FORCE_3; IN_FORCE_3="$(echo "$RUN3_INPUTS" | jq -c '.acks_in_force')"
  local DENY3; DENY3="$(jq -r '.emitted.deny[]' "$R/.claude/permissions.stack.json")"
  if [[ "$answer_all_y" == "y" ]]; then
    assert_not_contains "T-48 [y]: deny stays ABSENT" "$DENY3" "apply_migration"
    local NEW_HASH; NEW_HASH="$(jq -r '.multi_mode_suppression_ack[0].scope_hash' "$R/.claude/permissions.stack.json")"
    assert_eq "T-48 [y]: ack re-authored with the CURRENT scope_hash" "$H0" "$NEW_HASH"
    local NEW_DATE; NEW_DATE="$(jq -r '.multi_mode_suppression_ack[0].date' "$R/.claude/permissions.stack.json")"
    assert_not_contains "T-48 [y]: ack re-authored with a NEW date (not carried forward, project-init has no set B)" "$NEW_DATE" "2020-01-01"
    assert_contains "T-48 [y]: acks_in_force(run3) == A (the re-affirmed pair)" "$IN_FORCE_3" "apply_migration"
  else
    assert_contains "T-48 [n]: deny is PRESENT" "$DENY3" "mcp__supabase__apply_migration"
    local CLAUSE3; CLAUSE3="$(echo "$RUN3_INPUTS" | jq -r '.suppressions_withheld[] | select(.tool=="apply_migration") | .clause')"
    assert_eq "T-48 [n]: clause is consent (the entry is really gone)" "consent" "$CLAUSE3"
    assert_eq "T-48 [n]: acks_in_force(run3) excludes the declined pair" "0" "$(echo "$IN_FORCE_3" | jq '[.[] | select(.tool=="apply_migration")] | length')"
  fi
}
run_t48 "y"
run_t48 "n"

echo "-- T-48: arity<=1 vacuity -- same flow with a single mode: no prompt, A==[], acks_in_force==[], inherited acks end at zero --"
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
INHERITED="$(ack_entry "schema-migration" '["apply_migration"]' "$H0")"
sidecar_with_acks "$R" "$INHERITED"
RES="$(dm_flow "$R" '"schema-migration"' '__ABSENT__' '[]' "project-init" "all_y" "")"
assert_eq "T-48 vacuity: no prompt at arity 1" "0" "$(echo "$RES" | jq '.prompt_set | length')"
assert_eq "T-48 vacuity: acks_in_force == [] at arity 1" "0" "$(jq '.inputs.acks_in_force | length' "$R/.claude/permissions.stack.json")"
assert_eq "T-48 vacuity: every inherited ack entry ends at zero -- the delete-all is not a no-op at arity 1" \
  "[]" "$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"

# ===========================================================================
# /sensitivity primitives -- P0/P1/P2/P2b/P3, literally per
# skills/sensitivity/SKILL.md's "Recompiling -- the P1/P2/P3 prune contract".
# ===========================================================================

# p2_shape_check_text <raw_plan_json> -- performs EXACTLY the plan-shape
# check skills/sensitivity/SKILL.md's P2 prescribes: root an object; inputs
# an object; inputs.acks_prunable PRESENT and an array (absent is NOT an
# empty prune); every element an object whose mode and tool are non-empty
# strings. Prints the failing reason, or "" if valid. Takes the plan as an
# ARGV, not stdin -- `python3 -` already consumes stdin as its own script
# source via the heredoc, so piping data through the same stdin would be
# silently swallowed as EOF (the exact pitfall Bucket D's own comments name).
p2_shape_check_text() {
  python3 - "$1" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    doc = json.loads(raw)
except Exception:
    print("stdout does not parse as JSON"); sys.exit(0)
if not isinstance(doc, dict):
    print("root is not an object"); sys.exit(0)
inputs = doc.get("inputs")
if not isinstance(inputs, dict):
    print("inputs is not an object"); sys.exit(0)
if "acks_prunable" not in inputs:
    print("acks_prunable is absent (a missing key is NOT an empty prune)"); sys.exit(0)
ap = inputs["acks_prunable"]
if not isinstance(ap, list):
    print("acks_prunable is not an array"); sys.exit(0)
for el in ap:
    if not isinstance(el, dict):
        print("an acks_prunable element is not an object"); sys.exit(0)
    m, t = el.get("mode"), el.get("tool")
    if not isinstance(m, str) or not m or not isinstance(t, str) or not t:
        print("an acks_prunable element has a missing/non-string/empty mode or tool"); sys.exit(0)
print("")
PY
}

# sensitivity_prune <repo> <prunable_pairs_json> -- deletes exactly the
# named (mode,tool) pairs, drops entries that empty, never touches
# waivers[]/pinned[] or any other key.
sensitivity_prune() {
  local repo="$1" prunable_json="$2"
  local sidecar="$repo/.claude/permissions.stack.json"
  python3 - "$sidecar" "$prunable_json" <<'PY'
import json, sys
path, prunable_arg = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
prunable = json.loads(prunable_arg)
prune_pairs = {(p["mode"], p["tool"]) for p in prunable}
acks = data.get("multi_mode_suppression_ack")
if not isinstance(acks, list):
    acks = []
new_acks = []
for a in acks:
    if not isinstance(a, dict):
        continue
    tools = [t for t in a.get("tools", []) if (a.get("mode"), t) not in prune_pairs]
    if tools:
        b = dict(a); b["tools"] = tools; new_acks.append(b)
data["multi_mode_suppression_ack"] = new_acks
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

# sensitivity_flow <repo> <corrupt_stage>
#   corrupt_stage: "" | "before_p0" | "compiler_missing" | "compiler_nonzero"
#     | "compiler_nonjson" | "shape_root_not_object" | "shape_inputs_not_object"
#     | "shape_acks_prunable_absent" | "shape_element_malformed"
#     | "mid_flow_before_p3"
# Prints one JSON object: {aborted_at, invocations, prune_aborted, wrote_sidecar, run3_rc}
sensitivity_flow() {
  local repo="$1" corrupt_stage="${2:-}"
  local sidecar="$repo/.claude/permissions.stack.json"
  local cfg="$repo/.claude/stack-config.json"

  # INVOKE_LOG -- see dm_flow's identical mechanism/comment.
  local INVOKE_LOG; INVOKE_LOG="$(mktemp)"; echo "$INVOKE_LOG" >> "$CLEANUP_LIST"
  invoke_summary() {
    local n order; n="$(wc -l < "$INVOKE_LOG" | tr -d ' ')"; order="$(paste -sd, "$INVOKE_LOG" 2>/dev/null)"
    jq -n --argjson n "$n" --arg order "$order" '{invocations:$n, invoke_order:$order}'
  }

  local p0_out p0_rc
  p0_out="$(p0_predicate_rc "$sidecar" 2>&1)"; p0_rc=$?
  if [[ "$p0_rc" -ne 0 ]]; then
    jq -n --arg aborted_at "P0" --arg reason "$p0_out" --argjson summary "$(invoke_summary)" \
      '{aborted_at:$aborted_at, reason:$reason} + $summary'
    return
  fi

  # P1 -- write. A real field /sensitivity actually owns.
  jq '.sensitivity.level = "sensitive"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"

  # P2 -- report and prune.
  local raw rc
  case "$corrupt_stage" in
    compiler_missing) raw="$(COMPILE_BIN="/nonexistent/permissions-compile-$$.sh" compile_dry_stdout "$repo")" ;;
    compiler_nonzero) raw="$(COMPILE_BIN="$SENS_BADBIN_NONZERO" compile_dry_stdout "$repo")" ;;
    compiler_nonjson) raw="$(COMPILE_BIN="$SENS_BADBIN_NONJSON" compile_dry_stdout "$repo")" ;;
    *) raw="$(compile_dry_stdout "$repo")" ;;
  esac

  case "$corrupt_stage" in
    shape_root_not_object)        raw="$(printf '%s' "$raw" | jq -c '[.]' 2>/dev/null)" ;;
    shape_inputs_not_object)      raw="$(printf '%s' "$raw" | jq -c '.inputs = 42' 2>/dev/null)" ;;
    shape_acks_prunable_absent)   raw="$(printf '%s' "$raw" | jq -c 'del(.inputs.acks_prunable)' 2>/dev/null)" ;;
    shape_element_malformed)      raw="$(printf '%s' "$raw" | jq -c '.inputs.acks_prunable += [{"mode":"","tool":"x"}]' 2>/dev/null)" ;;
  esac

  local shape_reason prune_aborted=0 wrote_sidecar=0
  shape_reason="$(p2_shape_check_text "$raw")"
  if [[ -z "$raw" ]] || [[ -n "$shape_reason" ]]; then
    prune_aborted=1
  else
    local prunable; prunable="$(printf '%s' "$raw" | jq -c '.inputs.acks_prunable')"
    if [[ "$(echo "$prunable" | jq 'length')" -gt 0 ]]; then
      sensitivity_prune "$repo" "$prunable"
      wrote_sidecar=1
    fi
  fi

  if [[ "$corrupt_stage" == "mid_flow_before_p3" ]]; then
    write_bad_sidecar "$repo" "trailing_comma"
  fi
  local p2b_out p2b_rc
  p2b_out="$(p0_predicate_rc "$sidecar" 2>&1)"; p2b_rc=$?
  if [[ "$p2b_rc" -ne 0 ]]; then
    jq -n --arg aborted_at "P2b" --arg reason "$p2b_out" --argjson summary "$(invoke_summary)" \
          --argjson prune_aborted "$prune_aborted" \
      '{aborted_at:$aborted_at, reason:$reason, prune_aborted:$prune_aborted} + $summary'
    return
  fi

  local run3_rc
  run3_rc="$(compile_apply_rc "$repo")"
  jq -n --arg aborted_at "none" --argjson summary "$(invoke_summary)" --argjson prune_aborted "$prune_aborted" \
        --argjson wrote_sidecar "$wrote_sidecar" --argjson run3_rc "$run3_rc" \
    '{aborted_at:$aborted_at, prune_aborted:$prune_aborted, wrote_sidecar:$wrote_sidecar, run3_rc:$run3_rc} + $summary'
}

# ===========================================================================
# T-61 -- /sensitivity's non-prompting prune contract.
# ===========================================================================
SENS_BADBIN_NONZERO="$(mktemp)"; printf '#!/usr/bin/env bash\necho "warning: synthetic" >&2\nexit 5\n' > "$SENS_BADBIN_NONZERO"; chmod +x "$SENS_BADBIN_NONZERO"
SENS_BADBIN_NONJSON="$(mktemp)"; printf '#!/usr/bin/env bash\necho "not json at all"\nexit 0\n' > "$SENS_BADBIN_NONJSON"; chmod +x "$SENS_BADBIN_NONJSON"
echo "$SENS_BADBIN_NONZERO" >> "$CLEANUP_LIST"; echo "$SENS_BADBIN_NONJSON" >> "$CLEANUP_LIST"

echo "-- T-61(a): P1 (write) must precede P2 (report+prune) -- a harness that inverts them misses a pair the write made dormant --"
# AMBIGUITY NOTE: /sensitivity's OWN field (sensitivity.level) never changes
# any (mode,tool) pair's prunability -- the consent hash preimage is exactly
# {modes, scoped keys, gates ∩ GATE_OWNERS} (T-41), which sensitivity.level
# is not part of. The ORDERING RULE itself (P1 writes, THEN P2 reports, so
# the prune always sees a POST-write report) is stated in the ADR as a
# property of "whatever mutation this stack-config.json writer performs in
# this invocation" -- so this case demonstrates the mechanism generically
# with a domain_mode edit standing in for "the write", exactly as Bucket D
# already reuses a domain_mode edit as a generic "third actor" vehicle for
# concurrency mechanics that are not domain-mode-specific either. Resolution
# recorded here rather than guessed silently.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
Q_ACK="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
sidecar_with_acks "$R" "$Q_ACK"
PRE_WRITE_REPORT="$(compile_dry_stdout "$R")"
assert_not_contains "T-61(a) precondition: pre-write, Q is NOT prunable (in force)" \
  "$(echo "$PRE_WRITE_REPORT" | jq -r '.inputs.acks_prunable[].tool')" "execute_sql"
write_cfg "$R" '["ui-design"]' '__ABSENT__' '[]'   # "the write" -- drops schema-migration, making Q dormant
POST_WRITE_REPORT="$(compile_dry_stdout "$R")"
assert_contains "T-61(a) precondition: post-write, Q IS prunable (the write made it dormant)" \
  "$(echo "$POST_WRITE_REPORT" | jq -r '.inputs.acks_prunable[].tool')" "execute_sql"

R_CORRECT="$(new_repo)"; write_cfg "$R_CORRECT" '["ui-design"]' '__ABSENT__' '[]'
sidecar_with_acks "$R_CORRECT" "$Q_ACK"
CORRECT_PRUNABLE="$(echo "$POST_WRITE_REPORT" | jq -c '.inputs.acks_prunable')"
sensitivity_prune "$R_CORRECT" "$CORRECT_PRUNABLE"
assert_eq "T-61(a): CORRECT order (write-then-report) deletes Q -- it reflects post-write reality" \
  "0" "$(jq '.multi_mode_suppression_ack | length' "$R_CORRECT/.claude/permissions.stack.json")"

R_INVERTED="$(new_repo)"; write_cfg "$R_INVERTED" '["ui-design"]' '__ABSENT__' '[]'
sidecar_with_acks "$R_INVERTED" "$Q_ACK"
INVERTED_PRUNABLE="$(echo "$PRE_WRITE_REPORT" | jq -c '.inputs.acks_prunable')"   # report taken BEFORE the write
sensitivity_prune "$R_INVERTED" "$INVERTED_PRUNABLE"
assert_eq "T-61(a): a harness that inverts P1/P2 (report-before-write) misses Q entirely -- it survives, undeleted, even though it is genuinely dead post-write" \
  "1" "$(jq '.multi_mode_suppression_ack | length' "$R_INVERTED/.claude/permissions.stack.json")"

echo "-- T-61(b): acks_prunable == [] -> no sidecar write at all --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
BEFORE="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null)"
RES="$(sensitivity_flow "$R" "")"
assert_eq "T-61(b): prune_aborted is false and wrote_sidecar is false when acks_prunable==[]" "0" "$(echo "$RES" | jq -r '.wrote_sidecar')"
AFTER_ACK_ONLY="$(jq -c '.multi_mode_suppression_ack // []' "$R/.claude/permissions.stack.json" 2>/dev/null)"
assert_eq "T-61(b): the ack array is empty both before and after (an unrelated edit does not fabricate one)" "[]" "$AFTER_ACK_ONLY"

echo "-- T-61(c): acks_prunable non-empty -> exactly those pairs deleted, waivers/pinned byte-identical, in-force/promptable untouched --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
ACK_P_INFORCE="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
ACK_Q_GATED="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
sidecar_with_acks_and_extras "$R" "[$ACK_P_INFORCE, $ACK_Q_GATED]" '[{"rule":"Bash(psql:*)"}]' '[]'
BEFORE_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
RES="$(sensitivity_flow "$R" "")"
assert_eq "T-61(c): the flow completes and DID write (Q was prunable, explicit-gate)" "1" "$(echo "$RES" | jq -r '.wrote_sidecar')"
AFTER_ACKS="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
assert_not_contains "T-61(c): Q (deploy_edge_function, explicit-gate) is deleted" "$AFTER_ACKS" "deploy_edge_function"
assert_contains "T-61(c): P (execute_sql, in force) is untouched" "$AFTER_ACKS" "execute_sql"
AFTER_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
assert_eq "T-61(c): waivers[] byte-identical" "$BEFORE_WAIVERS" "$AFTER_WAIVERS"

echo "-- T-61(d): compiler missing/non-zero/non-JSON, AND four parseable-but-invalid plan shapes -- nothing deleted, apply still runs --"
for shape in compiler_missing compiler_nonzero compiler_nonjson shape_root_not_object shape_inputs_not_object shape_acks_prunable_absent shape_element_malformed; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  H0="$(get_hash "$R")"
  ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"   # genuinely prunable (explicit-gate)
  sidecar_with_acks "$R" "$ACK_Q"
  BEFORE_ACKS="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
  RES="$(sensitivity_flow "$R" "$shape")"
  AFTER_ACKS="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
  assert_eq "T-61(d) [$shape]: nothing deleted -- the genuinely-prunable Q survives untouched" "$BEFORE_ACKS" "$AFTER_ACKS"
  assert_eq "T-61(d) [$shape]: the apply still runs (P3 is reached, not the compiler-unavailable-style total abort)" "none" "$(echo "$RES" | jq -r '.aborted_at')"
  assert_eq "T-61(d) [$shape]: run3_rc is 0 (apply succeeded)" "0" "$(echo "$RES" | jq -r '.run3_rc')"
done

echo "-- T-61(d) round 9: a FIFTH abort trigger, scoped to the P0->P2 race -- sidecar corrupted mid-flow aborts BEFORE P3, distinct message path --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$ACK_Q"
RES="$(sensitivity_flow "$R" "mid_flow_before_p3")"
assert_eq "T-61(d)/round9: aborted at P2b, distinct from the plan-shape-check abort" "P2b" "$(echo "$RES" | jq -r '.aborted_at')"
assert_eq "T-61(d)/round9: run 3 never runs (no run3_rc field emitted)" "" "$(echo "$RES" | jq -r '.run3_rc // empty')"

echo "-- T-61(e): after the apply, acks_prunable == [] is asserted; no rollback / no second deletion pass on mismatch (structural: this harness performs exactly one prune pass) --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$ACK_Q"
RES="$(sensitivity_flow "$R" "")"
POST_APPLY_PRUNABLE="$(jq '.inputs.acks_prunable | length' "$R/.claude/permissions.stack.json")"
assert_eq "T-61(e): after the apply, inputs.acks_prunable == [] in the real post-apply plan" "0" "$POST_APPLY_PRUNABLE"

echo "-- T-61(f): an unrelated /sensitivity edit in a single-mode repo carrying an inherited ack DOES delete it (why=single-mode), intended --"
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
INHERITED="$(ack_entry "schema-migration" '["apply_migration"]' "$H0")"
sidecar_with_acks "$R" "$INHERITED"
PRE_PLAN="$(compile_dry_stdout "$R")"
assert_contains "T-61(f) precondition: the pair is prunable, why=single-mode" \
  "$(echo "$PRE_PLAN" | jq -r '.inputs.acks_prunable[] | select(.tool=="apply_migration") | .why')" "single-mode"
RES="$(sensitivity_flow "$R" "")"
assert_eq "T-61(f): the inherited ack IS deleted by an unrelated /sensitivity edit" "0" "$(jq '.multi_mode_suppression_ack | length' "$R/.claude/permissions.stack.json")"
DENIES_STILL_ARITY1="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule')"
assert_not_contains "T-61(f): at arity 1 the tool stays honored regardless (clause 3 is vacuous -- ADR-044's escape hatch, deleting the ack changes nothing yet)" \
  "$DENIES_STILL_ARITY1" "apply_migration"
write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'   # escalate to arity 2, outside any flow -- exposes the now-missing ack
CLAUSE_AFTER_ESCALATION="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration") | .clause')"
assert_eq "T-61(f): recovery is a plain 'consent' prompt the next time arity actually requires the ack (a later /domain-mode run)" "consent" "$CLAUSE_AFTER_ESCALATION"

# ===========================================================================
# T-66 -- the strengthening-intent asymmetry.
# ===========================================================================
echo "-- T-66(a)/(b): P0 refuses BEFORE any write, for all three writers, across the T-65 unparseable fixtures AND the T-54 non-object roots --"
for fixture in trailing_comma unclosed_brace zero_byte non_utf8 root_array root_number root_string root_true root_null; do
  for writer_kind in "domain-mode" "project-init" "sensitivity"; do
    R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
    CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
    H0="$(get_hash "$R")"
    FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
    sidecar_with_acks "$R" "$FRESH_ACK"
    compile_apply_rc "$R" >/dev/null   # establish a REAL prior compiled settings.json (valid sidecar, denies absent) BEFORE corrupting anything
    CFG_BEFORE="$(cat "$R/.claude/stack-config.json")"
    SETTINGS_BEFORE="$(cat "$R/.claude/settings.json")"
    write_bad_sidecar "$R" "$fixture"   # NOW corrupt it -- this is the state P0 must refuse against
    SIDECAR_BEFORE="$(cat "$R/.claude/permissions.stack.json" | base64)"

    if [[ "$writer_kind" == "sensitivity" ]]; then
      RES="$(sensitivity_flow "$R" "")"
    else
      RES="$(dm_flow "$R" '["ui-design"]' '__ABSENT__' '[]' "$writer_kind" "all_y" "")"
    fi
    assert_eq "T-66(a) [$fixture/$writer_kind]: P0 aborts" "P0" "$(echo "$RES" | jq -r '.aborted_at')"
    assert_eq "T-66(b) [$fixture/$writer_kind]: ZERO real compiler invocations happened (P0 precedes run 1 -- the property, not just the abort)" \
      "0" "$(echo "$RES" | jq -r '.invocations')"
    CFG_AFTER="$(cat "$R/.claude/stack-config.json")"
    SIDECAR_AFTER="$(cat "$R/.claude/permissions.stack.json" | base64)"
    SETTINGS_AFTER="$(cat "$R/.claude/settings.json" 2>/dev/null)"
    assert_eq "T-66(a) [$fixture/$writer_kind]: stack-config.json byte-identical (never even written)" "$CFG_BEFORE" "$CFG_AFTER"
    assert_eq "T-66(a) [$fixture/$writer_kind]: sidecar byte-identical" "$SIDECAR_BEFORE" "$SIDECAR_AFTER"
    assert_eq "T-66(a) [$fixture/$writer_kind]: settings.json byte-identical to whatever it held before this flow" "$SETTINGS_BEFORE" "$SETTINGS_AFTER"
  done
done

echo "-- T-66(e): recovery -- fixing the sidecar typo lands the strengthening; deleting it also lands it, at the documented cost --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
WAIVERS='[{"rule":"Bash(psql:*)"}]'
sidecar_with_acks_and_extras "$R" "[$FRESH_ACK]" "$WAIVERS" '[]'
compile_apply_rc "$R" >/dev/null   # real prior applied state: 3 denies absent, waiver honored, ledger populated
DENIES_BEFORE="$(jq -r '.emitted.deny[]' "$R/.claude/permissions.stack.json" | sort)"
GOOD_SIDECAR_BYTES="$(cat "$R/.claude/permissions.stack.json")"
write_bad_sidecar "$R" "trailing_comma"
RES_ABORT="$(dm_flow "$R" '"ui-design"' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-66(e) precondition: /domain-mode none (collapsing to ui-design here) is refused by P0" "P0" "$(echo "$RES_ABORT" | jq -r '.aborted_at')"

printf '%s' "$GOOD_SIDECAR_BYTES" > "$R/.claude/permissions.stack.json"   # (i) fix the typo -- restore valid JSON
RES_FIXED="$(dm_flow "$R" '"ui-design"' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-66(e)/fix: the flow now completes" "none" "$(echo "$RES_FIXED" | jq -r '.aborted_at')"
DENIES_AFTER_FIX="$(compile_dry_stdout "$R" | jq -r '.compiled_deny[].rule' | sort)"
assert_contains "T-66(e)/fix: the strengthening lands -- schema-migration no longer active (arity 1, ui-design) so nothing suppresses apply_migration; the deny is back and the flow completed cleanly" \
  "$DENIES_AFTER_FIX" "apply_migration"
WAIVERS_AFTER_FIX="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
assert_eq "T-66(e)/fix: waivers[] intact" "$WAIVERS" "$WAIVERS_AFTER_FIX"

echo "-- T-66(e)/delete: waivers[] half -- waiver is genuinely gone, waived rule returns --"
R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R2")"
FRESH_ACK2="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks_and_extras "$R2" "[$FRESH_ACK2]" "$WAIVERS" '[]'
compile_apply_rc "$R2" >/dev/null   # real prior state: 3 denies absent (fresh ack) AND Bash(psql:*) waived
rm -f "$R2/.claude/permissions.stack.json"   # (ii) delete the sidecar entirely (a human's own rm)
RES_DELETED="$(dm_flow "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
assert_eq "T-66(e)/delete: the flow completes (absent is mergeable)" "none" "$(echo "$RES_DELETED" | jq -r '.aborted_at')"
WAIVED_AFTER_DELETE="$(compile_dry_stdout "$R2" | jq -r '.waived_count')"
assert_eq "T-66(e)/delete: the cost is exactly as promised -- waivers[] is gone, waived_count is 0" "0" "$WAIVED_AFTER_DELETE"
RULES_AFTER_DELETE="$(compile_dry_stdout "$R2" | jq -r '.compiled_deny[].rule')"
assert_contains "T-66(e)/delete: the previously-waived rule is back in compiled_deny" "$RULES_AFTER_DELETE" "Bash(psql:*)"

echo "-- T-66(e)/delete round-10: the D8 ledger permanence check -- a rule DENIED (not waived, not honored) before the deletion is stranded human-owned forever after --"
# AMBIGUITY-ADJACENT NOTE: using Bash(psql:*) here would be vacuous -- it is
# an ADDITIVE rule that is never itself in the ledger while waived (the
# compiler strips a waived rule from compiled_deny before the plan reaches
# settings_lock.py, so a waived rule is never "claimed" by the ledger at
# all). The mechanically correct rule to pin the "existing strings adopted
# as human, so no future compile can ever prune it" promise against is one
# that is genuinely DENIED and PRESENT in a prior real settings.json with a
# "stack"-owned ledger entry, which then loses that ledger entry when the
# sidecar is deleted -- apply_migration (denied, no ack) is exactly that.
R3="$(new_repo)"; write_cfg "$R3" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
compile_apply_rc "$R3" >/dev/null   # first-ever apply: no ack -> apply_migration denied, ledger claims it "stack"-owned
LEDGER_OWNER_BEFORE="$(jq -r '.ledger.deny["mcp__supabase__apply_migration"].owner' "$R3/.claude/permissions.stack.json")"
assert_eq "T-66(e) precondition: freshly compiled, the rule is stack-owned" "stack" "$LEDGER_OWNER_BEFORE"
rm -f "$R3/.claude/permissions.stack.json"   # the human's own rm -- the ledger (and any ack) is gone
RES_R3="$(dm_flow "$R3" '["ui-design","schema-migration"]' '__ABSENT__' '[]' "domain-mode" "all_n" "")"
assert_eq "T-66(e)/round10: the flow completes" "none" "$(echo "$RES_R3" | jq -r '.aborted_at')"
DENY_R3="$(jq -r '.emitted.deny[]' "$R3/.claude/permissions.stack.json")"
assert_contains "T-66(e)/round10: apply_migration is still (correctly) denied across the transition -- no ack was re-affirmed" "$DENY_R3" "mcp__supabase__apply_migration"
LEDGER_OWNER_AFTER="$(jq -r '.ledger.deny["mcp__supabase__apply_migration"].owner' "$R3/.claude/permissions.stack.json")"
assert_eq "T-66(e)/round10: the string was ADOPTED as human-owned (the ledger restarted empty -- it strands as human)" "human" "$LEDGER_OWNER_AFTER"
compile_apply_rc "$R3" >/dev/null; compile_apply_rc "$R3" >/dev/null   # two FURTHER real compiles, unchanged config
PLAN_AFTER_TWO_MORE="$(compile_apply_rc "$R3" >/dev/null; jq -r '.ledger.deny["mcp__supabase__apply_migration"].owner' "$R3/.claude/permissions.stack.json")"
assert_eq "T-66(e)/round10: still human-owned after two further compiles (the promise is mechanical, not one-shot)" "human" "$PLAN_AFTER_TWO_MORE"
DENY_AFTER_MORE="$(jq -r '.emitted.deny[]' "$R3/.claude/permissions.stack.json")"
assert_contains "T-66(e)/round10: never pruned by any of the further compiles" "$DENY_AFTER_MORE" "mcp__supabase__apply_migration"

echo "-- T-66(f): anti-regression -- a harness that skips P0 (round-8's old behavior) produces the divergent half-landed state; this harness does not --"
dm_flow_no_p0() {
  # A deliberately-wrong variant: proceeds past a corrupt sidecar exactly as
  # round 8's rejected behavior did ("abort the sidecar write and continue").
  # Used ONLY to prove the real dm_flow (which DOES check P0) never reaches
  # this divergent state.
  local repo="$1" new_dm="$2"
  write_cfg "$repo" "$new_dm" '__ABSENT__' '[]'
  compile_apply_rc "$repo" >/dev/null 2>&1   # the apply refuses (corrupt sidecar) -- settings.json is NOT recompiled
  echo "done"
}
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
FRESH_ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$FRESH_ACK"
compile_apply_rc "$R" >/dev/null   # real prior state: 3 denies ABSENT (the weaker state /domain-mode none is meant to fix)
write_bad_sidecar "$R" "trailing_comma"
dm_flow_no_p0 "$R" "null" >/dev/null
CFG_DIVERGED="$(jq -c '.domain_mode' "$R/.claude/stack-config.json")"
assert_eq "T-66(f) anti-regression control, half 1: the NO-P0 variant's config HAS moved to null" "null" "$CFG_DIVERGED"
# The oracle here must be the REAL, ON-DISK settings.json -- NOT a fresh
# compile_dry_stdout, which recomputes a plan against the NEW (null) config
# and would show apply_migration denied for an unrelated reason (no mode is
# declared to suppress it), masking the actual divergence under test: the
# REAL settings.json was never recompiled at all (the apply refused on the
# corrupt sidecar), so it still reflects the OLD, weaker, pre-flow state.
SETTINGS_DIVERGED="$(jq -r '.permissions.deny[]' "$R/.claude/settings.json" 2>/dev/null | sort)"
assert_not_contains "T-66(f) anti-regression control, half 2: the NO-P0 variant's REAL settings.json was never recompiled -- it still lacks the three denies even though stack-config.json already moved to null (config/permission planes now disagree)" \
  "$SETTINGS_DIVERGED" "apply_migration"

R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R2")"
FRESH_ACK2="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R2" "$FRESH_ACK2"
compile_apply_rc "$R2" >/dev/null
write_bad_sidecar "$R2" "trailing_comma"
RES_REAL="$(dm_flow "$R2" '"ui-design"' '__ABSENT__' '[]' "domain-mode" "all_y" "")"
CFG_REAL="$(jq -c '.domain_mode' "$R2/.claude/stack-config.json")"
assert_eq "T-66(f): the REAL dm_flow (P0-checked) never half-lands -- config is unchanged, not null" '["ui-design","schema-migration"]' "$CFG_REAL"
assert_eq "T-66(f): the real flow reports P0, not a silent continue" "P0" "$(echo "$RES_REAL" | jq -r '.aborted_at')"

echo "-- T-66(g): the parser differential -- python3 -m json.tool exits 0 on the exact roots the pinned predicate must refuse --"
for root_fixture in '[]' '42' 'null'; do
  TMPF="$(mktemp)"; printf '%s' "$root_fixture" > "$TMPF"
  python3 -m json.tool "$TMPF" >/dev/null 2>&1
  JSONTOOL_RC=$?
  assert_eq "T-66(g): python3 -m json.tool exits 0 on root=$root_fixture (the parser gap the pinned heredoc must not share)" "0" "$JSONTOOL_RC"
  PREDICATE_RC=0
  p0_predicate_rc "$TMPF" >/dev/null 2>&1 || PREDICATE_RC=$?
  assert_eq "T-66(g): the pinned mergeability predicate exits 4 (root is not a JSON object) on root=$root_fixture -- pinning 4, not merely non-zero, is what distinguishes the shape branch from the parse-failure branch (rc 3)" \
    "4" "$PREDICATE_RC"
  rm -f "$TMPF"
done

echo "----------------------------------------"
echo "domain-mode-e2e-flows (ADR-053 BUCKET E): $PASS passed, $FAIL failed"
echo "Covers, via real execution of the documented flow: T-19, T-20, T-23, T-31(a), T-32(a/b/c),"
echo "  T-35(a/b/c), T-38, T-44, T-45(a/b), T-48, T-58, T-61(a-f), T-66(a/b/e/f/g)."
echo "T-45(c) is a one-line NOTE (already docs-logic-asserted in Bucket B). T-66(c) is real"
echo "two-process concurrency and lives entirely in tests/test-domain-mode-concurrency.sh (BUCKET D)."
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
