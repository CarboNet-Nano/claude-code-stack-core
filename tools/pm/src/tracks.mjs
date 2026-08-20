function parseYaml(yaml) {
  const result = {};
  const lines = yaml.split('\n');
  for (const line of lines) {
    const match = line.match(/^(\w+):\s*(.*?)$/);
    if (match) {
      const [, key, value] = match;
      if (value === 'true') {
        result[key] = true;
      } else if (value === 'false') {
        result[key] = false;
      } else {
        result[key] = value;
      }
    }
  }
  return result;
}

export function parseTrack(md) {
  // Extract frontmatter between --- delimiters
  const match = md.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) {
    throw new Error("Invalid track format: missing frontmatter delimiters");
  }

  const [, frontmatter, body] = match;
  const meta = parseYaml(frontmatter);

  // REQ-111 amendment (ASSUMPTION 3) -- optional spend-estimate field. Only
  // ever a Number when present and numeric; a missing or non-numeric value
  // stays undefined so spend.mjs's collectSpend() can tell "no estimate"
  // apart from "estimate of zero" and omit the track silently, per contract.
  const budgetUsd = meta.budget_usd !== undefined ? Number(meta.budget_usd) : undefined;

  return {
    track: meta.track || "",
    goal: meta.goal || "",
    updated: meta.updated || "",
    blocked_on: meta.blocked_on || "",
    prioritized: meta.prioritized === true,
    ...(Number.isFinite(budgetUsd) ? { budget_usd: budgetUsd } : {}),
    body
  };
}

function stringifyYaml(meta) {
  const lines = [];
  if (meta.track) lines.push(`track: ${meta.track}`);
  if (meta.goal) lines.push(`goal: ${meta.goal}`);
  if (meta.updated) lines.push(`updated: ${meta.updated}`);
  if (meta.budget_usd !== undefined) lines.push(`budget_usd: ${meta.budget_usd}`);
  // Only output blocked_on if non-empty to avoid trailing space
  if (meta.blocked_on) {
    lines.push(`blocked_on: ${meta.blocked_on}`);
  } else {
    lines.push(`blocked_on:`);
  }
  lines.push(`prioritized: ${meta.prioritized === true}`);
  return lines.join("\n");
}

export function updateTrack(md, { state, updated }) {
  // Parse current content
  const match = md.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) {
    throw new Error("Invalid track format: missing frontmatter delimiters");
  }

  const [, frontmatter, body] = match;
  const meta = parseYaml(frontmatter);

  // Update metadata
  if (updated) {
    meta.updated = updated;
  }

  // Replace only the "## Current state" section with regex lookahead for end of section
  let newBody = body;
  if (state !== undefined) {
    // Sanitize state: indent any line starting with 2+ hashes to prevent injection attacks
    // Matches boundary lookahead /\n##/ (which treats "###" as a boundary since it starts with ##)
    // This ensures caller content can never introduce a section boundary
    const sanitizedState = state
      .split('\n')
      .map(line => (line.match(/^#{2,}/) ? `  ${line}` : line))
      .join('\n');

    // Match the state section and preserve blank lines between sections
    const stateRegex = /## Current state\n([\s\S]*?)(?=\n##|\s*$)/;
    const stateMatch = body.match(stateRegex);
    if (stateMatch) {
      const hasNextSection = /\n##/.test(body.substring(stateMatch.index + stateMatch[0].length));
      const replacement = `## Current state\n${sanitizedState}${hasNextSection ? '\n' : ''}`;
      newBody = body.replace(stateRegex, replacement);
    }
  }

  // Reconstruct document
  const newFrontmatter = stringifyYaml(meta);
  return `---\n${newFrontmatter}\n---\n${newBody}`;
}

export function stalenessDays(track, nowIsoDate) {
  // Date-only UTC arithmetic: parse both as YYYY-MM-DD at midnight UTC
  const trackMs = Date.parse(track.updated + "T00:00:00Z");
  const nowMs = Date.parse(nowIsoDate + "T00:00:00Z");

  const days = Math.floor((nowMs - trackMs) / (24 * 60 * 60 * 1000));
  return days;
}
