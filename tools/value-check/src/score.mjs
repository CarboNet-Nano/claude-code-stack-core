#!/usr/bin/env node
// score.mjs — the ONE deterministic engine behind `/value-check` (proposal
// docs/proposals/2026-07-30-business-value-real-build-v2.md §4, D12, D13,
// D14). No LLM participates in PASS/MISS. scripts/value-check-gate.sh shells
// out to this file for every computed/hashed/validated value so there is
// exactly one implementation of canonicalization, bounds, and the D14
// allowlist — a second implementation in bash would drift (CLAIM-CHANGED on
// every run) the first time key-sorting or whitespace disagreed.
//
// Subcommands (each prints one JSON object to stdout; non-zero exit means
// "could not even attempt the computation", NOT "verdict is non-passing" —
// a CLAIM-INVALID verdict is still printed JSON on exit 0):
//   bounds
//   canon-hash   <claim-file>
//   check-bounds <claim-file>
//   resolve-probe-path --repo <path> --probe-rel <rel>   (CRITICAL 2, prints abs path or exits 1)
//   check-probe-safety --file <abs-path>                 (CRITICAL 1, exits 1 with violations on stderr)
//   precheck   --repo <path> --claim <id>
//   postcheck  --repo <path> --claim <id> --exit-code <n> --stdout-file <path>
//   anomaly-scan --repo <path>
//   render     --repo <path> [--write]
//   report     --repo <path> [--claim <id>] [--json]
//
// D16: the verdict is a single terminal first-match state (§4's 13 rules);
// apparatus/anomaly conditions co-occur in signals[]. PASS/MISS/NOT-YET-DUE
// are never added to signals[] — they are the verdict itself, not a
// co-occurring fault (see the D16 signal table, which omits all three).

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const SCORER_VERSION = '1.0.0';

// ── D13 bounds (constants, printed by `bounds` so a claim author reads them
// before writing a claim rather than after a refusal) ───────────────────────
const BOUNDS = {
  minN_min: 3,
  staleness_min: 1,
  staleness_max: 14,
  notScorableBefore_maxDaysAfterRatify: 90,
  targetBy_maxDaysAfterRatify: 365,
  metricNameRegex: '^[a-z][a-z0-9_]{2,63}$',
  unitMaxLen: 32,
  unitCharsRegex: '^[A-Za-z0-9/_%.-]+$',
  statementMinLen: 40,
  statementMaxLen: 600,
  attributionNoteMinLen: 20,
  attributionNoteMaxLen: 300,
  probeTableRegex: '^[a-z_][a-z0-9_]*(\\.[a-z_][a-z0-9_]*)?$',
};

// D11's family-separation rule 2, restated exactly (openai-review.sh's
// OAIR_CLAUDE_RE) so the two reviewers can't drift on what counts as "the
// producer's own family."
const CLAUDE_FAMILY_RE = /claude|anthropic|opus|sonnet|haiku|fable/i;

// ── security remediation (2026-07-31 audit): claimId charset + probe.path
// containment + probe content safety. See the three new checks below —
// claimPath()/ledgerPath() (HIGH 5), resolveProbeAbsSafe() (CRITICAL 2),
// probeSafetyViolations() (CRITICAL 1). ─────────────────────────────────────

// HIGH 5: a claimId is interpolated straight into filesystem paths
// (claimPath/ledgerPath below). Held to the exact shape the fixture claimId
// already uses (`md-daily-march-autosettle-v1`, and `revise`'s generated
// `<base>-vN`) — lowercase alnum segments joined by single hyphens, no `.`,
// no `/`, so a `../`-shaped claimId can never escape docs/value/{claims,.meta}/.
const CLAIM_ID_RE = /^[a-z0-9][a-z0-9-]*$/;

function assertSafeClaimId(claimId) {
  if (typeof claimId !== 'string' || !CLAIM_ID_RE.test(claimId)) {
    throw new Error(`unsafe claimId (must match ${CLAIM_ID_RE}): ${JSON.stringify(claimId)}`);
  }
}

// HIGH 5 follow-up (2026-07-31 audit re-review): assertSafeClaimId's throw
// is correct for a caller-supplied claimId (--claim, a claimId embedded in
// another claim's `supersedes`) but wrong for an id merely *enumerated* off
// disk (a `docs/value/claims/*.json` or `docs/value/.meta/*.verdicts.jsonl`
// filename) — a single stray file with an unsafe-shaped name (e.g. a dotted
// filename, whose `.json`-stripped id then contains a literal `.`) would
// otherwise throw uncaught out of `render`/`report`/`anomaly-scan`, crashing
// all three on every subsequent invocation until the file is manually
// removed. Directory enumeration filters silently (skip, don't throw) —
// only a directly-supplied claimId is asked to justify itself with an
// error.
function isSafeClaimId(claimId) {
  return typeof claimId === 'string' && CLAIM_ID_RE.test(claimId);
}

// CRITICAL 1: a claim's probe file gets `cat`'d into the D11 review context
// at ratify-time and `psql -f`'d at score-time. `--no-psqlrc` and
// `-v ON_ERROR_STOP=1` do NOT disable psql's client-side backslash
// meta-command processing (`\!`, `\copy ... program`, `\o |cmd`, `\g |cmd`,
// and many more) — those are a local command-execution surface that
// completely bypasses the D9 Layer 1 read-only DB role. A meta-command is
// not always line-initial (`SELECT 1 \g |sh -c '...'` is valid psql input),
// so this cannot be a "line starts with \" heuristic.
//
// This used to be a hand-rolled SQL lexer that tracked single-quote/
// dollar-quote/comment state and only flagged a bare backslash found
// *outside* those states — an allowlist-of-safe-SQL approach. It was
// unsound: it had no double-quoted-identifier state, and it treated `''`
// as the only way a quoted string ends, so a file that opens (but never
// legitimately closes, from the lexer's point of view) a squote state —
// e.g. `SELECT 1 AS "it's";` (the `'` inside a double-quoted identifier
// walks the lexer into `squote`, which psql's own parser never enters) —
// hid a subsequent `\!` line from the checker entirely while psql still
// executed it. Closing that gap with more SQL-lexer parity (E-strings,
// double-quote state, etc.) is unbounded work for a check whose entire
// value is being airtight, so per the "closed-refusal is correct here"
// remediation: reject the file if it contains a backslash BYTE anywhere at
// all, full stop — no string/comment-state carve-out, nothing about *why*
// it's there is inspected. Plain read-only SQL never needs a literal
// backslash (see the fixture probe, rewritten to use a non-backslash LIKE
// ESCAPE character instead of relying on one).
function probeSafetyViolations(text) {
  const violations = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('\\')) {
      violations.push({ line: i + 1, content: lines[i].trim() });
    }
  }
  return violations;
}

// CRITICAL 2: a claim's `probe.path` is claim-author-controlled and, before
// this fix, was joined onto `repo` with no containment check — a
// `"probe.path": "../../../../.ssh/id_rsa"` claim would get that file
// `cat`'d verbatim into the D11 review context (ratify) and potentially
// `psql -f`'d (score). Resolves via `fs.realpathSync` (follows symlinks, so
// a symlink planted inside docs/value/probes/ pointing outside it is also
// caught) and refuses unless the real path is contained under
// `<repo>/docs/value/probes/`.
function resolveProbeAbsSafe(repo, probeRelPath) {
  if (typeof probeRelPath !== 'string' || !probeRelPath) return { ok: false };
  const allowedRoot = path.join(repo, 'docs', 'value', 'probes');
  let allowedReal;
  try {
    allowedReal = fs.realpathSync(allowedRoot);
  } catch {
    return { ok: false };
  }
  const candidate = path.join(repo, probeRelPath);
  let real;
  try {
    real = fs.realpathSync(candidate);
  } catch {
    return { ok: false };
  }
  const rel = path.relative(allowedReal, real);
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) {
    return { ok: false };
  }
  return { ok: true, abs: real };
}

// ── small utilities ─────────────────────────────────────────────────────────

function sha256hex(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function sortKeysDeep(value) {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value && typeof value === 'object') {
    return Object.keys(value)
      .sort()
      .reduce((acc, k) => {
        acc[k] = sortKeysDeep(value[k]);
        return acc;
      }, {});
  }
  return value;
}

// D12: "claimCoreSha256 — sha256 of the canonicalized claim file: the whole
// claim JSON with object keys sorted and whitespace normalized." Object keys
// sorted recursively; JSON.stringify with no indent already normalizes
// whitespace. One implementation, called by both `ratify` (bash) and every
// `score` (via precheck) so the two can never disagree.
function canonHashOfObject(obj) {
  return sha256hex(JSON.stringify(sortKeysDeep(obj)));
}

function parseISODate(s) {
  if (typeof s !== 'string' || !s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

function addDays(date, n) {
  return new Date(date.getTime() + n * 86400000);
}

function todayUTC() {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

function ageDaysFrom(dateStrYYYYMMDD) {
  const asOf = new Date(`${dateStrYYYYMMDD}T00:00:00Z`);
  if (Number.isNaN(asOf.getTime())) return null;
  return Math.floor((todayUTC().getTime() - asOf.getTime()) / 86400000);
}

function nowISO() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function git(repo, args) {
  return execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}

function gitOk(repo, args) {
  try {
    execFileSync('git', args, { cwd: repo, stdio: ['ignore', 'ignore', 'ignore'] });
    return true;
  } catch {
    return false;
  }
}

function gitHashObject(absPath) {
  try {
    return execFileSync('git', ['hash-object', absPath], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

// ── Contract A/B/C paths ─────────────────────────────────────────────────────

function claimPath(repo, claimId) {
  assertSafeClaimId(claimId);
  return path.join(repo, 'docs', 'value', 'claims', `${claimId}.json`);
}
function ledgerPath(repo, claimId) {
  assertSafeClaimId(claimId);
  return path.join(repo, 'docs', 'value', '.meta', `${claimId}.verdicts.jsonl`);
}
function claimsDir(repo) {
  return path.join(repo, 'docs', 'value', 'claims');
}
function rollupPath(repo) {
  return path.join(repo, 'docs', 'value', 'ROLLUP.md');
}

// HIGH 5 follow-up: the one implementation of "enumerate claimIds off
// docs/value/claims/*.json", used by anomalyScan/renderBody/buildReport
// instead of each independently re-deriving readdir+filter+slice — an
// unsafe-shaped filename is skipped here, never reaches claimPath/
// ledgerPath's assertSafeClaimId.
function listClaimIds(repo) {
  const dir = claimsDir(repo);
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => f.slice(0, -5))
    .filter(isSafeClaimId);
}

function readClaim(repo, claimId) {
  const p = claimPath(repo, claimId);
  let raw;
  try {
    raw = fs.readFileSync(p, 'utf8');
  } catch {
    return { ok: false, reason: 'claim-file-missing', path: p };
  }
  try {
    return { ok: true, claim: JSON.parse(raw), path: p, raw };
  } catch {
    return { ok: false, reason: 'claim-file-unparseable', path: p };
  }
}

function readLedger(repo, claimId) {
  const p = ledgerPath(repo, claimId);
  if (!fs.existsSync(p)) return [];
  const text = fs.readFileSync(p, 'utf8');
  const records = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      records.push(JSON.parse(trimmed));
    } catch {
      // A hand-corrupted ledger line is not this scorer's concern to fix;
      // skip it rather than crash the whole run on one bad byte.
    }
  }
  return records;
}

function latestPin(records) {
  const pins = records.filter((r) => r.type === 'pin');
  return pins.length ? pins[pins.length - 1] : null;
}
function verdictRecords(records) {
  return records.filter((r) => r.type === 'verdict');
}
function dispositionRecords(records) {
  return records.filter((r) => r.type === 'disposition');
}

// ── D13 bounds check ─────────────────────────────────────────────────────────

function checkBounds(claim) {
  const violations = [];
  const target = claim.target || {};
  const baseline = claim.baseline || {};
  const metric = claim.metric || {};
  const freshness = claim.freshness || {};

  if (!(Number.isFinite(target.minN) && target.minN >= BOUNDS.minN_min)) {
    violations.push('bound1:minN>=3');
  }
  if (
    !(
      Number.isFinite(freshness.maxStalenessDays) &&
      freshness.maxStalenessDays >= BOUNDS.staleness_min &&
      freshness.maxStalenessDays <= BOUNDS.staleness_max
    )
  ) {
    violations.push('bound2:1<=maxStalenessDays<=14');
  }

  const ratifiedAt = parseISODate(claim.ratifiedAt);
  const notScorableBefore = parseISODate(claim.notScorableBefore);
  const targetBy = parseISODate(target.by);

  if (!ratifiedAt || !notScorableBefore) {
    violations.push('bound3:notScorableBefore-out-of-range');
  } else {
    const max3 = addDays(ratifiedAt, BOUNDS.notScorableBefore_maxDaysAfterRatify);
    if (!(notScorableBefore >= ratifiedAt && notScorableBefore <= max3)) {
      violations.push('bound3:notScorableBefore-out-of-range');
    }
  }

  if (!notScorableBefore || !targetBy || !ratifiedAt) {
    violations.push('bound4:target.by-out-of-range');
  } else {
    const max4 = addDays(ratifiedAt, BOUNDS.targetBy_maxDaysAfterRatify);
    if (!(targetBy >= notScorableBefore && targetBy <= max4)) {
      violations.push('bound4:target.by-out-of-range');
    }
  }

  const tv = target.value;
  const bv = baseline.value;
  if (!(Number.isFinite(tv) && Number.isFinite(bv))) {
    violations.push('bound6:target/baseline-not-finite');
  } else if (tv === bv) {
    violations.push('bound6:target/baseline-do-not-differ');
  } else if (metric.direction === 'higher-is-better' && bv >= tv) {
    violations.push('bound5:target-already-satisfied-by-baseline');
  } else if (metric.direction === 'lower-is-better' && bv <= tv) {
    violations.push('bound5:target-already-satisfied-by-baseline');
  } else if (metric.direction !== 'higher-is-better' && metric.direction !== 'lower-is-better') {
    violations.push('bound5:metric.direction-invalid');
  }

  if (!new RegExp(BOUNDS.metricNameRegex).test(metric.name || '')) {
    violations.push('bound7:metric.name-format');
  }
  if (
    !(
      typeof metric.unit === 'string' &&
      metric.unit.length <= BOUNDS.unitMaxLen &&
      new RegExp(BOUNDS.unitCharsRegex).test(metric.unit)
    )
  ) {
    violations.push('bound7:metric.unit-format');
  }

  if (
    !(
      typeof claim.statement === 'string' &&
      claim.statement.length >= BOUNDS.statementMinLen &&
      claim.statement.length <= BOUNDS.statementMaxLen
    )
  ) {
    violations.push('bound8:statement-length');
  }
  if (claim.attribution === 'proxy') {
    if (
      !(
        typeof claim.attributionNote === 'string' &&
        claim.attributionNote.length >= BOUNDS.attributionNoteMinLen &&
        claim.attributionNote.length <= BOUNDS.attributionNoteMaxLen
      )
    ) {
      violations.push('bound8:attributionNote-required-for-proxy');
    }
  }

  const tableRe = new RegExp(BOUNDS.probeTableRegex);
  if (
    !(
      Array.isArray(claim.probeTables) &&
      claim.probeTables.length > 0 &&
      claim.probeTables.every((t) => typeof t === 'string' && tableRe.test(t))
    )
  ) {
    violations.push('bound9:probeTables-empty-or-malformed');
  }

  return violations;
}

// ── D14 closed output allowlist ──────────────────────────────────────────────

const OBSERVATION_KEYS = ['metric', 'value', 'n', 'unit', 'window'];
const WINDOW_KEYS = ['from', 'to'];
const FRESHNESS_KEYS = ['source', 'asOf'];
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function exactKeys(obj, expected) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return false;
  const keys = Object.keys(obj).sort();
  return JSON.stringify(keys) === JSON.stringify([...expected].sort());
}

function withinDateBounds(dateStr, lowBoundDate, highBoundDate) {
  const d = parseISODate(dateStr);
  if (!d) return false;
  return d >= lowBoundDate && d <= highBoundDate;
}

// Returns { ok:true, observation, freshness } or { ok:false, verdict, reason }.
function validateProbeOutput(stdoutText, claim) {
  const lines = stdoutText.split('\n');
  const obsLines = [];
  const freshLines = [];

  for (const line of lines) {
    if (line.startsWith('VALUE-OBSERVATION')) obsLines.push(line);
    else if (line.startsWith('VALUE-FRESHNESS')) freshLines.push(line);
    // everything else is discarded — never recorded, never rendered (D14 #2,
    // and the fix for the markdown/prompt-injection path into the renderer).
  }

  if (obsLines.length === 0 || freshLines.length === 0) {
    return { ok: false, verdict: 'PROBE-BROKEN', reason: 'missing required line type' };
  }
  if (obsLines.length > 1 || freshLines.length > 1) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'duplicate line type' };
  }

  const obsLine = obsLines[0];
  const freshLine = freshLines[0];

  if (Buffer.byteLength(obsLine, 'utf8') > 512 || Buffer.byteLength(freshLine, 'utf8') > 512) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'line exceeds 512 bytes' };
  }

  const obsMatch = obsLine.match(/^VALUE-OBSERVATION\s+(\{.*)$/);
  const freshMatch = freshLine.match(/^VALUE-FRESHNESS\s+(\{.*)$/);
  if (!obsMatch || !freshMatch) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'malformed line prefix' };
  }

  let observation, freshness;
  try {
    observation = JSON.parse(obsMatch[1]);
    freshness = JSON.parse(freshMatch[1]);
  } catch {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'invalid JSON payload' };
  }

  if (!exactKeys(observation, OBSERVATION_KEYS) || !exactKeys(observation.window, WINDOW_KEYS)) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'observation key set not closed' };
  }
  if (!exactKeys(freshness, FRESHNESS_KEYS)) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'freshness key set not closed' };
  }

  const metric = claim.metric || {};
  if (observation.metric !== metric.name) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'metric name mismatch' };
  }
  if (observation.unit !== metric.unit) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'unit mismatch' };
  }
  if (
    typeof observation.value !== 'number' ||
    !Number.isFinite(observation.value) ||
    Math.abs(observation.value) >= 1e12 ||
    !decimalPlacesWithinLimit(observation.value, 6)
  ) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'value out of bounds' };
  }
  if (!Number.isInteger(observation.n) || observation.n < 0 || observation.n > 1e9) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'n out of bounds' };
  }

  const baselineAsOf = parseISODate((claim.baseline || {}).asOf) || todayUTC();
  const lowBound = addDays(baselineAsOf, -3650);
  const highBound = addDays(todayUTC(), 1);

  if (
    !DATE_RE.test(observation.window.from) ||
    !DATE_RE.test(observation.window.to) ||
    !(new Date(observation.window.from) <= new Date(observation.window.to)) ||
    !withinDateBounds(observation.window.from, lowBound, highBound) ||
    !withinDateBounds(observation.window.to, lowBound, highBound)
  ) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'window date invalid or out of bounds' };
  }

  const freshnessCfg = claim.freshness || {};
  if (freshness.source !== freshnessCfg.source) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'freshness source mismatch' };
  }
  if (!DATE_RE.test(freshness.asOf) || !withinDateBounds(freshness.asOf, lowBound, highBound)) {
    return { ok: false, verdict: 'PROBE-OUTPUT-REJECTED', reason: 'freshness asOf invalid or out of bounds' };
  }

  return { ok: true, observation, freshness };
}

function decimalPlacesWithinLimit(value, limit) {
  const s = String(value);
  const dot = s.indexOf('.');
  if (dot === -1) return true;
  return s.length - dot - 1 <= limit;
}

// ── §4 scorer: rules 1-7 (precheck, no probe execution) ─────────────────────

function precheck(repo, claimId) {
  const signals = [];
  let verdict = null;
  const setVerdict = (v) => {
    if (verdict === null) verdict = v;
  };
  const addSignal = (s) => {
    if (!signals.includes(s)) signals.push(s);
  };

  const claimResult = readClaim(repo, claimId);
  const out = {
    claimId,
    runAt: nowISO(),
    claimCoreSha256: null,
    claimMatchesPin: null,
    probeSha256: null,
    probeMatchesPin: null,
    probeRef: null,
    pinPresent: false,
    verdict: null,
    signals: [],
    needProbe: false,
  };

  // rule 1: unparseable, unknown schemaVersion, or any D13 bound violated.
  if (!claimResult.ok) {
    addSignal('CLAIM-INVALID');
    setVerdict('CLAIM-INVALID');
    out.verdict = verdict;
    out.signals = signals;
    return out;
  }

  const claim = claimResult.claim;
  out.claimCoreSha256 = canonHashOfObject(claim);

  const schemaOk = claim.schemaVersion === 2;
  const boundViolations = schemaOk ? checkBounds(claim) : ['schemaVersion-unknown'];
  if (!schemaOk || boundViolations.length > 0) {
    addSignal('CLAIM-INVALID');
    setVerdict('CLAIM-INVALID');
  }

  // rule 1.5 (security remediation, CRITICAL 1 + CRITICAL 2, new terminal
  // states not in the original 13-rule table): claim.probe.path is
  // claim-author-controlled and untrustworthy until proven contained and
  // safe. Evaluated unconditionally (not gated on pin presence) so this
  // fires even on a claim's first, never-pinned score attempt — a
  // malicious probe.path or probe body must never reach the D11 review
  // context or `psql -f`, ratified or not.
  if (claim.probe && typeof claim.probe.path === 'string') {
    const resolved = resolveProbeAbsSafe(repo, claim.probe.path);
    if (!resolved.ok) {
      addSignal('PROBE-PATH-REJECTED');
      setVerdict('PROBE-PATH-REJECTED');
    } else {
      let text = null;
      try {
        text = fs.readFileSync(resolved.abs, 'utf8');
      } catch {
        text = null;
      }
      if (text !== null && probeSafetyViolations(text).length > 0) {
        addSignal('PROBE-REJECTED');
        setVerdict('PROBE-REJECTED');
      }
    }
  }

  const records = readLedger(repo, claimId);
  const pin = latestPin(records);

  // rule 2: no pin, or any review.verdict != ACCEPT, or any review.by ==
  // claim.ratifiedBy (D11, amended §10.1: pin.review is an ARRAY of two
  // independent-family blocks; either can veto).
  const reviews = pin && Array.isArray(pin.review) ? pin.review : null;
  const reviewOk =
    !!pin &&
    !!reviews &&
    reviews.length >= 1 &&
    reviews.every((r) => r && r.verdict === 'ACCEPT') &&
    reviews.every((r) => r && r.by !== claim.ratifiedBy);
  if (!reviewOk) {
    addSignal('NOT-SCORABLE');
    setVerdict('NOT-SCORABLE');
  } else {
    out.pinPresent = true;
  }

  // rule 3: claim lacks ratifiedBy/ratifiedAt/ratifiedCommit, or attribution
  // == unattributable.
  const missingRatifyFields = !claim.ratifiedBy || !claim.ratifiedAt || !claim.ratifiedCommit;
  const unattributable = claim.attribution === 'unattributable';
  if (missingRatifyFields || unattributable) {
    addSignal('NOT-SCORABLE');
    setVerdict('NOT-SCORABLE');
  }

  // rules 4/5/7 need a pin to compare against — absent from signals[] rather
  // than reported as passing when there is none (D16).
  if (pin) {
    out.claimMatchesPin = out.claimCoreSha256 === pin.claimCoreSha256;
    if (!out.claimMatchesPin) {
      addSignal('CLAIM-CHANGED');
      setVerdict('CLAIM-CHANGED');
    }

    const anchorReachable = pin.pinCommit ? gitOk(repo, ['cat-file', '-e', `${pin.pinCommit}^{commit}`]) : false;
    if (!anchorReachable) {
      addSignal('CLAIM-ANCHOR-UNAVAILABLE');
      setVerdict('CLAIM-ANCHOR-UNAVAILABLE');
    }

    // rule 6: today < notScorableBefore. Not a signal (D16's table omits it —
    // it is a legitimate terminal state, not an apparatus fault).
    const nsb = parseISODate(claim.notScorableBefore);
    if (nsb && todayUTC() < nsb) {
      setVerdict('NOT-YET-DUE');
    }

    // rule 7: pinned-probe check fires BEFORE the probe runs (v1's rule,
    // preserved) — cheap (git hash-object), so evaluated regardless of
    // whether rule 6 already decided the verdict.
    if (claim.probe && claim.probe.path) {
      const resolved = resolveProbeAbsSafe(repo, claim.probe.path);
      out.probeSha256 = resolved.ok ? gitHashObject(resolved.abs) : null;
      out.probeRef = { path: claim.probe.path, sha256: out.probeSha256 };
      out.probeMatchesPin = out.probeSha256 !== null && out.probeSha256 === pin.probeSha256;
      if (!out.probeMatchesPin) {
        addSignal('PROBE-CHANGED');
        setVerdict('PROBE-CHANGED');
      }
    }
  }

  out.verdict = verdict;
  out.signals = signals;
  out.needProbe = verdict === null;
  return out;
}

// ── §4 scorer: rules 8-13 (postcheck, after the probe ran) ───────────────────

function postcheck(repo, claimId, exitCode, stdoutFile) {
  const claimResult = readClaim(repo, claimId);
  const records = readLedger(repo, claimId);
  const pin = latestPin(records);

  const out = {
    type: 'verdict',
    claimId,
    runAt: nowISO(),
    claimCoreSha256: null,
    claimMatchesPin: true,
    probeSha256: null,
    probeMatchesPin: true,
    probeRef: null,
    observation: null,
    freshness: null,
    verdict: null,
    signals: [],
    scoredBy: 'deterministic',
    scorerVersion: SCORER_VERSION,
  };

  if (!claimResult.ok) {
    out.verdict = 'CLAIM-INVALID';
    out.signals = ['CLAIM-INVALID'];
    return out;
  }
  const claim = claimResult.claim;
  out.claimCoreSha256 = canonHashOfObject(claim);
  if (claim.probe && claim.probe.path) {
    const resolved = resolveProbeAbsSafe(repo, claim.probe.path);
    out.probeSha256 = resolved.ok ? gitHashObject(resolved.abs) : null;
    out.probeRef = { path: claim.probe.path, sha256: out.probeSha256 };
  }
  if (pin) {
    out.probeMatchesPin = out.probeSha256 !== null && out.probeSha256 === pin.probeSha256;
  }

  let stdoutText = '';
  try {
    stdoutText = fs.readFileSync(stdoutFile, 'utf8');
  } catch {
    stdoutText = '';
  }
  const obsCount = stdoutText.split('\n').filter((l) => l.startsWith('VALUE-OBSERVATION')).length;
  const freshCount = stdoutText.split('\n').filter((l) => l.startsWith('VALUE-FRESHNESS')).length;

  // rule 8
  if (Number(exitCode) !== 0 || obsCount === 0 || freshCount === 0) {
    out.verdict = 'PROBE-BROKEN';
    out.signals = ['PROBE-BROKEN'];
    return out;
  }

  // rule 9 (D14 allowlist)
  const validated = validateProbeOutput(stdoutText, claim);
  if (!validated.ok) {
    out.verdict = validated.verdict;
    out.signals = [validated.verdict];
    return out;
  }

  out.observation = validated.observation;
  const ageDays = ageDaysFrom(validated.freshness.asOf);
  out.freshness = { ...validated.freshness, ageDays };

  // rule 10
  const maxStaleness = (claim.freshness || {}).maxStalenessDays;
  if (ageDays === null || ageDays > maxStaleness) {
    out.verdict = 'STALE-SOURCE';
    out.signals = ['STALE-SOURCE'];
    return out;
  }

  // rule 11
  const minN = (claim.target || {}).minN;
  if (out.observation.n < minN) {
    out.verdict = 'INSUFFICIENT-DATA';
    out.signals = ['INSUFFICIENT-DATA'];
    return out;
  }

  // rules 12/13 — not added to signals[] (they ARE the verdict, D16).
  const direction = (claim.metric || {}).direction;
  const met =
    direction === 'higher-is-better'
      ? out.observation.value >= claim.target.value
      : out.observation.value <= claim.target.value;
  out.verdict = met ? 'PASS' : 'MISS';
  return out;
}

// ── repo-level anomaly scan (§5.2) — degrades gracefully with < 2 claims and
// no ratified inventory, both true for Phase 1's single-claim state. ────────

function anomalyScan(repo) {
  const anomalies = [];
  const claimIds = listClaimIds(repo);

  const claims = claimIds
    .map((id) => ({ id, ...readClaim(repo, id) }))
    .filter((c) => c.ok)
    .map((c) => ({ id: c.id, claim: c.claim }));

  // CLAIM-ORPHANED: a ledger file with a pin but no corresponding claim file.
  const metaDir = path.join(repo, 'docs', 'value', '.meta');
  if (fs.existsSync(metaDir)) {
    for (const f of fs.readdirSync(metaDir)) {
      if (!f.endsWith('.verdicts.jsonl')) continue;
      const id = f.slice(0, -'.verdicts.jsonl'.length);
      if (id === 'inventory') continue;
      if (!isSafeClaimId(id)) continue; // HIGH 5: unsafe-shaped filename, skip rather than throw
      if (!fs.existsSync(claimPath(repo, id))) {
        const records = readLedger(repo, id);
        if (latestPin(records)) anomalies.push({ signal: 'CLAIM-ORPHANED', claimId: id });
      }
    }
  }

  const liveByFeature = new Map();
  const supersededIds = new Set(claims.map((c) => c.claim.supersedes).filter(Boolean));
  for (const { id, claim } of claims) {
    if (supersededIds.has(id)) continue; // not live
    const feature = String(claim.feature || '').toLowerCase().trim().replace(/\s+/g, ' ');
    if (!feature) continue;
    if (liveByFeature.has(feature) && !claim.supersedes) {
      anomalies.push({ signal: 'CLAIM-DUPLICATE-FEATURE', claimId: id, feature });
    } else {
      liveByFeature.set(feature, id);
    }
  }

  // WEAKENED-TARGET: a superseding claim whose target.value is easier than
  // its predecessor's in the stated direction.
  for (const { id, claim } of claims) {
    if (!claim.supersedes) continue;
    const predResult = readClaim(repo, claim.supersedes);
    if (!predResult.ok) continue;
    const pred = predResult.claim;
    const dir = (claim.metric || {}).direction;
    const curT = (claim.target || {}).value;
    const predT = (pred.target || {}).value;
    if (!Number.isFinite(curT) || !Number.isFinite(predT)) continue;
    const weakened =
      (dir === 'higher-is-better' && curT < predT) || (dir === 'lower-is-better' && curT > predT);
    if (weakened) anomalies.push({ signal: 'WEAKENED-TARGET', claimId: id, supersedes: claim.supersedes });
  }

  // ATTRIBUTION-ANOMALY: population-guarded threshold (D5), or any revision
  // into unattributable — the latter needs supersession-chain attribution
  // history, which Phase 1 (one claim, no revisions) never exercises; the
  // population guard is checked below regardless of claim count.
  const liveClaims = claims.filter((c) => !supersededIds.has(c.id));
  const unattributableLive = liveClaims.filter((c) => c.claim.attribution === 'unattributable');
  if (liveClaims.length >= 5 && unattributableLive.length > liveClaims.length / 3) {
    anomalies.push({ signal: 'ATTRIBUTION-ANOMALY', reason: 'population-guarded threshold' });
  }

  // INVENTORY-CHANGED / FEATURE-NOT-IN-INVENTORY: Phase 1 has no ratified
  // inventory (D3) — skip when absent rather than fail (advisor guidance).
  const inventoryPath = path.join(repo, 'docs', 'value', 'inventory.json');
  if (fs.existsSync(inventoryPath)) {
    // Not reachable in Phase 1 (no ratify-inventory verb); left as a no-op
    // scaffold so Phase 2 can fill it in without re-touching this function's
    // shape.
  }

  return anomalies;
}

// ── disposition-required tracking (D8) ───────────────────────────────────────

function disposeState(records) {
  const events = [
    ...verdictRecords(records).map((r) => ({ ts: r.runAt, type: 'verdict', record: r })),
    ...dispositionRecords(records).map((r) => ({ ts: r.recordedAt, type: 'disposition', record: r })),
  ].sort((a, b) => new Date(a.ts) - new Date(b.ts));

  let requiresDisposition = false;
  let firstUndisposedMissAt = null;
  for (const ev of events) {
    if (ev.type === 'verdict') {
      if (ev.record.verdict === 'MISS' && !requiresDisposition) {
        requiresDisposition = true;
        firstUndisposedMissAt = ev.record.runAt;
      }
      // A later PASS never auto-clears (D8, deliberately).
    } else if (ev.type === 'disposition' && requiresDisposition) {
      requiresDisposition = false;
      firstUndisposedMissAt = null;
    }
  }
  return { requiresDisposition, firstUndisposedMissAt };
}

// ── render (§1.2 + §5.4) ──────────────────────────────────────────────────────

function escapeClaimString(s) {
  if (typeof s !== 'string') return '';
  let out = s.length > 600 ? `${s.slice(0, 600)}…` : s;
  out = out.replace(/[`|<]/g, '\\$&').replace(/^(#+|-)/gm, '\\$1');
  return out;
}

// Shared by render's per-claim block AND `report`'s text/json output (D8's
// "undisposed-MISS is a property of the claim, not of a run" rule must read
// identically on both surfaces \u2014 a maintainer reading `--report` and the CEO
// reading ROLLUP.md must see the same state in the same words).
function claimStatusLabel(records) {
  const verdicts = verdictRecords(records);
  const latest = verdicts.length ? verdicts[verdicts.length - 1] : null;
  const { requiresDisposition, firstUndisposedMissAt } = disposeState(records);

  let label;
  if (!latest) {
    label = 'NOT-SCORABLE';
  } else if (requiresDisposition && latest.verdict !== 'MISS') {
    label = `MISS \u2192 ${latest.verdict}, disposition still required`;
  } else if (requiresDisposition) {
    const age = firstUndisposedMissAt
      ? Math.max(0, Math.floor((Date.now() - new Date(firstUndisposedMissAt).getTime()) / 86400000))
      : 0;
    label = `MISS (undisposed, ${age}d)`;
  } else {
    label = latest.verdict;
  }
  return { label, latest, requiresDisposition, firstUndisposedMissAt };
}

function buildClaimBlock(repo, claimId) {
  const claimResult = readClaim(repo, claimId);
  if (!claimResult.ok) return null;
  const claim = claimResult.claim;
  const records = readLedger(repo, claimId);
  const pin = latestPin(records);
  const { label, latest, requiresDisposition } = claimStatusLabel(records);

  const lines = [];
  lines.push(`### ${label} — ${escapeClaimString(claim.feature)}`);
  lines.push(escapeClaimString(claim.statement));
  if (latest && latest.observation) {
    const t = claim.target || {};
    const dirWord = (claim.metric || {}).direction === 'lower-is-better' ? '\u2264' : '\u2265';
    lines.push(
      `  ${escapeClaimString(claim.metric.name)} \u2014 target ${dirWord} ${t.value} by ${t.by}, observed **${latest.observation.value}**`,
    );
    lines.push(
      `  measured ${latest.observation.window.from} \u2192 ${latest.observation.window.to} (n=${latest.observation.n}, minN=${t.minN}) \u00b7 source ${escapeClaimString(claim.freshness.source)}, ${latest.freshness ? latest.freshness.ageDays : '?'}d old`,
    );
  }
  const attributionParts = [claim.attribution];
  if (claim.attribution === 'proxy' && claim.attributionNote) {
    attributionParts.push(`\u2014 ${escapeClaimString(claim.attributionNote)}`);
  }
  const reviewers = pin && Array.isArray(pin.review) ? pin.review.map((r) => r.by).join(', ') : 'none';
  const probeShort = pin && pin.probeSha256 ? pin.probeSha256.slice(0, 8) : 'unpinned';
  attributionParts.push(`\u00b7 claim ${claim.claimId} \u00b7 probe @${probeShort} \u00b7 reviewed by ${reviewers}`);
  lines.push(`  ${attributionParts.join(' ')}`);
  if (requiresDisposition) {
    lines.push('  disposition required: keep-and-revise | fix | retire');
  }
  return lines.join('\n');
}

function renderBody(repo) {
  const repoName = path.basename(repo);
  const claimIds = listClaimIds(repo);

  const supersededIds = new Set(
    claimIds
      .map((id) => readClaim(repo, id))
      .filter((c) => c.ok)
      .map((c) => c.claim.supersedes)
      .filter(Boolean),
  );
  const liveIds = claimIds.filter((id) => !supersededIds.has(id));

  let totalVerdicts = 0;
  for (const id of claimIds) totalVerdicts += verdictRecords(readLedger(repo, id)).length;

  const inventoryPath = path.join(repo, 'docs', 'value', 'inventory.json');
  const coverageLine = fs.existsSync(inventoryPath)
    ? 'coverage: NOT-ESTABLISHED (inventory present but ratify-inventory not run in Phase 1)'
    : 'coverage: NOT-ESTABLISHED (no ratified feature inventory)';

  // Deterministic "generated" so two consecutive renders of the same ledger
  // state are byte-identical (exit test 15) — no wall-clock in the body.
  let newest = null;
  for (const id of claimIds) {
    for (const v of verdictRecords(readLedger(repo, id))) {
      if (!newest || new Date(v.runAt) > new Date(newest)) newest = v.runAt;
    }
  }
  const generatedAt = newest || 'never';

  const lines = [];
  lines.push(`## ${repoName}`);
  lines.push(coverageLine);
  lines.push(
    `generated ${generatedAt} from ${liveIds.length} claim${liveIds.length === 1 ? '' : 's'} / ${totalVerdicts} verdict${totalVerdicts === 1 ? '' : 's'}`,
  );
  lines.push('');
  for (const id of liveIds) {
    const block = buildClaimBlock(repo, id);
    if (block) {
      lines.push(block);
      lines.push('');
    }
  }
  return lines.join('\n').replace(/\n+$/, '\n');
}

// D12/D14's provenance rule made mechanical: the body is generated bytes;
// bodySha256 is a hash of that body EXCLUDING the line that carries the hash
// itself (otherwise the hash would be self-referential). HAND-EDITED is
// detected by re-hashing the ON-DISK body against its OWN embedded hash — a
// self-consistency check that needs no external "did the ledger change"
// state (see advisor note, resolved 2026-07-31).
function renderFull(repo) {
  const body = renderBody(repo);
  const lines = body.split('\n');
  const genLineIdx = lines.findIndex((l) => l.startsWith('generated '));
  const bodyHash = sha256hex(body);
  if (genLineIdx !== -1) {
    lines[genLineIdx] = `${lines[genLineIdx]} \u00b7 bodySha256 ${bodyHash}`;
  }
  return { full: lines.join('\n'), bodySha256: bodyHash, body };
}

function checkHandEdited(existingFull) {
  // NOTE: trailing `$` only (no `\s*` before it) -- `\s` matches newlines
  // too, and a greedy `\s*$` here swallowed the blank line separating the
  // generated-line from the first claim block, corrupting the
  // reconstruction and making every UNEDITED render self-report as
  // HAND-EDITED (caught by the fixture self-test, 2026-07-31).
  const match = existingFull.match(/^(generated .*)\u00b7 bodySha256 ([0-9a-f]{64})$/m);
  if (!match) return false; // nothing to compare against — treat as not-yet-rendered
  const embeddedHash = match[2];
  const strippedGenLine = match[1].replace(/\s+$/, '');
  const reconstructed = existingFull.replace(match[0], strippedGenLine);
  const selfHash = sha256hex(reconstructed);
  return selfHash !== embeddedHash;
}

function atomicWrite(filePath, content) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, content, { mode: 0o644 });
  fs.renameSync(tmp, filePath);
}

function doRender(repo, write) {
  const target = rollupPath(repo);
  let handEdited = false;
  if (fs.existsSync(target)) {
    handEdited = checkHandEdited(fs.readFileSync(target, 'utf8'));
  }
  const { full, bodySha256, body } = renderFull(repo);
  if (write) atomicWrite(target, full);
  return { full, bodySha256, body, handEdited, path: target };
}

// ── report / goodmorning Value: line data ────────────────────────────────────

function buildReport(repo) {
  const claimIds = listClaimIds(repo);

  const claimsOut = [];
  let lastRunAt = null;
  for (const id of claimIds) {
    const records = readLedger(repo, id);
    const { label, latest, requiresDisposition, firstUndisposedMissAt } = claimStatusLabel(records);
    if (latest && (!lastRunAt || new Date(latest.runAt) > new Date(lastRunAt))) lastRunAt = latest.runAt;
    claimsOut.push({
      claimId: id,
      verdict: latest ? latest.verdict : null,
      label,
      signals: latest ? latest.signals || [] : [],
      requiresDisposition,
      firstUndisposedMissAt,
    });
  }

  const anomalies = anomalyScan(repo);

  const apparatusStates = new Set([
    'PROBE-BROKEN',
    'PROBE-CHANGED',
    'PROBE-OUTPUT-REJECTED',
    'PROBE-PATH-REJECTED',
    'PROBE-REJECTED',
    'STALE-SOURCE',
    'CLAIM-CHANGED',
    'CLAIM-INVALID',
    'CLAIM-ANCHOR-UNAVAILABLE',
    'NOT-SCORABLE',
  ]);
  const anomalyStates = new Set([
    'ATTRIBUTION-ANOMALY',
    'CLAIM-ORPHANED',
    'CLAIM-DUPLICATE-FEATURE',
    'WEAKENED-TARGET',
    'INVENTORY-CHANGED',
    'FEATURE-NOT-IN-INVENTORY',
    'HAND-EDITED',
  ]);

  const missUndisposed = claimsOut.filter((c) => c.requiresDisposition);
  let oldestMissAgeDays = null;
  for (const c of missUndisposed) {
    if (!c.firstUndisposedMissAt) continue;
    const age = Math.floor((Date.now() - new Date(c.firstUndisposedMissAt).getTime()) / 86400000);
    if (oldestMissAgeDays === null || age > oldestMissAgeDays) oldestMissAgeDays = age;
  }

  const apparatusFaultStates = new Set();
  for (const c of claimsOut) for (const s of c.signals) if (apparatusStates.has(s)) apparatusFaultStates.add(s);
  const anomalyFaultStates = new Set(anomalies.map((a) => a.signal).filter((s) => anomalyStates.has(s)));

  const heartbeatWindowDays = 35;
  const emptyLedger = claimIds.length === 0;
  const staleRun = !lastRunAt || Math.floor((Date.now() - new Date(lastRunAt).getTime()) / 86400000) > heartbeatWindowDays;

  return {
    lastRunAt,
    claims: claimsOut,
    anomalies,
    counts: {
      missUndisposed: missUndisposed.length,
      oldestMissAgeDays,
      apparatusFaultStates: [...apparatusFaultStates],
      anomalyFaultStates: [...anomalyFaultStates],
    },
    heartbeat: {
      emptyLedger,
      staleRun,
      windowDays: heartbeatWindowDays,
    },
  };
}

// ── CLI dispatch ──────────────────────────────────────────────────────────────

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

function main() {
  const [, , cmd, ...rest] = process.argv;

  if (cmd === 'bounds') {
    console.log(JSON.stringify(BOUNDS, null, 2));
    return;
  }

  if (cmd === 'canon-hash') {
    const file = rest[0];
    const raw = fs.readFileSync(file, 'utf8');
    console.log(canonHashOfObject(JSON.parse(raw)));
    return;
  }

  if (cmd === 'check-bounds') {
    const file = rest[0];
    const raw = fs.readFileSync(file, 'utf8');
    const claim = JSON.parse(raw);
    const violations = claim.schemaVersion === 2 ? checkBounds(claim) : ['schemaVersion-unknown'];
    console.log(JSON.stringify({ ok: violations.length === 0, violations }, null, 2));
    process.exitCode = violations.length === 0 ? 0 : 1;
    return;
  }

  // CRITICAL 2: the one implementation of probe.path containment, called by
  // the bash gate at ratify/score/revise instead of each independently
  // re-deriving `$REPO/$probe_rel` (the drift the original finding named).
  // Prints the resolved absolute path on success (exit 0); prints nothing
  // and exits 1 if probe.path is missing, unsafe, or escapes
  // docs/value/probes/.
  if (cmd === 'resolve-probe-path') {
    const flags = parseFlags(rest);
    const resolved = resolveProbeAbsSafe(flags.repo, flags['probe-rel']);
    if (!resolved.ok) {
      process.exitCode = 1;
      return;
    }
    console.log(resolved.abs);
    return;
  }

  // CRITICAL 1: re-usable from bash as a standalone gate immediately before
  // `psql -f` (belt-and-suspenders alongside precheck's rule 1.5, which
  // already covers the same check earlier in the `score` pipeline). Exit 0
  // and prints "ok" if the file has no bare-backslash line outside a
  // string/comment/dollar-quote; exit 1 and lists each offending line to
  // stderr otherwise.
  if (cmd === 'check-probe-safety') {
    const flags = parseFlags(rest);
    let text;
    try {
      text = fs.readFileSync(flags.file, 'utf8');
    } catch {
      console.error('check-probe-safety: file not found or unreadable');
      process.exitCode = 1;
      return;
    }
    const violations = probeSafetyViolations(text);
    if (violations.length > 0) {
      for (const v of violations) {
        console.error(`check-probe-safety: line ${v.line}: psql meta-command / bare backslash outside a string or comment: ${v.content}`);
      }
      process.exitCode = 1;
      return;
    }
    console.log('ok');
    return;
  }

  if (cmd === 'precheck') {
    const flags = parseFlags(rest);
    console.log(JSON.stringify(precheck(flags.repo, flags.claim)));
    return;
  }

  if (cmd === 'postcheck') {
    const flags = parseFlags(rest);
    console.log(JSON.stringify(postcheck(flags.repo, flags.claim, flags['exit-code'], flags['stdout-file'])));
    return;
  }

  if (cmd === 'anomaly-scan') {
    const flags = parseFlags(rest);
    console.log(JSON.stringify(anomalyScan(flags.repo), null, 2));
    return;
  }

  if (cmd === 'render') {
    const flags = parseFlags(rest);
    const result = doRender(flags.repo, !!flags.write);
    if (flags.write) {
      console.log(JSON.stringify({ path: result.path, bodySha256: result.bodySha256, handEdited: result.handEdited }));
    } else {
      console.log(result.full);
    }
    return;
  }

  if (cmd === 'report') {
    const flags = parseFlags(rest);
    const report = buildReport(flags.repo);
    if (flags.json) {
      console.log(JSON.stringify(report, null, 2));
      return;
    }
    console.log(`docs/value/ report — repo ${flags.repo}`);
    console.log(`last scored run: ${report.lastRunAt || 'never'}`);
    for (const c of report.claims) {
      console.log(`  ${c.claimId}: ${c.label || 'never scored'}`);
      if (c.signals.length) console.log(`    signals: ${c.signals.join(', ')}`);
    }
    if (report.anomalies.length) {
      console.log('  anomalies:');
      for (const a of report.anomalies) console.log(`    ${a.signal} ${JSON.stringify(a)}`);
    }
    return;
  }

  console.error(`score.mjs: unknown subcommand '${cmd}'`);
  console.error('usage: score.mjs <bounds|canon-hash|check-bounds|precheck|postcheck|anomaly-scan|render|report> ...');
  process.exitCode = 2;
}

main();
