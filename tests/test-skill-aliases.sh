#!/usr/bin/env bash
# Tests for scripts/gen-alias-stubs.sh — declared skill aliases, phase 1
# (docs/ADRs/083-declared-skill-aliases.md, company scope only).
#
# Every case runs against synthetic --repo-root / --home-root fixtures under a
# temp dir — never against the real repo or the real ~/.claude. That is
# deliberate: a test that writes to the developer's actual home directory is
# a defect (see architect-handoff.md).
#
# --home-root is the ~/.claude-EQUIVALENT dir itself (confirmed against the
# script's own default, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`) — NOT $HOME.
# So fixtures write <home-root>/config/aliases.json (stack — required for
# every full run, since install.sh's tier step already copies the repo's
# config/aliases.json there before generation runs),
# <home-root>/config/aliases.org.json (org, optional),
# <home-root>/.stack-install.json (installed-tier stamp, same shape
# scripts/stack-help.sh already reads), <home-root>/skills/<word>/SKILL.md
# (stub root), <home-root>/state/alias-pending-purge.json (deferred purge).
# `--stack-only` is the one mode that reads directly from --repo-root instead
# (config/aliases.json + config/capability-registry.json, or a skills/*/
# SKILL.md scan if the registry isn't present) and writes nothing anywhere —
# what CI's lint-skills.yml uses.
#
# Case-to-plan map (architect-handoff.md "Test plan" section, exact ids):
#   A1-A5  schema/validation (stack source)
#   B1-B4  resolver (D2 forward-compat contract)
#   C1-C6  generation / purge
#   D1-D4  mid-session safety (ADR-083 D16)
#   E1-E2  ADR-075 guard / honesty (writes)
#   F1-F2  honesty (reads / output vocabulary)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/scripts/gen-alias-stubs.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

[[ -f "$GEN" ]] || echo "NOTE: $GEN does not exist yet (ADR-083 phase 1) — cases below are expected to fail until it lands."

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
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
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in: $2)"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly found '$3' in: $2)"; fi
}
assert_exists() {
  # assert_exists <label> <path>
  if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
assert_absent() {
  # assert_absent <label> <path>
  if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (should not exist: $2)"; fi
}
assert_file_eq() {
  # assert_file_eq <label> <expected-content> <path>
  if [[ ! -f "$3" ]]; then fail "$1 (file missing: $3)"; return; fi
  local got; got="$(cat "$3")"
  if [[ "$got" == "$2" ]]; then
    pass "$1"
  else
    fail "$1 (content mismatch)"
    diff <(printf '%s' "$2") <(printf '%s' "$got") | head -20
  fi
}

# ─── Fixture builders ─────────────────────────────────────────────────────

BASE_REGISTRY="$TMP/base-registry.json"
cat > "$BASE_REGISTRY" <<'EOF'
{
  "capabilities": [
    { "id": "goodmorning",   "kind": "skill", "summary": "Boot a Claude Code session with full context.", "tier_min": 0, "user_invocable": true, "model_invocable": true, "recommendable": true },
    { "id": "carbonight",    "kind": "skill", "summary": "End a Claude Code session and hand off.",         "tier_min": 0, "user_invocable": true, "model_invocable": true, "recommendable": true },
    { "id": "handbook",      "kind": "skill", "summary": "Browse the team handbook.",                       "tier_min": 0, "user_invocable": true, "model_invocable": true, "recommendable": true },
    { "id": "acme-handbook", "kind": "skill", "summary": "Browse Acme's own handbook.",                     "tier_min": 0, "user_invocable": true, "model_invocable": true, "recommendable": true },
    { "id": "rare-t3",       "kind": "skill", "summary": "A tier-3-only fixture skill.",                    "tier_min": 3, "user_invocable": true, "model_invocable": true, "recommendable": true }
  ],
  "aliases": {}
}
EOF

# fresh_pair <label> -> sets REPO / HOMEF globals under fresh dirs. REPO gets
# a committed-shaped repo root (config/capability-registry.json present, for
# --stack-only's fallback and for every full run's registry lookup — the
# script prefers <home-root>/config/capability-registry.json and falls back
# to <repo-root>/config/capability-registry.json, which fixtures below never
# populate at home, so the repo copy is what's actually read).
fresh_pair() {
  REPO="$TMP/$1-repo"
  HOMEF="$TMP/$1-home"
  mkdir -p "$REPO/config" "$REPO/skills" "$HOMEF"
  cp "$BASE_REGISTRY" "$REPO/config/capability-registry.json"
}

put_stack() { mkdir -p "$1/config"; printf '%s' "$2" > "$1/config/aliases.json"; }      # put_stack <dir> <json>
put_org()   { mkdir -p "$1/config"; printf '%s' "$2" > "$1/config/aliases.org.json"; }    # put_org <home> <json>
set_tier()  { mkdir -p "$1"; printf '{"tier": %s}' "$2" > "$1/.stack-install.json"; }     # set_tier <home> <tier>

stub_path()  { echo "$1/skills/$2/SKILL.md"; }              # stub_path <home> <word>
purge_file() { echo "$1/state/alias-pending-purge.json"; }  # purge_file <home>

run_gen() { # run_gen <repo> <home> [args...]
  local repo="$1" home="$2" errfile; shift 2
  errfile=$(mktemp)
  OUT=$(bash "$GEN" --repo-root "$repo" --home-root "$home" "$@" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}
run_gen_env() { # run_gen_env <env-assignment> <repo> <home> [args...]
  local envs="$1" repo="$2" home="$3" errfile; shift 3
  errfile=$(mktemp)
  OUT=$(env "$envs" bash "$GEN" --repo-root "$repo" --home-root "$home" "$@" 2>"$errfile"); RC=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
}

# ═══════════════════════════════════════════════════════════════════════
# A — Schema / validation (stack source)
# ═══════════════════════════════════════════════════════════════════════

# ═══ A1: valid file resolves to the expected map ═══════════════════════
fresh_pair a1
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF" --sources stack
assert_rc "A1: exit 0 on a valid stack declaration" 0 "$RC"
EXPECT_A1=$'---\nname: standup\ndescription: Alias for /goodmorning. Boot a Claude Code session with full context.\nalias_of: goodmorning\nuser-invocable: true\nmodel-invocable: false\nrecommendable: false\n---\n<!-- generated by scripts/gen-alias-stubs.sh \xe2\x80\x94 declared in stack (config/aliases.json) \xe2\x80\x94 do not edit -->\n\n# /standup \xe2\x86\x92 /goodmorning\n\nInvoke the `goodmorning` skill and follow its instructions exactly.'
assert_file_eq "A1: generated stub is byte-identical to the ADR-083 template" "$EXPECT_A1" "$(stub_path "$HOMEF" standup)"

# ═══ A2: unknown field → exit 3 ═════════════════════════════════════════
fresh_pair a2
put_stack "$REPO" '{"version":1,"aliases":{"standup":{"target":"goodmorning","bogus":true}}}'
run_gen "$REPO" "$HOMEF" --stack-only
assert_rc "A2: unknown field -> exit 3" 3 "$RC"
assert_absent "A2: --stack-only writes nothing to home-root" "$HOMEF/skills"

# ═══ A3: word failing ^[a-z][a-z0-9-]{0,31}$ → exit 3 ═══════════════════
fresh_pair a3
put_stack "$REPO" '{"version":1,"aliases":{"UPPER":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF" --stack-only
assert_rc "A3: word failing the id pattern -> exit 3" 3 "$RC"
assert_absent "A3: --stack-only writes nothing to home-root" "$HOMEF/skills"

# ═══ A4: disable combined with target → exit 3 ══════════════════════════
fresh_pair a4
put_stack "$REPO" '{"version":1,"aliases":{"bye":{"disable":true,"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF" --stack-only
assert_rc "A4: disable+target -> exit 3" 3 "$RC"
assert_absent "A4: --stack-only writes nothing to home-root" "$HOMEF/skills"

# ═══ A5: help: "row" in the org source → rejected ═══════════════════════
fresh_pair a5
put_stack "$HOMEF" '{"version":1,"aliases":{}}'
put_org "$HOMEF" '{"version":1,"aliases":{"docs":{"target":"acme-handbook","help":"row","description":"x"}}}'
run_gen "$REPO" "$HOMEF" --sources org,stack
assert_rc "A5: help:row in the org source -> exit 3" 3 "$RC"
assert_absent "A5: no docs stub materialized" "$(stub_path "$HOMEF" docs)"

# ═══════════════════════════════════════════════════════════════════════
# B — Resolver (D2, the forward-compat contract)
# ═══════════════════════════════════════════════════════════════════════

# ═══ B1: org beats stack on a shared word ═══════════════════════════════
fresh_pair b1
put_stack "$HOMEF" '{"version":1,"aliases":{"docs":{"target":"handbook"}}}'
put_org "$HOMEF" '{"version":1,"aliases":{"docs":{"target":"acme-handbook"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "B1: exit 0" 0 "$RC"
grep -q '^alias_of: acme-handbook$' "$(stub_path "$HOMEF" docs)" 2>/dev/null \
  && pass "B1: org's target wins on a shared word" || fail "B1: org's target did not win (docs should point at acme-handbook)"

# ═══ B2: disable at org kills a stack word ══════════════════════════════
fresh_pair b2
put_stack "$HOMEF" '{"version":1,"aliases":{"bye":{"target":"carbonight"}}}'
put_org "$HOMEF" '{"version":1,"aliases":{"bye":{"disable":true}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "B2: exit 0" 0 "$RC"
assert_absent "B2: org disable kills the stack word — no stub" "$(stub_path "$HOMEF" bye)"

# ═══ B3: 2-source and 5-source resolution agree on a fixture ═══════════
# HONEST SCOPE (reviewer finding, 2026-08-17): phase 1's --sources only
# recognizes the two scope NAMES "org" and "stack" — there is nowhere yet
# for a 3rd/4th/5th DISTINCT named scope to read a file from (D1 builds
# exactly two sources), and ADR-083 D20 forbids building a reader for an
# unbuilt level just to make this test more thorough. So this case cannot
# be, and does not claim to be, a test of 5-distinct-source precedence —
# that property is untestable until a third named source exists to write
# it against. What it DOES claim, precisely: the resolver's fold loop is
# invariant to the LENGTH and repetition of the source list, which is the
# literal D2 property ("adding a level is one more tuple in that list" —
# the fold doesn't care how long the list is or how many times a name
# repeats in it).
#
# A prior version of this case used two DISJOINT words (one only in stack,
# one only in org) padded to 5 tokens. That is not a real length-invariance
# test either: with no word declared in both sources, there is no
# precedence DECISION for the fold to make, so a broken implementation that
# ignored list order entirely (e.g. a plain non-positional set union) would
# pass it too. Fixed by adding an OVERLAPPING word ("standup", declared in
# BOTH sources with different targets) so B1's "org beats stack" precedence
# is the thing actually being held constant across list lengths — the
# property this case's own name promises.
fresh_pair b3a
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"},"eod":{"target":"carbonight"}}}'
put_org "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF" --sources org,stack
RC_2SRC="$RC"; HOMEF_2SRC="$HOMEF"
grep -q '^alias_of: carbonight$' "$(stub_path "$HOMEF_2SRC" standup)" 2>/dev/null \
  && pass "B3: 2-source list — org's target wins on the overlapping word (sanity, matches B1)" \
  || fail "B3: 2-source list — org's target did NOT win on the overlapping word; the fixture itself is broken"

fresh_pair b3b
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"},"eod":{"target":"carbonight"}}}'
put_org "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF" --sources org,org,stack,org,stack
RC_5SRC="$RC"

assert_rc "B3: 2-source list exits 0" 0 "$RC_2SRC"
assert_rc "B3: 5-token source list exits 0" 0 "$RC_5SRC"
grep -q '^alias_of: carbonight$' "$(stub_path "$HOMEF" standup)" 2>/dev/null \
  && pass "B3: 5-token (padded/repeated) source list — org's target STILL wins on the overlapping word" \
  || fail "B3: 5-token source list — precedence on the overlapping word changed when the list was padded/repeated"
if diff -r "$HOMEF_2SRC/skills" "$HOMEF/skills" >/dev/null 2>&1; then
  pass "B3: 2-source and 5-source resolution agree on the same fixture (including the contested word)"
else
  fail "B3: 2-source and 5-source resolution produced different stub trees"
fi

# ═══ B4: resolution stable regardless of key order in the files ════════
fresh_pair b4a
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"},"eod":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF"
RC_A="$RC"; HOMEF_A="$HOMEF"

fresh_pair b4b
put_stack "$HOMEF" '{"version":1,"aliases":{"eod":{"target":"carbonight"},"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF"
RC_B="$RC"

assert_rc "B4: first key order exits 0" 0 "$RC_A"
assert_rc "B4: reordered key order exits 0" 0 "$RC_B"
if diff -r "$HOMEF_A/skills" "$HOMEF/skills" >/dev/null 2>&1; then
  pass "B4: generated stub trees are byte-identical regardless of key order"
else
  fail "B4: generated stub trees differ by key order alone"
fi

# ═══════════════════════════════════════════════════════════════════════
# C — Generation / purge
# ═══════════════════════════════════════════════════════════════════════

# ═══ C1: resolved words materialize under the fixture --home-root ══════
fresh_pair c1
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
put_org "$HOMEF" '{"version":1,"aliases":{"eod":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C1: exit 0" 0 "$RC"
assert_exists "C1: stack-declared word materializes" "$(stub_path "$HOMEF" standup)"
assert_exists "C1: org-declared word materializes" "$(stub_path "$HOMEF" eod)"

# ═══ C2: header-carrying stub whose word left the map is purged ════════
fresh_pair c2
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF"
assert_exists "C2: standup stubbed on first run" "$(stub_path "$HOMEF" standup)"
grep -q 'generated by scripts/gen-alias-stubs.sh' "$(stub_path "$HOMEF" standup)" \
  && pass "C2: pre-purge stub carries the generated-file header" || fail "C2: pre-purge stub missing the D12 header"
put_stack "$HOMEF" '{"version":1,"aliases":{}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C2: second run (word removed) exits 0" 0 "$RC"
assert_absent "C2: orphaned header-carrying stub purged" "$(stub_path "$HOMEF" standup)"

# ═══ C3: non-header dirs untouched — skills/handoff/ survives a full run ═
fresh_pair c3
mkdir -p "$HOMEF/skills/handoff"
cat > "$HOMEF/skills/handoff/SKILL.md" <<'EOF'
---
name: handoff
description: Redirect stub, ADR-074. Hand-written, never generated.
---
This file has no generated-file header and must never be touched.
EOF
HANDOFF_BEFORE="$(cat "$HOMEF/skills/handoff/SKILL.md")"
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C3: exit 0" 0 "$RC"
HANDOFF_AFTER="$(cat "$HOMEF/skills/handoff/SKILL.md" 2>/dev/null || echo "__MISSING__")"
assert_eq "C3: skills/handoff/ (no header) survives a full generation untouched" "$HANDOFF_BEFORE" "$HANDOFF_AFTER"

# ═══ C4: stack alias whose target tier_min > installed tier is not generated ═
fresh_pair c4
put_stack "$HOMEF" '{"version":1,"aliases":{"rare-word":{"target":"rare-t3"},"standup":{"target":"goodmorning"}}}'
set_tier "$HOMEF" 0
run_gen "$REPO" "$HOMEF"
assert_rc "C4: exit 0" 0 "$RC"
assert_absent "C4: alias whose target's tier_min (3) exceeds the installed tier (0) is not generated" "$(stub_path "$HOMEF" rare-word)"
assert_exists "C4: sibling tier-0 alias still generates" "$(stub_path "$HOMEF" standup)"

# ═══ C5: --check rc semantics; rc 2 bad flag; rc 3 malformed ════════════
fresh_pair c5
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C5: initial generation exit 0" 0 "$RC"
run_gen "$REPO" "$HOMEF" --check
assert_rc "C5: --check exit 0 immediately after generation (clean)" 0 "$RC"
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"},"eod":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF" --check
assert_rc "C5: --check exit 1 after the source drifts from what's on disk" 1 "$RC"
run_gen "$REPO" "$HOMEF" --not-a-real-flag
assert_rc "C5: unrecognized flag -> exit 2" 2 "$RC"
fresh_pair c5b
printf '%s' '{ not valid json' > "$REPO/config/aliases.json"
run_gen "$REPO" "$HOMEF" --stack-only
assert_rc "C5: malformed source JSON -> exit 3" 3 "$RC"

# ═══ C6: write-then-purge — an aborted run never leaves a word with no stub ═
fresh_pair c6
put_stack "$HOMEF" '{"version":1,"aliases":{"a":{"target":"goodmorning"},"b":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C6: first run (a, b) exits 0" 0 "$RC"
assert_exists "C6: a stubbed" "$(stub_path "$HOMEF" a)"
assert_exists "C6: b stubbed" "$(stub_path "$HOMEF" b)"
# Simulate a collision that must abort the whole run (D13 rule 8): a plain
# directory at the stub path for word "c", carrying no D12 header.
mkdir -p "$HOMEF/skills/c"
cat > "$HOMEF/skills/c/SKILL.md" <<'EOF'
---
name: c
---
Hand-authored, not ours — no generated-file header.
EOF
put_stack "$HOMEF" '{"version":1,"aliases":{"a":{"target":"goodmorning"},"b":{"target":"carbonight"},"c":{"target":"handbook"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "C6: run aborts on the header-less collision (rule 8) -> exit 3" 3 "$RC"
assert_exists "C6: a's stub survives the aborted run" "$(stub_path "$HOMEF" a)"
assert_exists "C6: b's stub survives the aborted run" "$(stub_path "$HOMEF" b)"

# ═══════════════════════════════════════════════════════════════════════
# D — Mid-session safety (ADR-083 D16 — bug 2)
# ═══════════════════════════════════════════════════════════════════════

fresh_pair d
put_stack "$HOMEF" '{"version":1,"aliases":{"a":{"target":"goodmorning"},"b":{"target":"carbonight"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "D setup: first (non-in-session) run exits 0" 0 "$RC"
assert_exists "D setup: a stubbed" "$(stub_path "$HOMEF" a)"
assert_exists "D setup: b stubbed" "$(stub_path "$HOMEF" b)"

put_stack "$HOMEF" '{"version":1,"aliases":{"a":{"target":"goodmorning"},"c":{"target":"handbook"}}}'
run_gen_env "STACK_INSESSION=1" "$REPO" "$HOMEF"
RC_INSESSION="$RC"

# ═══ D1: additions/refreshes yes, purge no ═══════════════════════════════
assert_rc "D1: in-session run exits 0" 0 "$RC_INSESSION"
assert_exists "D1: a (unchanged word) still present" "$(stub_path "$HOMEF" a)"
assert_exists "D1: c (new word) added" "$(stub_path "$HOMEF" c)"
assert_exists "D1: b (dropped word) NOT purged mid-session" "$(stub_path "$HOMEF" b)"

# ═══ D2: the deferred purge is recorded ═════════════════════════════════
PF="$(purge_file "$HOMEF")"
assert_exists "D2: pending-purge state file written" "$PF"
if [[ -f "$PF" ]]; then
  jq -e '.pending_purge // [] | index("b") != null' "$PF" >/dev/null 2>&1 \
    && pass "D2: pending-purge file names b" || fail "D2: pending-purge file does not name b: $(cat "$PF" 2>/dev/null)"
fi

# ═══ D3: the next non-in-session run applies the pending purge, clears it ═
run_gen "$REPO" "$HOMEF"
assert_rc "D3: next non-in-session run exits 0" 0 "$RC"
assert_absent "D3: b purged by the deferred-purge run" "$(stub_path "$HOMEF" b)"
assert_absent "D3: pending-purge file cleared (removed once nothing remains deferred)" "$PF"

# ═══ D4: STACK_INSESSION=1 suppresses recorded-pack re-resolution (install.sh) ═
# Exercised against scripts/install.sh directly since D6/D16's pack
# re-resolution step lives there, not in gen-alias-stubs.sh.
D4_PACK="$TMP/d4-pack"
mkdir -p "$D4_PACK/config"
cat > "$D4_PACK/tenant.json" <<'EOF'
{ "tenant_id": "d4tenant", "pack_version": "1.0.0", "github": { "org": "d4org" } }
EOF
cat > "$D4_PACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"before":{"target":"goodmorning"}}}
EOF
D4_HOME="$TMP/d4-home"; D4_CLAUDE="$D4_HOME/.claude"
mkdir -p "$D4_CLAUDE/config"
cp "$D4_PACK/config/aliases.org.json" "$D4_CLAUDE/config/aliases.org.json"
cat > "$D4_CLAUDE/stack-defaults.json" <<EOF
{ "stack_version": "1.0.0", "tenant_pack": { "tenant_id": "d4tenant", "source": "$D4_PACK", "ref": "", "pack_version": "1.0.0" } }
EOF
# Upstream "changes" — the recorded pack now names a different word.
cat > "$D4_PACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"after":{"target":"goodmorning"}}}
EOF
if [[ -f "$REPO_ROOT/scripts/install.sh" ]]; then
  # Guards against a vacuous pass: if install.sh never learns the
  # recorded-pack-re-resolution convention at all, "the org file is
  # unchanged" would be trivially true with or without STACK_INSESSION.
  if grep -q 'STACK_INSESSION' "$REPO_ROOT/scripts/install.sh"; then
    pass "D4: install.sh recognizes STACK_INSESSION (sanity — not a no-op check)"
  else
    fail "D4: install.sh does not reference STACK_INSESSION yet — the suppression below cannot be a real signal until D6/D16 land"
  fi
  # No `timeout` wrapper (not portable — absent on macOS without coreutils,
  # and a silently-missing `timeout` binary would make install.sh never run
  # at all, turning "org file unchanged" into a vacuous pass). `</dev/null`
  # is the actual safety net: if STACK_INSESSION somehow failed to suppress
  # the pack step, `read -r -p` against a closed stdin returns empty
  # immediately (declines and exits 1) rather than blocking forever.
  # An ambient CLAUDE_CONFIG_DIR from the outer session points at the real
  # $HOME, not $D4_HOME — the profile resolver correctly refuses it as
  # foreign, which would make this a vacuous "install never ran" failure.
  # Isolate it exactly like test-install.sh isolates it.
  ( cd "$REPO_ROOT" && HOME="$D4_HOME" STACK_INSESSION=1 \
      env -u CLAUDE_CONFIG_DIR ./scripts/install.sh --tier=0 --mode=merge --skip-requirements </dev/null >/dev/null 2>&1 )
  # Sanity — prove install.sh actually ran to completion (not a vacuous pass
  # from, say, a missing/misnamed binary silently no-op'ing the subshell).
  assert_exists "D4: sanity — install.sh actually ran (install stamp written)" "$D4_CLAUDE/.stack-install.json"
  D4_ORG_AFTER="$(cat "$D4_CLAUDE/config/aliases.org.json" 2>/dev/null)"
  D4_ORG_BEFORE='{"version":1,"aliases":{"before":{"target":"goodmorning"}}}'
  assert_eq "D4: STACK_INSESSION=1 install.sh never re-resolves the recorded pack (org file unchanged)" \
    "$D4_ORG_BEFORE" "$D4_ORG_AFTER"
else
  fail "D4: $REPO_ROOT/scripts/install.sh not found"
fi

# ═══════════════════════════════════════════════════════════════════════
# E — ADR-075 guard (bug 1) / write-scope honesty
# ═══════════════════════════════════════════════════════════════════════

# ═══ E1: .claude/skills/ does NOT appear in project-init's gitignore block ═
PROJECT_INIT="$REPO_ROOT/skills/project-init/SKILL.md"
GI_BLOCK="$(sed -n '/# Claude Code Stack — runtime scratch, never commit/,/^graph\.json$/p' "$PROJECT_INIT" 2>/dev/null)"
assert_contains "E1: located the real gitignore enumeration (sanity — not an empty/wrong slice)" "$GI_BLOCK" '.claude/sessions/'
assert_not_contains "E1: .claude/skills/ absent from the gitignore enumeration (rev-1's D12 must never return)" "$GI_BLOCK" '.claude/skills/'

# ═══ E2: no phase-1 code path writes anything under a project's own
#         .claude/skills/ — only the designated --home-root ═══════════
fresh_pair e2
mkdir -p "$REPO/.claude"   # simulates a project checkout co-located with repo-root
put_stack "$HOMEF" '{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}'
run_gen "$REPO" "$HOMEF"
assert_rc "E2: exit 0" 0 "$RC"
assert_absent "E2: repo-root's own .claude/skills/ is never created" "$REPO/.claude/skills"
assert_exists "E2: --home-root's skills/ is the only stub root written" "$(stub_path "$HOMEF" standup)"

# ═══════════════════════════════════════════════════════════════════════
# F — Honesty (ADR-083 D20)
# ═══════════════════════════════════════════════════════════════════════

# ═══ F1: no source file reads the unbuilt-level files ═══════════════════
BANNED_READS=("aliases.user.json" ".claude/aliases.json" ".claude/aliases.local.json")
F1_HITS=""
for pattern in "${BANNED_READS[@]}"; do
  hit="$(grep -rl --include='*.sh' --include='*.py' --include='*.md' \
    --exclude-dir=.git --exclude-dir=tests --exclude-dir=docs \
    --exclude-dir=.claude \
    -- "$pattern" "$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$REPO_ROOT/lib" "$REPO_ROOT/config" 2>/dev/null || true)"
  [[ -n "$hit" ]] && F1_HITS="$F1_HITS $pattern:[$hit]"
done
if [[ -z "$F1_HITS" ]]; then
  pass "F1: no source file reads aliases.user.json / .claude/aliases.json / .claude/aliases.local.json"
else
  fail "F1: unbuilt-level file(s) referenced in source: $F1_HITS"
fi

# ═══ F2: /alias output carries no unbuilt-level vocabulary, no "coming soon" ═
# Reviewer finding (2026-08-17): the original BANNED_VOCAB list banned
# "personal scope"/"project scope"/"checkout scope" (2-word phrases), but
# skills/alias/SKILL.md's actual honesty disclaimer says "no personal,
# project, or checkout-level file" — a different construction entirely
# (three adjectives sharing one noun, "level" not "scope"). The banned
# list never matched the wording the file actually uses, so it could not
# have caught a regression to that wording either way. Fixed the
# assertion (not the skill text, which is correct): keep banning
# unambiguous unbuilt-level FILE NAMES and "coming soon" (still real,
# still never legitimate in any context), and ADD a positive check that
# the actual honesty disclaimer sentence is present verbatim — so removing
# or weakening it is what F2 now actually catches.
ALIAS_SKILL="$REPO_ROOT/skills/alias/SKILL.md"
if [[ -f "$ALIAS_SKILL" ]]; then
  BANNED_VOCAB=("coming soon" "aliases.user.json" "aliases.local.json" ".claude/aliases.json")
  F2_HITS=""
  for term in "${BANNED_VOCAB[@]}"; do
    grep -qi -F -- "$term" "$ALIAS_SKILL" && F2_HITS="$F2_HITS [$term]"
  done
  if [[ -z "$F2_HITS" ]]; then
    pass "F2: skills/alias/SKILL.md names no unbuilt-level file and no 'coming soon'"
  else
    fail "F2: skills/alias/SKILL.md contains banned unbuilt-level vocabulary:$F2_HITS"
  fi
  # Markdown-stripped, whitespace-collapsed copy, same technique as
  # tests/test-goodmorning-faces.sh's GM_FLAT -- the disclaimer sentence
  # wraps across two raw lines.
  ALIAS_FLAT="$(sed -E 's/\*\*//g; s/`//g' "$ALIAS_SKILL" | tr '\n\t' '  ' | tr -s ' ')"
  if grep -qi -F 'There is no personal, project, or checkout-level file' <<<"$ALIAS_FLAT"; then
    pass "F2: the actual honesty disclaimer ('no personal, project, or checkout-level file') is present verbatim"
  else
    fail "F2: the honesty disclaimer is missing or its wording changed — F2's whole point is to catch exactly this"
  fi
  if grep -qi -F 'do not imply one exists' <<<"$ALIAS_FLAT"; then
    pass "F2: the disclaimer also forbids IMPLYING an unbuilt level exists, not just naming one"
  else
    fail "F2: missing 'do not imply one exists' — a technically-true-but-misleading rewrite would slip through without it"
  fi
else
  fail "F2: $ALIAS_SKILL does not exist yet"
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
