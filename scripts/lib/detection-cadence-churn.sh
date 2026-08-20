#!/usr/bin/env bash
# scripts/lib/detection-cadence-churn.sh — churn-selection logic for the
# monthly cross-family-review job in .github/workflows/detection-cadence.yml
# (stack ADR-082 spec P1e). Factored out of the workflow so
# tests/test-detection-cadence.sh can drive it directly against a fixture
# git repo (ties + zero-churn cases), same house pattern as
# scripts/lib/resolve-migrations-dir.sh: sourced, not executed — functions
# only, callers own `set -uo pipefail`.
#
# "top dir" = depth-2 directory (at most two leading path segments; a file
# directly under the repo root with no directory component is excluded —
# nothing to attribute churn to) with the most COMMITS touching it (a commit
# that changes five files under the same bucket counts once for that bucket,
# not five), since a given cutoff. Ties broken alphabetically (spec P1e).

# dc_since_arg <since-iso-or-empty> -> a value git's `--since` understands.
# git parses "30 days ago" itself (b4-merge-run.sh's own precedent) — no
# GNU/BSD date arithmetic needed here.
dc_since_arg() {
  local since="${1:-}"
  if [[ -n "$since" ]]; then
    printf '%s' "$since"
  else
    printf '30 days ago'
  fi
}

# dc_top_churn_dir <repo-root> [since-iso-or-empty] -> the winning depth-2
# directory on stdout, or nothing (empty) when zero commits touched any
# directory since the cutoff. rc is always 0 — "no churn" is a legitimate
# result, not a failure, so the caller decides what an empty answer means.
dc_top_churn_dir() {
  local root="$1" since="${2:-}"
  local since_arg; since_arg="$(dc_since_arg "$since")"

  local tmp; tmp="$(mktemp 2>/dev/null)" || return 0
  git -C "$root" log --since="$since_arg" --pretty=format:'@@%H' --name-only 2>/dev/null > "$tmp"

  awk '
    /^@@/ { commit = $0; next }
    NF == 0 { next }
    {
      n = split($0, parts, "/")
      if (n < 2) next
      bucket = (n >= 3) ? parts[1] "/" parts[2] : parts[1]
      key = commit SUBSEP bucket
      if (!(key in seen)) { seen[key] = 1; count[bucket]++ }
    }
    END {
      for (b in count) print count[b], b
    }
  ' "$tmp" | sort -k1,1nr -k2,2 | awk 'NR==1 { print $2 }'

  rm -f "$tmp"
  return 0
}
