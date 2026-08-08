import { test } from "node:test";
import assert from "node:assert/strict";
import { parseTrack, updateTrack, stalenessDays } from "../src/tracks.mjs";

const fixture = `---
track: project-alpha
goal: Deliver MVP by Q3
updated: 2026-08-01
blocked_on:
prioritized: true
---

## Current state
On track. Team allocated.

## Risks
None identified.

## Next steps
Deploy staging.
`;

const fixtureNoPrioritized = `---
track: project-beta
goal: Refactor module
updated: 2026-08-05
blocked_on: waiting-approval
---

## Current state
Blocked by review.

## Risks
Review bottleneck.

## Next steps
Follow up with reviewer.
`;

const fixtureLastSection = `---
track: final-test
goal: Test edge case
updated: 2026-08-03
blocked_on:
prioritized: false
---

## Risks
None.

## Next steps
Validate.

## Current state
Ready for testing.
`;

test("REQ-102: parseTrack round-trip with prioritized=true (boolean)", () => {
  const parsed = parseTrack(fixture);
  assert.equal(parsed.track, "project-alpha");
  assert.equal(parsed.goal, "Deliver MVP by Q3");
  assert.equal(parsed.updated, "2026-08-01");
  assert.equal(parsed.blocked_on, "");
  assert.equal(parsed.prioritized, true);
  assert.match(parsed.body, /On track\. Team allocated\./);
});

test("REQ-102: parseTrack with prioritized missing defaults to false", () => {
  const parsed = parseTrack(fixtureNoPrioritized);
  assert.equal(parsed.prioritized, false);
  assert.equal(parsed.track, "project-beta");
});

test("REQ-102: parseTrack returns body with all sections", () => {
  const parsed = parseTrack(fixture);
  assert.match(parsed.body, /## Risks/);
  assert.match(parsed.body, /## Next steps/);
  assert.match(parsed.body, /None identified/);
  assert.match(parsed.body, /Deploy staging/);
});

test("REQ-103: updateTrack modifies only state section", () => {
  const updated = updateTrack(fixture, { state: "Deployed to production.", updated: "2026-08-08" });
  assert.match(updated, /updated: 2026-08-08/);
  assert.match(updated, /Deployed to production\./);
  assert.match(updated, /## Risks/);
  assert.match(updated, /None identified/);
  assert.match(updated, /## Next steps/);
  assert.match(updated, /Deploy staging/);
  assert.match(updated, /prioritized: true/);
});

test("REQ-103: updateTrack works when Current state is LAST section", () => {
  const updated = updateTrack(fixtureLastSection, { state: "Tested and verified.", updated: "2026-08-04" });
  assert.match(updated, /updated: 2026-08-04/);
  assert.match(updated, /Tested and verified\./);
  assert.match(updated, /## Current state/);
  // Ensure other sections still exist
  assert.match(updated, /## Risks/);
  assert.match(updated, /## Next steps/);
});

test("REQ-103: updateTrack preserves frontmatter keys", () => {
  const updated = updateTrack(fixtureNoPrioritized, { state: "New state.", updated: "2026-08-07" });
  assert.match(updated, /track: project-beta/);
  assert.match(updated, /goal: Refactor module/);
  assert.match(updated, /blocked_on: waiting-approval/);
  assert.match(updated, /prioritized: false/);
});

test("REQ-103: stalenessDays calculates 7 for 08-01 to 08-08", () => {
  const track = { updated: "2026-08-01" };
  const days = stalenessDays(track, "2026-08-08");
  assert.equal(days, 7);
});

test("REQ-103: stalenessDays returns 0 for same day", () => {
  const track = { updated: "2026-08-08" };
  const days = stalenessDays(track, "2026-08-08");
  assert.equal(days, 0);
});

test("REQ-103: stalenessDays uses date-only UTC (TZ-invariant)", () => {
  try {
    process.env.TZ = "Pacific/Kiritimati";
    const track = { updated: "2026-08-01" };
    const days = stalenessDays(track, "2026-08-08");
    assert.equal(days, 7);
  } finally {
    delete process.env.TZ;
  }
});

test("REQ-102: parseTrack with empty blocked_on", () => {
  const parsed = parseTrack(fixture);
  assert.equal(parsed.blocked_on, "");
});

test("REQ-102: parseTrack with non-empty blocked_on", () => {
  const parsed = parseTrack(fixtureNoPrioritized);
  assert.equal(parsed.blocked_on, "waiting-approval");
});

test("REQ-103: updateTrack prevents injection — state with fake header sanitized", () => {
  const injectedState = "Working on feature.\n## Injected fake header\nNot a real section.";
  const updated = updateTrack(fixture, { state: injectedState, updated: "2026-08-08" });

  // Verify the injected header is escaped/indented (not a real section boundary)
  const reparsed = parseTrack(updated);
  // Should still have exactly 3 sections in the body
  const sectionCount = (reparsed.body.match(/^## /gm) || []).length;
  assert.equal(sectionCount, 3, "Body should have exactly 3 sections, not 4");

  // Verify the injected text is preserved but escaped
  assert.match(updated, /  ## Injected fake header/, "Fake header should be indented/escaped");
});

test("REQ-103: updateTrack twice — second update cleanly replaces escaped state", () => {
  const injectedState1 = "State with\n## Fake header\nstuff.";
  const updated1 = updateTrack(fixture, { state: injectedState1, updated: "2026-08-08" });

  // Second update with different state
  const injectedState2 = "Clean replacement\n## Another fake\nmore content.";
  const updated2 = updateTrack(updated1, { state: injectedState2, updated: "2026-08-09" });

  // Parse back
  const reparsed = parseTrack(updated2);
  // Should still have exactly 3 sections
  const sectionCount = (reparsed.body.match(/^## /gm) || []).length;
  assert.equal(sectionCount, 3, "After second update, should still have 3 sections");

  // Verify new escaped content is present, old is gone
  assert.match(updated2, /Another fake/, "New fake header should be present");
  assert.match(updated2, /  ## Another fake/, "New fake header should be escaped");
});

test("REQ-103: updateTrack sanitizes H3+ headings (asymmetry fix)", () => {
  // State with H3 heading (###) which escapes old /^##\s/ but matches /\n##/ boundary
  const stateWithH3 = "Working on feature.\n### Fake H3 heading\nMore text.";
  const updated1 = updateTrack(fixture, { state: stateWithH3, updated: "2026-08-08" });

  // First update: verify exactly 3 real sections remain
  const reparsed1 = parseTrack(updated1);
  const sectionCount1 = (reparsed1.body.match(/^## /gm) || []).length;
  assert.equal(sectionCount1, 3, "After first update, should have exactly 3 real sections");

  // H3 should be escaped (indented)
  assert.match(updated1, /  ### Fake H3 heading/, "H3 heading should be indented/escaped");

  // Second update: verify state is cleanly replaced with no orphaned residue
  const updated2 = updateTrack(updated1, { state: "New state content.", updated: "2026-08-09" });
  const reparsed2 = parseTrack(updated2);
  const sectionCount2 = (reparsed2.body.match(/^## /gm) || []).length;
  assert.equal(sectionCount2, 3, "After second update, should still have exactly 3 sections");

  // Old H3 should be completely gone, not orphaned between sections
  assert.doesNotMatch(updated2, /Fake H3/, "Old H3 content should be completely replaced");
  assert.match(updated2, /New state content\./, "New state should be present");
});
