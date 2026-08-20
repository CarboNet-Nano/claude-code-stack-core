#!/usr/bin/env bash
# lib/portable-core.sh — the ONE implementation behind ADR-075 (D8, D14).
#
# The problem: `config/portable-core-skills.json` names four skills that get
# COPIED into other repos' `.claude/skills/`, and both copiers only ever write
# when the file is absent. Nothing refreshes them. So every repo initialised
# before any stack change holds a silently stale fork, forever.
#
# The fix: provenance lives in a generated content-hash manifest, never as a
# stamp inside a file. Hash a copy; if its bytes are one the stack itself
# published in the past, the copy is a stale stack version and overwriting it
# loses nothing recoverable. If its bytes are anything else, a human wrote them
# and we never touch it.
#
# Callers: hooks/portable-core-refresh.sh (boot), scripts/stack-sync.sh
# (--skills), skills/project-init, templates/team-admin/scripts/reconcile.sh,
# and scripts/session-close.sh (pc_attribute only).
#
# Every function is safe to call in a non-git directory and returns rather than
# exiting — this is sourced by a boot hook that must never break a session.

# shellcheck shell=bash

_PC_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_PC_LIBDIR/profile-resolver.sh" ]] && source "$_PC_LIBDIR/profile-resolver.sh"
_PC_HOME="${CLAUDE_PLUGIN_ROOT:-$(command -v pr_resolve_dir_or_default >/dev/null && pr_resolve_dir_or_default 2>/dev/null || echo "$HOME/.claude")}"

# Cooperative budget: checked BETWEEN files via $SECONDS, never enforced
# against a single hung command. `timeout(1)` is GNU coreutils and is absent
# from a stock macOS PATH, so a hard-enforcement claim would be wider than the
# code (ADR-075 D11).
_PC_BUDGET_SECS="${PORTABLE_SYNC_BUDGET_SECS:-2}"

_pc_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | awk '{print $1}'
  else return 1; fi
}

_pc_hash_file() {
  local f="${1:-}" h
  [[ -f "$f" ]] || { echo ""; return 0; }
  h="$(_pc_sha256 < "$f" 2>/dev/null)" || { echo ""; return 0; }
  [[ -n "$h" ]] && printf 'sha256:%s' "$h" || echo ""
  return 0
}

pc_manifest_path() {
  local p
  for p in "$_PC_HOME/config/portable-core-manifest.json" \
           "$_PC_HOME/portable-core-manifest.json"; do
    [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  # Source-repo fallback, so the stack repo itself and the tests work.
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
  [[ -n "$here" && -f "$here/config/portable-core-manifest.json" ]] && \
    { printf '%s' "$here/config/portable-core-manifest.json"; return 0; }
  echo ""
  return 0
}

_pc_installed_source() {  # where a refreshed file's bytes come from
  printf '%s/skills' "$_PC_HOME"
}

# --- gates -------------------------------------------------------------------
#
# Every gate fails toward NOT writing. A refusal is reported as a class, never
# as an error: `diverged` and `blocked` are normal outcomes, not failures.

_pc_repo_state() {  # per-worktree; NEVER --git-common-dir (D3b, matches
                    # session-close.sh's shipped precedent)
  local root="${1:-}" g
  g="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"
  [[ -z "$g" ]] && { printf 'clean'; return 0; }
  [[ -d "$g/rebase-merge" || -d "$g/rebase-apply" ]] && { printf 'rebase'; return 0; }
  [[ -f "$g/MERGE_HEAD" ]] && { printf 'merge'; return 0; }
  [[ -f "$g/CHERRY_PICK_HEAD" ]] && { printf 'cherry-pick'; return 0; }
  [[ -f "$g/REVERT_HEAD" ]] && { printf 'revert'; return 0; }
  printf 'clean'
  return 0
}

_pc_ci_env() {  # 0 = looks like CI
  local v
  for v in CI GITHUB_ACTIONS BUILDKITE JENKINS_URL GITLAB_CI; do
    [[ -n "${!v:-}" ]] && return 0
  done
  # Extensible: a harness we have never seen is one config line away from
  # being recognised, rather than requiring a stack release (D3b).
  local defaults="$_PC_HOME/stack-defaults.json" extra
  if [[ -f "$defaults" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r extra; do
      [[ -n "$extra" && -n "${!extra:-}" ]] && return 0
    done < <(jq -r '.portable_sync_ci_env[]? // empty' "$defaults" 2>/dev/null)
  fi
  return 1
}

_pc_config_mode() {  # D7: auto | report | off
  local root="${1:-}" cfg="${1:-}/.claude/stack-config.json" m=""
  [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1 && \
    m="$(jq -r '.portable_sync.mode // ""' "$cfg" 2>/dev/null)"
  [[ -z "$m" || "$m" == "null" ]] && m="auto"
  printf '%s' "$m"
  return 0
}

_pc_is_pinned() {  # D7: an explicitly pinned path is never rewritten
  local root="${1:-}" rel="${2:-}" cfg="${1:-}/.claude/stack-config.json"
  [[ -f "$cfg" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg p "$rel" '(.portable_sync.pin // []) | index($p) != null' "$cfg" >/dev/null 2>&1
}

# --- classify ----------------------------------------------------------------

# pc_classify <repo_root>
#   TSV: <rel_path>\t<class>\t<reason>\t<hash>
pc_classify() {
  local root="${1:-}"
  [[ -n "$root" && -d "$root" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local manifest; manifest="$(pc_manifest_path)"
  [[ -n "$manifest" && -f "$manifest" ]] || return 0

  # Repo-wide gates: computed once, applied to every managed path.
  local blocked_reason=""
  if ! git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    blocked_reason="not-a-git-repo"
  elif [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
    # Explicit refusal, not an accident of an empty ~/.claude (D3b).
    blocked_reason="remote"
  elif _pc_ci_env; then
    blocked_reason="ci"
  elif [[ -z "$(git -C "$root" branch --show-current 2>/dev/null)" ]]; then
    # A modified tracked file makes the NEXT checkout refuse, which breaks a
    # bisect mid-run. Content is not at risk; an active workflow is.
    blocked_reason="detached-head"
  else
    local st; st="$(_pc_repo_state "$root")"
    [[ "$st" != "clean" ]] && blocked_reason="repo-state-$st"
  fi
  if [[ -z "$blocked_reason" ]]; then
    local mode; mode="$(_pc_config_mode "$root")"
    [[ "$mode" == "off" ]] && return 0
    [[ "$mode" == "report" ]] && blocked_reason="mode-report"
  fi

  local skills_root="$root/.claude/skills"
  local src_root; src_root="$(_pc_installed_source)"
  local started=$SECONDS

  local rel
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    (( SECONDS - started > _PC_BUDGET_SECS )) && break

    # Manifest paths are `skills/<name>/...`; in a consumer repo they live at
    # `.claude/skills/<name>/...`.
    local sub="${rel#skills/}"
    local dest="$skills_root/$sub"
    local skill_dir="$skills_root/${sub%%/*}"

    # D4: never seed a skill directory the repo does not already have. A
    # maintainer who deleted a stale copy must not find it back at next boot.
    if [[ ! -d "$skill_dir" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$rel" "unmanaged" "" ""
      continue
    fi

    local current; current="$(jq -r --arg p "$rel" '.files[$p].current // ""' "$manifest" 2>/dev/null)"
    [[ -z "$current" ]] && continue

    if [[ ! -f "$dest" ]]; then
      if [[ -n "$blocked_reason" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$rel" "blocked" "$blocked_reason" ""
      else
        printf '%s\t%s\t%s\t%s\n' "$rel" "absent" "" ""
      fi
      continue
    fi

    local h; h="$(_pc_hash_file "$dest")"
    if [[ "$h" == "$current" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$rel" "current" "" "$h"
      continue
    fi

    if ! jq -e --arg p "$rel" --arg h "$h" '(.files[$p].known // []) | index($h) != null' \
         "$manifest" >/dev/null 2>&1; then
      # Bytes the stack never published. A human wrote them. Never touch (D5).
      printf '%s\t%s\t%s\t%s\n' "$rel" "diverged" "" "$h"
      continue
    fi

    # Would be `stale`. Per-file gates.
    local reason="$blocked_reason"
    if [[ -z "$reason" ]] && _pc_is_pinned "$root" ".claude/skills/$sub"; then
      reason="pinned"
    fi
    if [[ -z "$reason" ]]; then
      # GIT_OPTIONAL_LOCKS=0: a status call must never take the index lock at
      # boot, or it races whatever the user is doing (D3 gate 4).
      local porcelain
      porcelain="$(GIT_OPTIONAL_LOCKS=0 git -C "$root" status --porcelain -- ".claude/skills/$sub" 2>/dev/null)"
      if [[ -n "$porcelain" ]]; then
        case "$porcelain" in
          '??'*) reason="untracked" ;;
          *)     reason="dirty" ;;
        esac
      elif ! git -C "$root" ls-files --error-unmatch ".claude/skills/$sub" >/dev/null 2>&1; then
        reason="untracked"
      fi
    fi
    if [[ -z "$reason" ]]; then
      # Gate 5: the destination must belong to THIS worktree, not a nested repo
      # or submodule, and must not have been reached through a symlink.
      local dest_top
      dest_top="$(git -C "$(dirname "$dest")" rev-parse --show-toplevel 2>/dev/null)"
      local root_real; root_real="$(cd "$root" 2>/dev/null && pwd -P)"
      local dest_real; dest_real="$(cd "$dest_top" 2>/dev/null && pwd -P)"
      [[ -n "$dest_real" && "$dest_real" == "$root_real" ]] || reason="other-worktree"
    fi
    if [[ -z "$reason" ]]; then
      [[ -f "$src_root/$sub" ]] || reason="source-missing"
    fi
    if [[ -z "$reason" ]]; then
      # The installed copy must itself be `current`. Refreshing from a stale
      # global install would just move the staleness.
      local src_hash; src_hash="$(_pc_hash_file "$src_root/$sub")"
      [[ "$src_hash" == "$current" ]] || reason="source-mismatch"
    fi

    if [[ -n "$reason" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$rel" "blocked" "$reason" "$h"
    else
      printf '%s\t%s\t%s\t%s\n' "$rel" "stale" "" "$h"
    fi
  done < <(jq -r '.files | keys[]' "$manifest" 2>/dev/null)

  return 0
}

# --- reconcile ---------------------------------------------------------------

# pc_reconcile <repo_root> <apply:0|1>  -> one JSON object on stdout
pc_reconcile() {
  local root="${1:-}" apply="${2:-0}"
  command -v jq >/dev/null 2>&1 || { echo '{}'; return 0; }

  local refreshed='[]' created='[]' diverged='[]' blocked='[]' current_n=0
  local rel class reason hash

  while IFS=$'\t' read -r rel class reason hash; do
    [[ -z "$rel" ]] && continue
    local sub="${rel#skills/}"
    local dest="$root/.claude/skills/$sub"
    local src; src="$(_pc_installed_source)/$sub"

    case "$class" in
      current) current_n=$((current_n + 1)) ;;
      diverged) diverged="$(jq -c --arg p ".claude/skills/$sub" '. + [$p]' <<<"$diverged")" ;;
      blocked)  blocked="$(jq -c --arg p ".claude/skills/$sub" --arg r "$reason" \
                    '. + [{path:$p, reason:$r}]' <<<"$blocked")" ;;
      stale)
        if [[ "$apply" == "1" && -f "$src" ]]; then
          # Never a .bak inside a user repo, never a delete: the old bytes are
          # in the manifest's `known` and in git, so this is byte-recoverable.
          local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/pcsync.XXXXXX" 2>/dev/null)" || continue
          if cat "$src" > "$tmp" 2>/dev/null && mv "$tmp" "$dest" 2>/dev/null; then
            refreshed="$(jq -c --arg p ".claude/skills/$sub" '. + [$p]' <<<"$refreshed")"
          else
            rm -f "$tmp" 2>/dev/null
          fi
        else
          refreshed="$(jq -c --arg p ".claude/skills/$sub" '. + [$p]' <<<"$refreshed")"
        fi
        ;;
      absent)
        if [[ "$apply" == "1" && -f "$src" ]]; then
          mkdir -p "$(dirname "$dest")" 2>/dev/null
          local tmp2; tmp2="$(mktemp "${TMPDIR:-/tmp}/pcsync.XXXXXX" 2>/dev/null)" || continue
          if cat "$src" > "$tmp2" 2>/dev/null && mv "$tmp2" "$dest" 2>/dev/null; then
            created="$(jq -c --arg p ".claude/skills/$sub" '. + [$p]' <<<"$created")"
          else
            rm -f "$tmp2" 2>/dev/null
          fi
        else
          created="$(jq -c --arg p ".claude/skills/$sub" '. + [$p]' <<<"$created")"
        fi
        ;;
    esac
  done < <(pc_classify "$root")

  jq -n --arg repo "$root" --argjson r "$refreshed" --argjson c "$created" \
        --argjson d "$diverged" --argjson b "$blocked" --argjson n "$current_n" \
        --arg applied "$apply" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    '{repo:$repo, as_of:$now, applied:($applied == "1"), current:$n,
      refreshed:$r, created:$c, diverged:$d, blocked:$b}'
  return 0
}

# --- attribution (D15) -------------------------------------------------------

# pc_attribute <repo_root> <rel_path>  -> "stack-self-heal" | ""
#
# DERIVED, never recorded. A written receipt would reintroduce the
# recorded-plus-time-window shape ADR-072 documented producing a confident
# wrong disclosure; a derivation has no window to be wrong about, works
# whichever entry point did the write, and survives receipt pruning.
#
# True iff: the working-tree bytes are exactly `current`, AND the committed
# bytes at HEAD are some OTHER version the stack published. That is precisely
# "this modification moves the file from an older stack version to the current
# one" — which nothing but the refresher does.
pc_attribute() {
  local root="${1:-}" rel="${2:-}"
  [[ -n "$root" && -n "$rel" ]] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }

  local manifest; manifest="$(pc_manifest_path)"
  [[ -n "$manifest" && -f "$manifest" ]] || { echo ""; return 0; }

  case "$rel" in
    .claude/skills/*) ;;
    *) echo ""; return 0 ;;
  esac
  local key="skills/${rel#.claude/skills/}"

  local current; current="$(jq -r --arg p "$key" '.files[$p].current // ""' "$manifest" 2>/dev/null)"
  [[ -n "$current" ]] || { echo ""; return 0; }

  local wt; wt="$(_pc_hash_file "$root/$rel")"
  [[ "$wt" == "$current" ]] || { echo ""; return 0; }

  local head_hash
  head_hash="$(git -C "$root" show "HEAD:$rel" 2>/dev/null | _pc_sha256 2>/dev/null)"
  [[ -n "$head_hash" ]] || { echo ""; return 0; }
  head_hash="sha256:$head_hash"
  [[ "$head_hash" == "$current" ]] && { echo ""; return 0; }

  if jq -e --arg p "$key" --arg h "$head_hash" \
       '(.files[$p].known // []) | index($h) != null' "$manifest" >/dev/null 2>&1; then
    printf 'stack-self-heal'
  else
    echo ""
  fi
  return 0
}

# --- receipt -----------------------------------------------------------------

pc_receipt_write() {
  local root="${1:-}" payload="${2:-}"
  [[ -n "$root" && -n "$payload" ]] || return 0
  local dir="$_PC_HOME/state/portable-sync"
  mkdir -p "$dir" 2>/dev/null || return 0
  local slug; slug="$(printf '%s' "$root" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s\n' "$payload" > "$dir/$slug.json" 2>/dev/null

  # Prune receipts older than 30 days. `find -mtime` is portable enough here
  # and this is best-effort: a failure to prune must never affect a boot.
  find "$dir" -name '*.json' -type f -mtime +30 -delete 2>/dev/null || true
  return 0
}
