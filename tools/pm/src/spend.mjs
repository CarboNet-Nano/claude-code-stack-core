// REQ-111 (3rd challenge threshold) amendment / ASSUMPTION 3 -- the
// spend-source contract, forward-only: estimates come from a track's
// frontmatter `budget_usd` (tracks.mjs's parseTrack), actuals are summed
// from `~/.claude/logs/cost-log.jsonl` rows carrying BOTH `cost_usd` and
// `track`. Either side missing for a given track -> that track is omitted
// from the result silently (no fabricated 0, no fabricated estimate) --
// `challenges()` in brief.mjs only fires the threshold for tracks present
// in this array, so an omitted track simply never gets weighed.
//
// A malformed cost-log line (bad JSON, or any single line that throws) is
// skipped and reported via the optional `warnings` sink -- it must never
// abort the whole scan; one bad line from an unrelated writer must not cost
// every other track its actual-spend figure.
export async function collectSpend({ readFile, tracks, costLogPath, warnings = [] }) {
  const estimates = new Map();
  for (const track of tracks || []) {
    if (typeof track.budget_usd === "number" && Number.isFinite(track.budget_usd)) {
      estimates.set(track.track, track.budget_usd);
    }
  }

  // No track in scope declares an estimate -- nothing this threshold could
  // ever fire on, so skip the cost-log read entirely (also keeps every
  // pre-existing caller/fixture that never sets budget_usd silent, with no
  // new "cost-log unreadable" warning noise).
  if (estimates.size === 0) return [];

  let raw;
  try {
    raw = await readFile(costLogPath, "utf8");
  } catch (err) {
    warnings.push(`cost-log unreadable: ${err.message}`);
    return [];
  }

  const actuals = new Map();
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let row;
    try {
      row = JSON.parse(trimmed);
    } catch (err) {
      warnings.push(`cost-log line skipped (malformed JSON): ${err.message}`);
      continue;
    }

    if (typeof row.cost_usd !== "number" || typeof row.track !== "string") continue;
    actuals.set(row.track, (actuals.get(row.track) || 0) + row.cost_usd);
  }

  const result = [];
  for (const [track, estimate] of estimates) {
    const actual = actuals.get(track);
    if (actual === undefined) continue;
    result.push({ track, estimate, actual });
  }
  return result;
}
