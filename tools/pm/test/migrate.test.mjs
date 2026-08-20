import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openJournal } from "../src/journal.mjs";
import { validateEventId } from "../src/db.mjs";
import {
  legacyEventIdToV7,
  subjectKindFor,
  openSourceDb,
  importEvents,
  finalizeMigration,
  isFinalizedPath
} from "../src/migrate.mjs";
import { main } from "../src/cli.mjs";

// ADR-060 §6 + the Migration amendment ("§E: deterministic legacy-id
// canonicalization"). Fixture journals are built via the REAL P1a
// openJournal (never a hand-rolled schema), per the task-6 brief -- so
// these tests exercise the actual on-disk shape a real ~/.claude/data
// journal has, not an approximation of it.

const MIGRATE_URL = new URL("../src/migrate.mjs", import.meta.url).href;
const USER_ID = "018e5a00-1111-7000-8000-000000000001";
const V7_PRESEEDED = "018e5a00-0000-7000-8000-0000000000aa";

function tmpJournalPath() {
  const dir = mkdtempSync(join(tmpdir(), "pm-migrate-test-"));
  return join(dir, "pm-journal.sqlite");
}

// Directly inserts a row with a hand-chosen event_id/ts/ref_event_id --
// journal.append() always mints its own randomUUID() and attachOutcome()
// always stamps `new Date().toISOString()`, so this is the only way to
// seed a fixture row with a specific id, a pathological ts (pre-1970,
// out-of-order vs. its ref target), or an unresolvable ref.
function insertRawRow(dbPath, row) {
  const db = new DatabaseSync(dbPath);
  db.prepare(
    `INSERT INTO events (event_id, schema_version, ts, type, subject, author, portfolio, ref_event_id, body)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    row.event_id,
    row.schema_version ?? 1,
    row.ts,
    row.type,
    row.subject,
    row.author,
    row.portfolio,
    row.ref_event_id ?? null,
    row.body ? JSON.stringify(row.body) : null
  );
  db.close();
}

// Fake transport: an in-memory `stack.events` engine that switches on the
// `-- migrate:<tag>` SQL comment, exactly like journal-pg.test.mjs's fake
// does for journal-pg.mjs's own tags.
//
// Enforces the SAME self-FK real Postgres has
// (events_ref_same_portfolio): an insert whose ref_event_id doesn't match
// an already-persisted row throws, exactly mimicking a live foreign-key
// violation -- this is what makes the insert-ORDER test (review finding
// #3) a genuine regression test, not just an assertion on internal state.
//
// ALSO enforces RLS context (Task 7 live-checkpoint finding, ADR-060
// addendum §A): stack.events is FORCE ROW LEVEL SECURITY, fail-closed on
// the transaction-local `stack.portfolio` GUC. Any statement in a tx call
// that touches events (insert or dest-counts) without `select
// stack.set_portfolio($1)` as an earlier statement in that SAME tx call
// throws -- exactly like real Postgres would reject the write/see zero
// rows. `contextPortfolio` resets to null on every fresh `tx()` call
// (the GUC is transaction-local, set via set_config(..., true), and each
// tx() call is its own transaction) -- context from one call never leaks
// into the next. This is what makes it impossible for the RLS-context bug
// class (migrate.mjs shipped once WITHOUT the set_portfolio prefix and
// stayed green here) to ship green again: remove the prefix from
// migrate.mjs and this fake throws immediately.
//
// `lieOnAttempt` simulates a lossy write for the parity-failure test: the
// Nth insert ATTEMPT (1-indexed, in actual send order) reports success
// (RETURNING the event_id, as a real ON CONFLICT DO NOTHING insert would)
// but never actually lands the row -- the exact silent-loss shape parity
// checking exists to catch.
//
// `existingPortfolios`/`existingUserIds` seed the pre-flight tables
// (stack.portfolio_settings / stack.users) for the dry-run pre-flight
// tests (review finding #4) -- those two tables carry no RLS in the real
// schema, so the preflight tags below deliberately do NOT require a
// set_portfolio prefix.
function makeFakeTransport({ lieOnAttempt, existingPortfolios = [], existingUserIds = [] } = {}) {
  const rows = [];
  const seen = new Set();
  let insertAttempts = 0;
  const portfolioSet = new Set(existingPortfolios);
  const userIdSet = new Set(existingUserIds);

  function rowFromParams(params) {
    const [
      event_id, portfolio, user_id, schema_version, ts, ingested_at, type,
      subject_kind, subject_id, author, producer, ref_event_id, bodyJson
    ] = params;
    return {
      event_id, portfolio, user_id, schema_version, ts, ingested_at, type,
      subject_kind, subject_id, author, producer, ref_event_id,
      body: bodyJson ? JSON.parse(bodyJson) : null
    };
  }

  async function tx(statements) {
    const results = [];
    let contextPortfolio = null; // transaction-local, resets every tx() call
    for (const { sql, params } of statements) {
      if (/select stack\.set_portfolio/i.test(sql)) {
        contextPortfolio = params[0];
        results.push([{}]);
        continue;
      }
      if (sql.includes("migrate:insert-event")) {
        insertAttempts += 1;
        const [eventId] = params;
        const portfolio = params[1];
        const refEventId = params[11];

        if (contextPortfolio !== portfolio) {
          throw new Error(
            `row-level security policy violation for table events -- insert for portfolio '${portfolio}' with no matching set_portfolio() in this tx (context: ${contextPortfolio ?? "unset"})`
          );
        }
        if (lieOnAttempt && insertAttempts === lieOnAttempt) {
          // Reports success but never persists -- the silent-loss case.
          results.push([{ event_id: eventId }]);
          continue;
        }
        if (seen.has(eventId)) {
          results.push([]); // ON CONFLICT DO NOTHING
          continue;
        }
        if (refEventId && !rows.some((r) => r.event_id === refEventId)) {
          throw new Error(`violates foreign key constraint "events_ref_same_portfolio" -- ref ${refEventId} not yet present`);
        }
        seen.add(eventId);
        rows.push(rowFromParams(params));
        results.push([{ event_id: eventId }]);
        continue;
      }
      if (sql.includes("migrate:dest-counts")) {
        if (!contextPortfolio) {
          throw new Error("row-level security policy violation for table events -- dest-counts read with no set_portfolio() in this tx");
        }
        const [producer] = params;
        const counts = {};
        for (const r of rows) {
          if (r.producer !== producer) continue;
          if (r.portfolio !== contextPortfolio) continue; // RLS: only the current portfolio is visible
          const key = `${r.type}|${r.portfolio}`;
          counts[key] = (counts[key] ?? 0) + 1;
        }
        results.push(Object.entries(counts).map(([key, count]) => {
          const [type, portfolio] = key.split("|");
          return { type, portfolio, count };
        }));
        continue;
      }
      if (sql.includes("migrate:preflight-portfolios")) {
        const [portfolios] = params;
        results.push(portfolios.filter((p) => portfolioSet.has(p)).map((p) => ({ portfolio: p })));
        continue;
      }
      if (sql.includes("migrate:preflight-user")) {
        const [userId] = params;
        results.push(userIdSet.has(userId) ? [{ "?column?": 1 }] : []);
        continue;
      }
      throw new Error(`fake transport: unrecognized SQL: ${sql}`);
    }
    return results;
  }

  return { rows, tx };
}

test("legacyEventIdToV7: deterministic across 100 in-process calls", () => {
  const row = { event_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", ts: "2024-03-01T12:00:00.000Z" };
  const first = legacyEventIdToV7(row);
  for (let i = 0; i < 100; i++) {
    assert.equal(legacyEventIdToV7(row), first);
  }
});

test("legacyEventIdToV7: output passes validateEventId({allowHistoric:true})", () => {
  const row = { event_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", ts: "2020-01-01T00:00:00.000Z" };
  const id = legacyEventIdToV7(row);
  assert.equal(validateEventId(id, { allowHistoric: true }), true);
});

test("legacyEventIdToV7: same event_id, different ts -> different id (ts drives the timestamp field)", () => {
  const a = legacyEventIdToV7({ event_id: "same-id-1234", ts: "2020-01-01T00:00:00.000Z" });
  const b = legacyEventIdToV7({ event_id: "same-id-1234", ts: "2021-01-01T00:00:00.000Z" });
  assert.notEqual(a, b);
});

test("legacyEventIdToV7: embedded timestamp field round-trips to the original ms", () => {
  const tsIso = "2024-06-15T08:30:00.123Z";
  const id = legacyEventIdToV7({ event_id: "round-trip-id", ts: tsIso });
  const tsHex = id.slice(0, 8) + id.slice(9, 13);
  assert.equal(parseInt(tsHex, 16), Date.parse(tsIso));
});

test("legacyEventIdToV7: unparsable ts throws (malformed, not silently dropped upstream)", () => {
  assert.throws(() => legacyEventIdToV7({ event_id: "x", ts: "not-a-date" }));
});

// Review finding #2: a pre-1970 ts is reachable and, before the fix,
// silently produced a non-UUID string (Date.parse gives a negative ms
// value; (-N).toString(16) emits a leading '-' into what should be a
// 12-hex-digit timestamp field). legacyEventIdToV7 must now validate its
// own output and throw instead of returning that.
test("legacyEventIdToV7: pre-1970 ts throws instead of silently producing a non-UUID", () => {
  assert.throws(
    () => legacyEventIdToV7({ event_id: "22222222-3333-4444-8555-666666666666", ts: "1969-06-01T00:00:00.000Z" }),
    /valid uuid/i
  );
});

test("legacyEventIdToV7: a row already carrying a valid v7 id passes through UNCHANGED", () => {
  const row = { event_id: V7_PRESEEDED, ts: "2020-01-01T00:00:00.000Z" };
  assert.equal(legacyEventIdToV7(row), V7_PRESEEDED);
});

test("legacyEventIdToV7: cross-process determinism -- two separate node processes produce the same id", () => {
  const script =
    `import { legacyEventIdToV7 } from "${MIGRATE_URL}";` +
    `console.log(legacyEventIdToV7({ event_id: "11111111-2222-4333-8444-555555555555", ts: "2026-01-01T00:00:00.000Z" }));`;
  const runOnce = () =>
    spawnSync(process.execPath, ["--input-type=module", "-e", script], {
      encoding: "utf8",
      env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" }
    });

  const a = runOnce();
  const b = runOnce();
  assert.equal(a.status, 0, a.stderr);
  assert.equal(b.status, 0, b.stderr);
  const idA = a.stdout.trim();
  const idB = b.stdout.trim();
  assert.match(idA, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(idA, idB);
});

test("subjectKindFor: §6 type table + ambiguous fallback", () => {
  assert.deepEqual(subjectKindFor("override"), { kind: "agent", ambiguous: false });
  assert.deepEqual(subjectKindFor("challenge"), { kind: "agent", ambiguous: false });
  assert.deepEqual(subjectKindFor("audit_verdict"), { kind: "agent", ambiguous: false });
  assert.deepEqual(subjectKindFor("matrix_change"), { kind: "agent", ambiguous: false });
  assert.deepEqual(subjectKindFor("priority_call"), { kind: "track", ambiguous: false });
  assert.deepEqual(subjectKindFor("interview_answer"), { kind: "user", ambiguous: false });
  assert.deepEqual(subjectKindFor("handoff"), { kind: "system", ambiguous: false });
  assert.deepEqual(subjectKindFor("outcome"), { kind: "system", ambiguous: true });
  assert.deepEqual(subjectKindFor("suggestion_decision"), { kind: "system", ambiguous: true });
});

function buildFixture() {
  const dbPath = tmpJournalPath();
  const journal = openJournal(dbPath);
  journal.append({
    ts: "2026-07-01T10:00:00.000Z",
    type: "priority_call",
    subject: "cogs",
    author: "pm",
    portfolio: "carbonet",
    body: { predicted: "cogs" }
  });
  const callId = journal.events("carbonet")[0].event_id;
  journal.append({
    ts: "2026-07-01T09:00:00.000Z",
    type: "override",
    subject: "architect",
    author: "user",
    portfolio: "carbonet",
    body: { positions: { caller: 1, user: 2 } }
  });
  journal.attachOutcome(callId, { result: "confirmed" });
  journal.append({
    ts: "2026-07-02T08:00:00.000Z",
    type: "handoff",
    subject: "track-a",
    author: "user",
    portfolio: "other",
    body: { state: "done" }
  });
  return { dbPath, callId };
}

test("importEvents: dry run writes nothing, counts match, remap count correct, pre-flight skipped (no transport)", async () => {
  const { dbPath } = buildFixture();
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, undefined, { dryRun: true });
  sourceDb.close();

  assert.equal(report.dryRun, true);
  assert.equal(report.totalRows, 4);
  assert.equal(report.remapCount, 4);
  assert.equal(report.passthroughCount, 0);
  assert.equal(report.malformed.length, 0);
  assert.equal(report.insertedCount, 0);
  assert.equal(report.parityOk, null);
  assert.deepEqual(report.byTypePortfolio, {
    "priority_call|carbonet": 1,
    "override|carbonet": 1,
    "outcome|carbonet": 1,
    "handoff|other": 1
  });
  // ambiguous: outcome falls to 'system' with no explicit table entry.
  assert.equal(report.ambiguousSubjectKind, 1);
  assert.equal(report.preflight.ran, false);
  assert.equal(report.preflight.skippedReason, "no transport supplied");
});

test("importEvents: a pre-seeded valid-v7 row passes through unchanged alongside remapped rows", async () => {
  const { dbPath } = buildFixture();
  insertRawRow(dbPath, {
    event_id: V7_PRESEEDED,
    ts: "2026-07-03T00:00:00.000Z",
    type: "handoff",
    subject: "track-b",
    author: "user",
    portfolio: "carbonet"
  });
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, undefined, { dryRun: true });
  sourceDb.close();

  assert.equal(report.totalRows, 5);
  assert.equal(report.remapCount, 4);
  assert.equal(report.passthroughCount, 1);
  assert.equal(report.idMap[V7_PRESEEDED], V7_PRESEEDED);
});

test("importEvents: live run twice -- second inserts 0, id maps byte-identical, ref chain survives both runs", async () => {
  const { dbPath, callId } = buildFixture();
  const transport = makeFakeTransport();

  const sourceDb1 = openSourceDb(dbPath);
  const report1 = await importEvents(sourceDb1, transport, { dryRun: false, userId: USER_ID });
  sourceDb1.close();

  assert.equal(report1.insertedCount, 4);
  assert.equal(report1.parityOk, true);

  const newCallId = report1.idMap[callId];
  assert.ok(newCallId);
  const outcomeRow = transport.rows.find((r) => r.type === "outcome");
  assert.equal(outcomeRow.ref_event_id, newCallId, "outcome must join the call via the REMAPPED id");
  const callRow = transport.rows.find((r) => r.event_id === newCallId);
  assert.equal(callRow.type, "priority_call");

  const sourceDb2 = openSourceDb(dbPath);
  const report2 = await importEvents(sourceDb2, transport, { dryRun: false, userId: USER_ID });
  sourceDb2.close();

  assert.equal(report2.insertedCount, 0, "second run must insert 0 rows (ON CONFLICT DO NOTHING + identical ids)");
  assert.deepEqual(report2.idMap, report1.idMap, "id map must be byte-identical across runs");
  assert.equal(report2.parityOk, true);

  // Ref chain still resolves correctly on the second run's own view of the data.
  const outcomeRow2 = transport.rows.find((r) => r.type === "outcome");
  assert.equal(outcomeRow2.ref_event_id, newCallId);
});

test("importEvents: original v4 id preserved at body._p1a_event_id", async () => {
  const { dbPath, callId } = buildFixture();
  const transport = makeFakeTransport();
  const sourceDb = openSourceDb(dbPath);
  await importEvents(sourceDb, transport, { dryRun: false, userId: USER_ID });
  sourceDb.close();

  const newCallId = transport.rows.find((r) => r.type === "priority_call").event_id;
  const callRow = transport.rows.find((r) => r.event_id === newCallId);
  assert.equal(callRow.body._p1a_event_id, callId);
});

test("importEvents: parity failure (fake transport silently drops a row) -> parityOk false", async () => {
  const { dbPath } = buildFixture();
  const transport = makeFakeTransport({ lieOnAttempt: 1 });
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: false, userId: USER_ID });
  sourceDb.close();

  assert.equal(report.parityOk, false);
});

test("importEvents: malformed row (unparsable ts) reported, not silently dropped, other rows still imported", async () => {
  const dbPath = tmpJournalPath();
  const journal = openJournal(dbPath);
  journal.append({
    ts: "2026-07-01T10:00:00.000Z",
    type: "handoff",
    subject: "track-a",
    author: "user",
    portfolio: "carbonet",
    body: { state: "ok" }
  });
  insertRawRow(dbPath, {
    event_id: "bad-ts-row",
    ts: "not-a-real-timestamp",
    type: "handoff",
    subject: "track-b",
    author: "user",
    portfolio: "carbonet"
  });

  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, undefined, { dryRun: true });
  sourceDb.close();

  assert.equal(report.malformed.length, 1);
  assert.equal(report.malformed[0].event_id, "bad-ts-row");
  assert.equal(report.totalRows, 2);
  assert.equal(report.remapCount, 1);
  assert.equal(report.byTypePortfolio["handoff|carbonet"], 1);
});

// Review finding #2, importEvents-level: §E requires a malformed id be
// "reported in the dry-run counts" -- this is that requirement, not just
// legacyEventIdToV7 throwing in isolation.
test("importEvents: pre-1970 ts row is reported as malformed in the dry-run counts (§E)", async () => {
  const dbPath = tmpJournalPath();
  const journal = openJournal(dbPath);
  journal.append({
    ts: "2026-07-01T10:00:00.000Z",
    type: "handoff",
    subject: "track-a",
    author: "user",
    portfolio: "carbonet",
    body: { state: "ok" }
  });
  insertRawRow(dbPath, {
    event_id: "33333333-4444-4444-8555-666666666666",
    ts: "1969-06-01T00:00:00.000Z",
    type: "handoff",
    subject: "track-b",
    author: "user",
    portfolio: "carbonet"
  });

  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, undefined, { dryRun: true });
  sourceDb.close();

  assert.equal(report.malformed.length, 1);
  assert.equal(report.malformed[0].event_id, "33333333-4444-4444-8555-666666666666");
  assert.match(report.malformed[0].reason, /valid uuid/i);
  assert.equal(report.totalRows, 2);
  assert.equal(report.remapCount, 1);
});

// Review finding #1: before the fix, an unresolvable ref fell back to the
// ORIGINAL (v4-shaped) id, which then hit the destination's composite
// self-FK and aborted the entire import mid-flight. Row B refs row A;
// row A is itself malformed (bad ts), so it's never in the id map -- B
// must be reported too, and every OTHER row must still import.
test("importEvents: unresolvable ref (target row malformed) is reported, not silently passed through, and import completes", async () => {
  const dbPath = tmpJournalPath();
  openJournal(dbPath); // creates the events table before any raw insert
  insertRawRow(dbPath, {
    event_id: "row-a-bad-ts",
    ts: "not-a-real-timestamp",
    type: "priority_call",
    subject: "cogs",
    author: "pm",
    portfolio: "carbonet"
  });
  insertRawRow(dbPath, {
    event_id: "row-b-refs-a",
    ts: "2026-07-05T00:00:00.000Z",
    type: "outcome",
    subject: "system",
    author: "pm",
    portfolio: "carbonet",
    ref_event_id: "row-a-bad-ts"
  });
  const journal = openJournal(dbPath);
  journal.append({
    ts: "2026-07-06T00:00:00.000Z",
    type: "handoff",
    subject: "track-a",
    author: "user",
    portfolio: "carbonet",
    body: { state: "unrelated, must still import" }
  });

  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, undefined, { dryRun: true });
  sourceDb.close();

  assert.equal(report.totalRows, 3);
  assert.equal(report.malformed.length, 2);
  const reasons = Object.fromEntries(report.malformed.map((m) => [m.event_id, m.reason]));
  assert.match(reasons["row-a-bad-ts"], /unparsable ts/);
  assert.match(reasons["row-b-refs-a"], /unresolvable ref: row-a-bad-ts/);
  // The unrelated handoff row still imports.
  assert.equal(report.byTypePortfolio["handoff|carbonet"], 1);
  assert.equal(Object.keys(report.byTypePortfolio).length, 1);
});

// Review finding #3: source order (ts, event_id) does not guarantee a
// ref-carrying row sorts after its target -- here the outcome's own ts
// PREDATES its call's ts. Before the fix, the FK-enforcing fake transport
// below would throw on the outcome's insert (the call not yet present);
// the fix (topological insert order) makes this succeed.
test("importEvents: outcome ts earlier than its call's ts still imports successfully (topological insert order)", async () => {
  const dbPath = tmpJournalPath();
  const journal = openJournal(dbPath);
  journal.append({
    ts: "2026-07-10T00:00:00.000Z",
    type: "priority_call",
    subject: "cogs",
    author: "pm",
    portfolio: "carbonet",
    body: { predicted: "cogs" }
  });
  const callId = journal.events("carbonet")[0].event_id;
  insertRawRow(dbPath, {
    event_id: "outcome-before-its-call",
    ts: "2026-07-01T00:00:00.000Z", // earlier than the call's ts above
    type: "outcome",
    subject: "system",
    author: "pm",
    portfolio: "carbonet",
    ref_event_id: callId
  });

  const transport = makeFakeTransport();
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: false, userId: USER_ID });
  sourceDb.close();

  assert.equal(report.malformed.length, 0);
  assert.equal(report.insertedCount, 2);
  assert.equal(report.parityOk, true);
  assert.equal(transport.rows.length, 2);
});

// Review finding #4: dry-run pre-flight, transport supplied.
test("importEvents: dry-run pre-flight reports missing portfolio and missing user when transport is supplied", async () => {
  const { dbPath } = buildFixture(); // portfolios: carbonet, other
  const transport = makeFakeTransport({ existingPortfolios: ["carbonet"], existingUserIds: [] });
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: true, userId: USER_ID });
  sourceDb.close();

  assert.equal(report.preflight.ran, true);
  assert.deepEqual(report.preflight.missingPortfolios, ["other"]);
  assert.equal(report.preflight.userIdChecked, true);
  assert.equal(report.preflight.userIdExists, false);
});

test("importEvents: dry-run pre-flight reports clean when portfolios and user all exist", async () => {
  const { dbPath } = buildFixture();
  const transport = makeFakeTransport({ existingPortfolios: ["carbonet", "other"], existingUserIds: [USER_ID] });
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: true, userId: USER_ID });
  sourceDb.close();

  assert.deepEqual(report.preflight.missingPortfolios, []);
  assert.equal(report.preflight.userIdExists, true);
});

test("importEvents: dry-run pre-flight without --user-id only checks portfolios", async () => {
  const { dbPath } = buildFixture();
  const transport = makeFakeTransport({ existingPortfolios: ["carbonet", "other"] });
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: true });
  sourceDb.close();

  assert.equal(report.preflight.ran, true);
  assert.equal(report.preflight.userIdChecked, false);
  assert.equal(report.preflight.userIdExists, null);
});

// Review fix (round 2, Important): runPreflight must degrade to
// "skipped, with reason" on a transport error -- never propagate and
// fail the whole dry run (which wrote nothing and has every reason to
// still report its counts). Most reachable case: a typo'd --user-id
// failing the $1::uuid cast in PREFLIGHT_USER_SQL.
test("importEvents: dry run still exits clean with counts when the pre-flight query itself rejects", async () => {
  const { dbPath } = buildFixture();
  const rejectingTransport = {
    async tx(statements) {
      if (statements.some((s) => s.sql.includes("migrate:preflight"))) {
        throw new Error('invalid input syntax for type uuid: "not-a-uuid"');
      }
      throw new Error("unexpected call in this test");
    }
  };
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, rejectingTransport, { dryRun: true, userId: "not-a-uuid" });
  sourceDb.close();

  assert.equal(report.dryRun, true);
  assert.equal(report.totalRows, 4);
  assert.equal(report.remapCount, 4);
  assert.equal(report.preflight.ran, false);
  assert.match(report.preflight.skippedReason, /invalid input syntax for type uuid/);
});

test("cli pm migrate: --dry-run pre-flight rejection still exits 0, reported as skipped-with-reason", async () => {
  const { dbPath } = buildFixture();
  const rejectingTransport = {
    async tx() {
      throw new Error('invalid input syntax for type uuid: "not-a-uuid"');
    }
  };
  const deps = cliDeps({ transport: rejectingTransport });
  const result = await main(["migrate", "--from", dbPath, "--dry-run", "--user-id", "not-a-uuid"], deps);

  assert.equal(result.code, 0);
  assert.equal(existsSync(dbPath), true);
  assert.ok(deps.stdoutLines.some((l) => l.includes("pre-flight skipped") && l.includes("invalid input syntax")));
  assert.ok(
    !deps.stdoutLines.some((l) => l.includes("import failed")),
    "a pre-flight-only failure must never be reported as an import failure"
  );
});

// Minor #10 (untested passthrough-ref path) -- a ref pointing at a row
// that already carries a valid v7 id (so the id map maps it to itself)
// must still resolve correctly, not just for a remapped target.
test("importEvents: a ref pointing at an already-v7 (passthrough) row resolves through the id map unchanged", async () => {
  const dbPath = tmpJournalPath();
  openJournal(dbPath); // creates the events table before any raw insert
  insertRawRow(dbPath, {
    event_id: V7_PRESEEDED,
    ts: "2026-07-01T00:00:00.000Z",
    type: "priority_call",
    subject: "cogs",
    author: "pm",
    portfolio: "carbonet"
  });
  insertRawRow(dbPath, {
    event_id: "v4-outcome-refs-passthrough",
    ts: "2026-07-02T00:00:00.000Z",
    type: "outcome",
    subject: "system",
    author: "pm",
    portfolio: "carbonet",
    ref_event_id: V7_PRESEEDED
  });

  const transport = makeFakeTransport();
  const sourceDb = openSourceDb(dbPath);
  const report = await importEvents(sourceDb, transport, { dryRun: false, userId: USER_ID });
  sourceDb.close();

  assert.equal(report.parityOk, true);
  const outcomeRow = transport.rows.find((r) => r.type === "outcome");
  assert.equal(outcomeRow.ref_event_id, V7_PRESEEDED);
});

test("finalizeMigration: renames to <path>.migrated and refuses to double-finalize", () => {
  const { dbPath } = buildFixture();
  const finalPath = finalizeMigration(dbPath);
  assert.equal(finalPath, `${dbPath}.migrated`);
  assert.equal(existsSync(dbPath), false);
  assert.equal(existsSync(finalPath), true);
  assert.throws(() => finalizeMigration(finalPath));
  assert.equal(isFinalizedPath(finalPath), true);
  assert.equal(isFinalizedPath(dbPath), false);
});

// ---------------------------------------------------------------------
// CLI-level tests (`pm migrate`), via cli.mjs's main() -- real fixture
// files on disk, a fake transport injected through deps.transport.
// ---------------------------------------------------------------------

function cliDeps(overrides = {}) {
  const stdoutLines = [];
  return {
    stdout: (line) => stdoutLines.push(line),
    stdoutLines,
    transport: overrides.transport,
    ...overrides
  };
}

test("cli pm migrate: --dry-run with no transport -- pre-flight skipped, nothing renamed", async () => {
  const { dbPath } = buildFixture();
  const deps = cliDeps({});
  const result = await main(["migrate", "--from", dbPath, "--dry-run"], deps);

  assert.equal(result.code, 0);
  assert.equal(existsSync(dbPath), true);
  assert.equal(existsSync(`${dbPath}.migrated`), false);
  assert.ok(deps.stdoutLines.some((l) => l.includes("pre-flight skipped")));
});

test("cli pm migrate: --dry-run with a transport runs the read-only pre-flight, still writes/renames nothing", async () => {
  const { dbPath } = buildFixture();
  const transport = makeFakeTransport({ existingPortfolios: ["carbonet"], existingUserIds: [] });
  const deps = cliDeps({ transport });
  const result = await main(["migrate", "--from", dbPath, "--dry-run", "--user-id", USER_ID], deps);

  assert.equal(result.code, 0);
  assert.equal(existsSync(dbPath), true, "dry run must never rename");
  assert.equal(existsSync(`${dbPath}.migrated`), false);
  assert.equal(transport.rows.length, 0, "dry run must never insert");
  assert.ok(deps.stdoutLines.some((l) => l.includes("missing portfolio(s)") && l.includes("other")));
  assert.ok(deps.stdoutLines.some((l) => l.includes("--user-id") && l.includes("MISSING")));
});

test("cli pm migrate: live run + parity PASS finalizes (renames to .migrated)", async () => {
  const { dbPath } = buildFixture();
  const deps = cliDeps({ transport: makeFakeTransport() });
  const result = await main(["migrate", "--from", dbPath, "--user-id", USER_ID], deps);

  assert.equal(result.code, 0);
  assert.equal(existsSync(dbPath), false);
  assert.equal(existsSync(`${dbPath}.migrated`), true);
});

test("cli pm migrate: parity FAILURE -> non-zero exit, source untouched, never finalized", async () => {
  const { dbPath } = buildFixture();
  const deps = cliDeps({ transport: makeFakeTransport({ lieOnAttempt: 1 }) });
  const result = await main(["migrate", "--from", dbPath, "--user-id", USER_ID], deps);

  assert.equal(result.code, 1);
  assert.equal(existsSync(dbPath), true, "source must survive a parity failure");
  assert.equal(existsSync(`${dbPath}.migrated`), false, "must never finalize on parity failure");
});

test("cli pm migrate: accepts a .migrated source path for a post-rename re-run, without double-finalizing", async () => {
  const { dbPath } = buildFixture();
  const transport = makeFakeTransport();
  const firstDeps = cliDeps({ transport });
  const first = await main(["migrate", "--from", dbPath, "--user-id", USER_ID], firstDeps);
  assert.equal(first.code, 0);
  const migratedPath = `${dbPath}.migrated`;
  assert.equal(existsSync(migratedPath), true);

  const secondDeps = cliDeps({ transport });
  const second = await main(["migrate", "--from", migratedPath, "--user-id", USER_ID], secondDeps);

  assert.equal(second.code, 0);
  assert.equal(second.report.insertedCount, 0, "re-run against the same data must insert 0 new rows");
  assert.equal(existsSync(`${migratedPath}.migrated`), false, "must not double-rename");
});

test("cli pm migrate: --from is required", async () => {
  const deps = cliDeps({});
  const result = await main(["migrate"], deps);
  assert.equal(result.code, 1);
});

test("cli pm migrate: --user-id is required for a live run", async () => {
  const { dbPath } = buildFixture();
  const deps = cliDeps({ transport: makeFakeTransport() });
  const result = await main(["migrate", "--from", dbPath], deps);
  assert.equal(result.code, 1);
  assert.equal(existsSync(dbPath), true);
});

// Fold-in (operator safety, minor #7): a finalize (rename) failure must
// read differently from a failed import -- the data already landed and
// parity already passed; only the source-file housekeeping failed.
// Pre-creating a DIRECTORY at the target path forces a real, portable
// renameSync failure (EISDIR: source is a regular file, destination
// exists as a non-empty-incompatible directory) without needing to fake
// the filesystem.
test("cli pm migrate: finalize (rename) failure is reported distinctly from an import failure, still non-zero exit", async () => {
  const { dbPath } = buildFixture();
  mkdirSync(`${dbPath}.migrated`);
  const deps = cliDeps({ transport: makeFakeTransport() });
  const result = await main(["migrate", "--from", dbPath, "--user-id", USER_ID], deps);

  assert.equal(result.code, 1);
  assert.equal(result.report.insertedCount, 4, "the import itself must have succeeded");
  assert.equal(result.report.parityOk, true, "parity must have passed before finalize was even attempted");
  assert.equal(existsSync(dbPath), true, "a failed rename must leave the source file in place");
  assert.ok(deps.stdoutLines.some((l) => l.includes("finalize (rename) FAILED")));
  assert.ok(deps.stdoutLines.some((l) => l.includes("by hand")));
  assert.ok(
    !deps.stdoutLines.some((l) => l.includes("unexpected error")),
    "must not be reported as a generic/unexpected error, indistinguishable from an import failure"
  );
});
