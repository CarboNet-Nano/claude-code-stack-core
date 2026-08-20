#!/usr/bin/env bash
# Test: backup.sh copies stack config/source but skips regenerable bulk.
#
# install.sh runs backup.sh on every install. Without the exclude list the
# snapshot was 2.6G on a real machine, almost all of it chat transcripts and
# dependency trees no restore would want. This test fails if that returns.

set -euo pipefail

BACKUP="$(cd "$(dirname "$0")/.." && pwd)/scripts/backup.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

CLAUDE="$TMP/.claude"

# Paths a restore genuinely needs.
KEEP=(
  settings.json
  CLAUDE.md
  config/behavior-matrix.json
  skills/example/SKILL.md
  hooks/session-start.sh
  commands/example.md
  agents/example.md
  lib/helper.sh
  scripts/install.sh
  templates/job-spec.md
  schemas/006-roles.sql
  tools/pm/bin.mjs
)

# Paths that are regenerable and must not be copied.
DROP=(
  projects/some-repo/transcript.jsonl
  plugins/vendor/index.js
  jobs/run-1/output.json
  logs/debug.log
  file-history/old.txt
  downloads/blob.bin
  tools/pm/node_modules/dep/index.js
  tools/graphify/.venv/bin/python
)

for p in "${KEEP[@]}" "${DROP[@]}"; do
  mkdir -p "$CLAUDE/$(dirname "$p")"
  echo "content" > "$CLAUDE/$p"
done

HOME="$TMP" bash "$BACKUP" > "$TMP/out.txt" 2>&1 || {
  echo "FAIL: backup.sh exited non-zero"
  cat "$TMP/out.txt"
  exit 1
}

backup_dir="$(ls -d "$TMP"/.claude.backup.* 2>/dev/null | head -1)"
[[ -d "$backup_dir" ]] || { echo "FAIL: no backup directory created"; exit 1; }

fail=0

for p in "${KEEP[@]}"; do
  if [[ ! -f "$backup_dir/$p" ]]; then
    echo "FAIL: $p missing from backup — a restore would lose it"
    fail=1
  fi
done

for p in "${DROP[@]}"; do
  if [[ -e "$backup_dir/$p" ]]; then
    echo "FAIL: $p was copied — regenerable bulk is back in the snapshot"
    fail=1
  fi
done

[[ $fail -eq 0 ]] || exit 1

echo "PASS: backup keeps ${#KEEP[@]} stack paths, skips ${#DROP[@]} regenerable ones"
