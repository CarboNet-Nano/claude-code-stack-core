import { test } from "node:test";
import assert from "node:assert/strict";
import { listPmIssues, fileIssue, closeIssue } from "../src/board.mjs";

let execCalls = [];

const fakeExec = (cmd, args) => {
  execCalls.push({ cmd, args });
  if (cmd === "gh" && args[0] === "issue" && args[1] === "list") {
    return Promise.resolve('[]');
  }
  if (cmd === "gh" && args[0] === "issue" && args[1] === "create") {
    return Promise.resolve('{"number": 42}');
  }
  if (cmd === "gh" && args[0] === "issue" && args[1] === "comment") {
    return Promise.resolve('');
  }
  if (cmd === "gh" && args[0] === "issue" && args[1] === "close") {
    return Promise.resolve('');
  }
  return Promise.resolve('');
};

const reset = () => {
  execCalls = [];
};

test("REQ-116: listPmIssues constructs gh issue list with label pm", async () => {
  reset();
  await listPmIssues(fakeExec, ["org/repo1"]);
  assert.equal(execCalls.length, 1);
  assert.equal(execCalls[0].cmd, "gh");
  assert.equal(execCalls[0].args[0], "issue");
  assert.equal(execCalls[0].args[1], "list");
  assert.equal(execCalls[0].args[2], "--repo");
  assert.equal(execCalls[0].args[3], "org/repo1");
  assert(execCalls[0].args.includes("--label"));
  assert(execCalls[0].args.includes("pm"));
  assert(execCalls[0].args.includes("--state"));
  assert(execCalls[0].args.includes("open"));
  assert(execCalls[0].args.includes("--json"));
  assert(execCalls[0].args.includes("number,title,labels"));
});

test("REQ-116: listPmIssues calls gh for each repo", async () => {
  reset();
  await listPmIssues(fakeExec, ["org/repo1", "org/repo2"]);
  assert.equal(execCalls.length, 2);
  assert.equal(execCalls[0].args[3], "org/repo1");
  assert.equal(execCalls[1].args[3], "org/repo2");
});

test("REQ-103: listPmIssues isolates a per-repo gh failure — other repos still returned ok", async () => {
  reset();
  const flakyExec = async (cmd, args) => {
    execCalls.push({ cmd, args });
    const repoIdx = args.indexOf("--repo");
    if (args[repoIdx + 1] === "org/repo2") {
      throw new Error("gh: network error");
    }
    return fakeExec(cmd, args);
  };

  const results = await listPmIssues(flakyExec, ["org/repo1", "org/repo2", "org/repo3"]);

  assert.equal(results.length, 3, "one entry per repo, even the failed one");
  assert.equal(results[0].repo, "org/repo1");
  assert.equal(results[0].ok, true);
  assert.equal(results[1].repo, "org/repo2");
  assert.equal(results[1].ok, false, "failed repo marked ok:false, not thrown");
  assert.match(results[1].error, /network error/);
  assert.equal(results[2].repo, "org/repo3");
  assert.equal(results[2].ok, true, "repo after the failure still attempted and succeeds");
});

test("REQ-104: fileIssue throws 'repo out of portfolio scope' before any exec", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await fileIssue(fakeExec, scope, "org/repo2", { title: "Test", body: "Body", track: "test", source: "review" });
    assert.fail("Should have thrown");
  } catch (e) {
    assert.match(e.message, /repo out of portfolio scope/);
  }
  assert.equal(execCalls.length, 0, "No exec calls should be made for out-of-scope repo");
});

test("REQ-101: closeIssue throws 'closing comment required' on blank comment before any exec", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await closeIssue(fakeExec, scope, "org/repo1", 42, "");
    assert.fail("Should have thrown on blank comment");
  } catch (e) {
    assert.match(e.message, /closing comment required/);
  }
  assert.equal(execCalls.length, 0, "No exec calls should be made with blank comment");
});

test("REQ-104: closeIssue throws 'repo out of portfolio scope' before any exec", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await closeIssue(fakeExec, scope, "org/repo2", 42, "Closing this");
    assert.fail("Should have thrown");
  } catch (e) {
    assert.match(e.message, /repo out of portfolio scope/);
  }
  assert.equal(execCalls.length, 0, "No exec calls should be made for out-of-scope repo");
});

test("REQ-116: fileIssue passes title as SINGLE array element (injection-safe)", async () => {
  reset();
  const scope = ["org/repo1"];
  const hostileTitle = "$(rm -rf ~)";
  await fileIssue(fakeExec, scope, "org/repo1", { title: hostileTitle, body: "Body", track: "cogs", source: "review" });

  assert.equal(execCalls.length, 1);
  const args = execCalls[0].args;
  assert(args.includes(hostileTitle), "Hostile title should arrive as a single intact array element");
  // Verify it's not concatenated or split
  const titleIndex = args.indexOf(hostileTitle);
  assert.equal(titleIndex, args.indexOf("--title") + 1, "Title should immediately follow --title flag");
});

test("REQ-101: fileIssue requires valid source from enum", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await fileIssue(fakeExec, scope, "org/repo1", { title: "Issue", body: "Body", track: "test", source: "invalid" });
    assert.fail("Should have thrown on invalid source");
  } catch (e) {
    assert.match(e.message, /source must be one of/);
  }
  assert.equal(execCalls.length, 0);
});

test("REQ-101: fileIssue validates track format", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await fileIssue(fakeExec, scope, "org/repo1", { title: "Issue", body: "Body", track: "Test_Invalid", source: "review" });
    assert.fail("Should have thrown on invalid track");
  } catch (e) {
    assert.match(e.message, /track must match/);
  }
  assert.equal(execCalls.length, 0);
});

test("REQ-101: fileIssue includes all three labels (pm, track, source)", async () => {
  reset();
  const scope = ["org/repo1"];
  await fileIssue(fakeExec, scope, "org/repo1", { title: "Issue", body: "Body", track: "cogs", source: "audit" });

  const args = execCalls[0].args;
  assert(args.includes("--label"), "Should have --label flag");
  assert(args.includes("pm"), "Should include pm label");
  assert(args.includes("track:cogs"), "Should include track label");
  assert(args.includes("source:audit"), "Should include source label");
});

test("REQ-103: fileIssue labels match what listPmIssues filters on", async () => {
  reset();
  const scope = ["org/repo1"];
  await fileIssue(fakeExec, scope, "org/repo1", { title: "Issue", body: "Body", track: "alpha", source: "human" });

  const fileIssueArgs = execCalls[0].args;
  // The fileIssue should use "pm" label
  const pmLabelIdx = fileIssueArgs.indexOf("pm");
  assert(pmLabelIdx > 0, "fileIssue should include pm label");
  assert.equal(fileIssueArgs[pmLabelIdx - 1], "--label", "pm should follow --label flag");

  // Now check that listPmIssues would filter for the same label
  reset();
  await listPmIssues(fakeExec, ["org/repo1"]);
  const listArgs = execCalls[0].args;
  const listPmIdx = listArgs.indexOf("pm");
  assert(listPmIdx > 0, "listPmIssues should filter by pm label");
  assert.equal(listArgs[listPmIdx - 1], "--label", "pm should follow --label in list");
});

test("REQ-116: closeIssue comments then closes with positional number", async () => {
  reset();
  const scope = ["org/repo1"];
  await closeIssue(fakeExec, scope, "org/repo1", 42, "Closing this issue");

  assert.equal(execCalls.length, 2, "Should make 2 calls (comment + close)");

  // First call: comment with positional number
  assert.equal(execCalls[0].args[0], "issue");
  assert.equal(execCalls[0].args[1], "comment");
  assert.equal(execCalls[0].args[2], "42", "Issue number should be positional after comment");
  assert.equal(execCalls[0].args[3], "--repo");
  assert.equal(execCalls[0].args[4], "org/repo1");
  assert(execCalls[0].args.includes("--body"), "Should include --body flag");
  assert(execCalls[0].args.includes("Closing this issue"), "Comment text should be in args");

  // Second call: close with positional number
  assert.equal(execCalls[1].args[0], "issue");
  assert.equal(execCalls[1].args[1], "close");
  assert.equal(execCalls[1].args[2], "42", "Issue number should be positional after close");
  assert.equal(execCalls[1].args[3], "--repo");
  assert.equal(execCalls[1].args[4], "org/repo1");
});

test("REQ-116: fileIssue in-scope succeeds with valid source", async () => {
  reset();
  const scope = ["org/repo1"];
  const result = await fileIssue(fakeExec, scope, "org/repo1", { title: "New Issue", body: "Content", track: "alpha", source: "handoff" });

  assert.equal(execCalls.length, 1);
  assert.equal(execCalls[0].cmd, "gh");
  assert.equal(execCalls[0].args[0], "issue");
  assert.equal(execCalls[0].args[1], "create");
});

test("REQ-116: closeIssue in-scope succeeds with whitespace-only comment treated as blank", async () => {
  reset();
  const scope = ["org/repo1"];
  try {
    await closeIssue(fakeExec, scope, "org/repo1", 42, "   \n  ");
    assert.fail("Should throw on whitespace-only comment");
  } catch (e) {
    assert.match(e.message, /closing comment required/);
  }
  assert.equal(execCalls.length, 0);
});
