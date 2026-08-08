#!/usr/bin/env bash
# Tests for scripts/lib/hook-metadata.py and the hook-aware
# scripts/gen-capability-registry.sh (docs/ADRs/043-capability-registry-hooks-and-live-state.md).
#
# Every case here runs against a synthetic fixture repo root built under a
# temp dir and passed via --repo-root — never against the real repo. That is
# deliberate: D14 requires --repo-root to be a required argument with NO
# $0-relative fallback, specifically so a fixture run cannot silently read the
# real repo's hooks/config. Case T19 asserts that property directly.
#
# Case-to-ADR-bullet map (ADR-043, "tests/test-capability-registry.sh" section
# of the Test plan, bullets in document order):
#   T01 -> bullet  1  valid summary produces one entry with that exact summary
#   T02 -> bullet  2  summary on a non-line-2 line inside the leading block
#   T03 -> bullet  3  summary-shaped text after the leading block is not picked up
#   T04 -> bullet  4  hook with no summary -> exit 1, stderr names the file
#   T05 -> bullet  5  summary >200 chars truncated
#   T06 -> bullet  6  statusLine-only wiring -> events:["statusLine"], matchers:[]
#   T07 -> bullet  7  doubly-matchered hook -> matchers sorted+deduped, wired_in sorted
#   T08 -> bullet  8  hook wired in hooks.json AND a template -> wired_in has both, events unioned
#   T09 -> bullet  9  formatting tolerance (D3/High-3): reformatted wiring, byte-identical entry
#   T10 -> bullet 10  empty-string matcher -> omitted, not ""
#   T11 -> bullet 11  command under an unrecognized top-level key -> exit 1, names file+path
#   T12 -> bullet 12  tier_min derived for one tier-0/1/2 fixture hook each
#   T13 -> bullet 13  hook in no tier manifest -> exit 1 naming the file
#   T14 -> bullet 14  hook wired nowhere -> exit 1 naming the file
#   T15 -> bullet 15  hook id == skill id -> exit 1 (duplicate id, D6)
#   T16 -> bullet 16  recommendable/user_invocable/model_invocable=false, invocation.slash=null
#   T17 -> bullet 17  capabilities[] sorted by id across all three kinds
#   T18 -> bullet 18  entry counts derived from globs, never literals
#   T19 -> bullet 19  --repo-root <fixture> reads nothing outside the fixture
#   T20 -> bullet 20  --lint: silent exit 0 on valid, exit 1 same message on invalid
#   T21 -> bullet 21  --check: exit 0 fresh, exit 1 after mutating a committed summary
#   T22 -> bullet 22  --check: exit 1 when the committed registry is missing
#   T23 -> bullet 23  skill/subagent entry shape is byte-identical to pre-ADR-043 output
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_META="$REPO_ROOT/scripts/lib/hook-metadata.py"
GEN="$REPO_ROOT/scripts/gen-capability-registry.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }

[[ -f "$HOOK_META" ]] || echo "NOTE: $HOOK_META does not exist yet (D14) — cases below are expected to fail until it lands."
[[ -f "$GEN" ]] || echo "NOTE: $GEN does not exist."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2 | actual: $3)"; fi
}
assert_rc() {
  # assert_rc <label> <expected-rc> <actual-rc>
  if [[ "$3" -eq "$2" ]]; then pass "$1"; else fail "$1 (expected rc=$2, got rc=$3)"; fi
}
assert_contains() {
  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in: $2)"; fi
}
assert_not_contains() {
  # assert_not_contains <label> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly found '$3' in: $2)"; fi
}

# ─── Fixture builders ─────────────────────────────────────────────────────────

# mkfixture <dir> — minimal skeleton: hooks/, empty wiring files, empty tier
# manifests. No skills/agents (hook-metadata.py itself never reads them).
mkfixture() {
  local dir="$1"
  mkdir -p "$dir/hooks" "$dir/config/tier-manifests"
  echo '{"hooks":{}}' > "$dir/hooks/hooks.json"
  echo '{"hooks":{}}' > "$dir/config/settings.global.template.json"
  echo '{"hooks":{}}' > "$dir/config/settings.tier-1.template.json"
  echo '{"hooks":{}}' > "$dir/config/settings.team.template.json"
  echo '{"tier":0,"files":{"global":[]}}' > "$dir/config/tier-manifests/tier-0.json"
  echo '{"tier":1,"files":{"global":[]}}' > "$dir/config/tier-manifests/tier-1.json"
  echo '{"tier":2,"files":{"global":[]}}' > "$dir/config/tier-manifests/tier-2.json"
}

# add_skill <dir> <id> — used only by generator-level cases (T15/T17/T18/T23).
add_skill() {
  local dir="$1" id="$2"
  mkdir -p "$dir/skills/$id"
  cat > "$dir/skills/$id/SKILL.md" <<EOF
---
name: $id
description: Fixture skill $id for the capability-registry test suite.
---
Body text.
EOF
}

# add_agent <dir> <id>
add_agent() {
  local dir="$1" id="$2"
  mkdir -p "$dir/agents"
  cat > "$dir/agents/$id.md" <<EOF
---
name: $id
description: Fixture subagent $id for the capability-registry test suite.
---
Body text.
EOF
}

# write_hook <dir> <id> <leading-block-line>... -- <code-line>...
# Writes hooks/<id>.sh: line 1 shebang, then the leading-block lines (each
# should start with '#' to stay inside the scanned block unless a case is
# deliberately testing where the block ends), then the code lines verbatim.
write_hook() {
  local dir="$1" id="$2"; shift 2
  local leading=() code=() in_code=false
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then in_code=true; continue; fi
    if $in_code; then code+=("$arg"); else leading+=("$arg"); fi
  done
  {
    printf '#!/usr/bin/env bash\n'
    if [[ ${#leading[@]} -gt 0 ]]; then printf '%s\n' "${leading[@]}"; fi
    if [[ ${#code[@]} -gt 0 ]]; then printf '%s\n' "${code[@]}"; fi
  } > "$dir/hooks/$id.sh"
  chmod +x "$dir/hooks/$id.sh"
}

# wire_no_matcher <file> <event> <hookpath> — wired with no matcher key at all
# (the "absent matcher" case — distinct from T10's explicit "" case).
wire_no_matcher() {
  local file="$1" event="$2" hookpath="$3"
  local cmd='${CLAUDE_PLUGIN_ROOT}/'"$hookpath"
  jq --arg ev "$event" --arg cmd "$cmd" \
    '.hooks[$ev] = ((.hooks[$ev] // []) + [{"hooks":[{"type":"command","command":$cmd}]}])' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# wire_matcher <file> <event> <matcher> <hookpath>
wire_matcher() {
  local file="$1" event="$2" matcher="$3" hookpath="$4"
  local cmd='${CLAUDE_PLUGIN_ROOT}/'"$hookpath"
  jq --arg ev "$event" --arg m "$matcher" --arg cmd "$cmd" \
    '.hooks[$ev] = ((.hooks[$ev] // []) + [{"matcher":$m,"hooks":[{"type":"command","command":$cmd}]}])' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# wire_statusline <file> <hookpath>
wire_statusline() {
  local file="$1" hookpath="$2"
  local cmd='${CLAUDE_PLUGIN_ROOT}/'"$hookpath"
  jq --arg cmd "$cmd" '.statusLine = {"type":"command","command":$cmd}' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# add_to_manifest <dir> <tier> <hookpath>
add_to_manifest() {
  local dir="$1" tier="$2" hookpath="$3"
  local mf="$dir/config/tier-manifests/tier-$tier.json"
  jq --arg from "$hookpath" \
    '.files.global += [{"from":$from,"to":("~/.claude/"+$from),"executable":true}]' \
    "$mf" > "$mf.tmp" && mv "$mf.tmp" "$mf"
}

hook_glob_count()  { ls "$1"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' '; }
skill_glob_count() { find "$1/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' '; }
agent_glob_count() { ls "$1"/agents/*.md 2>/dev/null | wc -l | tr -d ' '; }

# ─── Invocation helpers — set globals OUT / ERR / RC ─────────────────────────

run_meta() {
  local dir="$1" errfile; errfile=$(mktemp)
  OUT=$(python3 "$HOOK_META" --repo-root "$dir" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_meta_lint() {
  local dir="$1" errfile; errfile=$(mktemp)
  OUT=$(python3 "$HOOK_META" --repo-root "$dir" --lint 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_meta_no_root() {
  local errfile; errfile=$(mktemp)
  OUT=$(python3 "$HOOK_META" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_gen() {
  local dir="$1" errfile; errfile=$(mktemp)
  OUT=$(bash "$GEN" --repo-root "$dir" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_gen_check() {
  local dir="$1" errfile; errfile=$(mktemp)
  OUT=$(bash "$GEN" --repo-root "$dir" --check 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}

# ═══ T01 (bullet 1): valid summary -> one hook entry with that exact summary ═
D01="$TMP/t01"; mkfixture "$D01"
write_hook "$D01" valid-summary-hook \
  '# summary: Does the sample thing for testing.'
wire_no_matcher "$D01/hooks/hooks.json" UserPromptSubmit hooks/valid-summary-hook.sh
add_to_manifest "$D01" 0 hooks/valid-summary-hook.sh

run_meta "$D01"
assert_rc "T01: exit 0 on valid fixture" 0 "$RC"
assert_eq "T01: exactly one entry" "1" "$(echo "$OUT" | jq 'length')"
assert_eq "T01: id" "valid-summary-hook" "$(echo "$OUT" | jq -r '.[0].id')"
assert_eq "T01: kind == hook" "hook" "$(echo "$OUT" | jq -r '.[0].kind')"
assert_eq "T01: exact summary text" "Does the sample thing for testing." "$(echo "$OUT" | jq -r '.[0].summary')"

# ═══ T02 (bullet 2): summary on a line other than line 2, still in the block ═
D02="$TMP/t02"; mkfixture "$D02"
write_hook "$D02" leading-block-hook \
  '# PreToolUse hook: prose line first.' \
  '# more prose before the summary line' \
  '# summary: Found even though not on line two.'
wire_no_matcher "$D02/hooks/hooks.json" UserPromptSubmit hooks/leading-block-hook.sh
add_to_manifest "$D02" 0 hooks/leading-block-hook.sh

run_meta "$D02"
assert_rc "T02: exit 0" 0 "$RC"
assert_eq "T02: summary found off line 2" "Found even though not on line two." \
  "$(echo "$OUT" | jq -r '.[] | select(.id=="leading-block-hook") | .summary')"

# ═══ T03 (bullet 3): summary-shaped text after the leading block is ignored ══
D03="$TMP/t03"; mkfixture "$D03"
write_hook "$D03" code-only-summary-hook \
  '# prose only, no summary here yet' \
  -- \
  'echo "starting"' \
  '# summary: this should NOT be picked up (in code section)' \
  'echo hi'
wire_no_matcher "$D03/hooks/hooks.json" UserPromptSubmit hooks/code-only-summary-hook.sh
add_to_manifest "$D03" 0 hooks/code-only-summary-hook.sh

run_meta "$D03"
assert_rc "T03: exit 1 (summary only in code, not the leading block)" 1 "$RC"
assert_contains "T03: stderr names the file" "$ERR" "hooks/code-only-summary-hook.sh"
assert_contains "T03: stderr message shape confirms missing-summary (not some other failure)" "$ERR" "no '# summary:' line"

# ═══ T04 (bullet 4): hook with no summary anywhere -> exit 1, names the file ═
D04="$TMP/t04"; mkfixture "$D04"
write_hook "$D04" no-summary-hook \
  '# just a description, no summary key' \
  -- \
  'echo hi'
wire_no_matcher "$D04/hooks/hooks.json" UserPromptSubmit hooks/no-summary-hook.sh
add_to_manifest "$D04" 0 hooks/no-summary-hook.sh

run_meta "$D04"
assert_rc "T04: exit 1" 1 "$RC"
assert_contains "T04: stderr names the file" "$ERR" "hooks/no-summary-hook.sh"
assert_contains "T04: stderr message shape" "$ERR" "no '# summary:' line"

# ═══ T05 (bullet 5): summary longer than 200 chars is truncated ═════════════
D05="$TMP/t05"; mkfixture "$D05"
LONG_250=$(printf 'A%.0s' $(seq 1 250))
EXPECT_200=$(printf 'A%.0s' $(seq 1 200))
write_hook "$D05" long-summary-hook \
  "# summary: $LONG_250"
wire_no_matcher "$D05/hooks/hooks.json" UserPromptSubmit hooks/long-summary-hook.sh
add_to_manifest "$D05" 0 hooks/long-summary-hook.sh

run_meta "$D05"
assert_rc "T05: exit 0" 0 "$RC"
GOT_SUMMARY=$(echo "$OUT" | jq -r '.[0].summary')
assert_eq "T05: summary truncated to 200 chars" "$EXPECT_200" "$GOT_SUMMARY"
assert_eq "T05: summary length == 200" "200" "${#GOT_SUMMARY}"

# ═══ T06 (bullet 6): statusLine-only wiring -> events:["statusLine"] ════════
D06="$TMP/t06"; mkfixture "$D06"
write_hook "$D06" statusline \
  '# summary: Renders the custom status line.'
wire_statusline "$D06/config/settings.global.template.json" hooks/statusline.sh
add_to_manifest "$D06" 0 hooks/statusline.sh

run_meta "$D06"
assert_rc "T06: exit 0" 0 "$RC"
assert_eq "T06: events == [statusLine]" '["statusLine"]' \
  "$(echo "$OUT" | jq -c '.[0].hook.events')"
assert_eq "T06: matchers == [] (not an empty events list)" '[]' \
  "$(echo "$OUT" | jq -c '.[0].hook.matchers')"

# ═══ T07 (bullet 7): doubly-matchered hook -> matchers sorted+deduped ═══════
D07="$TMP/t07"; mkfixture "$D07"
write_hook "$D07" schema-deploy-gate \
  '# summary: Gates schema-changing commands behind review.'
wire_matcher "$D07/config/settings.team.template.json" PreToolUse Supabase hooks/schema-deploy-gate.sh
wire_matcher "$D07/config/settings.team.template.json" PreToolUse Bash hooks/schema-deploy-gate.sh
wire_matcher "$D07/config/settings.team.template.json" PreToolUse Bash hooks/schema-deploy-gate.sh  # duplicate, must dedupe
add_to_manifest "$D07" 2 hooks/schema-deploy-gate.sh

run_meta "$D07"
assert_rc "T07: exit 0" 0 "$RC"
assert_eq "T07: matchers sorted+deduped == [Bash, Supabase]" '["Bash","Supabase"]' \
  "$(echo "$OUT" | jq -c '.[0].hook.matchers')"
assert_eq "T07: wired_in names the one file it's wired in" '["config/settings.team.template.json"]' \
  "$(echo "$OUT" | jq -c '.[0].hook.wired_in')"

# ═══ T08 (bullet 8): wired in both hooks.json and a template -> both, union ══
D08="$TMP/t08"; mkfixture "$D08"
write_hook "$D08" double-wired-hook \
  '# summary: Wired in two places on purpose.'
wire_no_matcher "$D08/hooks/hooks.json" UserPromptSubmit hooks/double-wired-hook.sh
wire_no_matcher "$D08/config/settings.global.template.json" SessionStart hooks/double-wired-hook.sh
add_to_manifest "$D08" 0 hooks/double-wired-hook.sh

run_meta "$D08"
assert_rc "T08: exit 0" 0 "$RC"
assert_eq "T08: wired_in has both files, sorted" \
  '["config/settings.global.template.json","hooks/hooks.json"]' \
  "$(echo "$OUT" | jq -c '.[0].hook.wired_in')"
assert_eq "T08: events unioned and sorted" '["SessionStart","UserPromptSubmit"]' \
  "$(echo "$OUT" | jq -c '.[0].hook.events')"

# ═══ T09 (bullet 9): formatting tolerance — reformatted wiring is byte-identical ═
# Fixture A: compact, matcher-before-hooks key order. Fixture B: same wiring,
# reformatted with an extra nesting level, keys reordered, whitespace changed.
D09A="$TMP/t09a"; mkfixture "$D09A"
write_hook "$D09A" reformat-hook '# summary: Same wiring, different JSON formatting.'
cat > "$D09A/config/settings.team.template.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/reformat-hook.sh"}]}]}}
EOF
add_to_manifest "$D09A" 0 hooks/reformat-hook.sh

D09B="$TMP/t09b"; mkfixture "$D09B"
write_hook "$D09B" reformat-hook '# summary: Same wiring, different JSON formatting.'
cat > "$D09B/config/settings.team.template.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "group": {
          "hooks": [
            {
              "command": "${CLAUDE_PLUGIN_ROOT}/hooks/reformat-hook.sh",
              "type": "command"
            }
          ],
          "matcher": "Bash"
        }
      }
    ]
  }
}
EOF
add_to_manifest "$D09B" 0 hooks/reformat-hook.sh

run_meta "$D09A"; ENTRY_A=$(echo "$OUT" | jq -c '.[0]')
RC_A=$RC
run_meta "$D09B"; ENTRY_B=$(echo "$OUT" | jq -c '.[0]')
RC_B=$RC

assert_rc "T09: fixture A exit 0" 0 "$RC_A"
assert_rc "T09: fixture B (extra nesting + reorder) exit 0" 0 "$RC_B"
assert_contains "T09: fixture A produced a real entry (not an empty/failed run)" "$ENTRY_A" "reformat-hook"
assert_contains "T09: fixture B produced a real entry (not an empty/failed run)" "$ENTRY_B" "reformat-hook"
assert_eq "T09: byte-identical hook entry across reformatted wiring" "$ENTRY_A" "$ENTRY_B"

# ═══ T10 (bullet 10): empty-string matcher -> omitted, not "" ═══════════════
D10="$TMP/t10"; mkfixture "$D10"
write_hook "$D10" empty-matcher-hook '# summary: Wired with an explicit empty-string matcher.'
wire_matcher "$D10/hooks/hooks.json" PreToolUse "" hooks/empty-matcher-hook.sh
add_to_manifest "$D10" 0 hooks/empty-matcher-hook.sh

run_meta "$D10"
assert_rc "T10: exit 0" 0 "$RC"
assert_eq "T10: matchers == [] (empty string omitted, not emitted as \"\")" '[]' \
  "$(echo "$OUT" | jq -c '.[0].hook.matchers')"

# ═══ T11 (bullet 11): command under an unrecognized top-level key -> exit 1 ═
D11="$TMP/t11"; mkfixture "$D11"
write_hook "$D11" bad-container-hook '# summary: Wired somewhere the scanner should reject.'
# Also wire it properly elsewhere, so the only possible failure is the bad
# container below — a hook otherwise wired-somewhere must still be rejected
# the moment ANY reference sits under an unrecognized top-level key.
wire_no_matcher "$D11/hooks/hooks.json" UserPromptSubmit hooks/bad-container-hook.sh
jq --arg cmd '${CLAUDE_PLUGIN_ROOT}/hooks/bad-container-hook.sh' \
  '.weirdKey = {"command":$cmd}' "$D11/config/settings.team.template.json" \
  > "$D11/config/settings.team.template.json.tmp" \
  && mv "$D11/config/settings.team.template.json.tmp" "$D11/config/settings.team.template.json"
add_to_manifest "$D11" 0 hooks/bad-container-hook.sh

run_meta "$D11"
assert_rc "T11: exit 1 (unrecognized container)" 1 "$RC"
assert_contains "T11: stderr names the file" "$ERR" "config/settings.team.template.json"
assert_contains "T11: stderr names the hook" "$ERR" "hooks/bad-container-hook.sh"
assert_contains "T11: stderr names the JSON path" "$ERR" "\$.weirdKey.command"
assert_contains "T11: stderr calls it out as unrecognized" "$ERR" "unrecognized container"

# ═══ T12 (bullet 12): tier_min derived for one tier-0/1/2 fixture hook each ══
D12="$TMP/t12"; mkfixture "$D12"
for spec in "tier0-hook:0" "tier1-hook:1" "tier2-hook:2"; do
  id="${spec%%:*}"; tier="${spec##*:}"
  write_hook "$D12" "$id" "# summary: Tier $tier fixture hook."
  wire_no_matcher "$D12/hooks/hooks.json" UserPromptSubmit "hooks/$id.sh"
  add_to_manifest "$D12" "$tier" "hooks/$id.sh"
done

run_meta "$D12"
assert_rc "T12: exit 0" 0 "$RC"
assert_eq "T12: tier0-hook tier_min == 0" "0" "$(echo "$OUT" | jq -r '.[] | select(.id=="tier0-hook") | .tier_min')"
assert_eq "T12: tier1-hook tier_min == 1" "1" "$(echo "$OUT" | jq -r '.[] | select(.id=="tier1-hook") | .tier_min')"
assert_eq "T12: tier2-hook tier_min == 2" "2" "$(echo "$OUT" | jq -r '.[] | select(.id=="tier2-hook") | .tier_min')"

# ═══ T13 (bullet 13): hook in no tier manifest -> exit 1 naming the file ════
D13="$TMP/t13"; mkfixture "$D13"
write_hook "$D13" no-manifest-hook '# summary: Valid and wired, but in no tier manifest.'
wire_no_matcher "$D13/hooks/hooks.json" UserPromptSubmit hooks/no-manifest-hook.sh
# deliberately: no add_to_manifest call

run_meta "$D13"
assert_rc "T13: exit 1" 1 "$RC"
assert_contains "T13: stderr names the file" "$ERR" "hooks/no-manifest-hook.sh"
assert_contains "T13: stderr message shape" "$ERR" "no tier manifest"

# ═══ T14 (bullet 14): hook wired in no wiring file -> exit 1 naming the file ═
D14="$TMP/t14"; mkfixture "$D14"
write_hook "$D14" unwired-hook '# summary: Valid and tiered, but wired nowhere.'
add_to_manifest "$D14" 0 hooks/unwired-hook.sh
# deliberately: no wire_* call

run_meta "$D14"
assert_rc "T14: exit 1" 1 "$RC"
assert_contains "T14: stderr names the file" "$ERR" "hooks/unwired-hook.sh"
assert_contains "T14: stderr message shape" "$ERR" "not wired in any settings template or hooks.json"

# ═══ T15 (bullet 15): hook id == skill id -> exit 1, duplicate id (D6) ══════
D15="$TMP/t15"; mkfixture "$D15"
add_skill "$D15" sample-skill
add_agent "$D15" sample-agent
write_hook "$D15" sample-skill '# summary: Deliberately collides with the sample-skill skill id.'
wire_no_matcher "$D15/hooks/hooks.json" UserPromptSubmit hooks/sample-skill.sh
add_to_manifest "$D15" 0 hooks/sample-skill.sh

run_gen "$D15"
assert_rc "T15: generator exits 1 on duplicate id" 1 "$RC"
assert_contains "T15: stderr names the duplicate id" "$ERR" "duplicate capability id 'sample-skill'"
assert_contains "T15: stderr names both kinds" "$ERR" "skill and hook"

# ═══ T16 (bullet 16): hook entries are always non-recommendable/non-invocable ═
D16="$TMP/t16"; mkfixture "$D16"
write_hook "$D16" recommend-flags-hook '# summary: Checked only for its recommendability flags.'
wire_no_matcher "$D16/hooks/hooks.json" UserPromptSubmit hooks/recommend-flags-hook.sh
add_to_manifest "$D16" 0 hooks/recommend-flags-hook.sh

run_meta "$D16"
assert_rc "T16: exit 0" 0 "$RC"
ENTRY16=$(echo "$OUT" | jq -c '.[0]')
assert_eq "T16: recommendable == false" "false" "$(echo "$ENTRY16" | jq -r '.recommendable')"
assert_eq "T16: user_invocable == false" "false" "$(echo "$ENTRY16" | jq -r '.user_invocable')"
assert_eq "T16: model_invocable == false" "false" "$(echo "$ENTRY16" | jq -r '.model_invocable')"
assert_eq "T16: invocation.slash == null" "null" "$(echo "$ENTRY16" | jq -r '.invocation.slash')"

# ═══ T17 (bullet 17): capabilities[] sorted by id across all three kinds ════
D17="$TMP/t17"; mkfixture "$D17"
add_skill "$D17" sample-skill
add_agent "$D17" sample-agent
write_hook "$D17" aaa-hook '# summary: Sorts first alphabetically.'
write_hook "$D17" zzz-hook '# summary: Sorts last alphabetically.'
wire_no_matcher "$D17/hooks/hooks.json" UserPromptSubmit hooks/aaa-hook.sh
wire_no_matcher "$D17/hooks/hooks.json" UserPromptSubmit hooks/zzz-hook.sh
add_to_manifest "$D17" 0 hooks/aaa-hook.sh
add_to_manifest "$D17" 0 hooks/zzz-hook.sh

run_gen "$D17"
assert_rc "T17: generator exit 0" 0 "$RC"
REG17="$D17/config/capability-registry.json"
assert_eq "T17: capabilities[] sorted by id across kinds" \
  '["aaa-hook","sample-agent","sample-skill","zzz-hook"]' \
  "$(jq -c '[.capabilities[].id]' "$REG17")"

# ═══ T18 (bullet 18): entry counts derived from globs, never literals ═══════
D18="$TMP/t18"; mkfixture "$D18"
add_skill "$D18" skill-one
add_skill "$D18" skill-two
add_agent "$D18" agent-one
add_agent "$D18" agent-two
for i in 1 2 3; do
  id="count-hook-$i"
  write_hook "$D18" "$id" "# summary: Count fixture hook $i."
  wire_no_matcher "$D18/hooks/hooks.json" UserPromptSubmit "hooks/$id.sh"
  add_to_manifest "$D18" 0 "hooks/$id.sh"
done

run_gen "$D18"
assert_rc "T18: generator exit 0" 0 "$RC"
REG18="$D18/config/capability-registry.json"
EXPECT_HOOKS=$(hook_glob_count "$D18")
EXPECT_SKILLS=$(skill_glob_count "$D18")
EXPECT_AGENTS=$(agent_glob_count "$D18")
EXPECT_TOTAL=$((EXPECT_HOOKS + EXPECT_SKILLS + EXPECT_AGENTS))
assert_eq "T18: hook entry count == hooks/*.sh glob count (not a literal)" \
  "$EXPECT_HOOKS" "$(jq '[.capabilities[]|select(.kind=="hook")]|length' "$REG18")"
assert_eq "T18: total entry count == skills+agents+hooks glob counts (not a literal)" \
  "$EXPECT_TOTAL" "$(jq '.capabilities|length' "$REG18")"

# ═══ T19 (bullet 19): --repo-root <fixture> reads nothing outside the fixture ═
D19="$TMP/t19"; mkfixture "$D19"
write_hook "$D19" zz-fixture-only-hook '# summary: Exists only in this fixture, never in the real repo.'
wire_no_matcher "$D19/hooks/hooks.json" UserPromptSubmit hooks/zz-fixture-only-hook.sh
add_to_manifest "$D19" 0 hooks/zz-fixture-only-hook.sh

run_meta "$D19"
assert_rc "T19: exit 0 against fixture root (real repo present on disk)" 0 "$RC"
assert_eq "T19: output has exactly the fixture's 1 hook, not the real repo's ~24-25" \
  "1" "$(echo "$OUT" | jq 'length')"
assert_not_contains "T19: real-repo-only hook id 'dispatch-nudge' absent from output" \
  "$OUT" "dispatch-nudge"
assert_not_contains "T19: real-repo-only hook id 'session-prefs-init' absent from output" \
  "$OUT" "session-prefs-init"
assert_contains "T19: fixture-only hook id is present" "$OUT" "zz-fixture-only-hook"

# T19b (D14 hard requirement, same load-bearing property): omitting --repo-root
# entirely must fail, not silently fall back to $0's directory.
run_meta_no_root
if [[ "$RC" -ne 0 ]]; then
  pass "T19b: --repo-root omitted -> nonzero exit (no \$0 fallback)"
else
  fail "T19b: --repo-root omitted should fail, but exited 0"
fi

# ═══ T20 (bullet 20): --lint silent on success, same message on failure ═════
run_meta_lint "$D01"   # D01 is T01's valid fixture
assert_rc "T20: --lint exit 0 on valid fixture" 0 "$RC"
assert_eq "T20: --lint prints nothing to stdout on success" "" "$OUT"

run_meta "$D04"; ERR_PLAIN="$ERR"; RC_PLAIN="$RC"
run_meta_lint "$D04"; ERR_LINT="$ERR"; RC_LINT="$RC"
assert_rc "T20: --lint exit 1 on invalid fixture" 1 "$RC_LINT"
assert_eq "T20: --lint stderr matches the non-lint failure message" "$ERR_PLAIN" "$ERR_LINT"
assert_rc "T20: sanity — non-lint run on same fixture also exits 1" 1 "$RC_PLAIN"

# ═══ T21 (bullet 21): --check exit 0 fresh, exit 1 after mutating a summary ══
D21="$TMP/t21"; mkfixture "$D21"
add_skill "$D21" sample-skill
add_agent "$D21" sample-agent
write_hook "$D21" check-hook '# summary: Used only by the --check freshness cases.'
wire_no_matcher "$D21/hooks/hooks.json" UserPromptSubmit hooks/check-hook.sh
add_to_manifest "$D21" 0 hooks/check-hook.sh

run_gen "$D21"
assert_rc "T21: generator exit 0 (writes committed registry)" 0 "$RC"

run_gen_check "$D21"
assert_rc "T21: --check exit 0 immediately after generation" 0 "$RC"

REG21="$D21/config/capability-registry.json"
# Mutate the HOOK entry's summary specifically (not "whichever entry sorts
# first") — this is what proves a stale hook summary trips the CI freshness
# gate, the exact invariant D2/D14 are buying.
jq '(.capabilities[] | select(.kind=="hook" and .id=="check-hook") | .summary) = "mutated summary that does not match the source"' \
  "$REG21" > "$REG21.tmp" && mv "$REG21.tmp" "$REG21"

run_gen_check "$D21"
assert_rc "T21: --check exit 1 after mutating a committed hook summary" 1 "$RC"

# ═══ T22 (bullet 22): --check exit 1 when the committed registry is missing ══
D22="$TMP/t22"; mkfixture "$D22"
add_skill "$D22" sample-skill
add_agent "$D22" sample-agent
write_hook "$D22" never-generated-hook '# summary: Never generated before --check runs.'
wire_no_matcher "$D22/hooks/hooks.json" UserPromptSubmit hooks/never-generated-hook.sh
add_to_manifest "$D22" 0 hooks/never-generated-hook.sh
# deliberately: no run_gen call first — config/capability-registry.json never written

run_gen_check "$D22"
assert_rc "T22: --check exit 1 when committed registry is missing" 1 "$RC"
assert_contains "T22: stderr explains the missing registry" "$ERR" "committed registry missing"

# ═══ T23 (bullet 23): skill/subagent entry shape unchanged (no ADR-017 regression) ═
D23="$TMP/t23"; mkfixture "$D23"
add_skill "$D23" sample-skill
add_agent "$D23" sample-agent
write_hook "$D23" shape-check-hook '# summary: Present so the fixture also exercises hook splicing.'
wire_no_matcher "$D23/hooks/hooks.json" UserPromptSubmit hooks/shape-check-hook.sh
add_to_manifest "$D23" 0 hooks/shape-check-hook.sh

run_gen "$D23"
assert_rc "T23: generator exit 0" 0 "$RC"
REG23="$D23/config/capability-registry.json"

EXPECT_SKILL_ENTRY='{"id":"sample-skill","kind":"skill","summary":"Fixture skill sample-skill for the capability-registry test suite.","invocation":{"slash":"/sample-skill","natural_language":"fixture skill sample-skill for the capability-registry test suite"},"tier_min":0,"user_invocable":true,"model_invocable":true,"recommendable":true}'
EXPECT_AGENT_ENTRY='{"id":"sample-agent","kind":"subagent","summary":"Fixture subagent sample-agent for the capability-registry test suite.","invocation":{"slash":null,"natural_language":"fixture subagent sample-agent for the capability-registry test suite"},"tier_min":0,"user_invocable":false,"model_invocable":true,"recommendable":true}'

GOT_SKILL_ENTRY=$(jq -Sc '.capabilities[] | select(.id=="sample-skill")' "$REG23")
GOT_AGENT_ENTRY=$(jq -Sc '.capabilities[] | select(.id=="sample-agent")' "$REG23")
EXPECT_SKILL_SORTED=$(echo "$EXPECT_SKILL_ENTRY" | jq -Sc '.')
EXPECT_AGENT_SORTED=$(echo "$EXPECT_AGENT_ENTRY" | jq -Sc '.')

assert_eq "T23: skill entry shape/content unchanged by hook splicing" \
  "$EXPECT_SKILL_SORTED" "$GOT_SKILL_ENTRY"
assert_eq "T23: subagent entry shape/content unchanged by hook splicing" \
  "$EXPECT_AGENT_SORTED" "$GOT_AGENT_ENTRY"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
