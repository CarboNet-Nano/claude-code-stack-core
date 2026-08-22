#!/usr/bin/env node
// Issue #152: UPSTREAM.md records a sha256 for a vendored driver, but the
// lint and installer only ever checked that a `sha256:` LINE EXISTED in
// UPSTREAM.md — never that it matched the actual committed file. This
// recomputes the real hash of each vendored file and compares it against
// the per-file checksum UPSTREAM.md records, so a corrupted or tampered
// vendor copy is caught, not just an absent checksum line.
//
// Deliberately dependency-free (stdlib only) and unaware of any specific
// package name: it walks `vendorDir` for every UPSTREAM.md it finds and
// verifies whatever per-file checksums that file records, next to it. This
// keeps it generic across future vendored packages and out of the vendored-
// package literal-scan lint's blast radius (ADR-060 §D) — it never spells
// any vendored package's own name.

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// "- <file>.mjs sha256: <64-hex>" — requires a filename before `sha256:`,
// which is what distinguishes a per-file line from UPSTREAM.md's own
// tarball line ("- sha256: <64-hex>", no filename token).
const PER_FILE_SHA_RE = /^-\s+([\w.-]+\.mjs)\s+sha256:\s*([0-9a-fA-F]{64})\s*$/gm;
const DEFERRED_RE = /^status:\s*deferred-to-task-7\s*$/m;

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function findUpstreamFiles(rootDir) {
  const out = [];
  for (const entry of readdirSync(rootDir, { withFileTypes: true })) {
    const abs = join(rootDir, entry.name);
    if (entry.isDirectory()) {
      out.push(...findUpstreamFiles(abs));
    } else if (entry.name === "UPSTREAM.md") {
      out.push(abs);
    }
  }
  return out;
}

// Recomputes and compares the per-file sha256 every UPSTREAM.md under
// `vendorDir` records, against the actual committed file beside it.
// Returns { ok, checked: [{file, expected, actual}], errors: [string] }.
export function verifyVendorDir(vendorDir) {
  const errors = [];
  const checked = [];

  if (!existsSync(vendorDir)) {
    return { ok: false, checked, errors: [`vendor directory does not exist: ${vendorDir}`] };
  }

  const upstreamFiles = findUpstreamFiles(vendorDir);
  if (upstreamFiles.length === 0) {
    return { ok: false, checked, errors: [`no UPSTREAM.md found under ${vendorDir} — nothing to verify`] };
  }

  for (const upstreamPath of upstreamFiles) {
    const upstream = readFileSync(upstreamPath, "utf8");
    if (DEFERRED_RE.test(upstream)) continue; // nothing vendored yet — not an error

    const pkgDir = dirname(upstreamPath);
    const matches = [...upstream.matchAll(PER_FILE_SHA_RE)];

    if (matches.length === 0) {
      errors.push(
        `${upstreamPath}: no per-file sha256 line found (expected "- <file>.mjs sha256: <64-hex>") — ` +
          `cannot verify the vendored file against anything but its presence`
      );
      continue;
    }

    for (const [, fileName, expected] of matches) {
      const filePath = join(pkgDir, fileName);
      if (!existsSync(filePath)) {
        errors.push(`${upstreamPath}: records a checksum for ${fileName}, but ${filePath} is missing`);
        continue;
      }
      const actual = sha256File(filePath);
      checked.push({ file: filePath, expected: expected.toLowerCase(), actual });
      if (actual !== expected.toLowerCase()) {
        errors.push(
          `${filePath}: sha256 mismatch — expected ${expected} (recorded in ${upstreamPath}), got ${actual}. ` +
            `The vendored file does not match its recorded checksum. If this is an intentional upgrade, ` +
            `re-vendor and update the checksum recorded in ${upstreamPath} per its "Re-vendoring a newer ` +
            `version" section.`
        );
      }
    }
  }

  return { ok: errors.length === 0, checked, errors };
}

// Same symlink-safe main-module predicate as bin.mjs's isMainModule
// (tools/pm/test/main-module-guard.test.mjs) — a raw
// `import.meta.url === pathToFileURL(argv[1]).href` comparison goes false
// (silently, no error) when this file is reached through a symlinked
// directory, e.g. a stack install's `~/.claude/tools/pm` pointing at a
// checkout of this repo. Duplicated rather than imported from bin.mjs to
// keep this script dependency-free — it must work standing alone, as the
// installer invokes it before any other tools/pm module is known-good.
function isMainModule(moduleUrl, argvPath) {
  if (!argvPath) return false;
  try {
    return moduleUrl === pathToFileURL(realpathSync(argvPath)).href;
  } catch {
    return false;
  }
}

if (isMainModule(import.meta.url, process.argv[1])) {
  const target = process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "vendor");
  const { ok, errors } = verifyVendorDir(target);
  if (!ok) {
    for (const e of errors) console.error(`[vendor-verify] ${e}`);
    process.exit(1);
  }
  console.log(`[vendor-verify] OK — vendored file(s) under ${target} match their recorded checksums.`);
}
