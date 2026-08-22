#!/usr/bin/env bash
# Generate config/capability-registry.json from skills/*/SKILL.md and agents/*.md
#
# Parser: delegates frontmatter extraction to an inline python3 helper (stdlib
# only — no pip install). It handles single-line scalars AND YAML block scalars
# (`|`, `>`) plus indented wrapped continuations, so multi-line `description`
# values are not truncated.
#
# Capability `id` (and a skill's slash command) comes from the SOURCE LOCATION,
# not the frontmatter `name`: skills are invoked by directory name, subagents by
# file name. The frontmatter `name` is treated only as a presence/validity check.
#
# Usage: ./scripts/gen-capability-registry.sh [--repo-root PATH] [--check]
#
# --check: regenerate to a temp file and compare against the committed registry,
#          ignoring the volatile `generated_at` timestamp. Exit 1 on drift (or if
#          the committed registry is missing). This is the CI freshness gate —
#          `git diff` alone cannot be used because `generated_at` changes every run
#          and an untracked registry is invisible to diff.
#
# Hooks (ADR-043 D14): after building skill/subagent entries, this script invokes
# scripts/lib/hook-metadata.py --repo-root "$REPO_ROOT", splices the returned
# kind:"hook" entries into capabilities[], re-sorts by id, and propagates the
# helper's own exit code/stderr on failure. Duplicate-id-across-kinds (D6) is
# checked here, on the merged array, since this is the only place all three
# kinds are visible.
#
# Declared aliases (ADR-083 D9/D10): the top-level `.aliases` map and any
# promoted-alias (`help: "row"`) capabilities[] entries are read from
# config/aliases.json — the stack source only, never a disk scan of
# skills/*/SKILL.md `alias_of:` fields (that field no longer exists). A
# missing config/aliases.json is treated as {} (no aliases), not an error —
# fixture repos with no alias declarations still generate cleanly. A present
# but malformed/invalid file fails the whole run (fail closed, same as any
# other structural registry error).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --check) CHECK=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

STACK_CONFIG="$REPO_ROOT/.claude/stack-config.json"
OUTPUT="$REPO_ROOT/config/capability-registry.json"

# Temp files are script-scoped so the EXIT trap can clean them regardless of
# where execution stops; guarded with :- so the trap is safe under `set -u`.
tmp_caps=""
check_tmp=""
hook_tmp=""
trap 'rm -f "${tmp_caps:-}" "${check_tmp:-}" "${hook_tmp:-}"' EXIT

stack_version() {
  if [[ -f "$STACK_CONFIG" ]]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("stack_version","unknown"))' "$STACK_CONFIG"
  else
    echo "unknown"
  fi
}

# Python extractor — reads (path kind) pairs from argv, writes JSON array to stdout.
PYTHON_EXTRACTOR=$(cat <<'PYEOF'
import sys, re, json, os

KEY_LINE = re.compile(r'^[\w-]+:\s')

def get_field(text, key):
    """Value of a frontmatter field. Handles single-line scalars, YAML block
    scalars (| or >), and indented wrapped continuations."""
    lines = text.split('\n')
    pat = re.compile(rf'^{re.escape(key)}:\s?(.*)$')
    for i, line in enumerate(lines):
        m = pat.match(line)
        if not m:
            continue
        rest = m.group(1).strip()
        # Block scalar indicator: gather indented/blank following lines.
        if re.match(r'^[|>][+-]?\d*$', rest):
            block = []
            for cont in lines[i + 1:]:
                if cont.strip() == '' or cont[:1] in (' ', '\t'):
                    block.append(cont.strip())
                else:
                    break
            return ' '.join(block).strip() or None
        # Plain scalar, possibly continued on indented non-key lines.
        parts = [rest] if rest else []
        for cont in lines[i + 1:]:
            if cont[:1] in (' ', '\t') and cont.strip() and not KEY_LINE.match(cont.strip()):
                parts.append(cont.strip())
            else:
                break
        val = ' '.join(parts).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        return val or None
    return None

def first_sentence(text):
    if not text:
        return ''
    s = re.split(r'\.\s+', text)[0].strip()
    return s + '.' if s and not s.endswith('.') else s

def natural_language(cid, description):
    nl_name = cid.replace('-', ' ')
    if not description:
        return f'use {nl_name}'
    snippet = re.split(r'\.\s+', description)[0].strip().rstrip('.')
    if not snippet:
        return f'use {nl_name}'
    words = snippet.split()
    if words and words[0].isupper() and len(words[0]) > 1:
        return snippet  # leave acronym-leading phrases (ADR, UI, CI) intact
    return snippet[0].lower() + snippet[1:]

def truthy(val, default):
    if val is None:
        return default
    return val.lower() not in ('false', '0', 'no')

# Meta capabilities never recommend themselves; overridable per-file via
# `recommendable: false` frontmatter.
NON_RECOMMENDABLE = {'recommend-capabilities', 'stack-config', 'config'}

def capability_id(file_path, kind):
    if kind == 'skill':
        return os.path.basename(os.path.dirname(file_path))
    return os.path.basename(file_path)[:-3] if file_path.endswith('.md') else os.path.basename(file_path)

aliases_path = sys.argv[1]
args = sys.argv[2:]
file_pairs = [(args[i], args[i + 1]) for i in range(0, len(args), 2)]

entries = []
for file_path, kind in file_pairs:
    try:
        with open(file_path) as f:
            raw = f.read()
    except OSError:
        continue

    fm_match = re.match(r'^---\n(.*?)\n---', raw, re.DOTALL)
    if not fm_match:
        continue
    fm_text = fm_match.group(1)
    if not get_field(fm_text, 'name'):
        continue  # require a name field as a validity check

    cid = capability_id(file_path, kind)

    description = get_field(fm_text, 'description') or ''

    tier_min_raw = get_field(fm_text, 'tier_min')
    try:
        tier_min = int(tier_min_raw) if tier_min_raw is not None else 0
    except (ValueError, TypeError):
        tier_min = 0

    recommendable_raw = get_field(fm_text, 'recommendable')
    recommendable = truthy(recommendable_raw, cid not in NON_RECOMMENDABLE)

    entries.append({
        'id': cid,
        'kind': kind,
        'summary': first_sentence(description),
        'invocation': {
            'slash': f'/{cid}' if kind == 'skill' else None,
            'natural_language': natural_language(cid, description),
        },
        'tier_min': tier_min,
        'user_invocable': truthy(get_field(fm_text, 'user-invocable'), kind == 'skill'),
        'model_invocable': truthy(get_field(fm_text, 'model-invocable'), True),
        'recommendable': recommendable,
    })

# ADR-083 D9/D10 — declared aliases (stack source only). A suffix entry
# (help omitted or "suffix") becomes a word->target row in the top-level
# `aliases` map. A promoted entry (help: "row") gets its own synthesized
# capabilities[] entry — its own help row and registry id — because a
# promoted alias needs a help-groups membership a stub file alone can't
# carry (D10). `disable: true` resolves the word to nothing at all.
WORD_RE = re.compile(r'^[a-z][a-z0-9-]{0,31}$')
skill_ids = {e['id'] for e in entries if e['kind'] == 'skill'}
skill_tier_min = {e['id']: e['tier_min'] for e in entries if e['kind'] == 'skill'}

aliases = {}
try:
    with open(aliases_path) as f:
        alias_doc = json.load(f)
except FileNotFoundError:
    alias_doc = {'version': 1, 'aliases': {}}
except (OSError, json.JSONDecodeError) as e:
    print(f'FAIL: config/aliases.json is malformed: {e}', file=sys.stderr)
    sys.exit(1)

if alias_doc.get('version') != 1:
    print('FAIL: config/aliases.json: version must be 1', file=sys.stderr)
    sys.exit(1)
alias_words = alias_doc.get('aliases')
if not isinstance(alias_words, dict):
    print('FAIL: config/aliases.json: "aliases" must be an object', file=sys.stderr)
    sys.exit(1)
if set(alias_doc.keys()) - {'version', 'aliases'}:
    print(f'FAIL: config/aliases.json: unknown top-level field(s): {sorted(set(alias_doc.keys()) - {"version", "aliases"})}', file=sys.stderr)
    sys.exit(1)

ALLOWED_ENTRY_FIELDS = {'target', 'disable', 'mode', 'help', 'description', 'tools'}
for word, entry in alias_words.items():
    if not WORD_RE.match(word):
        print(f'FAIL: config/aliases.json: word "{word}" fails ^[a-z][a-z0-9-]{{0,31}}$', file=sys.stderr)
        sys.exit(1)
    if not isinstance(entry, dict):
        print(f'FAIL: config/aliases.json: entry for "{word}" must be an object', file=sys.stderr)
        sys.exit(1)
    extra = set(entry.keys()) - ALLOWED_ENTRY_FIELDS
    if extra:
        print(f'FAIL: config/aliases.json: "{word}" has unknown field(s): {sorted(extra)}', file=sys.stderr)
        sys.exit(1)
    if entry.get('disable'):
        if entry.get('disable') is not True or (set(entry.keys()) - {'disable'}):
            print(f'FAIL: config/aliases.json: "{word}".disable must be the only field, set to true', file=sys.stderr)
            sys.exit(1)
        continue
    target = entry.get('target')
    if not target:
        print(f'FAIL: config/aliases.json: "{word}" has no target and is not disabled', file=sys.stderr)
        sys.exit(1)
    if word in skill_ids or word in {e['id'] for e in entries}:
        print(f'FAIL: config/aliases.json: word "{word}" collides with an existing capability id', file=sys.stderr)
        sys.exit(1)
    if target not in skill_ids:
        print(f'FAIL: config/aliases.json: "{word}" target "{target}" is not a kind:"skill" capability (or is itself an alias)', file=sys.stderr)
        sys.exit(1)
    help_kind = entry.get('help', 'suffix')
    if help_kind not in ('suffix', 'row'):
        print(f'FAIL: config/aliases.json: "{word}".help must be "suffix" or "row"', file=sys.stderr)
        sys.exit(1)
    if help_kind == 'row':
        desc = entry.get('description')
        if not desc or '\n' in desc:
            print(f'FAIL: config/aliases.json: "{word}" has help:"row" and needs a single-line description', file=sys.stderr)
            sys.exit(1)
        entries.append({
            'id': word,
            'kind': 'skill',
            'summary': first_sentence(desc),
            'invocation': {
                'slash': f'/{word}',
                'natural_language': natural_language(word, desc),
            },
            'tier_min': skill_tier_min[target],
            'user_invocable': True,
            'model_invocable': False,
            'recommendable': True,
        })
    else:
        aliases[word] = target

entries.sort(key=lambda e: e['id'])
aliases_sorted = dict(sorted(aliases.items()))
print(json.dumps({'capabilities': entries, 'aliases': aliases_sorted}))
PYEOF
)

main() {
  local version generated_at
  version=$(stack_version)
  generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local args=()
  for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
    [[ -f "$skill_file" ]] && args+=("$skill_file" "skill")
  done
  for agent_file in "$REPO_ROOT"/agents/*.md; do
    [[ -f "$agent_file" ]] && args+=("$agent_file" "subagent")
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    echo "FAIL: no skills/*/SKILL.md or agents/*.md found under $REPO_ROOT — refusing to write an empty registry" >&2
    exit 1
  fi

  tmp_caps=$(mktemp)

  local dest="$OUTPUT"
  if [[ "$CHECK" == true ]]; then
    check_tmp=$(mktemp)
    dest="$check_tmp"
  fi

  python3 -c "$PYTHON_EXTRACTOR" "$REPO_ROOT/config/aliases.json" "${args[@]}" > "$tmp_caps"

  # ADR-043 D14 — derive hook entries via the standalone helper, splice them
  # into capabilities[], re-sort by id, and fail with its own exit code/stderr
  # if it fails.
  hook_tmp=$(mktemp)
  python3 "$SCRIPT_DIR/lib/hook-metadata.py" --repo-root "$REPO_ROOT" > "$hook_tmp"

  python3 - "$tmp_caps" "$hook_tmp" <<'PYEOF_MERGE'
import sys, json

caps_path, hooks_path = sys.argv[1], sys.argv[2]

with open(caps_path) as f:
    data = json.load(f)
caps = data['capabilities']
aliases = data.get('aliases', {})
with open(hooks_path) as f:
    hooks = json.load(f)

merged = caps + hooks
merged.sort(key=lambda e: e['id'])

# D6 — duplicate id across kinds. Stable sort keeps the first-seen kind ahead
# of a later entry sharing the same id.
seen = {}
for entry in merged:
    cid = entry['id']
    if cid in seen:
        print(f"FAIL: duplicate capability id '{cid}' ({seen[cid]} and {entry['kind']})", file=sys.stderr)
        sys.exit(1)
    seen[cid] = entry['kind']

with open(caps_path, 'w') as f:
    json.dump({'capabilities': merged, 'aliases': aliases}, f)
PYEOF_MERGE

  python3 - "$generated_at" "$version" "$dest" "$tmp_caps" "$CHECK" <<'PYEOF2'
import sys, json

generated_at, version, output_path, caps_file, check = sys.argv[1:6]

with open(caps_file) as f:
    data = json.load(f)
capabilities = data['capabilities']
aliases = data.get('aliases', {})

registry = {
    'generated_at': generated_at,
    'stack_version': version,
    'capabilities': capabilities,
    'aliases': aliases,
}

with open(output_path, 'w') as f:
    json.dump(registry, f, indent=2)
    f.write('\n')

if check != 'true':
    print(f"Wrote {len(capabilities)} capabilities to {output_path}")
PYEOF2

  if [[ "$CHECK" == true ]]; then
    local rc=0
    compare_registries "$OUTPUT" "$dest" || rc=$?
    return $rc
  fi
}

# Compare two registries ignoring the volatile generated_at field.
# Exit 0 if content matches; 1 on drift or missing committed file.
compare_registries() {
  local committed="$1" fresh="$2"
  if [[ ! -f "$committed" ]]; then
    echo "FAIL: committed registry missing at $committed — run gen-capability-registry.sh and commit it" >&2
    return 1
  fi
  python3 - "$committed" "$fresh" <<'PYEOF3'
import sys, json

def content(path):
    d = json.load(open(path))
    d.pop('generated_at', None)
    return d

if content(sys.argv[1]) == content(sys.argv[2]):
    print("OK: capability-registry.json is fresh")
    sys.exit(0)
print("FAIL: capability-registry.json is stale — run scripts/gen-capability-registry.sh and commit", file=sys.stderr)
sys.exit(1)
PYEOF3
}

main
