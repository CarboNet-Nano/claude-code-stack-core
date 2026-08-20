#!/usr/bin/env bash
# Mirror-sync — ADR-036 Job A: one-way snapshot sync of the scrubbed core to
# a downstream tenant mirror repo (CarboNet license-cutoff control). Job B
# (pack -> app-repo PRs, ADR-034 §5) is explicitly deferred — this is
# snapshot-only, no history rewrite, no filter-repo dependency.
#
# Mechanism: `git archive` the requested ref (honors .gitattributes
# export-ignore — the normative scrub allowlist-by-exclusion, see
# .gitattributes), scrub-guard the resulting tree (scripts/lib/mirror-scrub.sh,
# defense-in-depth), then commit it as ONE fresh, parentless snapshot commit
# and force-push it onto the mirror repo's `main`. This is a frozen-copy
# mirror (ADR-036), not a history mirror: the mirror never accumulates the
# core's real commit history.
#
# Usage:
#   ./scripts/mirror-sync.sh --dest <git-url> [--ref <ref>] [--dry-run]
#
#   --dest <git-url>   required. Mirror repo remote — MUST be https://.
#                       Name mirror repos with an explicit "-mirror" suffix
#                       (ADR-036 Q4).
#   --ref <ref>        ref to archive. Default: HEAD.
#   --dry-run          produce + scrub the tree, skip the commit/push.
#
# --dest is https:// only, rejected otherwise. An ssh://... or scp-style
# git@host:path dest would silently fall through to whatever SSH identity
# happens to be ambient on the runner (wrong-identity risk, not fail-closed)
# instead of the App-minted token below — MVP scope is App-token/https only
# (ADR-036 explicitly rejects hand-minted PATs; a GitHub App mints its own
# short-lived install token, which only speaks https).
#
# ENV:
#   LADE_MIRROR_PUSH_TOKEN   required for a real (non-dry-run) push. Sent via
#                            git's http.extraheader as an HTTP Basic auth
#                            header — never in argv, never interpolated into
#                            a logged URL (same pattern as
#                            scripts/lib/pack-installer.sh's clone auth,
#                            company-prefixed per house naming rule). This
#                            script is App-vs-PAT agnostic: it only cares
#                            that a token is in this env var. The workflow
#                            (.github/workflows/mirror-sync.yml) mints it
#                            per run via actions/create-github-app-token.
#
# EXIT: 0 = pushed (or --dry-run clean). Nonzero = scrub violation, non-https
# dest, missing token, or push failure. Fails closed.

set -euo pipefail

DEST=""
REF="HEAD"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    --help)
      echo "Usage: $0 --dest <git-url> [--ref <ref>] [--dry-run]"
      exit 0
      ;;
    *)
      echo "[mirror-sync-fail] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DEST" ]]; then
  echo "[mirror-sync-fail] --dest <git-url> is required" >&2
  exit 1
fi

if [[ "$DEST" != https://* ]]; then
  echo "[mirror-sync-fail] --dest must be an https:// URL (got: $DEST)." \
    "MVP is App-token/https only — an ssh:// or git@host:path dest would" \
    "silently use ambient SSH identity instead of the App-minted token." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '[mirror-sync] %s\n' "$*" >&2; }

source "$SCRIPT_DIR/lib/mirror-scrub.sh"

if [[ "$DRY_RUN" != "1" && -z "${LADE_MIRROR_PUSH_TOKEN:-}" ]]; then
  echo "[mirror-sync-fail] LADE_MIRROR_PUSH_TOKEN is not set. Set it before a" \
    "real (non-dry-run) push, e.g.: export LADE_MIRROR_PUSH_TOKEN=<mirror push token>" >&2
  exit 1
fi

SHA="$(git -C "$REPO_ROOT" rev-parse "$REF")" \
  || { echo "[mirror-sync-fail] cannot resolve ref: $REF" >&2; exit 1; }

WORK="$(mktemp -d)"
# Retry-tolerant: a straggling git child could recreate files under
# $WORK/tree/.git mid-delete, and a failing EXIT trap would overwrite the
# script's real exit status with rm's.
cleanup() {
  rm -rf "$WORK" 2>/dev/null && return 0
  sleep 1
  rm -rf "$WORK" || true
}
trap cleanup EXIT

TREE="$WORK/tree"
mkdir -p "$TREE"

log "Archiving $SHA into scrubbed tree..."
if ! git -C "$REPO_ROOT" archive --format=tar "$SHA" | tar -x -C "$TREE"; then
  echo "[mirror-sync-fail] git archive failed for ref $REF ($SHA)" >&2
  exit 1
fi

log "Running scrub guard..."
if ! scrub_guard "$TREE"; then
  echo "[mirror-sync-fail] scrub guard rejected the archived tree — fix" \
    ".gitattributes export-ignore or remove the offending content; not pushing" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "Dry run clean: $SHA would sync to $DEST"
  exit 0
fi

log "Committing snapshot..."
git -c init.defaultBranch=main init -q "$TREE"
git -C "$TREE" add -A
# maintenance.auto/gc.auto off: commit otherwise spawns a detached
# `git maintenance run --auto` child that outlives this script and races
# the cleanup trap's rm -rf (ENOTEMPTY under $TREE/.git on slow runners).
git -C "$TREE" \
  -c user.name="lade mirror-sync" -c user.email="mirror-sync@lade.dev" \
  -c maintenance.auto=false -c gc.auto=0 \
  commit -q -m "Mirror sync from $SHA"

# --dest is validated https:// above, so the auth header always applies.
B64="$(printf 'x-access-token:%s' "$LADE_MIRROR_PUSH_TOKEN" | base64 | tr -d '\n')"
PUSH_ENV=(GIT_TERMINAL_PROMPT=0
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=http.extraheader
  "GIT_CONFIG_VALUE_0=Authorization: basic $B64")

log "Force-pushing snapshot to $DEST main..."
if ! env "${PUSH_ENV[@]}" git -C "$TREE" push --force -q "$DEST" HEAD:refs/heads/main; then
  echo "[mirror-sync-fail] push to $DEST failed" >&2
  exit 1
fi

log "Mirror sync complete: $SHA -> $DEST main"
