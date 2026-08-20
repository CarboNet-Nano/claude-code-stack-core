-- Schema for model_audits table. Tracks the output of /model-audit over time
-- and which proposals were accepted/rejected.
-- v1.1.1: placed in the `stack` schema for consistency with 001-cost-log.sql.

create schema if not exists stack;

CREATE TABLE IF NOT EXISTS stack.model_audits (
  id BIGSERIAL PRIMARY KEY,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  audit_date DATE NOT NULL,
  stack_version TEXT NOT NULL,

  -- The audit summary
  pricing_changes JSONB,            -- {model: {old_price, new_price, delta_pct}}
  benchmark_movements JSONB,        -- {capability: {model, old_rank, new_rank, benchmark}}
  new_models_observed JSONB,        -- [{model, provider, brief}]

  -- The proposals
  proposals JSONB NOT NULL,          -- [{subagent, current_model, proposed_model, evidence, cost_delta}]

  -- Resolution
  status TEXT NOT NULL DEFAULT 'pending',  -- 'pending', 'approved', 'partial', 'rejected'
  applied_changes JSONB,                    -- subset of proposals that were applied
  rejected_changes JSONB,                   -- subset rejected, with reasons
  decided_at TIMESTAMPTZ,
  decided_by TEXT,

  -- Outcome tracking (filled in by next audit)
  outcome_assessed_at TIMESTAMPTZ,
  outcome_summary TEXT,             -- "perf improved on architect"; "cost dropped 12% overall"

  notes JSONB
);

CREATE INDEX IF NOT EXISTS idx_model_audits_audit_date ON stack.model_audits(audit_date DESC);
CREATE INDEX IF NOT EXISTS idx_model_audits_status ON stack.model_audits(status);

ALTER TABLE stack.model_audits ENABLE ROW LEVEL SECURITY;

-- Roles are stack_writer / stack_reader from schemas/006-roles.sql, not
-- Supabase's `service_role` (retired 2026-08-10 with the Neon move). Guarded on
-- pg_roles so this file applies cleanly to a database where 006-roles.sql has
-- not run yet -- you get the table without the grants, not an error.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stack_writer') THEN
    GRANT USAGE ON SCHEMA stack TO stack_writer;
    GRANT SELECT, INSERT, UPDATE ON stack.model_audits TO stack_writer;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'stack' AND tablename = 'model_audits' AND policyname = 'model_audits_writer_all'
    ) THEN
      CREATE POLICY model_audits_writer_all ON stack.model_audits FOR ALL TO stack_writer USING (true) WITH CHECK (true);
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stack_reader') THEN
    GRANT USAGE ON SCHEMA stack TO stack_reader;
    GRANT SELECT ON stack.model_audits TO stack_reader;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'stack' AND tablename = 'model_audits' AND policyname = 'model_audits_reader_select'
    ) THEN
      CREATE POLICY model_audits_reader_select ON stack.model_audits FOR SELECT TO stack_reader USING (true);
    END IF;
  END IF;
END $$;

COMMENT ON TABLE stack.model_audits IS 'Tracks /model-audit history. Enables Tier 4 self-improvement by remembering what was tried and what worked.';
