import { randomBytes } from "node:crypto";

// ADR-060 §2 (seam S3 — transport) + addendum §D/§E.
//
// `createTransport`'s `driver` seam is a small abstraction owned by this
// file, not the vendored package's own shape:
//   driver.connect(connectionString, {fetchImpl}?) -> {query, transaction}
// The real path lazy-imports the vendored driver (dynamic import() below,
// only reached when no `driver` is injected) and adapts it to this same
// shape. Unit tests inject a fake driver and never reach the import() line,
// which is what keeps the suite green with the vendor subtree absent
// (Task 1's deferred-state guard).

const VENDOR_MODULE_PATH = "./vendor/neon-serverless/index.mjs";

// Mirrors the REQ-144 credential-scan pattern from ADR-060 §5 so a leaked
// connection string is caught the same way wherever it could surface.
const CREDENTIAL_RE = /postgres(?:ql)?:\/\/[^\s]*:[^\s]*@/gi;

async function loadRealDriver() {
  const mod = await import(VENDOR_MODULE_PATH);
  return {
    connect(connectionString, { fetchImpl } = {}) {
      if (fetchImpl) {
        if (!mod.neonConfig) {
          throw new Error("createTransport: vendored driver exposes no config object for fetchImpl");
        }
        mod.neonConfig.fetchFunction = fetchImpl;
      }
      const sql = mod.neon(connectionString);
      return {
        query: (text, params) => sql.query(text, params ?? []),
        transaction: (pending) => sql.transaction(pending)
      };
    }
  };
}

function resolveConnectionString(descriptor) {
  const cs = typeof descriptor === "string" ? descriptor : descriptor?.connectionString;
  if (!cs) {
    throw new Error("createTransport: descriptor must include a connection string");
  }
  return cs;
}

function sanitizeError(err) {
  const rawMessage = err instanceof Error ? err.message : String(err);
  const message = rawMessage.replace(CREDENTIAL_RE, "postgres://[redacted]@");
  const sanitized = new Error(message);
  sanitized.name = err instanceof Error && err.name ? err.name : "TransportError";
  return sanitized;
}

async function runQuery(client, text, params) {
  try {
    return await client.query(text, params ?? []);
  } catch (err) {
    throw sanitizeError(err);
  }
}

async function runTx(client, statements) {
  if (!Array.isArray(statements) || statements.length === 0) {
    throw new Error("tx: statements must be a non-empty array of {sql, params}");
  }
  const pending = statements.map((s) => client.query(s.sql, s.params ?? []));
  try {
    return await client.transaction(pending);
  } catch (err) {
    throw sanitizeError(err);
  }
}

export async function createTransport(descriptor, { fetchImpl, driver } = {}) {
  const connectionString = resolveConnectionString(descriptor);
  const activeDriver = driver ?? (await loadRealDriver());

  let client;
  try {
    client = activeDriver.connect(connectionString, { fetchImpl });
  } catch (err) {
    throw sanitizeError(err);
  }

  return {
    query: (text, params) => runQuery(client, text, params),
    tx: (statements) => runTx(client, statements)
  };
}

// UUIDv7 (RFC 9562), monotonic within a millisecond: a 12-bit per-process
// sequence counter rides in rand_a, seeded randomly on each new millisecond
// tick and incremented (never reset) for repeat calls in the same tick, so
// same-millisecond ids still sort strictly ascending. On counter overflow
// (>4095 calls in one tick) time is advanced by one synthetic millisecond
// rather than wrapping, which keeps ordering intact at the cost of drifting
// slightly ahead of the wall clock in that pathological case.
const SEQ_MAX = 0xfff;
let lastMs = -1;
let seq = 0;

function nextTimestampAndSeq(nowMs) {
  if (nowMs > lastMs) {
    lastMs = nowMs;
    seq = randomBytes(2).readUInt16BE(0) & SEQ_MAX;
    return { ms: lastMs, seq };
  }
  seq += 1;
  if (seq > SEQ_MAX) {
    lastMs += 1;
    seq = 0;
  }
  return { ms: lastMs, seq };
}

export function uuidv7() {
  const { ms, seq: seqValue } = nextTimestampAndSeq(Date.now());
  const tsHex = ms.toString(16).padStart(12, "0").slice(-12);
  const randAHex = seqValue.toString(16).padStart(3, "0");
  const tail = randomBytes(8);
  tail[0] = (tail[0] & 0x3f) | 0x80; // variant nibble forced into {8,9,a,b}
  const tailHex = tail.toString("hex");

  return [
    tsHex.slice(0, 8),
    tsHex.slice(8, 12),
    `7${randAHex}`,
    tailHex.slice(0, 4),
    tailHex.slice(4, 16)
  ].join("-");
}

// §E: format -> nil -> version -> variant -> timestamp window. Any failure
// throws (never returns false) — a malformed id is a programmer error, and
// §E's last line requires it never be routed to the write-ahead outbox,
// which would retry it forever.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NIL_UUID = "00000000-0000-0000-0000-000000000000";
const VALID_VARIANT_NIBBLES = new Set(["8", "9", "a", "b"]);
const WINDOW_PAST_MS = 24 * 60 * 60 * 1000;
const WINDOW_FUTURE_MS = 5 * 60 * 1000;

export function validateEventId(id, { allowHistoric = false } = {}) {
  if (typeof id !== "string" || !UUID_RE.test(id)) {
    throw new Error(`validateEventId: not a valid uuid: ${id}`);
  }
  const lower = id.toLowerCase();
  if (lower === NIL_UUID) {
    throw new Error("validateEventId: nil uuid is not a valid event id");
  }
  const versionNibble = lower[14];
  if (versionNibble !== "7") {
    throw new Error(`validateEventId: expected UUIDv7 (version nibble '7'), got '${versionNibble}'`);
  }
  const variantNibble = lower[19];
  if (!VALID_VARIANT_NIBBLES.has(variantNibble)) {
    throw new Error(`validateEventId: invalid variant nibble '${variantNibble}', expected one of 8/9/a/b`);
  }
  if (allowHistoric) {
    return true;
  }

  const tsHex = lower.slice(0, 8) + lower.slice(9, 13);
  const tsMs = parseInt(tsHex, 16);
  const now = Date.now();
  if (tsMs < now - WINDOW_PAST_MS || tsMs > now + WINDOW_FUTURE_MS) {
    throw new Error(`validateEventId: timestamp out of allowed window: ${new Date(tsMs).toISOString()}`);
  }
  return true;
}
