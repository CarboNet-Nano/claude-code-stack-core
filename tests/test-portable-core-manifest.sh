#!/usr/bin/env bash
# Tests for scripts/gen-portable-core-manifest.sh and the manifest it writes
# (ADR-075 D6).
#
# The load-bearing case is PM8. The manifest's value is that `known` holds every
# version a managed path ever had. Regenerate it anywhere without that history —
# most plausibly the public mirror, which is force-pushed as a parentless
# snapshot — and every path gets `known == [current]`, which reclassifies every
# older copy in the fleet as hand-edited and silently disables self-healing
# everywhere. The generator has to refuse there, and nothing about that refusal
# is visible from a passing manifest, so it needs its own test.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO_ROOT/scripts/gen-portable-core-manifest.sh"
MANIFEST="$REPO_ROOT/config/portable-core-manifest.json"
SKILLS_LIST="$REPO_ROOT/config/portable-core-skills.json"

PASS=0; FAIL=0; SKIPPED=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP: $1"; }

command -v jq >/dev/null 2>&1 || { echo "test-portable-core-manifest: jq required" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pcm-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- PM1 shape
if [[ -f "$MANIFEST" ]]; then
  pass "PM1: config/portable-core-manifest.json is committed"
else
  fail "PM1: manifest missing — run scripts/gen-portable-core-manifest.sh"
  echo "test-portable-core-manifest: $PASS passed, $FAIL failed, $SKIPPED skipped"; exit 1
fi
if jq -e '(.generated_at | type == "string") and (.source_sha | type == "string")
          and (.files | type == "object")' "$MANIFEST" >/dev/null 2>&1; then
  pass "PM1: top-level shape is generated_at / source_sha / files"
else
  fail "PM1: top-level shape wrong"
fi
if jq -e '.files | to_entries | all(.value |
      .current as $c
      | ($c | startswith("sha256:")) and (.known | type == "array")
      and ((.known | length) > 0) and (.known_count == (.known | length))
      and ((.known | index($c)) != null))' "$MANIFEST" >/dev/null 2>&1; then
  pass "PM1: every entry has current, a non-empty known containing current, and a matching count"
else
  fail "PM1: per-file shape wrong: $(jq -c '.files | to_entries[0]' "$MANIFEST")"
fi

# ---------------------------------------------------------------- PM2 coverage
MISSING=""
while IFS= read -r s; do
  jq -e --arg p "skills/$s/SKILL.md" '.files | has($p)' "$MANIFEST" >/dev/null 2>&1 \
    || MISSING="$MISSING $s"
done < <(jq -r '.skills[]' "$SKILLS_LIST")
[[ -z "$MISSING" ]] \
  && pass "PM2: every portable-core skill is covered by the manifest" \
  || fail "PM2: not covered:$MISSING"

# ---------------------------------------------------------------- PM6 size
BYTES="$(wc -c < "$MANIFEST" | tr -d ' ')"
if [[ "$BYTES" =~ ^[0-9]+$ ]] && (( BYTES < 524288 )); then
  pass "PM6: the manifest is ${BYTES}B, under the 512KB ceiling"
else
  fail "PM6: manifest is ${BYTES}B — at this size the per-file history needs bounding, and a bound must be visible rather than silent"
fi

# ---------------------------------------------------------------- PM7 migration
# The claim the whole no-migration story rests on: the pre-fold 230-line
# handoff copy sitting in every repo initialised before ADR-074 must be
# recognised as an old stack version, not as someone's hand-edit.
if OLD="$(git -C "$REPO_ROOT" show 99805b4~1:skills/handoff/SKILL.md 2>/dev/null | shasum -a 256 | awk '{print $1}')"; then
  if jq -e --arg h "sha256:$OLD" '.files["skills/handoff/SKILL.md"].known | index($h) != null' \
       "$MANIFEST" >/dev/null 2>&1; then
    pass "PM7: the pre-fold handoff copy is in known — the fleet self-heals with no migration step"
  else
    fail "PM7: the pre-fold copy is NOT in known — every repo holding it would be treated as hand-edited"
  fi
else
  skip "PM7: pre-fold blob unavailable in this clone"
fi

# ---------------------------------------------------------------- PM3 --check
# This is the check that fires whenever someone edits a portable-core skill
# and forgets the manifest. It must say exactly what to run, because the
# consequence of ignoring it is invisible: a manifest whose `current` disagrees
# with the shipped file classifies every up-to-date copy in the fleet as
# `diverged`, and self-healing stops without a symptom.
bash "$GEN" --check >/dev/null 2>&1
PM3_RC=$?
case "$PM3_RC" in
  0) pass "PM3: --check passes against the committed manifest" ;;
  2)
    # The generator refuses where the history it needs is absent — a shallow
    # checkout, or a parentless snapshot. CI checks out at depth 1, so this is
    # the NORMAL result there, and it is the guard working rather than a
    # problem. Treating it as drift is how this test failed its first CI run:
    # "cannot verify here" is not "verified wrong", and a test that conflates
    # them turns a correct refusal into a red build.
    skip "PM3: --check cannot run here (the generator refuses without full history — expected on a shallow checkout)" ;;
  *)
    fail "PM3: the committed manifest no longer matches the skills in this tree.
        You edited a portable-core skill. Run, and commit the result:
          bash scripts/gen-portable-core-manifest.sh
        Differing paths:
$(bash "$GEN" --check 2>&1 | grep 'differs:' | sed 's/^/        /')" ;;
esac
CHECK_TMP="$TMP/stale-manifest.json"
jq '.files["skills/handoff/SKILL.md"].current = "sha256:0000"' "$MANIFEST" > "$CHECK_TMP"
if bash "$GEN" --check --out "$CHECK_TMP" >/dev/null 2>&1; then
  fail "PM3: --check passed against a doctored manifest"
else
  pass "PM3: --check fails (exit 1) when the manifest disagrees with the tree"
fi

# ---------------------------------------------------------------- PM4 usage
bash "$GEN" --bogus >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "PM4: an unknown argument exits 2" || fail "PM4: expected exit 2"

# ---------------------------------------------------------------- PM8 (D6 guard 2)
# Reproduce the mirror's shape: one parentless commit, so every managed path has
# exactly one revision. This is the case that would silently break the fleet.
SNAP="$TMP/snapshot"
mkdir -p "$SNAP"
( cd "$SNAP" && git init -q -b main . && git config user.email t@t.t && git config user.name t ) >/dev/null 2>&1
mkdir -p "$SNAP/config" "$SNAP/scripts"
cp "$SKILLS_LIST" "$SNAP/config/"
cp "$GEN" "$SNAP/scripts/"
while IFS= read -r s; do
  mkdir -p "$SNAP/skills/$s"
  cp "$REPO_ROOT/skills/$s/SKILL.md" "$SNAP/skills/$s/SKILL.md" 2>/dev/null || true
done < <(jq -r '.skills[]' "$SKILLS_LIST")
( cd "$SNAP" && git add -A && git commit -qm "parentless snapshot" ) >/dev/null 2>&1

GEN_OUT="$( cd "$SNAP" && bash scripts/gen-portable-core-manifest.sh 2>&1 )"; GEN_RC=$?
if [[ $GEN_RC -eq 2 ]]; then
  pass "PM8: the generator REFUSES on a parentless snapshot (the mirror's shape)"
else
  fail "PM8: generated a manifest from a one-commit snapshot (rc=$GEN_RC) — every older copy in the fleet would classify as hand-edited"
fi
if [[ ! -f "$SNAP/config/portable-core-manifest.json" ]]; then
  pass "PM8: the refusal wrote nothing"
else
  fail "PM8: a manifest was written despite the refusal"
fi
printf '%s' "$GEN_OUT" | grep -qi "snapshot\|history\|source repository" \
  && pass "PM8: the refusal explains why, not just that" \
  || fail "PM8: unhelpful refusal message: $GEN_OUT"

# ---------------------------------------------------------------- PM9 (append-only)
# `known` means "every version the stack has ever published", and git is not
# a reliable record of that: a squash merge, a deleted branch, a dropped
# stash or a `gc` all make a real published version unreachable. A generator
# that rebuilds purely from `git log --all` therefore SHRINKS the list, and a
# machine still holding a dropped version stops being recognised as stale --
# it reads as hand-edited and never self-heals again.
#
# Measured 2026-08-19 against the pre-fix generator: a plain rebuild dropped
# 1 hash from goodmorning and 2 from project-init, one surviving only in a
# dangling commit. This asserts the property directly rather than those
# numbers, which move with history.

PM9_OUT="$TMP/pm9-regenerated.json"
if bash "$GEN" --out "$PM9_OUT" >/dev/null 2>&1 && [ -s "$PM9_OUT" ]; then
  PM9_LOST=0
  PM9_DETAIL=""
  for p in $(jq -r '.files | keys[]' "$MANIFEST"); do
    jq -r --arg p "$p" '.files[$p].known[]' "$MANIFEST"  | sort > "$TMP/pm9-old.txt"
    jq -r --arg p "$p" '.files[$p].known[]' "$PM9_OUT"   | sort > "$TMP/pm9-new.txt"
    n="$(comm -23 "$TMP/pm9-old.txt" "$TMP/pm9-new.txt" | grep -c . || true)"
    if [ "$n" != "0" ]; then
      PM9_LOST=$((PM9_LOST + n))
      PM9_DETAIL="$PM9_DETAIL $p($n)"
    fi
  done
  [ "$PM9_LOST" = "0" ] \
    && pass "PM9: regenerating drops no known hash — the list is append-only, so a version git can no longer reach still self-heals in the fleet" \
    || fail "PM9: regenerating would drop $PM9_LOST known hash(es):$PM9_DETAIL — those copies would classify as hand-edited and never self-heal"

  # ...and the guard is not vacuous: it must be comparing a real, non-empty
  # list, or "nothing lost" would be true of an empty manifest too.
  PM9_TOTAL="$(jq -r '[.files[].known[]] | length' "$MANIFEST")"
  [ "$PM9_TOTAL" -gt 10 ] \
    && pass "PM9 precondition: $PM9_TOTAL known hashes were actually compared (not a vacuous empty-vs-empty pass)" \
    || fail "PM9 precondition: only $PM9_TOTAL known hashes in the manifest — the check above proves little"
else
  skip "PM9: append-only regeneration — the generator declined to run here"
fi

# ---------------------------------------------------------------- I-d
# The generator must not be installed anywhere. Not shipping it is guard 1:
# a tool that cannot reach a consumer machine cannot be run there by accident.
if grep -rq "gen-portable-core-manifest" "$REPO_ROOT/config/tier-manifests/" 2>/dev/null; then
  fail "I-d: the generator appears in a tier manifest — it must never install"
else
  pass "I-d: the generator is in no tier manifest (D6 guard 1)"
fi
if grep -q "portable-core-manifest.json" "$REPO_ROOT/config/tier-manifests/tier-0.json" 2>/dev/null; then
  pass "I-d: the manifest itself IS a tier-0 entry, so it cannot go stale on a machine"
else
  fail "I-d: the manifest is not installed at tier 0"
fi

echo "test-portable-core-manifest: $PASS passed, $FAIL failed, $SKIPPED skipped"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
