#!/usr/bin/env bash
# logic-receipt.sh — ADR-050 Contract A. The SOLE writer of
# docs/user/.meta/<unit>.receipts.json.
#
# Every field this script writes is either (a) recomputed from the repo at
# call time (git rev-parse, git hash-object — never trusted from the caller)
# or (b) passed explicitly by the caller as the literal recomputed value
# (e.g. a parity verdict returned by scripts/logic-parity-gate.sh). This
# script never reads anything from the producer's own doc file — that is
# the whole point of ADR-050 D3: "a receipts file the producer could have
# authored is worthless."
#
# Subcommands (one per Contract-A section; each PATCHes only its own section,
# preserving the rest of the file byte-for-byte otherwise):
#
#   init            <receipts-file> --unit <u> --entry-point <s> --entry-file <p> --dispatched-by human|foreman --repo-root <p>
#   set-extraction  <receipts-file> --doc <p> --spans <json-array> --repo-root <p>
#   set-closure     <receipts-file> --files <json-array-of-paths> --sources-incomplete <json-array> --repo-root <p>
#   set-harness     <receipts-file> --path <p> --command <s> --target-check PASS|FAIL --repo-root <p>
#   set-execution   <receipts-file> --status executed|unverified --examples <json-array> --repo-root <p>
#   update-execution <receipts-file> --repo-root <p>          (Contract C step 5 — timestamps only)
#   set-parity      <receipts-file> --verdict <V> [--counterexample <s>] [--checker <s>]
#   add-signal      <receipts-file> --signal <S> --detail <s>
#
# set-parity: verdict must be one of PASSED|FAILED|DEFERRED|PAYLOAD_TOO_LARGE|
# SOURCES-INCOMPLETE. Per ADR-050 Contract D, a DEFERRED verdict always forces
# checker to null regardless of any --checker argument — DEFERRED means no
# checker ran.
#
# Exit 0 on success. Exit 2 on usage error, missing repo-root git context, or
# malformed JSON argument.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "logic-receipt: python3 not found" >&2; exit 2; }

SUBCOMMAND="${1:-}"
RECEIPTS_FILE="${2:-}"
shift 2 2>/dev/null || true

if [[ -z "$SUBCOMMAND" || -z "$RECEIPTS_FILE" ]]; then
  echo "usage: logic-receipt.sh <init|set-extraction|set-closure|set-harness|set-execution|update-execution|set-parity|add-signal> <receipts-file> [--flag value ...]" >&2
  exit 2
fi

# Parse remaining --flag value pairs into a JSON object handed to python3.
# Bash 3.2 has no associative arrays, so build a flat args-as-JSON string.
ARGS_JSON="$(python3 - "$@" <<'PYEOF'
import json, sys
argv = sys.argv[1:]
out = {}
i = 0
while i < len(argv):
    a = argv[i]
    if not a.startswith('--'):
        print(f"logic-receipt: unexpected positional argument: {a}", file=sys.stderr)
        sys.exit(2)
    key = a[2:]
    if i + 1 >= len(argv):
        print(f"logic-receipt: flag --{key} missing a value", file=sys.stderr)
        sys.exit(2)
    out[key] = argv[i + 1]
    i += 2
print(json.dumps(out))
PYEOF
)" || exit 2

python3 - "$SUBCOMMAND" "$RECEIPTS_FILE" "$ARGS_JSON" <<'PYEOF'
import json, os, subprocess, sys, tempfile
from datetime import datetime, timezone

subcommand, receipts_file, args_json = sys.argv[1], sys.argv[2], sys.argv[3]
args = json.loads(args_json)

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def git(repo_root, *cmd):
    try:
        return subprocess.run(
            ["git", "-C", repo_root, *cmd],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"logic-receipt: git {' '.join(cmd)} failed in {repo_root}: {e}", file=sys.stderr)
        sys.exit(2)

def load():
    if os.path.exists(receipts_file):
        with open(receipts_file) as f:
            return json.load(f)
    return {
        "schemaVersion": 1,
        "unit": None,
        "dispatch": None,
        "extraction": None,
        "closure": None,
        "harness": None,
        "execution": None,
        "parity": None,
        "signals": [],
    }

def save(doc):
    os.makedirs(os.path.dirname(os.path.abspath(receipts_file)) or ".", exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(os.path.abspath(receipts_file)) or ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, receipts_file)
    except BaseException:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise

def require(keys):
    missing = [k for k in keys if k not in args]
    if missing:
        print(f"logic-receipt: {subcommand} missing required flag(s): {', '.join('--' + m for m in missing)}", file=sys.stderr)
        sys.exit(2)

doc = load()

if subcommand == "init":
    require(["unit", "entry-point", "entry-file", "dispatched-by", "repo-root"])
    if args["dispatched-by"] not in ("human", "foreman"):
        print("logic-receipt: --dispatched-by must be 'human' or 'foreman'", file=sys.stderr)
        sys.exit(2)
    doc["unit"] = args["unit"]
    doc["dispatch"] = {
        "entryPoint": args["entry-point"],
        "entryFile": args["entry-file"],
        "dispatchedBy": args["dispatched-by"],
        "dispatchedAt": now_iso(),
    }

elif subcommand == "set-extraction":
    require(["doc", "spans", "repo-root"])
    repo_root = args["repo-root"]
    commit = git(repo_root, "rev-parse", "HEAD")
    doc_hash = git(repo_root, "hash-object", args["doc"])
    try:
        spans = json.loads(args["spans"])
    except json.JSONDecodeError as e:
        print(f"logic-receipt: --spans is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    doc["extraction"] = {
        "commit": commit,
        "docPath": args["doc"],
        "docHash": doc_hash,
        "spans": spans,
    }

elif subcommand == "set-closure":
    require(["files", "sources-incomplete", "repo-root"])
    repo_root = args["repo-root"]
    try:
        files = json.loads(args["files"])
        sources_incomplete = json.loads(args["sources-incomplete"])
    except json.JSONDecodeError as e:
        print(f"logic-receipt: --files/--sources-incomplete is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    hashes = {f: git(repo_root, "hash-object", f) for f in files}
    doc["closure"] = {
        "files": files,
        "hashes": hashes,
        "sourcesIncomplete": sources_incomplete,
    }

elif subcommand == "set-harness":
    require(["path", "command", "target-check", "repo-root"])
    if args["target-check"] not in ("PASS", "FAIL"):
        print("logic-receipt: --target-check must be PASS or FAIL", file=sys.stderr)
        sys.exit(2)
    repo_root = args["repo-root"]
    doc["harness"] = {
        "path": args["path"],
        "hash": git(repo_root, "hash-object", args["path"]),
        "command": args["command"],
        "targetCheck": args["target-check"],
    }

elif subcommand == "set-execution":
    require(["status", "examples", "repo-root"])
    if args["status"] not in ("executed", "unverified"):
        print("logic-receipt: --status must be 'executed' or 'unverified'", file=sys.stderr)
        sys.exit(2)
    repo_root = args["repo-root"]
    try:
        examples = json.loads(args["examples"])
    except json.JSONDecodeError as e:
        print(f"logic-receipt: --examples is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    doc["execution"] = {
        "status": args["status"],
        "lastRunAt": now_iso(),
        "lastRunCommit": git(repo_root, "rev-parse", "HEAD"),
        "examples": examples,
    }

elif subcommand == "update-execution":
    require(["repo-root"])
    if not doc.get("execution"):
        print("logic-receipt: update-execution requires an existing execution section (run set-execution first)", file=sys.stderr)
        sys.exit(2)
    repo_root = args["repo-root"]
    doc["execution"]["lastRunAt"] = now_iso()
    doc["execution"]["lastRunCommit"] = git(repo_root, "rev-parse", "HEAD")

elif subcommand == "set-parity":
    require(["verdict"])
    verdict = args["verdict"]
    valid = ("PASSED", "FAILED", "DEFERRED", "PAYLOAD_TOO_LARGE", "SOURCES-INCOMPLETE")
    if verdict not in valid:
        print(f"logic-receipt: --verdict must be one of {', '.join(valid)}", file=sys.stderr)
        sys.exit(2)
    checker = args.get("checker")
    if verdict == "DEFERRED":
        # ADR-050 Contract D: a DEFERRED verdict means no checker ran.
        checker = None
    doc["parity"] = {
        "verdict": verdict,
        "counterexample": args.get("counterexample"),
        "checkedAt": now_iso(),
        "checker": checker,
    }

elif subcommand == "add-signal":
    require(["signal", "detail"])
    doc.setdefault("signals", []).append({
        "signal": args["signal"],
        "raisedAt": now_iso(),
        "detail": args["detail"],
    })

else:
    print(f"logic-receipt: unknown subcommand: {subcommand}", file=sys.stderr)
    sys.exit(2)

save(doc)
PYEOF
