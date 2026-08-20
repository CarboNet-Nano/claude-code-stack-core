import { uuidv7, validateEventId } from "./db.mjs";
import { redactSecretsAndPaths } from "./journal.mjs";
import { appendToOutbox, drainOutbox, readOutbox, unsentCount as outboxUnsentCount } from "./outbox.mjs";

// ADR-060 §4/§5/§6 + Revision addendum §A/§D/§E. Interface-compatible with
// P1a's tools/pm/src/journal.mjs (same method names, same behaviors) --
// verified by a name+behavior parity test, not arity (JS default params
// make .length lie; see attachOutcome/sweepRetention below for the two
// places this engine's arity legitimately differs).

const SET_PORTFOLIO_SQL = "select stack.set_portfolio($1)";

// schemas/006-knowledge-store.sql's `type` CHECK list, verbatim -- NOT
// P1a's VALID_TYPES (tools/pm/src/journal.mjs), which is missing
// 'decision' (ADR-060 §6, REQ-147, PG-only). Checked client-side before
// ever touching the transport: a schema-rejected `type` must throw
// synchronously, never land in the outbox (see assertEventShape below --
// Important #3, drain-stop-at-first-failure would otherwise jam every
// subsequent event behind one poison pill forever).
const EVENT_TYPES = new Set([
  "priority_call", "override", "challenge", "outcome", "interview_answer",
  "audit_verdict", "suggestion_decision", "matrix_change", "handoff", "decision"
]);

// Deliberately NOT P1a's validateEvent (tools/pm/src/journal.mjs): that
// throws on secret-shaped bodies, which contradicts this engine's F9
// redact-and-flag policy. This is shape-only -- the minimum needed so a
// caller mistake throws before the transport, not after.
function assertEventShape(e) {
  if (!e.portfolio) throw new Error("portfolio is required");
  if (!EVENT_TYPES.has(e.type)) throw new Error(`Unknown event type: ${e.type}`);
  if (!e.author) throw new Error("author is required");
}

// P1a's `subject` -> this schema's (subject_kind, subject_id). Explicit
// e.subject_kind always wins; anything not listed here (outcome,
// suggestion_decision, ...) falls through to 'system'.
const TYPE_TO_SUBJECT_KIND = {
  override: "agent",
  challenge: "agent",
  audit_verdict: "agent",
  matrix_change: "agent",
  priority_call: "track",
  decision: "track",
  interview_answer: "user",
  handoff: "system"
};

// Every SQL string below carries a `-- journal-pg:<tag>` comment. That's
// not decoration: it's the stable hook the fake transport in
// journal-pg.test.mjs switches on, so the test double never has to parse
// real SQL to know which statement it's looking at.

const INSERT_EVENT_SQL = `-- journal-pg:insert-event
insert into stack.events
  (event_id, org_id, portfolio, user_id, schema_version, ts, type,
   subject_kind, subject_id, author, repo, track, session_id, machine_id,
   producer, ref_event_id, body, redacted)
values
  ($1::uuid, $2, $3, $4::uuid, $5, $6::timestamptz, $7,
   $8, $9, $10, $11, $12, $13, $14,
   $15, $16::uuid, $17::jsonb, $18::text[])
on conflict (event_id) do nothing`;

const EVENTS_BASE_SQL = `-- journal-pg:events
select * from stack.events where portfolio = $1`;
const EVENTS_ALL_SQL = `${EVENTS_BASE_SQL} order by ts`;
const EVENTS_SINCE_SQL = `${EVENTS_BASE_SQL} and ts >= $2 order by ts`;

const STALE_CALLS_SQL = `-- journal-pg:stale-calls
select count(*)::int as count
from stack.events e
left join stack.events o
  on o.portfolio = e.portfolio and o.ref_event_id = e.event_id and o.type = 'outcome'
where e.portfolio = $1 and e.type = 'priority_call' and e.ts < $2::timestamptz and o.event_id is null`;

const PENDING_PREDICTIONS_SQL = `-- journal-pg:pending-predictions
select count(*)::int as count
from stack.events e
left join stack.events o
  on o.portfolio = e.portfolio and o.ref_event_id = e.event_id and o.type = 'outcome'
where e.portfolio = $1 and e.type = 'priority_call' and e.ts >= $2::timestamptz and o.event_id is null`;

const OVERRIDES_BY_AGENT_SQL = `-- journal-pg:overrides-by-agent
select subject_id, count(*)::int as count
from stack.events
where portfolio = $1 and type = 'override' and ts >= $2::timestamptz
group by subject_id`;

const PURGE_SQL = "select stack.purge_portfolio()";
const SWEEP_RETENTION_SQL = "select stack.sweep_retention($1)";

const REF_EXISTS_SQL = `-- journal-pg:ref-exists
select 1 from stack.events where event_id = $1::uuid limit 1`;

// The review BLOCKER: briefData is ONE transport.tx -- set_portfolio plus
// this single multi-CTE statement -- never N queries in a loop (ADR-060
// §6's "the brief must issue ONE round trip"). $2 is the ALREADY-
// SUBTRACTED 7-day cutoff (computed once, client-side, in briefData()
// below -- exactly like counters() computes its own cutoff) -- never a
// raw `now` with interval arithmetic left to the SQL. A prior version did
// that arithmetic in SQL via a `cutoff` CTE but bound $2 to `now` instead
// of the cutoff at the call site, silently turning the whole brief into a
// same-instant (zero-day) window -- caught in review, not by the original
// test suite, because the test double independently (and incorrectly)
// re-derived a 7-day subtraction the shipped SQL never performed. Fixed
// by removing all interval arithmetic from this statement entirely: one
// subtraction site (briefData()'s own `nowMs - 7 days`), matching
// counters().
// Exported so pg-integration.test.mjs (Task 7 checkpoint) can execute the
// SHIPPED statement text against real Postgres, not a hand-retyped copy.
export const BRIEF_DATA_SQL = `-- journal-pg:brief-data
with stale_calls as (
  select count(*)::int as n
  from stack.events e
  left join stack.events o
    on o.portfolio = e.portfolio and o.ref_event_id = e.event_id and o.type = 'outcome'
  where e.portfolio = $1 and e.type = 'priority_call'
    and e.ts < $2::timestamptz and o.event_id is null
),
pending_predictions as (
  select count(*)::int as n
  from stack.events e
  left join stack.events o
    on o.portfolio = e.portfolio and o.ref_event_id = e.event_id and o.type = 'outcome'
  where e.portfolio = $1 and e.type = 'priority_call'
    and e.ts >= $2::timestamptz and o.event_id is null
),
overrides_agg as (
  select subject_id, count(*)::int as n
  from stack.events
  where portfolio = $1 and type = 'override' and ts >= $2::timestamptz
  group by subject_id
),
overrides_by_agent as (
  select coalesce(jsonb_object_agg(subject_id, n), '{}'::jsonb) as obj from overrides_agg
),
recent_overrides as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'event_id', event_id, 'ref_event_id', ref_event_id, 'subject_id', subject_id,
    'session_id', session_id, 'ts', ts
  ) order by ts desc), '[]'::jsonb) as arr
  from stack.events
  where portfolio = $1 and type = 'override' and ts >= $2::timestamptz
),
recent_challenges as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'event_id', event_id, 'ref_event_id', ref_event_id, 'subject_id', subject_id,
    'session_id', session_id, 'ts', ts
  ) order by ts desc), '[]'::jsonb) as arr
  from stack.events
  where portfolio = $1 and type = 'challenge' and ts >= $2::timestamptz
)
select
  jsonb_build_object(
    'staleCalls', (select n from stale_calls),
    'overridesByAgent', (select obj from overrides_by_agent),
    'pendingPredictions', (select n from pending_predictions)
  ) as counters,
  (select arr from recent_overrides) as "recentOverrides",
  (select arr from recent_challenges) as "recentChallenges"`;

function subjectKindFor(e) {
  return e.subject_kind ?? TYPE_TO_SUBJECT_KIND[e.type] ?? "system";
}

// The fully-resolved event (id stamped, subject mapped, body
// redacted-and-flagged) is built BEFORE any transport attempt, so the
// exact same object can be replayed verbatim from the outbox later --
// never re-derived, never re-redacted.
function buildFullEvent(e, ctx) {
  const eventId = uuidv7();
  validateEventId(eventId);
  const { body, redacted } = redactSecretsAndPaths(e.body);
  return {
    event_id: eventId,
    org_id: ctx.orgId,
    portfolio: e.portfolio,
    user_id: ctx.userId,
    schema_version: 1,
    ts: e.ts ?? new Date().toISOString(),
    type: e.type,
    subject_kind: subjectKindFor(e),
    // Silent default to "system" when neither is given -- deferred minor
    // (ledger): a caller that forgets `subject`/`subject_id` on a type
    // that expects an agent/track/user gets a quietly wrong-looking row
    // rather than a loud error. Not fixed here; noted for whoever revisits.
    subject_id: e.subject_id ?? e.subject ?? "system",
    author: e.author,
    repo: e.repo ?? null,
    track: e.track ?? null,
    session_id: e.session_id ?? ctx.sessionId ?? null,
    machine_id: e.machine_id ?? ctx.machineId ?? null,
    producer: ctx.producer,
    ref_event_id: e.ref_event_id ?? null,
    body,
    redacted
  };
}

function insertStatementFor(fe) {
  return {
    sql: INSERT_EVENT_SQL,
    params: [
      fe.event_id, fe.org_id, fe.portfolio, fe.user_id, fe.schema_version, fe.ts, fe.type,
      fe.subject_kind, fe.subject_id, fe.author, fe.repo, fe.track, fe.session_id, fe.machine_id,
      fe.producer, fe.ref_event_id, fe.body ? JSON.stringify(fe.body) : null,
      fe.redacted && fe.redacted.length ? fe.redacted : null
    ]
  };
}

export function openPgJournal({ transport, orgId, userId, producer, outboxPath, sessionId, machineId }) {
  const ctx = { orgId, userId, producer, sessionId, machineId };

  // #149: drainOutboxFirst() and appendToOutbox() (below, in the catch)
  // are two concurrent writers of the same outboxPath -- a brief-triggered
  // drain and a closeout append can interleave a read-modify-rewrite and
  // drop the appended event. Resolved in outbox.mjs itself via an O_EXCL
  // lockfile shared by both operations, not here (this call site is
  // unchanged; the serialization is transparent to it).
  function drainOutboxFirst() {
    return drainOutbox(outboxPath, async (queuedEvent) => {
      await transport.tx([
        { sql: SET_PORTFOLIO_SQL, params: [queuedEvent.portfolio] },
        insertStatementFor(queuedEvent)
      ]);
    });
  }

  return {
    async append(e) {
      assertEventShape(e);
      const fullEvent = buildFullEvent(e, ctx);
      await drainOutboxFirst();
      try {
        await transport.tx([
          { sql: SET_PORTFOLIO_SQL, params: [fullEvent.portfolio] },
          insertStatementFor(fullEvent)
        ]);
      } catch {
        // TRANSPORT failure only -- the event is already fully formed
        // (own UUIDv7, already redacted), so it's queued verbatim rather
        // than lost.
        await appendToOutbox(outboxPath, fullEvent);
      }
      return fullEvent.event_id;
    },

    async attachOutcome(refEventId, body, portfolio) {
      // P1a's SQLite engine looks up the ref's portfolio with an unscoped
      // query (one file, no RLS). RLS here fails closed with no portfolio
      // context set, and there's no admin/bypass role at Layer A to do
      // that lookup blind -- so the caller (which already knows its own
      // portfolio) supplies it. This is the one place arity intentionally
      // differs from P1a's 2-arg version; the interface contract is
      // name+behavior parity, not arity.
      validateEventId(refEventId, { allowHistoric: true });
      if (!portfolio) throw new Error("portfolio is required");
      // P1a throws `Event <id> not found` for a well-formed but
      // nonexistent ref (Important #4) -- without this, a nonexistent ref
      // would sail past validation, hit the server's FK constraint deep
      // inside append()'s transport.tx, and get treated as a transport
      // failure -> queued to the outbox -> jam every event behind it
      // (drain-stop-at-first-failure never manages to replay a row the
      // server will keep rejecting). One SELECT, own round trip, before
      // any insert is attempted.
      //
      // Review round 3 (regression from the #4 fix): this probe is the
      // FIRST transport touch attachOutcome makes, and a bare `await`
      // with no try/catch meant a transport outage during the probe
      // itself propagated straight out -- no event ever formed, nothing
      // outboxed, the outcome/close-out write silently lost. That is
      // exactly the failure ADR-060 §6's outbox exists to prevent
      // (§6:614-618's motivating case is an outcome/close-out event at
      // exactly the moment the user stops watching). Fix: distinguish
      // "probe answered zero rows" (genuinely nonexistent ref -> throw,
      // never outbox) from "probe never answered" (transport outage ->
      // fall through to append(), which forms the event and queues it to
      // the outbox like any other transport failure). refExists defaults
      // true so an outage never gets misread as "not found"; a
      // genuinely-bad ref written during an outage still jams on retry
      // once the transport recovers (both conditions must hold), which
      // is accepted as rarer and strictly better than losing the write.
      let refExists = true;
      try {
        const probe = await transport.tx([
          { sql: SET_PORTFOLIO_SQL, params: [portfolio] },
          { sql: REF_EXISTS_SQL, params: [refEventId] }
        ]);
        refExists = probe[1].length > 0;
      } catch {
        // transport outage during the probe -- unknown, not "doesn't
        // exist". Fall through; refExists stays true.
      }
      if (!refExists) {
        throw new Error(`Event ${refEventId} not found`);
      }
      return this.append({
        ts: new Date().toISOString(),
        type: "outcome",
        subject: "system",
        author: "pm",
        portfolio,
        ref_event_id: refEventId,
        body
      });
    },

    async events(portfolio, options = {}) {
      if (portfolio === undefined) throw new Error("portfolio is required");
      const sinceMs = options.sinceMs;
      const sql = sinceMs !== undefined ? EVENTS_SINCE_SQL : EVENTS_ALL_SQL;
      const params = sinceMs !== undefined ? [portfolio, new Date(sinceMs).toISOString()] : [portfolio];
      const results = await transport.tx([{ sql: SET_PORTFOLIO_SQL, params: [portfolio] }, { sql, params }]);
      return results[1];
    },

    async counters(portfolio, nowMs) {
      if (portfolio === undefined) throw new Error("portfolio is required");
      const cutoff = new Date(nowMs - 7 * 86_400_000).toISOString();
      const results = await transport.tx([
        { sql: SET_PORTFOLIO_SQL, params: [portfolio] },
        { sql: STALE_CALLS_SQL, params: [portfolio, cutoff] },
        { sql: OVERRIDES_BY_AGENT_SQL, params: [portfolio, cutoff] },
        { sql: PENDING_PREDICTIONS_SQL, params: [portfolio, cutoff] }
      ]);
      const overridesByAgent = {};
      for (const row of results[2]) overridesByAgent[row.subject_id] = Number(row.count);
      return {
        staleCalls: Number(results[1][0]?.count ?? 0),
        overridesByAgent,
        pendingPredictions: Number(results[3][0]?.count ?? 0)
      };
    },

    // Additive: the CLI brief path's one-round-trip answer (review
    // BLOCKER). events()/counters() remain for other callers.
    async briefData(portfolio, nowMs) {
      if (!portfolio) throw new Error("portfolio is required");
      const cutoff = new Date(nowMs - 7 * 86_400_000).toISOString();
      const results = await transport.tx([
        { sql: SET_PORTFOLIO_SQL, params: [portfolio] },
        { sql: BRIEF_DATA_SQL, params: [portfolio, cutoff] }
      ]);
      const row = results[1][0] ?? {};
      return {
        counters: row.counters ?? { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 },
        recentOverrides: row.recentOverrides ?? [],
        recentChallenges: row.recentChallenges ?? []
      };
    },

    async purge(portfolio) {
      if (!portfolio) throw new Error("portfolio is required");
      await transport.tx([{ sql: SET_PORTFOLIO_SQL, params: [portfolio] }, { sql: PURGE_SQL, params: [] }]);
    },

    // stack.sweep_retention(days) is portfolio-scoped (it reads the
    // set_portfolio GUC) and always sweeps by server `now()`, unlike
    // P1a's client-supplied nowMs -- so nowMs is accepted for interface
    // parity but not used, and portfolio is a required additional
    // argument for the same RLS reason as attachOutcome above.
    async sweepRetention(nowMs, days = 365, portfolio) {
      if (!portfolio) throw new Error("portfolio is required");
      await transport.tx([
        { sql: SET_PORTFOLIO_SQL, params: [portfolio] },
        { sql: SWEEP_RETENTION_SQL, params: [days] }
      ]);
    },

    unsentCount() {
      return outboxUnsentCount(outboxPath);
    },

    // Review fix (Task 8): an unsentCount before/after diff around append()
    // is NOT exact -- a drain that removes an older queued event and a
    // fresh append() that queues THIS event can net to an unchanged count
    // (drain -1, this append +1), which reads as "no change -> wrote
    // straight to the DB" when in fact this exact event is sitting unsent.
    // outboxHas(eventId) answers the only question that matters: is THIS
    // event, by id, currently queued -- independent of how many other
    // events drained or queued around it in the same call.
    outboxHas(eventId) {
      return readOutbox(outboxPath).some((e) => e.event_id === eventId);
    },

    flushOutbox() {
      return drainOutboxFirst();
    }
  };
}
