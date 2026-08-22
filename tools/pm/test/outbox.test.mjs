import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, existsSync, mkdtempSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendToOutbox, readOutbox, unsentCount, clearOutbox, drainOutbox } from "../src/outbox.mjs";

// ADR-060 §6: NDJSON write-ahead outbox, mode 0600, never read to answer a
// query -- only unacknowledged writes.

const outboxPath = () => join(mkdtempSync(join(tmpdir(), "pm-outbox-")), "pm-outbox.ndjson");
const evt = (n) => ({ event_id: `evt-${n}`, portfolio: "carbonet", type: "challenge", body: { n } });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A lockfile that looks live (pid + fresh timestamp) so isStaleLock() must
// not break it -- used to simulate a genuine concurrent holder.
function writeLiveLock(path, { pid = process.pid, ts = Date.now() } = {}) {
  writeFileSync(`${path}.lock`, JSON.stringify({ pid, ts }));
}

// A lockfile that looks like it belongs to a process that crashed.
function writeDeadLock(path, { ts = Date.now() } = {}) {
  // A pid this large is never a real running process id.
  writeFileSync(`${path}.lock`, JSON.stringify({ pid: 999999, ts }));
}

test("appendToOutbox creates the file mode 0600 and writes one NDJSON line per event", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.deepEqual(readOutbox(path), [evt(1)]);
});

test("appendToOutbox creates parent directories that don't exist yet", async () => {
  const path = join(mkdtempSync(join(tmpdir(), "pm-outbox-")), "nested", "deeper", "pm-outbox.ndjson");
  assert.equal(existsSync(path), false);
  await appendToOutbox(path, evt(1));
  assert.equal(existsSync(path), true);
  assert.equal(statSync(path).mode & 0o777, 0o600);
});

test("readOutbox on a missing file returns an empty array, not a throw", () => {
  const path = join(mkdtempSync(join(tmpdir(), "pm-outbox-")), "never-written.ndjson");
  assert.deepEqual(readOutbox(path), []);
  assert.equal(unsentCount(path), 0);
});

test("unsentCount reflects the number of queued events", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  await appendToOutbox(path, evt(2));
  await appendToOutbox(path, evt(3));
  assert.equal(unsentCount(path), 3);
});

test("clearOutbox empties the file without deleting it", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  clearOutbox(path);
  assert.deepEqual(readOutbox(path), []);
  assert.equal(existsSync(path), true);
});

test("drainOutbox sends every queued event in file order and empties the file on full success", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  await appendToOutbox(path, evt(2));
  await appendToOutbox(path, evt(3));

  const sentOrder = [];
  const result = await drainOutbox(path, async (e) => {
    sentOrder.push(e.event_id);
  });

  assert.deepEqual(sentOrder, ["evt-1", "evt-2", "evt-3"]);
  assert.deepEqual(result, { sent: 3, remaining: 0 });
  assert.equal(unsentCount(path), 0);
});

test("drainOutbox on an empty outbox is a no-op, never calls sendFn", async () => {
  const path = outboxPath();
  let calls = 0;
  const result = await drainOutbox(path, async () => {
    calls += 1;
  });
  assert.equal(calls, 0);
  assert.deepEqual(result, { sent: 0, remaining: 0 });
});

test("drainOutbox stops at the first send failure, preserving order and remaining count -- never throws itself", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  await appendToOutbox(path, evt(2));
  await appendToOutbox(path, evt(3));

  const sentOrder = [];
  const result = await drainOutbox(path, async (e) => {
    if (e.event_id === "evt-2") throw new Error("still down");
    sentOrder.push(e.event_id);
  });

  assert.deepEqual(sentOrder, ["evt-1"]);
  assert.deepEqual(result, { sent: 1, remaining: 2 });
  assert.deepEqual(readOutbox(path), [evt(2), evt(3)]);
  assert.equal(statSync(path).mode & 0o777, 0o600, "file must stay 0600 after a partial-drain rewrite");
});

// #149: the race this issue fixes -- a concurrent append landing between
// drain's read and its rewrite used to be silently overwritten. With the
// O_EXCL lock, a real concurrent drain (slow sendFn) and append must
// serialize instead of interleaving, and no event may be lost.
test("#149: a concurrent append during a slow drain is never lost -- it either drains too or survives as still-queued", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  await appendToOutbox(path, evt(2));

  const sentIds = [];
  const drainPromise = drainOutbox(path, async (e) => {
    await sleep(60); // hold the lock across the append's whole attempt window
    sentIds.push(e.event_id);
  });

  await sleep(15); // fire while drain is holding the lock, mid-send
  const appendPromise = appendToOutbox(path, evt(3));

  const [drainResult] = await Promise.all([drainPromise, appendPromise]);

  const stillQueued = readOutbox(path).map((e) => e.event_id);
  const allAccountedFor = new Set([...sentIds, ...stillQueued]);
  assert.ok(allAccountedFor.has("evt-3"), `evt-3 must have drained or still be queued, got sent=${JSON.stringify(sentIds)} queued=${JSON.stringify(stillQueued)}`);
  assert.equal(sentIds.length + stillQueued.length >= 2, true, "evt-1/evt-2 must not vanish either");
  assert.ok(drainResult.sent >= 1);
});

test("#149: lock is released after a successful drain -- no lockfile left behind", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  await drainOutbox(path, async () => {});
  assert.equal(existsSync(`${path}.lock`), false);
});

test("#149: lock is released after a successful append -- no lockfile left behind", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  assert.equal(existsSync(`${path}.lock`), false);
});

test("#149: drainOutbox skips the round (fails soft) instead of blocking when a live lock is held", async () => {
  const path = outboxPath();
  await appendToOutbox(path, evt(1));
  writeLiveLock(path);

  let calls = 0;
  const result = await drainOutbox(path, async () => {
    calls += 1;
  });

  assert.equal(calls, 0, "drain must not touch the outbox while a live lock is held");
  assert.deepEqual(result, { sent: 0, remaining: 1, skipped: true });
  assert.deepEqual(readOutbox(path), [evt(1)], "queued event must be untouched");
});

test("#149: appendToOutbox waits briefly on a live lock, then still writes the event once it's free", async () => {
  const path = outboxPath();
  writeLiveLock(path);

  // Release the lock shortly after, like a drain finishing mid-wait.
  setTimeout(() => {
    try { unlinkSync(`${path}.lock`); } catch {}
  }, 80);

  await appendToOutbox(path, evt(1));
  assert.deepEqual(readOutbox(path), [evt(1)]);
});

test("#149: appendToOutbox never drops the event even if the lock is still held after the wait window", async () => {
  const path = outboxPath();
  writeLiveLock(path); // held for the whole test, never released

  await appendToOutbox(path, evt(1));
  assert.deepEqual(readOutbox(path), [evt(1)], "event must land even without the lock, per fail-soft/never-drop");
});

test("#149: a stale lock from a dead process is broken immediately, not waited out", async () => {
  const path = outboxPath();
  writeDeadLock(path, { ts: Date.now() }); // fresh timestamp, but the pid is dead

  const start = Date.now();
  await appendToOutbox(path, evt(1));
  const elapsed = Date.now() - start;

  assert.deepEqual(readOutbox(path), [evt(1)]);
  assert.ok(elapsed < 200, `dead-process lock should be reclaimed near-instantly, took ${elapsed}ms`);
});

test("#149: a stale lock aged past the threshold is broken even with a live-looking pid", async () => {
  const path = outboxPath();
  // Our own pid (definitely alive) but timestamped far in the past --
  // exercises the age-based branch of staleness independent of liveness.
  writeLiveLock(path, { ts: Date.now() - 60_000 });

  await appendToOutbox(path, evt(1));
  assert.deepEqual(readOutbox(path), [evt(1)]);
});

test("#149: a corrupt lockfile is treated as stale and broken rather than wedging forever", async () => {
  const path = outboxPath();
  writeFileSync(`${path}.lock`, "not json");

  await appendToOutbox(path, evt(1));
  assert.deepEqual(readOutbox(path), [evt(1)]);
});
