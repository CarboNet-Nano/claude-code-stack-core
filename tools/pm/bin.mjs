#!/usr/bin/env node
import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import { readFile, writeFile, readdir } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { createHash } from "node:crypto";
import { join, basename, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve as resolveDirectory } from "./src/directory.mjs";
import { createTransport } from "./src/db.mjs";
import { openPgJournal } from "./src/journal-pg.mjs";
import { unsentCount as outboxUnsentCount } from "./src/outbox.mjs";
import { main } from "./src/cli.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORTFOLIO_CONFIG_PATH = join(__dirname, "..", "..", "config", "portfolio.json");
const DEFAULT_CHECKOUT_ROOT = join(homedir(), "Antigravity");

// ASSUMPTION 5 -- `~` and `~/…` expand against `home` (real homedir() at
// runtime, injected in tests) the same way a shell would. Any other value
// (already-absolute, or relative with no leading `~`) passes through
// unchanged -- this is purely a convenience so config/portfolio.json and
// PM_CHECKOUT_ROOT can be written portably (`~/Antigravity`) instead of a
// machine-specific absolute path.
function expandHome(path, home) {
  if (path === "~") return home;
  if (path.startsWith("~/")) return join(home, path.slice(2));
  return path;
}

// ASSUMPTION 5 -- checkout_root precedence: env PM_CHECKOUT_ROOT wins over
// config/portfolio.json's per-portfolio `checkout_root`, which wins over the
// flat-layout default (`~/Antigravity`). Every dependency is injectable so
// this is directly unit-testable without spawning bin.mjs as a subprocess
// (importing this module has no side effects -- see the `run()` guard at
// the bottom of the file). A missing/unreadable config, or a portfolioName
// absent from it, falls through silently to the default -- resolving the
// checkout root must never brick track discovery.
export async function resolveCheckoutRoot(
  portfolioName,
  {
    env = process.env,
    readFileImpl = readFile,
    configPath = PORTFOLIO_CONFIG_PATH,
    defaultRoot = DEFAULT_CHECKOUT_ROOT,
    home = homedir()
  } = {}
) {
  if (env.PM_CHECKOUT_ROOT) return expandHome(env.PM_CHECKOUT_ROOT, home);

  try {
    const raw = await readFileImpl(configPath, "utf8");
    const config = JSON.parse(raw);
    const root = config.portfolios?.[portfolioName]?.checkout_root;
    if (root) return expandHome(root, home);
  } catch {
    // config missing/unreadable/malformed, or portfolio not present in it --
    // fall through to the default rather than blocking track discovery.
  }

  return defaultRoot;
}

// Track files live per-member-repo under a local checkout, not under this
// tool's own tree — map "org/repo" -> <checkout_root>/<repo-basename>/.claude/tracks/*.md.
// `resolveCheckoutRootImpl` is injectable so tests can assert config/env
// precedence with a fake readdir, never touching the real filesystem.
export function createGlob({ readdirImpl = readdir, resolveCheckoutRootImpl = resolveCheckoutRoot } = {}) {
  return async function glob(repos, portfolioName) {
    const checkoutRoot = await resolveCheckoutRootImpl(portfolioName);
    const result = {};
    for (const repo of repos) {
      const dir = join(checkoutRoot, basename(repo), ".claude", "tracks");
      try {
        const entries = await readdirImpl(dir);
        result[repo] = entries.filter((f) => f.endsWith(".md")).map((f) => join(dir, f));
      } catch {
        result[repo] = [];
      }
    }
    return result;
  };
}

const glob = createGlob();

// ADR-060 §6/Task 8 cutover: bin.mjs wires the org Postgres store, not the
// P1a SQLite engine (journal.mjs) any more -- that engine stays only for
// the migrate tool's fixtures and cli.test.mjs's purge tests. One org for
// now (§2 Layer A: one directory entry, "carbonet").
const ORG_ID = "carbonet";
const PRODUCER = "stack@p1b";
const outboxPath = join(homedir(), ".claude", "data", "pm-outbox.ndjson");

// F4/REQ-144: machine_id is a stable HASH of hostname, never the cleartext
// hostname itself (a cleartext hostname can be personally identifying).
function machineIdHash() {
  return createHash("sha256").update(hostname()).digest("hex");
}

// A journal built when directory.resolve()/createTransport() themselves
// threw (RESOLUTION failure -- no descriptor, no formed event, nothing an
// outbox could cover): every data method rethrows the SAME actionable
// message (the Keychain command lives inside directory.mjs's thrown error).
// unsentCount()/flushOutbox() stay real -- the outbox is a plain file,
// independent of whether THIS process can currently resolve credentials --
// so `pm brief` can still report events queued by a past, successfully
// resolved run.
function unreachableJournal(message) {
  const fail = async () => {
    throw new Error(message);
  };
  return {
    append: fail,
    attachOutcome: fail,
    events: fail,
    counters: fail,
    briefData: fail,
    purge: fail,
    sweepRetention: fail,
    unsentCount: () => outboxUnsentCount(outboxPath),
    flushOutbox: async () => ({ sent: 0, remaining: outboxUnsentCount(outboxPath) })
  };
}

// Issue #150 -- this is bin.mjs's one resolveDirectory()+createTransport()
// seam, previously used only to build the journal. `pm migrate` (cli.mjs's
// runMigrate) already reads deps.transport -- see migrate.test.mjs -- but
// nothing upstream of it ever set that field, so a real invocation always
// saw `undefined` and the only way to hand `pm migrate` a real transport
// was scripts/task7-live-migrate.mjs's standalone harness. Returning the
// SAME transport this function builds the journal with (rather than
// resolving a second one) means `pm migrate` rides the one credential
// chain ($STACK_DB_URL env -> Keychain, directory.mjs) every other command
// already uses, into the same org database the journal writes to -- not a
// second, parallel credential path. Every dependency is injectable
// (matching createGlob's pattern above) so this is unit-testable without
// resolving real credentials or opening a real connection; see
// test/bin-transport.test.mjs.
export async function buildJournal({
  resolveDirectoryImpl = resolveDirectory,
  createTransportImpl = createTransport,
  openPgJournalImpl = openPgJournal
} = {}) {
  try {
    const { descriptor, userId } = await resolveDirectoryImpl(ORG_ID);
    const transport = await createTransportImpl(descriptor);
    const journal = openPgJournalImpl({
      transport,
      orgId: ORG_ID,
      userId,
      producer: PRODUCER,
      outboxPath,
      sessionId: process.env.CLAUDE_SESSION_ID || null,
      machineId: machineIdHash()
    });
    return { journal, journalError: null, transport };
  } catch (err) {
    const message = `journal unreachable: ${err.message}`;
    return { journal: unreachableJournal(message), journalError: message, transport: null };
  }
}

// Actual CLI execution lives behind this guard so importing bin.mjs (e.g.
// from a test that only wants resolveCheckoutRoot/createGlob) never
// resolves real credentials, opens a real transport, or runs a command --
// none of that happens at module-evaluation time any more.
async function run() {
  const { journal, journalError, transport } = await buildJournal();

  const deps = {
    execFile: promisify(execFileCb),
    journal,
    journalError,
    transport,
    readFile: (p) => readFile(p, "utf8"),
    writeFile: (p, c) => writeFile(p, c, "utf8"),
    glob,
    stdout: (line) => console.log(line),
    nowIso: () => new Date().toISOString(),
    // REQ-113/ASSUMPTION 8 -- the CURRENT session's identity, for brief.mjs's
    // override-suppression check (Task 15). Same source as the journal
    // ctx.sessionId above (stamped onto appended events), read independently
    // here since brief never appends anything.
    sessionId: process.env.CLAUDE_SESSION_ID || null
  };

  const result = await main(process.argv.slice(2), deps);
  process.exitCode = result?.code ?? 0;
}

// Review fix (Task 17 round 1) — `import.meta.url` is resolved through the
// REAL path by Node's default (non---preserve-symlinks) module loader, but
// `process.argv[1]` is the invocation path exactly as typed/passed, symlink
// and all. Any symlinked invocation (a stack install's `~/.claude/tools/pm`
// pointing at this repo, a symlinked macOS `/tmp`, a CI workspace symlink)
// made the naive string comparison false, so `run()` never fired -- no
// output, no error, no non-zero exit, just silent nothing. `realpathSync`
// resolves argv[1] through any symlinks first so both sides are compared as
// the same kind of path; `pathToFileURL` (not manual `file://` string
// concatenation) handles platform/encoding edge cases the same way the
// loader does. A missing/unreadable argv[1] (e.g. this module reached via
// `import()` from a test, with no argv[1] at all) resolves to `false`, never
// throws.
export function isMainModule(moduleUrl, argvPath) {
  if (!argvPath) return false;
  try {
    return moduleUrl === pathToFileURL(realpathSync(argvPath)).href;
  } catch {
    return false;
  }
}

if (isMainModule(import.meta.url, process.argv[1])) {
  await run();
}
