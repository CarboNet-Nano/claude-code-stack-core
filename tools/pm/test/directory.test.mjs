import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

import { isRegistered, register, resolve } from "../src/directory.mjs";
import { adoptCustomerDatabase, createTenantDatabase, destroyTenantDatabase } from "../src/provision.mjs";

// ADR-060 §2 (seams S1/S2) + §5 (Q3 — credential distribution). Every test
// below uses an isolated temp config file, never the real
// config/knowledge-store.json, and a fake `fetch`/`keychain` reader, so the
// suite never shells out to the real macOS Keychain and never opens a
// socket — matching §5's "no cloud API in P1b" and REQ-116's no-real-child-
// process-in-tests spirit.

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..", "..", "..");
const REAL_CONFIG_PATH = join(REPO_ROOT, "config", "knowledge-store.json");

function withTempConfig(orgs) {
  const dir = mkdtempSync(join(tmpdir(), "knowledge-store-test-"));
  const configPath = join(dir, "knowledge-store.json");
  writeFileSync(configPath, JSON.stringify({ schema_version: 1, orgs }, null, 2));
  return { dir, configPath };
}

function cleanup(dir) {
  rmSync(dir, { recursive: true, force: true });
}

const CARBONET_ENTRY = {
  org_id: "carbonet",
  descriptor: { database: "knowledge", ssl_mode: "require" },
  credential_ref: { env_var: "STACK_DB_URL", keychain_item: "stack-db-url-carbonet" },
  capabilities: {},
  schema_version: 6,
  user_id: null
};

// --- S1 directory: resolve() credential chain ---------------------------

test("resolve: env wins over keychain, and keychain is never consulted", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    let keychainCalls = 0;
    const result = await resolve("carbonet", {
      env: { STACK_DB_URL: "postgres://envuser:envpass@example/knowledge" },
      keychain: async () => {
        keychainCalls += 1;
        return "postgres://keychainuser:keychainpass@example/knowledge";
      },
      configPath
    });
    assert.equal(keychainCalls, 0);
    assert.equal(result.descriptor.connectionString, "postgres://envuser:envpass@example/knowledge");
  } finally {
    cleanup(dir);
  }
});

test("resolve: falls back to keychain when env is absent, trailing newline stripped", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    const result = await resolve("carbonet", {
      env: {},
      keychain: async (item) => {
        assert.equal(item, "stack-db-url-carbonet");
        return "postgres://keychainuser:keychainpass@example/knowledge\n";
      },
      configPath
    });
    assert.equal(result.descriptor.connectionString, "postgres://keychainuser:keychainpass@example/knowledge");
  } finally {
    cleanup(dir);
  }
});

test("resolve: falls back to keychain when env is whitespace-only", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    const result = await resolve("carbonet", {
      env: { STACK_DB_URL: "   " },
      keychain: async () => "postgres://keychainuser:keychainpass@example/knowledge",
      configPath
    });
    assert.equal(result.descriptor.connectionString, "postgres://keychainuser:keychainpass@example/knowledge");
  } finally {
    cleanup(dir);
  }
});

test("resolve: env and keychain both absent -> throws, message names the exact setup command and item", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    await assert.rejects(
      () =>
        resolve("carbonet", {
          env: {},
          keychain: async () => {
            throw new Error("security: The specified item could not be found in the keychain.");
          },
          configPath
        }),
      (err) => {
        assert.match(err.message, /security add-generic-password/);
        assert.match(err.message, /stack-db-url-carbonet/);
        return true;
      }
    );
  } finally {
    cleanup(dir);
  }
});

test("resolve: unknown org throws before any credential lookup is attempted", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    let keychainCalls = 0;
    await assert.rejects(
      () =>
        resolve("no-such-org", {
          env: {},
          keychain: async () => {
            keychainCalls += 1;
            return "postgres://x:y@example/knowledge";
          },
          configPath
        }),
      /unknown org 'no-such-org'/
    );
    assert.equal(keychainCalls, 0);
  } finally {
    cleanup(dir);
  }
});

test("resolve: descriptor carries the resolved credential plus the entry's own metadata", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    const result = await resolve("carbonet", {
      env: { STACK_DB_URL: "postgres://envuser:envpass@example/knowledge" },
      configPath
    });
    assert.deepEqual(result.descriptor, {
      database: "knowledge",
      ssl_mode: "require",
      connectionString: "postgres://envuser:envpass@example/knowledge"
    });
    assert.deepEqual(result.credentialRef, CARBONET_ENTRY.credential_ref);
    assert.deepEqual(result.capabilities, {});
    assert.equal(result.userId, null);
  } finally {
    cleanup(dir);
  }
});

// --- S1 directory: register() --------------------------------------------

test("register: adds a new org entry, resolvable afterward", async () => {
  const { dir, configPath } = withTempConfig([]);
  try {
    register("acme", { database: "knowledge" }, { env_var: "STACK_DB_URL", keychain_item: "stack-db-url-acme" }, { configPath });
    assert.equal(isRegistered("acme", { configPath }), true);

    const result = await resolve("acme", { env: { STACK_DB_URL: "postgres://a:b@example/db" }, configPath });
    assert.equal(result.descriptor.connectionString, "postgres://a:b@example/db");
  } finally {
    cleanup(dir);
  }
});

test("register: never persists a connectionString even if the caller passes one", () => {
  const { dir, configPath } = withTempConfig([]);
  try {
    register(
      "acme",
      { database: "knowledge", connectionString: "postgres://leaked:pw@example/db" },
      { env_var: "STACK_DB_URL", keychain_item: "stack-db-url-acme" },
      { configPath }
    );
    const raw = readFileSync(configPath, "utf8");
    assert.doesNotMatch(raw, /postgres:\/\//);
  } finally {
    cleanup(dir);
  }
});

test("register: updating an existing org preserves its capabilities and schema_version", () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    register("carbonet", { database: "knowledge-v2" }, CARBONET_ENTRY.credential_ref, { configPath });
    const config = JSON.parse(readFileSync(configPath, "utf8"));
    const entry = config.orgs.find((o) => o.org_id === "carbonet");
    assert.equal(entry.schema_version, 6);
    assert.deepEqual(entry.capabilities, {});
    assert.deepEqual(entry.descriptor, { database: "knowledge-v2" });
    assert.equal(config.orgs.length, 1);
  } finally {
    cleanup(dir);
  }
});

// --- S2 provisioner stubs --------------------------------------------------

function withFetchSpy(fn) {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (...args) => {
    calls += 1;
    return originalFetch ? originalFetch(...args) : undefined;
  };
  return fn(() => calls).finally(() => {
    globalThis.fetch = originalFetch;
  });
}

test("createTenantDatabase: adopts an already-registered org, makes zero network calls", async () => {
  const { dir, configPath } = withTempConfig([CARBONET_ENTRY]);
  try {
    await withFetchSpy(async (callCount) => {
      const result = await createTenantDatabase(
        { orgId: "carbonet", region: "us-east-1" },
        { env: { STACK_DB_URL: "postgres://a:b@example/db" }, configPath }
      );
      assert.deepEqual(result.descriptor, {
        database: "knowledge",
        ssl_mode: "require",
        connectionString: "postgres://a:b@example/db"
      });
      assert.equal(callCount(), 0);
    });
  } finally {
    cleanup(dir);
  }
});

test("createTenantDatabase: unregistered org throws the human-step message, zero network calls", async () => {
  const { dir, configPath } = withTempConfig([]);
  try {
    await withFetchSpy(async (callCount) => {
      await assert.rejects(
        () => createTenantDatabase({ orgId: "acme", region: "us-east-1" }, { configPath }),
        /no database registered for org acme — provisioning is a human step in P1b \(see Task 7 checklist\)/
      );
      assert.equal(callCount(), 0);
    });
  } finally {
    cleanup(dir);
  }
});

test("adoptCustomerDatabase: always throws BYO-is-Layer-B, zero network calls", async () => {
  await withFetchSpy(async (callCount) => {
    await assert.rejects(
      () => adoptCustomerDatabase({ orgId: "carbonet", connectionString: "postgres://a:b@example/db" }),
      /BYO adoption is Layer B \(ADR-060 §5\)/
    );
    assert.equal(callCount(), 0);
  });
});

test("destroyTenantDatabase: always throws teardown-is-Layer-B, zero network calls", async () => {
  // Asserted in two pieces, not one literal string, so this file (not a
  // seam file per Task 1's literal-scan lint) never has to spell the
  // provider name provision.mjs's message ends with.
  await withFetchSpy(async (callCount) => {
    await assert.rejects(
      () => destroyTenantDatabase({ orgId: "carbonet" }),
      /tenant destruction is Layer B \(ADR-060 §5\)/
    );
    assert.equal(callCount(), 0);
  });
  const err = await destroyTenantDatabase({ orgId: "carbonet" }).catch((e) => e);
  assert.match(err.message, /Layer A erasure = pm purge \+/);
});

// --- config/knowledge-store.json: no credential ever committed ------------

test("config/knowledge-store.json: exists, has exactly the carbonet entry, and holds no connection string", () => {
  assert.equal(existsSync(REAL_CONFIG_PATH), true);
  const raw = readFileSync(REAL_CONFIG_PATH, "utf8");
  assert.doesNotMatch(raw, /postgres(ql)?:\/\//i);

  const config = JSON.parse(raw);
  assert.equal(config.orgs.length, 1);
  const [entry] = config.orgs;
  assert.equal(entry.org_id, "carbonet");
  // null until the Task 7 human signoff writes the stable pseudonymous id
  // (ADR-060 Q5 / ASSUMPTION 6); a uuid afterward. Never anything else.
  assert.ok(
    entry.user_id === null || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(entry.user_id),
    "user_id must be null (pre-signoff) or a uuid (post-signoff)"
  );
  assert.equal(typeof entry.schema_version, "number");
  assert.ok(entry.credential_ref.keychain_item);
  assert.ok(entry.credential_ref.env_var);
});

test("real config: resolve() against it succeeds given an injected env credential (no real Keychain touched)", async () => {
  const result = await resolve("carbonet", {
    env: { STACK_DB_URL: "postgres://a:b@example/db" },
    keychain: async () => {
      throw new Error("must not be called — env should win");
    }
  });
  assert.equal(result.descriptor.connectionString, "postgres://a:b@example/db");
});
