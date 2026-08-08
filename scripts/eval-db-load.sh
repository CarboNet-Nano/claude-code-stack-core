#!/usr/bin/env bash
# Load model_eval rows from the append-only log into the SQLite eval datastore.
# ADR-059. The log is the source of truth; this database is a derived, rebuildable view.
#
# Idempotent: re-running inserts nothing new and changes no existing row. That property
# is what makes "drop it and reload" a safe recovery, so it is asserted by
# tests/test-eval-datastore.sh rather than assumed.
#
# Usage:
#   scripts/eval-db-load.sh                  # load into ~/.claude/eval.db
#   scripts/eval-db-load.sh --db /tmp/x.db   # load elsewhere (tests use this)
#   scripts/eval-db-load.sh --log path.jsonl # read a different log
#   scripts/eval-db-load.sh --rebuild        # drop and recreate before loading

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$REPO_ROOT/schemas/005-model-eval.sql"
DB="${HOME}/.claude/eval.db"
LOG="${HOME}/.claude/logs/subagent-runs.jsonl"
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)      DB="$2"; shift 2 ;;
    --log)     LOG="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || { echo "eval-db-load: sqlite3 not found" >&2; exit 3; }
command -v jq      >/dev/null 2>&1 || { echo "eval-db-load: jq not found" >&2; exit 3; }
[[ -f "$SCHEMA" ]] || { echo "eval-db-load: schema missing at $SCHEMA" >&2; exit 3; }

# A missing log is not an error (nothing has been measured yet); an unreadable one is.
if [[ ! -f "$LOG" ]]; then
  echo "eval-db-load: no log at $LOG — nothing to load"; exit 0
fi

mkdir -p "$(dirname "$DB")"
[[ $REBUILD -eq 1 ]] && rm -f "$DB"
sqlite3 "$DB" < "$SCHEMA" || { echo "eval-db-load: schema apply failed" >&2; exit 4; }

BEFORE="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM model_eval;' 2>/dev/null || echo 0)"

# Build INSERT statements. Two things worth noting:
#
#  1. `rep` is assigned per cell in log order, so repetitions of an identical config
#     land as distinct rows instead of colliding on the UNIQUE key. Without it a reload
#     would silently discard the variance data.
#  2. INSERT OR IGNORE against the UNIQUE key is what makes the load idempotent — a
#     second run re-derives the same natural keys and every insert is a no-op.
#
# Empty-string defaults (not NULL) on the key columns are deliberate: both SQLite and
# Postgres treat NULLs in a UNIQUE index as distinct from each other, so a NULL key
# column would let duplicates through on every re-run.
SQL="$(jq -r '
  select(.event == "model_eval")
  | [ (.ts // ""), (.project // ""), (.run_id // ""), (.agent // ""), (.task_id // ""),
      (.executor_model // ""), (.advisor_model // ""), (.effort // ""), (.arm // ""),
      (.harness // ""), (.judge // ""),
      (.score_correctness // -1), (.score_completeness // -1), (.score_edge // -1),
      (.check // ""), (if .passed == null then -1 elif .passed then 1 else 0 end),
      (.tokens // 0), (.cache_read_tokens // 0), (.cache_creation_tokens // 0), (.wall_ms // 0)
    ] | @tsv
' "$LOG" 2>/dev/null | awk -F'\t' '
  function q(s) { gsub(/'"'"'/, "'"'"''"'"'", s); return "'"'"'" s "'"'"'" }
  function nn(v) { return (v == -1 || v == "") ? "NULL" : v }
  {
    cell = $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
    rep[cell]++
    printf "INSERT OR IGNORE INTO model_eval (ts,project,run_id,agent,task_id,executor_model,advisor_model,effort,arm,harness,judge,score_correctness,score_completeness,score_edge,check_name,passed,tokens,cache_read_tokens,cache_creation_tokens,wall_ms,rep) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d);\n", \
      q($1), q($2), q($3), q($4), q($5), q($6), q($7), q($8), q($9), q($10), q($11), \
      nn($12), nn($13), nn($14), q($15), nn($16), $17, $18, $19, $20, rep[cell]
  }
')"

if [[ -z "$SQL" ]]; then
  echo "eval-db-load: no model_eval rows in $LOG"; exit 0
fi

printf 'BEGIN;\n%s\nCOMMIT;\n' "$SQL" | sqlite3 "$DB" || {
  echo "eval-db-load: insert failed" >&2; exit 5; }

AFTER="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM model_eval;')"
echo "eval-db-load: $DB — ${BEFORE} -> ${AFTER} rows (+$((AFTER-BEFORE)))"
