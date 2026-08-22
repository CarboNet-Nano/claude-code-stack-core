#!/usr/bin/env bash
# lib/broker-push.sh — the sanctioned push/PR path for the stack's own GitHub
# writers (D18 P4 step 5). Sourceable only, matching lib/receipt.sh.
#
# broker_push_and_pr <workdir> <owner/repo> <branch> <base> <title> <body>
#   Pushes <branch> from <workdir> through `stack-broker github.branch.push`
#   and opens a PR through `stack-broker github.pr.create`.
#
# Returns:
#   0   pushed and PR created through the broker (PR url on stdout, if any)
#   75  broker unavailable on this machine (not installed / daemon down):
#       the caller MAY fall back to its direct git/gh path. That fallback is
#       a PRE-P5 transition path: once GitHub write is revoked at the vendor,
#       the fallback dies of DENIED_BY_AUTH on its own, and the broker is the
#       only door left. Callers must log which path they took.
#   *   any other nonzero: the broker REFUSED (invariant, param, approval) —
#       do NOT fall back; the refusal is the answer.

broker_push_and_pr() {
  local wd="$1" repo="$2" branch="$3" base="$4" title="$5" body="$6"

  command -v stack-broker >/dev/null 2>&1 || return 75
  stack-broker pending --json >/dev/null 2>&1
  local rc=$?
  [[ $rc -eq 6 ]] && return 75

  local head_sha bundle rc2
  head_sha="$(git -C "$wd" rev-parse --verify "refs/heads/$branch" 2>/dev/null)" || return 3
  bundle="$(mktemp)" || return 3
  if ! git -C "$wd" bundle create "$bundle" "refs/heads/$branch" >/dev/null 2>&1; then
    rm -f "$bundle"; return 3
  fi

  stack-broker github.branch.push \
    --repo "$repo" --branch "$branch" --head-sha "$head_sha" \
    --bundle-file "$bundle" \
    --reason "stack caller: push $branch" >/dev/null
  rc2=$?
  rm -f "$bundle"
  [[ $rc2 -eq 6 ]] && return 75
  [[ $rc2 -ne 0 ]] && return "$rc2"

  local out
  out="$(stack-broker github.pr.create \
    --repo "$repo" --head "$branch" --base "$base" \
    --title "$title" --body "$body" \
    --reason "stack caller: PR for $branch" --json)"
  rc2=$?
  [[ $rc2 -eq 6 ]] && return 75
  [[ $rc2 -ne 0 ]] && return "$rc2"
  echo "$out" | jq -r '.result.html_url // empty' 2>/dev/null
  return 0
}
