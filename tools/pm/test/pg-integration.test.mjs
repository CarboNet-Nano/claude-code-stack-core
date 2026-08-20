import { test, before } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { BRIEF_DATA_SQL } from "../src/journal-pg.mjs";

// ADR-060 Revision addendum §A/§E. Gated on FOUR role-scoped Postgres
// connection strings -- there is no Postgres reachable in this dev loop
// (P1b ASSUMPTION 1), so this suite is written now and exercised for real
// at the Task 7 human checkpoint. Per the plan's Global Constraints: "When
// any [env var] is unset the suite reports SKIPPED (visibly, via t.skip(),
// never silently green)."
//
// Run it: PM_TEST_DB_URL_ADMIN=... PM_TEST_DB_URL_MIGRATOR=... \
//   PM_TEST_DB_URL_WRITER=... PM_TEST_DB_URL_READER=... \
//   node --test tools/pm/test/pg-integration.test.mjs
//
// Role identities (never conflate -- see the brief's B4/B5 review notes):
//   ADMIN    -- provider/bootstrap identity; the only one that may run
//               006-roles.sql (role DDL).
//   MIGRATOR -- stack_migrator; owns schema `stack`; applies
//               006-knowledge-store.sql (objects only).
//   WRITER   -- stack_writer; RLS fail-closed probes, append-only grants.
//   READER   -- stack_reader; read-only under context.
//
// Uses `psql` via execFile with argument arrays only (REQ-116: no shell-
// string interpolation) -- not the vendored S3 driver, deliberately: this
// suite verifies the SQL/RLS/role layer in isolation, independent of
// Task 3's S3 transport (which doesn't exist yet when this task is
// authored) and independent of which provider hosts the target Postgres.
//
// Tests below intentionally depend on declaration order (node:test runs a
// single file's top-level tests sequentially by default): the "matching
// insert succeeds" probe writes a row that later probes (UPDATE/DELETE
// rejected) address by id. Do not add `{ concurrency: true }` here.

const execFileAsync = promisify(execFile);

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMAS_DIR = join(__dirname, "..", "..", "..", "schemas");
const ROLES_SQL = join(SCHEMAS_DIR, "006-roles.sql");
const STORE_SQL = join(SCHEMAS_DIR, "006-knowledge-store.sql");

const REQUIRED_ENV = ["PM_TEST_DB_URL_ADMIN", "PM_TEST_DB_URL_MIGRATOR", "PM_TEST_DB_URL_WRITER", "PM_TEST_DB_URL_READER"];
const MISSING_ENV = REQUIRED_ENV.filter((k) => !process.env[k]);
const GATED = MISSING_ENV.length > 0;

// Two known-shape UUIDv7-CHECK-passing literals (position 15 = '7',
// position 20 in {8,9,a,b} of the dashed text form) and one deliberately
// malformed (v4-shaped) literal, used across the probes below.
const V7_A = "018e5a00-0000-7000-8000-0000000000a1";
const V7_B = "018e5a00-0000-7000-8000-0000000000b2";
const V7_OTHER = "018e5a00-0000-7000-8000-0000000000c3"; // seeded into portfolio 'other'
const V7_WRONG_ORG = "018e5a00-0000-7000-8000-0000000000d4";
const V7_MISSING_USER = "018e5a00-0000-7000-8000-0000000000e5";
const V7_CROSS_REF = "018e5a00-0000-7000-8000-0000000000f6";
const V7_READER_INSERT = "018e5a00-0000-7000-8000-000000000107";
const V7_EMPTY_TENANT = "018e5a00-0000-7000-8000-000000000108";
const V4_MALFORMED = "11111111-1111-4111-8111-111111111111"; // version nibble '4', not '7'

// briefData fixture (Task 5 review follow-up): distinct literals so this
// doesn't collide with the rows the probes above leave behind.
const V7_BRIEF_STALE = "018e5a00-0000-7000-8000-000000000201";
const V7_BRIEF_STALE_2 = "018e5a00-0000-7000-8000-000000000207";
const V7_BRIEF_PENDING = "018e5a00-0000-7000-8000-000000000202";
const V7_BRIEF_RESOLVED = "018e5a00-0000-7000-8000-000000000203";
const V7_BRIEF_RESOLVED_OUTCOME = "018e5a00-0000-7000-8000-000000000204";
const V7_BRIEF_OVERRIDE = "018e5a00-0000-7000-8000-000000000205";
const V7_BRIEF_CHALLENGE = "018e5a00-0000-7000-8000-000000000206";

// Postgres error-message fragments each negative probe below asserts
// against (review finding Important #6: a bare `assert.rejects()` with no
// message matcher passes on ANY failure, including the wrong one -- e.g.
// the "no context" probe below used to pass for the Critical #1 grant bug,
// not because RLS fired). Fragments, not full messages: exact wording is
// stable across Postgres 15/16, constraint names are not guaranteed to be.
const ERR = {
  RLS: /row-level security/i,
  PERMISSION_EVENTS: /permission denied for table events/i,
  CHECK_VIOLATION: /violates check constraint/i,
  FK_VIOLATION: /violates foreign key constraint/i,
  UNKNOWN_PORTFOLIO: /unknown portfolio/i,
  DAYS_GUARD: /days must be >= 1/i
};

const SEED_USER_ID = "018e5a00-1111-7000-8000-000000000001";
const SEED_ORG_ID = "carbonet-test";
const SEED_PORTFOLIO = "carbonet";
const OTHER_PORTFOLIO = "other";

function psql(url, args) {
  return execFileAsync("psql", [url, "-v", "ON_ERROR_STOP=1", "-X", "-q", ...args]);
}

function runFile(url, filePath) {
  return psql(url, ["-f", filePath]);
}

function runSql(url, sql) {
  return psql(url, ["-c", sql]);
}

async function scalar(url, sql) {
  const { stdout } = await psql(url, ["-t", "-A", "-c", sql]);
  return stdout.trim();
}

function insertEvent({
  eventId, portfolio, userId = SEED_USER_ID, orgId, type = "handoff", ref = null,
  ts = null, subjectKind = "system", subjectId = "pg-integration-test"
}) {
  const orgClause = orgId ? `'${orgId}'` : "default";
  const refClause = ref ? `'${ref}'` : "null";
  const tsClause = ts ? `'${ts}'::timestamptz` : "now()";
  return `insert into stack.events
    (event_id, org_id, portfolio, user_id, schema_version, ts, type, subject_kind, subject_id, author, producer, ref_event_id)
    values ('${eventId}', ${orgClause}, '${portfolio}', '${userId}', 1, ${tsClause}, '${type}', '${subjectKind}', '${subjectId}', 'test', 'stack@test', ${refClause});`;
}

if (GATED) {
  test(
    `pg-integration: SKIPPED -- missing env var(s): ${MISSING_ENV.join(", ")} (set all four PM_TEST_DB_URL_* to run against real Postgres; see ADR-060 Task 7 checklist)`,
    { skip: true },
    () => {}
  );
} else {
  const ADMIN = process.env.PM_TEST_DB_URL_ADMIN;
  const MIGRATOR = process.env.PM_TEST_DB_URL_MIGRATOR;
  const WRITER = process.env.PM_TEST_DB_URL_WRITER;
  const READER = process.env.PM_TEST_DB_URL_READER;

  before(async () => {
    // ADMIN: role bootstrap, run twice below (idempotency is its own test).
    await runFile(ADMIN, ROLES_SQL);
    // MIGRATOR: objects, into what Task 7 provides as an empty DB.
    await runFile(MIGRATOR, STORE_SQL);
    // Fixture data a fresh schema doesn't seed itself (org identity, the
    // two portfolios these probes need, and one non-system user).
    await runSql(MIGRATOR, `insert into stack.tenant_identity (org_id) values ('${SEED_ORG_ID}');`);
    await runSql(MIGRATOR, `insert into stack.portfolio_settings (portfolio) values ('${SEED_PORTFOLIO}'), ('${OTHER_PORTFOLIO}');`);
    await runSql(MIGRATOR, `insert into stack.users (id, emails) values ('${SEED_USER_ID}', '{"test@carbonet.internal"}');`);
    // A seed row in the OTHER portfolio, for the cross-portfolio ref probe.
    await runSql(MIGRATOR, insertEvent({ eventId: V7_OTHER, portfolio: OTHER_PORTFOLIO }));
  });

  test("ADMIN: 006-roles.sql is idempotent -- second apply is a no-op", async () => {
    await runFile(ADMIN, ROLES_SQL);
  });

  test("MIGRATOR: 006-knowledge-store.sql loaded cleanly (objects visible)", async () => {
    const count = await scalar(MIGRATOR, "select count(*) from stack.portfolio_settings;");
    assert.equal(count, "2");
  });

  test("WRITER: no context set -> SELECT returns 0 rows (fail-closed)", async () => {
    const count = await scalar(WRITER, "select count(*) from stack.events;");
    assert.equal(count, "0");
  });

  test("WRITER: no context set -> INSERT is rejected", async () => {
    await assert.rejects(() => runSql(WRITER, insertEvent({ eventId: V7_A, portfolio: SEED_PORTFOLIO })), ERR.RLS);
  });

  test("WRITER: set_portfolio('carbonet') then matching insert succeeds", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({ eventId: V7_A, portfolio: SEED_PORTFOLIO })}`;
    await runSql(WRITER, sql);
    const count = await scalar(MIGRATOR, `select count(*) from stack.events where event_id = '${V7_A}';`);
    assert.equal(count, "1");
  });

  test("WRITER: under carbonet context, insert into portfolio 'other' is rejected by WITH CHECK", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({ eventId: V7_B, portfolio: OTHER_PORTFOLIO })}`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.RLS);
  });

  test("WRITER: set_portfolio('nonexistent') raises", async () => {
    await assert.rejects(() => runSql(WRITER, "select stack.set_portfolio('nonexistent-portfolio-xyz');"), ERR.UNKNOWN_PORTFOLIO);
  });

  test("WRITER: UPDATE on events is rejected (no UPDATE grant -- append-only)", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); update stack.events set track = 'x' where event_id = '${V7_A}';`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.PERMISSION_EVENTS);
  });

  test("WRITER: DELETE on events is rejected (no DELETE grant -- append-only)", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); delete from stack.events where event_id = '${V7_A}';`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.PERMISSION_EVENTS);
  });

  test("WRITER: cross-portfolio ref_event_id is rejected", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({ eventId: V7_CROSS_REF, portfolio: SEED_PORTFOLIO, ref: V7_OTHER })}`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.FK_VIOLATION);
  });

  test("WRITER: wrong org_id is rejected", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({
      eventId: V7_WRONG_ORG,
      portfolio: SEED_PORTFOLIO,
      orgId: "definitely-not-" + SEED_ORG_ID
    })}`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.CHECK_VIOLATION);
  });

  test("WRITER: non-v7 uuid is rejected", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({ eventId: V4_MALFORMED, portfolio: SEED_PORTFOLIO })}`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.CHECK_VIOLATION);
  });

  test("WRITER: user_id not in stack.users is rejected (FK)", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({
      eventId: V7_MISSING_USER,
      portfolio: SEED_PORTFOLIO,
      userId: "018e5a00-9999-7000-8000-000000000099"
    })}`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.FK_VIOLATION);
  });

  test("WRITER: org_id CHECK fails closed when tenant_identity is empty (regression: Important #2)", async () => {
    // Live-verified bug: `org_id = current_org_id()` is NULL (not FALSE)
    // when tenant_identity is empty, and Postgres treats a NULL CHECK
    // result as satisfied -- so ANY org_id passed before this fix. The
    // fixed CHECK uses IS NOT DISTINCT FROM, which is a real FALSE here.
    await runSql(MIGRATOR, "delete from stack.tenant_identity;");
    try {
      const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({
        eventId: V7_EMPTY_TENANT,
        portfolio: SEED_PORTFOLIO,
        orgId: "TOTALLY-WRONG-ORG"
      })}`;
      await assert.rejects(() => runSql(WRITER, sql), ERR.CHECK_VIOLATION);
    } finally {
      await runSql(MIGRATOR, `insert into stack.tenant_identity (org_id) values ('${SEED_ORG_ID}');`);
    }
  });

  test("WRITER: sweep_retention rejects days < 1 (regression: Important #3)", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); select stack.sweep_retention(-1);`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.DAYS_GUARD);
  });

  test("WRITER: purge_portfolio rejects a portfolio reached via a raw SET LOCAL bypass that doesn't exist (regression: Important #4 hardening)", async () => {
    // Does NOT prove the spoofing vector is closed for a portfolio that
    // genuinely exists (it isn't -- see the dated ADR-060 addendum §B
    // amendment); this proves only that the added EXISTS re-check fires
    // for a stale/mistyped GUC value reached by bypassing set_portfolio().
    const sql = `set local "stack.portfolio" = 'totally-bogus-portfolio-xyz'; select stack.purge_portfolio();`;
    await assert.rejects(() => runSql(WRITER, sql), ERR.UNKNOWN_PORTFOLIO);
  });

  test("WRITER: portfolio context does NOT leak across transactions", async () => {
    const sql = [
      "begin;",
      `select stack.set_portfolio('${SEED_PORTFOLIO}');`,
      "commit;",
      "select count(*) from stack.events;"
    ].join(" ");
    const { stdout } = await psql(WRITER, ["-t", "-A", "-c", sql]);
    // Two statement results come back on separate lines in unaligned mode;
    // the count from the SECOND (post-commit) implicit transaction is last.
    const lines = stdout.trim().split("\n").filter(Boolean);
    assert.equal(lines.at(-1), "0", "context set in a committed transaction must not survive into the next one");
  });

  test("READER: SELECT works under context", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); select count(*) from stack.events;`;
    const { stdout } = await psql(READER, ["-t", "-A", "-c", sql]);
    const lines = stdout.trim().split("\n").filter(Boolean);
    assert.ok(Number(lines.at(-1)) >= 1, "reader should see at least the one carbonet row inserted by the writer probes");
  });

  test("READER: INSERT is rejected (no INSERT grant)", async () => {
    const sql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); ${insertEvent({ eventId: V7_READER_INSERT, portfolio: SEED_PORTFOLIO })}`;
    await assert.rejects(() => runSql(READER, sql), ERR.PERMISSION_EVENTS);
  });

  // Task 5 review follow-up (structural fix): the SHIPPED BRIEF_DATA_SQL
  // multi-CTE statement (imported directly from journal-pg.mjs, not
  // retyped) parsed and executed by real Postgres, with hand-computed
  // expected values -- this is what would have caught the Critical #1
  // cutoff-binding bug (a fake transport re-deriving its own "correct"
  // math can mask a bug in the shipped SQL; real Postgres cannot).
  test("briefData: shipped BRIEF_DATA_SQL parsed + executed by real Postgres, matches hand-computed values", async () => {
    const now = Date.now();
    const cutoffIso = new Date(now - 7 * 86_400_000).toISOString();
    const nineDaysAgo = new Date(now - 9 * 86_400_000).toISOString();
    const tenDaysAgo = new Date(now - 10 * 86_400_000).toISOString();
    const oneDayAgo = new Date(now - 1 * 86_400_000).toISOString();

    const seedSql = [
      `select stack.set_portfolio('${SEED_PORTFOLIO}');`,
      // stale: priority_call >7d old, no linked outcome. TWO of these
      // (9d, 10d), deliberately different from the ONE pending row below:
      // a boundary-operator mutation (e.g. `<` -> `>` on the stale-calls
      // CTE) would swap which rows count instead of leaving the total
      // count unchanged, so this asymmetry is load-bearing, not padding
      // (caught a real gap: an earlier single-stale-row version of this
      // fixture passed even with that exact mutation live).
      insertEvent({ eventId: V7_BRIEF_STALE, portfolio: SEED_PORTFOLIO, type: "priority_call", ts: nineDaysAgo, subjectKind: "track", subjectId: "cogs" }),
      insertEvent({ eventId: V7_BRIEF_STALE_2, portfolio: SEED_PORTFOLIO, type: "priority_call", ts: tenDaysAgo, subjectKind: "track", subjectId: "cogs2" }),
      // pending: priority_call <=7d old, no linked outcome.
      insertEvent({ eventId: V7_BRIEF_PENDING, portfolio: SEED_PORTFOLIO, type: "priority_call", ts: oneDayAgo, subjectKind: "track", subjectId: "pnl" }),
      // resolved: priority_call >7d old, BUT has a linked outcome -> excluded from staleCalls.
      insertEvent({ eventId: V7_BRIEF_RESOLVED, portfolio: SEED_PORTFOLIO, type: "priority_call", ts: nineDaysAgo, subjectKind: "track", subjectId: "evals" }),
      insertEvent({ eventId: V7_BRIEF_RESOLVED_OUTCOME, portfolio: SEED_PORTFOLIO, type: "outcome", ts: oneDayAgo, ref: V7_BRIEF_RESOLVED, subjectKind: "system", subjectId: "system" }),
      // override <=7d old, by 'architect'.
      insertEvent({ eventId: V7_BRIEF_OVERRIDE, portfolio: SEED_PORTFOLIO, type: "override", ts: oneDayAgo, subjectKind: "agent", subjectId: "architect" }),
      // challenge <=7d old, by 'cogs'.
      insertEvent({ eventId: V7_BRIEF_CHALLENGE, portfolio: SEED_PORTFOLIO, type: "challenge", ts: oneDayAgo, subjectKind: "agent", subjectId: "cogs" })
    ].join(" ");
    await runSql(WRITER, seedSql);

    // $1/$2 substituted with literals -- psql -c has no bind-parameter
    // support, matching this file's existing insertEvent()-style pattern.
    const boundSql = BRIEF_DATA_SQL.replaceAll("$1", `'${SEED_PORTFOLIO}'`).replaceAll("$2", `'${cutoffIso}'`);
    const readSql = `select stack.set_portfolio('${SEED_PORTFOLIO}'); select row_to_json(t) from (${boundSql}) t;`;
    const { stdout } = await psql(READER, ["-t", "-A", "-c", readSql]);
    const lines = stdout.trim().split("\n").filter(Boolean);
    const brief = JSON.parse(lines.at(-1));

    assert.equal(brief.counters.staleCalls, 2, "the two unresolved >7d-old priority_calls are stale; the resolved one is excluded");
    assert.equal(brief.counters.pendingPredictions, 1, "only the 1d-old unresolved priority_call is pending");
    assert.deepEqual(brief.counters.overridesByAgent, { architect: 1 });
    assert.equal(brief.recentOverrides.length, 1);
    assert.equal(brief.recentOverrides[0].event_id, V7_BRIEF_OVERRIDE);
    assert.equal(brief.recentOverrides[0].subject_id, "architect");
    assert.equal(brief.recentChallenges.length, 1);
    assert.equal(brief.recentChallenges[0].event_id, V7_BRIEF_CHALLENGE);
    assert.equal(brief.recentChallenges[0].subject_id, "cogs");
  });
}
