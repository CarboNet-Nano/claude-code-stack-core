-- schemas/006-roles.sql
--
-- ADR-060 addendum (2026-08-08) §A: three fixed login roles per org
-- database, a count independent of portfolio count. Run FIRST, by the
-- provider admin/owner identity (the only identity allowed to create
-- roles -- stack_migrator cannot create its own role). Then run
-- schemas/006-knowledge-store.sql SECOND, as stack_migrator.
--
-- Idempotent: safe to re-run. Each role is created inside a
-- DO $$ ... IF NOT EXISTS (SELECT FROM pg_roles ...) $$ guard; the schema
-- creation and ownership/usage grants below are all naturally re-runnable
-- (CREATE SCHEMA IF NOT EXISTS, ALTER SCHEMA ... OWNER TO, GRANT).
--
-- Role DDL and schema-ownership bootstrap ONLY. No table/function/policy/
-- index DDL lives in this file -- that is schemas/006-knowledge-store.sql's
-- job, applied by stack_migrator once it owns the schema.
--
-- Passwords/credentials are set separately, OUTSIDE this file, by the
-- provider admin as part of the Task 7 human bootstrap checklist
-- (ALTER ROLE ... PASSWORD, generated secret held in the org's credential
-- store per ADR-060 Q2/§5) -- never committed here.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'stack_writer') then
    create role stack_writer login;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'stack_reader') then
    create role stack_reader login;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'stack_migrator') then
    create role stack_migrator login;
  end if;
end $$;

-- schema `stack` is owned by stack_migrator, so the object DDL in
-- schemas/006-knowledge-store.sql (run second, as stack_migrator) needs no
-- further ownership grants to add objects inside it.
create schema if not exists stack;
alter schema stack owner to stack_migrator;

-- stack_writer/stack_reader need USAGE on the schema before any object
-- inside it is reachable; the object-level grants (SELECT/INSERT/EXECUTE
-- on specific tables and functions per the addendum §A grant table) are
-- issued from schemas/006-knowledge-store.sql, once those objects exist.
grant usage on schema stack to stack_writer, stack_reader;
