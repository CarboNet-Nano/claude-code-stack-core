#!/usr/bin/env python3
"""scripts/lib/settings_lock.py — the ONLY code path that opens the Claude
Code settings lock (ADR-044 Contract C.1).

ADR-071 D7: `--apply-sandbox-policy` is a THIRD entry point (see
apply_sandbox_policy() below), added by scripts/sandbox-policy-compile.sh --
a second, independently-owned compiler that shares only this lock and this
writer with permissions-compile.sh's --apply-permissions-plan. It touches
ONLY `sandbox.network.allowedDomains`, `sandbox.failIfUnavailable`, and the
`WebFetch(domain:...)` entries inside `permissions.allow` -- nothing else in
settings.json, and it never reads or writes permissions.deny/ask or the D8
ownership ledger those touch. Like --apply-permissions-plan, it does not
trust its stdin plan's `project`/`local`/`webfetch_prune` arrays verbatim: it
re-reads config/vendor-hosts.json (or the same hardcoded fallback the
compiler uses, F8-drift-gated) from disk and refuses any plan entry that does
not reference a governed vendor host.

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
from datetime import date, datetime

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

def locked_update(settings_path, mutate, *, pre_check=None, extra_writes=(), write_target=True, post_target_writes=()):
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
        if write_target:
            _atomic_write_json(settings_path, data)
        # post_target_writes: red-team MEDIUM fix, 2026-08-11. A write here
        # happens ONLY after settings_path's own write has completed (still
        # under the same lock) -- for a record that CLAIMS something about
        # settings_path's content (ADR-071's receipt), writing it first would
        # let a kill between the two renames leave that claim asserting a
        # tightened policy the governing file does not yet actually hold --
        # a lie in the unsafe direction. Ordinary extra_writes (ADR-044's
        # sidecar ledger) keep their existing before-target order
        # deliberately -- that ledger's crash-recovery argument (see
        # apply_permissions_plan's docstring) is the OPPOSITE: written before
        # is what makes ITS convergence property hold. Do not merge these two
        # lists; they have inverse correctness requirements.
        for compute in post_target_writes:
            ex_path, ex_content = compute()
            if ex_path is None:
                continue
            _atomic_write_json(ex_path, ex_content)
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
        file_tools = ["Edit"]

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


# --- Sandbox-policy plan application (ADR-071 D7 / D14) --------------------
# Used only via --apply-sandbox-policy. apply_permissions_plan() never calls
# into this section, and this section never touches permissions.deny/ask.

HARDCODED_VENDOR_HOSTS = (
    "api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com",
    "api.deepseek.com", "api.x.ai", "openrouter.ai",
)  # F8 drift gate: this tuple must equal the host set in config/vendor-hosts.json
   # and scripts/sandbox-policy-compile.sh's own fallback constant.

WEBFETCH_RE = re.compile(r"^WebFetch\(domain:(.+)\)$")


def _sp_normalize_host(h):
    h = h.strip().lower()
    if h.endswith("."):
        h = h[:-1]
    if ":" in h and not h.startswith("["):  # strip :port; governed hosts never carry [ipv6]
        h = h.split(":", 1)[0]
    return h


_SP_RUNTIME_HOST = "api.anthropic.com"
_SP_VENDOR_REQUIRED_FIELDS = ("host", "vendor", "kind", "is_runtime", "cleared_at_sensitive", "reviewed_on", "terms_url", "why")


def _sp_validate_vendor_hosts(data):
    """Structural validator -- kept in sync with
    scripts/sandbox-policy-compile.sh's validate_vendor_hosts() (security-
    audit CRITICAL fix, 2026-08-11: this writer previously only checked
    `isinstance(host, str)`, so a structurally-broken vendor-hosts.json --
    e.g. a fake is_runtime:true entry -- was silently accepted here even
    though the compiler independently rejects it. Returns True/False; never
    raises."""
    if not isinstance(data, dict):
        return False
    vendors = data.get("vendors")
    if not isinstance(vendors, list) or not vendors:
        return False
    seen, runtime_hosts = set(), []
    for v in vendors:
        if not isinstance(v, dict):
            return False
        if any(f not in v for f in _SP_VENDOR_REQUIRED_FIELDS):
            return False
        host = v.get("host")
        if not isinstance(host, str) or not host:
            return False
        h = host.strip().lower()
        if h != host or "://" in host or "*" in host or ":" in host or " " in host:
            return False
        if h in seen:
            return False
        seen.add(h)
        if not isinstance(v.get("is_runtime"), bool) or not isinstance(v.get("cleared_at_sensitive"), bool):
            return False
        if v["is_runtime"]:
            runtime_hosts.append(h)
    return len(runtime_hosts) == 1 and runtime_hosts[0] == _SP_RUNTIME_HOST


def _sp_load_vendor_records(vendor_hosts_path):
    """Fresh-from-disk read of the full, VALIDATED vendor records -- never
    taken from the plan on stdin (see _sp_load_vendor_universe's original
    docstring for why). Falls back to the hardcoded fallback records
    (ADR-071 D8, F8-gated) when the file is absent, unparseable, OR fails
    structural validation -- a broken vendor-hosts.json must never be
    trusted for ANY purpose, universe membership or clearance."""
    try:
        with open(vendor_hosts_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if _sp_validate_vendor_hosts(data):
            return [
                {
                    "host": _sp_normalize_host(v["host"]),
                    "is_runtime": v["is_runtime"] is True,
                    "cleared_at_sensitive": v["cleared_at_sensitive"] is True,
                    "reviewed_on": v.get("reviewed_on"),
                }
                for v in data["vendors"]
            ]
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return [
        {"host": h, "is_runtime": h == _SP_RUNTIME_HOST,
         "cleared_at_sensitive": False, "reviewed_on": None}
        for h in HARDCODED_VENDOR_HOSTS
    ]


def _sp_policy_for_level(level, records):
    """Independent re-derivation of the allowed-host set for `level`, using
    freshly-loaded `records` -- the SAME three-tier rule
    scripts/sandbox-policy-compile.sh's policy_for() implements, duplicated
    here (not imported -- this module has no import path back to a bash
    script) so the writer can verify a plan's clearance claims itself rather
    than trusting the compiler's classification of its own plan."""
    all_hosts = {r["host"] for r in records}
    runtime = {r["host"] for r in records if r["is_runtime"]}
    if level == "normal":
        return set(all_hosts)
    if level == "sensitive":
        return set(runtime) | {r["host"] for r in records if r["cleared_at_sensitive"] and r["reviewed_on"]}
    return set(runtime)  # confidential / restricted / unknown -> most restrictive


def _sp_load_vendor_universe(vendor_hosts_path):
    """Backward-compatible host-set view over _sp_load_vendor_records(), used
    by _sp_verify_plan's membership check."""
    return {r["host"] for r in _sp_load_vendor_records(vendor_hosts_path)}


def _sp_resolve_current_level(repo):
    """Independent, fresh-from-disk re-derivation of the CURRENT sensitivity
    level for `repo` -- duplicated from scripts/sandbox-policy-compile.sh's
    resolve_level() (not imported; no path from this module back to a bash
    script). Security-audit HIGH fix (H1/H2), 2026-08-11: used to verify a
    plan is not stale relative to what stack-config.json says RIGHT NOW,
    under the lock -- the plan itself was computed before the lock was
    acquired and could be racing a concurrent compile."""
    if not isinstance(repo, str) or not repo:
        return "restricted"
    cfg_path = os.path.join(repo, ".claude", "stack-config.json")
    try:
        with open(cfg_path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return "restricted"
    if not isinstance(cfg, dict):
        return "restricted"
    sens = cfg.get("sensitivity")
    if sens is None:
        return "normal"
    if not isinstance(sens, dict):
        return "restricted"
    level = sens.get("level")
    if level is None:
        return "normal"
    if not isinstance(level, str) or level not in ("normal", "sensitive", "confidential"):
        return "restricted"
    return level


def _sp_references_governed_host(entry, universe):
    """True if `entry` (a literal allowedDomains string, which may itself be
    a glob such as '*.openai.com') is either an exact governed host or a
    pattern that matches one -- the same denied_entry() shape ADR-071 D6/S7
    define, reused here so the writer can refuse a plan entry that names
    something outside the governed set, without trusting the compiler's own
    classification of it."""
    import fnmatch
    n = _sp_normalize_host(entry)
    if n in universe:
        return True
    return any(fnmatch.fnmatch(u, n) for u in universe)


def _sp_verify_plan(plan, universe):
    """Refuse (Refused -> exit 2) a plan that names anything outside the
    governed vendor-host universe, or whose add/remove sets overlap. This is
    the D7 'refuses any plan naming a host outside it' contract, enforced at
    the writer, not merely assumed of the caller."""
    project = plan.get("project") if isinstance(plan.get("project"), dict) else {}
    local = plan.get("local") if isinstance(plan.get("local"), dict) else {}
    p_add = [s for s in project.get("add", []) if isinstance(s, str)]
    p_remove = [s for s in project.get("remove", []) if isinstance(s, str)]
    l_remove = [s for s in local.get("remove", []) if isinstance(s, str)]

    if set(p_add) & set(p_remove):
        raise Refused("plan project.add and project.remove overlap; refusing the whole plan")

    for entry in p_add:
        # add entries are always canonical (never a glob) -- exact membership only.
        if _sp_normalize_host(entry) not in universe:
            raise Refused(f"plan names a host outside config/vendor-hosts.json (project.add: {entry!r})")
    for entry in p_remove + l_remove:
        if not _sp_references_governed_host(entry, universe):
            raise Refused(f"plan names a host outside config/vendor-hosts.json (remove: {entry!r})")

    wf = plan.get("webfetch_prune") if isinstance(plan.get("webfetch_prune"), dict) else {}
    for scope in ("project", "local"):
        for entry in wf.get(scope, []) or []:
            if not isinstance(entry, str):
                raise Refused("webfetch_prune entry is not a string")
            m = WEBFETCH_RE.match(entry)
            if not m:
                raise Refused(f"webfetch_prune entry is not a WebFetch(domain:...) rule: {entry!r}")
            if not _sp_references_governed_host(m.group(1), universe):
                raise Refused(f"webfetch_prune names a host outside config/vendor-hosts.json: {entry!r}")


def _sp_apply_domains(network, add, remove):
    domains = [d for d in network.get("allowedDomains", []) if isinstance(d, str)]
    remove_set = set(remove)
    kept = [d for d in domains if d not in remove_set]
    added = []
    existing_normalized = {_sp_normalize_host(d) for d in kept}
    for h in add:
        if _sp_normalize_host(h) not in existing_normalized:
            kept.append(h)
            existing_normalized.add(_sp_normalize_host(h))
            added.append(h)
    removed = [d for d in domains if d in remove_set]
    return kept, added, removed


def _sp_apply_webfetch(allow_list, prune):
    prune_set = set(prune)
    kept = [s for s in allow_list if not (isinstance(s, str) and s in prune_set)]
    pruned = [s for s in allow_list if isinstance(s, str) and s in prune_set]
    return kept, pruned


def _sp_mutate_scope(data, add, remove, wf_prune, set_fail_if_unavailable):
    """Shared mutation for both the project target and (add=[] always) the
    local target. Touches ONLY sandbox.network.allowedDomains,
    sandbox.failIfUnavailable, and permissions.allow -- nothing else."""
    sandbox = data.get("sandbox")
    if sandbox is not None and not isinstance(sandbox, dict):
        raise IOErrorSanitized("'sandbox' exists but is not an object")
    sandbox = dict(sandbox) if isinstance(sandbox, dict) else {}
    network = sandbox.get("network")
    if network is not None and not isinstance(network, dict):
        raise IOErrorSanitized("'sandbox.network' exists but is not an object")
    network = dict(network) if isinstance(network, dict) else {}

    new_domains, added, removed = _sp_apply_domains(network, add, remove)
    network["allowedDomains"] = new_domains
    sandbox["network"] = network
    if set_fail_if_unavailable is True:
        sandbox["failIfUnavailable"] = True
    data["sandbox"] = sandbox

    perms = data.get("permissions")
    perms = dict(perms) if isinstance(perms, dict) else {}
    allow = [s for s in perms.get("allow", []) if isinstance(s, str)]
    new_allow, wf_pruned = _sp_apply_webfetch(allow, wf_prune)
    if allow:
        perms["allow"] = new_allow
        data["permissions"] = perms

    return {"added": added, "removed": removed, "webfetch_pruned": wf_pruned}


def apply_sandbox_policy(target, local_target, sidecar_path, receipt_path, vendor_hosts_path):
    plan = _read_plan_stdin()
    if not isinstance(plan, dict):
        raise IOErrorSanitized("plan on stdin is not a JSON object")

    vendor_records = _sp_load_vendor_records(vendor_hosts_path)
    universe = {r["host"] for r in vendor_records}
    _sp_verify_plan(plan, universe)

    write_settings = bool(plan.get("_write_settings"))
    project = plan.get("project") if isinstance(plan.get("project"), dict) else {}
    local = plan.get("local") if isinstance(plan.get("local"), dict) else {}
    wf = plan.get("webfetch_prune") if isinstance(plan.get("webfetch_prune"), dict) else {}
    p_add = [s for s in project.get("add", []) if isinstance(s, str)]
    p_remove = [s for s in project.get("remove", []) if isinstance(s, str)]
    l_remove = [s for s in local.get("remove", []) if isinstance(s, str)]
    p_wf = [s for s in wf.get("project", []) if isinstance(s, str)]
    l_wf = [s for s in wf.get("local", []) if isinstance(s, str)]
    fail_if_unavailable = plan.get("fail_if_unavailable") is True

    result = {"project": None, "local": None}

    def mutate_project(data):
        if not write_settings:
            result["project"] = {"added": [], "removed": [], "webfetch_pruned": []}
            return data
        # Security-audit HIGH fix (H1/H2): re-derive level + clearance FRESH,
        # under the lock, rather than trusting the plan's own claims (which
        # were computed by the bash/python compiler BEFORE this lock was
        # acquired -- the only part of a compile that WAS serialized before
        # this fix was the final write). A plan that wants to add a host not
        # currently allowed, or remove a host that IS currently allowed, is
        # stale -- refuse rather than apply it; the caller (a hook) simply
        # recompiles on its next invocation.
        current_level = _sp_resolve_current_level(plan.get("repo"))
        current_allowed = _sp_policy_for_level(current_level, vendor_records)
        stale_add = [h for h in p_add if h not in current_allowed]
        # Exact-membership only (not glob-containment): current_allowed holds
        # plain hostnames, so a glob entry like "*.openai.com" being removed
        # never spuriously matches here -- only a literal governed host that
        # fresh policy says is CURRENTLY allowed counts as stale.
        stale_remove = [h for h in (p_remove + l_remove) if _sp_normalize_host(h) in current_allowed]
        if stale_add or stale_remove:
            raise Refused(
                "plan is stale relative to the current stack-config.json (re-derived "
                f"level={current_level!r}); would add not-currently-allowed host(s) "
                f"{stale_add}, or remove currently-allowed host(s) {stale_remove} -- "
                "refusing; the caller must recompile"
            )
        result["project"] = _sp_mutate_scope(data, p_add, p_remove, p_wf, fail_if_unavailable)
        return data

    def compute_local():
        if not write_settings or not local_target:
            return (None, None)
        if not (l_remove or l_wf):
            return (None, None)  # nothing to change -- never create/rewrite the file for a no-op
        local_data = load_json_object(local_target, "local settings")
        result["local"] = _sp_mutate_scope(local_data, [], l_remove, l_wf, False)
        return (local_target, local_data)

    def compute_sidecar():
        if not sidecar_path:
            return (None, None)
        old = load_json_object(sidecar_path, "sidecar")
        new_sidecar = dict(old)
        sp_old = old.get("sandbox_policy") if isinstance(old.get("sandbox_policy"), dict) else {}
        ledger = dict(sp_old.get("ledger", {})) if isinstance(sp_old.get("ledger"), dict) else {}
        stashed = list(sp_old.get("stashed_entries", [])) if isinstance(sp_old.get("stashed_entries"), list) else []

        today = _today()
        # Adopt-before-claim (ADR-044 D8 steps 1-2, replicated per ADR-071 D14):
        # every currently-live governed value with no ledger entry is human-owned.
        for scope_name, entries in (("project", plan.get("_live_governed_project", [])),
                                     ("local", plan.get("_live_governed_local", []))):
            for v in entries:
                if isinstance(v, str) and v not in ledger:
                    ledger[v] = {"owner": "human", "first_seen": today}
        # Claim: every host WE add this round with no ledger entry is stack-owned.
        if write_settings:
            for v in p_add:
                if v not in ledger:
                    ledger[v] = {"owner": "stack", "first_seen": today}

        new_stash_entries = []
        if write_settings:
            level = plan.get("level")
            for scope_name, removed_vals in (("project", (result["project"] or {}).get("removed", [])),
                                              ("local", (result["local"] or {}).get("removed", []))):
                for v in removed_vals:
                    owner = ledger.get(v, {}).get("owner", "unknown")
                    entry = {"value": v, "scope": scope_name, "owner": owner,
                              "stashed_on": today, "level": level,
                              "reason": "not cleared at this sensitivity level"}
                    stashed.append(entry)
                    new_stash_entries.append(entry)
            # ADR-071 WF7: a WebFetch(domain:H) allow-rule prune is also a
            # removal from live config and gets its own stash record, keyed
            # on the extracted host (not the full rule string) so it shares
            # the ledger with an allowedDomains entry for the same host.
            for scope_name, pruned_rules in (("project", (result["project"] or {}).get("webfetch_pruned", [])),
                                              ("local", (result["local"] or {}).get("webfetch_pruned", []))):
                for rule in pruned_rules:
                    m = WEBFETCH_RE.match(rule)
                    host = m.group(1) if m else rule
                    owner = ledger.get(host, {}).get("owner", "unknown")
                    entry = {"value": host, "scope": scope_name, "owner": owner,
                              "stashed_on": today, "level": level,
                              "reason": "WebFetch(domain:...) allow rule pruned (not cleared at this sensitivity level)"}
                    stashed.append(entry)
                    new_stash_entries.append(entry)

        new_sidecar["sandbox_policy"] = {"stashed_entries": stashed, "ledger": ledger}
        result["new_stashes"] = new_stash_entries
        return (sidecar_path, new_sidecar)

    def compute_receipt():
        if not receipt_path:
            return (None, None)
        receipt = dict(plan)
        receipt.pop("_write_settings", None)
        receipt.pop("_live_governed_project", None)
        receipt.pop("_live_governed_local", None)
        receipt["compiled_at"] = _today()
        # ADR-071 §8: "Fields = plan JSON + {compiled_at, effective_this_session,
        # stack_config_mtime}" -- both were missing (validator HIGH finding).
        #
        # effective_this_session: this compile is guaranteed live for the
        # CURRENT process only when it ran from SessionStart -- a
        # PostToolUse recompile (hooks/sandbox-policy-recompile.sh) writes
        # settings.json for the NEXT session, since whether an already-running
        # process picks up a mid-session settings.json change at all is the
        # open question ADR-071 D9/L6 has not settled. CLAUDE_HOOK_EVENT is
        # set by whichever hook invoked the compiler (the bash wrapper
        # already refuses to run without it), and is inherited unchanged by
        # this subprocess.
        receipt["effective_this_session"] = os.environ.get("CLAUDE_HOOK_EVENT") == "SessionStart"
        # stack_config_mtime: the mtime of THIS repo's .claude/stack-config.json
        # at the moment of this compile, so a reader of the receipt alone
        # (without filesystem access to compare timestamps, e.g. a copy
        # attached to a bug report) can independently judge staleness -- the
        # same fact cross-family-preflight.sh's cfp_vendor_policy checks by
        # comparing file mtimes directly (R6), now also self-described here.
        repo = plan.get("repo")
        stack_config_mtime = None
        if isinstance(repo, str):
            cfg_path = os.path.join(repo, ".claude", "stack-config.json")
            try:
                mtime = os.path.getmtime(cfg_path)
                stack_config_mtime = datetime.utcfromtimestamp(mtime).strftime("%Y-%m-%dT%H:%M:%SZ")
            except OSError:
                pass
        receipt["stack_config_mtime"] = stack_config_mtime
        return (receipt_path, receipt)

    extra_writes = (compute_local, compute_sidecar)
    # W5 / D8: CLOUD_HOOK_ONLY and DISABLED must not write settings.json at
    # all (not even a byte-identical rewrite) -- the sidecar/local writes
    # still land inside the same lock via extra_writes. The receipt is a
    # post_target_write (red-team MEDIUM fix): it must never claim a
    # tightened policy the governing settings.json write has not actually
    # completed yet -- see locked_update's own comment for the rationale.
    locked_update(target, mutate_project, extra_writes=extra_writes,
                  write_target=write_settings, post_target_writes=(compute_receipt,))

    counts = {
        "added": len((result["project"] or {}).get("added", [])),
        "removed": len((result["project"] or {}).get("removed", [])) + len((result["local"] or {}).get("removed", [])),
        "webfetch_pruned": len((result["project"] or {}).get("webfetch_pruned", [])) + len((result["local"] or {}).get("webfetch_pruned", [])),
        "stashed": len(result.get("new_stashes", [])),
    }
    print(json.dumps({"changed": write_settings, "counts": counts,
                       "new_stashes": result.get("new_stashes", [])}))


# --- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="settings_lock")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apply-permissions-plan", action="store_true")
    mode.add_argument("--apply-sandbox-policy", action="store_true")
    p.add_argument("--target", required=True)
    p.add_argument("--sidecar", default=None)
    p.add_argument("--local-target", default=None)
    p.add_argument("--receipt", default=None)
    p.add_argument("--vendor-hosts", default=None)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.apply_sandbox_policy:
            vendor_hosts_path = args.vendor_hosts or os.path.join(
                _claude_home(), ".claude", "config", "vendor-hosts.json")
            apply_sandbox_policy(args.target, args.local_target, args.sidecar,
                                  args.receipt, vendor_hosts_path)
        else:
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
