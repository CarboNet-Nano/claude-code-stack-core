import { test } from "node:test";
import assert from "node:assert/strict";
import { collectSpend } from "../src/spend.mjs";
import { challenges } from "../src/brief.mjs";

const COST_LOG_PATH = "/fake/logs/cost-log.jsonl";

function makeReadFile(files) {
  return async (p) => {
    if (!(p in files)) throw new Error(`ENOENT: ${p}`);
    return files[p];
  };
}

// REQ-111 amendment / ASSUMPTION 3 -- the spend-source contract:
// estimate from track frontmatter `budget_usd`, actual summed from
// cost-log rows carrying {cost_usd, track}. Either side missing -> the
// track is silently omitted (no fabricated data). A malformed cost-log
// line never throws; it is skipped and reported via `warnings`.

test("REQ-111 amendment: collectSpend pairs budget_usd estimate with summed cost-log actual", async () => {
  const tracks = [{ track: "t1", budget_usd: 10 }];
  const costLog = [
    { cost_usd: 15, track: "t1" },
    { cost_usd: 10, track: "t1" }
  ]
    .map((r) => JSON.stringify(r))
    .join("\n");

  const result = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH
  });

  assert.deepEqual(result, [{ track: "t1", estimate: 10, actual: 25 }]);
});

test("REQ-111 amendment: collectSpend output reaches challenges() and fires the 2.5x threshold", async () => {
  const tracks = [{ track: "t1", budget_usd: 10, updated: "2026-08-08" }];
  const costLog = [
    { cost_usd: 15, track: "t1" },
    { cost_usd: 10, track: "t1" }
  ]
    .map((r) => JSON.stringify(r))
    .join("\n");

  const spend = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH
  });

  const result = challenges({ tracks, counters: {}, spend }, "2026-08-08");
  assert(result.some((c) => /t1 at 2\.5× its estimate/.test(c)), `expected a 2.5x spend challenge, got: ${JSON.stringify(result)}`);
});

test("REQ-111 amendment: a track with no budget_usd is omitted, even with matching cost-log rows", async () => {
  const tracks = [{ track: "t1" }];
  const costLog = JSON.stringify({ cost_usd: 999, track: "t1" });

  const result = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH
  });

  assert.deepEqual(result, []);
});

test("REQ-111 amendment: a track with budget_usd but no matching cost-log rows is omitted", async () => {
  const tracks = [{ track: "t1", budget_usd: 10 }, { track: "t2", budget_usd: 5 }];
  const costLog = JSON.stringify({ cost_usd: 20, track: "t2" });

  const result = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH
  });

  assert.deepEqual(result, [{ track: "t2", estimate: 5, actual: 20 }]);
});

test("REQ-111 amendment: cost-log rows missing cost_usd or track are ignored, not counted", async () => {
  const tracks = [{ track: "t1", budget_usd: 10 }];
  const costLog = [
    { cost_usd: 5, track: "t1" },
    { track: "t1" }, // missing cost_usd
    { cost_usd: 5 }, // missing track
    { cost_usd: 5, track: "t1" }
  ]
    .map((r) => JSON.stringify(r))
    .join("\n");

  const result = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH
  });

  assert.deepEqual(result, [{ track: "t1", estimate: 10, actual: 10 }]);
});

test("REQ-111 amendment: a malformed cost-log line is skipped with a warning, never throws", async () => {
  const tracks = [{ track: "t1", budget_usd: 10 }];
  const costLog = ["{not valid json", JSON.stringify({ cost_usd: 25, track: "t1" }), ""].join("\n");
  const warnings = [];

  const result = await collectSpend({
    readFile: makeReadFile({ [COST_LOG_PATH]: costLog }),
    tracks,
    costLogPath: COST_LOG_PATH,
    warnings
  });

  assert.deepEqual(result, [{ track: "t1", estimate: 10, actual: 25 }]);
  assert(warnings.some((w) => /malformed/i.test(w)), `expected a malformed-line warning, got: ${JSON.stringify(warnings)}`);
});

test("REQ-111 amendment: an unreadable cost-log file warns and returns [], never throws", async () => {
  const tracks = [{ track: "t1", budget_usd: 10 }];
  const warnings = [];

  const result = await collectSpend({
    readFile: makeReadFile({}),
    tracks,
    costLogPath: COST_LOG_PATH,
    warnings
  });

  assert.deepEqual(result, []);
  assert(warnings.some((w) => /cost-log unreadable/.test(w)));
});

test("REQ-111 amendment: no track declares budget_usd -> cost-log is never even read", async () => {
  const tracks = [{ track: "t1" }, { track: "t2" }];
  let readCalled = false;
  const readFile = async () => {
    readCalled = true;
    return "";
  };

  const result = await collectSpend({ readFile, tracks, costLogPath: COST_LOG_PATH });

  assert.deepEqual(result, []);
  assert.equal(readCalled, false, "collectSpend must not read the cost-log when no track has an estimate");
});
