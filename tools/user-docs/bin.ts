#!/usr/bin/env -S npx tsx
/**
 * ADR-045 user-docs runner CLI.
 *
 * user-docs-run (--guide <slug> | --all) --repo <path> --base-url <url> [--json]
 *
 * Enforcement is runner-side, not advisory, and every refusal is decided from a
 * STATIC parse of each docs-test — no browser is launched for a spec the runner
 * will refuse.
 *
 * Exit codes (severity, highest wins): 5 usage/config/allowlist > 4
 * RUNNER-UNAVAILABLE > 3 AUTH-EXPIRED > 1 STALE > 2 NEEDS-RECAPTURE > 0 fresh.
 * Note the deliberate 1-over-2 ordering: a UI that changed under a doc is a
 * louder signal than a flow that was never eligible for auto-replay.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
// Type-only: erased at runtime. The value import of parseDocsMeta is deliberately
// deferred until after assertRunnerAvailable(), so a missing node_modules exits 4
// (RUNNER-UNAVAILABLE) instead of dying in module resolution.
import type { CaptureRecord, DocsMeta } from './src/index.ts';

const RUNNER_DIR = dirname(fileURLToPath(import.meta.url));
const AUTH_EXPIRED_SENTINEL = 'USER_DOCS_AUTH_EXPIRED';
const MISSING_BROWSER = /Executable doesn't exist|playwright install/i;

type Status = 'fresh' | 'STALE' | 'NEEDS-RECAPTURE' | 'AUTH-EXPIRED';

type CaptureResult = {
  name: string;
  committed: string;
  fresh: string;
  identical: boolean;
  framing: string;
};

type GuideResult = {
  guide: string;
  status: Status;
  replay: DocsMeta['replay'] | 'unknown';
  failure: string | null;
  captures: CaptureResult[];
};

const SEVERITY: Record<number, number> = { 0: 0, 2: 1, 1: 2, 3: 3, 4: 4, 5: 5 };
const EXIT_FOR: Record<Status, number> = { fresh: 0, STALE: 1, 'NEEDS-RECAPTURE': 2, 'AUTH-EXPIRED': 3 };

function die(code: number, message: string): never {
  process.stderr.write(`user-docs-run: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv: string[]) {
  const args: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (!flag.startsWith('--')) die(5, `unexpected argument '${flag}'`);
    const key = flag.slice(2);
    if (key === 'all' || key === 'json') args[key] = true;
    else {
      const value = argv[++i];
      if (value === undefined || value.startsWith('--')) die(5, `--${key} requires a value`);
      args[key] = value;
    }
  }
  const guide = typeof args.guide === 'string' ? args.guide : undefined;
  const all = args.all === true;
  const repo = typeof args.repo === 'string' ? args.repo : undefined;
  const baseUrl = typeof args['base-url'] === 'string' ? args['base-url'] : undefined;

  if (!repo) die(5, 'usage: user-docs-run (--guide <slug> | --all) --repo <path> --base-url <url> [--json]');
  if (!baseUrl) die(5, '--base-url is required');
  if (guide && all) die(5, '--guide and --all are mutually exclusive');
  if (!guide && !all) die(5, 'one of --guide <slug> or --all is required');

  return { guide, all, repo: resolve(repo), baseUrl, json: args.json === true };
}

function loadProjectConfig(repo: string, baseUrl: string) {
  const path = join(repo, '.claude', 'user-docs.json');
  if (!existsSync(path)) die(5, `no .claude/user-docs.json under ${repo}`);
  let config: { captureBaseUrlAllowlist?: unknown };
  try {
    config = JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    die(5, `.claude/user-docs.json is not valid JSON (${(error as Error).message})`);
  }
  const allowlist = config.captureBaseUrlAllowlist;
  if (!Array.isArray(allowlist) || allowlist.length === 0) {
    die(5, '.claude/user-docs.json has no captureBaseUrlAllowlist — refusing to replay against an unfenced base URL');
  }
  if (!allowlist.includes(baseUrl)) {
    die(5, `base URL ${baseUrl} is not in captureBaseUrlAllowlist (${allowlist.join(', ')}) — refusing to run`);
  }
  return config;
}

function assertRunnerAvailable() {
  const modules = join(RUNNER_DIR, 'node_modules');
  if (!existsSync(modules) || !existsSync(join(modules, '@playwright', 'test'))) {
    die(4, 'RUNNER-UNAVAILABLE: node_modules missing — re-run the /user-docs preflight bootstrap (npm install + npx playwright install chromium)');
  }
}

function discoverSpecs(repo: string, guide?: string): string[] {
  const captures = join(repo, 'docs', 'user', 'captures');
  if (!existsSync(captures)) die(5, `no docs-tests directory at ${captures}`);
  const all = readdirSync(captures).filter((f) => f.endsWith('.docs.ts')).sort();
  if (!guide) return all;
  const wanted = `${guide}.docs.ts`;
  if (!all.includes(wanted)) die(5, `no docs-test for guide '${guide}' at ${join(captures, wanted)}`);
  return [wanted];
}

function refusalFor(replay: DocsMeta['replay']): string {
  return replay === 'reset-required' ? 'reset-required, not yet automated' : 'manual';
}

function readManifest(path: string): CaptureRecord[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line) as CaptureRecord);
}

function identical(a: string, b: string): boolean {
  if (!existsSync(a) || !existsSync(b)) return false;
  return readFileSync(a).equals(readFileSync(b));
}

function runPlaywright(projects: string[], env: NodeJS.ProcessEnv) {
  const args = ['playwright', 'test', '--config', join(RUNNER_DIR, 'playwright.config.ts')];
  for (const project of projects) args.push('--project', project);
  return spawnSync('npx', args, { cwd: RUNNER_DIR, env, encoding: 'utf8' });
}

type ProjectOutcome = { ran: number; failure: string | null };

// Tracks how many results each project produced, not just its failures: a
// project that collected ZERO tests is indistinguishable from a passing one if
// you only look at failures, and would be reported `fresh`. A freshness tool
// that reports fresh because it ran nothing is the worst possible outcome, so
// zero-collected is escalated to RUNNER-UNAVAILABLE by the caller.
function outcomesByProject(reportPath: string): Map<string, ProjectOutcome> {
  const outcomes = new Map<string, ProjectOutcome>();
  if (!existsSync(reportPath)) return outcomes;
  let report: any;
  try {
    report = JSON.parse(readFileSync(reportPath, 'utf8'));
  } catch {
    return outcomes;
  }
  const walk = (suite: any) => {
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests ?? []) {
        const project = test.projectName ?? spec.title;
        const outcome = outcomes.get(project) ?? { ran: 0, failure: null };
        outcome.ran += (test.results ?? []).length;
        outcomes.set(project, outcome);
        const bad = (test.results ?? []).find((r: any) => r.status !== 'passed' && r.status !== 'skipped');
        if (!bad || outcome.failure) continue;
        const message = String(bad.error?.message ?? bad.errors?.[0]?.message ?? 'assertion failed')
          .replace(/\[[0-9;]*m/g, '')
          .split('\n')[0];
        outcome.failure = message;
      }
    }
    for (const child of suite.suites ?? []) walk(child);
  };
  for (const suite of report.suites ?? []) walk(suite);
  return outcomes;
}

async function main() {
  const { guide, repo, baseUrl, json } = parseArgs(process.argv.slice(2));
  loadProjectConfig(repo, baseUrl);
  assertRunnerAvailable();
  const { parseDocsMeta } = await import('./src/index.ts');

  const specs = discoverSpecs(repo, guide);
  const captures = join(repo, 'docs', 'user', 'captures');
  const results: GuideResult[] = [];
  const replayable: string[] = [];

  for (const file of specs) {
    const slug = file.replace(/\.docs\.ts$/, '');
    const meta = parseDocsMeta(readFileSync(join(captures, file), 'utf8'));
    if (!meta?.replay) die(5, `${file} has no parseable 'export const docsMeta' with a replay mode`);

    if (meta.replay !== 'auto') {
      results.push({ guide: slug, status: 'NEEDS-RECAPTURE', replay: meta.replay, failure: refusalFor(meta.replay), captures: [] });
      continue;
    }

    const authState = meta.authState ? resolve(repo, meta.authState) : undefined;
    if (!authState || !existsSync(authState)) {
      results.push({ guide: slug, status: 'AUTH-EXPIRED', replay: 'auto', failure: `storage state missing at ${meta.authState ?? '<unset>'}`, captures: [] });
      continue;
    }
    replayable.push(slug);
  }

  if (replayable.length > 0) {
    const runDir = join(RUNNER_DIR, '.run');
    rmSync(runDir, { recursive: true, force: true });
    mkdirSync(runDir, { recursive: true });
    const manifestPath = join(runDir, 'captures.jsonl');
    const reportPath = join(runDir, 'report.json');
    const freshDir = join(runDir, 'fresh');

    const run = runPlaywright(replayable, {
      ...process.env,
      USER_DOCS_REPO: repo,
      USER_DOCS_BASE_URL: baseUrl,
      USER_DOCS_MANIFEST: manifestPath,
      USER_DOCS_REPORT: reportPath,
      USER_DOCS_FRESH_DIR: freshDir,
    });

    const output = `${run.stdout ?? ''}${run.stderr ?? ''}`;
    if (MISSING_BROWSER.test(output)) {
      die(4, 'RUNNER-UNAVAILABLE: Chromium is not installed — run `npx playwright install chromium` in the runner directory');
    }

    const outcomes = outcomesByProject(reportPath);
    const manifest = readManifest(manifestPath);

    const collectedNothing = replayable.filter((slug) => (outcomes.get(slug)?.ran ?? 0) === 0);
    if (collectedNothing.length > 0) {
      die(4, `RUNNER-UNAVAILABLE: no tests were collected for ${collectedNothing.join(', ')} — the docs-test did not load (check the @stack/user-docs alias and testMatch). Refusing to report a guide fresh on a run that executed nothing.`);
    }

    for (const slug of replayable) {
      // shot() stamps each record with the docs-test's own filename stem, which
      // is exactly the project name used here.
      const shots = manifest.filter((c) => c.guide === slug);
      const failure = outcomes.get(slug)?.failure ?? null;
      const status: Status = failure ? (failure.includes(AUTH_EXPIRED_SENTINEL) ? 'AUTH-EXPIRED' : 'STALE') : 'fresh';
      results.push({
        guide: slug,
        status,
        replay: 'auto',
        failure,
        captures: shots.map((c) => ({
          name: c.name,
          committed: c.committed,
          fresh: c.fresh,
          identical: identical(c.committed, c.fresh),
          framing: c.framing,
        })),
      });
    }
  }

  results.sort((a, b) => a.guide.localeCompare(b.guide));

  if (json) {
    process.stdout.write(`${JSON.stringify({ results }, null, 2)}\n`);
  } else {
    for (const r of results) {
      const suffix = r.failure ? ` (${r.failure})` : '';
      const changed = r.captures.filter((c) => !c.identical).length;
      process.stdout.write(`${r.guide}: ${r.status}${suffix} — ${r.captures.length} captures, ${changed} differing\n`);
    }
  }

  const exit = results.reduce((worst, r) => {
    const candidate = EXIT_FOR[r.status];
    return SEVERITY[candidate] > SEVERITY[worst] ? candidate : worst;
  }, 0);
  process.exit(exit);
}

await main();
