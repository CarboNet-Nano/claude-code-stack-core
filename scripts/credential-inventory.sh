#!/usr/bin/env bash
# credential-inventory.sh — D18 §7.1's checklist walker.
#
# Walks the ten declared credential locations and prints presence, scope and a
# last-4 fingerprint — NEVER a value. A value-shaped string in this script's
# output is a test failure (the P0 done-test greps for token shapes).
#
# Honesty rules (ADR-085, ADR-088 D1a):
#   - A scan root that is not declared is reported as NOT SCANNED, never clean.
#   - A location this host cannot check (e.g. macOS Keychain on Linux) is
#     reported as not_scanned with a reason, never as empty.
#   - Retained-by-design credentials are DECLARED (broker-retained.json), not
#     discovered.
#
# The `principals` object always carries one key per D18 surface
# (github/cloudflare/neon/supabase/netlify). `present:false` means this host
# holds no discoverable agent credential for that surface — that is a fact
# about THIS host, and P5 must only ever run against a baseline generated on
# the machine whose keys it revokes (the `host` field says which that was).
#
# Usage: credential-inventory.sh [--json]
# Config: $CLAUDE_CONFIG_DIR/config/broker-inventory.json (scan roots)
#         $CLAUDE_CONFIG_DIR/config/broker-retained.json  (declared retained)
#         STACK_INVENTORY_CONFIG overrides the scan-root config path (tests).

set -uo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

CONF_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INV_CONF="${STACK_INVENTORY_CONFIG:-$CONF_DIR/config/broker-inventory.json}"
RETAINED_CONF="${STACK_RETAINED_CONFIG:-$CONF_DIR/config/broker-retained.json}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTN="$(hostname 2>/dev/null || echo unknown)"
OS="$(uname -s)"

# fingerprint <value> -> "…abcd" (last 4). Never the value.
fingerprint() {
  local v="$1"
  local n=${#v}
  if (( n >= 8 )); then printf '…%s' "${v: -4}"; else printf 'present'; fi
}

# Bearer token via curl's stdin config, never argv: a token passed as -H lands
# in the process command line, readable by any same-uid process for the life of
# the call — the exact leak class section 3 below hunts for in other processes.
auth_get() { # auth_get <token> <url> -> response body
  printf 'silent\nshow-error\nmax-time = 8\nheader = "Authorization: Bearer %s"\nurl = "%s"\n' \
    "$1" "$2" | curl --config - 2>/dev/null
}

# ── Scan roots (declared, never inferred) ──────────────────────────────────
SCAN_ROOTS_JSON="[]"
declare -a SCAN_ROOTS=()
if [[ -f "$INV_CONF" ]] && jq -e '.schema=="broker-inventory/v1"' "$INV_CONF" >/dev/null 2>&1; then
  while IFS= read -r r; do
    r="${r/#\~/$HOME}"
    if [[ -d "$r" ]]; then
      SCAN_ROOTS+=("$r")
      SCAN_ROOTS_JSON="$(echo "$SCAN_ROOTS_JSON" | jq --arg r "$r" '. + [{root:$r, scanned:true}]')"
    else
      SCAN_ROOTS_JSON="$(echo "$SCAN_ROOTS_JSON" | jq --arg r "$r" '. + [{root:$r, scanned:false, reason:"declared root does not exist on this host"}]')"
    fi
  done < <(jq -r '.scan_roots[]' "$INV_CONF" 2>/dev/null)
  ROOTS_DECLARED=true
else
  # No declaration -> $HOME is scanned as a safe default, and the output says
  # loudly that the declaration file is missing.
  SCAN_ROOTS+=("$HOME")
  SCAN_ROOTS_JSON="$(jq -n --arg r "$HOME" '[{root:$r, scanned:true, reason:"fallback: broker-inventory.json absent"}]')"
  ROOTS_DECLARED=false
fi

FINDINGS="[]"
add_finding() {
  # add_finding <location#> <kind> <path-or-name> <fingerprint-or-note> <surface-or-null>
  FINDINGS="$(echo "$FINDINGS" | jq --arg loc "$1" --arg kind "$2" --arg where "$3" \
    --arg note "$4" --arg surface "${5:-}" \
    '. + [{location:($loc|tonumber), kind:$kind, where:$where, note:$note,
           surface:(if $surface=="" then null else $surface end)}]')"
}

NOT_SCANNED="[]"
add_not_scanned() {
  NOT_SCANNED="$(echo "$NOT_SCANNED" | jq --arg loc "$1" --arg what "$2" --arg why "$3" \
    '. + [{location:($loc|tonumber), what:$what, reason:$why}]')"
}

# ── 1. Vendor CLI config/state ─────────────────────────────────────────────
for d in "$HOME/.config/gh" "$HOME/.wrangler" "$HOME/.config/.wrangler" \
         "$HOME/.netlify" "$HOME/.supabase" "$HOME/.config/neonctl" \
         "$HOME/Library/Application Support/gh" \
         "$HOME/Library/Preferences/.wrangler"; do
  [[ -e "$d" ]] && add_finding 1 "vendor-cli-state" "$d" "directory present" ""
done

# ── 2. Shell rc / profile / .envrc / .env* under scan roots ───────────────
ENV_VAR_RE='(GH_TOKEN|GITHUB_TOKEN|CLOUDFLARE_API_TOKEN|CF_API_TOKEN|NEON_API_KEY|SUPABASE_ACCESS_TOKEN|SUPABASE_SERVICE_ROLE|NETLIFY_AUTH_TOKEN|OPENAI_API_KEY|GEMINI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY)'
for root in "${SCAN_ROOTS[@]}"; do
  while IFS= read -r f; do
    while IFS= read -r var; do
      [[ -n "$var" ]] && add_finding 2 "env-file-assignment" "$f" "sets $var (value not read)" ""
    done < <(grep -hoE "${ENV_VAR_RE}=" "$f" 2>/dev/null | sort -u | tr -d '=')
  done < <(find "$root" -maxdepth 6 \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.npm' \) -prune -o \
             -type f \( -name '.envrc' -o -name '.env' -o -name '.env.*' -o -name '.bashrc' -o -name '.zshrc' \
                        -o -name '.profile' -o -name '.bash_profile' -o -name '.zprofile' \) -print 2>/dev/null | head -200)
done

# ── 3. Process environments ────────────────────────────────────────────────
PROC_SCANNED=false
if [[ "$OS" == "Linux" && -d /proc ]]; then
  PROC_SCANNED=true
  for envf in /proc/[0-9]*/environ; do
    pid="${envf#/proc/}"; pid="${pid%/environ}"
    [[ -r "$envf" ]] || continue
    while IFS= read -r var; do
      [[ -n "$var" ]] && add_finding 3 "process-env" "pid $pid ($(cat /proc/$pid/comm 2>/dev/null || echo '?'))" "carries $var (value not read)" ""
    done < <({ tr '\0' '\n' < "$envf"; } 2>/dev/null | grep -oE "^${ENV_VAR_RE}=" | tr -d '=' | sort -u)
  done
elif [[ "$OS" == "Darwin" ]]; then
  if command -v ps >/dev/null 2>&1; then
    PROC_SCANNED=true
    while IFS= read -r line; do
      add_finding 3 "process-env" "ps -Eww match" "$line" ""
    done < <(ps -Eww -ax 2>/dev/null | grep -oE "${ENV_VAR_RE}=" | tr -d '=' | sort -u | head -40)
  fi
fi
$PROC_SCANNED || add_not_scanned 3 "process environments" "no supported enumeration on this host"

# ── 4. launchd / systemd EnvironmentVariables ──────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
  for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      grep -q 'EnvironmentVariables' "$f" 2>/dev/null && add_finding 4 "launchd-env" "$f" "declares EnvironmentVariables (values not read)" ""
    done < <(find "$d" -name '*.plist' -maxdepth 1 2>/dev/null)
  done
elif [[ "$OS" == "Linux" ]]; then
  for d in "$HOME/.config/systemd/user" /etc/systemd/system; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      grep -qE '^Environment=' "$f" 2>/dev/null && add_finding 4 "systemd-env" "$f" "declares Environment= (values not read)" ""
    done < <(find "$d" -name '*.service' -maxdepth 1 2>/dev/null)
  done
else
  add_not_scanned 4 "service-manager environments" "unsupported OS $OS"
fi

# ── 5. Keychain item NAMES only ────────────────────────────────────────────
if command -v security >/dev/null 2>&1; then
  while IFS= read -r kc; do
    kc="$(echo "$kc" | sed 's/^ *"//; s/" *$//')"
    [[ -z "$kc" ]] && continue
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && add_finding 5 "keychain-item" "$kc" "service: $svc (value never read)" ""
    done < <(security dump-keychain "$kc" 2>/dev/null | grep -E '"svce"' | sed 's/.*<blob>="\(.*\)"$/\1/' | sort -u | head -100)
  done < <(security list-keychains 2>/dev/null)
else
  add_not_scanned 5 "Keychain" "security(1) not present on this host ($OS)"
fi

# ── 6. git credential helpers ──────────────────────────────────────────────
for scope in system global; do
  while IFS= read -r h; do
    [[ -n "$h" ]] && add_finding 6 "git-credential-helper" "git config --$scope" "$h" "github"
  done < <(git config --$scope --get-all credential.helper 2>/dev/null)
done
[[ -f "$HOME/.git-credentials" ]] && add_finding 6 "git-credentials-file" "$HOME/.git-credentials" "file present ($(grep -c . "$HOME/.git-credentials" 2>/dev/null || echo '?') entries; values not read)" "github"

# ── 7. SSH ─────────────────────────────────────────────────────────────────
for k in "$HOME"/.ssh/id_*; do
  [[ -f "$k" && "$k" != *.pub ]] && add_finding 7 "ssh-private-key" "$k" "private key file present" "github"
done
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  add_finding 7 "ssh-agent" "SSH_AUTH_SOCK" "agent socket present" "github"
  if command -v ssh-add >/dev/null 2>&1; then
    n="$(ssh-add -l 2>/dev/null | grep -c . || true)"
    add_finding 7 "ssh-agent-keys" "ssh-add -l" "$n identity(ies) loaded" "github"
  fi
fi
[[ -f "$HOME/.ssh/config" ]] && grep -qiE '^\s*(IdentityFile|ForwardAgent\s+yes)' "$HOME/.ssh/config" 2>/dev/null && \
  add_finding 7 "ssh-config" "$HOME/.ssh/config" "declares IdentityFile/ForwardAgent" "github"
while IFS= read -r m; do
  [[ -n "$m" ]] && add_finding 7 "ssh-controlmaster" "$m" "live control socket" "github"
done < <(find "$HOME/.ssh" -maxdepth 1 -type s 2>/dev/null)

# ── 8. MCP grants / servers ────────────────────────────────────────────────
for f in "$HOME/.claude/.credentials.json" "$CONF_DIR/.credentials.json"; do
  [[ -f "$f" ]] && add_finding 8 "mcp-credential-store" "$f" "store present (values not read)" ""
done
for f in "$CONF_DIR/settings.json" ".claude/settings.json" "$HOME/.claude.json"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r s; do
    [[ -n "$s" ]] && add_finding 8 "mcp-server-configured" "$f" "$s" ""
  done < <(jq -r '(.mcpServers // {}) | keys[]' "$f" 2>/dev/null)
  while IFS= read -r p; do
    [[ -n "$p" ]] && add_finding 8 "plugin-enabled" "$f" "$p" ""
  done < <(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value==true) | .key' "$f" 2>/dev/null)
done
while IFS= read -r p; do
  [[ -n "$p" ]] && add_finding 8 "mcp-server-process" "pgrep" "$p" ""
done < <(pgrep -fl 'mcp' 2>/dev/null | head -20 | awk '{$1=""; print substr($0,2)}' | sort -u)

# ── 9. Other cloud CLI caches ──────────────────────────────────────────────
for d in "$HOME/.aws" "$HOME/.config/gcloud" "$HOME/.kube/config" "$HOME/.azure" "$HOME/.docker/config.json"; do
  [[ -e "$d" ]] && add_finding 9 "cloud-cli-cache" "$d" "present" ""
done

# ── 10. Repo-local secrets under scan roots ────────────────────────────────
for root in "${SCAN_ROOTS[@]}"; do
  while IFS= read -r f; do
    add_finding 10 "repo-secret-file" "$f" "file present (values not read)" ""
  done < <(find "$root" -maxdepth 6 \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
             -type f \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.tfvars' -o -name 'terraform.tfstate' \) -print 2>/dev/null | head -100)
done

# ── Principals: the ids P5 revokes, by id where resolvable ─────────────────
# Value never printed; fingerprint is last-4. Identity resolution is a single
# read-only call per surface and is skipped (id:null, id_error noted) when the
# network or credential is absent.
principal_json() {
  # args: surface, present(0/1), source, fingerprint, id, id_error
  jq -n --arg s "$1" --argjson present "$2" --arg src "$3" --arg fp "$4" \
        --arg id "$5" --arg err "$6" \
    '{present:($present==1),
      source:(if $src=="" then null else $src end),
      fingerprint:(if $fp=="" then null else $fp end),
      principal_id:(if $id=="" then null else $id end),
      id_error:(if $err=="" then null else $err end)}'
}

# github
GH_SRC=""; GH_TOK=""
if [[ -n "${GH_TOKEN:-}" ]]; then GH_TOK="$GH_TOKEN"; GH_SRC="env:GH_TOKEN";
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then GH_TOK="$GITHUB_TOKEN"; GH_SRC="env:GITHUB_TOKEN";
elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then GH_TOK="$(gh auth token 2>/dev/null)"; GH_SRC="gh auth token"; fi
if [[ -z "$GH_TOK" ]]; then
  # git credential helper is how this host may authenticate pushes
  cred="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | grep '^password=' | head -1 | cut -d= -f2-)"
  [[ -n "$cred" ]] && { GH_TOK="$cred"; GH_SRC="git-credential-helper"; }
fi
GH_ID=""; GH_IDERR=""
if [[ -n "$GH_TOK" ]]; then
  GH_ID="$(auth_get "$GH_TOK" https://api.github.com/user | jq -r 'if .login then "\(.login) (id \(.id))" else empty end' 2>/dev/null)"
  [[ -z "$GH_ID" ]] && GH_IDERR="identity endpoint unresolvable from this host"
  P_GITHUB="$(principal_json github 1 "$GH_SRC" "$(fingerprint "$GH_TOK")" "$GH_ID" "$GH_IDERR")"
else
  P_GITHUB="$(principal_json github 0 "" "" "" "no agent github credential discovered on this host")"
fi

simple_principal() {
  # args: surface, token, source, id_url, jq_id_expr
  local surface="$1" tok="$2" src="$3" id_url="$4" idexpr="$5"
  if [[ -z "$tok" ]]; then
    principal_json "$surface" 0 "" "" "" "no agent $surface credential discovered on this host"
    return
  fi
  local id="" iderr=""
  id="$(auth_get "$tok" "$id_url" | jq -r "$idexpr" 2>/dev/null)"
  [[ -z "$id" || "$id" == "null" ]] && { id=""; iderr="identity endpoint unresolvable from this host"; }
  principal_json "$surface" 1 "$src" "$(fingerprint "$tok")" "$id" "$iderr"
}

CF_TOK="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"; CF_SRC=""; [[ -n "$CF_TOK" ]] && CF_SRC="env"
P_CLOUDFLARE="$(simple_principal cloudflare "$CF_TOK" "$CF_SRC" "https://api.cloudflare.com/client/v4/user/tokens/verify" '.result.id // empty')"

NEON_TOK="${NEON_API_KEY:-}"; NEON_SRC=""; [[ -n "$NEON_TOK" ]] && NEON_SRC="env:NEON_API_KEY"
P_NEON="$(simple_principal neon "$NEON_TOK" "$NEON_SRC" "https://console.neon.tech/api/v2/users/me" '.id // empty')"

SB_TOK="${SUPABASE_ACCESS_TOKEN:-}"; SB_SRC=""
[[ -z "$SB_TOK" && -f "$HOME/.supabase/access-token" ]] && { SB_TOK="$(cat "$HOME/.supabase/access-token" 2>/dev/null)"; SB_SRC="~/.supabase/access-token"; }
[[ -n "$SB_TOK" && -z "$SB_SRC" ]] && SB_SRC="env:SUPABASE_ACCESS_TOKEN"
P_SUPABASE="$(simple_principal supabase "$SB_TOK" "$SB_SRC" "https://api.supabase.com/v1/organizations" 'if type=="array" and length>0 then .[0].id else empty end')"

NL_TOK="${NETLIFY_AUTH_TOKEN:-}"; NL_SRC=""; [[ -n "$NL_TOK" ]] && NL_SRC="env:NETLIFY_AUTH_TOKEN"
P_NETLIFY="$(simple_principal netlify "$NL_TOK" "$NL_SRC" "https://api.netlify.com/api/v1/user" '.id // empty')"

# ── Retained-by-design (declared, not discovered) ──────────────────────────
if [[ -f "$RETAINED_CONF" ]] && jq -e '.schema=="broker-retained/v1"' "$RETAINED_CONF" >/dev/null 2>&1; then
  RETAINED="$(jq '.retained' "$RETAINED_CONF")"
else
  RETAINED="null"
fi

WARNING=""
if [[ "$HOSTN" != *MBP* && "$HOSTN" != *Williams* ]]; then
  WARNING="baseline generated on host '$HOSTN' — NOT the maintainer's machine. P5 revokes by the ids in the baseline generated on the machine whose keys it revokes; regenerate there before any revocation."
fi

OUT="$(jq -n \
  --arg now "$NOW" --arg host "$HOSTN" --arg os "$OS" \
  --argjson roots_declared "$([[ $ROOTS_DECLARED == true ]] && echo true || echo false)" \
  --argjson scan_roots "$SCAN_ROOTS_JSON" \
  --argjson findings "$FINDINGS" \
  --argjson not_scanned "$NOT_SCANNED" \
  --argjson p_github "$P_GITHUB" --argjson p_cloudflare "$P_CLOUDFLARE" \
  --argjson p_neon "$P_NEON" --argjson p_supabase "$P_SUPABASE" \
  --argjson p_netlify "$P_NETLIFY" \
  --argjson retained "$RETAINED" \
  --arg warning "$WARNING" \
  '{schema:"credential-inventory/v1", generated_at:$now, host:$host, os:$os,
    warning:(if $warning=="" then null else $warning end),
    scan_roots_declared:$roots_declared,
    scan_roots:$scan_roots,
    principals:{github:$p_github, cloudflare:$p_cloudflare, neon:$p_neon,
                supabase:$p_supabase, netlify:$p_netlify},
    findings:$findings,
    not_scanned:$not_scanned,
    retained:$retained}')"

if (( JSON )); then
  echo "$OUT"
else
  echo "credential-inventory @ $NOW on $HOSTN ($OS)"
  echo "$OUT" | jq -r '.principals | to_entries[] | "  \(.key): \(if .value.present then "present via \(.value.source) [\(.value.fingerprint)]\(if .value.principal_id then " id=" + .value.principal_id else "" end)" else "not discovered" end)"'
  echo "  findings: $(echo "$OUT" | jq '.findings|length'), not_scanned: $(echo "$OUT" | jq '.not_scanned|length')"
  [[ -n "$WARNING" ]] && echo "  ⚠️  $WARNING"
fi
