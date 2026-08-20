import { execFile } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ADR-060 §2 (seam S1 — directory) + §5 (Q3 — credential distribution).
//
// Layer A (P1b, now): the backing store is `config/knowledge-store.json`,
// one entry (org `carbonet`). Layer B (P4+, designed later, not built here)
// swaps the backing to a control-plane database; every caller above this
// file already speaks the opaque `{descriptor, credentialRef, capabilities,
// userId}` shape §5 requires, so that swap is additive here, not a rewrite
// of callers.
//
// Credential chain is exactly `gmn_key()`'s shape (scripts/lib/gemini-api.sh,
// §5): env `$STACK_DB_URL` -> macOS Keychain `stack-db-url-<orgId>` -> fail
// loud, printing the exact `security add-generic-password` command. Both
// sources are whitespace-stripped (ADR-026: a pasted trailing newline
// corrupts the value and fails confusingly downstream, not here).
//
// Keychain reads shell out (REQ-116): `execFile` with an argument array
// only, never a string passed through a shell.

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = join(__dirname, "..", "..", "..", "config", "knowledge-store.json");

function keychainItemFor(orgId) {
  return `stack-db-url-${orgId}`;
}

function readSecurityFindPassword(item) {
  return new Promise((resolvePromise, rejectPromise) => {
    execFile("security", ["find-generic-password", "-s", item, "-w"], (err, stdout) => {
      if (err) {
        rejectPromise(err);
        return;
      }
      resolvePromise(stdout);
    });
  });
}

function loadConfig(configPath) {
  if (!existsSync(configPath)) {
    throw new Error(`directory: no knowledge-store config found at ${configPath}`);
  }
  return JSON.parse(readFileSync(configPath, "utf8"));
}

function findOrgEntry(config, orgId) {
  return (config.orgs ?? []).find((o) => o.org_id === orgId);
}

function requireOrgEntry(config, orgId) {
  const entry = findOrgEntry(config, orgId);
  if (!entry) {
    throw new Error(`directory.resolve: unknown org '${orgId}' — no entry in config/knowledge-store.json`);
  }
  return entry;
}

function missingCredentialError(orgId, item) {
  return new Error(
    `directory.resolve: no credential for org '${orgId}'. Set $STACK_DB_URL, or run:\n` +
      `  security add-generic-password -a "$USER" -s ${item} -w 'YOUR_CONNECTION_STRING'`
  );
}

async function resolveConnectionString(orgId, { env, keychain }) {
  const item = keychainItemFor(orgId);

  const envValue = env?.STACK_DB_URL;
  if (typeof envValue === "string" && envValue.trim() !== "") {
    return envValue.trim();
  }

  const readKeychain = keychain ?? readSecurityFindPassword;
  try {
    const raw = await readKeychain(item);
    const trimmed = typeof raw === "string" ? raw.trim() : "";
    if (trimmed !== "") {
      return trimmed;
    }
  } catch {
    // Keychain item absent, `security` unavailable, or the caller's fake
    // reader threw — every case falls through to the same fail-loud error.
  }

  throw missingCredentialError(orgId, item);
}

// Returns true iff `orgId` has a directory entry, independent of whether its
// credential currently resolves. `provision.mjs`'s "adopt-if-registered"
// stub needs this distinction: a registered org with a temporarily missing
// credential is a credential problem, not "no database registered".
export function isRegistered(orgId, { configPath = DEFAULT_CONFIG_PATH } = {}) {
  if (!existsSync(configPath)) {
    return false;
  }
  return Boolean(findOrgEntry(loadConfig(configPath), orgId));
}

// directory.resolve(orgId, {env, keychain}?) -> {descriptor, credentialRef, capabilities, userId}
//
// THROWS on missing config entry or missing credential — never returns a
// partial descriptor (contract note for Task 8: resolve before composing
// events or mutating anything; a resolution failure has no formed event and
// no descriptor to flush via the outbox, so it fails loud and early here).
export async function resolve(orgId, { env = process.env, keychain, configPath = DEFAULT_CONFIG_PATH } = {}) {
  const config = loadConfig(configPath);
  const entry = requireOrgEntry(config, orgId);
  const connectionString = await resolveConnectionString(orgId, { env, keychain });

  return {
    descriptor: { ...entry.descriptor, connectionString },
    credentialRef: entry.credential_ref,
    capabilities: entry.capabilities,
    userId: entry.user_id ?? null
  };
}

// directory.register(orgId, descriptor, credentialRef) — writes/updates the
// org's directory entry. Never persists a credential: `descriptor` is
// stripped of any `connectionString` field before it is written, and
// `credentialRef` is a reference (env var name / Keychain item name), not a
// secret value, matching §5's "no component above S1 ever handles a
// connection string" boundary.
export function register(orgId, descriptor, credentialRef, { configPath = DEFAULT_CONFIG_PATH } = {}) {
  const config = existsSync(configPath) ? loadConfig(configPath) : { schema_version: 1, orgs: [] };
  const { connectionString: _drop, ...safeDescriptor } = descriptor ?? {};
  const existing = findOrgEntry(config, orgId);

  const entry = {
    org_id: orgId,
    descriptor: safeDescriptor,
    credential_ref: credentialRef,
    capabilities: existing?.capabilities ?? {},
    schema_version: existing?.schema_version ?? 6,
    user_id: existing?.user_id ?? null
  };

  const orgs = (config.orgs ?? []).filter((o) => o.org_id !== orgId);
  orgs.push(entry);
  const next = { ...config, orgs };

  writeFileSync(configPath, `${JSON.stringify(next, null, 2)}\n`);
  return entry;
}
