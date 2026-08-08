-- Eval datastore (ADR-059). One row per (agent, config, task, repetition).
--
-- Engine: SQLite (~/.claude/eval.db). Types are deliberately restricted to
-- TEXT / INTEGER / REAL and timestamps are ISO-8601 strings, so `.dump` loads into
-- Postgres with only the CREATE TABLE header changed. Do NOT introduce SQLite-only
-- types or expressions — the migration path to Guardian depends on this staying
-- portable (ADR-059 § Migration to Guardian).
--
-- The append-only log (~/.claude/logs/subagent-runs.jsonl) remains the source of
-- truth. This database is a derived, rebuildable view: drop it, reload, get the same
-- rows. Never hand-edit it.

CREATE TABLE IF NOT EXISTS model_eval (
  id                    INTEGER PRIMARY KEY,

  -- provenance
  ts                    TEXT    NOT NULL,   -- ISO-8601 UTC
  project               TEXT,
  run_id                TEXT    NOT NULL DEFAULT '',  -- groups one sweep; '' for ungrouped rows
  agent                 TEXT    NOT NULL,
  task_id               TEXT    NOT NULL,

  -- the configuration under test
  executor_model        TEXT    NOT NULL,
  advisor_model         TEXT    NOT NULL DEFAULT '',  -- '' when no advisor was paired
  effort                TEXT    NOT NULL DEFAULT '',  -- low|medium|high|xhigh|max; '' if n/a
  arm                   TEXT,               -- lowered|baseline|bumped, when part of an effort sweep

  -- how it was measured
  harness               TEXT,               -- 'agent' (real dispatch) | 'api' (direct call)
  judge                 TEXT,               -- openai | gemini | deterministic-code-inspection

  -- scored rows (NULL when the check was deterministic instead)
  score_correctness     INTEGER,
  score_completeness    INTEGER,
  score_edge            INTEGER,

  -- deterministic rows (NULL when the row was scored instead)
  check_name            TEXT,               -- e.g. race_free_exactly_once
  passed                INTEGER,            -- 0/1

  -- cost
  tokens                INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  wall_ms               INTEGER,

  -- repetition index within a cell. Load assigns it in log order. Without this a
  -- reload would collapse identical repetitions into one row and silently destroy
  -- the variance data — which is the measurement that has actually changed a
  -- routing decision in this repo.
  rep                   INTEGER NOT NULL DEFAULT 1,

  -- NOTE: every column in this key is NOT NULL (with '' defaults where a value may
  -- be absent). SQLite and Postgres both treat NULLs in a UNIQUE index as distinct,
  -- so a nullable key column would let duplicates through and break idempotency.
  UNIQUE (run_id, agent, task_id, executor_model, advisor_model, effort, rep)
);

CREATE INDEX IF NOT EXISTS idx_model_eval_cell ON model_eval (agent, executor_model, effort);
CREATE INDEX IF NOT EXISTS idx_model_eval_run  ON model_eval (run_id);

-- Cell-level rollup.
--
-- Mean is the number people reach for; VARIABILITY is what has actually changed
-- decisions here. On 2026-08-07 architect medium-vs-high had means 0.82 apart (inside
-- the noise floor, not actionable) while medium's worst case was 1.67 points lower.
-- Use `stddev` for cross-cell stability comparisons and `worst` for tail risk;
-- `spread` (max-min) is kept for eyeballing a single cell but is n-biased — see the
-- warning on the stddev column below.
CREATE VIEW IF NOT EXISTS cell_stats AS
SELECT
  agent,
  executor_model,
  effort,
  advisor_model                                                              AS advisor,
  COUNT(*)                                                                   AS n,
  ROUND(AVG((score_correctness + score_completeness + score_edge) / 3.0), 2) AS mean,
  ROUND(MIN((score_correctness + score_completeness + score_edge) / 3.0), 2) AS worst,
  ROUND(MAX((score_correctness + score_completeness + score_edge) / 3.0), 2) AS best,
  ROUND(MAX((score_correctness + score_completeness + score_edge) / 3.0)
      - MIN((score_correctness + score_completeness + score_edge) / 3.0), 2) AS spread,
  -- Standard deviation, computed as sqrt(E[x^2] - E[x]^2) since SQLite has no STDDEV.
  -- USE THIS, NOT `spread`, TO COMPARE STABILITY ACROSS CELLS. `spread` is max-min,
  -- which grows with n purely because more draws have more chance to hit an extreme —
  -- comparing spread between an n=3 and an n=9 cell measures sample size, not stability.
  -- (Learned the hard way on 2026-08-07: sonnet/high n=3 spread 1.67 vs sonnet/xhigh
  -- n=9 spread 4.67 looked like a stability difference and was mostly an n difference.)
  ROUND(
    CASE WHEN COUNT(*) < 2 THEN NULL ELSE
      SQRT( MAX(0.0,
        AVG( ((score_correctness + score_completeness + score_edge)/3.0)
           * ((score_correctness + score_completeness + score_edge)/3.0) )
        - AVG((score_correctness + score_completeness + score_edge)/3.0)
        * AVG((score_correctness + score_completeness + score_edge)/3.0) ) )
    END, 2)                                                                  AS stddev,
  SUM(tokens)                                                                AS tokens
FROM model_eval
WHERE score_correctness IS NOT NULL
GROUP BY agent, executor_model, effort, advisor_model;
