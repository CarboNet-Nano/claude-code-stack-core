#!/usr/bin/env node
/**
 * ADR record-drift check — portable across repos.
 *
 * WHY THIS EXISTS
 *
 * Agents read design documents as ground truth, at scale, faster than a human would
 * notice an error. A human skimming a doc that says "not built" about live code gets
 * suspicious. An agent does not.
 *
 * On 2026-08-05, in carbonet-dashboards, an architecture-critic pass read ADR-064's
 * header ("PROPOSED — design only; not built"), concluded the feature was orphaned dead
 * code, and recommended replacing the project's core data model. The feature had
 * shipped three weeks earlier; only the header was stale. The verdict had to be
 * withdrawn and re-run. A sweep then found 14 more instances across four months.
 *
 * Two mechanisms, both mechanical, both cheap to detect:
 *
 *   1. STALE STATUS — the design loop terminates at "converged/approved", the code lands
 *      0-2 days later via PR, and nobody returns to flip the status. It fossilizes at
 *      whatever the last review round wrote.
 *   2. DANGLING REFERENCE — a doc cites ADR-NNN that no file defines, usually because the
 *      cited ADR was authored on a branch that closed unmerged, or was never written.
 *
 * Offline by design: no network, no `gh` calls. Reads the ADR directory and git log.
 *
 *   node check.mjs [--dir docs/ADRs] [--baseline N] [--json]
 *
 * Exit 0 = at or below baseline. Exit 1 = new drift. Exit 2 = bad invocation.
 *
 * BASELINE: adopting repos will have pre-existing drift. Run once, set --baseline (or
 * `adrDrift.baseline` in package.json) to the current count, and the check then fails
 * only when drift RISES. Lower it as debt is paid; never raise it without fixing the
 * cause. Same convention as a lint allowlist ceiling.
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

function arg(flag, fallback) {
    const i = process.argv.indexOf(flag);
    return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const JSON_OUT = process.argv.includes('--json');

/**
 * Anchor every relative path to the repo root, not the caller's CWD. Reading
 * `package.json` from CWD meant the tool worked only when invoked from exactly
 * one directory: from the repo root the ADR dir resolved but a tool-local
 * config did not, and from the tool's own directory the reverse — so a declared
 * baseline silently never applied and the check failed at 0. Falls back to CWD
 * outside a git repo.
 */
function repoRoot() {
    try {
        return execSync('git rev-parse --show-toplevel', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch {
        return process.cwd();
    }
}
const ROOT = repoRoot();
const TOOL_DIR = dirname(dirname(fileURLToPath(import.meta.url)));

function readAdrDrift(pkgPath) {
    try {
        return JSON.parse(readFileSync(pkgPath, 'utf8')).adrDrift ?? null;
    } catch {
        return null;
    }
}

/**
 * Config precedence: the ADOPTING repo's root package.json wins, preserving the
 * portable-across-repos intent. A repo with no root package.json — any shell,
 * Python, or Go repo — falls back to the tool's own package.json so a declared
 * baseline still applies instead of silently reverting to 0.
 */
const cfg = readAdrDrift(join(ROOT, 'package.json'))
    ?? readAdrDrift(join(TOOL_DIR, 'package.json'))
    ?? {};

const ADR_DIR_RAW = arg('--dir', cfg.dir ?? 'docs/ADRs');
const ADR_DIR = resolve(ROOT, ADR_DIR_RAW);
const BASELINE = Number(arg('--baseline', cfg.baseline ?? 0));

if (!existsSync(ADR_DIR)) {
    // Not an error: plenty of repos have no ADRs. Nothing to check.
    if (JSON_OUT) console.log(JSON.stringify({ ok: true, skipped: `no ${ADR_DIR}` }));
    else console.log(`ADR drift check skipped — no ${ADR_DIR} directory.`);
    process.exit(0);
}

/**
 * Status VALUES asserting the work is not yet built.
 *
 * Matched against an explicit status declaration ONLY, never free header prose. An
 * early version scanned the first 15 lines and produced false positives on documents
 * whose TITLE contained "design" while the status said "Accepted". A guard with false
 * positives gets ignored, which defeats it.
 */
const UNBUILT = /^(design only|not built|not yet built|proposed|draft|ready for (approval|sign-?off))\b/i;

/** Status VALUES asserting the work IS resolved — these win outright. */
const BUILT = /\b(accepted|shipped|implemented|executed|ratified|live|superseded|retired|dead|closed|rejected|withdrawn)\b/i;

/** An explicit correction/recovery banner — the status has been reviewed by a human. */
const CORRECTED = /STATUS CORRECTED|Recovery note|Header correction|DEAD —/;

/**
 * Extract the declared status. Formats vary widely across repos:
 *   "Status: Proposed"         "- Status: Proposed (design)"
 *   "**Status:** ACCEPTED"     "_… · status: **accepted** (2026-06-11) …_"
 */
function declaredStatus(text) {
    for (const line of text.split('\n').slice(0, 40)) {
        if (!/status/i.test(line)) continue;
        const m = line.match(/\**status:?\**\s*[:\-—]?\s*(.+)/i);
        if (m) return m[1].replace(/[*_`]/g, '').trim();
    }
    return null;
}

/**
 * Commit subjects that count as EVIDENCE OF IMPLEMENTATION.
 *
 * Excludes docs/chore/test/style commits: the commit that CREATES an ADR necessarily
 * names it, and would otherwise "prove" its own subject shipped. Caught immediately when
 * this tool was first run against a second repo — ADR-038 ("stub only") was flagged by
 * `docs(adr): ... add ADR-038/039 stubs`, the commit that created the stub. A merge
 * commit naming an ADR is also weak evidence, but is kept: merges are how work lands.
 */
const NON_IMPLEMENTING = /^(docs|chore|style|test|ci|build|revert)[(:]/i;

function commitSubjects() {
    try {
        // cwd-pinned to the repo root: from a subdirectory `git log` would still
        // resolve, but anchoring it keeps every path in this tool root-relative.
        return execSync('git log --first-parent --pretty=%s -n 4000', { encoding: 'utf8', cwd: ROOT })
            .split('\n')
            .filter((s) => s && !NON_IMPLEMENTING.test(s.trim()))
            .join('\n');
    } catch {
        return ''; // not a git repo, or shallow clone — check 1 degrades to a no-op
    }
}

const files = readdirSync(ADR_DIR)
    .filter((f) => f.endsWith('.md') && /^\d{3}/.test(f))
    .map((f) => join(ADR_DIR, f));

const subjects = commitSubjects();
/**
 * Numbers that RESOLVE for citation purposes — top-level ADRs plus `drafts/`.
 *
 * Citing a draft is legitimate: an ADR under review is a real document with a real
 * number. Scanning only the top level made live drafts look like dangling references —
 * this tool's second false-positive class, both found by running it against real data.
 * Drafts are NOT scanned for stale status: "proposed" is correct for a draft.
 */
const DRAFTS_DIR = join(ADR_DIR, 'drafts');
const draftNums = existsSync(DRAFTS_DIR)
    ? readdirSync(DRAFTS_DIR).filter((f) => f.endsWith('.md') && /^\d{3}/.test(f)).map((f) => f.slice(0, 3))
    : [];
const defined = new Set([...files.map((f) => basename(f).slice(0, 3)), ...draftNums]);
const findings = [];

for (const file of files) {
    const text = readFileSync(file, 'utf8');
    const num = basename(file).slice(0, 3);

    // ---- 1: declared status says unbuilt, but merged commits name this ADR ----
    const status = declaredStatus(text);
    if (status && UNBUILT.test(status) && !BUILT.test(status) && !CORRECTED.test(text.slice(0, 2000))) {
        const cited = new RegExp(`ADR[- ]?0*${num}\\b`, 'i');
        const shipped = subjects.split('\n').filter((t) => cited.test(t));
        if (shipped.length) {
            findings.push({
                severity: 'HIGH',
                adr: num,
                file,
                type: 'stale-status',
                detail: `declared status "${status}" asserts unbuilt, but ${shipped.length} merged commit(s) name it`,
                evidence: shipped.slice(0, 3),
            });
        }
    }

    // ---- 2: dangling ADR references ----
    for (const m of text.matchAll(/\bADR[- ]?(\d{3})\b/g)) {
        const ref = m[1];
        if (ref === num || defined.has(ref)) continue;
        if (findings.some((f) => f.type === 'dangling-ref' && f.adr === num && f.ref === ref)) continue;
        findings.push({
            severity: 'MEDIUM',
            adr: num,
            file,
            type: 'dangling-ref',
            ref,
            detail: `cites ADR-${ref}, which no file in ${ADR_DIR} defines`,
        });
    }
}

const over = findings.length > BASELINE;

if (JSON_OUT) {
    console.log(JSON.stringify({ ok: !over, count: findings.length, baseline: BASELINE, findings }, null, 2));
    process.exit(over ? 1 : 0);
}

if (!findings.length) {
    console.log(`✅ ADR drift check clean — ${files.length} ADRs in ${ADR_DIR}.`);
    process.exit(0);
}

const out = over ? console.error : console.log;
out(`\n${over ? '❌ FAIL' : '⚠️  at baseline'} — ADR record drift: ${findings.length} finding(s), baseline ${BASELINE}\n`);
for (const f of findings) {
    out(`  [${f.severity}] ADR-${f.adr}  ${f.type}`);
    out(`         ${f.file}`);
    out(`         ${f.detail}`);
    for (const e of f.evidence ?? []) out(`           · ${e}`);
}
out(`
How to fix:
  stale-status  — the work shipped; update the status line, or prepend a correction
                  note. A design record that says "not built" about live code will
                  mislead the next reader — and an agent will not get suspicious the
                  way a human skimming it would.
  dangling-ref  — the cited ADR does not exist. It may live on an unmerged branch
                  (git log --all --diff-filter=A --name-only -- '${ADR_DIR}/NNN*'),
                  or was never written. Recover it, write a stub, or fix the citation.
`);

if (over) {
    console.error(`NEW drift: ${findings.length - BASELINE} above the ${BASELINE} baseline.`);
    console.error(`Fix it, or raise the baseline in the same PR with a comment saying why.\n`);
} else {
    console.log(`At or below baseline — not failing. Fixing any of these and lowering the`);
    console.log(`baseline is welcome.\n`);
}

process.exit(over ? 1 : 0);
