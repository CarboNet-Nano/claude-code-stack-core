#!/usr/bin/env bash
# OpenAI API key resolver — Keychain backup for the Codex/OpenAI family (ADR-028).
#
# WHY: the Codex roles (reviewer, security-auditor, product-critic) reach the
# OpenAI/GPT-5.5 family via the local Codex CLI (~/.codex/auth.json), with
# OPENAI_API_KEY (env) as the cloud direct-API rung (ADR-015). The Gemini CLI
# died on 2026-06-30 (IneligibleTierError, ADR-027) — a sharp reminder that a
# vendor CLI can vanish. This adds a macOS Keychain item `openai-api-key` as a
# resilient LOCAL backup so the direct-API rung works even if the Codex CLI
# stops authenticating.
#
# This NEVER overrides a CLI that works and NEVER overrides an already-set
# OPENAI_API_KEY (cloud env wins). It only fills the gap: if OPENAI_API_KEY is
# unset, resolve it from the Keychain so the preflight verdict and the
# direct-API rung can proceed.
#
# Whitespace is stripped (the ADR-026/027 401 lesson); the key is never logged;
# xtrace is disabled so a caller's `set -x` can't echo it.
#
# USAGE
#   source "$DIR/openai-key.sh"
#   oai_available     # 0 if a key resolves (env or Keychain)
#   oai_export        # export OPENAI_API_KEY from the Keychain IFF currently unset
#   oai_key           # print the resolved key (env first, else Keychain)

set -uo pipefail
{ set +x; } 2>/dev/null

oai_trim() { local s="$1"; printf '%s' "${s//[$' \t\r\n']/}"; }

oai_key() {
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local k; k="$(oai_trim "$OPENAI_API_KEY")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  if command -v security >/dev/null 2>&1; then
    local k; k="$(security find-generic-password -s openai-api-key -w 2>/dev/null)" || return 1
    k="$(oai_trim "$k")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

oai_available() { oai_key >/dev/null 2>&1; }

# Fill OPENAI_API_KEY from the Keychain only when it is NOT already set (cloud env
# always wins). Safe to call before the preflight / a codex direct-API rung.
oai_export() {
  [[ -n "${OPENAI_API_KEY:-}" ]] && return 0
  local k; k="$(oai_key)" || return 1
  export OPENAI_API_KEY="$k"
}
