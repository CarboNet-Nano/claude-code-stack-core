#!/usr/bin/env python3
"""hook-metadata.py — derive `kind:"hook"` capability-registry entries from
hooks/*.sh, their wiring, and the tier manifests (ADR-043 D14).

Stdlib only (no pip), matching gen-capability-registry.sh and
skills/native-settings-edit/native_settings_edit.py.

Usage:
  python3 scripts/lib/hook-metadata.py --repo-root PATH            # JSON array -> stdout
  python3 scripts/lib/hook-metadata.py --repo-root PATH --lint     # validate only; silent on success

--repo-root is REQUIRED. No $0-relative fallback — a fixture run must never
read the real repo.

Reads: hooks/*.sh, hooks/hooks.json, config/settings.global.template.json,
config/settings.tier-1.template.json, config/settings.team.template.json,
config/tier-manifests/tier-*.json — all resolved under --repo-root.

All failures below exit 1 and name the offending file BEFORE any output is
written:
  - hook has no '# summary:' in its leading comment block
  - hook listed in no config/tier-manifests/tier-*.json
  - hook wired in none of the four wiring files
  - a `command` referencing a hook sits under neither `hooks` nor `statusLine`
"""

import argparse
import glob
import json
import os
import re
import sys

WIRING_FILES = (
    ("hooks/hooks.json", ("hooks", "hooks.json")),
    ("config/settings.global.template.json", ("config", "settings.global.template.json")),
    ("config/settings.tier-1.template.json", ("config", "settings.tier-1.template.json")),
    ("config/settings.team.template.json", ("config", "settings.team.template.json")),
)

SUMMARY_RE = re.compile(r'^#\s*summary:\s*(\S.*?)\s*$')


class HookMetadataError(Exception):
    """Any validation failure — exit 1, message already formatted."""


def extract_summary(path):
    """Leading comment block = line 2 through the first line not matching ^#.
    First `# summary:` match wins; value truncated to 200 chars."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    block = []
    for line in lines[1:]:
        if line.startswith("#"):
            block.append(line.rstrip("\n"))
        else:
            break
    for line in block:
        m = SUMMARY_RE.match(line)
        if m:
            return m.group(1)[:200]
    return None


def path_to_str(path):
    out = "$"
    for tok in path:
        if isinstance(tok, int):
            out += f"[{tok}]"
        else:
            out += f".{tok}"
    return out


def collect_commands(node, path=(), ancestors=()):
    """Recursively walk a wiring JSON tree, collecting every string value
    under a key named `command`. Returns list of (path, ancestors, command)."""
    results = []
    if isinstance(node, dict):
        if isinstance(node.get("command"), str):
            results.append((path + ("command",), ancestors + (node,), node["command"]))
        new_ancestors = ancestors + (node,)
        for k, v in node.items():
            results.extend(collect_commands(v, path + (k,), new_ancestors))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            results.extend(collect_commands(v, path + (i,), ancestors))
    return results


def find_matcher(ancestors):
    """Matcher = the `matcher` value of the nearest ancestor object that has
    one. Absent or empty string -> no matcher (not an empty-string entry)."""
    for anc in reversed(ancestors):
        if "matcher" in anc:
            val = anc["matcher"]
            if isinstance(val, str) and val != "":
                return val
            return None
    return None


def find_tier(hook_id, manifest_paths):
    """Lowest N where tier-N.json (filename, not any `tier` field) lists
    "from": "hooks/<id>.sh" under any files.*[] array."""
    candidates = []
    for path in manifest_paths:
        m = re.match(r'^tier-(\d+)\.json$', os.path.basename(path))
        if not m:
            continue
        num = int(m.group(1))
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        files = data.get("files")
        if not isinstance(files, dict):
            continue
        target = f"hooks/{hook_id}.sh"
        found = False
        for arr in files.values():
            if not isinstance(arr, list):
                continue
            for elem in arr:
                if isinstance(elem, dict) and elem.get("from") == target:
                    found = True
                    break
            if found:
                break
        if found:
            candidates.append(num)
    return min(candidates) if candidates else None


def build_entries(repo_root):
    hooks_dir = os.path.join(repo_root, "hooks")
    hook_files = sorted(glob.glob(os.path.join(hooks_dir, "*.sh")))
    hook_ids = [os.path.basename(f)[:-3] for f in hook_files]

    # 1. summaries
    summaries = {}
    for hook_file, hid in zip(hook_files, hook_ids):
        summary = extract_summary(hook_file)
        if summary is None:
            raise HookMetadataError(
                f"FAIL: hooks/{hid}.sh has no '# summary:' line — add one (see ADR-043)"
            )
        summaries[hid] = summary

    # 2. wiring — scan the four wiring files, deriving events/matchers/wired_in
    hook_wiring = {hid: {"events": set(), "matchers": set(), "wired_in": set()} for hid in hook_ids}

    for rel_name, rel_parts in WIRING_FILES:
        abs_path = os.path.join(repo_root, *rel_parts)
        try:
            with open(abs_path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue

        for path, ancestors, cmd in collect_commands(data):
            for hid in hook_ids:
                if f"hooks/{hid}.sh" not in cmd:
                    continue
                if not path or path[0] not in ("hooks", "statusLine"):
                    raise HookMetadataError(
                        f"FAIL: {rel_name}: hooks/{hid}.sh referenced at "
                        f"{path_to_str(path)} — unrecognized container"
                    )
                if path[0] == "statusLine":
                    event = "statusLine"
                elif len(path) >= 2:
                    event = path[1]
                else:
                    raise HookMetadataError(
                        f"FAIL: {rel_name}: hooks/{hid}.sh referenced at "
                        f"{path_to_str(path)} — unrecognized container"
                    )
                matcher = find_matcher(ancestors)
                hook_wiring[hid]["events"].add(event)
                if matcher:
                    hook_wiring[hid]["matchers"].add(matcher)
                hook_wiring[hid]["wired_in"].add(rel_name)

    # 3. every hook must be wired somewhere
    for hid in hook_ids:
        if not hook_wiring[hid]["wired_in"]:
            raise HookMetadataError(
                f"FAIL: hooks/{hid}.sh is not wired in any settings template or hooks.json"
            )

    # 4. tier_min derived from tier manifests
    manifest_paths = sorted(glob.glob(os.path.join(repo_root, "config", "tier-manifests", "tier-*.json")))
    tier_min = {}
    for hid in hook_ids:
        tier = find_tier(hid, manifest_paths)
        if tier is None:
            raise HookMetadataError(
                f"FAIL: hooks/{hid}.sh is in no tier manifest — add it to a tier-N manifest"
            )
        tier_min[hid] = tier

    # 5. assemble entries
    entries = []
    for hid in hook_ids:
        entries.append({
            "id": hid,
            "kind": "hook",
            "summary": summaries[hid],
            "invocation": {"slash": None, "natural_language": None},
            "tier_min": tier_min[hid],
            "user_invocable": False,
            "model_invocable": False,
            "recommendable": False,
            "hook": {
                "path": f"hooks/{hid}.sh",
                "events": sorted(hook_wiring[hid]["events"]),
                "matchers": sorted(hook_wiring[hid]["matchers"]),
                "wired_in": sorted(hook_wiring[hid]["wired_in"]),
            },
        })
    entries.sort(key=lambda e: e["id"])
    return entries


def build_parser():
    p = argparse.ArgumentParser(
        prog="hook-metadata",
        description="Derive kind:\"hook\" capability-registry entries (ADR-043 D14).",
    )
    p.add_argument("--repo-root", required=True, help="repo root (required, never derived from $0)")
    p.add_argument("--lint", action="store_true", help="validate only; silent on success")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        entries = build_entries(args.repo_root)
    except HookMetadataError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if not args.lint:
        print(json.dumps(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
