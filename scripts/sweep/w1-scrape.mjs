#!/usr/bin/env node
// scripts/sweep/w1-scrape.mjs — the read-only control inventory.
//
// W1 proper asserts a declared behaviour per control, which means it needs
// a walk manifest and it clicks things. This does neither. It opens each
// screen, lists every interactive control it can see, flags the ones wired
// to nothing, and can emit a starter manifest in W1's own shape.
//
// It exists for the moment BEFORE a manifest exists — including an app
// whose team already has hand-written browser checks and wants the one
// thing those cannot give them: what the checks never mention. A
// hand-written check list can only ever confirm what someone thought to
// write down; this reads the other side of that comparison off the live
// page.
//
// READ-ONLY IS ENFORCED, NOT INTENDED. Nothing here clicks, types, submits,
// or dispatches an event. A test asserts it by serving a page whose every
// click rewrites the document and checking the rewrite never happened. That
// matters because the natural place to run this is an app where a click can
// reach an outside system.
//
// Usage:
//   w1-scrape.mjs --base <url> --screens </a,/b,...> [--repo <dir>]
//                 [--json] [--emit-manifest] [--storage-state <file>]
//
// --repo is where playwright is resolved from (default: cwd), matching
// W1's rule that the browser is the TARGET repo's dependency, never the
// stack's.
//
// --storage-state points at a saved Playwright session, which is how you
// reach an app that returns 404 to anyone signed out.

import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";

import { INTERACTIVE_ROLES } from "./lib/w1-manifest.mjs";

function fail(msg) {
  process.stderr.write(`w1-scrape: ${msg}\n`);
  process.exit(1);
}

const argv = process.argv.slice(2);
function flag(name) {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? null : (argv[i + 1] ?? "");
}
const has = (name) => argv.includes(`--${name}`);

const base = flag("base");
if (!base) fail("--base <url> is required");

const screensArg = flag("screens");
if (!screensArg) fail("--screens </a,/b> is required — an empty screen list is not an empty result");
const screens = screensArg.split(",").map((s) => s.trim()).filter(Boolean);
if (screens.length === 0) fail("--screens parsed to nothing");

const repoRoot = flag("repo") || process.cwd();
const storageState = flag("storage-state");
const asJson = has("json");
const asManifest = has("emit-manifest");

const require = createRequire(path.join(repoRoot, "/"));
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch (e) {
  fail(`playwright could not be resolved from ${repoRoot} — pass --repo <dir> pointing at a repo that has it installed: ${e.message}`);
}

// Same scrape the W1 driver runs, kept deliberately identical: an
// inventory that disagreed with what W1 later measures would send someone
// chasing a difference in the tools rather than in the app.
async function scrapeControls(page, roles) {
  return page.evaluate((interactiveRoles) => {
    const sel = ["button", "a", ...interactiveRoles.map((r) => `[role="${r}"]`)].join(",");
    const out = [];
    for (const el of document.querySelectorAll(sel)) {
      const name = (el.getAttribute("aria-label") || el.textContent || "").trim();
      if (!name) continue;
      if (el.hasAttribute("data-inert")) {
        out.push({ name, dead: false, inert: true });
        continue;
      }
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
      out.push({ name, dead: !hasHref && !hasInline && !hasListener && !frameworkHandler, inert: false });
    }
    return out;
  }, roles);
}

let browser;
try {
  browser = await chromium.launch();
} catch (e) {
  fail(`chromium could not launch: ${e.message.split("\n")[0]}`);
}

const contextOpts = {};
if (storageState) {
  try {
    JSON.parse(readFileSync(storageState, "utf8"));
    contextOpts.storageState = storageState;
  } catch (e) {
    await browser.close();
    fail(`--storage-state ${storageState} could not be read as a Playwright session: ${e.message}`);
  }
}

const context = await browser.newContext(contextOpts);
const page = await context.newPage();

const result = { base, screens: [] };
let hardFailure = null;

try {
  for (const screen of screens) {
    const url = new URL(screen, base).toString();
    let response;
    try {
      response = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 20000 });
    } catch (e) {
      hardFailure = `${screen}: ${e.message.split("\n")[0]}`;
      break;
    }
    const status = response ? response.status() : 0;
    if (status >= 400) {
      // A signed-out app commonly answers 404 rather than redirecting.
      // Reporting "0 controls" here would be a lie with a number on it.
      hardFailure = `${screen}: HTTP ${status} — if this app hides itself from signed-out visitors, pass --storage-state with a saved session`;
      break;
    }
    const controls = await scrapeControls(page, INTERACTIVE_ROLES);
    result.screens.push({ screen, status, controls });
  }
} finally {
  await browser.close();
}

if (hardFailure) fail(hardFailure);

if (asManifest) {
  // Every control gets `navigates` as a placeholder. It is the weakest of
  // the four verbs and the most likely to be wrong, which is the point: a
  // starter manifest should read as a to-do list, not as a finished
  // declaration somebody might trust.
  const manifest = {
    screens: result.screens.map((s) => ({
      screen: s.screen,
      controls: s.controls
        .filter((c) => !c.inert)
        .map((c) => ({ find: c.name, assert: "navigates" })),
    })).filter((s) => s.controls.length > 0),
  };
  process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
} else if (asJson) {
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
} else {
  for (const s of result.screens) {
    const dead = s.controls.filter((c) => c.dead);
    process.stdout.write(`\n${s.screen} — ${s.controls.length} control(s), ${dead.length} dead\n`);
    for (const c of s.controls) {
      const tag = c.inert ? "inert" : c.dead ? "DEAD" : "ok";
      process.stdout.write(`  [${tag}] ${c.name}\n`);
    }
  }
  const total = result.screens.reduce((n, s) => n + s.controls.length, 0);
  const totalDead = result.screens.reduce((n, s) => n + s.controls.filter((c) => c.dead).length, 0);
  process.stdout.write(`\n${total} control(s) across ${result.screens.length} screen(s), ${totalDead} wired to nothing.\n`);
}
