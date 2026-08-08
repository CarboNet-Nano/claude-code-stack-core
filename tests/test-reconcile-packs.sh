#!/usr/bin/env bash
# Test: templates/team-admin/scripts/reconcile-packs.sh (Job B, ADR-034 §5)
# offline decision logic. Stubs `gh` and `git` on PATH so no network/GitHub is
# touched. Verifies the opt-out (no pack_repo), the safety gate (enabled != true
# forces dry-run, opens no PRs), tenant.json parsing, scope enumeration, and the
# stale-vs-current stamp decision.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

SCRIPT="templates/team-admin/scripts/reconcile-packs.sh"
LIB_SRC="$PWD/scripts/lib"   # whole dir — project-pack-vendor.sh sources pack-installer.sh
STUBS="$(mktemp -d)"
FIX="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$FIX"' EXIT

# --- Fixture pack repo: tenant.json + one standards file --------------------
mkdir -p "$FIX/pack/standards"
printf '# security rules\n' > "$FIX/pack/standards/security.md"
cat > "$FIX/pack/tenant.json" <<'EOF'
{ "tenant_id": "carbonet", "pack_version": "1.2.0", "github": {"org":"x"},
  "standards": { "security": "standards/security.md" } }
EOF

# --- git stub: populate the two shallow clones from local fixtures ----------
cat > "$STUBS/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "clone" ]; then
  dest=""; for a in "\$@"; do dest="\$a"; done   # last arg is the dest
  mkdir -p "\$dest"
  case "\$dest" in
    */stack) mkdir -p "\$dest/scripts/lib"; cp "$LIB_SRC"/*.sh "\$dest/scripts/lib/" ;;
    */pack)  cp -R "$FIX/pack/." "\$dest/" ;;
  esac
  exit 0
fi
exit 0
EOF

# --- gh stub: 2 tagged repos; stamp lookup 404s (both stale) ----------------
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  search) printf 'repo-a\nrepo-b\n'; exit 0 ;;
  api)    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;   # stamp absent → stale
esac
exit 0
EOF
chmod +x "$STUBS/git" "$STUBS/gh"

failures=0
check() { if grep -q "$2" <<<"$3"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; failures=$((failures+1)); fi; }
nocheck() { if grep -q "$2" <<<"$3"; then echo "  [FAIL] $1"; failures=$((failures+1)); else echo "  [PASS] $1"; fi; }

# --- 1. Opt-out: template config has empty pack_repo → no-op, exit 0 --------
out1="$(PATH="$STUBS:$PATH" CONFIG=templates/team-admin/config.yml \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)"; rc1=$?
[ "$rc1" = "0" ] && echo "  [PASS] opt-out exits 0" || { echo "  [FAIL] opt-out exit $rc1"; failures=$((failures+1)); }
check "opt-out when pack_repo unset" "Job B not configured" "$out1"

# --- 2. Configured + enabled:false → forced dry-run, stale repos flagged ----
CFG="$FIX/config.yml"
cat > "$CFG" <<'EOF'
enabled: false
org: acme
topic: claude-stack
exclude:
pack_repo: https://example.invalid/carbonet-pack
pack_topic: lade-tenant-carbonet
pack_branch: chore/claude-stack-pack-update
EOF
out2="$(PATH="$STUBS:$PATH" CONFIG="$CFG" STACK_REPO=https://example.invalid/stack \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)"; rc2=$?
[ "$rc2" = "0" ] && echo "  [PASS] exits 0" || { echo "  [FAIL] exit $rc2"; failures=$((failures+1)); }
check "forces dry-run when disabled"   "forcing DRY_RUN"                 "$out2"
check "parses tenant + pack_version"   "tenant=carbonet pack_version=1.2.0" "$out2"
check "enumerates tagged repos"        "2 repo(s) tagged"                "$out2"
check "flags stale repo"               "needs pack update: repo-a"       "$out2"
check "reports dry_run summary"        "dry_run=true"                    "$out2"
nocheck "no PR opened in dry-run"      "PR ready"                        "$out2"

# --- 3. Current stamp → repo skipped (stamp equals pack_version) ------------
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  search) printf 'repo-a\n'; exit 0 ;;
  api)    printf '{"content":"MS4yLjA="}'; exit 0 ;;   # base64("1.2.0")
esac
exit 0
EOF
chmod +x "$STUBS/gh"
out3="$(PATH="$STUBS:$PATH" CONFIG="$CFG" STACK_REPO=https://example.invalid/stack \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)"
check "skips repo already on current version" "ok repo-a (current: 1.2.0)" "$out3"
nocheck "current repo not flagged stale"      "needs pack update"          "$out3"

# --- 4. Fail CLOSED: non-404 stamp lookup error → repo skipped, NOT stale ---
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  search) printf 'repo-a\n'; exit 0 ;;
  api)    echo "gh: HTTP 403 rate limit exceeded" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$STUBS/gh"
out4="$(PATH="$STUBS:$PATH" CONFIG="$CFG" STACK_REPO=https://example.invalid/stack \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)" || true   # exits 1 (a repo failed) by design
check "fails closed on non-404 API error" "skipping to avoid fail-open" "$out4"
nocheck "non-404 error not treated as stale" "needs pack update"        "$out4"

# --- 5. Invalid tenant_id in pack → hard fail (no injected PR content) ------
cat > "$FIX/pack/tenant.json" <<'EOF'
{ "tenant_id": "Evil Corp [click here](http://x)", "pack_version": "1.0.0",
  "github": {"org":"x"}, "standards": { "s": "standards/security.md" } }
EOF
# restore a normal search/api stub (must reach the tenant.json parse first anyway)
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in search) printf 'repo-a\n'; exit 0 ;; api) echo "Not Found" >&2; exit 1 ;; esac
exit 0
EOF
chmod +x "$STUBS/gh"
out5="$(PATH="$STUBS:$PATH" CONFIG="$CFG" STACK_REPO=https://example.invalid/stack \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)" && rc5=0 || rc5=$?
[ "$rc5" != "0" ] && echo "  [PASS] invalid tenant_id exits nonzero" || { echo "  [FAIL] invalid tenant_id exit $rc5"; failures=$((failures+1)); }
check "rejects invalid tenant_id" "tenant_id not" "$out5"

[ "$failures" -gt 0 ] && { echo "FAILED: $failures"; exit 1; }
echo "PASS: reconcile-packs (Job B) tests passed."
