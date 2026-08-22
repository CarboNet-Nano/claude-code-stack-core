#!/usr/bin/env bash
# org-check — "are you ready to work?" for a non-technical team member.
# Backs the /carbonet skill (org-agnostic by design: A-D4 in the architect
# handoff). Reads ~/.claude/config/org.json for org identity + which provider
# keys matter; checks five things in one pass; never prints a key, a
# credential, or an HTTP status number.
#
# Usage:
#   scripts/org-check.sh [--deep] [--json] [--no-network] [--org-config PATH]
#                        [--stack-config PATH] [--help]
#
#   --deep           run the real (billable) quota probes instead of the free
#                     auth-only check. Off by default.
#   --json            machine-readable verdict on stdout.
#   --no-network      skip every network call; access + provider-liveness
#                     degrade to "not checked (offline mode)". Verdict can
#                     never be READY under this flag.
#   --org-config PATH   test hook — override the org.json path.
#   --stack-config PATH test hook — override the project's stack-config.json
#                       path (skips the normal nearest-parent search).
#
# Exit codes:
#   0   READY        — every check passed
#   10  NOT READY     — at least one check failed
#   20  ALMOST READY  — no failures, but at least one check is unknown
#   2   usage error, or org.json is missing/malformed/invalid (a TOOL
#       failure, distinct from a user-facing NOT READY)
#
# Constraints (architect handoff §A.4/A.7, "Constraints for the implementer"):
#   - no key value is ever read into anything that is printed, logged,
#     cached, or written to disk (set +x below; only presence/status is used)
#   - writes nothing, ever — no cache, no state file, no log line
#   - never prints READY while any check is unknown
#   - vocabulary gate: no API/token/credential/keychain/env/export/HTTP
#     status numbers/"exit code" in user-facing output

set -uo pipefail
{ set +x; } 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_HOME="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}"

DEEP=0
JSON_OUT=0
NO_NETWORK=0
ORG_CONFIG=""
STACK_CONFIG_OVERRIDE=""

usage() {
  cat <<'EOF'
org-check.sh [--deep] [--json] [--no-network] [--org-config PATH]
             [--stack-config PATH] [--help]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep) DEEP=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --no-network) NO_NETWORK=1; shift ;;
    --org-config)
      # A trailing --org-config with no value must exit, not hang: `shift 2`
      # on a 1-arg-remaining argv fails under `set -u` (no `-e` to abort on
      # it), so $# never shrinks and the while loop re-processes this same
      # arg forever (reproduced: reviewer finding, 2026-08-11).
      (( $# >= 2 )) || { echo "org-check: --org-config requires a value" >&2; exit 2; }
      ORG_CONFIG="$2"; shift 2 ;;
    --org-config=*) ORG_CONFIG="${1#*=}"; shift ;;
    --stack-config)
      (( $# >= 2 )) || { echo "org-check: --stack-config requires a value" >&2; exit 2; }
      STACK_CONFIG_OVERRIDE="$2"; shift 2 ;;
    --stack-config=*) STACK_CONFIG_OVERRIDE="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "org-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "org-check: jq is required" >&2; exit 2; }

# ---------------------------------------------------------------- resolvers
# Same lib either at the installed location (~/.claude/<rel>) or, when run
# from a repo checkout (dev/test), at <repo-root>/<rel> — matches every
# tier-manifest from/to pair this script depends on.
resolve_lib() {
  local rel="$1" installed="$CLAUDE_HOME/$1" repo="$REPO_ROOT/$1"
  [[ -f "$installed" ]] && { printf '%s' "$installed"; return; }
  printf '%s' "$repo"
}

# _scv_safe_source <lib-path> <fn1> [<fn2> ...]
# Sources <lib-path> and returns 0 only if BOTH the `source` command itself
# exited 0 AND every named function is defined afterward. Checking function
# existence alone is not enough: a library that fails to load part-way can
# still leave a stub of the function behind (defined earlier in the file,
# before whatever failed) — bash keeps function definitions that already
# executed even when a later command in the same sourced file errors and
# `source` itself returns non-zero. Every "source a lib, then call its
# functions" site in this script must go through this, not just check
# `declare -f` (reviewer finding, round 4: the round-3 fix checked function
# existence only, and only at 3 of the 4 sites — the ORIGINAL repro site,
# Check 4's `scv_validate` caller, was untouched; a stub `scv_validate`
# defined despite a failed `source` still made an invalid config read ✅).
_scv_safe_source() {
  local lib="$1"; shift
  # shellcheck disable=SC1090
  source "$lib" 2>/dev/null
  local rc=$?
  (( rc == 0 )) || return 1
  local fn
  for fn in "$@"; do
    declare -f "$fn" >/dev/null 2>&1 || return 1
  done
  return 0
}

# --------------------------------------------------------------- sanitizer
# ADR-072 D10 (Stage 2): the five vocabulary-gate functions used to be
# defined inline here. They are now a pure move to lib/plain-text-guard.sh
# (same names, same bodies, same comments — nothing about the allowlist-by-
# outcome design changed), shared with scripts/session-brief.sh.
#
# Rev 2's fail-SAFE fix for finding 8: rev 1 exited 2 when the lib was
# unresolvable, bricking the primary welcome screen over a half-finished
# `update.sh`. There IS a safe state available, so failing closed was a
# choice to brick. If the lib can't be sourced (missing, or fails partway —
# `_scv_safe_source` catches both), this script enters "untrusted-everything
# mode": sanitize_field/sanitize_path are redefined right here as
# UNCONDITIONAL placeholder returns — every config-derived value prints as
# a placeholder, and the ✅/❌/⚠️ rows, the verdict, and the exit code all
# still work. There is no second copy of the detection logic in that mode,
# because there is no detection at all — that is exactly why it's safe.
GUARD_DEGRADED=0
_PTG_LIB="$(resolve_lib lib/plain-text-guard.sh)"
if ! _scv_safe_source "$_PTG_LIB" _scv_has_non_ascii _scv_contains_banned_words _scv_contains_banned_vocab sanitize_field sanitize_path; then
  GUARD_DEGRADED=1
  sanitize_field() { printf '%s' "${3:-(from your settings)}"; }
  sanitize_path()  { printf '%s' "${3:-(path hidden)}"; }
fi

# ------------------------------------------------------------------- org.json
[[ -n "$ORG_CONFIG" ]] || ORG_CONFIG="$CLAUDE_HOME/config/org.json"

# The path itself is not usually attacker-controlled the way JSON field
# VALUES are (it's a --org-config argv value or a fixed install location),
# but a caller-influenced path could still carry gated vocabulary, so these
# tool-failure messages route it through the same sanitizer rather than
# assuming paths are exempt.
if [[ ! -f "$ORG_CONFIG" ]]; then
  echo "org-check: org config not found: $(sanitize_path "$ORG_CONFIG")" >&2
  exit 2
fi
if ! jq -e . "$ORG_CONFIG" >/dev/null 2>&1; then
  echo "org-check: org config is not valid JSON: $(sanitize_path "$ORG_CONFIG")" >&2
  exit 2
fi

ORG_ID="$(jq -r '.org.id // empty' "$ORG_CONFIG")"
ORG_DISPLAY="$(jq -r '.org.display_name // empty' "$ORG_CONFIG")"
ACCESS_URL="$(jq -r '.org.access_url // empty' "$ORG_CONFIG")"
SUPPORT_CONTACT="$(jq -r '.org.support_contact // empty' "$ORG_CONFIG")"
# Fallback wiring uses the RAW values (an empty string must still fall
# through); sanitization happens after, right before these ever reach output.
[[ -n "$ORG_DISPLAY" ]] || ORG_DISPLAY="${ORG_ID:-this org}"
[[ -n "$SUPPORT_CONTACT" ]] || SUPPORT_CONTACT="your admin"
ORG_ID="$(sanitize_field "$ORG_ID" 60)"
ORG_DISPLAY="$(sanitize_field "$ORG_DISPLAY" 60)"
SUPPORT_CONTACT="$(sanitize_field "$SUPPORT_CONTACT" 120)"

if [[ "$ACCESS_URL" != https://* ]]; then
  # access_url is attacker/admin-controlled free text at this point (the
  # https:// prefix hasn't even been confirmed yet) — must go through the
  # sanitizer before it's echoed, not printed raw (reviewer finding,
  # 2026-08-11 re-verification: this exact site leaked "TokEn-leak-test").
  # No CarboNet-specific host allowlist here on purpose: A-D4 requires this
  # script stay org-agnostic (a future /lade must work with a different
  # domain), so the fix is "never echo the raw value," not "only allow
  # *.carbonet.app".
  SAFE_ACCESS_URL="$(sanitize_field "${ACCESS_URL:-<empty>}" 200 "(from your settings)")"
  SAFE_ORG_CONFIG_PATH="$(sanitize_path "$ORG_CONFIG")"
  echo "org-check: org config access_url must be https:// — got '${SAFE_ACCESS_URL}' in $SAFE_ORG_CONFIG_PATH" >&2
  exit 2
fi

declare -a REQUIRED_PROVIDERS=()
while IFS= read -r p; do
  [[ -n "$p" ]] && REQUIRED_PROVIDERS+=("$p")
done < <(jq -r '.org.required_providers[]? // empty' "$ORG_CONFIG")

if (( ${#REQUIRED_PROVIDERS[@]} )); then
  for p in "${REQUIRED_PROVIDERS[@]}"; do
    case "$p" in
      anthropic|openai|gemini) ;;
      *)
        echo "org-check: unknown provider in required_providers: $(sanitize_field "$p" 60) ($(sanitize_path "$ORG_CONFIG"))" >&2
        exit 2
        ;;
    esac
  done
fi

provider_required() {
  local want="$1" p
  (( ${#REQUIRED_PROVIDERS[@]} )) || return 1
  for p in "${REQUIRED_PROVIDERS[@]}"; do [[ "$p" == "$want" ]] && return 0; done
  return 1
}

# ------------------------------------------------------------- effective tier
# repo tier: nearest .claude/stack-config.json's .stack_tier, else
# ~/.claude/stack-defaults.json's .default_tier, else 0.
# installed tier: ~/.claude/.stack-install.json's .tier, else 5 (assume
# fully-installed rather than under-provisioned when the stamp is absent).
# effective = min(repo, installed).
STACK_CONFIG_PATH="$STACK_CONFIG_OVERRIDE"
if [[ -z "$STACK_CONFIG_PATH" ]]; then
  FIND_CFG_LIB="$(resolve_lib lib/find-stack-config.sh)"
  if [[ -f "$FIND_CFG_LIB" ]]; then
    STACK_CONFIG_PATH="$(bash "$FIND_CFG_LIB" "$PWD" 2>/dev/null)"
  fi
fi

resolve_repo_tier() {
  if [[ -n "$STACK_CONFIG_PATH" && -f "$STACK_CONFIG_PATH" ]] && jq -e . "$STACK_CONFIG_PATH" >/dev/null 2>&1; then
    local t; t="$(jq -r '.stack_tier // empty' "$STACK_CONFIG_PATH" 2>/dev/null)"
    if [[ "$t" =~ ^[0-9]+$ ]]; then printf '%s' "$t"; return; fi
  fi
  local defaults="$CLAUDE_HOME/stack-defaults.json"
  if [[ -f "$defaults" ]]; then
    local d; d="$(jq -r '.default_tier // empty' "$defaults" 2>/dev/null)"
    if [[ "$d" =~ ^[0-9]+$ ]]; then printf '%s' "$d"; return; fi
  fi
  printf '0'
}

resolve_installed_tier() {
  local stamp="$CLAUDE_HOME/.stack-install.json"
  if [[ -f "$stamp" ]]; then
    local t; t="$(jq -r '.tier // empty' "$stamp" 2>/dev/null)"
    if [[ "$t" =~ ^[0-9]+$ ]]; then printf '%s' "$t"; return; fi
  fi
  printf '5'
}

REPO_TIER="$(resolve_repo_tier)"
INSTALLED_TIER="$(resolve_installed_tier)"
EFFECTIVE_TIER=$(( REPO_TIER < INSTALLED_TIER ? REPO_TIER : INSTALLED_TIER ))

# ----------------------------------------------------------------- glyphs
GLYPH_OK="✅"
GLYPH_FAIL="❌"
GLYPH_WARN="⚠️"

plural_things() { [[ "$1" == "1" ]] && printf 'thing' || printf 'things'; }

generic_warn_fix() {
  printf 'nothing for you to do. %s if work is blocked.' "$SUPPORT_CONTACT"
}

# ============================================================ Check 1: Keys
KEYS_STATUS="ok"
KEYS_DETAIL=""
KEYS_FIX=""
declare -a KEYS_ITEM_PROVIDER=() KEYS_ITEM_STATUS=() KEYS_ITEM_REASON=() KEYS_ITEM_TEXT=()
SKIP_PROVIDER_PROBES=0

worse() {
  # echoes the worse of two statuses (fail > warn > ok)
  local a="$1" b="$2"
  [[ "$a" == "fail" || "$b" == "fail" ]] && { echo fail; return; }
  [[ "$a" == "warn" || "$b" == "warn" ]] && { echo warn; return; }
  echo ok
}

add_key_item() {
  # add_key_item <provider> <status> <reason> <text> [<fix-if-not-ok>]
  KEYS_ITEM_PROVIDER+=("$1")
  KEYS_ITEM_STATUS+=("$2")
  KEYS_ITEM_REASON+=("$3")
  KEYS_ITEM_TEXT+=("$4")
  if [[ "$2" != "ok" && "$2" != "skipped" ]]; then
    KEYS_STATUS="$(worse "$KEYS_STATUS" "$2")"
    [[ -z "$KEYS_FIX" ]] && KEYS_FIX="${5:-}"
  fi
}

check_anthropic() {
  if ! command -v claude >/dev/null 2>&1; then
    add_key_item anthropic warn unreachable "Can't tell if Claude is signed in" "$(generic_warn_fix)"
    return
  fi
  local out rc logged
  out="$(claude auth status --json 2>/dev/null)"; rc=$?
  logged=""
  # NOTE: `.loggedIn // empty` would be wrong here — jq's `//` treats a real
  # JSON `false` as falsy too, silently collapsing "not signed in" into
  # "absent/unreachable". Compare explicitly instead.
  [[ $rc -eq 0 && -n "$out" ]] && logged="$(jq -r 'if .loggedIn == true then "true" elif .loggedIn == false then "false" else "" end' <<<"$out" 2>/dev/null)"
  case "$logged" in
    true)
      add_key_item anthropic ok "" "Claude signed in"
      ;;
    false)
      add_key_item anthropic fail not-signed-in "Claude not signed in" "Type: claude login"
      SKIP_PROVIDER_PROBES=1
      ;;
    *)
      add_key_item anthropic warn unreachable "Can't tell if Claude is signed in" "$(generic_warn_fix)"
      ;;
  esac
}

_curl_status_stdin() {
  # _curl_status_stdin <header-line> <url>  — GET, header piped on stdin so
  # the key never lands in curl's argv (visible via ps/proc).
  local header="$1" url="$2"
  printf '%s\n' "$header" \
    | curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 4 --max-time 6 \
        -H @- -- "$url" 2>/dev/null
}

check_openai() {
  local lib; lib="$(resolve_lib scripts/lib/openai-key.sh)"
  [[ -f "$lib" ]] || { add_key_item openai warn unreachable "Can't tell if the OpenAI key is set up" "$(generic_warn_fix)"; return; }
  if ! _scv_safe_source "$lib" oai_export oai_available; then
    add_key_item openai warn unreachable "Can't tell if the OpenAI key is set up" "$(generic_warn_fix)"
    return
  fi
  oai_export 2>/dev/null || true
  if ! oai_available; then
    add_key_item openai fail missing "OpenAI key missing" "the OpenAI key is not on this machine. $SUPPORT_CONTACT."
    return
  fi
  if (( NO_NETWORK )); then
    add_key_item openai warn offline "OpenAI key found, not checked (offline mode)" "$(generic_warn_fix)"
    return
  fi
  if (( DEEP )); then
    local cfp_lib; cfp_lib="$(resolve_lib scripts/lib/cross-family-preflight.sh)"
    if [[ ! -f "$cfp_lib" ]]; then
      add_key_item openai warn unreachable "Could not check OpenAI spending room" "$(generic_warn_fix)"
      return
    fi
    if ! _scv_safe_source "$cfp_lib" cfp_api_reachable; then
      add_key_item openai warn unreachable "Could not check OpenAI spending room" "$(generic_warn_fix)"
      return
    fi
    # cfp_api_reachable (not the higher-level cfp_run) is called directly:
    # cfp_run's verdict lands in the global $CFP_VERDICT, but running it via
    # `$(...)` to capture its printed block forks a subshell that variable
    # can never escape. cfp_api_reachable is the actual reused, hardened
    # probe (argv-safe auth header, model-fallback handling) — this still
    # satisfies "reused wholesale, never reimplemented" (A-D2).
    local reach
    reach="$(cfp_api_reachable)"
    case "$reach" in
      yes|model_fallback:*)
        add_key_item openai ok "" "OpenAI key accepted" ;;
      quota)
        add_key_item openai fail no-quota "OpenAI key has no spending room left" "$SUPPORT_CONTACT to add spending room for OpenAI." ;;
      unauthorized)
        add_key_item openai fail rejected "OpenAI key rejected" "the OpenAI key was turned down. $SUPPORT_CONTACT." ;;
      *)
        add_key_item openai warn unreachable "Could not check OpenAI spending room" "$(generic_warn_fix)" ;;
    esac
    return
  fi
  local key="${OPENAI_API_KEY:-}" code
  code="$(_curl_status_stdin "Authorization: Bearer ${key}" "https://api.openai.com/v1/models")"
  case "$code" in
    200) add_key_item openai ok "" "OpenAI key accepted" ;;
    401|403) add_key_item openai fail rejected "OpenAI key rejected" "the OpenAI key was turned down. $SUPPORT_CONTACT." ;;
    *) add_key_item openai warn unreachable "OpenAI key found, could not reach OpenAI" "$(generic_warn_fix)" ;;
  esac
}

check_gemini() {
  local lib; lib="$(resolve_lib scripts/lib/gemini-api.sh)"
  [[ -f "$lib" ]] || { add_key_item gemini warn unreachable "Can't tell if the Gemini key is set up" "$(generic_warn_fix)"; return; }
  if ! _scv_safe_source "$lib" gmn_available gmn_key; then
    add_key_item gemini warn unreachable "Can't tell if the Gemini key is set up" "$(generic_warn_fix)"
    return
  fi
  if ! gmn_available; then
    add_key_item gemini fail missing "Gemini key missing" "the Gemini key is not on this machine. $SUPPORT_CONTACT."
    return
  fi
  if (( NO_NETWORK )); then
    add_key_item gemini warn offline "Gemini key found, not checked (offline mode)" "$(generic_warn_fix)"
    return
  fi
  local key; key="$(gmn_key)"
  if (( DEEP )); then
    local code body resp
    body="$(jq -nc '{contents:[{parts:[{text:"ping"}]}],generationConfig:{maxOutputTokens:16}}')"
    resp="$(printf 'x-goog-api-key: %s\n' "$key" \
      | curl -s -w '\n%{http_code}' \
          --connect-timeout 4 --max-time 6 \
          -H @- -H 'Content-Type: application/json' -d "$body" \
          -- "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent" 2>/dev/null)"
    code="${resp##*$'\n'}"
    case "$code" in
      200) add_key_item gemini ok "" "Gemini key accepted" ;;
      429) add_key_item gemini fail no-quota "Gemini key has no spending room left" "$SUPPORT_CONTACT to add spending room for Gemini." ;;
      400|403) add_key_item gemini fail rejected "Gemini key rejected" "the Gemini key was turned down. $SUPPORT_CONTACT." ;;
      *) add_key_item gemini warn unreachable "Could not check Gemini spending room" "$(generic_warn_fix)" ;;
    esac

    # A-D20 (docs/plans/2026-08-11-gemini-paid-tier-precondition.md): advisory
    # tier report, reusing this SAME probe/response -- no second call. Provider
    # token is `gemini-tier`, NOT `gemini`: tests/test-carbonet-check.sh:257,267
    # select on .provider=="gemini", and a second such item would make those
    # selectors emit two lines. Status is warn, never fail: a free key is
    # perfectly usable at `normal`. Anything else (400/403/5xx/REFUSED/a 429
    # with no free_tier marker) adds no item at all -- never guess (finding 4).
    # 200 => ok is safe ONLY because this probe targets gemini-3.1-pro-preview
    # (the pinned model above), which has been paid-only since April 2026 -- a
    # free-tier key draws a 429 free-tier-quota-0 there, never 200 (reviewer
    # BLOCKING 2, 2026-08-11: REFUTED on this ground). If the pinned model is
    # ever demoted back onto the free tier, this 200 => ok mapping goes stale;
    # that model-demotion risk is the architect's accepted finding 4 (a dated,
    # human-owned claim with a hard expiry), and this is an advisory
    # warn-surface only -- it never gates the sandbox boundary.
    case "$code" in
      200)
        add_key_item gemini-tier ok "" "Your Gemini key is the paid kind"
        ;;
      429)
        local body_only free_tier_hit
        body_only="${resp%$'\n'*}"
        free_tier_hit="$(printf '%s' "$body_only" | jq -r '
          [(.error.details // [])[]
            | select((.["@type"] // "") | test("QuotaFailure"))
            | (.violations // [])[]
            | ((.quotaId // "") + " " + (.quotaMetric // ""))]
          | join(" ")
        ' 2>/dev/null)"
        if [[ "$free_tier_hit" == *free_tier* ]]; then
          add_key_item gemini-tier warn free-tier \
            "Your Gemini key is the free kind -- it cannot be used on sensitive work" \
            "$SUPPORT_CONTACT to turn on billing for Gemini."
        fi
        ;;
    esac
    return
  fi
  local code
  code="$(_curl_status_stdin "x-goog-api-key: ${key}" "https://generativelanguage.googleapis.com/v1beta/models")"
  case "$code" in
    200) add_key_item gemini ok "" "Gemini key accepted" ;;
    400|403) add_key_item gemini fail rejected "Gemini key rejected" "the Gemini key was turned down. $SUPPORT_CONTACT." ;;
    *) add_key_item gemini warn unreachable "Gemini key found, could not reach Gemini" "$(generic_warn_fix)" ;;
  esac
}

for provider in anthropic openai gemini; do
  provider_required "$provider" || continue
  case "$provider" in
    anthropic) check_anthropic ;;
    openai|gemini)
      if (( SKIP_PROVIDER_PROBES )); then
        KEYS_ITEM_PROVIDER+=("$provider"); KEYS_ITEM_STATUS+=("skipped"); KEYS_ITEM_REASON+=(""); KEYS_ITEM_TEXT+=("")
        continue
      fi
      if (( EFFECTIVE_TIER < 2 )); then
        KEYS_ITEM_PROVIDER+=("$provider"); KEYS_ITEM_STATUS+=("skipped"); KEYS_ITEM_REASON+=(""); KEYS_ITEM_TEXT+=("")
        continue
      fi
      [[ "$provider" == "openai" ]] && check_openai
      [[ "$provider" == "gemini" ]] && check_gemini
      ;;
  esac
done

join_by() {
  local sep="$1"; shift
  local out="" first=1 x
  for x in "$@"; do
    if (( first )); then out="$x"; first=0; else out="$out$sep$x"; fi
  done
  printf '%s' "$out"
}

declare -a KEYS_TEXT_PARTS=()
if (( ${#KEYS_ITEM_PROVIDER[@]} )); then
  for i in "${!KEYS_ITEM_PROVIDER[@]}"; do
    [[ "${KEYS_ITEM_STATUS[$i]}" == "skipped" ]] && continue
    KEYS_TEXT_PARTS+=("${KEYS_ITEM_TEXT[$i]}")
  done
fi
if (( ${#KEYS_TEXT_PARTS[@]} )); then
  KEYS_DETAIL="$(join_by ' · ' "${KEYS_TEXT_PARTS[@]}")"
else
  KEYS_DETAIL=""
fi

# =========================================================== Check 2: Access
ACCESS_STATUS="warn"
ACCESS_REASON=""
ACCESS_DETAIL=""
ACCESS_FIX="$(generic_warn_fix)"

if (( NO_NETWORK )); then
  ACCESS_REASON="offline"
  ACCESS_DETAIL="Not checked (offline mode)"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 6 -- "${ACCESS_URL%/}/" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    ACCESS_REASON="not-checkable-from-cli"
    ACCESS_DETAIL="Access app reachable — your sign-in is not checkable from here yet"
  else
    ACCESS_REASON="unreachable"
    ACCESS_DETAIL="Could not reach the access app"
  fi
fi

# ============================================================ Check 3: Stack
# ADR-086 D12: this row is receipt-driven. The self-update hook
# (hooks/stack-self-update.sh) has already probed/staged by the time this
# script runs -- org-check.sh reads its receipt and never touches
# lib/stack-freshness.sh, update.sh, install.sh or the network itself.
STACK_STATUS="ok"
STACK_REASON=""
STACK_DETAIL="Stack up to date"
STACK_FIX=""

# stack-profile: a distinct advisory item, never a second "stack" check
# (tests/test-carbonet-check.sh selects items by token; reusing "stack"
# would collide with the freshness check above). Warn-only, present only
# when the receipt's reason is unstamped-profile.
PROFILE_PRESENT=0
PROFILE_STATUS=""
PROFILE_REASON=""
PROFILE_DIR=""
PROFILE_DETAIL=""
PROFILE_FIX=""

# ADR-067's rehome detector, when it exists, wins ordering: a moved $HOME is
# the more actionable fact, so its line prints before the profile line and
# the profile line is marked secondary. lib/rehome-check.sh may not be built
# yet -- absence is the normal case and must be silent, not an error.
REHOME_PRESENT=0
REHOME_LINE=""

# The hook writes its receipt under the ACTIVE config dir — on a profile
# session that is $CLAUDE_CONFIG_DIR, not master ~/.claude. Reading master's
# path there reported "self-updater didn't run" on every profile session.
RECEIPT_HOME="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME}}"
RECEIPT_PATH="$RECEIPT_HOME/state/stack-update/receipt.json"
UNSAFE_RECEIPT_PATH="$RECEIPT_HOME/state/stack-update-unsafe.json"

# D17: the primary receipt is unwritable by the model. When a state-dir
# safety failure diverted the hook to the sibling unsafe leaf instead (D17
# control 2), that leaf is read as a fallback -- it is still the truth about
# why the primary receipt doesn't exist.
RECEIPT_JSON=""
if [[ -f "$RECEIPT_PATH" ]]; then
  RECEIPT_JSON="$(jq -e . "$RECEIPT_PATH" 2>/dev/null)" || RECEIPT_JSON=""
fi
if [[ -z "$RECEIPT_JSON" && -f "$UNSAFE_RECEIPT_PATH" ]]; then
  RECEIPT_JSON="$(jq -e . "$UNSAFE_RECEIPT_PATH" 2>/dev/null)" || RECEIPT_JSON=""
fi

RECEIPT_STALE=1
RCPT_STATUS_VAL=""
RCPT_REASON_VAL=""
RCPT_NEEDS_HUMAN="false"
RCPT_PACK_PENDING="false"
RCPT_PURGES_PENDING="0"
RCPT_REPO_RAW=""
RCPT_TIER_RAW=""
RCPT_PROFILE_DIR_RAW=""

if [[ -n "$RECEIPT_JSON" ]]; then
  RCPT_AS_OF="$(jq -r '.as_of // empty' <<<"$RECEIPT_JSON")"
  if [[ -n "$RCPT_AS_OF" ]]; then
    AS_OF_EPOCH="$(date -u -d "$RCPT_AS_OF" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$RCPT_AS_OF" +%s 2>/dev/null)"
    if [[ -n "$AS_OF_EPOCH" ]]; then
      NOW_EPOCH="$(date -u +%s)"
      (( NOW_EPOCH - AS_OF_EPOCH <= 43200 )) && RECEIPT_STALE=0
    fi
  fi
  RCPT_STATUS_VAL="$(jq -r '.status // empty' <<<"$RECEIPT_JSON")"
  RCPT_REASON_VAL="$(jq -r '.reason // empty' <<<"$RECEIPT_JSON")"
  RCPT_NEEDS_HUMAN="$(jq -r 'if .needs_human == true then "true" else "false" end' <<<"$RECEIPT_JSON")"
  RCPT_PACK_PENDING="$(jq -r 'if .pack_pending == true then "true" else "false" end' <<<"$RECEIPT_JSON")"
  RCPT_PURGES_PENDING="$(jq -r '.purges_pending // 0' <<<"$RECEIPT_JSON")"
  [[ "$RCPT_PURGES_PENDING" =~ ^[0-9]+$ ]] || RCPT_PURGES_PENDING=0
  RCPT_REPO_RAW="$(jq -r '.repo // empty' <<<"$RECEIPT_JSON")"
  RCPT_TIER_RAW="$(jq -r '.tier // empty' <<<"$RECEIPT_JSON")"
  RCPT_PROFILE_DIR_RAW="$(jq -r '.profile_dir // empty' <<<"$RECEIPT_JSON")"
fi

# D19: re-apply the sanitizer to any receipt free-text this script renders,
# defensively, because the receipt may have been written by an older hook.
stack_terminal_fix() {
  local repo tier
  repo="$(sanitize_path "${RCPT_REPO_RAW:-<repo>}")"
  tier="$(sanitize_field "${RCPT_TIER_RAW:-N}" 10)"
  printf 'Run ./scripts/update.sh --tier=%s in %s from a terminal — or %s.' "$tier" "$repo" "$SUPPORT_CONTACT"
}

if [[ -z "$RECEIPT_JSON" || "$RECEIPT_STALE" == "1" || "$RCPT_REASON_VAL" == "no-pin" || "$RCPT_REASON_VAL" == "pin-outdated" ]]; then
  # Missing, stale (>12h -- the hook did not run this boot), or never
  # bootstrapped (ADR-085 couldn't-look: this must read as an error, never
  # as silence or as health).
  STACK_STATUS="fail"; STACK_REASON="couldnt-look"
  STACK_DETAIL="Can't tell — the self-updater didn't run"
  STACK_FIX="$SUPPORT_CONTACT."
elif [[ "$RCPT_REASON_VAL" == "unstamped-profile" ]]; then
  PROFILE_PRESENT=1
  PROFILE_DIR="$(sanitize_path "$RCPT_PROFILE_DIR_RAW")"
  PROFILE_NAME="${RCPT_PROFILE_DIR_RAW##*.claude-}"
  PROFILE_STATUS="warn"; PROFILE_REASON="unstamped-profile"
  PROFILE_DETAIL="This machine's ${PROFILE_DIR} profile is empty — Claude tools won't load from repos that use it"
  PROFILE_FIX="run: ./scripts/install.sh --migrate-profile=${PROFILE_NAME} (from the stack repo)"

  REHOME_LIB="$(resolve_lib lib/rehome-check.sh)"
  if [[ -f "$REHOME_LIB" ]]; then
    REHOME_LINE="$(bash "$REHOME_LIB" --oneline 2>/dev/null)"; REHOME_RC=$?
    if [[ "$REHOME_RC" == "10" && -n "$REHOME_LINE" ]]; then
      REHOME_PRESENT=1
      PROFILE_DETAIL="${PROFILE_DETAIL} (secondary)"
    fi
  fi

  # The generic Stack row still reflects "can't tell" -- unchanged wording
  # for this case.
  STACK_STATUS="warn"; STACK_REASON="unstamped"
  STACK_DETAIL="Can't tell — the stack install has no version stamp"
  STACK_FIX="$(generic_warn_fix)"
elif [[ "$RCPT_NEEDS_HUMAN" == "true" ]]; then
  STACK_STATUS="fail"; STACK_REASON="needs-human"
  STACK_DETAIL="The stack couldn't update itself"
  STACK_FIX="$(stack_terminal_fix)"
elif [[ "$RCPT_STATUS_VAL" == "applying" || "$RCPT_STATUS_VAL" == "running" ]]; then
  STACK_STATUS="warn"; STACK_REASON="applying"
  STACK_DETAIL="An update is being applied right now"
  STACK_FIX="Nothing to do — check back after your next message."
elif [[ "$RCPT_STATUS_VAL" == "staged" ]]; then
  STACK_STATUS="warn"; STACK_REASON="staged"
  STACK_DETAIL="An update is ready to apply"
  STACK_FIX="Say /stack-update — it shows what changed and applies it. Not sure? $SUPPORT_CONTACT."
elif [[ "$RCPT_PACK_PENDING" == "true" || "$RCPT_PURGES_PENDING" -gt 0 ]]; then
  STACK_STATUS="warn"; STACK_REASON="pending"
  STACK_DETAIL="Some org settings are waiting to be applied"
  STACK_FIX="$(stack_terminal_fix)"
elif [[ "$RCPT_STATUS_VAL" == "current" || "$RCPT_STATUS_VAL" == "updated" ]]; then
  STACK_STATUS="ok"; STACK_DETAIL="Stack up to date"
else
  # Every other skipped reason (offline, no-jq, no-git, no-stamp,
  # repo-missing, cooldown, backoff, ...) means the same thing here: we
  # cannot confirm, but nothing is known to be broken.
  STACK_STATUS="warn"; STACK_REASON="unclear"
  STACK_DETAIL="Can't tell if the stack is current on this machine"
  STACK_FIX="$(generic_warn_fix)"
fi

# ============================================================= Check 4: Repo
REPO_STATUS="ok"
REPO_REASON=""
REPO_DETAIL=""
REPO_FIX=""
REPO_VERSION_DETAIL_REPO=""
REPO_VERSION_DETAIL_INSTALLED=""

REPROJECT_FIX="type /project-init in this window, then run /carbonet again."

if [[ -z "$STACK_CONFIG_PATH" || ! -f "$STACK_CONFIG_PATH" ]]; then
  REPO_STATUS="fail"; REPO_REASON="no-config"
  REPO_DETAIL="This folder isn't set up for Claude yet"
  REPO_FIX="$REPROJECT_FIX"
elif ! jq -e . "$STACK_CONFIG_PATH" >/dev/null 2>&1; then
  REPO_STATUS="fail"; REPO_REASON="bad-json"
  REPO_DETAIL="This folder's settings file is damaged"
  REPO_FIX="$REPROJECT_FIX"
else
  SCV_LIB="$(resolve_lib lib/stack-config-validate.sh)"
  SCHEMA_PATH="$(resolve_lib schemas/stack-config-schema.json)"
  SCV_AVAILABLE=0
  if [[ -f "$SCV_LIB" ]]; then
    _scv_safe_source "$SCV_LIB" scv_validate && SCV_AVAILABLE=1
  fi
  if (( ! SCV_AVAILABLE )) || [[ ! -f "$SCHEMA_PATH" ]]; then
    # FAIL CLOSED, not "assume valid": a missing/broken validator or schema
    # must never read as "this folder's settings are fine" — that was the
    # exact bug class scv_validate's own fail-closed fix (finding #2) closed
    # INSIDE the function; this reintroduced it one layer up, at the caller
    # (reviewer finding, 2026-08-11 re-verification pass). "Can't verify" is
    # the honest state of the world here, same category as Check 3's
    # helper-missing case.
    REPO_STATUS="warn"; REPO_REASON="helper-missing"
    REPO_DETAIL="Can't tell if this folder's settings are valid — the checker isn't installed"
    REPO_FIX="$(generic_warn_fix)"
  elif SCV_ERR="$(scv_validate "$STACK_CONFIG_PATH" "$SCHEMA_PATH")" && [[ -z "$SCV_ERR" ]]; then
    # Compare RAW values; sanitize ONLY at the point of display (reviewer
    # finding, round 3: sanitizing before comparison let two DIFFERENT
    # versions collapse to the identical placeholder — e.g. "4.0.1" and
    # "4.0.2" both contain a 4xx-shaped digit run, both got replaced with
    # "(from your settings)", and the false equality made a stale repo
    # report ✅. Live-reproduced by the reviewer; do not reorder this again.)
    REPO_VER_RAW="$(jq -r '.stack_version // empty' "$STACK_CONFIG_PATH")"
    REPO_TIER_VAL="$(jq -r '.stack_tier // empty' "$STACK_CONFIG_PATH")"
    INSTALL_STAMP="$CLAUDE_HOME/.stack-install.json"
    INSTALLED_VER_RAW=""
    [[ -f "$INSTALL_STAMP" ]] && INSTALLED_VER_RAW="$(jq -r '.stack_version // empty' "$INSTALL_STAMP" 2>/dev/null)"
    if [[ -z "$INSTALLED_VER_RAW" ]]; then
      REPO_STATUS="warn"; REPO_REASON="unstamped"
      REPO_DETAIL="Can't tell if this folder matches the installed version"
      REPO_FIX="$(generic_warn_fix)"
    elif [[ "$REPO_VER_RAW" != "$INSTALLED_VER_RAW" ]]; then
      REPO_VER="$(sanitize_field "$REPO_VER_RAW" 40)"
      INSTALLED_VER="$(sanitize_field "$INSTALLED_VER_RAW" 40)"
      REPO_STATUS="fail"; REPO_REASON="version-behind"
      REPO_DETAIL="This folder's settings are from an older version ($REPO_VER, machine has $INSTALLED_VER)"
      REPO_FIX="$REPROJECT_FIX"
      REPO_VERSION_DETAIL_REPO="$REPO_VER"
      REPO_VERSION_DETAIL_INSTALLED="$INSTALLED_VER"
    else
      REPO_VER="$(sanitize_field "$REPO_VER_RAW" 40)"
      REPO_STATUS="ok"
      REPO_DETAIL="Set up right (v${REPO_VER}, tier ${REPO_TIER_VAL})"
    fi
  else
    FIRST_ERR="${SCV_ERR%%;*}"
    FIRST_ERR="${FIRST_ERR# }"
    # scv_validate's error text embeds config VALUES verbatim (e.g. "bad
    # orchestration_mode: <whatever the config said>") — attacker-controlled,
    # must go through the sanitizer before it reaches this report.
    FIRST_ERR="$(sanitize_field "$FIRST_ERR" 160)"
    REPO_STATUS="fail"; REPO_REASON="invalid-config"
    REPO_DETAIL="This folder's settings are invalid: $FIRST_ERR"
    REPO_FIX="$REPROJECT_FIX"
  fi
fi

# =========================================================== Check 5: Review
# ADR-087 D5: gate-health row. The gate's deny text is one opaque code
# ("machinery") by design; diagnosis surfaces HERE and in the operator log,
# never in the deny itself. Three conditions, first match wins:
#   machinery deny in the last 24h        -> fail
#   disable file present with no reason   -> warn
#   otherwise                             -> ok, "Review gate active (<mode>)"
REVIEW_STATUS="ok"
REVIEW_REASON=""
REVIEW_DETAIL=""
REVIEW_FIX=""

REVIEW_CONF_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REVIEW_DISABLE_FILE="$REVIEW_CONF_DIR/state/attest/override/review-gate.disabled"
REVIEW_GATE_LOG="$HOME/.claude/logs/review-gate.jsonl"

# Resolve displayed mode the same way the gate does: repo config ->
# stack-defaults -> built-in warn. A disable file with a real reason shows
# as off — the honest state, without quoting the (attacker-writable) reason.
REVIEW_MODE="warn"
if [[ -n "${STACK_CONFIG_PATH:-}" && -f "$STACK_CONFIG_PATH" ]] \
   && jq -e '.guards.review_gate' "$STACK_CONFIG_PATH" >/dev/null 2>&1; then
  REVIEW_MODE="$(jq -r '.guards.review_gate' "$STACK_CONFIG_PATH" 2>/dev/null)"
elif [[ -f "$REVIEW_CONF_DIR/stack-defaults.json" ]] \
   && jq -e '.guards.review_gate' "$REVIEW_CONF_DIR/stack-defaults.json" >/dev/null 2>&1; then
  REVIEW_MODE="$(jq -r '.guards.review_gate' "$REVIEW_CONF_DIR/stack-defaults.json" 2>/dev/null)"
fi
case "$REVIEW_MODE" in off|warn|on) : ;; *) REVIEW_MODE="warn" ;; esac

REVIEW_MACHINERY_24H=0
if [[ -f "$REVIEW_GATE_LOG" ]] && command -v jq >/dev/null 2>&1; then
  REVIEW_CUTOFF="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  if [[ -n "$REVIEW_CUTOFF" ]]; then
    REVIEW_MACHINERY_24H="$(jq -rs --arg cutoff "$REVIEW_CUTOFF" \
      '[ .[] | select(type=="object" and .reason=="machinery" and ((.ts // "") > $cutoff)) ] | length' \
      "$REVIEW_GATE_LOG" 2>/dev/null || echo 0)"
    [[ "$REVIEW_MACHINERY_24H" =~ ^[0-9]+$ ]] || REVIEW_MACHINERY_24H=0
  fi
fi

if (( REVIEW_MACHINERY_24H > 0 )); then
  REVIEW_STATUS="fail"; REVIEW_REASON="machinery"
  REVIEW_DETAIL="The review gate is broken on this machine"
  REVIEW_FIX="See docs/runbooks/review-gate-recovery.md — or $SUPPORT_CONTACT."
elif [[ -f "$REVIEW_DISABLE_FILE" ]] \
   && [[ -z "$(head -c 200 "$REVIEW_DISABLE_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')" ]]; then
  REVIEW_STATUS="warn"; REVIEW_REASON="disabled-no-reason"
  REVIEW_DETAIL="The review gate is switched off but nobody wrote down why"
  REVIEW_FIX="Add one line saying why, or delete the file."
else
  [[ -f "$REVIEW_DISABLE_FILE" ]] && REVIEW_MODE="off"
  REVIEW_STATUS="ok"
  REVIEW_DETAIL="Review gate active ($REVIEW_MODE)"
fi

# ============================================================ broker (D18 P4)
# Row exists only where the stack-broker is installed (system config present).
#   fail: daemon down, any broker-only surface directly reachable, or
#         verify-approval-channel.sh failing
#   warn: pending approvals waiting, or a principal within 14 days of max_age
#   ok:   otherwise
BROKER_PRESENT=0
BROKER_STATUS="ok"; BROKER_REASON=""; BROKER_DETAIL=""; BROKER_FIX=""
BROKER_SYS_CONF="${STACK_BROKER_SYSTEM_CONFIG:-/etc/stack-broker/config.json}"
if [[ -f "$BROKER_SYS_CONF" ]]; then
  BROKER_PRESENT=1
  if ! command -v stack-broker >/dev/null 2>&1; then
    BROKER_STATUS="fail"; BROKER_REASON="client-missing"
    BROKER_DETAIL="The broker is configured but the stack-broker client is not installed"
    BROKER_FIX="Re-run scripts/broker-install.sh."
  else
    stack-broker pending --json >/dev/null 2>&1; BROKER_RC=$?
    if [[ $BROKER_RC -eq 6 ]]; then
      BROKER_STATUS="fail"; BROKER_REASON="daemon-down"
      BROKER_DETAIL="The broker daemon is not running"
      BROKER_FIX="Restart it: sudo bash scripts/broker-install.sh"
    elif ! bash "$SCRIPT_DIR/verify-approval-channel.sh" >/dev/null 2>&1; then
      BROKER_STATUS="fail"; BROKER_REASON="approval-channel"
      BROKER_DETAIL="The approval channel failed verification"
      BROKER_FIX="Run scripts/verify-approval-channel.sh and fix what it names."
    else
      BROKER_DIRECT=""
      for _surf in cloudflare neon; do
        _st="$(bash "$SCRIPT_DIR/can-i-still-act.sh" --surface "$_surf" --json 2>/dev/null \
               | jq -r '.surfaces[0].status // "UNKNOWN"' 2>/dev/null)"
        [[ "$_st" == "REACHABLE" ]] && BROKER_DIRECT="$_surf"
      done
      if [[ -n "$BROKER_DIRECT" ]]; then
        BROKER_STATUS="fail"; BROKER_REASON="direct-path-open"
        BROKER_DETAIL="A broker-only surface ($BROKER_DIRECT) is still directly reachable"
        BROKER_FIX="Re-check the sandbox allowlist narrowing (D18 P4 step 1)."
      else
        BROKER_PENDING_N="$(stack-broker pending --json 2>/dev/null | jq '.pending|length' 2>/dev/null || echo 0)"
        [[ "$BROKER_PENDING_N" =~ ^[0-9]+$ ]] || BROKER_PENDING_N=0
        BROKER_NEAR_EXPIRY="$(stack-broker whoami --json 2>/dev/null \
          | jq '[.provisioned[]? | select((.days_left // 99) < 14)] | length' 2>/dev/null || echo 0)"
        [[ "$BROKER_NEAR_EXPIRY" =~ ^[0-9]+$ ]] || BROKER_NEAR_EXPIRY=0
        if (( BROKER_PENDING_N > 0 )); then
          BROKER_STATUS="warn"; BROKER_REASON="pending-approvals"
          BROKER_DETAIL="$BROKER_PENDING_N operation(s) waiting for human approval"
          BROKER_FIX="Run: sudo stack-approve"
        elif (( BROKER_NEAR_EXPIRY > 0 )); then
          BROKER_STATUS="warn"; BROKER_REASON="principal-near-expiry"
          BROKER_DETAIL="$BROKER_NEAR_EXPIRY broker principal(s) expire within 14 days"
          BROKER_FIX="Mint replacement principals before they expire (design §7.3)."
        else
          BROKER_DETAIL="Broker up; approval channel verified; no direct vendor path"
        fi
      fi
    fi
  fi
fi

# ================================================================== verdict
FAIL_COUNT=0
WARN_COUNT=0
(( BROKER_PRESENT )) && [[ "$BROKER_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
(( BROKER_PRESENT )) && [[ "$BROKER_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
[[ "$KEYS_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$KEYS_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
[[ "$ACCESS_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$ACCESS_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
[[ "$STACK_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$STACK_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
(( PROFILE_PRESENT )) && [[ "$PROFILE_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
(( REHOME_PRESENT )) && WARN_COUNT=$((WARN_COUNT+1))
[[ "$REPO_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$REPO_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))
[[ "$REVIEW_STATUS" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$REVIEW_STATUS" == "warn" ]] && WARN_COUNT=$((WARN_COUNT+1))

if (( FAIL_COUNT > 0 )); then
  VERDICT="NOT_READY"
  VERDICT_TEXT="NOT READY"
  VERB="need"; [[ "$FAIL_COUNT" == "1" ]] && VERB="needs"
  VERDICT_LINE="NOT READY — ${FAIL_COUNT} $(plural_things "$FAIL_COUNT") ${VERB} fixing."
  EXIT_CODE=10
elif (( WARN_COUNT > 0 )); then
  VERDICT="ALMOST"
  VERDICT_TEXT="ALMOST READY"
  VERDICT_LINE="ALMOST READY — ${WARN_COUNT} $(plural_things "$WARN_COUNT") could not be checked."
  EXIT_CODE=20
else
  VERDICT="READY"
  VERDICT_TEXT="READY"
  VERDICT_LINE="READY — everything's good."
  EXIT_CODE=0
fi

FOOTER="(spending limits not checked — /carbonet --deep checks those)"
(( DEEP )) && FOOTER="(deep check — costs about a penny)"

# ==================================================================== output
if (( JSON_OUT )); then
  KEYS_ITEMS_JSON="$(
    if (( ${#KEYS_ITEM_PROVIDER[@]} )); then
      for i in "${!KEYS_ITEM_PROVIDER[@]}"; do
        jq -n --arg p "${KEYS_ITEM_PROVIDER[$i]}" --arg s "${KEYS_ITEM_STATUS[$i]}" \
              --arg r "${KEYS_ITEM_REASON[$i]}" \
              '{provider:$p, status:$s, reason:(if $r=="" then null else $r end)}'
      done
    fi | jq -s '.'
  )"
  FIXES_JSON="$(jq -n '[]')"
  add_fix() {
    local check="$1" text="$2"
    FIXES_JSON="$(jq -n --argjson prev "$FIXES_JSON" --arg c "$check" --arg t "$text" '$prev + [{check:$c, text:$t}]')"
  }
  [[ "$KEYS_STATUS" != "ok" ]] && add_fix keys "$KEYS_FIX"
  [[ "$ACCESS_STATUS" != "ok" ]] && add_fix access "$ACCESS_FIX"
  [[ "$STACK_STATUS" != "ok" ]] && add_fix stack "$STACK_FIX"
  (( PROFILE_PRESENT )) && [[ "$PROFILE_STATUS" != "ok" ]] && add_fix stack-profile "$PROFILE_FIX"
  [[ "$REPO_STATUS" != "ok" ]] && add_fix repo "$REPO_FIX"
  [[ "$REVIEW_STATUS" != "ok" ]] && add_fix review "$REVIEW_FIX"
  (( BROKER_PRESENT )) && [[ "$BROKER_STATUS" != "ok" ]] && add_fix broker "$BROKER_FIX"

  jq -n \
    --arg org "$ORG_ID" --arg verdict "$VERDICT" --argjson deep "$( ((DEEP)) && echo true || echo false )" \
    --arg keys_status "$KEYS_STATUS" --argjson keys_items "$KEYS_ITEMS_JSON" \
    --arg access_status "$ACCESS_STATUS" --arg access_reason "$ACCESS_REASON" \
    --arg stack_status "$STACK_STATUS" --arg stack_reason "$STACK_REASON" \
    --arg repo_status "$REPO_STATUS" --arg repo_reason "$REPO_REASON" \
    --arg repo_ver "$REPO_VERSION_DETAIL_REPO" --arg installed_ver "$REPO_VERSION_DETAIL_INSTALLED" \
    --arg review_status "$REVIEW_STATUS" --arg review_reason "$REVIEW_REASON" \
    --argjson profile_present "$( ((PROFILE_PRESENT)) && echo true || echo false )" \
    --arg profile_status "$PROFILE_STATUS" --arg profile_reason "$PROFILE_REASON" --arg profile_dir "$PROFILE_DIR" \
    --argjson broker_present "$( ((BROKER_PRESENT)) && echo true || echo false )" \
    --arg broker_status "$BROKER_STATUS" --arg broker_reason "$BROKER_REASON" \
    --argjson fixes "$FIXES_JSON" --argjson degraded "$( ((GUARD_DEGRADED)) && echo true || echo false )" \
    '{
      org: $org,
      verdict: $verdict,
      deep: $deep,
      checks: ( [
        {id:"keys", status:$keys_status, items:$keys_items},
        {id:"access", status:$access_status, reason:(if $access_reason=="" then null else $access_reason end)},
        {id:"stack", status:$stack_status, reason:(if $stack_reason=="" then null else $stack_reason end)},
        {id:"repo", status:$repo_status, reason:(if $repo_reason=="" then null else $repo_reason end)}
          + (if $repo_ver != "" then {detail:{repo:$repo_ver, installed:$installed_ver}} else {} end),
        {id:"review", status:$review_status, reason:(if $review_reason=="" then null else $review_reason end)}
      ] + (if $profile_present then
        [{id:"stack-profile", status:$profile_status,
          reason:(if $profile_reason=="" then null else $profile_reason end),
          detail:{dir:$profile_dir}}]
      else [] end)
        + (if $broker_present then
        [{id:"broker", status:$broker_status,
          reason:(if $broker_reason=="" then null else $broker_reason end)}]
      else [] end) ),
      fixes: $fixes
    } + (if $degraded then {guard_degraded: true} else {} end)'
  exit "$EXIT_CODE"
fi

row_line() {
  local glyph="$1" label="$2" detail="$3"
  printf '%s  %-9s%s\n' "$glyph" "$label" "$detail"
}

glyph_for() {
  case "$1" in
    ok) printf '%s' "$GLYPH_OK" ;;
    fail) printf '%s' "$GLYPH_FAIL" ;;
    warn) printf '%s' "$GLYPH_WARN" ;;
  esac
}

printf '%s check · %s\n' "$ORG_DISPLAY" "$(date +'%Y-%m-%d %H:%M')"
echo
row_line "$(glyph_for "$KEYS_STATUS")" "Keys" "$KEYS_DETAIL"
row_line "$(glyph_for "$ACCESS_STATUS")" "Access" "$ACCESS_DETAIL"
row_line "$(glyph_for "$STACK_STATUS")" "Stack" "$STACK_DETAIL"
# Rehome (ADR-067), when present, wins ordering over the profile line -- a
# moved $HOME is the more actionable fact.
(( REHOME_PRESENT )) && row_line "$GLYPH_WARN" "Stack" "$REHOME_LINE"
(( PROFILE_PRESENT )) && row_line "$(glyph_for "$PROFILE_STATUS")" "Stack" "$PROFILE_DETAIL"
row_line "$(glyph_for "$REPO_STATUS")" "Repo" "$REPO_DETAIL"
row_line "$(glyph_for "$REVIEW_STATUS")" "Review" "$REVIEW_DETAIL"
(( BROKER_PRESENT )) && row_line "$(glyph_for "$BROKER_STATUS")" "Broker" "$BROKER_DETAIL"
echo
echo "$VERDICT_LINE"

if (( FAIL_COUNT > 0 )); then
  [[ "$KEYS_STATUS" == "fail" ]] && printf '  %s Keys: %s\n' "$GLYPH_FAIL" "$KEYS_FIX"
  [[ "$ACCESS_STATUS" == "fail" ]] && printf '  %s Access: %s\n' "$GLYPH_FAIL" "$ACCESS_FIX"
  [[ "$STACK_STATUS" == "fail" ]] && printf '  %s Stack: %s\n' "$GLYPH_FAIL" "$STACK_FIX"
  [[ "$REPO_STATUS" == "fail" ]] && printf '  %s Repo: %s\n' "$GLYPH_FAIL" "$REPO_FIX"
  [[ "$REVIEW_STATUS" == "fail" ]] && printf '  %s Review: %s\n' "$GLYPH_FAIL" "$REVIEW_FIX"
  (( BROKER_PRESENT )) && [[ "$BROKER_STATUS" == "fail" ]] && printf '  %s Broker: %s\n' "$GLYPH_FAIL" "$BROKER_FIX"
elif (( WARN_COUNT > 0 )); then
  [[ "$KEYS_STATUS" == "warn" ]] && printf '  %s Keys: %s\n' "$GLYPH_WARN" "$KEYS_FIX"
  [[ "$ACCESS_STATUS" == "warn" ]] && printf '  %s Access: %s\n' "$GLYPH_WARN" "$ACCESS_FIX"
  [[ "$STACK_STATUS" == "warn" ]] && printf '  %s Stack: %s\n' "$GLYPH_WARN" "$STACK_FIX"
  (( PROFILE_PRESENT )) && [[ "$PROFILE_STATUS" == "warn" ]] && printf '  %s Stack: %s\n' "$GLYPH_WARN" "$PROFILE_FIX"
  [[ "$REPO_STATUS" == "warn" ]] && printf '  %s Repo: %s\n' "$GLYPH_WARN" "$REPO_FIX"
  [[ "$REVIEW_STATUS" == "warn" ]] && printf '  %s Review: %s\n' "$GLYPH_WARN" "$REVIEW_FIX"
  (( BROKER_PRESENT )) && [[ "$BROKER_STATUS" == "warn" ]] && printf '  %s Broker: %s\n' "$GLYPH_WARN" "$BROKER_FIX"
fi

echo
echo "$FOOTER"
(( GUARD_DEGRADED )) && echo "(some details hidden — your setup is mid-update)"

exit "$EXIT_CODE"
