#!/usr/bin/env bash
# Claude Code Stack — org reconciler
#
# Ensures every in-scope repo in a GitHub org carries the Path B cloud
# bootstrap (.claude/hooks/cloud-bootstrap.sh + SessionStart wiring +
# portable-core skills), so cloud sessions of those repos self-install the
# stack. Idempotent: opens a PR only where the bootstrap is missing or stale.
#
# Scope = repos in $org tagged with GitHub topic $topic. Delivery = pull
# request per repo. Runs from a GitHub Action in a per-org admin repo (see the
# templates/team-admin/ README) on an hourly cron + manual dispatch.
#
# SAFETY: refuses to open PRs unless config `enabled: true`. Until then it
# forces dry-run (lists intended changes, writes nothing). Manual runs default
# to dry-run too.
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

log() { printf '[reconcile] %s\n' "$*"; }
# Read a flat top-level scalar from the YAML-ish config (no nesting).
cfg() { sed -nE "s/^$1:[[:space:]]*//p" "$CONFIG" | head -n1 | tr -d '\r'; }

[ -f "$CONFIG" ] || { log "ERROR: $CONFIG not found"; exit 1; }
ENABLED="$(cfg enabled)"
ORG="$(cfg org)"
TOPIC="$(cfg topic)"
TIER="$(cfg tier)"; TIER="${TIER:-2}"
BRANCH="$(cfg branch)"; BRANCH="${BRANCH:-chore/claude-stack-bootstrap}"
EXCLUDE="$(cfg exclude)"

[ -z "${GH_TOKEN:-}" ] && { log "ERROR: GH_TOKEN not set (add the STACK_RECONCILE_TOKEN secret)."; exit 1; }
[ -z "$ORG" ] && { log "ERROR: 'org' not set in $CONFIG"; exit 1; }
[ -z "$TOPIC" ] && { log "ERROR: 'topic' not set in $CONFIG"; exit 1; }

# Safety gate.
if [ "$ENABLED" != "true" ]; then
  log "config 'enabled' != true → forcing DRY_RUN (no PRs will be opened)."
  DRY_RUN=true
fi

# Source the bootstrap payload + a version stamp from the public stack.
STACK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$STACK_DIR"; }
trap cleanup EXIT
git clone --depth 1 "$STACK_REPO" "$STACK_DIR/stack" >/dev/null 2>&1 \
  || { log "ERROR: could not clone $STACK_REPO"; exit 1; }
VERSION="$(git -C "$STACK_DIR/stack" rev-parse --short HEAD)"
log "stack version $VERSION; org=$ORG topic=$TOPIC tier=$TIER dry_run=$DRY_RUN"

# In-scope repos: tagged with $topic, not archived. (Portable read — macOS
# ships bash 3.2, which has no `mapfile`.)
REPOS=()
while IFS= read -r _r; do
  [ -n "$_r" ] && REPOS+=("$_r")
done < <(gh search repos --owner "$ORG" --topic "$TOPIC" \
  --limit 1000 --json name --jq '.[].name' 2>/dev/null | sort -u)
log "${#REPOS[@]} repo(s) tagged '$TOPIC'"

is_excluded() { case ",${EXCLUDE// /}," in *",$1,"*) return 0 ;; esac; return 1; }

changed=0 skipped=0 failed=0
[ "${#REPOS[@]}" -eq 0 ] && { log "no repos in scope; nothing to do."; exit 0; }
for repo in "${REPOS[@]}"; do
  [ -z "$repo" ] && continue
  if is_excluded "$repo"; then log "skip $repo (excluded)"; skipped=$((skipped + 1)); continue; fi

  remote_ver="$(gh api "repos/$ORG/$repo/contents/.claude/.stack-bootstrap-version" \
    --jq '.content' 2>/dev/null | base64 --decode 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$remote_ver" = "$VERSION" ]; then
    log "ok $repo (current)"; skipped=$((skipped + 1)); continue
  fi

  log "needs bootstrap: $repo (has '${remote_ver:-none}')"
  if [ "$DRY_RUN" = "true" ]; then changed=$((changed + 1)); continue; fi

  work="$STACK_DIR/work-$repo"
  if ! git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$repo.git" "$work" >/dev/null 2>&1; then
    log "WARN: clone failed $repo"; failed=$((failed + 1)); continue
  fi
  if ( cd "$work"
    default="$(git rev-parse --abbrev-ref HEAD)"
    git checkout -B "$BRANCH" >/dev/null 2>&1
    mkdir -p .claude/hooks .claude/skills
    cp "$STACK_DIR/stack/scripts/cloud-bootstrap.sh" .claude/hooks/cloud-bootstrap.sh
    chmod +x .claude/hooks/cloud-bootstrap.sh
    tmpl="$STACK_DIR/stack/templates/project-cloud-settings.template.json"
    if [ -f .claude/settings.json ]; then
      if ! grep -q 'cloud-bootstrap.sh' .claude/settings.json; then
        jq --slurpfile add "$tmpl" \
          '.hooks.SessionStart = ((.hooks.SessionStart // []) + $add[0].hooks.SessionStart)' \
          .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
      fi
    else
      cp "$tmpl" .claude/settings.json
    fi
    while IFS= read -r s; do
      [ -n "$s" ] && [ ! -d ".claude/skills/$s" ] && cp -r "$STACK_DIR/stack/skills/$s" ".claude/skills/$s"
    done < <(jq -r '.skills[]' "$STACK_DIR/stack/config/portable-core-skills.json")
    # ADR-075: seeding only ever writes when a directory is ABSENT, which is
    # what made every repo a permanently stale fork. Reconcile the ones that
    # already exist, using the clone we already have rather than a second
    # implementation. Refreshed files ride the same commit and PR below.
    if [ -f "$STACK_DIR/stack/lib/portable-core.sh" ]; then
      # shellcheck disable=SC1090
      CLAUDE_PLUGIN_ROOT="$STACK_DIR/stack" . "$STACK_DIR/stack/lib/portable-core.sh" 2>/dev/null || true
      if command -v pc_reconcile >/dev/null 2>&1 || declare -F pc_reconcile >/dev/null 2>&1; then
        CLAUDE_PLUGIN_ROOT="$STACK_DIR/stack" pc_reconcile "$PWD" 1 >/dev/null 2>&1 || true
      fi
    fi
    # Default stack-config.json so the repo is initialized for foreman without a
    # manual /project-init. Tier comes from the admin config. NEVER overwrite an
    # existing one — a repo someone ran /project-init on keeps its own settings.
    cfgtmpl="$STACK_DIR/stack/templates/stack-config.template.json"
    if [ ! -f .claude/stack-config.json ] && [ -f "$cfgtmpl" ]; then
      today="$(date +%F)"
      jq --arg tier "$TIER" --arg d "$today" \
        '.stack_tier = (($tier | gsub("[^0-9]";"")) | tonumber)
         | .created = $d | .last_modified = $d
         | .purpose = "Auto-initialized by the Claude Code Stack org reconciler"' \
        "$cfgtmpl" > .claude/stack-config.json
    fi
    echo "$VERSION" > .claude/.stack-bootstrap-version
    git add .claude
    git -c user.name='claude-stack-bot' -c user.email='claude-stack-bot@users.noreply.github.com' \
      commit -q -m "chore: add Claude Code Stack cloud bootstrap ($VERSION)" || exit 3
    git push -f origin "$BRANCH" >/dev/null 2>&1
    gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
      --title "Add Claude Code Stack cloud bootstrap" \
      --body "Automated by the Claude Code Stack org reconciler. Adds \`.claude/hooks/cloud-bootstrap.sh\` + a SessionStart hook + portable-core skills so this repo's cloud sessions (web/iOS) self-install the stack. Stack version \`$VERSION\`. See https://github.com/bschonbrun/claude-code-stack/blob/main/docs/CLOUD.md" \
      >/dev/null 2>&1 || true
  ); then
    log "PR ready: $repo"; changed=$((changed + 1))
  else
    rc=$?
    if [ "$rc" = "3" ]; then log "ok $repo (no diff)"; skipped=$((skipped + 1)); else log "WARN: failed $repo"; failed=$((failed + 1)); fi
  fi
done

log "done. changed=$changed skipped=$skipped failed=$failed dry_run=$DRY_RUN"
[ "$failed" -gt 0 ] && exit 1 || exit 0
