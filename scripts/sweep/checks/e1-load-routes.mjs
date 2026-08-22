#!/usr/bin/env node
// scripts/sweep/checks/e1-load-routes.mjs — E1: does every route load
// without a client-side error? (stack ADR-078, spec S4.6 E1; task 7 of
// the Sweep serial spine). Reproduces audit row #10: SSR HTML returned
// fine, tsc/tests/build all passed, and the page was blank in production
// because the client render threw — the only mechanism that catches this
// is a real browser, so this check drives Playwright's chromium.
//
// Reads sweep-job/v1 on stdin (task 4's contract), reads the route
// universe from `config.route_manifest_cmd` — a command that prints one
// route per line, the adapter seam [RT-9] — resolves the base URL from
// `process.env[config.base_url_env]`, and goes to every non-excluded
// route, failing on any `pageerror`, any uncaught console error, or a
// rendered `[data-error-boundary]` marker. Emits one sweep-result/v1
// envelope as the LAST stdout line, `SWEEP_RESULT:v1 <base64>` (spec
// S5.1). A missing prerequisite (no route_manifest_cmd, no base URL env,
// no Playwright resolvable) never prints a result line: exit non-zero
// with one clear stderr line is the fail-closed contract — the runner
// turns a check that exited without a result line into `error`, never a
// silent pass.
//
// Playwright is resolved from the TARGET repo's node_modules, never from
// this stack repo's — the stack repo carries no package.json and adds no
// new dependency of its own (Karpathy rule 8): `require.resolve('playwright',
// {paths:[repo_root]})`-equivalent, via `createRequire` rooted at
// repo_root. Only reached when there is at least one non-excluded route to
// check — a universe that is entirely excluded (e.g. every route is a
// dynamic segment) needs no browser at all.
//
// `identity_key` is NOT the raw route string. sweep-emit.sh's R1 refuses
// any identity_key containing a run of 4+ consecutive digits — it reads
// as run identity (a year, a build number, a timestamp fragment), not a
// stable finding identity — and a route like /reports/2026 or /v2026
// would trip that verbatim. Same fix shape as b4-merge-run.sh's
// grouped_id(): every 4+ digit run in the route is broken into groups of
// 3 digits joined by a dash (identityKeyForRoute below); every other
// character of the route is untouched, so distinctness and stability
// across reruns are preserved. The RAW, ungrouped route is never lost —
// it is what `what` and `plain` say, and neither is hashed or subject to
// R1 (spec S4.3 [RT-10]: `what` is deliberately excluded from the hash).

import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const CHECK_ID_FALLBACK = "E1";
const NAV_TIMEOUT_MS = 15000;

function fail(msg) {
  process.stderr.write(`e1-load-routes: ${msg}\n`);
  process.exit(1);
}

// identityKeyForRoute <route> -> a deterministic, R1-safe identity_key.
// Every run of 4+ consecutive digits (a year, a build number, ...) is
// broken into groups of 3 joined by a dash; everything else in the route
// is untouched. /reports/2026 -> /reports/202-6. Deterministic, so the
// same route always produces the same identity_key across runs.
function identityKeyForRoute(route) {
  return route.replace(/[0-9]{4,}/g, (run) => {
    const groups = [];
    for (let i = 0; i < run.length; i += 3) groups.push(run.slice(i, i + 3));
    return groups.join("-");
  });
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

const raw = await readStdin();
let job;
try {
  job = JSON.parse(raw);
} catch (e) {
  fail(`could not parse the sweep-job/v1 payload on stdin as JSON: ${e.message}`);
}

const repoRoot = job.repo_root;
const checkId = job.check_id || CHECK_ID_FALLBACK;
const evidenceBasis = job.evidence_basis;
const surface = job.surface;
const config = job.config || {};

if (!repoRoot) fail("the job carries no repo_root");

const routeManifestCmd = typeof config.route_manifest_cmd === "string" ? config.route_manifest_cmd.trim() : "";
if (!routeManifestCmd) {
  fail("config.route_manifest_cmd is missing — E1 has no route-manifest adapter to enumerate its universe [RT-9]");
}

const baseUrlEnvName = config.base_url_env;
if (!baseUrlEnvName) fail("config.base_url_env is missing");

const start = Date.now();

// ---- Universe: one route per line from the adapter seam ----

const manifest = spawnSync(routeManifestCmd, { cwd: repoRoot, shell: true, encoding: "utf8" });
if (manifest.error) {
  fail(`route_manifest_cmd could not be executed: ${manifest.error.message}`);
}
const routes = (manifest.stdout || "")
  .split("\n")
  .map((s) => s.trim())
  .filter((s) => s.length > 0);
const universeSize = routes.length;

// ---- Exclusions: config-declared reasons, then dynamic segments by default ----

const declaredExclusions = new Map();
for (const ex of Array.isArray(config.exclusions) ? config.exclusions : []) {
  if (ex && typeof ex.unit === "string" && typeof ex.reason === "string" && ex.reason.trim().length > 0) {
    declaredExclusions.set(ex.unit, ex.reason);
  }
}

const excluded = [];
const checkedRoutes = [];
for (const route of routes) {
  if (declaredExclusions.has(route)) {
    excluded.push({ unit: route, reason: declaredExclusions.get(route) });
  } else if (route.includes("[") && route.includes("]")) {
    excluded.push({ unit: route, reason: "dynamic segment needs a sample id" });
  } else {
    checkedRoutes.push(route);
  }
}

let findings = [];
const assertionsExecuted = checkedRoutes.length;
let assertionsPassed = assertionsExecuted;

// ---- Only reach for a browser when there is a non-excluded route to check ----

if (checkedRoutes.length > 0) {
  const baseUrl = process.env[baseUrlEnvName];
  if (!baseUrl) {
    fail(`${baseUrlEnvName} is not set — E1 has no base URL to load routes against`);
  }

  const requireFromRepo = createRequire(path.join(repoRoot, "package.json"));
  let playwrightEntry;
  try {
    playwrightEntry = requireFromRepo.resolve("playwright");
  } catch {
    fail(
      `playwright is not resolvable from ${repoRoot}'s node_modules — install it as a devDependency in the ` +
        `target app before enabling E1 (it is the only mechanism that observes a client render, audit row #10)`
    );
  }

  let chromium;
  try {
    const mod = await import(pathToFileURL(playwrightEntry).href);
    chromium = mod.chromium ?? mod.default?.chromium;
  } catch (e) {
    fail(`playwright could not be loaded from ${playwrightEntry}: ${e.message}`);
  }
  if (!chromium) fail(`playwright loaded from ${playwrightEntry} exposes no chromium launcher`);

  let browser;
  try {
    browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
  } catch (e) {
    fail(`chromium failed to launch: ${String(e.message || e).split("\n")[0]}`);
  }

  const page = await browser.newPage();
  let currentErrors = [];
  page.on("pageerror", (err) => currentErrors.push(String(err && err.message ? err.message : err)));
  page.on("console", (msg) => {
    if (msg.type() === "error") currentErrors.push(msg.text());
  });

  const brokenRoutes = [];
  for (const route of checkedRoutes) {
    currentErrors = [];
    const url = new URL(route, baseUrl).toString();
    let navFailed = false;
    try {
      await page.goto(url, { waitUntil: "load", timeout: NAV_TIMEOUT_MS });
    } catch {
      navFailed = true;
    }
    let hasErrorBoundary = false;
    try {
      hasErrorBoundary = (await page.$("[data-error-boundary]")) !== null;
    } catch {
      hasErrorBoundary = false;
    }
    if (navFailed || currentErrors.length > 0 || hasErrorBoundary) {
      brokenRoutes.push(route);
    }
  }

  await browser.close();

  assertionsPassed = assertionsExecuted - brokenRoutes.length;

  const rev = spawnSync("git", ["-C", repoRoot, "rev-parse", "HEAD"], { encoding: "utf8" });
  const commitSha = rev.status === 0 ? rev.stdout.trim() : "";
  if (!commitSha) fail("could not resolve the HEAD commit sha for repo_root — evidence requires one");

  findings = brokenRoutes.map((route) => ({
    identity_key: identityKeyForRoute(route),
    what: `page.goto for route ${route} produced a client-side error before it settled (pageerror, an uncaught console error, or a rendered error-boundary marker)`,
    plain: `The ${route} screen fails to load — a visitor sees a blank or broken page.`,
    mechanism: "CONTRACT DRIFT",
    surface,
    surface_source: "declared",
    found_by: "sweep-family-E",
    evidence: {
      commit: commitSha,
      measurement: {
        statement: "routes that fail to load",
        count: 1,
        denominator: universeSize,
        source: evidenceBasis,
      },
    },
    liveness: { assertions_executed: assertionsExecuted, assertions_passed: assertionsPassed },
    responsible_agent: null,
    roster_action: null,
  }));
}

const durationMs = Date.now() - start;
const status = findings.length > 0 ? "fail" : "pass";

const envelope = {
  schema: "sweep-result/v1",
  check_id: checkId,
  evidence_basis: evidenceBasis,
  surface,
  status,
  universe_size: universeSize,
  excluded,
  assertions_executed: assertionsExecuted,
  assertions_passed: assertionsPassed,
  measurements: [
    {
      statement: "routes that fail to load",
      count: findings.length,
      denominator: universeSize,
      source: evidenceBasis,
    },
  ],
  findings,
  duration_ms: durationMs,
};

process.stdout.write(
  `e1-load-routes: examined ${universeSize} route(s), ${excluded.length} excluded, ${findings.length} broken\n`
);
process.stdout.write(`SWEEP_RESULT:v1 ${Buffer.from(JSON.stringify(envelope)).toString("base64")}\n`);
