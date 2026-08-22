#!/usr/bin/env bash
# Test: install in a clean dir succeeds for each tier.
# Uses --skip-requirements: this tests install *mechanics* (file placement,
# verify pass), not whether this machine has codex/gemini/ollama installed —
# so it runs the same on a bare CI runner as on a fully provisioned laptop.

set -euo pipefail

TMPDIR="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
ORIG_HOME="$HOME"
export HOME="$TMPDIR"

# An ambient CLAUDE_CONFIG_DIR from the outer session (e.g. this very sandbox's
# own $HOME/.claude-lade) points at the real $HOME, not $TMPDIR — under the
# resolver that's correctly refused as foreign, which would break every test
# below. Isolate it exactly like HOME is isolated.
HAD_CCD=0
if [[ -n "${CLAUDE_CONFIG_DIR+x}" ]]; then HAD_CCD=1; ORIG_CCD="$CLAUDE_CONFIG_DIR"; fi
unset CLAUDE_CONFIG_DIR

restore_env() {
  export HOME="$ORIG_HOME"
  if [[ "$HAD_CCD" -eq 1 ]]; then export CLAUDE_CONFIG_DIR="$ORIG_CCD"; fi
  rm -rf "$TMPDIR"
}
trap restore_env EXIT

cd "$(dirname "$0")/.."

failures=0

# Assert every hook/statusline command in the installed settings.json points at a
# script that actually exists. Catches the tier-0/1 "settings references a
# tier-2-only hook" bug: lower tiers must not wire team hooks (subagent-log,
# workflow-roster-check, dispatch-nudge, subagent-complete-log) that only ship
# at tier 2.
check_settings_hooks_exist() {
  local settings="$HOME/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  local rc=0 cmd path
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    path="${cmd%% *}"          # strip any trailing args
    path="${path/#\~/$HOME}"   # expand leading ~
    if [[ ! -e "$path" ]]; then
      echo "    [dangling] settings.json references missing hook: $path"
      rc=1
    fi
  done < <(jq -r '[ (.hooks // {} | to_entries[].value[].hooks[]?.command), (.statusLine.command // empty) ] | .[]' "$settings")
  return $rc
}

# Tier 5 omitted: its verify checks for pulled Ollama models, which can't be
# satisfied under a sandboxed HOME or on a CI runner (same reason the install
# matrix in test-install.yml skips tier 5).
for tier in 0 1 2 3 4; do
  echo "=== Testing tier $tier in clean $HOME ==="
  rm -rf "$HOME/.claude"
  if ./scripts/install.sh --tier="$tier" --mode=fresh --skip-requirements > /tmp/install-$tier.log 2>&1; then
    echo "  [PASS] Tier $tier installed"
  else
    echo "  [FAIL] Tier $tier — see /tmp/install-$tier.log"
    failures=$((failures + 1))
  fi
  if ./scripts/verify.sh --tier="$tier" --skip-requirements > /tmp/verify-$tier.log 2>&1; then
    echo "  [PASS] Tier $tier verified"
  else
    echo "  [FAIL] Tier $tier verify — see /tmp/verify-$tier.log"
    failures=$((failures + 1))
  fi
  if check_settings_hooks_exist; then
    echo "  [PASS] Tier $tier — settings.json hooks all exist on disk"
  else
    echo "  [FAIL] Tier $tier — settings.json references missing hook script(s)"
    failures=$((failures + 1))
  fi

  if [[ "$tier" -eq 0 ]]; then
    # J3 (ADR-083): the five tier-0 smoke lines pass post-install because
    # generation ran — dedicated, per-file check (not just "verify.sh
    # returned 0") so a single missing stub can't hide behind an aggregate
    # pass.
    j3_ok=true
    for word in hi hello bye goodbye docs; do
      if [[ ! -f "$HOME/.claude/skills/$word/SKILL.md" ]]; then
        echo "    [J3] missing generated alias stub: skills/$word/SKILL.md"
        j3_ok=false
      fi
    done
    if [[ "$j3_ok" == true ]]; then
      echo "  [PASS] J3: all five tier-0 alias stubs materialized (generation ran before verify)"
    else
      echo "  [FAIL] J3: one or more tier-0 alias stubs missing post-install"
      failures=$((failures + 1))
    fi
  fi
done

# --- rev-2 §1: hostile CLAUDE_CONFIG_DIR must refuse, not write ---
echo "Test: hostile CLAUDE_CONFIG_DIR values refuse"
for bad in "$HOME/.ssh" "/tmp/evil" "$HOME/.claude-a/../.ssh" "$HOME/.claude-$(printf 'x\ty')"; do
  if CLAUDE_CONFIG_DIR="$bad" ./scripts/install.sh --tier=0 --skip-requirements >/dev/null 2>&1; then
    echo "  FAIL: accepted CLAUDE_CONFIG_DIR=$bad"; failures=$((failures+1))
  fi
  [[ -e "$HOME/.ssh/skills" || -e "/tmp/evil/skills" ]] && { echo "  FAIL: wrote through $bad"; failures=$((failures+1)); }
done

echo "Test: symlinked target refuses in fresh mode"
mkdir -p "$HOME/.claude-realtarget"; ln -s "$HOME/.claude-realtarget" "$HOME/.claude-lnk"
if CLAUDE_CONFIG_DIR="$HOME/.claude-lnk" ./scripts/install.sh --tier=0 --mode=fresh --skip-requirements >/dev/null 2>&1; then
  echo "  FAIL: fresh mode accepted a symlinked target"; failures=$((failures+1))
fi
[[ -d "$HOME/.claude-realtarget" ]] || { echo "  FAIL: fresh mode displaced the link's target"; failures=$((failures+1)); }

echo "Test: --profile installs to ~/.claude-<name> and stamps it"
./scripts/install.sh --tier=0 --profile=teamx --skip-requirements >/dev/null 2>&1 \
  || { echo "  FAIL: --profile install failed"; failures=$((failures+1)); }
[[ -f "$HOME/.claude-teamx/.stack-install.json" ]] \
  || { echo "  FAIL: profile not stamped"; failures=$((failures+1)); }

# --- C1: an ambient CLAUDE_CONFIG_DIR naming a profile must behave exactly
# like --profile=<name>. Before the fix, CLAUDE_DIR resolved to the profile
# and the tier loop installed INTO it — cp'ing through the overlay's symlinks
# (clobbering master) and rm -rf'ing linked dirs (forking the profile off
# master). It fires with no flag at all, via update.sh, on any machine that
# exports CLAUDE_CONFIG_DIR.
echo "Test: ambient CLAUDE_CONFIG_DIR=<profile> installs master, not the profile"
rm -rf "$HOME/.claude" "$HOME/.claude-amb"
./scripts/install.sh --tier=0 --profile=amb --skip-requirements >/dev/null 2>&1 \
  || { echo "  FAIL: setup profile install failed"; failures=$((failures+1)); }

# Canary in a MASTER file the tier loop rewrites, plus a REAL (customized)
# copy of that same file in the profile. Only a run that targets master
# clears the canary; a run that targets the profile overwrites the profile's
# real copy and leaves master stale.
MASTER_FILE="$HOME/.claude/lib/find-stack-config.sh"
PROFILE_FILE="$HOME/.claude-amb/lib/find-stack-config.sh"
echo "# CANARY-MASTER-STALE" >> "$MASTER_FILE"
rm -f "$PROFILE_FILE"; echo "# PROFILE-LOCAL-OVERRIDE" > "$PROFILE_FILE"

amb_out="$(CLAUDE_CONFIG_DIR="$HOME/.claude-amb" ./scripts/install.sh --tier=0 --skip-requirements 2>&1)" \
  || { echo "  FAIL: ambient-profile install failed"; failures=$((failures+1)); }

case "$amb_out" in
  *"CLAUDE_CONFIG_DIR names profile 'amb'"*) : ;;
  *) echo "  FAIL: banner did not announce the promoted profile"; failures=$((failures+1)) ;;
esac
grep -q "CANARY-MASTER-STALE" "$MASTER_FILE" \
  && { echo "  FAIL: master file not refreshed — tier content did not land in master"; failures=$((failures+1)); }
diff -q "$MASTER_FILE" ./lib/find-stack-config.sh >/dev/null 2>&1 \
  || { echo "  FAIL: master file is not the freshly installed copy"; failures=$((failures+1)); }
[[ -L "$PROFILE_FILE" ]] \
  && { echo "  FAIL: overlay replaced the profile's real customized file with a link"; failures=$((failures+1)); }
grep -q "PROFILE-LOCAL-OVERRIDE" "$PROFILE_FILE" \
  || { echo "  FAIL: profile's real file was overwritten by tier content"; failures=$((failures+1)); }
[[ -L "$HOME/.claude-amb/skills/goodmorning" ]] \
  || { echo "  FAIL: profile entries are no longer symlinks into master"; failures=$((failures+1)); }
[[ -f "$HOME/.claude/.stack-install.json" ]] \
  || { echo "  FAIL: master not stamped under ambient profile"; failures=$((failures+1)); }
[[ -f "$HOME/.claude-amb/.stack-install.json" ]] \
  || { echo "  FAIL: profile not stamped under ambient profile"; failures=$((failures+1)); }

# --- I2: first-run --profile --pack must produce a profile CLAUDE.md that
# carries MASTER's content plus the tenant fragment. Before the fix the pack
# step ran before po_build_overlay, so `touch` created a real empty file, the
# fragment was appended to it, and the later overlay build skipped the name —
# leaving the profile with the fragment and nothing else.
echo "Test: first-run --profile --pack seeds master CLAUDE.md under the fragment"
rm -rf "$HOME/.claude" "$HOME/.claude-packp"
./scripts/install.sh --tier=0 --skip-requirements >/dev/null 2>&1 \
  || { echo "  FAIL: master install for pack test failed"; failures=$((failures+1)); }

TESTPACK="$HOME/testpack"
mkdir -p "$TESTPACK"
cat > "$TESTPACK/tenant.json" << 'EOF'
{
  "tenant_id": "profiletest",
  "pack_version": "0.1.0",
  "display_name": "Profile Test",
  "github": { "org": "CarboNet-Nano" }
}
EOF
cat > "$TESTPACK/CLAUDE.fragment.md" << 'EOF'
PROFILE-PACK-FRAGMENT-SENTINEL
EOF

echo y | ./scripts/install.sh --tier=0 --profile=packp --pack="$TESTPACK" --skip-requirements >/dev/null 2>&1 \
  || { echo "  FAIL: --profile --pack install failed"; failures=$((failures+1)); }

PACK_CLAUDE_MD="$HOME/.claude-packp/CLAUDE.md"
[[ -f "$PACK_CLAUDE_MD" && ! -L "$PACK_CLAUDE_MD" ]] \
  || { echo "  FAIL: profile CLAUDE.md is missing or still a symlink into master"; failures=$((failures+1)); }
grep -q "Core Principles (Always Active)" "$PACK_CLAUDE_MD" 2>/dev/null \
  || { echo "  FAIL: profile CLAUDE.md lost master's global content"; failures=$((failures+1)); }
grep -q "PROFILE-PACK-FRAGMENT-SENTINEL" "$PACK_CLAUDE_MD" 2>/dev/null \
  || { echo "  FAIL: profile CLAUDE.md missing the tenant fragment"; failures=$((failures+1)); }
grep -q "PROFILE-PACK-FRAGMENT-SENTINEL" "$HOME/.claude/CLAUDE.md" 2>/dev/null \
  && { echo "  FAIL: tenant fragment leaked into master CLAUDE.md"; failures=$((failures+1)); }

# Second run must be idempotent: the fragment is re-applied in place, master
# content is still there, and nothing is duplicated.
echo y | ./scripts/install.sh --tier=0 --profile=packp --pack="$TESTPACK" --skip-requirements >/dev/null 2>&1 \
  || { echo "  FAIL: second --profile --pack run failed"; failures=$((failures+1)); }
[[ "$(grep -c "PROFILE-PACK-FRAGMENT-SENTINEL" "$PACK_CLAUDE_MD")" == "1" ]] \
  || { echo "  FAIL: second run duplicated the tenant fragment"; failures=$((failures+1)); }
grep -q "Core Principles (Always Active)" "$PACK_CLAUDE_MD" 2>/dev/null \
  || { echo "  FAIL: second run dropped master's global content"; failures=$((failures+1)); }
# ═══ J1: ordering — pull -> tier -> pack -> generate -> verify (ADR-083 D16 rule 3) ═══
echo "=== J1: ordering ==="

# Static half: update.sh pulls before it ever invokes install.sh; install.sh's
# own step banners are in tier -> pack -> generate -> verify order.
# ADR-086 D2: the pull is now conditional on STACK_UPDATE_NO_PULL (indented
# inside an if), so the grep tolerates leading whitespace — the invariant
# under test is ordering, not column position.
pull_line="$(grep -n '^[[:space:]]*git pull' scripts/update.sh | head -1 | cut -d: -f1 || true)"
install_call_line="$(grep -n 'SCRIPT_DIR/install\.sh' scripts/update.sh | head -1 | cut -d: -f1 || true)"
if [[ -n "$pull_line" && -n "$install_call_line" && "$pull_line" -lt "$install_call_line" ]]; then
  echo "  [PASS] J1: update.sh pulls before invoking install.sh"
else
  echo "  [FAIL] J1: update.sh does not pull before invoking install.sh (pull=$pull_line install-call=$install_call_line)"
  failures=$((failures + 1))
fi

tier_step_line="$(grep -n 'Installing tiers 0 through' scripts/install.sh | head -1 | cut -d: -f1 || true)"
pack_step_line="$(grep -n 'Installing tenant pack' scripts/install.sh | head -1 | cut -d: -f1 || true)"
generate_line="$(grep -n 'gen-alias-stubs\.sh' scripts/install.sh | head -1 | cut -d: -f1 || true)"
verify_line="$(grep -n 'Verifying installation' scripts/install.sh | head -1 | cut -d: -f1 || true)"
if [[ -n "$tier_step_line" && -n "$pack_step_line" && -n "$generate_line" && -n "$verify_line" \
      && "$tier_step_line" -lt "$pack_step_line" && "$pack_step_line" -lt "$generate_line" \
      && "$generate_line" -lt "$verify_line" ]]; then
  echo "  [PASS] J1: install.sh's own step order is tier -> pack -> generate -> verify"
else
  echo "  [FAIL] J1: install.sh step order wrong (tier=$tier_step_line pack=$pack_step_line generate=$generate_line verify=$verify_line)"
  failures=$((failures + 1))
fi

# Effect half: a single --pack install proves the order transitively — the
# org-declared word's target (goodmorning) had to be installed by the tier
# step, the org file had to have landed by the pack step, before generation
# could materialize the stub, before verify could see it.
J1_PACK="$TMPDIR/j1-pack"
mkdir -p "$J1_PACK/config"
cat > "$J1_PACK/tenant.json" <<'EOF'
{ "tenant_id": "j1tenant", "pack_version": "1.0.0", "github": { "org": "j1org" } }
EOF
cat > "$J1_PACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"standup":{"target":"goodmorning"}}}
EOF
rm -rf "$HOME/.claude"
if printf 'y\n' | ./scripts/install.sh --tier=0 --pack="$J1_PACK" --mode=fresh --skip-requirements > /tmp/install-j1.log 2>&1; then
  echo "  [PASS] J1: install with --pack completes"
else
  echo "  [FAIL] J1: install with --pack failed — see /tmp/install-j1.log"
  failures=$((failures + 1))
fi
if [[ -f "$HOME/.claude/skills/standup/SKILL.md" ]]; then
  echo "  [PASS] J1: org-declared word materialized — proves tier -> pack -> generate ran in that order"
else
  echo "  [FAIL] J1: org-declared word 'standup' never materialized under ~/.claude/skills/"
  failures=$((failures + 1))
fi
if ./scripts/verify.sh --tier=0 --skip-requirements > /tmp/verify-j1.log 2>&1; then
  echo "  [PASS] J1: verify passes post-install (generate ran before verify)"
else
  echo "  [FAIL] J1: verify failed post-install — see /tmp/verify-j1.log"
  failures=$((failures + 1))
fi

# ═══ J2: recorded-pack re-resolution (ADR-083 D6) ═══════════════════════
echo "=== J2: recorded-pack re-resolution ==="

# 2a/2b — a tag-pinned pack: re-resolution at the same recorded ref produces
# an empty diff and picks up nothing, even when upstream has moved on.
J2_TAGPACK="$TMPDIR/j2-tagpack"
mkdir -p "$J2_TAGPACK/config"
git init -q "$J2_TAGPACK"
cat > "$J2_TAGPACK/tenant.json" <<'EOF'
{ "tenant_id": "j2tag", "pack_version": "1.0.0", "github": { "org": "j2org" } }
EOF
cat > "$J2_TAGPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"pinned-word":{"target":"goodmorning"}}}
EOF
( cd "$J2_TAGPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m init && git tag v1 )

rm -rf "$HOME/.claude"
if printf 'y\n' | ./scripts/install.sh --tier=0 --pack="${J2_TAGPACK}@v1" --mode=fresh --skip-requirements > /tmp/install-j2a.log 2>&1; then
  echo "  [PASS] J2a: initial tag-pinned pack install completes"
else
  echo "  [FAIL] J2a: initial tag-pinned pack install failed — see /tmp/install-j2a.log"
  failures=$((failures + 1))
fi
recorded_ref="$(jq -r '.tenant_pack.ref // empty' "$HOME/.claude/stack-defaults.json" 2>/dev/null || echo '')"
j2a_seeded=false
if [[ "$recorded_ref" == "v1" ]]; then
  echo "  [PASS] J2a: tenant_pack.ref recorded as v1"
  j2a_seeded=true
else
  echo "  [FAIL] J2a: tenant_pack.ref not recorded as v1 (got: $recorded_ref)"
  failures=$((failures + 1))
fi

# Upstream changes WITHOUT moving the v1 tag.
cat > "$J2_TAGPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"pinned-word":{"target":"goodmorning"},"surprise-word":{"target":"goodmorning"}}}
EOF
( cd "$J2_TAGPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m upstream-change )

if [[ "$j2a_seeded" != true ]]; then
  # J2a's setup never recorded a tenant_pack — J2b/J2d would otherwise "pass"
  # vacuously by skipping the pack step entirely rather than exercising
  # re-resolution. Fail loudly instead of reporting a false green.
  echo "  [FAIL] J2b: skipped — J2a never seeded a recorded tenant_pack, so this case cannot exercise re-resolution"
  failures=$((failures + 1))
elif ./scripts/install.sh --tier=0 --mode=merge --skip-requirements </dev/null > /tmp/install-j2b.log 2>&1; then
  echo "  [PASS] J2b: recorded-pack re-resolution completes with no prompt needed (empty diff at the pinned tag)"
  if grep -q 'surprise-word' "$HOME/.claude/config/aliases.org.json" 2>/dev/null; then
    echo "  [FAIL] J2b: a tag-pinned pack picked up an upstream change it should not have"
    failures=$((failures + 1))
  else
    echo "  [PASS] J2b: a tag-pinned pack sees no behaviour change (same ref, empty diff)"
  fi
else
  echo "  [FAIL] J2b: recorded-pack re-resolution at a pinned tag should be a no-op empty-diff run — see /tmp/install-j2b.log"
  failures=$((failures + 1))
fi

# 2c/2d — a moving ref (a branch, not a tag): re-resolution at the SAME
# recorded ref DOES pick up an upstream change, once confirmed.
J2_BRANCHPACK="$TMPDIR/j2-branchpack"
mkdir -p "$J2_BRANCHPACK/config"
git init -q "$J2_BRANCHPACK"
( cd "$J2_BRANCHPACK" && git checkout -q -b release )
cat > "$J2_BRANCHPACK/tenant.json" <<'EOF'
{ "tenant_id": "j2branch", "pack_version": "1.0.0", "github": { "org": "j2org" } }
EOF
cat > "$J2_BRANCHPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"branch-word-v1":{"target":"goodmorning"}}}
EOF
( cd "$J2_BRANCHPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m init )

rm -rf "$HOME/.claude"
j2c_seeded=false
if printf 'y\n' | ./scripts/install.sh --tier=0 --pack="${J2_BRANCHPACK}@release" --mode=fresh --skip-requirements > /tmp/install-j2c.log 2>&1; then
  echo "  [PASS] J2c: initial moving-ref (branch) pack install completes"
  recorded_branch_ref="$(jq -r '.tenant_pack.ref // empty' "$HOME/.claude/stack-defaults.json" 2>/dev/null || echo '')"
  [[ "$recorded_branch_ref" == "release" ]] && j2c_seeded=true
else
  echo "  [FAIL] J2c: initial moving-ref pack install failed — see /tmp/install-j2c.log"
  failures=$((failures + 1))
fi

cat > "$J2_BRANCHPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"branch-word-v2":{"target":"goodmorning"}}}
EOF
( cd "$J2_BRANCHPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m advance )

if [[ "$j2c_seeded" != true ]]; then
  # Same anti-vacuous-pass guard as J2b: don't let J2d "pass" by skipping
  # the pack step entirely because J2c's setup never actually recorded it.
  echo "  [FAIL] J2d: skipped — J2c never seeded a recorded tenant_pack (ref=release), so this case cannot exercise re-resolution"
  failures=$((failures + 1))
elif printf 'y\n' | ./scripts/install.sh --tier=0 --mode=merge --skip-requirements > /tmp/install-j2d.log 2>&1; then
  echo "  [PASS] J2d: recorded-pack re-resolution (no --pack) completes"
  if grep -q 'branch-word-v2' "$HOME/.claude/config/aliases.org.json" 2>/dev/null; then
    echo "  [PASS] J2d: a moving-ref pack picks up the upstream change on the next re-resolution"
  else
    echo "  [FAIL] J2d: recorded-pack re-resolution at a moving ref did not pick up the upstream change"
    failures=$((failures + 1))
  fi
else
  echo "  [FAIL] J2d: recorded-pack re-resolution failed — see /tmp/install-j2d.log"
  failures=$((failures + 1))
fi

# ═══ J4: legacy-stub upgrade path (commit e28941b — the merge-mode gap ═══
# every existing user's machine actually hits) ═══════════════════════════
# J2b/J2d's merge-mode cases always rm -rf $HOME/.claude and install fresh
# under the NEW manifest first, so they only ever merge over stubs this
# script itself just generated — never over an install created under the
# OLD (pre-ADR-083) manifest, which is what a real upgrading machine has:
# hand-written ~/.claude/skills/{hi,hello,bye,goodbye,docs,carbonet}/
# SKILL.md with no `<!-- generated by scripts/gen-alias-stubs.sh ... -->`
# header, but the same `alias_of:` frontmatter field the generator has
# always used (ADR-065/D65-D). gen-alias-stubs.sh's refuse-overwrite guard
# (D13 rule 8) used to fire against that exact prior output, hard-aborting
# install.sh's `set -e` on the very next update.sh — commit e28941b fixed
# it with a precise adoption rule (is_adoptable_legacy_stub). Simulates the
# exact scenario the fix's own commit message names.
echo "=== J4: legacy-stub upgrade path (merge over a pre-branch install) ==="

LEGACY_WORDS=(hi hello bye goodbye docs carbonet)
strip_header() {  # strip_header <skill-md-path>
  sed -i.bak '/generated by scripts\/gen-alias-stubs\.sh/d' "$1"
  rm -f "$1.bak"
}

rm -rf "$HOME/.claude"
if ./scripts/install.sh --tier=1 --mode=fresh --skip-requirements > /tmp/install-j4a-fresh.log 2>&1; then
  echo "  [PASS] J4a: initial tier-1 fresh install completes"
else
  echo "  [FAIL] J4a: initial tier-1 fresh install failed — see /tmp/install-j4a-fresh.log"
  failures=$((failures + 1))
fi

j4_setup_ok=true
for word in "${LEGACY_WORDS[@]}"; do
  stub="$HOME/.claude/skills/$word/SKILL.md"
  if [[ ! -f "$stub" ]]; then
    echo "    [J4a] setup: $stub missing after fresh install — cannot simulate the legacy signature"
    j4_setup_ok=false
    continue
  fi
  if ! grep -q 'generated by scripts/gen-alias-stubs\.sh' "$stub"; then
    echo "    [J4a] setup: $stub has no generator header before the strip — fixture is already wrong"
    j4_setup_ok=false
    continue
  fi
  strip_header "$stub"
  if grep -q 'generated by scripts/gen-alias-stubs\.sh' "$stub"; then
    echo "    [J4a] setup: header still present in $stub after strip_header — sed pattern did not match"
    j4_setup_ok=false
  fi
  if ! grep -q '^alias_of:' "$stub"; then
    echo "    [J4a] setup: $stub lost its alias_of: field during the strip — fixture no longer matches the legacy signature"
    j4_setup_ok=false
  fi
done

if [[ "$j4_setup_ok" != true ]]; then
  # Anti-vacuous-pass guard, same pattern as J2b/J2d: if the fixture itself
  # isn't in the legacy shape this case exists to simulate, a merge that
  # "passes" afterward proves nothing about the adoption rule.
  echo "  [FAIL] J4a: legacy-signature fixture setup failed — see notes above; the merge below cannot be trusted as a real test"
  failures=$((failures + 1))
else
  echo "  [PASS] J4a: all six stubs reduced to the legacy signature (alias_of: present, generator header absent)"
fi

if ./scripts/install.sh --tier=1 --mode=merge --skip-requirements > /tmp/install-j4a-merge.log 2>&1; then
  echo "  [PASS] J4a: merge over a legacy (pre-branch) install exits 0 (commit e28941b's fix)"
else
  echo "  [FAIL] J4a: merge over a legacy install failed — see /tmp/install-j4a-merge.log (this is the exact bug e28941b fixed, regressed)"
  failures=$((failures + 1))
fi

j4a_headers_ok=true
for word in "${LEGACY_WORDS[@]}"; do
  stub="$HOME/.claude/skills/$word/SKILL.md"
  if grep -q 'generated by scripts/gen-alias-stubs\.sh' "$stub" 2>/dev/null; then
    :
  else
    echo "    [J4a] $stub does NOT carry the generator header after the merge"
    j4a_headers_ok=false
  fi
done
if [[ "$j4a_headers_ok" == true ]]; then
  echo "  [PASS] J4a: all six legacy stubs were adopted — the header is back on every one"
else
  echo "  [FAIL] J4a: one or more legacy stubs were not adopted (missing header post-merge)"
  failures=$((failures + 1))
fi

# J4b (negative companion — the one that matters most): an unrelated,
# hand-authored SKILL.md with NO `alias_of:` at one of these exact paths
# must still be refused, never silently adopted or overwritten. Without
# this, the adoption rule in J4a could be hiding a blanket "overwrite
# anything header-less" behaviour that would let a real update.sh purge a
# user's own skill just because it happens to share a directory name with
# a promoted alias.
J4B_TARGET="$HOME/.claude/skills/hi/SKILL.md"
J4B_CONTENT=$'---\nname: hi\ndescription: My own personal high-intensity interval training tracker, nothing to do with this stack.\n---\n\n# /hi\n\nLog today'"'"'s HIIT session.\n'
printf '%s' "$J4B_CONTENT" > "$J4B_TARGET"

if grep -q '^alias_of:' "$J4B_TARGET"; then
  echo "  [FAIL] J4b: setup fixture accidentally contains alias_of: — this would not exercise the negative case"
  failures=$((failures + 1))
fi

if ./scripts/install.sh --tier=1 --mode=merge --skip-requirements > /tmp/install-j4b-merge.log 2>&1; then
  echo "  [FAIL] J4b: merge over an unrelated hand-authored skills/hi/SKILL.md exited 0 — it must refuse (this is the case that would let the purge eat a user's own skill)"
  failures=$((failures + 1))
else
  j4b_rc=$?
  if [[ "$j4b_rc" -eq 3 ]]; then
    echo "  [PASS] J4b: merge refuses (exit 3) rather than adopting or overwriting an unrelated hand-authored skill"
  else
    echo "  [FAIL] J4b: merge exited $j4b_rc, want exactly 3 — see /tmp/install-j4b-merge.log"
    failures=$((failures + 1))
  fi
fi

J4B_AFTER="$(cat "$J4B_TARGET" 2>/dev/null || echo '__MISSING__')"
if [[ "$J4B_AFTER" == "$J4B_CONTENT" ]]; then
  echo "  [PASS] J4b: the unrelated hand-authored skills/hi/SKILL.md is byte-unchanged"
else
  echo "  [FAIL] J4b: skills/hi/SKILL.md was modified or deleted by the refused merge — content diverged"
  failures=$((failures + 1))
fi

# Extra rigor beyond the two required assertions: the refuse-overwrite
# check runs "across every materialize target... before any write" (the
# script's own comment) -- prove that by checking a SIBLING word untouched
# by J4b's fixture still carries its header from J4a's successful merge,
# i.e. the whole run really did abort up front rather than half-landing.
J4B_SIBLING="$HOME/.claude/skills/hello/SKILL.md"
if grep -q 'generated by scripts/gen-alias-stubs\.sh' "$J4B_SIBLING" 2>/dev/null; then
  echo "  [PASS] J4b: a sibling stub (hello) is untouched — the refusal aborted the whole run, not just the colliding word"
else
  echo "  [FAIL] J4b: sibling stub hello lost its header — the refused run appears to have partially written before aborting"
  failures=$((failures + 1))
fi

# ═══ T39: install.sh writes a stack-update-pin/v2 pin (ADR-086 D10/D16) ═══
echo "=== T39: install.sh writes the stack-update-pin/v2 pin ==="
rm -rf "$HOME/.claude"
if ./scripts/install.sh --tier=0 --mode=fresh --skip-requirements > /tmp/install-t39.log 2>&1; then
  echo "  [PASS] T39: tier-0 install for the pin test completes"
else
  echo "  [FAIL] T39: tier-0 install for the pin test failed — see /tmp/install-t39.log"
  failures=$((failures + 1))
fi
PIN_FILE="$HOME/.claude/hooks/stack-update.pin.json"
REAL_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REAL_REMOTE="$(git -C "$REAL_REPO_ROOT" remote get-url origin 2>/dev/null || echo '')"
if [[ -z "$REAL_REMOTE" ]]; then
  echo "  [SKIP] T39: this checkout has no 'origin' remote configured — install.sh's" \
    "best-effort pin write has nothing to record, so the file legitimately does not exist"
elif [[ -f "$PIN_FILE" ]]; then
  pin_schema="$(jq -r '.schema' "$PIN_FILE" 2>/dev/null)"
  pin_repo="$(jq -r '.source_repo' "$PIN_FILE" 2>/dev/null)"
  pin_remote="$(jq -r '.remote_url' "$PIN_FILE" 2>/dev/null)"
  pin_tier="$(jq -r '.tier' "$PIN_FILE" 2>/dev/null)"
  t39_ok=true
  [[ "$pin_schema" == "stack-update-pin/v2" ]] \
    || { echo "  [FAIL] T39: pin schema is '$pin_schema', want stack-update-pin/v2"; t39_ok=false; }
  [[ "$pin_repo" == "$REAL_REPO_ROOT" ]] \
    || { echo "  [FAIL] T39: pin source_repo='$pin_repo', want '$REAL_REPO_ROOT'"; t39_ok=false; }
  # D10's validation rules: absolute path, allowlisted characters, no ".." segment.
  case "$pin_repo" in
    /*) : ;;
    *) echo "  [FAIL] T39: pin source_repo is not absolute: $pin_repo"; t39_ok=false ;;
  esac
  [[ "$pin_repo" =~ ^[A-Za-z0-9._/\ -]+$ ]] \
    || { echo "  [FAIL] T39: pin source_repo fails D10's character allowlist: $pin_repo"; t39_ok=false; }
  case "/$pin_repo/" in
    */../*) echo "  [FAIL] T39: pin source_repo contains a '..' segment: $pin_repo"; t39_ok=false ;;
  esac
  [[ "$pin_remote" == "$REAL_REMOTE" ]] \
    || { echo "  [FAIL] T39: pin remote_url='$pin_remote', want '$REAL_REMOTE'"; t39_ok=false; }
  [[ "$pin_tier" == "0" ]] \
    || { echo "  [FAIL] T39: pin tier='$pin_tier', want 0"; t39_ok=false; }
  if [[ "$t39_ok" == true ]]; then
    echo "  [PASS] T39: stack-update-pin/v2 written next to the stamp — schema/source_repo/remote_url/tier all match, validates against D10"
  else
    failures=$((failures + 1))
  fi
else
  echo "  [FAIL] T39: install.sh did not write $PIN_FILE"
  failures=$((failures + 1))
fi

# ═══ T41: install.sh's pack step under STACK_UPDATE_MODE=hook (ADR-086 D11) ═══
echo "=== T41: STACK_UPDATE_MODE=hook pack re-resolution branch ==="

# Case A — a change that needs NO ADR-055 confirmation (a tag-pinned pack
# re-resolved at the SAME tag: empty diff) applies exactly as a human run
# would, even under STACK_UPDATE_MODE=hook + STACK_INSESSION=1.
T41_TAGPACK="$TMPDIR/t41-tagpack"
mkdir -p "$T41_TAGPACK/config"
git init -q "$T41_TAGPACK"
cat > "$T41_TAGPACK/tenant.json" <<'EOF'
{ "tenant_id": "t41tag", "pack_version": "1.0.0", "github": { "org": "t41org" } }
EOF
cat > "$T41_TAGPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"t41-pinned-word":{"target":"goodmorning"}}}
EOF
( cd "$T41_TAGPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m init && git tag v1 )

rm -rf "$HOME/.claude"
if printf 'y\n' | ./scripts/install.sh --tier=0 --pack="${T41_TAGPACK}@v1" --mode=fresh --skip-requirements > /tmp/install-t41a-init.log 2>&1; then
  echo "  [PASS] T41a: initial tag-pinned pack install completes"
else
  echo "  [FAIL] T41a: initial tag-pinned pack install failed — see /tmp/install-t41a-init.log"
  failures=$((failures + 1))
fi

cat > "$T41_TAGPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"t41-pinned-word":{"target":"goodmorning"},"t41-surprise-word":{"target":"goodmorning"}}}
EOF
( cd "$T41_TAGPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m upstream-change )

if STACK_UPDATE_MODE=hook STACK_INSESSION=1 ./scripts/install.sh --tier=0 --mode=merge --skip-requirements </dev/null > /tmp/install-t41a-reresolve.log 2>&1; then
  echo "  [PASS] T41a: no-confirmation-needed re-resolution completes under STACK_UPDATE_MODE=hook, no TTY read attempted"
else
  echo "  [FAIL] T41a: no-confirmation-needed re-resolution failed under STACK_UPDATE_MODE=hook — see /tmp/install-t41a-reresolve.log"
  failures=$((failures + 1))
fi
if grep -q 't41-surprise-word' "$HOME/.claude/config/aliases.org.json" 2>/dev/null; then
  echo "  [FAIL] T41a: a tag-pinned (empty-diff) pack picked up an upstream change it should not have"
  failures=$((failures + 1))
else
  echo "  [PASS] T41a: empty-diff case applies with no behaviour change, as a human run would"
fi
[[ -f "$HOME/.claude/state/pack-pending.json" ]] \
  && { echo "  [FAIL] T41a: pack_pending recorded for a change that needed no confirmation"; failures=$((failures + 1)); } \
  || echo "  [PASS] T41a: no pack_pending recorded (nothing needed confirming)"

# Case B — a change that WOULD have prompted (a moving-ref pack re-resolved
# at the same ref, with real upstream content changes) is deferred rather
# than applied or hard-failed: nothing prompted, pack_pending: true.
T41_BRANCHPACK="$TMPDIR/t41-branchpack"
mkdir -p "$T41_BRANCHPACK/config"
git init -q "$T41_BRANCHPACK"
( cd "$T41_BRANCHPACK" && git checkout -q -b release )
cat > "$T41_BRANCHPACK/tenant.json" <<'EOF'
{ "tenant_id": "t41branch", "pack_version": "1.0.0", "github": { "org": "t41org" } }
EOF
cat > "$T41_BRANCHPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"t41-branch-word-v1":{"target":"goodmorning"}}}
EOF
( cd "$T41_BRANCHPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m init )

rm -rf "$HOME/.claude"
if printf 'y\n' | ./scripts/install.sh --tier=0 --pack="${T41_BRANCHPACK}@release" --mode=fresh --skip-requirements > /tmp/install-t41b-init.log 2>&1; then
  echo "  [PASS] T41b: initial moving-ref pack install completes"
else
  echo "  [FAIL] T41b: initial moving-ref pack install failed — see /tmp/install-t41b-init.log"
  failures=$((failures + 1))
fi

cat > "$T41_BRANCHPACK/config/aliases.org.json" <<'EOF'
{"version":1,"aliases":{"t41-branch-word-v2":{"target":"goodmorning"}}}
EOF
( cd "$T41_BRANCHPACK" && git add -A && git -c user.email=t@example.com -c user.name=tester commit -q -m advance )

t41b_rc=0
STACK_UPDATE_MODE=hook STACK_INSESSION=1 ./scripts/install.sh --tier=0 --mode=merge --skip-requirements </dev/null > /tmp/install-t41b-reresolve.log 2>&1 || t41b_rc=$?
if [[ "$t41b_rc" -eq 0 ]]; then
  echo "  [PASS] T41b: confirmation-class pack re-resolution exits 0 (deferred, not a hard failure) under STACK_UPDATE_MODE=hook"
else
  echo "  [FAIL] T41b: confirmation-class pack re-resolution exited $t41b_rc, want 0 (deferred, not failed) — see /tmp/install-t41b-reresolve.log"
  failures=$((failures + 1))
fi
if grep -q 't41-branch-word-v2' "$HOME/.claude/config/aliases.org.json" 2>/dev/null; then
  echo "  [FAIL] T41b: a confirmation-class change was applied without confirmation"
  failures=$((failures + 1))
else
  echo "  [PASS] T41b: the confirmation-class change was NOT applied"
fi
if [[ -f "$HOME/.claude/state/pack-pending.json" ]] \
    && [[ "$(jq -r '.pack_pending' "$HOME/.claude/state/pack-pending.json" 2>/dev/null)" == "true" ]]; then
  echo "  [PASS] T41b: pack_pending: true recorded for the deferred confirmation-class change"
else
  echo "  [FAIL] T41b: pack_pending was not recorded at \$HOME/.claude/state/pack-pending.json"
  failures=$((failures + 1))
fi
grep -q '\[pack-pending\]' /tmp/install-t41b-reresolve.log \
  && echo "  [PASS] T41b: install.sh's own output names the deferral" \
  || { echo "  [FAIL] T41b: no [pack-pending] marker in install.sh's output"; failures=$((failures + 1)); }

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "$failures failures."
  exit 1
fi

echo "All tiers install + verify pass."
