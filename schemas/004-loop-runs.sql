-- 004-loop-runs.sql
-- Loop-engineering telemetry (ADR-019 Phase 2). One row per governed loop run.
-- Tier 3+. Populated by loop_runs_record() (skills/loop-engineer/loop_lib.sh) when
-- the Stop-hook marks a terminal status; the writer no-ops without database creds,
-- so this table is the optional shared rollup over the always-on local JSONL log.
-- Placed in the `stack` schema for consistency with 001/002/003.

create schema if not exists stack;

create table if not exists stack.loop_runs (
  id              bigserial primary key,
  created_at      timestamptz not null default now(),

  -- Identification
  loop_id         text not null,
  session_id      text,
  project_slug    text,

  -- Shape
  pattern         text,            -- ralph | eval-driven | generator-critic | react | ...
  autonomy        text,            -- checkpoint | bounded-checkpoint | bounded-autonomous
  goal            text,

  -- Outcome
  status          text not null,   -- met | max_iterations | budget_exceeded | timeout | no_progress | escalated | cleared
  iterations      integer not null default 0,
  recursion_depth integer not null default 0,
  cost_usd        numeric(12, 6) not null default 0,

  -- Timing
  started_at      timestamptz,
  ended_at        timestamptz,

  -- Metadata
  stack_version   text,
  notes           jsonb
);

create index if not exists idx_loop_runs_loop_id    on stack.loop_runs(loop_id);
create index if not exists idx_loop_runs_created_at  on stack.loop_runs(created_at desc);
create index if not exists idx_loop_runs_status      on stack.loop_runs(status);

alter table stack.loop_runs enable row level security;

-- Roles are stack_writer / stack_reader from schemas/006-roles.sql, not
-- Supabase's `service_role` (retired 2026-08-10 with the Neon move). Guarded on
-- pg_roles so this file applies cleanly to a database where 006-roles.sql has
-- not run yet -- you get the table without the grants, not an error.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'stack_writer') then
    grant usage on schema stack to stack_writer;
    grant select, insert, update on stack.loop_runs to stack_writer;
    if not exists (
      select 1 from pg_policies
      where schemaname = 'stack' and tablename = 'loop_runs' and policyname = 'loop_runs_writer_all'
    ) then
      create policy loop_runs_writer_all on stack.loop_runs for all to stack_writer using (true) with check (true);
    end if;
  end if;

  if exists (select 1 from pg_roles where rolname = 'stack_reader') then
    grant usage on schema stack to stack_reader;
    grant select on stack.loop_runs to stack_reader;
    if not exists (
      select 1 from pg_policies
      where schemaname = 'stack' and tablename = 'loop_runs' and policyname = 'loop_runs_reader_select'
    ) then
      create policy loop_runs_reader_select on stack.loop_runs for select to stack_reader using (true);
    end if;
  end if;
end $$;

-- Rollup: loop outcomes over the last 30 days (feeds cap calibration / reviews).
create or replace view stack.loop_runs_30d as
select
  pattern,
  autonomy,
  count(*)                                              as runs,
  count(*) filter (where status = 'met') * 100.0 / count(*)              as met_pct,
  count(*) filter (where status = 'budget_exceeded') * 100.0 / count(*)  as budget_exceeded_pct,
  count(*) filter (where status = 'max_iterations') * 100.0 / count(*)   as iter_cap_pct,
  avg(iterations)                                       as avg_iterations,
  sum(cost_usd)                                         as total_usd,
  avg(cost_usd)                                         as avg_usd
from stack.loop_runs
where created_at > now() - interval '30 days'
group by pattern, autonomy
order by total_usd desc;

comment on table stack.loop_runs is 'Loop-engineering run telemetry (ADR-019 Phase 2). One row per governed loop. Tier 3+.';
