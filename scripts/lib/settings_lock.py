#!/usr/bin/env python3
"""scripts/lib/settings_lock.py — the ONLY code path that opens the Claude
Code settings lock (ADR-044 Contract C.1).

Two writers must serialize against each other and previously could not:
`native_settings_edit.py` locked with Python `fcntl.flock` on a path it
derived internally, while `scripts/permissions-compile.sh` (bash) has no
equivalent — macOS ships no `flock(1)`. This module is a behavior-preserving
extraction of `native_settings_edit.py`'s original `atomic_write()` (moved,
not rewritten — see that file's history) plus a second entry point,
`--apply-permissions-plan`, that the bash compiler shells out to. Both
callers resolve the identical lock path: `<settings_path>.lock`, computed
against the REALPATH of the settings file's containing directory (so two
callers invoked from different CWDs but targeting the same file converge on
one lock when their resolved absolute paths are the same inode (e.g. both
via `/private/tmp`, not one via the `/tmp` symlink), and the JSON write
itself is fsync'd before rename — see
`_atomic_write_json`). `--apply-permissions-plan` does not trust the plan's
`compiled_deny`/`compiled_ask` verbatim: it independently re-reads the
permissions baseline and the live MCP server snapshot from disk and refuses
any rule string that is not derivable from them (see
`_verify_plan_rules`/`_derivable_universe`) — a bare
`echo '{...}' | settings_lock.py --apply-permissions-plan` cannot smuggle an
*arbitrary rule* past this writer. It does NOT independently guard against a
plan that simply *omits* rules (a near-empty or truncated plan still prunes
every stack-owned entry not present in it) — per the D1 amendment, hardening
this writer against a caller who already has Bash execution is out of scope;
that caller can edit settings.json directly with equal ease. This module's
checks are accident-prevention (malformed/mismatched plans from legitimate
callers), not a security boundary.

Exit codes on the CLI entry point follow the native-settings-edit convention:
  0  applied
  2  refused (Refused) — one-line sanitized reason
  3  I/O / parse error (IOErrorSanitized) — sanitized
"""

import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
from datetime import date

LOCK_SUFFIX = ".lock"


class Refused(Exception):
    """Validation / policy refusal — exit 2 convention."""


class IOErrorSanitized(Exception):
    """Read/parse failure with a message safe to print — exit 3 convention."""


def _today():
    return date.today().isoformat()


# --- Generic JSON load/write helpers (shared by both writer entry points) ---

def load_json_object(path, what="file"):
    """Return parsed dict, or {} if the file is absent. Never echoes content."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        raise IOErrorSanitized(
            f"could not read or parse {what} at {_short(path)} "
            "(file unreadable or not valid JSON)"
        )
    if not isinstance(data, dict):
        raise IOErrorSanitized(f"{what} at {_short(path)} is not a JSON object")
    return data


def load_settings(path):
    return load_json_object(path, "settings")


def _short(path):
    home = os.path.expanduser("~")
    if home and (path == home or path.startswith(home + os.sep)):
        return path.replace(home, "~", 1)
    return path


def _atomic_write_json(path, data):
    """mkstemp (unpredictable name + O_EXCL), fsync the temp file's contents
    to disk, THEN os.replace() — same hardening as the original
    atomic_write() (preserved verbatim, not rewritten), plus the fsync the
    docstring always claimed but the code never performed. D8's crash-recovery
    ordering (sidecar written before settings.json, both via this function) is
    load-bearing on the rename actually being durable, which requires the
    temp file's bytes to have hit disk before the rename is issued."""
    target_dir = os.path.dirname(path)
    os.makedirs(target_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=target_dir, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2, ensure_ascii=False)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp_path, path)  # atomic; replaces the dir entry, not a symlink target
        tmp_path = None
        try:
            dir_fd = os.open(target_dir, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass  # best-effort: durability of the rename itself, not correctness
    finally:
        if tmp_path is not None and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


# --- The single shared locked writer ----------------------------------------

def locked_update(settings_path, mutate, *, pre_check=None, extra_writes=()):
    """Acquire `<settings_path>.lock` (O_CREAT|O_RDWR|O_NOFOLLOW mode 0600 +
    fcntl.flock(LOCK_EX)); run pre_check() under the lock; re-read settings
    under the lock; data = mutate(data); write each entry of `extra_writes`
    (zero-arg callables returning (path, dict) — return (None, None) to skip
    that write) IN ORDER, then settings via mkstemp+fsync+rename; LOCK_UN +
    close in `finally`.

    Hardened against a hostile project `.claude/` dir (security-auditor
    findings, preserved verbatim from the original atomic_write()):
    - lock opened with O_NOFOLLOW + no truncate, so a planted
      `settings.json.lock` symlink can neither be followed nor used to
      truncate a victim file.
    - temp written via mkstemp (unpredictable name + O_EXCL), so a planted
      `settings.json.tmp` symlink cannot redirect the write.
    - `pre_check` runs AFTER the lock is held, closing any TOCTOU between
      target resolution and the write.

    `settings_path` is canonicalized (realpath of its containing directory,
    basename preserved) before the lock path is derived. This closes the
    string-identity half of the ADR-044 finding: two callers that both
    resolve to the same real path but spell it differently (`/tmp/x` vs the
    realpath'd `/private/tmp/x` on macOS, or a symlinked repo root) now
    converge on the same `<settings_path>.lock` and genuinely contend
    (`flock` is inode-scoped). It does NOT make two different absolute paths
    converge -- a caller resolving `--repo-root .` from one CWD and a second
    caller resolving an absolute path from a genuinely different CWD still
    name two different files/inodes, and no amount of canonicalization can
    merge those without one of the callers being wrong about where the
    project root is; that is a caller-discipline problem, not something this
    function can fix. Only the directory component is realpath'd — the
    settings FILE itself is never resolved through a symlink, so a symlinked
    settings.json still gets
    written at the path the caller named, not its link target.
    """
    target_dir = os.path.dirname(settings_path) or "."
    os.makedirs(target_dir, exist_ok=True)
    settings_path = os.path.join(os.path.realpath(target_dir), os.path.basename(settings_path))
    target_dir = os.path.dirname(settings_path)
    lock_path = settings_path + LOCK_SUFFIX
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise Refused("could not acquire the settings lock (suspicious lock file)")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        if pre_check is not None:
            pre_check()
        data = load_settings(settings_path)  # re-read under the lock
        data = mutate(data)
        for compute in extra_writes:
            ex_path, ex_content = compute()
            if ex_path is None:
                continue
            _atomic_write_json(ex_path, ex_content)
        _atomic_write_json(settings_path, data)
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


# --- Permissions-plan application (D8 ownership ledger) --------------------
# Used only via --apply-permissions-plan. `native_settings_edit.py` never
# calls into this section.

CLASS_ORDER = {"identity": 0, "path": 1, "bash": 2}


def classify_rule(rule):
    """Infer a rule's enforcement class from its shape (ADR-044 D1). Used for
    the human-readable summary only — the plan's own class tags are
    authoritative for anything the compiler emitted this round."""
    if rule.startswith("mcp__") or rule in ("WebFetch", "WebSearch"):
        return "identity"
    if rule.startswith(("Read(", "Edit(", "Write(")):
        return "path"
    if rule.startswith("Bash("):
        return "bash"
    return "unknown"


def _apply_ledger(existing, compiled, ledger, pinned):
    """ADR-044 D8 steps 1-4 for one rule bucket (deny or ask).

    `existing` / `compiled` are ordered lists of bare rule strings (no
    `set()` anywhere here — order is semantically load-bearing and Python
    set iteration order is not deterministic across runs).

    Returns (new_list, new_ledger, adopted_count, pruned_list).
    """
    ledger = {k: dict(v) for k, v in ledger.items()}

    # Step 1 — Adopt: every live string with no ledger entry is human-owned.
    adopted = 0
    for s in existing:
        if s not in ledger:
            ledger[s] = {"owner": "human", "first_seen": _today(), "last_compiled": None}
            adopted += 1

    # Step 2 — Claim: every compiled string with no ledger entry becomes
    # stack-owned; an existing entry (of either owner) only gets its
    # last_compiled refreshed.
    for s in compiled:
        if s not in ledger:
            ledger[s] = {"owner": "stack", "first_seen": _today(), "last_compiled": _today()}
        else:
            entry = dict(ledger[s])
            entry["last_compiled"] = _today()
            ledger[s] = entry

    # Pinned escape hatch: owner forced to "human" permanently; never
    # removed, never re-claimed (applied after adopt/claim so a pin always
    # wins, even against a string the stack just claimed this same round).
    for s in pinned:
        if s in ledger:
            entry = dict(ledger[s])
            entry["owner"] = "human"
            ledger[s] = entry
        else:
            ledger[s] = {"owner": "human", "first_seen": _today(), "last_compiled": None}

    # Step 3 — Remove: only strings the compiler provably emitted before and
    # does not emit this round, and that are not pinned.
    pinned_set = list(pinned)
    removable = []
    for s in existing:
        entry = ledger.get(s)
        if entry and entry.get("owner") == "stack" and s not in compiled and s not in pinned_set:
            removable.append(s)
    for s in removable:
        entry = dict(ledger[s])
        entry["removed"] = _today()
        ledger[s] = entry

    # Step 4 — Order: survivors keep relative order; new strings are
    # appended in the order the compiler already produced them in (identity,
    # path, bash, then lexical — assigned when the plan was built).
    survivors = [s for s in existing if s not in removable]
    new_list = list(survivors)
    for s in compiled:
        if s not in new_list:
            new_list.append(s)

    pruned = [s for s in removable]
    return new_list, ledger, adopted, pruned


def _apply_user_scope(existing, floor_rules, retired, prune):
    """User-scope floor: plain union (merge_json semantics — never removes on
    its own), plus the explicit `retired_rules` prune (the user-scope
    ownership ledger per D8 — no adopt/claim machinery needed here)."""
    new_list = list(existing)
    for s in floor_rules:
        if s not in new_list:
            new_list.append(s)
    pruned = []
    if prune:
        retired_set = list(retired)
        kept = [s for s in new_list if s not in retired_set]
        pruned = [s for s in new_list if s in retired_set]
        new_list = kept
    return new_list, pruned


def _read_plan_stdin():
    raw = sys.stdin.read()
    try:
        return json.loads(raw)
    except ValueError:
        raise IOErrorSanitized("plan on stdin is not valid JSON")


# --- Independent plan verification (ADR-044 D7 / Contract C) ---------------
# `--apply-permissions-plan` must not trust a caller-supplied plan's
# compiled_deny/compiled_ask verbatim -- "no free-form rule argument, every
# rule string must be derivable from the baseline" is a hard-refusal
# contract on THIS writer, not merely a discipline the bash compiler happens
# to follow. Everything below is read fresh from disk, never taken from the
# plan on stdin (an attacker-supplied path or server list would defeat the
# check): the baseline (same install-then-repo resolution order as
# scripts/permissions-compile.sh), the live MCP server snapshot, and (for the
# user-scope prune) the baseline's own `retired_rules` -- taking that array
# from the plan instead would let a hostile plan smuggle
# `retired_rules: [<every floor rule>]` + `prune_user: true` and strip the
# floor through this door instead of editing the baseline file directly.

def _claude_home():
    """os.path.expanduser("~") (HOME env var). Tried switching this to
    pwd.getpwuid for hygiene (avoid trusting HOME) but reverted: HOME
    override is how tests/CI/containers legitimately sandbox this module
    against a fixture, and per the D1 amendment this was never a security
    fix anyway (a Bash-capable caller has equal-effort alternatives either
    way) — not worth breaking legitimate HOME-based isolation for."""
    return os.path.expanduser("~")


def _resolve_baseline_path():
    """Same precedence as scripts/permissions-compile.sh: the installed copy
    first, then the CLAUDE_PLUGIN_ROOT/repo fallback."""
    home = _claude_home()
    installed = os.path.join(home, ".claude", "config", "permissions-baseline.json")
    if os.path.isfile(installed):
        return installed
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(home, ".claude")
    return os.path.join(root, "config", "permissions-baseline.json")


def _resolve_snapshot_path():
    return os.path.join(_claude_home(), ".claude", "session-state", "live-capabilities.json")


def _load_baseline_for_verification():
    path = _resolve_baseline_path()
    if not os.path.isfile(path):
        raise IOErrorSanitized(f"could not find the permissions baseline at {_short(path)}")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        raise IOErrorSanitized(f"could not read or parse the permissions baseline at {_short(path)}")
    if not isinstance(data, dict):
        raise IOErrorSanitized(f"permissions baseline at {_short(path)} is not a JSON object")
    return data


def _live_servers():
    """Independent read of the live MCP server snapshot -- never taken from
    the plan's own `inputs.mcp_servers`, which a hostile plan could pad with
    a name that was never actually live to unlock an mcp__<name> rule."""
    path = _resolve_snapshot_path()
    if not os.path.isfile(path):
        return set()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            snap = json.load(fh)
    except (OSError, ValueError):
        return set()
    if not isinstance(snap, dict):
        return set()
    mcp = snap.get("mcp_servers")
    if not isinstance(mcp, list):
        return set()
    return {
        m["name"] for m in mcp
        if isinstance(m, dict) and isinstance(m.get("name"), str)
    }


def _overlay_rules_into(overlay, servers, universe):
    if not isinstance(overlay, dict):
        return
    for tool in overlay.get("mcp_tool_denies") or []:
        if isinstance(tool, str):
            for srv in servers:
                universe.add(f"mcp__{srv}__{tool}")
    for srv_name in overlay.get("mcp_server_denies") or []:
        if isinstance(srv_name, str) and srv_name in servers:
            universe.add(f"mcp__{srv_name}")
    for verb in overlay.get("bash_guardrails") or []:
        if isinstance(verb, str):
            universe.add(f"Bash({verb}:*)")


def _derivable_universe(baseline, servers, scope):
    """Every rule string the baseline could ever legitimately produce for
    `scope` -- a superset of any single compile's compiled_deny/compiled_ask,
    since a real plan is always narrowed further by domain_mode,
    sensitivity, required_approvals, overlay suppression, and waivers.
    Checking plan membership against this superset is invariant under all of
    that narrowing, so it can never disagree with a legitimately-compiled
    plan (unlike a full re-derivation, which would have to replicate the
    compiler's suppression/waiver logic exactly)."""
    universe = set()
    floor = baseline.get("floor") if isinstance(baseline.get("floor"), dict) else {}
    file_tools = baseline.get("file_tools")
    if not isinstance(file_tools, list) or not all(isinstance(t, str) for t in file_tools):
        file_tools = ["Edit", "Write"]

    for item in floor.get("deny") or []:
        if isinstance(item, dict) and isinstance(item.get("rule"), str):
            universe.add(item["rule"])
    for pr in floor.get("path_rules") or []:
        if isinstance(pr, dict) and isinstance(pr.get("path"), str):
            for tool in file_tools:
                universe.add(f"{tool}({pr['path']})")

    if scope == "user":
        return universe  # user scope only ever compiles the floor (D3)

    for overlay in (baseline.get("domain_overlays") or {}).values():
        _overlay_rules_into(overlay, servers, universe)
    for overlay in (baseline.get("approval_gate_map") or {}).values():
        _overlay_rules_into(overlay, servers, universe)
    for overlay in (baseline.get("sensitivity_overlays") or {}).values():
        if isinstance(overlay, dict):
            for item in overlay.get("deny") or []:
                if isinstance(item, dict) and isinstance(item.get("rule"), str):
                    universe.add(item["rule"])
            _overlay_rules_into(overlay, servers, universe)

    return universe


def _verify_plan_rules(plan, scope, baseline):
    """Refuse (Refused -> exit 2) any compiled_deny/compiled_ask entry whose
    rule string is not in the on-disk-derived universe for this scope. This
    is what makes 'a bare `echo plan.json | settings_lock.py
    --apply-permissions-plan` cannot silently wipe or set arbitrary
    permissions.deny/ask content' true at the writer, not just at the
    compiler that is supposed to call it."""
    servers = _live_servers()
    universe = _derivable_universe(baseline, servers, scope)
    for bucket in ("compiled_deny", "compiled_ask"):
        for entry in plan.get(bucket, []):
            rule = entry.get("rule") if isinstance(entry, dict) else None
            if not isinstance(rule, str) or rule not in universe:
                raise Refused(
                    "plan contains a rule not derivable from the permissions "
                    f"baseline ({bucket}: {rule!r}); refusing the whole plan"
                )


def apply_permissions_plan(target, sidecar_path):
    plan = _read_plan_stdin()
    if not isinstance(plan, dict):
        raise IOErrorSanitized("plan on stdin is not a JSON object")
    scope = plan.get("scope")
    if scope not in ("project", "user"):
        raise Refused("plan scope must be 'project' or 'user'")

    baseline = _load_baseline_for_verification()
    _verify_plan_rules(plan, scope, baseline)

    result = {}

    def mutate(data):
        perms = data.get("permissions")
        perms = dict(perms) if isinstance(perms, dict) else {}

        existing_deny = [s for s in perms.get("deny", []) if isinstance(s, str)]
        existing_ask = [s for s in perms.get("ask", []) if isinstance(s, str)]

        if scope == "user":
            floor_deny = [r["rule"] for r in plan.get("compiled_deny", [])]
            # retired_rules comes from the baseline loaded fresh from disk
            # above (_load_baseline_for_verification), never from the plan on
            # stdin -- otherwise a hostile plan could pair a fabricated
            # retired_rules list with prune_user=true to strip the floor
            # through this door instead of editing the baseline file itself.
            retired = baseline.get("retired_rules", [])
            if not isinstance(retired, list):
                retired = []
            prune = bool(plan.get("prune_user"))
            new_deny, pruned = _apply_user_scope(existing_deny, floor_deny, retired, prune)
            new_ask = existing_ask  # the floor never emits ask rules

            result["new_deny"] = new_deny
            result["new_ask"] = new_ask
            result["adopted"] = 0
            result["pruned"] = pruned
        else:
            sidecar_old = load_json_object(sidecar_path, "sidecar") if sidecar_path else {}
            ledger_deny_old = (sidecar_old.get("ledger") or {}).get("deny", {})
            ledger_ask_old = (sidecar_old.get("ledger") or {}).get("ask", {})
            pinned = sidecar_old.get("pinned", [])
            if not isinstance(pinned, list):
                pinned = []

            compiled_deny = [r["rule"] for r in plan.get("compiled_deny", [])]
            compiled_ask = [r["rule"] for r in plan.get("compiled_ask", [])]

            new_deny, ledger_deny_new, adopted_deny, pruned_deny = _apply_ledger(
                existing_deny, compiled_deny, ledger_deny_old, pinned
            )
            new_ask, ledger_ask_new, adopted_ask, pruned_ask = _apply_ledger(
                existing_ask, compiled_ask, ledger_ask_old, pinned
            )

            result["new_deny"] = new_deny
            result["new_ask"] = new_ask
            result["adopted"] = adopted_deny + adopted_ask
            result["pruned"] = pruned_deny + pruned_ask
            result["ledger_deny"] = ledger_deny_new
            result["ledger_ask"] = ledger_ask_new
            result["sidecar_old"] = sidecar_old
            result["compiled_deny"] = compiled_deny
            result["compiled_ask"] = compiled_ask

        perms["deny"] = result["new_deny"]
        perms["ask"] = result["new_ask"]
        data["permissions"] = perms
        return data

    def compute_sidecar():
        if scope != "project" or not sidecar_path:
            return (None, None)
        old = result.get("sidecar_old", {})
        new_sidecar = dict(old)
        new_sidecar["baseline_version"] = plan.get("baseline_version")
        new_sidecar["compiled_at"] = _today()
        new_sidecar["inputs"] = plan.get("inputs", {})
        new_sidecar["emitted"] = {
            "deny": result.get("compiled_deny", []),
            "ask": result.get("compiled_ask", []),
        }
        new_sidecar["ledger"] = {
            "deny": result.get("ledger_deny", {}),
            "ask": result.get("ledger_ask", {}),
        }
        new_sidecar.setdefault("pinned", old.get("pinned", []))
        new_sidecar.setdefault("waivers", old.get("waivers", []))
        return (sidecar_path, new_sidecar)

    extra_writes = () if scope == "user" else (compute_sidecar,)
    locked_update(target, mutate, extra_writes=extra_writes)

    counts = {"identity": 0, "path": 0, "bash": 0, "unknown": 0}
    for rule in result["new_deny"]:
        counts[classify_rule(rule)] += 1

    summary = {
        "scope": scope,
        "new_deny": result["new_deny"],
        "new_ask": result["new_ask"],
        "adopted": result["adopted"],
        "pruned": result["pruned"],
        "counts": counts,
    }
    print(json.dumps(summary))


# --- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="settings_lock")
    p.add_argument("--apply-permissions-plan", action="store_true", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--sidecar", default=None)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        apply_permissions_plan(args.target, args.sidecar)
        return 0
    except Refused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    except IOErrorSanitized as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
