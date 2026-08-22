-- schemas/006-knowledge-store.sql
--
-- ADR-060 §4 (row identity & keys) + Revision addendum §A (fixed role
-- tiers + transaction-local portfolio context) and §E (UUIDv7 write-
-- boundary CHECK). Run SECOND, as stack_migrator (schemas/006-roles.sql
-- runs first, by the provider admin, and creates the three roles plus the
-- `stack` schema owned by stack_migrator).
--
-- Objects only. No role DDL here -- stack_writer/stack_reader/stack_migrator
-- already exist by the time this file runs.
--
-- Plain PostgreSQL >=15. No provider extensions, no provider-specific
-- functions (ADR-060 §9 "portable by construction") -- this file must load
-- unmodified into any Postgres >=15, hosted or bring-your-own.

-- ---------------------------------------------------------------------
-- stack.tenant_identity -- this database's own statement of which
-- organization it is (ADR-060 §4). Singleton: exactly one row, inserted
-- once per org database as an operational bootstrap step (Task 7), not by
-- this shared schema file.
-- ---------------------------------------------------------------------

create table if not exists stack.tenant_identity (
  org_id     text        primary key,
  created_at timestamptz not null default now(),
  singleton  boolean     not null default true unique check (singleton)
);

create or replace function stack.current_org_id() returns text
  language sql stable as $$ select org_id from stack.tenant_identity $$;

-- Review fix (Critical #1, live-verified against Postgres 16): current_org_id()
-- evaluates with the INSERTING role's privileges (plain SQL function, not
-- SECURITY DEFINER), because it backs a column DEFAULT/CHECK on stack.events
-- that stack_writer/stack_reader must be able to evaluate. Without this grant
-- every stack_writer INSERT fails "permission denied for table tenant_identity"
-- before RLS is ever reached. See addendum §A amendment below.
grant select on stack.tenant_identity to stack_writer, stack_reader;

-- ---------------------------------------------------------------------
-- stack.users -- Q5: a random stable id is the key; email is an
-- attribute, never the key (a person may hold several emails across
-- their lifetime, and Bill personally operates under three today).
-- ---------------------------------------------------------------------

create table if not exists stack.users (
  id         uuid        primary key,
  emails     text[]      not null default '{}',
  created_at timestamptz not null default now()
);

-- A reserved system pseudo-user, for the two SECURITY DEFINER retention
-- functions below to attribute their own journal entries to (never a real
-- person; the nil uuid is a recognizable, reserved sentinel). Seeded here
-- because it is schema-bootstrap data, not org-specific data.
insert into stack.users (id, emails)
  select '00000000-0000-0000-0000-000000000000'::uuid, '{}'
  where not exists (
    select 1 from stack.users where id = '00000000-0000-0000-0000-000000000000'::uuid
  );

-- Review fix (Important #5): user rows are written by stack_migrator only
-- in P1b (Task 7 checkpoint inserts Bill's user row; the two retention
-- functions insert only the reserved system row above, also as migrator).
-- stack_writer/stack_reader get SELECT so the engine can read/join user
-- rows (e.g. resolving emails for a brief) -- INSERT stays migrator-only
-- until P1b needs a self-serve user-creation path.
grant select on stack.users to stack_writer, stack_reader;

-- ---------------------------------------------------------------------
-- stack.portfolio_settings -- mutable, per-portfolio settings (REQ-124
-- pace dial, REQ-146 retention + export consent). A per-row flag in the
-- append-only events table would be un-revocable; this table is what
-- makes consent and retention actually mutable.
--
-- portfolio <> '' (review fix, fold-in #7): a custom GUC that was set at
-- least once in a session but is unset in the CURRENT transaction can read
-- back as '' rather than NULL (verified live) -- current_setting(...,true)'s
-- NULL-means-unset assumption the RLS policy below relies on does not hold
-- in that state. Banning the empty string as a portfolio value everywhere
-- it's compared against the GUC keeps the fail-closed property true even
-- when the GUC reads back as '' instead of NULL.
-- ---------------------------------------------------------------------

create table if not exists stack.portfolio_settings (
  portfolio      text    primary key check (portfolio <> ''),
  pace           text    not null default 'balanced' check (pace in ('fast', 'balanced', 'frugal')),
  retention_days integer not null default 365,
  export_consent boolean not null default false
);

-- ---------------------------------------------------------------------
-- stack.events -- the append-only knowledge-store journal (ADR-060 §4).
-- org_id routes (selects the database) and is a self-describing assertion
-- against stack.tenant_identity, not a query predicate: a mismatch is a
-- misrouting bug caught by the CHECK, not a filter anyone can forget.
-- portfolio isolates within the database (RLS, below). user_id is the
-- learning-model subject and a typed FK into stack.users (Q5's random
-- stable id).
-- ---------------------------------------------------------------------

create table if not exists stack.events (
  event_id       uuid        primary key
                             check (
                               substring(event_id::text, 15, 1) = '7'
                               and substring(event_id::text, 20, 1) in ('8', '9', 'a', 'b')
                             ),
  -- Review fix (Important #2, live-verified): `=` is NULL when
  -- current_org_id() is NULL (unseeded tenant_identity), and a NULL CHECK
  -- result is treated as satisfied -- so ANY org_id value was accepted
  -- while the database was unseeded (verified live with 'TOTALLY-WRONG-ORG').
  -- IS NOT DISTINCT FROM is null-safe equality: it evaluates to a real
  -- FALSE (constraint violated) when org_id is non-null and
  -- current_org_id() is null, closing the hole, while leaving the seeded
  -- match/mismatch cases unchanged.
  org_id         text        not null default stack.current_org_id()
                             check (org_id is not distinct from stack.current_org_id()),
  portfolio      text        not null references stack.portfolio_settings (portfolio)
                             check (portfolio <> ''),
  user_id        uuid        not null references stack.users (id),
  schema_version integer     not null,
  ts             timestamptz not null,
  ingested_at    timestamptz not null default now(),
  type           text        not null check (type in (
                               'priority_call', 'override', 'challenge', 'outcome',
                               'interview_answer', 'audit_verdict', 'suggestion_decision',
                               'matrix_change', 'handoff', 'decision'
                             )),
  subject_kind   text        not null,
  subject_id     text        not null,
  author         text        not null,
  repo           text,
  track          text,
  session_id     text,
  machine_id     text,
  producer       text        not null,
  ref_event_id   uuid,
  body           jsonb,
  redacted       text[],

  constraint events_portfolio_uk unique (portfolio, event_id),
  constraint events_ref_same_portfolio
    foreign key (portfolio, ref_event_id)
    references stack.events (portfolio, event_id)
);

comment on table stack.events is
  'Append-only knowledge-store journal (ADR-060 Sec.4). RLS fail-closed on the stack.portfolio transaction-local GUC (Revision addendum Sec.A).';

grant select, insert on stack.events to stack_writer;
grant select on stack.events to stack_reader;

-- ---------------------------------------------------------------------
-- Indexes (ADR-060 §4 hot paths).
-- ---------------------------------------------------------------------

create index if not exists idx_events_portfolio_ts on stack.events (portfolio, ts desc);
create index if not exists idx_events_portfolio_track_ts on stack.events (portfolio, track, ts desc);
create index if not exists idx_events_ref_event_id on stack.events (ref_event_id);
create index if not exists idx_events_session_id on stack.events (session_id);

-- Partial index on the priority_call counters hot path (staleCalls /
-- pendingPredictions in journal.mjs). A predicate testing "lacking a
-- linked outcome" cannot itself be expressed here -- Postgres partial
-- index predicates must be immutable and may not reference other rows via
-- a subquery -- so the partial index narrows to the type instead; the
-- anti-join against outcome events (see journal.mjs's LEFT JOIN pattern)
-- stays in the query, now scanning only priority_call rows.
create index if not exists idx_events_priority_call_open
  on stack.events (portfolio, ts)
  where type = 'priority_call';

grant select, update on stack.portfolio_settings to stack_writer;
grant select on stack.portfolio_settings to stack_reader;

-- ---------------------------------------------------------------------
-- stack.uuidv7() -- pure-SQL, extension-free UUIDv7 generator used ONLY
-- by the two SECURITY DEFINER functions below to journal their own
-- execution (application code generates event ids client-side, per
-- ADR-060 Sec.4 "event_id ... client-generated" and Task 3's uuidv7()).
--
-- Builds the 32 hex digits directly: the first 12 (=48 bits) are a
-- millisecond timestamp; digit 13 is the fixed version nibble '7'; digit
-- 17 is the variant nibble, drawn from {8,9,a,b}; the rest are randomness
-- taken from a fresh gen_random_uuid() (built into Postgres core since
-- v13, no extension required). Undashed 32-hex-digit text is a valid uuid
-- input format; Postgres always renders ::text output in the standard
-- dashed form, so digit 13 lands at text position 15 and digit 17 lands
-- at text position 20 -- exactly where the CHECK above looks.
-- ---------------------------------------------------------------------

create or replace function stack.uuidv7() returns uuid
  language sql volatile as $$
  select (
    lpad(to_hex(floor(extract(epoch from clock_timestamp()) * 1000)::bigint), 12, '0')
    || '7' || substr(r, 1, 3)
    || (array['8', '9', 'a', 'b'])[1 + floor(random() * 4)::int]
    || substr(r, 4, 3)
    || substr(r, 7, 12)
  )::uuid
  from (select replace(gen_random_uuid()::text, '-', '') as r) s;
$$;

-- ---------------------------------------------------------------------
-- stack.set_portfolio(p) -- Revision addendum Sec.A. Deliberately NO
-- `SET` clause on the function: a SET clause would revert the GUC when
-- the function returns, silently making every RLS policy below match
-- zero rows for the rest of the transaction (the addendum's footgun
-- note). All identifiers are schema-qualified instead of relying on a
-- SET search_path, for the same reason.
-- ---------------------------------------------------------------------

create or replace function stack.set_portfolio(p text) returns void
  language plpgsql security definer as $$
begin
  if not exists (select 1 from stack.portfolio_settings s where s.portfolio = p) then
    raise exception 'unknown portfolio: %', p;
  end if;
  perform set_config('stack.portfolio', p, true);  -- true = transaction-local
end $$;

revoke execute on function stack.set_portfolio(text) from public;
grant execute on function stack.set_portfolio(text) to stack_writer, stack_reader;

-- ---------------------------------------------------------------------
-- RLS: fail-closed on the transaction-local `stack.portfolio` setting.
-- current_setting(..., true) yields NULL when unset, so the predicate is
-- NULL -> false for both USING and WITH CHECK: an unset context reads no
-- rows and can insert none. FORCE makes this apply even to the table
-- owner (stack_migrator), which is why stack_migrator needs its own
-- explicit permissive policy below rather than relying on ownership.
-- ---------------------------------------------------------------------

alter table stack.events enable row level security;
alter table stack.events force row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'stack' and tablename = 'events' and policyname = 'events_portfolio_isolation'
  ) then
    create policy events_portfolio_isolation on stack.events
      for all
      to stack_writer, stack_reader
      using      (portfolio = current_setting('stack.portfolio', true))
      with check (portfolio = current_setting('stack.portfolio', true));
  end if;
end $$;

-- stack_migrator: an explicit permissive policy, not a superuser-only
-- row-level-security bypass attribute on the role -- that attribute needs
-- superuser, which a bring-your-own-database customer may refuse to grant
-- (ADR-060 §9's portability argument).
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'stack' and tablename = 'events' and policyname = 'events_migrator_all'
  ) then
    create policy events_migrator_all on stack.events
      for all
      to stack_migrator
      using (true)
      with check (true);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- stack.purge_portfolio() / stack.sweep_retention(days) -- REQ-146.
-- SECURITY DEFINER: the session roles have no UPDATE/DELETE on
-- stack.events (append-only is a grant, §5), so erasure and the
-- retention sweep run as these two narrow functions instead. Both
-- require a portfolio context to already be set (stack.set_portfolio)
-- and act only on that portfolio -- the role can erase its own portfolio
-- and nothing else, and cannot delete a single row by hand.
--
-- Both journal their own execution before deleting: purge_portfolio
-- writes its own audit row into the just-purged portfolio, then excludes
-- that one row (by id) from the delete it is about to issue -- otherwise
-- an unconditional "delete everything in this portfolio" would erase the
-- very record proving the purge happened, and "journal before deleting"
-- would be theater. sweep_retention needs no such exclusion: its own
-- audit row is timestamped `now()`, which is never older than the
-- retention cutoff it is about to delete by.
--
-- Review fix (Important #4, live-verified): both functions read the
-- `stack.portfolio` GUC directly, so a caller can bypass stack.set_portfolio
-- entirely via `SET LOCAL "stack.portfolio" = '<any-existing-portfolio>'`
-- and reach a sibling portfolio's rows without ever validating through
-- set_portfolio's own EXISTS check. Both now re-run that same EXISTS check
-- before doing anything destructive, so a portfolio name that only exists
-- because of a typo or stale GUC state fails loudly and consistently with
-- set_portfolio's own error, rather than silently no-op'ing or (worse)
-- reaching the FK indirectly. This does NOT close the underlying trust
-- question -- a credential holder who can already run arbitrary SQL as
-- stack_writer can name any portfolio that genuinely exists, exactly the
-- same as calling stack.set_portfolio(p) would allow. See the dated
-- amendment to addendum §B for the honest statement of that residual scope.
-- ---------------------------------------------------------------------

create or replace function stack.purge_portfolio() returns void
  language plpgsql security definer as $$
declare
  p text := current_setting('stack.portfolio', true);
  journal_id uuid;
begin
  if p is null then
    raise exception 'purge_portfolio: no portfolio context set -- call stack.set_portfolio(p) first';
  end if;

  if not exists (select 1 from stack.portfolio_settings s where s.portfolio = p) then
    raise exception 'purge_portfolio: unknown portfolio: %', p;
  end if;

  journal_id := stack.uuidv7();

  insert into stack.events
    (event_id, portfolio, user_id, schema_version, ts, type,
     subject_kind, subject_id, author, producer, body)
  values
    (journal_id, p, '00000000-0000-0000-0000-000000000000'::uuid, 1, now(), 'decision',
     'system', 'stack.purge_portfolio', 'stack', 'stack@p1b',
     jsonb_build_object('action', 'purge_portfolio', 'portfolio', p));

  delete from stack.events where portfolio = p and event_id <> journal_id;
end $$;

create or replace function stack.sweep_retention(days integer) returns void
  language plpgsql security definer as $$
declare
  p text := current_setting('stack.portfolio', true);
  cutoff timestamptz;
begin
  if p is null then
    raise exception 'sweep_retention: no portfolio context set -- call stack.set_portfolio(p) first';
  end if;

  if not exists (select 1 from stack.portfolio_settings s where s.portfolio = p) then
    raise exception 'sweep_retention: unknown portfolio: %', p;
  end if;

  -- Review fix (Important #3, live-verified): an unguarded days<1 (e.g.
  -- -1) puts the cutoff in the future, so "older than cutoff" matches
  -- every row including ones just journaled by this same call --
  -- verified live wiping a 5-row portfolio to 0. A retention window of
  -- zero or negative days is never a legitimate call.
  if days < 1 then
    raise exception 'sweep_retention: days must be >= 1, got %', days;
  end if;

  cutoff := now() - (days || ' days')::interval;

  insert into stack.events
    (event_id, portfolio, user_id, schema_version, ts, type,
     subject_kind, subject_id, author, producer, body)
  values
    (stack.uuidv7(), p, '00000000-0000-0000-0000-000000000000'::uuid, 1, now(), 'decision',
     'system', 'stack.sweep_retention', 'stack', 'stack@p1b',
     jsonb_build_object('action', 'sweep_retention', 'portfolio', p, 'days', days, 'cutoff', cutoff));

  -- Review fix (fold-in #8): delete on ingested_at (server-authoritative,
  -- ADR-060 §4), not the client-supplied ts -- a future-dated ts would
  -- otherwise evade retention indefinitely.
  delete from stack.events where portfolio = p and ingested_at < cutoff;
end $$;

revoke execute on function stack.purge_portfolio() from public;
revoke execute on function stack.sweep_retention(integer) from public;
grant execute on function stack.purge_portfolio() to stack_writer;
grant execute on function stack.sweep_retention(integer) to stack_writer;
