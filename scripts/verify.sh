#!/usr/bin/env bash
# Verify a tier install, or a repo's stack onboarding.
# Usage: ./verify.sh --tier=N [--skip-requirements]
#        ./verify.sh --repo=PATH
#
# --tier=N         verifies the global stack install (tiers 0..N).
# --repo=PATH      verifies that a repo is correctly onboarded onto the stack.
# --skip-requirements treats environmental smoke tests (external commands,
# Keychain items) as skipped rather than failed. Intended for CI.

set -euo pipefail

TIER=""
REPO=""
SKIP_REQUIREMENTS=""
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}" ;;
    --skip-requirements) SKIP_REQUIREMENTS="1" ;;
  esac
done

if [[ -z "$TIER" && -z "$REPO" ]]; then
  echo "Usage: $0 --tier=N [--skip-requirements]"
  echo "       $0 --repo=PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ADR-053 D7/D8: domain_mode may be a scalar or an array; loop dm_active_modes
# rather than `jq -r .domain_mode`, which on an array emits pretty-printed
# multi-line JSON that then corrupted the interpolated hard_check command.
_DM_LIB="$REPO_ROOT/lib/domain-modes.sh"
[[ -f "$_DM_LIB" ]] || _DM_LIB="$HOME/.claude/lib/domain-modes.sh"
# shellcheck disable=SC1090
source "$_DM_LIB" 2>/dev/null || true

failures=0
passes=0
warnings=0

run_test() {
  local cmd="$1"
  if [[ -n "$SKIP_REQUIREMENTS" ]] && [[ "$cmd" == "command -v "* || "$cmd" == *"security find-generic-password"* ]]; then
    echo "  [SKIP] $cmd"
    return
  fi
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [PASS] $cmd"
    passes=$((passes + 1))
  else
    echo "  [FAIL] $cmd"
    failures=$((failures + 1))
  fi
}

hard_check() {
  # hard_check <test-expr> <pass-msg> <fail-msg>
  if eval "$1" > /dev/null 2>&1; then
    echo "  [PASS] $2"; passes=$((passes + 1))
  else
    echo "  [FAIL] $3"; failures=$((failures + 1))
  fi
}

soft_check() {
  # soft_check <test-expr> <pass-msg> <warn-msg>
  if eval "$1" > /dev/null 2>&1; then
    echo "  [PASS] $2"; passes=$((passes + 1))
  else
    echo "  [WARN] $3"; warnings=$((warnings + 1))
  fi
}

verify_repo() {
  local repo="${1%/}"
  local cfg="$repo/.claude/stack-config.json"
  local modes="$REPO_ROOT/config/domain-modes.json"

  echo "Verifying repo: $repo"

  if [[ ! -f "$cfg" ]]; then
    echo "  [FAIL] .claude/stack-config.json missing — foreman refuses to dispatch (strict mode)"
    failures=$((failures + 1))
    return
  fi
  echo "  [PASS] .claude/stack-config.json exists"; passes=$((passes + 1))

  if ! jq -e . "$cfg" > /dev/null 2>&1; then
    echo "  [FAIL] stack-config.json is not valid JSON — fix before anything else"
    failures=$((failures + 1))
    return
  fi
  echo "  [PASS] stack-config.json is valid JSON"; passes=$((passes + 1))

  local tier version
  tier="$(jq -r '.stack_tier // empty' "$cfg")"
  version="$(jq -r '.stack_version // empty' "$cfg")"

  hard_check "[[ '$tier' =~ ^[0-5]\$ ]]" \
    "stack_tier = $tier" \
    "stack_tier missing or not 0-5 (got: '${tier:-unset}')"

  hard_check "[[ -n '$version' ]]" \
    "stack_version = ${version:-unset}" \
    "stack_version missing"

  local declared_modes
  declared_modes="$(dm_active_modes "$cfg")"
  if [[ -z "$declared_modes" ]]; then
    echo "  [INFO] no domain_mode set (expected for tier 0-2)"
  else
    local m
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      if jq -e --arg m "$m" '.modes | has($m)' "$modes" > /dev/null 2>&1; then
        echo "  [PASS] domain_mode '$m' is a known mode"; passes=$((passes + 1))
      else
        echo "  [FAIL] domain_mode '$m' is not defined in config/domain-modes.json"; failures=$((failures + 1))
      fi
    done <<< "$declared_modes"
  fi

  # §11 audit artifacts — soft checks (tier-dependent, advisory)
  soft_check "[[ -n \"\$(ls -A '$repo/docs/ADRs' 2>/dev/null)\" ]]" \
    "docs/ADRs/ present" \
    "docs/ADRs/ missing or empty — §11 retroactive audit incomplete"
  soft_check "[[ -d '$repo/docs/runbooks' ]]" \
    "docs/runbooks/ present" \
    "docs/runbooks/ missing — §11 retroactive audit incomplete"
  soft_check "[[ -f '$repo/docs/ONBOARDING.md' ]]" \
    "docs/ONBOARDING.md present" \
    "docs/ONBOARDING.md missing — no successor onboarding doc"
}

if [[ -n "$REPO" ]]; then
  verify_repo "$REPO"
else
  for ((t=0; t<=TIER; t++)); do
    manifest="$REPO_ROOT/config/tier-manifests/tier-$t.json"
    [[ -f "$manifest" ]] || continue

    echo "Verifying tier $t..."
    tests="$(jq -r '.smoke_tests // [] | .[]' "$manifest")"
    while IFS= read -r test; do
      [[ -z "$test" ]] && continue
      run_test "$test"
    done <<< "$tests"

    # advisory_smoke_tests (ADR-030): warn, never fail — for capabilities the
    # default config does not need (e.g. `command -v codex` once the OpenAI
    # family reaches GPT-5.5 via the API by default; the CLI is opt-in).
    adv="$(jq -r '.advisory_smoke_tests // [] | .[]' "$manifest")"
    while IFS= read -r test; do
      [[ -z "$test" ]] && continue
      # ADR-030: codex CLI is only relevant when codex_transport=cli; the
      # machine-wide default is 'api', so skip the check entirely unless the
      # operator opted into the CLI transport via env.
      if [[ "$test" == *codex* && "${REVIEW_CODEX_TRANSPORT:-api}" != "cli" ]]; then
        continue
      fi
      soft_check "$test" "$test" "$test (advisory — needed only for codex_transport=cli; ADR-030)"
    done <<< "$adv"
  done
fi

echo ""
echo "Results: $passes passed, $failures failed, $warnings warning(s)"

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "Some checks failed. Common fixes:"
  echo "  - Missing stack-config.json: run /project-init in the repo"
  echo "  - Missing Keychain item: security add-generic-password -s '<name>' -a \"\$USER\" -w '<value>' -U"
  echo "  - Missing command: brew install <tool>"
  echo "  - Missing schema: apply via Supabase SQL editor"
  exit 1
fi

if [[ "$warnings" -gt 0 ]]; then
  echo "All hard checks passed ($warnings warning(s) — advisory, see above)."
else
  echo "All checks passed."
fi
