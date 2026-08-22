#!/usr/bin/env bash
# Claude Code Stack — Master installer
# Usage:
#   ./install.sh --tier=N [--pack=<git-url|path>[@ref]] [--mode=merge|overwrite|fresh] [--include-ollama=laptop] [--profile=<name>] [--skip-requirements]
#   ./install.sh --migrate-profile=<name>
#
# Examples:
#   ./install.sh --tier=0
#   ./install.sh --tier=5 --include-ollama=laptop
#   ./install.sh --tier=2 --mode=fresh
#   ./install.sh --tier=4 --pack=git@github.com:CarboNet-Nano/carbonet-vibe-coding-standards.git@v1.0.0
#   ./install.sh --tier=2 --profile=teamx
#   ./install.sh --migrate-profile=teamx
#
# --profile=<name> installs tier content into master ~/.claude and builds the
# profile overlay (per-entry symlinks + real config seeds) at ~/.claude-<name>.
# --migrate-profile=<name> converts a hand-made whole-dir symlink farm at
# ~/.claude-<name> to that overlay form, then exits.
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
PROFILE=""
MIGRATE_PROFILE=""
export SKIP_REQUIREMENTS=""

# Parse args
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
    --pack=*) PACK_SPEC="${arg#*=}" ;;
    --mode=*) MODE="${arg#*=}" ;;
    --include-ollama=*) INCLUDE_OLLAMA="${arg#*=}" ;;
    --profile=*) PROFILE="${arg#*=}" ;;
    --migrate-profile=*) MIGRATE_PROFILE="${arg#*=}" ;;
    --skip-requirements) SKIP_REQUIREMENTS="1" ;;
    --help) echo "Usage: $0 --tier=N [--pack=<git-url|path>[@ref]] [--mode=merge|overwrite|fresh] [--include-ollama=laptop] [--profile=<name>] [--migrate-profile=<name>] [--skip-requirements]"; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [[ -z "$MIGRATE_PROFILE" && -z "$TIER" ]]; then
  echo "Error: --tier required"
  exit 1
fi

if [[ -n "$TIER" && ! "$TIER" =~ ^[0-5]$ ]]; then
  echo "Error: --tier must be 0, 1, 2, 3, 4, or 5"
  exit 1
fi

if [[ ! "$MODE" =~ ^(merge|overwrite|fresh)$ ]]; then
  echo "Error: --mode must be merge, overwrite, or fresh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/profile-resolver.sh"

# --migrate-profile short-circuits before any tier install logic: converts a
# hand-made symlink-farm profile (whole-dir links into master) to overlay
# form (per-entry links + real config), then exits. Two-pass shape is a
# security requirement — audit ALL entries before mutating ANY of them.
if [[ -n "$MIGRATE_PROFILE" ]]; then
  pr_validate_name "$MIGRATE_PROFILE" || { echo "Error: invalid profile name"; exit 4; }
  P="$HOME/.claude-$MIGRATE_PROFILE"; M="$HOME/.claude"
  [[ -d "$P" ]] || { echo "Error: $(pr_display_path "$P") does not exist"; exit 4; }
  pr_assert_safe_target "$P" || { echo "Error: refusing $(pr_display_path "$P") — not a real user-owned dir directly under \$HOME"; exit 4; }
  # Master is a target here too — po_build_overlay reads it, po_register and
  # the stamp copy WRITE into it. A symlinked/foreign ~/.claude must be
  # refused with the same gate the profile side gets (M3).
  pr_assert_safe_target "$M" || { echo "Error: refusing master $(pr_display_path "$M") — not a real user-owned dir directly under \$HOME"; exit 4; }
  source "$SCRIPT_DIR/lib/profile-overlay.sh"
  # Pass 1: audit only. A top-level symlink named X is EXPECTED iff (a) X is
  # one of PO_CONTENT_DIRS or CLAUDE.md — the only names po_build_overlay
  # ever creates a top-level link for — AND (b) its target is exactly $M/X.
  # Anything else (outside master, deeper inside master, a mismatched name,
  # or a farm-linked dotfile po_build_overlay doesn't manage) is refused.
  # The removal list is built HERE, from this same enumeration, so pass 2
  # can only ever remove what pass 1 actually verified — never a fresh glob
  # that could see a different (or asymmetric, e.g. dotfile-including-vs-not)
  # set of entries than the audit did.
  refused=0
  to_remove=()
  while IFS= read -r -d '' l; do
    name="$(basename "$l")"
    tgt="$(readlink "$l")"
    expected=0
    if [[ "$name" == "CLAUDE.md" ]]; then
      expected=1
    else
      for d in "${PO_CONTENT_DIRS[@]}"; do
        [[ "$name" == "$d" ]] && { expected=1; break; }
      done
    fi
    if [[ "$expected" -eq 1 && "$tgt" == "$M/$name" ]]; then
      to_remove+=("$l")
    else
      echo "  REFUSED: $(pr_display_path "$l") -> $(pr_display_path "$tgt") (not the whole-dir farm shape)"
      refused=1
    fi
  done < <(find "$P" -maxdepth 1 -type l -print0)
  [[ "$refused" -eq 1 ]] && { echo "Migration refused — fix the entries above and re-run. Nothing was changed."; exit 5; }
  # Pass 2: convert. Remove ONLY the links pass 1 verified, then rebuild.
  # ${to_remove[@]+"${to_remove[@]}"} (not a bare "${to_remove[@]}") because
  # bash 3.2's `set -u` treats expanding an EMPTY array as an unbound
  # variable — a profile with zero farm links (or a second, idempotent run
  # after a clean migration) would abort with "unbound variable" instead of
  # the required no-op exit 0. `${to_remove[@]:-}` is NOT equivalent here:
  # on an empty array it still yields one empty-string element, which would
  # feed `rm ""` into the loop body.
  for l in ${to_remove[@]+"${to_remove[@]}"}; do
    rm "$l"
  done
  po_build_overlay "$M" "$P"
  [[ -f "$P/.stack-install.json" ]] || cp "$M/.stack-install.json" "$P/.stack-install.json" 2>/dev/null || true
  po_register "$P"
  echo "Profile $(pr_display_path "$P") migrated to overlay form."
  exit 0
fi

PROFILE_FROM_ENV=""
if [[ -n "$PROFILE" ]]; then
  pr_validate_name "$PROFILE" || { echo "Error: invalid --profile name (letters/digits/._- only)"; exit 4; }
  CLAUDE_DIR="$HOME/.claude-$PROFILE"
else
  CLAUDE_DIR="$(pr_resolve_dir)" || { echo "Error: CLAUDE_CONFIG_DIR is set to an unsupported path — use --profile=<name> (targets are always \$HOME/.claude-<name>)"; exit 4; }
  # CRITICAL (rev-2 review C1): an ambient CLAUDE_CONFIG_DIR naming a profile
  # is treated EXACTLY as if --profile=<name> had been passed. Tier content
  # must never target a profile dir directly: the per-file `cp` would write
  # THROUGH the overlay's symlinks and clobber master's real files, and the
  # `rm -rf` in tier-installer's global_dirs copy would delete a linked dir
  # and fork the profile off master. This fires without any flag via
  # update.sh on any machine that exports CLAUDE_CONFIG_DIR.
  if [[ "$CLAUDE_DIR" != "$HOME/.claude" ]]; then
    PROFILE="${CLAUDE_DIR#"$HOME/.claude-"}"
    pr_validate_name "$PROFILE" || { echo "Error: CLAUDE_CONFIG_DIR names an invalid profile"; exit 4; }
    PROFILE_FROM_ENV=1
  fi
fi
pr_assert_safe_target "$CLAUDE_DIR" || { echo "Error: refusing target $(pr_display_path "$CLAUDE_DIR") — not a real user-owned dir directly under \$HOME"; exit 4; }
# Propagate the resolved target to child scripts (backup.sh) so they agree
# with this run's target even when --profile (not CLAUDE_CONFIG_DIR) chose it.
export CLAUDE_CONFIG_DIR="$CLAUDE_DIR"

# Overlay model (rev-2 §2 amended): tier content always lands in master
# ~/.claude, never in the profile dir directly. --profile only changes where
# the per-entry overlay (symlinks + real config) is built, after tiers land.
# TIER_TARGET is master's real path even under --profile; CLAUDE_DIR keeps
# meaning "this run's overlay/profile target" for the pack/verify/stamp steps
# below, exactly as before this change.
if [[ -n "$PROFILE" ]]; then
  TIER_TARGET="$HOME/.claude"
  pr_assert_safe_target "$TIER_TARGET" || { echo "Error: refusing master target $(pr_display_path "$TIER_TARGET") — not a real user-owned dir directly under \$HOME"; exit 4; }
else
  TIER_TARGET="$CLAUDE_DIR"
fi

echo "==============================================="
echo "Claude Code Stack installer"
echo "Tier: $TIER"
echo "Mode: $MODE"
echo "Source: $REPO_ROOT"
echo "Target: $CLAUDE_DIR"
[[ -n "$PROFILE_FROM_ENV" ]] && echo "CLAUDE_CONFIG_DIR names profile '$PROFILE' — installing master + refreshing overlay"
[[ -n "$PROFILE" ]] && echo "Tier content installs into: $TIER_TARGET (profile $CLAUDE_DIR overlays it)"
echo "==============================================="

# Source library functions
source "$SCRIPT_DIR/lib/tier-installer.sh"
source "$SCRIPT_DIR/lib/config-merger.sh"
source "$SCRIPT_DIR/lib/pack-installer.sh"
source "$SCRIPT_DIR/lib/pack-lint.sh"
source "$SCRIPT_DIR/lib/profile-overlay.sh"

# Step 1: Backup. The backup must cover the directory this run actually
# MUTATES, which is $TIER_TARGET — under --profile that is master ~/.claude
# (the profile only gains symlinks + config seeds). backup.sh resolves its
# own target from CLAUDE_CONFIG_DIR, and this script exported that as the
# PROFILE dir above, so it is passed explicitly here (IMPORTANT 1: the old
# code backed up the profile while the tier writes hit master, leaving master
# unbacked behind a message that claimed otherwise).
if [[ "$MODE" != "fresh" ]]; then
  echo "[1/7] Backing up current $(pr_display_path "$TIER_TARGET")/..."
  CLAUDE_CONFIG_DIR="$TIER_TARGET" "$SCRIPT_DIR/backup.sh"
else
  echo "[1/7] Fresh mode: archiving current $(pr_display_path "$CLAUDE_DIR")/ and starting clean..."
  if [[ -d "$CLAUDE_DIR" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    pr_assert_safe_target "$CLAUDE_DIR" || { echo "Error: target changed underfoot — aborting"; exit 4; }
    mv "$CLAUDE_DIR" "$HOME/.claude.backup.fresh-$timestamp"
    echo "  Moved to ~/.claude.backup.fresh-$timestamp"
  fi
  mkdir -p "$CLAUDE_DIR"
  # Fresh mode's archive above covers the PROFILE (the --mode=fresh target).
  # Master is still overwritten by the tier loop below and that archive does
  # not cover it, so it gets a real backup of its own.
  if [[ -n "$PROFILE" ]]; then
    echo "  Backing up $(pr_display_path "$TIER_TARGET")/ too (tier content lands there)..."
    CLAUDE_CONFIG_DIR="$TIER_TARGET" "$SCRIPT_DIR/backup.sh"
  fi
fi

# Step 2: Install tiers 0 through TIER (cumulative)
echo "[2/7] Installing tiers 0 through $TIER..."
for ((t=0; t<=TIER; t++)); do
  echo "  Tier $t..."
  install_tier "$t" "$REPO_ROOT" "$TIER_TARGET" "$MODE"
done

# Overlay build (rev-2 §2 amended): only when --profile was given (including
# the ambient-CLAUDE_CONFIG_DIR promotion above). Tier content already landed
# in master ($TIER_TARGET); this creates the profile's per-entry symlinks over
# it and seeds its real config files, then registers the profile so
# `update.sh` can refresh its links after future master updates.
#
# This runs BEFORE the pack step, not after it (IMPORTANT 2). The pack
# composes into $CLAUDE_DIR and relies on po_copy_up turning an overlay link
# into a real file that already holds master's content. With the overlay
# built afterwards instead, a first-run `--profile --pack` produced a profile
# CLAUDE.md (and stack-defaults/settings) containing ONLY the tenant fragment:
# `touch` created a real empty file, the fragment was appended to it, and the
# later overlay build skipped the name because a real entry already existed.
if [[ -n "$PROFILE" ]]; then
  po_build_overlay "$TIER_TARGET" "$CLAUDE_DIR"
  po_merge_settings_fragments "$REPO_ROOT" "$TIER" "$CLAUDE_DIR"
  po_register "$CLAUDE_DIR"
fi

# Step 3: Tenant pack (optional; composes over the installed core — pack-wins,
# ADR-034). Phase-0 failure means zero writes; mid-compose failure is restored
# from the step-1 backup.
#
# ADR-083 D6: when --pack is omitted but stack-defaults.json already records
# a tenant_pack.source (a prior install/update pulled one), re-resolve that
# same source at its recorded ref instead of silently skipping the pack step
# — otherwise publishing an org alias would mean telling every person a new
# ref by hand. Never mid-session (D16): STACK_INSESSION=1 suppresses this,
# since a pack compose can fire ADR-055's confirmation prompt, which the
# in-session plain face never asks. ADR-086 D11 amends this one way: under
# STACK_UPDATE_MODE=hook (the self-update applier's own in-session run),
# re-resolution runs anyway, in no-prompt mode — only the confirmation-class
# subset defers (see the STACK_UPDATE_MODE branch below), so tenant packs
# keep flowing through hook-driven updates instead of being suppressed by
# STACK_INSESSION=1 entirely.
PACK_FROM_RECORD=false
if [[ -z "$PACK_SPEC" && ( "${STACK_INSESSION:-}" != "1" || "${STACK_UPDATE_MODE:-}" == "hook" ) && -f "$CLAUDE_DIR/stack-defaults.json" ]]; then
  recorded_source="$(jq -r '.tenant_pack.source // empty' "$CLAUDE_DIR/stack-defaults.json" 2>/dev/null)"
  if [[ -n "$recorded_source" ]]; then
    recorded_ref="$(jq -r '.tenant_pack.ref // empty' "$CLAUDE_DIR/stack-defaults.json" 2>/dev/null)"
    PACK_SPEC="$recorded_source"
    [[ -n "$recorded_ref" ]] && PACK_SPEC="$PACK_SPEC@$recorded_ref"
    PACK_FROM_RECORD=true
  fi
fi

PACK_TENANT_ID=""
PACK_VERSION=""
if [[ -n "$PACK_SPEC" ]]; then
  echo "[3/7] Installing tenant pack..."
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
    # ADR-083 D6: a recorded-pack re-resolution pinned to a tag that produces
    # no change at all needs no human — "same bytes, empty diff, nothing to
    # confirm." An explicit --pack always confirms, even on an empty diff.
    empty_diff=false
    if [[ "$PACK_FROM_RECORD" == true ]] && ! grep -q '^  --- ' <<< "$install_preview_out"; then
      empty_diff=true
    fi
    pack_deferred=false
    if [[ "$empty_diff" == true ]]; then
      echo "  Recorded pack re-resolved — no changes, nothing to confirm."
    elif [[ "${STACK_UPDATE_MODE:-}" == "hook" ]]; then
      # ADR-086 D11: under the hook-driven applier, pack re-resolution runs
      # in no-prompt mode. A change that needs no ADR-055 confirmation (the
      # empty_diff case above) applies exactly as a human run would; a
      # change that WOULD have prompted is deferred instead of hard-failing
      # this whole run — STACK_INSESSION=1 alone used to fail closed here,
      # which paralyzed tenant-pack distribution on every hook-driven
      # update. Deferring is recorded so it renders instead of vanishing.
      echo "  Pack changes need human review — deferred (STACK_UPDATE_MODE=hook)."
      echo "  Nothing applied. Run install.sh/update.sh from a terminal to"
      echo "  review and apply this pack."
      pack_deferred=true
      mkdir -p "$CLAUDE_DIR/state" 2>/dev/null || true
      jq -n --arg src "$pack_source" --arg ref "$pack_ref" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pack_pending: true, source: $src, ref: $ref, deferred_at: $at}' \
        > "$CLAUDE_DIR/state/pack-pending.json" 2>/dev/null || true
      echo "  [pack-pending] recorded at $(pr_display_path "$CLAUDE_DIR/state/pack-pending.json")"
    elif [[ "${STACK_INSESSION:-}" == "1" ]]; then
      # ADR-083 D16: STACK_INSESSION=1 means this is running mid-session,
      # where nothing may block on stdin (there is no human to answer a
      # `read -r -p`) and no unreviewed pack change may land. D16's own
      # recorded-pack re-resolution path already can't reach this branch
      # (it's suppressed earlier, at PACK_FROM_RECORD's own gate) — this
      # guards the other way in: an explicit --pack passed alongside
      # STACK_INSESSION=1, which D16 never anticipated a caller doing. Fail
      # closed rather than hang or silently apply an unconfirmed diff.
      echo "  Pack changes need human review and cannot be confirmed"
      echo "  mid-session (STACK_INSESSION=1) — nothing was applied."
      echo "  Run install.sh/update.sh outside an active session to review"
      echo "  and apply this pack."
      exit 1
    else
      echo ""
      read -r -p "  Apply the changes above? [y/N] " pack_confirm
      if [[ ! "$pack_confirm" =~ ^[Yy]$ ]]; then
        echo "  Pack install cancelled — no changes applied."
        exit 1
      fi
    fi
    if [[ "$pack_deferred" != true ]]; then
      if ! PACK_SOURCE="$pack_source" PACK_REF="$pack_ref" \
          install_pack "$landing" "$CLAUDE_DIR" "$REPO_ROOT" "reviewed"; then
        echo "  Pack compose failed. ~/.claude was backed up in step 1 —"
        echo "  restore with: ls -dt ~/.claude.backup* | head -1"
        exit 1
      fi
    fi
  fi
  # A deferred pack (ADR-086 D11, above) applied nothing — recording
  # tenant_pack as freshly installed here would be a lie about what this
  # run actually did. The pending marker written above is the honest record;
  # skip PACK_TENANT_ID/PACK_VERSION and the tenant_pack write entirely.
  if [[ "$pack_deferred" != true ]]; then
  PACK_TENANT_ID="$(jq -r '.tenant_id' "$landing/tenant.json")"
  PACK_VERSION="$(jq -r '.pack_version' "$landing/tenant.json")"
  defaults_file="$CLAUDE_DIR/stack-defaults.json"

  # ADR-083 D6 needs tenant_pack recorded regardless of tier — stack-defaults.json
  # otherwise only ships at tier 1 (config/tier-manifests/tier-1.json), so a
  # tier-0 install with --pack used to silently record nothing and D6's
  # recorded-pack re-resolution could never fire for that person. Seed a
  # MINIMAL file here (never the tier-1 template — it carries
  # "<prompted-at-install>" placeholders no code path here ever fills in) so
  # a tier-0-only machine still gets one. tier-1's own manifest row for this
  # file is "merge": true (not a plain copy) specifically so a later upgrade
  # to tier 1 merges the template's defaults IN rather than clobbering this
  # seed — target (already-installed) wins on any scalar conflict, per
  # scripts/lib/config-merger.sh's merge_json.
  if [[ ! -f "$defaults_file" ]]; then
    stack_version_seed="$(jq -r '.stack_version // "unknown"' "$REPO_ROOT/templates/stack-defaults.template.json" 2>/dev/null)" || stack_version_seed="unknown"
    if ! jq -n --arg ver "$stack_version_seed" '{stack_version: $ver}' > "$defaults_file"; then
      echo "  Error: failed to seed $defaults_file to record tenant_pack — aborting rather than skip silently"
      exit 1
    fi
  fi
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
  # A pack actually composed this run — any earlier deferral is now stale.
  rm -f "$CLAUDE_DIR/state/pack-pending.json" 2>/dev/null || true
  fi
fi

# Step 4: Generate declared skill aliases (ADR-083 D16 rule 3 — after tier
# install, so targets exist; after the pack, so an org's aliases.org.json is
# present; before verify, so the smoke tests see the stubs). STACK_INSESSION
# is read by gen-alias-stubs.sh itself (env, not a flag) to suppress purge.
# Stubs are tier-derived content, so they land in master ($TIER_TARGET),
# never the profile — then the overlay is rebuilt so the profile picks up
# links to any stub dirs that did not exist at the step-2 overlay build.
echo "[4/7] Generating declared skill aliases..."
bash "$SCRIPT_DIR/gen-alias-stubs.sh" --repo-root "$REPO_ROOT" --home-root "$TIER_TARGET"
if [[ -n "$PROFILE" ]]; then
  po_build_overlay "$TIER_TARGET" "$CLAUDE_DIR"
fi

# Step 5: Schemas (Tier 2+)
if [[ "$TIER" -ge 2 ]]; then
  echo "[5/7] Applying Supabase schemas..."
  apply_schemas "$REPO_ROOT" "$TIER"
fi

# Step 6: Ollama (Tier 5 with --include-ollama)
if [[ "$TIER" -ge 5 ]] && [[ "$INCLUDE_OLLAMA" == "laptop" ]]; then
  echo "[6/7] Installing Ollama..."
  install_ollama
fi

# ADR-071 D2: the four third-party vendor hosts moved from the tier-1
# template into the per-repo sandbox-policy-compile.sh compiler (they are
# unioned into ~/.claude/settings.json across every prior install/update, and
# config-merger.sh's array merge never subtracts — see scripts/lib/
# config-merger.sh:8, "arrays concatenated (deduped)"). This is a ONE-TIME
# prune of an EXISTING ~/.claude/settings.json, install/update path only
# (unsandboxed, human-invoked, ADR-063 D4) — never run from inside a session.
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [[ -f "$SETTINGS_FILE" ]] && command -v jq >/dev/null 2>&1; then
  PRUNE_TMP="$(mktemp)"
  if jq '
    .sandbox.network.allowedDomains as $d
    | if ($d | type) == "array" then
        .sandbox.network.allowedDomains = ($d - [
          "api.openai.com", "generativelanguage.googleapis.com",
          "api.deepseek.com", "api.x.ai"
        ])
      else . end
  ' "$SETTINGS_FILE" > "$PRUNE_TMP" 2>/dev/null; then
    mv "$PRUNE_TMP" "$SETTINGS_FILE"
  else
    rm -f "$PRUNE_TMP"
    echo "  Warning: could not prune legacy vendor hosts from $SETTINGS_FILE (ADR-071 D2); leaving it unchanged."
  fi
fi

# Step 7: Verify
echo "[7/7] Verifying installation..."
"$SCRIPT_DIR/verify.sh" --tier="$TIER" ${SKIP_REQUIREMENTS:+--skip-requirements}

# Record an install stamp so freshness checks (lib/stack-freshness.sh, used by
# /goodmorning and /project-init) can tell whether ~/.claude is behind the
# source repo. Best-effort: skip silently if jq is unavailable.
if command -v jq >/dev/null 2>&1; then
  # Tier content no longer creates the profile dir as a side effect (it now
  # lands in master). po_build_overlay creates it under --profile, but the
  # non-profile path has no such guarantee — keep the mkdir so the stamp
  # write below always has a directory. Harmless no-op otherwise.
  mkdir -p "$CLAUDE_DIR"
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
  # Overlay model: the profile's own stamp (above, including any pack
  # tenant_id/pack_version) is copied onto master's stamp too, so freshness
  # tooling reading ~/.claude/.stack-install.json directly still sees a
  # recent install rather than a stale/missing one.
  [[ -n "$PROFILE" ]] && cp "$CLAUDE_DIR/.stack-install.json" "$TIER_TARGET/.stack-install.json"

  # ADR-086 D10/D16 — write/refresh the stack-update-pin/v2 pin at the same
  # point the stamp above is written. `hooks/` is one of PO_CONTENT_DIRS (a
  # shared, symlinked directory under every profile overlay), so there is
  # exactly one physical pin file regardless of --profile: it always lives
  # under $TIER_TARGET (master — the only place tier content, including
  # hooks/, is ever installed; see the TIER_TARGET assignment above).
  # Best-effort: skip silently if there's no `origin` remote (e.g. a repo
  # cloned without one) rather than leave a malformed pin.
  pin_source_repo="$(cd "$REPO_ROOT" && pwd -P)"
  pin_remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
  if [[ -n "$pin_remote_url" ]]; then
    mkdir -p "$TIER_TARGET/hooks"
    jq -n \
      --arg repo "$pin_source_repo" \
      --arg remote "$pin_remote_url" \
      --argjson tier "$TIER" \
      '{schema: "stack-update-pin/v2", source_repo: $repo, remote_url: $remote, tier: $tier}' \
      > "$TIER_TARGET/hooks/stack-update.pin.json"
  fi
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
