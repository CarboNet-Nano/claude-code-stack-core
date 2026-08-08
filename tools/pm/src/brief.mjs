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

export function challenges(input, now) {
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
      result.push(`${s.track} at ${ratio}× its estimate`);
    }
  }

  return result;
}

const MAX_STRUCTURAL_LINES = 12;

// The 12-line cap is a fixed constant today. P1b's plan is to make this a
// PM-overridable judgment call (which sections matter enough to keep,
// case by case) rather than a hardcoded number — this function is that seam.
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

  const trackChallenges = challenges(input, now);
  const challengeLines = [];
  if (trackChallenges.length > 0) {
    challengeLines.push("Challenge:");
    for (const challenge of trackChallenges) {
      challengeLines.push(`  • ${challenge}`);
    }
  }

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

  // Severity order: Challenges first, then blocked tracks, then remaining
  // tracks (stalest first), then Counters, then Audit pointers.
  const lines = capToBudget(
    [["Brief:"], challengeLines, blockedTrackLines, remainingTrackLines, countersLines, auditLines],
    input.full === true
  );

  return { lines, fence };
}
