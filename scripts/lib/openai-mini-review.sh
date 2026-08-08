#!/usr/bin/env bash
# OpenAI free-quota mini model — fifth advisory review voice (2026-08-04, PILOT).
#
# WHY: Bill's OpenAI account is eligible for up to 10,000,000 free tokens/day
# across a mini/nano model tier (gpt-5.1-codex-mini, gpt-5-mini, gpt-5.4-mini,
# etc — account screenshot, 2026-08-04). The routine review path already has
# a gate (local Qwen / codex escalation), a third voice (DeepSeek-v4, ADR-026),
# and a fourth voice (Grok 4.5, PILOT, grok-review.sh). This adds a FIFTH,
# advisory-only voice at effectively $0 marginal cost.
#
# Unlike Grok/DeepSeek this voice reuses openai-review.sh's oair_call (same
# vendor, same key/transport/model-guard plumbing already built for the
# routine-escalation and high-tier rungs) rather than a fresh HTTP client —
# see .claude/plans/2026-08-04-openai-free-mini-fifth-voice-pilot.md.
#
# INDEPENDENCE CAVEAT (documented, not fixed here): this voice shares a vendor
# with the routine-escalation rung (codex/gpt-5.4) — a weaker "different blind
# spots" argument than DeepSeek/Grok, which are each a distinct family. Worth
# weighing explicitly before any promotion past advisory.
#
# This voice is ADVISORY and ADDITIVE: it never replaces the gate pass and
# never auto-blocks. A missing key, unreachable API, or any oair_call failure
# degrades to "voice unavailable" — it does NOT fail the overall review.
#
# PILOT status: 2-week shadow before any promotion. See the plan doc above for
# the silent-corruption-bake-off caveat (no dedicated harness exists yet;
# same gap the Grok pilot already carries).
#
# MODEL: gpt-5.1-codex-mini by default (code-specialized, on the free 10M/day
# list). Override via OPENAI_MINI_REVIEW_MODEL.
#
# USAGE
#   source "$DIR/openai-mini-review.sh"
#   omr_available                 # 0 if a key resolves, non-zero otherwise
#   omr_run <agent> [base] [head] # prints the fifth-voice block; exit 0 ok / non-zero degraded
#
# Cross-family rule (ADR-011): OpenAI is non-Claude — oair_guard_model (sourced
# from openai-review.sh) refuses a Claude-family model id at call time.

set -uo pipefail
{ set +x; } 2>/dev/null

_omr_lib="$(dirname "${BASH_SOURCE[0]}")/openai-review.sh"
# shellcheck source=/dev/null
[[ -f "$_omr_lib" ]] && source "$_omr_lib"

OMR_MODEL="${OPENAI_MINI_REVIEW_MODEL:-gpt-5.1-codex-mini}"
OMR_MAX_DIFF_BYTES="${OMR_MAX_DIFF_BYTES:-200000}"   # bound the prompt; oversized diffs are truncated with a marker

omr_available() { command -v oair_available >/dev/null 2>&1 && oair_available; }

# --- diff resolution (mirrors grok-review.sh / deepseek-review.sh defaults) --

omr_default_base() {
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

OMR_PROMPT='Adversarially review the diff below. Read the code COLD — you do NOT have the architect plan, the implementer commentary, or the other reviewers findings; you are an independent fifth voice whose value is the blind spots the others share. Check: correctness, edge cases (empty/null/boundary/malformed), security (injection, auth bypass, secret leakage, RLS holes), error handling, performance (N+1, unbounded loops, missing indexes), concurrency/idempotency, and dependency risk. Output findings as BLOCKING / NON-BLOCKING / NIT with file:line and a one-line why. If you find nothing material, say so plainly — do not invent findings.'

# --- run ----------------------------------------------------------------------

omr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(omr_default_base)}"
  local head="${3:-HEAD}"

  if ! command -v oair_call >/dev/null 2>&1; then
    echo "=== OpenAI free-mini fifth voice (PILOT): UNAVAILABLE — openai-review.sh not sourced ==="; return 1
  fi
  if ! omr_available; then
    cat <<'EOF'
=== OpenAI free-mini fifth voice (PILOT): UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s openai-api-key -w 'YOUR_KEY'
Or export OPENAI_API_KEY (cloud/CI). Advisory — the gate pass remains mandatory.
EOF
    return 2
  fi

  # Resolve diff; any git failure -> degrade (advisory voice, never aborts the review).
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1; then
    echo "=== OpenAI free-mini fifth voice (PILOT): UNAVAILABLE — unresolved refs ${base}..${head} ==="; return 4
  fi
  local mb diff
  mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "=== OpenAI free-mini fifth voice: UNAVAILABLE — merge-base failed ==="; return 4; }
  diff="$(git diff "$mb..$head" 2>/dev/null)" || { echo "=== OpenAI free-mini fifth voice: UNAVAILABLE — git diff failed ==="; return 4; }
  if [[ -z "$diff" ]]; then
    echo "=== OpenAI free-mini fifth voice (PILOT): empty diff ${base}..${head} — nothing to review ==="; return 0
  fi
  if (( ${#diff} > OMR_MAX_DIFF_BYTES )); then
    diff="${diff:0:OMR_MAX_DIFF_BYTES}
[...diff truncated at ${OMR_MAX_DIFF_BYTES} bytes for the review prompt...]"
  fi

  local content rc
  content="$(printf '%s' "$diff" | oair_call "$OMR_PROMPT" "$OMR_MODEL" "")"; rc=$?
  if [[ $rc -ne 0 || -z "$content" ]]; then
    echo "=== OpenAI free-mini fifth voice (PILOT): UNAVAILABLE — ${content:-oair_call failed (rc=$rc)} ==="; return 6
  fi

  cat <<EOF
=== OpenAI free-mini fifth voice (PILOT) — ${OMR_MODEL} ===
agent : $agent
diff  : ${base}..${head}
--- findings (advisory; does not block) ---
$content
==============================================
EOF
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  omr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
