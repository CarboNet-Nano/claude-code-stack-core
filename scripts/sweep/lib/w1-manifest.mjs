// scripts/sweep/lib/w1-manifest.mjs — W1's pure layer: the closed
// assertion-verb list, walk-manifest parsing, and R1-safe identity keys.
//
// Deliberately browser-free. Every rule that can be decided without a
// rendered page lives here, so it is testable on any machine — including
// one where chromium cannot launch. The driver
// (scripts/sweep/checks/w1-walk-surface.mjs) imports this and adds the DOM
// work; only the four verbs and the control scrape need Playwright.
//
// Spec: docs/superpowers/specs/2026-08-18-sweep-live-observation-design.md

// The verb list is CLOSED. A manifest naming a verb that is not here is a
// config error, not a skipped control: silently ignoring an unrecognised
// verb would let a typo read as coverage. Frozen so a caller cannot widen
// it at runtime and route around that refusal.
export const ASSERTION_VERBS = Object.freeze([
  "navigates",
  "opens-menu-adjacent-to-anchor",
  "shows-pending",
  "persists-after-reload",
]);

// identityKeyFor <screen> <find> -> a deterministic, R1-safe identity_key.
//
// sweep-emit.sh's R1 refuses any identity_key containing a run of 4+
// consecutive digits — such a run reads as RUN identity (a year, a build
// number, a timestamp fragment) rather than FINDING identity, and a screen
// path like /reports/2026 or a control named "Order 12345" would trip it
// verbatim. Every such run is broken into groups of 3 joined by a dash;
// every other character is untouched, so distinctness and stability across
// reruns both survive. Same shape as e1-load-routes.mjs's
// identityKeyForRoute and b4-merge-run.sh's grouped_id().
//
// The RAW screen and control text are never lost: they are what `what` and
// `plain` say, and neither is hashed or subject to R1 (spec S4.3 [RT-10]).
export function identityKeyFor(screen, find) {
  return `${screen}#${find}`.replace(/[0-9]{4,}/g, (run) => {
    const groups = [];
    for (let i = 0; i < run.length; i += 3) groups.push(run.slice(i, i + 3));
    return groups.join("-");
  });
}

// parseWalkManifest <text> -> { screens: [{ screen, controls: [{find, assert}] }] }
//
// Throws on anything malformed. Every refusal here is a case where the
// alternative would be an empty or partial universe reported as a pass —
// the failure mode the whole Sweep exists to prevent.
export function parseWalkManifest(text) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    throw new Error(`walk manifest is not valid JSON: ${e.message}`);
  }

  const screens = doc && doc.screens;
  if (!Array.isArray(screens) || screens.length === 0) {
    throw new Error(
      "walk manifest declares no screens — a walk with no universe is a config error, not an empty pass"
    );
  }

  for (const s of screens) {
    if (!s || typeof s.screen !== "string" || s.screen.length === 0) {
      throw new Error("every screen entry needs a non-empty `screen` path");
    }
    if (!Array.isArray(s.controls) || s.controls.length === 0) {
      throw new Error(`screen ${s.screen} declares no controls`);
    }
    for (const c of s.controls) {
      if (!c || typeof c.find !== "string" || c.find.length === 0) {
        throw new Error(`screen ${s.screen} has a control with no \`find\` text — W1 would have nothing to locate`);
      }
      if (!ASSERTION_VERBS.includes(c.assert)) {
        throw new Error(
          `screen ${s.screen}, control ${c.find}: unknown assertion verb "${c.assert}" — the verb list is closed (${ASSERTION_VERBS.join(", ")})`
        );
      }
    }
  }

  return { screens };
}

// The closed set of ARIA roles W1 treats as interactive, alongside the
// native `button` and `a` elements the scrape always includes.
//
// This list IS the coverage denominator's boundary: a role absent here is
// neither walked nor counted, so widening coverage means editing this list
// — an explicit, reviewable act, never a runtime accident. Frozen for the
// same reason ASSERTION_VERBS is.
//
// First draft, to be checked against the pilot repo's real DOM (spec open
// question 2).
export const INTERACTIVE_ROLES = Object.freeze([
  "button",
  "link",
  "checkbox",
  "radio",
  "switch",
  "tab",
  "menuitem",
  "menuitemcheckbox",
  "menuitemradio",
  "combobox",
  "option",
  "textbox",
  "searchbox",
  "slider",
  "spinbutton",
]);

// coverageDiff <declared> <discovered> -> { declared, discovered, undeclared }
//
// The outside-list comparison (spec Decision 4). `discovered` comes from
// the live DOM and is the denominator; the manifest never grades itself.
// This is the same rule the handbook coverage gate learned in #268, where
// a gate that accepted any passing mention was replaced by one that
// cross-checks against an independently-derived list.
//
// A control DECLARED but not rendered is deliberately NOT a coverage gap.
// Its assertion verb already reports that it could not be found, and
// counting it here too would report one defect twice.
export function coverageDiff(declaredControls, discoveredControls) {
  const declared = new Set(declaredControls);
  const discovered = new Set(discoveredControls);
  const undeclared = [...discovered].filter((c) => !declared.has(c)).sort();
  return { declared: declared.size, discovered: discovered.size, undeclared };
}
