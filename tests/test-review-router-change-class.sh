#!/usr/bin/env bash
# Tests for scripts/lib/review-router.sh's rr_change_class (ADR-087 D4).
# rr_stakes/rr_run/rr_classify_stakes are untouched by this addition -- see
# tests/test-review-router.sh for their coverage.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/review-router.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected '$2', got '$3')"; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
export REVIEW_ASSUME_LOCAL=1

# build_repo <changed_file_path> [content] : commits base, then a feature
# commit changing the given path (creating it if needed).
build_repo() {
  local changed="$1" content="${2:-change}"
  local R="$TMP/repo-$RANDOM$RANDOM"; mkdir -p "$R"
  (
    cd "$R"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    echo base > README.md
    mkdir -p hooks scripts/lib schemas config docs/ADRs
    git add -A; git commit -qm base
    git checkout -q -b feat
    mkdir -p "$(dirname "$changed")"
    printf '%s\n' "$content" > "$changed"
    git add -A; git commit -qm feat
  )
  echo "$R"
}

class_of() { # <repo> -> echoes low/med/high
  local R="$1"
  ( cd "$R"; bash -c "source '$LIB'; rr_change_class main HEAD" )
}

# ─── low: docs/tests/fixtures/changelogs only ───────────────────────────────
R1="$(build_repo docs/notes.md)"
assert_eq "docs-only change -> low" "low" "$(class_of "$R1")"

R1B="$(build_repo tests/test-something.sh)"
assert_eq "test file change -> med (source extension, not docs)" "med" "$(class_of "$R1B")"

# ─── med: source-file extension, not high ───────────────────────────────────
R2="$(build_repo scripts/some-tool.sh)"
assert_eq "generic .sh under scripts/ (not install/update) -> med" "med" "$(class_of "$R2")"

R2B="$(build_repo src/app.py)"
assert_eq ".py source file -> med" "med" "$(class_of "$R2B")"

# ─── high: rr_stakes' own high triggers fold in ─────────────────────────────
R3="$(build_repo src/auth/login.ts)"
assert_eq "auth-path source file -> high (rr_stakes fold-in)" "high" "$(class_of "$R3")"

# ─── high: hooks/** ──────────────────────────────────────────────────────────
R4="$(build_repo hooks/some-new-hook.sh)"
assert_eq "hooks/** -> high" "high" "$(class_of "$R4")"

# ─── high: the three named config files ─────────────────────────────────────
R5="$(build_repo config/managed-settings.floor.json '{}')"
assert_eq "config/managed-settings.floor.json -> high" "high" "$(class_of "$R5")"
R5B="$(build_repo config/permissions-baseline.json '{}')"
assert_eq "config/permissions-baseline.json -> high" "high" "$(class_of "$R5B")"
R5C="$(build_repo config/settings.global.template.json '{}')"
assert_eq "config/settings.global.template.json -> high" "high" "$(class_of "$R5C")"

# ─── high: schemas/** ────────────────────────────────────────────────────────
R6="$(build_repo schemas/whatever.json '{}')"
assert_eq "schemas/** -> high" "high" "$(class_of "$R6")"

# ─── high: scripts/install.sh, scripts/update.sh ────────────────────────────
R7="$(build_repo scripts/install.sh)"
assert_eq "scripts/install.sh -> high" "high" "$(class_of "$R7")"
R7B="$(build_repo scripts/update.sh)"
assert_eq "scripts/update.sh -> high" "high" "$(class_of "$R7B")"

# ─── high: every member of D13b's self-governing set ────────────────────────
SG_R="$TMP/repo-sg"; mkdir -p "$SG_R"
( cd "$SG_R"; git init -q -b main; git config user.email t@t.t; git config user.name t
  echo base > README.md; git add -A; git commit -qm base )
while IFS= read -r member; do
  [[ -z "$member" ]] && continue
  R_SG="$(build_repo "$member" 'x')"
  RESULT="$(class_of "$R_SG")"
  assert_eq "self-governing member '$member' -> high" "high" "$RESULT"
done < <( ( cd "$SG_R"; bash -c "source '$LIB'; rr_self_governing_paths" ) )

R_GH="$(build_repo .github/workflows/self-governance.yml 'on: push')"
assert_eq ".github/workflows/** -> high" "high" "$(class_of "$R_GH")"
R_GHR="$(build_repo .github/rulesets/self-governance.json '{}')"
assert_eq ".github/rulesets/** -> high" "high" "$(class_of "$R_GHR")"

# ─── high: a NEW ADR (added file, not merely edited) ────────────────────────
R8="$(build_repo docs/ADRs/999-new-thing.md '# New ADR')"
assert_eq "a newly-added ADR file -> high" "high" "$(class_of "$R8")"

# An EDIT to an existing ADR (already present at the base commit) is not, on
# its own, a "new ADR" -- it still classifies on its own extension (.md is
# neither a med source extension nor high by path), so it should be low.
R8B="$TMP/repo-adr-edit"; mkdir -p "$R8B/docs/ADRs"
( cd "$R8B"; git init -q -b main; git config user.email t@t.t; git config user.name t
  echo "# Existing ADR" > docs/ADRs/001-existing.md
  git add -A; git commit -qm base
  git checkout -q -b feat
  echo "# Existing ADR, revised" > docs/ADRs/001-existing.md
  git add -A; git commit -qm feat )
assert_eq "editing an EXISTING ADR (not adding one) -> low" "low" "$(class_of "$R8B")"

# ─── high: a new external network host added to vendor-hosts.json ──────────
R9="$TMP/repo-host"; mkdir -p "$R9/config"
( cd "$R9"; git init -q -b main; git config user.email t@t.t; git config user.name t
  echo '{"allowedHosts":["api.example.com"]}' > config/vendor-hosts.json
  git add -A; git commit -qm base
  git checkout -q -b feat
  echo '{"allowedHosts":["api.example.com","evil.newhost.com"]}' > config/vendor-hosts.json
  git add -A; git commit -qm feat )
assert_eq "new external host in vendor-hosts.json -> high" "high" "$(class_of "$R9")"

# ─── fail-safe: unresolvable ref -> high ─────────────────────────────────────
RFS="$(build_repo docs/notes.md)"
RESULT_FS="$( cd "$RFS"; bash -c "source '$LIB'; rr_change_class does-not-exist HEAD" )"
assert_eq "unresolvable base ref -> high (fail-safe)" "high" "$RESULT_FS"

# ─── empty diff -> high (the ref-rewrite attack's exact shape) ──────────────
REMPTY="$(build_repo docs/notes.md)"
RESULT_EMPTY="$( cd "$REMPTY"; bash -c "source '$LIB'; rr_change_class HEAD HEAD" )"
assert_eq "empty diff (base==head) -> high (incoherent, ADR-087 D4)" "high" "$RESULT_EMPTY"

# ─── never empty ─────────────────────────────────────────────────────────────
[[ -n "$RESULT_FS" ]] && pass "rr_change_class never prints empty output" || fail "empty output on fail-safe path"

echo "----------------------------------------"
echo "review-router-change-class: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
