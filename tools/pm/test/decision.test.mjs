import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { main } from "../src/cli.mjs";
import { openJournal } from "../src/journal.mjs";
import { openPgJournal } from "../src/journal-pg.mjs";

// REQ-147 (Task 13). `pm decision` (append) + `pm decisions` (query,
// outcomes joined via ref_event_id) exercised against BOTH engines the CLI
// can be wired to (ADR-060 §D's injected-deps seam) -- a minimal fake
// Postgres transport (same `-- journal-pg:<tag>` switch journal-pg.test.mjs
// uses) plus the real legacy SQLite engine.

function makeFakeTransport() {
  const rows = [];
  function insertRow(params) {
    const [
      event_id, org_id, portfolio, user_id, schema_version, ts, type,
      subject_kind, subject_id, author, repo, track, session_id, machine_id,
      producer, ref_event_id, bodyJson, redacted
    ] = params;
    rows.push({
      event_id, org_id, portfolio, user_id, schema_version, ts, type,
      subject_kind, subject_id, author, repo, track, session_id, machine_id,
      producer, ref_event_id, body: bodyJson ? JSON.parse(bodyJson) : null,
      redacted: redacted ?? []
    });
  }
  function selectEvents(params) {
    return rows.filter((r) => r.portfolio === params[0]).sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  }
  function execStatement(stmt, currentPortfolio) {
    const { sql, params } = stmt;
    if (/select stack\.set_portfolio/i.test(sql)) return [{}];
    if (sql.includes("journal-pg:insert-event")) {
      insertRow(params);
      return [];
    }
    if (sql.includes("journal-pg:events")) return selectEvents(params);
    if (sql.includes("journal-pg:ref-exists")) {
      const [refEventId] = params;
      return rows.some((r) => r.portfolio === currentPortfolio && r.event_id === refEventId) ? [{ "?column?": 1 }] : [];
    }
    throw new Error(`fake transport: unrecognized statement: ${sql.slice(0, 60)}`);
  }
  return {
    async tx(statements) {
      let currentPortfolio = null;
      return statements.map((s) => {
        if (/select stack\.set_portfolio/i.test(s.sql)) currentPortfolio = s.params[0];
        return execStatement(s, currentPortfolio);
      });
    }
  };
}

function pgDeps(overrides = {}) {
  const outboxPath = join(mkdtempSync(join(tmpdir(), "pm-decision-outbox-")), "pm-outbox.ndjson");
  const journal = openPgJournal({
    transport: makeFakeTransport(),
    orgId: "carbonet-test",
    userId: "018e5a00-1111-7000-8000-000000000001",
    producer: "stack@p1b-test",
    outboxPath
  });
  const stdoutLines = [];
  return { journal, stdout: (l) => stdoutLines.push(l), stdoutLines, nowIso: () => "2026-08-08T12:00:00.000Z", ...overrides };
}

function legacyDeps(overrides = {}) {
  const dbPath = join(mkdtempSync(join(tmpdir(), "pm-decision-sqlite-")), "j.sqlite");
  const journal = openJournal(dbPath);
  const stdoutLines = [];
  return { journal, stdout: (l) => stdoutLines.push(l), stdoutLines, nowIso: () => "2026-08-08T12:00:00.000Z", ...overrides };
}

const decisionArgs = [
  "decision", "--portfolio", "carbonet", "--track", "cogs",
  "--question", "Use X or Y?", "--choice", "X",
  "--option", "X", "--option", "Y",
  "--rationale", "because reasons",
  "--ref", "spec:docs/superpowers/specs/2026-08-08-pm-layer-design.md"
];

test("REQ-147: pm decision + pm decisions round trip on fake PG transport", async () => {
  const deps = pgDeps();
  const appendResult = await main(decisionArgs, deps);
  assert.equal(appendResult.code, 0);
  assert.ok(appendResult.eventId);

  const queryResult = await main(["decisions", "--portfolio", "carbonet", "--track", "cogs"], deps);
  assert.equal(queryResult.code, 0);
  assert.equal(queryResult.decisions.length, 1);
  const [d] = queryResult.decisions;
  assert.equal(d.body.question, "Use X or Y?");
  assert.deepEqual(d.body.options, ["X", "Y"]);
  assert.equal(d.body.choice, "X");
  assert.equal(d.body.rationale, "because reasons");
  assert.deepEqual(d.body.refs, [{ kind: "spec", ref: "docs/superpowers/specs/2026-08-08-pm-layer-design.md" }]);
  assert.equal(d.outcome, null);
});

test("REQ-147: outcome joins via ref_event_id (PG engine)", async () => {
  const deps = pgDeps();
  const { eventId } = await main(decisionArgs, deps);
  await deps.journal.attachOutcome(eventId, { result: "shipped X" }, "carbonet");

  const { decisions } = await main(["decisions", "--portfolio", "carbonet", "--track", "cogs"], deps);
  assert.equal(decisions.length, 1);
  assert.deepEqual(decisions[0].outcome, { result: "shipped X" });
});

test("REQ-147: ref containing an absolute local path is REJECTED under the legacy engine", async () => {
  const deps = legacyDeps();
  const result = await main([
    "decision", "--portfolio", "carbonet", "--track", "cogs",
    "--question", "q", "--choice", "c",
    "--ref", "commit:/Users/alice/secret-notes.txt"
  ], deps);
  assert.equal(result.code, 1);
  assert.ok(deps.stdoutLines.some((l) => l.startsWith("decision refused:")));
  assert.equal(deps.journal.events("carbonet").length, 0);
});

test("REQ-147: ref containing an absolute local path is REDACTED (not rejected) under the PG engine", async () => {
  const deps = pgDeps();
  const result = await main([
    "decision", "--portfolio", "carbonet", "--track", "cogs",
    "--question", "q", "--choice", "c",
    "--ref", "commit:/Users/alice/secret-notes.txt"
  ], deps);
  assert.equal(result.code, 0);

  const { decisions } = await main(["decisions", "--portfolio", "carbonet", "--track", "cogs"], deps);
  assert.equal(decisions[0].body.refs[0].ref, "[REDACTED]");
});

test("REQ-147 amendment: ref of kind 'spec' is accepted (both lists now name spec)", async () => {
  const deps = legacyDeps();
  const result = await main([
    "decision", "--portfolio", "carbonet", "--track", "cogs",
    "--question", "q", "--choice", "c",
    "--ref", "spec:docs/foo.md"
  ], deps);
  assert.equal(result.code, 0);
});

test("REQ-147: an unknown ref kind is refused by the CLI before touching the journal", async () => {
  const deps = legacyDeps();
  const result = await main([
    "decision", "--portfolio", "carbonet", "--track", "cogs",
    "--question", "q", "--choice", "c",
    "--ref", "url:https://example.com"
  ], deps);
  assert.equal(result.code, 1);
  assert.equal(deps.journal.events("carbonet").length, 0);
});

test("REQ-147: pm decisions is ordered by ts", async () => {
  const times = ["2026-08-08T12:00:00.000Z", "2026-08-08T09:00:00.000Z", "2026-08-08T15:00:00.000Z"];
  let i = 0;
  const deps = legacyDeps({ nowIso: () => times[i++] });
  await main(["decision", "--portfolio", "carbonet", "--track", "cogs", "--question", "q1", "--choice", "a"], deps);
  await main(["decision", "--portfolio", "carbonet", "--track", "cogs", "--question", "q2", "--choice", "b"], deps);
  await main(["decision", "--portfolio", "carbonet", "--track", "cogs", "--question", "q3", "--choice", "c"], deps);

  const { decisions } = await main(["decisions", "--portfolio", "carbonet", "--track", "cogs"], deps);
  assert.deepEqual(decisions.map((d) => d.body.question), ["q2", "q1", "q3"]);
});

test("REQ-147: author 'skill' accepted, author 'vibe' rejected (legacy VALID_AUTHORS)", () => {
  const dbPath = join(mkdtempSync(join(tmpdir(), "pm-decision-authors-")), "j.sqlite");
  const j = openJournal(dbPath);
  const base = {
    ts: "2026-08-08T12:00:00Z", subject: "cogs", portfolio: "carbonet",
    type: "decision", body: { question: "q", options: [], choice: "c", rationale: "", refs: [] }
  };
  assert.doesNotThrow(() => j.append({ ...base, author: "skill" }));
  assert.throws(() => j.append({ ...base, author: "vibe" }));
});

test("REQ-147: brainstorming, plan, and handoff SKILL.md each emit a decision event", () => {
  const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
  for (const skill of ["brainstorming", "plan", "handoff"]) {
    const content = readFileSync(join(repoRoot, "skills", skill, "SKILL.md"), "utf8");
    assert.ok(content.includes("pm decision"), `${skill}/SKILL.md must reference 'pm decision'`);
  }
});
