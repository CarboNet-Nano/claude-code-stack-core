#!/usr/bin/env python3
"""scripts/lib/mcp_state.py — ADR-046 D18 (revision 2): state schema v3.

State is a plain JSON file, no longer embedded in the issue body (D20).
This module is intentionally small — three pure-ish functions:

  load(path)             -> state dict, or None if absent/unparseable/wrong
                             version/invalid (never raises on untrusted bytes)
  dump(state, path)      -> True on a verified write, False otherwise
                             (write-then-verify: re-read + compare, D18r2)
  validate(state)        -> bool, pure function, no I/O

`load()` must never raise on adversarial or corrupt input — every failure
degrades to "treat as absent" (seed mode, D11r2), never a crash. `validate()`
checks container shapes BEFORE any field-value indexing (D18r2 round-4 fix —
checking field values first throws on `"pending": ["not-a-map"]` instead of
rejecting cleanly).

CLI (used by scripts/lib/mcp-sweep.sh so all state I/O funnels through one
python3 invocation per call, matching D14's "python3 for arithmetic only,
never ambient state" discipline):

  mcp_state.py load   <path>                 -> canonical JSON on stdout, exit 0
                                                  or "null" on stdout, exit 0 (absent/invalid)
  mcp_state.py dump   <path>   (state on stdin) -> exit 0 verified-written, 1 otherwise
  mcp_state.py validate        (state on stdin) -> exit 0 valid, 1 invalid
"""

import json
import sys
from datetime import datetime, timezone

SCHEMA_VERSION = 3
_SOURCES = ("npm", "github", "registry")
_SOURCE_HEALTH_INT_FIELDS = (
    "failStreak",
    "alertedAt",
    "pageCapStreak",
    "pageCapAlertedAt",
)


def _is_non_negative_int(value):
    # bool is a subclass of int in Python — explicitly excluded so a stray
    # `true`/`false` in a counter field is rejected, not silently coerced.
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_rfc3339(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        # Python's fromisoformat (3.11+) accepts a trailing "Z"; the older
        # runtimes this repo also runs under (macos-latest ships whichever
        # python3 Homebrew/Xcode provides) may not, so normalize explicitly
        # rather than assume a version.
        normalized = value.replace("Z", "+00:00") if value.endswith("Z") else value
        dt = datetime.fromisoformat(normalized)
    except (ValueError, TypeError):
        return False
    if dt.tzinfo is None:
        return False
    return True


def validate(state):
    """Pure function. Returns True iff `state` is a structurally valid v3
    state dict. Never raises — every check is a guarded isinstance/get."""
    if not isinstance(state, dict):
        return False
    if state.get("v") != SCHEMA_VERSION:
        return False

    # --- Step 1: container shapes, before any indexing/iteration. ---
    pending = state.get("pending")
    if not isinstance(pending, dict):
        return False

    aged = state.get("aged")
    if not isinstance(aged, list):
        return False

    source_health = state.get("sourceHealth")
    if not isinstance(source_health, dict):
        return False
    for source in _SOURCES:
        health = source_health.get(source)
        if not isinstance(health, dict):
            return False

    # --- Step 2: per-field checks. ---
    if not _is_non_negative_int(state.get("cleanRuns")):
        return False
    if not _is_non_negative_int(state.get("dropped")):
        return False
    if not _is_non_negative_int(state.get("allEmptyStreak")):
        return False
    if not _is_non_negative_int(state.get("allEmptyAlertedAt")):
        return False

    for source in _SOURCES:
        health = source_health[source]
        for field in _SOURCE_HEALTH_INT_FIELDS:
            if not _is_non_negative_int(health.get(field)):
                return False

    for key in aged:
        if not isinstance(key, str):
            return False

    for key, first_seen in pending.items():
        if not isinstance(key, str):
            return False
        if not _is_rfc3339(first_seen):
            return False

    if not _is_rfc3339(state.get("ackedAtUtc")):
        return False
    if not _is_rfc3339(state.get("lastRunUtc")):
        return False

    if not isinstance(state.get("mode"), str):
        return False

    return True


def load(path):
    """Returns the parsed state dict, or None on any absence/corruption/
    invalidity. Never raises."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None

    try:
        state = json.loads(raw)
    except (ValueError, TypeError):
        return None

    if not validate(state):
        return None

    return state


def _canonical(state):
    return json.dumps(state, sort_keys=True, ensure_ascii=True)


def dump(state, path):
    """Writes `state` to `path`, then re-reads and compares canonically
    (write-then-verify, D18r2). Returns True only on a verified write.
    Refuses to write a state that does not pass validate()."""
    if not validate(state):
        return False

    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(_canonical(state))
            fh.flush()
    except OSError:
        return False

    reloaded = load(path)
    if reloaded is None:
        return False

    return _canonical(reloaded) == _canonical(state)


def _cli_load(path):
    state = load(path)
    print(json.dumps(state))
    return 0


def _cli_dump(path):
    try:
        state = json.loads(sys.stdin.read())
    except (ValueError, TypeError):
        return 1
    return 0 if dump(state, path) else 1


def _cli_validate():
    try:
        state = json.loads(sys.stdin.read())
    except (ValueError, TypeError):
        return 1
    return 0 if validate(state) else 1


def main(argv):
    if len(argv) < 2:
        print("usage: mcp_state.py <load|dump|validate> [path]", file=sys.stderr)
        return 2

    cmd = argv[1]
    if cmd == "load":
        if len(argv) != 3:
            print("usage: mcp_state.py load <path>", file=sys.stderr)
            return 2
        return _cli_load(argv[2])
    if cmd == "dump":
        if len(argv) != 3:
            print("usage: mcp_state.py dump <path>", file=sys.stderr)
            return 2
        return _cli_dump(argv[2])
    if cmd == "validate":
        return _cli_validate()

    print(f"usage: unknown command '{cmd}'", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
