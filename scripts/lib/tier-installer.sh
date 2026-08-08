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
    local dest_path="${to/#\~/$HOME}"

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
      supabase_project)
        # Just a soft check — we trust the user knows the project exists
        echo "    [requirement] Supabase project: $name (assumed available)"
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

    local schemas
    schemas="$(jq -r '.files.schemas // [] | .[] | select(.apply_to_supabase) | .from' "$manifest")"

    while read -r schema; do
      [[ -z "$schema" ]] && continue
      echo "  Applying $schema..."
      apply_one_schema "$repo_root/$schema"
    done <<< "$schemas"
  done
}

apply_one_schema() {
  local schema_path="$1"

  # Get Supabase URL + service role key from Keychain
  local supabase_url="${SUPABASE_URL:-}"
  if [[ -z "$supabase_url" ]]; then
    echo "  [skip] SUPABASE_URL not set"
    echo "  Set it: export SUPABASE_URL=https://<your-supabase-ref>.supabase.co"
    return
  fi
  local service_role_key
  service_role_key="$(security find-generic-password -s supabase-service-role-key -w 2>/dev/null || echo '')"

  if [[ -z "$service_role_key" ]]; then
    echo "  [skip] supabase-service-role-key not in Keychain"
    echo "  Apply manually: psql <connection-string> < $schema_path"
    return
  fi

  # Apply via PG REST or psql
  # For now, prompt user to apply manually
  echo "  Schema file: $schema_path"
  echo "  Apply via Supabase SQL Editor or psql. Cannot auto-apply without psql connection string."
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
