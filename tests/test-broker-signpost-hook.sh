#!/usr/bin/env bash
# tests/test-broker-signpost-hook.sh — D18 P4: the layer-3 signpost denies
# direct vendor CLI invocations with a message NAMING THE BROKER, and stays
# out of the way of everything else (including gh reads).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/broker-signpost.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_hook() { jq -n --arg c "$1" '{tool_input:{command:$c}}' | bash "$HOOK"; }

denies() { run_hook "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }
names_broker() { run_hook "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -q 'stack-broker'; }

# ── denials, each naming the broker ────────────────────────────────────────
for c in "wrangler deploy" "cd /x && wrangler deploy --env prod" \
         "supabase db push" "netlify deploy --prod" "neonctl branches create" \
         "gh pr create --title x" "gh pr merge 5" "gh api /repos/o/r/rulesets -X POST" \
         "git pull && gh pr merge --auto 7"; do
  if denies "$c" && names_broker "$c"; then
    pass "denies + names broker: $c"
  else
    fail "should deny naming broker: $c"
  fi
done

# ── pass-through: reads and unrelated commands ─────────────────────────────
for c in "gh pr view 12" "gh run view 123 --log" "git push origin feat/x" \
         "ls -la" "echo wrangler deploy" "grep supabase docs/notes.md" \
         "gh api /repos/o/r/pulls" ; do
  if denies "$c"; then
    fail "should NOT deny: $c"
  else
    pass "passes through: $c"
  fi
done

# ── the deny text never names private machinery ────────────────────────────
LEAK=0
for c in "wrangler deploy" "gh pr merge 5"; do
  MSG="$(run_hook "$c" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
  echo "$MSG" | grep -qE '/var/db/stack-broker|/etc/sudoers|approve\.sock|stack-approve --' && LEAK=1
done
[[ $LEAK -eq 0 ]] && pass "deny text names the remedy, not the machinery" || fail "deny text leaked a private path"

# ── evasion is documented, not defended (labelled friction) ────────────────
if denies 'W=wrangler; $W deploy'; then
  fail "variable indirection unexpectedly caught — update the hook's own honesty comment"
else
  pass "variable indirection evades, as the hook's header documents (friction, not boundary)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
