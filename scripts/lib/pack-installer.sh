#!/usr/bin/env bash
# Tenant-pack install logic (M3, ADR-034). Sourced by install.sh.
# Requires config-merger.sh (merge_json_pack_wins) and pack-lint.sh
# (lint_pack_deltas) to be sourced alongside.
#
# Callers run these functions with errexit suppressed (`if ! install_pack`),
# so every fallible step is checked explicitly — never rely on set -e here.

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
  # xtrace) and never interpolated into a logged URL (ADR-034 §1).
  local token="${CLAUDE_STACK_PACK_TOKEN:-${CLAUDE_STACK_REPO_TOKEN:-}}"
  local -a auth_env=()
  if [[ -n "$token" && "$url" == https://* ]]; then
    local b64
    b64="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    auth_env=(GIT_CONFIG_COUNT=1
      GIT_CONFIG_KEY_0=http.extraheader
      "GIT_CONFIG_VALUE_0=Authorization: basic $b64")
  fi

  if ! env GIT_TERMINAL_PROMPT=0 "${auth_env[@]}" \
      git "${git_args[@]}" -- "$url" "$clone_dir" >/dev/null 2>&1; then
    rm -rf "$clone_dir"
    echo "  [pack-fail] Could not clone $(sanitize_pack_source "$url")${ref:+ @$ref}" >&2
    return 1
  fi

  echo "$clone_dir|$(sanitize_pack_source "$url")|$ref"
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

# _install_pack_print_preview <pack_dir> <claude_dir>
# Prints (to stderr) every config-merge override and every skill/agent/
# command file install_pack would add or replace, WITHOUT writing anything.
# Shared by install_pack's review gate (ADR-055) and nothing else.
_install_pack_print_preview() {
  local pack_dir="$1" claude_dir="$2"

  if [[ -d "$pack_dir/config" ]]; then
    local pack_file rel dest overrides n
    while IFS= read -r -d '' pack_file; do
      rel="${pack_file#"$pack_dir"/config/}"
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
    _install_pack_print_preview "$pack_dir" "$claude_dir"
    echo "  [pack-install-review-required] review the changes above, then re-run with a fourth argument \"reviewed\" to apply them." >&2
    return 1
  fi

  if [[ -d "$pack_dir/config" ]]; then
    local pack_file rel dest
    while IFS= read -r -d '' pack_file; do
      rel="${pack_file#"$pack_dir"/config/}"
      dest="$claude_dir/$rel"
      mkdir -p "$(dirname "$dest")" || return 1
      if [[ -f "$dest" ]]; then
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
