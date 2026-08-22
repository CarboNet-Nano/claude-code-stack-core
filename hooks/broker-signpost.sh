#!/usr/bin/env bash
# PreToolUse Bash hook: the D18 layer-3 SIGNPOST. Denies direct vendor-CLI
# invocations with a message naming the broker.
# summary: Denies direct vendor CLI calls (wrangler/supabase/netlify/neonctl and gh write verbs) and points at stack-broker.
#
# EXPLICITLY LABELLED FRICTION, NOT A BOUNDARY (design §4 layer 3): a mistaken
# agent gets a remedy instead of a confusing network timeout. `W=wrangler;
# $W deploy` walks straight past this — the same accepted class that
# hooks/review-gate.sh:174-177 records about itself. The boundary is the dead
# credential (P5), not this string test.

set -uo pipefail

input="$(cat 2>/dev/null || echo '{}')"
cmd="$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[[ -z "$cmd" || "$cmd" == "null" ]] && exit 0

deny() {
  # ADR-087 D5 deny-message contract: name the remedy, never the machinery.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$1"
  exit 0
}

# Vendor CLIs whose direct use is broker-only. Word match at a command
# position (start of line or after ; && || | $( ` ).
VENDOR_CLI='(wrangler|supabase|netlify|neonctl|neon)'
if echo "$cmd" | grep -qE "(^|[;&|\`(]|\\\$\\()[[:space:]]*${VENDOR_CLI}[[:space:]]"; then
  deny "Direct vendor CLI access is broker-only (D18). Use the stack-broker: run stack-broker ops to see what is available. Write-class operations need human approval — ask the maintainer to run sudo stack-approve."
fi

# gh WRITE verbs (read verbs stay native on the read-only PAT — §5.3).
GH_WRITE='gh[[:space:]]+(pr[[:space:]]+(create|merge|close|edit|ready)|repo[[:space:]]+(create|delete|edit)|release[[:space:]]+(create|delete)|api[[:space:]]+[^|;]*-(X|-method)[[:space:]]+(POST|PUT|PATCH|DELETE)|secret[[:space:]]|ruleset[[:space:]]|workflow[[:space:]]+(run|enable|disable))'
if echo "$cmd" | grep -qE "(^|[;&|\`(]|\\\$\\()[[:space:]]*${GH_WRITE}"; then
  deny "GitHub writes are broker-only (D18): use stack-broker github.branch.push / github.pr.create. PR merge is write-class and needs human approval via sudo stack-approve. Read commands (gh pr view, gh run view) stay native."
fi

exit 0
