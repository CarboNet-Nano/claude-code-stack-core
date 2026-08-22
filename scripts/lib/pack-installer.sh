#!/usr/bin/env bash
# Tenant-pack install logic (M3, ADR-034). Sourced by install.sh.
# Requires config-merger.sh (merge_json_pack_wins) and pack-lint.sh
# (lint_pack_deltas) to be sourced alongside.
#
# Callers run these functions with errexit suppressed (`if ! install_pack`),
# so every fallible step is checked explicitly — never rely on set -e here.

# po_copy_up (overlay model) — self-sourced so install_pack's copy-up-before-
# write calls work whether or not the caller already sourced this.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profile-overlay.sh"

# Splits an optional @ref off a git pack spec: echoes "<url>|<ref>".
# The ref is split from the RIGHT, only when the suffix contains no "/" and,
# for scp-style git@host:org/repo.git@v1, at least one "@" remains in the URL
# part. Ref must match ^[A-Za-z0-9._-]+$. Do not "simplify" the right-split
# rule — it is what keeps git@host:org/repo.git (no ref) intact. Known limit
# (accepted, plan §6.4): slash refs like feat/x cannot be expressed — they are
# indistinguishable from the URL tail; use a tag or simple branch name.
parse_pack_ref() {
  local spec="$1"
  local url="$spec" ref=""
  local candidate_ref="${spec##*@}"
  local candidate_url="${spec%@*}"
  if [[ "$spec" == *"@"* ]] \
    && [[ "$candidate_ref" != */* ]] \
    && [[ "$candidate_ref" =~ ^[A-Za-z0-9._-]+$ ]] \
    && { [[ "$candidate_url" != git@* ]] || [[ "$candidate_url" == *"@"* ]]; }; then
    url="$candidate_url"
    ref="$candidate_ref"
  fi
  echo "$url|$ref"
}

# ci_template_dest_allowed <dest> -> 0 iff <dest> is a GitHub Actions workflow
# path: .github/workflows/<name>.yml|.yaml, no subdirectories. Without this, a
# pack's ci_templates.dest could target any clean relative path in the repo
# (e.g. .git/config or package.json) for a write-what-where RCE — see
# security-report.md 2026-08-04, CRITICAL. Shared by validate_pack (Phase 0,
# here) and vendor_tenant_ci_templates (actual write, project-pack-vendor.sh).
ci_template_dest_allowed() {
  local dest="$1"
  [[ "$dest" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]]
}

# Strips userinfo (user:token@) out of an https/ssh URL, and redacts common
# credential-bearing query-string params, so credential-bearing specs are
# never logged or persisted to stamps/defaults. security-report.md
# 2026-08-04 (MEDIUM): the https-only userinfo strip missed ssh://user:pass@
# and query-string tokens (?access_token=...) — both handled now.
sanitize_pack_source() {
  local url="$1"
  if [[ "$url" == https://*@* ]]; then
    url="https://${url#https://*@}"
  elif [[ "$url" == ssh://*@* ]]; then
    url="ssh://${url#ssh://*@}"
  fi
  echo "$url" | sed -E 's/([?&])(access_token|token|password|key|secret)=[^&]*/\1\2=REDACTED/g'
}

# Parses a --pack spec into "<local_dir>|<source>|<ref>" on stdout.
# Existing directory -> local path mode (no clone). Otherwise git mode; the
# clone lands in a mktemp dir the caller owns (and must clean up).
resolve_pack_source() {
  local spec="$1"

  if [[ "$spec" == -* ]]; then
    echo "  [pack-fail] Pack spec may not start with '-': $spec" >&2
    return 1
  fi

  if [[ -d "$spec" ]]; then
    echo "$spec|$spec|"
    return 0
  fi

  local url ref
  IFS='|' read -r url ref <<< "$(parse_pack_ref "$spec")"

  local clone_dir
  clone_dir="$(mktemp -d)" || return 1

  local -a git_args=(clone --depth 1)
  [[ -n "$ref" ]] && git_args+=(--branch "$ref")

  # Token goes through GIT_CONFIG_* env vars, never argv (invisible to ps /
  # xtrace) and never interpolated into a logged URL (ADR-034 §1). By design
  # the token is NEVER persisted anywhere (stack-defaults.json only ever
  # records the credential-stripped URL via sanitize_pack_source below) — so
  # a private-HTTPS pack needs this env var present again at EVERY future
  # resolution, including ADR-083 D6's recorded-pack re-resolution on a
  # plain `update.sh` with no `--pack`. If it's absent then, the clone below
  # fails exactly like a first-time missing token would, with a hint added
  # for that case (not silent, but easy to miss without this comment).
  local token="${CLAUDE_STACK_PACK_TOKEN:-${CLAUDE_STACK_REPO_TOKEN:-}}"
  local -a auth_env=()
  if [[ -n "$token" && "$url" == https://* ]]; then
    local b64
    b64="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    auth_env=(GIT_CONFIG_COUNT=1
      GIT_CONFIG_KEY_0=http.extraheader
      "GIT_CONFIG_VALUE_0=Authorization: basic $b64")
  fi

  if ! env GIT_TERMINAL_PROMPT=0 ${auth_env[@]+"${auth_env[@]}"} \
      git "${git_args[@]}" -- "$url" "$clone_dir" >/dev/null 2>&1; then
    rm -rf "$clone_dir"
    echo "  [pack-fail] Could not clone $(sanitize_pack_source "$url")${ref:+ @$ref}" >&2
    if [[ "$url" == https://* && -z "$token" ]]; then
      echo "  If this is a private pack repo: its credential is never" >&2
      echo "  stored (only the URL is), so set CLAUDE_STACK_PACK_TOKEN or" >&2
      echo "  CLAUDE_STACK_REPO_TOKEN before every install/update that" >&2
      echo "  resolves it, including an automatic recorded-pack" >&2
      echo "  re-resolution with no --pack (ADR-083 D6)." >&2
    fi
    return 1
  fi

  echo "$clone_dir|$(sanitize_pack_source "$url")|$ref"
}

# _validate_pack_aliases_org <org_file> <pack_dir> <core_repo_root>
# ADR-083 D8/D13 — Phase-0 hard-deny for a pack's config/aliases.org.json.
# A target may be a skill the pack itself ships (D7's /docs -> /acme-handbook
# example) as well as a core skill, so both trees are checked. Word/target
# validity mirrors gen-alias-stubs.sh's own validation (defense in depth —
# this runs before land_pack; gen-alias-stubs.sh runs again at generation
# time against whatever actually landed).
_validate_pack_aliases_org() {
  local org_file="$1" pack_dir="$2" core_repo_root="$3"

  python3 - "$org_file" "$pack_dir" "$core_repo_root" <<'PYEOF'
import sys, os, re, json, glob

org_file, pack_dir, core_repo_root = sys.argv[1:4]


def fail(msg):
    print(f'  [pack-fail] {msg}', file=sys.stderr)
    sys.exit(1)


try:
    with open(org_file) as f:
        doc = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    fail(f'config/aliases.org.json is malformed: {e}')

if not isinstance(doc, dict):
    fail('config/aliases.org.json: top level must be an object')
extra_top = set(doc.keys()) - {'version', 'aliases'}
if extra_top:
    fail(f'config/aliases.org.json: unknown top-level field(s): {sorted(extra_top)}')
if doc.get('version') != 1:
    fail('config/aliases.org.json: version must be 1')
words = doc.get('aliases')
if not isinstance(words, dict):
    fail('config/aliases.org.json: "aliases" must be an object')

WORD_RE = re.compile(r'^[a-z][a-z0-9-]{0,31}$')
MODE_RE = re.compile(r'^[a-z][a-z0-9-]{0,15}$')
ALLOWED_ENTRY = {'target', 'disable', 'mode', 'help', 'description', 'tools'}


def skill_ids(root):
    return {os.path.basename(os.path.dirname(p))
            for p in glob.glob(os.path.join(root, 'skills', '*', 'SKILL.md'))}


def agent_ids(root):
    return {os.path.basename(p)[:-3] for p in glob.glob(os.path.join(root, 'agents', '*.md'))}


def target_declares_mode(target, mode):
    for root in (pack_dir, core_repo_root):
        path = os.path.join(root, 'skills', target, 'SKILL.md')
        if os.path.isfile(path):
            with open(path) as f:
                text = f.read()
            m = re.search(r'^## Display modes\s*$(.*?)(^## |\Z)', text, re.MULTILINE | re.DOTALL)
            if m and re.search(rf'\b{re.escape(mode)}\b', m.group(1)):
                return True
    return False


all_skill_ids = skill_ids(core_repo_root) | skill_ids(pack_dir)
all_capability_ids = all_skill_ids | agent_ids(core_repo_root) | agent_ids(pack_dir)

stack_aliases_path = os.path.join(core_repo_root, 'config', 'aliases.json')
promoted_stack_words = set()
stack_alias_words = set()
if os.path.isfile(stack_aliases_path):
    with open(stack_aliases_path) as f:
        stack_doc = json.load(f)
    for w, e in (stack_doc.get('aliases') or {}).items():
        stack_alias_words.add(w)
        if isinstance(e, dict) and e.get('help') == 'row':
            promoted_stack_words.add(w)

for word, entry in words.items():
    if not WORD_RE.match(word):
        fail(f'"{word}" fails ^[a-z][a-z0-9-]{{0,31}}$')
    if not isinstance(entry, dict):
        fail(f'"{word}" entry must be an object')
    extra = set(entry.keys()) - ALLOWED_ENTRY
    if extra:
        fail(f'"{word}" has unknown field(s): {sorted(extra)}')
    if word in promoted_stack_words:
        fail(f'"{word}" is a stack promoted alias — a company pack may never take it over')
    if entry.get('disable'):
        if entry.get('disable') is not True or (set(entry.keys()) - {'disable'}):
            fail(f'"{word}".disable must be the only field, set to true')
        continue
    if entry.get('help') == 'row':
        fail(f'"{word}" sets help:"row" — promoted aliases are stack-only')
    target = entry.get('target')
    if not target:
        fail(f'"{word}" has no target and is not disabled')
    if word in all_capability_ids:
        fail(f'"{word}" collides with an existing capability id')
    if target not in all_skill_ids or target in stack_alias_words:
        fail(f'"{word}" target "{target}" is not a kind:"skill" capability (or is itself an alias — chains are not allowed)')
    mode = entry.get('mode')
    if mode is not None:
        if not MODE_RE.match(mode):
            fail(f'"{word}".mode "{mode}" fails ^[a-z][a-z0-9-]{{0,15}}$')
        if not target_declares_mode(target, mode):
            fail(f'"{word}" sets mode "{mode}" but target "{target}" does not declare it under "## Display modes"')
    tools = entry.get('tools')
    if tools is not None and not isinstance(tools, str):
        fail(f'"{word}".tools must be a string')

sys.exit(0)
PYEOF
}

# Phase 0 — validates a pack WITHOUT writing anything. Run this against the
# resolved source (temp clone or local dir) BEFORE land_pack, so a bad pack
# can never destroy the previously-landed copy (fail closed, zero writes).
validate_pack() {
  local pack_dir="$1"
  local core_repo_root="$2"

  if ! jq -e . "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-fail] tenant.json missing or unparseable" >&2
    return 1
  fi

  # Required fields + patterns (jq checks; the JSON-schema is normative docs +
  # pack-repo CI, not a runtime dependency — Working Principle 8).
  if ! jq -e '
      (.tenant_id | type == "string" and test("^[a-z][a-z0-9-]{1,62}$")) and
      (.pack_version | type == "string" and test("^\\d+\\.\\d+\\.\\d+$")) and
      (.github.org | type == "string" and length > 0) and
      ((.secrets // []) | all(type == "string" and test("^[A-Z][A-Z0-9_]*$")))
    ' "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-fail] tenant.json invalid: requires tenant_id (^[a-z][a-z0-9-]{1,62}\$), pack_version (semver), github.org; secrets must be UPPER_SNAKE names" >&2
    return 1
  fi

  # claude_fragment_path must stay inside the pack: no absolute paths, no
  # traversal, no symlink escaping — otherwise a pack could pull arbitrary
  # local files into ~/.claude/CLAUDE.md.
  local fragment_rel
  fragment_rel="$(jq -r '.claude_fragment_path // "CLAUDE.fragment.md"' "$pack_dir/tenant.json")" || return 1
  if [[ "$fragment_rel" == /* || "$fragment_rel" == *..* ]]; then
    echo "  [pack-fail] claude_fragment_path must be a relative path inside the pack: $fragment_rel" >&2
    return 1
  fi
  if [[ -e "$pack_dir/$fragment_rel" ]]; then
    local pack_real frag_real
    pack_real="$(cd "$pack_dir" && pwd -P)" || return 1
    frag_real="$(cd "$(dirname "$pack_dir/$fragment_rel")" 2>/dev/null && pwd -P)/$(basename "$fragment_rel")" || return 1
    if [[ -L "$pack_dir/$fragment_rel" || "$frag_real" != "$pack_real/"* ]]; then
      echo "  [pack-fail] claude_fragment_path escapes the pack (symlink or traversal): $fragment_rel" >&2
      return 1
    fi
  fi

  # ci_templates (optional): map of name -> {source, dest} (schema:
  # tenant-pack-schema.json). Shape-checked here like every other declared
  # field (Working Principle 8: schema is normative docs + pack-repo CI, not
  # a runtime dependency) — a bad shape must fail Phase 0, before any write.
  if jq -e '(has("ci_templates") and .ci_templates != null)' "$pack_dir/tenant.json" >/dev/null 2>&1; then
    if ! jq -e '
        (.ci_templates | type == "object") and
        (.ci_templates | to_entries | all(
          (.value | type == "object") and
          (.value.source | type == "string" and length > 0) and
          (.value.dest   | type == "string" and length > 0)
        ))
      ' "$pack_dir/tenant.json" >/dev/null 2>&1; then
      echo "  [pack-fail] ci_templates must be an object mapping name -> {source, dest} (both non-empty strings)" >&2
      return 1
    fi
    # Each declared source must stay inside the pack — same traversal/absolute
    # guard as claude_fragment_path above (symlink-escape is re-checked, more
    # strictly, by the vendor step itself against the actual pack dir).
    local ct_name ct_source ct_dest
    while IFS=$'\t' read -r ct_name ct_source ct_dest; do
      [[ -z "$ct_name" ]] && continue
      if [[ "$ct_source" == /* || "$ct_source" == *..* ]]; then
        echo "  [pack-fail] ci_templates.$ct_name.source must be a relative path inside the pack: $ct_source" >&2
        return 1
      fi
      if ! ci_template_dest_allowed "$ct_dest"; then
        echo "  [pack-fail] ci_templates.$ct_name.dest must be a GitHub Actions workflow path (.github/workflows/<name>.yml): $ct_dest" >&2
        return 1
      fi
    done < <(jq -r '.ci_templates // {} | to_entries[] | [.key, .value.source, .value.dest] | @tsv' "$pack_dir/tenant.json" 2>/dev/null)
  fi

  # Every mergeable pack JSON must parse before any compose step runs.
  if [[ -d "$pack_dir/config" ]]; then
    local pack_file
    while IFS= read -r -d '' pack_file; do
      if ! jq -e . "$pack_file" >/dev/null 2>&1; then
        echo "  [pack-fail] invalid JSON in pack: ${pack_file#"$pack_dir"/}" >&2
        return 1
      fi
    done < <(find "$pack_dir/config" -type f -name '*.json' -print0)
  fi

  # Hard-deny (ADR-055): permissions.* and mcpServers.*.command|args are
  # dangerous enough that no pack may ever set them, confirmed or not — a
  # pack-wins merge here could rewrite the operator's own permission
  # enforcement or repoint an MCP server's executed command. Checked against
  # every config/*.json file, not just settings.json, since a pack could put
  # these keys in any filename. hooks.* is deliberately NOT on this list —
  # config-merger.sh's hook-group-merge logic is an existing, tested,
  # designed pack-customization feature; it goes through install_pack's
  # review-and-confirm gate instead (still visible, no longer silent).
  if [[ -d "$pack_dir/config" ]]; then
    local pack_file
    while IFS= read -r -d '' pack_file; do
      if jq -e '
          [paths(scalars)] | any(
            .[0] == "permissions" or
            (.[0] == "mcpServers" and (.[2] == "command" or .[2] == "args"))
          )
        ' "$pack_file" >/dev/null 2>&1; then
        echo "  [pack-fail] pack config sets a hard-denied key (permissions.* or mcpServers.*.command|args) in ${pack_file#"$pack_dir"/} — packs may never touch these (ADR-055)" >&2
        return 1
      fi
    done < <(find "$pack_dir/config" -type f -name '*.json' -print0)
  fi

  # Hard-deny (ADR-055): a pack may never ship (and thus silently replace)
  # the cross-family-review roster's own agent definitions — doing so could
  # drop the adversarial-review requirement those roles exist to enforce
  # (ADR-011).
  if [[ -d "$pack_dir/agents" ]]; then
    local denied_agent
    for denied_agent in reviewer.md security-auditor.md red-team.md product-critic.md architecture-critic.md; do
      if [[ -f "$pack_dir/agents/$denied_agent" ]]; then
        echo "  [pack-fail] pack ships agents/$denied_agent — packs may never replace a cross-family-review roster agent (ADR-055)" >&2
        return 1
      fi
    done
  fi

  # ADR-083 D8 — a pack's config/aliases.org.json (if it ships one) is
  # validated in Phase 0, fail closed, before any write. Word collisions
  # with a real capability, chains, promoted-word takeovers, help:"row",
  # and unknown/malformed shapes are all rejected here; a plain add or a
  # repoint is fine and flows through to the review-and-confirm gate below
  # (D7's printed word-change lines, _install_pack_print_preview).
  if [[ -f "$pack_dir/config/aliases.org.json" ]]; then
    _validate_pack_aliases_org "$pack_dir/config/aliases.org.json" "$pack_dir" "$core_repo_root" || return 1
  fi

  if ! lint_pack_deltas "$pack_dir" "$core_repo_root"; then
    echo "  [pack-fail] deltas-only lint failed — pack ships verbatim core content (ADR-013 amendment)" >&2
    return 1
  fi

  # Secret VALUES never ship in a pack (ADR-034) — cheap mechanical grep.
  local secret_hits
  secret_hits="$(grep -rEl --exclude-dir=.git \
    'sk_live_|sk-ant-|AKIA[0-9A-Z]{16}|-----BEGIN( [A-Z]+)? PRIVATE KEY-----' \
    "$pack_dir" 2>/dev/null || true)"
  if [[ -n "$secret_hits" ]]; then
    echo "  [pack-fail] secret-value shapes found in pack files:" >&2
    echo "$secret_hits" | sed 's/^/    /' >&2
    return 1
  fi

  return 0
}

# Copies a validated pack into its durable home ~/.claude/packs/<tenant_id>/
# (.git/ retained for future ref updates). Callers MUST validate_pack the
# source first — the rsync --delete below replaces the previous landed copy.
# Echoes the landing dir.
land_pack() {
  local src_dir="$1"
  local claude_dir="$2"

  local tenant_id
  tenant_id="$(jq -r '.tenant_id // empty' "$src_dir/tenant.json" 2>/dev/null)" || tenant_id=""
  if [[ ! "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
    echo "  [pack-fail] tenant.json missing or tenant_id invalid" >&2
    return 1
  fi

  local landing="$claude_dir/packs/$tenant_id"
  mkdir -p "$landing" || return 1
  rsync -a --delete "$src_dir/" "$landing/" || return 1
  echo "$landing"
}

# _pack_alias_change_preview <pack_dir> <claude_dir> <core_repo_root>
# ADR-083 D7 — every stack/org collision (a new word, a repoint, a disable,
# OR a REMOVAL) is printed in words before it lands: "alias /docs changes
# (was -> /handbook, now -> /acme-handbook)". "was"/"now" are each word's
# effective resolution — the already-landed aliases.org.json when it names
# the word, else the already-landed (stack) aliases.json, else the stack
# repo's own committed copy (a fresh ~/.claude with no tier-0 install yet),
# else "(none)". A word the OLD landed file named and the pack's NEW one
# drops entirely (not just disables) is shown too — install_pack lands this
# file verbatim (D5: a plain replace, never a merge), so a word missing
# from the pack's new aliases.org.json is a genuine removal on disk, not
# just an absence of an update. (A pack that stops shipping the file at
# all is a different case: install_pack only ever adds/replaces files the
# pack actually contains, so the previously-landed file — and every word in
# it — is untouched; that case prints nothing here because nothing is
# actually changing.)
_pack_alias_change_preview() {
  local pack_dir="$1" claude_dir="$2" core_repo_root="$3"
  local new_org_file="$pack_dir/config/aliases.org.json"
  [[ -f "$new_org_file" ]] || return 0

  python3 - "$new_org_file" \
           "$claude_dir/config/aliases.org.json" \
           "$claude_dir/config/aliases.json" \
           "$core_repo_root/config/aliases.json" >&2 <<'PYEOF'
import sys, json

new_path, old_org_path, old_stack_path, core_stack_path = sys.argv[1:5]


def load(path):
    try:
        with open(path) as f:
            return (json.load(f) or {}).get('aliases') or {}
    except (OSError, json.JSONDecodeError):
        return {}


new_words = load(new_path)
old_org_words = load(old_org_path)
old_stack_words = load(old_stack_path) or load(core_stack_path)


def display(entry):
    if not entry:
        return '(none)'
    if entry.get('disable'):
        return '(disabled)'
    return '/' + entry.get('target', '?')


for word in sorted(new_words):
    new_entry = new_words[word]
    old_entry = old_org_words.get(word) or old_stack_words.get(word)
    new_disp = display(new_entry)
    old_disp = display(old_entry)
    if new_disp != old_disp:
        print(f'  --- alias /{word} changes (was -> {old_disp}, now -> {new_disp}) ---')

# Removals: named in the currently-landed org file, no longer named in the
# pack's new one at all (distinct from an explicit disable, which is a
# "changes" line above, not a removal here).
for word in sorted(set(old_org_words) - set(new_words)):
    old_disp = display(old_org_words[word])
    new_disp = display(old_stack_words.get(word))
    print(f'  --- alias /{word} removed from your company\'s list (was -> {old_disp}, now -> {new_disp}) ---')
PYEOF
}

# _install_pack_print_preview <pack_dir> <claude_dir> <core_repo_root>
# Prints (to stderr) every config-merge override and every skill/agent/
# command file install_pack would add or replace, WITHOUT writing anything.
# Shared by install_pack's review gate (ADR-055) and nothing else.
_install_pack_print_preview() {
  local pack_dir="$1" claude_dir="$2" core_repo_root="$3"

  if [[ -d "$pack_dir/config" ]]; then
    local pack_file rel dest overrides n
    while IFS= read -r -d '' pack_file; do
      rel="${pack_file#"$pack_dir"/config/}"
      # ADR-083 D7 — aliases.org.json never merges (D5: no core counterpart,
      # plain copy) and gets its own word-level preview below instead of the
      # generic JSON-path diff, which would print raw paths a human can't
      # read as "which command changed."
      [[ "$rel" == "aliases.org.json" ]] && continue
      dest="$claude_dir/$rel"
      if [[ -f "$dest" ]]; then
        overrides="$(pack_config_overrides_preview "$pack_file" "$dest")" || continue
        n="$(jq 'length' <<<"$overrides")" || n=0
        if [[ "$n" -gt 0 ]]; then
          echo "  --- $dest ($n value(s) would be overwritten) ---" >&2
          jq -r '.[] | "    \(.path | join(".")): \(.previous) -> \(.pack)"' <<<"$overrides" >&2
        fi
      else
        echo "  --- $dest (new file) ---" >&2
      fi
    done < <(find "$pack_dir/config" -type f -name '*.json' -print0)
  fi

  _pack_alias_change_preview "$pack_dir" "$claude_dir" "$core_repo_root"

  local md_root f rel dest
  for md_root in skills agents commands; do
    [[ -d "$pack_dir/$md_root" ]] || continue
    while IFS= read -r -d '' f; do
      rel="${f#"$pack_dir"/}"
      dest="$claude_dir/$rel"
      if [[ -f "$dest" ]]; then
        echo "  --- $dest (would be REPLACED) ---" >&2
      else
        echo "  --- $dest (new file) ---" >&2
      fi
    done < <(find "$pack_dir/$md_root" -type f -print0)
  done
}

# install_pack <pack_dir> <claude_dir> <core_repo_root> [reviewed]
# Re-runs Phase 0 (validate_pack — cheap, keeps direct callers fail-closed),
# then composes the pack over the installed core with pack-wins semantics
# (ADR-034 §2). Dispatch is by the convention layout (plan §2): config/**/
# *.json merge pack-wins; skills/agents/commands are whole-file payloads
# (including any non-.md files inside them — a replaced skill replaces
# wholesale); standards/ and design/ are consumed later from the landed copy.
# Optional env for the success stamp: PACK_SOURCE, PACK_REF.
#
# Human review gate (ADR-055): validate_pack's hard-deny list (above) stops
# the worst-case overrides outright, but everything else a pack changes
# still needs a human to see it first. Without the literal fourth argument
# "reviewed", this function prints every pending change via
# _install_pack_print_preview and returns 1 without writing anything.
install_pack() {
  local pack_dir="$1"
  local claude_dir="$2"
  local core_repo_root="$3"
  local reviewed="${4:-}"

  validate_pack "$pack_dir" "$core_repo_root" || return 1

  local tenant_id pack_version
  tenant_id="$(jq -r '.tenant_id' "$pack_dir/tenant.json")" || return 1
  pack_version="$(jq -r '.pack_version' "$pack_dir/tenant.json")" || return 1

  if [[ "$reviewed" != "reviewed" ]]; then
    _install_pack_print_preview "$pack_dir" "$claude_dir" "$core_repo_root"
    echo "  [pack-install-review-required] review the changes above, then re-run with a fourth argument \"reviewed\" to apply them." >&2
    return 1
  fi

  if [[ -d "$pack_dir/config" ]]; then
    local pack_file rel dest
    while IFS= read -r -d '' pack_file; do
      rel="${pack_file#"$pack_dir"/config/}"
      dest="$claude_dir/$rel"
      # ADR-083 D5 — config/aliases.org.json is the one pack config file
      # whose destination keeps the "config/" segment the rest of this
      # dispatch drops (every other pack config/*.json lands flat under
      # $claude_dir, matching settings.json's own ~/.claude/settings.json
      # placement) — it has no core counterpart and must land at
      # ~/.claude/config/aliases.org.json specifically, verbatim, never
      # merged (D5: provenance, and gen-alias-stubs.sh/stack-help.sh both
      # read it from exactly that path).
      [[ "$rel" == "aliases.org.json" ]] && dest="$claude_dir/config/$rel"
      mkdir -p "$(dirname "$dest")" || return 1
      # IMPORTANT 3: a discarded po_copy_up failure leaves $dest an overlay
      # SYMLINK, and the merge/cp below would then write straight THROUGH it
      # into master — a per-profile pack silently rewriting shared content.
      # Fail the install instead; nothing here is worth writing through.
      # The copy-up rel must be dest-relative — aliases.org.json keeps its
      # "config/" segment (D5 above), so strip $claude_dir/ from $dest.
      if [[ "$claude_dir" != "$HOME/.claude" ]]; then
        if ! po_copy_up "$claude_dir" "${dest#"$claude_dir"/}"; then
          echo "  [pack-fail] copy-up failed for $rel — refusing to write through the overlay link into master" >&2
          return 1
        fi
      fi
      if [[ "$rel" == "aliases.org.json" ]]; then
        cp "$pack_file" "$dest" || return 1
        echo "    [pack-copy] $dest"
      elif [[ -f "$dest" ]]; then
        merge_json_pack_wins "$pack_file" "$dest" || return 1
        echo "    [pack-merge] $dest"
      else
        cp "$pack_file" "$dest" || return 1
        echo "    [pack-copy] $dest"
      fi
    done < <(find "$pack_dir/config" -type f -name '*.json' -print0)
  fi

  local fragment_rel
  fragment_rel="$(jq -r '.claude_fragment_path // "CLAUDE.fragment.md"' "$pack_dir/tenant.json")" || return 1
  if [[ -f "$pack_dir/$fragment_rel" ]]; then
    # IMPORTANT 3: same rule as the config loop — apply_org_overlay_section
    # appends, and appending to a still-linked CLAUDE.md would land the
    # tenant fragment in MASTER's CLAUDE.md for every profile on the box.
    if [[ "$claude_dir" != "$HOME/.claude" ]]; then
      if ! po_copy_up "$claude_dir" "CLAUDE.md"; then
        echo "  [pack-fail] copy-up failed for CLAUDE.md — refusing to append the tenant fragment through the overlay link into master" >&2
        return 1
      fi
    fi
    touch "$claude_dir/CLAUDE.md" || return 1
    apply_org_overlay_section "$pack_dir/$fragment_rel" "$claude_dir/CLAUDE.md" || return 1
    echo "    [pack-overlay] $claude_dir/CLAUDE.md"
  fi

  local md_root f
  for md_root in skills agents commands; do
    [[ -d "$pack_dir/$md_root" ]] || continue
    while IFS= read -r -d '' f; do
      rel="${f#"$pack_dir"/}"
      dest="$claude_dir/$rel"
      if [[ "$claude_dir" != "$HOME/.claude" ]]; then
        local top_entry="${rel#"$md_root"/}"
        top_entry="${top_entry%%/*}"
        # IMPORTANT 3: without this check a failed copy-up leaves the skill/
        # agent/command dir a link into master, and the cp below replaces
        # master's copy for every profile.
        if ! po_copy_up "$claude_dir" "$md_root/$top_entry"; then
          echo "  [pack-fail] copy-up failed for $md_root/$top_entry — refusing to write through the overlay link into master" >&2
          return 1
        fi
      fi
      mkdir -p "$(dirname "$dest")" || return 1
      cp "$f" "$dest" || return 1
      echo "    [pack-copy] $dest"
    done < <(find "$pack_dir/$md_root" -type f -print0)
  done

  local sha
  sha="$(git -C "$pack_dir" rev-parse HEAD 2>/dev/null || echo "")"
  jq -n \
    --arg tenant_id "$tenant_id" \
    --arg pack_version "$pack_version" \
    --arg source "$(sanitize_pack_source "${PACK_SOURCE:-$pack_dir}")" \
    --arg ref "${PACK_REF:-}" \
    --arg sha "$sha" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tenant_id:$tenant_id, pack_version:$pack_version, source:$source, ref:$ref, sha:$sha, installed_at:$at}' \
    > "$pack_dir/.pack-install.json" || return 1

  echo "  Pack $tenant_id@$pack_version composed over core."
}

# Clone of append_stack_section for the tenant overlay region (ADR-013
# amendment #3). The core CLAUDE_CODE_STACK_MANAGED region is never touched;
# both regions coexist and stay independently re-writable.
apply_org_overlay_section() {
  local source="$1"
  local target="$2"

  local marker="<!-- ORG_OVERLAY_MANAGED -->"
  local end_marker="<!-- /ORG_OVERLAY_MANAGED -->"

  # A fragment that embeds either marker string can defeat the re-apply scan
  # below on the NEXT pack update — the awk pass would find the fragment's
  # own embedded end-marker first and close the section early, stranding
  # stale content outside the managed region (security-report.md 2026-08-04,
  # MEDIUM). Refuse up front instead.
  if grep -qF -- "$marker" "$source" 2>/dev/null || grep -qF -- "$end_marker" "$source" 2>/dev/null; then
    echo "  [pack-fail] fragment source embeds an ORG_OVERLAY_MANAGED marker string, refusing: $source" >&2
    return 1
  fi

  if grep -q "$marker" "$target" 2>/dev/null; then
    # A start marker without its end marker would truncate the rest of the
    # file in the replace pass — refuse instead.
    if ! grep -q "$end_marker" "$target"; then
      echo "  [pack-fail] $target has an unclosed ORG_OVERLAY_MANAGED region" >&2
      return 1
    fi
    awk -v source="$source" -v marker="$marker" -v end_marker="$end_marker" '
      BEGIN { in_section = 0 }
      index($0, end_marker) { in_section = 0; print; next }
      index($0, marker) { in_section = 1; print; while ((getline line < source) > 0) print line; next }
      !in_section { print }
    ' "$target" > "$target.new" || return 1
    mv "$target.new" "$target" || return 1
  else
    {
      echo ""
      echo "$marker"
      cat "$source"
      [[ -n "$(tail -c1 "$source")" ]] && echo ""
      echo "$end_marker"
    } >> "$target" || return 1
  fi
}
