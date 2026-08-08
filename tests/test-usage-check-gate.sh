#!/usr/bin/env bash
# Tests for hooks/usage-check-token.sh (minting) and hooks/usage-check-gate.sh (gate).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINT_HOOK="$REPO_ROOT/hooks/usage-check-token.sh"
GATE_HOOK="$REPO_ROOT/hooks/usage-check-gate.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

build_repo() {
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main && git config user.email t@t.t && git config user.name t
    echo x > README.md && git add -A && git commit -qm init )
  echo "$R"
}

REPO="$(build_repo)"
REPO="$(cd "$REPO" && git rev-parse --show-toplevel)"
SOURCE="$REPO_ROOT/scripts/lib/usage-check-common.sh"
# shellcheck source=/dev/null
source "$SOURCE"

checker_result_line() { # <repo> <target> -> the real result line from Task 2's checker
  ( cd "$1" && bash "$REPO_ROOT/scripts/usage-check.sh" --target "$2" ) | grep '^USAGE_CHECK_RESULT:v1 '
}

mint_payload() { # <repo> <command> <stdout> <session_id> -> jq-built PostToolUse payload
  jq -nc --arg cwd "$1" --arg cmd "$2" --arg out "$3" --arg sid "$4" \
    '{cwd:$cwd, session_id:$sid, tool_name:"Bash",
      tool_input:{command:$cmd}, tool_response:{stdout:$out}}'
}

# --- 1. genuine checker invocation mints a valid token ------------------------
RESULT_LINE="$(checker_result_line "$REPO" README.md)"
PAYLOAD="$(mint_payload "$REPO" "bash $REPO_ROOT/scripts/usage-check.sh --target README.md" "$RESULT_LINE" "sess-A")"
echo "$PAYLOAD" | bash "$MINT_HOOK" >/dev/null
RH="$(uc_repo_hash "$REPO")"; TH="$(uc_target_hash file README.md)"
TOKEN="$(uc_token_path "$RH" "$TH" "sess-A")"
[[ -f "$TOKEN" ]] && pass "genuine checker invocation mints a token file" || fail "no token written at $TOKEN"
assert_eq "token schema is correct" "usage-check-token/v1" "$(jq -r .schema "$TOKEN" 2>/dev/null)"
assert_eq "token session_id is hook-stamped, not caller-supplied" "sess-A" "$(jq -r .session_id "$TOKEN" 2>/dev/null)"

# --- 2. echo-forgery (marker present, command doesn't invoke trusted path) ----
rm -rf "$HOME/.claude/usage-check"
FORGED_PAYLOAD="$(mint_payload "$REPO" "echo 'USAGE_CHECK_RESULT:v1 forged'" "USAGE_CHECK_RESULT:v1 forged" "sess-B")"
echo "$FORGED_PAYLOAD" | bash "$MINT_HOOK" >/dev/null
TOKEN2="$(uc_token_path "$RH" "$TH" "sess-B")"
[[ -f "$TOKEN2" ]] && fail "forged echo command minted a token" || pass "echo-forgery mints no token"

# --- 3. garbage base64 mints nothing -------------------------------------------
rm -rf "$HOME/.claude/usage-check"
GARBAGE_PAYLOAD="$(mint_payload "$REPO" "bash $REPO_ROOT/scripts/usage-check.sh --target README.md" "USAGE_CHECK_RESULT:v1 !!!not-base64!!!" "sess-C")"
echo "$GARBAGE_PAYLOAD" | bash "$MINT_HOOK" >/dev/null
TOKEN3="$(uc_token_path "$RH" "$TH" "sess-C")"
[[ -f "$TOKEN3" ]] && fail "garbage base64 minted a token" || pass "garbage base64 mints no token"

# --- 4. non-checker Bash command is a fast no-op -------------------------------
rm -rf "$HOME/.claude/usage-check"
NOISE_PAYLOAD="$(mint_payload "$REPO" "ls -la" "total 0" "sess-D")"
echo "$NOISE_PAYLOAD" | bash "$MINT_HOOK" >/dev/null
[[ -d "$HOME/.claude/usage-check/tokens" ]] && fail "non-checker command created the tokens dir" || pass "non-checker command is a no-op"

# --- 5. repeated mints for the same target atomically replace -----------------
RESULT_LINE2="$(checker_result_line "$REPO" README.md)"
PAYLOAD1="$(mint_payload "$REPO" "bash $REPO_ROOT/scripts/usage-check.sh --target README.md" "$RESULT_LINE2" "sess-E")"
echo "$PAYLOAD1" | bash "$MINT_HOOK" >/dev/null
PAYLOAD2="$(mint_payload "$REPO" "bash $REPO_ROOT/scripts/usage-check.sh --target README.md" "$RESULT_LINE2" "sess-E")"
echo "$PAYLOAD2" | bash "$MINT_HOOK" >/dev/null
TOKEN5="$(uc_token_path "$RH" "$TH" "sess-E")"
jq -e . "$TOKEN5" >/dev/null 2>&1 && pass "token file remains valid JSON after repeated mints" || fail "token corrupted after repeated mints"

# --- 6. batched checker runs (one Bash call, several targets) mint ALL tokens -
# Regression test for the tail-1 bug: a for-loop running the checker once per
# target in a single Bash call must mint one token per target, not just the
# last one.
rm -rf "$HOME/.claude/usage-check"
mkdir -p "$REPO/src"
echo 'export const a = 1;' > "$REPO/src/alpha.ts"
echo 'export const b = 1;' > "$REPO/src/bravo.ts"
( cd "$REPO" && git add -A && git commit -qm "add alpha/bravo" )
BATCH_STDOUT="$(checker_result_line "$REPO" src/alpha.ts)"$'\n'"$(checker_result_line "$REPO" src/bravo.ts)"
BATCH_PAYLOAD="$(mint_payload "$REPO" "for t in src/alpha.ts src/bravo.ts; do bash $REPO_ROOT/scripts/usage-check.sh --target \$t; done" "$BATCH_STDOUT" "sess-BATCH")"
echo "$BATCH_PAYLOAD" | bash "$MINT_HOOK" >/dev/null
TOKEN_ALPHA="$(uc_token_path "$RH" "$(uc_target_hash file src/alpha.ts)" "sess-BATCH")"
TOKEN_BRAVO="$(uc_token_path "$RH" "$(uc_target_hash file src/bravo.ts)" "sess-BATCH")"
[[ -f "$TOKEN_ALPHA" ]] && pass "batched run mints a token for the first target" || fail "batched run did not mint token for src/alpha.ts"
[[ -f "$TOKEN_BRAVO" ]] && pass "batched run mints a token for the second target" || fail "batched run did not mint token for src/bravo.ts (tail-1 regression)"
assert_eq "first token's target is byte-correct" "src/alpha.ts" "$(jq -r .target "$TOKEN_ALPHA" 2>/dev/null)"
assert_eq "second token's target is byte-correct" "src/bravo.ts" "$(jq -r .target "$TOKEN_BRAVO" 2>/dev/null)"

# --- 7. a malformed result line among several is skipped, not fatal -----------
rm -rf "$HOME/.claude/usage-check"
GOOD_LINE="$(checker_result_line "$REPO" src/alpha.ts)"
MIXED_STDOUT="USAGE_CHECK_RESULT:v1 !!!not-base64!!!"$'\n'"$GOOD_LINE"
MIXED_PAYLOAD="$(mint_payload "$REPO" "bash $REPO_ROOT/scripts/usage-check.sh --target src/alpha.ts" "$MIXED_STDOUT" "sess-MIXED")"
echo "$MIXED_PAYLOAD" | bash "$MINT_HOOK" >/dev/null
TOKEN_MIXED="$(uc_token_path "$RH" "$(uc_target_hash file src/alpha.ts)" "sess-MIXED")"
[[ -f "$TOKEN_MIXED" ]] && pass "a genuine line still mints even when a malformed line precedes it" || fail "malformed line among several blocked the genuine one"

echo
echo "usage-check-gate (minting): $PASS passed, $FAIL failed"

# ==============================================================================
# Gate tests
# ==============================================================================
gate_payload() { # <repo> <subagent_type> <prompt> <session_id> [transcript_path]
  jq -nc --arg cwd "$1" --arg st "$2" --arg prompt "$3" --arg sid "$4" --arg tp "${5:-/tmp/t.jsonl}" \
    '{cwd:$cwd, tool_name:"Agent", session_id:$sid, transcript_path:$tp,
      tool_input:{subagent_type:$st, prompt:$prompt}}'
}
is_deny() { # <gate stdout> -> 0 if a deny decision, 1 otherwise
  echo "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
}

mkdir -p "$REPO/.claude"
echo '{"stack_tier":4}' > "$REPO/.claude/stack-config.json"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

mint_fresh_token() { # <repo> <target> <session_id> -> mints via the real checker+minting hook chain
  local repo="$1" target="$2" sid="$3"
  local result_line; result_line="$(checker_result_line "$repo" "$target")"
  local payload; payload="$(mint_payload "$repo" "bash $REPO_ROOT/scripts/usage-check.sh --target $target" "$result_line" "$sid")"
  echo "$payload" | bash "$MINT_HOOK" >/dev/null
}

# --- 8. ungated agent no-ops ---------------------------------------------------
echo '{"stack_tier":4,"guards":{"usage_check_gate":"on"}}' > "$REPO/.claude/stack-config.json"
OUT="$(gate_payload "$REPO" "implementer" "do stuff" "sess-F" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "ungated agent (implementer) produces no output" || fail "implementer unexpectedly produced output: $OUT"

# --- 9. valid fresh token + unchanged HEAD + agreeing re-run passes silently ---
mint_fresh_token "$REPO" README.md "sess-G"
OUT="$(gate_payload "$REPO" "reviewer" "Review the change. Usage-check-target: README.md" "sess-G" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "valid fresh token passes silently (no output)" || fail "valid token unexpectedly denied: $OUT"

# --- 10. missing target line denies --------------------------------------------
OUT="$(gate_payload "$REPO" "reviewer" "Review the change, no target line here" "sess-G" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "missing Usage-check-target line denies" || fail "missing target line should deny: $OUT"
echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'no_target_declared\|Usage-check-target' \
  && pass "deny reason mentions the missing-target remediation" || fail "deny reason unclear: $OUT"

# --- 11. declared target with no token denies ----------------------------------
OUT="$(gate_payload "$REPO" "reviewer" "Usage-check-target: some/other/file.ts" "sess-G" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "declared target with no token denies" || fail "no-token case should deny: $OUT"

# --- 12. byte-mismatched target denies (no fuzzy pass) -------------------------
mint_fresh_token "$REPO" README.md "sess-H"
OUT="$(gate_payload "$REPO" "reviewer" "Usage-check-target: README-DIFFERENT.md" "sess-H" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "mismatched target denies (byte equality enforced)" || fail "mismatched target should deny: $OUT"

# --- 13. HEAD moved invalidates even with a fresh TTL ---------------------------
mint_fresh_token "$REPO" README.md "sess-I"
( cd "$REPO" && git commit --allow-empty -qm "unrelated commit" )
OUT="$(gate_payload "$REPO" "reviewer" "Usage-check-target: README.md" "sess-I" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "HEAD moved past token's commit denies (AND semantics)" || fail "moved-HEAD case should deny: $OUT"

# --- 14. re-verification catches a hand-forged token ----------------------------
FORGED_TOKEN_PATH="$(uc_token_path "$(uc_repo_hash "$REPO")" "$(uc_target_hash file 'src/never/referenced/anywhere.ts')" "sess-J")"
mkdir -p "$(dirname "$FORGED_TOKEN_PATH")"
HEAD_NOW="$(cd "$REPO" && git rev-parse HEAD)"
jq -nc --arg t "src/never/referenced/anywhere.ts" --arg h "$HEAD_NOW" --arg sid "sess-J" --arg now "$(uc_now_iso)" \
  '{schema:"usage-check-token/v1", target:$t, target_kind:"file", repo_root:"'"$REPO"'",
    repo_hash:"x", head_commit:$h, session_id:$sid, minted_at:$now, ttl_seconds:3600,
    search:{tool:"rg", pattern:"\\banyway\\b", search_root:".", excluded_target:$t, match_count:99, matched_files:["fake.ts"]},
    graphify:{consulted:false}, verdict:"used"}' > "$FORGED_TOKEN_PATH"
OUT="$(gate_payload "$REPO" "reviewer" "Usage-check-target: src/never/referenced/anywhere.ts" "sess-J" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "hand-forged token with fake match_count is caught by re-verification" || fail "forged token should be denied by re-run: $OUT"

# --- 15. Task matcher behaves identically to Agent matcher -----------------------
mint_fresh_token "$REPO" README.md "sess-K"
OUT="$(jq -nc --arg cwd "$REPO" --arg sid "sess-K" \
  '{cwd:$cwd, tool_name:"Task", session_id:$sid, transcript_path:"/tmp/t.jsonl",
    tool_input:{subagent_type:"reviewer", prompt:"Usage-check-target: README.md"}}' | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "Task-matcher dispatch with valid token passes silently" || fail "Task matcher should behave like Agent: $OUT"

# --- 16. disable file bypasses everything, even a broken config -----------------
echo 'not valid json {{{' > "$REPO/.claude/stack-config.json"
mkdir -p "$HOME/.claude"
touch "$HOME/.claude/usage-check-gate.disabled"
OUT="$(gate_payload "$REPO" "reviewer" "no target line, broken config too" "sess-L" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "disable file bypasses gate even with broken config" || fail "disable file should bypass everything: $OUT"
rm -f "$HOME/.claude/usage-check-gate.disabled"
echo '{"stack_tier":4,"guards":{"usage_check_gate":"on"}}' > "$REPO/.claude/stack-config.json"

# --- 17. every deny string is free of bypass-teaching text ----------------------
OUT="$(gate_payload "$REPO" "reviewer" "no target here" "sess-M" | bash "$GATE_HOOK")"
REASON="$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
echo "$REASON" | grep -qi 'disabled\|override-once\|usage_check_gate' \
  && fail "deny reason leaks a bypass mechanism: $REASON" \
  || pass "deny reason never mentions disable/override/config-key"

# --- 18. warn mode never blocks ---------------------------------------------------
echo '{"stack_tier":4,"guards":{"usage_check_gate":"warn"}}' > "$REPO/.claude/stack-config.json"
OUT="$(gate_payload "$REPO" "reviewer" "no target, would normally deny" "sess-N" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "warn mode never emits a blocking decision" || fail "warn mode should never block: $OUT"

# --- 19. re-verification catches a genuine verdict mismatch (existing target) ---
# Distinct from test 14: that forged target doesn't exist on disk, so the
# checker exits before ever computing a verdict, proving only reverify_failed.
# This test forges a token for a target that DOES exist (README.md, real
# verdict "unused" in this fixture repo) but claims verdict "used" — the
# checker must actually run and disagree for this to catch anything.
echo '{"stack_tier":4,"guards":{"usage_check_gate":"on"}}' > "$REPO/.claude/stack-config.json"
FORGED_TOKEN_PATH2="$(uc_token_path "$(uc_repo_hash "$REPO")" "$(uc_target_hash file README.md)" "sess-O")"
mkdir -p "$(dirname "$FORGED_TOKEN_PATH2")"
HEAD_NOW2="$(cd "$REPO" && git rev-parse HEAD)"
jq -nc --arg t "README.md" --arg h "$HEAD_NOW2" --arg sid "sess-O" --arg now "$(uc_now_iso)" \
  '{schema:"usage-check-token/v1", target:$t, target_kind:"file", repo_root:"'"$REPO"'",
    repo_hash:"x", head_commit:$h, session_id:$sid, minted_at:$now, ttl_seconds:3600,
    search:{tool:"rg", pattern:"\\bREADME\\b", search_root:".", excluded_target:$t, match_count:5, matched_files:["fake.ts"]},
    graphify:{consulted:false}, verdict:"used"}' > "$FORGED_TOKEN_PATH2"
OUT="$(gate_payload "$REPO" "reviewer" "Usage-check-target: README.md" "sess-O" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "genuine verdict mismatch (claimed used, actually unused) is caught by re-verification" || fail "verdict-mismatch case should deny: $OUT"
echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'reverify_verdict_mismatch' \
  && pass "deny reason correctly identifies reverify_verdict_mismatch" || fail "deny reason should mention reverify_verdict_mismatch: $OUT"

# ==============================================================================
# IMPORTANT #1 — mode resolution fallback rung: repo stack-config, else
# ~/.claude/stack-defaults.json, else built-in default "warn".
# ==============================================================================

# --- 20. repo config has no "guards" key -> falls back to stack-defaults.json,
#     which says "off" -> gate no-ops entirely, even with no target declared.
echo '{"stack_tier":4}' > "$REPO/.claude/stack-config.json"
mkdir -p "$HOME/.claude"
echo '{"guards":{"usage_check_gate":"off"}}' > "$HOME/.claude/stack-defaults.json"
OUT="$(gate_payload "$REPO" "reviewer" "no target line at all" "sess-P" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "stack-defaults.json guards.usage_check_gate=off is honored when repo config has no guards key" \
  || fail "fallback to stack-defaults 'off' should no-op: $OUT"

# --- 21. same fallback, stack-defaults.json says "on" -> denies on missing target
echo '{"guards":{"usage_check_gate":"on"}}' > "$HOME/.claude/stack-defaults.json"
OUT="$(gate_payload "$REPO" "reviewer" "no target line at all" "sess-Q" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "stack-defaults.json guards.usage_check_gate=on is honored when repo config has no guards key" \
  || fail "fallback to stack-defaults 'on' should deny on missing target: $OUT"

# --- 22. repo config value wins over stack-defaults.json (precedence unchanged) ---
echo '{"stack_tier":4,"guards":{"usage_check_gate":"warn"}}' > "$REPO/.claude/stack-config.json"
echo '{"guards":{"usage_check_gate":"on"}}' > "$HOME/.claude/stack-defaults.json"
OUT="$(gate_payload "$REPO" "reviewer" "no target line at all" "sess-R" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "repo config's own guards value takes precedence over stack-defaults.json" \
  || fail "repo config 'warn' should not block even though stack-defaults says 'on': $OUT"

# --- 23. no repo stack-config at all -> stack-defaults.json fallback still applies -
NOCONFIG_REPO="$TMP/noconfig-repo"; rm -rf "$NOCONFIG_REPO"; mkdir -p "$NOCONFIG_REPO"
( cd "$NOCONFIG_REPO" && git init -q -b main && git config user.email t@t.t && git config user.name t
  echo x > README.md && git add -A && git commit -qm init )
echo '{"guards":{"usage_check_gate":"off"}}' > "$HOME/.claude/stack-defaults.json"
OUT="$(gate_payload "$NOCONFIG_REPO" "reviewer" "no target line" "sess-S" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "stack-defaults.json fallback applies even with no repo stack-config.json at all" \
  || fail "no-repo-config case should still consult stack-defaults.json: $OUT"

rm -f "$HOME/.claude/stack-defaults.json"
echo '{"stack_tier":4,"guards":{"usage_check_gate":"on"}}' > "$REPO/.claude/stack-config.json"

# ==============================================================================
# IMPORTANT #3 — repo-local override (.claude/.usage-check-override-once)
# ==============================================================================
OVERRIDE_FILE="$REPO/.claude/.usage-check-override-once"

# --- 24. untracked override file is consumed once and allows the dispatch -----
rm -f "$OVERRIDE_FILE"
touch "$OVERRIDE_FILE"
OUT="$(gate_payload "$REPO" "reviewer" "no target line, relying on override" "sess-T" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "untracked override file allows the dispatch through" || fail "untracked override should bypass the gate: $OUT"
[[ ! -f "$OVERRIDE_FILE" ]] && pass "untracked override file is consumed (deleted) after use" || fail "override file was not consumed"
OUT2="$(gate_payload "$REPO" "reviewer" "no target line, override already spent" "sess-T" | bash "$GATE_HOOK")"
is_deny "$OUT2" && pass "override is single-use: a second dispatch after consumption denies normally" || fail "override should not still apply after consumption: $OUT2"

# --- 25. a tracked (git-committed) override file is refused and left in place -
rm -f "$OVERRIDE_FILE"
touch "$OVERRIDE_FILE"
( cd "$REPO" && git add -f .claude/.usage-check-override-once && git commit -qm "accidentally commit override" )
OUT="$(gate_payload "$REPO" "reviewer" "no target line, tracked override present" "sess-U" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "tracked override file is refused (gate still denies)" || fail "tracked override should not bypass the gate: $OUT"
[[ -f "$OVERRIDE_FILE" ]] && pass "tracked override file is left in place, not consumed" || fail "tracked override file was unexpectedly removed"
( cd "$REPO" && git rm -q --cached .claude/.usage-check-override-once && git commit -qm "untrack override" )
rm -f "$OVERRIDE_FILE"

# --- 26. an override file is never honored when transcript_path indicates workflow context ---
touch "$OVERRIDE_FILE"
OUT="$(gate_payload "$REPO" "reviewer" "no target line, in a workflow" "sess-V" "/some/path/workflows/run123.jsonl" | bash "$GATE_HOOK")"
is_deny "$OUT" && pass "override is never honored in workflow context (denies normally)" || fail "workflow-context dispatch should not honor the override: $OUT"
[[ -f "$OVERRIDE_FILE" ]] && pass "override file is left untouched in workflow context (never read)" || fail "override file should not be consumed in workflow context"

# --- 27. override actually engages when the repo has NO stack-config.json at all --
# Tests 24-26 above all run against $REPO, which has a stack-config.json (set at
# the top of this section) — CONFIG is non-empty there, so
# hooks/usage-check-gate.sh:109 (`[[ -n "$CONFIG" && -f "$CONFIG" ]] && ORCH_MODE=...`)
# unconditionally overwrites ORCH_MODE from the jq read, and the initializer one
# line above it is never actually exercised. The ORCH_MODE="on"->"main-thread" bug
# only manifests when CONFIG is empty (no repo stack-config.json at all), which is
# exactly NOCONFIG_REPO from test 23. This test isolates that path.
echo '{"guards":{"usage_check_gate":"on"}}' > "$HOME/.claude/stack-defaults.json"
mkdir -p "$NOCONFIG_REPO/.claude"
NOCONFIG_OVERRIDE="$NOCONFIG_REPO/.claude/.usage-check-override-once"
rm -f "$NOCONFIG_OVERRIDE"
touch "$NOCONFIG_OVERRIDE"
OUT="$(gate_payload "$NOCONFIG_REPO" "reviewer" "no target line, no stack-config, relying on override" "sess-W" | bash "$GATE_HOOK")"
[[ -z "$OUT" ]] && pass "override engages with no repo stack-config.json present (ORCH_MODE initializer must be main-thread)" \
  || fail "override should bypass the gate even with no stack-config.json present: $OUT"
[[ ! -f "$NOCONFIG_OVERRIDE" ]] && pass "override file is consumed in the no-stack-config case" \
  || fail "override file was not consumed in the no-stack-config case"
rm -f "$HOME/.claude/stack-defaults.json"
rm -f "$OVERRIDE_FILE"

# --- tool_response shape robustness ------------------------------------------
# Every other test in this file builds its own payload with tool_response as an
# object carrying .stdout. If the real harness ever hands the minting hook a
# different shape, the hook's fast path exits silently and NO token is ever
# minted — the entire feature inert, with all these tests still green.
# hooks/subagent-complete-log.sh:18 documents this exact variance (and handles
# a bare-string tool_response), so the risk is real, not theoretical. These
# tests pin every shape the hook now probes.
SHAPE_RESULT_LINE="$(checker_result_line "$REPO" README.md)"
RH_SHAPE="$(uc_repo_hash "$REPO")"
TH_SHAPE="$(uc_target_hash file README.md)"
SHAPE_CMD="bash $REPO_ROOT/scripts/usage-check.sh --target README.md"

assert_shape_mints() { # <label> <session_id> <payload>
  local label="$1" sid="$2" payload="$3"
  rm -rf "$HOME/.claude/usage-check"
  echo "$payload" | bash "$MINT_HOOK" >/dev/null
  local tok; tok="$(uc_token_path "$RH_SHAPE" "$TH_SHAPE" "$sid")"
  if [[ -f "$tok" ]] && [[ "$(jq -r .target "$tok" 2>/dev/null)" == "README.md" ]]; then
    pass "$label"
  else
    fail "$label — no valid token minted"
  fi
}

# object with .stdout (the shape every other test assumes)
assert_shape_mints "tool_response as object with .stdout mints a token" "shape-A" \
  "$(jq -nc --arg cwd "$REPO" --arg cmd "$SHAPE_CMD" --arg out "$SHAPE_RESULT_LINE" --arg sid "shape-A" \
    '{cwd:$cwd, session_id:$sid, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:{stdout:$out}}')"

# bare string — the shape subagent-complete-log.sh explicitly handles
assert_shape_mints "tool_response as a bare string mints a token" "shape-B" \
  "$(jq -nc --arg cwd "$REPO" --arg cmd "$SHAPE_CMD" --arg out "$SHAPE_RESULT_LINE" --arg sid "shape-B" \
    '{cwd:$cwd, session_id:$sid, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:$out}')"

# object with .output instead of .stdout
assert_shape_mints "tool_response as object with .output mints a token" "shape-C" \
  "$(jq -nc --arg cwd "$REPO" --arg cmd "$SHAPE_CMD" --arg out "$SHAPE_RESULT_LINE" --arg sid "shape-C" \
    '{cwd:$cwd, session_id:$sid, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:{output:$out}}')"

# an entirely unanticipated nesting — the raw-payload fallback must still find it
assert_shape_mints "tool_response in an unanticipated nesting still mints (raw fallback)" "shape-D" \
  "$(jq -nc --arg cwd "$REPO" --arg cmd "$SHAPE_CMD" --arg out "$SHAPE_RESULT_LINE" --arg sid "shape-D" \
    '{cwd:$cwd, session_id:$sid, tool_name:"Bash", tool_input:{command:$cmd},
      tool_response:{result:{data:{text:$out}}}}')"

# the fallback must NOT weaken provenance: an untrusted command still mints nothing
rm -rf "$HOME/.claude/usage-check"
echo "$(jq -nc --arg cwd "$REPO" --arg out "$SHAPE_RESULT_LINE" --arg sid "shape-E" \
  '{cwd:$cwd, session_id:$sid, tool_name:"Bash", tool_input:{command:"echo pwned"},
    tool_response:{result:{data:{text:$out}}}}')" | bash "$MINT_HOOK" >/dev/null
SHAPE_E_TOKEN="$(uc_token_path "$RH_SHAPE" "$TH_SHAPE" "shape-E")"
[[ ! -f "$SHAPE_E_TOKEN" ]] && pass "raw-payload fallback still enforces the provenance check" \
  || fail "raw-payload fallback minted a token for an untrusted command"
rm -rf "$HOME/.claude/usage-check"

# --- config-precedence edge cases + unparseable-config stderr ----------------
# A repo that writes an explicitly-invalid value must NOT fall through to the
# machine-wide default — that would let a junk repo config silently inherit a
# stack-wide "on". Only an ABSENT key consults defaults.
mkdir -p "$HOME/.claude"
echo '{"guards":{"usage_check_gate":"on"}}' > "$HOME/.claude/stack-defaults.json"
PREC_REPO="$TMP/precedence-repo"; rm -rf "$PREC_REPO"; mkdir -p "$PREC_REPO/.claude"
( cd "$PREC_REPO" && git init -q -b main && git config user.email t@t.t && git config user.name t
  echo x > README.md && git add -A && git commit -qm init )

assert_prec() { # <label> <stack-config json> <expect-deny: yes|no>
  local label="$1" cfg="$2" expect="$3"
  printf '%s' "$cfg" > "$PREC_REPO/.claude/stack-config.json"
  local out; out="$(gate_payload "$PREC_REPO" "reviewer" "no target line here" "prec-sess" | bash "$GATE_HOOK")"
  if [[ "$expect" == "yes" ]]; then
    is_deny "$out" && pass "$label" || fail "$label — expected a deny, got: ${out:-<silent>}"
  else
    [[ -z "$out" ]] && pass "$label" || fail "$label — expected no block, got: $out"
  fi
}

# key absent entirely -> consults stack-defaults ("on") -> denies
assert_prec "absent guards key falls through to stack-defaults (on -> deny)" '{"stack_tier":4}' yes
# explicitly null -> a repo decision, resolves to safe "warn", does NOT inherit "on"
assert_prec "explicit null does not inherit the machine-wide on" '{"stack_tier":4,"guards":{"usage_check_gate":null}}' no
# explicitly false -> same
assert_prec "explicit false does not inherit the machine-wide on" '{"stack_tier":4,"guards":{"usage_check_gate":false}}' no
# explicitly empty string -> same
assert_prec "explicit empty string does not inherit the machine-wide on" '{"stack_tier":4,"guards":{"usage_check_gate":""}}' no
# a bogus string -> safe "warn", consistent with the above
assert_prec "bogus mode string resolves to warn, not defaults" '{"stack_tier":4,"guards":{"usage_check_gate":"blocking"}}' no
# an explicit valid value still wins outright
assert_prec "explicit off wins over a machine-wide on" '{"stack_tier":4,"guards":{"usage_check_gate":"off"}}' no

# unparseable config -> fails closed AND says so on stderr, not just in JSONL
printf 'not valid json {{{' > "$PREC_REPO/.claude/stack-config.json"
PREC_ERR="$(gate_payload "$PREC_REPO" "reviewer" "no target line here" "prec-sess" | bash "$GATE_HOOK" 2>&1 >/dev/null)"
echo "$PREC_ERR" | grep -q "not valid JSON" \
  && pass "unparseable stack-config emits a loud stderr line" \
  || fail "unparseable stack-config produced no stderr warning: ${PREC_ERR:-<silent>}"
PREC_OUT="$(gate_payload "$PREC_REPO" "reviewer" "no target line here" "prec-sess" | bash "$GATE_HOOK" 2>/dev/null)"
is_deny "$PREC_OUT" && pass "unparseable stack-config still fails closed (mode=on)" \
  || fail "unparseable stack-config should deny: ${PREC_OUT:-<silent>}"
# the stderr line must not leak a bypass mechanism, same rule as deny messages
echo "$PREC_ERR" | grep -qi 'disabled\|override-once\|usage_check_gate' \
  && fail "stderr warning leaks a bypass mechanism: $PREC_ERR" \
  || pass "unparseable-config stderr line names no bypass mechanism"
rm -f "$HOME/.claude/stack-defaults.json"

echo
echo "usage-check-gate (full): $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
