#!/usr/bin/env bash
# stack-receipt/v1 envelope: reader/writer/sanitizer + hashing helpers.
# ADR-087 D1, D3e. Sourceable only — no side effects on source, matching the
# usage-check-common.sh convention (lib/*.sh: sourced by both hooks and
# scripts, never executed for its own behavior).
#
# One envelope, two subject kinds ("artifact" for G1, "patch" for G2), closed
# set. Exactly one subject kind's fields may be present in a receipt — a
# receipt carrying both content_sha and patch_sha is invalid, not "flexible".
#
# Every free-text field is sanitized AT WRITE TIME via rcpt_sanitize (ADR-086
# D19's sanitizer, reused unchanged) — no reader is trusted.
#
# API:
#   rcpt_write        <path> <json>
#   rcpt_read         <path>                     # rc 1 if absent/invalid
#   rcpt_state        <path>                     # CLEAN | OBSERVED | SKIPPED | NOT-CHECKED
#   rcpt_sanitize     <string> <maxlen>
#   rcpt_artifact_sha <repo_root> <path>          # D3e
#   rcpt_patch_sha    <repo_root> <base> <head>   # D3e
#
# rcpt_state's four values are ADR-085 D4's vocabulary, reused unchanged. A
# stale or invalid receipt is NOT-CHECKED, never CLEAN (D11).

set -uo pipefail

RCPT_SCHEMA="stack-receipt/v1"

# ── Trusted config-dir resolution ───────────────────────────────────────────
# rcpt_safe_conf_dir -> echoes a config dir that the managed floor's globs
# actually cover.
#
# WHY THIS EXISTS (red-team finding, 2026-08-20): every gate/minter path used
# to read $CLAUDE_CONFIG_DIR verbatim. An agent that sets it to a directory
# outside ~/.claude* -- /tmp/fake, say -- lands its override and receipt
# lookups somewhere denyWrite does not reach, and can then write its own
# "gate disabled" file. The floor protects exactly three globs
# (~/.claude/state/attest/**, **/.claude/state/attest/**,
# ~/.claude-*/state/attest/**), so this refuses to look anywhere those globs
# do not cover, and falls back to $HOME/.claude.
#
# Accepted: $HOME/.claude, or $HOME/.claude-<profile> (ADR-067 profiles).
# Refused: any other path, a symlinked config dir, one not owned by the
# invoking uid, or one that is group-/other-writable.
#
# Residual, stated plainly: a forged $HOME moves the accepted set with it.
# HOME is set by the harness that spawns the hook, not by the tool call, and
# the floor's own globs are HOME-relative too -- so this closes the gap the
# floor closes and no more. It is friction plus namespace discipline, not
# authentication.
rcpt_safe_conf_dir() {
  local fallback="${HOME:-}/.claude"
  local cand="${CLAUDE_CONFIG_DIR:-$fallback}"
  [[ -n "${HOME:-}" ]] || { printf '%s' "$cand"; return 0; }
  cand="${cand%/}"

  # CANONICALIZE BEFORE COMPARING. A prefix test on the raw string is not a
  # namespace check: "$HOME/.claude-evil/../../tmp/fake" passes any
  # startswith test and resolves straight out of the protected namespace
  # (red-team verification pass, new finding 1). Resolve first, compare
  # after; a `..` that survives resolution is refused outright.
  local resolved
  resolved="$(cd "$cand" 2>/dev/null && pwd -P 2>/dev/null)" || resolved=""
  if [[ -n "$resolved" ]]; then
    cand="$resolved"
  else
    case "/$cand/" in */../*) printf '%s' "$fallback"; return 0 ;; esac
  fi
  local home_real
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P 2>/dev/null)" || home_real="$HOME"

  if [[ "$cand" != "$home_real/.claude" && "$cand" != "$home_real/.claude-"* \
     && "$cand" != "$HOME/.claude" && "$cand" != "$HOME/.claude-"* ]]; then
    printf '%s' "$fallback"; return 0
  fi
  if [[ -L "$cand" ]]; then
    printf '%s' "$fallback"; return 0
  fi
  if [[ -d "$cand" ]]; then
    [[ -O "$cand" ]] || { printf '%s' "$fallback"; return 0; }
    local perms
    perms="$(stat -c '%a' "$cand" 2>/dev/null || stat -f '%Lp' "$cand" 2>/dev/null)"
    if [[ -n "$perms" ]]; then
      local last2="${perms: -2}"
      (( (8#${last2:0:1}) & 2 )) && { printf '%s' "$fallback"; return 0; }
      (( (8#${last2:1:1}) & 2 )) && { printf '%s' "$fallback"; return 0; }
    fi
  fi
  printf '%s' "$cand"
}

# ── Trusted PATH ────────────────────────────────────────────────────────────
# rcpt_pin_path -> prepends the standard system tool directories to $PATH.
#
# WHY (red-team finding, 2026-08-20): a hook inherits the agent's $PATH. An
# agent that drops an executable named `jq` or `git` earlier on that PATH
# feeds the gate empty JSON fields and fabricated commit ids -- every
# decision downstream reads as "nothing to gate here". Prepending the real
# locations means the genuine binaries win the lookup.
rcpt_pin_path() {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
  export PATH
}

# ── D19(a) sanitizer, reused verbatim from hooks/stack-self-update.sh ───────
# rcpt_sanitize <raw> <maxlen> -> first line only, printable ASCII, trimmed,
# collapsed whitespace, truncated to maxlen. Never empty on non-empty input
# (falls back to "no error text").
rcpt_sanitize() {
  local raw="${1:-}" maxlen="${2:-200}"
  local firstline="${raw%%$'\n'*}"
  firstline="${firstline%%$'\r'*}"
  local cleaned
  cleaned="$(printf '%s' "$firstline" | LC_ALL=C tr -cd '\40-\176')"
  cleaned="$(printf '%s' "$cleaned" | LC_ALL=C sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//')"
  cleaned="${cleaned:0:$maxlen}"
  [[ -z "$cleaned" ]] && cleaned="no error text"
  printf '%s' "$cleaned"
}

# rcpt_write <path> <json> -> atomic write (mktemp same dir, then mv). The
# caller is responsible for having already sanitized every free-text field
# via rcpt_sanitize before calling this — this function does not re-parse or
# re-sanitize the payload, only writes it atomically.
rcpt_write() {
  local path="$1" json="$2"
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || return 1
  # A symlinked destination must be replaced, not followed (test 7): mv onto
  # a symlink target replaces the link itself when the temp file and target
  # are on the same filesystem (same dir), which mktemp-in-same-dir + mv
  # guarantees.
  local tmp
  tmp="$(mktemp "$dir/.receipt.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null
}

# rcpt_read <path> -> prints the JSON on stdout if valid per the schema rules
# below; rc 1 if absent, unparseable, or structurally invalid (wrong schema,
# unknown kind, or both subject kinds present). A schema-invalid receipt is
# treated as ABSENT, never as a pass (D1).
rcpt_read() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local json
  json="$(cat "$path" 2>/dev/null)"
  [[ -n "$json" ]] || return 1
  echo "$json" | jq -e . >/dev/null 2>&1 || return 1
  echo "$json" | jq -e '.schema == "stack-receipt/v1"' >/dev/null 2>&1 || return 1
  echo "$json" | jq -e '.kind == "review" or .kind == "rollout"' >/dev/null 2>&1 || return 1

  # Required-field enforcement (cross-family review finding: the reader
  # checked schema and kind, then accepted an envelope missing everything a
  # consumer goes on to read). A malformed receipt is refused here, once,
  # rather than surfacing as an empty string somewhere downstream.
  echo "$json" | jq -e '
    (.writer | type) == "string" and (.writer | length) > 0
    and (.as_of | type) == "string" and (.as_of | length) > 0
    and has("verdict") and has("evidence")
  ' >/dev/null 2>&1 || return 1

  if echo "$json" | jq -e '.kind == "review"' >/dev/null 2>&1; then
    # A review receipt must name a subject kind from the closed set, and
    # carry exactly the hash field that kind implies — no more, no less.
    echo "$json" | jq -e '
      (.subject | type) == "object"
      and ((.subject.kind == "artifact" and (.subject.content_sha | type) == "string"
            and (.subject.content_sha | length) > 0 and .subject.patch_sha == null
            and (.subject.path | type) == "string" and (.subject.path | length) > 0)
        or (.subject.kind == "patch" and (.subject.patch_sha | type) == "string"
            and (.subject.patch_sha | length) > 0 and .subject.content_sha == null
            and (.subject.base_commit | type) == "string"
            and (.subject.reviewed_head | type) == "string"))
    ' >/dev/null 2>&1 || return 1
  fi
  printf '%s' "$json"
  return 0
}

# rcpt_state <path> [max_age_s] -> CLEAN | NOT-CHECKED. This is the generic
# freshness check every consumer starts from; callers needing OBSERVED/SKIPPED
# semantics (review-gate's pass/deny rows) layer that on top after rcpt_read.
rcpt_state() {
  local path="$1" max_age="${2:-604800}"
  local json
  json="$(rcpt_read "$path")" || { echo "NOT-CHECKED"; return; }
  local as_of epoch now
  as_of="$(echo "$json" | jq -r '.as_of // empty' 2>/dev/null)"
  [[ -z "$as_of" ]] && { echo "NOT-CHECKED"; return; }
  epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$as_of" +%s 2>/dev/null)"
  [[ -z "$epoch" ]] && epoch="$(date -u -d "$as_of" +%s 2>/dev/null)"
  [[ -z "$epoch" ]] && { echo "NOT-CHECKED"; return; }
  now="$(date -u +%s)"
  if (( now - epoch > max_age )); then
    echo "NOT-CHECKED"
    return
  fi
  echo "CLEAN"
}

# rcpt_artifact_sha <repo_root> <path> -> echoes the git blob sha of the
# worktree bytes at <path> (relative to repo_root), computed with
# `hash-object -w --no-filters` (D3e). Refuses symlinks and directories
# (rc 2, no output) — a subject must be a regular file.
rcpt_artifact_sha() {
  local repo_root="$1" rel="$2"
  local abs="$repo_root/$rel"
  if [[ -L "$abs" ]]; then return 2; fi
  if [[ -d "$abs" ]]; then return 2; fi
  [[ -f "$abs" ]] || return 3
  git -C "$repo_root" hash-object -w --no-filters -- "$rel" 2>/dev/null
}

# rcpt_patch_sha <repo_root> <base> <head> -> echoes the sha of the frozen-flag
# diff between base and head (D3e). Both refs are resolved by the caller to
# full 40-hex before calling this — this function does not re-resolve them,
# so the minter and the gate run the identical command against identical
# inputs and cannot drift.
rcpt_patch_sha() {
  local repo_root="$1" base="$2" head="$3"
  git -c core.abbrev=40 -C "$repo_root" diff --no-color --no-ext-diff --binary \
      --find-renames=50% "${base}..${head}" 2>/dev/null \
    | git -C "$repo_root" hash-object -w --stdin --no-filters 2>/dev/null
}
