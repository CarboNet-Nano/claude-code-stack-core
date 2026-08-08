#!/usr/bin/env bash
# publish.sh (ADR-035/next-step #2): bind a tenant's Cloudflare Secrets Store
# secrets into wrangler.toml, then deploy — in ONE bash process, so a bind
# failure hard-aborts BEFORE `wrangler deploy` ever runs (set -e propagates
# the failing `bind_tenant_secrets` call straight to exit, no separate step
# to skip). Invoke this whole script via `bash publish.sh ...` — never source
# it into an interactive session shell (see skills/publish/SKILL.md for the
# bash-vs-zsh gotcha).
#
# Usage: publish.sh [--repo=<path>] [-- <extra wrangler deploy args>]
#   --repo   Target app repo root. Defaults to $PWD. Must contain
#            .claude/stack-config.json (for tenant_id) and wrangler.toml
#            (created if absent).
#
# Tenant resolution is NEVER free-typed on the command line: the tenant_id
# comes only from the target repo's .claude/stack-config.json, and the
# tenant.json it resolves to must already be landed at
# ~/.claude/packs/<tenant_id>/tenant.json (M3 pack installer). This prevents
# binding the wrong tenant's secrets into a deploy.

set -euo pipefail

# Resolve $0 to its real (symlink-free) location before deriving SCRIPT_DIR —
# a symlinked invocation of this script must not let dirname "$0" point at
# an attacker-planted lib directory. Portable manual resolution (no
# readlink -f dependency; macOS's BSD readlink doesn't support it).
_publish_src="$0"
_publish_depth=0
while [[ -L "$_publish_src" ]]; do
  _publish_depth=$((_publish_depth + 1))
  if [[ "$_publish_depth" -gt 40 ]]; then
    echo "  [publish-fail] Symlink chain resolving $0 exceeded 40 hops — refusing (possible cycle)" >&2
    exit 1
  fi
  _publish_link_dir="$(cd -P "$(dirname "$_publish_src")" && pwd)"
  _publish_src="$(readlink "$_publish_src")"
  [[ "$_publish_src" != /* ]] && _publish_src="$_publish_link_dir/$_publish_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_publish_src")" && pwd)"
unset _publish_src _publish_link_dir _publish_depth
source "$SCRIPT_DIR/lib/secret-binder.sh"

REPO_DIR="$PWD"
EXTRA_ARGS=()
parsing_flags=1
for arg in "$@"; do
  if [[ "$parsing_flags" == 1 && "$arg" == "--repo="* ]]; then
    REPO_DIR="${arg#*=}"
    continue
  fi
  if [[ "$parsing_flags" == 1 && "$arg" == "--" ]]; then
    parsing_flags=0
    continue
  fi
  if [[ "$parsing_flags" == 1 ]]; then
    echo "  [publish-fail] Unknown argument: $arg (expected --repo=<path> [-- <wrangler deploy args>])" >&2
    exit 1
  fi
  # Never let a passthrough arg override the bound config — wrangler deploy
  # is always invoked with an explicit --config pointing at the wrangler.toml
  # that was just bind-verified (see below); reject anything that could
  # override it anyway, so the guarantee can't be second-guessed by flag
  # order or a future change to how we invoke wrangler.
  # Don't rely on wrangler rejecting a duplicate --config/--env as the
  # security boundary (fragile across wrangler versions) — reject every
  # spelling wrangler itself accepts: long form, short form, and the
  # glued-equals short form (`-e=prod` parses as `--env=prod`; `-c=*` is the
  # `--config` analog and rejected for the same defense-in-depth reason).
  case "$arg" in
    --config|--config=*|-c|-c=*|--env|--env=*|-e|-e=*|*.toml)
      echo "  [publish-fail] Extra wrangler arg '$arg' can override the bound config or env — rejected" >&2
      exit 1
      ;;
  esac
  EXTRA_ARGS+=("$arg")
done

REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && pwd)" || {
  echo "  [publish-fail] --repo path does not exist: ${REPO_DIR:-<empty>}" >&2
  exit 1
}

STACK_CONFIG="$REPO_DIR/.claude/stack-config.json"
if [[ ! -f "$STACK_CONFIG" ]]; then
  echo "  [requirement-fail] No .claude/stack-config.json in $REPO_DIR — run /project-init first" >&2
  exit 1
fi

TENANT_ID="$(jq -r '.tenant_id // empty' "$STACK_CONFIG" 2>/dev/null || echo "")"
if [[ ! "$TENANT_ID" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
  echo "  [requirement-fail] $STACK_CONFIG has no valid tenant_id — install a tenant pack first (see /project-init)" >&2
  exit 1
fi

TENANT_JSON="$HOME/.claude/packs/$TENANT_ID/tenant.json"
if [[ ! -f "$TENANT_JSON" ]]; then
  echo "  [requirement-fail] No landed tenant pack for '$TENANT_ID': $TENANT_JSON missing — run the pack installer first" >&2
  exit 1
fi

# Cross-check: the path above is DERIVED from TENANT_ID, but secret-binder
# re-reads .tenant_id from INSIDE that file with no equality check of its
# own. A stale/mislanded pack whose .tenant_id doesn't match would bind the
# wrong tenant's CF secrets — fail closed before that can happen.
LANDED_TENANT_ID="$(jq -r '.tenant_id // empty' "$TENANT_JSON" 2>/dev/null || echo "")"
if [[ "$LANDED_TENANT_ID" != "$TENANT_ID" ]]; then
  echo "  [requirement-fail] $TENANT_JSON has .tenant_id '$LANDED_TENANT_ID', expected '$TENANT_ID' (from $STACK_CONFIG) — refusing to bind a mismatched tenant's secrets" >&2
  exit 1
fi

command -v wrangler >/dev/null 2>&1 || {
  echo "  [requirement-fail] wrangler not found on PATH" >&2
  exit 1
}

WRANGLER_TOML="$REPO_DIR/wrangler.toml"

echo "  [publish] Binding tenant '$TENANT_ID' secrets into $WRANGLER_TOML"
bind_tenant_secrets "$TENANT_JSON" "$WRANGLER_TOML"

echo "  [publish] Bind succeeded — deploying"
# Bind needed the CF token; `wrangler deploy` (which can shell out to a
# tenant-controlled build command) does not — unset it from this process's
# environment before spawning wrangler so a build script can't read it back
# out of its own env (same concern as the Pipedream contract doc §6).
TENANT_TOKEN_ENV_NAME="$(echo "$TENANT_ID" | tr 'a-z-' 'A-Z_')_API_TOKEN"
unset "$TENANT_TOKEN_ENV_NAME" CF_API_TOKEN 2>/dev/null || true

# --config is always explicit and points at the file we just bound — this
# is what makes the "you can't deploy an unbound config" guarantee hold
# regardless of what's in EXTRA_ARGS (which is also filtered above).
(cd "$REPO_DIR" && wrangler deploy --config "$WRANGLER_TOML" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")
