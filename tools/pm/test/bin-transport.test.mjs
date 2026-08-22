import { test } from "node:test";
import assert from "node:assert/strict";
import { buildJournal } from "../bin.mjs";

// Issue #150 -- `pm migrate`'s transport dependency was only ever injectable
// via scripts/task7-live-migrate.mjs's standalone createTransport() call;
// the shipped CLI path (bin.mjs -> cli.mjs's runMigrate, which already reads
// deps.transport -- see migrate.test.mjs) never actually populated
// deps.transport, so a real `pm migrate` invocation always saw `undefined`
// no matter what credentials were available. buildJournal() is bin.mjs's
// existing resolveDirectory()+createTransport() seam (used to build the
// journal for every other command) -- these tests assert it now also
// returns that SAME resolved transport so run() can hand it to deps.transport,
// reusing the one credential chain instead of adding a second one.
//
// Importing bin.mjs must not resolve real credentials or run a command --
// buildJournal only touches whatever resolveDirectoryImpl/createTransportImpl
// it's given, and the module's own side-effecting run() stays behind the
// isMainModule guard.

function fakeJournal() {
  return { fake: true };
}

test("buildJournal: resolves a real transport via resolveDirectoryImpl + createTransportImpl on success", async () => {
  const descriptor = { connectionString: "postgres://fake" };
  const transportObj = { tx: async () => [] };
  const calls = { resolveDirectory: [], createTransport: [], openPgJournal: [] };

  const { journal, journalError, transport } = await buildJournal({
    resolveDirectoryImpl: async (orgId) => {
      calls.resolveDirectory.push(orgId);
      return { descriptor, userId: "user-123" };
    },
    createTransportImpl: async (d) => {
      calls.createTransport.push(d);
      return transportObj;
    },
    openPgJournalImpl: (opts) => {
      calls.openPgJournal.push(opts);
      return fakeJournal();
    }
  });

  assert.equal(journalError, null);
  assert.deepEqual(journal, fakeJournal());
  assert.equal(transport, transportObj, "buildJournal must return the SAME transport object it built the journal with");
  assert.deepEqual(calls.resolveDirectory, ["carbonet"]);
  assert.deepEqual(calls.createTransport, [descriptor]);
  assert.equal(calls.openPgJournal[0].transport, transportObj);
});

test("buildJournal: resolveDirectory failure -> transport is null, journal is unreachable, journalError set", async () => {
  const { journal, journalError, transport } = await buildJournal({
    resolveDirectoryImpl: async () => {
      throw new Error("no credential for org 'carbonet'");
    },
    createTransportImpl: async () => {
      throw new Error("createTransportImpl must not be called when resolveDirectory failed");
    },
    openPgJournalImpl: () => fakeJournal()
  });

  assert.equal(transport, null);
  assert.match(journalError, /journal unreachable:.*no credential for org 'carbonet'/);
  await assert.rejects(() => journal.append({}), /journal unreachable/);
});

test("buildJournal: createTransport failure -> transport is null, journal is unreachable, journalError set", async () => {
  const { journal, journalError, transport } = await buildJournal({
    resolveDirectoryImpl: async () => ({ descriptor: {}, userId: "user-123" }),
    createTransportImpl: async () => {
      throw new Error("connection refused");
    },
    openPgJournalImpl: () => fakeJournal()
  });

  assert.equal(transport, null);
  assert.match(journalError, /journal unreachable:.*connection refused/);
  await assert.rejects(() => journal.append({}), /journal unreachable/);
});
