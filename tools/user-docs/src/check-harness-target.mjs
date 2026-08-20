#!/usr/bin/env node
// check-harness-target.mjs — docs-agent-pipeline-v2 §2.2 (Phase 5a).
//
// Mechanical check that a committed logic-extraction harness invokes the
// REAL entry point named in the dispatch receipt, not some inner function
// bypassing caller-side wrappers (caps/floors/multipliers). This is the
// fix for red-team's Critical #2: a "scratch harness" that calls an inner
// computation function directly can produce verified:true examples that
// never pass through the real caps/floors/multiplier logic.
//
// Zero LLM tokens. Checks that the harness file's own relative-import graph
// includes the entry-point file, AND does not import any *other* project
// source file that is not part of the entry point's own evidence closure
// (a harness reaching around the entry point into a sibling inner-function
// file is exactly the bypass this exists to catch).
//
// Usage:
//   node check-harness-target.mjs <harness-file> <entry-file> <repo-root>
// Exit 0: harness targets the entry point (pass).
// Exit 1: harness does not import the entry point, or imports a project
//         source file outside the entry point's own evidence closure
//         (both printed to stderr as the reason).
// Exit 2: usage/file-not-found error.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const EVIDENCE_SCRIPT = join(HERE, 'logic-evidence.mjs');

const RELATIVE_IMPORT_RE =
  /\b(?:import|export)\s+(?:[^'"]*?\sfrom\s+)?['"](\.[^'"]+)['"]|\brequire\(\s*['"](\.[^'"]+)['"]\s*\)|\bimport\(\s*['"](\.[^'"]+)['"]\s*\)/g;

const CANDIDATE_EXTS = ['', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'];
const INDEX_EXTS = ['/index.ts', '/index.tsx', '/index.js', '/index.mjs'];

function resolveSpecifier(fromFile, spec) {
  const base = resolve(dirname(fromFile), spec);
  for (const ext of CANDIDATE_EXTS) {
    const candidate = base + ext;
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  for (const suffix of INDEX_EXTS) {
    const candidate = base + suffix;
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return null;
}

function directRelativeImports(file) {
  const src = readFileSync(file, 'utf8');
  const out = [];
  let m;
  RELATIVE_IMPORT_RE.lastIndex = 0;
  while ((m = RELATIVE_IMPORT_RE.exec(src))) {
    const spec = m[1] || m[2] || m[3];
    if (!spec) continue;
    const resolved = resolveSpecifier(file, spec);
    if (resolved) out.push(resolved);
  }
  return out;
}

function main() {
  const [, , harnessFile, entryFile, repoRoot] = process.argv;
  if (!harnessFile || !entryFile || !repoRoot) {
    console.error('usage: node check-harness-target.mjs <harness-file> <entry-file> <repo-root>');
    process.exit(2);
  }
  const harnessAbs = resolve(harnessFile);
  const entryAbs = resolve(entryFile);
  const repoAbs = resolve(repoRoot);
  if (!existsSync(harnessAbs)) {
    console.error(`check-harness-target: harness file not found: ${harnessFile}`);
    process.exit(2);
  }
  if (!existsSync(entryAbs)) {
    console.error(`check-harness-target: entry file not found: ${entryFile}`);
    process.exit(2);
  }

  // The entry point's own evidence closure — anything in here is fine to
  // import (it's part of the real path); anything outside it that isn't the
  // entry point itself is a bypass.
  let closure;
  try {
    const raw = execFileSync('node', [EVIDENCE_SCRIPT, entryAbs, repoAbs], { encoding: 'utf8' });
    closure = new Set(JSON.parse(raw).map((p) => resolve(repoAbs, p)));
  } catch (e) {
    console.error(`check-harness-target: failed to compute entry-point closure: ${e.message}`);
    process.exit(2);
  }

  const directImports = directRelativeImports(harnessAbs);
  const targetsEntry = directImports.some((f) => f === entryAbs) || harnessAbs === entryAbs;

  const outsideClosure = directImports.filter(
    (f) => f.startsWith(repoAbs) && f !== entryAbs && !closure.has(f),
  );

  if (!targetsEntry) {
    console.error(
      `FAIL: harness ${relative(repoAbs, harnessAbs)} does not import the entry point ` +
        `${relative(repoAbs, entryAbs)} — it may be calling an inner function directly, ` +
        `bypassing caller-side wrappers (caps/floors/multipliers). This is red-team Critical #2.`,
    );
    process.exit(1);
  }

  if (outsideClosure.length > 0) {
    console.error(
      `FAIL: harness ${relative(repoAbs, harnessAbs)} imports project source file(s) outside ` +
        `the entry point's evidence closure: ${outsideClosure.map((f) => relative(repoAbs, f)).join(', ')}. ` +
        `A harness that reaches around the entry point into an unrelated file is not exercising the real path.`,
    );
    process.exit(1);
  }

  console.log(`PASS: ${relative(repoAbs, harnessAbs)} targets the real entry point ${relative(repoAbs, entryAbs)}`);
  process.exit(0);
}

main();
