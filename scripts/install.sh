#!/usr/bin/env bash
# Claude Code Stack — Master installer
# Usage:
#   ./install.sh --tier=N [--pack=<git-url|path>[@ref]] [--mode=merge|overwrite|fresh] [--include-ollama=laptop] [--skip-requirements]
#
# Examples:
#   ./install.sh --tier=0
#   ./install.sh --tier=5 --include-ollama=laptop
#   ./install.sh --tier=2 --mode=fresh
#   ./install.sh --tier=4 --pack=git@github.com:CarboNet-Nano/carbonet-vibe-coding-standards.git@v1.0.0
#
# --skip-requirements downgrades missing-command / missing-Keychain checks to
# warnings instead of hard failures. Intended for CI, which tests install
# mechanics without the external tools (codex, gemini) the tiers expect.

set -euo pipefail

# Defaults
TIER=""
PACK_SPEC=""
MODE="merge"
INCLUDE_OLLAMA=""
export SKIP_REQUIREMENTS=""

# Parse args
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
    --pack=*) PACK_SPEC="${arg#*=}" ;;
    --mode=*) MODE="${arg#*=}" ;;
    --include-ollama=*) INCLUDE_OLLAMA="${arg#*=}" ;;
    --skip-requirements) SKIP_REQUIREMENTS="1" ;;
    --help) echo "Usage: $0 --tier=N [--pack=<git-url|path>[@ref]] [--mode=merge|overwrite|fresh] [--include-ollama=laptop] [--skip-requirements]"; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [[ -z "$TIER" ]]; then
  echo "Error: --tier required"
  exit 1
fi

if [[ ! "$TIER" =~ ^[0-5]$ ]]; then
  echo "Error: --tier must be 0, 1, 2, 3, 4, or 5"
  exit 1
fi

if [[ ! "$MODE" =~ ^(merge|overwrite|fresh)$ ]]; then
  echo "Error: --mode must be merge, overwrite, or fresh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "==============================================="
echo "Claude Code Stack installer"
echo "Tier: $TIER"
echo "Mode: $MODE"
echo "Source: $REPO_ROOT"
echo "Target: $CLAUDE_DIR"
echo "==============================================="

# Source library functions
source "$SCRIPT_DIR/lib/tier-installer.sh"
source "$SCRIPT_DIR/lib/config-merger.sh"
source "$SCRIPT_DIR/lib/pack-installer.sh"
source "$SCRIPT_DIR/lib/pack-lint.sh"

# Step 1: Backup if mode != fresh (fresh handles its own backup)
if [[ "$MODE" != "fresh" ]]; then
  echo "[1/6] Backing up current ~/.claude/..."
  "$SCRIPT_DIR/backup.sh"
else
  echo "[1/6] Fresh mode: archiving current ~/.claude/ and starting clean..."
  if [[ -d "$CLAUDE_DIR" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    mv "$CLAUDE_DIR" "$HOME/.claude.backup.fresh-$timestamp"
    echo "  Moved to ~/.claude.backup.fresh-$timestamp"
  fi
  mkdir -p "$CLAUDE_DIR"
fi

# Step 2: Install tiers 0 through TIER (cumulative)
echo "[2/6] Installing tiers 0 through $TIER..."
for ((t=0; t<=TIER; t++)); do
  echo "  Tier $t..."
  install_tier "$t" "$REPO_ROOT" "$CLAUDE_DIR" "$MODE"
done

# Step 3: Tenant pack (optional; composes over the installed core — pack-wins,
# ADR-034). Phase-0 failure means zero writes; mid-compose failure is restored
# from the step-1 backup.
PACK_TENANT_ID=""
PACK_VERSION=""
if [[ -n "$PACK_SPEC" ]]; then
  echo "[3/6] Installing tenant pack..."
  resolved="$(resolve_pack_source "$PACK_SPEC")" || exit 1
  IFS='|' read -r pack_src_dir pack_source pack_ref <<< "$resolved"

  # Cloned temp dirs must not leak on any failure path below.
  PACK_TMP_DIR=""
  [[ "$pack_src_dir" != "$PACK_SPEC" ]] && PACK_TMP_DIR="$pack_src_dir"
  cleanup_pack_tmp() { [[ -n "$PACK_TMP_DIR" ]] && rm -rf "$PACK_TMP_DIR"; return 0; }
  trap cleanup_pack_tmp EXIT

  # Phase 0 runs against the resolved source BEFORE landing, so a bad pack
  # never destroys the previously-landed copy (fail closed).
  if ! validate_pack "$pack_src_dir" "$REPO_ROOT"; then
    echo "  Pack rejected before landing — nothing was written."
    exit 1
  fi

  landing="$(land_pack "$pack_src_dir" "$CLAUDE_DIR")" || exit 1
  cleanup_pack_tmp; PACK_TMP_DIR=""; trap - EXIT

  # Dry-run first (ADR-055): install_pack without "reviewed" writes nothing
  # and prints every pending config/skill/agent/command change instead.
  # `|| install_preview_rc=$?` (not a bare `$?` on the next line) is required
  # under this script's `set -e` — a plain nonzero-exit command substitution
  # would abort the script before the exit code could be captured.
  install_preview_rc=0
  install_preview_out="$(PACK_SOURCE="$pack_source" PACK_REF="$pack_ref" \
      install_pack "$landing" "$CLAUDE_DIR" "$REPO_ROOT" 2>&1)" || install_preview_rc=$?
  if [[ "$install_preview_rc" -ne 0 ]]; then
    echo "$install_preview_out"
    if [[ "$install_preview_out" != *"[pack-install-review-required]"* ]]; then
      echo "  Pack compose failed. ~/.claude was backed up in step 1 —"
      echo "  restore with: ls -dt ~/.claude.backup* | head -1"
      exit 1
    fi
    echo ""
    read -r -p "  Apply the changes above? [y/N] " pack_confirm
    if [[ ! "$pack_confirm" =~ ^[Yy]$ ]]; then
      echo "  Pack install cancelled — no changes applied."
      exit 1
    fi
    if ! PACK_SOURCE="$pack_source" PACK_REF="$pack_ref" \
        install_pack "$landing" "$CLAUDE_DIR" "$REPO_ROOT" "reviewed"; then
      echo "  Pack compose failed. ~/.claude was backed up in step 1 —"
      echo "  restore with: ls -dt ~/.claude.backup* | head -1"
      exit 1
    fi
  fi
  PACK_TENANT_ID="$(jq -r '.tenant_id' "$landing/tenant.json")"
  PACK_VERSION="$(jq -r '.pack_version' "$landing/tenant.json")"
  defaults_file="$CLAUDE_DIR/stack-defaults.json"
  if [[ -f "$defaults_file" ]]; then
    if ! jq \
      --arg tenant_id "$PACK_TENANT_ID" \
      --arg source "$pack_source" \
      --arg ref "$pack_ref" \
      --arg pack_version "$PACK_VERSION" \
      --arg path "$landing" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.tenant_pack = {tenant_id:$tenant_id, source:$source, ref:$ref, pack_version:$pack_version, path:$path, installed_at:$at}' \
      "$defaults_file" > "$defaults_file.tmp"; then
      rm -f "$defaults_file.tmp"
      echo "  Error: failed to record tenant_pack in stack-defaults.json"
      exit 1
    fi
    mv "$defaults_file.tmp" "$defaults_file"
  fi
fi

# Step 4: Schemas (Tier 2+)
if [[ "$TIER" -ge 2 ]]; then
  echo "[4/6] Applying Supabase schemas..."
  apply_schemas "$REPO_ROOT" "$TIER"
fi

# Step 5: Ollama (Tier 5 with --include-ollama)
if [[ "$TIER" -ge 5 ]] && [[ "$INCLUDE_OLLAMA" == "laptop" ]]; then
  echo "[5/6] Installing Ollama..."
  install_ollama
fi

# Step 6: Verify
echo "[6/6] Verifying installation..."
"$SCRIPT_DIR/verify.sh" --tier="$TIER" ${SKIP_REQUIREMENTS:+--skip-requirements}

# Record an install stamp so freshness checks (lib/stack-freshness.sh, used by
# /goodmorning and /project-init) can tell whether ~/.claude is behind the
# source repo. Best-effort: skip silently if jq is unavailable.
if command -v jq >/dev/null 2>&1; then
  source_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
  source_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  stack_version="$(jq -r '.stack_version // "unknown"' "$REPO_ROOT/templates/stack-defaults.template.json" 2>/dev/null || echo "unknown")"
  # A core-only re-install (no --pack) must not wipe the recorded pack
  # identity — carry tenant_id/pack_version forward from the prior stamp.
  if [[ -z "$PACK_TENANT_ID" && -f "$CLAUDE_DIR/.stack-install.json" ]]; then
    PACK_TENANT_ID="$(jq -r '.tenant_id // empty' "$CLAUDE_DIR/.stack-install.json" 2>/dev/null || echo "")"
    PACK_VERSION="$(jq -r '.pack_version // empty' "$CLAUDE_DIR/.stack-install.json" 2>/dev/null || echo "")"
  fi
  jq -n \
    --arg ver "$stack_version" \
    --argjson tier "$TIER" \
    --arg sha "$source_sha" \
    --arg branch "$source_branch" \
    --arg repo "$REPO_ROOT" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tenant_id "${PACK_TENANT_ID:-}" \
    --arg pack_version "${PACK_VERSION:-}" \
    '{stack_version:$ver, tier:$tier, source_sha:$sha, source_branch:$branch, source_repo:$repo, installed_at:$at}
     + (if $tenant_id != "" then {tenant_id:$tenant_id, pack_version:$pack_version} else {} end)' \
    > "$CLAUDE_DIR/.stack-install.json"
fi

echo "==============================================="
echo "Install complete. Stack tier $TIER is live."
echo "==============================================="
echo
echo "Next steps:"
echo "  - cd into a project"
echo "  - run /project-init to set tier for that project"
echo "  - open Claude Code; SessionStart hook should fire"
echo
echo "If anything failed, see logs in /tmp/claude-stack-install.log"
