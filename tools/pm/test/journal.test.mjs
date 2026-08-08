import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openJournal } from "../src/journal.mjs";

const db = () => openJournal(join(mkdtempSync(join(tmpdir(), "pmdb-")), "j.sqlite"));
const base = { ts: "2026-08-08T12:00:00Z", subject: "architect", author: "user", portfolio: "carbonet" };

test("REQ-140: override joins its priority_call via ref_event_id", () => {
  const j = db();
  const callId = j.append({ ...base, type: "priority_call", subject: "cogs", author: "pm", body: { predicted: "ships this week" } });
  const ovId = j.append({ ...base, type: "override", ref_event_id: callId, body: { positions: { caller: "cogs first", user: "evals first" } } });
  const ov = j.events("carbonet").find((e) => e.event_id === ovId);
  assert.equal(ov.ref_event_id, callId);
});

test("REQ-140: outcome attaches as linked event, original row immutable", () => {
  const j = db();
  const callId = j.append({ ...base, type: "priority_call", subject: "cogs", author: "pm", body: { predicted: "x" } });
  j.attachOutcome(callId, { result: "met" });
  const rows = j.events("carbonet");
  assert.equal(rows.length, 2);
  assert.equal(rows.find((e) => e.event_id === callId).body.predicted, "x");
});

test("REQ-141: counters use the outcome JOIN, 7d windows (UTC)", () => {
  const j = db();
  const now = Date.parse("2026-08-08T12:00:00Z");
  const at = (d) => new Date(now - d * 86_400_000).toISOString();
  const old = j.append({ ...base, ts: at(9), type: "priority_call", subject: "a", author: "pm", body: { predicted: "p" } });
  j.append({ ...base, ts: at(8), type: "priority_call", subject: "b", author: "pm", body: { predicted: "p" } }); // stale
  j.attachOutcome(old, { result: "met" }); // resolved → not stale
  j.append({ ...base, ts: at(1), type: "override", body: { positions: { caller: "x", user: "y" } } });
  const c = j.counters("carbonet", now);
  assert.equal(c.staleCalls, 1);
  assert.equal(c.overridesByAgent.architect, 1);
  assert.equal(c.pendingPredictions, 0);
});

test("REQ-140: two TRULY concurrent writer processes, no torn rows", async () => {
  const j = db();
  const path = j.path;
  const script = (n) => `import { openJournal } from ${JSON.stringify(new URL("../src/journal.mjs", import.meta.url).pathname)};
const j = openJournal(${JSON.stringify(path)});
for (let i = 0; i < 50; i++) j.append({ ts: new Date().toISOString(), type: "challenge", subject: "t${n}", author: "pm", portfolio: "carbonet", body: { i } });`;
  // spawn (non-blocking) both BEFORE awaiting either — real overlap, unlike spawnSync
  const { spawn } = await import("node:child_process");
  const run = (n) => new Promise((res, rej) => {
    const p = spawn(process.execPath, ["--input-type=module", "-e", script(n)], { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    p.stderr.on("data", (d) => (err += d));
    p.on("exit", (code) => (code === 0 ? res() : rej(new Error(err))));
  });
  await Promise.all([run(1), run(2)]);
  assert.equal(openJournal(path).events("carbonet").length, 100);
});

test("REQ-146: sweepRetention deletes only rows older than the window", () => {
  const j = db();
  const now = Date.parse("2026-08-08T12:00:00Z");
  j.append({ ...base, ts: new Date(now - 400 * 86_400_000).toISOString(), type: "challenge", body: {} });
  j.append({ ...base, ts: new Date(now - 10 * 86_400_000).toISOString(), type: "challenge", body: {} });
  j.sweepRetention(now, 365);
  assert.equal(j.events("carbonet").length, 1);
});

test("REQ-140: events() without portfolio throws", () => {
  assert.throws(() => db().events());
});

test("REQ-146: purge removes only the named portfolio", () => {
  const j = db();
  j.append({ ...base, type: "challenge", body: {} });
  j.append({ ...base, type: "challenge", portfolio: "lade", body: {} });
  j.purge("carbonet");
  assert.deepEqual(j.events("lade").map((e) => e.portfolio), ["lade"]);
});

test("REQ-144 discipline: secret-shaped body rejected; unknown type rejected", () => {
  const j = db();
  assert.throws(() => j.append({ ...base, type: "challenge", body: { note: "ghp_abcdefghijklmnopqrstuvwxyz012345" } }));
  assert.throws(() => j.append({ ...base, type: "vibe", body: {} }));
});

test("REQ-140: handoff event appends successfully; unknown type still throws", () => {
  const j = db();
  const handoffId = j.append({ ...base, type: "handoff", body: { note: "session complete" } });
  assert(handoffId);
  const events = j.events("carbonet");
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "handoff");
  assert.throws(() => j.append({ ...base, type: "unknown_type", body: {} }));
});
