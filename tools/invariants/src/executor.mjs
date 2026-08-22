// Two executors behind the same interface -- { writeProbe, currentRole,
// setReadOnlySession, runQuery } -- so bin.mjs's `run` command never
// branches on real-vs-fake past the point of construction.
//
// pg executor: real Postgres, per the spec's write-probe + read-only
// session contract (sweep-design §4.6 D0's read-only-proven-by-
// introspection). The probe MUST run before setReadOnlySession() --
// Postgres exempts temp-table writes from a session's own
// default_transaction_read_only flag (temp tables are scratch space owned
// by the session), so probing AFTER setting that flag would always read
// "safe" regardless of the connecting ROLE's real grants. Probing first
// tests the role itself, not a flag this runner just set on itself.
export function buildPgExecutor(client) {
  return {
    async writeProbe() {
      let createOk = false;
      let insertOk = false;
      try {
        await client.query('CREATE TEMP TABLE pg_temp.__invariants_probe__ (x int)');
        createOk = true;
      } catch {
        createOk = false;
      }
      if (createOk) {
        try {
          await client.query('INSERT INTO pg_temp.__invariants_probe__ (x) VALUES (1)');
          insertOk = true;
        } catch {
          insertOk = false;
        }
      }
      return { createOk, insertOk };
    },
    async currentRole() {
      const res = await client.query('SELECT current_user');
      return res.rows[0]?.current_user ?? 'unknown';
    },
    async setReadOnlySession() {
      // Session-settable defense-in-depth ONLY -- never the guarantee (the
      // write-probe above is the guarantee). Two statements, not one
      // multi-statement string, so this stays consistent with the
      // single-statement-per-query rule applied to invariant SQL.
      await client.query('SET default_transaction_read_only = on');
      await client.query('SET statement_timeout = 15000');
    },
    async runQuery(_id, sql) {
      const res = await client.query(sql);
      return res.rows;
    },
  };
}

// Test-only fake executor (documented for tests/test-invariants.sh):
// INVARIANTS_FAKE_RESULTS=<path-to-json> points at a file shaped
//   { "__probe__": {"createOk":bool,"insertOk":bool,"role":string},
//     "<invariant-id>": {"rows":[...]} | {"error":"message"} }
// `__probe__` can never collide with a real invariant id (the id charset
// [a-z0-9-]+ excludes underscores). An id with no entry in the file
// defaults to zero rows -- lets a test fixture cover only the ids it cares
// about without a mandatory boilerplate entry for every case. This env var
// exists ONLY to make tests/test-invariants.sh hermetic (no live Postgres
// in CI); it is not a supported production interface.
export function buildFakeExecutor(fakeResultsPath, readFileImpl) {
  const raw = readFileImpl(fakeResultsPath, 'utf8');
  const data = JSON.parse(raw);
  const probeCfg = data.__probe__ || {};
  return {
    async writeProbe() {
      return { createOk: !!probeCfg.createOk, insertOk: !!probeCfg.insertOk };
    },
    async currentRole() {
      return probeCfg.role || 'fake-role';
    },
    async setReadOnlySession() {},
    async runQuery(id, _sql) {
      const entry = data[id];
      if (!entry) return [];
      if (entry.error) throw new Error(entry.error);
      return entry.rows || [];
    },
  };
}
