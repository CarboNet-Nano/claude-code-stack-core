import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as pathJoin } from "node:path";
import { main } from "../src/cli.mjs";
import { openJournal } from "../src/journal.mjs";

const CONFIG_PATH = "/fake/config/portfolio.json";

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

function makeJournal(counters) {
  const calls = [];
  return {
    calls,
    append(e) {
      calls.push(e);
      return "fake-event-id";
    },
    counters() {
      return counters || { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 };
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
    trackPath: overrides.trackPath
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
