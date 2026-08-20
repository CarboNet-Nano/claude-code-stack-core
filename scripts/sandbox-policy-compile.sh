#!/usr/bin/env bash
# scripts/sandbox-policy-compile.sh — ADR-071 D7. Compiles a repo's
# `.claude/stack-config.json` sensitivity.level + `config/vendor-hosts.json`
# into project-scope `sandbox.network.allowedDomains` (plus
# `sandbox.failIfUnavailable` and a `WebFetch(domain:...)` prune of
# `permissions.allow`). Hands the plan to scripts/lib/settings_lock.py
# --apply-sandbox-policy (ADR-044 Contract C.1's shared lock) — this script
# NEVER writes settings.json / settings.local.json / the sidecar / the
# receipt itself.
#
# HOOKS ONLY. A bare Bash invocation of this script is refused (exit 2): the
# managed floor's `denyWrite` would make its write fail anyway (EPERM), and a
# comprehensible refusal here is better than that opaque failure. Hooks that
# legitimately call this set CLAUDE_HOOK_EVENT before doing so.
#
# Usage:
#   sandbox-policy-compile.sh --repo-root <path> [--dry-run] [--json] [--verify-only]
#
# Exit codes (native-settings-edit / permissions-compile.sh convention):
#   0  applied, dry-run preview, or an intentional no-op (NOT_GOVERNED)
#   2  refused (validation, missing CLAUDE_HOOK_EVENT) — one-line reason
#   3  I/O / parse error (sanitized)
#
# summary: Compiles sensitivity.level + vendor-hosts.json into the sandbox network allowlist (ADR-071).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PY="$SCRIPT_DIR/lib/settings_lock.py"
[[ -f "$LIB_PY" ]] || LIB_PY="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib/settings_lock.py"

REPO_ROOT=""
DRY_RUN=0
JSON_OUT=0
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --verify-only) VERIFY_ONLY=1; DRY_RUN=1; JSON_OUT=1; shift ;;
    *) echo "refused: unknown argument $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 3; }
[[ -f "$LIB_PY" ]] || {
  echo "error: could not resolve scripts/lib/settings_lock.py (repo or installed layout)" >&2
  exit 3
}
[[ -n "$REPO_ROOT" ]] || { echo "refused: --repo-root is required" >&2; exit 2; }

# --- hooks-only gate (ADR-071 D9 pointer) -----------------------------------
# A Bash tool call cannot write under the managed floor's denyWrite anyway
# (once the floor is installed); this refusal fails comprehensibly instead
# of surfacing an opaque EPERM, and stays true even before the floor exists
# (nothing but a hook is meant to run this).
if [[ -z "${CLAUDE_HOOK_EVENT:-}" ]]; then
  echo "refused: sandbox-policy-compile.sh runs only from a hook (CLAUDE_HOOK_EVENT unset). See docs/ADRs/071-sandbox-vendor-host-compile.md D9." >&2
  exit 2
fi

# --- cloud detector (ADR-018 H4 lineage, DELIBERATELY DIVERGED from
# scripts/permissions-compile.sh:78-87 -- security-audit CRITICAL fix,
# 2026-08-11) ----------------------------------------------------------------
# permissions-compile.sh's twin of this function also checks for
# /tmp/.claude-stack-cloud-bootstrap.done. That marker lives in a path the
# Bash sandbox's own allowWrite list grants write access to (~/.claude,
# /tmp, /private/tmp are all writable per ADR-063 D4) -- so a Bash-capable
# subagent can `touch` (or delete) it and flip this detector's answer for
# every SUBSEQUENT hook invocation, in either direction: forging
# CLOUD_HOOK_ONLY suppresses a legitimate recompile (write_settings=False),
# preserving a stale, WIDER allowlist across a sensitivity tightening --
# exactly the case D9's "fail-closed above normal" exists to prevent.
#
# Fixed here by dropping the marker entirely and relying ONLY on the
# environment-variable signals. Those are unforgeable across the boundary
# that matters: a hook is spawned by the Claude Code harness as a SEPARATE
# process from any Bash tool call, and (per this stack's own documented
# behavior) shell state including `export` does not persist across distinct
# Bash tool invocations, let alone into an unrelated hook process's
# environment. A subagent cannot set CLAUDE_CODE_REMOTE/CLAUDE_CODE_CLOUD/etc.
# for this hook's process short of writing a persistent env source under a
# `denyWrite`-protected path -- which is exactly the guarantee D11 exists to
# give. This function is intentionally NOT "replicated verbatim" from
# permissions-compile.sh any more; do not resync it with that file without
# fixing the same gap there first.
is_cloud_session() {
  [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] && return 0
  local v val
  for v in CLAUDE_CODE_CLOUD CLAUDE_CLOUD CODESPACES CLOUD_SHELL; do
    val="${!v:-}"
    case "$val" in [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) return 0 ;; esac
  done
  return 1
}
CLOUD=0
is_cloud_session && CLOUD=1

# --- canonicalize repo root (same rule as permissions-compile.sh:100-106,
# so lock-path identity never depends on CWD consistency across processes) --
[[ -d "$REPO_ROOT" ]] || { echo "refused: --repo-root does not exist" >&2; exit 2; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

CFG="$REPO_ROOT/.claude/stack-config.json"
if [[ ! -f "$CFG" ]]; then
  # D8: repo not stack-governed. Intentional no-op — exit 0, nothing
  # written, no receipt.
  if [[ "$JSON_OUT" -eq 1 ]]; then
    jq -nc --arg repo "$REPO_ROOT" '{v:1, repo:$repo, verdict:"NOT_GOVERNED"}'
  elif [[ "$DRY_RUN" -eq 0 ]]; then
    :  # SessionStart hook: silent
  else
    echo "[dry-run] sandbox-policy-compile: NOT_GOVERNED (no .claude/stack-config.json)"
  fi
  exit 0
fi

# --- resolve inputs ---------------------------------------------------------
# vendor-hosts.json is a SECURITY-AUTHORITY file (it names the closed set of
# hosts the compiler may add/remove), so unlike BASELINE below it gets only
# the same two-tier resolution config/permissions-baseline.json's own
# precedent uses -- installed copy, then the plugin/CLAUDE_PLUGIN_ROOT copy.
# Security-audit CRITICAL fix, 2026-08-11: a THIRD fallback to
# "$REPO_ROOT/config/vendor-hosts.json" previously existed here and does not
# for BASELINE's resolution -- REPO_ROOT is the project under test, i.e.
# attacker-controlled content in the general case (a malicious PR checkout),
# and that fallback let a crafted repo-local vendor-hosts.json (e.g. a fake
# is_runtime:true entry) govern its OWN sandbox policy at every sensitivity
# level. Removed; if neither trusted copy exists, load_vendor_hosts() below
# falls back to the hardcoded, non-configurable universe (F6/F7 semantics),
# never to anything read from the repo being governed.
VENDOR_HOSTS="$HOME/.claude/config/vendor-hosts.json"
[[ -f "$VENDOR_HOSTS" ]] || VENDOR_HOSTS="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/config/vendor-hosts.json"

BASELINE="$HOME/.claude/config/permissions-baseline.json"
[[ -f "$BASELINE" ]] || BASELINE="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/config/permissions-baseline.json"

SNAPSHOT="$HOME/.claude/session-state/live-capabilities.json"
MANAGED_SETTINGS_PATH="${MANAGED_SETTINGS_PATH:-/Library/Application Support/ClaudeCode/managed-settings.json}"
PROJECT_SETTINGS="$REPO_ROOT/.claude/settings.json"
LOCAL_SETTINGS="$REPO_ROOT/.claude/settings.local.json"
USER_SETTINGS="$HOME/.claude/settings.json"
SIDECAR="$REPO_ROOT/.claude/permissions.stack.json"
RECEIPT_KEY="$(printf '%s' "$REPO_ROOT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
RECEIPT_DIR="$HOME/.claude/session-state/sandbox-policy"
RECEIPT="$RECEIPT_DIR/$RECEIPT_KEY.json"
mkdir -p "$RECEIPT_DIR" 2>/dev/null || true

DISABLED=0
[[ "${SANDBOX_POLICY_COMPILE:-}" == "off" ]] && DISABLED=1

# --- build the plan (read-only; nothing is written here) -------------------
# Do NOT use apostrophes anywhere in the heredoc below — see
# scripts/permissions-compile.sh's own warning; the same nested-$(...)
# fragility applies here. Verify any edit with: bash -n scripts/sandbox-policy-compile.sh
PLAN_JSON="$(python3 - "$REPO_ROOT" "$CFG" "$VENDOR_HOSTS" "$BASELINE" "$SNAPSHOT" \
  "$MANAGED_SETTINGS_PATH" "$PROJECT_SETTINGS" "$LOCAL_SETTINGS" "$USER_SETTINGS" \
  "$SIDECAR" "$RECEIPT" "$CLOUD" "$DISABLED" <<'PYEOF'
import fnmatch
import hashlib
import json
import os
import sys

(repo_root, cfg_path, vendor_hosts_path, baseline_path, snapshot_path,
 managed_path, project_settings_path, local_settings_path, user_settings_path,
 sidecar_path, receipt_path, cloud_str, disabled_str) = sys.argv[1:14]

CLOUD = cloud_str == "1"
DISABLED = disabled_str == "1"

REQUIRED_DENY_PATHS = [
    "**/.claude/settings.json", "**/.claude/settings.local.json",
    "**/.claude/stack-config.json", "~/.claude/settings.json",
    "~/.claude/stack-defaults.json", "~/.claude/hooks/**",
    "~/.claude/scripts/**", "~/.claude/config/**", "~/.claude/agents/**",
    "~/.claude/skills/**", "~/.claude/lib/**",
]

# F8 drift gate: must equal the host set in config/vendor-hosts.json and
# the HARDCODED_VENDOR_HOSTS tuple in scripts/lib/settings_lock.py.
HARDCODED_FALLBACK_HOSTS = (
    "api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com",
    "api.deepseek.com", "api.x.ai", "openrouter.ai",
)


def load_json(path):
    """(data, existed, parse_error). Never raises."""
    if not path or not os.path.exists(path):
        return None, False, False
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), True, False
    except (OSError, ValueError):
        return None, True, True


VENDOR_REQUIRED_FIELDS = ("host", "vendor", "kind", "is_runtime", "cleared_at_sensitive", "reviewed_on", "terms_url", "why")
RUNTIME_HOST = "api.anthropic.com"  # pinned -- the endpoint the session itself runs on (ADR-071 D4)


def validate_vendor_hosts(data):
    """Real structural validation against the shape declared in
    schemas/vendor-hosts-schema.json (security-audit CRITICAL fix,
    2026-08-11: previously only `isinstance(host, str)` was checked, despite
    the schema file docstring claiming this validator existed). Returns (ok, reason). A STRUCTURAL
    violation here makes the WHOLE FILE untrusted (same treatment as
    unparseable -- falls back to the hardcoded universe); a per-entry
    semantic issue (cleared_at_sensitive:true with no reviewed_on) is
    handled separately and downgrades only that one host, not the file."""
    if not isinstance(data, dict):
        return False, "root is not an object"
    vendors = data.get("vendors")
    if not isinstance(vendors, list) or not vendors:
        return False, "vendors is missing or not a non-empty array"

    seen_hosts = set()
    runtime_hosts = []
    for i, v in enumerate(vendors):
        if not isinstance(v, dict):
            return False, f"vendors[{i}] is not an object"
        for field in VENDOR_REQUIRED_FIELDS:
            if field not in v:
                return False, f"vendors[{i}] missing required field '{field}'"
        host = v.get("host")
        if not isinstance(host, str) or not host:
            return False, f"vendors[{i}].host is not a non-empty string"
        h = host.strip().lower()
        if h != host or "://" in host or "*" in host or ":" in host or " " in host:
            return False, f"vendors[{i}].host '{host}' is not lowercase/scheme-free/glob-free/port-free/space-free"
        if h in seen_hosts:
            return False, f"duplicate host '{h}'"
        seen_hosts.add(h)
        if not isinstance(v.get("is_runtime"), bool):
            return False, f"vendors[{i}].is_runtime is not a boolean"
        if not isinstance(v.get("cleared_at_sensitive"), bool):
            return False, f"vendors[{i}].cleared_at_sensitive is not a boolean"
        if v.get("reviewed_on") is not None and not isinstance(v.get("reviewed_on"), str):
            return False, f"vendors[{i}].reviewed_on is not a string or null"
        if v.get("terms_url") is not None and not isinstance(v.get("terms_url"), str):
            return False, f"vendors[{i}].terms_url is not a string or null"
        if v["is_runtime"]:
            runtime_hosts.append(h)

    if len(runtime_hosts) != 1:
        return False, f"expected exactly one is_runtime:true host, found {len(runtime_hosts)}"
    if runtime_hosts[0] != RUNTIME_HOST:
        return False, f"the is_runtime:true host must be '{RUNTIME_HOST}', found '{runtime_hosts[0]}'"

    return True, None


def normalize(h):
    h = (h or "").strip().lower()
    if h.endswith("."):
        h = h[:-1]
    if ":" in h and not h.startswith("["):
        h = h.split(":", 1)[0]
    return h


def denied_entry(e, denied_set):
    n = normalize(e)
    if n in denied_set:
        return True
    return any(fnmatch.fnmatch(d, n) for d in denied_set)


# --- 1. sensitivity level -----------------------------------------------
cfg_data, cfg_existed, cfg_broken = load_json(cfg_path)
warnings = []


def resolve_level(cfg):
    if cfg_broken or not isinstance(cfg, dict):
        return "restricted", "restrictive-fallback", "stack-config.json is not a valid JSON object"
    sens = cfg.get("sensitivity")
    if sens is None:
        return "normal", "default-normal", None
    if not isinstance(sens, dict):
        return "restricted", "restrictive-fallback", "sensitivity is not an object"
    level = sens.get("level")
    if level is None:
        return "normal", "default-normal", None
    if not isinstance(level, str):
        return "restricted", "restrictive-fallback", "sensitivity.level is not a string"
    if level not in ("normal", "sensitive", "confidential"):
        return "restricted", "restrictive-fallback", f"unknown sensitivity.level {level!r}"
    return level, "stack-config", None


level, level_source, level_warning = resolve_level(cfg_data)
if level_warning:
    warnings.append(level_warning)

# --- 2. vendor host universe ---------------------------------------------
vh_data, vh_existed, vh_broken = load_json(vendor_hosts_path)
vh_shape_ok, vh_shape_reason = (False, "missing/unparseable") if (vh_broken or not vh_existed) else validate_vendor_hosts(vh_data)
vendor_broken = not vh_shape_ok

if vendor_broken:
    vendors = [
        {"host": h, "is_runtime": h == "api.anthropic.com",
         "cleared_at_sensitive": False, "reviewed_on": None}
        for h in HARDCODED_FALLBACK_HOSTS
    ]
    vendor_version = "fallback"
    policy_source = "hardcoded-fallback"
    warnings.append(f"config/vendor-hosts.json missing, unparseable, or fails structural validation ({vh_shape_reason}); using the hardcoded fallback (all non-Anthropic hosts denied at every level)")
else:
    vendors = [v for v in vh_data["vendors"] if isinstance(v, dict) and isinstance(v.get("host"), str)]
    vendor_version = vh_data.get("version", "unknown")
    policy_source = "local-stack-config"

vendors = [dict(v, host=normalize(v["host"])) for v in vendors]
all_hosts = {v["host"] for v in vendors}


def policy_for(lvl):
    if lvl == "normal":
        return set(all_hosts)
    runtime = {v["host"] for v in vendors if v.get("is_runtime")}
    if lvl in ("confidential", "restricted"):
        return set(runtime)
    if lvl == "sensitive":
        return set(runtime) | {
            v["host"] for v in vendors
            if v.get("cleared_at_sensitive") is True and v.get("reviewed_on")
        }
    return set(runtime)


effective_level = "restricted" if vendor_broken else level
allowed_hosts = policy_for(effective_level)
denied_hosts = all_hosts - allowed_hosts

# --- 3. managed floor status ------------------------------------------
managed_data, managed_existed, managed_broken = load_json(managed_path)
sandbox_enabled = False
strict_allowlist = False
deny_write_list = []
if isinstance(managed_data, dict):
    sandbox = managed_data.get("sandbox")
    if isinstance(sandbox, dict):
        sandbox_enabled = sandbox.get("enabled") is True
        network = sandbox.get("network")
        if isinstance(network, dict):
            strict_allowlist = network.get("strictAllowlist") is True
        fs = sandbox.get("filesystem")
        if isinstance(fs, dict) and isinstance(fs.get("denyWrite"), list):
            deny_write_list = [d for d in fs["denyWrite"] if isinstance(d, str)]

missing_deny = [p for p in REQUIRED_DENY_PATHS if p not in deny_write_list]
deny_write_ok = not missing_deny

# Security-audit H6 (verdict-accuracy hardening, 2026-08-11): a
# world-writable managed-settings.json cannot back an un-overridable
# guarantee -- if anyone can edit it, it is not "managed" in the sense D11
# needs. Checked cheaply (mode bits only, no ownership/uid check -- a full
# "must be owned by root" check would also reject every non-live test
# fixture written by the invoking user, which a unit-test harness is not the
# place to solve; see the implementer report for the accepted-with-rationale
# note). Best-effort: a stat failure never raises, it just cannot confirm
# safety, so it downgrades floor_present.
managed_world_writable = False
if managed_existed:
    try:
        import stat as _stat
        mode = os.stat(managed_path).st_mode
        managed_world_writable = bool(mode & (_stat.S_IWGRP | _stat.S_IWOTH))
    except OSError:
        managed_world_writable = True  # cannot verify -> do not trust

floor_present = sandbox_enabled and deny_write_ok and not managed_world_writable
floor = {
    "present": floor_present,
    "sandbox_enabled": sandbox_enabled,
    "strict_allowlist": strict_allowlist,
    "deny_write_ok": deny_write_ok,
    "missing": missing_deny,
    "world_writable": managed_world_writable,
}

# --- 4. verdict ------------------------------------------------------------
if DISABLED:
    verdict = "DISABLED"
    write_settings = False
elif CLOUD:
    verdict = "CLOUD_HOOK_ONLY"
    write_settings = False
elif level_source == "restrictive-fallback" or vendor_broken:
    verdict = "RESTRICTED_FALLBACK"
    write_settings = True
elif not floor["present"]:
    verdict = "FLOOR_ABSENT"
    write_settings = True
elif effective_level != "normal" and not floor["strict_allowlist"]:
    verdict = "WALL_ABSENT"
    write_settings = True
else:
    verdict = "COMPILED"
    write_settings = True

# --- 5. project / local scope diffs ----------------------------------------
proj_data, _, proj_broken = load_json(project_settings_path)
local_data, _, local_broken = load_json(local_settings_path)


def scope_domains(data):
    if not isinstance(data, dict):
        return []
    sandbox = data.get("sandbox")
    if not isinstance(sandbox, dict):
        return []
    network = sandbox.get("network")
    if not isinstance(network, dict):
        return []
    return [d for d in network.get("allowedDomains", []) if isinstance(d, str)]


def scope_allow(data):
    if not isinstance(data, dict):
        return []
    perms = data.get("permissions")
    if not isinstance(perms, dict):
        return []
    return [d for d in perms.get("allow", []) if isinstance(d, str)]


proj_domains = scope_domains(proj_data)
local_domains = scope_domains(local_data)
proj_allow = scope_allow(proj_data)
local_allow = scope_allow(local_data)

live_governed_project = [d for d in proj_domains if normalize(d) in all_hosts or any(fnmatch.fnmatch(h, normalize(d)) for h in all_hosts)]
live_governed_local = [d for d in local_domains if normalize(d) in all_hosts or any(fnmatch.fnmatch(h, normalize(d)) for h in all_hosts)]

project_remove = [d for d in proj_domains if denied_entry(d, denied_hosts)]
local_remove = [d for d in local_domains if denied_entry(d, denied_hosts)]

# Validator LOW finding: an exact-string check alone misses the case where
# an EXISTING glob entry already covers the host being added (e.g.
# "*.openai.com" is already present and "api.openai.com" is now cleared) --
# adding the literal host on top is redundant, not wrong, but not what a
# human would have written and not idempotent-looking. Check against the
# SURVIVING entries only (post-removal) with the same glob-containment rule
# denied_entry() uses, so a denied host glob (about to be removed anyway)
# never "covers" and suppresses a legitimate add.
proj_survivors = [d for d in proj_domains if d not in project_remove]


def covered_by_existing(h, existing):
    for e in existing:
        en = normalize(e)
        if en == h:
            return True
        if "*" in en and fnmatch.fnmatch(h, en):
            return True
    return False


project_add = sorted(
    (h for h in allowed_hosts if not covered_by_existing(h, proj_survivors)),
    key=lambda h: [v["host"] for v in vendors].index(h) if h in [v["host"] for v in vendors] else 999,
)


def webfetch_prune_for(allow_list):
    out = []
    for entry in allow_list:
        if not entry.startswith("WebFetch(domain:") or not entry.endswith(")"):
            continue
        host = entry[len("WebFetch(domain:"):-1]
        if denied_entry(host, denied_hosts):
            out.append(entry)
    return out


proj_wf_prune = webfetch_prune_for(proj_allow)
local_wf_prune = webfetch_prune_for(local_allow)

fail_if_unavailable = True if effective_level != "normal" else None

# --- 6. leaks ---------------------------------------------------------------
user_data, _, _ = load_json(user_settings_path)
user_domains = scope_domains(user_data)
managed_domains = []
if isinstance(managed_data, dict):
    sandbox = managed_data.get("sandbox")
    if isinstance(sandbox, dict):
        network = sandbox.get("network")
        if isinstance(network, dict):
            managed_domains = [d for d in network.get("allowedDomains", []) if isinstance(d, str)]

leaks_user = [d for d in user_domains if denied_entry(d, denied_hosts)]
leaks_managed = [d for d in managed_domains if denied_entry(d, denied_hosts)]
leaks_glob = [d for d in (leaks_user + leaks_managed) if "*" in d]

# --- 7. MCP visibility (D12 row 3 — report only) ----------------------------
mcp_unreviewed = []
if effective_level != "normal":
    snap_data, _, _ = load_json(snapshot_path)
    live_servers = []
    if isinstance(snap_data, dict) and isinstance(snap_data.get("mcp_servers"), list):
        live_servers = sorted({
            m["name"] for m in snap_data["mcp_servers"]
            if isinstance(m, dict) and isinstance(m.get("name"), str)
        })
    baseline_data, _, _ = load_json(baseline_path)
    reviewed = set()
    if isinstance(baseline_data, dict):
        for overlay in (baseline_data.get("domain_overlays") or {}).values():
            if isinstance(overlay, dict):
                reviewed.update(s for s in overlay.get("mcp_server_denies", []) if isinstance(s, str))
        for overlay in (baseline_data.get("sensitivity_overlays") or {}).values():
            if isinstance(overlay, dict):
                reviewed.update(s for s in overlay.get("mcp_server_denies", []) if isinstance(s, str))
    mcp_unreviewed = [s for s in live_servers if s not in reviewed]

# --- 8. tamper detection (D9 / D15 #4) --------------------------------------
prev_receipt, _, _ = load_json(receipt_path)
tamper = False
if isinstance(prev_receipt, dict) and isinstance(prev_receipt.get("level"), str):
    prev_level = prev_receipt["level"]
    if prev_level != level and isinstance(cfg_data, dict):
        history = cfg_data.get("change_history")
        found = False
        if isinstance(history, list):
            for entry in history:
                if (isinstance(entry, dict) and entry.get("setting") == "sensitivity.level"
                        and entry.get("new_value") == level):
                    found = True
                    break
        tamper = not found

plan = {
    "v": 1,
    "repo": repo_root,
    "level": level,
    "level_source": level_source,
    "policy_source": policy_source,
    "vendor_hosts_version": vendor_version,
    "allowed_hosts": sorted(allowed_hosts),
    "denied_hosts": sorted(denied_hosts),
    "project": {"add": project_add, "remove": project_remove},
    "local": {"add": [], "remove": local_remove},
    "webfetch_prune": {"project": proj_wf_prune, "local": local_wf_prune},
    "fail_if_unavailable": fail_if_unavailable,
    "floor": floor,
    "leaks": {"user": leaks_user, "managed": leaks_managed, "glob": leaks_glob, "mcp_unreviewed": mcp_unreviewed},
    "tamper": {"level_changed_without_change_history": tamper},
    "verdict": verdict,
    "warnings": warnings,
    "_write_settings": write_settings,
    "_live_governed_project": live_governed_project,
    "_live_governed_local": live_governed_local,
}
print(json.dumps(plan))
PYEOF
)"
rc=$?
if [[ $rc -ne 0 ]]; then
  exit $rc
fi

echo "$PLAN_JSON" | jq -r '.warnings[]? | "warning: " + .' >&2

VERDICT="$(echo "$PLAN_JSON" | jq -r '.verdict')"
WRITE_SETTINGS="$(echo "$PLAN_JSON" | jq -r '._write_settings')"

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$JSON_OUT" -eq 1 ]]; then
    echo "$PLAN_JSON" | jq 'del(._write_settings, ._live_governed_project, ._live_governed_local)'
  else
    echo "[dry-run] sandbox-policy-compile: verdict=$VERDICT"
    echo "$PLAN_JSON" | jq -r '.project.add[]? | "  + " + .'
    echo "$PLAN_JSON" | jq -r '.project.remove[]? | "  - " + .'
  fi
  exit 0
fi

ERR_TMP="$(mktemp)"
STDOUT_JSON="$(echo "$PLAN_JSON" | python3 "$LIB_PY" \
  --apply-sandbox-policy \
  --target "$PROJECT_SETTINGS" \
  --local-target "$LOCAL_SETTINGS" \
  --sidecar "$SIDECAR" \
  --receipt "$RECEIPT" \
  --vendor-hosts "$VENDOR_HOSTS" 2>"$ERR_TMP")"
rc=$?
if [[ $rc -ne 0 ]]; then
  cat "$ERR_TMP" >&2
  rm -f "$ERR_TMP"
  exit $rc
fi
rm -f "$ERR_TMP"
chmod 600 "$RECEIPT" 2>/dev/null || true

if [[ "$JSON_OUT" -eq 1 ]]; then
  echo "$PLAN_JSON" | jq --argjson result "$STDOUT_JSON" 'del(._write_settings, ._live_governed_project, ._live_governed_local) + {result: $result}'
  exit 0
fi

echo "sandbox-policy-compile: verdict=$VERDICT"
echo "$STDOUT_JSON" | jq -r '"  added \(.counts.added), removed \(.counts.removed), webfetch-pruned \(.counts.webfetch_pruned), stashed \(.counts.stashed)"'
echo "$STDOUT_JSON" | jq -r '.new_stashes[]? | "  stashed: " + .value + " (" + .scope + ", was " + .owner + "-owned) — restore: /sensitivity restore " + .value'
if [[ "$VERDICT" == "FLOOR_ABSENT" ]]; then
  echo "  Managed floor not installed. See docs/runbooks/managed-floor-install.md."
fi
MCP_UNREVIEWED="$(echo "$PLAN_JSON" | jq -r '.leaks.mcp_unreviewed[]? // empty')"
[[ -n "$MCP_UNREVIEWED" ]] && echo "  MCP servers with no recorded filesystem-write review: $MCP_UNREVIEWED"
exit 0
