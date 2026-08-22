import { DatabaseSync } from "node:sqlite";
import { createHash } from "node:crypto";
import { renameSync } from "node:fs";
import { validateEventId } from "./db.mjs";

// ADR-060 §6 (Q4 -- migration path) + the Migration amendment ("§E:
// deterministic legacy-id canonicalization"). One-shot import of a P1a
// SQLite journal into the Postgres knowledge store. `pm migrate` in
// cli.mjs is the only caller; every function here is pure or filesystem-
// local and none opens a network connection.

const MIGRATE_PRODUCER = "stack@p1a";

// The dashed-text positions the write-boundary CHECK in
// schemas/006-knowledge-store.sql inspects (position 15 = version nibble,
// position 20 = variant nibble) -- mirrored here so a row already carrying
// a valid v7 id is recognized WITHOUT calling validateEventId's timestamp
// window (import rows are historic by definition; format/version/variant
// is all that matters for the pass-through decision).
const V7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isValidV7(id) {
  return typeof id === "string" && V7_RE.test(id);
}

// legacyEventIdToV7(row) -> uuid
//
// Deterministic, NEVER calls uuidv7()/the random generator: the 48-bit v7
// timestamp field comes from Date.parse(row.ts); every remaining
// random-field bit comes from the leading bits of SHA-256(row.event_id) --
// the row's stable identity, since P1a ids are UUIDv4 (random, not
// derivable from anything else). Same (event_id, ts) pair -> same output,
// every run, forever, on any machine -- that's what lets `ON CONFLICT
// (event_id) DO NOTHING` actually de-dupe a re-run instead of minting a
// fresh id each time (the review BLOCKER this amendment closes).
//
// A row already carrying a valid v7 id passes through UNCHANGED (§E's
// "ids are never rewritten," which the amendment narrows to exactly this
// one-shot exception and then closes again for everything else).
//
// Review fix (Important #2): the constructed id is validated
// (validateEventId(id, {allowHistoric:true})) before it is ever returned
// -- NOT assumed correct by construction. A pre-1970 `ts` is the
// reachable counter-example: Date.parse yields a negative ms value,
// (-N).toString(16) emits a leading '-' into what should be a 12-hex-digit
// timestamp field, and the result silently fails to be a well-formed
// UUID at all. validateEventId throws on that; the caller
// (buildIdMapAndMalformed) already catches and reports it as a malformed
// row, which is exactly §E's "reported in the dry-run counts" requirement
// -- this is what implements that, not a separate check.
export function legacyEventIdToV7(row) {
  if (isValidV7(row.event_id)) {
    validateEventId(row.event_id, { allowHistoric: true });
    return row.event_id;
  }

  const tsMs = Date.parse(row.ts);
  if (!Number.isFinite(tsMs)) {
    throw new Error(`legacyEventIdToV7: unparsable ts "${row.ts}" for event ${row.event_id}`);
  }

  const hash = createHash("sha256").update(String(row.event_id)).digest();
  const tsHex = Math.trunc(tsMs).toString(16).padStart(12, "0").slice(-12);

  // rand_a: 12 bits from the hash's leading 16 bits.
  const randAValue = hash.readUInt16BE(0) & 0x0fff;
  const randAHex = randAValue.toString(16).padStart(3, "0");

  // rand_b (62 bits, the remaining 2 forced into the variant nibble):
  // the next 8 hash bytes.
  const tail = Buffer.from(hash.subarray(2, 10));
  tail[0] = (tail[0] & 0x3f) | 0x80; // variant nibble forced into {8,9,a,b}
  const tailHex = tail.toString("hex");

  const id = [
    tsHex.slice(0, 8),
    tsHex.slice(8, 12),
    `7${randAHex}`,
    tailHex.slice(0, 4),
    tailHex.slice(4, 16)
  ].join("-");

  validateEventId(id, { allowHistoric: true });
  return id;
}

// §6's per-type subject_kind table (interview_answer -> user; anything not
// listed is ambiguous and falls to 'system', counted in the report). Not
// imported from journal-pg.mjs: that file's table also carries 'decision'
// (PG-only, REQ-147), which a P1a source row can never contain, and this
// file owns its own copy deliberately so the two tables can diverge
// without one migration changing the other's live-write behavior.
const TYPE_TO_SUBJECT_KIND = {
  override: "agent",
  challenge: "agent",
  audit_verdict: "agent",
  matrix_change: "agent",
  priority_call: "track",
  interview_answer: "user",
  handoff: "system"
};

export function subjectKindFor(type) {
  if (Object.prototype.hasOwnProperty.call(TYPE_TO_SUBJECT_KIND, type)) {
    return { kind: TYPE_TO_SUBJECT_KIND[type], ambiguous: false };
  }
  return { kind: "system", ambiguous: true };
}

// openSourceDb(path) -> { rows(): row[], close(): void }
//
// Reads the P1a events table directly (readOnly connection) -- NOT via
// journal.mjs's openJournal().events(), which is portfolio-scoped and
// cannot answer "every row, every portfolio" the way a migration needs to.
export function openSourceDb(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  return {
    rows() {
      return db
        .prepare("SELECT * FROM events ORDER BY ts, event_id")
        .all()
        .map((raw) => ({ ...raw, body: raw.body ? JSON.parse(raw.body) : null }));
    },
    close() {
      db.close();
    }
  };
}

function countByTypePortfolio(items) {
  const counts = {};
  for (const item of items) {
    const key = `${item.type}|${item.portfolio}`;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

function countsEqual(a, b) {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const key of keys) {
    if ((a[key] ?? 0) !== (b[key] ?? 0)) return false;
  }
  return true;
}

// ADR-060 addendum §A / the Task 5 convention journal-pg.mjs already
// follows: stack.events has RLS FORCEd, fail-closed on the
// transaction-local `stack.portfolio` GUC. EVERY statement that touches
// stack.events -- insert or read -- must ride inside the SAME
// transport.tx call as a preceding `select stack.set_portfolio($1)`, or
// it sees/writes zero rows (fail-closed) rather than an error, which is
// exactly how this shipped broken: the live Task 7 checkpoint's real
// Postgres (real RLS) rejected the very first insert with "new row
// violates row-level security policy for table events" -- the fake
// transport in migrate.test.mjs enforced the FK but not RLS context, so
// the unit suite stayed green while the live path was dead on arrival.
// Literal string matches journal-pg.mjs's SET_PORTFOLIO_SQL exactly
// (untagged, like that file's) -- there is only one correct way to spell
// this call, and a second spelling would just be drift.
const SET_PORTFOLIO_SQL = "select stack.set_portfolio($1)";

// The tag comment is the same fake-transport hook journal-pg.test.mjs
// uses for journal-pg.mjs's SQL -- this file's own tag namespace
// ("migrate:") so a fake transport can tell the two apart without parsing
// real SQL.
const INSERT_MIGRATED_EVENT_SQL = `-- migrate:insert-event
insert into stack.events
  (event_id, portfolio, user_id, schema_version, ts, ingested_at, type,
   subject_kind, subject_id, author, producer, ref_event_id, body)
values
  ($1::uuid, $2, $3::uuid, $4, $5::timestamptz, $6::timestamptz, $7,
   $8, $9, $10, $11, $12::uuid, $13::jsonb)
on conflict (event_id) do nothing
returning event_id`;

// Scoped to producer = $1 (always MIGRATE_PRODUCER) so parity counts only
// the rows THIS migration wrote, not live stack@p1b traffic landing in the
// same destination table between dry-run and live-run, or between re-runs.
// Also RLS-scoped like the insert above: under a given `set_portfolio`
// context this can only ever see that one portfolio's rows, so the
// `group by portfolio` here is a same-portfolio no-op per call -- kept
// anyway so a single call's result rows are still self-labeled by
// portfolio, and callers issue one call per source portfolio (see
// destCountsByPortfolio below), merging into the same type|portfolio-keyed
// map DEST_COUNTS_SQL used to produce in one shot before RLS made that
// impossible.
const DEST_COUNTS_SQL = `-- migrate:dest-counts
select type, portfolio, count(*)::int as count
from stack.events
where producer = $1
group by type, portfolio`;

// Read-only pre-flight (§6 review finding #4): when a transport IS
// available at dry-run time, check the destination has what a live run
// will need -- the source's distinct portfolios in
// stack.portfolio_settings, and (if --user-id was given) that user row in
// stack.users. Never fatal to the dry run itself; just reported. `bin.mjs`
// doesn't wire a transport for `pm migrate` yet, so the common case today
// is `transport` absent -- that's `ran: false`, not an error.
const PREFLIGHT_PORTFOLIOS_SQL = `-- migrate:preflight-portfolios
select portfolio from stack.portfolio_settings where portfolio = any($1::text[])`;

const PREFLIGHT_USER_SQL = `-- migrate:preflight-user
select 1 from stack.users where id = $1::uuid`;

async function runPreflight(transport, portfolios, userId) {
  if (!transport) {
    return { ran: false, skippedReason: "no transport supplied", missingPortfolios: [], userIdChecked: false, userIdExists: null };
  }

  // Review fix (round 2, Important): this whole function is documented
  // "read-only, never fatal to the dry run" -- but a bare await propagated
  // any transport error straight out of importEvents, turning a dry run
  // into a reported "import failed", exit 1, for a run that wrote
  // NOTHING. Most reachable case: a typo'd --user-id failing
  // PREFLIGHT_USER_SQL's $1::uuid cast; a network blip is the other. The
  // pre-flight is a nice-to-have diagnostic, not part of the dry run's
  // actual contract -- any failure here degrades to "skipped, with the
  // reason," never to a thrown error.
  try {
    const result = { ran: true, skippedReason: null, missingPortfolios: [], userIdChecked: false, userIdExists: null };

    if (portfolios.length > 0) {
      const portfolioResult = await transport.tx([{ sql: PREFLIGHT_PORTFOLIOS_SQL, params: [portfolios] }]);
      const existing = new Set((portfolioResult[0] ?? []).map((r) => r.portfolio));
      result.missingPortfolios = portfolios.filter((p) => !existing.has(p));
    }

    if (userId) {
      result.userIdChecked = true;
      const userResult = await transport.tx([{ sql: PREFLIGHT_USER_SQL, params: [userId] }]);
      result.userIdExists = (userResult[0] ?? []).length > 0;
    }

    return result;
  } catch (err) {
    return { ran: false, skippedReason: err.message, missingPortfolios: [], userIdChecked: false, userIdExists: null };
  }
}

function insertParamsFor(e) {
  return [
    e.event_id, e.portfolio, e.user_id, e.schema_version, e.ts, e.ingested_at, e.type,
    e.subject_kind, e.subject_id, e.author, e.producer, e.ref_event_id,
    e.body ? JSON.stringify(e.body) : null
  ];
}

function buildIdMapAndMalformed(rows) {
  const idMap = new Map();
  const malformed = [];
  for (const row of rows) {
    try {
      idMap.set(row.event_id, legacyEventIdToV7(row));
    } catch (err) {
      malformed.push({ event_id: row.event_id, reason: err.message });
    }
  }
  return { idMap, malformed };
}

// Review finding #3: source order (ts, event_id) does NOT guarantee a
// ref-carrying row (e.g. an outcome) sorts after its target (e.g. the
// call it resolves) -- a forward-dated target row or a same-millisecond
// v4 tie can put them either way, and the destination's
// events_ref_same_portfolio FK requires the target to already exist.
// Depth-first topological order: visit a row's ref target before the row
// itself, `visited` marked on entry so a (data-model-impossible, but not
// worth crashing on) ref cycle terminates instead of recursing forever.
function orderForInsert(events) {
  const byId = new Map(events.map((e) => [e.event_id, e]));
  const visited = new Set();
  const ordered = [];

  function visit(e) {
    if (visited.has(e.event_id)) return;
    visited.add(e.event_id);
    if (e.ref_event_id && byId.has(e.ref_event_id)) {
      visit(byId.get(e.ref_event_id));
    }
    ordered.push(e);
  }

  for (const e of events) visit(e);
  return ordered;
}

// importEvents(sourceDb, transport, {dryRun, userId}) -> report
//
// Pure: no filesystem mutation (sourceDb is already open; nothing here
// renames or deletes anything -- that's finalizeMigration's job, called
// separately by the CLI, strictly after a parity PASS).
//
// Idempotent: re-running against the same source produces the same
// idMap (legacyEventIdToV7 is deterministic) and inserts 0 new rows the
// second time (ON CONFLICT (event_id) DO NOTHING), because the id is
// identical both times -- never re-derived from a fresh id map.
export async function importEvents(sourceDb, transport, { dryRun = false, userId } = {}) {
  const rows = sourceDb.rows();
  // Pass 1: build the full old-id -> new-id map before touching ref_event_id
  // remapping in pass 2 -- a ref can point to a row appearing later in this
  // same array, so the map must be complete first.
  const { idMap, malformed } = buildIdMapAndMalformed(rows);

  const events = [];
  let remapCount = 0;
  let passthroughCount = 0;
  let ambiguousSubjectKind = 0;

  for (const row of rows) {
    const newId = idMap.get(row.event_id);
    if (newId === undefined) continue; // malformed, already recorded

    // Review finding #1: a ref target that isn't in the id map (because
    // it was itself malformed, or genuinely doesn't exist in this source)
    // must never fall back to the OLD id -- that id is a v4 shape the
    // destination's write-boundary CHECK rejects outright, and letting it
    // through used to abort the whole import mid-transaction the moment
    // the composite self-FK (events_ref_same_portfolio) hit it. Report
    // and skip this row instead; every OTHER row still imports.
    //
    // Deferred (reviewer minor, round 2, non-transitive by design): this
    // skip does NOT propagate transitively. `idMap` (pass 1) only records
    // whether a row's OWN (event_id, ts) produced a valid id -- it has no
    // knowledge of ref resolvability, which is only checked here in pass
    // 2. So if row B's OWN ts/id is fine but B is skipped here because
    // ITS ref is unresolvable, idMap.get(B.event_id) still returns a
    // value, and a hypothetical row C with ref_event_id = B.event_id
    // would resolve against that value even though B was never inserted
    // -- an orphaned ref, not caught as "unresolvable" itself. Not fixed:
    // P1a's real write API (journal.mjs) only ever sets ref_event_id on
    // `outcome` events, and nothing in that API ever sets a ref pointing
    // at an outcome -- so a depth-2 ref chain (C -> B -> A) cannot be
    // produced by any real P1a journal, only by a hand-crafted fixture.
    let refEventId = null;
    if (row.ref_event_id) {
      const mapped = idMap.get(row.ref_event_id);
      if (mapped === undefined) {
        malformed.push({ event_id: row.event_id, reason: `unresolvable ref: ${row.ref_event_id}` });
        continue;
      }
      refEventId = mapped;
    }

    if (newId === row.event_id) passthroughCount += 1;
    else remapCount += 1;

    const { kind, ambiguous } = subjectKindFor(row.type);
    if (ambiguous) ambiguousSubjectKind += 1;

    events.push({
      event_id: newId,
      portfolio: row.portfolio,
      user_id: userId ?? null,
      schema_version: row.schema_version,
      ts: row.ts,
      ingested_at: row.ts,
      type: row.type,
      subject_kind: kind,
      subject_id: row.subject,
      author: row.author,
      producer: MIGRATE_PRODUCER,
      ref_event_id: refEventId,
      body: { ...(row.body ?? {}), _p1a_event_id: row.event_id }
    });
  }

  const byTypePortfolio = countByTypePortfolio(events);

  const report = {
    dryRun,
    totalRows: rows.length,
    remapCount,
    passthroughCount,
    ambiguousSubjectKind,
    malformed,
    byTypePortfolio,
    idMap: Object.fromEntries(idMap),
    insertedCount: 0,
    destCounts: null,
    parityOk: dryRun ? null : false,
    preflight: null
  };

  if (dryRun) {
    // Read-only, never fatal to the dry run -- see runPreflight's comment.
    const portfolios = [...new Set(events.map((e) => e.portfolio))];
    report.preflight = await runPreflight(transport, portfolios, userId);
    return report;
  }

  if (!userId) {
    throw new Error("importEvents: userId is required for a live (non-dry-run) import");
  }

  // Live evidence fix (Task 7 checkpoint): each insert now rides in the
  // SAME tx call as its own row's set_portfolio -- see SET_PORTFOLIO_SQL's
  // comment above. Two statements, one tx, per event; result index shifts
  // to 1 (index 0 is the set_portfolio call's own result).
  let insertedCount = 0;
  for (const e of orderForInsert(events)) {
    const result = await transport.tx([
      { sql: SET_PORTFOLIO_SQL, params: [e.portfolio] },
      { sql: INSERT_MIGRATED_EVENT_SQL, params: insertParamsFor(e) }
    ]);
    insertedCount += (result[1] ?? []).length;
  }
  report.insertedCount = insertedCount;

  const destCounts = await destCountsByPortfolio(transport, [...new Set(events.map((e) => e.portfolio))]);
  report.destCounts = destCounts;
  report.parityOk = countsEqual(byTypePortfolio, destCounts);

  return report;
}

// Reads are RLS-scoped exactly like writes: one tx (set_portfolio, then
// DEST_COUNTS_SQL) PER source portfolio, merged into the same
// type|portfolio-keyed map a single unscoped query used to produce before
// RLS made that one-shot form impossible.
async function destCountsByPortfolio(transport, portfolios) {
  const destCounts = {};
  for (const portfolio of portfolios) {
    const result = await transport.tx([
      { sql: SET_PORTFOLIO_SQL, params: [portfolio] },
      { sql: DEST_COUNTS_SQL, params: [MIGRATE_PRODUCER] }
    ]);
    for (const r of result[1] ?? []) {
      destCounts[`${r.type}|${r.portfolio}`] = Number(r.count);
    }
  }
  return destCounts;
}

// finalizeMigration(sourcePath) -> string (the new path)
//
// CLI-only, invoked strictly after a parity PASS. Renames the source file
// to `<path>.migrated` -- never deletes it (the 30-day retention window is
// the rollback plan, §6, and must not be shortened by this function).
export function finalizeMigration(sourcePath) {
  if (sourcePath.endsWith(".migrated")) {
    throw new Error(`finalizeMigration: source already finalized: ${sourcePath}`);
  }

  // journal.mjs's openJournal always opens WAL mode, which keeps recently
  // committed rows in a `<path>-wal` sidecar until checkpointed. Renaming
  // only the main file would strand that sidecar under the OLD name --
  // any later open of `<path>.migrated` (a CLI re-run, an audit, this
  // task's own idempotency test) would see stale/incomplete data despite
  // every write having genuinely committed. Checkpoint-and-truncate folds
  // the WAL into the main file and empties the sidecar BEFORE the rename,
  // so the renamed file is fully self-contained.
  const db = new DatabaseSync(sourcePath);
  db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  db.close();

  const target = `${sourcePath}.migrated`;
  renameSync(sourcePath, target);
  return target;
}

export function isFinalizedPath(path) {
  return path.endsWith(".migrated");
}
