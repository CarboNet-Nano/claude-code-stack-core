#!/usr/bin/env bash
# scripts/permissions-compile.sh — ADR-044 Contract C. Deterministic,
# non-LLM compiler for Claude Code's native permissions.deny / permissions.ask.
#
# Builds a PLAN (steps 1-7 below) from config/permissions-baseline.json plus
# existing signals (stack-config.json, the live-capability snapshot, the
# project sidecar's waivers[]) and hands it to scripts/lib/settings_lock.py
# (Contract C.1) — the ONLY code path that opens the settings lock and
# writes settings.json / the sidecar. This script NEVER writes those files
# itself.
#
# Usage:
#   permissions-compile.sh --scope project --repo-root <path> [--dry-run] [--json]
#   permissions-compile.sh --scope user [--prune-user] [--dry-run]
#
# Exit codes (native-settings-edit convention):
#   0  applied, or a dry-run / diff-only preview (nothing written)
#   2  refused (validation, cloud gate, missing stack-config) — one-line reason
#   3  I/O / parse error (sanitized — never echoes file contents)
#
# summary: Compiles config/permissions-baseline.json into permissions.deny/ask (ADR-044).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper resolution (both layouts) — scripts/ and scripts/lib/ are always
# siblings, but fall back to the installed layout defensively rather than
# assume, per the ADR's "do not guess; do not rely on CWD" instruction.
LIB_PY="$SCRIPT_DIR/lib/settings_lock.py"
[[ -f "$LIB_PY" ]] || LIB_PY="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib/settings_lock.py"

SCOPE=""
REPO_ROOT=""
DRY_RUN=0
JSON_OUT=0
PRUNE_USER=0
FROM_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --prune-user) PRUNE_USER=1; shift ;;
    --from-install) FROM_INSTALL=1; shift ;;
    *) echo "refused: unknown argument $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 3; }
[[ -f "$LIB_PY" ]] || {
  echo "error: could not resolve scripts/lib/settings_lock.py (repo or installed layout)" >&2
  exit 3
}

[[ "$SCOPE" == "project" || "$SCOPE" == "user" ]] || {
  echo "refused: --scope must be 'project' or 'user'" >&2
  exit 2
}

# Contract C hard refusal: "--scope user without the template/install path."
# No convention currently exists in this repo for an install/update script to
# signal "this is the install path," so a new explicit flag is the mechanism:
# only scripts/install.sh / scripts/update.sh may pass --from-install. This
# is the same rule for --dry-run as for a real write -- there is no wired
# caller today that needs a --scope user preview, so requiring the flag
# unconditionally cannot regress anything currently working.
if [[ "$SCOPE" == "user" && "$FROM_INSTALL" -ne 1 ]]; then
  echo "refused: --scope user may only run from the install/update path (pass --from-install; not intended for ad-hoc or agent-driven invocation)" >&2
  exit 2
fi

# --- cloud gate (ADR-018 H4 multi-factor detector, replicated) --------------
# Reads/dry-runs are allowed in a cloud session; writes are not — same rule
# as native-settings-edit.
is_cloud_session() {
  [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] && return 0
  local v val
  for v in CLAUDE_CODE_CLOUD CLAUDE_CLOUD CODESPACES CLOUD_SHELL; do
    val="${!v:-}"
    case "$val" in [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) return 0 ;; esac
  done
  [[ -f "/tmp/.claude-stack-cloud-bootstrap.done" ]] && return 0
  return 1
}
if [[ "$DRY_RUN" -eq 0 ]] && is_cloud_session; then
  echo "refused: writes are disabled in the cloud environment (read-only). Use --dry-run to preview." >&2
  exit 2
fi

if [[ "$SCOPE" == "project" ]]; then
  [[ -n "$REPO_ROOT" ]] || { echo "refused: --repo-root is required for --scope project" >&2; exit 2; }
  CFG="$REPO_ROOT/.claude/stack-config.json"
  [[ -f "$CFG" ]] || {
    echo "refused: no .claude/stack-config.json at $REPO_ROOT (run /project-init first)" >&2
    exit 2
  }
  # Canonicalize so a relative --repo-root (e.g. the documented "." used by
  # every current caller: /project-init, /domain-mode, /sensitivity) resolves
  # to the same absolute path settings_lock.py's own realpath canonicalization
  # derives its lock from -- lock-path identity must not depend on CWD
  # consistency across processes.
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
  CFG="$REPO_ROOT/.claude/stack-config.json"
else
  CFG=""
fi

# --- resolve the baseline (installed, then repo-relative fallback) ---------
BASELINE="$HOME/.claude/config/permissions-baseline.json"
[[ -f "$BASELINE" ]] || BASELINE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/config/permissions-baseline.json"
[[ -f "$BASELINE" ]] || {
  echo "error: could not find config/permissions-baseline.json" >&2
  exit 3
}

SNAPSHOT="$HOME/.claude/session-state/live-capabilities.json"

SIDECAR=""
[[ "$SCOPE" == "project" ]] && SIDECAR="$REPO_ROOT/.claude/permissions.stack.json"

# --- Steps 1-7: build the plan (read-only; nothing is written here) --------
#
# Step 4's `+ domain_overlays[cfg.domain_mode]` is written generically in
# Contract C, but MCQ 2 (ADR-044, "Resolved questions") requires
# apply_migration/execute_sql/deploy_edge_function to be denied EVERYWHERE
# BY DEFAULT, independent of `required_approvals` — and the ADR's own escape
# list ("set domain_mode to schema-migration... the hook resumes
# payload-conditional gating") only works if the static deny for those tools
# is ABSENT under that domain_mode, not re-added by the overlay. A plain
# additive union of domain_overlays[...].mcp_tool_denies on top of an
# unconditional pre-schema-change/pre-deploy default can never satisfy both
# requirements at once (verified against T2's three assertions). The reading
# implemented below — domain_overlays[*].mcp_tool_denies SUPPRESSES matching
# tool names out of the MCQ-2 *default* emission, rather than adding to it —
# is the only one under which T2 holds. bash_guardrails and mcp_server_denies
# on a domain overlay remain purely additive.
#
# Confirmed-fixed bug (post-review): the suppression above must apply ONLY to
# the implicit MCQ-2 default, never to a gate the human explicitly requested
# via `required_approvals`. D4 says "every `required_approvals` entry ...
# becomes a deny" -- unconditionally. Before the fix, `domain_mode: "deploy"`
# + `required_approvals: ["pre-deploy"]` silently suppressed
# `deploy_edge_function`'s deny entirely, because the suppression check did
# not distinguish "default" from "explicitly requested." The two sources are
# now separated: a gate name present in `required_approvals` is expanded with
# no suppression at all (it is unconditional and non-negotiable); a gate name
# NOT in `required_approvals` still gets only the MCQ-2 default, which the
# active domain overlay may suppress (the documented escape hatch). Ordered
# consequence: `domain_mode: "schema-migration"` + explicit
# `required_approvals: ["pre-schema-change"]` now denies `execute_sql` even
# though the overlay would otherwise have owned it -- explicit human intent
# always wins over the domain-mode escape hatch.
# Do NOT use apostrophes (contractions, possessives) anywhere in the heredoc
# below. It is nested inside $(...); an ODD total count of ' characters in
# the body breaks bash's parse of THIS WHOLE SCRIPT (not just the heredoc),
# with a confusing error reported at an unrelated line number. Verify any
# edit here with: bash -n scripts/permissions-compile.sh
PLAN_JSON="$(python3 - "$BASELINE" "$CFG" "$SNAPSHOT" "$SCOPE" "$PRUNE_USER" "$SIDECAR" <<'PYEOF'
import hashlib
import json
import re
import sys

def fail(msg, code):
    print(msg, file=sys.stderr)
    sys.exit(code)

def load_json(path, what):
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        fail(f"error: could not read or parse {what} at {path}", 3)


def load_sidecar(path, warn):
    """ADR-053 D6-revised / round 8. The sidecar OWN loader -- distinct from
    load_json() on purpose, and used at exactly ONE call site (the sidecar
    read in main()). load_json() maps OSError/ValueError (including a JSON syntax error)
    to fail(..., 3), which is correct for the baseline, stack-config.json and
    the live-capabilities snapshot, and WRONG for the one file this ADR
    invites humans to hand-edit. Returning None here is fail-safe in both
    directions that matter: no acks -> every suppression is withheld; no
    waivers -> every waived rule returns. Both are the STRONGER boundary.
    Never widen this function tolerance to another call site, and never
    reuse it for a file whose absence or unreadability would WEAKEN the plan.

    The warning deliberately foreshadows the apply-side refusal
    (settings_lock.py:493, reached from inside mutate() and therefore costing
    the settings.json write too). Exit 0 here is NOT a promise that the next
    apply will succeed -- the three writer skills close that gap positionally
    at their own P0 preflight; a bare CLI caller has only this sentence."""
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        warn(f"permissions.stack.json is not valid JSON or is unreadable "
             f"({type(e).__name__}); all consent records and waivers ignored "
             f"for this compile -- this is a REPORT-ONLY degradation: a real "
             f"apply will REFUSE, and will write neither settings.json nor the "
             f"sidecar, until this file is fixed or removed")
        return None


# ADR-053 D6-revised. The only gates that own suppressible tools. This SAME
# constant builds UNCONDITIONAL_TOOLS, clause-1 `explicit` set, AND
# consent_scope `gates` field -- one constant in all three call sites is
# what makes the consent preimage provably complete (T-41).
GATE_OWNERS = ("pre-schema-change", "pre-deploy")

ALLOWED_TOP = {
    "$schema", "version", "file_tools", "floor", "domain_overlays",
    "sensitivity_overlays", "approval_gate_map", "retired_rules",
}
ALLOWED_CLASSES = {"identity", "path", "bash"}
WILDCARD_RE = re.compile(r"mcp__[^_]*__\*")


def _validate_rule_item(item, require_rule=False, require_path=False, where=""):
    if not isinstance(item, dict):
        fail(f"error: {where} rule entry must be an object", 3)
    if require_rule:
        rule = item.get("rule")
        if not isinstance(rule, str):
            fail(f"error: {where} rule entry missing string 'rule'", 3)
        if WILDCARD_RE.search(rule):
            fail(f"error: rule '{rule}' uses a wildcard MCP specifier, which the harness does not support", 3)
    if require_path and not isinstance(item.get("path"), str):
        fail(f"error: {where} path_rules entry missing string 'path'", 3)
    cls = item.get("class")
    if cls not in ALLOWED_CLASSES:
        fail(f"error: {where} rule entry has unknown class '{cls}' (must be identity|path|bash)", 3)
    if not isinstance(item.get("why"), str):
        fail(f"error: {where} rule entry missing string 'why'", 3)


def _validate_str_list(val, where):
    if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
        fail(f"error: {where} must be an array of strings", 3)


def _validate_overlay(overlay, where, allow_mcp_server=True):
    if not isinstance(overlay, dict):
        fail(f"error: {where} must be an object", 3)
    keys = ["mcp_tool_denies", "bash_guardrails"]
    if allow_mcp_server:
        keys.append("mcp_server_denies")
    for key in keys:
        if key in overlay:
            _validate_str_list(overlay[key], f"{where}.{key}")


def validate_baseline(b):
    if not isinstance(b, dict):
        fail("error: baseline is not a JSON object", 3)
    extra = set(b.keys()) - ALLOWED_TOP
    if extra:
        fail(f"error: baseline has unknown top-level key(s): {sorted(extra)}", 3)
    if "allow" in b:
        fail("error: baseline must not define an 'allow' key (D5 — the stack emits no allow rules)", 3)
    if "file_tools" in b:
        _validate_str_list(b["file_tools"], "file_tools")
    floor = b.get("floor", {})
    if not isinstance(floor, dict):
        fail("error: floor must be an object", 3)
    for item in floor.get("deny", []):
        _validate_rule_item(item, require_rule=True, where="floor.deny")
    for item in floor.get("path_rules", []):
        _validate_rule_item(item, require_path=True, where="floor.path_rules")
    for name, overlay in b.get("domain_overlays", {}).items():
        _validate_overlay(overlay, f"domain_overlays.{name}")
    for name, overlay in b.get("sensitivity_overlays", {}).items():
        if not isinstance(overlay, dict):
            fail(f"error: sensitivity_overlays.{name} must be an object", 3)
        for item in overlay.get("deny", []):
            _validate_rule_item(item, require_rule=True, where=f"sensitivity_overlays.{name}.deny")
        if "mcp_server_denies" in overlay:
            _validate_str_list(overlay["mcp_server_denies"], f"sensitivity_overlays.{name}.mcp_server_denies")
    for name, gate in b.get("approval_gate_map", {}).items():
        _validate_overlay(gate, f"approval_gate_map.{name}", allow_mcp_server=False)
    if "retired_rules" in b:
        _validate_str_list(b["retired_rules"], "retired_rules")


def active_modes(cfg):
    """ADR-053 D7. Inline twin of lib/domain-modes.sh dm_active_modes.
    Duplicated deliberately: this runs inside a python heredoc and cannot
    source bash. Callers must run this only after validate_domain_mode has
    already refused a malformed shape."""
    v = cfg.get("domain_mode")
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    if isinstance(v, list):
        return v
    raise TypeError


def validate_domain_mode(cfg, known_modes):
    """ADR-053. Exit 3 on every malformed shape; never a traceback, never a
    silently weaker rule set. Mirrors the scalar precedent this replaces
    (test-permissions-boundary.sh:606)."""
    v = cfg.get("domain_mode")
    if v is None:
        return
    if isinstance(v, str):
        modes = [v]
    elif isinstance(v, list):
        if not v:
            fail("refused: domain_mode must not be an empty array", 3)
        if not all(isinstance(x, str) for x in v):
            fail("refused: every domain_mode element must be a string", 3)
        if len(set(v)) != len(v):
            fail("refused: domain_mode contains duplicate entries", 3)
        modes = v
    else:
        fail("refused: domain_mode must be a string, an array of strings, or null", 3)
    bad = sorted(x for x in modes if x not in known_modes)
    if bad:
        fail(f"refused: unknown domain_mode value(s): {bad}", 3)


def validate_domain_mode_paths(cfg, known_modes, warn):
    """ADR-053. Returns (ignored, malformed) -- the sorted key lists that
    become inputs.domain_mode_paths_ignored and
    inputs.domain_mode_paths_malformed. Must run AFTER validate_domain_mode,
    so active_modes(cfg) is safe here.

    Fatal vs drift is the D6-revised rule, applied and not re-litigated: exit
    3 only when the state is unreachable by an ordinary, documented workflow
    AND tolerating it could leave the grant wider than the config plain
    reading."""
    if "domain_mode_paths" not in cfg:
        return [], []
    dmp = cfg["domain_mode_paths"]
    if dmp is None:              # absent and null are made equivalent by
        return [], []            # THESE two branches, not by the parser.
    if not isinstance(dmp, dict):
        # Ignoring the whole block unscopes EVERY mode at once and hands back
        # EVERY suppression -- prong (ii) satisfied -- and no workflow produces it.
        fail("refused: domain_mode_paths must be an object", 3)

    declared = set(active_modes(cfg))
    ignored, malformed = [], []
    for k in sorted(dmp):
        if k not in known_modes:
            # Typo-d key ("schema_migration"): the REAL mode is then unmapped,
            # passes clause 2 and recovers its repo-wide grant. Widens -> fatal.
            fail(f"refused: domain_mode_paths key '{k}' is not a known domain mode", 3)
        v = dmp[k]
        if not (isinstance(v, list) and v and all(isinstance(g, str) for g in v)):
            # Gap A. DRIFT, and the KEY IS RETAINED. Deleting the key would
            # unscope the mode -> clause 2 passes -> grant recovered, which is
            # this ADR own CRITICAL 2. No per-element salvage: ["a", 42] is
            # malformed as a whole.
            malformed.append(k)
            warn(f"domain_mode_paths['{k}'] is not a non-empty array of strings; "
                 f"globs ignored -- '{k}' is treated as always-active for routing "
                 f"and stays scope-incoherent for permissions")
        if k not in declared:
            # Orphan: ordinary mode removal produces it, and the honor test
            # reads keys only for ACTIVE modes, so it is unreachable dead config.
            ignored.append(k)
            warn(f"domain_mode_paths key '{k}' names a mode not declared in "
                 f"domain_mode; ignored (dead config)")
    return ignored, malformed


def consent_scope(cfg, active):
    """ADR-053 D6-revised. The hash preimage -- exactly the stack-config.json
    surface the honor test reads, and nothing else (T-41)."""
    paths = cfg.get("domain_mode_paths") or {}
    return {"v": 1,
            "modes":  sorted(set(active)),
            "scoped": sorted(set(paths.keys()) & set(active)),
            "gates":  sorted(set(cfg.get("required_approvals") or [])
                             & set(GATE_OWNERS))}


def consent_scope_hash(scope):
    blob = json.dumps(scope, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "sha256:" + hashlib.sha256(blob).hexdigest()


def read_acks(sidecar, ctx, warn):
    """ADR-053 D6-revised. Sidecar is human-editable and schema-less: NOTHING
    here is fatal. Ignoring an ack can only strengthen the boundary. This is
    the SHAPE layer only -- it never sees a parse failure, because
    load_sidecar() has already absorbed one and handed this function None.
    ctx = {"known_modes", "active", "suppresses", "want_hash"}, where
    suppresses[m] = set(overlays[m].mcp_tool_denies) & UNCONDITIONAL_TOOLS.

    Returns THREE values: (fresh, stale, inert).

    CONTAINMENT INVARIANT (read this before classify_suppressions). fresh and
    stale are sets of (mode, tool) and together cover every pair any
    well-formed entry claims. `inert` is NOT a third bucket and is NOT a
    membership source: it is a REASON ANNOTATION over a subset of those same
    pairs. Every dict appended to `inert` names a pair that the UNCONDITIONAL
    `target.add((m, t))` on the immediately preceding line already put in
    fresh or stale:

        {(p["mode"], p["tool"]) for p in inert}  subset-of  fresh | stale

    inert supplies `why` to prune_reason. It never supplies membership to
    classify_suppressions `claimed`, which already contains every inert pair
    via fresh|stale. The target.add()-before-annotate ordering below is
    LOAD-BEARING -- never move the inert appends above it, and never make the
    add conditional on the pair being non-inert: either edit turns `inert`
    into a real third bucket, and an ack whose mode goes undeclared becomes
    permanently unprunable by every writer skill (silent reactivation)."""
    # isinstance, NOT `sidecar or {}`. A truthy non-dict root (a bare list,
    # string or number at the top of a hand-edited file) is truthy and has no
    # .get -- the `or {}` form raises AttributeError there, fatal, in the one
    # file this ADR guarantees is never fatal.
    if not isinstance(sidecar, dict):
        if sidecar is not None:
            warn("permissions.stack.json root is not an object; all consent "
                 "records ignored")
        return set(), set(), []
    raw = sidecar.get("multi_mode_suppression_ack")
    if raw is None:
        return set(), set(), []
    if not isinstance(raw, list):
        warn("multi_mode_suppression_ack is not an array; all consent records ignored")
        return set(), set(), []

    fresh, stale, inert = set(), set(), []
    for i, a in enumerate(raw):
        if (not isinstance(a, dict)
                or not isinstance(a.get("mode"), str) or a["mode"] not in ctx["known_modes"]
                or not isinstance(a.get("tools"), list) or not a["tools"]
                or not all(isinstance(t, str) and t for t in a["tools"])):
            warn(f"multi_mode_suppression_ack[{i}] is malformed; ignored")
            continue
        m = a["mode"]
        target = fresh if a.get("scope_hash") == ctx["want_hash"] else stale
        for t in a["tools"]:
            target.add((m, t))
            if m not in ctx["active"]:
                inert.append({"mode": m, "tool": t, "why": "undeclared-mode"})
            elif t not in ctx["suppresses"].get(m, set()):
                inert.append({"mode": m, "tool": t, "why": "not-suppressed"})
        if m not in ctx["active"]:
            warn(f"multi_mode_suppression_ack[{i}] names mode '{m}', which is not "
                 f"declared in domain_mode; inert (no effect on this compile)")
        else:
            for t in a["tools"]:
                if t not in ctx["suppresses"].get(m, set()):
                    warn(f"multi_mode_suppression_ack[{i}] names tool '{t}', which "
                         f"'{m}' does not suppress; inert (no effect on this compile)")
        if target is stale:
            why = "no scope_hash" if not isinstance(a.get("scope_hash"), str) else "scope_hash mismatch"
            warn(f"multi_mode_suppression_ack[{i}] ('{m}') was recorded for a "
                 f"different configuration ({why}); ignored. Re-run /domain-mode to "
                 f"re-affirm. current scope_hash: {ctx['want_hash']}")
    return fresh, stale, inert


FIX = {
    "explicit-gate":   "remove the owning gate from required_approvals to make this suppressible",
    "scope-coherence": 'delete domain_mode_paths["<mode>"] to make the chain unconditional',
    "consent":         "run /domain-mode and answer y, or add a multi_mode_suppression_ack entry with the current scope_hash",
    "consent-stale":   "re-run /domain-mode to re-affirm this configuration",
}
# Deterministic reporting order for the failing clause. consent-stale
# outranks consent because it names a record the human can actually see and fix.
CLAUSE_RANK = {"consent-stale": 0, "consent": 1, "scope-coherence": 2}


def rules_for_tool(t, servers):
    """The SAME expression expand_overlay uses, factored so the report can
    never disagree with the plan. Empty when the live-capabilities snapshot
    is missing -- in which case no deny rule is emitted for `t` at all and
    the withheld warning must say so instead of promising a deny."""
    return [] if servers is None else sorted(f"mcp__{srv}__{t}" for srv in servers)


PRUNE_RANK = ("undeclared-mode", "not-suppressed", "explicit-gate",
              "scope-coherence", "single-mode", "superseded")


def prune_reason(pair, ctx):
    """Exactly ONE reason per pair, by fixed precedence (PRUNE_RANK), so a
    pair qualifying under several shapes is reported deterministically."""
    m, t = pair
    if pair in ctx["inert_why"]:
        return ctx["inert_why"][pair]   # undeclared-mode | not-suppressed
    if t in ctx["explicit"]:
        return "explicit-gate"
    if m in ctx["scoped"]:
        return "scope-coherence"
    if not ctx["multi"]:
        return "single-mode"
    return "superseded"


def classify_suppressions(cfg, baseline, active, acks, gates_ctx):
    """ADR-053 D6-revised. Returns ONE dict: {honored, suppressions_honored,
    suppressions_withheld, acks_in_force, acks_prunable}. acks = (fresh,
    stale, inert) from read_acks. gates_ctx = {"required_approvals",
    "unconditional_tools", "servers"}. Reads domain_mode_paths KEYS only --
    no glob is ever evaluated here, and a malformed VALUE does not remove its
    key. Only gate-owned tools are suppressions; every other mcp_tool_denies
    entry is an ADDITIVE deny and must never be classified."""
    fresh, stale, inert = acks
    overlays = baseline.get("domain_overlays", {})
    gate_map = baseline.get("approval_gate_map", {})
    servers  = gates_ctx["servers"]
    scoped   = set((cfg.get("domain_mode_paths") or {}).keys()) & set(active)
    multi    = len(active) >= 2

    explicit = set()
    for g in gates_ctx["required_approvals"]:
        if g in GATE_OWNERS:
            explicit |= set(gate_map.get(g, {}).get("mcp_tool_denies", []))

    per_tool = {}   # tool -> {"by": [modes], "fail": [(mode, clause)]}
    for m in active:
        for t in overlays.get(m, {}).get("mcp_tool_denies", []):
            if t not in gates_ctx["unconditional_tools"]:   # additive deny, not a suppression
                continue
            e = per_tool.setdefault(t, {"by": [], "fail": []})
            if   m in scoped:            e["fail"].append((m, "scope-coherence"))
            elif not multi:              e["by"].append(m)
            elif (m, t) in fresh:        e["by"].append(m)
            elif (m, t) in stale:        e["fail"].append((m, "consent-stale"))
            else:                        e["fail"].append((m, "consent"))

    # The prune set is a REMAINDER, not an accumulation. `claimed` is TOTAL
    # over acknowledged pairs, INCLUDING inert ones (read_acks adds every
    # pair to fresh/stale unconditionally and only then annotates some as
    # inert -- see its CONTAINMENT INVARIANT).
    claimed = fresh | stale
    inert_why = {}
    for p in inert:
        inert_why.setdefault((p["mode"], p["tool"]), p["why"])

    honored_tools = set()
    honored, withheld, in_force = [], [], []

    for t in sorted(per_tool):
        e = per_tool[t]
        if t in explicit:              # clause 1 wins outright, even over a
                                        # populated e["by"]. No prompt is EVER
                                        # offered for a clause-1 pair, which is
                                        # what puts its acks in the prune set.
            withheld.append({"tool": t, "clause": "explicit-gate", "mode": None,
                             "modes": sorted({m for m in e["by"]} | {m for m, _ in e["fail"]}),
                             "deny_rules": rules_for_tool(t, servers),
                             "fix": FIX["explicit-gate"]})
            continue
        if e["by"]:
            honored_tools.add(t)
            honored.append({"tool": t,
                            "by": sorted(e["by"]),      # sorted: unsorted makes
                                                         # sidecar bytes a function
                                                         # of domain_mode order
                            "deny_rules_removed": rules_for_tool(t, servers)})
            # acks_in_force is computed HERE -- at the point the tool is
            # actually honored -- and never inside the per-mode loop above.
            if multi:
                in_force += [{"mode": m, "tool": t}
                             for m in sorted(e["by"]) if (m, t) in fresh]
            continue
        pick = min(e["fail"], key=lambda f: (CLAUSE_RANK[f[1]], f[0]))
        withheld.append({"tool": t, "clause": pick[1], "mode": pick[0],
                         "modes": sorted({m for m, _ in e["fail"]}),
                         "deny_rules": rules_for_tool(t, servers),
                         "fix": FIX[pick[1]]})

    promptable = {(w["mode"], w["tool"]) for w in withheld
                  if w["clause"] in ("consent", "consent-stale")}

    pctx = {"inert_why": inert_why, "explicit": explicit,
            "scoped": scoped, "multi": multi}
    dead = claimed - {(p["mode"], p["tool"]) for p in in_force} - promptable
    prunable = [{"mode": m, "tool": t, "why": prune_reason((m, t), pctx)}
                for (m, t) in sorted(dead, key=lambda p: (p[1], p[0]))]

    pair_key = lambda p: (p["tool"], p["mode"])
    return {"honored":               honored_tools,
            "suppressions_honored":  honored,     # already sorted by tool
            "suppressions_withheld": withheld,    # already sorted by tool
            "acks_in_force":         sorted(in_force, key=pair_key),
            "acks_prunable":         prunable}    # already sorted by (tool, mode)


def validate_cfg(cfg, baseline):
    """Defensive type + value validation of the stack-config.json fields this
    compiler consumes. Malformed shape (e.g. `sensitivity` as a bare string
    instead of an object) previously caused an unhandled AttributeError
    traceback at exit 1; unknown values silently produced a WEAKER rule set
    at exit 0. Both are refused here with a sanitized message at exit 3 --
    never a traceback, never a silent weaker-ruleset success. domain_mode /
    domain_mode_paths shape checks live in validate_domain_mode /
    validate_domain_mode_paths (ADR-053 round 5) -- called separately by
    main(), in that order, once known_modes is built."""
    if not isinstance(cfg, dict):
        fail("error: stack-config.json is not a JSON object", 3)

    sensitivity = cfg.get("sensitivity")
    if sensitivity is not None and not isinstance(sensitivity, dict):
        fail("error: stack-config.json 'sensitivity' must be an object or null", 3)
    if isinstance(sensitivity, dict):
        level = sensitivity.get("level")
        if level is not None and not isinstance(level, str):
            fail("error: stack-config.json 'sensitivity.level' must be a string or null", 3)
        known_levels = set(baseline.get("sensitivity_overlays", {}).keys())
        if level is not None and level not in known_levels:
            fail(f"error: stack-config.json 'sensitivity.level' value '{level}' is not a known level ({sorted(known_levels)})", 3)

    required_approvals = cfg.get("required_approvals")
    if required_approvals is not None:
        if not isinstance(required_approvals, list) or not all(isinstance(x, str) for x in required_approvals):
            fail("error: stack-config.json 'required_approvals' must be an array of strings", 3)
        known_gates = set(baseline.get("approval_gate_map", {}).keys())
        unknown = [g for g in required_approvals if g not in known_gates]
        if unknown:
            fail(f"error: stack-config.json 'required_approvals' contains unknown gate(s) {sorted(unknown)} (known: {sorted(known_gates)})", 3)


def _dedupe_canonical(rules):
    order = {"identity": 0, "path": 1, "bash": 2}
    seen = {}
    for rule, cls in rules:
        if rule not in seen:
            seen[rule] = cls
    items = list(seen.items())
    items.sort(key=lambda rc: (order.get(rc[1], 9), rc[0]))
    return items


def build_plan(baseline, cfg, servers, waivers, scope, prune_user,
               sidecar, dmp_ignored, dmp_malformed, warnings):
    def warn(msg):
        warnings.append(msg)

    if scope == "user":
        rules = []
        floor = baseline.get("floor", {})
        for item in floor.get("deny", []):
            rules.append((item["rule"], item["class"]))
        file_tools = baseline.get("file_tools", ["Edit", "Write"])
        for pr in floor.get("path_rules", []):
            for tool in file_tools:
                rules.append((f"{tool}({pr['path']})", pr["class"]))
        rules = _dedupe_canonical(rules)
        return {
            "scope": "user",
            "compiled_deny": [{"rule": r, "class": c} for r, c in rules],
            "compiled_ask": [],
            "baseline_version": baseline.get("version"),
            "retired_rules": baseline.get("retired_rules", []),
            "prune_user": bool(prune_user),
            "waived_count": 0,
            "warnings": warnings,
        }

    domain_mode = cfg.get("domain_mode")            # raw, echoed verbatim --
                                                      # NOT the normalized list
    active = active_modes(cfg)
    sensitivity = (cfg.get("sensitivity") or {}).get("level", "normal")
    required_approvals = cfg.get("required_approvals") or []

    rules = []
    floor = baseline.get("floor", {})
    for item in floor.get("deny", []):
        rules.append((item["rule"], item["class"]))
    file_tools = baseline.get("file_tools", ["Edit", "Write"])
    for pr in floor.get("path_rules", []):
        for tool in file_tools:
            rules.append((f"{tool}({pr['path']})", pr["class"]))

    def expand_overlay(overlay, suppress_tools=()):
        for tool in overlay.get("mcp_tool_denies", []):
            if tool in suppress_tools:
                continue
            if servers is None:
                warn(f"live-capabilities snapshot missing/stale; no MCP rule emitted for tool '{tool}'")
                continue
            for srv in servers:
                rules.append((f"mcp__{srv}__{tool}", "identity"))
        for srv_name in overlay.get("mcp_server_denies", []):
            if servers is None:
                warn(f"live-capabilities snapshot missing/stale; no MCP rule emitted for server '{srv_name}'")
                continue
            if srv_name in servers:
                rules.append((f"mcp__{srv_name}", "identity"))
        for verb in overlay.get("bash_guardrails", []):
            rules.append((f"Bash({verb}:*)", "bash"))

    domain_overlays = baseline.get("domain_overlays", {})
    gate_map = baseline.get("approval_gate_map", {})

    # MCQ 2 (ADR-044): the three migration/deploy MCP tools are denied
    # unconditionally by default, suppressed only when the ADR-053
    # D6-revised honor test below actually HONORS them -- BUT ONLY when the
    # gate was not explicitly requested via required_approvals. D4: an
    # explicitly requested gate is unconditional and never suppressible.
    unconditional_tools = set()
    for gate_name in GATE_OWNERS:
        for tool in gate_map.get(gate_name, {}).get("mcp_tool_denies", []):
            unconditional_tools.add(tool)
    explicit_gates = set(required_approvals)

    # ---- ADR-053 D6-revised: the suppression honor test -------------------
    scope_obj = consent_scope(cfg, active)
    want_hash = consent_scope_hash(scope_obj)
    known_modes = set(domain_overlays.keys())
    suppresses = {
        m: set(domain_overlays.get(m, {}).get("mcp_tool_denies", [])) & unconditional_tools
        for m in known_modes
    }
    ack_ctx = {
        "known_modes": known_modes,
        "active": set(active),
        "suppresses": suppresses,
        "want_hash": want_hash,
    }
    fresh, stale, inert = read_acks(sidecar, ack_ctx, warn)
    gates_ctx = {
        "required_approvals": required_approvals,
        "unconditional_tools": unconditional_tools,
        "servers": servers,
    }
    res = classify_suppressions(cfg, baseline, active, (fresh, stale, inert), gates_ctx)

    for gate_name in GATE_OWNERS:
        gate_rules = gate_map.get(gate_name, {})
        if gate_name in explicit_gates:
            # Explicit human request: unconditional, no suppression. Covers
            # bash_guardrails too (expand_overlay handles the whole dict).
            expand_overlay(gate_rules)
        else:
            # MCQ-2 implicit default only: suppressible by whatever the honor
            # test actually honored across every active mode.
            expand_overlay(gate_rules, suppress_tools=res["honored"])

    # Every active mode own overlay: mcp_tool_denies additive for tool
    # names NOT already covered unconditionally above (avoids double
    # emission); bash_guardrails / mcp_server_denies additive. Unioned
    # across ALL active modes (ADR-053 D1) -- monotonically more
    # restrictive, so no gate is needed here.
    for m in active:
        overlay = domain_overlays.get(m, {})
        overlay_for_tools = dict(overlay)
        overlay_for_tools["mcp_tool_denies"] = [
            t for t in overlay.get("mcp_tool_denies", []) if t not in unconditional_tools
        ]
        expand_overlay(overlay_for_tools)

    sensitivity_overlays = baseline.get("sensitivity_overlays", {})
    sens_overlay = sensitivity_overlays.get(sensitivity, {})
    for item in sens_overlay.get("deny", []):
        rules.append((item["rule"], item["class"]))
    for srv_name in sens_overlay.get("mcp_server_denies", []):
        if servers is None:
            warn(f"live-capabilities snapshot missing/stale; no MCP rule emitted for server '{srv_name}'")
        elif srv_name in servers:
            rules.append((f"mcp__{srv_name}", "identity"))

    for gate in required_approvals:
        if gate in GATE_OWNERS:
            continue  # already applied unconditionally above (MCQ 2)
        if gate in gate_map:
            expand_overlay(gate_map[gate])

    rules = _dedupe_canonical(rules)

    waiver_set = set(waivers)
    before = len(rules)
    rules = [(r, c) for (r, c) in rules if r not in waiver_set]
    waived_count = before - len(rules)

    # One warnings[] line per withheld tool (report-truthfulness invariant:
    # the snapshot-missing variant never claims a deny that is not emitted),
    # plus one per prunable ack -- both already plumbed to stderr (line 475).
    for entry in res["suppressions_withheld"]:
        if entry["deny_rules"]:
            warn(f"withheld suppression: '{entry['tool']}' stays denied "
                 f"({entry['clause']}; modes: {entry['modes']}). Fix: {entry['fix']}")
        else:
            warn(f"withheld suppression: '{entry['tool']}' would stay denied, but no "
                 f"MCP rule was emitted (live-capabilities snapshot missing/stale)")

    for p in res["acks_prunable"]:
        warn(f"multi_mode_suppression_ack for mode '{p['mode']}' tool '{p['tool']}' is "
             f"prunable ({p['why']}); the next stack-config.json-writing skill will delete it")

    # Drift-gate only (T-41) -- NEVER part of the consent preimage.
    baseline_hash = "sha256:" + hashlib.sha256(
        json.dumps(baseline, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    return {
        "scope": "project",
        "compiled_deny": [{"rule": r, "class": c} for r, c in rules],
        "compiled_ask": [],
        "baseline_version": baseline.get("version"),
        "inputs": {
            "domain_mode": domain_mode,
            "sensitivity": sensitivity,
            "required_approvals": required_approvals,
            "mcp_servers": servers if servers is not None else [],
            "consent_scope": scope_obj,
            "consent_scope_hash": want_hash,
            "suppressions_honored": res["suppressions_honored"],
            "suppressions_withheld": res["suppressions_withheld"],
            "acks_in_force": res["acks_in_force"],
            "acks_prunable": res["acks_prunable"],
            "baseline_hash": baseline_hash,
            "domain_mode_paths_ignored": dmp_ignored,
            "domain_mode_paths_malformed": dmp_malformed,
        },
        "waived_count": waived_count,
        "warnings": warnings,
    }


def main():
    baseline_path, cfg_path, snapshot_path, scope, prune_flag, sidecar_path = sys.argv[1:7]
    baseline = load_json(baseline_path, "baseline")
    if baseline is None:
        fail(f"error: baseline not found at {baseline_path}", 3)
    validate_baseline(baseline)

    warnings = []
    def warn(msg):
        warnings.append(msg)

    cfg = {}
    dmp_ignored, dmp_malformed = [], []
    if scope == "project":
        cfg = load_json(cfg_path, "stack-config")
        if cfg is None:
            fail("refused: no .claude/stack-config.json found", 2)
        validate_cfg(cfg, baseline)
        known_modes = set(baseline.get("domain_overlays", {}).keys())
        validate_domain_mode(cfg, known_modes)
        dmp_ignored, dmp_malformed = validate_domain_mode_paths(cfg, known_modes, warn)

    snapshot = load_json(snapshot_path, "live-capabilities snapshot")
    servers = None
    if isinstance(snapshot, dict):
        mcp = snapshot.get("mcp_servers")
        if isinstance(mcp, list):
            # Sorted + deduped at construction (ADR-053 round 6): inputs.mcp_servers
            # reaches the sidecar via plan["inputs"], so byte-identical-compile
            # (T-7/T-29) and the writer-skill run-2 drift gate must not be
            # order-sensitive to snapshot iteration order.
            servers = sorted({
                m["name"] for m in mcp
                if isinstance(m, dict) and isinstance(m.get("name"), str)
            })

    sidecar = None
    waivers = []
    if scope == "project" and sidecar_path:
        sidecar = load_sidecar(sidecar_path, warn)
        if isinstance(sidecar, dict):
            for w in sidecar.get("waivers", []):
                if isinstance(w, dict) and isinstance(w.get("rule"), str):
                    waivers.append(w["rule"])

    plan = build_plan(baseline, cfg, servers, waivers, scope, prune_flag == "1",
                       sidecar, dmp_ignored, dmp_malformed, warnings)
    print(json.dumps(plan))


main()
PYEOF
)"
rc=$?
if [[ $rc -ne 0 ]]; then
  exit $rc
fi

echo "$PLAN_JSON" | jq -r '.warnings[]? | "warning: " + .' >&2

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$JSON_OUT" -eq 1 ]]; then
    echo "$PLAN_JSON"
  else
    echo "[dry-run] permissions-compile ($SCOPE):"
    echo "$PLAN_JSON" | jq -r '.compiled_deny[] | "  deny " + .rule + "  [" + .class + "]"'
    WAIVED="$(echo "$PLAN_JSON" | jq -r '.waived_count // 0')"
    [[ "$WAIVED" != "0" ]] && echo "  (waived $WAIVED rule(s))"
  fi
  exit 0
fi

if [[ "$SCOPE" == "user" ]]; then
  TARGET="$HOME/.claude/settings.json"
else
  TARGET="$REPO_ROOT/.claude/settings.json"
fi

ERR_TMP="$(mktemp)"
RESULT_JSON="$(echo "$PLAN_JSON" | python3 "$LIB_PY" --apply-permissions-plan --target "$TARGET" ${SIDECAR:+--sidecar "$SIDECAR"} 2>"$ERR_TMP")"
rc=$?
if [[ $rc -ne 0 ]]; then
  cat "$ERR_TMP" >&2
  rm -f "$ERR_TMP"
  exit $rc
fi
rm -f "$ERR_TMP"

if [[ "$JSON_OUT" -eq 1 ]]; then
  echo "$RESULT_JSON"
  exit 0
fi

A="$(echo "$RESULT_JSON" | jq -r '.counts.identity')"
B="$(echo "$RESULT_JSON" | jq -r '.counts.path')"
C="$(echo "$RESULT_JSON" | jq -r '.counts.bash')"
WAIVED="$(echo "$PLAN_JSON" | jq -r '.waived_count // 0')"
PRUNED="$(echo "$RESULT_JSON" | jq -r '.pruned | length')"
ADOPTED="$(echo "$RESULT_JSON" | jq -r '.adopted')"
echo "permissions-compile ($SCOPE): $A identity (A) / $B path (B) / $C bash-guardrail (C, NOT enforcement); waived $WAIVED; pruned $PRUNED; adopted $ADOPTED"
echo "  file: $TARGET"
exit 0
