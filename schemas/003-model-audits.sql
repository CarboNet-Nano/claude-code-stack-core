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

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'stack' AND tablename = 'model_audits' AND policyname = 'model_audits_service_all'
  ) THEN
    CREATE POLICY model_audits_service_all ON stack.model_audits FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

COMMENT ON TABLE stack.model_audits IS 'Tracks /model-audit history. Enables Tier 4 self-improvement by remembering what was tried and what worked.';
