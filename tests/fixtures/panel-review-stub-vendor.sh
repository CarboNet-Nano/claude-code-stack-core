#!/usr/bin/env bash
# Stub vendor lib for tests/test-panel-review.sh. Implements gmn_call and
# oair_call with the SAME contract as scripts/lib/gemini-api.sh /
# scripts/lib/openai-review.sh (evidence sidecar via GMN_EVIDENCE_OUT /
# OAIR_EVIDENCE_OUT, success/degraded return codes) so panel-review.sh's
# vendor-independent logic can be exercised deterministically, with no real
# network call and no key requirement.
set -uo pipefail

STUB_RC="${STUB_RC:-0}"
STUB_HTTP="${STUB_HTTP:-200}"
STUB_OUTPUT_BYTES="${STUB_OUTPUT_BYTES:-600}"
STUB_OUTPUT_TOKENS="${STUB_OUTPUT_TOKENS:-150}"
STUB_INPUT_TOKENS="${STUB_INPUT_TOKENS:-500}"
STUB_RESPONSE_ID="${STUB_RESPONSE_ID:-resp-123}"
STUB_NO_SIDECAR="${STUB_NO_SIDECAR:-0}"
STUB_ERR_MSG="${STUB_ERR_MSG:-degraded}"

_stub_output() {
  if [[ -n "${STUB_OUTPUT:-}" ]]; then
    printf '%s' "$STUB_OUTPUT"
  else
    printf '%*s' "$STUB_OUTPUT_BYTES" '' | tr ' ' 'x'
  fi
}

_stub_call() {
  local vendor_label="$1" evidence_out="$2" vendor="$3" family="$4" model_req="$5"
  if [[ "$STUB_RC" != "0" ]]; then
    echo "=== ${vendor_label} API: UNAVAILABLE — HTTP ${STUB_HTTP} (${STUB_ERR_MSG}) ==="
    return "$STUB_RC"
  fi
  local out; out="$(_stub_output)"
  if [[ -n "$evidence_out" && "$STUB_NO_SIDECAR" != "1" ]]; then
    jq -nc \
      --arg vendor "${STUB_VENDOR:-$vendor}" --arg family "${STUB_FAMILY:-$family}" \
      --arg model_requested "$model_req" \
      --arg model_returned "${STUB_MODEL_RETURNED:-$model_req}" \
      --argjson http_status "$STUB_HTTP" \
      --arg response_id "$STUB_RESPONSE_ID" \
      --argjson input_tokens "$STUB_INPUT_TOKENS" \
      --argjson output_tokens "$STUB_OUTPUT_TOKENS" \
      '{vendor:$vendor, family:$family, model_requested:$model_requested, model_returned:$model_returned,
        http_status:$http_status, response_id:$response_id,
        usage:{input_tokens:$input_tokens, output_tokens:$output_tokens}}' \
      > "$evidence_out" 2>/dev/null
  fi
  printf '%s' "$out"
  return 0
}

gmn_call() {
  local prompt="${1:-}"
  [[ -z "$prompt" ]] && { echo "=== Gemini API: ERROR — empty prompt ===" >&2; return 9; }
  _stub_call "Gemini" "${GMN_EVIDENCE_OUT:-}" "google" "gemini" "${GEMINI_API_MODEL:-gemini-3.1-pro-preview}"
}

oair_call() {
  local prompt="${1:-}" model="${2:-gpt-5.6-terra}" effort="${3:-}"
  [[ -z "$prompt" ]] && { echo "=== OpenAI API: ERROR — empty prompt ===" >&2; return 9; }
  _stub_call "OpenAI" "${OAIR_EVIDENCE_OUT:-}" "openai" "openai" "$model"
}
