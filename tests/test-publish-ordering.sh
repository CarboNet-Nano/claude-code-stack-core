#!/usr/bin/env bash
# Test: scripts/publish.sh binds tenant secrets before deploying, and hard-
# aborts before `wrangler deploy` if the bind fails (ADR-035 next-step #2 —
# secret-binder deploy wiring). Stubs wrangler + curl on PATH; secret-binder
# itself is untouched (regression covered separately by test-secret-binder.sh).

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$REPO_ROOT/scripts/publish.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

# --- Stub PATH: wrangler (marker file) + curl (CF API fixtures) -----------
BIN="$TMP/bin"
mkdir -p "$BIN"

WRANGLER_MARKER="$TMP/wrangler-ran.marker"
WRANGLER_ARGS_CAPTURE="$TMP/wrangler-args.captured"
cat > "$BIN/wrangler" << EOF
#!/usr/bin/env bash
: > "$WRANGLER_MARKER"
echo "\$*" > "$WRANGLER_ARGS_CAPTURE"
echo "stub wrangler: \$*" >&2
exit 0
EOF
chmod +x "$BIN/wrangler"

# Synthetic 32-hex fixture — must match ^[0-9a-f]{32}$, must never be a real
# Cloudflare Secrets Store id (the stub curl below is the only consumer).
STUB_STORE_ID="cafebabecafebabecafebabecafebabe"
cat > "$BIN/curl" << 'EOF'
#!/usr/bin/env bash
# Stub CF API: last arg is the URL (real curl invocation is
# `curl -sS --config - <url>`). Fixtures switch on PUBLISH_TEST_MODE.
url="${@: -1}"
case "$url" in
  */secrets_store/stores)
    echo "{\"success\":true,\"errors\":[],\"result\":[{\"id\":\"$STUB_STORE_ID\",\"name\":\"default\"}]}"
    ;;
  */secrets\?page=1*)
    if [[ "${PUBLISH_TEST_MODE:-ok}" == "missing" ]]; then
      echo '{"success":true,"errors":[],"result":[],"result_info":{"total_pages":1}}'
    else
      echo "{\"success\":true,\"errors\":[],\"result\":[{\"name\":\"$STUB_SECRET_NAME\",\"status\":\"active\"}],\"result_info\":{\"total_pages\":1}}"
    fi
    ;;
  *)
    echo '{"success":false,"errors":[{"code":404,"message":"unmocked"}]}'
    ;;
esac
EOF
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"
export STUB_STORE_ID

# --- Fixtures: landed tenant pack (fake HOME) + fake app repo -------------
FAKE_HOME="$TMP/home"
TENANT_ID="acme"
ACCOUNT_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SECRET_NAME="ACME_API_TOKEN"

mkdir -p "$FAKE_HOME/.claude/packs/$TENANT_ID"
cat > "$FAKE_HOME/.claude/packs/$TENANT_ID/tenant.json" << EOF
{
  "tenant_id": "$TENANT_ID",
  "pack_version": "1.0.0",
  "github": { "org": "acme-org" },
  "deploy": { "default": "cloudflare",
    "cloudflare": { "account_id": "$ACCOUNT_ID" } },
  "secrets": ["$SECRET_NAME"]
}
EOF

REPO_DIR="$TMP/app-repo"
mkdir -p "$REPO_DIR/.claude"
cat > "$REPO_DIR/.claude/stack-config.json" << EOF
{ "stack_version": "1.0.0", "stack_tier": 2, "purpose": "fixture",
  "created": "2026-07-22", "tenant_id": "$TENANT_ID" }
EOF
cat > "$REPO_DIR/wrangler.toml" << 'EOF'
name = "acme-app"
main = "src/index.ts"
EOF

export HOME="$FAKE_HOME"
export ACME_API_TOKEN="dummy-token-value"
export STUB_SECRET_NAME="$SECRET_NAME"

# 1. Bind SUCCESS -> wrangler stub runs, wrangler.toml gets the managed
#    region + the bound secret name.
export PUBLISH_TEST_MODE="ok"
rm -f "$WRANGLER_MARKER"
OUT1="$(bash "$PUBLISH" --repo="$REPO_DIR" 2>&1)" || {
  echo "FAIL: publish.sh failed on the bind-success path: $OUT1"
  exit 1
}
if [[ ! -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler stub did not run after a successful bind"
  exit 1
fi
if ! grep -qxF '# STACK_SECRETS_MANAGED' "$REPO_DIR/wrangler.toml"; then
  echo "FAIL: wrangler.toml missing the STACK_SECRETS_MANAGED region after bind"
  exit 1
fi
if ! grep -q "$SECRET_NAME" "$REPO_DIR/wrangler.toml"; then
  echo "FAIL: wrangler.toml missing the bound secret name"
  exit 1
fi
if ! grep -q -- "--config" "$WRANGLER_ARGS_CAPTURE"; then
  echo "FAIL: wrangler was not invoked with an explicit --config"
  exit 1
fi
if ! grep -qF "$REPO_DIR/wrangler.toml" "$WRANGLER_ARGS_CAPTURE"; then
  echo "FAIL: wrangler --config did not point at the bound wrangler.toml: $(cat "$WRANGLER_ARGS_CAPTURE")"
  exit 1
fi

# 2. Bind FAILURE (missing-secret fixture) -> hard-abort BEFORE wrangler.
#    Proves the ordering guarantee: deploy must never run on a failed bind.
export PUBLISH_TEST_MODE="missing"
rm -f "$WRANGLER_MARKER"
if OUT2="$(bash "$PUBLISH" --repo="$REPO_DIR" 2>&1)"; then
  echo "FAIL: publish.sh exited 0 despite a missing-secret bind failure"
  exit 1
fi
if [[ -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler ran even though bind failed — deploy must be gated on bind success"
  exit 1
fi
if ! grep -q "$SECRET_NAME" <<<"$OUT2"; then
  echo "FAIL: bind-failure output does not name the missing secret: $OUT2"
  exit 1
fi
export PUBLISH_TEST_MODE="ok"

# 3. EXTRA_ARGS containing a config/env-overriding flag must be rejected
#    BEFORE wrangler ever runs — otherwise a passthrough --config could
#    deploy a file that was never secret-bound (security fix: explicit
#    --config to the bound file is not enough on its own if an override
#    flag were still allowed through).
rm -f "$WRANGLER_MARKER" "$WRANGLER_ARGS_CAPTURE"
if OUT3="$(bash "$PUBLISH" --repo="$REPO_DIR" -- --config /tmp/evil.toml 2>&1)"; then
  echo "FAIL: publish.sh accepted a passthrough --config override: $OUT3"
  exit 1
fi
if [[ -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler ran despite a rejected --config override"
  exit 1
fi

# 3b. Glued-equals short forms must be caught too — wrangler parses `-e=prod`
#     as `--env=prod` and `-c=<path>` as `--config=<path>`; a denylist that
#     only matches the space-separated/long forms lets these through silently
#     (confirmed against real wrangler — no duplicate-flag error, since
#     publish.sh never sets --env itself).
rm -f "$WRANGLER_MARKER" "$WRANGLER_ARGS_CAPTURE"
if OUT3B="$(bash "$PUBLISH" --repo="$REPO_DIR" -- -e=prod 2>&1)"; then
  echo "FAIL: publish.sh accepted a glued -e=prod passthrough: $OUT3B"
  exit 1
fi
if [[ -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler ran despite a rejected -e=prod override"
  exit 1
fi

rm -f "$WRANGLER_MARKER" "$WRANGLER_ARGS_CAPTURE"
if OUT3C="$(bash "$PUBLISH" --repo="$REPO_DIR" -- -c=/tmp/x.json 2>&1)"; then
  echo "FAIL: publish.sh accepted a glued -c=/tmp/x.json passthrough: $OUT3C"
  exit 1
fi
if [[ -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler ran despite a rejected -c=/tmp/x.json override"
  exit 1
fi

# 4. tenant_id mismatch between stack-config and the landed pack's own
#    .tenant_id must be rejected BEFORE wrangler runs — the path is derived
#    from stack-config's tenant_id, but a stale/mislanded pack could carry a
#    different .tenant_id inside, binding the wrong tenant's CF secrets.
cp "$FAKE_HOME/.claude/packs/$TENANT_ID/tenant.json" "$TMP/tenant.json.orig"
jq '.tenant_id = "other-tenant"' "$TMP/tenant.json.orig" > "$FAKE_HOME/.claude/packs/$TENANT_ID/tenant.json"
rm -f "$WRANGLER_MARKER"
if OUT4="$(bash "$PUBLISH" --repo="$REPO_DIR" 2>&1)"; then
  echo "FAIL: publish.sh accepted a landed pack whose .tenant_id doesn't match stack-config: $OUT4"
  exit 1
fi
if [[ -f "$WRANGLER_MARKER" ]]; then
  echo "FAIL: wrangler ran despite the tenant_id mismatch"
  exit 1
fi
cp "$TMP/tenant.json.orig" "$FAKE_HOME/.claude/packs/$TENANT_ID/tenant.json"

# 5. zsh-safety — run the skill's documented command path (`bash publish.sh
#    ...`) from a zsh -c wrapper (simulating the session's default shell)
#    and confirm it succeeds with no "command not found" (the sourcing-under-
#    zsh regression the SKILL.md warns about).
if command -v zsh >/dev/null 2>&1; then
  rm -f "$WRANGLER_MARKER"
  OUT5="$(zsh -c "bash '$PUBLISH' --repo='$REPO_DIR'" 2>&1)"
  RC5=$?
  if [[ "$RC5" != 0 ]]; then
    echo "FAIL: zsh -c invocation of publish.sh failed (rc=$RC5): $OUT5"
    exit 1
  fi
  if grep -qi "command not found" <<<"$OUT5"; then
    echo "FAIL: zsh -c invocation surfaced a 'command not found' error: $OUT5"
    exit 1
  fi
  if [[ ! -f "$WRANGLER_MARKER" ]]; then
    echo "FAIL: zsh -c invocation did not reach wrangler deploy"
    exit 1
  fi
else
  echo "SKIP: zsh not found, skipping zsh-safety case"
fi

echo "PASS: publish.sh binds before deploy, hard-aborts on bind failure, zsh-safe invocation"
