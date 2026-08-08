#!/usr/bin/env bash
# logic-parity-gate.sh — docs-agent-pipeline-v2 §2.1 + §2.3 (Phase 5a).
#
# Adversarial parity check for a logic-extraction doc: an independent
# reviewer (Gemini, via scripts/lib/gemini-api.sh) is given the doc PLUS the
# entry point's producer-independent evidence closure (computed by
# tools/user-docs/src/logic-evidence.mjs — never the producer's own
# self-reported source list) and asked to find a counterexample.
#
# Fixes applied here (see docs/proposals/2026-07-30-docs-agent-pipeline-v2.md):
#   - §2.1: evidence set is closure ∪ declared-sources, not producer-selected.
#     A closure file missing from declared-sources is reported as
#     SOURCES-INCOMPLETE (blocking) before the parity call is even made.
#   - §2.3: payload size is preflighted against GMN_MAX_INPUT_BYTES BEFORE
#     calling gmn_call. gemini-api.sh silently truncates oversized input
#     (line ~102-103) rather than erroring — letting that truncation reach
#     the parity gate would risk a false PASSED on an incompletely-reviewed
#     doc (the exact ADR-025 fail-open class). This script fails loudly with
#     PAYLOAD_TOO_LARGE instead.
#   - §2.3: uses a dedicated parity prompt/contract (PASSED | FAILED:
#     counterexample <input>), NOT agents/red-team.md's security-diff prompt.
#
# Usage:
#   logic-parity-gate.sh <logic-doc-file> <entry-file> <repo-root> [declared-source-1,declared-source-2,...]
#
# declared-sources: comma-separated, repo-relative paths — the producer's
# logicMeta.sources[].file list. Extracting that list from the doc's YAML
# front matter is the CALLER's job (the dispatching skill procedure), not
# this script's — kept out to avoid a YAML-parser dependency in Phase 5a.
#
# Exit 0 + "PASSED" on stdout: doc survived the adversarial check.
# Exit 1 + "FAILED: counterexample <...>" on stdout: parity gate caught a
#   real discrepancy.
# Exit 1 + "SOURCES-INCOMPLETE: <files>" on stdout: closure has files the
#   producer didn't cite — must be resolved before a parity call is made.
# Exit 2: usage error, missing files, or PAYLOAD_TOO_LARGE.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_SCRIPT="$DIR/../tools/user-docs/src/logic-evidence.mjs"

LOGIC_DOC="${1:-}"
ENTRY_FILE="${2:-}"
REPO_ROOT="${3:-}"
DECLARED_SOURCES_CSV="${4:-}"

if [[ -z "$LOGIC_DOC" || -z "$ENTRY_FILE" || -z "$REPO_ROOT" ]]; then
  echo "usage: logic-parity-gate.sh <logic-doc-file> <entry-file> <repo-root> [declared-sources-csv]" >&2
  exit 2
fi
[[ -f "$LOGIC_DOC" ]] || { echo "logic-parity-gate: doc not found: $LOGIC_DOC" >&2; exit 2; }
[[ -f "$ENTRY_FILE" ]] || { echo "logic-parity-gate: entry file not found: $ENTRY_FILE" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "logic-parity-gate: node not found" >&2; exit 2; }

CLOSURE_JSON="$(node "$EVIDENCE_SCRIPT" "$ENTRY_FILE" "$REPO_ROOT" 2>/dev/null)"
if [[ -z "$CLOSURE_JSON" ]]; then
  echo "logic-parity-gate: evidence closure computation failed" >&2
  exit 2
fi

# ── SOURCES-INCOMPLETE check (§2.1) ─────────────────────────────────────────
declare -a CLOSURE_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && CLOSURE_FILES+=("$f")
done < <(echo "$CLOSURE_JSON" | jq -r '.[]' 2>/dev/null)

# Portable (bash 3.2 / macOS default has no associative arrays): wrap the CSV
# in delimiters and substring-match each closure file against it.
DECLARED_WRAPPED=",${DECLARED_SOURCES_CSV},"

MISSING=()
for f in "${CLOSURE_FILES[@]}"; do
  case "$DECLARED_WRAPPED" in
    *",${f},"*) : ;;  # declared — no-op
    *) MISSING+=("$f") ;;
  esac
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "SOURCES-INCOMPLETE: ${MISSING[*]}"
  exit 1
fi

# ── Assemble payload + preflight size (§2.3) ────────────────────────────────
DOC_CONTENT="$(cat "$LOGIC_DOC")"
CLOSURE_CONTENT=""
for f in "${CLOSURE_FILES[@]}"; do
  abs="$REPO_ROOT/$f"
  [[ -f "$abs" ]] || continue
  CLOSURE_CONTENT+=$'\n\n--- '"$f"$' ---\n'"$(cat "$abs")"
done

PARITY_PROMPT='You are an adversarial logic-parity checker. You will be given a logic-extraction
document (a plain-language + Mermaid + "if X then Y" explanation of what some
source code computes) followed by the ACTUAL source code it claims to
describe. Your ONLY job: find an input for which the documented logic and the
code disagree — a branch condition, evaluation order, rounding rule,
precedence, cap, floor, or default the doc gets wrong or omits.

Respond with EXACTLY one of:
  PASSED
  FAILED: counterexample <describe the specific input and how doc vs code diverge>

Do not soften a real discrepancy. Do not invent one that is not really there.'

FULL_PAYLOAD="${PARITY_PROMPT}"$'\n\n--- LOGIC DOC ---\n'"${DOC_CONTENT}"$'\n\n--- SOURCE (evidence closure) ---'"${CLOSURE_CONTENT}"

GMN_MAX_INPUT_BYTES="${GMN_MAX_INPUT_BYTES:-700000}"
if (( ${#FULL_PAYLOAD} > GMN_MAX_INPUT_BYTES )); then
  echo "PAYLOAD_TOO_LARGE: assembled payload is ${#FULL_PAYLOAD} bytes, exceeds GMN_MAX_INPUT_BYTES=${GMN_MAX_INPUT_BYTES}. Refusing to call the parity gate — gemini-api.sh would silently truncate input rather than erroring, which could produce a false PASSED on an incompletely-reviewed doc. Narrow the evidence closure or split the logic unit." >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$DIR/lib/gemini-api.sh" 2>/dev/null || { echo "logic-parity-gate: could not source gemini-api.sh" >&2; exit 2; }

if ! gmn_available; then
  echo "logic-parity-gate: Gemini API unavailable (no key) — cannot run the parity gate" >&2
  exit 2
fi

RESULT="$(gmn_call "$PARITY_PROMPT" <<<"$FULL_PAYLOAD")"

if [[ "$RESULT" == PASSED* ]]; then
  echo "PASSED"
  exit 0
elif [[ "$RESULT" == FAILED:* ]]; then
  echo "$RESULT"
  exit 1
else
  echo "logic-parity-gate: unexpected model response, treating as FAILED (fail-closed): $RESULT" >&2
  echo "FAILED: counterexample unparseable-response"
  exit 1
fi
