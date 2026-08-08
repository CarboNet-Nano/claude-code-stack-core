#!/usr/bin/env node
import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import { readFile, writeFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { openJournal } from "./src/journal.mjs";
import { main } from "./src/cli.mjs";

// Track files live per-member-repo under a local checkout, not under this
// tool's own tree — map "org/repo" -> ~/Antigravity/<repo-basename>/.claude/tracks/*.md.
// Pragmatic: assumes member repos are checked out flat under ~/Antigravity.
async function glob(repos) {
  const result = {};
  for (const repo of repos) {
    const dir = join(homedir(), "Antigravity", basename(repo), ".claude", "tracks");
    try {
      const entries = await readdir(dir);
      result[repo] = entries.filter((f) => f.endsWith(".md")).map((f) => join(dir, f));
    } catch {
      result[repo] = [];
    }
  }
  return result;
}

const deps = {
  execFile: promisify(execFileCb),
  journal: openJournal(join(homedir(), ".claude", "data", "pm-journal.sqlite")),
  readFile: (p) => readFile(p, "utf8"),
  writeFile: (p, c) => writeFile(p, c, "utf8"),
  glob,
  stdout: (line) => console.log(line),
  nowIso: () => new Date().toISOString()
};

const result = await main(process.argv.slice(2), deps);
process.exitCode = result?.code ?? 0;
