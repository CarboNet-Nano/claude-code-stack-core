import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveScope, discoverSuggestions, fetchGhProperties } from "./portfolio.mjs";
import { parseTrack, updateTrack, stalenessDays } from "./tracks.mjs";
import { listPmIssues, fileIssue, closeIssue } from "./board.mjs";
import { assembleBrief } from "./brief.mjs";
import { validateEvent } from "./journal.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = join(__dirname, "..", "..", "..", "config", "portfolio.json");
const EMPTY_CONFIG = { portfolios: {} };

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const opts = { done: [] };
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (!key.startsWith("--")) continue;
    const name = key.slice(2);
    if (name === "yes") {
      opts.yes = true;
      continue;
    }
    if (name === "full") {
      opts.full = true;
      continue;
    }
    const value = rest[++i];
    if (name === "done") {
      opts.done.push(value);
    } else {
      opts[name] = value;
    }
  }
  return { command, opts };
}

function trackFilePath(deps, track) {
  if (typeof deps.trackPath === "function") return deps.trackPath(track);
  return join(process.cwd(), ".claude", "tracks", `${track}.md`);
}

async function loadConfig(deps) {
  const configPath = deps.configPath || DEFAULT_CONFIG_PATH;
  const raw = await deps.readFile(configPath, "utf8");
  return JSON.parse(raw);
}

async function collectTracks(deps, scope, nowIso, warnings) {
  const tracks = [];
  let filesByRepo = {};
  try {
    filesByRepo = (await deps.glob(scope)) || {};
  } catch (err) {
    warnings.push(`glob failed: ${err.message}`);
    return tracks;
  }

  const nowIsoDate = nowIso.slice(0, 10);
  for (const repo of scope) {
    const paths = filesByRepo[repo] || [];
    for (const path of paths) {
      try {
        const content = await deps.readFile(path, "utf8");
        const track = parseTrack(content);
        track.staleness = stalenessDays(track, nowIsoDate);
        tracks.push(track);
      } catch (err) {
        warnings.push(`track file failed (${path}): ${err.message}`);
      }
    }
  }
  return tracks;
}

function extractStdout(result) {
  return typeof result === "string" ? result : result?.stdout ?? "";
}

async function collectIssueCount(deps, scope, warnings) {
  let total = 0;
  const byRepo = {};
  const failedRepos = [];
  let results;
  try {
    results = await listPmIssues(deps.execFile, scope);
  } catch (err) {
    // listPmIssues itself isolates per-repo failures now; this only fires on
    // a truly unexpected throw (e.g. bad input), so treat the whole scope as unreadable.
    warnings.push(`listPmIssues failed: ${err.message}`);
    return { total, byRepo, failedRepos: [...scope] };
  }

  for (const entry of results) {
    if (!entry.ok) {
      failedRepos.push(entry.repo);
      warnings.push(`issue list failed for ${entry.repo}: ${entry.error}`);
      continue;
    }
    try {
      const issues = JSON.parse(extractStdout(entry.result));
      byRepo[entry.repo] = issues.length;
      total += issues.length;
    } catch (err) {
      failedRepos.push(entry.repo);
      warnings.push(`issue parse failed for ${entry.repo}: ${err.message}`);
    }
  }

  return { total, byRepo, failedRepos };
}

async function collectSuggestions(deps, portfolioName, scope, config, warnings) {
  try {
    const ghProps = await fetchGhProperties(deps.execFile, scope);
    const repos = discoverSuggestions(portfolioName, ghProps, config);
    return repos.map((repo) => ({
      author: "pm",
      subject: "portfolio",
      text: `${repo} tagged cn-portfolio=${portfolioName}, not yet in scope`
    }));
  } catch (err) {
    warnings.push(`suggestions failed: ${err.message}`);
    return [];
  }
}

async function runBrief(opts, deps) {
  const warnings = [];
  const portfolioName = opts.portfolio;
  const nowIso = typeof deps.nowIso === "function" ? deps.nowIso() : new Date().toISOString();

  if (!portfolioName) {
    deps.stdout("brief: --portfolio is required");
    return { command: "brief", code: 1, lines: [], fence: [], warnings };
  }

  let config = EMPTY_CONFIG;
  try {
    config = await loadConfig(deps);
  } catch (err) {
    warnings.push(`config load failed: ${err.message}`);
  }

  const scope = resolveScope(portfolioName, config);

  const tracks = await collectTracks(deps, scope, nowIso, warnings);
  const { total: issueCount, byRepo: issuesByRepo, failedRepos: issueFailedRepos } = await collectIssueCount(deps, scope, warnings);
  const suggestions = await collectSuggestions(deps, portfolioName, scope, config, warnings);

  let counters = { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 };
  try {
    counters = deps.journal.counters(portfolioName, Date.parse(nowIso));
  } catch (err) {
    warnings.push(`counters failed: ${err.message}`);
  }

  const { lines, fence } = assembleBrief({ tracks, counters, suggestions, spend: [], nowIso, full: opts.full === true });

  for (const line of lines) deps.stdout(line);
  for (const line of fence) deps.stdout(line);
  // Degraded reads must stay visible on the count line itself — a bare
  // "Issues: 0 open" reads as "no open issues," not "couldn't check."
  deps.stdout(
    issueFailedRepos.length
      ? `Issues: ${issueCount} open (${issueFailedRepos.length} repo(s) unreadable: ${issueFailedRepos.join(", ")})`
      : `Issues: ${issueCount} open`
  );
  for (const w of warnings) deps.stdout(`warning: ${w}`);

  return {
    command: "brief",
    code: 0,
    lines,
    fence,
    trackCount: tracks.length,
    issueCount,
    issuesByRepo,
    issueFailedRepos,
    warnings
  };
}

function parseDoneEntry(entry) {
  const m = String(entry).match(/^([^#]+)#(\d+):(.*)$/s);
  if (!m) {
    throw new Error(`invalid --done entry (expected repo#number:comment): ${entry}`);
  }
  const [, repo, numStr, comment] = m;
  return { repo, number: Number(numStr), comment };
}

function validateNextEntries(nextRaw) {
  const nextIssues = nextRaw ? JSON.parse(nextRaw) : [];
  if (!Array.isArray(nextIssues)) {
    throw new Error("--next must be a JSON array");
  }
  for (const n of nextIssues) {
    if (!n.repo || !n.title || !n.body) {
      throw new Error("each --next entry requires repo, title, body");
    }
  }
  return nextIssues;
}

function printFailure(deps, completed, failedStep, err) {
  deps.stdout("FAILED closeout");
  deps.stdout(`Completed: ${completed.length ? completed.join(", ") : "(none)"}`);
  deps.stdout(`Failed: ${failedStep}${err ? ` (${err.message})` : ""}`);
}

async function runCloseout(opts, deps) {
  const completed = [];
  const nowIso = typeof deps.nowIso === "function" ? deps.nowIso() : new Date().toISOString();

  const track = opts.track;
  const portfolioName = opts.portfolio;
  const state = opts.state;
  if (!track || !portfolioName || state === undefined) {
    deps.stdout("closeout: --track, --portfolio and --state are required");
    return { command: "closeout", code: 1, completed, failed: "validate-args" };
  }

  let doneEntries;
  try {
    doneEntries = (opts.done || []).map(parseDoneEntry);
    for (const d of doneEntries) {
      if (!d.comment || d.comment.trim() === "") {
        throw new Error("closing comment required");
      }
    }
  } catch (err) {
    deps.stdout(`closeout refused: ${err.message}`);
    return { command: "closeout", code: 1, completed, failed: "validate-done" };
  }

  let nextIssues;
  try {
    nextIssues = validateNextEntries(opts.next);
  } catch (err) {
    deps.stdout(`closeout refused: ${err.message}`);
    return { command: "closeout", code: 1, completed, failed: "validate-next" };
  }

  // Compose the handoff event and dry-run journal validation on it BEFORE any
  // mutation runs. Journal validation used to run last (after track-file
  // write, issue closes, and issue creates), so a --state containing an
  // absolute path or secret-shaped string bricked closeout at the final step
  // with everything else already mutated. Validating first means a bad
  // --state fails clean, with nothing touched.
  const handoffEvent = {
    ts: nowIso,
    type: "handoff",
    subject: track,
    author: "user",
    portfolio: portfolioName,
    body: {
      state,
      done: doneEntries.map((d) => `${d.repo}#${d.number}`),
      next: nextIssues.map((n) => n.repo)
    }
  };
  try {
    validateEvent(handoffEvent);
  } catch (err) {
    deps.stdout(`closeout refused: state text failed journal validation: ${err.message} — no changes made`);
    return { command: "closeout", code: 1, completed, failed: "validate-state" };
  }

  let config;
  try {
    config = await loadConfig(deps);
  } catch (err) {
    deps.stdout(`closeout refused: cannot load portfolio config: ${err.message}`);
    return { command: "closeout", code: 1, completed, failed: "resolve-scope" };
  }
  const scope = resolveScope(portfolioName, config);

  const trackPath = trackFilePath(deps, track);
  try {
    const original = await deps.readFile(trackPath, "utf8");
    const updated = updateTrack(original, { state, updated: nowIso.slice(0, 10) });
    await deps.writeFile(trackPath, updated, "utf8");
    completed.push("track-file");
  } catch (err) {
    printFailure(deps, completed, "track-file", err);
    return { command: "closeout", code: 1, completed, failed: "track-file" };
  }

  for (const d of doneEntries) {
    const step = `done:${d.repo}#${d.number}`;
    try {
      await closeIssue(deps.execFile, scope, d.repo, d.number, d.comment);
      completed.push(step);
    } catch (err) {
      printFailure(deps, completed, step, err);
      return { command: "closeout", code: 1, completed, failed: step };
    }
  }

  for (const n of nextIssues) {
    const step = `next:${n.repo}`;
    try {
      await fileIssue(deps.execFile, scope, n.repo, { title: n.title, body: n.body, track, source: "handoff" });
      completed.push(step);
    } catch (err) {
      printFailure(deps, completed, step, err);
      return { command: "closeout", code: 1, completed, failed: step };
    }
  }

  try {
    deps.journal.append(handoffEvent);
    completed.push("journal");
  } catch (err) {
    printFailure(deps, completed, "journal", err);
    return { command: "closeout", code: 1, completed, failed: "journal" };
  }

  deps.stdout(`closeout complete: ${completed.join(", ")}`);
  return { command: "closeout", code: 0, completed };
}

async function runPurge(opts, deps) {
  const portfolioName = opts.portfolio;
  if (!portfolioName) {
    deps.stdout("purge: --portfolio is required");
    return { command: "purge", code: 1 };
  }

  let count;
  try {
    count = deps.journal.events(portfolioName).length;
  } catch (err) {
    deps.stdout(`purge: failed to read events: ${err.message}`);
    return { command: "purge", code: 1 };
  }

  if (!opts.yes) {
    deps.stdout(`purge: would delete ${count} event(s) for portfolio "${portfolioName}". Re-run with --yes to confirm.`);
    return { command: "purge", code: 1, count };
  }

  deps.journal.purge(portfolioName);
  deps.stdout(`purge complete: deleted ${count} event(s) for portfolio "${portfolioName}"`);
  return { command: "purge", code: 0, count };
}

export async function main(argv, deps) {
  const { command, opts } = parseArgs(argv);

  if (command === "brief") {
    try {
      return await runBrief(opts, deps);
    } catch (err) {
      deps.stdout(`brief warning: unexpected error: ${err.message}`);
      return { command: "brief", code: 0, lines: [], fence: [], warnings: [err.message] };
    }
  }

  if (command === "closeout") {
    try {
      return await runCloseout(opts, deps);
    } catch (err) {
      // Backstop: every known step is already individually try/caught inside
      // runCloseout. This only fires on a bug — but closeout is FAIL-FAST,
      // so it must still report and exit non-zero, never look like success.
      printFailure(deps, [], "unexpected", err);
      return { command: "closeout", code: 1, completed: [], failed: "unexpected" };
    }
  }

  if (command === "purge") {
    try {
      return await runPurge(opts, deps);
    } catch (err) {
      deps.stdout(`purge: unexpected error: ${err.message}`);
      return { command: "purge", code: 1 };
    }
  }

  deps.stdout(`unknown command: ${command}`);
  return { command, code: 1 };
}
