#!/usr/bin/env bash
# Tests for scripts/stack-sync.sh and scripts/lib/repo-walk.sh — ADR-068.
#
# Every case builds a throwaway repo under a temp root and runs the real script
# against it, so the shipped logic is what is exercised.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$REPO_ROOT/scripts/stack-sync.sh"
PASS=0; FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-sync-test.XXXXXX")" || exit 1
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# mkrepo <name> <json>
mkrepo() {
  local d="$TMPROOT/$1"; mkdir -p "$d/.claude"
  printf '%s' "$2" > "$d/.claude/stack-config.json"
  printf '%s\n' "$d"
}
sync1()  { bash "$SYNC" --repo "$1" >/dev/null 2>&1; }
field()  { jq -r "$2" "$1/.claude/stack-config.json"; }

echo "=== stack-sync ==="

# 1 — a missing key is added, and a kept field is untouched.
R=$(mkrepo add-key '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","sensitivity":{"level":"confidential","notes":"keep me"}}')
sync1 "$R" --apply >/dev/null 2>&1; bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "missing key added (brevity)"        "$(field "$R" 'has("brevity")')" "true"
check "keep-list survives (sensitivity)"   "$(field "$R" '.sensitivity.level')" "confidential"

# 2 — D11: tier lifted to the floor, never lowered.
R=$(mkrepo tier-lift '{"stack_version":"1.3.1","stack_tier":1,"purpose":"p","created":"2026-01-01"}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "tier 1 lifted to 4"                 "$(field "$R" '.stack_tier')" "4"
R=$(mkrepo tier-high '{"stack_version":"1.3.1","stack_tier":5,"purpose":"p","created":"2026-01-01"}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "tier 5 not lowered"                 "$(field "$R" '.stack_tier')" "5"

# 3 — D11a: lift precedes D3a, so a lifted repo receives a loop policy.
check "lifted repo gains loop_policy"      "$(field "$TMPROOT/tier-lift" 'has("loop_policy")')" "true"

# 4 — D3a branch 2: preset merges, and the invariant field survives.
R=$(mkrepo half-l4 '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","loop_policy":{"level":"L4"}}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "half-applied L4 gets iterations"    "$(field "$R" '.loop_policy.max_iterations')" "250"
check "L4 autonomy applied"                "$(field "$R" '.loop_policy.default_autonomy')" "bounded-autonomous"
check "invariant survives preset merge"    "$(field "$R" '.loop_policy.irreversible_actions_break_loop')" "true"
check "L4 cap from preset, not ladder"     "$(field "$R" '.cost_protection.per_session_hard_cap_usd')" "120"

# 5 — D3a branch 3: a hand-set value with no declared level is not overwritten.
R=$(mkrepo custom-budget '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","cost_protection":{"per_session_alert_usd":10,"per_day_alert_usd":100,"per_session_hard_cap_usd":null}}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "custom alert preserved"             "$(field "$R" '.cost_protection.per_session_alert_usd')" "10"
check "uncapped repo gains ladder cap"     "$(field "$R" '.cost_protection.per_session_hard_cap_usd')" "50"

# 6 — D10: an existing cap is neither raised nor lowered.
R=$(mkrepo has-cap '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","cost_protection":{"per_session_alert_usd":5,"per_day_alert_usd":50,"per_session_hard_cap_usd":50}}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "existing cap untouched"             "$(field "$R" '.cost_protection.per_session_hard_cap_usd')" "50"

# 7 — D10: a recorded cap-clear is honored, not silently re-capped.
R=$(mkrepo cleared-cap '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","change_history":[{"setting":"cost_protection.per_session_hard_cap_usd","new_value":"null","reason":"deliberate"}],"cost_protection":{"per_session_alert_usd":5,"per_day_alert_usd":50,"per_session_hard_cap_usd":null}}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "recorded clear is honored"          "$(field "$R" '.cost_protection.per_session_hard_cap_usd')" "null"

# 8 — D5: the roster always collapses to [].
R=$(mkrepo roster '{"stack_version":"1.3.1","stack_tier":4,"purpose":"p","created":"2026-01-01","active_subagents":["architect","implementer"]}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "stale roster becomes []"            "$(field "$R" '.active_subagents | length')" "0"

# 9 — D4: schema-required fields are synthesized.
R=$(mkrepo bare '{"stack_tier":2,"domain_mode":null}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
check "stack_version synthesized"          "$(field "$R" '.stack_version != null')" "true"
check "purpose synthesized"                "$(field "$R" '.purpose != null')" "true"
check "created synthesized"                "$(field "$R" '.created != null')" "true"

# 10 — a config with no stack_tier is refused and left untouched.
R=$(mkrepo no-tier '{"stack_version":"1.3.1","purpose":"p","created":"2026-01-01"}')
before="$(cat "$R/.claude/stack-config.json")"
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1; rc=$?
check "no stack_tier exits non-zero"       "$( ((rc!=0)) && echo yes || echo no)" "yes"
check "no stack_tier leaves file intact"   "$(cat "$R/.claude/stack-config.json")" "$before"

# 11 — malformed JSON fails without writing.
R=$(mkrepo broken '{not json')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1; rc=$?
check "malformed JSON exits non-zero"      "$( ((rc!=0)) && echo yes || echo no)" "yes"
check "malformed JSON left untouched"      "$(cat "$R/.claude/stack-config.json")" '{not json'

# 12 — dry run writes nothing.
R=$(mkrepo dryrun '{"stack_version":"1.1.3","stack_tier":2,"purpose":"p","created":"2026-01-01"}')
before="$(cat "$R/.claude/stack-config.json")"
bash "$SYNC" --repo "$R" >/dev/null 2>&1
check "dry run writes nothing"             "$(cat "$R/.claude/stack-config.json")" "$before"

# 13 — D6a: number formatting alone is not a change.
R=$(mkrepo noise "$(jq -c '.cost_protection.per_session_alert_usd = 5.0 | .cost_protection.per_day_alert_usd = 50.0' "$REPO_ROOT/templates/stack-config.template.json")")
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
out="$(bash "$SYNC" --repo "$R" 2>&1)"
# anchored: an unanchored 'CHANGED' also matches the UNCHANGED heading
check "formatting noise is not a change"   "$(grep -c '^CHANGED' <<<"$out")" "0"

# 14 — D8: idempotent.
R=$(mkrepo idem '{"stack_version":"1.1.3","stack_tier":2,"purpose":"p","created":"2026-01-01","active_subagents":["architect"]}')
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
first="$(jq -S 'del(.last_modified)' "$R/.claude/stack-config.json")"
bash "$SYNC" --repo "$R" --apply >/dev/null 2>&1
second="$(jq -S 'del(.last_modified)' "$R/.claude/stack-config.json")"
check "second apply changes nothing"       "$first" "$second"

# 15 — a backup is written alongside every applied change.
check "backup written on apply"            "$(ls "$TMPROOT/idem/.claude/" | grep -c 'stack-config.json.bak-')" "1"

# 16 — every repo ends capped.
uncapped=0
for d in "$TMPROOT"/*/; do
  f="$d/.claude/stack-config.json"; jq -e . "$f" >/dev/null 2>&1 || continue
  case "$(basename "$d")" in
    cleared-cap) continue ;;          # honored clear, case 7
    no-tier|broken) continue ;;       # correctly refused, cases 10-11 — never written
    dryrun) continue ;;               # case 12 never applies it, by design
  esac
  [[ "$(jq -r '.cost_protection.per_session_hard_cap_usd // "null"' "$f")" == "null" ]] && uncapped=$((uncapped+1))
done
check "no repo left uncapped"              "$uncapped" "0"

echo
echo "=== repo-walk ==="
source "$REPO_ROOT/scripts/lib/repo-walk.sh"
mkdir -p "$TMPROOT/deep/nested/.claude"; echo '{}' > "$TMPROOT/deep/nested/.claude/stack-config.json"
d1="$(walk_repos --max-depth 1 --root "$TMPROOT" | wc -l | tr -d ' ')"
d2="$(walk_repos --max-depth 2 --root "$TMPROOT" | wc -l | tr -d ' ')"
check "depth 2 sees more than depth 1"     "$( ((d2>d1)) && echo yes || echo no)" "yes"
check "depth 1 excludes the nested repo"   "$(walk_repos --max-depth 1 --root "$TMPROOT" | grep -c 'deep/nested')" "0"
check "depth 2 includes the nested repo"   "$(walk_repos --max-depth 2 --root "$TMPROOT" | grep -c 'deep/nested')" "1"
walk_repos --max-depth 0 --root "$TMPROOT" >/dev/null 2>&1
check "depth 0 rejected"                   "$?" "2"
mkdir -p "$TMPROOT/pruned/node_modules/pkg/.claude"; echo '{}' > "$TMPROOT/pruned/node_modules/pkg/.claude/stack-config.json"
check "node_modules pruned"                "$(walk_repos --max-depth 3 --root "$TMPROOT" | grep -c node_modules)" "0"

echo
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
