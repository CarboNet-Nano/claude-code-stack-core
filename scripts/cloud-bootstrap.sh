#!/usr/bin/env bash
# Claude Code Stack — cloud session bootstrap
#
# WHY: Claude Code *cloud* sessions (claude.ai/code on web + iOS) run in an
# ephemeral container. The repo is cloned fresh, but the user's laptop
# ~/.claude is NEVER synced up — so personal/global skills like /goodmorning
# and /carbonight are not discoverable. This script installs the stack into the
# container's ~/.claude at session start so they load on every surface.
#
# USED TWO WAYS (see docs/CLOUD.md):
#   1. As the ENVIRONMENT setup script (configured per-environment in the
#      Claude Code web UI). Then EVERY cloud session of EVERY repo gets the
#      stack, without committing anything into each project.
#   2. Copied into a single repo's .claude/hooks/ by /project-init and wired
#      to that repo's SessionStart hook, so that repo self-bootstraps the
#      stack in cloud with no per-environment config.
#
# It clones this repo, then runs the idempotent installer: install.sh
# --mode=merge backs up ~/.claude and deep-merges JSON (user wins on conflict),
# so re-runs are safe.
#
# The default target is the PUBLIC, scrubbed mirror (ADR-036), so the clone
# needs no credential — no per-environment token, no setup-script secret.
# This makes the flow fully repo-driven for the common (CarboNet) case.
# lade's own environments, which need the private unscrubbed source instead,
# override CLAUDE_STACK_REPO to github.com/get-lade/claude-code-stack and set
# CLAUDE_STACK_REPO_TOKEN.
#
# OPTIONAL ENV:
#   CLAUDE_STACK_REPO        default: github.com/CarboNet-Nano/claude-code-stack-core
#   CLAUDE_STACK_REF         default: main
#   CLAUDE_STACK_TIER        default: 2
#   CLAUDE_STACK_REPO_TOKEN  only needed when CLAUDE_STACK_REPO points at a
#                            private repo (e.g. lade's own source); if set, it
#                            is used (via GIT_ASKPASS, never in argv or
#                            .git/config). Never hardcode it.
#
# EXIT POLICY: best-effort. A network-blocked clone prints a prominent warning
# and exits 0 — it never hard-fails the cloud session.

set -uo pipefail

log() { printf '[stack-cloud-bootstrap] %s\n' "$*" >&2; }

# Only meaningful in the remote/cloud container. Local sessions install the
# stack themselves via ./scripts/install.sh, so this is a true no-op there.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Idempotency: two hooks may fire for the same session (the environment setup
# script and a repo's committed hook) — whichever lands first wins; the rest
# no-op on this marker.
MARKER="/tmp/.claude-stack-cloud-bootstrap.done"
STAMP="$HOME/.claude/.stack-install.json"

REPO="${CLAUDE_STACK_REPO:-github.com/CarboNet-Nano/claude-code-stack-core}"
REF="${CLAUDE_STACK_REF:-main}"
TIER="${CLAUDE_STACK_TIER:-2}"

# Strip any scheme the caller supplied so we control the auth method.
REPO="${REPO#https://}"
REPO="${REPO#http://}"
REPO="${REPO%.git}"

# The marker was originally documented as "once per container boot", on the
# assumption that /tmp is boot-scoped. It is not, on every cloud host: where
# /tmp survives a container restart, the marker outlives the install it
# describes and the stack silently freezes at whatever ref it was first
# installed from. Observed 2026-07-26 — a container still running a 4-day-old
# install, with a marker and an install stamp both dated to the original boot,
# while three upstream fixes to the installed hooks had landed since.
#
# So the marker alone no longer authorizes a skip. When one is present, ask the
# remote what `$REF` points at now and compare it to what is actually installed.
# One `ls-remote` (no clone) decides it.
#
# Fail-safe in both directions: no stamp, no `git`, or an unreachable remote all
# mean "cannot prove staleness" and honor the marker, so a network-blocked
# environment behaves exactly as it does today. Only a *positive* mismatch —
# a readable stamp and a readable remote sha that differ — re-runs the install.
installed_sha() {
  [ -f "$STAMP" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.source_sha // empty' "$STAMP" 2>/dev/null
  else
    sed -n 's/.*"source_sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAMP" 2>/dev/null | head -1
  fi
}

TMP="$(mktemp -d)"
ASKPASS="$(mktemp)"
cleanup() { rm -rf "$TMP" "$ASKPASS"; }
trap cleanup EXIT

# Public repo → anonymous clone, no credential. If CLAUDE_STACK_REPO_TOKEN is
# set anyway (e.g. the repo was made private again), use it via GIT_ASKPASS so
# the token stays OUT of argv and .git/config: the username (x-access-token)
# lives in the URL and git asks the helper only for the password.
if [ -n "${CLAUDE_STACK_REPO_TOKEN:-}" ]; then
  export CLAUDE_STACK_REPO_TOKEN
  printf '#!/bin/sh\nexec printf "%%s" "$CLAUDE_STACK_REPO_TOKEN"\n' > "$ASKPASS"
  chmod +x "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
  clone_url="https://x-access-token@${REPO}.git"
else
  clone_url="https://${REPO}.git"
fi

# Runs after clone_url so the staleness probe uses the same credential the
# clone would, rather than silently failing closed on a private repo.
if [ -f "$MARKER" ]; then
  have="$(installed_sha || true)"
  if [ -z "$have" ] || ! command -v git >/dev/null 2>&1; then
    exit 0
  fi
  want="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$clone_url" "$REF" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$want" ] || [ "$want" = "$have" ]; then
    exit 0
  fi
  log "installed stack is ${have:0:7}, $REF is now ${want:0:7} — refreshing."
fi

attempt=0
max=3
delay=2
until GIT_TERMINAL_PROMPT=0 \
      git clone --depth 1 --branch "$REF" "$clone_url" "$TMP/stack" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max" ]; then
    log "WARNING: could not clone $REPO (ref $REF) after $max attempts."
    log "Check the environment's network policy allows GitHub."
    log "Continuing without the stack."
    exit 0
  fi
  log "clone attempt $attempt failed; retrying in ${delay}s..."
  sleep "$delay"
  delay=$((delay * 2))
done

log "cloned $REPO@$REF; installing tier $TIER into ~/.claude (merge mode)..."
if bash "$TMP/stack/scripts/install.sh" --tier="$TIER" --skip-requirements; then
  log "stack tier $TIER installed. Custom skills/commands are now available."
  : > "$MARKER"
else
  log "WARNING: install.sh exited non-zero; some stack pieces may be missing."
fi

# --- External-model critic CLIs (Codex / Gemini) ---------------------------
# reviewer/security-auditor/product-critic reach GPT-5.5 via the `codex` CLI;
# red-team/architecture-critic/historian reach Gemini via the `gemini` CLI.
# Cloud containers don't preinstall these, but the API keys are typically set
# as ENVIRONMENT VARIABLES (the intended cloud mechanism — see docs/CLOUD.md).
# Install each CLI when its key is present so the critic gate runs natively
# instead of relying on each agent's runtime fallback. Best-effort: a failure
# here never blocks the session, and the agents still have their fallbacks.
install_critic_cli() {
  key_name="$1"; pkg="$2"; bin="$3"
  if [ -z "$(printenv "$key_name" 2>/dev/null)" ]; then
    return 0
  fi
  if command -v "$bin" >/dev/null 2>&1; then
    log "$bin already on PATH; skipping $pkg install."
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log "WARNING: $key_name is set but npm is absent; cannot install $pkg. Agents will fall back at runtime."
    return 0
  fi
  log "$key_name present → installing $pkg ..."
  if npm i -g "$pkg" >/dev/null 2>&1; then
    log "$pkg installed ($bin available)."
  else
    log "WARNING: 'npm i -g $pkg' failed. Agents will fall back at runtime."
  fi
}

install_critic_cli OPENAI_API_KEY @openai/codex codex
install_critic_cli GEMINI_API_KEY @google/gemini-cli gemini

# --- RTK (token-reduction proxy) -------------------------------------------
# Rewrites shell commands (git, docker, npm, etc.) to pipe through RTK for
# compressed output before it hits Claude's context. Tier 1+ installs the
# PreToolUse hook; this ensures the binary is present in cloud containers.
# Best-effort: failure here never blocks the session.
if [ "${RTK_DISABLED:-}" != "1" ]; then
  # ADR-063 D6.2: pinned + hash-verified install, in a sourceable lib so the
  # refusal path is testable offline (tests/test-cloud-bootstrap.sh).
  . "$(dirname "$0")/lib/rtk-install.sh"
  rtk_install_pinned || true
fi
