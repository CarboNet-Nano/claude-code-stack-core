#!/usr/bin/env bash
# Tests for ADR-053 (multi-domain-mode, path-scoped forced review chains) --
# BUCKET D: REAL two-(or more)-process concurrency, deliberately deferred out
# of the T-1..T-66 test plan's first two passes.
#
# tests/test-domain-mode-multi.sh (BUCKET A, 354 assertions) and
# tests/test-domain-mode-skills-docs.sh (BUCKET B, 56 assertions) are both
# single-process: they call scripts/permissions-compile.sh sequentially, or
# grep the SKILL.md prose for the documented contract. Neither exercises
# actual OS-level interleaving. This file does: every scenario below forks a
# REAL second (sometimes third) bash/python process against a SHARED
# throwaway fixture repo (never the real claude-code-stack repo's own
# .claude/*), and uses file-based signal handshakes (touch + a polling
# wait_for, never a bare sleep-and-hope) to force one specific, named
# interleaving at a time.
#
# Case IDs reference docs/ADRs/053-implementer-handoff.md's test plan:
#   T-49  drift gate catches ENVIRONMENT drift (live-capabilities snapshot,
#         baseline) landing between the y/N and run 2.
#   T-50  drift gate catches a CONCURRENT ACTOR editing stack-config.json or
#         the sidecar between the y/N and run 2.
#   T-64  writer-vs-writer UNLOCKED read-modify-write race on
#         .claude/permissions.stack.json between /domain-mode's reconcile and
#         /sensitivity's prune -- ADR's "named residual (c)", pinned OPEN,
#         not something this harness is expected to close.
#   T-66(c) the narrow "preflight -> apply" interval -- corrupting the
#         sidecar at four distinct positions in the flow catches three of
#         them and leaves the fourth (after the reconcile's write, before
#         run 3) uncovered BY DESIGN. That fourth interval is the ADR's own
#         accepted-open residual; this harness's job is to confirm it
#         behaves exactly as documented (fails safe, never silently), not to
#         eliminate it.
#
# /domain-mode's reconcile and /sensitivity's prune are SKILL.md prose
# (executed by an LLM agent), not code -- there is no script to shell out to
# for "the real reconcile." What IS real and testable is the underlying file
# mechanic both skills are documented to use: an UNLOCKED read of
# .claude/permissions.stack.json, held in memory for some elapsed time (the
# y/N prompt, a model turn, etc.), then a whole-object write. sim_*_below
# implement exactly that mechanic -- nothing more -- as real subprocesses;
# they never re-derive classify_suppressions()'s logic (acks_prunable /
# acks_in_force always come from a REAL `permissions-compile.sh --dry-run
# --json` call). R2b's mergeability predicate (r2b_predicate_rc) is a
# byte-for-byte copy of the heredoc pinned in skills/domain-mode/SKILL.md and
# skills/sensitivity/SKILL.md -- not a re-implementation.
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
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 (missing '$3' in: $2)"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1 (unexpectedly found '$3' in: $2)"; }
assert_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1 (missing exact line '$3' in: $2)"; fi
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
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/session-state" "$h/.claude/config"
  echo "$h" >> "$CLEANUP_LIST"
  printf '%s' "$h"
}

new_repo() {
  local d; d="$(mktemp -d)"
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

write_fixture_baseline() {
  # write_fixture_baseline <home> <json> -- checked BEFORE CLAUDE_PLUGIN_ROOT's
  # installed baseline (permissions-compile.sh:112), isolating baseline-edit
  # tests from the real config/permissions-baseline.json.
  mkdir -p "$1/.claude/config"
  printf '%s' "$2" > "$1/.claude/config/permissions-baseline.json"
}

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
  local mode="$1" tools="$2" hash="$3" date="${4:-2026-08-01}" by="${5:-tester}"
  jq -n --arg m "$mode" --argjson t "$tools" --arg h "$hash" --arg d "$date" --arg b "$by" \
    '{mode:$m, tools:$t, scope_hash:$h, date:$d, by:$b, reason:"test"}'
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

compile_dry_stdout() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" --dry-run --json 2>/dev/null
}
compile_apply_rc() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" >/dev/null 2>/dev/null
  echo $?
}
compile_apply_stderr() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" 2>&1 >/dev/null
}
get_hash() { compile_dry_stdout "$1" | jq -r '.inputs.consent_scope_hash'; }

# ===========================================================================
# Concurrency primitives
# ===========================================================================

wait_for() {
  # wait_for <signal-file> [max-polls (x0.05s each)] -- deterministic barrier,
  # never a bare sleep. Times out loudly rather than hanging forever.
  local path="$1" max="${2:-200}" i=0
  while [[ ! -f "$path" ]]; do
    i=$((i+1))
    if [[ "$i" -gt "$max" ]]; then
      echo "TIMEOUT waiting for $path" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}

corruptor_wait_and_corrupt() {
  # corruptor_wait_and_corrupt <sidecar> <go-signal> <done-signal> <payload>
  # A genuine second OS process: blocks on <go-signal>, then overwrites the
  # sidecar with <payload> (deliberately not-JSON), then signals done.
  local sidecar="$1" go="$2" done_sig="$3" payload="$4"
  wait_for "$go" 200 || { touch "$done_sig"; return 1; }
  printf '%s' "$payload" > "$sidecar"
  touch "$done_sig"
}

sim_domain_mode_reconcile() {
  # sim_domain_mode_reconcile <repo> <keep-ack-array-json> <go-signal|"">
  # Models skills/domain-mode/SKILL.md step 6 (R2b, the read) + step 7 (the
  # one durable write): R2b re-reads the CURRENT sidecar immediately before
  # writing (no staleness on THIS side -- the ADR proves "reconcile writes
  # last" safe precisely because the write REPLACES
  # multi_mode_suppression_ack wholesale instead of diffing a stale read),
  # replaces that one key, and preserves every other key untouched. The
  # keep-set itself (A union B) is never re-derived here -- callers compute
  # it from a real compiler dry-run and pass the finished ack array in.
  local repo="$1" keep_json="$2" go="$3"
  local sidecar="$repo/.claude/permissions.stack.json"
  if [[ -n "$go" ]]; then
    wait_for "$go" 200 || return 1
  fi
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

sim_sensitivity_prune() {
  # sim_sensitivity_prune <repo> <prunable-pairs-json> <ready-signal> <go-signal>
  # Models skills/sensitivity/SKILL.md P2's deletion: reads the sidecar ONCE
  # and holds it (this is the read this harness deliberately makes stale, to
  # reproduce the DYNAMIC hazard the ADR names -- "it read and classified
  # before /domain-mode's stack-config.json edit landed"), signals <ready>,
  # blocks on <go>, then deletes exactly the named (mode,tool) pairs from
  # that HELD snapshot and writes the rest back as read -- never re-reading
  # the file at write time. <prunable-pairs-json> always comes from a real
  # `permissions-compile.sh --dry-run --json`'s inputs.acks_prunable.
  local repo="$1" prunable_json="$2" ready="$3" go="$4"
  local sidecar="$repo/.claude/permissions.stack.json"
  local old; old="$(cat "$sidecar" 2>/dev/null || echo '{}')"
  touch "$ready"
  wait_for "$go" 200 || return 1
  # old is passed as argv[3], NOT piped -- `python3 -` already consumes stdin
  # as ITS OWN script source via the heredoc below, so piping data into the
  # same stdin would be silently swallowed (read as EOF by sys.stdin.read()).
  python3 - "$sidecar" "$prunable_json" "$old" <<'PY'
import json, sys
path, prunable_arg, old_raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads(old_raw)
    if not isinstance(data, dict):
        data = {}
except ValueError:
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
        a = dict(a)
        a["tools"] = tools
        new_acks.append(a)
data["multi_mode_suppression_ack"] = new_acks
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

r2b_predicate_rc() {
  # Byte-for-byte the heredoc pinned in skills/domain-mode/SKILL.md's P0/R2b
  # and skills/sensitivity/SKILL.md's P0/P2b. rc 0 = mergeable; 3 = unreadable
  # / not valid JSON; 4 = valid JSON but non-object root. Absence passes
  # trivially -- per the SKILL.md prose, the file-existence check happens
  # BEFORE the heredoc runs, never inside it.
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

inputs_differ() {
  # inputs_differ <run1-json-file> <run2-json-file> -- the drift gate is
  # "deep equality of the whole inputs object plus baseline_version" (ADR
  # constraint, not an enumerated field list); the named fields below are
  # only the documented ABORT-MESSAGE vocabulary/order. The final whole-.inputs
  # comparison is the real gate and catches anything the named fields miss
  # (T-49 round 6's harness-injected-extra-key negative case).
  local j1="$1" j2="$2" a b
  a="$(jq -S '.baseline_version' "$j1")"; b="$(jq -S '.baseline_version' "$j2")"
  [[ "$a" != "$b" ]] && { echo "baseline_version"; return; }
  a="$(jq -r '.inputs.consent_scope_hash' "$j1")"; b="$(jq -r '.inputs.consent_scope_hash' "$j2")"
  [[ "$a" != "$b" ]] && { echo "consent_scope_hash"; return; }
  a="$(jq -S '.inputs.mcp_servers' "$j1")"; b="$(jq -S '.inputs.mcp_servers' "$j2")"
  [[ "$a" != "$b" ]] && { echo "mcp_servers"; return; }
  a="$(jq -r '.inputs.baseline_hash' "$j1")"; b="$(jq -r '.inputs.baseline_hash' "$j2")"
  [[ "$a" != "$b" ]] && { echo "baseline_hash"; return; }
  a="$(jq -S '.inputs.acks_in_force' "$j1")"; b="$(jq -S '.inputs.acks_in_force' "$j2")"
  [[ "$a" != "$b" ]] && { echo "acks_in_force"; return; }
  a="$(jq -S '.inputs.acks_prunable' "$j1")"; b="$(jq -S '.inputs.acks_prunable' "$j2")"
  [[ "$a" != "$b" ]] && { echo "acks_prunable"; return; }
  a="$(jq -S '.inputs.suppressions_withheld' "$j1")"; b="$(jq -S '.inputs.suppressions_withheld' "$j2")"
  [[ "$a" != "$b" ]] && { echo "suppressions_withheld"; return; }
  a="$(jq -S '.inputs.suppressions_honored' "$j1")"; b="$(jq -S '.inputs.suppressions_honored' "$j2")"
  [[ "$a" != "$b" ]] && { echo "suppressions_honored"; return; }
  a="$(jq -S '.inputs' "$j1")"; b="$(jq -S '.inputs' "$j2")"
  [[ "$a" != "$b" ]] && { echo "other"; return; }
  echo ""
}

echo "== ADR-053 BUCKET D: real two-process concurrency (T-49, T-50, T-64, T-66c) =="

# ===========================================================================
# T-49 -- drift gate catches ENVIRONMENT drift between the y/N and run 2.
# A real background process performs the environment mutation while the
# "flow" process is blocked between run 1 and run 2.
# ===========================================================================
t49_race() {
  # t49_race <repo> <mutate-fn-name> -- run1, fork a real process that waits
  # on a signal then calls <mutate-fn-name> (a function defined by the
  # caller, inheriting the caller's variables at fork time), release it,
  # run2, report the first differing field.
  local repo="$1" mutate_fn="$2"
  local run1; run1="$(compile_dry_stdout "$repo")"
  local run1_file; run1_file="$(mktemp)"; printf '%s' "$run1" > "$run1_file"
  local go done_sig; go="$(mktemp -u)"; done_sig="$(mktemp -u)"
  ( wait_for "$go" 200 && "$mutate_fn"; touch "$done_sig" ) &
  local pid=$!
  touch "$go"
  wait_for "$done_sig" 200
  wait "$pid"
  rm -f "$go" "$done_sig"
  local run2; run2="$(compile_dry_stdout "$repo")"
  local run2_file; run2_file="$(mktemp)"; printf '%s' "$run2" > "$run2_file"
  inputs_differ "$run1_file" "$run2_file"
  rm -f "$run1_file" "$run2_file"
}

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; no_snapshot "$CUR_HOME"
t49_mutate_add_snapshot() { write_snapshot "$CUR_HOME" supabase; }
FIELD="$(t49_race "$R" t49_mutate_add_snapshot)"
assert_eq "T-49(a): live-capabilities snapshot arriving between run1/run2 (real concurrent writer) is caught -- field=mcp_servers" "mcp_servers" "$FIELD"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
t49_mutate_new_server() { write_snapshot "$CUR_HOME" supabase supabase_staging; }
FIELD="$(t49_race "$R" t49_mutate_new_server)"
assert_eq "T-49(b): a NEW MCP server joining between run1/run2 (real concurrent writer) is caught -- field=mcp_servers" "mcp_servers" "$FIELD"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
REAL_BASELINE="$(cat "$REPO_ROOT/config/permissions-baseline.json")"
write_fixture_baseline "$CUR_HOME" "$REAL_BASELINE"
t49_mutate_bump_version() {
  jq '.version = "9.9.9-test"' "$CUR_HOME/.claude/config/permissions-baseline.json" > "$CUR_HOME/.claude/config/permissions-baseline.json.tmp"
  mv "$CUR_HOME/.claude/config/permissions-baseline.json.tmp" "$CUR_HOME/.claude/config/permissions-baseline.json"
}
FIELD="$(t49_race "$R" t49_mutate_bump_version)"
assert_eq "T-49(c): a real concurrent stack upgrade (baseline_version bump) between run1/run2 is caught -- field=baseline_version" "baseline_version" "$FIELD"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
write_fixture_baseline "$CUR_HOME" "$REAL_BASELINE"
t49_mutate_content_only() {
  jq '.domain_overlays["ui-design"].bash_guardrails = ((.domain_overlays["ui-design"].bash_guardrails // []) + ["zzz-test-verb"])' \
    "$CUR_HOME/.claude/config/permissions-baseline.json" > "$CUR_HOME/.claude/config/permissions-baseline.json.tmp"
  mv "$CUR_HOME/.claude/config/permissions-baseline.json.tmp" "$CUR_HOME/.claude/config/permissions-baseline.json"
}
FIELD="$(t49_race "$R" t49_mutate_content_only)"
assert_eq "T-49(d): baseline content edited WITHOUT a version bump between run1/run2 is still caught -- field=baseline_hash" "baseline_hash" "$FIELD"

# T-49 round 6: the gate is whole-.inputs deep equality, not an
# allow-listed field list -- an unrecognized extra key must also abort.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
RUN1="$(compile_dry_stdout "$R")"; RUN1_FILE="$(mktemp)"; printf '%s' "$RUN1" > "$RUN1_FILE"
RUN2_INJECTED="$(compile_dry_stdout "$R" | jq '.inputs.__harness_injected_key = "x"')"
RUN2_FILE="$(mktemp)"; printf '%s' "$RUN2_INJECTED" > "$RUN2_FILE"
FIELD="$(inputs_differ "$RUN1_FILE" "$RUN2_FILE")"
assert_eq "T-49(round 6): a harness-injected unrecognized key in run2.inputs is still caught (whole-object equality, not a field allowlist)" "other" "$FIELD"
rm -f "$RUN1_FILE" "$RUN2_FILE"

# ===========================================================================
# T-50 -- drift gate catches a CONCURRENT ACTOR editing stack-config.json or
# the sidecar between the y/N and run 2. Same mechanism as T-49, different
# mutator: another real, file-editing process instead of an environment change.
# ===========================================================================
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
t50_mutate_domain_mode() { write_cfg "$R" '["ui-design"]' '__ABSENT__' '[]'; }
FIELD="$(t49_race "$R" t50_mutate_domain_mode)"
assert_eq "T-50(a): a second actor (real process) editing domain_mode between y/N and run2 is caught -- field=consent_scope_hash" "consent_scope_hash" "$FIELD"
CFG_AFTER="$(cat "$R/.claude/stack-config.json")"
assert_contains "T-50(a): the concurrent actor's config edit is NOT reverted by the aborted flow (abort only stops the ack ritual)" "$CFG_AFTER" '"domain_mode":["ui-design"]'

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
rm -f "$R/.claude/permissions.stack.json"
H50="$(get_hash "$R")"
t50_mutate_add_ack() {
  local a; a="$(ack_entry "schema-migration" '["execute_sql"]' "$H50")"
  sidecar_with_acks "$R" "$a"
}
FIELD="$(t49_race "$R" t50_mutate_add_ack)"
assert_eq "T-50(b): a second actor (real process) adding an ack to the sidecar between y/N and run2 is caught -- field=acks_in_force" "acks_in_force" "$FIELD"
SIDECAR_AFTER="$(cat "$R/.claude/permissions.stack.json")"
assert_contains "T-50(b): the concurrently-created ack is NOT deleted by the aborted flow" "$SIDECAR_AFTER" "execute_sql"
echo "NOTE: T-50(c) (/project-init variant) -- identical mechanism (an aborted flow performs no write at all): not separately re-raced here."

# ===========================================================================
# T-64 -- writer-vs-writer UNLOCKED sidecar race (named residual (c), pinned
# OPEN by the ADR, not something this harness is expected to close).
# Staging precondition (stated with its reason, per the ADR's own round-8
# correction): /sensitivity's prune performs NO write at all when
# acks_prunable == [], so every scenario below stages a SECOND, independently
# prunable pair Q (explicit-gate) that /sensitivity's own report DOES name --
# without it, /sensitivity never writes and there is no race to observe.
# ===========================================================================
echo "-- T-64(a): resurrected prune -- both sub-orderings, mode-removal (undeclared-mode) --"
for order in prune_last reconcile_last; do
  R="$(new_repo)"
  write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  H0="$(get_hash "$R")"
  ACK_P="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
  ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
  sidecar_with_acks "$R" "$ACK_P" "$ACK_Q"

  PLAN0="$(compile_dry_stdout "$R")"
  IN_FORCE_0="$(echo "$PLAN0" | jq -c '.inputs.acks_in_force')"
  assert_contains "T-64(a)/[$order]: precondition -- P (schema-migration,execute_sql) starts in force" "$IN_FORCE_0" '"tool":"execute_sql"'
  PRUNABLE_0="$(echo "$PLAN0" | jq -c '.inputs.acks_prunable')"
  assert_contains "T-64(a)/[$order]: precondition -- Q (schema-migration,deploy_edge_function) starts prunable (explicit-gate)" "$PRUNABLE_0" '"why":"explicit-gate"'

  READY_S="$(mktemp -u)"; GO_S="$(mktemp -u)"; GO_D="$(mktemp -u)"
  PRUNE_Q='[{"mode":"schema-migration","tool":"deploy_edge_function"}]'
  ( sim_sensitivity_prune "$R" "$PRUNE_Q" "$READY_S" "$GO_S" ) &
  SENS_PID=$!
  wait_for "$READY_S" 200   # sensitivity has read the 2-entry sidecar (P,Q); blocked on GO_S

  # Concurrently: /domain-mode edits stack-config.json, DROPPING schema-migration.
  write_cfg "$R" '["ui-design"]' '__ABSENT__' '["pre-deploy"]'
  PLAN1="$(compile_dry_stdout "$R")"   # domain_mode's own run1/run2, against the NEW config
  KEEP_ACKS='[]'   # A (nothing answered y) union B (run1's acks_in_force, empty at 1 mode)
  ( sim_domain_mode_reconcile "$R" "$KEEP_ACKS" "$GO_D" ) &
  DM_PID=$!

  if [[ "$order" == "prune_last" ]]; then
    touch "$GO_D"; wait "$DM_PID"
    PLAN_MID="$(compile_dry_stdout "$R")"
    PRUNABLE_MID="$(echo "$PLAN_MID" | jq -c '.inputs.acks_prunable')"
    assert_eq "T-64(a)/[prune_last]: immediate detection is order-dependent -- a compile landing BEFORE the losing write sees acks_prunable==[]" "[]" "$PRUNABLE_MID"
    touch "$GO_S"; wait "$SENS_PID"
  else
    touch "$GO_S"; wait "$SENS_PID"
    touch "$GO_D"; wait "$DM_PID"
  fi
  rm -f "$READY_S" "$GO_S" "$GO_D"

  FINAL_SIDECAR="$(cat "$R/.claude/permissions.stack.json")"
  PLAN2="$(compile_dry_stdout "$R")"

  if [[ "$order" == "prune_last" ]]; then
    N_ACKS="$(echo "$FINAL_SIDECAR" | jq '.multi_mode_suppression_ack | length')"
    assert_eq "T-64(a)/[prune_last]: P is resurrected (exactly one surviving ack entry)" "1" "$N_ACKS"
    SURV_TOOL="$(echo "$FINAL_SIDECAR" | jq -r '.multi_mode_suppression_ack[0].tools[0]')"
    assert_eq "T-64(a)/[prune_last]: the surviving entry is P (execute_sql), not Q" "execute_sql" "$SURV_TOOL"
    WHY_2="$(echo "$PLAN2" | jq -r '.inputs.acks_prunable[] | select(.tool=="execute_sql") | .why')"
    assert_eq "T-64(a)/[prune_last]: resurrected P now reports why=undeclared-mode -- caught, and every future compile keeps warning" "undeclared-mode" "$WHY_2"
  else
    N_ACKS="$(echo "$FINAL_SIDECAR" | jq '.multi_mode_suppression_ack | length')"
    assert_eq "T-64(a)/[reconcile_last]: reconcile writes last -- final array is exactly A union B (empty here); safe" "0" "$N_ACKS"
  fi

  # NOTE (not asserted here): comparing compiled_deny with vs. without the
  # resurrected ack in THIS scenario is vacuous -- schema-migration is
  # inactive under the post-edit config, so no ack for that mode can affect
  # compiled_deny under ANY content, resurrected or not. That comparison
  # would pass whether or not the resurrection happened, proving nothing.
  # The paths-variant loop below stages the case that actually has teeth:
  # schema-migration stays ACTIVE and the resurrected pair is dead for a
  # reason (scope-coherence) that is independent of the ack, so the
  # byte-identical-to-serial claim is asserted there instead.
  :
done

echo "-- T-64(a) variant: concurrent edit is a domain_mode_paths ADDITION (scope-coherence), not a mode removal --"
for order in prune_last reconcile_last; do
  R="$(new_repo)"
  write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  H0="$(get_hash "$R")"
  ACK_P="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
  ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
  sidecar_with_acks "$R" "$ACK_P" "$ACK_Q"

  READY_S="$(mktemp -u)"; GO_S="$(mktemp -u)"; GO_D="$(mktemp -u)"
  PRUNE_Q='[{"mode":"schema-migration","tool":"deploy_edge_function"}]'
  ( sim_sensitivity_prune "$R" "$PRUNE_Q" "$READY_S" "$GO_S" ) &
  SENS_PID=$!
  wait_for "$READY_S" 200

  write_cfg "$R" '["ui-design","schema-migration"]' '{"schema-migration":["nonexistent/**"]}' '["pre-deploy"]'
  KEEP_ACKS='[]'
  ( sim_domain_mode_reconcile "$R" "$KEEP_ACKS" "$GO_D" ) &
  DM_PID=$!

  if [[ "$order" == "prune_last" ]]; then
    touch "$GO_D"; wait "$DM_PID"
    touch "$GO_S"; wait "$SENS_PID"
  else
    touch "$GO_S"; wait "$SENS_PID"
    touch "$GO_D"; wait "$DM_PID"
  fi
  rm -f "$READY_S" "$GO_S" "$GO_D"

  FINAL="$(cat "$R/.claude/permissions.stack.json")"
  PLAN2="$(compile_dry_stdout "$R")"
  if [[ "$order" == "prune_last" ]]; then
    N="$(echo "$FINAL" | jq '.multi_mode_suppression_ack | length')"
    assert_eq "T-64(a)/paths-variant/[prune_last]: P resurrected (one entry survives)" "1" "$N"
    WHY="$(echo "$PLAN2" | jq -r '.inputs.acks_prunable[] | select(.tool=="execute_sql") | .why')"
    assert_eq "T-64(a)/paths-variant/[prune_last]: resurrected P now reports why=scope-coherence" "scope-coherence" "$WHY"
  else
    N="$(echo "$FINAL" | jq '.multi_mode_suppression_ack | length')"
    assert_eq "T-64(a)/paths-variant/[reconcile_last]: safe, final array empty" "0" "$N"
  fi

  # This byte-identity check HAS teeth here, unlike the mode-removal loop
  # above: schema-migration stays ACTIVE, so its ack content genuinely COULD
  # affect compiled_deny -- except clause 2 (scope-coherence) denies
  # unconditionally, independent of clause 3 (the ack), so the resurrected
  # (or absent) pair must produce byte-identical compiled_deny either way.
  DENY_RACY="$(echo "$PLAN2" | jq -S '.compiled_deny')"
  printf '{}' > "$R/.claude/permissions.stack.json"   # no ack at all, same config
  PLAN_REF="$(compile_dry_stdout "$R")"
  DENY_REF="$(echo "$PLAN_REF" | jq -S '.compiled_deny')"
  assert_eq "T-64(a)/paths-variant/[$order]: compiled_deny is byte-identical whether the (resurrected-or-not) ack is present -- scope-coherence denies it unconditionally either way" "$DENY_REF" "$DENY_RACY"
done

echo "-- T-64(b1): lost reconcile, brand-new ack (prune writes last drops a freshly-created ack entirely) -- safe direction --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$ACK_Q"   # only Q exists so far -- no ack for execute_sql yet, at all

READY_S="$(mktemp -u)"; GO_S="$(mktemp -u)"; GO_D="$(mktemp -u)"
PRUNE_Q='[{"mode":"schema-migration","tool":"deploy_edge_function"}]'
( sim_sensitivity_prune "$R" "$PRUNE_Q" "$READY_S" "$GO_S" ) &
SENS_PID=$!
wait_for "$READY_S" 200   # sensitivity has read the 1-entry (Q only) sidecar

# Concurrently: /domain-mode freshly acks execute_sql (X) in this same invocation
ACK_X="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
KEEP_ACKS="[$ACK_X]"
( sim_domain_mode_reconcile "$R" "$KEEP_ACKS" "$GO_D" ) &
DM_PID=$!
touch "$GO_D"; wait "$DM_PID"       # reconcile writes FIRST: sidecar becomes [X]
touch "$GO_S"; wait "$SENS_PID"     # sensitivity's stale write (based on {Q only}) lands LAST -> drops X entirely
rm -f "$READY_S" "$GO_S" "$GO_D"

FINAL_B1="$(cat "$R/.claude/permissions.stack.json")"
N_ACKS_B1="$(echo "$FINAL_B1" | jq '.multi_mode_suppression_ack | length')"
assert_eq "T-64(b1): the freshly-created execute_sql ack is dropped entirely by the late, stale prune write" "0" "$N_ACKS_B1"
PLAN_B1="$(compile_dry_stdout "$R")"
CLAUSE_B1="$(echo "$PLAN_B1" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="execute_sql") | .clause')"
assert_eq "T-64(b1): execute_sql deny is PRESENT again, clause=consent (no ack record survives at all) -- boundary moved STRONGER, never weaker" "consent" "$CLAUSE_B1"
RULES_B1="$(echo "$PLAN_B1" | jq -r '.compiled_deny[].rule')"
assert_contains_line "T-64(b1): mcp__supabase__execute_sql deny is back" "$RULES_B1" "mcp__supabase__execute_sql"

echo "-- T-64(b2): lost reconcile, RE-AUTHORED ack (the ADR's literal scenario) -- a stale ack reverts to its OLD record, not to nothing --"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
H0="$(get_hash "$R")"
ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
# execute_sql ALREADY has an ack entry, but it is STALE (wrong scope_hash,
# old provenance) -- /domain-mode is about to RE-AUTHOR it, not create it.
ACK_X_OLD="$(jq -n --arg m schema-migration --argjson t '["execute_sql"]' \
  '{mode:$m, tools:$t, scope_hash:"sha256:stale00000000000000000000000000000000000000000000000000000000", date:"2026-01-01", by:"old-user", reason:"old text"}')"
sidecar_with_acks "$R" "$ACK_Q" "$ACK_X_OLD"
PLAN0_B2="$(compile_dry_stdout "$R")"
CLAUSE_PRE="$(echo "$PLAN0_B2" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="execute_sql") | .clause')"
assert_eq "T-64(b2): precondition -- the stale execute_sql ack starts PROMPTABLE (consent-stale), not prunable" "consent-stale" "$CLAUSE_PRE"
PRUNABLE_PRE="$(echo "$PLAN0_B2" | jq -c '.inputs.acks_prunable')"
assert_not_contains "T-64(b2): precondition -- the stale execute_sql ack is NOT in acks_prunable (a promptable pair is never pruned)" "$PRUNABLE_PRE" "execute_sql"

READY_S="$(mktemp -u)"; GO_S="$(mktemp -u)"; GO_D="$(mktemp -u)"
PRUNE_Q='[{"mode":"schema-migration","tool":"deploy_edge_function"}]'
( sim_sensitivity_prune "$R" "$PRUNE_Q" "$READY_S" "$GO_S" ) &
SENS_PID=$!
wait_for "$READY_S" 200   # sensitivity holds the 2-entry (Q, X-old-stale) snapshot

# Concurrently: /domain-mode re-affirms execute_sql (X) with the CURRENT hash and fresh provenance
ACK_X_FRESH="$(ack_entry "schema-migration" '["execute_sql"]' "$H0")"
KEEP_ACKS="[$ACK_X_FRESH]"
( sim_domain_mode_reconcile "$R" "$KEEP_ACKS" "$GO_D" ) &
DM_PID=$!
touch "$GO_D"; wait "$DM_PID"       # reconcile writes FIRST: sidecar becomes [X-fresh]
touch "$GO_S"; wait "$SENS_PID"     # sensitivity's stale write (Q deleted, X-OLD untouched) lands LAST -> X REVERTS to its old record
rm -f "$READY_S" "$GO_S" "$GO_D"

FINAL_B2="$(cat "$R/.claude/permissions.stack.json")"
N_ACKS_B2="$(echo "$FINAL_B2" | jq '.multi_mode_suppression_ack | length')"
assert_eq "T-64(b2): exactly one ack entry survives (X, reverted -- not dropped)" "1" "$N_ACKS_B2"
SURV_HASH_B2="$(echo "$FINAL_B2" | jq -r '.multi_mode_suppression_ack[0].scope_hash')"
assert_eq "T-64(b2): the surviving entry carries the OLD scope_hash (the fresh re-authoring was lost, but a record still exists)" "sha256:stale00000000000000000000000000000000000000000000000000000000" "$SURV_HASH_B2"
SURV_REASON_B2="$(echo "$FINAL_B2" | jq -r '.multi_mode_suppression_ack[0].reason')"
assert_eq "T-64(b2): the surviving entry carries the OLD reason text -- this is the ADR's stated cost" "old text" "$SURV_REASON_B2"
PLAN_B2="$(compile_dry_stdout "$R")"
CLAUSE_B2="$(echo "$PLAN_B2" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="execute_sql") | .clause')"
assert_eq "T-64(b2): execute_sql deny is PRESENT again, clause=consent-stale (an ack record still exists, just reverted) -- matches the ADR's literal re-authoring scenario more precisely than T-64(b1)'s brand-new-ack case" "consent-stale" "$CLAUSE_B2"
RULES_B2="$(echo "$PLAN_B2" | jq -r '.compiled_deny[].rule')"
assert_contains_line "T-64(b2): mcp__supabase__execute_sql deny is back" "$RULES_B2" "mcp__supabase__execute_sql"

echo "-- T-64(c): reconcile-writes-last is safe under STATIC staging too (no concurrent config edit at all) --"
for order in prune_last reconcile_last; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-deploy"]'
  CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  H0="$(get_hash "$R")"
  ACK_Q="$(ack_entry "schema-migration" '["deploy_edge_function"]' "$H0")"
  sidecar_with_acks "$R" "$ACK_Q"   # Q is prunable (explicit-gate) BEFORE either flow starts; nothing dynamic

  READY_S="$(mktemp -u)"; GO_S="$(mktemp -u)"; GO_D="$(mktemp -u)"
  PRUNE_Q='[{"mode":"schema-migration","tool":"deploy_edge_function"}]'
  ( sim_sensitivity_prune "$R" "$PRUNE_Q" "$READY_S" "$GO_S" ) &
  SENS_PID=$!
  wait_for "$READY_S" 200
  # /domain-mode makes NO config change; its own reconcile keep-set is
  # whatever a serial run would write for this unchanged config: empty (Q is
  # the only ack and it is prunable in both flows' eyes).
  ( sim_domain_mode_reconcile "$R" '[]' "$GO_D" ) &
  DM_PID=$!
  if [[ "$order" == "prune_last" ]]; then
    touch "$GO_D"; wait "$DM_PID"; touch "$GO_S"; wait "$SENS_PID"
  else
    touch "$GO_S"; wait "$SENS_PID"; touch "$GO_D"; wait "$DM_PID"
  fi
  rm -f "$READY_S" "$GO_S" "$GO_D"
  FINAL_C="$(cat "$R/.claude/permissions.stack.json")"
  N_C="$(echo "$FINAL_C" | jq '.multi_mode_suppression_ack | length')"
  assert_eq "T-64(c)/[$order]: static staging -- neither ordering can fail (Q never survives either write)" "0" "$N_C"
done

echo "NOTE T-64(d): the byte-identical-to-serial claim is directly demonstrated above for the undeclared-mode and scope-coherence prune shapes, with explicit-gate present throughout as Q. The remaining three of T-51's six shapes (not-suppressed, single-mode, superseded) are pinned single-process in tests/test-domain-mode-multi.sh's T-51 -- the resurrection mechanism exercised here is a property of READ-MODIFY-WRITE TIMING, not of prune_reason()'s classification, so it is not re-run per shape."
echo "NOTE T-64(e): never-fatal (read-tolerate / write-refuse) under a torn/partial sidecar is exhaustively fixture-tested in tests/test-domain-mode-multi.sh's T-65; not duplicated here."

# ===========================================================================
# T-66(c) -- the narrow "preflight -> apply" interval. Four corruption
# positions, via a REAL concurrent corruptor process; the fourth is the
# ADR's own pinned-OPEN residual, and this harness's job is to confirm it
# fails exactly as documented -- caught nowhere, yet still never weaker than
# the previous compiled state.
# ===========================================================================
BADJSON='{"multi_mode_suppression_ack": [ this is not json'

t66_flow() {
  # t66_flow <stage> <arity> -- stage in
  #   before_run2 | after_run2_before_reconcile | after_reconcile_before_run3
  # arity (only meaningful for before_run2) in nonempty | zero.
  # Prints one JSON object describing what happened.
  local stage="$1" arity="${2:-nonempty}"
  local R; R="$(new_repo)"
  write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  local CUR_HOME; CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
  local H; H="$(get_hash "$R")"
  if [[ "$arity" == "nonempty" ]]; then
    local ACK; ACK="$(ack_entry "schema-migration" '["execute_sql"]' "$H")"
    sidecar_with_acks "$R" "$ACK"
  else
    rm -f "$R/.claude/permissions.stack.json"
  fi

  compile_apply_rc "$R" >/dev/null   # establish a REAL prior compiled state
  local SETTINGS_BEFORE; SETTINGS_BEFORE="$(cat "$R/.claude/settings.json" 2>/dev/null)"
  local CFG_BEFORE; CFG_BEFORE="$(cat "$R/.claude/stack-config.json")"

  local RUN1; RUN1="$(compile_dry_stdout "$R")"
  local RUN1_FILE; RUN1_FILE="$(mktemp)"; printf '%s' "$RUN1" > "$RUN1_FILE"

  local SIDECAR="$R/.claude/permissions.stack.json"
  local GO DONE_SIG; GO="$(mktemp -u)"; DONE_SIG="$(mktemp -u)"
  ( corruptor_wait_and_corrupt "$SIDECAR" "$GO" "$DONE_SIG" "$BADJSON" ) &
  local CORRUPT_PID=$!

  local drift_field="" aborted_at="" r2b_reason="" run3_rc="" run3_err=""

  case "$stage" in
    before_run2)
      touch "$GO"; wait_for "$DONE_SIG" 200; wait "$CORRUPT_PID"
      local RUN2; RUN2="$(compile_dry_stdout "$R")"
      local RUN2_FILE; RUN2_FILE="$(mktemp)"; printf '%s' "$RUN2" > "$RUN2_FILE"
      drift_field="$(inputs_differ "$RUN1_FILE" "$RUN2_FILE")"
      if [[ -n "$drift_field" ]]; then
        aborted_at="drift_gate"
      else
        local r2b_out; r2b_out="$(r2b_predicate_rc "$SIDECAR" 2>&1)"; local r2b_rc=$?
        if [[ "$r2b_rc" -ne 0 ]]; then aborted_at="R2b"; r2b_reason="$r2b_out"; else aborted_at="none"; fi
      fi
      rm -f "$RUN2_FILE"
      ;;
    after_run2_before_reconcile)
      local RUN2; RUN2="$(compile_dry_stdout "$R")"   # against the STILL-VALID sidecar
      local RUN2_FILE; RUN2_FILE="$(mktemp)"; printf '%s' "$RUN2" > "$RUN2_FILE"
      drift_field="$(inputs_differ "$RUN1_FILE" "$RUN2_FILE")"
      touch "$GO"; wait_for "$DONE_SIG" 200; wait "$CORRUPT_PID"   # corrupt AFTER run2 returns
      local r2b_out; r2b_out="$(r2b_predicate_rc "$SIDECAR" 2>&1)"; local r2b_rc=$?
      if [[ "$r2b_rc" -ne 0 ]]; then aborted_at="R2b"; r2b_reason="$r2b_out"; else aborted_at="none"; fi
      rm -f "$RUN2_FILE"
      ;;
    after_reconcile_before_run3)
      local RUN2; RUN2="$(compile_dry_stdout "$R")"
      # R2b passes (sidecar still valid) -- perform the ONE durable reconcile write.
      local KEEP; KEEP="$(echo "$RUN2" | jq -c '.inputs.acks_in_force')"
      local KEEP_ACKS='[]'
      if [[ "$(echo "$KEEP" | jq 'length')" -gt 0 ]]; then
        local m t; m="$(echo "$KEEP" | jq -r '.[0].mode')"; t="$(echo "$KEEP" | jq -r '.[0].tool')"
        KEEP_ACKS="[$(ack_entry "$m" "[\"$t\"]" "$H")]"
      fi
      sim_domain_mode_reconcile "$R" "$KEEP_ACKS" ""
      # NOW corrupt, in the exact NAMED-OPEN window: after the reconcile
      # write, before run 3.
      touch "$GO"; wait_for "$DONE_SIG" 200; wait "$CORRUPT_PID"
      run3_err="$(compile_apply_stderr "$R")"
      run3_rc="$(compile_apply_rc "$R")"
      aborted_at="run3_exit3"
      ;;
  esac

  local SETTINGS_AFTER; SETTINGS_AFTER="$(cat "$R/.claude/settings.json" 2>/dev/null)"
  local CFG_AFTER; CFG_AFTER="$(cat "$R/.claude/stack-config.json")"
  local SIDECAR_AFTER; SIDECAR_AFTER="$(cat "$SIDECAR" 2>/dev/null)"
  rm -f "$RUN1_FILE" "$GO" "$DONE_SIG"

  jq -n --arg stage "$stage" --arg drift "$drift_field" --arg aborted "$aborted_at" \
        --arg r2b_reason "$r2b_reason" --arg run3_rc "$run3_rc" --arg run3_err "$run3_err" \
        --arg settings_before "$SETTINGS_BEFORE" --arg settings_after "$SETTINGS_AFTER" \
        --arg cfg_before "$CFG_BEFORE" --arg cfg_after "$CFG_AFTER" --arg sidecar_after "$SIDECAR_AFTER" \
        '{stage:$stage, drift_field:$drift, aborted_at:$aborted, r2b_reason:$r2b_reason,
          run3_rc:$run3_rc, run3_err:$run3_err, settings_before:$settings_before,
          settings_after:$settings_after, cfg_before:$cfg_before, cfg_after:$cfg_after,
          sidecar_after:$sidecar_after}'
}

echo "-- T-66(c) position (i): before run2, run1 saw NON-EMPTY acks -> the drift gate catches it --"
RES_A="$(t66_flow before_run2 nonempty)"
assert_eq "T-66(c)/i: caught by the drift gate (not R2b)" "drift_gate" "$(echo "$RES_A" | jq -r '.aborted_at')"
assert_eq "T-66(c)/i: the field the drift gate would name is acks_in_force (an honored suppression silently reverted to tolerated-zero-acks)" "acks_in_force" "$(echo "$RES_A" | jq -r '.drift_field')"
assert_eq "T-66(c)/i: settings.json is byte-identical to its state before this flow" "$(echo "$RES_A" | jq -r '.settings_before')" "$(echo "$RES_A" | jq -r '.settings_after')"

echo "-- T-66(c) position (ii): before run2, run1 saw ZERO acks -> the drift gate is silent; R2b catches it --"
RES_B="$(t66_flow before_run2 zero)"
assert_eq "T-66(c)/ii: the drift gate does NOT fire (deep equality against an unchanged empty ack set)" "" "$(echo "$RES_B" | jq -r '.drift_field')"
assert_eq "T-66(c)/ii: R2b is the one that catches it" "R2b" "$(echo "$RES_B" | jq -r '.aborted_at')"
assert_contains "T-66(c)/ii: R2b's reason is the documented vocabulary" "$(echo "$RES_B" | jq -r '.r2b_reason')" "file unreadable or not valid JSON"
assert_eq "T-66(c)/ii: settings.json is byte-identical to its state before this flow" "$(echo "$RES_B" | jq -r '.settings_before')" "$(echo "$RES_B" | jq -r '.settings_after')"

echo "-- T-66(c) position (iii): after run2 returns, before the reconcile's read -> R2b catches it regardless of run1's ack count --"
RES_C="$(t66_flow after_run2_before_reconcile nonempty)"
assert_eq "T-66(c)/iii: no drift detected by run2 itself (nothing had changed yet when run2 executed)" "" "$(echo "$RES_C" | jq -r '.drift_field')"
assert_eq "T-66(c)/iii: R2b catches it (distinguishing R2b from the earlier, position-bound drift gate)" "R2b" "$(echo "$RES_C" | jq -r '.aborted_at')"
assert_eq "T-66(c)/iii: settings.json is byte-identical to its state before this flow" "$(echo "$RES_C" | jq -r '.settings_before')" "$(echo "$RES_C" | jq -r '.settings_after')"

echo "-- T-66(c) position (iv): AFTER the reconcile's write, BEFORE run 3 -- the ADR's pinned-OPEN residual --"
RES_D="$(t66_flow after_reconcile_before_run3 nonempty)"
assert_eq "T-66(c)/iv: nothing catches it before run 3 (uncaught by the drift gate or R2b, exactly as the ADR names)" "run3_exit3" "$(echo "$RES_D" | jq -r '.aborted_at')"
assert_eq "T-66(c)/iv: the real apply (run 3) exits 3" "3" "$(echo "$RES_D" | jq -r '.run3_rc')"
assert_contains "T-66(c)/iv: run 3's error is the COMPILER'S OWN sanitized refusal" "$(echo "$RES_D" | jq -r '.run3_err')" "could not read or parse"
assert_contains "T-66(c)/iv: run 3's error names the reason (not valid JSON)" "$(echo "$RES_D" | jq -r '.run3_err')" "not valid JSON"
assert_not_contains "T-66(c)/iv: run 3's error is NOT the skill-level mid-flow-divergence prose (no code emits that string)" "$(echo "$RES_D" | jq -r '.run3_err')" "became unreadable mid-flow"
assert_not_contains "T-66(c)/iv: run 3's error is NOT the P0 preflight prose either" "$(echo "$RES_D" | jq -r '.run3_err')" "cannot be merged into"
assert_eq "T-66(c)/iv: stack-config.json already holds the requested (new) value, unrolled-back" "$(echo "$RES_D" | jq -r '.cfg_before')" "$(echo "$RES_D" | jq -r '.cfg_after')"
assert_eq "T-66(c)/iv: settings.json is byte-identical to its PREVIOUS compiled state -- never weaker than either serial run, despite the uncaught window" "$(echo "$RES_D" | jq -r '.settings_before')" "$(echo "$RES_D" | jq -r '.settings_after')"

echo "-- T-66(c): the four-position contrast IS the pinned claim -- (i)/(ii)/(iii) are caught before run 3; (iv) alone reaches it, and even there settings.json never regresses --"
# Keyed on run3_rc, NOT aborted_at: aborted_at is a label t66_flow's own case
# branch assigns, so asserting against it cannot fail. run3_rc is set ONLY
# inside the after_reconcile_before_run3 branch, at the point it actually
# invokes compile_apply_rc (a real subprocess) -- for stages A/B/C, run3_rc
# stays at its unset default because that call site is never reached, which
# is the genuine, subprocess-backed observation that run 3 never happened.
for res in "$RES_A" "$RES_B" "$RES_C"; do
  st="$(echo "$res" | jq -r '.stage')"
  rc="$(echo "$res" | jq -r '.run3_rc')"
  assert_eq "T-66(c): stage=$st never invokes run 3 at all (caught earlier, per the ADR's stated coverage)" "" "$rc"
done
assert_eq "T-66(c): stage=after_reconcile_before_run3 is the ONLY one that actually invokes the real apply" "3" "$(echo "$RES_D" | jq -r '.run3_rc')"

echo "----------------------------------------"
echo "domain-mode-concurrency (ADR-053 BUCKET D): $PASS passed, $FAIL failed"
echo "Scope note: sim_domain_mode_reconcile / sim_sensitivity_prune / r2b_predicate_rc model"
echo "  the documented FILE MECHANIC of skills/domain-mode/SKILL.md and skills/sensitivity/SKILL.md"
echo "  (unlocked read-modify-write timing; the mergeability predicate) as real subprocesses --"
echo "  they never re-derive classify_suppressions()'s classification logic, which always comes"
echo "  from a real scripts/permissions-compile.sh --dry-run --json call."
[[ "$FAIL" -eq 0 ]] || exit 1
