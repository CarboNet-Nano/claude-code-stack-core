import { test } from "node:test";
import assert from "node:assert/strict";
import { createTransport, uuidv7, validateEventId } from "../src/db.mjs";

// ADR-060 §2 (S3 seam) + addendum §D/§E. This suite injects a fake driver
// that never touches tools/pm/src/vendor/** — the real vendored driver is
// reached only via a dynamic import() inside createTransport's real path,
// which these tests never exercise. That keeps the suite green even when
// the vendor subtree is absent (Task 1's deferred-state guard); verified
// manually by moving the vendor directory aside and re-running this file
// (see task-3-report.md for the transcript).
//
// The fake driver below is NOT a stand-in for the vendored package's own
// export names — db.mjs's `driver` seam is its own small abstraction
// (`connect(connectionString, {fetchImpl}) -> {query, transaction}`), kept
// deliberately independent of the vendored library's naming so this file
// never needs to spell that library's name (it is not on the seam
// allowlist that Task 1's literal-scan lint enforces).

function makeFakeDriver() {
  let fetchFn;
  let connectError;
  return {
    setConnectError(err) {
      connectError = err;
    },
    connect(connectionString, { fetchImpl } = {}) {
      if (connectError) throw connectError;
      if (fetchImpl) fetchFn = fetchImpl;

      async function execute(queries) {
        if (typeof fetchFn !== "function") {
          throw new Error("fake driver: fetchImpl was not configured");
        }
        const res = await fetchFn("https://fake-endpoint.example/sql", {
          method: "POST",
          body: JSON.stringify({ queries })
        });
        return res.results;
      }

      function query(text, params) {
        const queryData = { sql: text, params: params ?? [] };
        return {
          queryData,
          then(resolve, reject) {
            execute([queryData]).then((rows) => resolve(rows[0]), reject);
          }
        };
      }

      async function transaction(pending) {
        return execute(pending.map((p) => p.queryData));
      }

      return { query, transaction };
    }
  };
}

function makeFetchSpy(responder) {
  const calls = [];
  const fetchImpl = async (_url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body);
    return { results: responder(body.queries) };
  };
  return { fetchImpl, calls };
}

const DESCRIPTOR = { connectionString: "postgres://carbonet_writer:writerpass@db.example/knowledge" };

test("createTransport requires a connection string on the descriptor", async () => {
  await assert.rejects(
    () => createTransport({}, { driver: makeFakeDriver() }),
    /connection string/i
  );
});

test("T.query performs a single round trip and returns rows", async () => {
  const driver = makeFakeDriver();
  const { fetchImpl, calls } = makeFetchSpy(() => [[{ id: 1 }]]);
  const T = await createTransport(DESCRIPTOR, { driver, fetchImpl });

  const rows = await T.query("select 1", []);

  assert.equal(calls.length, 1);
  assert.deepEqual(rows, [{ id: 1 }]);
});

test("T.tx issues exactly ONE round trip for N statements", async () => {
  const driver = makeFakeDriver();
  const { fetchImpl, calls } = makeFetchSpy((queries) => queries.map(() => []));
  const T = await createTransport(DESCRIPTOR, { driver, fetchImpl });

  const statements = [
    { sql: "insert into stack.events (event_id) values ($1)", params: [uuidv7()] },
    { sql: "insert into stack.events (event_id) values ($1)", params: [uuidv7()] },
    { sql: "insert into stack.events (event_id) values ($1)", params: [uuidv7()] }
  ];
  const results = await T.tx(statements);

  assert.equal(calls.length, 1, "tx must be exactly one HTTP round trip regardless of statement count");
  assert.equal(calls[0].queries.length, 3);
  assert.equal(results.length, 3);
});

test("T.tx rejects an empty statement list rather than issuing a no-op round trip", async () => {
  const driver = makeFakeDriver();
  const { fetchImpl, calls } = makeFetchSpy(() => []);
  const T = await createTransport(DESCRIPTOR, { driver, fetchImpl });

  await assert.rejects(() => T.tx([]), /non-empty/i);
  assert.equal(calls.length, 0);
});

test("descriptor credential never leaks into a thrown message (query-time failure)", async () => {
  const secret = "Sup3r-Secret-Cred_42";
  const descriptor = { connectionString: `postgres://writer:${secret}@db.example/knowledge` };
  const driver = makeFakeDriver();
  const fetchImpl = async () => {
    throw new Error(`connect ECONNREFUSED to ${descriptor.connectionString}`);
  };
  const T = await createTransport(descriptor, { driver, fetchImpl });

  await assert.rejects(
    () => T.query("select 1", []),
    (err) => {
      assert.doesNotMatch(err.message, new RegExp(secret));
      return true;
    }
  );
});

test("descriptor credential never leaks into a thrown message (connect-time failure)", async () => {
  const secret = "another-Secret-99";
  const descriptor = { connectionString: `postgres://writer:${secret}@db.example/knowledge` };
  const driver = makeFakeDriver();
  driver.setConnectError(
    new Error(`Database connection string provided is not a valid URL: ${descriptor.connectionString}`)
  );

  await assert.rejects(
    () => createTransport(descriptor, { driver }),
    (err) => {
      assert.doesNotMatch(err.message, new RegExp(secret));
      return true;
    }
  );
});

test("uuidv7: output is well-formed and passes validateEventId", () => {
  const id = uuidv7();
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.doesNotThrow(() => validateEventId(id));
});

test("uuidv7: strictly ascending across 1000 calls in the same millisecond (monotonic, not luck)", () => {
  const realNow = Date.now;
  const frozenMs = realNow();
  Date.now = () => frozenMs;
  let ids;
  try {
    ids = Array.from({ length: 1000 }, () => uuidv7());
  } finally {
    Date.now = realNow;
  }

  const sorted = [...ids].sort();
  assert.deepEqual(ids, sorted, "ids must already be in ascending order as generated");
  assert.equal(new Set(ids).size, ids.length, "no duplicate ids");
});

function buildUuid({ tsMs = Date.now(), version = "7", variant = "8" } = {}) {
  const tsHex = Math.trunc(tsMs).toString(16).padStart(12, "0").slice(-12);
  return [tsHex.slice(0, 8), tsHex.slice(8, 12), `${version}abc`, `${variant}def`, "0123456789ab"].join("-");
}

test("validateEventId: rejects a string that does not parse as a uuid", () => {
  assert.throws(() => validateEventId("not-a-uuid-at-all"), /uuid/i);
});

test("validateEventId: rejects the nil uuid", () => {
  assert.throws(() => validateEventId("00000000-0000-0000-0000-000000000000"), /nil/i);
});

test("validateEventId: rejects a non-v7 version nibble", () => {
  assert.throws(() => validateEventId(buildUuid({ version: "4" })), /version/i);
});

test("validateEventId: rejects an invalid variant nibble", () => {
  assert.throws(() => validateEventId(buildUuid({ variant: "0" })), /variant/i);
});

test("validateEventId: rejects a timestamp more than 24h in the past", () => {
  const tooOld = Date.now() - 25 * 60 * 60 * 1000;
  assert.throws(() => validateEventId(buildUuid({ tsMs: tooOld })), /timestamp/i);
});

test("validateEventId: rejects a timestamp more than 5m in the future", () => {
  const tooFuture = Date.now() + 6 * 60 * 1000;
  assert.throws(() => validateEventId(buildUuid({ tsMs: tooFuture })), /timestamp/i);
});

test("validateEventId: accepts a timestamp at the edge of the window", () => {
  const justInsidePast = Date.now() - 23 * 60 * 60 * 1000;
  const justInsideFuture = Date.now() + 4 * 60 * 1000;
  assert.doesNotThrow(() => validateEventId(buildUuid({ tsMs: justInsidePast })));
  assert.doesNotThrow(() => validateEventId(buildUuid({ tsMs: justInsideFuture })));
});

test("validateEventId: allowHistoric passes a 2025 timestamp but still rejects a v4 uuid", () => {
  const historic2025 = new Date("2025-03-15T00:00:00Z").getTime();
  assert.doesNotThrow(() => validateEventId(buildUuid({ tsMs: historic2025 }), { allowHistoric: true }));
  assert.throws(
    () => validateEventId(buildUuid({ tsMs: historic2025, version: "4" }), { allowHistoric: true }),
    /version/i
  );
});

test("validateEventId: without allowHistoric, a 2025 timestamp is rejected as out of window", () => {
  const historic2025 = new Date("2025-03-15T00:00:00Z").getTime();
  assert.throws(() => validateEventId(buildUuid({ tsMs: historic2025 })), /timestamp/i);
});
