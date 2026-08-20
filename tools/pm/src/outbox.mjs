import {
  existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, chmodSync,
  openSync, closeSync, writeSync, unlinkSync
} from "node:fs";
import { dirname } from "node:path";

// ADR-060 §6: a write-ahead outbox, not a cache. NDJSON, mode 0600, never
// read to answer a query -- only unacknowledged writes, drained in file
// order (oldest first) before any new append (journal-pg.mjs's
// drainOutboxFirst).
const FILE_MODE = 0o600;
const LOCK_SUFFIX = ".lock";

// #149: drain (brief, on successful connection) and append (handoff/
// closeout) are two writers of the same file. Drain's shape is
// read-all -> send -> rewrite-remainder; an append landing between the
// read and the rewrite was silently overwritten by the rewrite, which
// only knows about what it read. An O_EXCL ('wx') lockfile below
// serializes the two so no append window falls inside a drain's
// read-...-rewrite span.
//
// A lock older than this is presumed to belong to a process that died
// mid-critical-section rather than one still working -- broken so a dead
// holder can never wedge every future reader/writer forever. 30s is
// generous next to a single drain or append pass.
const STALE_LOCK_MS = 30_000;

// Drain is opportunistic by design (ADR-060 §6: "drain can just skip this
// round") -- try once, don't make a background brief refresh spin-wait on
// a lock someone else is actively holding.
const DRAIN_LOCK_MAX_WAIT_MS = 0;

// Append must never drop an event (fail-soft philosophy), so it gets a
// short bounded wait for the lock before falling back to an unlocked-but-
// still-safe write -- see appendToOutbox.
const APPEND_LOCK_MAX_WAIT_MS = 500;
const LOCK_RETRY_DELAY_MS = 25;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function lockPathFor(path) {
  return `${path}${LOCK_SUFFIX}`;
}

function isStaleLock(lockPath) {
  let raw;
  try {
    raw = readFileSync(lockPath, "utf8");
  } catch {
    return true; // gone already -- nothing to break, treat as acquirable
  }
  let meta;
  try {
    meta = JSON.parse(raw);
  } catch {
    return true; // corrupt lock file, can't trust its age -- safe to break
  }
  if (typeof meta.pid === "number") {
    try {
      process.kill(meta.pid, 0); // liveness probe -- doesn't actually signal
    } catch (err) {
      if (err.code === "ESRCH") return true; // holder's process is dead
    }
  }
  return typeof meta.ts !== "number" || Date.now() - meta.ts > STALE_LOCK_MS;
}

function tryCreateLock(lockPath) {
  let fd;
  try {
    fd = openSync(lockPath, "wx", FILE_MODE); // O_EXCL: only one caller can win
  } catch (err) {
    if (err.code === "EEXIST") return false;
    throw err;
  }
  try {
    writeSync(fd, JSON.stringify({ pid: process.pid, ts: Date.now() }));
  } finally {
    closeSync(fd);
  }
  return true;
}

function breakStaleLock(lockPath) {
  try {
    unlinkSync(lockPath);
  } catch {
    // Another process may have already cleared or re-acquired it --
    // fine, the next tryCreateLock call is the real arbiter.
  }
}

async function acquireLock(path, maxWaitMs) {
  const lockPath = lockPathFor(path);
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true }); // lockfile needs somewhere to live before the outbox file itself is ever created
  const deadline = Date.now() + maxWaitMs;
  for (;;) {
    if (tryCreateLock(lockPath)) return lockPath;
    if (isStaleLock(lockPath)) {
      breakStaleLock(lockPath);
      continue; // retry immediately, doesn't count against maxWaitMs
    }
    if (Date.now() >= deadline) return null;
    await sleep(LOCK_RETRY_DELAY_MS);
  }
}

function releaseLock(lockPath) {
  try {
    unlinkSync(lockPath);
  } catch {
    // Already gone -- release is best-effort, never the caller's problem.
  }
}

function ensureFile(path) {
  if (existsSync(path)) {
    chmodSync(path, FILE_MODE);
    return;
  }
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, "", { mode: FILE_MODE });
}

function writeAppend(path, event) {
  ensureFile(path);
  appendFileSync(path, `${JSON.stringify(event)}\n`);
  chmodSync(path, FILE_MODE);
}

export async function appendToOutbox(path, event) {
  const lockPath = await acquireLock(path, APPEND_LOCK_MAX_WAIT_MS);
  if (lockPath) {
    try {
      writeAppend(path, event);
    } finally {
      releaseLock(lockPath);
    }
    return;
  }
  // Lock still held after the wait (a genuinely long-running, non-stale
  // drain). Never drop the event over this -- append anyway. This is the
  // one window where a drain rewrite in flight could in theory still
  // clobber the write, but that requires a live, non-stale holder to sit
  // stuck for the entire wait without finishing or crashing, which is far
  // rarer than the alternative of silently losing a closeout event.
  writeAppend(path, event);
}

export function readOutbox(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

export function unsentCount(path) {
  return readOutbox(path).length;
}

export function clearOutbox(path) {
  ensureFile(path);
  writeFileSync(path, "", { mode: FILE_MODE });
}

// Stops at the first send failure and rewrites the remainder so ordering
// and unsent state survive a still-down transport. Never throws itself --
// a caller mid-append must never be blocked by an outbox that can't drain.
export async function drainOutbox(path, sendFn) {
  const lockPath = await acquireLock(path, DRAIN_LOCK_MAX_WAIT_MS);
  if (!lockPath) return { sent: 0, remaining: unsentCount(path), skipped: true };
  try {
    const events = readOutbox(path);
    let sent = 0;
    for (const event of events) {
      try {
        await sendFn(event);
        sent += 1;
      } catch {
        const remaining = events.slice(sent);
        writeFileSync(path, remaining.map((e) => `${JSON.stringify(e)}\n`).join(""), { mode: FILE_MODE });
        chmodSync(path, FILE_MODE);
        return { sent, remaining: remaining.length };
      }
    }
    if (events.length > 0) clearOutbox(path);
    return { sent, remaining: 0 };
  } finally {
    releaseLock(lockPath);
  }
}
