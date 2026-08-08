-- Schema for subagent_runs table. Higher-level rollup over cost_log.
-- One row per subagent invocation, with outcome and metadata.
-- v1.1: added orchestration_mode field so /agent-performance-review can compare outcomes across modes.
-- v1.1.1: placed in the `stack` schema for consistency with 001-cost-log.sql (Artifact 4 used bare
--         public-schema names; corrected to keep all stack tables together).

create schema if not exists stack;

CREATE TABLE IF NOT EXISTS stack.subagent_runs (
  id BIGSERIAL PRIMARY KEY,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Identification
  session_id TEXT NOT NULL,
  project_path TEXT,
  task_summary TEXT,

  -- The invocation
  subagent TEXT NOT NULL,
  invoked_by TEXT,                  -- 'main-thread', 'foreman-team-lead', 'user', or another subagent name
  orchestration_mode TEXT,          -- v1.1: 'main-thread', 'agent-teams', or 'hybrid' — for cross-mode analysis
  model TEXT NOT NULL,
  provider TEXT NOT NULL,

  -- Context
  input_summary TEXT,               -- what the subagent was asked to do (1-2 sentences)
  output_summary TEXT,              -- what the subagent produced (1-2 sentences)
  handoff_to TEXT,                  -- next subagent in chain, if any

  -- Outcome
  outcome TEXT NOT NULL,            -- 'success', 'escalated', 'rejected', 'aborted', 'timeout'
  rejection_reason TEXT,            -- if outcome = rejected, why
  required_redo BOOLEAN DEFAULT FALSE,
  user_overrode BOOLEAN DEFAULT FALSE,

  -- Performance
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens INTEGER DEFAULT 0,
  cache_write_tokens INTEGER DEFAULT 0,
  cost_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
  wall_time_ms INTEGER NOT NULL DEFAULT 0,

  -- Metadata
  stack_version TEXT,
  notes JSONB
);

CREATE INDEX IF NOT EXISTS idx_subagent_runs_session ON stack.subagent_runs(session_id);
CREATE INDEX IF NOT EXISTS idx_subagent_runs_occurred_at ON stack.subagent_runs(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_subagent_runs_subagent ON stack.subagent_runs(subagent);
CREATE INDEX IF NOT EXISTS idx_subagent_runs_outcome ON stack.subagent_runs(outcome);
CREATE INDEX IF NOT EXISTS idx_subagent_runs_orchestration_mode ON stack.subagent_runs(orchestration_mode);

ALTER TABLE stack.subagent_runs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'stack' AND tablename = 'subagent_runs' AND policyname = 'subagent_runs_service_all'
  ) THEN
    CREATE POLICY subagent_runs_service_all ON stack.subagent_runs FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- Performance views

CREATE OR REPLACE VIEW stack.subagent_perf_30d AS
SELECT
  subagent,
  model,
  COUNT(*) AS invocations,
  SUM(cost_usd) AS total_usd,
  AVG(cost_usd) AS avg_usd,
  AVG(wall_time_ms) / 1000.0 AS avg_wall_seconds,
  PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY wall_time_ms) / 1000.0 AS p95_wall_seconds,
  COUNT(*) FILTER (WHERE outcome = 'success') * 100.0 / COUNT(*) AS success_pct,
  COUNT(*) FILTER (WHERE outcome = 'escalated') * 100.0 / COUNT(*) AS escalation_pct,
  COUNT(*) FILTER (WHERE required_redo) * 100.0 / COUNT(*) AS redo_pct,
  COUNT(*) FILTER (WHERE user_overrode) * 100.0 / COUNT(*) AS user_override_pct
FROM stack.subagent_runs
WHERE occurred_at > NOW() - INTERVAL '30 days'
GROUP BY subagent, model
ORDER BY total_usd DESC;

CREATE OR REPLACE VIEW stack.subagent_handoff_chains_30d AS
SELECT
  subagent AS from_agent,
  handoff_to AS to_agent,
  COUNT(*) AS handoff_count,
  COUNT(*) FILTER (WHERE outcome = 'rejected') * 100.0 / COUNT(*) AS rejection_rate
FROM stack.subagent_runs
WHERE occurred_at > NOW() - INTERVAL '30 days'
  AND handoff_to IS NOT NULL
GROUP BY subagent, handoff_to
ORDER BY handoff_count DESC;

COMMENT ON TABLE stack.subagent_runs IS 'Higher-level subagent invocation tracking. Feeds /agent-performance-review at Tier 4.';
