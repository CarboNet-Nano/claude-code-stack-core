import { stalenessDays } from "./tracks.mjs";
import { fenceBlock, sanitize } from "./fence.mjs";

function slugify(s, max = 40) {
  if (!s) return "";
  let slug = s
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (slug.length > max) {
    slug = slug.substring(0, max);
  }
  return slug;
}

// REQ-112 — the 5-rung assertiveness ladder (matrix.mjs's LADDER) collapses
// to the 3-word challenge vocabulary a human brief reads: the two softest
// rungs read/write the same passive posture ("advise"), the two middle
// rungs share the same working posture ("gate"), and only the ladder's top
// rung ("gate" assertiveness — MOST human control, per matrix-edit.mjs's
// LADDER comment: observe < recommend < decide-with-review < decide < gate)
// escalates to "insist". Not imported from matrix.mjs: that module owns the
// ladder's VALUES, this map owns how brief TEXT reacts to them — a
// one-way, brief-local concern, never the other way around.
const ASSERTIVENESS_TO_CHALLENGE_PREFIX = {
  observe: "advise",
  recommend: "advise",
  "decide-with-review": "gate",
  decide: "gate",
  gate: "insist"
};

// REQ-112 — `matrixCell` is optional and additive: every existing caller
// (every fixture in brief.test.mjs, every pre-Task-15 fixture) omits it and
// gets the exact unprefixed strings this function has always returned.
// Only a caller that resolved a real matrix cell (cli.mjs's `pm brief`,
// Task 12's resolver) opts into stakes-weighted prefixing.
export function challenges(input, now, matrixCell) {
  const result = [];
  if (!now) {
    now = new Date().toISOString().split("T")[0];
  }

  if (!input.tracks || !input.counters) {
    return result;
  }

  for (const track of input.tracks) {
    const staleDays = stalenessDays(track, now);
    if (track.prioritized && staleDays > 7) {
      result.push(`idle ${staleDays}d`);
      break;
    }
  }

  const overrides = input.counters.overridesByAgent || {};
  for (const [agent, count] of Object.entries(overrides)) {
    if (count >= 3) {
      result.push(`overridden ${count}×`);
      break;
    }
  }

  const pending = input.counters.pendingPredictions || 0;
  if (pending >= 2) {
    result.push(`${pending} already mid-flight`);
  }

  const spend = input.spend || [];
  for (const s of spend) {
    if (s.estimate > 0 && s.actual > 2 * s.estimate) {
      const ratio = (s.actual / s.estimate).toFixed(1);
      result.push(`${slugify(s.track)} at ${ratio}× its estimate`);
    }
  }

  const prefix = ASSERTIVENESS_TO_CHALLENGE_PREFIX[matrixCell?.assertiveness];
  return prefix ? result.map((c) => `${prefix}: ${c}`) : result;
}

const MAX_STRUCTURAL_LINES = 12;

// REQ-117 (P1b half): `full` bypasses the cap unconditionally (P1a's
// `--full`); a truthy `budgetOverride` (this function receives only the
// boolean bypass decision, never the reason text — that's rendered as line
// 1 by the caller, assembleBrief) bypasses it too. This is the seam the
// P1a comment above used to describe as a future plan — it is the plan,
// now wired to a real authoring path (cli.mjs's `--override-budget`).
function capToBudget(sections, full) {
  const allLines = sections.flat();
  if (full || allLines.length <= MAX_STRUCTURAL_LINES) {
    return allLines;
  }
  const kept = allLines.slice(0, MAX_STRUCTURAL_LINES - 1);
  const heldBack = allLines.length - kept.length;
  // Honest generic offer, never "+0" and never a silent drop: whatever got
  // cut — challenges, tracks, counters, audit — the reader is told exactly
  // that something was held back and how to see all of it.
  return [...kept, `  +${heldBack} items held back — run brief --full`];
}

const OVERRIDE_SUPPRESSION_WINDOW_MS = 24 * 60 * 60 * 1000;

// REQ-113 / ASSUMPTION 8 — an override "references this session" when its
// session_id matches the CURRENT session's, compared only when BOTH sides
// actually have one (an override recorded under a real CLAUDE_SESSION_ID,
// read back during a run that also has one). When either side lacks a
// session_id (older event, or CLAUDE_SESSION_ID unset), identity can't be
// established at all, so this falls back to a 24h window from `nowMs` —
// same-day re-runs still suppress without a false match across genuinely
// different, unrelated work sessions.
function overrideStillSuppresses(override, sessionId, nowMs) {
  if (override.session_id != null && sessionId != null) {
    return override.session_id === sessionId;
  }
  const overrideMs = Date.parse(override.ts);
  if (Number.isNaN(overrideMs)) return false;
  const age = nowMs - overrideMs;
  return age >= 0 && age < OVERRIDE_SUPPRESSION_WINDOW_MS;
}

export function assembleBrief(input) {
  const fenceEntries = [];
  const now = input.nowIso ? input.nowIso.slice(0, 10) : new Date().toISOString().split("T")[0];

  if (!input.tracks) {
    input.tracks = [];
  }

  const renderedTracks = input.tracks.map((track) => {
    const blocked = track.blocked_on ? " ⚠" : "";
    const slug = slugify(track.track);
    const staleDays = typeof track.staleness === "number" ? track.staleness : stalenessDays(track, now);
    if (track.goal) {
      fenceEntries.push({ label: track.track, text: track.goal });
    }
    return { track, staleDays, line: `  [${slug}] ${staleDays}d${blocked}` };
  });

  const stalestFirst = (a, b) => b.staleDays - a.staleDays;
  const blockedTrackLines = renderedTracks.filter((r) => r.track.blocked_on).sort(stalestFirst).map((r) => r.line);
  const remainingTrackLines = renderedTracks.filter((r) => !r.track.blocked_on).sort(stalestFirst).map((r) => r.line);

  // REQ-113 — an active override (this session, or within the 24h
  // fallback window) suppresses the WHOLE Challenge: section for this
  // brief, not just the one condition that was overridden: P1b has no
  // per-challenge identity to match against (challenges are recomputed
  // facts, not journaled events), and "never re-litigated in the same
  // session" is honored at the coarser, honest granularity this data
  // actually supports rather than faking a precision it doesn't have.
  const nowMs = input.nowIso ? Date.parse(input.nowIso) : Date.now();
  const sessionId = input.sessionId ?? null;
  const recentOverrides = input.recentOverrides || [];
  const overridden = recentOverrides.some((o) => overrideStillSuppresses(o, sessionId, nowMs));

  const trackChallenges = overridden ? [] : challenges(input, now, input.matrixCell || null);
  const challengeLines = [];
  if (trackChallenges.length > 0) {
    challengeLines.push("Challenge:");
    for (const challenge of trackChallenges) {
      challengeLines.push(`  • ${challenge}`);
    }
  }

  // REQ-125 — resolver warnings (an override lowering a shipped default
  // "gate" dial) render as structural lines, ranked alongside Challenge:
  // both are governance-severity signals, ahead of routine track status.
  const matrixWarnings = input.matrixWarnings || [];
  const warningLines = [];
  if (matrixWarnings.length > 0) {
    warningLines.push("Warning:");
    for (const w of matrixWarnings) {
      warningLines.push(`  • ${slugify(w.agent)}: ${w.dial} ${w.before}→${w.after} (${w.domainMode}/${w.sensitivity})`);
    }
  }

  // Task 8 (ADR-060 §6): the outbox's unsent count, when non-zero, IS the
  // whole no-silent-loss safety property made visible -- review fix: it
  // must survive the 12-line cap the same way Challenge/Warning do (a
  // previous rev ranked it below routine track lines, making it the FIRST
  // casualty of capToBudget on a busy portfolio -- exactly the situation
  // where an operator most needs to see it). Ranked WITH challenges/
  // warnings, ahead of routine track status. Zero/absent renders nothing
  // (regression guard: every existing fixture omits this field and must
  // be unaffected).
  const unsentCount = input.unsentCount || 0;
  const unsentLines = unsentCount > 0 ? [`⚠ ${unsentCount} events unsent`] : [];

  const counters = input.counters || {};
  const staleCalls = counters.staleCalls || 0;
  const overridesByAgent = counters.overridesByAgent || {};
  const pendingPredictions = counters.pendingPredictions || 0;

  const agentCount = Object.keys(overridesByAgent).length;
  const slugifiedAgents = Object.keys(overridesByAgent).map((a) => slugify(a));
  const agentList = agentCount > 0 ? ` (${slugifiedAgents.join(", ")})` : "";

  const countersLines = [];
  if (staleCalls > 0 || agentCount > 0 || pendingPredictions > 0) {
    const parts = [];
    if (staleCalls > 0) parts.push(`${staleCalls} stale`);
    if (agentCount > 0) parts.push(`${agentCount} agents overriding${agentList}`);
    if (pendingPredictions > 0) parts.push(`${pendingPredictions} pending`);
    countersLines.push(`Counters: ${parts.join(", ")}`);
  }

  const auditLines = [`Audit: see fence [${trackChallenges.length}]`];

  const suggestions = (input.suggestions || []).filter((s) => {
    return !(s.author === "pm" && s.subject === "pm");
  });

  for (const suggestion of suggestions) {
    fenceEntries.push({
      label: `suggestion from ${suggestion.author}`,
      text: suggestion.text
    });
  }

  const fence = fenceBlock(fenceEntries);

  // REQ-117 (P1b half) — a real authoring path, not just a mechanical
  // bypass: when the PM's judgment is that the capped brief hides
  // something material, `budgetOverride: {reason}` both replaces line 1
  // with the stated reason (never silent — the reader sees WHY this brief
  // is longer than usual) and lifts the cap, exactly like `--full` does
  // mechanically. `input.full` stays the P1a escape hatch; this is the
  // judgment-driven one.
  //
  // REQ-116 (review fix): `reason` reaches line 1 UNFENCED — it is a
  // structural line, not fence content — so it gets the same sanitize()
  // pass the fence's own entries get (control-char strip + fixpoint
  // delimiter strip + length cap), not the fence's wrapping. Without this,
  // an embedded newline could forge a fake structural line, and the
  // literal fence-delimiter string could close the REAL fence early —
  // exactly the injection REQ-116 exists to block, just at a different
  // rendering site. 200 chars is a generous cap for a one-line stated
  // reason, well under the fence's own 300-char suggestion cap.
  const budgetOverride = input.budgetOverride || null;
  const firstLine = budgetOverride ? `budget exceeded: ${sanitize(budgetOverride.reason, 200)}` : "Brief:";

  // Severity order: Challenges first, then matrix Warnings (REQ-125), then
  // the unsent-events line (Task 8 review fix — ranked with them, ahead of
  // routine track status, so it survives the cap), then blocked tracks,
  // then remaining tracks (stalest first), then Counters, then Audit
  // pointers.
  const lines = capToBudget(
    [[firstLine], challengeLines, warningLines, unsentLines, blockedTrackLines, remainingTrackLines, countersLines, auditLines],
    input.full === true || budgetOverride !== null
  );

  return { lines, fence };
}
