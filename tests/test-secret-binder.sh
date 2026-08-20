#!/usr/bin/env bash
# Test: secret-binder emits Secrets Store bindings, bind-only, fail-hard
# (ADR-035). API mocked by overriding cf_api_get after sourcing the lib.

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/secret-binder.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

# Synthetic 32-hex fixtures — must match ^[0-9a-f]{32}$ (the store-id shape
# check) but must NEVER be real Cloudflare account/store ids (they don't
# leave the mock CF API below, which treats them as opaque strings).
STORE_ID="cafebabecafebabecafebabecafebabe"
ACCOUNT_ID="deadbeefdeadbeefdeadbeefdeadbeef"
# Planted sentinel: a "secret value" that must NEVER surface in any output.
SENTINEL="sv_PLAINTEXT_SENTINEL_do_not_leak"

cat > "$TMP/tenant.json" << EOF
{
  "tenant_id": "carbonet",
  "pack_version": "1.0.0",
  "github": { "org": "CarboNet-Nano" },
  "deploy": { "default": "cloudflare",
    "cloudflare": { "account_id": "$ACCOUNT_ID", "api_token_keychain_item": "carbonet-cf-api-token" } },
  "secrets": ["CARBONET_API_TOKEN", "CARBONET_S3_API_ENDPOINT"]
}
EOF

# --- API mock -------------------------------------------------------------
# Modes via MOCK_MODE: ok | missing | auth10000 | paginated
MOCK_MODE="ok"
cf_api_get() {
  local path="$1"
  case "$path" in
    */secrets_store/stores)
      if [[ "$MOCK_MODE" == "auth10000" ]]; then
        echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}'
      else
        echo "{\"success\":true,\"errors\":[],\"result\":[{\"id\":\"$STORE_ID\",\"name\":\"default\"}]}"
      fi
      ;;
    */secrets\?page=1*)
      case "$MOCK_MODE" in
        missing)
          echo '{"success":true,"errors":[],"result":[{"name":"CARBONET_UNRELATED","status":"active"}],"result_info":{"total_pages":1}}'
          ;;
        paginated)
          echo '{"success":true,"errors":[],"result":[{"name":"CARBONET_API_TOKEN","status":"active"}],"result_info":{"total_pages":2}}'
          ;;
        *)
          echo '{"success":true,"errors":[],"result":[{"name":"CARBONET_API_TOKEN","status":"active"},{"name":"CARBONET_S3_API_ENDPOINT","status":"pending"}],"result_info":{"total_pages":1}}'
          ;;
      esac
      ;;
    */secrets\?page=2*)
      echo '{"success":true,"errors":[],"result":[{"name":"CARBONET_S3_API_ENDPOINT","status":"pending"}],"result_info":{"total_pages":2}}'
      ;;
    *)
      echo '{"success":false,"errors":[{"code":404,"message":"unmocked path"}]}'
      ;;
  esac
}

export CARBONET_API_TOKEN="$SENTINEL"

# 1. Golden emit — byte-identical TOML (pending secret binds fine)
WRANGLER="$TMP/wrangler.toml"
cat > "$WRANGLER" << 'EOF'
name = "carbonet-app"
main = "src/index.ts"
EOF
OUT1="$(bind_tenant_secrets "$TMP/tenant.json" "$WRANGLER" 2>&1)" || {
  echo "FAIL: bind_tenant_secrets failed: $OUT1"
  exit 1
}
cat > "$TMP/golden.toml" << EOF
name = "carbonet-app"
main = "src/index.ts"

# STACK_SECRETS_MANAGED
[[secrets_store_secrets]]
binding = "CARBONET_API_TOKEN"
store_id = "$STORE_ID"
secret_name = "CARBONET_API_TOKEN"

[[secrets_store_secrets]]
binding = "CARBONET_S3_API_ENDPOINT"
store_id = "$STORE_ID"
secret_name = "CARBONET_S3_API_ENDPOINT"

# /STACK_SECRETS_MANAGED
EOF
if ! diff -u "$TMP/golden.toml" "$WRANGLER"; then
  echo "FAIL: emitted wrangler.toml does not match golden"
  exit 1
fi

# 2. Idempotency — second run: exactly one block, content unchanged
cp "$WRANGLER" "$TMP/wrangler.first"
OUT2="$(bind_tenant_secrets "$TMP/tenant.json" "$WRANGLER" 2>&1)" || {
  echo "FAIL: second bind run failed"
  exit 1
}
if ! diff -q "$TMP/wrangler.first" "$WRANGLER" > /dev/null; then
  echo "FAIL: second bind run changed the file"
  exit 1
fi
if [[ "$(grep -cx '# STACK_SECRETS_MANAGED' "$WRANGLER")" != "1" ]]; then
  echo "FAIL: duplicate managed block after re-run"
  exit 1
fi

# 3. Missing names — exit 1, stderr names EVERY missing secret
MOCK_MODE="missing"
if OUT3="$(bind_tenant_secrets "$TMP/tenant.json" "$TMP/w3.toml" 2>&1)"; then
  echo "FAIL: missing secrets did not fail the bind"
  exit 1
fi
if ! grep -q "CARBONET_API_TOKEN" <<<"$OUT3" || ! grep -q "CARBONET_S3_API_ENDPOINT" <<<"$OUT3"; then
  echo "FAIL: not all missing secrets reported: $OUT3"
  exit 1
fi

# 4. 10000 auth error — message surfaces the account-id-vs-store-id gotcha
MOCK_MODE="auth10000"
if OUT4="$(bind_tenant_secrets "$TMP/tenant.json" "$TMP/w4.toml" 2>&1)"; then
  echo "FAIL: 10000 error did not fail the bind"
  exit 1
fi
if ! grep -qi "ACCOUNT id" <<<"$OUT4" || ! grep -q "Secrets Store: Read" <<<"$OUT4"; then
  echo "FAIL: 10000 error message lacks the store-id/permission gotcha: $OUT4"
  exit 1
fi

# 5. Pagination — names from page 2 resolve
MOCK_MODE="paginated"
if ! OUT5="$(bind_tenant_secrets "$TMP/tenant.json" "$TMP/w5.toml" 2>&1)"; then
  echo "FAIL: page-2 secret did not resolve: $OUT5"
  exit 1
fi
MOCK_MODE="ok"

# 6. Token resolution order — env beats keychain; neither → instruction
security() { echo "keychain-token-value"; }
CF_API_TOKEN=""
resolve_tenant_token "carbonet" "carbonet-cf-api-token"
if [[ "$CF_API_TOKEN" != "$SENTINEL" ]]; then
  echo "FAIL: env token did not beat keychain"
  exit 1
fi
unset CARBONET_API_TOKEN
CF_API_TOKEN=""
resolve_tenant_token "carbonet" "carbonet-cf-api-token"
if [[ "$CF_API_TOKEN" != "keychain-token-value" ]]; then
  echo "FAIL: keychain fallback did not resolve"
  exit 1
fi
security() { return 1; }
if OUT6="$(resolve_tenant_token "carbonet" "carbonet-cf-api-token" 2>&1)"; then
  echo "FAIL: absent token did not fail"
  exit 1
fi
if ! grep -q "add-generic-password" <<<"$OUT6"; then
  echo "FAIL: failure message lacks the add-generic-password instruction"
  exit 1
fi
unset -f security
export CARBONET_API_TOKEN="$SENTINEL"

# 7. No-plaintext guard — the sentinel token value must not appear in any
# captured output or written TOML
if grep -q "$SENTINEL" <<<"$OUT1$OUT2$OUT3$OUT4$OUT5" \
  || grep -rq "$SENTINEL" "$WRANGLER" "$TMP/w5.toml" 2>/dev/null; then
  echo "FAIL: plaintext token leaked into output or TOML"
  exit 1
fi

# 8. Prefix enforcement — foreign-prefix secret rejected
jq '.secrets = ["OTHER_TENANT_KEY"]' "$TMP/tenant.json" > "$TMP/t8.json"
if bind_tenant_secrets "$TMP/t8.json" "$TMP/w8.toml" > /dev/null 2>&1; then
  echo "FAIL: secret without tenant prefix accepted"
  exit 1
fi

# 9. No secrets declared — clean no-op
jq '.secrets = []' "$TMP/tenant.json" > "$TMP/t9.json"
if ! bind_tenant_secrets "$TMP/t9.json" "$TMP/w9.toml" > /dev/null 2>&1; then
  echo "FAIL: empty secrets list should be a no-op success"
  exit 1
fi
if [[ -s "$TMP/w9.toml" ]]; then
  echo "FAIL: no-op bind wrote content"
  exit 1
fi

# 10. Malformed .secrets (string, not array) — must fail closed, NOT read as
# "no secrets declared" (the silent zero-bindings deploy)
jq '.secrets = "CARBONET_NOT_AN_ARRAY"' "$TMP/tenant.json" > "$TMP/t10.json"
if bind_tenant_secrets "$TMP/t10.json" "$TMP/w10.toml" > /dev/null 2>&1; then
  echo "FAIL: malformed .secrets treated as empty (fail-open)"
  exit 1
fi
if [[ -s "$TMP/w10.toml" ]]; then
  echo "FAIL: malformed .secrets still wrote TOML"
  exit 1
fi

# 11. Unsafe secret name (TOML breakout chars) rejected before emit
jq '.secrets = ["CARBONET_X\" ]]\nevil = \"y"]' "$TMP/tenant.json" > "$TMP/t11.json"
if bind_tenant_secrets "$TMP/t11.json" "$TMP/w11.toml" > /dev/null 2>&1; then
  echo "FAIL: quote-bearing secret name accepted"
  exit 1
fi

# 12. Bad account_id shape rejected
jq '.deploy.cloudflare.account_id = "not-hex"' "$TMP/tenant.json" > "$TMP/t12.json"
if bind_tenant_secrets "$TMP/t12.json" "$TMP/w12.toml" > /dev/null 2>&1; then
  echo "FAIL: non-hex account_id accepted"
  exit 1
fi

# 13. Duplicate managed markers — refuse instead of silently mangling
cat > "$TMP/w13.toml" << 'EOF'
name = "x"

# STACK_SECRETS_MANAGED
# /STACK_SECRETS_MANAGED

# STACK_SECRETS_MANAGED
# /STACK_SECRETS_MANAGED
EOF
cp "$TMP/w13.toml" "$TMP/w13.orig"
if bind_tenant_secrets "$TMP/tenant.json" "$TMP/w13.toml" > /dev/null 2>&1; then
  echo "FAIL: duplicate managed regions accepted"
  exit 1
fi
if ! diff -q "$TMP/w13.orig" "$TMP/w13.toml" > /dev/null; then
  echo "FAIL: duplicate-marker failure still mutated the file"
  exit 1
fi

# 14. xtrace must not leak the token (set -x suppressed in token paths)
TRACE_OUT="$(bash -c '
  source "'"$REPO_ROOT"'/scripts/lib/secret-binder.sh"
  export CARBONET_API_TOKEN="'"$SENTINEL"'"
  set -x
  resolve_tenant_token carbonet "" >/dev/null 2>/tmp/dev-null-substitute
' 2>&1 || true)"
if grep -q "$SENTINEL" <<<"$TRACE_OUT"; then
  echo "FAIL: set -x leaked the token to trace output"
  exit 1
fi

# 15. CF_API_BASE cannot be redirected from env (token goes to the real host)
BASE_CHECK="$(bash -c '
  export CF_API_BASE="https://evil.example"
  source "'"$REPO_ROOT"'/scripts/lib/secret-binder.sh"
  echo "$CF_API_BASE"')"
if [[ "$BASE_CHECK" != "https://api.cloudflare.com/client/v4" ]]; then
  echo "FAIL: CF_API_BASE overridable from env"
  exit 1
fi

# 16. Missing .secrets key entirely (not null, not [] — the key absent) must
# fail closed, same as malformed .secrets (case 10) — a dropped key must not
# silently deploy with zero bindings (security fix: (.secrets // []) treated
# missing/null identically to an explicit []).
jq 'del(.secrets)' "$TMP/tenant.json" > "$TMP/t16.json"
if bind_tenant_secrets "$TMP/t16.json" "$TMP/w16.toml" > /dev/null 2>&1; then
  echo "FAIL: tenant.json with no .secrets key was treated as a no-op success"
  exit 1
fi
if [[ -s "$TMP/w16.toml" ]]; then
  echo "FAIL: missing .secrets key still wrote TOML"
  exit 1
fi

# --- splice hardening (17a-17d) -------------------------------------------
# These drive replace_secrets_region directly: they are about how the file is
# read and written, not about the CF API, so no mock is involved.

# Planted "arbitrary local file" a symlink attack would try to disclose.
VICTIM_MARK="VICTIM_MARK_do_not_disclose"

# Names anything in $1 that is not one of the remaining args. The scratch
# artifacts these assertions hunt for are dotfiles (.stack_secrets.XXXXXX),
# so the glob has to cover "$dir"/.* explicitly.
unexpected_files() {
  local dir="$1"
  shift
  local f base expected keep found=""
  for f in "$dir"/* "$dir"/.*; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    [[ "$base" == "." || "$base" == ".." ]] && continue
    keep=0
    for expected in "$@"; do
      [[ "$base" == "$expected" ]] && { keep=1; break; }
    done
    [[ "$keep" == 0 ]] && found+="$base "
  done
  printf '%s' "$found"
}

# 17a. Static symlinked target — refuse, and touch neither the link nor the
# file it points at.
mkdir -p "$TMP/s17a"
printf '%s\n' "$VICTIM_MARK" > "$TMP/s17a/victim.txt"
ln -s victim.txt "$TMP/s17a/wrangler.toml"
printf 'binding = "X"\n' > "$TMP/s17a/block.toml"
if replace_secrets_region "$TMP/s17a/block.toml" "$TMP/s17a/wrangler.toml" > /dev/null 2>&1; then
  echo "FAIL: symlinked target accepted"
  exit 1
fi
if [[ ! -L "$TMP/s17a/wrangler.toml" ]]; then
  echo "FAIL: refused splice still replaced the symlink"
  exit 1
fi
if [[ "$(cat "$TMP/s17a/victim.txt")" != "$VICTIM_MARK" ]]; then
  echo "FAIL: refused splice wrote through the symlink"
  exit 1
fi

# 17b. Symlink TOCTOU — the object checked and the object read must be the
# same object. `dirname` is the first external command the splice runs, and
# in the pre-fix code it ran AFTER the [[ -L ]] guard and BEFORE every
# cat/grep/awk of the target — i.e. squarely inside the check-then-read
# window. Overriding it lands the attacker's swap there deterministically,
# with no timing luck: pre-fix this test reproduces the disclosure every run.
mkdir -p "$TMP/s17b"
printf '%s\n' "$VICTIM_MARK" > "$TMP/s17b/victim.txt"
printf 'name = "x"\n' > "$TMP/s17b/wrangler.toml"
printf 'binding = "X"\n' > "$TMP/s17b/block.toml"
dirname() {
  # Fires once. A marker file, not a variable: the splice calls dirname
  # inside a command substitution, so a variable would not survive.
  if [[ ! -e "$TMP/s17b/.swapped" ]]; then
    : > "$TMP/s17b/.swapped"
    rm -f "$TMP/s17b/wrangler.toml"
    ln -s victim.txt "$TMP/s17b/wrangler.toml"
  fi
  command dirname "$@"
}
replace_secrets_region "$TMP/s17b/block.toml" "$TMP/s17b/wrangler.toml" > /dev/null 2>&1 || true
unset -f dirname
if [[ ! -e "$TMP/s17b/.swapped" ]]; then
  echo "FAIL: TOCTOU probe never fired — dirname is no longer the window hook"
  exit 1
fi
if [[ -L "$TMP/s17b/wrangler.toml" ]]; then
  : # refused after the swap: the symlink is untouched, which is the fix
elif grep -q "$VICTIM_MARK" "$TMP/s17b/wrangler.toml"; then
  echo "FAIL: TOCTOU — a symlink swapped in after the guard was read through into the managed TOML"
  exit 1
fi
if [[ "$(cat "$TMP/s17b/victim.txt")" != "$VICTIM_MARK" ]]; then
  echo "FAIL: TOCTOU — wrote through the symlink swapped in after the guard"
  exit 1
fi

# 17c. SIGKILL mid-splice must strand nothing inside the tenant checkout.
# `mv` is overridden to SIGKILL the process at the moment the new content is
# fully built but not yet installed — the widest point of the pre-fix
# exposure, where .stack_secrets.XXXXXX sat in the tenant's repo. TMPDIR is
# pinned to a same-filesystem dir so the atomic-rename path is under test
# (the cross-filesystem fallback is 17d).
mkdir -p "$TMP/s17c" "$TMP/tmpdir17c"
printf 'name = "x"\n' > "$TMP/s17c/wrangler.toml"
printf 'binding = "X"\n' > "$TMP/s17c/block.toml"
cat > "$TMP/s17c/kill-mid-splice.sh" << EOF
source "$REPO_ROOT/scripts/lib/secret-binder.sh"
mv() { kill -9 \$\$; }
replace_secrets_region "$TMP/s17c/block.toml" "$TMP/s17c/wrangler.toml"
EOF
# One extra shell level: the "Killed" job report is emitted by the *parent* of
# the killed process, so the victim's parent has to be something whose stderr
# we can redirect — otherwise this test script prints it. The kill is expected.
bash -c "TMPDIR='$TMP/tmpdir17c' bash '$TMP/s17c/kill-mid-splice.sh'; exit 0" > /dev/null 2>&1
STRANDED="$(unexpected_files "$TMP/s17c" wrangler.toml block.toml kill-mid-splice.sh)"
if [[ -n "$STRANDED" ]]; then
  echo "FAIL: SIGKILL mid-splice stranded files in the tenant checkout: $STRANDED"
  exit 1
fi

# 17d. Cross-filesystem fallback — when the scratch dir is NOT on the target's
# filesystem, `mv` from it would be a non-atomic copy, so the splice must
# stage the rename inside the target's directory instead. Forced by stubbing
# the device probe (a second filesystem is not available in CI). Asserts the
# result is still correct and nothing is left behind on a normal exit.
mkdir -p "$TMP/s17d"
printf 'name = "x"\n' > "$TMP/s17d/wrangler.toml"
printf 'binding = "X"\n' > "$TMP/s17d/block.toml"
_secret_binder_device_of() { [[ "$1" == "$TMP/s17d" ]] && echo 111 || echo 222; }
if ! replace_secrets_region "$TMP/s17d/block.toml" "$TMP/s17d/wrangler.toml" > /dev/null 2>&1; then
  echo "FAIL: cross-filesystem splice failed"
  exit 1
fi
unset -f _secret_binder_device_of
cat > "$TMP/s17d/golden.toml" << 'EOF'
name = "x"

# STACK_SECRETS_MANAGED
binding = "X"
# /STACK_SECRETS_MANAGED
EOF
if ! diff -u "$TMP/s17d/golden.toml" "$TMP/s17d/wrangler.toml"; then
  echo "FAIL: cross-filesystem splice produced wrong content"
  exit 1
fi
LEFTOVER="$(unexpected_files "$TMP/s17d" wrangler.toml block.toml golden.toml)"
if [[ -n "$LEFTOVER" ]]; then
  echo "FAIL: cross-filesystem splice left scratch files in the tenant checkout: $LEFTOVER"
  exit 1
fi

# 17e. The install must not LOOSEN the target's mode. The splice replaces the
# target by rename, so the target inherits the scratch file's mode. Moving the
# scratch out of the target's directory silently changed that from mktemp's
# 0600 to a `>` redirect's 0644 — a hardening change must not hand back a more
# permissive wrangler.toml than before. Both install paths are checked.
file_mode() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null; }
for checked in "$WRANGLER" "$TMP/s17d/wrangler.toml"; do
  MODE="$(file_mode "$checked")"
  if [[ "$MODE" != "600" ]]; then
    echo "FAIL: splice left $checked at mode $MODE, expected 600"
    exit 1
  fi
done
unset -f file_mode

# 17. LIVE smoke (opt-in): read-only against the CarboNet store
if [[ -n "${RUN_LIVE_CF_SMOKE:-}" ]]; then
  if [[ -z "${CARBONET_API_TOKEN:-}" || "$CARBONET_API_TOKEN" == "$SENTINEL" ]]; then
    echo "SKIP live smoke: real CARBONET_API_TOKEN not in env"
  else
    unset -f cf_api_get 2>/dev/null || true
    source "$REPO_ROOT/scripts/lib/secret-binder.sh"
    CF_API_TOKEN="$CARBONET_API_TOKEN"
    LIVE_STORE="$(resolve_store_id "$ACCOUNT_ID")" || { echo "FAIL: live store resolve"; exit 1; }
    if [[ "$LIVE_STORE" != "$STORE_ID" ]]; then
      echo "FAIL: live store id $LIVE_STORE != expected $STORE_ID"
      exit 1
    fi
    resolve_secret_names "$ACCOUNT_ID" "$LIVE_STORE" \
      CARBONET_API_TOKEN CARBONET_ACCESS_KEY_ID CARBONET_SECRET_ACCESS_KEY CARBONET_S3_API_ENDPOINT \
      || { echo "FAIL: live names did not all resolve"; exit 1; }
    echo "  live smoke OK: store + 4 names resolved (read-only)"
  fi
fi

echo "PASS: secret-binder binds by name, fails hard, leaks nothing"
