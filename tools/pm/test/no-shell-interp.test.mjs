import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

// REQ-116: every subprocess call in tools/pm must be execFile/execFileSync
// with an argument array — never exec()/execSync(), which pass a string
// through a shell and reopen the interpolation hole this tool exists to
// close. `shell: true` on any spawn-family call is the same hole by
// another name. This guard scans the real source (not just today's
// call sites) so a shell-string call added later fails the suite instead
// of shipping.
//
// Deliberate exception: node:sqlite's `DatabaseSync#exec()` (src/journal.mjs,
// static DDL strings, no external input) has nothing to do with child
// processes or shells. It is excluded by name (`db.exec(`) rather than by
// broadly allowing any `<obj>.exec(`, so `cp.exec(`/`child_process.exec(`
// style calls still fail. The exclusion is anchored on a `\b` word
// boundary before `db.` — a plain `(?<!db\.)` lookbehind would also
// exempt any identifier merely ENDING in "db" (`somedb.exec(`,
// `leveldb.exec(`), since a lookbehind only checks the characters
// immediately preceding the match, not where that text starts.
const EXEC_VIOLATION_RE = /(?<!\bdb\.)\bexec(?:Sync)?\s*\(/g;
const SHELL_TRUE_RE = /shell\s*:\s*true/g;

const __dirname = dirname(fileURLToPath(import.meta.url));
const PM_ROOT = join(__dirname, "..");
// The guard's own source necessarily contains the strings it forbids (to
// define and self-test the regexes below) — it is excluded from the scan
// it performs, the same way an eslint rule's own file is exempt from its
// own rule.
const SELF = basename(fileURLToPath(import.meta.url));

function mjsFilesIn(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".mjs"))
    .map((f) => join(dir, f));
}

function targetFiles() {
  return [
    ...mjsFilesIn(join(PM_ROOT, "src")),
    join(PM_ROOT, "bin.mjs"),
    ...mjsFilesIn(join(PM_ROOT, "test")).filter((f) => basename(f) !== SELF)
  ];
}

function findViolations(re, content) {
  re.lastIndex = 0;
  const hits = [];
  let m;
  while ((m = re.exec(content))) {
    hits.push({ line: content.slice(0, m.index).split("\n").length, text: m[0] });
  }
  return hits;
}

function scanAll(re) {
  const offenders = [];
  for (const file of targetFiles()) {
    const content = readFileSync(file, "utf8");
    for (const hit of findViolations(re, content)) {
      offenders.push(`${file}:${hit.line}: ${hit.text}`);
    }
  }
  return offenders;
}

test("REQ-116: no exec(/execSync( shell-string calls in tools/pm/src, bin.mjs, or tools/pm/test", () => {
  const offenders = scanAll(EXEC_VIOLATION_RE);
  assert.equal(offenders.length, 0, `Forbidden exec(/execSync( call(s):\n${offenders.join("\n")}`);
});

test("REQ-116: no shell:true in tools/pm/src, bin.mjs, or tools/pm/test", () => {
  const offenders = scanAll(SHELL_TRUE_RE);
  assert.equal(offenders.length, 0, `Forbidden shell:true usage(s):\n${offenders.join("\n")}`);
});

test("REQ-116 self-check: the guard actually catches violations (not a vacuous pass)", () => {
  const fakeExec = ["import { exec } from ", '"node:child_process";', "", "exec(`gh issue list --repo ${repo}`);", ""].join("\n");
  assert.equal(findViolations(EXEC_VIOLATION_RE, fakeExec).length, 1);

  const fakeMethodExec = "cp.exec(cmd);";
  assert.equal(findViolations(EXEC_VIOLATION_RE, fakeMethodExec).length, 1);

  const fakeExecSync = "execSync(cmd);";
  assert.equal(findViolations(EXEC_VIOLATION_RE, fakeExecSync).length, 1);

  const fakeShellTrue = "spawn(cmd, args, { shell: true });";
  assert.equal(findViolations(SHELL_TRUE_RE, fakeShellTrue).length, 1);

  // execFile/execFileSync must never trip the exec( detector.
  const safeExecFile = "await execFile(cmd, args);\nexecFileSync(cmd, args);";
  assert.equal(findViolations(EXEC_VIOLATION_RE, safeExecFile).length, 0);

  // db.exec( (node:sqlite DatabaseSync) is the one deliberate exception.
  const safeDbExec = 'db.exec("PRAGMA journal_mode = WAL");';
  assert.equal(findViolations(EXEC_VIOLATION_RE, safeDbExec).length, 0);

  // The db.exec( exception must be anchored to the literal identifier
  // `db`, not any identifier ending in "db" — somedb./leveldb. are real
  // shell-exec risks and must still be flagged.
  const lookalikeDbExec = "somedb.exec(x); leveldb.exec(y);";
  assert.equal(findViolations(EXEC_VIOLATION_RE, lookalikeDbExec).length, 2);
});
