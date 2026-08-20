import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync, writeFileSync, rmSync, mkdtempSync, cpSync } from "node:fs";
import { join, dirname, basename, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

// ADR-060 §D: the vendored `@neondatabase/serverless` driver is a seam —
// the literal `neon` (case-insensitive) may appear only where that seam is
// implemented (`tools/pm/src/{directory,provision,db}.mjs`), inside the
// vendored source tree itself (`tools/pm/src/vendor/**`), and in this file,
// which necessarily names the string it forbids in order to define and
// self-test the scan below (self-allowlisted — without this the lint fails
// on day one, a review BLOCKER per the P1b task-1 brief).
//
// Grandfathered: six pre-existing, unrelated `neon` mentions found in the
// scanned trees before this lint existed (an MCP plugin toggle, a tenant DB
// backend enum, a `neonctl` CLI-guardrail name, a doc mention, a URL-format
// comment). None are PM-layer driver leaks — the lint's load-bearing
// property is "no NEW neon reference outside the seams," not "zero neon
// anywhere in the repo." Grandfathered pre-existing, see P1b plan Global
// Constraints amendment 2026-08-08 (commit adf7fd3). This list may only
// shrink; it must never grow to cover a new, non-seam reference.
const GRANDFATHERED = [
  "skills/claude-automation-recommender/references/mcp-servers.md",
  "scripts/value-check-gate.sh",
  "config/settings.team.template.json",
  "config/permissions-baseline.json",
  "config/tier-manifests/tier-2.json",
  "schemas/tenant-pack-schema.json"
];

const SEAM_FILES = ["tools/pm/src/directory.mjs", "tools/pm/src/provision.mjs", "tools/pm/src/db.mjs"];
const SELF_PATH = "tools/pm/test/neon-literal.test.mjs";
const VENDOR_PREFIX = "tools/pm/src/vendor/";

const ALLOWLIST_EXACT = new Set([...SEAM_FILES, SELF_PATH, ...GRANDFATHERED]);

function isAllowlisted(relPath) {
  return ALLOWLIST_EXACT.has(relPath) || relPath.startsWith(VENDOR_PREFIX);
}

const NEON_RE = /neon/i;
const SCAN_DIRS = ["tools/pm", "skills", "scripts", "config", "schemas"];
const SKIP_DIR_NAMES = new Set(["node_modules", ".git", "__pycache__"]);
const SKIP_FILE_NAMES = new Set([".DS_Store"]);

const __dirname = dirname(fileURLToPath(import.meta.url));
const PM_ROOT = join(__dirname, "..");
const REPO_ROOT = join(PM_ROOT, "..", "..");

function walkFiles(rootDir) {
  const out = [];
  for (const entry of readdirSync(rootDir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (SKIP_DIR_NAMES.has(entry.name)) continue;
      out.push(...walkFiles(join(rootDir, entry.name)));
      continue;
    }
    if (SKIP_FILE_NAMES.has(entry.name)) continue;
    out.push(join(rootDir, entry.name));
  }
  return out;
}

function findNeonLines(absPath) {
  const lines = readFileSync(absPath, "utf8").split("\n");
  const hits = [];
  lines.forEach((line, i) => {
    if (NEON_RE.test(line)) hits.push({ line: i + 1, text: line.trim() });
  });
  return hits;
}

// Pure filesystem walk, no git dependency, so it can scan any directory —
// including a temp dir outside the repo entirely (see the self-check test).
// relPath is always relative to rootDir, forward-slash separated.
function scanTree(rootDir) {
  const hits = [];
  for (const absPath of walkFiles(rootDir)) {
    for (const hit of findNeonLines(absPath)) {
      hits.push({ relPath: relative(rootDir, absPath).split(sep).join("/"), line: hit.line, text: hit.text });
    }
  }
  return hits;
}

test("allowlist: seam files, vendor subtree, self, and grandfathered paths pass; lookalikes fail", () => {
  for (const p of SEAM_FILES) assert.equal(isAllowlisted(p), true, p);
  assert.equal(isAllowlisted(SELF_PATH), true);
  for (const p of GRANDFATHERED) assert.equal(isAllowlisted(p), true, p);
  assert.equal(isAllowlisted("tools/pm/src/vendor/neon-serverless/index.mjs"), true);
  assert.equal(isAllowlisted("tools/pm/src/vendor/neon-serverless/UPSTREAM.md"), true);

  assert.equal(isAllowlisted("tools/pm/src/directory2.mjs"), false);
  assert.equal(isAllowlisted("tools/pm/src/db.mjs.bak"), false);
  assert.equal(isAllowlisted("tools/pm/srcvendor/neon-serverless/index.mjs"), false);
  assert.equal(isAllowlisted("skills/foo/neon-thing.md"), false);
});

test("neon literal scan: `neon` (case-insensitive) appears only in allowlisted files", () => {
  const violations = [];
  for (const dir of SCAN_DIRS) {
    const abs = join(REPO_ROOT, ...dir.split("/"));
    if (!existsSync(abs)) continue;
    for (const hit of scanTree(abs)) {
      const relPath = `${dir}/${hit.relPath}`;
      if (!isAllowlisted(relPath)) violations.push(`${relPath}:${hit.line}: ${hit.text}`);
    }
  }
  assert.equal(violations.length, 0, `Unallowlisted 'neon' literal(s) found:\n${violations.join("\n")}`);
});

test("vendor state: UPSTREAM.md + LICENSE consistent with the vendored/deferred marker", () => {
  const vendorDir = join(PM_ROOT, "src", "vendor", "neon-serverless");
  const upstreamPath = join(vendorDir, "UPSTREAM.md");
  assert.equal(existsSync(upstreamPath), true, "UPSTREAM.md must exist in the vendor dir");

  const upstream = readFileSync(upstreamPath, "utf8");
  const isDeferred = /^status:\s*deferred-to-task-7\s*$/m.test(upstream);

  if (isDeferred) {
    assert.doesNotMatch(upstream, /sha256:/i, "deferred state must not fake a checksum");
    assert.equal(existsSync(join(vendorDir, "LICENSE")), false, "deferred state must not ship LICENSE");
    assert.equal(existsSync(join(vendorDir, "index.mjs")), false, "deferred state must not ship driver source");
  } else {
    assert.match(upstream, /sha256:\s*[0-9a-fA-F]{64}/, "UPSTREAM.md must record the tarball sha256");
    assert.equal(existsSync(join(vendorDir, "LICENSE")), true, "LICENSE must be committed alongside vendored source");
    assert.equal(existsSync(join(vendorDir, "index.mjs")), true, "driver source must be present when not deferred");
  }
});

// Issue #152: the checks above only ever asserted a `sha256:` LINE EXISTS in
// UPSTREAM.md — never that it matches the actual committed file. These
// exercise the real compute-and-compare in ../src/vendor-verify.mjs.
test("vendor hash: the recorded per-file sha256 matches the real vendored file (compute-and-compare, not line-exists)", async () => {
  const { verifyVendorDir } = await import("../src/vendor-verify.mjs");
  const vendorDir = join(PM_ROOT, "src", "vendor");

  const result = verifyVendorDir(vendorDir);

  assert.equal(result.ok, true, result.errors.join("\n"));
  assert.ok(result.checked.length > 0, "expected at least one vendored file to be checked");
});

test("vendor hash: tampering the vendored file is caught even though UPSTREAM.md's sha256 line is untouched", async () => {
  const { verifyVendorDir } = await import("../src/vendor-verify.mjs");
  const realVendorDir = join(PM_ROOT, "src", "vendor");

  const tmp = mkdtempSync(join(tmpdir(), "vendor-hash-tamper-"));
  try {
    const tamperedVendorDir = join(tmp, "vendor");
    cpSync(realVendorDir, tamperedVendorDir, { recursive: true });
    const indexPath = join(tamperedVendorDir, "neon-serverless", "index.mjs");
    const original = readFileSync(indexPath, "utf8");
    writeFileSync(indexPath, `${original}\n// tampered\n`);

    const result = verifyVendorDir(tamperedVendorDir);

    assert.equal(result.ok, false);
    assert.ok(
      result.errors.some((e) => e.includes("UPSTREAM.md") && e.includes("index.mjs") && e.includes("mismatch")),
      `expected a mismatch error naming both index.mjs and UPSTREAM.md, got:\n${result.errors.join("\n")}`
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("self-check: scanner catches a planted literal in a temp dir outside the scanned tree (not vacuous)", () => {
  const sourcePath = join(PM_ROOT, "src", "board.mjs");
  const source = readFileSync(sourcePath, "utf8");
  assert.doesNotMatch(source, NEON_RE, "fixture assumption: board.mjs must not already contain 'neon'");

  const tmp = mkdtempSync(join(tmpdir(), "neon-lint-selftest-"));
  try {
    const planted = `${source}\n// selftest: Neon\n`;
    writeFileSync(join(tmp, "board.mjs"), planted);

    const hits = scanTree(tmp);
    assert.equal(hits.length, 1);
    assert.equal(hits[0].relPath, "board.mjs");
    assert.equal(hits[0].line, source.split("\n").length + 1);
    assert.equal(isAllowlisted(hits[0].relPath), false, "planted file must not accidentally match the allowlist");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
