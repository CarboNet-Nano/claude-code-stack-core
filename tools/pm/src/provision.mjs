import { isRegistered, resolve } from "./directory.mjs";

// ADR-060 §2 (seam S2 — provisioner) + §5 ("Provisioning (S2) — a product
// flow, not an ops task"). All three functions are stubbed for P1b: none
// calls a cloud API, and none opens a network connection. Layer B (P4+,
// designed in §5, not built here) is where these become real sagas —
// idempotent adopt-or-create, an ordered step ledger, resume-from-failure,
// reverse-order teardown, reusing the golden-path provisioner's proven
// discipline (REQ-050/052/053).

// provisioner.createTenantDatabase({orgId, region}) -> {descriptor, credentialRef, capabilities}
//
// `region` is accepted (matches the §5 signature Layer B needs) but unused
// in P1b — there is nothing to provision yet. Adopt-if-registered: a
// directory entry already exists for Bill's org (created by hand, see Task
// 7), so this stub's only real job is returning that entry's resolved
// descriptor. An org with no directory entry throws — P1b provisioning is a
// human step, not automation.
export async function createTenantDatabase({ orgId, region: _region } = {}, opts = {}) {
  if (!orgId) {
    throw new Error("provision.createTenantDatabase: orgId is required");
  }
  if (!isRegistered(orgId, opts)) {
    throw new Error(
      `no database registered for org ${orgId} — provisioning is a human step in P1b (see Task 7 checklist)`
    );
  }
  const { descriptor, credentialRef, capabilities } = await resolve(orgId, opts);
  return { descriptor, credentialRef, capabilities };
}

// provisioner.adoptCustomerDatabase({orgId, connectionString}) -> {descriptor, credentialRef, capabilities}
//
// BYO adoption (capability probe, migration, registration) is Layer B
// (§5). P1b has exactly one org, hosted, already registered by hand —
// there is no BYO path to stub usefully yet, so this always throws.
export async function adoptCustomerDatabase({ orgId: _orgId, connectionString: _connectionString } = {}) {
  throw new Error("BYO adoption is Layer B (ADR-060 §5)");
}

// provisioner.destroyTenantDatabase({orgId}) -> void
//
// Hard erasure via a hosted provider API is Layer B (§5). Layer A's
// erasure path is `pm purge` (REQ-146, portfolio-scoped) plus a human
// deleting the project in the console — there is no automated tenant
// teardown to stub yet, so this always throws.
export async function destroyTenantDatabase({ orgId: _orgId } = {}) {
  throw new Error("tenant destruction is Layer B (ADR-060 §5); Layer A erasure = pm purge + Neon console");
}
