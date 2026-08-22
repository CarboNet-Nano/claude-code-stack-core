import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

// REQ-147: 'decision' joins VALID_TYPES for outbox/migration symmetry with
// schemas/006-knowledge-store.sql's `type` CHECK list (journal-pg.mjs's
// EVENT_TYPES) -- this legacy engine has no dedicated `track` column, so it
// stores nothing extra for the type, but a caller (e.g. cli.mjs) must be
// able to build+validate a decision event regardless of which engine is
// wired underneath.
const VALID_TYPES = new Set(["priority_call", "override", "challenge", "outcome", "interview_answer", "audit_verdict", "suggestion_decision", "matrix_change", "handoff", "decision"]);
// 'skill' (REQ-147): brainstorming/plan/handoff SKILL.md emit decision
// events as their own author, distinct from 'user' and 'pm'.
const VALID_AUTHORS = new Set(["user", "pm", "skill"]);

const SECRET_RE = /(sk_live|sk_test|secret_|service_role|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}|postgres(?:ql)?:\/\/[^\s]*:[^\s]*@)/;
const ABS_PATH_RE = /(^|["\s])\/(Users|home|var|etc|private)\//;

// ADR-060 §5 (F9 redact-and-flag) + addendum. Exported so the Postgres
// engine (journal-pg.mjs) runs the SAME secret/path detection as this
// legacy engine, just with a different policy at the call site: this file
// keeps throwing (frozen, for migration fidelity — see validateEvent
// above, unchanged); the PG engine redacts-and-flags instead of losing the
// event. Recursive so every string is caught at every depth, matching the
// depth coverage the legacy JSON.stringify()+regex check already has.
export function walkForRedaction(value, path, redacted) {
  if (typeof value === "string") {
    if (SECRET_RE.test(value) || ABS_PATH_RE.test(value)) {
      redacted.push(path);
      return "[REDACTED]";
    }
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((item, i) => walkForRedaction(item, `${path}.${i}`, redacted));
  }
  if (value !== null && typeof value === "object") {
    const out = {};
    for (const [key, val] of Object.entries(value)) {
      out[key] = walkForRedaction(val, `${path}.${key}`, redacted);
    }
    return out;
  }
  return value;
}

export function redactSecretsAndPaths(body) {
  const redacted = [];
  if (body === undefined || body === null) {
    return { body: body ?? null, redacted };
  }
  return { body: walkForRedaction(body, "body", redacted), redacted };
}

export function validateEvent(e) {
  if (!VALID_TYPES.has(e.type)) {
    throw new Error(`Unknown event type: ${e.type}`);
  }
  if (!VALID_AUTHORS.has(e.author)) {
    throw new Error(`Unknown author: ${e.author}`);
  }

  // Check for secrets/paths in body
  if (e.body) {
    const bodyStr = JSON.stringify(e.body);
    if (SECRET_RE.test(bodyStr)) {
      throw new Error("Secret-shaped string found in body");
    }
    if (ABS_PATH_RE.test(bodyStr)) {
      throw new Error("Absolute path found in body");
    }
  }

  // Type-specific validation
  if (e.type === "override") {
    if (!e.body || !e.body.positions || !e.body.positions.caller || !e.body.positions.user) {
      throw new Error("override body requires positions.caller and positions.user");
    }
  }
  if (e.type === "priority_call") {
    if (!e.body || !e.body.predicted) {
      throw new Error("priority_call body requires predicted field");
    }
  }
  if (e.type === "outcome") {
    if (!e.ref_event_id) {
      throw new Error("outcome event requires ref_event_id");
    }
  }
}

export function openJournal(dbPath) {
  // Create directory if needed
  const dir = dirname(dbPath);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }

  const db = new DatabaseSync(dbPath);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA busy_timeout = 5000");

  db.exec(`
    CREATE TABLE IF NOT EXISTS events (
      event_id TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      ts TEXT NOT NULL,
      type TEXT NOT NULL,
      subject TEXT NOT NULL,
      author TEXT NOT NULL,
      portfolio TEXT NOT NULL,
      ref_event_id TEXT,
      body TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_events_portfolio_ts ON events(portfolio, ts);
    CREATE INDEX IF NOT EXISTS idx_events_ref ON events(ref_event_id);
  `);

  return {
    path: dbPath,

    append(e) {
      if (!e.portfolio) {
        throw new Error("portfolio is required");
      }
      validateEvent(e);

      const event_id = randomUUID();
      const stmt = db.prepare(`
        INSERT INTO events (event_id, schema_version, ts, type, subject, author, portfolio, ref_event_id, body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      stmt.run(
        event_id,
        1,
        e.ts,
        e.type,
        e.subject,
        e.author,
        e.portfolio,
        e.ref_event_id || null,
        e.body ? JSON.stringify(e.body) : null
      );
      return event_id;
    },

    attachOutcome(refEventId, body) {
      // Get the referenced event to get its portfolio
      const stmt = db.prepare("SELECT portfolio FROM events WHERE event_id = ?");
      const row = stmt.get(refEventId);
      if (!row) {
        throw new Error(`Event ${refEventId} not found`);
      }
      return this.append({
        ts: new Date().toISOString(),
        type: "outcome",
        subject: "system",
        author: "pm",
        portfolio: row.portfolio,
        ref_event_id: refEventId,
        body
      });
    },

    events(portfolio, options) {
      if (portfolio === undefined) {
        throw new Error("portfolio is required");
      }
      options = options || {};

      let query = "SELECT * FROM events WHERE portfolio = ?";
      const params = [portfolio];

      if (options.sinceMs) {
        const sinceIso = new Date(options.sinceMs).toISOString();
        query += " AND ts >= ?";
        params.push(sinceIso);
      }

      query += " ORDER BY ts";

      const stmt = db.prepare(query);
      const rows = stmt.all(...params);

      return rows.map((row) => ({
        ...row,
        body: row.body ? JSON.parse(row.body) : undefined
      }));
    },

    counters(portfolio, nowMs) {
      const now = new Date(nowMs);
      const sevenDaysAgo = new Date(nowMs - 7 * 86_400_000);

      // Stale calls: priority_call > 7d old, no linked outcome
      const staleCalls = db.prepare(`
        SELECT COUNT(*) as count FROM events e
        LEFT JOIN events o ON o.ref_event_id = e.event_id AND o.type = 'outcome'
        WHERE e.portfolio = ? AND e.type = 'priority_call'
          AND e.ts < ? AND o.event_id IS NULL
      `).get(portfolio, sevenDaysAgo.toISOString());

      // Overrides by agent: count overrides by author/subject in last 7 days
      const overridesRaw = db.prepare(`
        SELECT subject, COUNT(*) as count FROM events
        WHERE portfolio = ? AND type = 'override' AND ts >= ?
        GROUP BY subject
      `).all(portfolio, sevenDaysAgo.toISOString());

      const overridesByAgent = {};
      overridesRaw.forEach((row) => {
        overridesByAgent[row.subject] = row.count;
      });

      // Pending predictions: priority_call <= 7d old, no linked outcome
      const pendingPredictions = db.prepare(`
        SELECT COUNT(*) as count FROM events e
        LEFT JOIN events o ON o.ref_event_id = e.event_id AND o.type = 'outcome'
        WHERE e.portfolio = ? AND e.type = 'priority_call'
          AND e.ts >= ? AND o.event_id IS NULL
      `).get(portfolio, sevenDaysAgo.toISOString());

      return {
        staleCalls: staleCalls.count,
        overridesByAgent,
        pendingPredictions: pendingPredictions.count
      };
    },

    purge(portfolio) {
      const stmt = db.prepare("DELETE FROM events WHERE portfolio = ?");
      stmt.run(portfolio);
    },

    sweepRetention(nowMs, days = 365) {
      const cutoff = new Date(nowMs - days * 86_400_000);
      const stmt = db.prepare("DELETE FROM events WHERE ts < ?");
      stmt.run(cutoff.toISOString());
    }
  };
}
