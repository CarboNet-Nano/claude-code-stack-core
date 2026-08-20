import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { main } from "../src/cli.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..", "..", "..");
const SKILL_PATH = join(REPO_ROOT, "skills", "foreman", "SKILL.md");

// ---------------------------------------------------------------------------
// REQ-122 — one resolver, two consumers (foreman dispatch, PM challenge
// level / Task 15). This file covers foreman's half: the skill text names
// the resolver command and the resolved dial names, and the CLI subcommand
// it names actually behaves per the accept criteria.
// ---------------------------------------------------------------------------

test("REQ-122: skills/foreman/SKILL.md names the matrix resolver command and the assertiveness/autonomy dials, never 'conviction'", () => {
  const text = readFileSync(SKILL_PATH, "utf8");
  assert.match(text, /matrix resolve/, "skill must name the resolver subcommand");
  assert.match(text, /pm\/bin\.mjs/, "skill must name the pm CLI entry point it invokes");
  assert.match(text, /assertiveness/, "skill must use the 'assertiveness' dial name");
  assert.match(text, /autonomy/, "skill must use the 'autonomy' dial name");
  assert.doesNotMatch(text.toLowerCase(), /conviction/, "the word 'conviction' must never appear in the skill");
});

test("REQ-122: skills/foreman/SKILL.md names a fallback for a failing resolver COMMAND (not just a bad input value), so dispatch never stalls on a broken environment", () => {
  const text = readFileSync(SKILL_PATH, "utf8");
  assert.match(
    text,
    /resolver.*(fails|unavailable)/i,
    "skill must address the resolver command itself failing (missing bin.mjs, unreadable config, non-zero exit)"
  );
  assert.match(
    text,
    /\{assertiveness:\s*recommend,\s*autonomy:\s*decide-with-review\}/,
    "skill must name the sane default cell to fall back to on resolver failure"
  );
});

function makeCliDeps({ repoConfigPath, portfolioConfigPath } = {}) {
  const stdoutLines = [];
  return {
    stdout: (line) => stdoutLines.push(line),
    stdoutLines,
    repoConfigPath,
    portfolioConfigPath
  };
}

test("CLI: pm matrix resolve — known agent/context prints {cell, warnings} JSON, exit 0", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "foreman-matrix-resolve-"));
  try {
    const repoConfigPath = join(tmp, "stack-config.json");
    const portfolioConfigPath = join(tmp, "portfolio.json");
    writeFileSync(repoConfigPath, JSON.stringify({}));
    writeFileSync(portfolioConfigPath, JSON.stringify({ portfolios: {} }));

    const deps = makeCliDeps({ repoConfigPath, portfolioConfigPath });
    const result = await main(
      ["matrix", "resolve", "--agent", "implementer", "--domain", "financial-code", "--sensitivity", "normal"],
      deps
    );

    assert.equal(result.code, 0);
    assert.deepEqual(result.cell, { assertiveness: "gate", autonomy: "decide-with-review" });
    assert.deepEqual(result.warnings, []);

    assert.equal(deps.stdoutLines.length, 1);
    const printed = JSON.parse(deps.stdoutLines[0]);
    assert.deepEqual(printed, { cell: { assertiveness: "gate", autonomy: "decide-with-review" }, warnings: [] });
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("CLI: pm matrix resolve — unknown agent falls back to the default row, exit 0 (dispatch must never brick)", async () => {
  const deps = makeCliDeps();
  const result = await main(
    ["matrix", "resolve", "--agent", "totally-unknown-agent-xyz", "--domain", "default", "--sensitivity", "normal"],
    deps
  );

  assert.equal(result.code, 0, "an unknown agent must never fail the resolve — dispatch cannot brick on a bad name");
  assert.deepEqual(result.cell, { assertiveness: "recommend", autonomy: "decide-with-review" });
  const printed = JSON.parse(deps.stdoutLines[0]);
  assert.deepEqual(printed.cell, { assertiveness: "recommend", autonomy: "decide-with-review" });
});

test("CLI: pm matrix resolve — unknown domain/sensitivity normalize to default/normal instead of erroring", async () => {
  const deps = makeCliDeps();
  const result = await main(
    ["matrix", "resolve", "--agent", "implementer", "--domain", "not-a-real-mode", "--sensitivity", "not-a-real-level"],
    deps
  );

  assert.equal(result.code, 0);
  assert.deepEqual(result.cell, { assertiveness: "recommend", autonomy: "decide-with-review" });
});

test("CLI: pm matrix resolve — missing --agent refused with code 1", async () => {
  const deps = makeCliDeps();
  const result = await main(["matrix", "resolve"], deps);
  assert.equal(result.code, 1);
  assert.ok(deps.stdoutLines.some((l) => l.includes("--agent")));
});
