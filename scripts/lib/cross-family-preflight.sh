#!/usr/bin/env bash
# Cross-family review preflight probe (ADR-022).
#
# WHY: the adversarial-review agents (reviewer, security-auditor, product-critic)
# reach a non-Claude model family — OpenAI/GPT-5.5 via the `codex` CLI or the
# OpenAI API (ADR-011/015). In cloud/sandboxed sessions that path can be broken
# in four distinct ways, and the agents historically discovered the break ~5
# minutes in (mid-`codex exec`) and then hard-STOPped, stranding the PR:
#
#   1. key not in the SUBAGENT shell env       → 401 "Missing bearer"
#   2. key present but api.openai.com is        → sandbox classifier DENY
#      hard-denied by the auto-mode classifier     (correct: repo source = exfil)
#   3. in-session settings.local.json edits to  → also DENY (classifier-bypass)
#      arm the path are themselves denied
#   4. net: agent exhausts its ladder and STOPs → held PR, no decision
#
# This probe runs FIRST and cheaply: it classifies which (if any) of those
# failure modes is active and prints a structured verdict the agent relays
# up front — before doing any review work. It does NOT arm anything, weaken any
# classifier, or send repo content anywhere (deliverable D: plumbing-only).
#
# The reachability check is a GET to the API base. When no OPENAI_API_KEY is
# available it is UNAUTHENTICATED (no key, no repo data on the wire — not an
# exfil vector): any HTTP status proves the endpoint is reachable under the
# network policy; a refused/timed-out connection proves the policy (or
# classifier) is blocking it. When a key IS available, the probe sends a
# QUOTA-SENSITIVE request instead — a minimal token-capped chat completion,
# NOT the free /v1/models list endpoint, which returns 200 for a zero-credit
# key and would prove nothing about usability (live-reproduced: exactly that
# key got 200 on /v1/models and then 429 "no credits remaining" on the real
# review call). Auth is piped via stdin (`-H @-`, ADR-030) so the key never
# lands in curl's argv. Real-world cost is a small fraction of a cent per
# preflight run. A 404 means the MODEL is unavailable — OpenAI authenticates
# before resolving the model, so a dead key can never reach 404 — and the
# probe warns and retries pinned alternates rather than misreporting it as a
# credential failure. Any status other than 200/401/403/404/429/5xx is
# treated as NOT ready (fail closed) — see cfp_api_reachable.
#
# USAGE
#   source "$DIR/cross-family-preflight.sh"
#   cfp_run            # prints the verdict block to stdout, sets $CFP_VERDICT
#   cfp_log_deviation <agent> <verdict> <decision> [note]
#
# VERDICTS (also the exit status of cfp_run: 0 READY, non-zero otherwise)
#   READY            a usable path exists (CLI reachable, or key authenticates
#                    AND has quota — the quota probe returned 200)
#   BLOCKED_NETWORK  a credential exists but api.openai.com is NOT reachable
#                    (failure mode 2 — environment/network-policy fix
#                    required), OR the base URL failed the host allowlist, OR
#                    the quota probe hit a transient 5xx (retry, not a
#                    credential problem)
#   BLOCKED_NOCREDS  no codex CLI and no OPENAI_API_KEY (failure mode 1), OR a
#                    key is present but rejected (401/403 — revoked/
#                    truncated), out of quota (429 — no billing/credits), or
#                    the probe got an unrecognized status (fail closed)
#   BLOCKED_MODEL    the key authenticated, but the review model returned 404
#                    (model not found) — a model-availability/config problem,
#                    NOT a credential problem; fix is OPENAI_REVIEW_MODEL
#   PROBE_SKIPPED    no curl/jq/tooling to probe with (treat as unknown →
#                    degrade — jq is required to safely build the quota
#                    probe's JSON body when a key is present)

set -uo pipefail
{ set +x; } 2>/dev/null   # never echo the key under a caller's xtrace (matches openai-key.sh/openai-review.sh)

# Endpoint the OpenAI family (CLI and API) talks to.
#
# ADR-030-style host hardening: OPENAI_BASE_URL is honored ONLY when it is
# https AND its host is EXACTLY api.openai.com — otherwise an attacker-
# influenced env (project config, CI, compromised shell profile) could point
# this "safe reachability probe" at an arbitrary host and receive the real
# OPENAI_API_KEY. Unlike openai-review.sh's silent per-call fallback, this
# probe REFUSES outright (BLOCKED_NETWORK, distinct message) rather than
# quietly substituting a different endpoint — a preflight probe's whole job
# is to tell the truth about what's configured, not paper over it.
# CFP_ALLOW_CUSTOM_BASE=1 is an explicit, always-opt-in escape hatch for a
# genuinely trusted OpenAI-compatible mirror/proxy (e.g. self-hosted in a
# controlled CI env) — never implied by OPENAI_BASE_URL alone.
# SECURITY CONTRACT (Codex re-review, PR #138): this flag must only ever be
# set BY A HUMAN, in a shell profile or CI config they control. It shares
# the env trust boundary with the attack it bypasses, so any automation,
# hook, or agent that sets it defeats the validation entirely. Reviewers:
# treat any committed/scripted CFP_ALLOW_CUSTOM_BASE=1 as a finding.
CFP_API_BASE="${OPENAI_BASE_URL:-https://api.openai.com}"
CFP_PROBE_URL="${CFP_API_BASE%/}/v1/models"
CFP_PROBE_TIMEOUT="${CFP_PROBE_TIMEOUT:-6}"
# Model for the quota probe: the model the REVIEW will actually use —
# OPENAI_REVIEW_MODEL, the same variable openai-review.sh resolves into
# OAIR_MODEL (keep this default in sync with that file) — so a READY verdict
# proves the real review path works. The previous pin of a probe-only model
# id (gpt-5.5-mini) rotted independently of the review path: OpenAI retired
# it and a WORKING key started probing 404 → false BLOCKED_NOCREDS while
# gpt-5.5 review calls succeeded (observed 2026-08-03).
# PR #138's pin rationale (an env-settable probe model is a cost-abuse
# footgun) is preserved: there is NO new probe-only env knob —
# OPENAI_REVIEW_MODEL already governs the far larger real review spend,
# the tiny completion cap bounds the probe, and a Claude-family value is ignored
# (ADR-011: the probe must stay cross-family) in favor of the pinned default.
CFP_PROBE_MODEL_DEFAULT="gpt-5.5"
# Pinned alternates tried in order when a probe model returns 404 (model not
# found), so the verdict can distinguish "this model is gone" from "the
# account is dead". Deliberately not env-settable (PR #138 contract).
CFP_PROBE_FALLBACK_MODELS="gpt-5.5 gpt-5.4"

_cfp_probe_model() {
  local m="${OPENAI_REVIEW_MODEL:-$CFP_PROBE_MODEL_DEFAULT}"
  case "$(printf '%s' "$m" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    *claude*) m="$CFP_PROBE_MODEL_DEFAULT" ;;
  esac
  printf '%s' "$m"
}

_cfp_base_url_host() {
  local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"
  printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# 0 if CFP_API_BASE is allowed to receive a request (with or without a key).
# ADR-063 D6.1: the escape hatch is leashed, not removed — it still requires
# https, and every use is logged so a scripted/committed CFP_ALLOW_CUSTOM_BASE
# leaves an audit trail instead of a silent full bypass. Under the sandbox's
# network allowlist an off-list host dies at the OS layer regardless; the log
# line is what turns that silent death into a diagnosable event.
_cfp_base_url_ok() {
  if [[ "${CFP_ALLOW_CUSTOM_BASE:-}" == "1" ]]; then
    [[ "$CFP_API_BASE" == https://* ]] || return 1
    _cfp_log_custom_base
    return 0
  fi
  [[ "$CFP_API_BASE" == https://* ]] || return 1
  [[ "$(_cfp_base_url_host "$CFP_API_BASE")" == "api.openai.com" ]]
}

_cfp_log_custom_base() {
  local log_dir="${HOME:-/tmp}/.claude/logs"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg host "$(_cfp_base_url_host "$CFP_API_BASE")" \
         '{event:"cfp_custom_base", ts:$ts, host:$host}' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# Strip CR/LF from a header value before it goes anywhere near `-H @-` stdin —
# an embedded CR/LF in OPENAI_API_KEY could otherwise inject an extra header
# line into curl's parsed input. Ordinary API keys never contain these; this
# is defense-in-depth against a malformed/malicious env value.
_cfp_strip_crlf() {
  local v="$1"
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  printf '%s' "$v"
}

# --- vendor policy gate (ADR-071 D7 §10) ---------------------------------
# Reads the receipt scripts/sandbox-policy-compile.sh wrote for the repo
# containing $PWD, and answers "is $1 allowed to be called at all" BEFORE
# any key is read or any network call is made. Host-parameterized so a
# future phase can wire additional hosts; only api.openai.com is wired into
# cfp_run today (ADR-071 D10 leaves the other four vendor helpers untouched).
cfp_vendor_policy() {
  local host="$1"
  CFP_VENDOR_LEVEL=""
  CFP_VENDOR_RECEIPT_VERDICT=""
  local repo receipt_key receipt cfg
  repo="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$repo" ]] && { echo "unknown"; return; }
  command -v python3 >/dev/null 2>&1 || { echo "unknown"; return; }
  command -v jq >/dev/null 2>&1 || { echo "unknown"; return; }
  receipt_key="$(printf '%s' "$repo" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])' 2>/dev/null)"
  [[ -z "$receipt_key" ]] && { echo "unknown"; return; }
  receipt="${CFP_RECEIPT_DIR:-$HOME/.claude/session-state/sandbox-policy}/$receipt_key.json"
  [[ -f "$receipt" ]] || { echo "unknown"; return; }
  cfg="$repo/.claude/stack-config.json"
  # Receipt older than stack-config.json mtime: the compiler has not seen
  # the current config yet (a recompile is pending) -- treat as unknown
  # rather than trust stale data.
  if [[ -f "$cfg" && "$cfg" -nt "$receipt" ]]; then echo "unknown"; return; fi

  CFP_VENDOR_LEVEL="$(jq -r '.level // "normal"' "$receipt" 2>/dev/null)"
  CFP_VENDOR_RECEIPT_VERDICT="$(jq -r '.verdict // empty' "$receipt" 2>/dev/null)"

  # ADR-071 D8: only a genuinely COMPILED receipt is trustworthy above
  # normal. Security-audit CRITICAL fix, 2026-08-11 -- this previously only
  # checked CLOUD_HOOK_ONLY; the runbook's own claim ("FLOOR_ABSENT blocks
  # sessions above normal") was not backed by any code. FLOOR_ABSENT,
  # WALL_ABSENT, RESTRICTED_FALLBACK, and DISABLED are ALL untrustworthy in
  # the same way at this level -- an un-overridable guarantee is either
  # fully in force or it is not trustworthy at all above normal.
  if [[ "$CFP_VENDOR_RECEIPT_VERDICT" != "COMPILED" && "$CFP_VENDOR_LEVEL" != "normal" ]]; then
    echo "denied"; return
  fi

  local allowed denied
  allowed="$(jq -r --arg h "$host" '(.allowed_hosts // []) | index($h) != null' "$receipt" 2>/dev/null)"
  denied="$(jq -r --arg h "$host" '(.denied_hosts // []) | index($h) != null' "$receipt" 2>/dev/null)"
  if [[ "$allowed" == "true" ]]; then echo "allowed"; return; fi
  if [[ "$denied" == "true" ]]; then echo "denied"; return; fi
  echo "unknown"
}

# Reads sensitivity.level straight off stack-config.json (no receipt
# required) -- used only to decide "unknown -> BLOCKED_POLICY iff level >
# normal" when there is no receipt at all to consult (R5).
_cfp_repo_level_raw() {
  local repo cfg lvl
  repo="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$repo" ]] && { echo "normal"; return; }
  cfg="$repo/.claude/stack-config.json"
  [[ -f "$cfg" ]] || { echo "normal"; return; }
  command -v jq >/dev/null 2>&1 || { echo "normal"; return; }
  lvl="$(jq -r '.sensitivity.level // "normal"' "$cfg" 2>/dev/null)"
  case "$lvl" in normal|sensitive|confidential) echo "$lvl" ;; *) echo "normal" ;; esac
}

# --- individual checks (each prints a yes/no token, no side effects) ----------

# Portable bounded run (macOS lacks coreutils `timeout`): SIGALRM via perl+exec.
# A quarantined codex can HANG (no output, no exit — observed on the box that
# motivated ADR-030), so the probe must be time-bounded or it stalls the whole
# preflight. Falls back to a direct run only if perl is unavailable.
_cfp_timeout() {
  local s="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift @ARGV; alarm $s; exec @ARGV; exit 127' "$s" "$@" 2>/dev/null
    return $?
  fi
  # No perl: bash watchdog so a hung `codex --version` can't stall the probe
  # (do NOT fall through to an unbounded run — that re-opens the ADR-030 hang).
  "$@" & local p=$!
  ( sleep "$s"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

# Runnable, not merely present (ADR-030), AND time-bounded: `codex --version`
# actually invokes the binary, so a quarantined/malware-blocked codex (present on
# PATH but killed or HUNG at exec) reports `no` within the timeout. `command -v
# codex` alone masked exactly that failure — the bug ADR-030 fixes and ADR-022
# intended to catch. Only called in cli mode (see cfp_run) — never in api mode.
cfp_have_cli() {
  command -v codex >/dev/null 2>&1 || { echo no; return; }
  if _cfp_timeout "${CFP_CLI_PROBE_TIMEOUT:-8}" codex --version >/dev/null 2>&1; then echo yes; else echo no; fi
}

cfp_have_key() {
  # The key must reach THIS (the subagent's) shell — printenv, not a settings
  # file. Empty or unset both count as absent.
  [[ -n "${OPENAI_API_KEY:-}" ]] && echo yes || echo no
}

cfp_api_reachable() {
  # Host allowlist gate FIRST — refuse before any network call at all (with
  # or without a key) rather than silently substituting a safe default.
  _cfp_base_url_ok || { echo blocked_base_url; return; }

  if ! command -v curl >/dev/null 2>&1; then echo unknown; return; fi

  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    # No key: unauthenticated GET to the free /v1/models endpoint. This is a
    # pure network/policy check (used by the CLI-only fallback), not an auth
    # check — no key to send, no key to protect.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
              --max-time "$CFP_PROBE_TIMEOUT" \
              -- "$CFP_PROBE_URL" 2>/dev/null)" || code="000"
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      echo yes    # any real HTTP status just proves the endpoint answered
    else
      echo no     # 000 (no connection) or unrecognized -w output — fail closed
    fi
    return
  fi

  # Key present. jq is required to safely build the probe's JSON body (the
  # model name is env-controlled; hand-building JSON would need to escape
  # it). Treat "can't safely build the request" the same as "no curl".
  command -v jq >/dev/null 2>&1 || { echo unknown; return; }

  # QUOTA-SENSITIVE probe: the cheapest real chat completion (tiny token cap),
  # NOT the free /v1/models list — that endpoint returns 200 for a zero-
  # credit key and proves nothing about usability (see the file header).
  # The probe model is the one the review will actually use (see
  # _cfp_probe_model). A 404 (model not found) is retried against the pinned
  # alternates: OpenAI authenticates BEFORE resolving the model, so a dead
  # key gets 401 here, never 404 — a 404 is model trouble, not credential
  # trouble, and must never be reported as BLOCKED_NOCREDS.
  local key primary m http body
  key="$(_cfp_strip_crlf "$OPENAI_API_KEY")"
  primary="$(_cfp_probe_model)"
  local candidates=("$primary") alt
  for alt in $CFP_PROBE_FALLBACK_MODELS; do
    [[ "$alt" == "$primary" ]] || candidates+=("$alt")
  done
  # Token-limit param: gpt-5.5-era models REJECT legacy max_tokens with 400
  # ("use max_completion_tokens instead"), which fell through to
  # unexpected:400 → false BLOCKED_NOCREDS on a WORKING key (observed
  # 2026-08-04). Probe with max_completion_tokens first; on a 400, retry the
  # SAME model once with legacy max_tokens (older/proxy OpenAI-compatible
  # endpoints that predate the new param). The probe sees only the status
  # code (no body), so a 400 on BOTH params still falls through to
  # unexpected:400 — fail-closed behavior unchanged for genuine 400s.
  #
  # The cap is 16, not 1: reasoning models (gpt-5.5) burn completion-token
  # budget on reasoning before any output, and a cap of 1 draws a DIFFERENT
  # 400 ("model output limit was reached") even with the right param name
  # (live-reproduced 2026-08-04; cap=16 returns 200 with ~4 tokens used).
  http="404"
  local p
  for m in "${candidates[@]}"; do
    for p in max_completion_tokens max_tokens; do
      body="$(jq -nc --arg model "$m" --arg limit_param "$p" \
        '{model:$model, messages:[{role:"user",content:"ping"}]} + {($limit_param): 16}')"
      # ADR-030 hardening: the auth header is piped in on stdin (-H @-), NOT
      # passed on the command line, so the key never lands in this curl's argv
      # (visible to other local users via `ps`/`/proc`) — identical pattern to
      # oair_api_call (openai-review.sh). curl is last in the pipe so its own
      # exit code already propagates without pipefail; the printf is guarded
      # with `|| :` so an EPIPE (curl exiting before reading stdin — real curl
      # on an early network error, mocked curl in tests) can't trip pipefail
      # into a false http=000 (flaked in CI 2026-08-11). A header that truly
      # never reaches curl just yields 401 → unauthorized, still fail-closed.
      # Note: curl's own process environment
      # still inherits OPENAI_API_KEY (this shell's env) — the stdin trick only
      # avoids argv exposure, not env-based inspection (/proc/<pid>/environ);
      # that's an accepted, documented tradeoff shared with oair_api_call.
      http="$({ printf 'Authorization: Bearer %s\n' "$key" || :; } \
        | curl -s -o /dev/null -w '%{http_code}' \
            --max-time "$CFP_PROBE_TIMEOUT" \
            -H @- \
            -H 'Content-Type: application/json' \
            -d "$body" \
            -- "${CFP_API_BASE%/}/v1/chat/completions" 2>/dev/null)" || http="000"
      [[ "$http" == "400" && "$p" == "max_completion_tokens" ]] || break
      echo "[cross-family-preflight] WARN: probe with max_completion_tokens returned 400 on '$m' — retrying with legacy max_tokens" >&2
    done
    # Only the FINAL status of the param pair is inspected here. A 400 on the
    # first param followed by a 404 on the legacy retry reads as "model not
    # found" and advances to the alternate — intentional: the status-only
    # probe cannot distinguish "unsupported param" from a genuine bad
    # request, and a 404 on the same model is the stronger signal. No
    # fail-open risk: 401/403/429/5xx break both loops immediately above.
    [[ "$http" == "404" ]] || break
    echo "[cross-family-preflight] WARN: probe model '$m' returned 404 (model not found) — trying alternate" >&2
  done

  if [[ "$http" == "000" ]]; then
    echo no   # could not connect (DNS/refused/timeout/classifier-deny)
    return
  fi
  case "$http" in
    200)
      if [[ "$m" == "$primary" ]]; then
        echo yes                  # authenticated AND has quota, on the review model
      else
        # Creds + quota verified — but only via a fallback model: the model
        # the review would actually use is gone. READY would strand the
        # review mid-call on the same 404, so report it distinctly.
        echo "model_fallback:${primary}:${m}"
      fi ;;
    401|403) echo unauthorized ;; # key rejected — dead/revoked/truncated
    404) echo "model_unavailable:${primary}" ;;  # every candidate model 404'd
    429) echo quota ;;            # key authenticated fine, no remaining quota/credits
    5[0-9][0-9])
      # Transient upstream error — not evidence this key/account is unusable.
      # Hard-blocking on it would make preflight flap on OpenAI-side blips,
      # so this is reported as retryable (BLOCKED_NETWORK), not BLOCKED_NOCREDS.
      echo transient ;;
    [1-5][0-9][0-9]) echo "unexpected:${http}" ;;  # e.g. 400/422 — fail closed, never guess READY
    *) echo no ;;   # not a recognized 3-digit code (broken/incompatible curl) — fail closed
  esac
}

# --- verdict ------------------------------------------------------------------

cfp_run() {
  local cli key reach verdict fix mf

  # --- ADR-071 D7 §10: vendor policy gate, FIRST — before any key read or
  # network call. A denied/untrustworthy verdict here short-circuits the
  # whole probe: no key is read, no curl is issued.
  # NOTE: cfp_vendor_policy is called via command substitution, which forks a
  # subshell — its CFP_VENDOR_LEVEL/CFP_VENDOR_RECEIPT_VERDICT side-effect
  # globals do not survive back into this shell. _cfp_repo_level_raw() reads
  # stack-config.json directly instead, so it works regardless.
  local vendor_decision vendor_level
  vendor_decision="$(cfp_vendor_policy api.openai.com)"
  vendor_level="$(_cfp_repo_level_raw)"
  local vendor_line="vendor_policy     : $vendor_decision (${vendor_level}; api.openai.com — config/vendor-hosts.json)"

  local policy_blocked=0
  if [[ "$vendor_decision" == "denied" ]]; then
    policy_blocked=1
  elif [[ "$vendor_decision" == "unknown" && "$vendor_level" != "normal" ]]; then
    policy_blocked=1
  fi

  if [[ "$policy_blocked" -eq 1 ]]; then
    verdict="BLOCKED_POLICY"
    fix="Clear api.openai.com in config/vendor-hosts.json with a reviewed_on date, or lower this repo's sensitivity with /sensitivity. See docs/ADRs/071-sandbox-vendor-host-compile.md."
    CFP_VERDICT="$verdict"
    cat <<EOF
=== cross-family preflight (ADR-022 / ADR-030) ===
codex_transport   : n/a (blocked before transport resolution)
codex CLI runnable: n/a
OPENAI_API_KEY    : n/a (blocked before key read — ADR-071 D7)
api.openai.com    : n/a (blocked before any network call — ADR-071 D7)
$vendor_line
VERDICT           : $verdict
FIX               : $fix
==================================================
EOF
    return 1
  fi

  # ADR-028: fill OPENAI_API_KEY from the Keychain backup (openai-api-key) IFF it
  # is not already set, BEFORE the env-based key check — so a local box with the
  # Keychain item passes preflight even when the Codex CLI auth is gone. Cloud env
  # always wins (oai_export is a no-op when OPENAI_API_KEY is already set).
  local _oai_lib="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib/openai-key.sh"
  [[ -f "$_oai_lib" ]] || _oai_lib="$(dirname "${BASH_SOURCE[0]:-${0:-.}}")/openai-key.sh"
  # shellcheck source=/dev/null
  [[ -f "$_oai_lib" ]] && { source "$_oai_lib"; oai_export 2>/dev/null || true; }

  # Transport (ADR-030): resolve via the review helper so preflight and the agent
  # agree. api → a runnable CLI does NOT count as a usable path (READY hinges on
  # key + reachable API); cli → the CLI counts (ADR-022 behavior), API is fallback.
  local _oair_lib="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/lib/openai-review.sh"
  [[ -f "$_oair_lib" ]] || _oair_lib="$(dirname "${BASH_SOURCE[0]:-${0:-.}}")/openai-review.sh"
  # shellcheck source=/dev/null
  local transport="api"
  [[ -f "$_oair_lib" ]] && { source "$_oair_lib"; transport="$(oair_transport)"; }

  # Only probe the CLI when it can affect the verdict (cli mode). In api mode the
  # CLI is irrelevant AND a quarantined binary can HANG `codex --version` — so we
  # must NOT probe it (that would stall preflight even when the API path is fine).
  if [[ "$transport" == "cli" ]]; then cli="$(cfp_have_cli)"; else cli="n/a (api — not probed)"; fi
  key="$(cfp_have_key)"

  # A usable credential path is transport-dependent (ADR-030). api: key only —
  # CLI presence is no longer evidence of capability (the malware-block lesson).
  # cli: a runnable CLI OR a key. If neither → BLOCKED_NOCREDS.
  local usable="no"
  if [[ "$transport" == "api" ]]; then
    [[ "$key" == "yes" ]] && usable="yes"
  else
    { [[ "$cli" == "yes" || "$key" == "yes" ]]; } && usable="yes"
  fi

  if [[ "$usable" == "no" ]]; then
    verdict="BLOCKED_NOCREDS"
    reach="n/a"
    if [[ "$transport" == "api" ]]; then
      fix="Set OPENAI_API_KEY in the ENVIRONMENT (printenv, not settings.local.json) or the Keychain 'openai-api-key' (ADR-028). Transport is 'api' (ADR-030) — the codex CLI is not used. See docs/runbooks/cross-family-review-cloud.md."
    else
      fix="No RUNNABLE codex CLI and no OPENAI_API_KEY reach this shell. Set the key (env or Keychain 'openai-api-key'), or set codex_transport=api. See docs/runbooks/cross-family-review-cloud.md."
    fi
  else
    reach="$(cfp_api_reachable)"
    if [[ "$reach" == "yes" ]]; then
      verdict="READY"
      fix="none"
    elif [[ "$reach" == "unauthorized" ]]; then
      verdict="BLOCKED_NOCREDS"
      fix="OPENAI_API_KEY reached this shell and api.openai.com is reachable, but the key was REJECTED (401/403) — it is revoked, truncated, or invalid. Set a valid key in the ENVIRONMENT (not settings.local.json) or the Keychain 'openai-api-key' (ADR-028). See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == "quota" ]]; then
      verdict="BLOCKED_NOCREDS"
      fix="OPENAI_API_KEY reached this shell and AUTHENTICATED successfully, but api.openai.com returned 429 — the account has no remaining quota/credits (not an auth problem: the key itself is valid). Add billing/credits to the OpenAI account, or set a different OPENAI_API_KEY that has quota. See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == model_fallback:* ]]; then
      # NOT a credential failure: the key authenticated AND has quota (a
      # fallback model probed 200) — only the configured review model is gone.
      mf="${reach#model_fallback:}"
      verdict="BLOCKED_MODEL"
      fix="The review model '${mf%%:*}' returned 404 (model not found), but the key authenticated and has quota — the probe verified the account via '${mf#*:}'. Set OPENAI_REVIEW_MODEL to an available model (e.g. '${mf#*:}') and re-run. See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == model_unavailable:* ]]; then
      verdict="BLOCKED_MODEL"
      fix="The review model '${reach#model_unavailable:}' and every pinned alternate (${CFP_PROBE_FALLBACK_MODELS}) returned 404 (model not found). The key authenticated (OpenAI resolves the model only AFTER auth), so this is model availability/config — NOT credentials. Set OPENAI_REVIEW_MODEL to a model this account can use. See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == unexpected:* ]]; then
      verdict="BLOCKED_NOCREDS"
      fix="OPENAI_API_KEY reached this shell and api.openai.com is reachable, but the quota probe returned an UNEXPECTED status (${reach#unexpected:}) — not one of 200/401/403/404/429/5xx. Failing closed rather than assuming READY. Investigate manually, or set a different/valid OPENAI_API_KEY. See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == "transient" ]]; then
      verdict="BLOCKED_NETWORK"
      fix="api.openai.com answered the quota probe with a 5xx (transient upstream error) — not a credential problem. Retry; if it persists, check https://status.openai.com. See docs/runbooks/cross-family-review-cloud.md."
    elif [[ "$reach" == "blocked_base_url" ]]; then
      verdict="BLOCKED_NETWORK"
      fix="OPENAI_BASE_URL ('${OPENAI_BASE_URL:-}') is not the vetted https://api.openai.com host — refusing to send OPENAI_API_KEY to an unverified endpoint. Unset OPENAI_BASE_URL, or set CFP_ALLOW_CUSTOM_BASE=1 to explicitly opt into a trusted custom/mirror host (see the CFP_API_BASE comment in cross-family-preflight.sh)."
    elif [[ "$reach" == "unknown" ]]; then
      verdict="PROBE_SKIPPED"
      fix="curl (or jq, needed to safely build the quota probe body when a key is present) not available to probe; treat cross-family as unverified."
    else
      verdict="BLOCKED_NETWORK"
      fix="Allow api.openai.com at the ENVIRONMENT / network-policy layer (NOT settings.local.json — that is classifier-blocked by design). See docs/runbooks/cross-family-review-cloud.md."
    fi
  fi

  CFP_VERDICT="$verdict"

  cat <<EOF
=== cross-family preflight (ADR-022 / ADR-030) ===
codex_transport   : $transport
codex CLI runnable: $cli
OPENAI_API_KEY    : $key   (env or Keychain, THIS shell)
api.openai.com    : $reach
$vendor_line
VERDICT           : $verdict
FIX               : $fix
==================================================
EOF

  [[ "$verdict" == "READY" ]]
}

# --- deviation logging (best-effort; never fails the caller) ------------------
# Appends one row to the same log subagent-log.sh writes, so /carbonight and
# reviews can surface "N cross-family deviations this session."
cfp_log_deviation() {
  local agent="${1:-unknown}" verdict="${2:-unknown}" decision="${3:-unknown}" note="${4:-}"
  command -v jq >/dev/null 2>&1 || return 0
  local log_dir="$HOME/.claude/logs"; mkdir -p "$log_dir" 2>/dev/null || return 0
  local project
  project="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$project" \
    --arg agent "$agent" \
    --arg verdict "$verdict" \
    --arg decision "$decision" \
    --arg note "${note:0:300}" \
    '{event:"cross_family_deviation", ts:$ts, project:$project, agent:$agent,
      preflight_verdict:$verdict, decision:$decision, note:$note}' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# Allow direct execution for the preflight probe (CI / manual / agent one-shot).
# Both expansions are guarded: bare `${BASH_SOURCE[0]}` ABORTS under zsh with
# `set -u` rather than evaluating empty, which made sourcing this file from an
# interactive zsh kill the caller mid-way and surface as "policy unavailable".
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  cfp_run
fi
