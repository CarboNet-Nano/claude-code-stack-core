#!/usr/bin/env bash
# Claude Code Stack — org reconciler, Job B: tenant pack distribution
# (ADR-034 §5). Sibling to reconcile.sh (Job A / cloud bootstrap).
#
# When a tenant's pack repo bumps `pack_version`, this opens one pull request
# per consuming app repo re-vendoring the pack's `standards/` files into the
# repo (the same layout /project-init lands via vendor_tenant_standards).
# Idempotent: a `.claude/.pack-version` stamp per app repo means a repo already
# on the current pack version is skipped, so no-op runs open no PRs.
#
# Scope = repos in $org tagged with GitHub topic $pack_topic. Delivery = pull
# request per repo. Runs from the same team-admin Action as Job A.
#
# MVP scope is the `standards/` map only (per handoff #5). The pack CLAUDE
# fragment overlay is intentionally NOT re-applied here yet — that is a
# separate follow-up; keeping this job to one responsibility.
#
# SAFETY: refuses to open PRs unless config `enabled: true`. Until then it
# forces dry-run (lists intended changes, writes nothing). Manual runs default
# to dry-run too. No-op (exit 0) when `pack_repo` is unset — Job B is opt-in.
#
# Env:
#   GH_TOKEN    (required)  PAT with, across in-scope repos: Contents: write,
#                           Pull requests: write, plus repo read/metadata.
#   DRY_RUN     true|false  Overridden to true whenever enabled != true.
#   CONFIG      path to config.yml (default: ./config.yml)
#   STACK_REPO  public stack URL (default: github.com/CarboNet-Nano/claude-code-stack-core)

set -euo pipefail

CONFIG="${CONFIG:-config.yml}"
STACK_REPO="${STACK_REPO:-https://github.com/CarboNet-Nano/claude-code-stack-core}"
DRY_RUN="${DRY_RUN:-false}"

log() { printf '[reconcile-packs] %s\n' "$*"; }
cfg() { sed -nE "s/^$1:[[:space:]]*//p" "$CONFIG" | head -n1 | tr -d '\r'; }

# tenant_id: nonempty, [a-z0-9-] only, must start with a letter (matches the
# pattern project-pack-vendor.sh enforces). pack_version: a conservative token
# charset. Both flow into commit/PR text + the committed stamp, so a crafted
# value from a malformed pack must not reach a human-read PR body verbatim.
valid_token() { case "$1" in ''|*[!a-z0-9-]*) return 1 ;; [a-z]*) return 0 ;; *) return 1 ;; esac; }
valid_ver()   { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

command -v jq >/dev/null 2>&1 || { log "ERROR: jq is required"; exit 1; }
[ -f "$CONFIG" ] || { log "ERROR: $CONFIG not found"; exit 1; }

ENABLED="$(cfg enabled)"
ORG="$(cfg org)"
PACK_REPO="$(cfg pack_repo)"
PACK_TOPIC="$(cfg pack_topic)"
BRANCH="$(cfg pack_branch)"; BRANCH="${BRANCH:-chore/claude-stack-pack-update}"
EXCLUDE="$(cfg exclude)"

# Job B is opt-in: no pack_repo configured → nothing to distribute.
[ -z "$PACK_REPO" ] && { log "no 'pack_repo' in $CONFIG → Job B not configured, nothing to do."; exit 0; }

[ -z "${GH_TOKEN:-}" ] && { log "ERROR: GH_TOKEN not set (add the STACK_RECONCILE_TOKEN secret)."; exit 1; }
[ -z "$ORG" ] && { log "ERROR: 'org' not set in $CONFIG"; exit 1; }
[ -z "$PACK_TOPIC" ] && { log "ERROR: 'pack_topic' not set in $CONFIG"; exit 1; }

# Safety gate.
if [ "$ENABLED" != "true" ]; then
  log "config 'enabled' != true → forcing DRY_RUN (no PRs will be opened)."
  DRY_RUN=true
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# The pack repo carries tenant.json (pack_version + standards map). Clone it and
# the stack (for vendor_tenant_standards) shallow.
if ! git clone --depth 1 "$PACK_REPO" "$WORKDIR/pack" >/dev/null 2>&1; then
  log "ERROR: could not clone pack repo $PACK_REPO"; exit 1
fi
if ! git clone --depth 1 "$STACK_REPO" "$WORKDIR/stack" >/dev/null 2>&1; then
  log "ERROR: could not clone $STACK_REPO"; exit 1
fi
# shellcheck source=/dev/null
source "$WORKDIR/stack/scripts/lib/project-pack-vendor.sh"

PACK_DIR="$WORKDIR/pack"
[ -f "$PACK_DIR/tenant.json" ] || { log "ERROR: pack repo has no tenant.json at root"; exit 1; }
TENANT_ID="$(jq -r '.tenant_id // empty' "$PACK_DIR/tenant.json" 2>/dev/null || true)"
PACK_VERSION="$(jq -r '.pack_version // empty' "$PACK_DIR/tenant.json" 2>/dev/null || true)"
[ -n "$TENANT_ID" ]   || { log "ERROR: tenant.json missing tenant_id"; exit 1; }
[ -n "$PACK_VERSION" ] || { log "ERROR: tenant.json missing pack_version"; exit 1; }
valid_token "$TENANT_ID"  || { log "ERROR: tenant_id not [a-z][a-z0-9-]*: $TENANT_ID"; exit 1; }
valid_ver   "$PACK_VERSION" || { log "ERROR: pack_version has invalid characters: $PACK_VERSION"; exit 1; }

# No standards map → nothing for Job B to vendor.
if ! jq -e '(.standards // {}) | length > 0' "$PACK_DIR/tenant.json" >/dev/null 2>&1; then
  log "pack $TENANT_ID has no standards map → nothing to distribute."; exit 0
fi

log "tenant=$TENANT_ID pack_version=$PACK_VERSION org=$ORG topic=$PACK_TOPIC dry_run=$DRY_RUN"

# In-scope repos: tagged with $pack_topic, not archived. (bash 3.2 — no mapfile.)
REPOS=()
while IFS= read -r _r; do
  [ -n "$_r" ] && REPOS+=("$_r")
done < <(gh search repos --owner "$ORG" --topic "$PACK_TOPIC" \
  --limit 1000 --json name --jq '.[].name' 2>/dev/null | sort -u)
log "${#REPOS[@]} repo(s) tagged '$PACK_TOPIC'"

is_excluded() { case ",${EXCLUDE// /}," in *",$1,"*) return 0 ;; esac; return 1; }

changed=0 skipped=0 failed=0
[ "${#REPOS[@]}" -eq 0 ] && { log "no repos in scope; nothing to do."; exit 0; }
for repo in "${REPOS[@]}"; do
  [ -z "$repo" ] && continue
  if is_excluded "$repo"; then log "skip $repo (excluded)"; skipped=$((skipped + 1)); continue; fi

  # Fail CLOSED on a stamp lookup error: only a genuine 404 (stamp absent) means
  # "needs update". Any other API failure (403/5xx/rate-limit) must NOT be read
  # as a missing stamp — that would fail open into a clone+force-push+PR against
  # a repo that may already be current. Such repos are skipped as failures.
  api_err="$WORKDIR/api-err"
  # `|| api_rc=$?` keeps the script's own `set -e` from aborting on a non-zero
  # gh exit (404 is expected) before we can classify it.
  api_rc=0
  resp="$(gh api "repos/$ORG/$repo/contents/.claude/.pack-version" 2>"$api_err")" || api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    if grep -qiE 'not found|http 404|status.*404' "$api_err"; then
      remote_ver=""   # stamp genuinely absent → needs update
    else
      log "WARN: stamp lookup failed for $repo (API error, not 404) — skipping to avoid fail-open"
      failed=$((failed + 1)); continue
    fi
  else
    remote_ver="$(printf '%s' "$resp" | jq -r '.content' 2>/dev/null | base64 --decode 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [ "$remote_ver" = "$PACK_VERSION" ]; then
    log "ok $repo (current: $PACK_VERSION)"; skipped=$((skipped + 1)); continue
  fi

  log "needs pack update: $repo (has '${remote_ver:-none}', want $PACK_VERSION)"
  if [ "$DRY_RUN" = "true" ]; then changed=$((changed + 1)); continue; fi

  work="$WORKDIR/work-$repo"
  if ! git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$repo.git" "$work" >/dev/null 2>&1; then
    log "WARN: clone failed $repo"; failed=$((failed + 1)); continue
  fi
  # Run the mutate+push+PR in a subshell (to contain `cd`) with EXPLICIT `|| exit`
  # on every fallible step, then capture the exit code separately. This subshell
  # is NOT used as an `if` condition — that form disables errexit and would let a
  # failed push still report "PR ready". Distinct codes: 2=git/setup, 3=no diff,
  # 4=push failed, 5=PR neither created nor already open.
  (
    cd "$work" || exit 2
    default="$(git rev-parse --abbrev-ref HEAD)" || exit 2
    # Never force-push onto the repo's default branch — that bypasses the whole
    # PR safety envelope. A pack_branch that equals default is a config error.
    if [ "$BRANCH" = "$default" ]; then
      echo "pack_branch '$BRANCH' equals default branch of $repo" >&2; exit 2
    fi
    git checkout -B "$BRANCH" >/dev/null 2>&1 || exit 2
    # Re-vendor the pack's standards/ (idempotent overwrite; containment-checked
    # inside vendor_tenant_standards). The explicit `git add standards ...` below
    # is also the boundary that keeps a non-standards/ map entry out of the commit.
    vendor_tenant_standards "$PACK_DIR" "$work" || exit 2
    mkdir -p .claude || exit 2
    printf '%s\n' "$PACK_VERSION" > .claude/.pack-version || exit 2
    git add standards .claude/.pack-version || exit 2
    git diff --cached --quiet && exit 3   # nothing changed → no PR needed
    git -c user.name='claude-stack-bot' -c user.email='claude-stack-bot@users.noreply.github.com' \
      commit -q -m "chore: update $TENANT_ID standards to pack $PACK_VERSION" || exit 2
    git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1 || exit 4
    # Create the PR; if creation fails, only accept it when one is already open
    # on this branch (idempotent re-run). Otherwise it's a real failure.
    if ! gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
        --title "Update $TENANT_ID standards to pack $PACK_VERSION" \
        --body "Automated by the Claude Code Stack org reconciler (Job B, ADR-034 §5). Re-vendors the \`$TENANT_ID\` pack's \`standards/\` at pack version \`$PACK_VERSION\`." \
        >/dev/null 2>&1; then
      gh pr list --repo "$ORG/$repo" --head "$BRANCH" --state open --json number \
        --jq '.[0].number' 2>/dev/null | grep -q . || exit 5
    fi
    exit 0
  )
  rc=$?
  if [ "$rc" = "0" ]; then log "PR ready: $repo"; changed=$((changed + 1))
  elif [ "$rc" = "3" ]; then log "ok $repo (no diff)"; skipped=$((skipped + 1))
  else log "WARN: failed $repo (rc=$rc)"; failed=$((failed + 1)); fi
done

log "done. changed=$changed skipped=$skipped failed=$failed dry_run=$DRY_RUN"
[ "$failed" -gt 0 ] && exit 1 || exit 0
