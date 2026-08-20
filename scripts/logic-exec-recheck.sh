#!/usr/bin/env bash
# logic-exec-recheck.sh — ADR-050 Contract C / D5's EXEC-DRIFT signal.
#
# Re-runs the committed harness and compares its LOGIC-EXAMPLE outputs
# (D6's harness output contract) against the values already recorded in the
# receipts. Zero LLM tokens, zero vision — runs regardless of hash state
# (docs-agent-pipeline-v2.md §7 red-team #4).
#
# Usage:
#   logic-exec-recheck.sh <receipts-file> <repo-root>
#
# Exit 0 + "EXEC-FRESH": harness re-ran clean and every example matched.
#   Calls logic-receipt.sh update-execution to bump lastRunAt/lastRunCommit.
#   This script NEVER writes the receipts file itself otherwise.
# Exit 1 + "HARNESS-CHANGED: ...": harness.hash no longer matches the
#   committed file. Remedy is a full gate re-run, not a recheck.
# Exit 1 + one "EXEC-DRIFT: <id> expected <json> got <json>" line per
#   mismatching example.
# Exit 2 + "HARNESS-UNRUNNABLE: <reason>": harness command failed, or
#   printed zero LOGIC-EXAMPLE lines. Never reported as EXEC-DRIFT — a
#   harness that cannot run says nothing about whether the logic drifted.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "HARNESS-UNRUNNABLE: jq not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "HARNESS-UNRUNNABLE: python3 not found" >&2; exit 2; }

RECEIPTS_FILE="${1:-}"
REPO_ROOT="${2:-}"

if [[ -z "$RECEIPTS_FILE" || -z "$REPO_ROOT" ]]; then
  echo "usage: logic-exec-recheck.sh <receipts-file> <repo-root>" >&2
  exit 2
fi
[[ -f "$RECEIPTS_FILE" ]] || { echo "HARNESS-UNRUNNABLE: receipts file not found: $RECEIPTS_FILE" >&2; exit 2; }
[[ -d "$REPO_ROOT" ]] || { echo "HARNESS-UNRUNNABLE: repo-root not found: $REPO_ROOT" >&2; exit 2; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS_PATH="$(jq -r '.harness.path // empty' "$RECEIPTS_FILE" 2>/dev/null)"
HARNESS_HASH="$(jq -r '.harness.hash // empty' "$RECEIPTS_FILE" 2>/dev/null)"
HARNESS_COMMAND="$(jq -r '.harness.command // empty' "$RECEIPTS_FILE" 2>/dev/null)"

if [[ -z "$HARNESS_PATH" || -z "$HARNESS_HASH" || -z "$HARNESS_COMMAND" ]]; then
  echo "HARNESS-UNRUNNABLE: receipts file has no harness section (schema-invalid or absent)" >&2
  exit 2
fi

# ── Step 1: hash-mismatch check ─────────────────────────────────────────────
if [[ ! -f "$REPO_ROOT/$HARNESS_PATH" ]]; then
  echo "HARNESS-UNRUNNABLE: harness file not found: $HARNESS_PATH" >&2
  exit 2
fi
CURRENT_HASH="$(git -C "$REPO_ROOT" hash-object "$HARNESS_PATH" 2>/dev/null)"
if [[ -z "$CURRENT_HASH" ]]; then
  echo "HARNESS-UNRUNNABLE: could not hash $HARNESS_PATH" >&2
  exit 2
fi
if [[ "$CURRENT_HASH" != "$HARNESS_HASH" ]]; then
  echo "HARNESS-CHANGED: $HARNESS_PATH hash is $CURRENT_HASH, receipts recorded $HARNESS_HASH — run the full gate, not a recheck"
  exit 1
fi

# ── Step 2: run the harness, capture stdout and stderr SEPARATELY ───────────
# Only stdout is parsed for LOGIC-EXAMPLE lines (per the D6 contract's own
# wording, "emit, on stdout") — a harness that echoes example-shaped text to
# stderr for debugging must not spuriously satisfy the "harness produced
# output" check.
HARNESS_ERR_FILE="$(mktemp)"
trap 'rm -f "$HARNESS_ERR_FILE"' EXIT
HARNESS_OUT="$(cd "$REPO_ROOT" && eval "$HARNESS_COMMAND" 2>"$HARNESS_ERR_FILE")"
HARNESS_RC=$?

# ── Step 3: collect LOGIC-EXAMPLE lines (D6 contract) ───────────────────────
EXAMPLE_LINES="$(printf '%s\n' "$HARNESS_OUT" | grep -E '^LOGIC-EXAMPLE \{.*\}$' || true)"

if [[ $HARNESS_RC -ne 0 ]]; then
  echo "HARNESS-UNRUNNABLE: harness command exited $HARNESS_RC: $HARNESS_COMMAND" >&2
  echo "$HARNESS_OUT" >&2
  cat "$HARNESS_ERR_FILE" >&2
  exit 2
fi
if [[ -z "$EXAMPLE_LINES" ]]; then
  echo "HARNESS-UNRUNNABLE: harness printed zero LOGIC-EXAMPLE lines (ADR-050 D6 contract) — never treated as a silent pass" >&2
  exit 2
fi

HARNESS_JSON_FILE="$(mktemp)"
EXPECTED_JSON_FILE="$(mktemp)"
trap 'rm -f "$HARNESS_JSON_FILE" "$EXPECTED_JSON_FILE"' EXIT
printf '%s\n' "$EXAMPLE_LINES" | sed -E 's/^LOGIC-EXAMPLE //' > "$HARNESS_JSON_FILE"

# ── Step 4: compare against receipts.execution.examples[] ───────────────────
jq -c '.execution.examples // []' "$RECEIPTS_FILE" > "$EXPECTED_JSON_FILE"

DRIFT_LINES="$(python3 - "$EXPECTED_JSON_FILE" "$HARNESS_JSON_FILE" <<'PYEOF'
import json, sys

expected_path, harness_path = sys.argv[1], sys.argv[2]
with open(expected_path) as f:
    expected = json.load(f)

actual_by_id = {}
with open(harness_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        actual_by_id[obj["id"]] = obj["output"]

def canon(v):
    return json.dumps(v, sort_keys=True, separators=(",", ":"))

drift = []
for ex in expected:
    eid = ex["id"]
    exp_out = ex.get("output")
    if eid not in actual_by_id:
        drift.append(f"EXEC-DRIFT: {eid} expected {canon(exp_out)} got <no LOGIC-EXAMPLE line for this id>")
        continue
    act_out = actual_by_id[eid]
    if canon(exp_out) != canon(act_out):
        drift.append(f"EXEC-DRIFT: {eid} expected {canon(exp_out)} got {canon(act_out)}")

print("\n".join(drift))
PYEOF
)"

if [[ -n "$DRIFT_LINES" ]]; then
  printf '%s\n' "$DRIFT_LINES"
  exit 1
fi

echo "EXEC-FRESH"
bash "$DIR/logic-receipt.sh" update-execution "$RECEIPTS_FILE" --repo-root "$REPO_ROOT" >&2
exit 0
