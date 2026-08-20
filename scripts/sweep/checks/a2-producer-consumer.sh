#!/usr/bin/env bash
# scripts/sweep/checks/a2-producer-consumer.sh — A2: producer/consumer key
# contract (stack ADR-078, spec S4.6 A2; sweep static-check spine).
# Reproduces audit rows #5/#23 ($161,700 counted, one specimen): a value
# written under one key name and read under another, so a feature
# silently no-ops.
#
# Reads sweep-job/v1 on stdin (task 4's contract). `config.producers` is a
# list of "path/to/file.ts#functionName" entries; `config.consumer_globs`
# is a list of globs (both repo-relative, spec S5.3's A2 family block).
# Extracts (a) the string keys a producer function writes into its
# returned object literal or a URLSearchParams it builds, and (b) the
# string keys consumer files read via `searchParams.get('x')`,
# `params.x`, or destructuring off an identifier ending in
# "params"/"Params". Emits one finding per orphan key in EITHER
# direction, mechanism CONTRACT DRIFT: a producer key with no consumer,
# and a consumer key with no producer — "both directions matter...
# `products` emitted-never-read and `product` read-never-emitted are the
# same bug seen from two sides" (spec S4.6 A2).
#
# The spec's stated preference is the TypeScript compiler API, already a
# devDependency in the repo the spec was written against. This check does
# not attempt that path: requiring `typescript` to be resolvable from an
# arbitrary target repo's node_modules is an assumption this check cannot
# make honestly for every repo the Sweep runs against, and the stack repo
# itself may add no new dependency of its own (Karpathy rule 8). Instead
# it always takes the spec's own explicitly sanctioned degrade: a
# self-contained node script doing plain lexical (regex-based)
# extraction, embedded in this file and written to a throwaway temp file
# at run time — no separate committed script, no new dependency anywhere.
# `evidence_basis` is echoed from the job exactly as every other check
# does; it was already `static-source`, which lexical extraction still
# honestly is.
#
# Node itself absent in the target repo, a malformed "path#function"
# producer entry, or a producer file/function that cannot be found all
# fail CLOSED: the envelope's `status` is "error" (the runner's
# `check-error` liveness violation), never a silent pass with an empty
# findings list. Compare scripts/sweep/checks/b4-merge-run.sh, this
# check's bash-side exemplar for job parsing and sweep-result/v1 envelope
# emission — the division of labor here is: node does the JS/TS
# comprehension (extraction, comparison), bash does the job parsing and
# the envelope assembly, exactly like every other check in this family.
#
# `identity_key` is the orphaned key name itself, sanitized the same way
# b4/e1 sanitize theirs: any run of 4+ consecutive digits is broken into
# groups of 3 joined by a dash, so a key like `page2026` can never trip
# sweep-emit.sh's R1 (identity_key must not look like run identity). Most
# real param/column names never hit this path; it costs nothing to be
# safe. The sanitization happens inside the node script, where the raw
# key is first produced.
#
# The balanced-brace extraction primitives (extractBalanced/parseObjectKeys/
# findFunctionBody) live in scripts/sweep/lib/extract.mjs, shared with
# a5-command-callers.sh (doctrine v2 P1a) — imported at runtime via dynamic
# `import()` from this check's own throwaway temp script, so the check
# stays self-contained-at-run-time while the extraction logic itself is
# not duplicated.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT_LIB="$DIR/../lib/extract.mjs"

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"

START="$SECONDS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a2.XXXXXX")" || { echo "a2-producer-consumer: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# emit_error_envelope <message> -> prints the status:"error" envelope the
# runner reads as the `check-error` liveness violation (fail-closed —
# never a silent pass) and the diagnostic line that precedes it.
emit_error_envelope() {
  local msg="$1" envelope
  envelope="$(jq -cn --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
    --argjson duration "$(( (SECONDS - START) * 1000 ))" '
    {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
     status: "error", universe_size: 0, excluded: [], assertions_executed: 0, assertions_passed: 0,
     measurements: [], findings: [], duration_ms: $duration}')"
  echo "a2-producer-consumer: $msg"
  echo "SWEEP_RESULT:v1 $(printf '%s' "$envelope" | base64 | tr -d '\n')"
}

if ! command -v node >/dev/null 2>&1; then
  emit_error_envelope "node is not available in this environment — cannot lexically extract producer/consumer keys"
  exit 0
fi

if [[ ! -f "$EXTRACT_LIB" ]]; then
  emit_error_envelope "the shared extraction lib is missing from this install: $EXTRACT_LIB"
  exit 0
fi

# ---- the self-contained lexical-extraction node script (see header) ----
cat > "$TMP/a2-extract.mjs" <<'NODE_EOF'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const { extractBalanced, parseObjectKeys, findFunctionBody } =
  await import(pathToFileURL(process.env.EXTRACT_LIB_PATH).href);

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => { data += c; });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

// extractBalanced/parseObjectKeys/findFunctionBody are imported from
// scripts/sweep/lib/extract.mjs (see header) — no longer defined here.

// producerKeysFromBody <body> -> string keys the producer function body
// writes: object-literal keys in a `return {...}`, object-literal keys in
// `new URLSearchParams({...})`, and the key argument of any `.set(...)`
// or `.append(...)` call (the URLSearchParams-builder shape).
function producerKeysFromBody(body) {
  const keys = new Set();
  let m;
  const returnRe = /return\s*\(?\s*\{/g;
  while ((m = returnRe.exec(body))) {
    const braceIdx = body.indexOf("{", m.index);
    const objText = extractBalanced(body, braceIdx);
    if (objText != null) for (const k of parseObjectKeys(objText)) keys.add(k);
  }
  const uspRe = /new\s+URLSearchParams\s*\(\s*\{/g;
  while ((m = uspRe.exec(body))) {
    const braceIdx = body.indexOf("{", m.index);
    const objText = extractBalanced(body, braceIdx);
    if (objText != null) for (const k of parseObjectKeys(objText)) keys.add(k);
  }
  const setRe = /\.(?:set|append)\(\s*(['"`])([^'"`]+)\1/g;
  while ((m = setRe.exec(body))) keys.add(m[2]);
  return keys;
}

// identitySanitize <key> -> R1-safe identity_key (b4/e1 precedent): every
// run of 4+ consecutive digits broken into groups of 3, dash-joined.
function identitySanitize(key) {
  return key.replace(/[0-9]{4,}/g, (run) => {
    const groups = [];
    for (let i = 0; i < run.length; i += 3) groups.push(run.slice(i, i + 3));
    return groups.join("-");
  });
}

// globToRegExp <glob> -> a RegExp for a repo-relative glob. Supports `*`
// (any run of non-slash characters), `**/` (any number of path segments,
// including zero) and `?` (one non-slash character) — the shapes
// consumer_globs actually uses (spec S5.3 examples).
function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        i++;
        if (glob[i + 1] === "/") { re += "(?:.*/)?"; i++; }
        else re += ".*";
      } else {
        re += "[^/]*";
      }
    } else if (c === "?") {
      re += "[^/]";
    } else if (".+^${}()|[]\\".includes(c)) {
      re += "\\" + c;
    } else {
      re += c;
    }
  }
  return new RegExp("^" + re + "$");
}

const IGNORE_DIRS = new Set(["node_modules", ".git", ".next", "dist", "build", ".turbo"]);

// An unreadable directory is NOT an empty directory: a consumer file the
// walk silently drops makes every key only that file read look like a
// producer orphan — a false CONTRACT DRIFT finding per key (the B4
// couldn't-look shape). fail() the walk instead of skipping.
function walkFiles(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
    catch (e) { fail(`could not read directory ${path.relative(root, dir) || "."}: ${e.message}`); }
    for (const ent of entries) {
      if (ent.isDirectory()) {
        if (IGNORE_DIRS.has(ent.name)) continue;
        stack.push(path.join(dir, ent.name));
      } else if (ent.isFile()) {
        out.push(path.join(dir, ent.name));
      }
    }
  }
  return out;
}

// consumerKeysFromText <text> -> string keys a consumer file reads:
// `searchParams.get('x')` (any identifier ending in params/Params before
// `.get(`), a bare `params.x` property read (never a `.method(` call),
// and destructuring off an identifier ending in params/Params.
function consumerKeysFromText(text) {
  const keys = new Set();
  let m;
  const getRe = /[A-Za-z_$][A-Za-z0-9_$]*[Pp]arams\s*\.\s*get\(\s*(['"`])([^'"`]+)\1/g;
  while ((m = getRe.exec(text))) keys.add(m[2]);
  const paramsRe = /\bparams\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)(?!\s*\()/g;
  while ((m = paramsRe.exec(text))) keys.add(m[1]);
  const destructureRe = /\{([^{}]+)\}\s*=\s*[A-Za-z_$][A-Za-z0-9_$]*[Pp]arams\b/g;
  while ((m = destructureRe.exec(text))) {
    for (const raw of m[1].split(",")) {
      let s = raw.trim();
      if (!s || s.startsWith("...")) continue;
      const ci = s.indexOf(":");
      if (ci >= 0) s = s.slice(0, ci).trim();
      const eq = s.indexOf("=");
      if (eq >= 0) s = s.slice(0, eq).trim();
      if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(s)) keys.add(s);
    }
  }
  return keys;
}

function fail(errorMessage) {
  process.stdout.write(JSON.stringify({ status: "error", error: errorMessage }));
  process.exit(0);
}

const raw = await readStdin();
let job;
try {
  job = JSON.parse(raw);
} catch (e) {
  fail(`could not parse the sweep-job/v1 payload on stdin as JSON: ${e.message}`);
}

const repoRoot = job.repo_root;
if (!repoRoot) fail("the job carries no repo_root");

const config = job.config || {};
const producers = Array.isArray(config.producers) ? config.producers : [];
const consumerGlobs = Array.isArray(config.consumer_globs) ? config.consumer_globs : [];
const exclusions = Array.isArray(config.exclusions) ? config.exclusions : [];

const producerKeys = new Set();
for (const entry of producers) {
  const hashIdx = typeof entry === "string" ? entry.indexOf("#") : -1;
  if (hashIdx < 0) fail(`producer entry is not in "path#functionName" form: ${entry}`);
  const relPath = entry.slice(0, hashIdx);
  const funcName = entry.slice(hashIdx + 1);
  const absPath = path.join(repoRoot, relPath);
  if (!fs.existsSync(absPath)) fail(`producer file not found: ${relPath}`);
  const source = fs.readFileSync(absPath, "utf8");
  const body = findFunctionBody(source, funcName);
  if (body == null) fail(`producer function not found: ${funcName} in ${relPath}`);
  for (const k of producerKeysFromBody(body)) producerKeys.add(k);
}

const consumerKeys = new Set();
if (consumerGlobs.length > 0) {
  const allFiles = walkFiles(repoRoot).map((f) => path.relative(repoRoot, f).split(path.sep).join("/"));
  const matchers = consumerGlobs.map(globToRegExp);
  const matched = allFiles.filter((f) => matchers.some((re) => re.test(f)));
  for (const rel of matched) {
    let text;
    // Same rule as the producer side (which already fail()s on a missing
    // file): an unreadable consumer file is not evidence nobody consumes.
    try { text = fs.readFileSync(path.join(repoRoot, rel), "utf8"); }
    catch (e) { fail(`could not read consumer file ${rel}: ${e.message}`); }
    for (const k of consumerKeysFromText(text)) consumerKeys.add(k);
  }
}

const declaredExclusions = new Map();
for (const ex of exclusions) {
  if (ex && typeof ex.unit === "string" && typeof ex.reason === "string" && ex.reason.trim().length > 0) {
    declaredExclusions.set(ex.unit, ex.reason);
  }
}

const allKeys = new Set([...producerKeys, ...consumerKeys]);
const excluded = [];
const checkedKeys = new Set();
for (const k of allKeys) {
  if (declaredExclusions.has(k)) excluded.push({ unit: k, reason: declaredExclusions.get(k) });
  else checkedKeys.add(k);
}

const producerOrphans = [...checkedKeys]
  .filter((k) => producerKeys.has(k) && !consumerKeys.has(k))
  .map((k) => ({ key: k, identity_key: identitySanitize(k) }));
const consumerOrphans = [...checkedKeys]
  .filter((k) => consumerKeys.has(k) && !producerKeys.has(k))
  .map((k) => ({ key: k, identity_key: identitySanitize(k) }));

const assertionsExecuted = checkedKeys.size;
const assertionsPassed = assertionsExecuted - producerOrphans.length - consumerOrphans.length;

process.stdout.write(JSON.stringify({
  status: "ok",
  error: null,
  universe_size: allKeys.size,
  excluded,
  assertions_executed: assertionsExecuted,
  assertions_passed: assertionsPassed,
  producer_orphans: producerOrphans,
  consumer_orphans: consumerOrphans,
}));
NODE_EOF

NODE_JSON="$(printf '%s' "$JOB" | EXTRACT_LIB_PATH="$EXTRACT_LIB" node "$TMP/a2-extract.mjs" 2>"$TMP/node.err")"
NODE_EC=$?

if [[ "$NODE_EC" -ne 0 || -z "$NODE_JSON" ]]; then
  emit_error_envelope "the lexical extraction script failed to run: $(tr '\n' ' ' < "$TMP/node.err" 2>/dev/null)"
  exit 0
fi

# Non-JSON stdout from node used to slip past this read (empty NODE_ERROR)
# and only got caught downstream by accident; refuse it here on purpose.
if ! jq -e 'type == "object"' <<<"$NODE_JSON" >/dev/null 2>&1; then
  emit_error_envelope "the lexical extraction script printed output that is not a JSON object"
  exit 0
fi
NODE_ERROR="$(jq -r '.error // empty' <<<"$NODE_JSON" 2>/dev/null)"
if [[ -n "$NODE_ERROR" ]]; then
  emit_error_envelope "$NODE_ERROR"
  exit 0
fi

UNIVERSE_SIZE="$(jq -r '.universe_size' <<<"$NODE_JSON")"
ASSERTIONS_EXECUTED="$(jq -r '.assertions_executed' <<<"$NODE_JSON")"
ASSERTIONS_PASSED="$(jq -r '.assertions_passed' <<<"$NODE_JSON")"
EXCLUDED="$(jq -c '.excluded' <<<"$NODE_JSON")"
PRODUCER_ORPHAN_N="$(jq '.producer_orphans | length' <<<"$NODE_JSON")"
CONSUMER_ORPHAN_N="$(jq '.consumer_orphans | length' <<<"$NODE_JSON")"

# git commit sha for evidence — only resolved (and required) when there is
# at least one orphan to report; a passing run with no findings needs no
# evidence.commit at all.
COMMIT=""
if [[ "$((PRODUCER_ORPHAN_N + CONSUMER_ORPHAN_N))" -gt 0 ]]; then
  COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
  if [[ -z "$COMMIT" ]]; then
    emit_error_envelope "could not resolve the HEAD commit sha for repo_root — evidence requires one"
    exit 0
  fi
fi

FINDINGS='[]'

# add_findings <direction: producer|consumer> <measurement statement>
add_findings() {
  local direction="$1" statement="$2" orphans entry
  orphans="$(jq -c --arg d "$direction" '.[$d + "_orphans"]' <<<"$NODE_JSON")"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local key ident what plain finding
    key="$(jq -r '.key' <<<"$entry")"
    ident="$(jq -r '.identity_key' <<<"$entry")"
    if [[ "$direction" == "producer" ]]; then
      what="a declared producer writes key \"$key\" into its returned object/URLSearchParams, but no declared consumer file reads it"
      plain="A part of the app sends a value named \"$key\" that nothing else ever reads, so it has no effect."
    else
      what="a declared consumer reads key \"$key\" from route/search params, but no declared producer ever writes it"
      plain="A part of the app looks for a value named \"$key\" that nothing ever sends, so it never gets set."
    fi
    finding="$(jq -n --arg id "$ident" --arg what "$what" --arg plain "$plain" --arg surface "$SURFACE" \
      --arg commit "$COMMIT" --arg statement "$statement" \
      --argjson denom "$UNIVERSE_SIZE" --argjson executed "$ASSERTIONS_EXECUTED" --argjson passed "$ASSERTIONS_PASSED" '
      {identity_key: $id, what: $what, plain: $plain, mechanism: "CONTRACT DRIFT",
       surface: $surface, surface_source: "declared", found_by: "sweep-family-A",
       evidence: {commit: $commit,
                  measurement: {statement: $statement, count: 1, denominator: $denom, source: "static-source"}},
       liveness: {assertions_executed: $executed, assertions_passed: $passed},
       responsible_agent: null, roster_action: null}')"
    FINDINGS="$(jq -c --argjson f "$finding" '. + [$f]' <<<"$FINDINGS")"
  done < <(jq -c '.[]?' <<<"$orphans")
}

add_findings "producer" "producer keys with no consumer"
add_findings "consumer" "consumer keys with no producer"

DURATION_MS=$(( (SECONDS - START) * 1000 ))
STATUS="pass"
[[ "$(jq 'length' <<<"$FINDINGS")" -gt 0 ]] && STATUS="fail"

MEASUREMENTS="$(jq -cn --argjson pc "$PRODUCER_ORPHAN_N" --argjson cc "$CONSUMER_ORPHAN_N" --argjson denom "$UNIVERSE_SIZE" '
  [{statement: "producer keys with no consumer", count: $pc, denominator: $denom, source: "static-source"},
   {statement: "consumer keys with no producer", count: $cc, denominator: $denom, source: "static-source"}]')"

ENVELOPE="$(jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson executed "$ASSERTIONS_EXECUTED" \
  --argjson passed "$ASSERTIONS_PASSED" --argjson excluded "$EXCLUDED" \
  --argjson measurements "$MEASUREMENTS" --argjson findings "$FINDINGS" --argjson duration "$DURATION_MS" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: $excluded, assertions_executed: $executed,
   assertions_passed: $passed, measurements: $measurements, findings: $findings, duration_ms: $duration}')"

echo "a2-producer-consumer: examined $UNIVERSE_SIZE key(s), $PRODUCER_ORPHAN_N producer-orphan, $CONSUMER_ORPHAN_N consumer-orphan"
echo "SWEEP_RESULT:v1 $(printf '%s' "$ENVELOPE" | base64 | tr -d '\n')"
