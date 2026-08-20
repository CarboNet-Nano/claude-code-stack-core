import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openPgJournal } from "../src/journal-pg.mjs";
import { openJournal } from "../src/journal.mjs";
import { readOutbox } from "../src/outbox.mjs";
import { uuidv7 } from "../src/db.mjs";

// ADR-060 §4/§5/§6, Revision addendum §A/§D/§E. Fake transport below is a
// small in-memory `stack.events` engine, switching on the `--
// journal-pg:<tag>` comment each SQL string in journal-pg.mjs carries --
// deliberately NOT a regex parser of real SQL, so it stays exactly as
// robust as the tags are, not as fragile as ad hoc SQL parsing would be.
// It never imports or mentions the vendored driver (out of scope for
// Task 1's literal-scan lint, which this file is not on the allowlist
// for).

function makeFakeTransport() {
  const rows = [];
  const seenIds = new Set();
  const txCalls = [];
  let down = false;

  function insertRow(params) {
    const [
      event_id, org_id, portfolio, user_id, schema_version, ts, type,
      subject_kind, subject_id, author, repo, track, session_id, machine_id,
      producer, ref_event_id, bodyJson, redacted
    ] = params;
    if (seenIds.has(event_id)) return;
    seenIds.add(event_id);
    rows.push({
      event_id, org_id, portfolio, user_id, schema_version, ts, type,
      subject_kind, subject_id, author, repo, track, session_id, machine_id,
      producer, ref_event_id, body: bodyJson ? JSON.parse(bodyJson) : null,
      redacted: redacted ?? []
    });
  }

  function selectEvents(params) {
    let filtered = rows.filter((r) => r.portfolio === params[0]);
    if (params.length > 1) filtered = filtered.filter((r) => r.ts >= params[1]);
    return [...filtered].sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  }

  function outcomeRefs(portfolio) {
    return new Set(rows.filter((r) => r.portfolio === portfolio && r.type === "outcome").map((r) => r.ref_event_id));
  }

  function countPriorityCalls(portfolio, cutoffIso, before) {
    const refs = outcomeRefs(portfolio);
    return rows.filter(
      (r) =>
        r.portfolio === portfolio &&
        r.type === "priority_call" &&
        (before ? r.ts < cutoffIso : r.ts >= cutoffIso) &&
        !refs.has(r.event_id)
    ).length;
  }

  function overridesByAgent(portfolio, cutoffIso) {
    const out = {};
    for (const r of rows) {
      if (r.portfolio === portfolio && r.type === "override" && r.ts >= cutoffIso) {
        out[r.subject_id] = (out[r.subject_id] ?? 0) + 1;
      }
    }
    return out;
  }

  function recentByType(portfolio, type, cutoffIso) {
    return rows
      .filter((r) => r.portfolio === portfolio && r.type === type && r.ts >= cutoffIso)
      .sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0))
      .map((r) => ({
        event_id: r.event_id,
        ref_event_id: r.ref_event_id,
        subject_id: r.subject_id,
        session_id: r.session_id,
        ts: r.ts
      }));
  }

  function execStatement(stmt, currentPortfolio) {
    const { sql, params } = stmt;
    if (/select stack\.set_portfolio/i.test(sql)) return [{}];
    if (sql.includes("journal-pg:insert-event")) {
      insertRow(params);
      return [];
    }
    if (sql.includes("journal-pg:events")) return selectEvents(params);
    if (sql.includes("journal-pg:stale-calls")) return [{ count: countPriorityCalls(params[0], params[1], true) }];
    if (sql.includes("journal-pg:pending-predictions")) return [{ count: countPriorityCalls(params[0], params[1], false) }];
    if (sql.includes("journal-pg:overrides-by-agent")) {
      return Object.entries(overridesByAgent(params[0], params[1])).map(([subject_id, count]) => ({ subject_id, count }));
    }
    if (sql.includes("journal-pg:ref-exists")) {
      // RLS-equivalent: only visible within the currently-set portfolio,
      // same as every other statement here.
      const [refEventId] = params;
      return rows.some((r) => r.portfolio === currentPortfolio && r.event_id === refEventId) ? [{ "?column?": 1 }] : [];
    }
    if (sql.includes("journal-pg:brief-data")) {
      // $2 is used AS-IS for comparison -- it must already be the
      // pre-subtracted cutoff, exactly as journal-pg.mjs's briefData()
      // computes it before sending, exactly like counters()'s statements.
      // Do NOT re-derive a 7-day subtraction here: that's the bug that
      // let the real cutoff bug ship green (Critical #2) -- this double
      // must model the real wire contract, not the intended one.
      const [portfolio, cutoffIso] = params;
      return [
        {
          counters: {
            staleCalls: countPriorityCalls(portfolio, cutoffIso, true),
            overridesByAgent: overridesByAgent(portfolio, cutoffIso),
            pendingPredictions: countPriorityCalls(portfolio, cutoffIso, false)
          },
          recentOverrides: recentByType(portfolio, "override", cutoffIso),
          recentChallenges: recentByType(portfolio, "challenge", cutoffIso)
        }
      ];
    }
    if (/purge_portfolio/i.test(sql)) {
      for (let i = rows.length - 1; i >= 0; i--) {
        if (rows[i].portfolio === currentPortfolio) rows.splice(i, 1);
      }
      return [];
    }
    if (/sweep_retention/i.test(sql)) return [];
    throw new Error(`fake transport: unrecognized statement: ${sql.slice(0, 60)}`);
  }

  return {
    setDown(v) {
      down = v;
    },
    get txCalls() {
      return txCalls;
    },
    get rowCount() {
      return rows.length;
    },
    async tx(statements) {
      if (down) throw new Error("transport down");
      txCalls.push(statements);
      let currentPortfolio = null;
      return statements.map((s) => {
        if (/select stack\.set_portfolio/i.test(s.sql)) currentPortfolio = s.params[0];
        return execStatement(s, currentPortfolio);
      });
    }
  };
}

function makeJournal(overrides = {}) {
  const transport = overrides.transport ?? makeFakeTransport();
  const outboxPath = overrides.outboxPath ?? join(mkdtempSync(join(tmpdir(), "pm-outbox-")), "pm-outbox.ndjson");
  const journal = openPgJournal({
    transport,
    orgId: "carbonet-test",
    userId: "018e5a00-1111-7000-8000-000000000001",
    producer: "stack@p1b-test",
    outboxPath,
    sessionId: "sess-1",
    machineId: "machine-1",
    ...overrides
  });
  return { journal, transport, outboxPath };
}

const baseEvent = { portfolio: "carbonet", ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "architect", author: "user", body: { note: "fine" } };

test("append issues exactly one tx whose first statement is set_portfolio with the event's portfolio", async () => {
  const { journal, transport } = makeJournal();
  await journal.append({ ...baseEvent, portfolio: "carbonet" });

  assert.equal(transport.txCalls.length, 1);
  const [first] = transport.txCalls[0];
  assert.match(first.sql, /set_portfolio/i);
  assert.deepEqual(first.params, ["carbonet"]);
});

test("transport rejection routes the fully-formed event to the outbox verbatim, file mode 0600, unsentCount()===1", async () => {
  const transport = makeFakeTransport();
  transport.setDown(true);
  const { journal, outboxPath } = makeJournal({ transport });

  const eventId = await journal.append({ ...baseEvent });

  assert.equal(journal.unsentCount(), 1);
  assert.equal(statSync(outboxPath).mode & 0o777, 0o600);
  const [queued] = readOutbox(outboxPath);
  assert.equal(queued.event_id, eventId);
  assert.equal(queued.portfolio, "carbonet");
});

test("transport rejection: the OUTBOXED body is already redacted, never the secret, before it ever touches disk", async () => {
  const transport = makeFakeTransport();
  transport.setDown(true);
  const { journal, outboxPath } = makeJournal({ transport });

  await journal.append({ ...baseEvent, body: { note: "conn: postgres://user:pass@h/db" } });

  const [queued] = readOutbox(outboxPath);
  assert.doesNotMatch(JSON.stringify(queued.body), /pass@h/);
  assert.equal(queued.body.note, "[REDACTED]");
  assert.deepEqual(queued.redacted, ["body.note"]);
});

test("flushOutbox() explicitly drains queued events without waiting for the next append", async () => {
  const transport = makeFakeTransport();
  const { journal } = makeJournal({ transport });

  transport.setDown(true);
  await journal.append({ ...baseEvent });
  assert.equal(journal.unsentCount(), 1);

  transport.setDown(false);
  const result = await journal.flushOutbox();

  assert.deepEqual(result, { sent: 1, remaining: 0 });
  assert.equal(journal.unsentCount(), 0);
  assert.equal(transport.rowCount, 1);
});

test("next successful append drains the outbox first (ordering asserted)", async () => {
  const transport = makeFakeTransport();
  const outboxPath = join(mkdtempSync(join(tmpdir(), "pm-outbox-")), "pm-outbox.ndjson");
  const { journal } = makeJournal({ transport, outboxPath });

  transport.setDown(true);
  const firstId = await journal.append({ ...baseEvent, ts: "2026-08-08T11:00:00Z" });
  assert.equal(journal.unsentCount(), 1);

  transport.setDown(false);
  const secondId = await journal.append({ ...baseEvent, ts: "2026-08-08T12:00:00Z" });
  assert.equal(journal.unsentCount(), 0);

  // The drained (older, queued) event's insert must appear in the
  // transport call log before the new event's own insert.
  const insertedIds = transport.txCalls
    .flat()
    .filter((s) => s.sql.includes("journal-pg:insert-event"))
    .map((s) => s.params[0]);
  assert.deepEqual(insertedIds, [firstId, secondId]);
});

test("attachOutcome: malformed ref event id throws before touching the outbox", async () => {
  const { journal } = makeJournal();
  await assert.rejects(() => journal.attachOutcome("not-a-uuid", { result: "met" }, "carbonet"));
  assert.equal(journal.unsentCount(), 0);
});

test("attachOutcome: valid ref event id appends an outcome event linked by ref_event_id", async () => {
  const { journal, transport } = makeJournal();
  const callId = await journal.append({ ...baseEvent, type: "priority_call", body: { predicted: "ships" } });
  const outcomeId = await journal.attachOutcome(callId, { result: "met" }, "carbonet");
  assert.ok(outcomeId);
  assert.equal(transport.rowCount, 2);
});

test("attachOutcome: well-formed but nonexistent ref throws 'not found' (P1a parity), never reaches the outbox", async () => {
  const { journal, transport } = makeJournal();
  const neverAppended = uuidv7(); // valid shape, never inserted anywhere
  await assert.rejects(() => journal.attachOutcome(neverAppended, { result: "met" }, "carbonet"), /not found/i);
  assert.equal(journal.unsentCount(), 0);
  assert.equal(transport.rowCount, 0);
});

test("attachOutcome: transport down during the ref-exists probe -- no throw, the outcome event lands in the outbox instead of being lost (review round 3 regression)", async () => {
  const transport = makeFakeTransport();
  const { journal, outboxPath } = makeJournal({ transport });
  const callId = await journal.append({ ...baseEvent, type: "priority_call", body: { predicted: "ships" } });

  transport.setDown(true);
  const outcomeId = await journal.attachOutcome(callId, { result: "met" }, "carbonet");

  assert.ok(outcomeId, "attachOutcome must resolve, not reject, when the outage is in the probe itself");
  assert.equal(journal.unsentCount(), 1);
  const [queued] = readOutbox(outboxPath);
  assert.equal(queued.event_id, outcomeId);
  assert.equal(queued.type, "outcome");
  assert.equal(queued.ref_event_id, callId);
});

test("attachOutcome: a ref that exists only in a SIBLING portfolio is 'not found' under this one (RLS-equivalent)", async () => {
  const { journal, transport } = makeJournal();
  const otherPortfolioCallId = await journal.append({ ...baseEvent, portfolio: "lade", type: "priority_call", body: { predicted: "x" } });
  await assert.rejects(() => journal.attachOutcome(otherPortfolioCallId, { result: "met" }, "carbonet"), /not found/i);
  assert.equal(transport.rowCount, 1, "the sibling-portfolio event itself must still exist, untouched");
});

test("poison-pill guard: an unknown event type throws before the transport, never lands in the outbox", async () => {
  const { journal, transport } = makeJournal();
  await assert.rejects(() => journal.append({ ...baseEvent, type: "not_a_real_type" }), /unknown event type/i);
  assert.equal(journal.unsentCount(), 0);
  assert.equal(transport.txCalls.length, 0, "must throw before ever calling the transport");
});

test("poison-pill guard: missing author throws before the transport, never lands in the outbox", async () => {
  const { journal, transport } = makeJournal();
  const { author, ...withoutAuthor } = baseEvent;
  await assert.rejects(() => journal.append({ ...withoutAuthor }), /author is required/i);
  assert.equal(journal.unsentCount(), 0);
  assert.equal(transport.txCalls.length, 0);
});

test("poison-pill guard: 'decision' is a valid PG-only type (ADR-060 §6, REQ-147), not rejected", async () => {
  const { journal } = makeJournal();
  const id = await journal.append({ ...baseEvent, type: "decision", body: { note: "chose x" } });
  assert.ok(id);
});

test("REQ-144 parity: postgres credential in body redacted + flagged", async () => {
  const { journal } = makeJournal();
  await journal.append({ ...baseEvent, body: { note: "conn: postgres://user:pass@h/db" } });
  const events = await journal.events("carbonet");
  const row = events.find((e) => e.type === "challenge");
  assert.doesNotMatch(JSON.stringify(row.body), /pass@h/);
  assert.deepEqual(row.redacted, ["body.note"]);
});

test("REQ-144 parity: absolute path in body redacted + flagged (new assertion class vs P1a)", async () => {
  const { journal } = makeJournal();
  await journal.append({ ...baseEvent, body: { note: "/Users/bill/x" } });
  const events = await journal.events("carbonet");
  const row = events.find((e) => e.type === "challenge");
  assert.notEqual(row.body.note, "/Users/bill/x");
  assert.deepEqual(row.redacted, ["body.note"]);
});

test("REQ-144 parity: nested-depth secret caught (walker depth parity with P1a)", async () => {
  const { journal } = makeJournal();
  await journal.append({ ...baseEvent, body: { positions: { caller: { deep: "ghp_abcdefghijklmnopqrstuvwxyz012345" } } } });
  const events = await journal.events("carbonet");
  const row = events.find((e) => e.type === "challenge");
  assert.equal(row.body.positions.caller.deep, "[REDACTED]");
  assert.deepEqual(row.redacted, ["body.positions.caller.deep"]);
});

test("REQ-140 unchanged: events() without portfolio throws", async () => {
  const { journal } = makeJournal();
  await assert.rejects(() => journal.events());
});

test("briefData: exactly one tx; returns counters + recentOverrides + recentChallenges from a seeded fixture", async () => {
  const { journal, transport } = makeJournal();
  const now = Date.parse("2026-08-08T12:00:00Z");
  const at = (d) => new Date(now - d * 86_400_000).toISOString();

  const staleCall = await journal.append({ ...baseEvent, ts: at(9), type: "priority_call", body: { predicted: "p" } });
  // A SECOND, genuinely-stale-and-unresolved call: the only OTHER >7d-old
  // priority_call (staleCall, above) gets resolved a few lines down, so
  // without this row staleCalls would correctly be 0 -- a value plenty of
  // binding-site bugs also produce by accident, making the assertion
  // below weak. This row gives staleCalls a genuine, nonzero, asserted
  // value (1) distinct from pendingPredictions (also 1, but from a
  // different row and a different comparison side of the cutoff), so a
  // regression that mis-binds or drops the cutoff (e.g. Critical #1,
  // where briefData() bound $2 to `now` instead of `now-7d`) changes this
  // count instead of leaving it coincidentally correct.
  await journal.append({ ...baseEvent, ts: at(10), type: "priority_call", subject: "unresolved-stale", body: { predicted: "still open" } });
  await journal.append({ ...baseEvent, ts: at(1), type: "priority_call", body: { predicted: "pending" } });
  await journal.attachOutcome(staleCall, { result: "met" }, "carbonet"); // resolves the 9d-old call, not stale
  await journal.append({ ...baseEvent, ts: at(1), type: "override", subject: "architect", body: { positions: { caller: "x", user: "y" } } });
  await journal.append({ ...baseEvent, ts: at(1), type: "challenge", subject: "cogs", body: {} });

  const callsBefore = transport.txCalls.length;
  const brief = await journal.briefData("carbonet", now);
  assert.equal(transport.txCalls.length, callsBefore + 1, "briefData must issue exactly one tx");
  assert.equal(transport.txCalls.at(-1).length, 2, "that tx must be exactly [set_portfolio, brief query]");

  assert.equal(brief.counters.staleCalls, 1, "only the unresolved 10d-old call is stale; the resolved 9d-old call is excluded");
  assert.equal(brief.counters.pendingPredictions, 1);
  assert.equal(brief.counters.overridesByAgent.architect, 1);
  assert.equal(brief.recentOverrides.length, 1);
  assert.equal(brief.recentOverrides[0].subject_id, "architect");
  assert.equal(brief.recentChallenges.length, 1);
  assert.equal(brief.recentChallenges[0].subject_id, "cogs");
});

test("purge invokes stack.purge_portfolio, not DELETE", async () => {
  const { journal, transport } = makeJournal();
  await journal.append({ ...baseEvent });
  await journal.purge("carbonet");

  const last = transport.txCalls.at(-1);
  assert.match(last[1].sql, /purge_portfolio/i);
  assert.doesNotMatch(last[1].sql, /\bdelete\b/i);
  assert.equal(transport.rowCount, 0);
});

test("parity: every P1a journal method name exists on the PG engine", () => {
  const legacyPath = join(mkdtempSync(join(tmpdir(), "pmdb-")), "j.sqlite");
  const legacy = openJournal(legacyPath);
  const { journal: pg } = makeJournal();

  for (const name of ["append", "attachOutcome", "events", "counters", "purge", "sweepRetention"]) {
    assert.equal(typeof legacy[name], "function", `legacy missing ${name}`);
    assert.equal(typeof pg[name], "function", `pg engine missing ${name}`);
  }
});

async function runAppendEventsCountersFixture(j, portfolio) {
  const now = Date.parse("2026-08-08T12:00:00Z");
  const at = (d) => new Date(now - d * 86_400_000).toISOString();
  await j.append({ portfolio, ts: at(9), type: "priority_call", subject: "cogs", author: "pm", body: { predicted: "p" } });
  await j.append({ portfolio, ts: at(1), type: "override", subject: "architect", author: "user", body: { positions: { caller: "x", user: "y" } } });
  const events = await j.events(portfolio);
  assert.equal(events.length, 2);
  const counters = await j.counters(portfolio, now);
  assert.equal(counters.staleCalls, 1);
  assert.equal(counters.overridesByAgent.architect, 1);
  assert.equal(counters.pendingPredictions, 0);
}

test("parity: shared append -> events -> counters fixture passes against P1a's SQLite engine", async () => {
  const legacy = openJournal(join(mkdtempSync(join(tmpdir(), "pmdb-")), "j.sqlite"));
  await runAppendEventsCountersFixture(legacy, "carbonet");
});

test("parity: shared append -> events -> counters fixture passes against the Postgres engine", async () => {
  const { journal } = makeJournal();
  await runAppendEventsCountersFixture(journal, "carbonet");
});
