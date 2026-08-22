#!/usr/bin/env node
// scripts/sweep/checks/w1-walk-surface.mjs — W1: does every declared
// control actually do what it claims, and is anything rendered wired to
// nothing?
//
// E1 loads a page; W1 interacts with one. That is the whole gap: a
// 90-minute live session found nine defects with 1,994 backend tests, 406
// web tests, CI and the Sweep all green, every one of them living in the
// composed, rendered, interactive page.
//
// STAGING ONLY, never production (spec Decision 2). This check clicks
// things, and in the pilot repo a click can approve a bill, post to an
// accounting system, or email a vendor. The production-reading half of the
// design is D0b, which only ever reads.
//
// Protocol: reads sweep-job/v1 on stdin, emits exactly one
// sweep-result/v1 envelope as the LAST stdout line
// (`SWEEP_RESULT:v1 <base64>`). Every missing prerequisite exits non-zero
// with one stderr line and prints NO result line — the runner turns a
// check that exited without a result line into `error`, never a silent
// pass.
//
// Playwright is resolved from the TARGET repo's node_modules, never this
// stack repo's (Karpathy rule 8: the stack repo carries no package.json
// and adds no dependency of its own), and only when there is at least one
// non-excluded screen to walk — a universe that is entirely excluded needs
// no browser at all.
//
// Spec: docs/superpowers/specs/2026-08-18-sweep-live-observation-design.md

import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

import { parseWalkManifest, identityKeyFor, coverageDiff, INTERACTIVE_ROLES } from "../lib/w1-manifest.mjs";

const CHECK_ID_FALLBACK = "W1";

function fail(msg) {
  process.stderr.write(`w1-walk-surface: ${msg}\n`);
  process.exit(1);
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
const surface = job.surface || "ui-route";
const config = job.config || {};

if (!repoRoot) fail("the job carries no repo_root");

const routeManifestCmd = typeof config.route_manifest_cmd === "string" ? config.route_manifest_cmd.trim() : "";
if (!routeManifestCmd) {
  fail("config.route_manifest_cmd is missing — W1 has no route-manifest adapter to enumerate its universe [RT-9]");
}

const baseUrlEnvName = config.base_url_env;
if (!baseUrlEnvName) fail("config.base_url_env is missing");
const baseUrl = process.env[baseUrlEnvName];
if (!baseUrl) {
  fail(`config.base_url_env names ${baseUrlEnvName}, but that environment variable is empty — W1 walks a deployed staging app and has nothing to walk`);
}

const walkManifestPath = config.walk_manifest;
if (!walkManifestPath) {
  fail("config.walk_manifest is missing — W1 has no declared controls to assert against");
}

let manifest;
try {
  manifest = parseWalkManifest(readFileSync(path.join(repoRoot, walkManifestPath), "utf8"));
} catch (e) {
  fail(`${walkManifestPath}: ${e.message}`);
}

const start = Date.now();

// ---- Universe: the manifest's screens, intersected with the adapter ----

const routeOut = spawnSync(routeManifestCmd, { cwd: repoRoot, shell: true, encoding: "utf8" });
if (routeOut.error) fail(`route_manifest_cmd could not be executed: ${routeOut.error.message}`);
const liveRoutes = new Set(
  (routeOut.stdout || "").split("\n").map((s) => s.trim()).filter((s) => s.length > 0)
);

const declaredExclusions = new Map();
for (const ex of Array.isArray(config.exclusions) ? config.exclusions : []) {
  if (ex && typeof ex.unit === "string" && typeof ex.reason === "string" && ex.reason.trim().length > 0) {
    declaredExclusions.set(ex.unit, ex.reason);
  }
}

const universeSize = manifest.screens.length;
const excluded = [];
const screensToWalk = [];
for (const s of manifest.screens) {
  if (declaredExclusions.has(s.screen)) {
    excluded.push({ unit: s.screen, reason: declaredExclusions.get(s.screen) });
  } else if (!liveRoutes.has(s.screen)) {
    excluded.push({ unit: s.screen, reason: "declared in the walk manifest but absent from the route adapter's output" });
  } else {
    screensToWalk.push(s);
  }
}

const VERB_TIMEOUT_MS = 5000;
// How far an opened surface may sit from its anchor before it reads as
// "thrown across the screen" rather than "adjacent to it" (AP #212).
const ADJACENCY_TOLERANCE_PX = 400;
// A surface shorter than this cannot be showing its content — AP #209's
// dropdown was clipped to a 1.5-row sliver by an ancestor's overflow.
const MIN_OPENED_HEIGHT_PX = 24;

// runAssertion <page> <verb> <findText> -> { ok, detail }
//
// Never throws. A Playwright error (a control that never renders, a
// timeout) becomes a FAILED assertion carrying its own message, so one bad
// control cannot abort the whole walk and cannot vanish silently either.
//
// Geometry is measured, not eyeballed. A screenshot baseline would also
// catch the layout classes, but it needs an approved-image store and goes
// stale on every unrelated style change; a bounding-box comparison is
// deterministic and needs neither.
// visibleRect <page> <selector> -> the element's rect INTERSECTED with every
// clipping ancestor, i.e. what a person can actually see.
//
// Playwright's boundingBox() reports the element's own geometry and knows
// nothing about an ancestor's overflow. AP #209 was a dropdown clipped to a
// 1.5-row sliver by exactly that: its own box was full height while the
// visible height was ~18px. Measuring boundingBox alone would miss the
// defect this verb exists to catch, so the intersection is computed in the
// page instead.
async function visibleRect(page, selector) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    let top = r.top, bottom = r.bottom, left = r.left, right = r.right;
    for (let a = el.parentElement; a; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.overflow !== "visible" || cs.overflowX !== "visible" || cs.overflowY !== "visible") {
        const ar = a.getBoundingClientRect();
        top = Math.max(top, ar.top);
        bottom = Math.min(bottom, ar.bottom);
        left = Math.max(left, ar.left);
        right = Math.min(right, ar.right);
      }
    }
    return {
      x: r.x,
      y: r.y,
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top),
      ownHeight: r.height,
    };
  }, selector);
}

async function runAssertion(page, verb, findText) {
  try {
    const control = page.getByText(findText, { exact: false }).first();
    await control.waitFor({ timeout: VERB_TIMEOUT_MS });

    if (verb === "navigates") {
      const before = page.url() + "|" + (await page.evaluate(() => document.body.innerHTML));
      await control.click({ timeout: VERB_TIMEOUT_MS });
      await page.waitForTimeout(250);
      const after = page.url() + "|" + (await page.evaluate(() => document.body.innerHTML));
      return before === after
        ? { ok: false, detail: "activating it changed neither the URL nor the rendered page" }
        : { ok: true, detail: "" };
    }

    if (verb === "opens-menu-adjacent-to-anchor") {
      const anchorBox = await control.boundingBox();
      await control.click({ timeout: VERB_TIMEOUT_MS });
      await page.waitForTimeout(250);
      const openedBox = await visibleRect(page, '[role="menu"], [role="listbox"]');
      if (!openedBox) return { ok: false, detail: "no menu or listbox became visible after activation" };
      if (openedBox.height < MIN_OPENED_HEIGHT_PX) {
        return {
          ok: false,
          detail: `the opened surface is ${Math.round(openedBox.ownHeight)}px tall but only ${Math.round(openedBox.height)}px of it is visible — an ancestor is clipping it`,
        };
      }
      if (!anchorBox) return { ok: false, detail: "the anchor control has no box to measure against" };
      const dx = Math.abs(openedBox.x - anchorBox.x);
      const dy = Math.abs(openedBox.y - anchorBox.y);
      if (dx > ADJACENCY_TOLERANCE_PX || dy > ADJACENCY_TOLERANCE_PX) {
        return { ok: false, detail: `the opened surface sits ${Math.round(dx)}px across and ${Math.round(dy)}px down from its anchor` };
      }
      const viewport = page.viewportSize();
      if (viewport && (openedBox.x < 0 || openedBox.y < 0 || openedBox.x > viewport.width || openedBox.y > viewport.height)) {
        return { ok: false, detail: "the opened surface is positioned outside the viewport" };
      }
      return { ok: true, detail: "" };
    }

    if (verb === "shows-pending") {
      await control.click({ timeout: VERB_TIMEOUT_MS });
      const busy = await page.evaluate(() =>
        Boolean(document.querySelector('[aria-busy="true"], [data-pending], [role="progressbar"], button[disabled], [aria-disabled="true"]'))
      );
      return busy
        ? { ok: true, detail: "" }
        : { ok: false, detail: "no busy, disabled, or progress state appeared while the effect was in flight" };
    }

    if (verb === "persists-after-reload") {
      const snapshot = () => page.evaluate(() =>
        [...document.querySelectorAll("input, textarea, select")].map((e) => e.value).join("")
      );
      const before = await snapshot();
      await control.click({ timeout: VERB_TIMEOUT_MS });
      await page.waitForTimeout(250);
      const afterClick = await snapshot();
      if (afterClick === before) {
        return { ok: false, detail: "activating it changed no field value, so there was nothing to persist" };
      }
      await page.reload({ waitUntil: "domcontentloaded" });
      await page.waitForTimeout(250);
      const afterReload = await snapshot();
      return afterReload === afterClick
        ? { ok: true, detail: "" }
        : { ok: false, detail: "the change did not survive a reload — the save reverted silently" };
    }

    // parseWalkManifest already refuses unknown verbs, so reaching here
    // means the closed list and this switch have drifted apart.
    return { ok: false, detail: `no implementation for verb ${verb}` };
  } catch (e) {
    return { ok: false, detail: e.message.split("\n")[0] };
  }
}

// scrapeControls <page> <roles> -> { names, dead }
//
// Runs inside the page so it sees the LIVE DOM, not the served HTML: a
// control wired up by client-side JavaScript is indistinguishable from a
// dead one in the source, which is the whole reason E1 and W1 drive a real
// browser at all.
//
// `names` is the coverage denominator (spec Decision 4). `dead` is the
// AP #217 class: rendered, styled, wired to nothing. A control escapes the
// dead list by having a bound handler, a usable href, or an explicit
// data-inert annotation stating it is deliberately inert — the annotation
// is how a decorative element opts out, visibly and in the repo's own
// source rather than by the checker guessing.
async function scrapeControls(page, roles) {
  return page.evaluate((interactiveRoles) => {
    const sel = ["button", "a", ...interactiveRoles.map((r) => `[role="${r}"]`)].join(",");
    const names = [];
    const dead = [];
    for (const el of document.querySelectorAll(sel)) {
      const name = (el.getAttribute("aria-label") || el.textContent || "").trim();
      if (!name) continue;
      names.push(name);
      if (el.hasAttribute("data-inert")) continue;
      const href = el.getAttribute("href");
      const hasHref = href !== null && href !== "" && href !== "#";
      const hasInline = el.hasAttribute("onclick");
      const hasListener = typeof el.onclick === "function";
      // A handler can be attached four ways, and missing any one of them
      // turns this check into a false-positive machine:
      //   1. an inline onclick attribute
      //   2. an assigned el.onclick
      //   3. a usable href (links)
      //   4. a FRAMEWORK handler. React attaches listeners at the root
      //      container and never on the element, so el.onclick is null for
      //      every React button ever rendered. React 17+ hangs the real
      //      props off a `__reactProps$<hash>` key on the DOM node; Vue
      //      leaves `__vnode`/`_vei`. Without this branch, running the
      //      inventory against any React app reports the entire UI dead.
      const frameworkHandler = Object.keys(el).some((k) => {
        if (k.startsWith("__reactProps$") || k.startsWith("__reactEventHandlers$")) {
          const p = el[k];
          return Boolean(p && (p.onClick || p.onMouseDown || p.onKeyDown || p.onChange));
        }
        if (k === "__vnode" || k === "_vei") return true;
        return false;
      });
      if (!hasHref && !hasInline && !hasListener && !frameworkHandler) dead.push(name);
    }
    return { names, dead };
  }, roles);
}

const findings = [];
let assertionsExecuted = 0;
let assertionsPassed = 0;
let coverage = { declared: 0, discovered: 0, undeclared: [] };

if (screensToWalk.length > 0) {
  const require = createRequire(path.join(repoRoot, "/"));
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch (e) {
    fail(`playwright could not be resolved from ${repoRoot} — W1 needs it installed in the TARGET repo, never in the stack repo: ${e.message}`);
  }

  let browser;
  try {
    browser = await chromium.launch();
  } catch (e) {
    fail(`chromium could not launch: ${e.message.split("\n")[0]}`);
  }
  const page = await browser.newPage();

  const allDeclared = [];
  const allDiscovered = [];
  const deadControls = [];

  try {
    for (const s of screensToWalk) {
      await page.goto(new URL(s.screen, baseUrl).toString(), { waitUntil: "domcontentloaded" });
      const scraped = await scrapeControls(page, INTERACTIVE_ROLES);
      allDiscovered.push(...scraped.names);
      for (const name of scraped.dead) deadControls.push({ screen: s.screen, name });
      for (const c of s.controls) {
        allDeclared.push(c.find);
        assertionsExecuted += 1;
        const verdict = await runAssertion(page, c.assert, c.find);
        if (verdict.ok) {
          assertionsPassed += 1;
        } else {
          findings.push({
            identity_key: identityKeyFor(s.screen, c.find),
            what: `the control "${c.find}" on ${s.screen} failed its declared assertion "${c.assert}": ${verdict.detail}`,
            plain: `The "${c.find}" control on this screen does not behave the way it is meant to.`,
            mechanism: "CONTRACT DRIFT",
            surface,
            surface_source: "declared",
            found_by: "sweep-family-E",
            evidence: {
              commit: "",
              measurement: {
                statement: "declared controls that fail their assertion",
                count: 1,
                denominator: 0,
                source: evidenceBasis,
              },
            },
            liveness: { assertions_executed: 0, assertions_passed: 0 },
            responsible_agent: null,
            roster_action: null,
          });
        }
        // Each verb leaves the page in whatever state it produced; the
        // next control must start from the place the manifest describes,
        // or assertions would depend on their neighbours.
        await page.goto(new URL(s.screen, baseUrl).toString(), { waitUntil: "domcontentloaded" });
      }
    }
  } finally {
    await browser.close();
  }

  coverage = coverageDiff(allDeclared, allDiscovered);

  // Liveness and the denominator are only knowable once the walk is over,
  // so they are stamped onto every finding here rather than guessed
  // mid-loop. A finding carrying zeroes would read as a vacuous check.
  for (const f of findings) {
    f.liveness = { assertions_executed: assertionsExecuted, assertions_passed: assertionsPassed };
    if (f.evidence.measurement.denominator === 0) f.evidence.measurement.denominator = assertionsExecuted;
  }

  for (const { screen, name } of deadControls) {
    findings.push({
      identity_key: identityKeyFor(screen, name),
      what: `the control "${name}" on ${screen} renders but has no bound handler, no usable href, and no data-inert annotation`,
      plain: `The "${name}" button does nothing when you click it.`,
      mechanism: "DISCONNECTED",
      surface,
      surface_source: "declared",
      found_by: "sweep-family-E",
      evidence: {
        commit: "",
        measurement: {
          statement: "rendered controls wired to nothing",
          count: 1,
          denominator: coverage.discovered,
          source: evidenceBasis,
        },
      },
      liveness: { assertions_executed: 0, assertions_passed: 0 },
      responsible_agent: null,
      roster_action: null,
    });
  }
}

const rev = spawnSync("git", ["-C", repoRoot, "rev-parse", "HEAD"], { encoding: "utf8" });
const commitSha = rev.status === 0 ? rev.stdout.trim() : "";
if (!commitSha) fail("could not resolve the HEAD commit sha for repo_root — evidence requires one");
for (const f of findings) f.evidence.commit = commitSha;

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
      statement: "declared controls that fail their assertion",
      count: findings.filter((f) => f.mechanism === "CONTRACT DRIFT").length,
      denominator: assertionsExecuted,
      source: evidenceBasis,
    },
    {
      statement: "rendered controls absent from the walk manifest",
      count: coverage.undeclared.length,
      denominator: coverage.discovered,
      source: evidenceBasis,
    },
  ],
  findings,
  duration_ms: durationMs,
};

process.stdout.write(
  `w1-walk-surface: ${universeSize} screen(s) declared, ${excluded.length} excluded, ${findings.length} finding(s)\n`
);
process.stdout.write(`SWEEP_RESULT:v1 ${Buffer.from(JSON.stringify(envelope)).toString("base64")}\n`);
