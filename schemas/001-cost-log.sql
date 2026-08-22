-- 001-cost-log.sql
--
-- Apply to the organization's Neon database (ADR-060 §1: one database per
-- organization). Supabase is retired -- this file previously targeted the
-- maintainer's shared Supabase project and its `service_role`, neither of
-- which exists any more.
--
-- ORDERING: schemas/006-roles.sql creates stack_writer / stack_reader /
-- stack_migrator and must run FIRST, by the provider admin identity. This file
-- is order-tolerant anyway -- every grant and policy below is wrapped in a
-- pg_roles existence guard, so applying it against a database without those
-- roles yields the table without the grants rather than an error.
--
-- Purpose: track LLM and deploy costs across all stack operations, attributed
-- to the person, organization, app, and agent that incurred them
-- (docs/plans/2026-08-10-entitlement-driven-config.md, Phase 3).

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

-- ---------------------------------------------------------------------------
-- Attribution (2026-08-10). Added as nullable columns rather than a second
-- table: this IS the ledger the AI gateway writes to, and a second ledger for
-- proxied calls would have to be reconciled against this one forever.
--
-- Every column is nullable because rows predating the gateway exist, and
-- because the gateway's own degrade path (control plane unreachable -> fall
-- back to a pooled provider key) deliberately writes a row with
-- attribution = 'unattributed' rather than dropping the call. A gap in the
-- ledger is the acceptable cost of an outage; a stopped session is not.
-- ---------------------------------------------------------------------------
alter table stack.cost_log add column if not exists user_id     text;  -- Clerk subject
alter table stack.cost_log add column if not exists org_id      text;  -- ADR-060 Organization rung
alter table stack.cost_log add column if not exists app_key     text;  -- registered app / repo
alter table stack.cost_log add column if not exists portfolio   text;  -- PM scope (REQ-100)
alter table stack.cost_log add column if not exists track       text;  -- workstream inside the portfolio
alter table stack.cost_log add column if not exists effort      text;  -- reasoning effort (ADR-056)
alter table stack.cost_log add column if not exists outcome     text;  -- caller-reported usefulness
alter table stack.cost_log add column if not exists attribution text
  not null default 'attributed'
  check (attribution in ('attributed', 'unattributed'));

-- `subagent` already carries which agent ran; deliberately NOT duplicated as an
-- `agent` column. Queries that answer "is red-team worth its cost" group by it.

create index if not exists idx_cost_log_created_at on stack.cost_log (created_at desc);
create index if not exists idx_cost_log_project on stack.cost_log (project_slug, created_at desc);
create index if not exists idx_cost_log_kind on stack.cost_log (kind, created_at desc);
create index if not exists idx_cost_log_subagent on stack.cost_log (subagent, created_at desc);
create index if not exists idx_cost_log_user on stack.cost_log (user_id, created_at desc);
create index if not exists idx_cost_log_org on stack.cost_log (org_id, created_at desc);
create index if not exists idx_cost_log_app on stack.cost_log (app_key, created_at desc);

-- ---------------------------------------------------------------------------
-- RLS. This table is internal to the stack: stack_writer writes, stack_reader
-- reads, nobody else touches it. Guarded so the file applies cleanly to a
-- database where 006-roles.sql has not run yet.
-- ---------------------------------------------------------------------------
alter table stack.cost_log enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'stack_writer') then
    grant usage on schema stack to stack_writer;
    grant select, insert, update on stack.cost_log to stack_writer;
    if not exists (
      select 1 from pg_policies
      where schemaname = 'stack' and tablename = 'cost_log' and policyname = 'cost_log_writer_all'
    ) then
      create policy cost_log_writer_all on stack.cost_log
        for all to stack_writer using (true) with check (true);
    end if;
  end if;

  if exists (select 1 from pg_roles where rolname = 'stack_reader') then
    grant usage on schema stack to stack_reader;
    grant select on stack.cost_log to stack_reader;
    if not exists (
      select 1 from pg_policies
      where schemaname = 'stack' and tablename = 'cost_log' and policyname = 'cost_log_reader_select'
    ) then
      create policy cost_log_reader_select on stack.cost_log
        for select to stack_reader using (true);
    end if;
  end if;
end $$;

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

-- Per-agent spend. The question the cost log has never been able to answer,
-- and the reason Phase 3 proxies the LLM providers rather than issuing
-- per-user provider keys: a per-user key attributes spend to a person, but
-- only the proxy can attribute it to the agent that chose to spend it.
create or replace view stack.cost_log_by_agent as
select
  subagent,
  model,
  effort,
  count(*)                                              as call_count,
  count(*) filter (where attribution = 'unattributed')  as unattributed_calls,
  sum(input_tokens)                                     as input_tokens,
  sum(output_tokens)                                    as output_tokens,
  sum(cost_usd)                                         as cost_usd,
  count(*) filter (where outcome = 'useful')            as useful_calls
from stack.cost_log
where subagent is not null
group by 1, 2, 3
order by cost_usd desc nulls last;

comment on table stack.cost_log is 'Operational cost tracking for Claude Code Stack, on the org''s Neon database (ADR-060). Written by subagents, /cost-gate, /deploy-edge, bulk-job scripts, and the AI gateway. Read by /agent-performance-review, /model-audit, ops subagent.';
comment on column stack.cost_log.attribution is 'attributed = the AI gateway identified the caller. unattributed = the control plane was unreachable and the call fell back to a pooled provider key. Never dropped: a gap in the ledger beats a stopped session.';
