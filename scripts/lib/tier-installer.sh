#!/usr/bin/env bash
# Per-tier install logic. Sourced by install.sh.

install_tier() {
  local tier="$1"
  local repo_root="$2"
  local target_dir="$3"
  local mode="$4"

  local manifest="$repo_root/config/tier-manifests/tier-$tier.json"

  if [[ ! -f "$manifest" ]]; then
    echo "  [skip] No manifest for tier $tier"
    return 0
  fi

  # Check requirements
  check_tier_requirements "$tier" "$manifest" || return 1

  # Install global files
  local files
  files="$(jq -r '.files.global // [] | .[] | "\(.from)|\(.to)|\(.executable // false)|\(.merge // false)"' "$manifest")"

  while IFS='|' read -r from to executable merge; do
    [[ -z "$from" ]] && continue

    local source_path="$repo_root/$from"
    local dest_path="${to/#\~\/.claude/$target_dir}"

    if [[ ! -e "$source_path" ]]; then
      echo "    [warn] Source missing: $source_path"
      continue
    fi

    mkdir -p "$(dirname "$dest_path")"

    if [[ "$merge" == "true" ]] && [[ -f "$dest_path" ]] && [[ "$dest_path" == *.json ]]; then
      merge_json "$source_path" "$dest_path"
      echo "    [merge] $dest_path"
    elif [[ "$merge" == "true" ]] && [[ -f "$dest_path" ]] && [[ "$dest_path" == *CLAUDE.md ]]; then
      # For CLAUDE.md, append stack section if not present
      append_stack_section "$source_path" "$dest_path"
      echo "    [append] $dest_path"
    else
      cp "$source_path" "$dest_path"
      echo "    [copy] $dest_path"
    fi

    if [[ "$executable" == "true" ]]; then
      chmod +x "$dest_path"
    fi
  done <<< "$files"

  # Recursive directory copies (files.global_dirs). Distinct from the
  # per-file loop above (tier-installer has no recursive copy there by
  # design — every other tier lists each file individually), because some
  # subtrees can't be named file-by-file in a manifest under config/: P1b's
  # vendored database driver dir (tools/pm/src/vendor/**, ADR-060 §D) has
  # the vendored package's name baked into its own subdirectory name, and
  # config/ is one of the trees tools/pm/test's vendor-literal lint scans
  # for that name (a closed allowlist — see that test file). Naming
  # "tools/pm/src/vendor" here (the directory, not its contents or the
  # package subdirectory inside it) never spells the vendored package's
  # name, so the manifest stays outside that lint's blast radius without
  # growing its allowlist.
  local dirs
  dirs="$(jq -r '.files.global_dirs // [] | .[] | "\(.from)|\(.to)"' "$manifest")"

  while IFS='|' read -r from to; do
    [[ -z "$from" ]] && continue

    local dir_source="$repo_root/$from"
    local dir_dest="${to/#\~\/.claude/$target_dir}"

    if [[ ! -d "$dir_source" ]]; then
      echo "    [warn] Source dir missing: $dir_source"
      continue
    fi

    mkdir -p "$(dirname "$dir_dest")"
    rm -rf "$dir_dest"
    cp -R "$dir_source" "$dir_dest"
    echo "    [copy-dir] $dir_dest"

    # Issue #152: a copied vendor directory may carry an UPSTREAM.md
    # recording a per-file sha256 (ADR-060 §D). Recompute-and-compare here —
    # not "does a sha256: line exist" — so a corrupted or tampered vendor
    # copy is refused before install completes, rather than only flagged
    # after the fact by a smoke test. vendor-verify.mjs lives beside this
    # tools/pm source, not inside the copied vendor dir itself, so it is
    # read from the source repo (known-good) even though it checks the
    # freshly-copied destination.
    local vendor_verify_script="$repo_root/tools/pm/src/vendor-verify.mjs"
    if [[ -f "$vendor_verify_script" ]] && command -v node > /dev/null 2>&1; then
      if ! node "$vendor_verify_script" "$dir_dest"; then
        echo "    [FAIL] Vendored driver under $dir_dest failed its checksum check —"
        echo "           see the UPSTREAM.md alongside it for re-vendoring instructions."
        return 1
      fi
    fi
  done <<< "$dirs"

  echo "  Tier $tier files installed."
}

check_tier_requirements() {
  local tier="$1"
  local manifest="$2"

  local reqs
  # advisory (ADR-030): an advisory command requirement WARNS on absence instead
  # of failing the install — for a tool the default config no longer needs (e.g.
  # the codex CLI once codex_transport defaults to api).
  reqs="$(jq -r '.requirements // [] | .[] | "\(.type)|\(.name // .ref // "")|\(.advisory // false)"' "$manifest")"

  while IFS='|' read -r type name advisory; do
    [[ -z "$type" ]] && continue

    case "$type" in
      keychain_item)
        if ! security find-generic-password -s "$name" > /dev/null 2>&1; then
          if [[ -n "${SKIP_REQUIREMENTS:-}" ]]; then
            echo "    [requirement-skip] Keychain item missing: $name"
          else
            echo "    [requirement-fail] Keychain item missing: $name"
            echo "    Add with: security add-generic-password -s '$name' -a \"\$USER\" -w '<value>' -U"
            return 1
          fi
        fi
        ;;
      command)
        if ! command -v "$name" > /dev/null 2>&1; then
          if [[ "$advisory" == "true" ]]; then
            echo "    [requirement-warn] Optional command missing: $name (advisory — not required for the default config; ADR-030)"
          elif [[ -n "${SKIP_REQUIREMENTS:-}" ]]; then
            echo "    [requirement-skip] Command missing: $name"
          else
            echo "    [requirement-fail] Command missing: $name"
            return 1
          fi
        fi
        ;;
      postgres_database|supabase_project)
        # Soft check by design: the stack degrades without a database (the
        # cost-log writer and the PM journal both no-op rather than fail), so a
        # missing one must never block an install. `supabase_project` is the
        # retired spelling, kept so an older manifest still installs.
        echo "    [requirement] Postgres database: $name (optional — writers no-op without it)"
        ;;
    esac
  done <<< "$reqs"

  return 0
}

apply_schemas() {
  local repo_root="$1"
  local tier="$2"

  # Find all schemas referenced in tier manifests up to current tier
  for ((t=0; t<=tier; t++)); do
    local manifest="$repo_root/config/tier-manifests/tier-$t.json"
    [[ -f "$manifest" ]] || continue

    # `apply_to_db` is the current key; `apply_to_supabase` is the retired
    # spelling, still honoured so an older manifest keeps working.
    local schemas
    schemas="$(jq -r '.files.schemas // [] | .[] | select(.apply_to_db or .apply_to_supabase) | .from' "$manifest")"

    while read -r schema; do
      [[ -z "$schema" ]] && continue
      echo "  Applying $schema..."
      apply_one_schema "$repo_root/$schema"
    done <<< "$schemas"
  done
}

# Resolve the org's Postgres connection string, ADR-060 §5 Q3 order:
# env $STACK_DB_URL first, then the macOS Keychain item stack-db-url-<org>.
# Prints the URL on stdout, or nothing. NEVER logs the value.
resolve_db_url() {
  local org="${STACK_ORG:-carbonet}"
  if [[ -n "${STACK_DB_URL:-}" ]]; then
    printf '%s' "$STACK_DB_URL"
    return 0
  fi
  # $USER is set by macOS login but not by Linux containers or CI runners, and
  # `set -u` turns the bare expansion into a hard install failure well before
  # `security` gets a chance to be absent and no-op.
  security find-generic-password -a "${USER:-$(id -un)}" -s "stack-db-url-${org}" -w 2>/dev/null || true
}

apply_one_schema() {
  local schema_path="$1"

  local db_url
  db_url="$(resolve_db_url)"

  if [[ -z "$db_url" ]]; then
    echo "  [skip] no database credential for org '${STACK_ORG:-carbonet}'"
    echo "  Set \$STACK_DB_URL, or apply manually: psql <connection-string> -f $schema_path"
    return
  fi

  if ! command -v psql > /dev/null 2>&1; then
    echo "  [skip] psql not installed — cannot auto-apply"
    echo "  Apply manually: psql \"\$STACK_DB_URL\" -f $schema_path"
    return
  fi

  # Schemas are idempotent by construction (CREATE ... IF NOT EXISTS, DO-block
  # guards), so re-running is safe. ON_ERROR_STOP so a genuine failure is loud
  # rather than a half-applied schema that looks like success.
  if psql "$db_url" -v ON_ERROR_STOP=1 -q -f "$schema_path" > /dev/null 2>&1; then
    echo "  [ok] applied $(basename "$schema_path")"
  else
    echo "  [warn] $(basename "$schema_path") did not apply cleanly"
    echo "  Re-run to see the error: psql \"\$STACK_DB_URL\" -v ON_ERROR_STOP=1 -f $schema_path"
  fi
}

install_ollama() {
  if ! command -v ollama > /dev/null 2>&1; then
    echo "  Installing Ollama via Homebrew..."
    brew install ollama
  else
    echo "  Ollama already installed."
  fi

  echo "  Starting Ollama service..."
  brew services start ollama || ollama serve &

  # Pull models based on system memory
  local memory_gb
  memory_gb="$(sysctl -n hw.memsize | awk '{print int($1/1024/1024/1024)}')"

  echo "  System memory: ${memory_gb}GB"

  echo "  Pulling llama3.2:3b (always)..."
  ollama pull llama3.2:3b

  if [[ "$memory_gb" -ge 16 ]]; then
    echo "  Pulling llama3.1:8b..."
    ollama pull llama3.1:8b
  fi

  if [[ "$memory_gb" -ge 24 ]]; then
    echo "  Pulling qwen2.5-coder:32b..."
    ollama pull qwen2.5-coder:32b
  fi

  if [[ "$memory_gb" -ge 36 ]]; then
    echo "  Pulling llama3.3:70b..."
    ollama pull llama3.3:70b
  fi

  echo "  Ollama install complete."
}
