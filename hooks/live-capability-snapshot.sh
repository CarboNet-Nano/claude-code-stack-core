#!/usr/bin/env bash
# SessionStart hook: write a redacted, machine-local snapshot of enabled
# plugins and MCP servers so the recommend-capabilities engine can rank live
# (per-machine) capabilities alongside the committed registry (ADR-043 D7-D13).
#
# Modes:
#   live-capability-snapshot.sh            write ~/.claude/session-state/live-capabilities.json; print nothing; always exit 0
#   live-capability-snapshot.sh --print    write nothing; print the JSON to stdout (manual/debug/tests)
#
# Fail-safe by design: any error (missing settings.json, malformed JSON,
# unwritable dir) leaves any existing snapshot file untouched and exits 0. A
# SessionStart hook must never break a session. This hook NEVER writes
# ~/.claude/settings.json (ADR-018's write allowlist is untouched).
#
# Secrets are excluded by construction (allowlist, not redaction): headers,
# env, args, command values, URL query strings, userinfo and paths are never
# read into the output. Only the URL host survives, for MCP servers with a
# URL. See the field-derivation table in ADR-043 for the exact allowlist.
#
# summary: Writes a redacted per-machine snapshot of enabled plugins/MCP servers for the recommend-capabilities engine.

set -uo pipefail

MODE="write"
if [[ "${1:-}" == "--print" ]]; then
  MODE="print"
fi

# Scope containment (D13): every path here is rooted at $HOME/.claude — never
# ${CLAUDE_PLUGIN_ROOT} — so a HOME-fixture test run touches nothing else.
STATE_DIR="$HOME/.claude/session-state"
DEST="$STATE_DIR/live-capabilities.json"
SETTINGS="$HOME/.claude/settings.json"
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
PLUGINS_ROOT="$HOME/.claude/plugins"

command -v python3 >/dev/null 2>&1 || exit 0

if [[ "$MODE" == "write" ]]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
fi

python3 - "$SETTINGS" "$INSTALLED_PLUGINS" "$PLUGINS_ROOT" "$MODE" "$DEST" "$STATE_DIR" <<'PYEOF'
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlsplit


def empty_envelope(generated_at):
    return {
        "generated_at": generated_at,
        "source": "live",
        "scope": "user",
        "plugins": [],
        "mcp_servers": [],
    }


def read_json_object(path):
    """Returns (obj_or_None, existed, malformed). `existed and malformed` means
    the file is present but failed to parse as a JSON object."""
    if not os.path.exists(path):
        return None, False, False
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None, True, True
    if not isinstance(data, dict):
        return None, True, True
    return data, True, False


def first_sentence(text):
    s = re.split(r"\.\s+", text.strip())[0].strip()
    if s and not s.endswith("."):
        s += "."
    return s[:200]


def _resolve_plugin_dir(entry, plugins_root_real):
    """installPath is allowlisted read-only (D8a): used solely to locate
    plugin.json, and only if it resolves under the real plugins root.
    installPath itself is never emitted. Returns the resolved dir or None."""
    install_path = entry.get("installPath") if isinstance(entry, dict) else None
    if not isinstance(install_path, str) or not plugins_root_real:
        return None
    try:
        resolved = os.path.realpath(install_path)
    except OSError:
        return None
    contained = resolved == plugins_root_real or resolved.startswith(plugins_root_real + os.sep)
    return resolved if contained else None


def _load_plugin_json(resolved_dir):
    plugin_json_path = os.path.join(resolved_dir, ".claude-plugin", "plugin.json")
    try:
        with open(plugin_json_path, encoding="utf-8") as fh:
            pj = json.load(fh)
    except (OSError, ValueError):
        return None
    return pj if isinstance(pj, dict) else None


def build_plugins(enabled_plugins, installed, plugins_root_real):
    """`enabled_plugins` is settings.json's enabledPlugins map (opt-in: only
    exactly-True entries survive). `installed` is installed_plugins.json's
    plugins map, used only to enrich version/summary — never required."""
    out = []
    for pid, val in enabled_plugins.items():
        if val is not True or not isinstance(pid, str):
            continue
        if "@" in pid:
            # rsplit, not split: marketplace is the trailing segment by
            # convention (name@marketplace) -- rsplit is correct even if a
            # future plugin id ever contains '@' within the name part itself.
            name, marketplace = pid.rsplit("@", 1)
        else:
            name, marketplace = pid, None

        version = None
        summary = None
        rec = installed.get(pid)
        if isinstance(rec, list) and rec and isinstance(rec[0], dict):
            entry = rec[0]
            v = entry.get("version")
            if isinstance(v, str):
                version = v

            resolved = _resolve_plugin_dir(entry, plugins_root_real)
            if resolved:
                pj = _load_plugin_json(resolved)
                desc = pj.get("description") if pj else None
                if isinstance(desc, str) and desc.strip():
                    summary = first_sentence(desc)

        out.append({
            "id": pid,
            "name": name,
            "marketplace": marketplace,
            "version": version,
            "summary": summary,
        })
    out.sort(key=lambda p: p["id"])
    return out


def collect_plugin_mcp_servers(enabled_plugins, installed, plugins_root_real):
    """Plugin-provided MCP servers are declared in the plugin's OWN mcp.json,
    referenced by plugin.json's "mcpServers" field (a relative path, per the
    Claude Code plugin spec) or, less commonly, inlined there directly as an
    object. settings.json's top-level `mcpServers` key never sees these — a
    plugin like `neon@claude-plugins-official` ships mcp.json = {"mcpServers":
    {"neon": {"type": "http", "url": "..."}}} and nothing in settings.json
    ever names it. Without this, every enabled-via-plugin MCP server is
    invisible to this snapshot, and any mcp_tool_denies / mcp_server_denies
    rule in config/permissions-baseline.json that targets it silently never
    fires (scripts/permissions-compile.sh only emits a rule for a server
    present in this snapshot's mcp_servers list). Returns name -> raw server
    def, same shape as a settings.json mcpServers value."""
    out = {}
    for pid, val in enabled_plugins.items():
        if val is not True or not isinstance(pid, str):
            continue
        rec = installed.get(pid)
        if not (isinstance(rec, list) and rec and isinstance(rec[0], dict)):
            continue
        resolved = _resolve_plugin_dir(rec[0], plugins_root_real)
        if not resolved:
            continue
        pj = _load_plugin_json(resolved)
        spec = pj.get("mcpServers") if pj else None
        servers_map = None
        if isinstance(spec, str):
            # Relative path from the plugin dir to its mcp.json; must stay
            # contained under that same resolved plugin dir.
            mcp_path = os.path.join(resolved, spec)
        elif isinstance(spec, dict):
            servers_map = spec
            mcp_path = None
        elif spec is None:
            # plugin.json omitting "mcpServers" entirely still ships a server
            # (e.g. cloudflare@claude-plugins-official 1.0.0) via the default
            # `.mcp.json` filename convention at the plugin root.
            mcp_path = os.path.join(resolved, ".mcp.json")
        else:
            mcp_path = None

        if servers_map is None and mcp_path is not None:
            try:
                mcp_path = os.path.realpath(mcp_path)
            except OSError:
                continue
            if mcp_path != resolved and not mcp_path.startswith(resolved + os.sep):
                continue
            try:
                with open(mcp_path, encoding="utf-8") as fh:
                    mcp_doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(mcp_doc, dict):
                candidate = mcp_doc.get("mcpServers")
                servers_map = candidate if isinstance(candidate, dict) else mcp_doc

        if not isinstance(servers_map, dict):
            continue
        for name, sdef in servers_map.items():
            # First declaration wins (settings.json entries are merged in
            # separately, taking precedence — see main()); don't let a
            # second plugin silently clobber another's server of the same name.
            if isinstance(name, str) and isinstance(sdef, dict) and name not in out:
                out[name] = sdef
    return out


def build_mcp_servers(mcp_servers_raw):
    """Opt-out (D9): every entry survives unless `.disabled` is exactly True.
    Only `.type`/`.command`(presence)/`.url`(host only)/`.disabled`(predicate
    only, never emitted) are read — never headers/env/args/command value."""
    out = []
    for name, val in mcp_servers_raw.items():
        if not isinstance(name, str) or not isinstance(val, dict):
            continue
        if val.get("disabled") is True:
            continue

        type_field = val.get("type")
        if isinstance(type_field, str) and type_field.strip():
            transport = type_field.strip()
        elif "command" in val:
            # Key presence, not value type (ADR field table: "absent + command
            # present -> stdio") -- a non-string command (e.g. array-form) is
            # still a local stdio server and must not fall through to the
            # url/host branch below.
            transport = "stdio"
        else:
            transport = None

        transport_is_stdio = isinstance(transport, str) and transport.lower() == "stdio"

        host = None
        if not transport_is_stdio:
            url = val.get("url")
            if isinstance(url, str) and url:
                try:
                    host = urlsplit(url).hostname
                except ValueError:
                    host = None

        # remote = anything not stdio: transport is an open string (ADR-043's
        # table lists http/sse/stdio as the expected values, but real configs
        # vary in case, use newer transport spellings like streamable-http, or
        # omit `.type` while still setting `.url`). A closed allowlist here
        # would silently defeat the confidential-mode remote-server gate in
        # skills/recommend-capabilities/SKILL.md Step 3 for any of those
        # shapes. `host` is already only populated for transport != stdio,
        # so this is consistent with -- not broader than -- the host
        # derivation. Case-insensitive stdio check so a cased "STDIO" isn't
        # mislabeled remote.
        remote = not transport_is_stdio

        out.append({
            "name": name,
            "transport": transport,
            "host": host,
            "remote": remote,
        })
    out.sort(key=lambda m: m["name"])
    return out


def main():
    settings_path, installed_path, plugins_root, mode, dest_path, state_dir = sys.argv[1:7]
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # settings.json missing or malformed is fatal (D7): write mode leaves any
    # existing snapshot untouched; print mode has no destination to protect,
    # so it reports the best-effort empty envelope instead of crashing.
    settings, _existed, _malformed = read_json_object(settings_path)
    if settings is None:
        if mode == "print":
            print(json.dumps(empty_envelope(generated_at), indent=2))
        return 0

    enabled_plugins = settings.get("enabledPlugins")
    if not isinstance(enabled_plugins, dict):
        enabled_plugins = {}

    mcp_servers_raw = settings.get("mcpServers")
    if not isinstance(mcp_servers_raw, dict):
        mcp_servers_raw = {}

    # installed_plugins.json missing entirely is NOT fatal — version/summary
    # simply fall back to null (the field table's stated default). Malformed
    # JSON in it IS fatal, same as settings.json ("either input" in the test
    # plan), since a parse failure means we cannot trust its content at all.
    installed, installed_existed, installed_malformed = read_json_object(installed_path)
    if installed_existed and installed_malformed:
        if mode == "print":
            print(json.dumps(empty_envelope(generated_at), indent=2))
        return 0
    installed_plugins_map = {}
    if installed is not None:
        candidate = installed.get("plugins")
        if isinstance(candidate, dict):
            installed_plugins_map = candidate

    try:
        plugins_root_real = os.path.realpath(plugins_root)
    except OSError:
        plugins_root_real = None

    # Union settings.json's top-level mcpServers with each enabled plugin's
    # own mcp.json-declared servers. settings.json wins on a name collision
    # (setdefault below only fills names settings.json didn't already claim).
    plugin_mcp_servers = collect_plugin_mcp_servers(enabled_plugins, installed_plugins_map, plugins_root_real)
    merged_mcp_servers = dict(mcp_servers_raw)
    for name, sdef in plugin_mcp_servers.items():
        merged_mcp_servers.setdefault(name, sdef)

    snapshot = {
        "generated_at": generated_at,
        "source": "live",
        "scope": "user",
        "plugins": build_plugins(enabled_plugins, installed_plugins_map, plugins_root_real),
        "mcp_servers": build_mcp_servers(merged_mcp_servers),
    }

    if mode == "print":
        print(json.dumps(snapshot, indent=2))
        return 0

    # Write mode (D13): temp file created in the destination directory itself,
    # then os.replace (atomic within one filesystem — never a torn read). Any
    # failure here leaves the existing destination untouched: dest is only
    # ever touched by the final os.replace call, never opened for truncation.
    try:
        os.makedirs(state_dir, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=state_dir, prefix=".live-capabilities-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out_fh:
                out_fh.write(json.dumps(snapshot, indent=2))
                out_fh.write("\n")
            os.replace(tmp_path, dest_path)
        except Exception:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
    except Exception:
        pass
    return 0


sys.exit(main())
PYEOF

exit 0
