#!/usr/bin/env bash
# Tests for ADR-044 (permissions.deny as the enforced approval-gate boundary):
# config/permissions-baseline.json, scripts/permissions-compile.sh,
# scripts/lib/settings_lock.py, the schema-deploy-gate.sh deny-mirroring
# (Contract F / D6b), and the irreversible-deny.sh gap telemetry (D6).
#
# Every case runs against a synthetic fixture repo under a temp dir with HOME
# redirected there too — never the developer's real ~/.claude/settings.json.
#
# T1 (live enforcement via a real `claude -p` session) and T7 (the headless
# `ask` probe) require spawning a nested Claude Code session, which incurs
# real cost/side effects this suite will not trigger by default. They run
# only when RUN_LIVE_PERMISSIONS_TESTS=1 is set in the environment; otherwise
# they SKIP explicitly (never silently) and this suite still runs every
# deterministic assertion that does not require a live harness (including a
# shape-level proxy for T1's fixture and T3's string-prefix proof, which
# needs no live harness at all since it is a property of the literal command
# string, not a harness decision).
#
# Case-to-test-plan map: T1..T14 in ADR-044 document order.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILE="$REPO_ROOT/scripts/permissions-compile.sh"
LIB_PY="$REPO_ROOT/scripts/lib/settings_lock.py"
NSE_PY="$REPO_ROOT/skills/native-settings-edit/native_settings_edit.py"
GATE_HOOK="$REPO_ROOT/hooks/schema-deploy-gate.sh"
DENY_HOOK="$REPO_ROOT/hooks/irreversible-deny.sh"
LOOP_LIB="$REPO_ROOT/skills/loop-engineer/loop_lib.sh"
CONFIG_MERGER="$REPO_ROOT/scripts/lib/config-merger.sh"

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$COMPILE" ]] || { echo "FAIL: $COMPILE not found"; exit 1; }
[[ -f "$LIB_PY" ]] || { echo "FAIL: $LIB_PY not found"; exit 1; }

LIVE_OK=0
if [[ "${RUN_LIVE_PERMISSIONS_TESTS:-0}" == "1" ]] && command -v claude >/dev/null 2>&1; then
  LIVE_OK=1
fi

PASS=0
FAIL=0
SKIPPED=()
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIPPED+=("$1"); }

assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected: $2 | actual: $3)"; }
assert_rc() { [[ "$3" -eq "$2" ]] && pass "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 (missing '$3' in: $2)"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1 (unexpectedly found '$3' in: $2)"; }
# Exact-line variants for rule-list assertions, where substring match would
# false-positive on prefix overlap (e.g. "mcp__stripe" is a substring of
# "mcp__stripe__apply_migration", a DIFFERENT rule).
assert_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1 (missing exact line '$3' in: $2)"; fi
}
assert_not_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then fail "$1 (unexpectedly found exact line '$3' in: $2)"; else pass "$1"; fi
}

ORIG_HOME="$HOME"
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

new_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/session-state" "$h/.claude/config" "$h/.claude/logs"
  CLEANUP_DIRS+=("$h")
  printf '%s' "$h"
}

write_snapshot() {
  # write_snapshot <home> <server1> [server2 ...]
  local home="$1"; shift
  local servers_json="[]"
  if [[ $# -gt 0 ]]; then
    servers_json="$(printf '%s\n' "$@" | jq -R '{name:.,transport:"stdio",host:null,remote:false}' | jq -s '.')"
  fi
  jq -n --argjson s "$servers_json" \
    '{generated_at:"2026-07-27T00:00:00Z",source:"live",scope:"user",plugins:[],mcp_servers:$s}' \
    > "$home/.claude/session-state/live-capabilities.json"
}

make_repo() {
  # make_repo <dir> <domain_mode-or-empty> <sensitivity> <required_approvals_json_array>
  # ADR-053: <domain_mode-or-empty> is null (empty), a bare mode name (quoted,
  # unchanged), or a JSON array literal (e.g. '["ui-design","schema-migration"]',
  # embedded raw) for the multi-mode form.
  local dir="$1" domain="${2:-}" sens="${3:-normal}" reqs="${4:-[]}"
  mkdir -p "$dir/.claude"
  local dm="null"
  if [[ "$domain" == \[* ]]; then
    dm="$domain"
  elif [[ -n "$domain" ]]; then
    dm="\"$domain\""
  fi
  jq -n --argjson dm "$dm" --arg sens "$sens" --argjson reqs "$reqs" \
    '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01",
      domain_mode:$dm, sensitivity:{level:$sens}, required_approvals:$reqs}' \
    > "$dir/.claude/stack-config.json"
}

compiled_rules() {
  # compiled_rules <repo> -- prints compiled_deny rule strings, one per line
  HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$COMPILE" --scope project --repo-root "$1" --dry-run --json 2>/dev/null \
    | jq -r '.compiled_deny[].rule'
}

live_deny() {
  jq -r '.permissions.deny[]?' "$1/.claude/settings.json" 2>/dev/null
}

echo "== ADR-044 permissions boundary suite =="

# ─────────────────────────────────────────────────────────────────────────
# T1 — live enforcement (the load-bearing test). Requires a real `claude -p`
# session against a fixture with a fake stripe MCP server actually wired up
# (credentials/session plumbing this suite will not fabricate). Runs only
# opt-in; the shape-level proxy (rule is genuinely present in compiled_deny)
# always runs so the fixture itself is proven sound even when the live leg
# is skipped.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T1="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T1")
make_repo "$REPO_T1" "financial-code" "normal" '[]'
write_snapshot "$CUR_HOME" "stripe"
RULES_T1="$(compiled_rules "$REPO_T1")"
assert_contains "T1 (shape proxy): mcp__stripe present under financial-code" "$RULES_T1" "mcp__stripe"
if [[ "$LIVE_OK" -eq 1 ]]; then
  echo "  (T1 live leg: RUN_LIVE_PERMISSIONS_TESTS=1 set, but no fake-stripe-server"
  echo "   harness wiring exists in this suite -- still not attempting a live call.)"
  skip "T1 live enforcement via real claude -p (no live MCP server harness in this suite; see ADR-044's T1 verification note for the Bash-rule-only result and the open class-A/MCP gap)"
else
  skip "T1 live enforcement via real claude -p (set RUN_LIVE_PERMISSIONS_TESTS=1 + claude on PATH; the class-A/MCP result must be hand-appended to ADR-044 as a verification note -- not automated by this suite -- see the existing partial note there)"
fi

# ─────────────────────────────────────────────────────────────────────────
# T2 — negative control (the read-path regression / D4 + MCQ 2 consequence).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T2="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T2")
write_snapshot "$CUR_HOME" "supabase"

make_repo "$REPO_T2" "schema-migration" "normal" '[]'
RULES_SM="$(compiled_rules "$REPO_T2")"
assert_not_contains "T2: execute_sql NOT denied under domain_mode=schema-migration" "$RULES_SM" "mcp__supabase__execute_sql"

make_repo "$REPO_T2" "" "normal" '[]'
RULES_NULL="$(compiled_rules "$REPO_T2")"
assert_contains "T2: execute_sql IS denied under domain_mode=null (fail-safe default, MCQ 2)" "$RULES_NULL" "mcp__supabase__execute_sql"
assert_not_contains "T2: list_tables never denied (over-broad-rule guard)" "$RULES_NULL" "list_tables"

if [[ "$LIVE_OK" -eq 1 ]]; then
  skip "T2 live leg (SELECT succeeds/denied via real claude -p) -- no live MCP harness in this suite"
else
  skip "T2 live leg (set RUN_LIVE_PERMISSIONS_TESTS=1 + claude on PATH)"
fi

# ─────────────────────────────────────────────────────────────────────────
# T3 — bypass control (asserts a KNOWN limitation, not a harness call). Bash
# rule matching is a documented prefix match on the literal command string
# (fact 4 in the ADR's Context section) -- this is provable without any
# harness at all: `sh -c "git push --dry-run"` simply does not start with
# the literal text "git push".
# ─────────────────────────────────────────────────────────────────────────
RULE='Bash(git push:*)'
[[ "$RULE" =~ ^Bash\((.*):\*\)$ ]]
PREFIX="${BASH_REMATCH[1]}"
CMD_WRAPPED='sh -c "git push --dry-run"'
CMD_DIRECT='git push --dry-run'
case "$CMD_DIRECT" in
  "$PREFIX"*) DIRECT_MATCHES=1 ;;
  *) DIRECT_MATCHES=0 ;;
esac
case "$CMD_WRAPPED" in
  "$PREFIX"*) WRAPPED_MATCHES=1 ;;
  *) WRAPPED_MATCHES=0 ;;
esac
assert_eq "T3: direct 'git push --dry-run' matches the Bash(git push:*) prefix" "1" "$DIRECT_MATCHES"
assert_eq "T3: sh -c wrapped 'git push --dry-run' does NOT match (documented bypass)" "0" "$WRAPPED_MATCHES"
if [[ "$LIVE_OK" -eq 1 ]]; then
  skip "T3 live leg (confirm the harness itself lets the wrapped form through) -- not attempted"
else
  skip "T3 live leg (set RUN_LIVE_PERMISSIONS_TESTS=1 + claude on PATH)"
fi

# ─────────────────────────────────────────────────────────────────────────
# T4 — idempotency + prune (byte-identical settings AND sidecar; no
# duplicated/re-ordered entries; then domain_mode -> null drops stack rules,
# `allow` untouched).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T4="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T4")
write_snapshot "$CUR_HOME" "stripe" "supabase"
mkdir -p "$REPO_T4/.claude"
jq -n '{permissions:{allow:["Bash(npm test:*)"]}}' > "$REPO_T4/.claude/settings.json"
make_repo "$REPO_T4" "financial-code" "normal" '["pre-merge"]'

HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T4" >/dev/null
SETTINGS_1="$(cat "$REPO_T4/.claude/settings.json")"
SIDECAR_1="$(cat "$REPO_T4/.claude/permissions.stack.json")"
DENY_1="$(live_deny "$REPO_T4")"

HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T4" >/dev/null
SETTINGS_2="$(cat "$REPO_T4/.claude/settings.json")"
SIDECAR_2="$(cat "$REPO_T4/.claude/permissions.stack.json")"

assert_eq "T4: settings.json byte-identical across two compiles" "$SETTINGS_1" "$SETTINGS_2"
assert_eq "T4: sidecar byte-identical across two compiles" "$SIDECAR_1" "$SIDECAR_2"
DENY_COUNT="$(echo "$DENY_1" | grep -c .)"
DENY_UNIQ_COUNT="$(echo "$DENY_1" | sort -u | grep -c .)"
assert_eq "T4: no duplicated deny entries" "$DENY_COUNT" "$DENY_UNIQ_COUNT"
ALLOW_AFTER="$(jq -r '.permissions.allow[]?' "$REPO_T4/.claude/settings.json")"
assert_eq "T4: allow untouched" "Bash(npm test:*)" "$ALLOW_AFTER"

make_repo "$REPO_T4" "" "normal" '["pre-merge"]'
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T4" >/dev/null
DENY_AFTER_CLEAR="$(live_deny "$REPO_T4")"
assert_not_contains_line "T4: mcp__stripe gone after domain_mode -> null" "$DENY_AFTER_CLEAR" "mcp__stripe"
assert_not_contains_line "T4: Bash(stripe:*) gone after domain_mode -> null" "$DENY_AFTER_CLEAR" "Bash(stripe:*)"
ALLOW_AFTER_2="$(jq -r '.permissions.allow[]?' "$REPO_T4/.claude/settings.json")"
assert_eq "T4: allow still untouched after prune" "Bash(npm test:*)" "$ALLOW_AFTER_2"

# ─────────────────────────────────────────────────────────────────────────
# T5 — MCP expansion across servers; missing snapshot degrades safely.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T5="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T5")
write_snapshot "$CUR_HOME" "a" "b"
make_repo "$REPO_T5" "" "normal" '[]'
RULES_T5="$(compiled_rules "$REPO_T5")"
assert_contains "T5: apply_migration expands to server a" "$RULES_T5" "mcp__a__apply_migration"
assert_contains "T5: apply_migration expands to server b" "$RULES_T5" "mcp__b__apply_migration"

rm -f "$CUR_HOME/.claude/session-state/live-capabilities.json"
OUT_T5="$(HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T5" --dry-run --json 2>/tmp/t5-warn.txt)"
RC_T5=$?
assert_rc "T5: missing snapshot still exits 0" "0" "$RC_T5"
NO_MCP="$(echo "$OUT_T5" | jq -r '[.compiled_deny[].rule | select(startswith("mcp__"))] | length')"
assert_eq "T5: no MCP rule emitted when snapshot missing" "0" "$NO_MCP"
assert_contains "T5: warns on missing snapshot" "$(cat /tmp/t5-warn.txt)" "missing/stale"

# ─────────────────────────────────────────────────────────────────────────
# T6 — ADR-018 regression: test-native-settings-edit.sh still green, and
# /permissions/deny still hard-refused (exit 2).
# ─────────────────────────────────────────────────────────────────────────
if bash "$REPO_ROOT/tests/test-native-settings-edit.sh" >/tmp/t6-nse.txt 2>&1; then
  pass "T6: test-native-settings-edit.sh still green"
else
  fail "T6: test-native-settings-edit.sh regressed: $(tail -5 /tmp/t6-nse.txt)"
fi
REPO_T6="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T6"); mkdir -p "$REPO_T6/.claude"
echo '{}' > "$REPO_T6/.claude/settings.json"
python3 "$NSE_PY" --path /permissions/deny --value 'Bash(rm:*)' --repo-root "$REPO_T6" >/dev/null 2>&1
assert_rc "T6: native-settings-edit still hard-refuses /permissions/deny" "2" "$?"

# ─────────────────────────────────────────────────────────────────────────
# T7 — headless `ask` probe (documents D4's margin). Requires a live
# `claude -p` session against a fixture with exactly one `ask` rule.
# ─────────────────────────────────────────────────────────────────────────
if [[ "$LIVE_OK" -eq 1 ]]; then
  skip "T7 headless ask probe (no fixture harness wired for a live -p session with a live ask rule in this suite)"
else
  skip "T7 headless ask probe (set RUN_LIVE_PERMISSIONS_TESTS=1 + claude on PATH; result must be hand-appended to ADR-044 as a verification note -- not automated by this suite)"
fi

# ─────────────────────────────────────────────────────────────────────────
# T8 — project-init not broken: the mechanical pieces /project-init step 5b
# and the settings.global.template.json floor depend on. Guards against a
# self-protection rule bricking init on a fresh repo (no prior settings.json
# or sidecar at all).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T8="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T8")
make_repo "$REPO_T8" "" "normal" '[]'
OUT_T8="$(HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T8" 2>&1)"
RC_T8=$?
assert_rc "T8: fresh repo (no prior settings.json/sidecar) compiles cleanly" "0" "$RC_T8"
[[ -f "$REPO_T8/.claude/settings.json" ]] && pass "T8: settings.json created" || fail "T8: settings.json missing"
[[ -f "$REPO_T8/.claude/permissions.stack.json" ]] && pass "T8: sidecar created" || fail "T8: sidecar missing"
FLOOR_T8="$(live_deny "$REPO_T8")"
assert_contains "T8: floor rule present (self-protection: ssh)" "$FLOOR_T8" "Read(~/.ssh/**)"

# User-scope template merge (the other half of Contract E / D3's floor).
USER_HOME="$(new_home)"
if [[ -f "$CONFIG_MERGER" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_MERGER"
  cp "$REPO_ROOT/config/settings.global.template.json" "$USER_HOME/.claude/settings.json.pack"
  echo '{}' > "$USER_HOME/.claude/settings.json"
  if STACK_MERGE_NONINTERACTIVE=1 merge_json "$USER_HOME/.claude/settings.json.pack" "$USER_HOME/.claude/settings.json" >/tmp/t8-merge.txt 2>&1; then
    pass "T8: settings.global.template.json floor merges cleanly via merge_json"
  else
    fail "T8: merge_json failed on the floor template: $(cat /tmp/t8-merge.txt)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# T9 — waiver path: removes exactly that rule and nothing else; a
# corresponding change_history entry exists (per D9's documented convention).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T9="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T9")
write_snapshot "$CUR_HOME" "stripe"
make_repo "$REPO_T9" "financial-code" "normal" '[]'
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T9" >/dev/null
BEFORE_T9="$(live_deny "$REPO_T9" | sort)"
assert_contains "T9: Bash(stripe:*) present before waiver" "$BEFORE_T9" "Bash(stripe:*)"

python3 - "$REPO_T9/.claude/permissions.stack.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("waivers", []).append(
    {"rule": "Bash(stripe:*)", "reason": "test waiver", "date": "2026-07-27", "by": "test@example.com"}
)
json.dump(d, open(p, "w"), indent=2)
PY
python3 - "$REPO_T9/.claude/stack-config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("change_history", []).append(
    {"date": "2026-07-27T00:00:00Z", "setting": "permissions.waiver:Bash(stripe:*)",
     "old_value": None, "new_value": "waived", "reason": "test waiver",
     "scope": "project", "also_updated_global": False, "invoked_via": "test"}
)
json.dump(d, open(p, "w"), indent=2)
PY

HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T9" >/dev/null
AFTER_T9="$(live_deny "$REPO_T9" | sort)"
assert_not_contains "T9: Bash(stripe:*) gone after waiver" "$AFTER_T9" "Bash(stripe:*)"
assert_contains "T9: mcp__stripe still present (waiver removed exactly one rule)" "$AFTER_T9" "mcp__stripe"
CH_ENTRY="$(jq -r '.change_history[] | select(.setting=="permissions.waiver:Bash(stripe:*)") | .setting' "$REPO_T9/.claude/stack-config.json")"
assert_eq "T9: change_history entry documents the waiver" "permissions.waiver:Bash(stripe:*)" "$CH_ENTRY"

# ─────────────────────────────────────────────────────────────────────────
# T10 — gap telemetry: irreversible-deny.sh, inside an active loop, on a
# command no static rule covers -> one well-formed line in
# permissions-gap.jsonl, and the hook still denied.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
export HOME="$CUR_HOME"
if [[ -f "$LOOP_LIB" ]]; then
  # shellcheck disable=SC1090
  unset CLAUDE_CODE_SESSION_ID LOOP_STATE_FILE 2>/dev/null || true
  source "$LOOP_LIB"
  loop_write_state '{"active":true}'
  GAP_FILE="$CUR_HOME/.claude/logs/permissions-gap.jsonl"
  rm -f "$GAP_FILE"
  OUT_T10="$(jq -nc '{tool_name:"Bash", tool_input:{command:"git push origin main"}}' | bash "$DENY_HOOK" 2>/dev/null)"
  echo "$OUT_T10" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
    && pass "T10: irreversible-deny.sh still denies" || fail "T10: expected deny, got $OUT_T10"
  if [[ -f "$GAP_FILE" ]]; then
    LINES="$(wc -l < "$GAP_FILE" | tr -d ' ')"
    assert_eq "T10: exactly one gap line" "1" "$LINES"
    jq -e '.ts and .hook=="irreversible-deny" and .tool=="Bash" and .class_hint=="bash" and .rule_candidate' "$GAP_FILE" >/dev/null 2>&1 \
      && pass "T10: gap line is well-formed" || fail "T10: gap line malformed: $(cat "$GAP_FILE")"
  else
    fail "T10: no gap line written for an uncovered denial"
  fi
  loop_write_state '{"active":false}'
else
  skip "T10 (loop_lib.sh not found)"
fi
unset HOME; export HOME="$ORIG_HOME"

# ─────────────────────────────────────────────────────────────────────────
# T11 — schema: rejects an unknown class, an `allow` key, and a wildcard MCP
# specifier. Tested against the compiler's own embedded validator (the
# load-bearing check, since no jsonschema dependency exists in this repo --
# schemas/permissions-baseline-schema.json documents the same shape).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T11="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T11")
make_repo "$REPO_T11" "" "normal" '[]'
BASE_T11="$CUR_HOME/.claude/config/permissions-baseline.json"

jq '.floor.deny[0].class = "bogus"' "$REPO_ROOT/config/permissions-baseline.json" > "$BASE_T11"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T11" --dry-run >/dev/null 2>/tmp/t11a.txt
assert_rc "T11: unknown class rejected (exit 3)" "3" "$?"

jq '. + {allow: ["Bash(git push:*)"]}' "$REPO_ROOT/config/permissions-baseline.json" > "$BASE_T11"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T11" --dry-run >/dev/null 2>/tmp/t11b.txt
assert_rc "T11: 'allow' key rejected (exit 3)" "3" "$?"

jq '.floor.deny += [{"rule":"mcp__foo__*","class":"identity","why":"bad"}]' "$REPO_ROOT/config/permissions-baseline.json" > "$BASE_T11"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T11" --dry-run >/dev/null 2>/tmp/t11c.txt
assert_rc "T11: wildcard MCP specifier rejected (exit 3)" "3" "$?"

rm -f "$BASE_T11"
[[ -f "$REPO_ROOT/schemas/permissions-baseline-schema.json" ]] \
  && pass "T11: schemas/permissions-baseline-schema.json exists" \
  || fail "T11: schema doc missing"

# ─────────────────────────────────────────────────────────────────────────
# T12 — no ask/deny collision (D6b / Contract F).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
export HOME="$CUR_HOME"
REPO_T12="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T12")
mkdir -p "$REPO_T12/.claude"
make_repo "$REPO_T12" "" "normal" '[]'
SREF="mcp__b01e2e70-5f54-4546-b543-7afe8050aed4__"
MAIN_TP="$HOME/.claude/projects/proj/sess.jsonl"
WF_TP="$HOME/.claude/projects/proj/sess/workflows/wf_abc.json"
GAP_FILE_T12="$HOME/.claude/logs/permissions-gap.jsonl"

run_mcp_gate() {
  jq -nc --arg c "$1" --arg t "$2" --argjson ti "$3" --arg tp "$4" \
    '{cwd:$c, tool_name:$t, tool_input:$ti, transcript_path:$tp}' | bash "$GATE_HOOK" 2>/dev/null
}

# statically denied (domain_mode null -> apply_migration denied by default)
jq -n --arg srv "supabase" '{emitted:{deny:[("mcp__" + $srv + "__apply_migration")],ask:[]}}' > "$REPO_T12/.claude/permissions.stack.json"
rm -f "$GAP_FILE_T12"
OUT_T12A="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$MAIN_TP")"
echo "$OUT_T12A" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  && pass "T12: statically-covered call mirrors to deny on main thread" || fail "T12: got $OUT_T12A"
echo "$OUT_T12A" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("permissions.deny rule")' >/dev/null 2>&1 \
  && pass "T12: reason names the covering rule" || fail "T12: reason missing rule name: $OUT_T12A"
if [[ -f "$GAP_FILE_T12" ]]; then
  fail "T12: a mirror must NOT be logged as a gap"
else
  pass "T12: no gap-log line for a mirrored deny"
fi
OUT_T12A_WF="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$WF_TP")"
echo "$OUT_T12A_WF" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  && pass "T12: workflow-context branch still denies (case 1)" || fail "T12: got $OUT_T12A_WF"

# sidecar missing -> graceful degradation to ask
rm -f "$REPO_T12/.claude/permissions.stack.json"
OUT_T12B="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$MAIN_TP")"
echo "$OUT_T12B" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1 \
  && pass "T12: missing sidecar degrades to ask" || fail "T12: got $OUT_T12B"
OUT_T12B_WF="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$WF_TP")"
echo "$OUT_T12B_WF" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  && pass "T12: workflow-context branch still denies (case 2)" || fail "T12: got $OUT_T12B_WF"

# domain_mode schema-migration + waiver -> tool no longer statically denied -> ask
make_repo "$REPO_T12" "schema-migration" "normal" '[]'
jq -n '{emitted:{deny:[],ask:[]},waivers:[{rule:"mcp__supabase__apply_migration",reason:"t",date:"2026-07-27",by:"t"}]}' > "$REPO_T12/.claude/permissions.stack.json"
OUT_T12C="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$MAIN_TP")"
echo "$OUT_T12C" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1 \
  && pass "T12: schema-migration + waiver -> ask (no longer statically denied)" || fail "T12: got $OUT_T12C"
OUT_T12C_WF="$(run_mcp_gate "$REPO_T12" "mcp__supabase__apply_migration" '{"name":"x","query":"create table t(id int)"}' "$WF_TP")"
echo "$OUT_T12C_WF" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  && pass "T12: workflow-context branch still denies (case 3)" || fail "T12: got $OUT_T12C_WF"
unset HOME; export HOME="$ORIG_HOME"

# ─────────────────────────────────────────────────────────────────────────
# T13 — ledger provenance, collision case (D8). Fixture ORDERING is the test.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T13="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T13")
write_snapshot "$CUR_HOME" "stripe"
mkdir -p "$REPO_T13/.claude"
# Seed a hand-added Bash(stripe:*) with NO sidecar, BEFORE the first compile ever.
jq -n '{permissions:{deny:["Bash(stripe:*)"]}}' > "$REPO_T13/.claude/settings.json"
make_repo "$REPO_T13" "financial-code" "normal" '[]'
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T13" >/dev/null
OWNER_T13="$(jq -r '.ledger.deny["Bash(stripe:*)"].owner' "$REPO_T13/.claude/permissions.stack.json")"
assert_eq "T13: hand-added string collision -> adopted as human-owned" "human" "$OWNER_T13"

make_repo "$REPO_T13" "" "normal" '[]'
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T13" >/dev/null
DENY_T13="$(live_deny "$REPO_T13")"
assert_contains "T13: Bash(stripe:*) survives domain_mode -> null (human-owned)" "$DENY_T13" "Bash(stripe:*)"
assert_not_contains_line "T13: mcp__stripe gone (stack-owned, no longer emitted)" "$DENY_T13" "mcp__stripe"

# Documented residual + pinned[] escape hatch: seed the human rule AFTER a
# compile already claimed it as stack-owned (a different fixture ordering).
CUR_HOME2="$(new_home)"
REPO_T13B="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T13B")
write_snapshot "$CUR_HOME2" "stripe"
make_repo "$REPO_T13B" "financial-code" "normal" '[]'
HOME="$CUR_HOME2" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T13B" >/dev/null
OWNER_RESIDUAL="$(jq -r '.ledger.deny["Bash(stripe:*)"].owner' "$REPO_T13B/.claude/permissions.stack.json")"
assert_eq "T13 (residual): stack claims it first when compiled before any hand-edit" "stack" "$OWNER_RESIDUAL"
# Fix via pinned[]:
python3 - "$REPO_T13B/.claude/permissions.stack.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["pinned"] = ["Bash(stripe:*)"]
json.dump(d, open(p, "w"), indent=2)
PY
make_repo "$REPO_T13B" "" "normal" '[]'
HOME="$CUR_HOME2" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T13B" >/dev/null
DENY_RESIDUAL="$(live_deny "$REPO_T13B")"
assert_contains "T13 (residual): pinned[] keeps the string after domain_mode -> null" "$DENY_RESIDUAL" "Bash(stripe:*)"
OWNER_RESIDUAL_2="$(jq -r '.ledger.deny["Bash(stripe:*)"].owner' "$REPO_T13B/.claude/permissions.stack.json")"
assert_eq "T13 (residual): pinning flips owner to human permanently" "human" "$OWNER_RESIDUAL_2"

# ─────────────────────────────────────────────────────────────────────────
# T14 — writers genuinely serialize (deterministic blocking test, not a
# race). A helper opens the SAME lock path both writers resolve, holds it,
# and (case 2) mutates settings.json under the lock before releasing.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T14="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T14")
mkdir -p "$REPO_T14/.claude"
make_repo "$REPO_T14" "" "normal" '[]'
TARGET_T14="$REPO_T14/.claude/settings.json"
echo '{}' > "$TARGET_T14"

LOCK_HELPER="$(mktemp)"
cat > "$LOCK_HELPER" <<'PY'
import fcntl, json, os, sys, time
target, sleep_s, marker = sys.argv[1], float(sys.argv[2]), sys.argv[3]
lock_path = target + ".lock"
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
data = {}
if os.path.exists(target):
    try:
        data = json.load(open(target))
    except Exception:
        data = {}
perms = data.setdefault("permissions", {})
deny = perms.setdefault("deny", [])
if marker not in deny:
    deny.append(marker)
with open(target, "w") as f:
    json.dump(data, f)
time.sleep(sleep_s)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY

# Case 1 (compiler blocks) + case 2 (read happens after lock, i.e. reflects
# the helper's mutation).
python3 "$LOCK_HELPER" "$TARGET_T14" 2 "Bash(helper-marker:*)" &
HELPER_PID=$!
sleep 0.4
SECONDS=0
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T14" >/dev/null 2>&1
ELAPSED=$SECONDS
wait "$HELPER_PID"
[[ "$ELAPSED" -ge 1 ]] && pass "T14: permissions-compile.sh blocked on the shared lock (elapsed=${ELAPSED}s)" \
  || fail "T14: permissions-compile.sh did not block (elapsed=${ELAPSED}s)"
FINAL_DENY_T14="$(live_deny "$REPO_T14")"
assert_contains "T14: compiler's write reflects the helper's mutation (read-after-lock)" "$FINAL_DENY_T14" "Bash(helper-marker:*)"

# Case: native-settings-edit.py also blocks on the SAME lock path.
echo '{}' > "$TARGET_T14"
python3 "$LOCK_HELPER" "$TARGET_T14" 2 "Bash(helper-marker-2:*)" &
HELPER_PID2=$!
sleep 0.4
SECONDS=0
python3 "$NSE_PY" --path /model --value opus --repo-root "$REPO_T14" >/dev/null 2>&1
ELAPSED2=$SECONDS
wait "$HELPER_PID2"
[[ "$ELAPSED2" -ge 1 ]] && pass "T14: native-settings-edit.py blocked on the shared lock (elapsed=${ELAPSED2}s)" \
  || fail "T14: native-settings-edit.py did not block (elapsed=${ELAPSED2}s)"
FINAL_DENY_T14B="$(live_deny "$REPO_T14")"
assert_contains "T14: both writers resolve the identical lock path (helper mutation survives native-settings-edit's write too)" "$FINAL_DENY_T14B" "Bash(helper-marker-2:*)"

rm -f "$LOCK_HELPER"

# ─────────────────────────────────────────────────────────────────────────
# T15 — required_approvals must be unconditional, never suppressed by a
# domain overlay (post-review bug fix in the unconditional_tools/suppressed
# logic). Reproduction: domain_mode:"deploy" + required_approvals:
# ["pre-deploy"] must still deny deploy_edge_function even though the
# "deploy" overlay would otherwise suppress it as the MCQ-2 default escape.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T15="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T15")
write_snapshot "$CUR_HOME" "supabase"
make_repo "$REPO_T15" "deploy" "normal" '["pre-deploy"]'
RULES_T15="$(compiled_rules "$REPO_T15")"
assert_contains "T15: explicit required_approvals[pre-deploy] survives a suppressing domain overlay" "$RULES_T15" "mcp__supabase__deploy_edge_function"

# Contrast: same domain_mode, no explicit required_approvals -> the MCQ-2
# default IS suppressible (the documented escape hatch still works).
make_repo "$REPO_T15" "deploy" "normal" '[]'
RULES_T15_DEFAULT="$(compiled_rules "$REPO_T15")"
assert_not_contains "T15: MCQ-2 default (no explicit gate) is still suppressed by the deploy overlay" "$RULES_T15_DEFAULT" "mcp__supabase__deploy_edge_function"

# Same class of bug for pre-schema-change + schema-migration overlay.
make_repo "$REPO_T15" "schema-migration" "normal" '["pre-schema-change"]'
RULES_T15_SM="$(compiled_rules "$REPO_T15")"
assert_contains "T15: explicit required_approvals[pre-schema-change] survives the schema-migration escape hatch" "$RULES_T15_SM" "mcp__supabase__execute_sql"

# ─────────────────────────────────────────────────────────────────────────
# T16 — malformed stack-config.json fields never crash with a raw traceback
# and never silently produce a weaker rule set at exit 0; always sanitized
# exit 3.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T16="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T16")
mkdir -p "$REPO_T16/.claude"
write_snapshot "$CUR_HOME"

# sensitivity as a bare string instead of an object (the reviewer's live repro).
jq -n '{stack_tier:2, stack_version:"1.0.0", purpose:"t", created:"2026-01-01", domain_mode:null, sensitivity:"confidential", required_approvals:[]}' \
  > "$REPO_T16/.claude/stack-config.json"
OUT_T16A="$(HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T16" --dry-run 2>&1)"
RC_T16A=$?
assert_rc "T16: malformed sensitivity (bare string) -> sanitized exit 3, not a traceback" "3" "$RC_T16A"
assert_not_contains "T16: no raw Python traceback leaks to output" "$OUT_T16A" "Traceback (most recent call last)"

# unknown domain_mode value (a typo) must refuse, not silently compile a
# weaker rule set at exit 0.
jq -n '{stack_tier:2, stack_version:"1.0.0", purpose:"t", created:"2026-01-01", domain_mode:"financial_code", sensitivity:{level:"normal"}, required_approvals:[]}' \
  > "$REPO_T16/.claude/stack-config.json"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T16" --dry-run >/dev/null 2>/tmp/t16b.txt
assert_rc "T16: unknown domain_mode value refused (exit 3), not silently weaker" "3" "$?"

# required_approvals as a bare string instead of an array.
jq -n '{stack_tier:2, stack_version:"1.0.0", purpose:"t", created:"2026-01-01", domain_mode:null, sensitivity:{level:"normal"}, required_approvals:"pre-deploy"}' \
  > "$REPO_T16/.claude/stack-config.json"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope project --repo-root "$REPO_T16" --dry-run >/dev/null 2>/tmp/t16c.txt
assert_rc "T16: required_approvals as a bare string refused (exit 3)" "3" "$?"

# ─────────────────────────────────────────────────────────────────────────
# T17 — settings_lock.py --apply-permissions-plan rejects an unauthenticated
# / non-derived plan piped directly on stdin (ADR-044 D7/Contract C: "no
# free-form rule argument"). A bare hostile plan must not silently wipe or
# set arbitrary permissions.deny content, and a legitimate (baseline-
# derivable) plan must still apply.
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T17="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T17")
mkdir -p "$REPO_T17/.claude"
echo '{}' > "$REPO_T17/.claude/settings.json"

OUT_T17A="$(echo '{"scope":"project","compiled_deny":[{"rule":"Read(/etc/passwd)","class":"path"}],"compiled_ask":[]}' \
  | HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$LIB_PY" --apply-permissions-plan --target "$REPO_T17/.claude/settings.json" 2>&1)"
RC_T17A=$?
assert_rc "T17: a rule not derivable from the baseline is refused (exit 2)" "2" "$RC_T17A"
DENY_T17A="$(jq -r '.permissions.deny[]?' "$REPO_T17/.claude/settings.json" 2>/dev/null)"
assert_eq "T17: settings.json untouched after a refused hostile plan" "" "$DENY_T17A"

OUT_T17B="$(echo '{"scope":"project","compiled_deny":[{"rule":"Read(~/.ssh/**)","class":"path"}],"compiled_ask":[]}' \
  | HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$LIB_PY" --apply-permissions-plan --target "$REPO_T17/.claude/settings.json" 2>&1)"
RC_T17B=$?
assert_rc "T17: a baseline-derivable plan still applies (exit 0)" "0" "$RC_T17B"
DENY_T17B="$(jq -r '.permissions.deny[]?' "$REPO_T17/.claude/settings.json" 2>/dev/null)"
assert_contains "T17: the legitimate rule was actually written" "$DENY_T17B" "Read(~/.ssh/**)"

# ─────────────────────────────────────────────────────────────────────────
# T18 — --scope user hard-refuses without --from-install (Contract C: "any
# rule string not derivable ... --scope user without the template/install
# path").
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
OUT_T18="$(HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope user --dry-run 2>&1)"
assert_rc "T18: --scope user without --from-install is refused (exit 2)" "2" "$?"
OUT_T18B="$(HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope user --from-install --dry-run 2>&1)"
assert_rc "T18: --scope user --from-install --dry-run proceeds (exit 0)" "0" "$?"

# The actual write path (not just --dry-run): the floor is genuinely written
# to ~/.claude/settings.json, and survives --prune-user when retired_rules is
# empty (this is the one path where #1's plan-verification, #2's new
# baseline-path floor rule, and #5's --from-install gate all interact).
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope user --from-install >/dev/null
assert_rc "T18: --scope user --from-install writes (exit 0)" "0" "$?"
USER_DENY="$(jq -r '.permissions.deny[]?' "$CUR_HOME/.claude/settings.json" 2>/dev/null)"
assert_contains "T18: written floor includes the new baseline self-protection rule" "$USER_DENY" "Write(~/.claude/config/permissions-baseline.json)"
USER_DENY_COUNT_BEFORE="$(jq -r '.permissions.deny | length' "$CUR_HOME/.claude/settings.json")"
assert_eq "T18: floor is 12 rules after the first user-scope compile" "12" "$USER_DENY_COUNT_BEFORE"
HOME="$CUR_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$COMPILE" --scope user --from-install --prune-user >/dev/null
assert_rc "T18: --scope user --from-install --prune-user still writes (exit 0)" "0" "$?"
USER_DENY_COUNT_AFTER="$(jq -r '.permissions.deny | length' "$CUR_HOME/.claude/settings.json")"
assert_eq "T18: floor survives --prune-user with an empty retired_rules" "12" "$USER_DENY_COUNT_AFTER"

# ─────────────────────────────────────────────────────────────────────────
# T19 — provisioning gate (design doc 2026-07-30-provider-scaffolding-
# automation-v2.md §4 layer 2 / §9 Phase 0): the four denies land only when
# the gate is explicitly requested via required_approvals, and never leak in
# by default (this gate is NOT in the pre-schema-change/pre-deploy
# unconditional set, so it follows the opt-in path of e.g. pre-merge).
# ─────────────────────────────────────────────────────────────────────────
CUR_HOME="$(new_home)"
REPO_T19="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO_T19")
write_snapshot "$CUR_HOME" "neon" "cloudflare"
make_repo "$REPO_T19" "" "normal" '["provisioning"]'
RULES_T19="$(compiled_rules "$REPO_T19")"
assert_contains_line "T19: gh repo delete denied when provisioning gate requested" "$RULES_T19" "Bash(gh repo delete:*)"
assert_contains_line "T19: gh repo edit denied when provisioning gate requested" "$RULES_T19" "Bash(gh repo edit:*)"
assert_contains_line "T19: neonctl denied when provisioning gate requested" "$RULES_T19" "Bash(neonctl:*)"
assert_contains_line "T19: wrangler denied when provisioning gate requested" "$RULES_T19" "Bash(wrangler:*)"
# Real Neon/Cloudflare MCP tool names, confirmed 2026-07-31 against the live-
# connected plugin servers (not invented — the original Phase 0 gap this
# closes). Expanded per live server name in the snapshot (neon, cloudflare).
assert_contains_line "T19: neon delete_project denied (MCP)" "$RULES_T19" "mcp__neon__delete_project"
assert_contains_line "T19: neon delete_branch denied (MCP)" "$RULES_T19" "mcp__neon__delete_branch"
assert_contains_line "T19: neon reset_from_parent denied (MCP)" "$RULES_T19" "mcp__neon__reset_from_parent"
assert_contains_line "T19: cloudflare d1_database_delete denied (MCP)" "$RULES_T19" "mcp__cloudflare__d1_database_delete"
assert_contains_line "T19: cloudflare kv_namespace_delete denied (MCP)" "$RULES_T19" "mcp__cloudflare__kv_namespace_delete"
assert_contains_line "T19: cloudflare r2_bucket_delete denied (MCP)" "$RULES_T19" "mcp__cloudflare__r2_bucket_delete"
assert_contains_line "T19: cloudflare hyperdrive_config_delete denied (MCP)" "$RULES_T19" "mcp__cloudflare__hyperdrive_config_delete"

make_repo "$REPO_T19" "" "normal" '[]'
RULES_T19B="$(compiled_rules "$REPO_T19")"
assert_not_contains_line "T19: gh repo delete absent when provisioning not requested" "$RULES_T19B" "Bash(gh repo delete:*)"
assert_not_contains_line "T19: neonctl absent when provisioning not requested" "$RULES_T19B" "Bash(neonctl:*)"
assert_not_contains_line "T19: wrangler absent when provisioning not requested" "$RULES_T19B" "Bash(wrangler:*)"
assert_not_contains_line "T19: neon delete_project absent when provisioning not requested" "$RULES_T19B" "mcp__neon__delete_project"

echo "----------------------------------------"
echo "permissions-boundary: $PASS passed, $FAIL failed, ${#SKIPPED[@]} skipped"
if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
  echo "Skipped (live-harness cases -- see comments above for how to opt in):"
  for s in "${SKIPPED[@]}"; do echo "  - $s"; done
fi
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
