#!/usr/bin/env bash
# Mirror-sync scrub guard (ADR-036 Job A). Sourced by scripts/mirror-sync.sh.
# No writes — pure read-only scan of an already-archived tree.
#
# Caller runs this with errexit suppressed (`if ! scrub_guard "$dir"`), so
# every fallible step is checked explicitly — never rely on set -e here
# (same style as scripts/lib/pack-installer.sh). Every fallible command
# below is the condition of an if/while, specifically so a nonzero exit
# inside this function body can never trip an inherited `set -e` before we
# get to inspect it.

# Deny-by-default mirrors .gitattributes (post cross-family review: an
# earlier allowlist-by-exclusion version of .gitattributes missed
# docs/ADRs/** and .claude/**, both real IP/secret leaks). Anything at the
# top level of the archived tree that isn't the known-safe installable-core
# set is a violation — this is a second, independent check of the same
# boundary .gitattributes enforces, so a misconfigured or bypassed
# .gitattributes still fails mirror-sync closed instead of silently
# shipping whatever git archive happened to include.
MIRROR_SCRUB_ALLOWED_DIRS=(agents config hooks lib schemas scripts skills templates tools tests)
MIRROR_SCRUB_ALLOWED_FILES=(README.md LICENSE)

# Secret-value shapes, same class pack-installer.sh guards against
# (ADR-034), plus GitHub PATs (this repo's own primary credential class —
# CLAUDE_STACK_REPO_TOKEN, LADE_MIRROR_PUSH_TOKEN). sk_live_/sk-ant- require
# a 12+ char trailing key-body: without it this grep self-matches the
# pattern's own source (this file, pack-installer.sh, and docs that document
# the bare prefix literally) and short fixture strings elsewhere in the repo
# (e.g. tests/test-pack-installer.sh's planted "sk_live_abc123"). Real
# Stripe/Anthropic/GitHub tokens run well past these floors.
MIRROR_SCRUB_SECRET_PATTERN='sk_live_[A-Za-z0-9_-]{12,}|sk-ant-[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|-----BEGIN( [A-Z]+)? PRIVATE KEY-----'

# _mirror_scrub_in_list <needle> <haystack...> -> exit 0 if needle is one of
# the remaining args.
_mirror_scrub_in_list() {
  local needle="$1"; shift
  local candidate
  for candidate in "$@"; do
    [[ "$needle" == "$candidate" ]] && return 0
  done
  return 1
}

# scrub_guard <archived_tree_dir> -> exit 0 clean | exit 1, stderr lists
# EVERY offending path (all-misses, not first-fail).
scrub_guard() {
  local dir="$1"
  local -a violations=()

  if [[ ! -d "$dir" ]]; then
    echo "  [mirror-scrub-fail] archived tree not found: $dir" >&2
    return 1
  fi

  # Top-level allowlist check (mirrors .gitattributes; see header comment).
  local entry name
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    if [[ -d "$entry" ]]; then
      if ! _mirror_scrub_in_list "$name" "${MIRROR_SCRUB_ALLOWED_DIRS[@]}"; then
        violations+=("$name/ present in archived tree (not on the installable-core allowlist)")
      fi
    else
      if ! _mirror_scrub_in_list "$name" "${MIRROR_SCRUB_ALLOWED_FILES[@]}"; then
        violations+=("$name present in archived tree (not on the installable-core allowlist)")
      fi
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  # .env* files must never ship, even nested inside an allowed dir.
  local env_hit
  while IFS= read -r -d '' env_hit; do
    violations+=("${env_hit#"$dir"/}: .env* file present in archived tree")
  done < <(find "$dir" -type f -name '.env*' -print0 2>/dev/null)

  # Secret-value shapes, wherever they appear. grep exit codes: 0 = match
  # (violation), 1 = no match (clean), >=2 = a real error (arg-list limits,
  # OOM, unreadable path) — that must fail CLOSED, never be swallowed as
  # "clean" the way a bare `|| true` would.
  local secret_matches secret_rc
  if secret_matches="$(grep -rEl --exclude-dir=.git "$MIRROR_SCRUB_SECRET_PATTERN" "$dir" 2>&1)"; then
    secret_rc=0
  else
    secret_rc=$?
  fi
  if [[ "$secret_rc" -ge 2 ]]; then
    violations+=("secret-shape scan failed (grep exit $secret_rc), failing closed: $secret_matches")
  elif [[ "$secret_rc" -eq 0 ]]; then
    local secret_hit
    while IFS= read -r secret_hit; do
      [[ -z "$secret_hit" ]] && continue
      violations+=("${secret_hit#"$dir"/}: secret-value shape found")
    done <<< "$secret_matches"
  fi

  if (( ${#violations[@]} > 0 )); then
    echo "  [mirror-scrub-fail] scrub guard found ${#violations[@]} violation(s):" >&2
    local v
    for v in "${violations[@]}"; do
      echo "    $v" >&2
    done
    return 1
  fi

  return 0
}
