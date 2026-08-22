import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { resolveScope, discoverSuggestions, fetchGhProperties } from "./portfolio.mjs";
import { parseTrack, updateTrack, stalenessDays } from "./tracks.mjs";
import { listPmIssues, fileIssue, closeIssue } from "./board.mjs";
import { assembleBrief } from "./brief.mjs";
import { validateEvent } from "./journal.mjs";
import { openSourceDb, importEvents, finalizeMigration, isFinalizedPath } from "./migrate.mjs";
import { resolveMatrix, loadDefaultMatrix, loadOverrides, LADDER, DIALS } from "./matrix.mjs";
import { editMatrix } from "./matrix-edit.mjs";
import { collectSpend } from "./spend.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG_PATH = join(__dirname, "..", "..", "..", "config", "portfolio.json");
const DEFAULT_COST_LOG_PATH = join(homedir(), ".claude", "logs", "cost-log.jsonl");
const EMPTY_CONFIG = { portfolios: {} };

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const opts = { done: [] };
  let i = 0;
  // A bare (non "--") first token is a subcommand, e.g. `pm matrix set ...`.
  // Every other command's rest[0] is already a "--flag", so this is a
  // strict addition — no existing command's parsing changes.
  if (rest[0] !== undefined && !rest[0].startsWith("--")) {
    opts.subcommand = rest[0];
    i = 1;
  }
  for (; i < rest.length; i++) {
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
    if (name === "dry-run") {
      opts.dryRun = true;
      continue;
    }
    if (name === "confirm-lower") {
      opts.confirmLower = true;
      continue;
    }
    const value = rest[++i];
    if (name === "done") {
      opts.done.push(value);
    } else if (name === "option") {
      (opts.options ??= []).push(value);
    } else if (name === "ref") {
      (opts.refs ??= []).push(value);
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

// The repo's own stack-config.json — where a repo-authored `pm_matrix`
// override (REQ-121's top precedence layer) lives. Same pattern as
// trackFilePath above: an injected deps.repoConfigPath wins for tests,
// otherwise resolve from process.cwd() — the WORKING repo, never __dirname
// (which points at wherever cli.mjs itself is installed: the stack repo in
// dev, or ~/.claude/tools/pm/src in production, neither of which is the
// repo pm is actually running against).
function stackConfigPath(deps) {
  return deps.repoConfigPath || join(process.cwd(), ".claude", "stack-config.json");
}

async function loadConfig(deps) {
  const configPath = deps.configPath || DEFAULT_CONFIG_PATH;
  const raw = await deps.readFile(configPath, "utf8");
  return JSON.parse(raw);
}

async function collectTracks(deps, scope, nowIso, warnings, portfolioName) {
  const tracks = [];
  let filesByRepo = {};
  try {
    // ASSUMPTION 5 -- portfolioName is passed through so a real glob (e.g.
    // bin.mjs's) can resolve a per-portfolio checkout_root; a two-arg-only
    // fake glob (every pre-Task-17 test fixture) simply ignores the second
    // argument, so this is additive, not breaking.
    filesByRepo = (await deps.glob(scope, portfolioName)) || {};
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

// REQ-112 (Task 15) — same resolver Task 12 wired for `pm matrix resolve`
// and foreman's dispatch check, called here in-process (no subprocess —
// this IS the process that owns matrix.mjs) for the PM's own row. Never
// lets a missing/corrupt behavior-matrix.json brick the brief: a failure
// here is pushed to `warnings` and the caller gets `{cell: undefined,
// matrixWarnings: []}`, which `challenges()`/`assembleBrief` already treat
// as "no prefix" / "no Warning: section" (P1a's exact rendering).
//
// REQ-125 (conformance-audit fix): `resolveMatrix` returns `{cell,
// warnings}` — `warnings` is REQ-125's own signal (a portfolio/repo
// override lowering a shipped `gate` dial on the PM's row) and must NOT be
// conflated with this function's OWN `warnings` param (free-text
// operational messages rendered as `warning: <msg>` footer lines). Both
// are returned here, under distinct names, so the call site can route each
// to its own destination: operational failures stay in `warnings`;
// REQ-125 warnings go to `assembleBrief`'s `matrixWarnings` input (the
// rendering tier Task 11 already built and six tests already cover at the
// fixture level — this was the missing runtime wire).
function resolvePmMatrixCell(opts, deps, warnings) {
  try {
    const stackDefault = loadDefaultMatrix();
    const { repo, portfolio } = loadOverrides({
      repoConfigPath: stackConfigPath(deps),
      portfolioConfigPath: deps.portfolioConfigPath || DEFAULT_CONFIG_PATH
    });
    const { cell, warnings: matrixWarnings } = resolveMatrix(
      { agent: "pm", domainMode: opts.domain || "default", sensitivity: opts.sensitivity || "normal" },
      { repo, portfolio, stackDefault }
    );
    return { cell, matrixWarnings: matrixWarnings || [] };
  } catch (err) {
    warnings.push(`matrix resolution failed: ${err.message}`);
    return { cell: undefined, matrixWarnings: [] };
  }
}

// Task 8: the outbox is a plain file -- reading its unsent count never
// touches the transport, so it works identically whether resolution
// succeeded or failed (see bin.mjs's unreachableJournal). Best-effort: a
// read failure here must never block brief or closeout, so it swallows and
// reports zero rather than propagating.
function journalUnsentCount(deps) {
  try {
    return typeof deps.journal?.unsentCount === "function" ? deps.journal.unsentCount() : 0;
  } catch {
    return 0;
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

  const tracks = await collectTracks(deps, scope, nowIso, warnings, portfolioName);
  const { total: issueCount, byRepo: issuesByRepo, failedRepos: issueFailedRepos } = await collectIssueCount(deps, scope, warnings);
  const suggestions = await collectSuggestions(deps, portfolioName, scope, config, warnings);

  // Task 8 -- two failure classes, two different messages, never conflated
  // (review BLOCKER on the previous rev): a RESOLUTION failure (bin.mjs
  // couldn't reach directory.resolve()/createTransport() at all -- no
  // journal exists to call) is reported via deps.journalError and briefData
  // is never attempted. A TRANSPORT failure (resolution succeeded, the
  // single briefData round trip itself failed) is caught here. Either way
  // brief warns and continues -- it must never brick on a Postgres or
  // credential outage (ADR-060 §6).
  let counters = { staleCalls: 0, overridesByAgent: {}, pendingPredictions: 0 };
  let recentOverrides = [];
  if (deps.journalError) {
    warnings.push(deps.journalError);
  } else {
    try {
      const data = await deps.journal.briefData(portfolioName, Date.parse(nowIso));
      counters = data.counters;
      // REQ-113 (Task 15) -- the SAME briefData round trip Task 8 already
      // makes (never a second query): recentOverrides feeds
      // assembleBrief's challenge-suppression check below.
      recentOverrides = data.recentOverrides || [];
      // Fold-in (ADR-060 §6): "the next successful connection flushes the
      // outbox" -- brief is a read path with no other drain trigger of its
      // own, so a proven-live connection (this briefData call just
      // succeeded) is the moment to attempt it. Best-effort: a flush
      // failure must never turn a successful brief into a warning:
      // unsentCount below is read AFTER this attempt either way, so the
      // printed line reflects reality whether the drain worked or not.
      try {
        await deps.journal.flushOutbox();
      } catch {
        // best-effort; nothing to report -- the unsent line still speaks
      }
    } catch (err) {
      warnings.push(`journal data unavailable: ${err.message}`);
    }
  }

  // REQ-111 amendment (ASSUMPTION 3) -- the real spend collection, replacing
  // the P1a `spend: []` placeholder. `costLogPath` is deps-overridable
  // (mirrors `configPath`/`trackPath`) so tests never touch the real
  // `~/.claude/logs/cost-log.jsonl`.
  const spend = await collectSpend({
    readFile: deps.readFile,
    tracks,
    costLogPath: deps.costLogPath || DEFAULT_COST_LOG_PATH,
    warnings
  });

  const unsentCount = journalUnsentCount(deps);
  const { cell: matrixCell, matrixWarnings } = resolvePmMatrixCell(opts, deps, warnings);
  // REQ-117 (Task 15) -- `--override-budget "<reason>"` is the runtime
  // authoring path: the PM's judgment that a capped brief hides something
  // material re-runs brief with this flag and a stated reason. Absent, the
  // budget is enforced exactly as P1a.
  const budgetOverride = opts["override-budget"] ? { reason: opts["override-budget"] } : null;

  const { lines, fence } = assembleBrief({
    tracks,
    counters,
    suggestions,
    spend,
    unsentCount,
    nowIso,
    full: opts.full === true,
    matrixCell,
    matrixWarnings,
    recentOverrides,
    sessionId: deps.sessionId ?? null,
    budgetOverride
  });

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

  // Task 8 (ADR-060 §6, review BLOCKER): RESOLUTION failure vs TRANSPORT
  // failure are different failure classes with different closeout
  // behaviors. A resolution failure (bin.mjs never reached a working
  // journal -- no descriptor, no formed event) has nothing an outbox could
  // cover, so it must fail loud and non-zero BEFORE any mutation --
  // checked here, first, before the track-file write or any gh call. A
  // TRANSPORT failure (resolution succeeded; the DB call itself fails)
  // is handled later, at the journal step, via the outbox -- it must NOT
  // stop closeout early.
  if (deps.journalError) {
    deps.stdout(`closeout refused: ${deps.journalError} — no changes made`);
    return { command: "closeout", code: 1, completed, failed: "resolve-journal" };
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

  // Task 8: resolution already succeeded (checked above), so the PG engine's
  // append() itself never throws for a transport outage -- it queues the
  // already-formed event to the outbox and returns normally (journal-pg.mjs,
  // Task 5). Review fix: a before/after unsentCount DIFF is not exact -- a
  // drain that removes an older queued event nets against THIS append
  // queuing a new one, so the count can come back unchanged and misreport
  // a queued write as a completed one. outboxHas(eventId) asks the only
  // question that matters: is THIS event, by id, currently sitting in the
  // outbox.
  let eventId;
  try {
    eventId = await deps.journal.append(handoffEvent);
  } catch (err) {
    printFailure(deps, completed, "journal", err);
    deps.stdout(
      "closeout: event was NOT persisted anywhere (no DB, no outbox) — the handoff is lost; re-run closeout once the journal is reachable"
    );
    return { command: "closeout", code: 1, completed, failed: "journal" };
  }
  const outboxed = typeof deps.journal.outboxHas === "function" && deps.journal.outboxHas(eventId);
  completed.push(outboxed ? `journal → outbox (${journalUnsentCount(deps)} unsent)` : "journal");

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
    count = (await deps.journal.events(portfolioName)).length;
  } catch (err) {
    deps.stdout(`purge: failed to read events: ${err.message}`);
    return { command: "purge", code: 1 };
  }

  if (!opts.yes) {
    deps.stdout(`purge: would delete ${count} event(s) for portfolio "${portfolioName}". Re-run with --yes to confirm.`);
    return { command: "purge", code: 1, count };
  }

  await deps.journal.purge(portfolioName);
  deps.stdout(`purge complete: deleted ${count} event(s) for portfolio "${portfolioName}"`);
  return { command: "purge", code: 0, count };
}

// REQ-147 amendment (2026-08-08): refs kind list matches the schema CHECK
// (schemas/006-knowledge-store.sql) and journal-pg.mjs's EVENT_TYPES
// exactly -- commit sha / PR number / ADR path / spec path, by reference
// only. Kind membership is the ONLY thing the CLI pre-rejects; secret- and
// absolute-path-shaped ref values are left to the engine (legacy throws,
// PG redacts-and-flags -- see journal.mjs/journal-pg.mjs), never
// duplicated here.
const DECISION_REF_KINDS = new Set(["commit", "pr", "adr", "spec"]);

function parseRefEntry(entry) {
  const sep = entry.indexOf(":");
  if (sep < 0) {
    throw new Error(`invalid --ref entry (expected kind:ref): ${entry}`);
  }
  const kind = entry.slice(0, sep);
  const ref = entry.slice(sep + 1);
  if (!DECISION_REF_KINDS.has(kind)) {
    throw new Error(`--ref kind must be one of ${[...DECISION_REF_KINDS].join("|")}, got "${kind}"`);
  }
  if (!ref) {
    throw new Error(`invalid --ref entry (empty ref): ${entry}`);
  }
  return { kind, ref };
}

// pm decision --portfolio <p> --track <t> --question <q> --choice <c>
//   [--option <o>]... [--rationale <r>] [--ref kind:ref]... [--author <a>]
//
// REQ-147: appends a `decision` event. `subject` is stamped from --track,
// matching priority_call's existing subject_kind="track" convention
// (journal-pg.mjs's TYPE_TO_SUBJECT_KIND) -- the field `pm decisions`
// actually filters on below (decisionTrack()), client-side, under both
// engines. `track` is ALSO stamped as its own top-level field so it lands
// in PG's dedicated, indexed `track` column (idx_events_portfolio_track_ts)
// -- write-only in P1b (nothing reads it yet; events() has no server-side
// track filter). Kept because the column is real schema and a future
// server-side filter wants it populated. P2: push track filtering into
// events() and read this column instead of scanning client-side. The
// legacy engine has no `track` column and silently drops the field, which
// is fine -- subject is P1b's only source of truth either way.
async function runDecision(opts, deps) {
  const { portfolio: portfolioName, track, question, choice } = opts;
  if (!portfolioName || !track || !question || !choice) {
    deps.stdout("decision: --portfolio, --track, --question and --choice are required");
    return { command: "decision", code: 1 };
  }

  let refs;
  try {
    refs = (opts.refs || []).map(parseRefEntry);
  } catch (err) {
    deps.stdout(`decision refused: ${err.message}`);
    return { command: "decision", code: 1 };
  }

  const nowIso = typeof deps.nowIso === "function" ? deps.nowIso() : new Date().toISOString();
  const event = {
    ts: nowIso,
    type: "decision",
    subject: track,
    track,
    author: opts.author || "user",
    portfolio: portfolioName,
    body: {
      question,
      options: opts.options || [],
      choice,
      rationale: opts.rationale ?? "",
      refs
    }
  };

  let eventId;
  try {
    eventId = await deps.journal.append(event);
  } catch (err) {
    deps.stdout(`decision refused: ${err.message}`);
    return { command: "decision", code: 1 };
  }

  deps.stdout(`decision journaled: ${eventId}`);
  return { command: "decision", code: 0, eventId };
}

// A decision event's track lives under `subject` (legacy) or `subject_id`
// (PG) -- see runDecision's comment above for why that's the field this
// reads, rather than the PG-only `track` column (write-only in P1b).
function decisionTrack(e) {
  return e.subject ?? e.subject_id;
}

// pm decisions --portfolio <p> --track <t>
//
// REQ-147 accept: returns the decision list for a track, outcomes joined
// via ref_event_id. Filtering is CLIENT-side: journal.events() has no
// server-side track parameter, so this fetches every event for the
// portfolio and filters in JS via decisionTrack() above. Fine at P1b's
// event volume; P2: push the track filter into events() itself (both
// engines) once volume warrants it. Relies on journal.events() already
// returning rows ordered by ts (both engines) -- no re-sort needed here.
async function runDecisions(opts, deps) {
  const portfolioName = opts.portfolio;
  const track = opts.track;
  if (!portfolioName || !track) {
    deps.stdout("decisions: --portfolio and --track are required");
    return { command: "decisions", code: 1 };
  }

  let events;
  try {
    events = await deps.journal.events(portfolioName);
  } catch (err) {
    deps.stdout(`decisions: failed to read events: ${err.message}`);
    return { command: "decisions", code: 1 };
  }

  const outcomes = events.filter((e) => e.type === "outcome");
  const decisions = events
    .filter((e) => e.type === "decision" && decisionTrack(e) === track)
    .map((e) => ({
      event_id: e.event_id,
      ts: e.ts,
      author: e.author,
      body: e.body,
      outcome: outcomes.find((o) => o.ref_event_id === e.event_id)?.body ?? null
    }));

  deps.stdout(JSON.stringify(decisions));
  return { command: "decisions", code: 0, decisions };
}

// pm override --portfolio <p> --ref <event_id> --caller "<pos>" --user "<pos>"
//
// REQ-113: one command = one user turn. `--ref` is parseArgs's shared
// generic flag (also used by `pm decision`'s `--ref kind:ref` entries) --
// it always collects into `opts.refs` regardless of command, so override
// takes the FIRST collected value as the plain event_id it overrides (no
// "kind:" parsing; that convention is decision's, not override's).
// Both positions are required and checked HERE, before the journal is ever
// touched -- the accept criterion is "rejected at CLI", not "rejected by
// whichever engine happens to validate override bodies" (legacy throws on
// a missing position; the PG engine is shape-only and would not catch
// this on its own). `ref_event_id` is read back via `recentOverrides`
// (briefData, Task 5) for brief.mjs's suppression check (Task 15) -- no
// second query, no dedicated read path for this command.
async function runOverride(opts, deps) {
  const portfolioName = opts.portfolio;
  const ref = opts.refs && opts.refs[0];
  const { caller, user } = opts;
  if (!portfolioName || !ref || !caller || !user) {
    deps.stdout("override: --portfolio, --ref, --caller and --user are required");
    return { command: "override", code: 1 };
  }

  const nowIso = typeof deps.nowIso === "function" ? deps.nowIso() : new Date().toISOString();
  const event = {
    ts: nowIso,
    type: "override",
    subject: opts.subject || "pm",
    ref_event_id: ref,
    author: opts.author || "user",
    portfolio: portfolioName,
    body: {
      positions: { caller, user }
    }
  };

  let eventId;
  try {
    eventId = await deps.journal.append(event);
  } catch (err) {
    deps.stdout(`override refused: ${err.message}`);
    return { command: "override", code: 1 };
  }

  deps.stdout(`override journaled: ${eventId}`);
  return { command: "override", code: 0, eventId };
}

function printMigrateReport(deps, report) {
  deps.stdout(
    `migrate: ${report.totalRows} row(s) read, ${report.remapCount} remapped, ` +
      `${report.passthroughCount} already-v7 passthrough, ${report.ambiguousSubjectKind} ambiguous subject_kind, ` +
      `${report.malformed.length} malformed`
  );
  for (const m of report.malformed) {
    deps.stdout(`  malformed: ${m.event_id}: ${m.reason}`);
  }
  for (const [key, count] of Object.entries(report.byTypePortfolio).sort()) {
    const [type, portfolio] = key.split("|");
    deps.stdout(`  ${type} / ${portfolio}: ${count}`);
  }
  if (report.preflight) printPreflight(deps, report.preflight);
}

function printPreflight(deps, preflight) {
  if (!preflight.ran) {
    deps.stdout(`migrate: pre-flight skipped (${preflight.skippedReason})`);
    return;
  }
  deps.stdout(
    preflight.missingPortfolios.length
      ? `migrate: pre-flight -- missing portfolio(s) in destination: ${preflight.missingPortfolios.join(", ")}`
      : "migrate: pre-flight -- all source portfolios exist in destination"
  );
  if (preflight.userIdChecked) {
    deps.stdout(`migrate: pre-flight -- --user-id ${preflight.userIdExists ? "exists" : "MISSING"} in stack.users`);
  }
}

// pm migrate --from <path>.sqlite[.migrated] [--dry-run] [--user-id <uuid>]
//
// ADR-060 §6 + the Migration amendment. Dry run reads and reports only,
// writes/renames nothing -- but WILL run a read-only destination
// pre-flight (portfolios exist, --user-id exists) when deps.transport is
// supplied, since that's cheap and catches a live run's most likely
// failure mode before it's attempted. `bin.mjs` doesn't wire a transport
// for `pm migrate` yet, so today's dry runs report the pre-flight as
// skipped, not run. A live run inserts (idempotent, ON CONFLICT DO
// NOTHING via importEvents), checks (type, portfolio) parity against the
// destination, and finalizes (renames to `.migrated`) ONLY on a parity
// PASS -- a parity failure leaves the source file exactly as it was, so a
// re-run can be attempted once the underlying problem is understood. The
// 30-day delete after that is a human act (§6's actual rollback plan),
// never automated here.
async function runMigrate(opts, deps) {
  const fromPath = opts.from;
  if (!fromPath) {
    deps.stdout("migrate: --from is required");
    return { command: "migrate", code: 1 };
  }
  const dryRun = opts.dryRun === true;

  if (!dryRun && !opts["user-id"]) {
    deps.stdout("migrate: --user-id is required for a live (non-dry-run) migration");
    return { command: "migrate", code: 1 };
  }

  let sourceDb;
  try {
    sourceDb = openSourceDb(fromPath);
  } catch (err) {
    deps.stdout(`migrate: failed to open source at ${fromPath}: ${err.message}`);
    return { command: "migrate", code: 1 };
  }

  let report;
  try {
    report = await importEvents(sourceDb, deps.transport, { dryRun, userId: opts["user-id"] });
  } catch (err) {
    deps.stdout(`migrate: import failed: ${err.message}`);
    return { command: "migrate", code: 1 };
  } finally {
    sourceDb.close();
  }

  printMigrateReport(deps, report);

  if (dryRun) {
    deps.stdout("migrate: dry run complete -- nothing written, nothing renamed");
    return { command: "migrate", code: 0, report };
  }

  deps.stdout(`migrate: inserted ${report.insertedCount} row(s); parity ${report.parityOk ? "PASS" : "FAIL"}`);
  if (!report.parityOk) {
    deps.stdout("migrate: parity check FAILED -- source left untouched, not finalized");
    return { command: "migrate", code: 1, report };
  }

  if (isFinalizedPath(fromPath)) {
    deps.stdout("migrate: source path already ends in .migrated -- nothing to rename");
    return { command: "migrate", code: 0, report };
  }

  // Fold-in (operator safety): a rename failure here (permissions, disk,
  // the file moved out from under us) must NOT read like a failed import
  // -- inserts already landed and parity already passed. Caught
  // separately so the operator knows the data is safe in the destination
  // and only the source-file housekeeping needs a manual `mv`.
  try {
    const finalPath = finalizeMigration(fromPath);
    deps.stdout(`migrate: finalized -- renamed to ${finalPath}. Delete after 30 days is a human act, not automated.`);
    return { command: "migrate", code: 0, report, finalPath };
  } catch (err) {
    deps.stdout(
      `migrate: inserted ${report.insertedCount} row(s), parity PASSED, but finalize (rename) FAILED: ${err.message}`
    );
    deps.stdout(`migrate: data is safe in the destination -- rename ${fromPath} to ${fromPath}.migrated by hand`);
    return { command: "migrate", code: 1, report };
  }
}

function setMatrixCell(matrixTree, agent, domainMode, sensitivity, cell) {
  const tree = { ...matrixTree };
  tree[agent] = { ...(tree[agent] || {}) };
  tree[agent][domainMode] = { ...(tree[agent][domainMode] || {}) };
  tree[agent][domainMode][sensitivity] = cell;
  return tree;
}

// pm matrix set --portfolio <p> --agent <a> [--domain <mode>] [--sensitivity <s>]
//   --dial <assertiveness|autonomy> --value <ladder-value> [--confirm-lower]
//
// REQ-125 change-control. Writes into config/portfolio.json's `.matrix`
// tree (the "portfolio" override layer resolveMatrix already understands —
// REQ-121 precedence). `before` is derived, never user-supplied: the
// currently-resolved cell for this (agent, domainMode, sensitivity), so the
// lowering check always compares against what is actually in effect right
// now, not a value the caller could get wrong or lie about.
async function runMatrixSet(opts, deps) {
  const { agent, portfolio: portfolioName, dial } = opts;
  const domainMode = opts.domain || "default";
  const sensitivity = opts.sensitivity || "normal";
  const after = opts.value;

  if (!agent || !portfolioName || !dial || after === undefined) {
    deps.stdout("matrix set: --agent, --portfolio, --dial and --value are required");
    return { command: "matrix", code: 1 };
  }
  if (!DIALS.includes(dial)) {
    deps.stdout(`matrix set: --dial must be one of ${DIALS.join("|")}`);
    return { command: "matrix", code: 1 };
  }
  if (!LADDER.includes(after)) {
    deps.stdout(`matrix set: --value must be one of ${LADDER.join("|")}`);
    return { command: "matrix", code: 1 };
  }

  let config;
  try {
    config = await loadConfig(deps);
  } catch (err) {
    deps.stdout(`matrix set refused: cannot load portfolio config: ${err.message}`);
    return { command: "matrix", code: 1 };
  }

  const stackDefault = loadDefaultMatrix();
  const { cell: currentCell } = resolveMatrix(
    { agent, domainMode, sensitivity },
    { portfolio: config.matrix, stackDefault }
  );
  const before = currentCell?.[dial];
  if (!before) {
    deps.stdout(`matrix set refused: no resolvable current value for ${agent}/${domainMode}/${sensitivity}.${dial}`);
    return { command: "matrix", code: 1 };
  }

  const nowIso = typeof deps.nowIso === "function" ? deps.nowIso() : new Date().toISOString();
  // editMatrix is pure — it only decides and (for a confirmed gated
  // lowering) builds the matrix_change event. It does NOT journal. Review
  // fix: journaling before the config write risked a permanent journal
  // record for a change that never actually took effect if the write then
  // failed — the opposite of REQ-125's audit-trail purpose. So the write
  // happens first, and the journal append (if any) happens only after it
  // succeeds, mirroring runCloseout's journal-last pattern (see above).
  const result = editMatrix({
    agent, domainMode, sensitivity, dial, before, after,
    confirmLower: opts.confirmLower === true, portfolio: portfolioName, nowIso
  });

  if (!result.ok) {
    deps.stdout(`matrix set refused: ${result.reason}`);
    return { command: "matrix", code: 1, reason: result.reason };
  }

  const updatedCell = { ...currentCell, [dial]: after };
  const updatedConfig = { ...config, matrix: setMatrixCell(config.matrix || {}, agent, domainMode, sensitivity, updatedCell) };

  try {
    await deps.writeFile(deps.configPath || DEFAULT_CONFIG_PATH, JSON.stringify(updatedConfig, null, 2), "utf8");
  } catch (err) {
    deps.stdout(`matrix set refused: failed to write config, nothing applied, no journal entry made: ${err.message}`);
    return { command: "matrix", code: 1, before, after };
  }

  let eventId;
  if (result.event) {
    try {
      eventId = await deps.journal.append(result.event);
    } catch (err) {
      // Config write already succeeded at this point — a journal failure
      // here means the change TOOK EFFECT but the audit record is
      // missing, a narrower and more honestly-reported problem than a
      // journal entry for a change that never happened.
      deps.stdout(
        `matrix set: config written (${agent}/${domainMode}/${sensitivity}.${dial} ${before} -> ${after}) but journal write failed, no audit record: ${err.message}`
      );
      return { command: "matrix", code: 1, before, after };
    }
  }

  deps.stdout(
    `matrix set: ${agent}/${domainMode}/${sensitivity}.${dial} ${before} -> ${after}` +
      (eventId ? ` (journaled ${eventId})` : "")
  );
  return { command: "matrix", code: 0, before, after, eventId };
}

// pm matrix resolve --agent <a> [--domain <mode>] [--sensitivity <s>]
//
// REQ-122 — read-only. The SAME resolver foreman calls before dispatching a
// subagent and PM calls for challenge level (Task 15): one resolver, both
// consumers. Never writes, never journals. `resolveMatrix` itself never
// throws and normalizes an unknown domain/sensitivity to "default"/"normal"
// (matrix.mjs) and falls through to the shipped fallback cube for an agent
// present in no layer — so an unrecognized `--agent` still resolves to a
// real cell and exits 0. Dispatch must never brick on a bad or stale agent
// name.
function runMatrixResolve(opts, deps) {
  const { agent } = opts;
  const domainMode = opts.domain || "default";
  const sensitivity = opts.sensitivity || "normal";

  if (!agent) {
    deps.stdout("matrix resolve: --agent is required");
    return { command: "matrix", code: 1 };
  }

  const stackDefault = loadDefaultMatrix();
  const { repo, portfolio } = loadOverrides({
    repoConfigPath: stackConfigPath(deps),
    portfolioConfigPath: deps.portfolioConfigPath || DEFAULT_CONFIG_PATH
  });

  const { cell, warnings } = resolveMatrix({ agent, domainMode, sensitivity }, { repo, portfolio, stackDefault });

  deps.stdout(JSON.stringify({ cell: cell ?? null, warnings }));
  return { command: "matrix", code: 0, cell, warnings };
}

async function runMatrix(opts, deps) {
  if (opts.subcommand === "set") {
    return runMatrixSet(opts, deps);
  }
  if (opts.subcommand === "resolve") {
    return runMatrixResolve(opts, deps);
  }
  deps.stdout(`matrix: unknown subcommand '${opts.subcommand || ""}' — expected 'set' or 'resolve'`);
  return { command: "matrix", code: 1 };
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

  if (command === "migrate") {
    try {
      return await runMigrate(opts, deps);
    } catch (err) {
      deps.stdout(`migrate: unexpected error: ${err.message}`);
      return { command: "migrate", code: 1 };
    }
  }

  if (command === "matrix") {
    try {
      return await runMatrix(opts, deps);
    } catch (err) {
      deps.stdout(`matrix: unexpected error: ${err.message}`);
      return { command: "matrix", code: 1 };
    }
  }

  if (command === "decision") {
    try {
      return await runDecision(opts, deps);
    } catch (err) {
      deps.stdout(`decision: unexpected error: ${err.message}`);
      return { command: "decision", code: 1 };
    }
  }

  if (command === "decisions") {
    try {
      return await runDecisions(opts, deps);
    } catch (err) {
      deps.stdout(`decisions: unexpected error: ${err.message}`);
      return { command: "decisions", code: 1 };
    }
  }

  if (command === "override") {
    try {
      return await runOverride(opts, deps);
    } catch (err) {
      deps.stdout(`override: unexpected error: ${err.message}`);
      return { command: "override", code: 1 };
    }
  }

  deps.stdout(`unknown command: ${command}`);
  return { command, code: 1 };
}
