import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ADR-060 §4 + Revision addendum §A/§E. Ungated, in-loop static assertions
// over the two schema files -- no Postgres required. These check shape and
// forbidden/required literals only; actual RLS/role/constraint behavior is
// verified by the gated pg-integration.test.mjs at the Task 7 checkpoint.

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMAS_DIR = join(__dirname, "..", "..", "..", "schemas");
const ROLES_PATH = join(SCHEMAS_DIR, "006-roles.sql");
const STORE_PATH = join(SCHEMAS_DIR, "006-knowledge-store.sql");

const EVENT_TYPES = [
  "priority_call", "override", "challenge", "outcome", "interview_answer",
  "audit_verdict", "suggestion_decision", "matrix_change", "handoff", "decision"
];

function read(path) {
  return readFileSync(path, "utf8");
}

test("both schema files exist and are non-empty", () => {
  assert.ok(read(ROLES_PATH).length > 0, "schemas/006-roles.sql must exist and be non-empty");
  assert.ok(read(STORE_PATH).length > 0, "schemas/006-knowledge-store.sql must exist and be non-empty");
});

// --- 006-knowledge-store.sql -------------------------------------------

test("006-knowledge-store.sql: FORCE ROW LEVEL SECURITY present", () => {
  assert.match(read(STORE_PATH), /force row level security/i);
});

test("006-knowledge-store.sql: no BYPASSRLS", () => {
  assert.doesNotMatch(read(STORE_PATH), /bypassrls/i);
});

test("006-knowledge-store.sql: no pg_session_jwt (rev-1 mechanism, retired ADR-060 §9)", () => {
  assert.doesNotMatch(read(STORE_PATH), /pg_session_jwt/i);
});

test("006-knowledge-store.sql: no CREATE EXTENSION (portable-by-construction, ADR-060 §9)", () => {
  assert.doesNotMatch(read(STORE_PATH), /create extension/i);
});

test("006-knowledge-store.sql: no CREATE ROLE (roles live in 006-roles.sql only)", () => {
  assert.doesNotMatch(read(STORE_PATH), /create role/i);
});

test("006-knowledge-store.sql: typed user FK -- REFERENCES stack.users present", () => {
  assert.match(read(STORE_PATH), /references stack\.users/i);
});

test("006-knowledge-store.sql: portfolio FK to stack.portfolio_settings present (typo = error, addendum §A)", () => {
  assert.match(read(STORE_PATH), /references stack\.portfolio_settings/i);
});

test("006-knowledge-store.sql: UUIDv7 write-boundary CHECK matches addendum §E's portable substring form", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /substring\(event_id::text,\s*15,\s*1\)\s*=\s*'7'/i);
  assert.match(sql, /substring\(event_id::text,\s*20,\s*1\)\s*in\s*\('8',\s*'9',\s*'a',\s*'b'\)/i);
});

test("006-knowledge-store.sql: event type list is P1a's nine plus decision, exactly", () => {
  const sql = read(STORE_PATH);
  const start = sql.indexOf("type           text        not null check (type in (");
  assert.notEqual(start, -1, "could not find the events.type CHECK clause");
  const end = sql.indexOf("))", start);
  const clause = sql.slice(start, end);
  for (const t of EVENT_TYPES) {
    assert.match(clause, new RegExp(`'${t}'`), `type list missing '${t}'`);
  }
  const found = [...clause.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
  assert.equal(found.length, EVENT_TYPES.length, `expected exactly ${EVENT_TYPES.length} types, found ${found.length}: ${found.join(", ")}`);
});

test("006-knowledge-store.sql: set_portfolio has no SET clause between its signature and body", () => {
  const sql = read(STORE_PATH);
  const start = sql.indexOf("function stack.set_portfolio");
  assert.notEqual(start, -1, "stack.set_portfolio definition not found");
  const asIdx = sql.indexOf("as $$", start);
  assert.notEqual(asIdx, -1, "could not find the AS $$ body marker after set_portfolio's signature");
  const signature = sql.slice(start, asIdx);
  assert.doesNotMatch(
    signature,
    /\bset\s+\S/i,
    "set_portfolio must have no SET clause (addendum footgun: a SET clause reverts the GUC on function exit)"
  );
});

test("006-knowledge-store.sql: set_portfolio is SECURITY DEFINER and fail-closed on stack.portfolio via current_setting(..., true)", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /function stack\.set_portfolio[\s\S]*?security definer/i);
  assert.match(sql, /current_setting\('stack\.portfolio',\s*true\)/);
});

test("006-knowledge-store.sql: migrator gets an explicit USING (true) policy, not BYPASSRLS", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /create policy events_migrator_all on stack\.events[\s\S]*?to stack_migrator[\s\S]*?using\s*\(true\)/i);
});

test("006-knowledge-store.sql: purge_portfolio and sweep_retention are SECURITY DEFINER", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /function stack\.purge_portfolio\(\)[\s\S]*?security definer/i);
  assert.match(sql, /function stack\.sweep_retention\(days integer\)[\s\S]*?security definer/i);
});

// --- Review fixes (2026-08-08, Task 2 live review against Postgres 16) --

test("review fix Critical #1: stack_writer/stack_reader have SELECT on stack.tenant_identity", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /grant select on stack\.tenant_identity to stack_writer, stack_reader/i);
});

test("review fix Important #5: stack_writer/stack_reader have SELECT on stack.users (no INSERT grant)", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /grant select on stack\.users to stack_writer, stack_reader/i);
  assert.doesNotMatch(sql, /grant[^;]*insert[^;]*on stack\.users/i);
});

test("review fix Important #2: org_id CHECK is null-safe (IS NOT DISTINCT FROM), not plain '='", () => {
  const sql = read(STORE_PATH);
  assert.match(sql, /check \(org_id is not distinct from stack\.current_org_id\(\)\)/i);
});

test("review fix fold-in #7: portfolio <> '' guarded on both portfolio_settings and events", () => {
  const sql = read(STORE_PATH);
  const start = sql.indexOf("create table if not exists stack.portfolio_settings");
  const end = sql.indexOf(");", start);
  assert.match(sql.slice(start, end), /portfolio\s+text\s+primary key check \(portfolio <> ''\)/i);

  const eventsStart = sql.indexOf("create table if not exists stack.events");
  const eventsEnd = sql.indexOf("constraint events_portfolio_uk", eventsStart);
  assert.match(sql.slice(eventsStart, eventsEnd), /check \(portfolio <> ''\)/i);
});

test("review fix Important #3: sweep_retention rejects days < 1", () => {
  const sql = read(STORE_PATH);
  const start = sql.indexOf("function stack.sweep_retention");
  assert.notEqual(start, -1);
  const body = sql.slice(start, sql.indexOf("end $$;", start));
  assert.match(body, /if days < 1 then\s*\n\s*raise exception/i);
});

test("review fix fold-in #8: sweep_retention deletes on ingested_at, not client-supplied ts", () => {
  const sql = read(STORE_PATH);
  const start = sql.indexOf("function stack.sweep_retention");
  const body = sql.slice(start, sql.indexOf("end $$;", start));
  assert.match(body, /delete from stack\.events where portfolio = p and ingested_at < cutoff/i);
  assert.doesNotMatch(body, /delete from stack\.events where portfolio = p and ts < cutoff/i);
});

test("review fix Important #4: purge_portfolio and sweep_retention re-validate the portfolio exists before acting", () => {
  const sql = read(STORE_PATH);
  for (const fn of ["stack.purge_portfolio", "stack.sweep_retention"]) {
    const start = sql.indexOf(`function ${fn}`);
    assert.notEqual(start, -1, `${fn} definition not found`);
    const body = sql.slice(start, sql.indexOf("end $$;", start));
    assert.match(
      body,
      /if not exists \(select 1 from stack\.portfolio_settings s where s\.portfolio = p\) then\s*\n\s*raise exception/i,
      `${fn} must re-validate the portfolio exists (review Important #4)`
    );
  }
});

// --- 006-roles.sql -------------------------------------------------------

test("006-roles.sql: contains the three fixed role names", () => {
  const sql = read(ROLES_PATH);
  for (const role of ["stack_writer", "stack_reader", "stack_migrator"]) {
    assert.match(sql, new RegExp(role));
  }
});

test("006-roles.sql: role creation is guarded by a pg_roles idempotency check per role", () => {
  const sql = read(ROLES_PATH);
  assert.match(sql, /pg_roles/);
  const guardCount = (sql.match(/select 1 from pg_roles where rolname\s*=/gi) || []).length;
  assert.equal(guardCount, 3, `expected 3 pg_roles idempotency guards (one per role), found ${guardCount}`);
});

test("006-roles.sql: stack_migrator is made owner of schema stack", () => {
  assert.match(read(ROLES_PATH), /alter schema stack owner to stack_migrator/i);
});

test("006-roles.sql: no object DDL (tables/functions/policies/indexes live in 006-knowledge-store.sql)", () => {
  const sql = read(ROLES_PATH);
  for (const forbidden of [/create table/i, /create function/i, /create policy/i, /create index/i, /create view/i]) {
    assert.doesNotMatch(sql, forbidden);
  }
});

test("006-roles.sql: no CREATE ROLE outside a pg_roles existence guard (must stay idempotent-safe)", () => {
  // Every `create role` line must appear after a pg_roles existence check
  // in the same DO block -- a bare, unguarded `create role` would fail on
  // re-run instead of being a no-op.
  const sql = read(ROLES_PATH);
  const blocks = sql.split(/do \$\$/i).slice(1);
  const roleBlocks = blocks.filter((b) => /create role/i.test(b));
  assert.equal(roleBlocks.length, 3, `expected 3 DO blocks containing CREATE ROLE, found ${roleBlocks.length}`);
  for (const b of roleBlocks) {
    assert.match(b, /if not exists[\s\S]*pg_roles[\s\S]*then[\s\S]*create role/i);
  }
});
