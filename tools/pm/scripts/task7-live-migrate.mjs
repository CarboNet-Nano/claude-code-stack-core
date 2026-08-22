// Task 7 checkpoint harness (P1b plan): drives the LIVE one-shot migration
// with a real transport. Lives under scripts/, not test/ (review fix,
// Task 8): node --test globs every .mjs under test/ automatically, and
// this file's CLI-args usage() exit(2) made the suite report a false
// failure on every run even though it isn't a test. Run manually, never
// under node --test:
//   STACK_DB_URL_WRITER=... node scripts/task7-live-migrate.mjs <sqlite-path> <user-id> [--dry-run]
import { createTransport } from "../src/db.mjs";
import { importEvents, finalizeMigration, openSourceDb } from "../src/migrate.mjs";

const [src, userId, flag] = process.argv.slice(2);
const url = process.env.STACK_DB_URL_WRITER;
if (!src || !userId || !url) {
  console.error("usage: STACK_DB_URL_WRITER=... node scripts/task7-live-migrate.mjs <sqlite-path> <user-id> [--dry-run]");
  process.exit(2);
}
const dryRun = flag === "--dry-run";
const transport = await createTransport({ connectionString: url });
const sourceDb = openSourceDb(src);
const report = await importEvents(sourceDb, transport, { dryRun, userId });
console.log(JSON.stringify(report, null, 2));
if (!dryRun && report.parityOk === true) {
  finalizeMigration(src);
  console.log(`finalized: ${src} renamed to ${src}.migrated`);
} else if (!dryRun) {
  console.error("parity FAILED -- source NOT renamed");
  process.exit(1);
}
