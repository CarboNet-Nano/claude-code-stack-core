#!/usr/bin/env bash
# Tests for ADR-053 (multi-domain-mode, path-scoped forced review chains) --
# BUCKET A of the tester split: real, executable tests against the actual
# enforcement point (scripts/permissions-compile.sh) and the shared reader
# (lib/domain-modes.sh), plus the four real hook/verify scripts that consume
# it (hooks/override-log.sh, hooks/statusline.sh,
# hooks/session-start-handoff.sh, scripts/verify.sh).
#
# Case IDs (T-N) reference docs/ADRs/053-implementer-handoff.md's test plan.
# NOT every T-case belongs here: the three-invocation consent flow
# (P0/run-1/run-2/R2b/reconcile/run-3/verify) lives entirely in SKILL.md
# prose read by an LLM agent, not in an executable script -- those cases are
# covered structurally in tests/test-domain-mode-skills-docs.sh (BUCKET B),
# and a handful of reconcile/prune-contract cases are covered here as
# explicitly-labeled BUCKET C contract simulations (they exercise the
# documented algorithm against the compiler's real plan JSON, not real
# skill/agent execution). See the tester report for the full T-1..T-66 map.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILE="$REPO_ROOT/scripts/permissions-compile.sh"
DM_LIB="$REPO_ROOT/lib/domain-modes.sh"
GUARD_HOOK="$REPO_ROOT/hooks/guard-check.sh"
OVERRIDE_LOG="$REPO_ROOT/hooks/override-log.sh"
STATUSLINE="$REPO_ROOT/hooks/statusline.sh"
SESSION_HANDOFF="$REPO_ROOT/hooks/session-start-handoff.sh"
VERIFY_SH="$REPO_ROOT/scripts/verify.sh"

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$COMPILE" ]] || { echo "FAIL: $COMPILE not found"; exit 1; }
[[ -f "$DM_LIB" ]] || { echo "FAIL: $DM_LIB not found"; exit 1; }

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

# new_home/new_repo are invoked via command substitution ($(...)), which runs
# in a subshell -- an append to a plain array inside the function would be
# lost when the subshell exits. Track cleanup targets in a file instead.
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
  mkdir -p "$h/.claude/session-state" "$h/.claude/config" "$h/.claude/logs" "$h/.claude/state"
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
  # write_snapshot <home> <server1> [server2 ...] -- no servers -> present but empty
  local home="$1"; shift
  local servers_json="[]"
  if [[ $# -gt 0 ]]; then
    servers_json="$(printf '%s\n' "$@" | jq -R '{name:.,transport:"stdio",host:null,remote:false}' | jq -s '.')"
  fi
  jq -n --argjson s "$servers_json" \
    '{generated_at:"2026-07-27T00:00:00Z",source:"live",scope:"user",plugins:[],mcp_servers:$s}' \
    > "$home/.claude/session-state/live-capabilities.json"
}

no_snapshot() {
  rm -f "$1/.claude/session-state/live-capabilities.json"
}

# write_cfg <dir> <domain_mode_json_literal> <domain_mode_paths_json_literal|__ABSENT__> <required_approvals_json_literal>
# Raw literal control (not jq --argjson) so malformed shapes (42, "x", true,
# duplicate array items) can be expressed exactly as ADR-053 test cases require.
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
  # Validate our own fixture is syntactically well-formed JSON unless the
  # case is deliberately testing a non-JSON stack-config.json (none here do --
  # malformed *values* inside otherwise-valid JSON are exercised via the
  # literal args above, e.g. dm="42" or dmp='{"schema-migration":[]}').
  jq empty "$dir/.claude/stack-config.json" 2>/dev/null || {
    echo "FIXTURE BUG: write_cfg produced invalid JSON" >&2
  }
}

write_sidecar_json() {
  # write_sidecar_json <dir> <json-text> -- writes EXACT bytes, no validation
  # (some callers deliberately pass invalid JSON for T-65).
  printf '%s' "$2" > "$1/.claude/permissions.stack.json"
}

# ack_entry <mode> <tools_json_array> <scope_hash> [date] [by]
ack_entry() {
  local mode="$1" tools="$2" hash="$3" date="${4:-2026-08-01}" by="${5:-tester}"
  jq -n --arg m "$mode" --argjson t "$tools" --arg h "$hash" --arg d "$date" --arg b "$by" \
    '{mode:$m, tools:$t, scope_hash:$h, date:$d, by:$b, reason:"test"}'
}

# sidecar_with_acks <dir> <ack1> [ack2 ...]
sidecar_with_acks() {
  local dir="$1"; shift
  local arr; arr="$(printf '%s\n' "$@" | jq -s '.')"
  jq -n --argjson acks "$arr" '{multi_mode_suppression_ack: $acks}' > "$dir/.claude/permissions.stack.json"
}

compile_dry_stdout() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" --dry-run --json 2>/dev/null
}
compile_dry_stderr() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" --dry-run --json 2>&1 >/dev/null
}
compile_dry_rc() {
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" --dry-run --json >/dev/null 2>&1
  echo $?
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

compiled_rules() {
  compile_dry_stdout "$1" | jq -r '.compiled_deny[].rule'
}

get_hash() {
  compile_dry_stdout "$1" | jq -r '.inputs.consent_scope_hash'
}

echo "== ADR-053 multi-domain-mode suite (BUCKET A: compiler + lib.domain-modes.sh) =="

# ---------------------------------------------------------------------------
# T-1 / T-2: schema-adjacent validate_domain_mode shape matrix
# ---------------------------------------------------------------------------
CUR_HOME="$(new_home)"; write_snapshot "$CUR_HOME" supabase
for dm in 'null' '"financial-code"' '"schema-migration"' '"deploy"' '"ui-design"' '"data-operation"' '["ui-design","schema-migration"]'; do
  R="$(new_repo)"; write_cfg "$R" "$dm" '__ABSENT__' '[]'
  rc="$(compile_dry_rc "$R")"
  assert_rc "T-1: domain_mode=$dm validates (exit 0)" 0 "$rc"
done

R="$(new_repo)"; write_cfg "$R" '[]' '__ABSENT__' '[]'
assert_rc "T-2: domain_mode=[] refused (minItems)" 3 "$(compile_dry_rc "$R")"

R="$(new_repo)"; write_cfg "$R" '["ui-design","ui-design"]' '__ABSENT__' '[]'
assert_rc "T-2: domain_mode=[dup,dup] refused (uniqueItems)" 3 "$(compile_dry_rc "$R")"

R="$(new_repo)"; write_cfg "$R" '["nope"]' '__ABSENT__' '[]'
assert_rc "T-2: domain_mode=[unknown] refused (enum)" 3 "$(compile_dry_rc "$R")"

R="$(new_repo)"; write_cfg "$R" '{"a":1}' '__ABSENT__' '[]'
assert_rc "T-2: domain_mode={} refused" 3 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-3: clause 2 AND clause 3 both closed -> exit 0, deny set absent by content
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
rc="$(compile_dry_rc "$R")"
assert_rc "T-3: full ack, no domain_mode_paths, no explicit gates -> exit 0" 0 "$rc"
RULES="$(compiled_rules "$R")"
assert_not_contains_line "T-3: apply_migration deny absent" "$RULES" "mcp__supabase__apply_migration"
assert_not_contains_line "T-3: execute_sql deny absent" "$RULES" "mcp__supabase__execute_sql"
assert_not_contains_line "T-3: deploy_edge_function deny absent" "$RULES" "mcp__supabase__deploy_edge_function"

# ---------------------------------------------------------------------------
# T-4: explicit gate (clause 1) overrides the ack for its 2 owned tools only
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-schema-change"]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
RULES="$(compiled_rules "$R")"
assert_contains_line "T-4: apply_migration deny back (explicit-gate)" "$RULES" "mcp__supabase__apply_migration"
assert_contains_line "T-4: execute_sql deny back (explicit-gate)" "$RULES" "mcp__supabase__execute_sql"
assert_not_contains_line "T-4: deploy_edge_function still absent (not owned by pre-schema-change)" "$RULES" "mcp__supabase__deploy_edge_function"
WITHHELD_CLAUSES="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration" or .tool=="execute_sql") | .clause' | sort -u)"
assert_eq "T-4: withheld clause is explicit-gate, not consent" "explicit-gate" "$WITHHELD_CLAUSES"

# ---------------------------------------------------------------------------
# T-5: typo inside an array -> exit 3, sanitized, no traceback
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","financial_code"]' '__ABSENT__' '[]'
ERR="$(compile_dry_stderr "$R")"
assert_rc "T-5: typo in array -> exit 3" 3 "$(compile_dry_rc "$R")"
assert_not_contains "T-5: no traceback" "$ERR" "Traceback"
assert_contains "T-5: sanitized refusal message" "$ERR" "refused:"

# ---------------------------------------------------------------------------
# T-6: shape refusals
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '[]' '__ABSENT__' '[]'
assert_rc "T-6: domain_mode=[] -> exit 3" 3 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["deploy","deploy"]' '__ABSENT__' '[]'
assert_rc "T-6: domain_mode=[dup] -> exit 3" 3 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '42' '__ABSENT__' '[]'
assert_rc "T-6: domain_mode=42 -> exit 3" 3 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-7: idempotency of a real apply with an array domain_mode
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","deploy"]' '__ABSENT__' '[]'
compile_apply_rc "$R" >/dev/null
SETTINGS_1="$(cat "$R/.claude/settings.json" 2>/dev/null)"
SIDECAR_1="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null || echo '{}')"
compile_apply_rc "$R" >/dev/null
SETTINGS_2="$(cat "$R/.claude/settings.json" 2>/dev/null)"
SIDECAR_2="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null || echo '{}')"
assert_eq "T-7: settings.json byte-identical across 2 consecutive applies" "$SETTINGS_1" "$SETTINGS_2"
assert_eq "T-7: sidecar byte-identical across 2 consecutive applies" "$SIDECAR_1" "$SIDECAR_2"

# ---------------------------------------------------------------------------
# T-8: array -> null prunes every stack-owned rule; allow untouched
# ---------------------------------------------------------------------------
# NOTE: apply_migration/execute_sql/deploy_edge_function are denied
# UNCONDITIONALLY BY DEFAULT (ADR-044 MCQ-2), independent of domain_mode --
# only an HONORED suppression removes them. So the rule that must disappear
# when domain_mode -> null is the domain overlay's OWN additive contribution
# (deploy's bash_guardrails), not the MCQ-2 default deny.
R="$(new_repo)"; write_cfg "$R" '["ui-design","deploy"]' '__ABSENT__' '[]'
mkdir -p "$R/.claude"
jq -n '{permissions:{allow:["Bash(ls:*)"],deny:[]}}' > "$R/.claude/settings.json"
compile_apply_rc "$R" >/dev/null
RULES_BEFORE="$(jq -r '.permissions.deny[]?' "$R/.claude/settings.json")"
assert_contains_line "T-8: deploy overlay bash_guardrail present before clearing" "$RULES_BEFORE" "Bash(vercel --prod:*)"
write_cfg "$R" 'null' '__ABSENT__' '[]'
compile_apply_rc "$R" >/dev/null
RULES_AFTER="$(jq -r '.permissions.deny[]?' "$R/.claude/settings.json")"
assert_not_contains_line "T-8: deploy overlay bash_guardrail gone after domain_mode:null" "$RULES_AFTER" "Bash(vercel --prod:*)"
assert_contains_line "T-8: MCQ-2 default deny for deploy_edge_function is UNAFFECTED by domain_mode (documented, not this ADR own rule)" "$RULES_AFTER" "mcp__supabase__deploy_edge_function"
ALLOW_AFTER="$(jq -r '.permissions.allow[]?' "$R/.claude/settings.json")"
assert_contains_line "T-8: allow untouched" "$ALLOW_AFTER" "Bash(ls:*)"

# ---------------------------------------------------------------------------
# T-9: override-log.sh honors an array domain_mode (financial-code context flag)
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","financial-code"]' '__ABSENT__' '[]'
LOG_HOME="$(new_home)"
PAYLOAD='{"cwd":"'"$R"'","tool_name":"Task","tool_input":{"subagent_type":"implementer","description":"do work"}}'
HOME="$LOG_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "source '$OVERRIDE_LOG'; ovlog_main" <<< "$PAYLOAD" >/dev/null 2>&1
LOGFILE="$(find "$LOG_HOME/.claude/logs" -name 'subagent-runs.jsonl' 2>/dev/null | head -1)"
if [[ -n "$LOGFILE" ]] && grep -q "financial-code" "$LOGFILE" 2>/dev/null; then
  pass "T-9: override-log.sh emits financial-code context flag for array domain_mode"
else
  fail "T-9: override-log.sh did not emit financial-code context flag for array domain_mode (log: ${LOGFILE:-none})"
fi

# ---------------------------------------------------------------------------
# T-11: verify.sh on an array config -- each element checked, no mangled eval
# ---------------------------------------------------------------------------
VERIFY_TMP="$(new_repo)"
git -C "$VERIFY_TMP" init -q 2>/dev/null
write_cfg "$VERIFY_TMP" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
mkdir -p "$VERIFY_TMP/docs/ADRs"
VOUT="$(HOME="$(new_home)" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$VERIFY_SH" --tier=2 --repo="$VERIFY_TMP" --skip-requirements 2>&1)"
assert_contains "T-11: verify.sh reports ui-design as known" "$VOUT" "ui-design"
assert_contains "T-11: verify.sh reports schema-migration as known" "$VOUT" "schema-migration"
assert_not_contains "T-11: verify.sh stderr has no stray newline artifact from a mangled eval" "$VOUT" '$'"'"'\n'"'"

VERIFY_TMP2="$(new_repo)"
git -C "$VERIFY_TMP2" init -q 2>/dev/null
write_cfg "$VERIFY_TMP2" '["ui-design","not-a-real-mode-xyz"]' '__ABSENT__' '[]'
mkdir -p "$VERIFY_TMP2/docs/ADRs"
VOUT2="$(HOME="$(new_home)" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$VERIFY_SH" --tier=2 --repo="$VERIFY_TMP2" --skip-requirements 2>&1)"
assert_contains "T-11: verify.sh FAILs a bad array element" "$VOUT2" "FAIL"

# ---------------------------------------------------------------------------
# T-12: statusline.sh / session-start-handoff.sh render one-line, comma-joined
# ---------------------------------------------------------------------------
SL_REPO="$(new_repo)"
write_cfg "$SL_REPO" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
SL_HOME="$(new_home)"
SL_OUT="$(HOME="$SL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "echo '{\"cwd\":\"$SL_REPO\"}' | bash '$STATUSLINE'")"
LINES="$(printf '%s' "$SL_OUT" | wc -l | tr -d ' ')"
assert_eq "T-12: statusline.sh emits exactly one line" "0" "$LINES"
assert_contains "T-12: statusline.sh renders comma-joined modes" "$SL_OUT" "ui-design, schema-migration"

SH_REPO="$(new_repo)"
git -C "$SH_REPO" init -q 2>/dev/null
write_cfg "$SH_REPO" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
SH_HOME="$(new_home)"
SH_OUT="$(cd "$SH_REPO" && HOME="$SH_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$SESSION_HANDOFF" 2>&1)"
assert_contains "T-12: session-start-handoff.sh renders comma-joined modes, not pretty JSON" "$SH_OUT" "ui-design, schema-migration"
assert_not_contains "T-12: session-start-handoff.sh never emits a raw JSON array bracket for domain" "$SH_OUT" '["ui-design"'

# ---------------------------------------------------------------------------
# T-13: dm_scoped_modes unit cases (sourced directly, no compiler involved)
# ---------------------------------------------------------------------------
source "$DM_LIB"
# (a)-(e): BOTH modes mapped, so neither is "unmapped -> always active" --
# this isolates path-matching from the D4 fail-safe exercised separately in (f).
DM_REPO="$(new_repo)"
write_cfg "$DM_REPO" '["ui-design","schema-migration"]' \
  '{"ui-design":["components/**"],"schema-migration":["migrations/**"]}' '[]'
CFGPATH="$DM_REPO/.claude/stack-config.json"

RES_A="$(dm_scoped_modes "$CFGPATH" "components/Dashboard.tsx")"
assert_eq "T-13(a): components/Dashboard.tsx -> ui-design only" "ui-design" "$RES_A"

RES_B="$(dm_scoped_modes "$CFGPATH" "migrations/003.sql")"
assert_eq "T-13(b): migrations/003.sql -> schema-migration only" "schema-migration" "$RES_B"

RES_C="$(dm_scoped_modes "$CFGPATH" "components/Dashboard.tsx" "migrations/003.sql" | sort | tr '\n' ',')"
assert_eq "T-13(c): both files -> both modes" "schema-migration,ui-design," "$RES_C"

RES_D="$(dm_scoped_modes "$CFGPATH" "README.md")"
assert_eq "T-13(d): README.md -> neither mode" "" "$RES_D"

RES_E="$(dm_scoped_modes "$CFGPATH" | sort | tr '\n' ',')"
assert_eq "T-13(e): zero files -> all declared modes (UNSCOPED fail-safe)" "schema-migration,ui-design," "$RES_E"

# (f): ui-design deliberately left UNMAPPED (no domain_mode_paths entry at
# all) -- D4 says an unmapped mode is always-active, so it must appear in
# EVERY result, including the README.md case that would otherwise match none.
DM_REPO_F="$(new_repo)"
write_cfg "$DM_REPO_F" '["ui-design","schema-migration"]' \
  '{"schema-migration":["migrations/**"]}' '[]'
CFGPATH_F="$DM_REPO_F/.claude/stack-config.json"
RES_F="$(dm_scoped_modes "$CFGPATH_F" "README.md")"
assert_contains "T-13(f): ui-design (no domain_mode_paths entry) present even for README.md" "$RES_F" "ui-design"

# ---------------------------------------------------------------------------
# T-14: cross-file mode-name-list consistency (real repo files, not fixtures)
# ---------------------------------------------------------------------------
MODES_JSON="$(jq -r '.modes | keys | sort | join(",")' "$REPO_ROOT/config/domain-modes.json")"
MODES_BASELINE="$(jq -r '.domain_overlays | keys | sort | join(",")' "$REPO_ROOT/config/permissions-baseline.json")"
MODES_STACK_SCHEMA="$(jq -r '.properties.domain_mode.oneOf[1].items.enum | sort | join(",")' "$REPO_ROOT/schemas/stack-config-schema.json")"
MODES_DEFAULTS_SCHEMA="$(jq -r '.properties.default_domain_mode.oneOf[1].items.enum | sort | join(",")' "$REPO_ROOT/schemas/stack-defaults-schema.json")"
assert_eq "T-14: domain-modes.json.modes == permissions-baseline.json.domain_overlays" "$MODES_JSON" "$MODES_BASELINE"
assert_eq "T-14: domain-modes.json.modes == stack-config-schema.json enum" "$MODES_JSON" "$MODES_STACK_SCHEMA"
assert_eq "T-14: domain-modes.json.modes == stack-defaults-schema.json enum" "$MODES_JSON" "$MODES_DEFAULTS_SCHEMA"

# ---------------------------------------------------------------------------
# T-15 / T-16: stage_order merge -- BUCKET C contract simulation.
# skills/foreman/SKILL.md step 6e describes this algorithm in prose for an
# LLM agent; there is no executable function to call. This simulates the
# documented algorithm faithfully against the real stage_order in
# config/domain-modes.json and pins the worked example from the handoff doc.
# It does NOT exercise foreman's actual runtime behavior -- see
# test-domain-mode-skills-docs.sh for the structural check that the prose
# still says this.
# ---------------------------------------------------------------------------
merge_stage_order() {
  # merge_stage_order <comma-chain> <comma-forced> <stage_order-json-array>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, json
chain = sys.argv[1].split(",") if sys.argv[1] else []
forced = sys.argv[2].split(",") if sys.argv[2] else []
stage_order = json.loads(sys.argv[3])
warnings = []
def idx(a):
    return stage_order.index(a) if a in stage_order else None
for a in forced:
    if a in chain:
        continue
    ia = idx(a)
    if ia is None:
        # insert immediately before scribe (append if no scribe), warn
        if "scribe" in chain:
            chain.insert(chain.index("scribe"), a)
        else:
            chain.append(a)
        warnings.append(a)
        continue
    insert_at = 0
    for i, c in enumerate(chain):
        ic = idx(c)
        if ic is not None and ic <= ia:
            insert_at = i + 1
    chain.insert(insert_at, a)
print(",".join(chain) + "|" + ",".join(warnings))
PY
}
STAGE_ORDER_JSON="$(jq -c '.stage_order' "$REPO_ROOT/config/domain-modes.json")"
OUT="$(merge_stage_order "architect,implementer,validator,reviewer,documenter,scribe" "designer,data-engineer" "$STAGE_ORDER_JSON")"
RESULT_CHAIN="${OUT%%|*}"
assert_eq "T-15: forced designer+data-engineer insert at stage position, existing members not reordered" \
  "architect,designer,data-engineer,implementer,validator,reviewer,documenter,scribe" "$RESULT_CHAIN"

OUT2="$(merge_stage_order "architect,implementer,reviewer,scribe" "totally-unknown-agent" "$STAGE_ORDER_JSON")"
RESULT_CHAIN2="${OUT2%%|*}"
WARN2="${OUT2##*|}"
assert_eq "T-16: agent absent from stage_order inserted immediately before scribe" \
  "architect,implementer,reviewer,totally-unknown-agent,scribe" "$RESULT_CHAIN2"
assert_eq "T-16: a warning is produced for the absent agent" "totally-unknown-agent" "$WARN2"

# ---------------------------------------------------------------------------
# T-17: glob dialect parity between dm_path_matches_mode and guard-check.sh
# ---------------------------------------------------------------------------
guard_style_match() {
  local rel="$1" glob="$2"
  case "$rel" in
    ${glob//\*\*/\*}) return 0 ;;
  esac
  return 1
}
GP_REPO="$(new_repo)"
write_cfg "$GP_REPO" '["ui-design"]' '{"ui-design":["app/**"]}' '[]'
GP_CFG="$GP_REPO/.claude/stack-config.json"
for path in "app/foo.tsx" "app/a/b/c.tsx" "notapp/foo.tsx"; do
  dm_r=1; dm_path_matches_mode "$GP_CFG" "ui-design" "$path" && dm_r=0
  gs_r=1; guard_style_match "$path" "app/**" && gs_r=0
  assert_eq "T-17: app/** parity for '$path'" "$gs_r" "$dm_r"
done
write_cfg "$GP_REPO" '["ui-design"]' '{"ui-design":["app/*"]}' '[]'
for path in "app/foo.tsx" "app/a/b/c.tsx"; do
  dm_r=1; dm_path_matches_mode "$GP_CFG" "ui-design" "$path" && dm_r=0
  gs_r=1; guard_style_match "$path" "app/*" && gs_r=0
  assert_eq "T-17: app/* behaves like app/** for '$path' (parity)" "$gs_r" "$dm_r"
done

# ---------------------------------------------------------------------------
# T-18: regression -- existing scalar-form suites still pass unchanged
# ---------------------------------------------------------------------------
REG_OUT="$(bash "$REPO_ROOT/tests/test-permissions-boundary.sh" 2>&1 | grep -E 'passed,.*failed')"
assert_contains "T-18: test-permissions-boundary.sh scalar-form regressions still pass" "$REG_OUT" "0 failed"
REG_OUT2="$(bash "$REPO_ROOT/tests/test-model-fit.sh" 2>&1 | grep -E 'passed,.*failed')"
assert_contains "T-18: test-model-fit.sh scalar-form regressions still pass" "$REG_OUT2" "0 failed"

write_fixture_baseline() {
  # write_fixture_baseline <home> <json> -- checked BEFORE CLAUDE_PLUGIN_ROOT's
  # installed baseline, so this fully isolates baseline-touching tests from
  # the real config/permissions-baseline.json.
  mkdir -p "$1/.claude/config"
  printf '%s' "$2" > "$1/.claude/config/permissions-baseline.json"
}

# ---------------------------------------------------------------------------
# T-21 *(CRITICAL 1 -- non-skill writer)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
PLAN="$(compile_dry_stdout "$R")"
ERR="$(compile_dry_stderr "$R")"
assert_rc "T-21: exit 0" 0 "$(compile_dry_rc "$R")"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_contains_line "T-21: mcp__supabase__$tool present" "$(echo "$PLAN" | jq -r '.compiled_deny[].rule')" "mcp__supabase__$tool"
done
N_WITHHELD="$(echo "$PLAN" | jq '.inputs.suppressions_withheld | length')"
assert_eq "T-21: 3 suppressions_withheld entries" "3" "$N_WITHHELD"
CLAUSES="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[].clause' | sort -u)"
assert_eq "T-21: all withheld clause == consent" "consent" "$CLAUSES"
MODES="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[].mode' | sort -u)"
assert_eq "T-21: all withheld mode == schema-migration" "schema-migration" "$MODES"
HASH_PRESENT="$(echo "$PLAN" | jq -r '.inputs.consent_scope_hash != null and .inputs.consent_scope != null')"
assert_eq "T-21: consent_scope and consent_scope_hash present" "true" "$HASH_PRESENT"
assert_contains "T-21: a warning names each withheld tool on stderr" "$ERR" "apply_migration"

# ---------------------------------------------------------------------------
# T-22 *(CRITICAL 2 -- dead/narrow glob)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '{"schema-migration":["nonexistent/**"]}' '[]'
RULES="$(compiled_rules "$R")"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_contains_line "T-22(a): mcp__supabase__$tool present (single-mode, mapped to a dead glob)" "$RULES" "mcp__supabase__$tool"
done
CLAUSE_A="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[0].clause')"
assert_eq "T-22(a): clause is scope-coherence" "scope-coherence" "$CLAUSE_A"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{"schema-migration":["nonexistent/**"]}' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
RULES="$(compiled_rules "$R")"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_contains_line "T-22(b): mcp__supabase__$tool present despite a full current-hash ack (clause 2 independent of clause 3)" "$RULES" "mcp__supabase__$tool"
done
CLAUSES_B="$(compile_dry_stdout "$R" | jq -r '.inputs.suppressions_withheld[].clause' | sort -u)"
assert_eq "T-22(b): clause is scope-coherence, not consent" "scope-coherence" "$CLAUSES_B"

# ---------------------------------------------------------------------------
# T-24 *(positive path)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_not_contains_line "T-24: mcp__supabase__$tool absent" "$RULES" "mcp__supabase__$tool"
done
HONORED_OK="$(echo "$PLAN" | jq -r '
  [.inputs.suppressions_honored[] | select(.by == ["schema-migration"])] | length == 3')"
assert_eq "T-24: suppressions_honored has 3 entries, each by:[schema-migration]" "true" "$HONORED_OK"
DENY_RULES_MATCH="$(echo "$PLAN" | jq -r '
  all(.inputs.suppressions_honored[]; .deny_rules_removed == ["mcp__supabase__" + .tool])')"
assert_eq "T-24: deny_rules_removed == rules_for_tool for each honored tool" "true" "$DENY_RULES_MATCH"
IN_FORCE_OK="$(echo "$PLAN" | jq -r '
  (.inputs.acks_in_force | map(.tool) | sort) == ["apply_migration","deploy_edge_function","execute_sql"]')"
assert_eq "T-24: acks_in_force lists all 3 pairs" "true" "$IN_FORCE_OK"
assert_eq "T-24: acks_prunable empty" "0" "$(echo "$PLAN" | jq '.inputs.acks_prunable | length')"
assert_eq "T-24: suppressions_withheld empty" "0" "$(echo "$PLAN" | jq '.inputs.suppressions_withheld | length')"

# ---------------------------------------------------------------------------
# T-25 *(partial ack)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
assert_not_contains_line "T-25: apply_migration absent" "$RULES" "mcp__supabase__apply_migration"
assert_not_contains_line "T-25: execute_sql absent" "$RULES" "mcp__supabase__execute_sql"
assert_contains_line "T-25: deploy_edge_function present" "$RULES" "mcp__supabase__deploy_edge_function"
CLAUSE="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="deploy_edge_function") | .clause')"
assert_eq "T-25: deploy_edge_function withheld clause is consent" "consent" "$CLAUSE"

# ---------------------------------------------------------------------------
# T-26 *(single-mode back-compat, reduced)* -- the "byte-identical to a
# pre-ADR-053 compile" half is unverifiable: no pre-ADR-053 compiler exists
# in this tree to diff against. Reduced to the checkable half.
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
RULES="$(compiled_rules "$R")"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_not_contains_line "T-26: single-mode schema-migration, no ack -> $tool absent (arity-1 carve-out)" "$RULES" "mcp__supabase__$tool"
done

# ---------------------------------------------------------------------------
# T-27 *(ack durability)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
jq -n '{
  multi_mode_suppression_ack: [{mode:"schema-migration", tools:["apply_migration"], scope_hash:"sha256:deadbeef", date:"2026-01-01", by:"human", reason:"manual"}],
  waivers: [{rule:"Bash(ls:*)"}],
  pinned: ["Bash(ls:*)"]
}' > "$R/.claude/permissions.stack.json"
ORIG_ACK="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
ORIG_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
ORIG_PINNED="$(jq -c '.pinned' "$R/.claude/permissions.stack.json")"
compile_apply_rc "$R" >/dev/null
compile_apply_rc "$R" >/dev/null
AFTER_ACK="$(jq -c '.multi_mode_suppression_ack' "$R/.claude/permissions.stack.json")"
AFTER_WAIVERS="$(jq -c '.waivers' "$R/.claude/permissions.stack.json")"
AFTER_PINNED="$(jq -c '.pinned' "$R/.claude/permissions.stack.json")"
assert_eq "T-27: multi_mode_suppression_ack survives 2 compiles verbatim" "$ORIG_ACK" "$AFTER_ACK"
assert_eq "T-27: waivers[] survives 2 compiles verbatim" "$ORIG_WAIVERS" "$AFTER_WAIVERS"
assert_eq "T-27: pinned[] survives 2 compiles verbatim" "$ORIG_PINNED" "$AFTER_PINNED"

# ---------------------------------------------------------------------------
# T-28 *(malformed stack-config.json shape matrix)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{"schema_migration":["x/**"]}' '[]'
assert_rc "T-28: domain_mode_paths typo'd key -> exit 3" 3 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '42' '[]'
assert_rc "T-28: domain_mode_paths=42 -> exit 3" 3 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '"x"' '[]'
assert_rc "T-28: domain_mode_paths=\"x\" -> exit 3" 3 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
assert_rc "T-28: domain_mode_paths absent -> exit 0" 0 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' 'null' '[]'
assert_rc "T-28: domain_mode_paths=null -> exit 0" 0 "$(compile_dry_rc "$R")"
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{}' '[]'
assert_rc "T-28: domain_mode_paths={} -> exit 0" 0 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-29 *(idempotency under withholding, dry-run)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
RUN1="$(compile_dry_stdout "$R")"
RUN2="$(compile_dry_stdout "$R")"
assert_eq "T-29: two consecutive dry-run compiles of a withheld config are byte-identical" "$RUN1" "$RUN2"

# ---------------------------------------------------------------------------
# T-30 *(clause precedence + corrected gate map)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-schema-change"]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
assert_contains_line "T-30: apply_migration present (explicit-gate)" "$RULES" "mcp__supabase__apply_migration"
assert_contains_line "T-30: execute_sql present (explicit-gate)" "$RULES" "mcp__supabase__execute_sql"
assert_not_contains_line "T-30: deploy_edge_function absent (honored)" "$RULES" "mcp__supabase__deploy_edge_function"
EG_CLAUSES="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration" or .tool=="execute_sql") | .clause' | sort -u)"
assert_eq "T-30: both withheld with clause explicit-gate" "explicit-gate" "$EG_CLAUSES"
DEF_HONORED="$(echo "$PLAN" | jq -r '.inputs.suppressions_honored[] | select(.tool=="deploy_edge_function") | .tool')"
assert_eq "T-30: deploy_edge_function listed in suppressions_honored" "deploy_edge_function" "$DEF_HONORED"

# ---------------------------------------------------------------------------
# T-33 *(TOCTOU characterization via self-heal)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
assert_not_contains_line "T-33: honored before out-of-band ack deletion" "$(echo "$PLAN" | jq -r '.compiled_deny[].rule')" "mcp__supabase__apply_migration"
rm -f "$R/.claude/permissions.stack.json"
PLAN2="$(compile_dry_stdout "$R")"
ERR2="$(compile_dry_stderr "$R")"
RULES2="$(echo "$PLAN2" | jq -r '.compiled_deny[].rule')"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_contains_line "T-33: $tool present after out-of-band ack deletion (self-heal)" "$RULES2" "mcp__supabase__$tool"
done
CLAUSE="$(echo "$PLAN2" | jq -r '.inputs.suppressions_withheld[0].clause')"
assert_eq "T-33: clause is consent (not consent-stale -- the ack is simply gone)" "consent" "$CLAUSE"
assert_rc "T-33: no exit-3" 0 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-34 *(orphan key is never fatal)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{"deploy":["supabase/functions/**"]}' '[]'
PLAN="$(compile_dry_stdout "$R")"
ERR="$(compile_dry_stderr "$R")"
assert_rc "T-34: exit 0 with an orphan domain_mode_paths key" 0 "$(compile_dry_rc "$R")"
IGNORED="$(echo "$PLAN" | jq -c '.inputs.domain_mode_paths_ignored')"
assert_eq "T-34: domain_mode_paths_ignored == [\"deploy\"]" '["deploy"]' "$IGNORED"
assert_contains "T-34: a warning names the orphan key" "$ERR" "deploy"
SCOPED="$(echo "$PLAN" | jq -c '.inputs.consent_scope.scoped')"
assert_eq "T-34: consent_scope.scoped == [] (orphan outside the preimage)" '[]' "$SCOPED"
HASH_WITH_ORPHAN="$(echo "$PLAN" | jq -r '.inputs.consent_scope_hash')"
R2="$(new_repo)"; write_cfg "$R2" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
HASH_WITHOUT_ORPHAN="$(get_hash "$R2")"
assert_eq "T-34: hash identical with/without the orphan key" "$HASH_WITHOUT_ORPHAN" "$HASH_WITH_ORPHAN"

# ---------------------------------------------------------------------------
# T-36 *(hash preimage: invariance and sensitivity)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H0="$(get_hash "$R")"

Ra="$(new_repo)"; write_cfg "$Ra" '["schema-migration","ui-design"]' '__ABSENT__' '[]'
assert_eq "T-36(a): reordering domain_mode does not change the hash" "$H0" "$(get_hash "$Ra")"

Rb="$(new_repo)"; write_cfg "$Rb" '["ui-design","schema-migration"]' '{"ui-design":["src/**"]}' '[]'
Hb="$(get_hash "$Rb")"
write_cfg "$Rb" '["ui-design","schema-migration"]' '{"ui-design":["src/other/**"]}' '[]'
assert_eq "T-36(b): editing a glob VALUE does not change the hash" "$Hb" "$(get_hash "$Rb")"

Rc="$(new_repo)"; write_cfg "$Rc" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
Hc="$(get_hash "$Rc")"
write_cfg "$Rc" '["ui-design","schema-migration"]' '{"deploy":["x/**"]}' '[]'
assert_eq "T-36(c): adding an orphan key does not change the hash" "$Hc" "$(get_hash "$Rc")"

Rd="$(new_repo)"; write_cfg "$Rd" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-merge"]'
assert_eq "T-36(d): a required_approvals gate owning no suppressible tool (pre-merge) does not change the hash" "$H0" "$(get_hash "$Rd")"

Re="$(new_repo)"; write_cfg "$Re" '["ui-design"]' '__ABSENT__' '[]'
He="$(get_hash "$Re")"
assert_not_contains "T-36(e): adding/removing a declared mode changes the hash" "$H0" "$He"

Rf="$(new_repo)"; write_cfg "$Rf" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
Hf0="$(get_hash "$Rf")"
write_cfg "$Rf" '["ui-design","schema-migration"]' '{"schema-migration":["migrations/**"]}' '[]'
Hf1="$(get_hash "$Rf")"
assert_not_contains "T-36(f): adding a domain_mode_paths key for a DECLARED mode changes the hash" "$Hf0" "$Hf1"

Rg="$(new_repo)"; write_cfg "$Rg" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
Hg0="$(get_hash "$Rg")"
write_cfg "$Rg" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-schema-change"]'
Hg1="$(get_hash "$Rg")"
assert_not_contains "T-36(g): adding pre-schema-change to required_approvals changes the hash" "$Hg0" "$Hg1"
for r in "$Ra" "$Rb" "$Rc" "$Rd" "$Re" "$Rf" "$Rg"; do
  assert_rc "T-36: every hash-mutation case still exits 0" 0 "$(compile_dry_rc "$r")"
done

# ---------------------------------------------------------------------------
# T-37 *(the sidecar is never fatal -- representative shape matrix)*
# ---------------------------------------------------------------------------
run_t37_case() {
  local label="$1" sidecar_json="$2"
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  printf '%s' "$sidecar_json" > "$R/.claude/permissions.stack.json"
  local rc err rules
  rc="$(compile_dry_rc "$R")"
  err="$(compile_dry_stderr "$R")"
  rules="$(compiled_rules "$R")"
  assert_rc "T-37 ($label): exit 0" 0 "$rc"
  assert_not_contains "T-37 ($label): no traceback" "$err" "Traceback"
  assert_contains_line "T-37 ($label): apply_migration stays denied (ignored/inert ack)" "$rules" "mcp__supabase__apply_migration"
}
run_t37_case "empty ack object" '{"multi_mode_suppression_ack": {}}'
run_t37_case "ack array of scalars" '{"multi_mode_suppression_ack": [42]}'
run_t37_case "entry missing tools" '{"multi_mode_suppression_ack": [{"mode":"schema-migration","scope_hash":"sha256:x"}]}'
run_t37_case "tools: []" '{"multi_mode_suppression_ack": [{"mode":"schema-migration","tools":[],"scope_hash":"sha256:x"}]}'
run_t37_case "tools: [\"\"] (empty-string element)" '{"multi_mode_suppression_ack": [{"mode":"schema-migration","tools":[""],"scope_hash":"sha256:x"}]}'
run_t37_case "unknown mode" '{"multi_mode_suppression_ack": [{"mode":"schema_migration_typo","tools":["apply_migration"],"scope_hash":"sha256:x"}]}'
run_t37_case "no scope_hash" '{"multi_mode_suppression_ack": [{"mode":"schema-migration","tools":["apply_migration"]}]}'
run_t37_case "wrong scope_hash" '{"multi_mode_suppression_ack": [{"mode":"schema-migration","tools":["apply_migration"],"scope_hash":"sha256:wrong"}]}'

# known-but-undeclared mode + tool-its-mode-does-not-suppress: assert "inert"
# warning wording specifically (round 4's requirement).
R="$(new_repo)"; write_cfg "$R" '["schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK_UNDECLARED="$(ack_entry "deploy" '["deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK_UNDECLARED"
ERR="$(compile_dry_stderr "$R")"
assert_contains "T-37 (round 4): known-but-undeclared mode warning contains 'inert'" "$ERR" "inert"

R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK_NOT_SUPP="$(ack_entry "ui-design" '["apply_migration"]' "$H")"
sidecar_with_acks "$R" "$ACK_NOT_SUPP"
ERR="$(compile_dry_stderr "$R")"
assert_contains "T-37 (round 4): tool-mode-does-not-suppress warning contains 'inert'" "$ERR" "inert"
RULES="$(compiled_rules "$R")"
assert_contains_line "T-37: inert ack does not honor apply_migration" "$RULES" "mcp__supabase__apply_migration"

# ---------------------------------------------------------------------------
# T-39 *(honoring is a union over modes; report never lies)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["deploy","schema-migration"]' '{"schema-migration":["supabase/migrations/**"]}' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "deploy" '["deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
assert_not_contains_line "T-39: deploy_edge_function absent (honored via deploy)" "$RULES" "mcp__supabase__deploy_edge_function"
assert_contains_line "T-39: apply_migration present (scope-coherence)" "$RULES" "mcp__supabase__apply_migration"
assert_contains_line "T-39: execute_sql present (scope-coherence)" "$RULES" "mcp__supabase__execute_sql"
SC_CLAUSES="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration" or .tool=="execute_sql") | .clause' | sort -u)"
assert_eq "T-39: apply_migration/execute_sql withheld clause is scope-coherence" "scope-coherence" "$SC_CLAUSES"
NO_DEF_WITHHELD="$(echo "$PLAN" | jq -r '[.inputs.suppressions_withheld[] | select(.tool=="deploy_edge_function")] | length')"
assert_eq "T-39: no suppressions_withheld entry mentions deploy_edge_function" "0" "$NO_DEF_WITHHELD"
INVARIANT_1="$(echo "$PLAN" | jq -r '
  ([.inputs.suppressions_withheld[].deny_rules[]] - [.compiled_deny[].rule]) | length == 0')"
assert_eq "T-39: withheld.deny_rules subset-of compiled_deny" "true" "$INVARIANT_1"
DENY_HONORED_DISJOINT="$(echo "$PLAN" | jq -r '
  ([.inputs.suppressions_honored[].deny_rules_removed[]]) as $removed
  | ([.compiled_deny[].rule]) as $deny
  | (($removed - ($removed - $deny)) | length == 0)')"
assert_eq "T-39: honored.deny_rules_removed ∩ compiled_deny == empty" "true" "$DENY_HONORED_DISJOINT"

# ---------------------------------------------------------------------------
# T-40 *(non-gate-owned overlay tools never enter the honor test)*
# ---------------------------------------------------------------------------
FIXTURE_HOME="$(new_home)"; write_snapshot "$FIXTURE_HOME" supabase
write_fixture_baseline "$FIXTURE_HOME" '{
  "version": "test-1",
  "floor": {"deny": [], "path_rules": []},
  "domain_overlays": {
    "schema-migration": {"mcp_tool_denies": ["apply_migration", "execute_sql", "deploy_edge_function", "list_tables"]},
    "ui-design": {}, "deploy": {}, "financial-code": {}, "data-operation": {}
  },
  "sensitivity_overlays": {"normal": {"deny": []}},
  "approval_gate_map": {
    "pre-schema-change": {"mcp_tool_denies": ["apply_migration", "execute_sql"]},
    "pre-deploy": {"mcp_tool_denies": ["deploy_edge_function"]}
  }
}'
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
CUR_HOME_SAVE="$CUR_HOME"; CUR_HOME="$FIXTURE_HOME"
PLAN="$(compile_dry_stdout "$R")"
CUR_HOME="$CUR_HOME_SAVE"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
assert_contains_line "T-40: list_tables (outside GATE_OWNERS.mcp_tool_denies) is denied additively" "$RULES" "mcp__supabase__list_tables"
IN_HONORED="$(echo "$PLAN" | jq -r '[.inputs.suppressions_honored[] | select(.tool=="list_tables")] | length')"
IN_WITHHELD="$(echo "$PLAN" | jq -r '[.inputs.suppressions_withheld[] | select(.tool=="list_tables")] | length')"
assert_eq "T-40: list_tables absent from suppressions_honored" "0" "$IN_HONORED"
assert_eq "T-40: list_tables absent from suppressions_withheld" "0" "$IN_WITHHELD"

# ---------------------------------------------------------------------------
# T-41 *(preimage completeness)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H0="$(get_hash "$R")"
KEYS_OK="$(compile_dry_stdout "$R" | jq -r '(.inputs.consent_scope | keys | sort) == ["gates","modes","scoped","v"]')"
assert_eq "T-41: consent_scope keys == {v,modes,scoped,gates} exactly" "true" "$KEYS_OK"

jq '.stack_tier = 3' "$R/.claude/stack-config.json" > "$R/.claude/stack-config.json.tmp" && mv "$R/.claude/stack-config.json.tmp" "$R/.claude/stack-config.json"
assert_eq "T-41: stack_tier is NOT in the preimage" "$H0" "$(get_hash "$R")"

jq '.sensitivity.level = "confidential"' "$R/.claude/stack-config.json" > "$R/.claude/stack-config.json.tmp" && mv "$R/.claude/stack-config.json.tmp" "$R/.claude/stack-config.json"
assert_eq "T-41: sensitivity is NOT in the preimage" "$H0" "$(get_hash "$R")"

jq '.guards = {"script":"true","paths":["**"]}' "$R/.claude/stack-config.json" > "$R/.claude/stack-config.json.tmp" && mv "$R/.claude/stack-config.json.tmp" "$R/.claude/stack-config.json"
assert_eq "T-41: guards is NOT in the preimage" "$H0" "$(get_hash "$R")"

jq '.review = {"foo":"bar"}' "$R/.claude/stack-config.json" > "$R/.claude/stack-config.json.tmp" && mv "$R/.claude/stack-config.json.tmp" "$R/.claude/stack-config.json"
assert_eq "T-41: review.* is NOT in the preimage" "$H0" "$(get_hash "$R")"

Rm="$(new_repo)"; write_cfg "$Rm" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-merge"]'
assert_eq "T-41: pre-merge in required_approvals is NOT in the preimage" "$H0" "$(get_hash "$Rm")"

# ---------------------------------------------------------------------------
# T-42 *(Gap A -- malformed domain_mode_paths VALUE is drift, KEY IS KEPT)*
# ---------------------------------------------------------------------------
for malformed_val in '[]' '"str"' '["a", 42]'; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' "{\"schema-migration\": $malformed_val}" '[]'
  H="$(get_hash "$R")"
  ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
  sidecar_with_acks "$R" "$ACK"
  PLAN="$(compile_dry_stdout "$R")"
  ERR="$(compile_dry_stderr "$R")"
  assert_rc "T-42 (val=$malformed_val): exit 0" 0 "$(compile_dry_rc "$R")"
  assert_contains "T-42 (val=$malformed_val): warning names the key" "$ERR" "schema-migration"
  MALFORMED="$(echo "$PLAN" | jq -c '.inputs.domain_mode_paths_malformed')"
  assert_eq "T-42 (val=$malformed_val): domain_mode_paths_malformed == [schema-migration]" '["schema-migration"]' "$MALFORMED"
  SCOPED="$(echo "$PLAN" | jq -c '.inputs.consent_scope.scoped')"
  assert_eq "T-42 (val=$malformed_val): consent_scope.scoped == [schema-migration] (key survives)" '["schema-migration"]' "$SCOPED"
  RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
  for tool in apply_migration execute_sql deploy_edge_function; do
    assert_contains_line "T-42 (val=$malformed_val): $tool PRESENT despite full ack (clause 2 wins)" "$RULES" "mcp__supabase__$tool"
  done
  CLAUSE="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[0].clause')"
  assert_eq "T-42 (val=$malformed_val): clause is scope-coherence" "scope-coherence" "$CLAUSE"
done
# Routing half (dm_path_matches_mode / dm_scoped_modes): malformed value ==
# always-active for routing (fail-safe), never a routing FAIL.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{"schema-migration":[]}' '[]'
CFGPATH="$R/.claude/stack-config.json"
assert_rc "T-42 (routing): dm_path_matches_mode returns 0 for README.md (malformed value == always-active)" 0 \
  "$(dm_path_matches_mode "$CFGPATH" "schema-migration" "README.md"; echo $?)"
SCOPED_EMPTY="$(dm_scoped_modes "$CFGPATH")"
assert_contains "T-42 (routing): dm_scoped_modes includes schema-migration for the empty file list" "$SCOPED_EMPTY" "schema-migration"
# Companion negative, on the SAME repo/config used in the malformed-value
# loop above (not a fresh unmapped repo -- that would only re-prove T-24).
# Malformed value present -> denies PRESENT (already asserted above for this
# $R). Now delete the domain_mode_paths key ENTIRELY from that same config
# (the widening variant this fix guards against) -> the hash changes
# (scoped: ["schema-migration"] -> []), a fresh ack against the NEW hash
# honors the tool, and the denies must flip to ABSENT. A harness that
# "repaired" a malformed value by silently dropping its key -- instead of
# keeping it scope-incoherent -- would pass the loop above by accident if
# this differential were skipped; asserting the flip on the identical repo
# is what makes it a real regression pin.
jq 'del(.domain_mode_paths["schema-migration"])' "$R/.claude/stack-config.json" > "$R/.claude/stack-config.json.tmp" \
  && mv "$R/.claude/stack-config.json.tmp" "$R/.claude/stack-config.json"
H2="$(get_hash "$R")"
assert_not_contains "T-42 (companion negative): deleting the key changes the hash (scoped goes empty)" "$H2" "$H"
ACK2="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H2")"
sidecar_with_acks "$R" "$ACK2"
RULES2="$(compiled_rules "$R")"
assert_not_contains_line "T-42 (companion negative): removing the malformed key entirely on the SAME repo -> apply_migration flips to absent" "$RULES2" "mcp__supabase__apply_migration"

# ---------------------------------------------------------------------------
# T-43(a,b) *(clause-1 gates are hashed; acks_in_force excludes explicit-gate)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H0="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H0")"
sidecar_with_acks "$R" "$ACK"
write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-schema-change"]'
H1="$(get_hash "$R")"
assert_not_contains "T-43(a): adding pre-schema-change changes the hash" "$H0" "$H1"
PLAN="$(compile_dry_stdout "$R")"
EG="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="apply_migration" or .tool=="execute_sql") | .clause' | sort -u)"
assert_eq "T-43(a): apply_migration/execute_sql withheld explicit-gate" "explicit-gate" "$EG"
DEF_CLAUSE="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[] | select(.tool=="deploy_edge_function") | .clause')"
assert_eq "T-43(a): deploy_edge_function (the control, unaffected by pre-schema-change) is consent-stale" "consent-stale" "$DEF_CLAUSE"
IN_FORCE_EMPTY="$(echo "$PLAN" | jq -r '(.inputs.acks_in_force | map(select(.tool=="apply_migration" or .tool=="execute_sql")) | length) == 0')"
assert_eq "T-43(a): acks_in_force excludes the explicit-gate pairs" "true" "$IN_FORCE_EMPTY"
PRUNABLE_OK="$(echo "$PLAN" | jq -r '
  ([.inputs.acks_prunable[] | select(.tool=="apply_migration" or .tool=="execute_sql") | .why] | sort) == ["explicit-gate","explicit-gate"]')"
assert_eq "T-43(a): acks_prunable lists both explicit-gated pairs with why=explicit-gate" "true" "$PRUNABLE_OK"
DEF_NOT_PRUNABLE="$(echo "$PLAN" | jq -r '[.inputs.acks_prunable[] | select(.tool=="deploy_edge_function")] | length')"
assert_eq "T-43(a): deploy_edge_function (the control) is NOT in acks_prunable (it is promptable)" "0" "$DEF_NOT_PRUNABLE"

# T-43(b): round-trip pin -- add then remove the gate with no skill run in between.
write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H2="$(get_hash "$R")"
assert_eq "T-43(b): removing the gate returns the hash to H0" "$H0" "$H2"
RULES="$(compiled_rules "$R")"
for tool in apply_migration execute_sql deploy_edge_function; do
  assert_not_contains_line "T-43(b): $tool absent again -- the ack is fresh with no prompt needed" "$RULES" "mcp__supabase__$tool"
done

# ---------------------------------------------------------------------------
# T-46 *(determinism under mode-array reorder)*
# ---------------------------------------------------------------------------
R1="$(new_repo)"; write_cfg "$R1" '["deploy","schema-migration"]' '{"schema-migration":["migrations/**"]}' '[]'
R2="$(new_repo)"; write_cfg "$R2" '["schema-migration","deploy"]' '{"schema-migration":["migrations/**"]}' '[]'
STALE_ACK="$(ack_entry "deploy" '["deploy_edge_function"]' "sha256:0000000000000000000000000000000000000000000000000000000000000000")"
sidecar_with_acks "$R1" "$STALE_ACK"
sidecar_with_acks "$R2" "$STALE_ACK"
PLAN1="$(compile_dry_stdout "$R1")"
PLAN2="$(compile_dry_stdout "$R2")"
# inputs.domain_mode is deliberately the RAW config value "echoed verbatim,
# NOT the normalized list" (permissions-compile.sh build_plan comment) -- it
# is EXPECTED to differ by array order and is not part of this claim.
# Everything else in .inputs (consent_scope, consent_scope_hash,
# suppressions_honored[*].by, suppressions_withheld clause/mode/warning
# content, acks_in_force/acks_prunable) must be identical.
INPUTS1="$(echo "$PLAN1" | jq -S '.inputs | del(.domain_mode)')"
INPUTS2="$(echo "$PLAN2" | jq -S '.inputs | del(.domain_mode)')"
assert_eq "T-46: inputs minus the raw domain_mode echo are byte-identical across array reorder" "$INPUTS1" "$INPUTS2"
compile_apply_rc "$R1" >/dev/null
compile_apply_rc "$R2" >/dev/null
DENY1="$(jq -S '.permissions.deny' "$R1/.claude/settings.json")"
DENY2="$(jq -S '.permissions.deny' "$R2/.claude/settings.json")"
assert_eq "T-46: settings.json permissions.deny byte-identical across array reorder" "$DENY1" "$DENY2"
SIDECAR1="$(jq -S '.multi_mode_suppression_ack, .ledger' "$R1/.claude/permissions.stack.json")"
SIDECAR2="$(jq -S '.multi_mode_suppression_ack, .ledger' "$R2/.claude/permissions.stack.json")"
assert_eq "T-46: sidecar (ack + ledger) byte-identical across array reorder" "$SIDECAR1" "$SIDECAR2"

# ---------------------------------------------------------------------------
# T-47 *(report truthfulness when the live-capabilities snapshot is missing)*
# ---------------------------------------------------------------------------
NOSNAP_HOME="$(new_home)"
no_snapshot "$NOSNAP_HOME"
# Multi-mode, unmapped, no ack -- the T-21 scenario, but with no snapshot.
# (A single/arity-1 mode is honored unconditionally regardless of ack --
# T-26's carve-out -- so it would never reach the withheld path at all.)
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
CUR_HOME_SAVE="$CUR_HOME"; CUR_HOME="$NOSNAP_HOME"
PLAN="$(compile_dry_stdout "$R")"
ERR="$(compile_dry_stderr "$R")"
CUR_HOME="$CUR_HOME_SAVE"
DENY_RULES_EMPTY="$(echo "$PLAN" | jq -r '[.inputs.suppressions_withheld[].deny_rules[]] | length == 0')"
assert_eq "T-47: withheld[*].deny_rules == [] when snapshot missing" "true" "$DENY_RULES_EMPTY"
assert_contains "T-47: warning says no MCP rule emitted rather than claiming a deny" "$ERR" "no MCP rule was emitted"
assert_rc "T-47: exit 0" 0 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-51 *(acks_prunable completeness -- representative shapes, compiler-only)*
# ---------------------------------------------------------------------------
# (ii) scope-coherence: mode is mapped (dead glob), ack stale-for-that-mode-vs-hash-mismatch is irrelevant to WHY.
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '{"schema-migration":["nonexistent/**"]}' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration"]' "$H")"
sidecar_with_acks "$R" "$ACK"
WHY="$(compile_dry_stdout "$R" | jq -r '.inputs.acks_prunable[] | select(.tool=="apply_migration") | .why')"
assert_eq "T-51(ii) scope-coherence: prune why is scope-coherence" "scope-coherence" "$WHY"

# (iii) undeclared-mode
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "deploy" '["deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
WHY="$(compile_dry_stdout "$R" | jq -r '.inputs.acks_prunable[] | select(.tool=="deploy_edge_function") | .why')"
assert_eq "T-51(iii) undeclared-mode: prune why is undeclared-mode" "undeclared-mode" "$WHY"

# (iv) not-suppressed (ui-design suppresses nothing)
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "ui-design" '["apply_migration"]' "$H")"
sidecar_with_acks "$R" "$ACK"
WHY="$(compile_dry_stdout "$R" | jq -r '.inputs.acks_prunable[] | select(.tool=="apply_migration" and .mode=="ui-design") | .why')"
assert_eq "T-51(iv) not-suppressed: prune why is not-suppressed" "not-suppressed" "$WHY"

# (v) single-mode: arity-1 with an inherited ack -- the tool is honored
# unconditionally (T-26 carve-out), so the ack does no work and is prunable.
R="$(new_repo)"; write_cfg "$R" '"schema-migration"' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
WHY="$(echo "$PLAN" | jq -r '.inputs.acks_prunable[] | select(.tool=="apply_migration") | .why')"
assert_eq "T-51(v) single-mode: prune why is single-mode" "single-mode" "$WHY"
assert_eq "T-51(v): acks_in_force is empty at arity 1 (never populated -- guarded by \`if multi\`)" "0" "$(echo "$PLAN" | jq '.inputs.acks_in_force | length')"
RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
assert_not_contains_line "T-51(v): apply_migration is still honored (arity-1 carve-out) despite the ack being prunable" "$RULES" "mcp__supabase__apply_migration"

# (i) explicit-gate + partition/containment invariant, over T-43(a)'s rich scenario.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '["pre-schema-change"]'
H="$(get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
PLAN="$(compile_dry_stdout "$R")"
WHY="$(echo "$PLAN" | jq -r '.inputs.acks_prunable[] | select(.tool=="apply_migration") | .why')"
assert_eq "T-51(i) explicit-gate: prune why is explicit-gate" "explicit-gate" "$WHY"
PARTITION_OK="$(echo "$PLAN" | jq -r '
  ((.inputs.suppressions_withheld | map(select(.clause=="consent" or .clause=="consent-stale")) | map({mode,tool})) ) as $promptable
  | (.inputs.acks_in_force | map({mode,tool})) as $in_force
  | (.inputs.acks_prunable | map({mode,tool})) as $prunable
  | (($in_force + $promptable + $prunable) | sort_by(.mode,.tool)) as $covered
  | (($in_force | length) + ($promptable | length) + ($prunable | length)) == ($covered | unique | length)')"
assert_eq "T-51: acks_in_force / promptable / acks_prunable are pairwise disjoint (partition)" "true" "$PARTITION_OK"

# ---------------------------------------------------------------------------
# T-53 *(baseline row 5 -- pre-existing, out of scope, pinned honest)*
# ---------------------------------------------------------------------------
FIX53_HOME="$(new_home)"; write_snapshot "$FIX53_HOME" supabase
write_fixture_baseline "$FIX53_HOME" '{
  "version": "test-row5",
  "floor": {"deny": [], "path_rules": []},
  "domain_overlays": {"schema-migration": {"mcp_tool_denies": ["apply_migration","execute_sql"]},
                       "ui-design": {}, "deploy": {}, "financial-code": {}, "data-operation": {}},
  "sensitivity_overlays": {"normal": {"deny": []}},
  "approval_gate_map": {
    "pre-schema-change": {"mcp_tool_denies": ["apply_migration","execute_sql"]},
    "pre-deploy": {"mcp_tool_denies": []}
  }
}'
for dm in '"schema-migration"' '["ui-design","schema-migration"]'; do
  R="$(new_repo)"; write_cfg "$R" "$dm" '__ABSENT__' '[]'
  CUR_HOME_SAVE="$CUR_HOME"; CUR_HOME="$FIX53_HOME"
  RULES="$(compiled_rules "$R")"
  CUR_HOME="$CUR_HOME_SAVE"
  assert_not_contains_line "T-53 (domain_mode=$dm): deploy_edge_function absent entirely (approval_gate_map lost it, no overlay lists it -- pre-existing ADR-044 behavior, NOT fixed here)" "$RULES" "mcp__supabase__deploy_edge_function"
done

# ---------------------------------------------------------------------------
# T-54 *(sidecar root is never fatal -- valid JSON, wrong shape)*
# ---------------------------------------------------------------------------
for root in '[]' '[1,2,3]' '"x"' '42' 'true'; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  write_sidecar_json "$R" "$root"
  rc="$(compile_dry_rc "$R")"
  err="$(compile_dry_stderr "$R")"
  rules="$(compiled_rules "$R")"
  assert_rc "T-54 (root=$root): exit 0" 0 "$rc"
  assert_not_contains "T-54 (root=$root): no traceback / AttributeError" "$err" "Error"
  assert_contains "T-54 (root=$root): a warning names the root shape (truthy non-dict)" "$err" "root is not an object"
  assert_contains_line "T-54 (root=$root): apply_migration falls through to consent, deny present" "$rules" "mcp__supabase__apply_migration"
done
# root == null: falls through SILENTLY (sidecar is None, not truthy) -- no
# warning, distinct from the truthy non-dict roots above.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
write_sidecar_json "$R" 'null'
err_null="$(compile_dry_stderr "$R")"
assert_not_contains "T-54 (root=null): no 'root is not an object' warning (null is treated as absent, not a truthy bad root)" "$err_null" "root is not an object"
assert_rc "T-54 (root=null): exit 0" 0 "$(compile_dry_rc "$R")"

# ---------------------------------------------------------------------------
# T-55 *(validate_domain_mode_paths full case matrix, incl. both-orphan-and-malformed)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '{"deploy":[]}' '[]'
PLAN="$(compile_dry_stdout "$R")"
ERR="$(compile_dry_stderr "$R")"
assert_rc "T-55: a key that is BOTH orphan (deploy not declared) AND malformed ([] value) -> exit 0" 0 "$(compile_dry_rc "$R")"
assert_eq "T-55: appears in domain_mode_paths_ignored" '["deploy"]' "$(echo "$PLAN" | jq -c '.inputs.domain_mode_paths_ignored')"
assert_eq "T-55: appears in domain_mode_paths_malformed" '["deploy"]' "$(echo "$PLAN" | jq -c '.inputs.domain_mode_paths_malformed')"
assert_contains "T-55: both warnings present (orphan)" "$ERR" "not declared in"
assert_contains "T-55: both warnings present (malformed)" "$ERR" "not a non-empty array"

# ---------------------------------------------------------------------------
# T-56 *(reconcile regrouping and duplicates)* -- BUCKET C CONTRACT SIMULATION.
# The reconcile (keep-set A ∪ B, provenance-tuple regrouping) is skill prose
# (skills/domain-mode/SKILL.md step 7), not an executable function. This
# implements the documented algorithm faithfully and checks it against the
# spec's own worked cases; it does NOT exercise the real skill.
# ---------------------------------------------------------------------------
reconcile_sim() {
  # reconcile_sim <entries-json-array> -- entries: [{mode,tool,date,by,reason}]
  # Group identical (mode,tool) claims; on a duplicate, the lexicographically
  # smallest (date,by,reason) wins. Then regroup survivors by
  # (mode,date,by,reason) into ack objects with a tools[] array.
  python3 - "$1" <<'PY'
import sys, json
entries = json.loads(sys.argv[1])
winners = {}
for e in entries:
    key = (e["mode"], e["tool"])
    prov = (e["date"], e["by"], e["reason"])
    if key not in winners or prov < winners[key][0]:
        winners[key] = (prov, e)
groups = {}
for (mode, tool), (prov, e) in winners.items():
    groups.setdefault((mode,) + prov, []).append(tool)
out = []
for (mode, date, by, reason), tools in sorted(groups.items()):
    out.append({"mode": mode, "tools": sorted(tools), "date": date, "by": by, "reason": reason})
print(json.dumps(out, sort_keys=True))
PY
}
ENTRIES_A="$(jq -n -c '[
  {mode:"X",tool:"t1",date:"2026-01-01",by:"human",reason:"old"},
  {mode:"X",tool:"t2",date:"2026-08-01",by:"human",reason:"new"}
]')"
OUT_A="$(reconcile_sim "$ENTRIES_A")"
assert_eq "T-56(a): two entries for mode X (different tools) both survive, byte-identical provenance each" \
  '[{"by": "human", "date": "2026-01-01", "mode": "X", "reason": "old", "tools": ["t1"]}, {"by": "human", "date": "2026-08-01", "mode": "X", "reason": "new", "tools": ["t2"]}]' "$OUT_A"

ENTRIES_B="$(jq -n -c '[
  {mode:"X",tool:"t1",date:"2026-08-02",by:"human",reason:"z"},
  {mode:"X",tool:"t1",date:"2026-01-01",by:"human",reason:"a"}
]')"
OUT_B="$(reconcile_sim "$ENTRIES_B")"
N_B="$(echo "$OUT_B" | jq 'length')"
assert_eq "T-56(b): duplicate (X,t1) claim from two source entries survives exactly once" "1" "$N_B"
DATE_B="$(echo "$OUT_B" | jq -r '.[0].date')"
assert_eq "T-56(b): the lexicographically smallest (date,by,reason) wins" "2026-01-01" "$DATE_B"

OUT_A2="$(reconcile_sim "$ENTRIES_A")"
assert_eq "T-56(d): reconcile is idempotent -- running twice on the same input is byte-identical" "$OUT_A" "$OUT_A2"

# ---------------------------------------------------------------------------
# T-57 *(classify_suppressions return-shape completeness -- real compiler output)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration","deploy"]' '__ABSENT__' '[]'
H="$(get_hash "$R")"
ACK1="$(ack_entry "schema-migration" '["execute_sql"]' "$H")"
ACK2="$(ack_entry "deploy" '["deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK1" "$ACK2"
PLAN="$(compile_dry_stdout "$R")"
HONORED_SHAPE_OK="$(echo "$PLAN" | jq -r '
  all(.inputs.suppressions_honored[]; (.by | length) > 0 and (.by == (.by | sort)) and (.deny_rules_removed != null) and (.tool != null))')"
assert_eq "T-57: every suppressions_honored entry has {tool,by(sorted,nonempty),deny_rules_removed}" "true" "$HONORED_SHAPE_OK"
WITHHELD_SHAPE_OK="$(echo "$PLAN" | jq -r '
  all(.inputs.suppressions_withheld[]; has("tool") and has("clause") and has("mode") and has("modes") and has("deny_rules") and has("fix"))')"
assert_eq "T-57: every suppressions_withheld entry has {tool,clause,mode,modes,deny_rules,fix}" "true" "$WITHHELD_SHAPE_OK"
CROSS_CHECK_1="$(echo "$PLAN" | jq -r '
  . as $root
  | ($root.inputs.acks_in_force | all(. as $p | ($p.mode as $m | $p.tool as $t |
      ([$root.inputs.suppressions_honored[]? | select(.tool==$t) | .by[]] | index($m)) != null)))')"
assert_eq "T-57: every acks_in_force pair tool appears in suppressions_honored with that mode in by" "true" "$CROSS_CHECK_1"

# ---------------------------------------------------------------------------
# T-60 *(consent is server-set independent -- designed property, pinned; compiler-only half)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
S60_HOME="$(new_home)"; write_snapshot "$S60_HOME" supabase
H="$(CUR_HOME="$S60_HOME" get_hash "$R")"
ACK="$(ack_entry "schema-migration" '["apply_migration","execute_sql","deploy_edge_function"]' "$H")"
sidecar_with_acks "$R" "$ACK"
CUR_HOME_SAVE="$CUR_HOME"; CUR_HOME="$S60_HOME"
RULES_1="$(compiled_rules "$R")"
HASH_1="$(get_hash "$R")"
CUR_HOME="$CUR_HOME_SAVE"
assert_not_contains_line "T-60: apply_migration absent on the original server set" "$RULES_1" "mcp__supabase__apply_migration"
write_snapshot "$S60_HOME" supabase supabase_staging
CUR_HOME="$S60_HOME"
RULES_2="$(compiled_rules "$R")"
ERR_2="$(compile_dry_stderr "$R")"
HASH_2="$(get_hash "$R")"
CUR_HOME="$CUR_HOME_SAVE"
assert_not_contains_line "T-60: mcp__supabase_staging__apply_migration ALSO absent -- honored on the new server too, no reprompt" "$RULES_2" "mcp__supabase_staging__apply_migration"
assert_eq "T-60: consent_scope_hash unchanged by a server-set change" "$HASH_1" "$HASH_2"
assert_not_contains "T-60: no new warning fires for apply_migration on the server-set change" "$ERR_2" "apply_migration' stays denied"

# ---------------------------------------------------------------------------
# T-62(a) *(single construction site for UNCONDITIONAL_TOOLS -- structural)*
# ---------------------------------------------------------------------------
N_CONSTRUCT="$(grep -c 'unconditional_tools.add(tool)' "$COMPILE")"
assert_eq "T-62(a): UNCONDITIONAL_TOOLS is built at exactly one call site" "1" "$N_CONSTRUCT"
SAME_OBJ="$(grep -c '"unconditional_tools": unconditional_tools' "$COMPILE")"
assert_eq "T-62(a): gates_ctx.unconditional_tools is the SAME object passed to classify_suppressions (not re-derived)" "1" "$SAME_OBJ"

# ---------------------------------------------------------------------------
# T-63 *(cross-process inputs determinism)*
# ---------------------------------------------------------------------------
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration","deploy","financial-code","data-operation"]' '__ABSENT__' '[]'
S63_HOME="$(new_home)"; write_snapshot "$S63_HOME" supabase stripe cloudflare neon
H="$(CUR_HOME="$S63_HOME" get_hash "$R")"
ACK1="$(ack_entry "schema-migration" '["apply_migration"]' "$H")"
ACK2="$(ack_entry "deploy" '["deploy_edge_function"]' "sha256:stale00000000000000000000000000000000000000000000000000000000")"
sidecar_with_acks "$R" "$ACK1" "$ACK2"
CUR_HOME_SAVE="$CUR_HOME"
OUT_SEED0="$(CUR_HOME="$S63_HOME" PYTHONHASHSEED=0 compile_dry_stdout "$R")"
OUT_SEED1="$(CUR_HOME="$S63_HOME" PYTHONHASHSEED=1 compile_dry_stdout "$R")"
OUT_SEEDR="$(CUR_HOME="$S63_HOME" PYTHONHASHSEED=random compile_dry_stdout "$R")"
CUR_HOME="$CUR_HOME_SAVE"
assert_eq "T-63(a): inputs deep-equal across PYTHONHASHSEED=0 vs 1" \
  "$(echo "$OUT_SEED0" | jq -S '.inputs')" "$(echo "$OUT_SEED1" | jq -S '.inputs')"
assert_eq "T-63(a): inputs deep-equal across PYTHONHASHSEED=1 vs random" \
  "$(echo "$OUT_SEED1" | jq -S '.inputs')" "$(echo "$OUT_SEEDR" | jq -S '.inputs')"

# T-63(b) structural: every construction site for a field that reaches
# plan["inputs"] must use sorted(...), not bare set/list iteration order.
# (plan["inputs"] itself is never assigned by subscript -- the dict is built
# as a literal in build_plan's return -- so grepping for that assignment
# shape would match nothing whether the code is correct or not; pin the
# actual per-field construction sites instead.)
assert_grep_compile() { grep -qF -- "$2" "$COMPILE" && pass "$1" || fail "$1 (not found: $2)"; }
assert_grep_compile "T-63(b): acks_in_force is sorted at its construction site" 'sorted(in_force, key=pair_key)'
assert_grep_compile "T-63(b): acks_prunable is sorted at its construction site" 'sorted(dead, key=lambda p: (p[1], p[0]))'
assert_grep_compile "T-63(b): suppressions_honored[*].by is sorted at its construction site" 'sorted(e["by"])'
assert_grep_compile "T-63(b): mcp_servers is sorted+deduped at its construction site" 'servers = sorted({'
GET_RETURN="$(sed -n '335,378p' "$COMPILE")"
assert_contains "T-63(b): domain_mode_paths_ignored/_malformed are returned as literal lists built via append, not an unsorted set" "$GET_RETURN" "return ignored, malformed"
HAS_HONORED_TOOLS="$(compile_dry_stdout "$R" | jq -r 'has("honored_tools") or (.inputs | has("honored_tools")) or (.inputs | has("honored"))')"
assert_eq "T-63(b): the one raw set (honored_tools/honored) never reaches inputs (would also crash json.dumps if it did)" "false" "$HAS_HONORED_TOOLS"

# T-63(c) negative: an unsorted-set-derived field WOULD vary across hash
# seeds -- proving this methodology is actually sensitive, not a fluke of
# a small fixture. Demonstrated against a standalone replica, NOT the real
# compiler (which is why (a) above is the real regression pin, not this).
UNSORTED_VARIES=0
for seed in 0 1 2 3; do
  OUT="$(PYTHONHASHSEED=$seed python3 -c 'print(list({"zeta","alpha","mu","beta","gamma"}))')"
  if [[ -z "${FIRST_UNSORTED:-}" ]]; then FIRST_UNSORTED="$OUT"; elif [[ "$OUT" != "$FIRST_UNSORTED" ]]; then UNSORTED_VARIES=1; fi
done
if [[ "$UNSORTED_VARIES" -eq 1 ]]; then
  pass "T-63(c): an unsorted set-derived field DOES vary across hash seeds (methodology sanity check)"
else
  echo "SKIP: T-63(c): this Python/platform did not exhibit hash-seed-dependent set order in 4 samples (non-deterministic to demonstrate, not a suite failure)"
fi

# ---------------------------------------------------------------------------
# T-65 *(the sidecar is never fatal to READ -- invalid JSON syntax)*
# T-66(d) *(bare-CLI surface: the warning is what covers it)* folded in here
# -- same fixtures, same compile invocation, the verbatim message assertion.
# ---------------------------------------------------------------------------
write_t65_fixture() {
  # write_t65_fixture <repo> <fixture-name>
  local r="$1" name="$2"
  local f="$r/.claude/permissions.stack.json"
  case "$name" in
    trailing_comma)   printf '{"multi_mode_suppression_ack": [1,],}' > "$f" ;;
    unclosed_brace)   printf '{"multi_mode_suppression_ack": [' > "$f" ;;
    unquoted_key)     printf '{multi_mode_suppression_ack: []}' > "$f" ;;
    bad_escape)       printf '{"a": "\\x"}' > "$f" ;;
    zero_byte)        : > "$f" ;;
    non_utf8)         printf '\xff\xfe\x00\x01' > "$f" ;;
  esac
}

for fixture in trailing_comma unclosed_brace unquoted_key bad_escape zero_byte non_utf8; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  write_t65_fixture "$R" "$fixture"
  PLAN="$(compile_dry_stdout "$R")"
  ERR="$(compile_dry_stderr "$R")"
  RC="$(compile_dry_rc "$R")"
  assert_rc "T-65(a) [$fixture]: report path exit 0" 0 "$RC"
  PLAN_VALID="$(echo "$PLAN" | jq empty >/dev/null 2>&1 && echo yes || echo no)"
  assert_eq "T-65(a) [$fixture]: stdout is a valid JSON plan" "yes" "$PLAN_VALID"
  N_WARN="$(printf '%s\n' "$ERR" | grep -c "not valid JSON or is unreadable")"
  assert_eq "T-65(a) [$fixture]: exactly one 'not valid JSON or unreadable' warning" "1" "$N_WARN"
  assert_not_contains "T-65(a) [$fixture]: no traceback" "$ERR" "Traceback"
  assert_eq "T-65(a) [$fixture]: acks_in_force == []" "0" "$(echo "$PLAN" | jq '.inputs.acks_in_force | length')"
  assert_eq "T-65(a) [$fixture]: acks_prunable == []" "0" "$(echo "$PLAN" | jq '.inputs.acks_prunable | length')"
  CLAUSES="$(echo "$PLAN" | jq -r '.inputs.suppressions_withheld[].clause' | sort -u)"
  assert_eq "T-65(a) [$fixture]: every suppression withheld with clause consent" "consent" "$CLAUSES"
  RULES="$(echo "$PLAN" | jq -r '.compiled_deny[].rule')"
  assert_contains_line "T-65(a) [$fixture]: apply_migration deny present" "$RULES" "mcp__supabase__apply_migration"
  assert_contains "T-66(d): stderr contains the verbatim REPORT-ONLY degradation clause [$fixture]" "$ERR" \
    "this is a REPORT-ONLY degradation: a real apply will REFUSE, and will write neither settings.json nor the sidecar, until this file is fixed or removed"
done

# T-65(b): waivers degrade the same way, strictly stronger than the parsing case.
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
jq -n '{waivers:[{rule:"Bash(psql:*)"}]}' > "$R/.claude/permissions.stack.json"
PLAN_OK="$(compile_dry_stdout "$R")"
WAIVED_OK="$(echo "$PLAN_OK" | jq -r '.waived_count')"
assert_eq "T-65(b): waiver honored when the sidecar parses (baseline for the comparison)" "1" "$WAIVED_OK"
RULES_OK="$(echo "$PLAN_OK" | jq -r '.compiled_deny[].rule')"
assert_not_contains_line "T-65(b): the waived rule is absent while the sidecar parses" "$RULES_OK" "Bash(psql:*)"
printf '{"waivers": [' > "$R/.claude/permissions.stack.json"
PLAN_BROKEN="$(compile_dry_stdout "$R")"
assert_eq "T-65(b): waived_count == 0 once the sidecar is corrupted" "0" "$(echo "$PLAN_BROKEN" | jq -r '.waived_count')"
RULES_BROKEN="$(echo "$PLAN_BROKEN" | jq -r '.compiled_deny[].rule')"
assert_contains_line "T-65(b): the previously-waived rule is BACK in compiled_deny" "$RULES_BROKEN" "Bash(psql:*)"
jq -n '{waivers:[{rule:"Bash(psql:*)"}]}' > "$R/.claude/permissions.stack.json"
RULES_REPAIRED="$(compiled_rules "$R")"
assert_not_contains_line "T-65(b): repairing the file restores the waiver on the next compile" "$RULES_REPAIRED" "Bash(psql:*)"

# T-65(c) / T-66(d): write path refuses; nothing half-lands; no backup file.
for fixture in trailing_comma zero_byte non_utf8; do
  R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
  compile_apply_rc "$R" >/dev/null   # establish a real prior settings.json
  SETTINGS_BEFORE="$(cat "$R/.claude/settings.json" 2>/dev/null)"
  write_t65_fixture "$R" "$fixture"
  SIDECAR_BEFORE="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null | base64)"
  RC="$(compile_apply_rc "$R")"
  ERR="$(compile_apply_stderr "$R")"
  assert_not_contains "T-65(c) [$fixture]: real apply refuses (non-zero exit)" "0" "$RC"
  SETTINGS_AFTER="$(cat "$R/.claude/settings.json" 2>/dev/null)"
  SIDECAR_AFTER="$(cat "$R/.claude/permissions.stack.json" 2>/dev/null | base64)"
  assert_eq "T-65(c) [$fixture]: settings.json byte-identical to before the failed apply" "$SETTINGS_BEFORE" "$SETTINGS_AFTER"
  assert_eq "T-65(c) [$fixture]: the broken sidecar is byte-identical (human bytes preserved, not overwritten)" "$SIDECAR_BEFORE" "$SIDECAR_AFTER"
  assert_not_contains "T-65(c) [$fixture]: no traceback in the refusal message" "$ERR" "Traceback"
  N_BACKUP_FILES="$(find "$R/.claude" -name '*.bak*' -o -name '*.quarantine*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "T-65(c) [$fixture]: no backup/quarantine file created" "0" "$N_BACKUP_FILES"
done

# T-65(e): the three absent-file directions differ deliberately.
EMPTY_HOME="$(new_home)"   # no baseline anywhere CLAUDE_PLUGIN_ROOT resolves to, and no CLAUDE_PLUGIN_ROOT fallback
R="$(new_repo)"; write_cfg "$R" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
NOBASELINE_RC="$(HOME="$EMPTY_HOME" CLAUDE_PLUGIN_ROOT="$EMPTY_HOME/does-not-exist" bash "$COMPILE" --scope project --repo-root "$R" --dry-run --json >/dev/null 2>&1; echo $?)"
assert_rc "T-65(e): baseline absent -> exit 3" 3 "$NOBASELINE_RC"

R2="$(new_repo)"   # no stack-config.json written at all
NOCFG_RC="$(compile_dry_rc "$R2")"
assert_rc "T-65(e): stack-config.json absent -> exit 2 (refused, not exit 3)" 2 "$NOCFG_RC"

R3="$(new_repo)"; write_cfg "$R3" '["ui-design","schema-migration"]' '__ABSENT__' '[]'
NOSNAP_HOME2="$(new_home)"; no_snapshot "$NOSNAP_HOME2"
NOSNAP_RC="$(CUR_HOME="$NOSNAP_HOME2" compile_dry_rc "$R3")"
assert_rc "T-65(e): live-capabilities snapshot absent -> exit 0 (tolerated)" 0 "$NOSNAP_RC"

echo "----------------------------------------"
echo "domain-mode-multi (ADR-053 BUCKET A): $PASS passed, $FAIL failed"
echo "Not covered here (skill-flow prose, or genuinely infeasible without executing an LLM agent):"
echo "  T-19, T-20, T-23, T-31(a), T-32, T-35, T-38, T-43(the /sensitivity leg), T-44,"
echo "  T-45, T-48, T-52(companion-positive skill leg), T-58, T-59(b/c skill legs),"
echo "  T-60(hook off-ramp sub-legs), T-61, T-66(a,b,e,f,g) -- see"
echo "  tests/test-domain-mode-skills-docs.sh (BUCKET B) and the tester report for the map."
echo "T-49, T-50, T-64 and T-66(c) -- the real concurrency cases this bucket could not exercise"
echo "  single-process -- are covered by tests/test-domain-mode-concurrency.sh (BUCKET D),"
echo "  which forks REAL second processes against a throwaway fixture repo."
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
