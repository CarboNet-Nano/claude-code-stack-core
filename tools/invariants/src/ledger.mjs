// Verdict-only ledger at docs/invariants/.meta/<id>.verdicts.jsonl -- reuses
// value-check's verdict-row fields (observation, freshness, scoredBy) and
// its `report` heartbeat shape (score.mjs's buildReport), but carries NO
// pin/ratification fields: those are meaningless without value-check's
// ratify flow (architect N3).
import { existsSync, mkdirSync, appendFileSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';

export function invariantsDir(repoRoot) {
  return join(repoRoot, 'docs', 'invariants');
}

export function ledgerPath(repoRoot, id) {
  return join(invariantsDir(repoRoot), '.meta', `${id}.verdicts.jsonl`);
}

export function listInvariantIds(repoRoot) {
  const dir = invariantsDir(repoRoot);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith('.sql'))
    .map((f) => f.slice(0, -4));
}

export function appendVerdict(repoRoot, row) {
  const p = ledgerPath(repoRoot, row.id);
  mkdirSync(dirname(p), { recursive: true });
  appendFileSync(p, `${JSON.stringify(row)}\n`);
}

export function readLedger(repoRoot, id) {
  const p = ledgerPath(repoRoot, id);
  if (!existsSync(p)) return [];
  const text = readFileSync(p, 'utf8');
  const records = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      records.push(JSON.parse(trimmed));
    } catch {
      // A hand-corrupted ledger line is not this reader's concern to fix;
      // skip it rather than crash the whole report on one bad byte (mirrors
      // score.mjs's readLedger).
    }
  }
  return records;
}

function nowISO() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

// Builds the one verdict row `run` appends per invariant per execution.
// `rows` is the raw array of result rows; `harnessError` is set when the
// query itself threw (connection drop, bad SQL, statement_timeout, etc.) --
// distinct from a scalar-equals shape violation, which is also 'error' per
// the expect grammar (never FAIL for a harness/shape problem).
export function buildVerdictRow(invariant, rows, harnessError) {
  const runAt = nowISO();
  let verdict;
  let observation;

  if (harnessError) {
    verdict = 'error';
    observation = { rowCount: null, value: null, error: harnessError };
  } else if (invariant.expect.type === 'zero-rows') {
    observation = { rowCount: rows.length, value: null };
    verdict = rows.length === 0 ? 'PASS' : 'FAIL';
  } else {
    const cols = rows.length ? Object.keys(rows[0]).length : 0;
    if (rows.length !== 1 || cols !== 1) {
      verdict = 'error';
      observation = { rowCount: rows.length, value: null, error: 'scalar-equals expects exactly one row with one column' };
    } else {
      const actual = Object.values(rows[0])[0];
      const expected = invariant.expect.value;
      const bothNumeric = actual !== null && actual !== '' && !Number.isNaN(Number(actual)) && !Number.isNaN(Number(expected));
      const matches = bothNumeric ? Number(actual) === Number(expected) : String(actual) === String(expected);
      verdict = matches ? 'PASS' : 'FAIL';
      observation = { rowCount: 1, value: actual };
    }
  }

  return {
    type: 'verdict',
    id: invariant.id,
    severity: invariant.severity,
    expect: invariant.expect.type === 'zero-rows' ? 'zero-rows' : `scalar-equals:${invariant.expect.value}`,
    runAt,
    observation,
    freshness: { source: 'live-query', asOf: runAt.slice(0, 10) },
    verdict,
    scoredBy: 'deterministic',
  };
}

// `report` semantics mirror score.mjs's buildReport: counts + a heartbeat
// (emptyLedger / staleRun) over the SAME 35-day window value-check uses.
export function buildReport(repoRoot) {
  const ids = listInvariantIds(repoRoot);

  const invariantsOut = [];
  let lastRunAt = null;
  for (const id of ids) {
    const verdicts = readLedger(repoRoot, id).filter((r) => r.type === 'verdict');
    const latest = verdicts.length ? verdicts[verdicts.length - 1] : null;
    if (latest && (!lastRunAt || new Date(latest.runAt) > new Date(lastRunAt))) lastRunAt = latest.runAt;
    invariantsOut.push({
      id,
      severity: latest ? latest.severity : null,
      verdict: latest ? latest.verdict : null,
      runAt: latest ? latest.runAt : null,
    });
  }

  const counts = {
    pass: invariantsOut.filter((i) => i.verdict === 'PASS').length,
    failCritical: invariantsOut.filter((i) => i.verdict === 'FAIL' && i.severity === 'critical').length,
    failWarn: invariantsOut.filter((i) => i.verdict === 'FAIL' && i.severity === 'warn').length,
    error: invariantsOut.filter((i) => i.verdict === 'error').length,
    neverRun: invariantsOut.filter((i) => i.verdict === null).length,
  };

  const heartbeatWindowDays = 35;
  const emptyLedger = ids.length === 0 || invariantsOut.every((i) => i.verdict === null);
  const staleRun = !lastRunAt || Math.floor((Date.now() - new Date(lastRunAt).getTime()) / 86400000) > heartbeatWindowDays;

  return {
    lastRunAt,
    invariants: invariantsOut,
    counts,
    heartbeat: { emptyLedger, staleRun, windowDays: heartbeatWindowDays },
  };
}
