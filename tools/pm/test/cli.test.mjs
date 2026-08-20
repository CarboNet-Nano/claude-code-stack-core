import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as pathJoin, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { main } from "../src/cli.mjs";
import { openJournal } from "../src/journal.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = pathJoin(__dirname, "..", "..", "..");
const CONFIG_PATH = "/fake/config/portfolio.json";

function idleTrackFixture(track, updated) {
  return `---\ntrack: ${track}\ngoal: Goal for ${track}\nupdated: ${updated}\nblocked_on:\nprioritized: true\n---\n\n## Current state\nwaiting\n\n## Risks\nnone\n\n## Next steps\nnone\n`;
}

function makeConfig(members) {
  return JSON.stringify({
    portfolios: {
      testfolio: { pace: "balanced", members }
    }
  });
}

function trackFixture(track, updated, state) {
  return `---\ntrack: ${track}\ngoal: Goal for ${track}\nupdated: ${updated}\nblocked_on:\nprioritized: false\n---\n\n## Current state\n${state}\n\n## Risks\nnone\n\n## Next steps\nnone\n`;
}

function makeFiles(initial) {
  return { ...initial };
}

// Task 8: a fake matching the PG engine's async shape (append/briefData
// return promises; unsentCount/outboxHas stay sync -- plain file reads, not
// transport calls, same as the real openPgJournal). `appendOutboxes: true`
// simulates a TRANSPORT failure inside append() (Task 5's real engine
// queues to the outbox and does NOT throw); `outboxHas` tracks the exact
// event id queued, not just a count, matching the review fix that replaced
// an unsentCount before/after diff (inexact under a same-call drain) with
// exact per-event detection. `flushSucceeds`/`flushThrows` simulate the
// brief-side best-effort drain-on-connection fold-in.
function makeJournal(opts = {}) {
  const calls = [];
  const briefDataCalls = [];
  const flushOutboxCalls = [];
  const outboxIds = new Set();
  let unsent = opts.unsentCount ?? 0;
  let nextId = 0;
  return {
    calls,
    briefDataCalls,
    flushOutboxCalls,
    async append(e) {
      calls.push(e);
      const eventId = `fake-event-${++nextId}`;
      if (opts.appendOutboxes) {
        unsent += 1;
        outboxIds.add(eventId);
      }
      return eventId;
    },
    async counters() {
      return opts.counters || { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 };
    },
    async briefData(portfolio, nowMs) {
      briefDataCalls.push({ portfolio, nowMs });
      if (opts.briefDataThrows) throw new Error(opts.briefDataThrows);
      return {
        counters: opts.counters || { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 },
        recentOverrides: opts.recentOverrides || [],
        recentChallenges: opts.recentChallenges || []
      };
    },
    unsentCount() {
      return unsent;
    },
    outboxHas(eventId) {
      return outboxIds.has(eventId);
    },
    async flushOutbox() {
      flushOutboxCalls.push(true);
      if (opts.flushThrows) throw new Error(opts.flushThrows);
      if (opts.flushSucceeds) {
        const sent = unsent;
        unsent = 0;
        outboxIds.clear();
        return { sent, remaining: 0 };
      }
      return { sent: 0, remaining: unsent };
    }
  };
}

function makeExecFile(handlers) {
  const calls = [];
  const fn = async (cmd, args) => {
    calls.push({ cmd, args });
    for (const h of handlers) {
      const result = h(cmd, args);
      if (result !== undefined) return result;
    }
    return { stdout: "" };
  };
  fn.calls = calls;
  return fn;
}

function baseDeps(overrides = {}) {
  const files = overrides.files || {};
  const stdoutLines = [];
  const deps = {
    execFile: overrides.execFile || makeExecFile([]),
    journal: overrides.journal || makeJournal(),
    readFile: overrides.readFile || (async (p) => {
      if (!(p in files)) throw new Error(`ENOENT: ${p}`);
      return files[p];
    }),
    writeFile: overrides.writeFile || (async (p, c) => {
      files[p] = c;
    }),
    glob: overrides.glob || (async () => ({})),
    stdout: overrides.stdout || ((line) => stdoutLines.push(line)),
    nowIso: overrides.nowIso || (() => "2026-08-08T12:00:00.000Z"),
    configPath: overrides.configPath || CONFIG_PATH,
    costLogPath: overrides.costLogPath,
    trackPath: overrides.trackPath,
    journalError: overrides.journalError,
    repoConfigPath: overrides.repoConfigPath,
    portfolioConfigPath: overrides.portfolioConfigPath,
    sessionId: overrides.sessionId ?? null
  };
  deps.stdoutLines = stdoutLines;
  deps.files = files;
  return deps;
}

test("brief: happy path prints <=12 structural lines plus fence", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0);
  assert(result.lines.length <= 12, `expected <=12 lines, got ${result.lines.length}`);
  assert(Array.isArray(result.fence));
  assert(deps.stdoutLines.length > 0, "should have printed something");
  assert(result.lines.some((l) => l.includes("[t1]")), "should list track t1");
});

test("REQ-110: brief --full skips the 12-line budget cap end to end", async () => {
  const trackPaths = Array.from({ length: 15 }, (_, i) => `/fake/repoA/t${i}.md`);
  const files = { [CONFIG_PATH]: makeConfig(["org/repoA"]) };
  for (const p of trackPaths) {
    files[p] = trackFixture(p.split("/").pop().replace(".md", ""), "2026-08-08", "state");
  }
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": trackPaths })
  });

  const capped = await main(["brief", "--portfolio", "testfolio"], deps);
  assert.equal(capped.lines.length, 12, "default run must stay capped at 12");
  assert(capped.lines.some((l) => /items held back — run brief --full/.test(l)), "capped run should carry the held-back marker");

  const full = await main(["brief", "--portfolio", "testfolio", "--full"], deps);
  assert(full.lines.length > 12, `--full run should exceed 12 lines, got ${full.lines.length}`);
  assert(!full.lines.some((l) => /items held back/.test(l)), "--full run must not carry the held-back marker");
});

// REQ-111 amendment (ASSUMPTION 3) — `pm brief`'s real spend collection,
// end to end: a track's frontmatter budget_usd paired against cost-log
// actuals reaches assembleBrief's Challenge: section through the same path
// production uses (collectSpend -> assembleBrief), not a hand-built spend
// fixture.
function trackFixtureWithBudget(track, updated, budgetUsd) {
  return `---\ntrack: ${track}\ngoal: Goal for ${track}\nupdated: ${updated}\nblocked_on:\nprioritized: false\nbudget_usd: ${budgetUsd}\n---\n\n## Current state\non track\n\n## Risks\nnone\n\n## Next steps\nnone\n`;
}

test("REQ-111 amendment: pm brief wires real spend collection — budget_usd + cost-log actual fires the 2.5x challenge", async () => {
  const COST_LOG_PATH = "/fake/logs/cost-log.jsonl";
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixtureWithBudget("t1", "2026-08-08", 10),
    [COST_LOG_PATH]: [
      JSON.stringify({ cost_usd: 15, track: "t1" }),
      JSON.stringify({ cost_usd: 10, track: "t1" })
    ].join("\n")
  };
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] }),
    costLogPath: COST_LOG_PATH
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0);
  assert(result.lines.some((l) => /t1 at 2\.5× its estimate/.test(l)), `expected the spend challenge line, got: ${JSON.stringify(result.lines)}`);
});

test("REQ-111 amendment: pm brief — a track with no budget_usd never triggers a cost-log read (no spurious warning)", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0);
  assert(!result.warnings.some((w) => /cost-log/.test(w)), `expected no cost-log warning, got: ${JSON.stringify(result.warnings)}`);
});

test("ASSUMPTION 5: pm brief passes the portfolio name through to deps.glob (second argument) for checkout_root resolution", async () => {
  const files = { [CONFIG_PATH]: makeConfig(["org/repoA"]) };
  let capturedPortfolio;
  const deps = baseDeps({
    files,
    glob: async (scope, portfolioName) => {
      capturedPortfolio = portfolioName;
      return {};
    }
  });

  await main(["brief", "--portfolio", "testfolio"], deps);
  assert.equal(capturedPortfolio, "testfolio");
});

test("brief: gh failure resilience — execFile throws, track lines still print", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const execFile = async () => {
    throw new Error("gh: command not found");
  };
  const deps = baseDeps({
    files,
    execFile,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0, "brief must never brick on gh failure");
  assert(result.lines.some((l) => l.includes("[t1]")), "track lines still present despite gh failure");
  assert(result.warnings.length > 0, "should record a warning about gh failure");
});

test("REQ-103: 3-repo completeness — every track listed, every open pm issue counted", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA", "org/repoB", "org/repoC"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "state a"),
    "/fake/repoB/t2.md": trackFixture("t2", "2026-08-08", "state b"),
    "/fake/repoB/t3.md": trackFixture("t3", "2026-08-08", "state c")
  };

  const issuesByRepo = {
    "org/repoA": 2,
    "org/repoB": 1,
    "org/repoC": 0
  };

  const execFile = makeExecFile([
    (cmd, args) => {
      if (cmd === "gh" && args[0] === "issue" && args[1] === "list") {
        const repoIdx = args.indexOf("--repo");
        const repo = args[repoIdx + 1];
        const n = issuesByRepo[repo] ?? 0;
        const issues = Array.from({ length: n }, (_, i) => ({ number: i + 1, title: "x", labels: [] }));
        return { stdout: JSON.stringify(issues) };
      }
      if (cmd === "gh" && args[0] === "api") {
        return { stdout: "{}" };
      }
      return undefined;
    }
  ]);

  const deps = baseDeps({
    files,
    execFile,
    glob: async () => ({
      "org/repoA": ["/fake/repoA/t1.md"],
      "org/repoB": ["/fake/repoB/t2.md", "/fake/repoB/t3.md"],
      "org/repoC": []
    })
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.trackCount, 3, "all 3 tracks across repos should be counted");
  for (const slug of ["t1", "t2", "t3"]) {
    assert(result.lines.some((l) => l.includes(`[${slug}]`)), `missing track ${slug}`);
  }
  assert.equal(result.issueCount, 3, "every open pm issue across repos should be counted (2+1+0)");
});

test("REQ-103: one repo's gh issue-list failure doesn't zero the whole portfolio's count", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA", "org/repoB", "org/repoC"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "state a"),
    "/fake/repoB/t2.md": trackFixture("t2", "2026-08-08", "state b")
  };

  const okCounts = { "org/repoA": 2, "org/repoB": 1 };

  const execFile = makeExecFile([
    (cmd, args) => {
      if (cmd === "gh" && args[0] === "issue" && args[1] === "list") {
        const repoIdx = args.indexOf("--repo");
        const repo = args[repoIdx + 1];
        if (repo === "org/repoC") {
          throw new Error("gh: network error for repoC");
        }
        const n = okCounts[repo] ?? 0;
        const issues = Array.from({ length: n }, (_, i) => ({ number: i + 1, title: "x", labels: [] }));
        return { stdout: JSON.stringify(issues) };
      }
      if (cmd === "gh" && args[0] === "api") {
        return { stdout: "{}" };
      }
      return undefined;
    }
  ]);

  const deps = baseDeps({
    files,
    execFile,
    glob: async () => ({
      "org/repoA": ["/fake/repoA/t1.md"],
      "org/repoB": ["/fake/repoB/t2.md"],
      "org/repoC": []
    })
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0, "brief must never brick on a single repo's gh failure");
  assert.equal(result.issueCount, 3, "repoA(2) + repoB(1) still counted despite repoC's failure");
  assert.deepEqual(result.issueFailedRepos, ["org/repoC"], "repoC recorded as unreadable, not silently zeroed");
  assert(
    deps.stdoutLines.some((l) => /Issues: 3 open/.test(l) && /org\/repoC/.test(l)),
    "Issues line itself must name the unreadable repo, not print a clean-looking count"
  );
});

test("closeout: track B untouched (byte-identical) while track A updates", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const trackBPath = "/fake/tracks/track-b.md";
  const trackBOriginal = trackFixture("track-b", "2020-01-01", "unchanged content");
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: trackFixture("track-a", "2020-01-01", "old state"),
    [trackBPath]: trackBOriginal
  });

  const execFile = makeExecFile([]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "new state",
      "--next", "[]"
    ],
    deps
  );

  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(files[trackBPath], trackBOriginal, "track B must be byte-identical");
  assert.notEqual(files[trackAPath], trackBOriginal, "track A content must actually have changed");
  assert(files[trackAPath].includes("new state"), "track A should have updated state");
});

test("closeout: done-without-comment refused, zero mutations", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const originalA = trackFixture("track-a", "2020-01-01", "old state");
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: originalA
  });

  const execFile = makeExecFile([]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "new state",
      "--done", "org/repoA#5:",
      "--next", "[]"
    ],
    deps
  );

  assert.notEqual(result.code, 0, "should refuse and exit non-zero");
  assert.equal(files[trackAPath], originalA, "track file must be untouched when refused");
  assert.equal(journal.calls.length, 0, "no journal event on refusal");
  assert.equal(execFile.calls.length, 0, "no gh calls attempted on refusal");
});

test("REQ-140/REQ-102: closeout with absolute-path state fails journal validation BEFORE any mutation", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const originalA = trackFixture("track-a", "2020-01-01", "old state");
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: originalA
  });

  const execFile = makeExecFile([]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "fixed the /Users/x bug",
      "--next", "[]"
    ],
    deps
  );

  assert.notEqual(result.code, 0, "must exit non-zero on bad --state");
  assert.equal(files[trackAPath], originalA, "track file must be untouched — validation runs before the write");
  assert.equal(journal.calls.length, 0, "no journal event appended");
  assert.equal(execFile.calls.length, 0, "no gh calls attempted");
  assert(result.completed.length === 0, "no steps should have completed");
  assert(
    deps.stdoutLines.some((l) => /state text failed journal validation/.test(l) && /no changes made/.test(l)),
    "should print a clear no-changes-made message"
  );
});

test("closeout: handoff event appended on success", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: trackFixture("track-a", "2020-01-01", "old state")
  });

  const execFile = makeExecFile([
    (cmd, args) => {
      if (cmd === "gh" && args[0] === "issue" && (args[1] === "comment" || args[1] === "close" || args[1] === "create")) {
        return { stdout: "" };
      }
      return undefined;
    }
  ]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "new state",
      "--done", "org/repoA#5:closing this out",
      "--next", "[]"
    ],
    deps
  );

  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(journal.calls.length, 1, "journal event should be appended exactly once");
  assert.equal(journal.calls[0].type, "handoff", "event type must be 'handoff' (valid per VALID_TYPES)");
});

test("closeout: fail-fast — issue-close failure after track update → non-zero, steps printed, NO journal event", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const originalA = trackFixture("track-a", "2020-01-01", "old state");
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: originalA
  });

  const execFile = makeExecFile([
    (cmd, args) => {
      if (cmd === "gh" && args[0] === "issue" && args[1] === "comment") {
        return { stdout: "" };
      }
      if (cmd === "gh" && args[0] === "issue" && args[1] === "close") {
        throw new Error("gh: network error");
      }
      return undefined;
    }
  ]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "new state",
      "--done", "org/repoA#5:closing this out",
      "--next", "[]"
    ],
    deps
  );

  assert.notEqual(result.code, 0, "must exit non-zero");
  assert(files[trackAPath].includes("new state"), "track-file mutation should have completed (order: track-file before issues)");
  assert(result.completed.includes("track-file"), "completed steps must list track-file");
  assert(!result.completed.some((s) => s.startsWith("done:")), "the failing done step should not be in completed");
  assert.equal(journal.calls.length, 0, "journal event must NOT be written on failure — it is the commit marker");
  assert(deps.stdoutLines.some((l) => /Completed/.test(l) || /completed/.test(l)), "should print completed steps");
  assert(deps.stdoutLines.some((l) => /Failed/.test(l) || /failed/.test(l)), "should print failed step");
});

// ---------------------------------------------------------------------------
// Task 8: cutover to the org Postgres store. Two failure classes, two
// behaviors -- RESOLUTION failure (bin.mjs never reached a working journal;
// simulated here via deps.journalError, exactly what bin.mjs sets when
// directory.resolve()/createTransport() throw) vs TRANSPORT failure
// (resolution succeeded; the DB call itself fails, simulated via
// makeJournal's appendOutboxes option, mirroring journal-pg.mjs's real
// outbox-on-transport-failure behavior).
// ---------------------------------------------------------------------------

const RESOLUTION_ERROR =
  "journal unreachable: directory.resolve: no credential for org 'carbonet'. Set $STACK_DB_URL, or run:\n" +
  "  security add-generic-password -a \"$USER\" -s stack-db-url-carbonet -w 'YOUR_CONNECTION_STRING'";

test("brief: resolution failure — track lines still print, warning names the Keychain command, exit 0", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const journal = makeJournal({ briefDataThrows: "briefData must not be attempted after a resolution failure" });
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] }),
    journal,
    journalError: RESOLUTION_ERROR
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0, "resolution failure must never brick the brief");
  assert(result.lines.some((l) => l.includes("[t1]")), "track lines still print");
  assert(
    result.warnings.some((w) => w.includes("journal unreachable:") && w.includes("security add-generic-password")),
    `expected an actionable Keychain warning, got: ${JSON.stringify(result.warnings)}`
  );
  assert.equal(journal.briefDataCalls.length, 0, "briefData must not be attempted once resolution is already known to have failed");
  assert.equal(journal.flushOutboxCalls.length, 0, "flushOutbox must not be attempted -- there was never a live connection to flush through");
});

test("closeout: resolution failure — exits non-zero, ZERO mutations, before any write", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const originalA = trackFixture("track-a", "2020-01-01", "old state");
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: originalA
  });
  const execFile = makeExecFile([]);
  const journal = makeJournal();
  const deps = baseDeps({
    files,
    execFile,
    journal,
    journalError: RESOLUTION_ERROR,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    ["closeout", "--track", "track-a", "--portfolio", "testfolio", "--state", "new state", "--next", "[]"],
    deps
  );

  assert.notEqual(result.code, 0, "resolution failure must exit non-zero");
  assert.equal(files[trackAPath], originalA, "track file must be untouched — resolution runs before any mutation");
  assert.equal(journal.calls.length, 0, "journal.append must never be attempted");
  assert.equal(execFile.calls.length, 0, "no gh calls attempted");
  assert.equal(result.completed.length, 0, "no steps should have completed");
  assert(
    deps.stdoutLines.some((l) => l.includes("journal unreachable:") && l.includes("security add-generic-password") && l.includes("no changes made")),
    `expected the actionable resolution error with a no-changes-made message, got: ${JSON.stringify(deps.stdoutLines)}`
  );
});

test("closeout: transport failure — track/issues steps complete, journal step outboxes, exit 0, output names the outbox", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: trackFixture("track-a", "2020-01-01", "old state")
  });
  const execFile = makeExecFile([
    (cmd, args) => {
      if (cmd === "gh" && args[0] === "issue" && (args[1] === "comment" || args[1] === "close" || args[1] === "create")) {
        return { stdout: "" };
      }
      return undefined;
    }
  ]);
  const journal = makeJournal({ appendOutboxes: true });
  const deps = baseDeps({
    files,
    execFile,
    journal,
    trackPath: (t) => `/fake/tracks/${t}.md`
  });

  const result = await main(
    [
      "closeout",
      "--track", "track-a",
      "--portfolio", "testfolio",
      "--state", "new state",
      "--done", "org/repoA#5:closing this out",
      "--next", "[]"
    ],
    deps
  );

  assert.equal(result.code, 0, JSON.stringify(result));
  assert(result.completed.includes("track-file"), "track-file step completed");
  assert(result.completed.some((s) => s.startsWith("done:")), "done step completed");
  assert(result.completed.some((s) => s.includes("outbox")), `expected an outboxed journal step, got: ${JSON.stringify(result.completed)}`);
  assert(
    deps.stdoutLines.some((l) => /outbox/.test(l) && /1 unsent/.test(l)),
    `stdout should name the outbox with the unsent count, got: ${JSON.stringify(deps.stdoutLines)}`
  );
});

// Review fix: a before/after unsentCount DIFF is not exact. Simulate
// journal-pg.mjs's real append() shape -- drainOutboxFirst() succeeds first
// (an OLDER queued event sends and is removed), THEN this new event's own
// transport write fails and gets queued in its place. unsentCount before
// this call and after are BOTH 1 (net unchanged), which the old diff-based
// detection read as "no change -> wrote straight to the DB". Exact
// per-event detection (outboxHas(thisEventId)) must still report it as
// outboxed.
test("closeout: drain-then-fail — unsentCount nets unchanged, but THIS event is still outboxed, not journaled", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: trackFixture("track-a", "2020-01-01", "old state")
  });
  const execFile = makeExecFile([]);

  let unsent = 1; // one pre-existing queued event
  const outboxIds = new Set(["stale-queued-event"]);
  const journal = {
    calls: [],
    async append(e) {
      journal.calls.push(e);
      unsent -= 1; // drain: the stale event sends successfully
      outboxIds.delete("stale-queued-event");
      const eventId = "this-events-id"; // this new event's own write fails -> queued
      unsent += 1;
      outboxIds.add(eventId);
      return eventId;
    },
    unsentCount() {
      return unsent;
    },
    outboxHas(id) {
      return outboxIds.has(id);
    }
  };

  const deps = baseDeps({ files, execFile, journal, trackPath: (t) => `/fake/tracks/${t}.md` });

  const result = await main(
    ["closeout", "--track", "track-a", "--portfolio", "testfolio", "--state", "new state", "--next", "[]"],
    deps
  );

  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(unsent, 1, "fixture sanity: unsentCount netted unchanged across the call (1 before, 1 after)");
  assert(
    result.completed.some((s) => s.includes("outbox")),
    `must report outboxed even though unsentCount netted unchanged, got: ${JSON.stringify(result.completed)}`
  );
  assert(deps.stdoutLines.some((l) => /outbox/.test(l)), "stdout must name the outbox");
});

// Review fold-in: when the journal step fails ENTIRELY (both the DB write
// and the outbox write itself fail, e.g. disk full), closeout must state
// the one fact that makes the loss legible: nothing durable happened.
test("closeout: journal step fails entirely (no DB, no outbox) — stdout states the event was not persisted anywhere", async () => {
  const trackAPath = "/fake/tracks/track-a.md";
  const files = makeFiles({
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    [trackAPath]: trackFixture("track-a", "2020-01-01", "old state")
  });
  const execFile = makeExecFile([]);
  const journal = {
    calls: [],
    async append() {
      throw new Error("outbox write failed: ENOSPC");
    }
  };
  const deps = baseDeps({ files, execFile, journal, trackPath: (t) => `/fake/tracks/${t}.md` });

  const result = await main(
    ["closeout", "--track", "track-a", "--portfolio", "testfolio", "--state", "new state", "--next", "[]"],
    deps
  );

  assert.notEqual(result.code, 0);
  assert(
    deps.stdoutLines.some((l) => l.includes("NOT persisted anywhere") && l.includes("no DB, no outbox")),
    `expected the explicit no-persistence fact, got: ${JSON.stringify(deps.stdoutLines)}`
  );
});

// Fold-in (ADR-060 §6): "the next successful connection flushes the
// outbox" -- brief has no other drain trigger, so a proven-live connection
// (briefData just succeeded) is the moment to attempt it.
test("brief: a successful briefData connection drains the outbox, best-effort", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const journal = makeJournal({ unsentCount: 2, flushSucceeds: true });
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] }),
    journal
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0);
  assert.equal(journal.flushOutboxCalls.length, 1, "flushOutbox should be attempted after a successful briefData connection");
  assert(!result.lines.some((l) => /events unsent/.test(l)), "outbox drained -> no unsent line");
});

test("brief: flushOutbox failure never fails the brief (best-effort)", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const journal = makeJournal({ unsentCount: 3, flushThrows: "transport dropped mid-flush" });
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] }),
    journal
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0, "flush failure must never fail the brief");
  assert(result.lines.includes("⚠ 3 events unsent"), "flush failed silently -> unsent count still accurately reported");
});

test("brief: journal-derived content comes from exactly one briefData call", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const journal = makeJournal({ counters: { staleCalls: 2, overridesByAgent: {}, pendingPredictions: 0 } });
  const deps = baseDeps({
    files,
    glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] }),
    journal
  });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);

  assert.equal(result.code, 0);
  assert.equal(journal.briefDataCalls.length, 1, "briefData must be called exactly once for all journal-derived brief content");
});

test("brief: prints ⚠ N events unsent when the outbox is non-empty; absent when empty", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": trackFixture("t1", "2026-08-08", "on track")
  };
  const glob = async () => ({ "org/repoA": ["/fake/repoA/t1.md"] });

  const emptyResult = await main(["brief", "--portfolio", "testfolio"], baseDeps({ files, glob, journal: makeJournal({ unsentCount: 0 }) }));
  assert(!emptyResult.lines.some((l) => /events unsent/.test(l)), "no unsent line when the outbox is empty");

  const nonEmptyResult = await main(["brief", "--portfolio", "testfolio"], baseDeps({ files, glob, journal: makeJournal({ unsentCount: 3 }) }));
  assert(nonEmptyResult.lines.includes("⚠ 3 events unsent"), `expected the unsent line, got: ${JSON.stringify(nonEmptyResult.lines)}`);
});

function realJournal() {
  return openJournal(pathJoin(mkdtempSync(pathJoin(tmpdir(), "pmdb-")), "j.sqlite"));
}

test("REQ-146: purge without --yes prints count, deletes nothing, exits non-zero", async () => {
  const j = realJournal();
  j.append({ ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "x", author: "pm", portfolio: "carbonet", body: {} });
  j.append({ ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "x", author: "pm", portfolio: "lade", body: {} });
  const deps = baseDeps({ journal: j });

  const result = await main(["purge", "--portfolio", "carbonet"], deps);

  assert.notEqual(result.code, 0, "must exit non-zero without --yes");
  assert.equal(j.events("carbonet").length, 1, "no events deleted without --yes");
  assert.equal(j.events("lade").length, 1, "other portfolio untouched");
  assert(deps.stdoutLines.some((l) => /would delete 1 event/.test(l)), "should print what-would-be-deleted count");
});

test("REQ-146: purge --yes deletes only the named portfolio's events", async () => {
  const j = realJournal();
  j.append({ ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "x", author: "pm", portfolio: "carbonet", body: {} });
  j.append({ ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "x", author: "pm", portfolio: "carbonet", body: {} });
  j.append({ ts: "2026-08-08T12:00:00Z", type: "challenge", subject: "x", author: "pm", portfolio: "lade", body: {} });
  const deps = baseDeps({ journal: j });

  const result = await main(["purge", "--portfolio", "carbonet", "--yes"], deps);

  assert.equal(result.code, 0, "must exit zero on confirmed purge");
  assert.equal(j.events("carbonet").length, 0, "named portfolio's events deleted");
  assert.equal(j.events("lade").length, 1, "other portfolio untouched");
});

// Task 8: deps.journal is the SAME PG-engine-shaped object for every
// command, not just brief/closeout -- events()/purge() are genuinely async
// under the real engine. A fake that actually returns promises (unlike the
// legacy sync SQLite engine used above) proves purge awaits them rather
// than reading .length off a pending Promise.
test("REQ-146: purge against a genuinely async journal — count and delete both await their promises", async () => {
  const events = [{ event_id: "1" }, { event_id: "2" }];
  const purgeCalls = [];
  const asyncJournal = {
    async events(portfolio) {
      return portfolio === "carbonet" ? events : [];
    },
    async purge(portfolio) {
      purgeCalls.push(portfolio);
    }
  };
  const deps = baseDeps({ journal: asyncJournal });

  const dryRun = await main(["purge", "--portfolio", "carbonet"], deps);
  assert.equal(dryRun.count, 2, "count must be the awaited event count, not a pending Promise's .length");

  const confirmed = await main(["purge", "--portfolio", "carbonet", "--yes"], deps);
  assert.equal(confirmed.code, 0);
  assert.deepEqual(purgeCalls, ["carbonet"], "purge() must have been awaited, not fired-and-forgotten");
});

// ---------------------------------------------------------------------------
// REQ-112 — CLI threads the resolved pm matrix cell into challenge prefixes
// (Task 15)
// ---------------------------------------------------------------------------

test("REQ-112: brief with no matrix override resolves the shipped default pm cell -- 'advise:' prefix", async () => {
  const tmp = mkdtempSync(pathJoin(tmpdir(), "pm-brief-matrix-default-"));
  try {
    const repoConfigPath = pathJoin(tmp, "stack-config.json");
    const portfolioConfigPath = pathJoin(tmp, "portfolio.json");
    const portfolioJson = JSON.stringify({ portfolios: { testfolio: { pace: "balanced", members: ["org/repoA"] } } });
    writeFileSync(repoConfigPath, JSON.stringify({}));
    writeFileSync(portfolioConfigPath, portfolioJson);

    const deps = baseDeps({
      // loadConfig() (scope resolution) reads via deps.readFile, the FAKE --
      // the same content must ALSO be registered here, distinct from the
      // real on-disk copy above that loadOverrides() (matrix resolution)
      // reads with its own, un-injected fs calls.
      files: { "/fake/repoA/t1.md": idleTrackFixture("t1", "2026-07-30"), [portfolioConfigPath]: portfolioJson },
      configPath: portfolioConfigPath,
      repoConfigPath,
      portfolioConfigPath,
      glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
    });

    const result = await main(["brief", "--portfolio", "testfolio"], deps);
    assert(
      result.lines.some((l) => l === "  • advise: idle 9d"),
      `expected advise: idle 9d, got: ${JSON.stringify(result.lines)}`
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("REQ-112: brief threads a portfolio matrix override (pm.default.normal -> gate) into an 'insist:' prefix", async () => {
  const tmp = mkdtempSync(pathJoin(tmpdir(), "pm-brief-matrix-gate-"));
  try {
    const repoConfigPath = pathJoin(tmp, "stack-config.json");
    const portfolioConfigPath = pathJoin(tmp, "portfolio.json");
    const portfolioJson = JSON.stringify({
      portfolios: { testfolio: { pace: "balanced", members: ["org/repoA"] } },
      matrix: { pm: { default: { normal: { assertiveness: "gate", autonomy: "decide" } } } }
    });
    writeFileSync(repoConfigPath, JSON.stringify({}));
    writeFileSync(portfolioConfigPath, portfolioJson);

    const deps = baseDeps({
      // See the sibling test above for why portfolioConfigPath's content is
      // registered both on real disk and in this fake readFile map.
      files: { "/fake/repoA/t1.md": idleTrackFixture("t1", "2026-07-30"), [portfolioConfigPath]: portfolioJson },
      configPath: portfolioConfigPath,
      repoConfigPath,
      portfolioConfigPath,
      glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
    });

    const result = await main(["brief", "--portfolio", "testfolio"], deps);
    assert(
      result.lines.some((l) => l === "  • insist: idle 9d"),
      `expected insist: idle 9d, got: ${JSON.stringify(result.lines)}`
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

// REQ-125 (conformance-audit fix): resolveMatrix's OWN {cell, warnings} --
// distinct from the REQ-112 cell test above -- must reach a REAL runBrief
// output as a `Warning:` structural line, not just assembleBrief called
// directly with a hand-built matrixWarnings fixture (that half already
// passed at fixture level; this closes the runtime wiring gap the
// conformance audit found at cli.mjs's old `const { cell } =
// resolveMatrix(...)`, which silently dropped `warnings`).
test("REQ-125: a portfolio override lowering the pm row's shipped gate reaches a real runBrief output as a Warning: line", async () => {
  const tmp = mkdtempSync(pathJoin(tmpdir(), "pm-brief-matrix-warning-"));
  try {
    const repoConfigPath = pathJoin(tmp, "stack-config.json");
    const portfolioConfigPath = pathJoin(tmp, "portfolio.json");
    // pm/default/confidential ships assertiveness: "gate" (config/behavior-
    // matrix.json) -- lowering it to "decide" via a portfolio override is
    // exactly REQ-125's "override lowers a shipped gate dial" trigger.
    const portfolioJson = JSON.stringify({
      portfolios: { testfolio: { pace: "balanced", members: ["org/repoA"] } },
      matrix: { pm: { default: { confidential: { assertiveness: "decide", autonomy: "observe" } } } }
    });
    writeFileSync(repoConfigPath, JSON.stringify({}));
    writeFileSync(portfolioConfigPath, portfolioJson);

    const deps = baseDeps({
      files: { [portfolioConfigPath]: portfolioJson },
      configPath: portfolioConfigPath,
      repoConfigPath,
      portfolioConfigPath,
      glob: async () => ({ "org/repoA": [] })
    });

    const result = await main(["brief", "--portfolio", "testfolio", "--sensitivity", "confidential"], deps);
    assert(result.lines.includes("Warning:"), `expected a Warning: section, got: ${JSON.stringify(result.lines)}`);
    assert(
      result.lines.some((l) => l === "  • pm: assertiveness gate→decide (default/confidential)"),
      `expected the lowered-gate warning line, got: ${JSON.stringify(result.lines)}`
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

// Finding #1 (final fix wave) — cli.mjs's default stack-config.json path used
// to be derived from __dirname (wherever cli.mjs itself lives: the stack
// repo in dev, ~/.claude/tools/pm/src in production), never from the WORKING
// repo pm is actually running against. Every REQ-112/REQ-125 test above
// proves the resolver logic works, but each one injects `repoConfigPath`
// explicitly — none of them exercise the REAL default-path fallback cli.mjs
// takes when a caller (goodmorning, a real terminal invocation) does NOT
// inject one. This test deliberately omits `repoConfigPath` from deps and
// chdirs into a fixture repo instead, proving the default path itself now
// resolves from process.cwd() (mirroring trackFilePath's existing pattern)
// and a repo-authored pm_matrix override actually wins.
test("finding #1: pm brief with no injected repoConfigPath resolves the WORKING repo's .claude/stack-config.json via process.cwd(), not __dirname — a fixture repo's pm_matrix override wins through the real default-path logic", async () => {
  const tmp = mkdtempSync(pathJoin(tmpdir(), "pm-brief-cwd-stack-config-"));
  const originalCwd = process.cwd();
  try {
    const dotClaudeDir = pathJoin(tmp, ".claude");
    mkdirSync(dotClaudeDir);
    const repoConfigPath = pathJoin(dotClaudeDir, "stack-config.json");
    const portfolioConfigPath = pathJoin(tmp, "portfolio.json");
    const portfolioJson = JSON.stringify({ portfolios: { testfolio: { pace: "balanced", members: ["org/repoA"] } } });
    // pm/default/normal ships assertiveness: "recommend" (advise: prefix) --
    // this repo-authored override raises it to "gate" (insist: prefix),
    // exactly REQ-121's top precedence layer.
    writeFileSync(
      repoConfigPath,
      JSON.stringify({ pm_matrix: { pm: { default: { normal: { assertiveness: "gate", autonomy: "decide" } } } } })
    );
    writeFileSync(portfolioConfigPath, portfolioJson);

    process.chdir(tmp);

    const deps = baseDeps({
      files: { "/fake/repoA/t1.md": idleTrackFixture("t1", "2026-07-30"), [portfolioConfigPath]: portfolioJson },
      configPath: portfolioConfigPath,
      portfolioConfigPath,
      // repoConfigPath deliberately OMITTED -- the whole point of this test
      // is that cli.mjs must resolve it itself, from process.cwd(), never
      // from an injected deps override.
      glob: async () => ({ "org/repoA": ["/fake/repoA/t1.md"] })
    });

    const result = await main(["brief", "--portfolio", "testfolio"], deps);
    assert(
      result.lines.some((l) => l === "  • insist: idle 9d"),
      `expected insist: idle 9d (repo pm_matrix override resolved via process.cwd()), got: ${JSON.stringify(result.lines)}`
    );
  } finally {
    process.chdir(originalCwd);
    rmSync(tmp, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// REQ-113 — `pm override` command + brief-side suppression, end to end
// (Task 15)
// ---------------------------------------------------------------------------

test("REQ-113: pm override refused when any required field is missing (portfolio/ref/caller/user), nothing journaled", async () => {
  const full = ["--portfolio", "testfolio", "--ref", "evt-1", "--caller", "ship it", "--user", "not yet"];
  const withoutPair = {
    "--portfolio": ["--ref", "evt-1", "--caller", "ship it", "--user", "not yet"],
    "--ref": ["--portfolio", "testfolio", "--caller", "ship it", "--user", "not yet"],
    "--caller": ["--portfolio", "testfolio", "--ref", "evt-1", "--user", "not yet"],
    "--user": ["--portfolio", "testfolio", "--ref", "evt-1", "--caller", "ship it"]
  };
  assert(full.length > 0, "sanity: full arg list constructed");

  for (const [missingFlag, args] of Object.entries(withoutPair)) {
    const deps = baseDeps();
    const result = await main(["override", ...args], deps);
    assert.equal(result.code, 1, `missing ${missingFlag} should refuse`);
    assert.equal(deps.journal.calls.length, 0, `missing ${missingFlag} should not journal anything`);
  }
});

test("REQ-113: pm override accepted with both positions -- one journal write, positions + ref recorded", async () => {
  const deps = baseDeps();
  const result = await main(
    ["override", "--portfolio", "testfolio", "--ref", "evt-1", "--caller", "ship it", "--user", "not yet, blocked on X"],
    deps
  );
  assert.equal(result.code, 0);
  assert.equal(deps.journal.calls.length, 1);
  const event = deps.journal.calls[0];
  assert.equal(event.type, "override");
  assert.equal(event.ref_event_id, "evt-1");
  assert.deepEqual(event.body.positions, { caller: "ship it", user: "not yet, blocked on X" });
});

test("REQ-113: same-session re-run after an override shows no repeat; different session 25h later re-fires", async () => {
  const files = {
    [CONFIG_PATH]: makeConfig(["org/repoA"]),
    "/fake/repoA/t1.md": idleTrackFixture("t1", "2026-07-30")
  };
  const glob = async () => ({ "org/repoA": ["/fake/repoA/t1.md"] });

  const firstDeps = baseDeps({ files, glob, sessionId: "sess-A" });
  const first = await main(["brief", "--portfolio", "testfolio"], firstDeps);
  assert(first.lines.includes("Challenge:"), "challenge should fire before any override is on record");

  const overrideRow = {
    event_id: "e1",
    ref_event_id: "c1",
    subject_id: "pm",
    session_id: "sess-A",
    ts: "2026-08-08T11:00:00.000Z"
  };
  const suppressedDeps = baseDeps({
    files,
    glob,
    sessionId: "sess-A",
    journal: makeJournal({ recentOverrides: [overrideRow] })
  });
  const suppressed = await main(["brief", "--portfolio", "testfolio"], suppressedDeps);
  assert(!suppressed.lines.includes("Challenge:"), "same-session re-run after an override must show no repeat");
  assert.equal(
    suppressedDeps.journal.briefDataCalls.length,
    1,
    "journal-derived content still comes from exactly one briefData call"
  );

  const refiredDeps = baseDeps({
    files,
    glob,
    nowIso: () => "2026-08-09T13:00:00.000Z",
    sessionId: "sess-B",
    journal: makeJournal({ recentOverrides: [overrideRow] })
  });
  const refired = await main(["brief", "--portfolio", "testfolio"], refiredDeps);
  assert(refired.lines.includes("Challenge:"), "a different session, 25h later, must re-fire the challenge");
});

// ---------------------------------------------------------------------------
// REQ-117 (P1b half) — CLI-authored budget override (Task 15)
// ---------------------------------------------------------------------------

function fifteenTrackFiles() {
  const trackPaths = Array.from({ length: 15 }, (_, i) => `/fake/repoA/t${i}.md`);
  const files = { [CONFIG_PATH]: makeConfig(["org/repoA"]) };
  for (const p of trackPaths) {
    files[p] = trackFixture(p.split("/").pop().replace(".md", ""), "2026-08-08", "state");
  }
  return { files, trackPaths };
}

test("REQ-117: brief --override-budget sets budgetOverride -- line 1 is the reason, >12 lines shipped", async () => {
  const { files, trackPaths } = fifteenTrackFiles();
  const deps = baseDeps({ files, glob: async () => ({ "org/repoA": trackPaths }) });

  const result = await main(["brief", "--portfolio", "testfolio", "--override-budget", "3 thresholds fired"], deps);
  assert.equal(result.lines[0], "budget exceeded: 3 thresholds fired");
  assert(result.lines.length > 12, `expected >12 lines, got ${result.lines.length}`);
});

test("REQ-117: brief without --override-budget stays capped exactly as P1a (regression)", async () => {
  const { files, trackPaths } = fifteenTrackFiles();
  const deps = baseDeps({ files, glob: async () => ({ "org/repoA": trackPaths }) });

  const result = await main(["brief", "--portfolio", "testfolio"], deps);
  assert.equal(result.lines[0], "Brief:");
  assert.equal(result.lines.length, 12);
});

test("REQ-117: agents/pm.md and skills/goodmorning/SKILL.md name the --override-budget flag", () => {
  const pmMd = readFileSync(pathJoin(REPO_ROOT, "agents", "pm.md"), "utf8");
  const goodmorningMd = readFileSync(pathJoin(REPO_ROOT, "skills", "goodmorning", "SKILL.md"), "utf8");
  assert.match(pmMd, /--override-budget/, "agents/pm.md must name the --override-budget flag");
  assert.match(goodmorningMd, /--override-budget/, "goodmorning SKILL.md must name the --override-budget flag");
});
