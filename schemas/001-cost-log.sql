-- 001-cost-log.sql
-- Apply to the maintainer's shared Supabase project (<your-supabase-ref>).
-- Purpose: track LLM and deploy costs across all stack operations.

create schema if not exists stack;

create table if not exists stack.cost_log (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),

  -- What happened
  kind            text not null check (kind in (
                    'cost_projection',     -- /cost-gate output
                    'cost_actual',         -- post-run actual
                    'subagent_invocation', -- single subagent call
                    'deploy',              -- /deploy-edge
                    'bulk_job',            -- bulk script run
                    'other'
                  )),
  description     text not null,

  -- Context
  project_slug    text,             -- e.g., 'my-project'
  session_id      text,             -- Claude Code session ID
  subagent        text,             -- which subagent if applicable
  task_type       text,             -- 'feature' | 'bug' | etc.

  -- Cost
  model           text,             -- 'anthropic/claude-opus-4-7'
  input_tokens    bigint,
  output_tokens   bigint,
  cached_tokens   bigint,
  cost_usd        numeric(10, 4),

  -- Outcome
  status          text check (status in ('projected', 'in_progress', 'success', 'failed', 'partial')),
  variance_pct    numeric(6, 2),    -- (actual - projected) / projected * 100; null until reconciled

  -- Free-form
  metadata        jsonb default '{}'::jsonb
);

create index if not exists idx_cost_log_created_at on stack.cost_log (created_at desc);
create index if not exists idx_cost_log_project on stack.cost_log (project_slug, created_at desc);
create index if not exists idx_cost_log_kind on stack.cost_log (kind, created_at desc);
create index if not exists idx_cost_log_subagent on stack.cost_log (subagent, created_at desc);

-- RLS: this table is internal to the stack. Service role only.
alter table stack.cost_log enable row level security;

create policy "Service role full access" on stack.cost_log
  for all
  to service_role
  using (true)
  with check (true);

-- Helpful views

create or replace view stack.cost_log_daily as
select
  date_trunc('day', created_at) as day,
  project_slug,
  model,
  count(*) as call_count,
  sum(input_tokens) as input_tokens,
  sum(output_tokens) as output_tokens,
  sum(cost_usd) as cost_usd
from stack.cost_log
where kind in ('subagent_invocation', 'bulk_job', 'cost_actual')
  and status = 'success'
group by 1, 2, 3
order by 1 desc, 4 desc;

create or replace view stack.cost_log_anomalies as
with avg_7day as (
  select avg(cost_usd) as avg_cost
  from stack.cost_log_daily
  where day >= current_date - interval '7 days'
    and day < current_date - interval '1 day'
)
select cl.*
from stack.cost_log cl, avg_7day a
where cl.created_at >= current_date - interval '1 day'
  and cl.cost_usd > a.avg_cost * 2;

comment on table stack.cost_log is 'Operational cost tracking for Claude Code Stack. Written by subagents, /cost-gate, /deploy-edge, bulk-job scripts. Read by /agent-performance-review, /model-audit, ops subagent.';
