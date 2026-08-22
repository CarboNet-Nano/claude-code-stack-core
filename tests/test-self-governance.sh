#!/usr/bin/env bash
# Tests for ADR-087 D13 (R3) — the GitHub-side half of the review control.
# Cases 92-99 of the 102-case plan.
#
#   92 — trigger lint: pull_request_target, NOT pull_request. (The rev-2
#        DON'T-SHIP regression test: a pull_request trigger would load the
#        workflow from the PR, making the PR its own judge.)
#   93 — no-head-code lint: no checkout of the PR's head ref, no execution of
#        anything the PR could supply. This is what makes
#        pull_request_target safe here rather than a "pwn request".
#   94 — minimal permissions lint.
#   95 — truncation fails closed (ADR-085's could-not-look rule).
#   96 — ruleset presence, name agreement, empty bypass list, strict policy.
#   97 — the job name carries "(required)" (ADR-085 D4).
#   98 — state/attest/** is in the floor for master AND ~/.claude-* forms.
#   99 — the floor gains exactly THREE attest entries and no more, so D14's
#        "no per-feature globs" rule is enforced by a test, not by memory.
#
# Also covers D13c #1's deny extension in hooks/irreversible-deny.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/self-governance.yml"
RULESET="$REPO_ROOT/.github/rulesets/self-governance.json"
FLOOR="$REPO_ROOT/config/managed-settings.floor.json"
DENY_HOOK="$REPO_ROOT/hooks/irreversible-deny.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ═══ 92: trigger lint ═══════════════════════════════════════════════════════
if [[ ! -f "$WF" ]]; then
  fail "92: .github/workflows/self-governance.yml is missing"
else
  if grep -qE '^[[:space:]]*pull_request_target:' "$WF"; then
    pass "92a: declares on: pull_request_target"
  else
    fail "92a: no pull_request_target trigger"
  fi
  # A bare `pull_request:` trigger would load this workflow FROM THE PR.
  # Match only a trigger key, not the string inside a comment or an
  # expression like github.event.pull_request.number.
  if grep -qE '^[[:space:]]{2,4}pull_request:[[:space:]]*$' "$WF"; then
    fail "92b: a pull_request trigger is present — the PR would judge itself"
  else
    pass "92b: no pull_request trigger"
  fi
fi

# ═══ 93: no head-ref code execution ═════════════════════════════════════════
if [[ -f "$WF" ]]; then
  # Any `ref:` naming the head is the pwn-request shape.
  if grep -nE '^[[:space:]]*ref:' "$WF" | grep -qiE 'head'; then
    fail "93a: a checkout ref references the PR head — head code would run"
  else
    pass "93a: no checkout ref references the PR head"
  fi
  # Belt and braces: the head sha/ref must not appear in any `ref:` position
  # at all, however spelled.
  if grep -qiE 'ref:[[:space:]]*\$\{\{[[:space:]]*github\.event\.pull_request\.head' "$WF"; then
    fail "93b: checkout uses github.event.pull_request.head.*"
  else
    pass "93b: no github.event.pull_request.head.* in a ref: position"
  fi
  # The PR's file list must be metadata, never something executed. Assert the
  # collected list is only ever read, not sourced or run.
  if grep -qE '(source|\.|bash|sh)[[:space:]]+/tmp/changed-files\.txt' "$WF"; then
    fail "93c: the changed-file list is executed rather than read"
  else
    pass "93c: the changed-file list is read as data, never executed"
  fi
fi

# ═══ 94: minimal permissions ════════════════════════════════════════════════
if [[ -f "$WF" ]]; then
  PERMS_BLOCK="$(awk '/^permissions:/{flag=1;next}/^[a-z]/{flag=0}flag' "$WF")"
  if [[ -z "$PERMS_BLOCK" ]]; then
    fail "94: no explicit top-level permissions: block"
  else
    GRANTS="$(printf '%s\n' "$PERMS_BLOCK" | grep -oE '^[[:space:]]*[a-z-]+:[[:space:]]*[a-z]+' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]//g' | sort)"
    EXPECTED="$(printf 'contents:read\npull-requests:read\n' | sort)"
    if [[ "$GRANTS" == "$EXPECTED" ]]; then
      pass "94: permissions are exactly contents:read + pull-requests:read"
    else
      fail "94: permissions block is '$GRANTS', expected '$EXPECTED'"
    fi
  fi
fi

# ═══ 95: truncation fails closed ════════════════════════════════════════════
# The classify step's contract: a file list that could not be read completely
# classifies high rather than classifying a partial list. Exercise the shell
# logic directly with a mocked truncation flag.
if [[ -f "$WF" ]]; then
  if grep -q 'truncated' "$WF" && grep -qE 'TRUNCATED.*==.*"1"' "$WF"; then
    pass "95a: the classify step branches on a truncation flag"
  else
    fail "95a: no truncation branch in the classify step"
  fi
  # The truncation branch must exit non-zero (block), not warn.
  TRUNC_BRANCH="$(awk '/TRUNCATED.*==.*"1"/{flag=1} flag{print} /^[[:space:]]*fi[[:space:]]*$/{if(flag){exit}}' "$WF")"
  if printf '%s' "$TRUNC_BRANCH" | grep -qE 'exit[[:space:]]+1'; then
    pass "95b: truncation exits non-zero (fails closed)"
  else
    fail "95b: truncation does not fail closed"
  fi
  # And the short-page check must exist, not just the declared-count check —
  # pagination can come back short without the count exceeding the cap.
  if grep -q 'came back short' "$WF"; then
    pass "95c: a short paginated result also fails closed"
  else
    fail "95c: only the declared count is checked, not the returned count"
  fi
fi

# ═══ 95d/95e: a self-governing PR blocks only when it would merge unattended ═
# The first version failed unconditionally on the self-governing set. With an
# empty bypass list that means those files can never change again, through any
# path, by anyone — the controls could not be fixed, improved, or removed.
# PR #314 proved it by locking itself out on the very first run. D13d's rule
# is "no auto-merge on the self-governing set; these PRs are human-merged",
# so the check blocks the UNATTENDED merge and leaves the human a door.
if [[ -f "$WF" ]]; then
  if grep -q 'AUTO_MERGE' "$WF"; then
    pass "95d: the classify step reads whether auto-merge is armed"
  else
    fail "95d: no auto-merge check — a self-governing PR would block forever"
  fi
  HIGH_BRANCH="$(awk '/if \[\[ "\$CLASS" == "high" \]\]/{flag=1} flag{print}' "$WF")"
  if printf '%s' "$HIGH_BRANCH" | grep -qE 'AUTO_MERGE.*==.*"true"'; then
    pass "95e-a: the high branch fails only when auto-merge is armed"
  else
    fail "95e-a: the high branch does not gate on auto-merge"
  fi
  if printf '%s' "$HIGH_BRANCH" | grep -qE 'exit[[:space:]]+0'; then
    pass "95e-b: a human-merged self-governing PR can still pass"
  else
    fail "95e-b: the high branch has no passing path — the door is bricked"
  fi
fi

# ═══ 96 + 97: ruleset presence and name agreement ═══════════════════════════
if [[ ! -f "$RULESET" ]]; then
  fail "96: .github/rulesets/self-governance.json is missing"
else
  if jq -e . "$RULESET" >/dev/null 2>&1; then
    pass "96a: ruleset file is valid JSON"
  else
    fail "96a: ruleset file is not valid JSON"
  fi

  BYPASS_COUNT="$(jq -r '.bypass_actors | length' "$RULESET" 2>/dev/null)"
  if [[ "$BYPASS_COUNT" == "0" ]]; then
    pass "96b: bypass_actors is empty (an admin bypass re-opens the hole)"
  else
    fail "96b: bypass_actors has $BYPASS_COUNT entr(ies) — the hole is re-opened"
  fi

  STRICT="$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy] | first' "$RULESET" 2>/dev/null)"
  if [[ "$STRICT" == "true" ]]; then
    pass "96c: require-branches-up-to-date is set"
  else
    fail "96c: strict_required_status_checks_policy is '$STRICT', want true"
  fi

  CONTEXT="$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | first' "$RULESET" 2>/dev/null)"
  JOB_NAME="$(grep -E '^[[:space:]]*name:[[:space:]]*classify' "$WF" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*name:[[:space:]]*//')"
  if [[ -n "$CONTEXT" && "$CONTEXT" == "$JOB_NAME" ]]; then
    pass "96d: the required check name matches the workflow job name exactly"
  else
    fail "96d: ruleset wants '$CONTEXT' but the job is named '$JOB_NAME'"
  fi

  # 97 (ADR-085 D4): a required check says so in its name.
  if [[ "$JOB_NAME" == *"(required)"* ]]; then
    pass "97: the job name carries '(required)'"
  else
    fail "97: job name '$JOB_NAME' does not carry '(required)'"
  fi

  if jq -e '.conditions.ref_name.include | index("refs/heads/main")' "$RULESET" >/dev/null 2>&1; then
    pass "96e: the ruleset targets main"
  else
    fail "96e: the ruleset does not target refs/heads/main"
  fi
fi

# ═══ 98 + 99: the floor's attest entries ════════════════════════════════════
ATTEST_ENTRIES="$(jq -r '.sandbox.filesystem.denyWrite[] | select(test("state/attest"))' "$FLOOR" 2>/dev/null)"
ATTEST_COUNT="$(printf '%s\n' "$ATTEST_ENTRIES" | grep -c . )"

for want in '~/.claude/state/attest/**' '**/.claude/state/attest/**' '~/.claude-*/state/attest/**'; do
  if printf '%s\n' "$ATTEST_ENTRIES" | grep -qxF -- "$want"; then
    pass "98: floor denies $want"
  else
    fail "98: floor is missing $want"
  fi
done

# 99: EXACTLY three. D14's rule ("a new feature gets a subdirectory, not a
# floor amendment") is enforced here rather than remembered.
if [[ "$ATTEST_COUNT" == "3" ]]; then
  pass "99: the floor carries exactly 3 attest entries, no per-feature globs"
else
  fail "99: the floor carries $ATTEST_COUNT attest entries, want exactly 3"
fi

# ═══ D13c #1: ruleset mutation is denied ════════════════════════════════════
# irreversible-deny.sh only acts while a governed loop is ACTIVE — that is
# the hook's pre-existing scope (ADR-020), not something this ADR changes.
# So D13c's mitigation covers ruleset mutation during an autonomous loop, and
# NOT during an ordinary interactive session. Stated plainly rather than
# implied: outside a loop, `gh ruleset delete` is not denied by anything
# local, which is exactly why D13c calls a non-admin token the real fix.
export HOME="$TMP/deny-home"
mkdir -p "$HOME/.claude/session-state"
DENY_STATE="$HOME/.claude/session-state/loop-state.json"
printf '%s' '{"active":true}' > "$DENY_STATE"

deny_says_deny() { # <command> -> 0 if the hook denies it
  local cmd="$1"
  local out
  # LOOP_STATE_FILE is pinned rather than relying on the directory: the real
  # session's CLAUDE_CODE_SESSION_ID leaks in from the environment and makes
  # the lib look for loop-state.<sid>.json, so a bare directory override
  # silently reads a file that does not exist — and every deny assertion
  # below would pass vacuously.
  out="$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' \
    | LOOP_STATE_DIR="$HOME/.claude/session-state" LOOP_STATE_FILE="$DENY_STATE" \
      bash "$DENY_HOOK" 2>/dev/null)"
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1
}

# Control: prove the harness itself works before trusting its verdicts. A
# known-denied command must deny, or every result below is meaningless.
if deny_says_deny 'git push origin main'; then
  pass "D13c-harness: a known-denied command denies (the fixture is live)"
else
  fail "D13c-harness: the fixture is not active — results below prove nothing"
fi

for cmd in \
  'gh api -X DELETE repos/o/r/rulesets/42' \
  'gh api --method PUT repos/o/r/branches/main/protection' \
  'gh api repos/o/r/rulesets/42 -X PATCH' \
  'gh ruleset delete self-governance' \
  ; do
  if deny_says_deny "$cmd"; then
    pass "D13c: denied — $cmd"
  else
    fail "D13c: NOT denied — $cmd"
  fi
done

# Reads must still work — this is friction on writes, not a lockout.
for cmd in \
  'gh api repos/o/r/rulesets' \
  'gh ruleset list' \
  ; do
  if deny_says_deny "$cmd"; then
    fail "D13c: over-reached, denied a read — $cmd"
  else
    pass "D13c: read still allowed — $cmd"
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
