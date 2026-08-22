#!/usr/bin/env node
// logic-evidence.mjs — docs-agent-pipeline-v2 §2.1 (ADR pending, Phase 5a).
//
// Computes the producer-independent evidence closure for a logic-extraction
// unit: a transitive static-import walk starting at a named entry-point file,
// bounded to the target repo. This is what the parity-gate checker sees —
// NOT the producer's self-reported logicMeta.sources — so a producer cannot
// hide a hallucinated branch by omitting a file from its own citation list.
//
// Zero LLM tokens. Regex-grade import resolution only (no type-checker, no
// bundler): follows relative `import`/`require`/dynamic-import specifiers
// only. Absolute/bare package specifiers (node_modules, path aliases like
// "@carbonet/ui/...") are NOT followed — they're outside the repo's own
// logic and out of scope for this walk. This is a known, stated limitation
// (docs-agent-pipeline-v2.md §9 residual #3): dynamic dispatch, DI
// containers, and string-built import paths are invisible to this walker.
// The entry-point execution gate (parity via the real harness) is what
// covers the runtime path regardless of what this static walk saw.
//
// Usage:
//   node logic-evidence.mjs <entry-file> <repo-root>
// Output: JSON array of repo-relative file paths (the entry file first),
// sorted, deduped, printed to stdout. Exit 0 on success.
// Exit 2: entry file not found / not inside repo-root.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve, dirname, join, relative, extname } from 'node:path';

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

function walk(entryFile, repoRoot) {
  const seen = new Set();
  const queue = [resolve(entryFile)];
  const repoAbs = resolve(repoRoot);

  while (queue.length) {
    const file = queue.pop();
    if (seen.has(file)) continue;
    if (!file.startsWith(repoAbs)) continue; // never leave the repo
    if (!existsSync(file) || !statSync(file).isFile()) continue;
    const ext = extname(file);
    if (!['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'].includes(ext)) continue;

    seen.add(file);

    let src;
    try {
      src = readFileSync(file, 'utf8');
    } catch {
      continue;
    }

    let m;
    RELATIVE_IMPORT_RE.lastIndex = 0;
    while ((m = RELATIVE_IMPORT_RE.exec(src))) {
      const spec = m[1] || m[2] || m[3];
      if (!spec) continue;
      const resolved = resolveSpecifier(file, spec);
      if (resolved) queue.push(resolved);
    }
  }

  return Array.from(seen)
    .map((f) => relative(repoAbs, f))
    .sort();
}

function main() {
  const [, , entryFile, repoRoot] = process.argv;
  if (!entryFile || !repoRoot) {
    console.error('usage: node logic-evidence.mjs <entry-file> <repo-root>');
    process.exit(2);
  }
  const entryAbs = resolve(entryFile);
  if (!existsSync(entryAbs)) {
    console.error(`logic-evidence: entry file not found: ${entryFile}`);
    process.exit(2);
  }
  const repoAbs = resolve(repoRoot);
  if (!entryAbs.startsWith(repoAbs)) {
    console.error(`logic-evidence: entry file is outside repo-root: ${entryFile}`);
    process.exit(2);
  }
  const closure = walk(entryAbs, repoAbs);
  console.log(JSON.stringify(closure, null, 2));
}

main();
