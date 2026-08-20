#!/usr/bin/env bash
# Runs a real, deterministic usage search for one target (file path or
# symbol), prints a human report, then a machine-readable result line the
# usage-check minting hook (hooks/usage-check-token.sh) observes. Never
# writes a token itself — that is the hook's job, from a trusted vantage
# point the agent invoking this script does not control. ADR-057.
#
# Exit 0 on any COMPLETED check, including a "used" or "unused" verdict —
# a clean negative result is a legitimate, valuable answer, not a failure.
# Exit 2 only when the check could not even be attempted (bad target).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib/usage-check-common.sh"

TARGET_RAW=""
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_RAW="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "usage: usage-check.sh --target <path|symbol:Name> [--repo <dir>]" >&2; exit 2 ;;
  esac
done

if [[ -z "$TARGET_RAW" ]]; then
  echo "usage-check: --target is required" >&2
  exit 2
fi

if [[ "$TARGET_RAW" == symbol:* ]]; then
  KIND="symbol"
  TARGET="$(uc_normalize_target symbol "$TARGET_RAW")"
else
  KIND="file"
  TARGET="$(uc_normalize_target file "$TARGET_RAW")"
  if [[ ! -e "$REPO/$TARGET" ]]; then
    echo "usage-check: target file '$TARGET' does not exist under $REPO" >&2
    exit 2
  fi
fi

HEAD_COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "no-git")"

# Derive the search pattern deterministically. As of commit c03af68, the gate
# no longer replays this exact string from the token at re-verification time
# — it invokes this checker fresh (same --target, same --repo) and compares
# verdicts, so the token's recorded search.* fields are write-only audit
# data, not something read back and replayed. This derivation is still the
# single source of truth for "what does checking this target actually mean",
# because the gate's fresh invocation runs this same derivation again.
if [[ "$KIND" == "symbol" ]]; then
  RAW_SYMBOL="${TARGET#symbol:}"
  PATTERN_BODY="$(printf '%s' "$RAW_SYMBOL" | sed -E 's/[.[\*^$()+?{}|\\]/\\&/g')"
else
  BASENAME="$(basename "$TARGET")"
  STEM="${BASENAME%.*}"
  PATTERN_BODY="$(printf '%s' "$STEM" | sed -E 's/[.[\*^$()+?{}|\\]/\\&/g')"
fi
PATTERN="\\b${PATTERN_BODY}\\b"

SEARCH_TOOL=""
MATCH_FILES=""
if command -v rg >/dev/null 2>&1; then
  SEARCH_TOOL="rg"
  MATCH_FILES="$(cd "$REPO" && rg -l --hidden --glob '!.git' -e "$PATTERN" . 2>/dev/null || true)"
else
  SEARCH_TOOL="grep"
  MATCH_FILES="$(cd "$REPO" && grep -rlE --exclude-dir=.git -e "$PATTERN" . 2>/dev/null || true)"
fi

# Drop the target file itself from results (a file always "contains itself").
if [[ "$KIND" == "file" ]]; then
  MATCH_FILES="$(echo "$MATCH_FILES" | grep -v -E "^(\./)?${TARGET//\//\\/}$" || true)"
fi
MATCH_FILES="$(echo "$MATCH_FILES" | sed '/^$/d')"
MATCH_COUNT="$(echo "$MATCH_FILES" | sed '/^$/d' | wc -l | tr -d ' ')"
MATCHED_JSON="$(echo "$MATCH_FILES" | sed '/^$/d' | head -50 | jq -R . | jq -sc .)"

# Advisory graphify consult (ADR-054) — zero-cost local lookup, never trusted
# alone. A negative graphify result never overrides a real grep.
GRAPHIFY_JSON='{"consulted":false}'
if [[ -f "$REPO/.claude/graphify/receipt.json" ]] && command -v graphify >/dev/null 2>&1; then
  EDGES="$(cd "$REPO" && graphify query "$TARGET" 2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)"
  [[ "$EDGES" =~ ^[0-9]+$ ]] || EDGES=0
  GRAPHIFY_JSON="$(jq -nc --argjson e "$EDGES" '{consulted:true, edges_found:$e}')"
fi
GRAPHIFY_POSITIVE=0
[[ "$(echo "$GRAPHIFY_JSON" | jq -r '.consulted')" == "true" && "$(echo "$GRAPHIFY_JSON" | jq -r '.edges_found')" -gt 0 ]] && GRAPHIFY_POSITIVE=1

if [[ "$KIND" == "symbol" ]]; then
  if [[ "$MATCH_COUNT" -le 1 ]]; then
    if [[ "$GRAPHIFY_POSITIVE" -eq 1 ]]; then
      VERDICT="indeterminate"
    else
      VERDICT="unused"
    fi
  else
    VERDICT="used"
  fi
else
  if [[ "$MATCH_COUNT" -ge 1 ]]; then
    VERDICT="used"
  elif [[ "$GRAPHIFY_POSITIVE" -eq 1 ]]; then
    VERDICT="indeterminate"
  else
    VERDICT="unused"
  fi
fi

EXCLUDED_TARGET=""
[[ "$KIND" == "file" ]] && EXCLUDED_TARGET="$TARGET"

RESULT_JSON="$(jq -nc \
  --arg schema "usage-check-result/v1" \
  --arg target "$TARGET" \
  --arg kind "$KIND" \
  --arg repo_root "$REPO" \
  --arg head "$HEAD_COMMIT" \
  --arg tool "$SEARCH_TOOL" \
  --arg pattern "$PATTERN" \
  --arg excluded "$EXCLUDED_TARGET" \
  --argjson match_count "$MATCH_COUNT" \
  --argjson matched_files "$MATCHED_JSON" \
  --argjson graph_hint "$GRAPHIFY_JSON" \
  --arg verdict "$VERDICT" \
  '{schema:$schema, target:$target, target_kind:$kind, repo_root:$repo_root,
    head_commit:$head,
    search:{tool:$tool, pattern:$pattern, search_root:".", excluded_target:$excluded,
            match_count:$match_count, matched_files:$matched_files},
    graph_hint:$graph_hint, verdict:$verdict}')"

echo "usage-check: target=$TARGET kind=$KIND verdict=$VERDICT matches=$MATCH_COUNT tool=$SEARCH_TOOL"
if [[ "$MATCH_COUNT" -gt 0 ]]; then
  echo "usage-check: referenced from:"
  # Capped to match the JSON's matched_files cap (:50) — the report is for a
  # human to skim, not an exhaustive listing. An uncapped list on a common
  # symbol (e.g. "the") can run tens of thousands of bytes, risking
  # truncation of the machine-readable USAGE_CHECK_RESULT line that MUST be
  # the last line of stdout for the minting hook to see it. MATCH_COUNT
  # above is always the true total, never capped.
  echo "$MATCH_FILES" | head -50 | sed 's/^/  /'
  if [[ "$MATCH_COUNT" -gt 50 ]]; then
    echo "  ... and $((MATCH_COUNT - 50)) more"
  fi
fi
echo "USAGE_CHECK_RESULT:v1 $(printf '%s' "$RESULT_JSON" | base64 | tr -d '\n')"
exit 0
