#!/usr/bin/env bash
# Adversarial-review model router (ADR-025).
#
# WHY: the adversarial-review agents (reviewer, security-auditor, product-critic)
# used to run EVERY review on the most expensive tier — gpt-5.5 @ reasoning
# effort=high via the Codex CLI, over a WHOLE-REPO cold read. Logs showed ~210
# review runs/month at ~950K tokens each (~$200). Most diffs are routine; paying
# frontier-tier-high-effort on all of them is the cost driver.
#
# This router classifies a diff's STAKES (cheaply, deterministically, from
# changed paths + domain-mode/sensitivity signals) and selects a tier:
#
#   high     → Codex / gpt-5.5 @ high     (auth, crypto, payment, migration, RLS…)
#   routine  → local Qwen first, escalate → Codex / gpt-5.4 @ medium
#
# Cross-family integrity (ADR-011) is preserved on BOTH tiers: local Qwen
# (Alibaba) and gpt-5.x (OpenAI) are each a different model family than the
# Claude implementer. The router never routes review to a Claude model.
#
# It also fixes SCOPE: every tier reviews the DIFF (base..head), not the whole
# repo — the single biggest token lever, applied even to high-stakes reviews.
#
# CONFIG-DRIVEN MODELS (ADR-025 + Tier-5 forward-compat): the tier model IDs are
# NOT hardcoded. Resolution order, highest first:
#   1. environment variable  (REVIEW_HIGH_MODEL, REVIEW_ROUTINE_MODEL, …)
#   2. <repo>/config/model-routing.json  ".review_tiers.*"  (per-repo override,
#      via jq, if present — today only this stack's own source repo vendors
#      this file)
#   3. ~/.claude/config/model-routing.json  (machine-wide default — every
#      repo gets this from install.sh/update.sh even without its own copy)
#   4. built-in default
# So when the Tier-5 box lands, repoint the routine/escalation/high models in
# config (or via env) — no edit to this script.
# NOTE: this is "pick ONE whole file," not a per-key deep merge — a repo-local
# file with only some keys set still skips rung 3 for its unset keys and falls
# straight to rung 4. No repo ships a partial override today.
#
# USAGE
#   source "$DIR/review-router.sh"
#   rr_run <agent> [base] [head]   # prints verdict block, sets RR_* vars
#   rr_log_route <agent> <stakes> <engine> <model> <scope> <escalated>
#
# After rr_run, the caller obeys:
#   RR_STAKES      high | routine
#   RR_ENGINE      local | codex          (initial engine to invoke)
#   RR_MODEL       <resolved routine/high model id>
#   RR_EFFORT      high | medium | n/a    (reasoning effort for codex tiers)
#   RR_SCOPE       diff                   (always diff — scope fix)
#   RR_ESC_ENGINE  codex                  (escalation target for routine)
#   RR_ESC_MODEL   <resolved escalation model id>
#   RR_ESC_EFFORT  medium
#   RR_REASON      one-line why this stakes class was chosen

set -uo pipefail

# Paths whose presence in a diff marks it high-stakes. Matched case-insensitively
# against changed file paths. The list is deliberately BROAD and biased toward
# false-high: a false "high" only costs money, but a false "routine" sends risky
# code to the cheap tier — the failure mode that matters for a security engine.
# (ADR-025 review: expanded to cover jwt/hmac/kms/cert/tls/ssh/vault/seed/
# private-key/key+cert file extensions, which the original list missed.)
RR_HIGH_STAKES_RE='(auth|login|oauth|sso|saml|session|token|jwt|jwk|passwd|password|passphrase|secret|credential|crypto|encrypt|decrypt|cipher|hmac|sign|keyring|keystore|keypair|private|mnemonic|seed|vault|kms|totp|mfa|2fa|tls|ssl|ssh|cert|payment|billing|invoice|charge|stripe|financ|ledger|payroll|migration|/migrations/|schema|\.sql$|rls|policy|\.env|security|webhook|\.(pem|key|crt|cer|p12|pfx|jks|keystore)$)'

# --- config resolution --------------------------------------------------------

rr_config_file() {
  # $RR_CONFIG wins; else <repo>/config/model-routing.json (per-repo override);
  # else ~/.claude/config/model-routing.json (machine-wide default); else empty.
  if [[ -n "${RR_CONFIG:-}" && -f "${RR_CONFIG}" ]]; then echo "$RR_CONFIG"; return; fi
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  [[ -n "$root" && -f "$root/config/model-routing.json" ]] && { echo "$root/config/model-routing.json"; return; }
  [[ -f "$HOME/.claude/config/model-routing.json" ]] && { echo "$HOME/.claude/config/model-routing.json"; return; }
  echo ""
}

# Model-family names that MUST NOT be used for adversarial review (ADR-011: the
# reviewer must be a DIFFERENT family than the Claude implementer). Enforced at
# resolution time so a stray env/config override can't quietly defeat the rule.
RR_CLAUDE_RE='claude|anthropic|opus|sonnet|haiku|fable'

# rr_resolve <env_var_name> <jq_path> <default>
# Resolution order: env override > config value > default. Empty/null config
# values fall through. A resolved value that names a Claude family is REFUSED
# (ADR-011) and the built-in non-Claude default is used instead — never silently
# honored.
rr_resolve() {
  local env_name="$1" jq_path="$2" def="$3" out=""
  # Indirect env read via eval, NOT ${!env_name}. ${!name} is a bash-only
  # expansion; under zsh — the shell the review subagents source this from —
  # it raises "bad substitution", which aborted rr_resolve mid-function and
  # returned an EMPTY engine/model (callers then fell back to a hardcoded rung).
  # eval works identically in bash and zsh. env_name is always a fixed literal
  # from the call sites below; the identifier guard keeps the eval injection-free.
  local env_val=""
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && eval "env_val=\${$env_name:-}"
  if [[ -n "$env_val" ]]; then
    out="$env_val"
  else
    local cfg; cfg="$(rr_config_file)"
    if [[ -n "$cfg" ]] && command -v jq >/dev/null 2>&1; then
      local v; v="$(jq -r "${jq_path} // empty" "$cfg" 2>/dev/null)"
      [[ -n "$v" && "$v" != "null" ]] && out="$v"
    fi
  fi
  [[ -z "$out" ]] && out="$def"
  if echo "$out" | grep -qiE "$RR_CLAUDE_RE"; then
    echo "[review-router] REFUSED Claude-family model '$out' for $env_name — ADR-011 requires a non-Claude reviewer; using default '$def'." >&2
    out="$def"
  fi
  echo "$out"
}

# --- diff resolution ----------------------------------------------------------

rr_default_base() {
  # Merge target: origin default branch if resolvable, else main/master, else HEAD~1.
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

# --- classification -----------------------------------------------------------

rr_classify_stakes() {
  # Echoes "high <reason>" or "routine <reason>".
  #
  # FAIL-SAFE PRINCIPLE (ADR-025 review): on ANY ambiguity or error — an invalid
  # override, an unresolvable ref, a failed git command — default to HIGH, never
  # routine. Downgrading is only ever done on a POSITIVE "this diff is routine"
  # signal (clean diff, no high-stakes paths). Silence is never routine.
  local base="$1" head="$2"

  # Forced tier: honor ONLY the two valid values. An invalid/typo value is
  # ignored (NOT treated as routine) and classification continues.
  case "${REVIEW_TIER_FORCE:-}" in
    high)    echo "high forced via REVIEW_TIER_FORCE"; return ;;
    routine) echo "routine forced via REVIEW_TIER_FORCE"; return ;;
    "")      : ;;
    *)       : ;;  # invalid → ignore, fall through to detection
  esac

  case "${STACK_DOMAIN_MODE:-}" in
    security|schema-migration)
      echo "high domain-mode=${STACK_DOMAIN_MODE}"; return ;;
  esac
  if [[ "${STACK_SENSITIVITY:-}" == "high" ]]; then
    echo "high sensitivity=high"; return
  fi

  # Resolve the diff. ANY git failure → HIGH (fail-safe): a broken git state must
  # not silently downgrade. Only a clean, empty diff is a legitimate routine.
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1; then
    echo "high unresolved diff refs (fail-safe: ${base}..${head})"; return
  fi
  local mb files hit
  mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "high merge-base failed (fail-safe)"; return; }
  files="$(git diff --name-only "$mb..$head" 2>/dev/null)" || { echo "high git diff failed (fail-safe)"; return; }

  # Uncommitted work is part of what gets reviewed when head is the current
  # checkout: two reviews (2026-07-11) classified "routine" against an EMPTY
  # commit-range diff while high-stakes files sat untracked in the working tree.
  # Scan `git status --porcelain -uall` paths (modified + staged + untracked,
  # incl. files inside untracked dirs) whenever head == HEAD — always, not only
  # when the range is empty: fail-safe bias means a risky uncommitted file must
  # flag high even alongside a routine committed diff. Skipped when head is not
  # the current checkout (working-tree state is unrelated to that range).
  local wt=""
  if [[ "$(git rev-parse --verify --quiet "${head}^{commit}" 2>/dev/null)" == "$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" ]]; then
    wt="$(git status --porcelain -uall 2>/dev/null)" || { echo "high git status failed (fail-safe)"; return; }
    wt="$(printf '%s\n' "$wt" | cut -c4-)"
  fi

  if [[ -n "$files" ]]; then
    hit="$(printf '%s\n' "$files" | grep -iE "$RR_HIGH_STAKES_RE" | head -1)"
    if [[ -n "$hit" ]]; then
      echo "high risk-path: ${hit}"; return
    fi
  fi
  if [[ -n "$wt" ]]; then
    hit="$(printf '%s\n' "$wt" | grep -iE "$RR_HIGH_STAKES_RE" | head -1)"
    if [[ -n "$hit" ]]; then
      echo "high risk-path (uncommitted): ${hit}"; return
    fi
  fi
  echo "routine no high-stakes paths in diff or working tree"
}

# --- local-model availability (cloud-safety) ----------------------------------

# rr_local_available <model-tag> : is the local routine engine usable here?
# Cloud / CI sessions have no ollama, so the `local` routine tier must transparently
# fall back to the escalation engine (Codex) rather than fail. Test/CI determinism
# via REVIEW_ASSUME_NO_LOCAL=1 (force unavailable) / REVIEW_ASSUME_LOCAL=1 (force
# available); NO_LOCAL wins when both are set.
#
# Tier gate: local models are Tier-5-only hardware (HARDWARE.md sizing assumes
# a Tier-5 laptop). Below Tier 5, a stray routine review silently loading a
# 32B model has crashed machines (see incident 2026-07-29). REVIEW_ASSUME_LOCAL=1
# is an explicit user opt-in (session/project) and is the ONLY way to use a
# local model below Tier 5 — it deliberately overrides the tier gate.
rr_local_available() {
  [[ "${REVIEW_ASSUME_NO_LOCAL:-}" == "1" ]] && return 1
  [[ "${REVIEW_ASSUME_LOCAL:-}" == "1" ]] && return 0
  local root tier=0
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -n "$root" && -f "$root/.claude/stack-config.json" ]] && command -v jq >/dev/null 2>&1; then
    tier="$(jq -r '.stack_tier // 0' "$root/.claude/stack-config.json" 2>/dev/null)"
    [[ "$tier" =~ ^[0-9]+$ ]] || tier=0
  fi
  (( tier < 5 )) && return 1
  command -v ollama >/dev/null 2>&1 || return 1
  local model="$1" tags
  tags="$(ollama list 2>/dev/null)" || return 0   # ollama present but list failed → don't over-block
  [[ -z "$tags" ]] && return 0
  grep -qF "$model" <<<"$tags"
}

# --- tier selection -----------------------------------------------------------

rr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(rr_default_base)}"
  local head="${3:-HEAD}"

  local classified stakes reason
  classified="$(rr_classify_stakes "$base" "$head")"
  stakes="${classified%% *}"
  reason="${classified#* }"

  RR_STAKES="$stakes"
  RR_REASON="$reason"
  RR_SCOPE="diff"
  RR_ESC_ENGINE=""
  RR_ESC_MODEL=""
  RR_ESC_EFFORT=""
  RR_LOCAL_FALLBACK="no"

  if [[ "$stakes" == "high" ]]; then
    RR_ENGINE="$(rr_resolve REVIEW_HIGH_ENGINE  '.review_tiers.high.engine'  codex)"
    RR_MODEL="$(rr_resolve  REVIEW_HIGH_MODEL   '.review_tiers.high.model'   gpt-5.5)"
    RR_EFFORT="$(rr_resolve REVIEW_HIGH_EFFORT  '.review_tiers.high.effort'  high)"
  else
    RR_ENGINE="$(rr_resolve REVIEW_ROUTINE_ENGINE '.review_tiers.routine.engine' local)"
    RR_MODEL="$(rr_resolve  REVIEW_ROUTINE_MODEL  '.review_tiers.routine.model'  qwen2.5-coder:32b)"
    RR_EFFORT="n/a"
    RR_ESC_ENGINE="$(rr_resolve REVIEW_ESCALATION_ENGINE '.review_tiers.routine.escalation_engine' codex)"
    RR_ESC_MODEL="$(rr_resolve  REVIEW_ESCALATION_MODEL  '.review_tiers.routine.escalation_model'  gpt-5.4)"
    RR_ESC_EFFORT="$(rr_resolve REVIEW_ESCALATION_EFFORT '.review_tiers.routine.escalation_effort' medium)"

    # Cloud-safety: if the routine engine is local but ollama/the model isn't
    # available here (cloud / CI), transparently route to the escalation engine
    # (Codex via OPENAI_API_KEY, ADR-015) so routine reviews still run cross-family.
    if [[ "$RR_ENGINE" == "local" ]] && ! rr_local_available "$RR_MODEL"; then
      RR_ENGINE="$RR_ESC_ENGINE"; RR_MODEL="$RR_ESC_MODEL"; RR_EFFORT="$RR_ESC_EFFORT"
      RR_LOCAL_FALLBACK="yes (local model unavailable → escalation engine)"
      RR_ESC_ENGINE=""; RR_ESC_MODEL=""; RR_ESC_EFFORT=""
    fi
  fi

  cat <<EOF
=== review router (ADR-025) ===
agent      : $agent
diff       : ${base}..${head}
stakes     : $RR_STAKES   ($RR_REASON)
engine     : $RR_ENGINE
model      : $RR_MODEL
effort     : $RR_EFFORT
scope      : $RR_SCOPE
local-fallback : $RR_LOCAL_FALLBACK
escalation : ${RR_ESC_ENGINE:-none}${RR_ESC_MODEL:+/$RR_ESC_MODEL}${RR_ESC_EFFORT:+@$RR_ESC_EFFORT} (routine only: on low-confidence / non-trivial diff)
===============================
EOF
}

# --- route logging (best-effort; never fails the caller) ----------------------
# Appends one row to subagent-runs.jsonl so /handoff and a quick jq query can
# verify the high/routine split and confirm projected savings.
rr_log_route() {
  local agent="${1:-unknown}" stakes="${2:-unknown}" engine="${3:-unknown}" \
        model="${4:-unknown}" scope="${5:-diff}" escalated="${6:-no}"
  command -v jq >/dev/null 2>&1 || return 0
  # ${HOME:-/tmp}: under `set -u` a bare $HOME would abort the caller before the
  # mkdir guard could fire — defeating "best-effort, never fails the caller".
  local log_dir="${HOME:-/tmp}/.claude/logs"; mkdir -p "$log_dir" 2>/dev/null || return 0
  local project; project="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$project" \
    --arg agent "$agent" \
    --arg stakes "$stakes" \
    --arg engine "$engine" \
    --arg model "$model" \
    --arg scope "$scope" \
    --arg escalated "$escalated" \
    '{event:"review_route", ts:$ts, project:$project, agent:$agent,
      stakes:$stakes, engine:$engine, model:$model, scope:$scope, escalated:$escalated}' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# Allow direct execution for manual / CI inspection. The `:-` guards keep
# sourcing safe under `set -u` even where BASH_SOURCE/$0 are unset.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  rr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
