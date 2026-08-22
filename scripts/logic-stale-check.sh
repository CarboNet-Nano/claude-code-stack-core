#!/usr/bin/env bash
# logic-stale-check.sh — ADR-050 Contract B / D5's LOGIC-STALE signal.
#
# Line-span-scoped staleness check: has any git change since
# receipts.extraction.commit touched a line span the logic doc cites?
# Pure git, zero LLM tokens, no AST — deliberately NOT a whole-file hash
# (docs-agent-pipeline-v2.md §7 R2-F2: a whole-file hash over-triggers on
# any edit to a large file and trains the reader to ignore the signal).
#
# Usage:
#   logic-stale-check.sh <receipts-file> <repo-root>
#
# Exit 0 + "FRESH": no cited span overlaps a change since extraction.commit.
# Exit 1: one "LOGIC-STALE: <file>:<start>-<end> (rule <n>)" line per hit.
#   Changed closure files with no cited-span overlap are printed as "note:"
#   lines only (never LOGIC-STALE) — R2-F2's over-triggering fix.
# Exit 2 + "STALE-CHECK-UNAVAILABLE: <reason>": extraction.commit is
#   unreachable (squashed, rebased, shallow clone) or a usage error. Per
#   ADR-025, an unavailable check must NEVER be reported as fresh — this is
#   why exit 2 is a distinct code from both 0 (fresh) and 1 (stale).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "STALE-CHECK-UNAVAILABLE: jq not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "STALE-CHECK-UNAVAILABLE: python3 not found" >&2; exit 2; }

RECEIPTS_FILE="${1:-}"
REPO_ROOT="${2:-}"

if [[ -z "$RECEIPTS_FILE" || -z "$REPO_ROOT" ]]; then
  echo "usage: logic-stale-check.sh <receipts-file> <repo-root>" >&2
  exit 2
fi
[[ -f "$RECEIPTS_FILE" ]] || { echo "STALE-CHECK-UNAVAILABLE: receipts file not found: $RECEIPTS_FILE" >&2; exit 2; }
[[ -d "$REPO_ROOT" ]] || { echo "STALE-CHECK-UNAVAILABLE: repo-root not found: $REPO_ROOT" >&2; exit 2; }

COMMIT="$(jq -r '.extraction.commit // empty' "$RECEIPTS_FILE" 2>/dev/null)"
if [[ -z "$COMMIT" ]]; then
  echo "STALE-CHECK-UNAVAILABLE: receipts file has no extraction.commit (schema-invalid or absent extraction section)" >&2
  exit 2
fi

# Unreachable-commit check per Contract B — cat-file -e, not rev-parse
# (rev-parse can succeed on a syntactically valid but unresolvable ref).
if ! git -C "$REPO_ROOT" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  echo "STALE-CHECK-UNAVAILABLE: extraction.commit $COMMIT is unreachable in $REPO_ROOT (squashed, rebased, or shallow clone)" >&2
  exit 2
fi

# Distinct span files, each with its list of [start,end,rule] spans.
SPAN_FILES="$(jq -r '.extraction.spans[]?.file' "$RECEIPTS_FILE" 2>/dev/null | sort -u)"
if [[ -z "$SPAN_FILES" ]]; then
  echo "FRESH"
  exit 0
fi

STALE_LINES=""
NOTE_LINES=""

while IFS= read -r span_file; do
  [[ -n "$span_file" ]] || continue

  # Span-file deletion/rename detection: cat-file -e against HEAD, not a
  # `git diff` heuristic (a rename-away is not reliably visible in a
  # path-scoped diff). Fail safe: missing at HEAD -> LOGIC-STALE.
  if ! git -C "$REPO_ROOT" cat-file -e "HEAD:${span_file}" 2>/dev/null; then
    while IFS= read -r span; do
      [[ -n "$span" ]] || continue
      start="$(echo "$span" | jq -r '.start')"
      end="$(echo "$span" | jq -r '.end')"
      rule="$(echo "$span" | jq -r '.rule')"
      STALE_LINES="${STALE_LINES}LOGIC-STALE: ${span_file}:${start}-${end} (rule ${rule}) [span file deleted or renamed]"$'\n'
    done < <(jq -c --arg f "$span_file" '.extraction.spans[] | select(.file == $f)' "$RECEIPTS_FILE")
    continue
  fi

  DIFF_OUT="$(git -C "$REPO_ROOT" diff --unified=0 "${COMMIT}..HEAD" -- "$span_file" 2>/dev/null)"
  [[ -z "$DIFF_OUT" ]] && continue  # file unchanged since extraction

  # Parse old-side hunk ranges: "@@ -a[,b] +c[,d] @@". Git omits ",b" when
  # b == 1 (a single-line hunk) — NOT when b == 0. A regex that assumes the
  # comma is always present silently drops single-line-change hunks and
  # would report FRESH on a real change (an ADR-025 fail-open bug).
  CHANGED_RANGES="$(echo "$DIFF_OUT" | grep -E '^@@ -[0-9]+' | \
    python3 -c '
import re, sys
pat = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+")
for line in sys.stdin:
    m = pat.match(line)
    if not m:
        continue
    a = int(m.group(1))
    b = int(m.group(2)) if m.group(2) is not None else 1
    if b == 0:
        # Pure insertion at a: touches the boundary between a and a+1.
        print(f"{a} {a+1}")
    else:
        print(f"{a} {a + b - 1}")
')"

  ANY_OVERLAP=0
  while IFS= read -r span; do
    [[ -n "$span" ]] || continue
    start="$(echo "$span" | jq -r '.start')"
    end="$(echo "$span" | jq -r '.end')"
    rule="$(echo "$span" | jq -r '.rule')"
    span_hit=0
    while IFS=' ' read -r ca cb; do
      [[ -n "$ca" ]] || continue
      # Overlap test: [ca,cb] intersects [start,end].
      if (( ca <= end && cb >= start )); then
        span_hit=1
        break
      fi
    done <<< "$CHANGED_RANGES"
    if [[ "$span_hit" -eq 1 ]]; then
      STALE_LINES="${STALE_LINES}LOGIC-STALE: ${span_file}:${start}-${end} (rule ${rule})"$'\n'
      ANY_OVERLAP=1
    fi
  done < <(jq -c --arg f "$span_file" '.extraction.spans[] | select(.file == $f)' "$RECEIPTS_FILE")

  if [[ "$ANY_OVERLAP" -eq 0 ]]; then
    NOTE_LINES="${NOTE_LINES}note: ${span_file} changed since ${COMMIT}, but no cited span overlaps"$'\n'
  fi
done <<< "$SPAN_FILES"

if [[ -n "$NOTE_LINES" ]]; then
  printf '%s' "$NOTE_LINES"
fi

if [[ -n "$STALE_LINES" ]]; then
  printf '%s' "$STALE_LINES"
  exit 1
fi

echo "FRESH"
exit 0
