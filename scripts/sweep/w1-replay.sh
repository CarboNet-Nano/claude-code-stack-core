#!/usr/bin/env bash
# scripts/sweep/w1-replay.sh — score W1 against a list of known defects.
#
# W1 does not enter scripts/sweep/inventory.txt until this has run and its
# number is recorded (spec Decision 6): an id in the inventory obliges every
# repo in the fleet to declare a block or a reasoned skip, and that cost
# should not be spent on a check nobody has measured.
#
# The number is only worth holding the id back for if it cannot be inflated,
# so this script is mostly about what it refuses to hide:
#   - out-of-scope defects are printed by id WITH their reason, and excluded
#     from the denominator. Quietly dropping what the verbs cannot see is
#     how a catch rate becomes a lie.
#   - misses are named individually, never summarised away.
#   - an absent, unreadable, or malformed list is an ERROR, not an empty
#     perfect score.
#
# Exit code is deliberate: 0 on a completed measurement WHATEVER the score.
# This instrument measures; whether the number is good enough to ship is a
# human judgement, recorded in docs/audits/w1-replay/ alongside it.
#
# Usage: w1-replay.sh <defect-list.json>
#
# The list is an array of:
#   { "id": "AP#217", "in_scope": true,  "caught": true  }
#   { "id": "AP#226", "in_scope": false, "reason": "..." }

set -uo pipefail

LIST="${1:-}"

if [ -z "$LIST" ]; then
  echo "w1-replay: usage: w1-replay.sh <defect-list.json>" >&2
  echo "w1-replay: the list is required — an absent list is not an empty perfect score" >&2
  exit 2
fi

if [ ! -f "$LIST" ]; then
  echo "w1-replay: $LIST does not exist — refusing to report a score over nothing" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "w1-replay: jq is required" >&2; exit 2; }

if ! jq -e 'type == "array"' "$LIST" >/dev/null 2>&1; then
  echo "w1-replay: $LIST is not a JSON array of defect records" >&2
  exit 2
fi

in_scope=0
caught=0

while IFS="$(printf '\t')" read -r id scope hit reason; do
  [ -z "$id" ] && continue
  if [ "$scope" != "true" ]; then
    printf 'OUT-OF-SCOPE  %s — %s\n' "$id" "$reason"
    continue
  fi
  in_scope=$((in_scope + 1))
  if [ "$hit" = "true" ]; then
    caught=$((caught + 1))
    printf 'CAUGHT        %s\n' "$id"
  else
    printf 'MISSED        %s\n' "$id"
  fi
done < <(jq -r '.[] | [.id, (.in_scope|tostring), ((.caught // false)|tostring), (.reason // "no reason stated")] | @tsv' "$LIST")

echo ""
echo "catch rate: ${caught}/${in_scope}"

if [ "$in_scope" -eq 0 ]; then
  echo "nothing in scope — every defect in this list is outside W1's verb set, so 0/0 is not a result"
else
  echo "(out-of-scope defects are listed above and excluded from this denominator)"
fi
