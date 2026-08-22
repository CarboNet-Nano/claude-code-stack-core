#!/usr/bin/env bash
# Tests for ADR-087 D6/D13 doc-wiring — cases 89-91 of the 102-case plan.
#
#   89 — skills/foreman/SKILL.md names the Review-subject: line and the
#        main-thread panel-runner rule (stops ADR-057's wiring miss from
#        happening twice).
#   90 — all five adversarial agent files route through panel-review.sh, none
#        still instruct a direct gmn_call/oair_call, and all five retain a
#        piped-stdin example (guards against re-introducing BLOCKER 2).
#   91 — every member of D13b's self-governing set — including
#        .github/workflows/** — classifies high under rr_change_class.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/review-router.sh"
FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
AGENTS=(architecture-critic red-team reviewer security-auditor product-critic)

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
unset CLAUDE_CONFIG_DIR
export REVIEW_ASSUME_LOCAL=1

# ─── 89: foreman dispatch protocol names the wiring ─────────────────────────
if grep -q 'Review-subject:' "$FOREMAN"; then
  pass "89a: foreman SKILL.md names the Review-subject: line"
else
  fail "89a: foreman SKILL.md has no Review-subject: line"
fi

if grep -q 'panel-review\.sh' "$FOREMAN" \
   && grep -qi 'main thread' "$FOREMAN"; then
  pass "89b: foreman SKILL.md states the main-thread panel-runner rule"
else
  fail "89b: foreman SKILL.md missing panel-review.sh main-thread rule"
fi

# ─── 90: five agent files route through panel-review.sh ─────────────────────
for a in "${AGENTS[@]}"; do
  f="$REPO_ROOT/agents/$a.md"
  if [[ ! -f "$f" ]]; then fail "90: agents/$a.md missing"; continue; fi

  if grep -q 'panel-review\.sh' "$f"; then
    pass "90a($a): routes through panel-review.sh"
  else
    fail "90a($a): no panel-review.sh reference"
  fi

  # A direct vendor *invocation* (piping into, or calling with a prompt arg)
  # must be gone. Narrative mentions of the helper names are allowed.
  if grep -Eq 'gmn_call "|oair_call "|\|[[:space:]]*gmn_call|\|[[:space:]]*oair_call' "$f"; then
    fail "90b($a): still instructs a direct gmn_call/oair_call"
  else
    pass "90b($a): no direct vendor-call instruction"
  fi

  # Piped-stdin example retained: a pipe-continuation line feeding the runner
  # ("... | \" followed by a "$PANEL" <seat> line). BLOCKER 2's guard.
  if grep -A1 -E '\|[[:space:]]*\\$' "$f" | grep -q '"\$PANEL"'; then
    pass "90c($a): retains a piped-stdin example into the runner"
  else
    fail "90c($a): no piped-stdin example into the runner"
  fi
done

# ─── 91: every self-governing member classifies high ────────────────────────
build_repo() { # <changed_file_path> -> echoes repo dir
  local changed="$1"
  local R="$TMP/repo-$RANDOM$RANDOM"; mkdir -p "$R"
  (
    cd "$R"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    echo base > README.md
    git add -A; git commit -qm base
    git checkout -q -b feat
    mkdir -p "$(dirname "$changed")"
    printf 'change\n' > "$changed"
    git add -A; git commit -qm feat
  )
  echo "$R"
}

class_of() { # <repo> -> echoes low/med/high
  local R="$1"
  ( cd "$R"; bash -c "source '$LIB'; rr_change_class main HEAD" )
}

MEMBERS="$(bash -c "source '$LIB'; rr_self_governing_paths")"
if [[ -z "$MEMBERS" ]]; then
  fail "91: rr_self_governing_paths returned nothing"
else
  ALL_HIGH=1
  while IFS= read -r m; do
    R="$(build_repo "$m")"
    got="$(class_of "$R")"
    if [[ "$got" != "high" ]]; then
      fail "91: self-governing member '$m' classified '$got', not high"
      ALL_HIGH=0
    fi
  done <<< "$MEMBERS"
  [[ "$ALL_HIGH" -eq 1 ]] && pass "91a: every exact self-governing member classifies high"
fi

R_WF="$(build_repo ".github/workflows/self-governance.yml")"
got="$(class_of "$R_WF")"
[[ "$got" == "high" ]] \
  && pass "91b: .github/workflows/** member classifies high" \
  || fail "91b: .github/workflows/ change classified '$got', not high"

R_RS="$(build_repo ".github/rulesets/self-governance.json")"
got="$(class_of "$R_RS")"
[[ "$got" == "high" ]] \
  && pass "91c: .github/rulesets/** member classifies high" \
  || fail "91c: .github/rulesets/ change classified '$got', not high"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
