#!/usr/bin/env bash
# Migrations-directory resolver (ADR-037 D-2): the single source of truth for
# "where do this repo's migrations live". Both the migration-edit hook (D-1)
# and /new-migration (D-3) resolve through here so the two cannot disagree
# about what counts as a migration file — a drift that would let the skill
# create files in a directory the hook never guards.
#
# Sourced, not executed (same pattern as secret-binder.sh / tier-installer.sh):
# functions only, callers own `set -uo pipefail`, errors on stderr.
#
# Resolution order (ADR-037 D-2):
#   1. guards.migrations_dir in .claude/stack-config.json, if set
#   2. probe a fixed candidate list, first hit wins
#   3. no-op — print nothing, return 1
#
# SECURITY: the configured value is a repo-controlled string from a checked-in
# file. It is REFUSED, not sanitized, when unclean — absolute paths, "..",
# control chars, and symlinks all fail closed. Containment reuses the vetted
# _ppv_* primitives rather than inventing a second pattern; see ADR-037 and
# the security-auditor finding that named them.

# Candidate directories probed when no explicit config is set. Ordered most- to
# least-specific so a repo with both supabase/migrations and migrations/ gets
# the one its tooling actually uses.
RMD_CANDIDATES=(
  "supabase/migrations"
  "db/migrations"
  "drizzle"
  "migrations"
)

# Load the containment primitives. Deliberately a hard failure: resolving a
# repo-controlled path WITHOUT containment checks is exactly the vector the
# ADR-037 review flagged, so a missing helper must stop the caller rather than
# silently degrade to an unchecked path.
_rmd_load_containment() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/project-pack-vendor.sh" 2>/dev/null || return 1
  declare -F _ppv_clean_rel >/dev/null && declare -F _ppv_source_within >/dev/null
}

# rmd_repo_root -> absolute repo root, or 1 if not in a git repo.
rmd_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# rmd_configured_dir <repo_root> -> the guards.migrations_dir value, or empty.
# A malformed stack-config.json yields empty (jq fails) rather than an error:
# the caller falls through to probing, which is the correct degradation.
rmd_configured_dir() {
  local root="$1"
  local cfg="$root/.claude/stack-config.json"
  [[ -f "$cfg" ]] || return 0
  jq -r '.guards.migrations_dir // empty' "$cfg" 2>/dev/null
}

# rmd_resolve [repo_root] -> prints the migrations dir RELATIVE to repo root.
# Returns 0 on a hit, 1 when no migrations directory exists (the silent no-op
# case — a repo without migrations must never pay for the hook).
#
# Returns 2 when a CONFIGURED value is present but unsafe. That is deliberately
# distinct from "not found": a repo that asked for a directory and got refused
# is a condition the caller must surface, not treat as "no migrations here".
rmd_resolve() {
  local root="${1:-}"
  [[ -n "$root" ]] || root="$(rmd_repo_root)" || return 1
  [[ -d "$root" ]] || return 1

  _rmd_load_containment || {
    printf 'resolve-migrations-dir: containment helpers unavailable; refusing to resolve\n' >&2
    return 2
  }

  local configured
  configured="$(rmd_configured_dir "$root")"

  if [[ -n "$configured" ]]; then
    if ! _ppv_clean_rel "$configured"; then
      printf 'resolve-migrations-dir: refusing unclean guards.migrations_dir\n' >&2
      return 2
    fi
    local abs="$root/$configured"
    [[ -d "$abs" ]] || return 1
    # _ppv_source_within rejects a symlinked final component, which is what
    # stops a configured dir from pointing outside the repo.
    if ! _ppv_source_within "$abs" "$root"; then
      printf 'resolve-migrations-dir: refusing guards.migrations_dir outside repo root\n' >&2
      return 2
    fi
    printf '%s\n' "$configured"
    return 0
  fi

  local cand
  for cand in "${RMD_CANDIDATES[@]}"; do
    local abs="$root/$cand"
    [[ -d "$abs" ]] || continue
    _ppv_source_within "$abs" "$root" || continue
    printf '%s\n' "$cand"
    return 0
  done

  return 1
}

# rmd_is_migration_file <abs_or_rel_path> [repo_root] -> 0 iff the path sits
# inside the resolved migrations directory. Used by the D-1 hook to decide
# whether an edit is in scope at all.
#
# Compares canonicalized paths so a symlinked repo dir or a "./db/./migrations"
# spelling cannot slip past a raw string prefix check.
rmd_is_migration_file() {
  local path="$1" root="${2:-}"
  [[ -n "$root" ]] || root="$(rmd_repo_root)" || return 1

  local rel_dir
  rel_dir="$(rmd_resolve "$root")" || return 1

  local mig_real
  mig_real="$(cd "$root/$rel_dir" 2>/dev/null && pwd -P)" || return 1

  local path_dir path_real
  path_dir="$(dirname "$path")"
  path_real="$(cd "$path_dir" 2>/dev/null && pwd -P)" || return 1

  [[ "$path_real" == "$mig_real" || "$path_real" == "$mig_real"/* ]]
}
