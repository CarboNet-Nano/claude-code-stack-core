import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveCheckoutRoot, createGlob } from "../bin.mjs";

// ASSUMPTION 5 -- checkout_root precedence: env PM_CHECKOUT_ROOT wins over
// config/portfolio.json's per-portfolio checkout_root, which wins over the
// flat-layout default. Importing bin.mjs here must not resolve real
// credentials or run a command -- its side-effecting execution is behind an
// `import.meta.url === file://process.argv[1]` guard (see bin.mjs), so this
// import is inert.

const CONFIG_PATH = "/fake/config/portfolio.json";
const DEFAULT_ROOT = "/fake/default/Antigravity";

function makeReadFile(files) {
  return async (p) => {
    if (!(p in files)) throw new Error(`ENOENT: ${p}`);
    return files[p];
  };
}

test("ASSUMPTION 5: resolveCheckoutRoot falls back to the default when no config and no env are present", async () => {
  const root = await resolveCheckoutRoot("carbonet", {
    env: {},
    readFileImpl: makeReadFile({}),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT
  });
  assert.equal(root, DEFAULT_ROOT);
});

test("ASSUMPTION 5: resolveCheckoutRoot uses config/portfolio.json's per-portfolio checkout_root when present", async () => {
  const config = JSON.stringify({ portfolios: { carbonet: { checkout_root: "/custom/config-root" } } });
  const root = await resolveCheckoutRoot("carbonet", {
    env: {},
    readFileImpl: makeReadFile({ [CONFIG_PATH]: config }),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT
  });
  assert.equal(root, "/custom/config-root");
});

test("ASSUMPTION 5: PM_CHECKOUT_ROOT env wins over config/portfolio.json's checkout_root", async () => {
  const config = JSON.stringify({ portfolios: { carbonet: { checkout_root: "/custom/config-root" } } });
  const root = await resolveCheckoutRoot("carbonet", {
    env: { PM_CHECKOUT_ROOT: "/env/wins" },
    readFileImpl: makeReadFile({ [CONFIG_PATH]: config }),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT
  });
  assert.equal(root, "/env/wins");
});

test("ASSUMPTION 5: a portfolio absent from config, or config unreadable, falls back to default (never brick)", async () => {
  const config = JSON.stringify({ portfolios: { other: { checkout_root: "/not-this-one" } } });
  const root = await resolveCheckoutRoot("carbonet", {
    env: {},
    readFileImpl: makeReadFile({ [CONFIG_PATH]: config }),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT
  });
  assert.equal(root, DEFAULT_ROOT);

  const rootUnreadable = await resolveCheckoutRoot("carbonet", {
    env: {},
    readFileImpl: makeReadFile({}),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT
  });
  assert.equal(rootUnreadable, DEFAULT_ROOT);
});

test("ASSUMPTION 5: a leading ~/ in config's checkout_root or env expands against home", async () => {
  const config = JSON.stringify({ portfolios: { carbonet: { checkout_root: "~/Antigravity" } } });
  const rootFromConfig = await resolveCheckoutRoot("carbonet", {
    env: {},
    readFileImpl: makeReadFile({ [CONFIG_PATH]: config }),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT,
    home: "/Users/fake"
  });
  assert.equal(rootFromConfig, "/Users/fake/Antigravity");

  const rootFromEnv = await resolveCheckoutRoot("carbonet", {
    env: { PM_CHECKOUT_ROOT: "~/CustomRoot" },
    readFileImpl: makeReadFile({}),
    configPath: CONFIG_PATH,
    defaultRoot: DEFAULT_ROOT,
    home: "/Users/fake"
  });
  assert.equal(rootFromEnv, "/Users/fake/CustomRoot");
});

test("ASSUMPTION 5: createGlob's glob() reads track files under <resolved checkout_root>/<repo-basename>/.claude/tracks", async () => {
  const readdirCalls = [];
  const readdirImpl = async (dir) => {
    readdirCalls.push(dir);
    return ["t1.md", "notes.txt"];
  };
  const resolveCheckoutRootImpl = async (portfolioName) => {
    assert.equal(portfolioName, "carbonet");
    return "/resolved/root";
  };

  const glob = createGlob({ readdirImpl, resolveCheckoutRootImpl });
  const result = await glob(["org/repoA"], "carbonet");

  assert.deepEqual(readdirCalls, ["/resolved/root/repoA/.claude/tracks"]);
  assert.deepEqual(result, { "org/repoA": ["/resolved/root/repoA/.claude/tracks/t1.md"] });
});

test("ASSUMPTION 5: createGlob's glob() returns an empty list for a repo whose tracks dir doesn't exist (never throws)", async () => {
  const readdirImpl = async () => {
    throw new Error("ENOENT");
  };
  const glob = createGlob({ readdirImpl, resolveCheckoutRootImpl: async () => "/resolved/root" });
  const result = await glob(["org/missing"], "carbonet");
  assert.deepEqual(result, { "org/missing": [] });
});
