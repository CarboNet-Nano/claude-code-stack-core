#!/usr/bin/env python3
"""native-settings-edit — the ONLY writer of Claude Code native settings.json.

Implements the ADR-018 "native-settings-edit security contract" (items 1-12).
Stdlib only (no pip install). Deny-by-default: a path that does not match the
curated allowlist is refused, and the denied segments (hooks / env / permissions /
*.command / *.args / *.env) are structurally unreachable.

Exit codes:
  0  success, or a dry-run / diff-only preview (nothing written)
  2  refused (validation, denylist, scope gate, cloud gate, would-create-key)
  3  I/O or parse error (message is sanitized — never echoes file contents)
  64 usage error (bad arguments)

Contract mapping (search "C<n>" / "H<n>" / "M<n>" / "L<n>" in code):
  C1 set-at-path never deep-merge      C2 RFC6901 pointer not split('.')
  C3 per-path value schema             H2 atomic write + lock
  H3 canonicalize pointer              H4 cloud gate inside the tool
  M1 hard-refuse denied segments       M2 default project + --confirm-global
  M4 sanitized errors                  L1 boolean string refusal
  L2/L3 tmp + rename atomicity         (item 11) refuse to CREATE plugin/mcp keys
"""

import argparse
import importlib.util
import json
import os
import sys
import unicodedata

# --- Audited constants (item 3, item 4) -------------------------------------
# Maintained as Claude Code evolves. A value that is not a member is REFUSED
# (model/statusLine) or falls through to diff-only (outputStyle). Free-typed
# values are never written.

MODEL_PRESETS = (
    "default", "opus", "sonnet", "haiku",
    "claude-opus-4-8", "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001", "claude-fable-5",
)

# Built-in output styles; unioned at runtime with ~/.claude/output-styles/*.md.
OUTPUT_STYLE_BUILTINS = ("default", "Explanatory", "Learning", "Concise")

# statusLine presets are AUDITED objects, substituted by name. The caller may
# only pass a preset NAME (a scalar); an object value is refused outright (C3).
# AUDIT INVARIANT (enforced by tests/test-native-settings-edit.sh):
#   no preset command references a user-writable path (no $HOME, ~/.claude,
#   /tmp, or an absolute path); commands use only shell builtins + Claude-set
#   $CLAUDE_PROJECT_DIR. This is what keeps "preset selection" off the RCE path.
STATUSLINE_PRESETS = {
    "static": {"type": "command", "command": "printf 'claude-code'"},
    "minimal": {"type": "command", "command": "printf '%s' \"${CLAUDE_PROJECT_DIR##*/}\""},
}

# --- Denylist (item 5 / M1) -------------------------------------------------
DENY_ANYWHERE = {"hooks", "env", "permissions"}
DENY_LEAF = {"command", "args", "env"}


class Refused(Exception):
    """Validation / policy refusal — exit 2."""


class IOErrorSanitized(Exception):
    """Read/parse failure with a message safe to print — exit 3 (M4)."""


# --- Cloud detection (item 8 / H4) ------------------------------------------
def detect_cloud():
    """Multi-factor, fail-toward-refuse. True if ANY cloud signal is present.

    Not a single env var: an attacker wanting to enable writes in cloud would
    have to clear every signal, all of which the cloud platform controls. The
    canonical stack signal is CLAUDE_CODE_REMOTE (session-start.sh,
    cloud-bootstrap.sh); the others are belt-and-suspenders.
    """
    if os.environ.get("CLAUDE_CODE_REMOTE", "").lower() == "true":
        return True
    for var in ("CLAUDE_CODE_CLOUD", "CLAUDE_CLOUD", "CODESPACES", "CLOUD_SHELL"):
        if os.environ.get(var, "").lower() in ("true", "1", "yes"):
            return True
    if os.path.exists("/tmp/.claude-stack-cloud-bootstrap.done"):
        return True
    return False


# --- JSON Pointer parsing (item 2 / C2, H3) ---------------------------------
def parse_pointer(pointer):
    """RFC 6901 parse + canonicalize. Returns a list of explicit tokens.

    Tokens are explicit, so a plugin key literally containing '.command' is a
    single token that cannot collide with the 'command' denylist leaf — the
    whole reason we use pointers, not split('.').
    """
    if not isinstance(pointer, str) or not pointer.startswith("/"):
        raise Refused("path must be an RFC 6901 JSON Pointer starting with '/'")
    raw_tokens = pointer.split("/")[1:]  # drop the leading empty segment
    tokens = []
    for tok in raw_tokens:
        # RFC 6901 unescape: ~1 -> /, ~0 -> ~ (order matters).
        tok = tok.replace("~1", "/").replace("~0", "~")
        tok = unicodedata.normalize("NFC", tok)
        if tok in ("", ".", ".."):
            raise Refused("path contains an empty or relative ('.', '..') segment")
        # Printable ASCII only, no whitespace/control — reject homoglyph tricks.
        if not all(0x21 <= ord(ch) <= 0x7E for ch in tok):
            raise Refused("path segment contains non-ASCII or control characters")
        if len(tok) > 200:
            raise Refused("path segment too long")
        tokens.append(tok)
    if not tokens:
        raise Refused("path is empty")
    return tokens


def enforce_denylist(tokens):
    """item 5 / M1 — refuse denied segments regardless of context."""
    for tok in tokens:
        if tok in DENY_ANYWHERE:
            raise Refused(
                f"'{tok}' is a review-only / security-boundary setting — "
                "change it with the native command (/hooks, /permissions) or a diff"
            )
    if tokens[-1] in DENY_LEAF:
        raise Refused(
            f"'{tokens[-1]}' is a denied leaf (command/args/env) — never written here"
        )


# --- Allowlist classification (item 3 / D3) ---------------------------------
def classify(tokens):
    """Map an allowlisted pointer to (kind, key). Deny-by-default."""
    if tokens == ["model"]:
        return ("model", None)
    if tokens == ["outputStyle"]:
        return ("outputStyle", None)
    if tokens == ["statusLine"]:
        return ("statusLine", None)
    if len(tokens) == 2 and tokens[0] == "enabledPlugins":
        return ("plugin_toggle", tokens[1])
    if len(tokens) == 3 and tokens[0] == "mcpServers" and tokens[2] == "disabled":
        return ("mcp_disabled", tokens[1])
    raise Refused(
        "path is not in the curated write-allowlist (model, outputStyle, "
        "statusLine, enabledPlugins/<key>, mcpServers/<name>/disabled)"
    )


# --- Value coercion per path schema (items 1, 3, 4 / C1, C3, L1) ------------
def _reject_container(raw):
    """C1 — an object/array value for a scalar path is hard-refused."""
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return  # not JSON => a plain string literal, fine
    if isinstance(parsed, (dict, list)):
        raise Refused("value is an object/array; only a single scalar leaf may be set")


def coerce_bool(raw):
    """L1 — accept ONLY the literal tokens true/false: no surrounding
    whitespace, no 'False'/'0'/'yes', no quoted-string '"false"'."""
    if raw == "true":
        return True
    if raw == "false":
        return False
    raise Refused("boolean field accepts only the literal values true or false")


def resolve_value(kind, raw):
    """Return (write_value, outcome). outcome 'write' or 'diff_only'."""
    _reject_container(raw)
    if kind in ("plugin_toggle", "mcp_disabled"):
        return (coerce_bool(raw), "write")
    if kind == "model":
        if raw not in MODEL_PRESETS:
            raise Refused(
                f"model '{raw}' is not in the shipped preset list "
                f"({', '.join(MODEL_PRESETS)})"
            )
        return (raw, "write")
    if kind == "outputStyle":
        styles = set(OUTPUT_STYLE_BUILTINS) | _installed_output_styles()
        if raw in styles:
            return (raw, "write")
        return (raw, "diff_only")  # C3 — unknown style => diff only, never written
    if kind == "statusLine":
        if raw not in STATUSLINE_PRESETS:
            raise Refused(
                f"statusLine '{raw}' is not an audited preset "
                f"({', '.join(STATUSLINE_PRESETS)}); object values are refused"
            )
        return (STATUSLINE_PRESETS[raw], "write")
    raise Refused("unhandled setting kind")  # defensive; classify() is exhaustive


def _installed_output_styles():
    home = _claude_home()
    styles_dir = os.path.join(home, ".claude", "output-styles")
    out = set()
    try:
        for name in os.listdir(styles_dir):
            if name.endswith(".md"):
                out.add(name[:-3])
    except OSError:
        pass
    return out


# --- Scope resolution (item 9 / M2) -----------------------------------------
def _claude_home():
    # Test hook: redirect the "user" dir without touching the real ~/.claude.
    return os.environ.get("CLAUDE_SETTINGS_HOME", os.path.expanduser("~"))


def _user_global_path():
    return os.path.join(_claude_home(), ".claude", "settings.json")


def _is_user_global(target):
    """True if `target` refers to ~/.claude/settings.json — robust to symlinks
    and case-insensitive filesystems, so --repo-root cannot smuggle the global
    file in under project scope (red-team / Codex finding #1)."""
    ug = _user_global_path()
    t_dir, ug_dir = os.path.dirname(target), os.path.dirname(ug)
    try:
        if os.path.exists(t_dir) and os.path.exists(ug_dir) and os.path.samefile(t_dir, ug_dir):
            return True
    except OSError:
        pass
    rt, rg = os.path.realpath(target), os.path.realpath(ug)
    if rt == rg:
        return True
    if sys.platform == "darwin" and rt.lower() == rg.lower():
        return True
    return False


def resolve_target(scope, repo_root, confirm_global):
    if scope not in ("project", "user"):
        raise Refused("scope must be 'project' or 'user'")
    if scope == "user":
        target = _user_global_path()
    else:
        root = repo_root or os.getcwd()
        target = os.path.join(root, ".claude", "settings.json")
    # M2 — any resolution to the user-global file requires --confirm-global,
    # even under project scope via --repo-root (blast-radius control).
    if _is_user_global(target) and not confirm_global:
        raise Refused(
            "this resolves to the user-global settings file "
            "(~/.claude/settings.json), which affects every project — "
            "re-run with --scope user --confirm-global"
        )
    return target


# --- Safe file load (item 10 / M4) ------------------------------------------
def load_settings(path):
    """Return parsed dict (or {} if absent). Errors are sanitized — the raw
    file content (which may hold the env/secrets block) is NEVER echoed."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        raise IOErrorSanitized(
            f"could not read or parse settings at {_short(path)} "
            "(file unreadable or not valid JSON)"
        )
    if not isinstance(data, dict):
        raise IOErrorSanitized(f"settings at {_short(path)} is not a JSON object")
    return data


def _short(path):
    # Boundary-aware (finding #4): only abbreviate a real home prefix, and cover
    # both the system home and a CLAUDE_SETTINGS_HOME override.
    for home in {os.path.expanduser("~"), _claude_home()}:
        if home and (path == home or path.startswith(home + os.sep)):
            return path.replace(home, "~", 1)
    return path


# --- Key-existence guard (item 11) ------------------------------------------
def ensure_key_exists(data, kind, key):
    """item 11 — only flip an EXISTING enabledPlugins / mcpServers key."""
    if kind == "plugin_toggle":
        if not isinstance(data.get("enabledPlugins"), dict) or key not in data["enabledPlugins"]:
            raise Refused(
                f"plugin '{key}' is not present in enabledPlugins — this tool "
                "flips existing toggles, it never creates them"
            )
    elif kind == "mcp_disabled":
        servers = data.get("mcpServers")
        if not isinstance(servers, dict) or key not in servers or not isinstance(servers[key], dict):
            raise Refused(
                f"MCP server '{key}' is not present in mcpServers — this tool "
                "only enables/disables an existing server"
            )


# --- Set-at-path (item 1 / C1) ----------------------------------------------
def current_value(data, tokens):
    node = data
    for tok in tokens:
        if isinstance(node, dict) and tok in node:
            node = node[tok]
        else:
            return None, False
    return node, True


def set_at_path(data, tokens, value):
    """Set exactly ONE leaf. No deep-merge of a value blob (C1). All untargeted
    siblings (and $schema) are preserved because we mutate one leaf in place."""
    node = data
    for tok in tokens[:-1]:
        node = node[tok]  # parents are guaranteed to exist by ensure_key_exists
    node[tokens[-1]] = value


# --- Shared locked writer resolution (ADR-044 Contract C.1) ----------------
# scripts/lib/settings_lock.py is now the ONLY code path that opens the
# settings lock. It is a behavior-preserving extraction of this file's
# original atomic_write() (moved, not rewritten) -- the O_NOFOLLOW lock,
# mkstemp+rename hardening, and re-read-under-lock semantics are unchanged.
_SETTINGS_LOCK_MODULE = None


def _load_settings_lock():
    """Resolve scripts/lib/settings_lock.py from this file's own location --
    repo layout then installed layout (same precedent as commit bb4f51c,
    "resolve hook-metadata.py via script dir"). skills/ and scripts/lib/ are
    siblings in the repo but land in different places under ~/.claude/, so
    CWD is never trusted."""
    global _SETTINGS_LOCK_MODULE
    if _SETTINGS_LOCK_MODULE is not None:
        return _SETTINGS_LOCK_MODULE
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "scripts", "lib", "settings_lock.py"),
        os.path.join(
            os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.expanduser("~"), ".claude"),
            "scripts", "lib", "settings_lock.py",
        ),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate):
            spec = importlib.util.spec_from_file_location("settings_lock", candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _SETTINGS_LOCK_MODULE = module
            return module
    raise IOErrorSanitized(
        "could not resolve scripts/lib/settings_lock.py (repo or installed layout)"
    )


# --- Atomic locked write (item 7 / H2, L2, L3) ------------------------------
def atomic_write(path, mutate, confirm_global):
    """Thin wrapper over settings_lock.locked_update() (ADR-044 Contract
    C.1). The user-global TOCTOU re-check (finding #3) moves into the
    `pre_check` callback so it still runs AFTER the lock is held."""
    settings_lock = _load_settings_lock()

    def pre_check():
        if _is_user_global(path) and not confirm_global:
            raise settings_lock.Refused(
                "target now resolves to the user-global settings file "
                "(~/.claude/settings.json) " + chr(0x2014) + " re-run with --scope user --confirm-global"
            )

    try:
        settings_lock.locked_update(path, mutate, pre_check=pre_check)
    except settings_lock.Refused as exc:
        raise Refused(str(exc))
    except settings_lock.IOErrorSanitized as exc:
        raise IOErrorSanitized(str(exc))


# --- Orchestration ----------------------------------------------------------
def run(args):
    cloud = detect_cloud()

    tokens = parse_pointer(args.path)
    enforce_denylist(tokens)            # M1 — before anything else touches it
    kind, key = classify(tokens)        # deny-by-default allowlist
    write_value, outcome = resolve_value(kind, args.value)

    target = resolve_target(args.scope, args.repo_root, args.confirm_global)

    # H4 — cloud gate inside the tool. Reads/dry-runs are allowed; writes are not.
    is_write = (outcome == "write") and not args.dry_run
    if cloud and is_write:
        raise Refused(
            "writes are disabled in the cloud environment (read-only). "
            "Use --dry-run to preview, or change this setting locally."
        )

    data = load_settings(target)
    ensure_key_exists(data, kind, key)  # item 11

    old, present = current_value(data, tokens)
    old_repr = json.dumps(old) if present else "<unset>"
    new_repr = json.dumps(write_value)

    # outputStyle miss => diff-only (C3); --dry-run => diff-only (item 6 / M1).
    if outcome == "diff_only" or args.dry_run:
        reason = "unknown output style" if outcome == "diff_only" else "dry-run"
        print(f"[diff-only: {reason}] {args.path} ({args.scope})")
        print(f"  - {old_repr}")
        print(f"  + {new_repr}")
        if outcome == "diff_only":
            print("  (not written — value is not an installed style)")
        return 0

    atomic_write(target, lambda d: (_apply(d, kind, key, tokens, write_value)), args.confirm_global)
    print(f"[written] {args.path} ({args.scope}): {old_repr} -> {new_repr}")
    print(f"  file: {_short(target)}")
    return 0


def _apply(data, kind, key, tokens, write_value):
    ensure_key_exists(data, kind, key)  # re-check under lock (data was re-read)
    set_at_path(data, tokens, write_value)
    return data


def build_parser():
    p = argparse.ArgumentParser(
        prog="native-settings-edit",
        description="The only writer of Claude Code native settings.json (ADR-018).",
    )
    p.add_argument("--path", required=True, help="RFC 6901 JSON Pointer, e.g. /model")
    p.add_argument("--value", required=True, help="scalar value (or preset name)")
    p.add_argument("--scope", choices=("project", "user"), default="project",
                   help="default project; user requires --confirm-global")
    p.add_argument("--confirm-global", action="store_true",
                   help="required to write ~/.claude/settings.json (user scope)")
    p.add_argument("--dry-run", action="store_true",
                   help="print the diff and exit without writing")
    p.add_argument("--repo-root", default=None,
                   help="project root for project scope (default: cwd)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except Refused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    except IOErrorSanitized as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
