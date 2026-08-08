#!/usr/bin/env bash
# Tests for scripts/lib/resolve-migrations-dir.sh (ADR-037 D-2).
#
# The load-bearing cases are the REFUSALS. guards.migrations_dir is a
# repo-controlled string from a checked-in file, so a malicious or careless
# value must fail closed rather than be sanitized into something plausible.
# The ADR-037 security review named the unchecked-path vector explicitly;
# these tests are what keeps it closed.
#
# Return-code contract under test:
#   0 -> resolved, path printed
#   1 -> no migrations directory (silent no-op; repo doesn't pay for the hook)
#   2 -> a value was configured but REFUSED (distinct from "not found")

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/resolve-migrations-dir.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$LIB"

# new_repo <name> -> prints an initialized repo root
new_repo() {
  local root="$TMP/$1"
  mkdir -p "$root/.claude"
  git -C "$root" init -q 2>/dev/null
  printf '%s\n' "$root"
}

set_cfg() {
  local root="$1" val="$2"
  jq -n --arg v "$val" '{guards: {migrations_dir: $v}}' > "$root/.claude/stack-config.json"
}

# --- probing ---------------------------------------------------------------

r="$(new_repo probe-supabase)"; mkdir -p "$r/supabase/migrations"
out="$(rmd_resolve "$r")" && [[ "$out" == "supabase/migrations" ]] \
  && pass "probes supabase/migrations" || fail "probes supabase/migrations (got '$out')"

r="$(new_repo probe-db)"; mkdir -p "$r/db/migrations"
out="$(rmd_resolve "$r")" && [[ "$out" == "db/migrations" ]] \
  && pass "probes db/migrations" || fail "probes db/migrations (got '$out')"

r="$(new_repo probe-order)"; mkdir -p "$r/migrations" "$r/supabase/migrations"
out="$(rmd_resolve "$r")" && [[ "$out" == "supabase/migrations" ]] \
  && pass "most-specific candidate wins" || fail "most-specific candidate wins (got '$out')"

r="$(new_repo probe-none)"
if rmd_resolve "$r" >/dev/null 2>&1; then
  fail "no migrations dir returns nonzero"
else
  [[ $? -eq 1 ]] && pass "no migrations dir returns 1 (silent no-op)" \
                 || fail "no migrations dir returned wrong code"
fi

# --- configured value ------------------------------------------------------

r="$(new_repo cfg-ok)"; mkdir -p "$r/custom/migs"; set_cfg "$r" "custom/migs"
out="$(rmd_resolve "$r")" && [[ "$out" == "custom/migs" ]] \
  && pass "configured dir wins over probe" || fail "configured dir wins over probe (got '$out')"

r="$(new_repo cfg-missing)"; set_cfg "$r" "does/not/exist"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] && pass "configured but absent dir returns 1" \
                || fail "configured but absent dir returned $rc"

# --- refusals (the point of this file) -------------------------------------

r="$(new_repo refuse-abs)"; mkdir -p "$r/m"; set_cfg "$r" "/etc"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses absolute path" || fail "absolute path returned $rc, want 2"

r="$(new_repo refuse-dotdot)"; mkdir -p "$r/m"; set_cfg "$r" "../../etc"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses .. traversal" || fail ".. traversal returned $rc, want 2"

r="$(new_repo refuse-trailing)"; mkdir -p "$r/m"; set_cfg "$r" "m/"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses trailing slash" || fail "trailing slash returned $rc, want 2"

r="$(new_repo refuse-dbl)"; mkdir -p "$r/m"; set_cfg "$r" "a//b"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses empty component" || fail "empty component returned $rc, want 2"

r="$(new_repo refuse-ctrl)"; mkdir -p "$r/m"; set_cfg "$r" "$(printf 'a\nb')"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses control chars" || fail "control chars returned $rc, want 2"

# Symlink escape: the configured dir exists and is lexically clean, but points
# outside the repo. A lexical-only check would pass this.
r="$(new_repo refuse-symlink)"; mkdir -p "$TMP/outside-target"
ln -s "$TMP/outside-target" "$r/escaped"; set_cfg "$r" "escaped"
rc=0; rmd_resolve "$r" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && pass "refuses symlink escaping repo root" \
               || fail "symlink escape returned $rc, want 2"

# A malformed config must degrade to probing, not error out.
r="$(new_repo cfg-malformed)"; mkdir -p "$r/db/migrations"
printf '{ not json' > "$r/.claude/stack-config.json"
out="$(rmd_resolve "$r")" && [[ "$out" == "db/migrations" ]] \
  && pass "malformed config falls through to probe" \
  || fail "malformed config fell through wrong (got '$out')"

# --- rmd_is_migration_file -------------------------------------------------

r="$(new_repo isfile)"; mkdir -p "$r/db/migrations"
touch "$r/db/migrations/001_init.sql" "$r/src/app.ts" 2>/dev/null || mkdir -p "$r/src" && touch "$r/src/app.ts"

rmd_is_migration_file "$r/db/migrations/001_init.sql" "$r" \
  && pass "identifies a migration file" || fail "identifies a migration file"

rmd_is_migration_file "$r/src/app.ts" "$r" \
  && fail "non-migration file wrongly matched" || pass "rejects a non-migration file"

# Path spelling must not defeat the check.
rmd_is_migration_file "$r/db/./migrations/001_init.sql" "$r" \
  && pass "canonicalizes ./ in path" || fail "canonicalizes ./ in path"

r2="$(new_repo isfile-none)"
rmd_is_migration_file "$r2/whatever.sql" "$r2" \
  && fail "matched with no migrations dir" || pass "no migrations dir means nothing matches"

echo
echo "resolve-migrations-dir: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
