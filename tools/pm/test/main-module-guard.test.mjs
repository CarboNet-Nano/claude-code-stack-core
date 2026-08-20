import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, symlinkSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { isMainModule } from "../bin.mjs";

// Review fix (Task 17 round 1) — the is-main-module guard used to compare
// `import.meta.url` (loader-resolved, i.e. symlink-free) against a raw
// `process.argv[1]` (exactly as invoked, symlink and all). Any symlinked
// invocation path — a stack install's `~/.claude/tools/pm` pointing at this
// repo, a symlinked macOS `/tmp`, a CI workspace symlink — made the
// comparison false, so `run()` silently never fired: no output, no error,
// no non-zero exit. `isMainModule` fixes this by realpath-resolving argv[1]
// before comparing. These tests exercise the fixed predicate directly,
// through real symlinks on disk, rather than spawning a subprocess (which
// would also need to resolve real Postgres credentials via `run()`).

const __dirname = dirname(fileURLToPath(import.meta.url));
const REAL_BIN_PATH = join(__dirname, "..", "bin.mjs");
const MODULE_URL = pathToFileURL(realpathSync(REAL_BIN_PATH)).href;

test("isMainModule: true for the real, non-symlinked invocation path (the common case must keep working)", () => {
  assert.equal(isMainModule(MODULE_URL, REAL_BIN_PATH), true);
});

test("isMainModule: true when argv[1] is a symlinked FILE pointing at bin.mjs", () => {
  const tmp = mkdtempSync(join(tmpdir(), "pm-bin-symlink-file-"));
  try {
    const symlinkPath = join(tmp, "bin.mjs");
    symlinkSync(REAL_BIN_PATH, symlinkPath);
    assert.equal(isMainModule(MODULE_URL, symlinkPath), true);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("isMainModule: true when argv[1] is reached through a symlinked DIRECTORY (the real-world case — a symlinked ~/.claude/tools/pm)", () => {
  const tmp = mkdtempSync(join(tmpdir(), "pm-bin-symlink-dir-"));
  try {
    const pmRealDir = dirname(REAL_BIN_PATH);
    const symlinkedDir = join(tmp, "pm");
    symlinkSync(pmRealDir, symlinkedDir);
    const invokedPath = join(symlinkedDir, "bin.mjs");
    assert.equal(isMainModule(MODULE_URL, invokedPath), true);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("isMainModule: false for an unrelated real file (not a false positive)", () => {
  const tmp = mkdtempSync(join(tmpdir(), "pm-bin-unrelated-"));
  try {
    const unrelated = join(tmp, "not-bin.mjs");
    writeFileSync(unrelated, "// not bin.mjs\n");
    assert.equal(isMainModule(MODULE_URL, unrelated), false);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("isMainModule: false, never throws, for a path that doesn't exist on disk", () => {
  assert.equal(isMainModule(MODULE_URL, "/definitely/does/not/exist/bin.mjs"), false);
});

test("isMainModule: false, never throws, when argv[1] is absent (module reached via import(), not `node bin.mjs`)", () => {
  assert.equal(isMainModule(MODULE_URL, undefined), false);
});
