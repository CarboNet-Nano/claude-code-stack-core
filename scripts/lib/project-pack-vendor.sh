#!/usr/bin/env bash
# Per-project tenant-pack consumption (M3, ADR-034 §4). Sourced by the
# /project-init skill. Where pack-installer.sh composes a pack into the GLOBAL
# ~/.claude at install time, these functions consume the already-landed pack
# into a single PROJECT repo: stamp the tenant id, apply the CLAUDE.md fragment
# to the project's own overlay region, and vendor the pack's standards/ files
# into the repo as committed files (retiring the old symlink+LaunchAgent sync).
#
# apply_org_overlay_section (ADR-013 amendment #3) is reused from
# pack-installer.sh — sourcing that file only defines functions (no top-level
# execution), and apply_org_overlay_section itself needs only awk/grep.
#
# Callers run these with errexit suppressed (`if ! vendor_tenant_standards`),
# so every fallible step is checked explicitly — never rely on set -e here.
#
# Security posture (tenant isolation, per cross-family review): a pack is
# untrusted input. Both the pack side (source) and the repo side (destination)
# are canonicalized with `pwd -P` and containment-checked, and final components
# are refused if they are symlinks — mirroring pack-installer.sh::validate_pack.
# A lexical `..`/absolute check alone is NOT sufficient (a symlinked file or
# intermediate dir escapes it), so realpath containment is the real guard.
#
# Threat model / scope (validate-then-copy TOCTOU): checks and the copy are
# separate syscalls. This is acceptable HERE because /project-init runs
# synchronously in a single user session over a pack dir that was written by a
# trusted `install.sh --pack` step and a repo the same user owns — neither is
# concurrently mutated by another principal during the run. We are NOT
# defending against an attacker with concurrent write access to the pack dir or
# repo tree mid-run; if that ever becomes part of the model, the copies must
# move to O_NOFOLLOW fds / copy-then-atomic-rename. To limit blast radius we do
# still: refuse symlinked final components, and break hardlinks on the
# destination (rm before cp) so a pre-existing hardlinked dest cannot be written
# through to an outside inode. Residual (documented, accepted): NFC/NFD Unicode
# path collisions are not folded — packs come from the trusted install step.

_ppv_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pack-installer.sh
if ! source "$_ppv_lib_dir/pack-installer.sh"; then
  echo "  [pack-vendor-fail] could not source pack-installer.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# _ppv_clean_rel <relpath> -> 0 iff <relpath> is a STRICT clean relative path:
# not absolute, no empty components (no "//", no leading/trailing slash), no
# control chars, and no "." or ".." components. Rejecting these outright (rather
# than trying to dedup their equivalents later) closes the whole "two spellings,
# one file" collision class in one place. Legit names like v1..2.md still pass —
# only a whole ".."/"." COMPONENT is rejected, not the substring.
_ppv_clean_rel() {
  local rel="$1"
  [[ -n "$rel" ]] || return 1
  # No control chars (newline/CR/tab/etc). An embedded newline is the visible
  # symptom of a jq/read transport boundary splitting one map value into two
  # paths; rejecting control chars closes that at the grammar layer too.
  case "$rel" in *[[:cntrl:]]*) return 1 ;; esac
  [[ "$rel" != /* && "$rel" != */ ]] || return 1
  [[ "$rel" != *"//"* ]] || return 1
  [[ "/$rel/" != *"/../"* ]] || return 1
  [[ "/$rel/" != *"/./"* ]] || return 1
  return 0
}

# _ppv_source_within <candidate> <root>
# 0 iff <candidate> resolves inside <root> (both canonicalized with pwd -P) AND
# its final component is not a symlink. Catches symlinked files and symlinked
# intermediate dirs that a lexical check would miss.
_ppv_source_within() {
  local cand="$1" root="$2"
  local root_real cand_real
  root_real="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  [[ ! -L "$cand" ]] || return 1
  cand_real="$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)/$(basename "$cand")" || return 1
  [[ "$cand_real" == "$root_real" || "$cand_real" == "$root_real"/* ]]
}

# _ppv_dest_safe <dest> <repo_root>
# 0 iff writing <dest> stays inside <repo_root>: the nearest EXISTING ancestor
# of <dest> resolves within repo_root (so a later mkdir -p cannot climb out via
# a symlinked ancestor), and <dest> itself is not an existing symlink.
_ppv_dest_safe() {
  local dest="$1" root="$2"
  local root_real d d_real
  root_real="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  [[ ! -L "$dest" ]] || return 1
  d="$(dirname "$dest")"
  while [[ ! -d "$d" && "$d" != "." && "$d" != "/" ]]; do d="$(dirname "$d")"; done
  d_real="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  [[ "$d_real" == "$root_real" || "$d_real" == "$root_real"/* ]]
}

# _ppv_canon_dest <dest> -> canonical absolute path used as the dedup key:
# resolve the nearest EXISTING ancestor with pwd -P (collapsing any symlinked
# repo dir like alias -> dir) and re-append the not-yet-existing tail. Two
# lexically-distinct rels that land on the same on-disk file therefore produce
# the same key — which a raw-string compare would miss.
_ppv_canon_dest() {
  local dest="$1"
  # Start at the PARENT and climb to the nearest existing DIRECTORY — never cd
  # into dest itself (it may already exist as a regular file, which would make
  # `cd` fail and break the normal re-vendor/overwrite path).
  local d tail
  d="$(dirname "$dest")"
  tail="/$(basename "$dest")"
  while [[ ! -d "$d" && "$d" != "/" && "$d" != "." ]]; do
    tail="/$(basename "$d")$tail"
    d="$(dirname "$d")"
  done
  local real
  real="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  printf '%s%s' "$real" "$tail"
}

# resolve_installed_pack <claude_dir>
# Reads the tenant_pack reference written by `install.sh --pack` into
# <claude_dir>/stack-defaults.json and confirms the landed pack dir + its
# tenant.json exist. Echoes "<tenant_id>|<pack_dir>" on success. Returns 1
# (silently — no pack is the normal single-tenant case) when no valid pack is
# installed, so /project-init falls back to today's tenant-less behavior.
resolve_installed_pack() {
  local claude_dir="$1"
  local defaults="$claude_dir/stack-defaults.json"

  [[ -f "$defaults" ]] || return 1
  jq -e '.tenant_pack' "$defaults" >/dev/null 2>&1 || return 1

  local tenant_id pack_dir
  tenant_id="$(jq -r '.tenant_pack.tenant_id // empty' "$defaults" 2>/dev/null)" || return 1
  pack_dir="$(jq -r '.tenant_pack.path // empty' "$defaults" 2>/dev/null)" || return 1

  [[ "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]] || return 1
  [[ -n "$pack_dir" && -f "$pack_dir/tenant.json" ]] || return 1
  # A "|" or newline in pack_dir would corrupt the delimited return protocol.
  [[ "$pack_dir" != *"|"* && "$pack_dir" != *$'\n'* ]] || return 1

  # pack_dir must resolve under <claude_dir>/packs/, not be a symlink itself
  # (mirrors _ppv_dest_safe/_ppv_source_within elsewhere in this file) — an
  # attacker-influenced stack-defaults.json pointer must not make this
  # function trust an arbitrary directory as "the landed pack" (see
  # security-report.md 2026-08-04, HIGH).
  [[ ! -L "$pack_dir" ]] || return 1
  local claude_real pack_real
  claude_real="$(cd "$claude_dir/packs" 2>/dev/null && pwd -P)" || return 1
  pack_real="$(cd "$pack_dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$pack_real" == "$claude_real" || "$pack_real" == "$claude_real"/* ]] || return 1

  # The landed pack must actually be this tenant — guards a stale/mismatched
  # stack-defaults pointer from stamping the wrong id into the project.
  local landed_id
  landed_id="$(jq -r '.tenant_id // empty' "$pack_dir/tenant.json" 2>/dev/null)" || return 1
  [[ "$landed_id" == "$tenant_id" ]] || return 1

  echo "$tenant_id|$pack_dir"
}

# set_config_tenant_id <stack_config_path> <tenant_id> <repo_root>
# Writes .tenant_id into an existing stack-config.json (per-tenant identity,
# ADR-034 §4). Idempotent; atomic via mktemp+mv so a jq failure never leaves a
# truncated config. Containment-checked like the other writers: refuses if the
# config (or a symlinked ancestor such as a symlinked .claude/) resolves outside
# repo_root, so a mktemp+mv can't land outside the repo.
set_config_tenant_id() {
  local config="$1" tenant_id="$2" repo_root="$3"

  [[ -f "$config" ]] || { echo "  [pack-vendor-fail] stack-config not found: $config" >&2; return 1; }
  [[ "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]] || {
    echo "  [pack-vendor-fail] invalid tenant_id: $tenant_id" >&2; return 1; }
  [[ -n "$repo_root" ]] || { echo "  [pack-vendor-fail] set_config_tenant_id requires repo_root" >&2; return 1; }
  if ! _ppv_dest_safe "$config" "$repo_root"; then
    echo "  [pack-vendor-fail] stack-config is a symlink or resolves outside the repo: $config" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp "$(dirname "$config")/.ppv.XXXXXX")" || return 1
  if ! jq --arg t "$tenant_id" '.tenant_id = $t' "$config" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "  [pack-vendor-fail] could not write tenant_id into $config" >&2
    return 1
  fi
  mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

# apply_project_claude_fragment <pack_dir> <project_claude_md> <repo_root>
# Applies the pack's CLAUDE fragment to the PROJECT CLAUDE.md ORG_OVERLAY_MANAGED
# region (marker-region replace, idempotent — ADR-013 amendment #3). No-op with
# success if the pack ships no fragment file. Refuses a symlinked fragment
# source (would read outside the pack) or a project CLAUDE.md target that is a
# symlink or resolves outside repo_root (would write outside the repo) — same
# containment guard set_config_tenant_id applies to its writes.
apply_project_claude_fragment() {
  local pack_dir="$1" project_claude="$2" repo_root="$3"

  [[ -n "$repo_root" ]] || { echo "  [pack-vendor-fail] apply_project_claude_fragment requires repo_root" >&2; return 1; }

  local fragment_rel
  fragment_rel="$(jq -r '.claude_fragment_path // "CLAUDE.fragment.md"' "$pack_dir/tenant.json" 2>/dev/null)" || return 1

  if ! _ppv_clean_rel "$fragment_rel"; then
    echo "  [pack-vendor-fail] claude_fragment_path is not a clean relative path: $fragment_rel" >&2
    return 1
  fi
  [[ -e "$pack_dir/$fragment_rel" ]] || return 0
  # Must be a regular file — a FIFO would hang the read, a dir/device would fail
  # partway (after touch has already created the target). Mirrors the -f check
  # vendor_tenant_standards applies to its sources.
  if [[ ! -f "$pack_dir/$fragment_rel" ]]; then
    echo "  [pack-vendor-fail] claude_fragment_path is not a regular file: $fragment_rel" >&2
    return 1
  fi
  if ! _ppv_source_within "$pack_dir/$fragment_rel" "$pack_dir"; then
    echo "  [pack-vendor-fail] claude_fragment_path is a symlink or escapes the pack: $fragment_rel" >&2
    return 1
  fi

  # Refuse a symlinked target, or one whose nearest existing ancestor resolves
  # outside the repo — a later touch/write must not climb out via a symlinked
  # ancestor. _ppv_dest_safe covers both the symlink and the containment case.
  if ! _ppv_dest_safe "$project_claude" "$repo_root"; then
    echo "  [pack-vendor-fail] project CLAUDE.md is a symlink or resolves outside the repo: $project_claude" >&2
    return 1
  fi
  # apply_org_overlay_section writes through a predictable "$target.new" temp;
  # refuse ANY pre-placed entry there (symlink OR hardlink OR regular file) —
  # a hardlink is the same outside-inode write-through risk as a symlink.
  if [[ -e "$project_claude.new" || -L "$project_claude.new" ]]; then
    echo "  [pack-vendor-fail] $project_claude.new already exists; refusing (write-through risk)" >&2
    return 1
  fi

  touch "$project_claude" || return 1
  apply_org_overlay_section "$pack_dir/$fragment_rel" "$project_claude" || return 1
  echo "    [pack-overlay] $project_claude"
}

# vendor_tenant_standards <pack_dir> <repo_root>
# Copies every file named in the pack's `standards` map (name -> pack-relative
# path) into the repo, preserving the pack-relative path under repo root, so
# `standards/foo.md` in the pack lands at <repo_root>/standards/foo.md as a
# committed file (ADR-034 §4).
#
# Fail-closed, all-or-nothing:
#   - `standards` absent/null  -> no-op success (single-tenant / no-standards).
#   - `standards` present but not an object of string values -> hard fail.
#   - one map entry == one vendored file: values are read newline-delimited and
#     the decoded count is cross-checked against `.standards | length`, so an
#     embedded newline (which jq -r would split into extra records) fails closed.
#     Control chars are also rejected by _ppv_clean_rel. Residual (accepted): a
#     NUL byte inside a JSON string value can't survive intact into a bash var,
#     so it is neither reliably rejected nor counted — JSON-with-NUL is exotic
#     and packs come from the trusted install step.
#   - every source + destination is realpath-containment + symlink checked, and
#     destinations are deduped by CANONICAL path (resolves symlinked repo dirs +
#     ASCII case), BEFORE any write.
#   - the copy loop tracks created vs overwritten dests and ROLLS BACK (rm the
#     created, restore the overwritten from backup) on any mid-loop failure, so
#     a partial vendor never survives and a pre-existing file is never lost.
vendor_tenant_standards() {
  local pack_dir="$1" repo_root="$2"

  local st_kind
  st_kind="$(jq -r 'if (has("standards") | not) or .standards == null then "absent" else (.standards | type) end' \
    "$pack_dir/tenant.json" 2>/dev/null)" || {
      echo "  [pack-vendor-fail] tenant.json unreadable" >&2; return 1; }
  [[ "$st_kind" == "absent" ]] && return 0
  if [[ "$st_kind" != "object" ]]; then
    echo "  [pack-vendor-fail] standards must be an object (name -> path); got: $st_kind" >&2
    return 1
  fi
  # Values must all be strings (schema: additionalProperties string).
  if ! jq -e '.standards | to_entries | all(.value | type == "string")' \
      "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-vendor-fail] standards map has non-string path value(s)" >&2
    return 1
  fi

  # Collect ALL values newline-delimited; the count cross-check below catches an
  # embedded newline (which jq -r splits into extra records). Empty strings are
  # collected too, to be rejected in phase 1.
  local expected
  expected="$(jq -r '.standards | length' "$pack_dir/tenant.json" 2>/dev/null)" || return 1
  local -a rels=()
  local rel
  while IFS= read -r rel; do
    rels+=("$rel")
  done < <(jq -r '.standards | to_entries[] | .value' "$pack_dir/tenant.json" 2>/dev/null)
  # Count cross-check: any mismatch (NUL in a value truncating, framing anomaly)
  # means the vendored set would not correspond to the declared map — fail closed.
  if [[ "${#rels[@]}" != "$expected" ]]; then
    echo "  [pack-vendor-fail] standards did not decode 1:1 (${#rels[@]} vs $expected) — control/NUL char in a value?" >&2
    return 1
  fi
  [[ ${#rels[@]} -gt 0 ]] || return 0

  # Phase 1: validate ALL sources AND destinations before copying ANY.
  # (bash 3.2 target — no associative arrays; dedup via linear scan of seen[].)
  local dest canon key
  local -a seen=()
  local s
  for rel in "${rels[@]}"; do
    if [[ -z "$rel" ]]; then
      echo "  [pack-vendor-fail] standards map has an empty path value" >&2
      return 1
    fi
    if ! _ppv_clean_rel "$rel"; then
      echo "  [pack-vendor-fail] standards path is not a clean relative path: $rel" >&2
      return 1
    fi
    if [[ ! -f "$pack_dir/$rel" ]] || ! _ppv_source_within "$pack_dir/$rel" "$pack_dir"; then
      echo "  [pack-vendor-fail] standards source missing, a symlink, or escapes the pack: $rel" >&2
      return 1
    fi
    if ! _ppv_dest_safe "$repo_root/$rel" "$repo_root"; then
      echo "  [pack-vendor-fail] standards destination escapes the repo: $rel" >&2
      return 1
    fi
    # Reject a duplicate destination — otherwise created-vs-overwrite rollback
    # bookkeeping collides. Dedup on the CANONICAL dest (resolves a symlinked
    # repo dir like alias->dir), case-folded (APFS/HFS+ are case-insensitive),
    # so equivalent-but-not-identical spellings are caught, not just exact dups.
    canon="$(_ppv_canon_dest "$repo_root/$rel")" || {
      echo "  [pack-vendor-fail] could not canonicalize destination: $rel" >&2; return 1; }
    key="$(printf '%s' "$canon" | tr '[:upper:]' '[:lower:]')"
    for s in ${seen[@]+"${seen[@]}"}; do
      if [[ "$s" == "$key" ]]; then
        echo "  [pack-vendor-fail] duplicate standards destination (same on-disk file): $rel" >&2
        return 1
      fi
    done
    seen+=("$key")
    # A pre-existing destination must be a plain regular file (symlink already
    # rejected by _ppv_dest_safe). A dir/FIFO/special file is rejected here, not
    # discovered mid-copy after other writes landed.
    if [[ -e "$repo_root/$rel" && ! -f "$repo_root/$rel" ]]; then
      echo "  [pack-vendor-fail] destination exists and is not a regular file: $rel" >&2
      return 1
    fi
    # Reject a non-directory existing intermediate component (e.g. a plain file
    # named "standards" when the dest is standards/x.md) here in phase 1, rather
    # than discovering it at mkdir time in phase 2.
    local pchk
    pchk="$(dirname "$repo_root/$rel")"
    while [[ ! -e "$pchk" && ! -L "$pchk" && "$pchk" != "/" && "$pchk" != "." ]]; do pchk="$(dirname "$pchk")"; done
    if [[ ! -d "$pchk" || -L "$pchk" ]]; then
      echo "  [pack-vendor-fail] destination path crosses a non-directory or dangling symlink: $rel" >&2
      return 1
    fi
  done

  # Phase 2: copy, all-or-nothing. Parallel arrays (no delimiter parsing) track
  # files we CREATE (roll back = rm) vs files we OVERWRITE (backed up first;
  # roll back = restore the original — never delete a pre-existing repo file).
  # Break hardlinks with a CHECKED rm-before-cp; the restore pair is recorded
  # only AFTER a confirmed rm, so a failed rm can't have rollback write the
  # backup back through a still-linked outside inode.
  local bdir
  bdir="$(mktemp -d)" || return 1
  local -a created=() bk_dst=() bk_src=()
  local ok=1 i=0
  for rel in "${rels[@]}"; do
    dest="$repo_root/$rel"
    if [[ -e "$dest" ]]; then          # pre-existing regular file (phase-1 verified)
      if ! cp -- "$dest" "$bdir/$i.bak"; then ok=0; break; fi
      if ! rm -f -- "$dest"; then ok=0; break; fi   # checked: unbreak hardlink
      bk_dst+=("$dest"); bk_src+=("$bdir/$i.bak")   # record only after rm succeeds
    else
      created+=("$dest")
    fi
    if ! mkdir -p "$(dirname "$dest")" || ! cp -- "$pack_dir/$rel" "$dest"; then
      ok=0
      break
    fi
    echo "    [pack-vendor] $dest"
    i=$((i + 1))
  done

  if [[ "$ok" -ne 1 ]]; then
    echo "  [pack-vendor-fail] copy failed mid-vendor; rolling back" >&2
    local w j
    for w in ${created[@]+"${created[@]}"}; do rm -f -- "$w"; done
    j=0
    while [[ $j -lt ${#bk_dst[@]} ]]; do
      cp -- "${bk_src[$j]}" "${bk_dst[$j]}" 2>/dev/null || true
      j=$((j + 1))
    done
    rm -rf "$bdir"
    return 1
  fi
  rm -rf "$bdir"
}

# vendor_tenant_ci_templates <pack_dir> <repo_root>
# Copies every {source, dest} pair in the pack's `ci_templates` map (name ->
# {source, dest}) into the repo at the pack-DECLARED destination — e.g. a pack
# file at `templates/run_tests.yml` lands at `.github/workflows/run_tests.yml`
# (issue #123). Unlike `standards` (pack-relative path doubles as the repo
# destination), a CI template's pack location and its delivered location are
# rarely the same relative path, so the map carries an explicit `dest`.
#
# Same fail-closed, all-or-nothing discipline as vendor_tenant_standards
# (validate every source+destination before any write; roll back on any
# mid-loop failure), reusing its exact safety primitives
# (_ppv_clean_rel / _ppv_source_within / _ppv_dest_safe / _ppv_canon_dest):
#   - `ci_templates` absent/null -> no-op success (packs that don't declare
#     one are unaffected).
#   - `ci_templates` present but not an object of {source, dest} string pairs
#     -> hard fail (matches validate_pack's own shape check).
#   - values decoded newline-delimited with the same count cross-check
#     vendor_tenant_standards uses, so an embedded newline fails closed.
#   - HUMAN REVIEW GATE (security-report.md 2026-08-04, HIGH): dest is
#     allowlisted to .github/workflows/, but the delivered YAML content
#     itself is unreviewed, attacker-authored GitHub Actions. After Phase 1
#     validation passes, this function refuses to write unless called with
#     the literal third argument "reviewed" — without it, every template's
#     full content is printed to stderr and it returns 1. The only real
#     caller (skills/project-init/SKILL.md) calls it once to get that
#     printed content, shows it to the user, and only re-invokes with
#     "reviewed" after explicit approval.
vendor_tenant_ci_templates() {
  local pack_dir="$1" repo_root="$2" reviewed="${3:-}"

  local ct_kind
  ct_kind="$(jq -r 'if (has("ci_templates") | not) or .ci_templates == null then "absent" else (.ci_templates | type) end' \
    "$pack_dir/tenant.json" 2>/dev/null)" || {
      echo "  [pack-vendor-fail] tenant.json unreadable" >&2; return 1; }
  [[ "$ct_kind" == "absent" ]] && return 0
  if [[ "$ct_kind" != "object" ]]; then
    echo "  [pack-vendor-fail] ci_templates must be an object (name -> {source, dest}); got: $ct_kind" >&2
    return 1
  fi
  if ! jq -e '.ci_templates | to_entries | all(
      (.value | type == "object") and
      (.value.source | type == "string") and
      (.value.dest   | type == "string")
    )' "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-vendor-fail] ci_templates entries must be {source, dest} string pairs" >&2
    return 1
  fi

  local expected
  expected="$(jq -r '.ci_templates | length' "$pack_dir/tenant.json" 2>/dev/null)" || return 1
  local -a srcs=() dests=()
  local ln
  while IFS= read -r ln; do srcs+=("$ln"); done \
    < <(jq -r '.ci_templates | to_entries[] | .value.source' "$pack_dir/tenant.json" 2>/dev/null)
  while IFS= read -r ln; do dests+=("$ln"); done \
    < <(jq -r '.ci_templates | to_entries[] | .value.dest' "$pack_dir/tenant.json" 2>/dev/null)
  if [[ "${#srcs[@]}" != "$expected" || "${#dests[@]}" != "$expected" ]]; then
    echo "  [pack-vendor-fail] ci_templates did not decode 1:1 (control/NUL char in a value?)" >&2
    return 1
  fi
  [[ ${#srcs[@]} -gt 0 ]] || return 0

  # Phase 1: validate ALL sources AND destinations before copying ANY.
  local i src dv dest canon key s
  local -a seen=()
  for ((i = 0; i < ${#srcs[@]}; i++)); do
    src="${srcs[$i]}"; dv="${dests[$i]}"
    if [[ -z "$src" || -z "$dv" ]]; then
      echo "  [pack-vendor-fail] ci_templates has an empty source or dest value" >&2
      return 1
    fi
    if ! _ppv_clean_rel "$src" || ! _ppv_clean_rel "$dv"; then
      echo "  [pack-vendor-fail] ci_templates source/dest is not a clean relative path: $src -> $dv" >&2
      return 1
    fi
    if ! ci_template_dest_allowed "$dv"; then
      echo "  [pack-vendor-fail] ci_templates dest is not a GitHub Actions workflow path (.github/workflows/<name>.yml): $dv" >&2
      return 1
    fi
    if [[ ! -f "$pack_dir/$src" ]] || ! _ppv_source_within "$pack_dir/$src" "$pack_dir"; then
      echo "  [pack-vendor-fail] ci_templates source missing, a symlink, or escapes the pack: $src" >&2
      return 1
    fi
    if ! _ppv_dest_safe "$repo_root/$dv" "$repo_root"; then
      echo "  [pack-vendor-fail] ci_templates destination escapes the repo: $dv" >&2
      return 1
    fi
    canon="$(_ppv_canon_dest "$repo_root/$dv")" || {
      echo "  [pack-vendor-fail] could not canonicalize destination: $dv" >&2; return 1; }
    key="$(printf '%s' "$canon" | tr '[:upper:]' '[:lower:]')"
    for s in ${seen[@]+"${seen[@]}"}; do
      if [[ "$s" == "$key" ]]; then
        echo "  [pack-vendor-fail] duplicate ci_templates destination (same on-disk file): $dv" >&2
        return 1
      fi
    done
    seen+=("$key")
    if [[ -e "$repo_root/$dv" && ! -f "$repo_root/$dv" ]]; then
      echo "  [pack-vendor-fail] destination exists and is not a regular file: $dv" >&2
      return 1
    fi
    local pchk
    pchk="$(dirname "$repo_root/$dv")"
    while [[ ! -e "$pchk" && ! -L "$pchk" && "$pchk" != "/" && "$pchk" != "." ]]; do pchk="$(dirname "$pchk")"; done
    if [[ ! -d "$pchk" || -L "$pchk" ]]; then
      echo "  [pack-vendor-fail] destination path crosses a non-directory or dangling symlink: $dv" >&2
      return 1
    fi
  done

  if [[ "$reviewed" != "reviewed" ]]; then
    echo "  [pack-vendor-review-required] ci_templates ships ${#srcs[@]} CI template file(s) — review the content below before vendoring:" >&2
    for ((i = 0; i < ${#srcs[@]}; i++)); do
      echo "  --- ${dests[$i]} (from pack: ${srcs[$i]}) ---" >&2
      cat -- "$pack_dir/${srcs[$i]}" >&2
      echo "" >&2
    done
    echo "  [pack-vendor-review-required] re-run with a third argument \"reviewed\" after a human has approved this content." >&2
    return 1
  fi

  # Phase 2: copy, all-or-nothing (same rollback discipline as
  # vendor_tenant_standards — created vs. overwritten dests tracked
  # separately so a pre-existing repo file is restored, never deleted).
  local bdir
  bdir="$(mktemp -d)" || return 1
  local -a created=() bk_dst=() bk_src=()
  local ok=1
  for ((i = 0; i < ${#srcs[@]}; i++)); do
    src="${srcs[$i]}"; dv="${dests[$i]}"
    dest="$repo_root/$dv"
    if [[ -e "$dest" ]]; then
      if ! cp -- "$dest" "$bdir/$i.bak"; then ok=0; break; fi
      if ! rm -f -- "$dest"; then ok=0; break; fi
      bk_dst+=("$dest"); bk_src+=("$bdir/$i.bak")
    else
      created+=("$dest")
    fi
    if ! mkdir -p "$(dirname "$dest")" || ! cp -- "$pack_dir/$src" "$dest"; then
      ok=0
      break
    fi
    echo "    [pack-vendor] $dest"
  done

  if [[ "$ok" -ne 1 ]]; then
    echo "  [pack-vendor-fail] copy failed mid-vendor; rolling back" >&2
    local w j
    for w in ${created[@]+"${created[@]}"}; do rm -f -- "$w"; done
    j=0
    while [[ $j -lt ${#bk_dst[@]} ]]; do
      cp -- "${bk_src[$j]}" "${bk_dst[$j]}" 2>/dev/null || true
      j=$((j + 1))
    done
    rm -rf "$bdir"
    return 1
  fi
  rm -rf "$bdir"
}
