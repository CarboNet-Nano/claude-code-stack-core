#!/usr/bin/env bash
# Tests for ADR-071 (sandbox vendor-host policy compile):
# config/vendor-hosts.json, scripts/sandbox-policy-compile.sh,
# scripts/lib/settings_lock.py --apply-sandbox-policy,
# scripts/lib/cross-family-preflight.sh cfp_vendor_policy, and the three new
# hooks (sandbox-policy-session-start.sh, sandbox-policy-recompile.sh,
# vendor-egress-cloud-guard.sh).
#
# Harness copied from tests/test-permissions-boundary.sh:21-76 (set -uo
# pipefail, pass/fail/skip, assert_* helpers, new_home() under mktemp -d with
# HOME redirected, trap cleanup EXIT, CLAUDE_PLUGIN_ROOT export). CI
# auto-discovers this file (.github/workflows/test-install.yml's
# `for t in tests/test-*.sh` loop).
#
# M9-M12 and the L-group (RUN_LIVE_SANDBOX_TESTS=1, macOS, sandbox available,
# and for M9-M12/L1 the managed floor genuinely installed) SKIP loudly
# otherwise, per the implementer instructions -- they cannot run without a
# human `sudo` install (docs/runbooks/managed-floor-install.md) and are not
# faked here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILE="$REPO_ROOT/scripts/sandbox-policy-compile.sh"
LIB_PY="$REPO_ROOT/scripts/lib/settings_lock.py"
CFP="$REPO_ROOT/scripts/lib/cross-family-preflight.sh"
SESSION_HOOK="$REPO_ROOT/hooks/sandbox-policy-session-start.sh"
RECOMPILE_HOOK="$REPO_ROOT/hooks/sandbox-policy-recompile.sh"
CLOUD_HOOK="$REPO_ROOT/hooks/vendor-egress-cloud-guard.sh"
VENDOR_HOSTS="$REPO_ROOT/config/vendor-hosts.json"

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$COMPILE" ]] || { echo "FAIL: $COMPILE not found"; exit 1; }
[[ -f "$LIB_PY" ]] || { echo "FAIL: $LIB_PY not found"; exit 1; }

PASS=0
FAIL=0
SKIPPED=()
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIPPED+=("$1"); }

assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected: $2 | actual: $3)"; }
assert_rc() { [[ "$3" -eq "$2" ]] && pass "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 (missing '$3' in: $2)"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1 (unexpectedly found '$3' in: $2)"; }
assert_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1 (missing exact line '$3' in: $2)"; fi
}
assert_not_contains_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then fail "$1 (unexpectedly found exact line '$3' in: $2)"; else pass "$1"; fi
}

ORIG_HOME="$HOME"
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

new_home() {
  local h; h="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  mkdir -p "$h/.claude/session-state/sandbox-policy" "$h/.claude/config" "$h/.claude/logs"
  CLEANUP_DIRS+=("$h")
  printf '%s' "$h"
}

new_repo() {
  local r; r="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
  CLEANUP_DIRS+=("$r")
  mkdir -p "$r/.claude"
  printf '%s' "$r"
}

write_cfg() {
  # write_cfg <repo> <level-or-empty>
  local repo="$1" level="$2"
  if [[ -z "$level" ]]; then
    echo '{}' > "$repo/.claude/stack-config.json"
  else
    jq -n --arg l "$level" '{sensitivity:{level:$l}}' > "$repo/.claude/stack-config.json"
  fi
}

# A minimal floor fixture the compiler will treat as fully present + strict.
write_floor() {
  local path="$1"
  jq -n '{
    sandbox: {
      enabled: true,
      network: { strictAllowlist: true },
      filesystem: { denyWrite: [
        "**/.claude/settings.json", "**/.claude/settings.local.json",
        "**/.claude/stack-config.json", "~/.claude/settings.json",
        "~/.claude/stack-defaults.json", "~/.claude/hooks/**",
        "~/.claude/scripts/**", "~/.claude/config/**", "~/.claude/agents/**",
        "~/.claude/skills/**", "~/.claude/lib/**"
      ] }
    }
  }' > "$path"
}

# The org access host (config/org.json -> org.access_url) is allowed at EVERY
# sensitivity level and is deliberately NOT part of the vendor universe, so
# every vendor-count assertion below filters it out and keeps pinning exactly
# what it pinned before. Its own presence is asserted separately (the ORG-*
# cases), which is what makes these counts safe to filter rather than bump.
ORG_ACCESS_HOST="$(jq -r '.org.access_url // ""' "$REPO_ROOT/config/org.json" 2>/dev/null \
  | sed -e 's#^https://##' -e 's#/.*##')"
vendors_only() {
  # vendors_only <json-array-expr> — length of allowed_hosts minus the org host
  jq --arg oh "$ORG_ACCESS_HOST" "[$1[] | select(. != \$oh)]"
}

compile() {
  # compile <home> <repo> [extra args...]
  local home="$1" repo="$2"; shift 2
  HOME="$home" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT="SessionStart" \
    bash "$COMPILE" --repo-root "$repo" "$@"
}

RC=0

# ═══════════════════════════════════════════════════════════════════════
# P — policy mapping
# ═══════════════════════════════════════════════════════════════════════
H1="$(new_home)"; R1="$(new_repo)"; write_floor "$H1/managed.json"
MANAGED_SETTINGS_PATH="$H1/managed.json" write_cfg "$R1" ""
OUT_P1="$(MANAGED_SETTINGS_PATH="$H1/managed.json" compile "$H1" "$R1" --json)"
assert_eq "P1: normal -> all six governed hosts present" "6" "$(echo "$OUT_P1" | vendors_only .allowed_hosts | jq 'length')"
assert_eq "ORG1: the org access host is allowed at normal" "true" "$(echo "$OUT_P1" | jq --arg oh "$ORG_ACCESS_HOST" '(.allowed_hosts | index($oh)) != null')"

H2="$(new_home)"; R2="$(new_repo)"; write_floor "$H2/managed.json"
write_cfg "$R2" "sensitive"
OUT_P2="$(MANAGED_SETTINGS_PATH="$H2/managed.json" compile "$H2" "$R2" --json)"
# P2 updated deliberately (ADR-071 D15 #6 / gemini-paid-tier-precondition
# Option A): generativelanguage.googleapis.com reverted to
# cleared_at_sensitive:false (a host-level allowlist can't bind which key is
# spent), so sensitive now clears only api.anthropic.com (runtime) +
# api.openai.com -- 2, not 3.
assert_eq "P2: sensitive -- with shipped vendor-hosts.json only anthropic+openai are cleared (gemini closed, ADR-071 D15 #6)" \
  "2" "$(echo "$OUT_P2" | vendors_only .allowed_hosts | jq 'length')"
assert_eq "ORG2: the org access host is allowed at sensitive" "true" "$(echo "$OUT_P2" | jq --arg oh "$ORG_ACCESS_HOST" '(.allowed_hosts | index($oh)) != null')"
assert_contains "P2: api.anthropic.com allowed at sensitive" "$(echo "$OUT_P2" | jq -r '.allowed_hosts | join(",")')" "api.anthropic.com"

# ═══════════════════════════════════════════════════════════════════════
# A1-A3 (docs/plans/2026-08-11-gemini-paid-tier-precondition.md, Option A)
# ═══════════════════════════════════════════════════════════════════════

# A1 — sensitive: generativelanguage.googleapis.com excluded from
# allowed_hosts, present in denied_hosts, verdict stays COMPILED (the host
# closure is a normal policy decision, not a fallback).
HA1="$(new_home)"; RA1="$(new_repo)"; write_floor "$HA1/managed.json"
write_cfg "$RA1" "sensitive"
OUT_A1="$(MANAGED_SETTINGS_PATH="$HA1/managed.json" compile "$HA1" "$RA1" --json)"
assert_not_contains "A1: generativelanguage.googleapis.com excluded from allowed_hosts at sensitive" \
  "$(echo "$OUT_A1" | jq -r '.allowed_hosts | join(",")')" "generativelanguage.googleapis.com"
assert_contains "A1: generativelanguage.googleapis.com present in denied_hosts at sensitive" \
  "$(echo "$OUT_A1" | jq -r '.denied_hosts | join(",")')" "generativelanguage.googleapis.com"
assert_eq "A1: verdict still COMPILED" "COMPILED" "$(echo "$OUT_A1" | jq -r '.verdict')"

# A2 — normal: the host is still allowed (all six).
HA2="$(new_home)"; RA2="$(new_repo)"; write_floor "$HA2/managed.json"
write_cfg "$RA2" ""
OUT_A2="$(MANAGED_SETTINGS_PATH="$HA2/managed.json" compile "$HA2" "$RA2" --json)"
assert_eq "A2: normal -> all six governed hosts present" "6" "$(echo "$OUT_A2" | vendors_only .allowed_hosts | jq 'length')"
assert_contains "A2: generativelanguage.googleapis.com allowed at normal" \
  "$(echo "$OUT_A2" | jq -r '.allowed_hosts | join(",")')" "generativelanguage.googleapis.com"

# A3 — a live sensitive compile removes an existing gemini entry from
# settings.json and records a stash entry with the existing machinery
# (same pattern as S1's api.deepseek.com case).
HA3="$(new_home)"; RA3="$(new_repo)"; write_floor "$HA3/managed.json"
write_cfg "$RA3" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["generativelanguage.googleapis.com"]}}}' > "$RA3/.claude/settings.local.json"
MANAGED_SETTINGS_PATH="$HA3/managed.json" compile "$HA3" "$RA3" >/dev/null
assert_not_contains "A3: generativelanguage.googleapis.com removed from settings.local.json at sensitive" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RA3/.claude/settings.local.json" 2>/dev/null)" "generativelanguage.googleapis.com"
assert_contains "A3: removal recorded as stashed" \
  "$(jq -r '.sandbox_policy.stashed_entries[].value' "$RA3/.claude/permissions.stack.json" 2>/dev/null)" "generativelanguage.googleapis.com"

H3="$(new_home)"; R3="$(new_repo)"; write_floor "$H3/managed.json"
write_cfg "$R3" "sensitive"
OUT_P3="$(MANAGED_SETTINGS_PATH="$H3/managed.json" compile "$H3" "$R3" --json)"
assert_contains "P3: sensitive + openai cleared with reviewed_on -> openai present" \
  "$(echo "$OUT_P3" | jq -r '.allowed_hosts | join(",")')" "api.openai.com"
assert_not_contains "P3: deepseek absent at sensitive (not cleared)" \
  "$(echo "$OUT_P3" | jq -r '.allowed_hosts | join(",")')" "api.deepseek.com"

# P4 — cleared_at_sensitive:true + reviewed_on:null -> NOT cleared. Point the
# compiler at a fixture vendor-hosts.json via a fixture repo layout
# (config/vendor-hosts.json resolution order: $HOME/.claude/config first).
H4="$(new_home)"; R4="$(new_repo)"; write_floor "$H4/managed.json"
write_cfg "$R4" "sensitive"
jq -n '{version:"1.0.0", vendors:[
  {host:"api.anthropic.com", vendor:"Anthropic", kind:"direct", is_runtime:true, cleared_at_sensitive:true, reviewed_on:"2026-01-01", terms_url:"https://x", why:"x"},
  {host:"api.openai.com", vendor:"OpenAI", kind:"direct", is_runtime:false, cleared_at_sensitive:true, reviewed_on:null, terms_url:"https://x", why:"x"}
]}' > "$H4/.claude/config/vendor-hosts.json"
OUT_P4="$(MANAGED_SETTINGS_PATH="$H4/managed.json" compile "$H4" "$R4" --json)"
assert_eq "P4: cleared_at_sensitive:true + reviewed_on:null -> NOT cleared" \
  "false" "$(echo "$OUT_P4" | jq '(.allowed_hosts | index("api.openai.com")) != null')"

H5="$(new_home)"; R5="$(new_repo)"; write_floor "$H5/managed.json"
write_cfg "$R5" "confidential"
OUT_P5="$(MANAGED_SETTINGS_PATH="$H5/managed.json" compile "$H5" "$R5" --json)"
assert_eq "P5: confidential -> api.anthropic.com only" "1" "$(echo "$OUT_P5" | vendors_only .allowed_hosts | jq 'length')"
assert_eq "P5: confidential allowed host is api.anthropic.com" "api.anthropic.com" "$(echo "$OUT_P5" | vendors_only .allowed_hosts | jq -r '.[0]')"
assert_eq "ORG3: the org access host survives confidential (org infrastructure, not model egress)" "true" "$(echo "$OUT_P5" | jq --arg oh "$ORG_ACCESS_HOST" '(.allowed_hosts | index($oh)) != null')"
assert_eq "ORG3: the org access host is never in the removal set" "true" "$(echo "$OUT_P5" | jq --arg oh "$ORG_ACCESS_HOST" '(.denied_hosts | index($oh)) == null')"

# ORG4 — a malformed access_url contributes NOTHING. The allowlist is a
# security surface, so an unparseable value must never be best-effort
# guessed into it. Each shape below is refused for its own reason: a
# non-https scheme, embedded credentials, an explicit port, a wildcard, and
# a bare IP literal (which would pin an address rather than a name).
for BAD_URL in "http://access.carbonet.app" "https://user@access.carbonet.app" \
               "https://access.carbonet.app:8443" "https://*.carbonet.app" \
               "https://10.0.0.1" "https://localhost" "" "not-a-url"; do
  HO4="$(new_home)"; RO4="$(new_repo)"; write_floor "$HO4/managed.json"
  write_cfg "$RO4" ""
  jq -n --arg u "$BAD_URL" '{org:{access_url:$u}}' > "$HO4/.claude/config/org.json"
  OUT_O4="$(MANAGED_SETTINGS_PATH="$HO4/managed.json" compile "$HO4" "$RO4" --json)"
  assert_eq "ORG4: malformed access_url '$BAD_URL' adds no host" "6" \
    "$(echo "$OUT_O4" | jq '.allowed_hosts | length')"
done

# ORG5 — a repo-local org.json must NEVER govern its own sandbox policy.
# Same threat vendor-hosts.json's two-tier resolution exists to stop
# (security-audit CRITICAL, 2026-08-11): REPO_ROOT is attacker-controlled in
# the general case, e.g. a malicious PR checkout. The compiler reads only
# HOME and CLAUDE_PLUGIN_ROOT, so the planted value must not appear.
HO5="$(new_home)"; RO5="$(new_repo)"; write_floor "$HO5/managed.json"
write_cfg "$RO5" ""
mkdir -p "$RO5/.claude/config"
jq -n '{org:{access_url:"https://evil.example.com"}}' > "$RO5/.claude/config/org.json"
jq -n '{org:{access_url:"https://access.carbonet.app"}}' > "$HO5/.claude/config/org.json"
OUT_O5="$(MANAGED_SETTINGS_PATH="$HO5/managed.json" compile "$HO5" "$RO5" --json)"
assert_eq "ORG5: a repo-local org.json cannot widen its own allowlist" "true" \
  "$(echo "$OUT_O5" | jq '(.allowed_hosts | index("evil.example.com")) == null')"
assert_eq "ORG5: the trusted org.json is still honoured" "true" \
  "$(echo "$OUT_O5" | jq '(.allowed_hosts | index("access.carbonet.app")) != null')"

# ORG6 — the WRITER re-derives the org host from disk itself. A plan naming
# a host that is neither a vendor nor the trusted org host is refused, so a
# compromised compiler cannot smuggle one past the lock.
HO6="$(new_home)"; RO6="$(new_repo)"; write_floor "$HO6/managed.json"
write_cfg "$RO6" ""
jq -n '{org:{access_url:"https://access.carbonet.app"}}' > "$HO6/.claude/config/org.json"
OUT_O6="$(jq -nc --arg repo "$RO6" '{repo:$repo, _write_settings:true,
  project:{add:["evil.example.com"], remove:[]}, local:{remove:[]}}' \
  | HOME="$HO6" python3 "$LIB_PY" --apply-sandbox-policy \
      --target "$RO6/.claude/settings.json" \
      --vendor-hosts "$REPO_ROOT/config/vendor-hosts.json" \
      --org-config "$HO6/.claude/config/org.json" 2>&1)"
assert_contains "ORG6: the writer refuses a host outside vendors + the org host" \
  "$OUT_O6" "outside config/vendor-hosts.json"
OUT_O6B="$(jq -nc --arg repo "$RO6" '{repo:$repo, _write_settings:true,
  project:{add:["access.carbonet.app"], remove:[]}, local:{remove:[]}}' \
  | HOME="$HO6" python3 "$LIB_PY" --apply-sandbox-policy \
      --target "$RO6/.claude/settings.json" \
      --vendor-hosts "$REPO_ROOT/config/vendor-hosts.json" \
      --org-config "$HO6/.claude/config/org.json" 2>&1)"
assert_not_contains "ORG6: the writer accepts the trusted org host" \
  "$OUT_O6B" "refused:"

# P6 — idempotence
H6="$(new_home)"; R6="$(new_repo)"; write_floor "$H6/managed.json"
write_cfg "$R6" "sensitive"
MANAGED_SETTINGS_PATH="$H6/managed.json" compile "$H6" "$R6" >/dev/null
cp "$R6/.claude/settings.json" "$H6/s1.json"
MANAGED_SETTINGS_PATH="$H6/managed.json" compile "$H6" "$R6" >/dev/null
cp "$R6/.claude/settings.json" "$H6/s2.json"
if diff -q "$H6/s1.json" "$H6/s2.json" >/dev/null; then pass "P6: two compiles are byte-identical"; else fail "P6: two compiles differ"; fi

# P7 — a non-governed host survives every level, keeps its position
H7="$(new_home)"; R7="$(new_repo)"; write_floor "$H7/managed.json"
write_cfg "$R7" "confidential"
jq -n '{sandbox:{network:{allowedDomains:["*.supabase.co","*.neon.tech"]}}}' > "$R7/.claude/settings.json"
MANAGED_SETTINGS_PATH="$H7/managed.json" compile "$H7" "$R7" >/dev/null
POS="$(jq -r '.sandbox.network.allowedDomains | index("*.supabase.co")' "$R7/.claude/settings.json")"
assert_eq "P7: *.supabase.co keeps position 0" "0" "$POS"
assert_contains "P7: *.neon.tech survives confidential" "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$R7/.claude/settings.json")" "*.neon.tech"

# P8 — diff proof: nothing outside allowedDomains/failIfUnavailable/allow changes
H8="$(new_home)"; R8="$(new_repo)"; write_floor "$H8/managed.json"
write_cfg "$R8" "sensitive"
jq -n '{someOtherKey: {nested: true}, permissions:{deny:["Read(~/.ssh/**)"]}}' > "$R8/.claude/settings.json"
MANAGED_SETTINGS_PATH="$H8/managed.json" compile "$H8" "$R8" >/dev/null
assert_eq "P8: unrelated top-level key untouched" "true" "$(jq -r '.someOtherKey.nested' "$R8/.claude/settings.json")"
assert_contains "P8: unrelated permissions.deny untouched" "$(jq -r '.permissions.deny|join(",")' "$R8/.claude/settings.json")" "Read(~/.ssh/**)"

# P9 — allowedDomains absent at normal -> created with the governed set
H9="$(new_home)"; R9="$(new_repo)"; write_floor "$H9/managed.json"
write_cfg "$R9" ""
MANAGED_SETTINGS_PATH="$H9/managed.json" compile "$H9" "$R9" >/dev/null
assert_eq "P9: allowedDomains created at normal" "6" "$(jq --arg oh "$ORG_ACCESS_HOST" '[.sandbox.network.allowedDomains[] | select(. != $oh)] | length' "$R9/.claude/settings.json")"

# ═══════════════════════════════════════════════════════════════════════
# F — fail-closed
# ═══════════════════════════════════════════════════════════════════════
HF1="$(new_home)"; RF1="$(new_repo)"
OUT_F1="$(HOME="$HF1" CLAUDE_HOOK_EVENT=SessionStart bash "$COMPILE" --repo-root "$RF1" --json)"
assert_eq "F1: no stack-config.json -> NOT_GOVERNED" "NOT_GOVERNED" "$(echo "$OUT_F1" | jq -r '.verdict')"
assert_eq "F1: no receipt written" "0" "$(find "$HF1/.claude/session-state/sandbox-policy" -type f 2>/dev/null | wc -l | tr -d ' ')"

HF2="$(new_home)"; RF2="$(new_repo)"; write_floor "$HF2/managed.json"
echo 'not json' > "$RF2/.claude/stack-config.json"
OUT_F2="$(MANAGED_SETTINGS_PATH="$HF2/managed.json" compile "$HF2" "$RF2" --dry-run --json)"
assert_eq "F2: unparseable stack-config -> RESTRICTED_FALLBACK" "RESTRICTED_FALLBACK" "$(echo "$OUT_F2" | jq -r '.verdict')"
assert_eq "F2: unparseable stack-config -> Anthropic-only" "api.anthropic.com" "$(echo "$OUT_F2" | vendors_only .allowed_hosts | jq -r '.[0]')"

HF3="$(new_home)"; RF3="$(new_repo)"; write_floor "$HF3/managed.json"
echo '{"sensitivity":"sensitive"}' > "$RF3/.claude/stack-config.json"
OUT_F3="$(MANAGED_SETTINGS_PATH="$HF3/managed.json" compile "$HF3" "$RF3" --dry-run --json)"
assert_eq "F3: sensitivity as bare string -> restrictive" "RESTRICTED_FALLBACK" "$(echo "$OUT_F3" | jq -r '.verdict')"

HF4="$(new_home)"; RF4="$(new_repo)"; write_floor "$HF4/managed.json"
echo '{"sensitivity":{"level":"secret"}}' > "$RF4/.claude/stack-config.json"
OUT_F4="$(MANAGED_SETTINGS_PATH="$HF4/managed.json" compile "$HF4" "$RF4" --dry-run --json)"
assert_eq "F4: unknown level -> restrictive" "RESTRICTED_FALLBACK" "$(echo "$OUT_F4" | jq -r '.verdict')"

HF5="$(new_home)"; RF5="$(new_repo)"; write_floor "$HF5/managed.json"
write_cfg "$RF5" ""
OUT_F5="$(MANAGED_SETTINGS_PATH="$HF5/managed.json" compile "$HF5" "$RF5" --dry-run --json)"
assert_eq "F5: sensitivity absent -> normal" "normal" "$(echo "$OUT_F5" | jq -r '.level')"
assert_eq "F5: level_source default-normal" "default-normal" "$(echo "$OUT_F5" | jq -r '.level_source')"

# F6/F7 need vendor-hosts.json to be genuinely unresolvable: the compiler's
# resolution order also falls back to $CLAUDE_PLUGIN_ROOT/config/vendor-hosts.json,
# which is this real repo's real file -- point CLAUDE_PLUGIN_ROOT at an empty
# decoy dir so only the (missing/broken) $HOME copy is reachable. The
# compiler script itself is still invoked by full path, so LIB_PY resolution
# (a sibling of the script, not CLAUDE_PLUGIN_ROOT-dependent) is unaffected.
DECOY_ROOT="$(mktemp -d)"; CLEANUP_DIRS+=("$DECOY_ROOT")

HF6="$(new_home)"; RF6="$(new_repo)"; write_floor "$HF6/managed.json"
write_cfg "$RF6" "sensitive"
OUT_F6="$(HOME="$HF6" CLAUDE_PLUGIN_ROOT="$DECOY_ROOT" CLAUDE_HOOK_EVENT=SessionStart MANAGED_SETTINGS_PATH="$HF6/managed.json" \
  bash "$COMPILE" --repo-root "$RF6" --dry-run --json)"
assert_eq "F6: vendor-hosts.json absent -> restrictive fallback" "RESTRICTED_FALLBACK" "$(echo "$OUT_F6" | jq -r '.verdict')"
assert_eq "F6: fallback allowed set is Anthropic-only" "1" "$(echo "$OUT_F6" | jq '.allowed_hosts|length')"

HF7="$(new_home)"; RF7="$(new_repo)"; write_floor "$HF7/managed.json"
write_cfg "$RF7" "sensitive"
echo 'not json' > "$HF7/.claude/config/vendor-hosts.json"
OUT_F7="$(HOME="$HF7" CLAUDE_PLUGIN_ROOT="$DECOY_ROOT" CLAUDE_HOOK_EVENT=SessionStart MANAGED_SETTINGS_PATH="$HF7/managed.json" \
  bash "$COMPILE" --repo-root "$RF7" --dry-run --json)"
assert_eq "F7: vendor-hosts.json unparseable -> same as F6" "RESTRICTED_FALLBACK" "$(echo "$OUT_F7" | jq -r '.verdict')"

# F8 — drift gate: fallback host set == vendor-hosts.json host set
F8_REAL="$(jq -r '[.vendors[].host] | sort | join(",")' "$VENDOR_HOSTS")"
F8_FALLBACK="$(python3 -c "print(','.join(sorted(['api.anthropic.com','api.openai.com','generativelanguage.googleapis.com','api.deepseek.com','api.x.ai','openrouter.ai'])))")"
assert_eq "F8: hardcoded fallback host set matches config/vendor-hosts.json" "$F8_REAL" "$F8_FALLBACK"

# ═══════════════════════════════════════════════════════════════════════
# M — managed floor (non-live subset: M1-M8)
# ═══════════════════════════════════════════════════════════════════════
HM1="$(new_home)"; RM1="$(new_repo)"; write_cfg "$RM1" "sensitive"
OUT_M1="$(MANAGED_SETTINGS_PATH="$HM1/nope.json" compile "$HM1" "$RM1" --dry-run --json)"
assert_eq "M1: floor absent -> FLOOR_ABSENT" "FLOOR_ABSENT" "$(echo "$OUT_M1" | jq -r '.verdict')"

HM2="$(new_home)"; RM2="$(new_repo)"; write_cfg "$RM2" "sensitive"
jq -n '{sandbox:{enabled:false,network:{strictAllowlist:true},filesystem:{denyWrite:[]}}}' > "$HM2/managed.json"
OUT_M2="$(MANAGED_SETTINGS_PATH="$HM2/managed.json" compile "$HM2" "$RM2" --dry-run --json)"
assert_eq "M2: sandbox.enabled not true -> FLOOR_ABSENT" "FLOOR_ABSENT" "$(echo "$OUT_M2" | jq -r '.verdict')"

HM3="$(new_home)"; RM3="$(new_repo)"; write_cfg "$RM3" "sensitive"
jq -n '{sandbox:{enabled:true,network:{strictAllowlist:false},filesystem:{denyWrite:[
  "**/.claude/settings.json","**/.claude/settings.local.json","**/.claude/stack-config.json",
  "~/.claude/settings.json","~/.claude/stack-defaults.json","~/.claude/hooks/**",
  "~/.claude/scripts/**","~/.claude/config/**","~/.claude/agents/**","~/.claude/skills/**","~/.claude/lib/**"
]}}}' > "$HM3/managed.json"
OUT_M3="$(MANAGED_SETTINGS_PATH="$HM3/managed.json" compile "$HM3" "$RM3" --dry-run --json)"
assert_eq "M3: strictAllowlist off + level>normal -> WALL_ABSENT" "WALL_ABSENT" "$(echo "$OUT_M3" | jq -r '.verdict')"

HM4="$(new_home)"; RM4="$(new_repo)"; write_cfg "$RM4" "sensitive"
jq -n '{sandbox:{enabled:true,network:{strictAllowlist:true},filesystem:{denyWrite:["**/.claude/settings.json"]}}}' > "$HM4/managed.json"
OUT_M4="$(MANAGED_SETTINGS_PATH="$HM4/managed.json" compile "$HM4" "$RM4" --dry-run --json)"
assert_eq "M4: missing denyWrite path -> FLOOR_ABSENT" "FLOOR_ABSENT" "$(echo "$OUT_M4" | jq -r '.verdict')"
assert_contains "M4: message names a missing path" "$(echo "$OUT_M4" | jq -r '.floor.missing|join(",")')" "settings.local.json"

M5_HAS_KEY="$(jq '(has("allowManagedDomainsOnly")) or ((.sandbox // {}) | has("allowManagedDomainsOnly"))' "$REPO_ROOT/config/managed-settings.floor.json" 2>/dev/null)"
assert_eq "M5: managed-settings.floor.json does not set allowManagedDomainsOnly" "false" "$M5_HAS_KEY"

M6_HITS="$(grep -rn 'echo|printf|tee|jq.*>|python3 -c|dd |cp ' "$REPO_ROOT"/scripts "$REPO_ROOT"/hooks "$REPO_ROOT"/lib 2>/dev/null | grep -E 'stack-config\.json|settings\.json' | grep -v -E 'scripts/install\.sh|scripts/update\.sh|scripts/lib/settings_lock\.py|scripts/permissions-compile\.sh|scripts/sandbox-policy-compile\.sh' || true)"
if [[ -z "$M6_HITS" ]]; then
  pass "M6: no runtime code path outside install/update and the two lock-writers touches a denyWrite-listed file"
else
  fail "M6: unexpected runtime write-path hit(s): $M6_HITS"
fi

HM7="$(new_home)"; RM7="$(new_repo)"; write_cfg "$RM7" "sensitive"
OUT_M7="$(HOME="$HM7" bash "$COMPILE" --repo-root "$RM7" --dry-run 2>&1)"
RC_M7=$?
assert_rc "M7: compiler refuses (exit 2) without CLAUDE_HOOK_EVENT" "2" "$RC_M7"

M8_EXCL="$(jq -r '.sandbox.excludedCommands[]?' "$REPO_ROOT/config/managed-settings.floor.json")"
assert_contains "M8: managed excludedCommands contains permissions-compile.sh" "$M8_EXCL" "permissions-compile.sh"
assert_contains "M8: managed excludedCommands contains native_settings_edit.py" "$M8_EXCL" "native_settings_edit.py"
assert_not_contains "M8: managed excludedCommands does NOT contain settings_lock.py" "$M8_EXCL" "settings_lock.py"

# S6 — level normal, strictAllowlist false -> COMPILED (floor otherwise complete)
HS6="$(new_home)"; RS6="$(new_repo)"
jq -n '{sandbox:{enabled:true,network:{strictAllowlist:false},filesystem:{denyWrite:[
  "**/.claude/settings.json","**/.claude/settings.local.json","**/.claude/stack-config.json",
  "~/.claude/settings.json","~/.claude/stack-defaults.json","~/.claude/hooks/**",
  "~/.claude/scripts/**","~/.claude/config/**","~/.claude/agents/**","~/.claude/skills/**","~/.claude/lib/**"
]}}}' > "$HS6/managed.json"
write_cfg "$RS6" ""
OUT_S6="$(MANAGED_SETTINGS_PATH="$HS6/managed.json" compile "$HS6" "$RS6" --dry-run --json)"
assert_eq "S6: normal + strictAllowlist false -> COMPILED" "COMPILED" "$(echo "$OUT_S6" | jq -r '.verdict')"

# S5 — level > normal, strictAllowlist not in force -> WALL_ABSENT (same fixture, sensitive)
HS5="$(new_home)"; RS5="$(new_repo)"
jq -n '{sandbox:{enabled:true,network:{strictAllowlist:false},filesystem:{denyWrite:[
  "**/.claude/settings.json","**/.claude/settings.local.json","**/.claude/stack-config.json",
  "~/.claude/settings.json","~/.claude/stack-defaults.json","~/.claude/hooks/**",
  "~/.claude/scripts/**","~/.claude/config/**","~/.claude/agents/**","~/.claude/skills/**","~/.claude/lib/**"
]}}}' > "$HS5/managed.json"
write_cfg "$RS5" "sensitive"
OUT_S5="$(MANAGED_SETTINGS_PATH="$HS5/managed.json" compile "$HS5" "$RS5" --dry-run --json)"
assert_eq "S5: sensitive + strictAllowlist off -> WALL_ABSENT" "WALL_ABSENT" "$(echo "$OUT_S5" | jq -r '.verdict')"

# ═══════════════════════════════════════════════════════════════════════
# S — scope sweep / leaks
# ═══════════════════════════════════════════════════════════════════════
HS1="$(new_home)"; RS1="$(new_repo)"; write_floor "$HS1/managed.json"
write_cfg "$RS1" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["api.deepseek.com"]}}}' > "$RS1/.claude/settings.local.json"
MANAGED_SETTINGS_PATH="$HS1/managed.json" compile "$HS1" "$RS1" >/dev/null
assert_not_contains "S1: denied host removed from settings.local.json" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RS1/.claude/settings.local.json" 2>/dev/null)" "api.deepseek.com"
assert_contains "S1: removal recorded as stashed" \
  "$(jq -r '.sandbox_policy.stashed_entries[].value' "$RS1/.claude/permissions.stack.json" 2>/dev/null)" "api.deepseek.com"

HS2="$(new_home)"; RS2="$(new_repo)"; write_floor "$HS2/managed.json"
write_cfg "$RS2" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["*.supabase.co"]}}}' > "$RS2/.claude/settings.local.json"
MANAGED_SETTINGS_PATH="$HS2/managed.json" compile "$HS2" "$RS2" >/dev/null
assert_contains "S2: non-governed host in settings.local.json untouched" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RS2/.claude/settings.local.json" 2>/dev/null)" "*.supabase.co"

HS3="$(new_home)"; RS3="$(new_repo)"; write_floor "$HS3/managed.json"
write_cfg "$RS3" "confidential"
jq -n '{sandbox:{network:{allowedDomains:["api.openai.com"]}}}' > "$HS3/.claude/settings.json"
BEFORE_S3="$(cat "$HS3/.claude/settings.json")"
OUT_S3="$(MANAGED_SETTINGS_PATH="$HS3/managed.json" compile "$HS3" "$RS3" --json)"
assert_contains "S3: denied host in user-scope settings.json -> leaks.user" \
  "$(echo "$OUT_S3" | jq -r '.leaks.user|join(",")')" "api.openai.com"
AFTER_S3="$(cat "$HS3/.claude/settings.json")"
assert_eq "S3: user-scope settings.json byte-unchanged (never written)" "$BEFORE_S3" "$AFTER_S3"

HS7="$(new_home)"; RS7="$(new_repo)"
jq -n '{sandbox:{enabled:true,network:{strictAllowlist:true,allowedDomains:["api.deepseek.com"]},filesystem:{denyWrite:[
  "**/.claude/settings.json","**/.claude/settings.local.json","**/.claude/stack-config.json",
  "~/.claude/settings.json","~/.claude/stack-defaults.json","~/.claude/hooks/**",
  "~/.claude/scripts/**","~/.claude/config/**","~/.claude/agents/**","~/.claude/skills/**","~/.claude/lib/**"
]}}}' > "$HS7/managed.json"
write_cfg "$RS7" "sensitive"
OUT_S7="$(MANAGED_SETTINGS_PATH="$HS7/managed.json" compile "$HS7" "$RS7" --json)"
assert_contains "S7: denied host in managed settings -> leaks.managed" "$(echo "$OUT_S7" | jq -r '.leaks.managed|join(",")')" "api.deepseek.com"

HS8="$(new_home)"; RS8="$(new_repo)"; write_floor "$HS8/managed.json"
write_cfg "$RS8" "sensitive"
MANAGED_SETTINGS_PATH="$HS8/managed.json" compile "$HS8" "$RS8" >/dev/null
assert_eq "S8: level>normal -> project failIfUnavailable true" "true" "$(jq -r '.sandbox.failIfUnavailable' "$RS8/.claude/settings.json")"

HS8B="$(new_home)"; RS8B="$(new_repo)"; write_floor "$HS8B/managed.json"
write_cfg "$RS8B" ""
MANAGED_SETTINGS_PATH="$HS8B/managed.json" compile "$HS8B" "$RS8B" >/dev/null
assert_eq "S8: at normal, failIfUnavailable not written" "null" "$(jq -r '.sandbox.failIfUnavailable // "null"' "$RS8B/.claude/settings.json")"

# S9 uses *.deepseek.com, NOT *.openai.com: B2 (maintainer, 2026-08-11)
# cleared api.openai.com at sensitive, so *.openai.com is no longer a denied
# entry at this level -- api.deepseek.com stays uncleared and is the correct
# fixture for "a glob over a still-denied host is itself denied" (D6).
HS9="$(new_home)"; RS9="$(new_repo)"; write_floor "$HS9/managed.json"
write_cfg "$RS9" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["*.deepseek.com"]}}}' > "$RS9/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HS9/managed.json" compile "$HS9" "$RS9" >/dev/null
assert_not_contains "S9: *.deepseek.com glob at sensitive -> denied, removed" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RS9/.claude/settings.json")" "*.deepseek.com"

HS10="$(new_home)"; RS10="$(new_repo)"; write_floor "$HS10/managed.json"
write_cfg "$RS10" "confidential"
jq -n '{sandbox:{network:{allowedDomains:["API.OpenAI.com."]}}}' > "$RS10/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HS10/managed.json" compile "$HS10" "$RS10" >/dev/null
assert_not_contains "S10: API.OpenAI.com. normalized and removed" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RS10/.claude/settings.json")" "OpenAI"

HS11="$(new_home)"; RS11="$(new_repo)"; write_floor "$HS11/managed.json"
write_cfg "$RS11" "confidential"
jq -n '{sandbox:{network:{allowedDomains:["api.openai.com:443"]}}}' > "$RS11/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HS11/managed.json" compile "$HS11" "$RS11" >/dev/null
assert_not_contains "S11: api.openai.com:443 normalized and removed" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RS11/.claude/settings.json")" "openai"

HS12="$(new_home)"; RS12="$(new_repo)"; write_floor "$HS12/managed.json"
write_cfg "$RS12" "sensitive"
jq -n '{mcp_servers:[{name:"filesystem"},{name:"stripe"}]}' > "$HS12/.claude/session-state/live-capabilities.json"
OUT_S12="$(MANAGED_SETTINGS_PATH="$HS12/managed.json" compile "$HS12" "$RS12" --json)"
assert_contains "S12: unreviewed live MCP server named in leaks.mcp_unreviewed" \
  "$(echo "$OUT_S12" | jq -r '.leaks.mcp_unreviewed|join(",")')" "filesystem"

# ═══════════════════════════════════════════════════════════════════════
# WF — WebFetch pruning
# ═══════════════════════════════════════════════════════════════════════
HWF1="$(new_home)"; RWF1="$(new_repo)"; write_floor "$HWF1/managed.json"
write_cfg "$RWF1" "sensitive"
jq -n '{permissions:{allow:["WebFetch(domain:api.deepseek.com)","WebFetch(domain:example.com)","Bash(ls:*)"]}}' > "$RWF1/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HWF1/managed.json" compile "$HWF1" "$RWF1" >/dev/null
WF1_ALLOW="$(jq -r '.permissions.allow|join(",")' "$RWF1/.claude/settings.json")"
assert_not_contains "WF1: denied-host WebFetch allow rule pruned" "$WF1_ALLOW" "deepseek"
assert_contains "WF4: unrelated WebFetch allow rule untouched" "$WF1_ALLOW" "WebFetch(domain:example.com)"
assert_contains "WF4: non-WebFetch allow entry untouched" "$WF1_ALLOW" "Bash(ls:*)"
assert_not_contains "WF6: no WebFetch deny rule emitted" "$(jq -c '.permissions.deny // []' "$RWF1/.claude/settings.json")" "WebFetch"
assert_contains "WF7: prune produces a stashed[] record" \
  "$(jq -r '.sandbox_policy.stashed_entries[].value' "$RWF1/.claude/permissions.stack.json" 2>/dev/null)" "api.deepseek.com"

HWF2="$(new_home)"; RWF2="$(new_repo)"; write_floor "$HWF2/managed.json"
write_cfg "$RWF2" ""
jq -n '{permissions:{allow:["WebFetch(domain:api.openai.com)"]}}' > "$RWF2/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HWF2/managed.json" compile "$HWF2" "$RWF2" >/dev/null
assert_contains "WF2: openai allowed at normal -> NOT pruned" \
  "$(jq -r '.permissions.allow|join(",")' "$RWF2/.claude/settings.json")" "WebFetch(domain:api.openai.com)"

HWF3="$(new_home)"; RWF3="$(new_repo)"; write_floor "$HWF3/managed.json"
write_cfg "$RWF3" "sensitive"
jq -n '{permissions:{allow:["WebFetch(domain:*.deepseek.com)"]}}' > "$RWF3/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HWF3/managed.json" compile "$HWF3" "$RWF3" >/dev/null
assert_not_contains "WF3: glob-domain WebFetch rule pruned" "$(jq -r '.permissions.allow|join(",")' "$RWF3/.claude/settings.json")" "deepseek"

HWF5="$(new_home)"; RWF5="$(new_repo)"; write_floor "$HWF5/managed.json"
write_cfg "$RWF5" "sensitive"
jq -n '{permissions:{allow:["WebFetch(domain:api.deepseek.com)"]}}' > "$HWF5/.claude/settings.json"
MANAGED_SETTINGS_PATH="$HWF5/managed.json" compile "$HWF5" "$RWF5" --json >/dev/null
assert_contains "WF5: user-scope WebFetch rule reported as leak, never pruned" \
  "$(jq -r '.permissions.allow|join(",")' "$HWF5/.claude/settings.json")" "WebFetch(domain:api.deepseek.com)"

# ═══════════════════════════════════════════════════════════════════════
# LG — stash ledger
# ═══════════════════════════════════════════════════════════════════════
HLG="$(new_home)"; RLG="$(new_repo)"; write_floor "$HLG/managed.json"
write_cfg "$RLG" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["api.x.ai"]}}}' > "$RLG/.claude/settings.local.json"
MANAGED_SETTINGS_PATH="$HLG/managed.json" compile "$HLG" "$RLG" >/dev/null
assert_eq "LG1: human-seeded host adopted as owner human" "human" "$(jq -r '.sandbox_policy.ledger["api.x.ai"].owner' "$RLG/.claude/permissions.stack.json")"
assert_not_contains "LG1: still removed at sensitive" "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RLG/.claude/settings.local.json")" "api.x.ai"
LG2_ENTRY="$(jq -c '.sandbox_policy.stashed_entries[0]' "$RLG/.claude/permissions.stack.json")"
assert_contains "LG2: stash entry has value/scope/owner/stashed_on/level/reason" "$LG2_ENTRY" '"owner":"human"'

# LG3: re-compile with no new stashes prints nothing new
OUT_LG3="$(MANAGED_SETTINGS_PATH="$HLG/managed.json" compile "$HLG" "$RLG" --json)"
assert_eq "LG3: re-compile has zero new stashes" "0" "$(echo "$OUT_LG3" | jq '.result.new_stashes | length')"

# LG4: a stack-added host removed on a level change records owner stack
HLG4="$(new_home)"; RLG4="$(new_repo)"; write_floor "$HLG4/managed.json"
write_cfg "$RLG4" "normal"
MANAGED_SETTINGS_PATH="$HLG4/managed.json" compile "$HLG4" "$RLG4" >/dev/null   # adds api.openai.com etc, owner stack
write_cfg "$RLG4" "confidential"
MANAGED_SETTINGS_PATH="$HLG4/managed.json" compile "$HLG4" "$RLG4" >/dev/null   # now denies openai -> removed
assert_eq "LG4: stack-added host removed on downgrade records owner stack" "stack" "$(jq -r '.sandbox_policy.ledger["api.openai.com"].owner' "$RLG4/.claude/permissions.stack.json")"

# LG5: a hand-added pinned key does not prevent removal
HLG5="$(new_home)"; RLG5="$(new_repo)"; write_floor "$HLG5/managed.json"
write_cfg "$RLG5" "sensitive"
jq -n '{sandbox:{network:{allowedDomains:["api.x.ai"]}},sandbox_policy:{pinned:["api.x.ai"]}}' > "$RLG5/.claude/permissions.stack.json"
jq -n '{sandbox:{network:{allowedDomains:["api.x.ai"]}}}' > "$RLG5/.claude/settings.local.json"
MANAGED_SETTINGS_PATH="$HLG5/managed.json" compile "$HLG5" "$RLG5" >/dev/null
assert_not_contains "LG5: pinned key does not prevent removal" "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RLG5/.claude/settings.local.json")" "api.x.ai"

# LG6: no auto-restore on downgrade
write_cfg "$RLG" "normal"
MANAGED_SETTINGS_PATH="$HLG/managed.json" compile "$HLG" "$RLG" >/dev/null
assert_not_contains "LG6: downgrade does NOT re-add the stashed host to settings.local.json" \
  "$(jq -r '.sandbox.network.allowedDomains|join(",")' "$RLG/.claude/settings.local.json" 2>/dev/null)" "api.x.ai"
assert_contains "LG6: it stays in stashed_entries[]" "$(jq -r '.sandbox_policy.stashed_entries[].value' "$RLG/.claude/permissions.stack.json")" "api.x.ai"

# LG7: ADR-044's ledger.deny/ask, waivers[], pinned[] byte-unchanged
HLG7="$(new_home)"; RLG7="$(new_repo)"; write_floor "$HLG7/managed.json"
write_cfg "$RLG7" "sensitive"
jq -n '{ledger:{deny:{"Read(~/.ssh/**)":{owner:"stack"}},ask:{}},waivers:[{rule:"Bash(rm:*)",reason:"x",date:"2026-01-01",who:"y"}],pinned:["Bash(rm:*)"]}' > "$RLG7/.claude/permissions.stack.json"
BEFORE_LG7="$(jq -c '{ledger,waivers,pinned}' "$RLG7/.claude/permissions.stack.json")"
MANAGED_SETTINGS_PATH="$HLG7/managed.json" compile "$HLG7" "$RLG7" >/dev/null
AFTER_LG7="$(jq -c '{ledger,waivers,pinned}' "$RLG7/.claude/permissions.stack.json")"
assert_eq "LG7: ledger.deny/ask, waivers[], pinned[] byte-unchanged" "$BEFORE_LG7" "$AFTER_LG7"

# ═══════════════════════════════════════════════════════════════════════
# W — writer contract
# ═══════════════════════════════════════════════════════════════════════
HW1="$(new_home)"; RW1="$(new_repo)"
echo '{}' > "$RW1/.claude/settings.json"
OUT_W1="$(echo '{"project":{"add":["evil.example.com"],"remove":[]},"local":{"add":[],"remove":[]},"webfetch_prune":{"project":[],"local":[]},"_write_settings":true}' \
  | HOME="$HW1" python3 "$LIB_PY" --apply-sandbox-policy --target "$RW1/.claude/settings.json" --vendor-hosts "$VENDOR_HOSTS" 2>&1)"
RC_W1=$?
assert_rc "W1: refuses a host outside vendor-hosts.json (exit 2)" "2" "$RC_W1"
assert_contains "W1: refusal names the reason" "$OUT_W1" "refused"

OUT_W2="$(echo '{"project":{"add":["api.openai.com"],"remove":["api.openai.com"]},"local":{"add":[],"remove":[]},"webfetch_prune":{"project":[],"local":[]},"_write_settings":true}' \
  | HOME="$HW1" python3 "$LIB_PY" --apply-sandbox-policy --target "$RW1/.claude/settings.json" --vendor-hosts "$VENDOR_HOSTS" 2>&1)"
RC_W2=$?
assert_rc "W2: refuses add ∩ remove != empty (exit 2)" "2" "$RC_W2"

HW4="$(new_home)"; RW4="$(new_repo)"
echo 'not json' > "$RW4/.claude/settings.json"
echo '{"project":{"add":[],"remove":[]},"local":{"add":[],"remove":[]},"webfetch_prune":{"project":[],"local":[]},"_write_settings":true}' \
  | HOME="$HW4" python3 "$LIB_PY" --apply-sandbox-policy --target "$RW4/.claude/settings.json" --vendor-hosts "$VENDOR_HOSTS" >/dev/null 2>&1
assert_rc "W4: settings.json unreadable -> exit 3" "3" "$?"

HW5="$(new_home)"; RW5="$(new_repo)"; write_floor "$HW5/managed.json"
write_cfg "$RW5" "sensitive"
OUT_W5="$(CLAUDE_CODE_REMOTE=true MANAGED_SETTINGS_PATH="$HW5/managed.json" compile "$HW5" "$RW5" --json)"
assert_eq "W5: cloud session -> CLOUD_HOOK_ONLY, no settings write" "CLOUD_HOOK_ONLY" "$(echo "$OUT_W5" | jq -r '.verdict')"
assert_eq "W5: cloud session -> settings.json not created" "false" "$(test -f "$RW5/.claude/settings.json" && echo true || echo false)"

HW6="$(new_home)"; RW6="$(new_repo)"
jq -n '{sandbox:{network:"not an object"}}' > "$RW6/.claude/settings.json"
echo '{"project":{"add":["api.anthropic.com"],"remove":[]},"local":{"add":[],"remove":[]},"webfetch_prune":{"project":[],"local":[]},"_write_settings":true}' \
  | HOME="$HW6" python3 "$LIB_PY" --apply-sandbox-policy --target "$RW6/.claude/settings.json" --vendor-hosts "$VENDOR_HOSTS" >/dev/null 2>&1
assert_rc "W6: sandbox present but not an object -> exit 3" "3" "$?"

HW7="$(new_home)"; RW7="$(new_repo)"; write_floor "$HW7/managed.json"
write_cfg "$RW7" "sensitive"
MANAGED_SETTINGS_PATH="$HW7/managed.json" compile "$HW7" "$RW7" >/dev/null; cp "$RW7/.claude/settings.json" "$HW7/a.json"
MANAGED_SETTINGS_PATH="$HW7/managed.json" compile "$HW7" "$RW7" >/dev/null; cp "$RW7/.claude/settings.json" "$HW7/b.json"
if diff -q "$HW7/a.json" "$HW7/b.json" >/dev/null; then pass "W7: two concurrent compiles are byte-identical (serial proxy)"; else fail "W7: compiles diverged"; fi

# ═══════════════════════════════════════════════════════════════════════
# R — receipt + preflight
# ═══════════════════════════════════════════════════════════════════════
HR1="$(new_home)"; RR1="$(new_repo)"; write_floor "$HR1/managed.json"
git -C "$RR1" init -q 2>/dev/null; RR1="$(git -C "$RR1" rev-parse --show-toplevel)"
write_cfg "$RR1" "sensitive"
MANAGED_SETTINGS_PATH="$HR1/managed.json" compile "$HR1" "$RR1" >/dev/null
RR1_REAL="$(cd "$RR1" && pwd -P)"
RCPT_KEY="$(printf '%s' "$RR1_REAL" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
RCPT="$HR1/.claude/session-state/sandbox-policy/$RCPT_KEY.json"
if [[ -f "$RCPT" ]]; then
  # GNU stat reads -f as --file-system and succeeds with a filesystem dump, so
  # the BSD-first order silently yielded that dump as the "mode" on Linux. Ask
  # GNU-style first (BSD rejects -c) and validate the digits.
  MODE="$(stat -c '%a' "$RCPT" 2>/dev/null)"
  case "$MODE" in ''|*[!0-7]*) MODE="$(stat -f '%Lp' "$RCPT" 2>/dev/null)" ;; esac
  assert_eq "R1: receipt mode 0600" "600" "$MODE"
  jq -e . "$RCPT" >/dev/null 2>&1 && pass "R1: receipt is valid JSON" || fail "R1: receipt is not valid JSON"
  # ADR-071 §8: "Fields = plan JSON + {compiled_at, effective_this_session,
  # stack_config_mtime}" -- validator HIGH finding: these two were promised
  # and never written. Assert each is PRESENT (a missing key -- not merely a
  # null value -- must fail this test) and has the expected shape/value.
  for _field in compiled_at effective_this_session stack_config_mtime; do
    if jq -e "has(\"$_field\")" "$RCPT" >/dev/null 2>&1; then
      pass "R1: receipt has promised field '$_field'"
    else
      fail "R1: receipt is MISSING promised field '$_field' (ADR-071 architect handoff §8)"
    fi
  done
  assert_eq "R1: effective_this_session is true for a SessionStart compile" "true" "$(jq -r '.effective_this_session' "$RCPT")"
  assert_eq "R1: stack_config_mtime is a non-null timestamp string" "true" "$(jq -r '(.stack_config_mtime | type == "string") and (.stack_config_mtime | length > 0)' "$RCPT")"
else
  fail "R1: receipt not found at expected path"
fi

# R1b: a PostToolUse recompile records effective_this_session:false -- it is
# NOT guaranteed live until the next SessionStart (D9/L6 hot-reload is open).
HR1B="$(new_home)"; RR1B="$(new_repo)"; write_floor "$HR1B/managed.json"
git -C "$RR1B" init -q 2>/dev/null; RR1B="$(git -C "$RR1B" rev-parse --show-toplevel)"
write_cfg "$RR1B" "sensitive"
HOME="$HR1B" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT="PostToolUse" MANAGED_SETTINGS_PATH="$HR1B/managed.json" \
  bash "$COMPILE" --repo-root "$RR1B" >/dev/null
RR1B_REAL="$(cd "$RR1B" && pwd -P)"
RCPT_KEY_B="$(printf '%s' "$RR1B_REAL" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
RCPT_B="$HR1B/.claude/session-state/sandbox-policy/$RCPT_KEY_B.json"
assert_eq "R1b: PostToolUse compile records effective_this_session false" "false" "$(jq -r '.effective_this_session' "$RCPT_B" 2>/dev/null)"

cfp_test() {
  # cfp_test <home> <repo>
  local home="$1" repo="$2"
  cat > /tmp/cfp_vhp_test.$$.sh <<WRAP
#!/usr/bin/env bash
set -uo pipefail
source "$CFP"
cfp_vendor_policy "\$1"
WRAP
  HOME="$home" bash /tmp/cfp_vhp_test.$$.sh "$3" 2>/dev/null
  rm -f /tmp/cfp_vhp_test.$$.sh
}

R2_DECISION="$(cd "$RR1" && cfp_test "$HR1" "$RR1" "api.openai.com")"
assert_eq "R2: cfp_vendor_policy allowed when receipt allows" "allowed" "$R2_DECISION"

HR3="$(new_home)"; RR3="$(new_repo)"; write_floor "$HR3/managed.json"
git -C "$RR3" init -q 2>/dev/null; RR3="$(git -C "$RR3" rev-parse --show-toplevel)"
write_cfg "$RR3" "confidential"
MANAGED_SETTINGS_PATH="$HR3/managed.json" compile "$HR3" "$RR3" >/dev/null
R3_DECISION="$(cd "$RR3" && cfp_test "$HR3" "$RR3" "api.openai.com")"
assert_eq "R3: cfp_vendor_policy denied at confidential" "denied" "$R3_DECISION"

HR4="$(new_home)"; RR4="$(new_repo)"
git -C "$RR4" init -q 2>/dev/null; RR4="$(git -C "$RR4" rev-parse --show-toplevel)"
write_cfg "$RR4" ""
R4_DECISION="$(cd "$RR4" && cfp_test "$HR4" "$RR4" "api.openai.com")"
assert_eq "R4: no receipt + normal -> unknown" "unknown" "$R4_DECISION"

HR6="$(new_home)"; RR6="$(new_repo)"; write_floor "$HR6/managed.json"
git -C "$RR6" init -q 2>/dev/null; RR6="$(git -C "$RR6" rev-parse --show-toplevel)"
write_cfg "$RR6" "sensitive"
MANAGED_SETTINGS_PATH="$HR6/managed.json" compile "$HR6" "$RR6" >/dev/null
touch -t 203001010000 "$RR6/.claude/stack-config.json" 2>/dev/null || touch -d '2030-01-01' "$RR6/.claude/stack-config.json" 2>/dev/null
R6_DECISION="$(cd "$RR6" && cfp_test "$HR6" "$RR6" "api.openai.com")"
assert_eq "R6: receipt older than stack-config.json mtime -> unknown" "unknown" "$R6_DECISION"

HR8="$(new_home)"; RR8="$(new_repo)"; write_floor "$HR8/managed.json"
LINKED="$(mktemp -d)"; CLEANUP_DIRS+=("$LINKED")
ln -s "$RR8" "$LINKED/link"
write_cfg "$RR8" "sensitive"
MANAGED_SETTINGS_PATH="$HR8/managed.json" compile "$HR8" "$LINKED/link" >/dev/null
RR8_REAL="$(cd "$RR8" && pwd -P)"
RCPT_KEY8="$(printf '%s' "$RR8_REAL" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
if [[ -f "$HR8/.claude/session-state/sandbox-policy/$RCPT_KEY8.json" ]]; then
  pass "R8: symlinked repo root -> receipt key matches the realpath variant"
else
  fail "R8: receipt not found under the realpath-derived key"
fi

# ═══════════════════════════════════════════════════════════════════════
# CG — cloud guard
# ═══════════════════════════════════════════════════════════════════════
HCG="$(new_home)"; RCG="$(new_repo)"
git -C "$RCG" init -q 2>/dev/null
RCG_REAL="$(git -C "$RCG" rev-parse --show-toplevel)"
CG_KEY="$(printf '%s' "$RCG_REAL" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])')"
mkdir -p "$HCG/.claude/session-state/sandbox-policy"
echo '{"denied_hosts":["api.deepseek.com"]}' > "$HCG/.claude/session-state/sandbox-policy/$CG_KEY.json"

cg_run() {
  local cloud="$1" cmd="$2"
  local payload; payload="$(jq -nc --arg c "$cmd" --arg cwd "$RCG_REAL" '{tool_input:{command:$c},cwd:$cwd}')"
  if [[ "$cloud" == "1" ]]; then
    HOME="$HCG" CLAUDE_CODE_REMOTE=true bash "$CLOUD_HOOK" <<<"$payload"
  else
    HOME="$HCG" bash "$CLOUD_HOOK" <<<"$payload"
  fi
}

OUT_CG1="$(cg_run 0 "curl https://api.deepseek.com")"
assert_eq "CG1: non-cloud -> no output, denies nothing" "" "$OUT_CG1"

OUT_CG2="$(cg_run 1 "curl https://api.deepseek.com")"
assert_contains "CG2: cloud + denied host -> deny" "$OUT_CG2" '"permissionDecision":"deny"'
assert_contains "CG2: reason names ADR-071 D17 and class C" "$OUT_CG2" "D17"

OUT_CG3="$(cg_run 1 "curl https://api.anthropic.com")"
assert_eq "CG3: cloud + allowed host -> no deny" "" "$OUT_CG3"

OUT_CG4="$(cg_run 1 "echo x > .claude/settings.json")"
assert_contains "CG4: cloud + denyWrite path write -> deny" "$OUT_CG4" '"permissionDecision":"deny"'

OUT_CG5="$(cg_run 1 "echo YXBpLmRlZXBzZWVrLmNvbQ== | base64 -d | xargs curl")"
assert_eq "CG5: base64-obfuscated invocation passes (documented bypass)" "" "$OUT_CG5"

OUT_CG6="$(HOME="$HCG" CLAUDE_CODE_REMOTE=true bash -c 'echo "not json" | bash "'"$CLOUD_HOOK"'"')"
assert_eq "CG6: malformed input -> exit 0, no deny" "" "$OUT_CG6"

# CG7-CG10 (red-team HIGH, 2026-08-11): four concrete bypass vectors all
# missed by the original WRITE_VERBS_RE / literal-substring matching.
OUT_CG7="$(cg_run 1 'echo x > .claude/./settings.json')"
assert_contains "CG7: path-canonicalization bypass (.claude/./settings.json) now denied" "$OUT_CG7" '"permissionDecision":"deny"'

OUT_CG8="$(cg_run 1 'echo x > .claude/setting?.json')"
assert_contains "CG8: glob-shaped path (.claude/setting?.json) now denied" "$OUT_CG8" '"permissionDecision":"deny"'

OUT_CG9="$(cg_run 1 "cd .claude && echo '{}' > settings.json")"
assert_contains "CG9: split-path via cd + relative write now denied" "$OUT_CG9" '"permissionDecision":"deny"'

OUT_CG10="$(cg_run 1 'python3 -c "open(\".claude/settings.json\",\"w\").write(\"{}\")"')"
assert_contains "CG10: python3 open(...,\"w\") write verb now denied" "$OUT_CG10" '"permissionDecision":"deny"'

# CG11: a REMAINING, KNOWN-OPEN bypass, asserted explicitly (not left
# implied) -- variable-indirected path construction defeats both the
# literal-substring and the glob-token check, same class of gap CG5
# documents for host names. This hook is class C; it does not close every
# construction, and this test exists so no future reader mistakes it for one.
OUT_CG11="$(cg_run 1 "f=settings.json; echo x > .claude/\$f")"
assert_eq "CG11: variable-indirected path construction passes (documented, KNOWN-OPEN bypass)" "" "$OUT_CG11"

# ═══════════════════════════════════════════════════════════════════════
# H — hooks
# ═══════════════════════════════════════════════════════════════════════
HH1="$(new_home)"
NOTGIT="$(mktemp -d)"; CLEANUP_DIRS+=("$NOTGIT")
OUT_H1="$(cd "$NOTGIT" && HOME="$HH1" bash "$SESSION_HOOK" 2>&1)"
assert_eq "H1: session hook silent outside a git repo" "" "$OUT_H1"
assert_rc "H1: session hook exits 0 outside a git repo" "0" "$?"

HH2="$(new_home)"; RH2="$(new_repo)"; git -C "$RH2" init -q 2>/dev/null
OUT_H2="$(cd "$(git -C "$RH2" rev-parse --show-toplevel)" && HOME="$HH2" bash "$SESSION_HOOK" 2>&1)"
assert_eq "H2: no stack-config.json -> silent" "" "$OUT_H2"

HH4="$(new_home)"; RH4="$(new_repo)"; git -C "$RH4" init -q 2>/dev/null; write_cfg "$RH4" "sensitive"
OUT_H4="$(cd "$(git -C "$RH4" rev-parse --show-toplevel)" && HOME="$HH4" SANDBOX_POLICY_COMPILE=off bash "$SESSION_HOOK" 2>&1)"
assert_rc "H4: SANDBOX_POLICY_COMPILE=off -> hook still exits 0" "0" "$?"
NO_WRITE="$(test -f "$RH4/.claude/settings.json" && echo written || echo none)"
assert_eq "H4: no write when disabled" "none" "$NO_WRITE"

HH7A="$(new_home)"; RH7="$(new_repo)"; write_floor "$HH7A/managed.json"; write_cfg "$RH7" ""
MANAGED_SETTINGS_PATH="$HH7A/managed.json" compile "$HH7A" "$RH7" >/dev/null
jq '.sensitivity.level = "sensitive" | .change_history = [{date:"2026-08-11T00:00:00Z",setting:"sensitivity.level",old_value:"normal",new_value:"sensitive",reason:"x",scope:"project",invoked_via:"/sensitivity"}]' \
  "$RH7/.claude/stack-config.json" > "$RH7/.claude/stack-config.json.tmp" && mv "$RH7/.claude/stack-config.json.tmp" "$RH7/.claude/stack-config.json"
PAYLOAD_H7="$(jq -nc --arg fp "$RH7/.claude/stack-config.json" '{tool_input:{file_path:$fp}}')"
MANAGED_SETTINGS_PATH="$HH7A/managed.json" HOME="$HH7A" bash "$RECOMPILE_HOOK" <<<"$PAYLOAD_H7" >/dev/null 2>&1
# 2, not 3: generativelanguage.googleapis.com reverted to
# cleared_at_sensitive:false (ADR-071 D15 #6 / gemini-paid-tier-precondition
# Option A) -- sensitive now clears only api.anthropic.com + api.openai.com.
assert_eq "H7: level-changing edit triggers a recompile" "2" "$(jq --arg oh "$ORG_ACCESS_HOST" '[.sandbox.network.allowedDomains[] | select(. != $oh)] | length' "$RH7/.claude/settings.json")"

# H7 (second half): an edit that does NOT change the level is a no-op --
# resulting settings.json byte-unchanged by the recompile hook.
BEFORE_H7B="$(cat "$RH7/.claude/settings.json")"
jq '.reason = "cosmetic, level unchanged"' "$RH7/.claude/stack-config.json" > "$RH7/.claude/stack-config.json.tmp" && mv "$RH7/.claude/stack-config.json.tmp" "$RH7/.claude/stack-config.json"
PAYLOAD_H7B="$(jq -nc --arg fp "$RH7/.claude/stack-config.json" '{tool_input:{file_path:$fp}}')"
MANAGED_SETTINGS_PATH="$HH7A/managed.json" HOME="$HH7A" bash "$RECOMPILE_HOOK" <<<"$PAYLOAD_H7B" >/dev/null 2>&1
AFTER_H7B="$(cat "$RH7/.claude/settings.json")"
assert_eq "H7: edit that does not change the level is a no-op" "$BEFORE_H7B" "$AFTER_H7B"

# H7 (third half): an edit to any other path does not fire at all.
OTHER_PATH="$RH7/.claude/other-file.json"; echo '{}' > "$OTHER_PATH"
PAYLOAD_H7C="$(jq -nc --arg fp "$OTHER_PATH" '{tool_input:{file_path:$fp}}')"
OUT_H7C="$(MANAGED_SETTINGS_PATH="$HH7A/managed.json" HOME="$HH7A" bash "$RECOMPILE_HOOK" <<<"$PAYLOAD_H7C" 2>&1)"
assert_eq "H7: edit to an unrelated path produces no output" "" "$OUT_H7C"

# H8: tamper -- level change with no matching change_history entry
HH8="$(new_home)"; RH8="$(new_repo)"; write_floor "$HH8/managed.json"; write_cfg "$RH8" ""
MANAGED_SETTINGS_PATH="$HH8/managed.json" compile "$HH8" "$RH8" >/dev/null
jq '.sensitivity.level = "confidential"' "$RH8/.claude/stack-config.json" > "$RH8/.claude/stack-config.json.tmp" && mv "$RH8/.claude/stack-config.json.tmp" "$RH8/.claude/stack-config.json"
OUT_H8="$(MANAGED_SETTINGS_PATH="$HH8/managed.json" compile "$HH8" "$RH8" --json)"
assert_eq "H8: level change with no change_history entry -> tamper flag true" "true" "$(echo "$OUT_H8" | jq -r '.tamper.level_changed_without_change_history')"

# ═══════════════════════════════════════════════════════════════════════
# SEC — security-audit + red-team regression tests (2026-08-11)
# ═══════════════════════════════════════════════════════════════════════

# SEC1 — a repo-local config/vendor-hosts.json must NEVER be read (the
# removed 3rd fallback). Point CLAUDE_PLUGIN_ROOT at an empty decoy so only
# the repo-local copy could possibly answer, then plant a forged
# is_runtime:true entry there and confirm it is never honored.
HSEC1="$(new_home)"; RSEC1="$(new_repo)"; write_floor "$HSEC1/managed.json"
write_cfg "$RSEC1" "confidential"
mkdir -p "$RSEC1/config"
jq -n '{version:"1.0.0", vendors:[
  {host:"evil.example.com", vendor:"Evil", kind:"direct", is_runtime:true, cleared_at_sensitive:true, reviewed_on:"2026-01-01", terms_url:"https://x", why:"forged"}
]}' > "$RSEC1/config/vendor-hosts.json"
OUT_SEC1="$(HOME="$HSEC1" CLAUDE_PLUGIN_ROOT="$DECOY_ROOT" CLAUDE_HOOK_EVENT=SessionStart MANAGED_SETTINGS_PATH="$HSEC1/managed.json" \
  bash "$COMPILE" --repo-root "$RSEC1" --dry-run --json)"
assert_eq "SEC1: repo-local vendor-hosts.json is never read (policy_source stays hardcoded-fallback)" \
  "hardcoded-fallback" "$(echo "$OUT_SEC1" | jq -r '.policy_source')"
assert_not_contains "SEC1: forged evil.example.com never appears in allowed_hosts" \
  "$(echo "$OUT_SEC1" | jq -r '.allowed_hosts | join(",")')" "evil.example.com"

# SEC2 — vendor-hosts.json structural validation: a fake is_runtime:true
# entry (or any structural violation) falls back to the hardcoded universe,
# never trusted even from a legitimately-resolved path.
HSEC2="$(new_home)"; RSEC2="$(new_repo)"; write_floor "$HSEC2/managed.json"
write_cfg "$RSEC2" "confidential"
jq -n '{version:"1.0.0", vendors:[
  {host:"evil.example.com", vendor:"Evil", kind:"direct", is_runtime:true, cleared_at_sensitive:true, reviewed_on:"2026-01-01", terms_url:"https://x", why:"forged"}
]}' > "$HSEC2/.claude/config/vendor-hosts.json"
OUT_SEC2="$(MANAGED_SETTINGS_PATH="$HSEC2/managed.json" compile "$HSEC2" "$RSEC2" --dry-run --json)"
assert_eq "SEC2: forged is_runtime host in an otherwise-resolvable file -> hardcoded fallback" \
  "hardcoded-fallback" "$(echo "$OUT_SEC2" | jq -r '.policy_source')"
assert_not_contains "SEC2: forged host never appears in allowed_hosts" \
  "$(echo "$OUT_SEC2" | jq -r '.allowed_hosts | join(",")')" "evil.example.com"

HSEC2B="$(new_home)"; RSEC2B="$(new_repo)"; write_floor "$HSEC2B/managed.json"
write_cfg "$RSEC2B" "normal"
jq -n '{version:"1.0.0", vendors:[
  {host:"api.anthropic.com", vendor:"Anthropic", kind:"direct", is_runtime:true, cleared_at_sensitive:true, reviewed_on:"2026-01-01", terms_url:"https://x", why:"x"},
  {host:"api.anthropic.com", vendor:"Dup", kind:"direct", is_runtime:false, cleared_at_sensitive:false, reviewed_on:null, terms_url:null, why:"duplicate host"}
]}' > "$HSEC2B/.claude/config/vendor-hosts.json"
OUT_SEC2B="$(MANAGED_SETTINGS_PATH="$HSEC2B/managed.json" compile "$HSEC2B" "$RSEC2B" --dry-run --json)"
assert_eq "SEC2b: duplicate host in vendor-hosts.json -> hardcoded fallback" \
  "hardcoded-fallback" "$(echo "$OUT_SEC2B" | jq -r '.policy_source')"

# SEC3 — forging the /tmp cloud marker must NOT suppress a recompile. The
# receipt written for a sensitive-level repo must show a real compile
# (verdict != CLOUD_HOOK_ONLY) even with a stale/forged marker file present,
# with none of CLAUDE_CODE_REMOTE/CLAUDE_CODE_CLOUD/CLAUDE_CLOUD/CODESPACES/
# CLOUD_SHELL set.
touch /tmp/.claude-stack-cloud-bootstrap.done 2>/dev/null || true
HSEC3="$(new_home)"; RSEC3="$(new_repo)"; write_floor "$HSEC3/managed.json"
write_cfg "$RSEC3" "sensitive"
OUT_SEC3="$(
  unset CLAUDE_CODE_REMOTE CLAUDE_CODE_CLOUD CLAUDE_CLOUD CODESPACES CLOUD_SHELL
  MANAGED_SETTINGS_PATH="$HSEC3/managed.json" compile "$HSEC3" "$RSEC3" --json
)"
rm -f /tmp/.claude-stack-cloud-bootstrap.done 2>/dev/null || true
assert_eq "SEC3: forged /tmp cloud marker does not suppress the compile (verdict is a real compile, not CLOUD_HOOK_ONLY)" \
  "COMPILED" "$(echo "$OUT_SEC3" | jq -r '.verdict')"
# 2, not 3: generativelanguage.googleapis.com reverted to
# cleared_at_sensitive:false (ADR-071 D15 #6 / gemini-paid-tier-precondition
# Option A) -- sensitive now clears only api.anthropic.com + api.openai.com.
assert_eq "SEC3: the tightened host list is actually written despite the forged marker" \
  "2" "$(echo "$OUT_SEC3" | vendors_only .allowed_hosts | jq 'length')"

# SEC5 (red-team MEDIUM, finding 4) — the receipt must be written strictly
# AFTER settings.json, not before, so a kill between the two writes cannot
# leave a receipt claiming a tightened policy the governing file does not
# yet hold. Monkeypatches _atomic_write_json to record call order.
SEC5_OUT="$(HOME="$(new_home)" python3 - "$LIB_PY" "$VENDOR_HOSTS" <<'PYEOF'
import importlib.util
import json
import sys

lib_path, vendor_hosts_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("settings_lock", lib_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

order = []
orig = m._atomic_write_json
def spy(path, data):
    order.append(path)
    orig(path, data)
m._atomic_write_json = spy

import tempfile, os
d = tempfile.mkdtemp()
target = os.path.join(d, "settings.json")
receipt = os.path.join(d, "receipt.json")
plan = {
    "v": 1, "repo": d, "level": "sensitive",
    "project": {"add": ["api.anthropic.com"], "remove": []},
    "local": {"add": [], "remove": []},
    "webfetch_prune": {"project": [], "local": []},
    "fail_if_unavailable": True,
    "_write_settings": True,
}
sys.stdin = open(os.devnull)
import io
old_stdin_read = m._read_plan_stdin
m._read_plan_stdin = lambda: plan
import contextlib
try:
    with contextlib.redirect_stdout(io.StringIO()):
        m.apply_sandbox_policy(target, None, None, receipt, vendor_hosts_path)
finally:
    m._read_plan_stdin = old_stdin_read

# Compare basenames, not exact paths: locked_update realpath()s the
# containing directory (e.g. /tmp -> /private/tmp on macOS) before writing,
# so the recorded paths legitimately differ from the ones passed in.
target_calls = [p for p in order if os.path.basename(p) == "settings.json"]
receipt_calls = [p for p in order if os.path.basename(p) == "receipt.json"]
assert target_calls, f"target never written: {order}"
assert receipt_calls, f"receipt never written: {order}"
assert order.index(target_calls[0]) < order.index(receipt_calls[0]), f"receipt written before target: {order}"
print("ORDER_OK")
PYEOF
)"
assert_eq "SEC5: receipt is written strictly after settings.json (not before)" "ORDER_OK" "$SEC5_OUT"

# SEC6 (red-team item 5, refuted -- recorded here, not "fixed") — the
# TOCTOU-symlink claim against _atomic_write_json does not hold. Evidence:
# it uses tempfile.mkstemp (unguessable name, O_EXCL) then os.replace(), which
# never follows a symlink at the TARGET path (replaces the directory entry,
# not a symlink target) -- verified directly against a planted symlink.
SEC6_OUT="$(python3 - "$LIB_PY" <<'PYEOF'
import importlib.util, os, sys, tempfile
lib_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("settings_lock", lib_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

d = tempfile.mkdtemp()
victim = os.path.join(d, "victim.json")
with open(victim, "w") as fh:
    fh.write('{"untouched": true}')
target = os.path.join(d, "settings.json")
os.symlink(victim, target)
m._atomic_write_json(target, {"written": "here"})
# The symlink itself must be replaced (no longer a symlink); the victim
# file it pointed at must be untouched.
ok = (not os.path.islink(target)) and (open(victim).read() == '{"untouched": true}')
print("REFUTED_OK" if ok else "SYMLINK_FOLLOWED_BAD")
PYEOF
)"
assert_eq "SEC6: _atomic_write_json never follows a symlink at the write target (TOCTOU claim refuted)" "REFUTED_OK" "$SEC6_OUT"

# SEC4 — permissions-compile.sh's OWN cloud-marker check is a known,
# DIFFERENT copy (ADR-018 H4) that this implementation does not own and was
# explicitly told not to edit. Recorded here as a confirmed, non-fixed
# residual so a future reader does not assume ADR-071 closed it everywhere.
if grep -q '\.claude-stack-cloud-bootstrap\.done' "$REPO_ROOT/scripts/permissions-compile.sh" 2>/dev/null; then
  skip "SEC4: scripts/permissions-compile.sh still trusts the same /tmp marker (ADR-018 H4, out of ADR-071's ownership -- not fixed here by instruction)"
else
  pass "SEC4: scripts/permissions-compile.sh no longer references the /tmp cloud marker"
fi

echo ""
echo "vendor-host-policy: $PASS passed, $FAIL failed, ${#SKIPPED[@]} skipped"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Skipped (live-harness cases -- set RUN_LIVE_SANDBOX_TESTS=1 on macOS with the managed floor installed):"
  for s in "${SKIPPED[@]}"; do echo "  - $s"; done
fi

# ═══════════════════════════════════════════════════════════════════════
# M9-M12, L1-L8 — live sandbox / installed-floor gates. Never faked.
# ═══════════════════════════════════════════════════════════════════════
if [[ "${RUN_LIVE_SANDBOX_TESTS:-0}" != "1" ]]; then
  skip "M9 (live) — generalized write-surface EPERM proof, requires the managed floor installed (RUN_LIVE_SANDBOX_TESTS=1)"
  skip "M10 (live) — SessionStart hook DOES write settings.json under the floor"
  skip "M11 (live) — hook script itself not writable from Bash under the floor"
  skip "M12 (live) — deny-only-narrows: allowWrite cannot re-open a denyWrite path"
  skip "L1/L1b/L1c/L1d (MERGE GATE, live) — removed host actually blocks egress; IP-literal/spoofed-Host bypass bounds"
  skip "L2 (live) — same as L1 with strictAllowlist:false"
  skip "L3 (live) — api.anthropic.com reachable at confidential"
  skip "L4 (live) — localhost:11434 reachable at confidential"
  skip "L5 (live) — full test-*.sh sweep under the sandbox with the floor installed"
  skip "L6 (MERGE GATE, live) — mid-session settings.json hot-reload behavior"
  skip "L7 (live) — gh / pm CLI still work under the floor"
  skip "L8 (live) — claude -p --settings can re-widen allowedDomains (disclosure check)"
elif [[ "$(uname -s)" != "Darwin" ]]; then
  skip "M9-M12/L1-L8 — RUN_LIVE_SANDBOX_TESTS=1 but not macOS; the sandbox is a macOS Seatbelt feature here"
else
  echo "RUN_LIVE_SANDBOX_TESTS=1 on macOS, but this implementer task cannot run 'sudo' to install the managed floor (docs/runbooks/managed-floor-install.md). M9-M12/L1-L8 require a human to install the floor first, then re-run this suite. Treating as SKIP, not PASS or FAIL." >&2
  skip "M9-M12/L1-L8 — managed floor not installed in this environment; see docs/runbooks/managed-floor-install.md"
fi

[[ "$FAIL" -eq 0 ]] || RC=1
exit $RC
