#!/usr/bin/env bash
# Deltas-only lint (M3, ADR-013 amendment): a tenant pack may only ship
# content that DIFFERS from core. Verbatim copies of core files are rejected
# by hash — rename-proof (a core file shipped at any pack path is caught).
# JSON is hashed in jq -S canonical form, so a key-reordered copy is still a
# verbatim copy. Non-goal (v1): a pack JSON that is a strict SUBSET of a core
# file is a no-op delta but passes — only byte/canonical identity is rejected.
# Revisit if it bites.

_pack_lint_hash() {
  local file="$1"
  if [[ "$file" == *.json ]] && jq -e . "$file" >/dev/null 2>&1; then
    jq -S . "$file" | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

lint_pack_deltas() {
  local pack_dir="$1"
  local core_repo_root="$2"

  # Core corpus: distributable content only — docs/tests/CI don't ship.
  # git ls-files when core is a repo; plain find for non-git fixtures.
  local core_list
  if git -C "$core_repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    core_list="$(git -C "$core_repo_root" ls-files)"
  else
    core_list="$(cd "$core_repo_root" && find . -type f | sed 's|^\./||')"
  fi

  local corpus
  corpus="$(mktemp)"
  local core_file
  while IFS= read -r core_file; do
    [[ -z "$core_file" ]] && continue
    case "$core_file" in
      docs/*|tests/*|.github/*) continue ;;
    esac
    [[ -f "$core_repo_root/$core_file" ]] || continue
    echo "$(_pack_lint_hash "$core_repo_root/$core_file") $core_file"
  done <<< "$core_list" > "$corpus"

  local violations=0
  local pack_file rel hash core_match
  while IFS= read -r pack_file; do
    rel="${pack_file#"$pack_dir"/}"
    case "$rel" in
      tenant.json|README.md|.pack-install.json|.git/*) continue ;;
    esac
    hash="$(_pack_lint_hash "$pack_file")"
    core_match="$(awk -v h="$hash" '$1 == h {print $2; exit}' "$corpus")"
    if [[ -n "$core_match" ]]; then
      echo "  [lint-fail] $rel is a verbatim copy of core $core_match" >&2
      violations=$((violations + 1))
    fi
  done < <(find "$pack_dir" -type f -not -path "$pack_dir/.git/*")

  rm -f "$corpus"

  if [[ "$violations" -gt 0 ]]; then
    echo "  [lint-fail] $violations verbatim core file(s) in pack — packs ship deltas only" >&2
    return 1
  fi
  return 0
}
