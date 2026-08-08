import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const VALID_TYPES = new Set(["priority_call", "override", "challenge", "outcome", "interview_answer", "audit_verdict", "suggestion_decision", "matrix_change", "handoff"]);
const VALID_AUTHORS = new Set(["user", "pm"]);

const SECRET_RE = /(sk_live|sk_test|secret_|service_role|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,})/;
const ABS_PATH_RE = /(^|["\s])\/(Users|home|var|etc|private)\//;

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
