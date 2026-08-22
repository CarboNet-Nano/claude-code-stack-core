#!/usr/bin/env node
// tools/invariants -- production-data invariants MVP (ADR-082 P1f). Native
// SQL files under docs/invariants/*.sql, executed through a database-
// enforced read-only Postgres connection behind a blocking write-probe,
// verdicts appended to docs/invariants/.meta/<id>.verdicts.jsonl.
//
// Exit codes: 0 ok (includes individual FAIL/error verdicts -- those are
// legitimate recorded outcomes, not process failures; `report` is how a
// caller reads them, mirroring value-check's score-always-exits-0
// convention) · 1 vacuous (zero invariant files, or --only matched none)
// · 2 usage/config error (missing --repo-root, missing INVARIANTS_DB_URL,
// unknown subcommand) · 3 parse error (docs/invariants/*.sql parse
// contract violation) · 4 write-probe refusal (CREATE TEMP TABLE + INSERT
// both succeeded -- the role is not a database-enforced read-only role)
// · 5 could not connect to INVARIANTS_DB_URL.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseInvariantFile } from './src/parse.mjs';
import { buildPgExecutor, buildFakeExecutor } from './src/executor.mjs';
import { appendVerdict, buildVerdictRow, buildReport, invariantsDir } from './src/ledger.mjs';

function parseFlags(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        out[key] = true;
      } else {
        out[key] = next;
        i++;
      }
    }
  }
  return out;
}

function die(code, msg) {
  console.error(`invariants: ${msg}`);
  process.exitCode = code;
}

async function cmdRun(flags) {
  const repoRoot = flags['repo-root'];
  if (!repoRoot || repoRoot === true) return die(2, '`run` requires --repo-root <path>');

  const dir = invariantsDir(repoRoot);
  let files = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.sql')) : [];
  if (flags.only) files = files.filter((f) => f.slice(0, -4) === flags.only);

  if (files.length === 0) {
    const scope = flags.only ? ` matching --only ${flags.only}` : '';
    return die(1, `vacuous -- zero invariant files found${scope} under ${dir}`);
  }

  const parsed = [];
  const parseErrors = [];
  for (const f of files) {
    const abs = join(dir, f);
    const result = parseInvariantFile(abs, readFileSync);
    if (result.ok) parsed.push(result.invariant);
    else parseErrors.push(`${f}: ${result.error}`);
  }
  if (parseErrors.length > 0) {
    console.error('invariants: parse error(s):');
    for (const e of parseErrors) console.error(`  ${e}`);
    process.exitCode = 3;
    return;
  }

  const fakeResultsPath = process.env.INVARIANTS_FAKE_RESULTS;
  let client = null;
  let exec;
  if (fakeResultsPath) {
    exec = buildFakeExecutor(fakeResultsPath, readFileSync);
  } else {
    const dbUrl = process.env.INVARIANTS_DB_URL;
    if (!dbUrl) return die(2, 'INVARIANTS_DB_URL is required (must be a database-enforced read-only role)');
    const { Client } = await import('pg');
    client = new Client({ connectionString: dbUrl });
    try {
      await client.connect();
    } catch (err) {
      return die(5, `could not connect via INVARIANTS_DB_URL: ${err.message}`);
    }
    exec = buildPgExecutor(client);
  }

  const probe = await exec.writeProbe();
  if (probe.createOk && probe.insertOk) {
    const role = await exec.currentRole();
    if (client) await client.end().catch(() => {});
    return die(
      4,
      `refusing to run -- write-probe succeeded (CREATE TEMP TABLE + INSERT both succeeded) for role '${role}'. ` +
        'INVARIANTS_DB_URL must be a database-enforced read-only role (e.g. a true read replica), not merely a session-level flag.',
    );
  }

  await exec.setReadOnlySession();

  let executedCount = 0;
  for (const inv of parsed) {
    executedCount++;
    let rows = null;
    let harnessError = null;
    try {
      rows = await exec.runQuery(inv.id, inv.query);
    } catch (err) {
      harnessError = err.message;
    }
    const row = buildVerdictRow(inv, rows || [], harnessError);
    appendVerdict(repoRoot, row);
    console.log(`${inv.id}: ${row.verdict}`);
  }

  if (client) await client.end().catch(() => {});

  if (executedCount === 0) return die(1, 'vacuous -- zero queries executed');
  process.exitCode = 0;
}

function cmdReport(flags) {
  const repoRoot = flags['repo-root'];
  if (!repoRoot || repoRoot === true) return die(2, '`report` requires --repo-root <path>');

  const report = buildReport(repoRoot);
  if (flags.json) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }
  console.log(`docs/invariants/ report -- repo ${repoRoot}`);
  console.log(`last run: ${report.lastRunAt || 'never'}`);
  for (const inv of report.invariants) {
    console.log(`  ${inv.id}: ${inv.verdict || 'never scored'} (${inv.severity || '?'})`);
  }
  console.log(`counts: ${JSON.stringify(report.counts)}`);
  console.log(`heartbeat: ${JSON.stringify(report.heartbeat)}`);
}

async function main() {
  const [, , cmd, ...rest] = process.argv;
  const flags = parseFlags(rest);

  if (cmd === 'run') return cmdRun(flags);
  if (cmd === 'report') return cmdReport(flags);

  console.error(`invariants: unknown subcommand '${cmd}'`);
  console.error('usage: bin.mjs <run|report> --repo-root <path> [--only <id>] [--json]');
  process.exitCode = 2;
}

await main();
