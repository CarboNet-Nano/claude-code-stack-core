#!/usr/bin/env bash
# scripts/sweep/checks/a4-column-writes.sh — A4: is every column of every
# declared table either written by a declared write-path file, or covered
# by a reasoned write_never entry? (stack ADR-078, spec S4.6 A4). Reproduces
# audit row #11: two columns existed since launch, never populated, 0 of 6
# events resolved in 7.5 weeks — a static, no-DB-required check that would
# have caught it on day one.
#
# Reads sweep-job/v1 on stdin (task 4's contract). Config
# (`.config`, the `families.A4` block — schemas/sweep-config.json):
#   tables             string[]  table names to check (as written by the
#                                repo's config; not normalized in output)
#   write_path_globs   string[]  glob patterns (matched against every
#                                repo file's REPO_ROOT-relative path, `*`
#                                and `**` both match across `/`) — files a
#                                column name is considered "written" by if
#                                it appears anywhere in one of them, as a
#                                whole word. Dollar-quoted routine bodies
#                                in the migrations also count as write
#                                paths (queue #227); truly dynamic writes
#                                (e.g. a data-driven jsonb map) still need
#                                a write_never entry naming the mechanism
#   write_never        {unit, reason}[]  unit = "table.column" (same shape
#                                as A1/A2/E1's `exclusions[]` — this is
#                                deliberately not a bespoke `{column,
#                                reason}` shape: schemas/sweep-config.json's
#                                A4 block already ships with this exact
#                                {unit, reason} contract, so this check
#                                follows the shipped schema rather than
#                                inventing a second one)
#   migrations_glob    string    OPTIONAL, default "supabase/migrations/*.sql".
#                                Glob (dir + single-`*` basename pattern)
#                                for the SQL files the column universe is
#                                parsed from.
#
# COLUMN UNIVERSE — the honest, degraded case (spec S4.6 A4 prefers
# introspecting an ephemeral Postgres built from migrations; that needs a
# live server and is unavailable to a hermetic test). This check instead
# parses CREATE TABLE / ALTER TABLE ADD COLUMN statements out of the
# configured tables' migration files with a small embedded Node parser
# (Node is a permitted "self-contained" dependency, same precedent as
# e1-load-routes.mjs) and reports evidence.measurement.source /
# job.evidence_basis as "static-source" throughout — never claiming a
# generated-world or production-data basis it did not earn. Known,
# accepted limitations of this degraded parse (documented rather than
# silently wrong): it does not track ALTER TABLE ... DROP COLUMN (a
# dropped column can linger in the reported universe until the migration
# that dropped it is itself understood — out of scope for a static parser
# with no DB to ask), and it folds unquoted identifiers to lowercase per
# Postgres's own casing rule but cannot recover a quoted identifier's
# original case fidelity.
#
# DEFERRED, DELIBERATELY NOT BUILT: a live-Postgres column universe via
# `DATABASE_URL`. It would be simple code (one information_schema query
# per table) but it is dead code under the current runner wiring —
# sweep-run.sh's build_job hardcodes evidence_basis:"static-source" and
# connection:null for every phase-1 check, and build_check_env's env
# allowlist has no DSN entry for A4 (only a check's declared
# `base_url_env`, which A4's schema block does not define). Wiring a real
# DSN through would mean adding a `connections`/dsn_env path to
# schemas/sweep-config.json and sweep-run.sh — both out of this task's
# scope ("Files NOT to touch: other checks") and untestable in this
# hermetic environment (no live Postgres here). Left as a follow-up once
# the runner grows a `connections` block (spec S4.4, phase 3+).
#
# FAIL-CLOSED on a write_never entry with a blank/whitespace-only reason:
# refused before a single column is examined (no SWEEP_RESULT line at
# all — same fail-closed shape as e1-load-routes.mjs's missing-prerequisite
# path). This is belt-and-suspenders with sweep-config.sh's own
# `_sweep_config_surface_violations`, which already refuses the same
# blank reason at the runner's config-validation stage (exit 3) before
# this check would ever be invoked in production; this check enforces it
# again for anyone invoking it directly, and because a fail-closed
# invariant this document calls out by name should never rely on only
# one enforcement point.
#
# `identity_key` = "table.column", with any run of 4+ consecutive digits
# broken into groups of 3 joined by a dash (b4-merge-run.sh's grouped_id /
# e1-load-routes.mjs's identityKeyForRoute precedent) — a real risk here,
# not a theoretical one: time-partitioned tables like `events_2024` are
# common, and an ungrouped identity_key would trip sweep-emit.sh's R1
# refusal. `evidence.locus` carries the migration file that introduced the
# column (never a line number — line numbers drift and would mint a new
# finding_id every run, RT-10), so `identity_key` alone need not carry all
# the distinctness burden the way it must for B4, but the grouping costs
# nothing and stays consistent with its siblings.

set -uo pipefail

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"
MIGRATIONS_GLOB="$(jq -r '.config.migrations_glob // "supabase/migrations/*.sql"' <<<"$JOB")"
WRITE_NEVER_JSON="$(jq -c '.config.write_never // []' <<<"$JOB")"

TABLES=()
while IFS= read -r t; do [[ -n "$t" ]] && TABLES+=("$t"); done \
  < <(jq -r '.config.tables[]? // empty' <<<"$JOB")

WRITE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && WRITE_GLOBS+=("$g"); done \
  < <(jq -r '.config.write_path_globs[]? // empty' <<<"$JOB")

START="$SECONDS"

# Fail-closed: a write_never entry with a blank/whitespace-only reason
# never reaches the classification loop below.
BLANK_COUNT="$(jq -r '[.[] | select(((.reason // "") | gsub("^\\s+|\\s+$";"")) == "")] | length' <<<"$WRITE_NEVER_JSON")"
if [[ "$BLANK_COUNT" != "0" ]]; then
  BLANK_UNIT="$(jq -r '[.[] | select(((.reason // "") | gsub("^\\s+|\\s+$";"")) == "")][0].unit // "(no unit)"' <<<"$WRITE_NEVER_JSON")"
  echo "a4-column-writes: refusing to run — write_never entry for '$BLANK_UNIT' has a blank reason; every write-never declaration must carry a non-empty reason a reviewer can read (fail-closed)" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a4.XXXXXX")" || { echo "a4-column-writes: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# group_digits <digit-run> -> the run split into groups of 3, dash-joined,
# unchanged if shorter than 4 digits.
group_digits() {
  local d="$1"
  if [[ "${#d}" -lt 4 ]]; then echo "$d"; return; fi
  local grouped="" i=0
  while [[ "$i" -lt "${#d}" ]]; do
    grouped="${grouped:+$grouped-}${d:$i:3}"
    i=$((i + 3))
  done
  echo "$grouped"
}

# group_digit_runs <string> -> the string with every run of 4+ consecutive
# digits replaced by group_digits' output; every other character untouched.
group_digit_runs() {
  local s="$1" out="" buf="" c i=0 n
  n="${#s}"
  while [[ "$i" -lt "$n" ]]; do
    c="${s:$i:1}"
    if [[ "$c" =~ [0-9] ]]; then
      buf+="$c"
    else
      [[ -n "$buf" ]] && { out+="$(group_digits "$buf")"; buf=""; }
      out+="$c"
    fi
    i=$((i + 1))
  done
  [[ -n "$buf" ]] && out+="$(group_digits "$buf")"
  echo "$out"
}

# ---- Column universe: the embedded Node parser (see header) ----

NODE_JS="$TMP/extract-columns.mjs"
cat > "$NODE_JS" <<'NODEJS'
import fs from "node:fs";
import path from "node:path";

const [, , repoRoot, migrationsGlobRaw, tablesJson, bodiesOut] = process.argv;
if (!repoRoot || !migrationsGlobRaw || !tablesJson || !bodiesOut) {
  process.stderr.write("extract-columns: usage: extract-columns.mjs <repoRoot> <migrationsGlob> <tablesJsonArray> <bodiesOutFile>\n");
  process.exit(1);
}

let tables;
try {
  tables = JSON.parse(tablesJson);
} catch (e) {
  process.stderr.write(`extract-columns: tables argument is not valid JSON: ${e.message}\n`);
  process.exit(1);
}

// expandGlob: dir part + a single-`*` basename pattern, resolved against
// an actual directory listing (no shell involved, no globstar dependency).
function expandGlob(root, globRel) {
  const idx = globRel.lastIndexOf("/");
  const dir = idx === -1 ? "." : globRel.slice(0, idx);
  const pattern = idx === -1 ? globRel : globRel.slice(idx + 1);
  const absDir = path.join(root, dir);
  if (!fs.existsSync(absDir) || !fs.statSync(absDir).isDirectory()) return [];
  const escaped = pattern.split("*").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  const re = new RegExp(`^${escaped}$`);
  return fs.readdirSync(absDir).filter((f) => re.test(f)).sort().map((f) => path.join(dir, f));
}

function stripComments(sql) {
  sql = sql.replace(/\/\*[\s\S]*?\*\//g, " ");
  return sql.split("\n").map((line) => {
    const idx = line.indexOf("--");
    return idx === -1 ? line : line.slice(0, idx);
  }).join("\n");
}

// splitStatements: semicolons at paren-depth 0 terminate a statement —
// good enough for DDL, which never needs a `;` inside a type/constraint
// paren.
function splitStatements(sql) {
  const stmts = [];
  let depth = 0, cur = "";
  for (const ch of sql) {
    if (ch === "(") depth++;
    if (ch === ")") depth = Math.max(0, depth - 1);
    if (ch === ";" && depth === 0) { stmts.push(cur); cur = ""; continue; }
    cur += ch;
  }
  if (cur.trim()) stmts.push(cur);
  return stmts;
}

function unquote(tok) {
  return tok.replace(/^"|"$/g, "");
}

// bareTableName: strip schema qualifier + quotes, lowercase (Postgres
// folds unquoted identifiers to lowercase; quoted-case fidelity is a known
// gap of this degraded static parse, documented in the check's header).
function bareTableName(qualified) {
  const parts = qualified.split(".");
  return unquote(parts[parts.length - 1]).toLowerCase();
}

const IDENT = '(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)';
const QUALIFIED = `${IDENT}(?:\\.${IDENT})?`;
const CREATE_RE = new RegExp(`^\\s*CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QUALIFIED})\\s*\\(`, "i");
const ALTER_RE = new RegExp(`^\\s*ALTER\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?(${QUALIFIED})\\s+`, "i");
const ADD_COLUMN_RE = new RegExp(`ADD\\s+(?:COLUMN\\s+)?(?:IF\\s+NOT\\s+EXISTS\\s+)?(${IDENT})`, "gi");
const CONSTRAINT_KEYWORD_RE = /^(PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|CONSTRAINT|EXCLUDE|LIKE)\b/i;
const COLUMN_NAME_RE = new RegExp(`^(${IDENT})`);

// splitTopLevel: comma-split a CREATE TABLE column-list body, not
// descending into nested parens (`numeric(10,2)`, `PRIMARY KEY (a, b)`).
function splitTopLevel(text, sep) {
  const parts = [];
  let depth = 0, cur = "";
  for (const ch of text) {
    if (ch === "(") depth++;
    if (ch === ")") depth = Math.max(0, depth - 1);
    if (ch === sep && depth === 0) { parts.push(cur); cur = ""; continue; }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}

// columnListBody: the substring between a CREATE TABLE statement's outer
// opening paren (already consumed by CREATE_RE) and its matching close.
function columnListBody(rest) {
  let depth = 1, i = 0;
  while (i < rest.length && depth > 0) {
    if (rest[i] === "(") depth++;
    else if (rest[i] === ")") { depth--; if (depth === 0) break; }
    i++;
  }
  return rest.slice(0, i);
}

const universe = new Map(); // bareTableName -> Map(column -> relFile)
for (const t of tables) universe.set(bareTableName(t), new Map());

// Dollar-quoted routine bodies ($$…$$ / $tag$…$tag$) are SQL that RUNS —
// a plpgsql function's UPDATE writes a column as surely as app code does
// (queue #227: 2 of 3 production findings were columns filled by a
// function the write-path glob scan could not see). Collected here and
// grepped alongside the write-path files. DDL is never dollar-quoted, so
// a column's own CREATE TABLE declaration cannot leak in and make the
// check vacuous.
const DOLLAR_BODY_RE = /\$([A-Za-z_][A-Za-z0-9_]*)?\$([\s\S]*?)\$\1\$/g;
const bodies = [];

for (const relFile of expandGlob(repoRoot, migrationsGlobRaw)) {
  let text;
  try {
    text = fs.readFileSync(path.join(repoRoot, relFile), "utf8");
  } catch {
    continue;
  }
  DOLLAR_BODY_RE.lastIndex = 0;
  let bodyMatch;
  while ((bodyMatch = DOLLAR_BODY_RE.exec(text)) !== null) bodies.push(bodyMatch[2]);
  text = stripComments(text);
  for (const stmt of splitStatements(text)) {
    const trimmed = stmt.trim();

    const createMatch = trimmed.match(CREATE_RE);
    if (createMatch) {
      const cols = universe.get(bareTableName(createMatch[1]));
      if (!cols) continue;
      const body = columnListBody(trimmed.slice(createMatch[0].length));
      for (const chunk of splitTopLevel(body, ",")) {
        const c = chunk.trim();
        if (!c || CONSTRAINT_KEYWORD_RE.test(c)) continue;
        const m = c.match(COLUMN_NAME_RE);
        if (!m) continue;
        const col = unquote(m[1]).toLowerCase();
        if (!cols.has(col)) cols.set(col, relFile);
      }
      continue;
    }

    const alterMatch = trimmed.match(ALTER_RE);
    if (alterMatch) {
      const cols = universe.get(bareTableName(alterMatch[1]));
      if (!cols) continue;
      const rest = trimmed.slice(alterMatch[0].length);
      ADD_COLUMN_RE.lastIndex = 0;
      let m;
      while ((m = ADD_COLUMN_RE.exec(rest)) !== null) {
        const col = unquote(m[1]).toLowerCase();
        if (!cols.has(col)) cols.set(col, relFile);
      }
    }
  }
}

// Output keyed by the ORIGINAL configured table strings, never the
// normalized bare name — write_never's `unit` and the emitted
// identity_key must match what the repo's config actually wrote.
const out = {};
for (const t of tables) out[t] = Object.fromEntries(universe.get(bareTableName(t)).entries());
fs.writeFileSync(bodiesOut, bodies.join("\n"));
process.stdout.write(JSON.stringify(out));
NODEJS

TABLES_JSON="$(printf '%s\n' "${TABLES[@]+${TABLES[@]}}" | jq -R . | jq -sc 'map(select(length>0))')"
FN_BODIES="$TMP/fn-bodies.sql"
COLUMN_MAP="$(node "$NODE_JS" "$REPO_ROOT" "$MIGRATIONS_GLOB" "$TABLES_JSON" "$FN_BODIES" 2>"$TMP/node.err")" || {
  echo "a4-column-writes: could not extract the column universe from migrations ($(tr '\n' ' ' < "$TMP/node.err"))" >&2
  exit 1
}

# ---- Which files count as "written" (matched against every glob) ----

# The walk's exit status is checked: "I could not walk the tree" is not
# "no file writes anything". A failed/partial find used to leave FILES
# empty, and column_is_written's empty-list short-circuit then reported
# EVERY column as never written — the couldn't-look-read-as-found-nothing
# failure B4 had (a swallowed 403 became 209 false findings).
WALK_LIST="$TMP/walk-files.zlist"
if ! find "$REPO_ROOT" -type f -not -path '*/.git/*' -print0 > "$WALK_LIST" 2>"$TMP/walk.err"; then
  echo "a4-column-writes: the repo file walk failed ($(tr '\n' ' ' < "$TMP/walk.err")) — cannot tell what is written, so no column is scored" >&2
  exit 1
fi
ALL_FILES_REL=()
while IFS= read -r -d '' f; do
  ALL_FILES_REL+=("${f#"$REPO_ROOT"/}")
done < "$WALK_LIST"

# Pattern matching, not pathname expansion: `[[ str == $pat ]]` matches `*`
# and `**` across `/` (unlike bash globstar, which bash 3.2 lacks entirely),
# so a config glob like "packages/api/src/lib/**" recurses correctly on
# every supported bash version without an `shopt -s globstar` dependency.
FILES=()
for rel in "${ALL_FILES_REL[@]+${ALL_FILES_REL[@]}}"; do
  for pat in "${WRITE_GLOBS[@]+${WRITE_GLOBS[@]}}"; do
    if [[ "$rel" == $pat ]]; then
      FILES+=("$REPO_ROOT/$rel")
      break
    fi
  done
done

# column_is_written <column> -> 0 (true) iff the column name appears as a
# whole word in any write-path file, or in a dollar-quoted routine body
# extracted from the migrations (queue #227 — a plpgsql function's writes
# are writes). Columns written through a mechanism no static text scan can
# see (e.g. a data-driven jsonb override map) still need a write_never
# entry whose reason names that mechanism.
# Returns 0 written, 1 not written, 2 could-not-look. grep exit 1 (no
# match) is evidence; exit 2+ (unreadable file, grep failing) is not —
# and FILES is chunked so a big repo can never hit ARG_MAX, which grep
# would also report as exit 2 rather than as "not written".
column_is_written() {
  local col="$1" rc i
  if [[ -s "$FN_BODIES" ]]; then
    grep -q -w -- "$col" "$FN_BODIES" 2>/dev/null
    rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -ge 2 ]] && return 2
  fi
  [[ "${#FILES[@]}" -eq 0 ]] && return 1
  for ((i = 0; i < ${#FILES[@]}; i += 500)); do
    grep -l -w -- "$col" "${FILES[@]:i:500}" >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -ge 2 ]] && return 2
  done
  return 1
}

# ---- Classify: excluded (write_never) vs checked (written / unwritten) ----

PAIRS_JSON="$(jq -c '[to_entries[] | .key as $t | .value | to_entries[] | {table:$t, column:.key, locus:.value, unit:($t+"."+.key)}]' <<<"$COLUMN_MAP")"
UNIVERSE_SIZE="$(jq 'length' <<<"$PAIRS_JSON")"
WRITE_NEVER_MAP="$(jq -c 'map({(.unit): .reason}) | add // {}' <<<"$WRITE_NEVER_JSON")"

EXCLUDED='[]'
CHECKED_COUNT=0
UNWRITTEN_PAIRS='[]'

while IFS= read -r pair; do
  [[ -z "$pair" ]] && continue
  column="$(jq -r '.column' <<<"$pair")"
  unit="$(jq -r '.unit' <<<"$pair")"
  reason="$(jq -r --arg u "$unit" '.[$u] // empty' <<<"$WRITE_NEVER_MAP")"
  if [[ -n "$reason" ]]; then
    EXCLUDED="$(jq -c --arg u "$unit" --arg r "$reason" '. + [{unit:$u, reason:$r}]' <<<"$EXCLUDED")"
    continue
  fi
  CHECKED_COUNT=$((CHECKED_COUNT + 1))
  column_is_written "$column"
  WRITTEN_RC=$?
  [[ "$WRITTEN_RC" -eq 0 ]] && continue
  if [[ "$WRITTEN_RC" -ge 2 ]]; then
    echo "a4-column-writes: a write-path file could not be read while checking \"$unit\" — an unreadable file is not evidence that nothing writes the column" >&2
    exit 1
  fi
  UNWRITTEN_PAIRS="$(jq -c --argjson p "$pair" '. + [$p]' <<<"$UNWRITTEN_PAIRS")"
done < <(jq -c '.[]' <<<"$PAIRS_JSON")

UNWRITTEN_COUNT="$(jq 'length' <<<"$UNWRITTEN_PAIRS")"
ASSERTIONS_PASSED=$((CHECKED_COUNT - UNWRITTEN_COUNT))

FINDINGS='[]'
while IFS= read -r pair; do
  [[ -z "$pair" ]] && continue
  table="$(jq -r '.table' <<<"$pair")"
  column="$(jq -r '.column' <<<"$pair")"
  locus="$(jq -r '.locus' <<<"$pair")"
  unit="$(jq -r '.unit' <<<"$pair")"
  IDK="$(group_digit_runs "$unit")"
  FINDING="$(jq -n --arg id "$IDK" --arg table "$table" --arg column "$column" \
    --arg locus "$locus" --arg surface "$SURFACE" --argjson denom "$CHECKED_COUNT" --argjson passed "$ASSERTIONS_PASSED" '
    {identity_key: $id,
     what: ("column " + $table + "." + $column + " exists in the schema but no write-path file was found to write it"),
     plain: ("The " + $table + " records have a field, " + $column + ", that nothing ever fills in."),
     mechanism: "DISCONNECTED",
     surface: $surface,
     surface_source: "declared",
     found_by: "sweep-family-A",
     evidence: {locus: $locus, measurement: {statement: "columns with no write-path occurrence and no declared write-never reason", count: 1, denominator: $denom, source: "static-source"}},
     liveness: {assertions_executed: $denom, assertions_passed: $passed},
     responsible_agent: null, roster_action: null}')"
  FINDINGS="$(jq -c --argjson f "$FINDING" '. + [$f]' <<<"$FINDINGS")"
done < <(jq -c '.[]' <<<"$UNWRITTEN_PAIRS")

DURATION_MS=$(( (SECONDS - START) * 1000 ))
STATUS="pass"
[[ "$UNWRITTEN_COUNT" -gt 0 ]] && STATUS="fail"

MEASUREMENTS="$(jq -cn --argjson count "$UNWRITTEN_COUNT" --argjson denom "$CHECKED_COUNT" \
  '[{statement: "columns with no write-path occurrence and no declared write-never reason", count: $count, denominator: $denom, source: "static-source"}]')"

ENVELOPE="$(jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson excluded "$EXCLUDED" \
  --argjson executed "$CHECKED_COUNT" --argjson passed "$ASSERTIONS_PASSED" \
  --argjson measurements "$MEASUREMENTS" --argjson findings "$FINDINGS" --argjson duration "$DURATION_MS" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: $excluded, assertions_executed: $executed,
   assertions_passed: $passed, measurements: $measurements, findings: $findings, duration_ms: $duration}')"

echo "a4-column-writes: examined $UNIVERSE_SIZE column(s) across ${#TABLES[@]} table(s), $UNWRITTEN_COUNT with no write-path occurrence and no declared write-never reason"
echo "SWEEP_RESULT:v1 $(printf '%s' "$ENVELOPE" | base64 | tr -d '\n')"
