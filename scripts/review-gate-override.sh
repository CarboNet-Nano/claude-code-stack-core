#!/usr/bin/env bash
# scripts/review-gate-override.sh — HUMAN-ONLY. ADR-087 D9.
#
# Writes a review-gate override: either a per-repo, single-use bypass (the
# default) or a machine-wide disable (--machine). Both destinations live
# under state/attest/override/**, which the managed floor's denyWrite list
# protects (D14) -- the actual boundary. This script's CLAUDECODE guard below
# is advisory and spoofable (ADR-086 D7 states the same for update.sh): a
# model that spoofs it gets a script that dies at its first write, exactly
# what happens to update.sh today. The guard's entire value is legibility.
#
# Usage:
#   scripts/review-gate-override.sh --reason "<why>" [--machine]
#
#   (default)   writes <conf>/state/attest/override/repo-once/<repo_hash>.json
#               for the CURRENT repo (cwd), consumed exactly once by the gate.
#   --machine   writes <conf>/state/attest/override/review-gate.disabled,
#               honored until removed.
#
# Sanctioned entry points: a human in a real terminal only (ADR-071 D15 #3).
# Never the Bash tool.
set -euo pipefail

# ADR-086 D7-style advisory guard. Trivially spoofable; the real boundary is
# the denyWrite layer under state/attest/**, which denies these writes from
# the Bash tool's process tree regardless of env vars.
if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
  echo "Refused: review-gate-override.sh cannot run from inside a Claude Code session's Bash tool." >&2
  echo "ADR-071 D15 #3 / ADR-087 D9: HUMAN-ONLY. Run this from a real terminal." >&2
  exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECEIPT_LIB="$SCRIPT_DIR/../lib/receipt.sh"
[[ -f "$RECEIPT_LIB" ]] || RECEIPT_LIB="$HOME/.claude/lib/receipt.sh"
# shellcheck source=/dev/null
source "$RECEIPT_LIB"

REASON=""
MACHINE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="${2:-}"; shift 2 ;;
    --machine) MACHINE=1; shift ;;
    *) echo "Usage: $0 --reason \"<why>\" [--machine]" >&2; exit 2 ;;
  esac
done

if [[ -z "$REASON" ]]; then
  echo "Usage: $0 --reason \"<why>\" [--machine]" >&2
  exit 2
fi

SAN_REASON="$(rcpt_sanitize "$REASON" 200)"
CONF_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
OVERRIDE_DIR="$CONF_DIR/state/attest/override"

if [[ "$MACHINE" -eq 1 ]]; then
  mkdir -p "$OVERRIDE_DIR"
  printf '%s\n' "$SAN_REASON" > "$OVERRIDE_DIR/review-gate.disabled"
  echo "Machine-wide review-gate disable written: $OVERRIDE_DIR/review-gate.disabled"
  echo "reason: $SAN_REASON"
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$REPO_ROOT" ]]; then
  echo "review-gate-override.sh: not inside a git repository (repo-once override needs a repo_hash)." >&2
  exit 4
fi
REPO_HASH="$(shasum -a 256 <<<"$REPO_ROOT" | cut -c1-12)"

mkdir -p "$OVERRIDE_DIR/repo-once"
OVFILE="$OVERRIDE_DIR/repo-once/${REPO_HASH}.json"
jq -nc --arg reason "$SAN_REASON" '{reason:$reason}' > "$OVFILE"
echo "Per-repo, single-use review-gate override written: $OVFILE"
echo "repo: $REPO_ROOT"
echo "reason: $SAN_REASON"
echo "This bypasses the NEXT denied dispatch/PR-create once, then is consumed."
