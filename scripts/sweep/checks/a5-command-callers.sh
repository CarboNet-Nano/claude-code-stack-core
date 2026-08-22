#!/usr/bin/env bash
# scripts/sweep/checks/a5-command-callers.sh — A5: command-has-interface-
# caller (stack ADR-078/ADR-082, spec P1a
# docs/superpowers/specs/2026-08-16-testing-doctrine-redesign.md). Audit
# #4's class: a command a mutation engine (or any dispatch table) knows
# about, that no interface actually wires up — so the command exists and
# does whatever it does for nobody, DISCONNECTED from the same class A1
# covers on the writer side.
#
# Reads sweep-job/v1 on stdin. `config.command_map` is a single
# "path/to/file.ts#exportSymbol" entry (A2's anchored-entry shape,
# S4.6 A2's own precedent) naming the exported object literal whose
# top-level string keys ARE the universe of command ids — DERIVED, never
# hand-enumerated (spec's own explicit ban on an ONLY-IF hand-kept id
# list in config form). `config.interface_files` is a list of repo-
# relative globs; a command id is DISCONNECTED when it does not appear as
# a literal substring in any matched interface file. `config.exclusions`
# is `[{id, reason}]` (note: keyed `id`, not `unit` — the spec's own
# stated shape for this family). `config.min_expected_commands` is the
# universe floor: an extracted count below it means the config's own
# extraction pattern could not resolve the map (e.g. dynamic/computed
# keys, which parseObjectKeys already refuses to guess at) — this check
# never fakes a smaller universe, it fails closed with status "error"
# (the runner's `check-error` liveness violation) exactly like a
# command_map file/symbol that cannot be found at all.
#
# The balanced-brace extraction primitives (extractBalanced/
# parseObjectKeys) are imported at runtime from
# scripts/sweep/lib/extract.mjs, shared with a2-producer-consumer.sh — see
# that file's header for why the extraction runs as a throwaway temp node
# script rather than a committed one (spec's sanctioned TS-compiler-API
# degrade). Division of labor is A2's: node does the JS/TS comprehension
# (extracting the command map's keys), bash does the job parsing, the
# interface-file grep, and the sweep-result/v1 envelope assembly — this
# check's bash-side exemplar is a2-producer-consumer.sh, followed exactly.
#
# `identity_key` is the command id itself, sanitized the same way a2/b4/e1
# sanitize theirs (any run of 4+ consecutive digits broken into groups of
# 3, dash-joined) so an id like `run2026` can never trip sweep-emit.sh's
# R1 (identity_key must not look like run identity).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT_LIB="$DIR/../lib/extract.mjs"

JOB="$(cat)"
REPO_ROOT="$(jq -r '.repo_root' <<<"$JOB")"
CHECK_ID="$(jq -r '.check_id' <<<"$JOB")"
EVIDENCE_BASIS="$(jq -r '.evidence_basis' <<<"$JOB")"
SURFACE="$(jq -r '.surface' <<<"$JOB")"

START="$SECONDS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-a5.XXXXXX")" || { echo "a5-command-callers: mktemp failed" >&2; exit 1; }
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
  echo "a5-command-callers: $msg"
  echo "SWEEP_RESULT:v1 $(printf '%s' "$envelope" | base64 | tr -d '\n')"
}

if ! command -v node >/dev/null 2>&1; then
  emit_error_envelope "node is not available in this environment — cannot lexically extract command ids"
  exit 0
fi

if [[ ! -f "$EXTRACT_LIB" ]]; then
  emit_error_envelope "the shared extraction lib is missing from this install: $EXTRACT_LIB"
  exit 0
fi

# ---- the self-contained lexical-extraction node script (see header) ----
cat > "$TMP/a5-extract.mjs" <<'NODE_EOF'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const { extractBalanced, parseObjectKeys } =
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

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// findExportedObjectBody <source> <symbolName> -> the balanced body text of
// `export const/let/var <symbolName> = {...}` (optionally typed), or null.
// A5-specific: A2's findFunctionBody locates a function body; a command
// map is an object literal assigned to a const, not a function.
function findExportedObjectBody(source, symbolName) {
  const name = escapeRe(symbolName);
  const re = new RegExp(`export\\s+(?:const|let|var)\\s+${name}\\s*(?::[^=]+)?=\\s*\\{`);
  const m = re.exec(source);
  if (!m) return null;
  const braceIdx = m.index + m[0].length - 1;
  return extractBalanced(source, braceIdx);
}

function fail(errorMessage) {
  process.stdout.write(JSON.stringify({ status: "error", error: errorMessage, ids: [] }));
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
const commandMap = config.command_map;
const hashIdx = typeof commandMap === "string" ? commandMap.indexOf("#") : -1;
if (hashIdx < 0) fail(`command_map is not in "path#exportSymbol" form: ${commandMap}`);

const relPath = commandMap.slice(0, hashIdx);
const symbolName = commandMap.slice(hashIdx + 1);
const absPath = path.join(repoRoot, relPath);
if (!fs.existsSync(absPath)) fail(`command_map file not found: ${relPath}`);

const source = fs.readFileSync(absPath, "utf8");
const body = findExportedObjectBody(source, symbolName);
if (body == null) fail(`exported object "${symbolName}" not found in ${relPath}`);

const ids = [...parseObjectKeys(body)].sort();

process.stdout.write(JSON.stringify({ status: "ok", error: null, ids }));
NODE_EOF

NODE_JSON="$(printf '%s' "$JOB" | EXTRACT_LIB_PATH="$EXTRACT_LIB" node "$TMP/a5-extract.mjs" 2>"$TMP/node.err")"
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

COMMAND_MAP="$(jq -r '.config.command_map' <<<"$JOB")"
MIN_EXPECTED="$(jq -r '.config.min_expected_commands // 0' <<<"$JOB")"
IDS_JSON="$(jq -c '.ids' <<<"$NODE_JSON")"
RAW_COUNT="$(jq -r '.ids | length' <<<"$NODE_JSON")"

if [[ "$RAW_COUNT" -lt "$MIN_EXPECTED" ]]; then
  emit_error_envelope "extracted $RAW_COUNT command id(s) from $COMMAND_MAP, below the configured floor of $MIN_EXPECTED (min_expected_commands) — a silently shrinking universe is a liveness failure, not a smaller green run"
  exit 0
fi

UNIVERSE_SIZE="$RAW_COUNT"

# exclusions: config.exclusions is [{id, reason}] (A5's own shape, not the
# {unit, reason} other A-family blocks use — spec's stated wording).
EXCLUDED='[]'
CHECKED_IDS=()
while IFS=$'\t' read -r id ex_reason; do
  [[ -z "$id" ]] && continue
  if [[ -n "$ex_reason" ]]; then
    EXCLUDED="$(jq -c --arg u "$id" --arg r "$ex_reason" '. + [{unit: $u, reason: $r}]' <<<"$EXCLUDED")"
  else
    CHECKED_IDS+=("$id")
  fi
done < <(jq -r --argjson excl "$(jq -c '.config.exclusions // []' <<<"$JOB")" '
  ($excl | map({(.id): .reason}) | add // {}) as $exmap |
  .[] as $id | [$id, ($exmap[$id] // "")] | @tsv' <<<"$IDS_JSON")

ASSERTIONS_EXECUTED="${#CHECKED_IDS[@]}"

# interface_files, matched the same way a1-writer-callers.sh matches
# writer_globs: plain bash `[[ == ]]` pattern matching over a repo file
# walk (no globstar dependency, matches this machine's system bash 3.2).
INTERFACE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && INTERFACE_GLOBS+=("$g"); done \
  < <(jq -r '(.config.interface_files // [])[]' <<<"$JOB")

# The walk goes through a FILE with its exit status checked. "I could not
# walk the tree" is not "the tree has no interface files": a failed find
# (unreadable subtree, missing binary) used to yield an empty interface
# list, which scored EVERY declared command as DISCONNECTED — the same
# couldn't-look-read-as-found-nothing failure B4 had (a swallowed 403
# became 209 false findings). pipefail is set, so a partial find failure
# fails the whole pipeline rather than passing a truncated list.
WALK_FILE="$TMP/iface-walk.txt"
if ! (cd "$REPO_ROOT" && find . -type f \
      -not -path './.git/*' -not -path './node_modules/*' \
      | sed 's#^\./##' | sort) > "$WALK_FILE" 2>"$TMP/walk.err"; then
  emit_error_envelope "the repo file walk failed ($(tr '\n' ' ' < "$TMP/walk.err" 2>/dev/null)) — cannot tell which commands are wired, so none are scored"
  exit 0
fi

matched_interface_files() {
  local rel matched
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    matched=0
    for pat in "${INTERFACE_GLOBS[@]+${INTERFACE_GLOBS[@]}}"; do
      [[ "$rel" == $pat ]] && { matched=1; break; }
    done
    [[ "$matched" -eq 1 ]] && echo "$rel"
  done < "$WALK_FILE"
}

IFACE_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && IFACE_FILES+=("$f"); done < <(matched_interface_files)

# grep exit 1 (no match) is evidence; exit 2+ (unreadable file, grep
# itself failing) is NOT — return 2 so the caller errors out instead of
# counting the command as uncalled.
id_has_caller() {
  local id="$1" f rc
  for f in "${IFACE_FILES[@]+${IFACE_FILES[@]}}"; do
    grep -qF -- "$id" "$REPO_ROOT/$f" 2>/dev/null
    rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -ge 2 ]] && return 2
  done
  return 1
}

# identitySanitize <key> -> R1-safe identity_key (a2/b4/e1 precedent):
# every run of 4+ consecutive digits broken into groups of 3, dash-joined.
identitySanitize() {
  local rest="$1" out="" run pre grouped i len
  while [[ "$rest" =~ ([0-9]{4,}) ]]; do
    run="${BASH_REMATCH[1]}"
    pre="${rest%%"$run"*}"
    rest="${rest#*"$run"}"
    grouped="" i=0 len=${#run}
    while (( i < len )); do
      grouped+="${run:i:3}"
      i=$((i+3))
      (( i < len )) && grouped+="-"
    done
    out+="$pre$grouped"
  done
  out+="$rest"
  printf '%s' "$out"
}

ASSERTIONS_PASSED=0
DISCONNECTED_IDS=()
for id in "${CHECKED_IDS[@]+${CHECKED_IDS[@]}}"; do
  id_has_caller "$id"
  CALLER_RC=$?
  if [[ "$CALLER_RC" -eq 0 ]]; then
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED + 1))
  elif [[ "$CALLER_RC" -ge 2 ]]; then
    emit_error_envelope "an interface file could not be read while checking \"$id\" — an unreadable file is not evidence that nothing calls the command"
    exit 0
  else
    DISCONNECTED_IDS+=("$id")
  fi
done

DISCONNECTED_N="${#DISCONNECTED_IDS[@]}"

COMMIT=""
if [[ "$DISCONNECTED_N" -gt 0 ]]; then
  COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
  if [[ -z "$COMMIT" ]]; then
    emit_error_envelope "could not resolve the HEAD commit sha for repo_root — evidence requires one"
    exit 0
  fi
fi

FINDINGS='[]'
for id in "${DISCONNECTED_IDS[@]+${DISCONNECTED_IDS[@]}}"; do
  IDENT="$(identitySanitize "$id")"
  WHAT="declared command \"$id\" appears in the command map at $COMMAND_MAP, but no declared interface file references it"
  PLAIN="A command the app defines has no way for anyone to actually run it, so it never gets used."
  FINDING="$(jq -n --arg id "$IDENT" --arg what "$WHAT" --arg plain "$PLAIN" --arg surface "$SURFACE" \
    --arg commit "$COMMIT" \
    --argjson denom "$UNIVERSE_SIZE" --argjson executed "$ASSERTIONS_EXECUTED" --argjson passed "$ASSERTIONS_PASSED" '
    {identity_key: $id, what: $what, plain: $plain, mechanism: "DISCONNECTED",
     surface: $surface, surface_source: "declared", found_by: "sweep-family-A",
     evidence: {commit: $commit,
                measurement: {statement: "command ids with no interface caller", count: 1, denominator: $denom, source: "static-source"}},
     liveness: {assertions_executed: $executed, assertions_passed: $passed},
     responsible_agent: null, roster_action: null}')"
  FINDINGS="$(jq -c --argjson f "$FINDING" '. + [$f]' <<<"$FINDINGS")"
done

DURATION_MS=$(( (SECONDS - START) * 1000 ))
STATUS="pass"
[[ "$DISCONNECTED_N" -gt 0 ]] && STATUS="fail"

MEASUREMENTS="$(jq -cn --argjson count "$DISCONNECTED_N" --argjson denom "$UNIVERSE_SIZE" '
  [{statement: "command ids with no interface caller", count: $count, denominator: $denom, source: "static-source"}]')"

ENVELOPE="$(jq -cn \
  --arg check_id "$CHECK_ID" --arg basis "$EVIDENCE_BASIS" --arg surface "$SURFACE" \
  --arg status "$STATUS" --argjson universe "$UNIVERSE_SIZE" --argjson executed "$ASSERTIONS_EXECUTED" \
  --argjson passed "$ASSERTIONS_PASSED" --argjson excluded "$EXCLUDED" \
  --argjson measurements "$MEASUREMENTS" --argjson findings "$FINDINGS" --argjson duration "$DURATION_MS" '
  {schema: "sweep-result/v1", check_id: $check_id, evidence_basis: $basis, surface: $surface,
   status: $status, universe_size: $universe, excluded: $excluded, assertions_executed: $executed,
   assertions_passed: $passed, measurements: $measurements, findings: $findings, duration_ms: $duration}')"

echo "a5-command-callers: examined $UNIVERSE_SIZE command id(s), $DISCONNECTED_N with no interface caller"
echo "SWEEP_RESULT:v1 $(printf '%s' "$ENVELOPE" | base64 | tr -d '\n')"
