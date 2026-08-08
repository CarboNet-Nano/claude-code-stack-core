#!/usr/bin/env bash
# Standalone deltas-only lint for pack-repo CI.
# Usage: pack-lint.sh <pack_dir> [<core_repo_root>]
# Core root defaults to this script's own repo.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <pack_dir> [<core_repo_root>]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACK_DIR="$(cd "$1" && pwd)"
CORE_ROOT="${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"

source "$SCRIPT_DIR/lib/pack-lint.sh"

if lint_pack_deltas "$PACK_DIR" "$CORE_ROOT"; then
  echo "pack-lint: OK — $PACK_DIR ships deltas only"
else
  exit 1
fi
