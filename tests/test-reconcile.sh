#!/usr/bin/env bash
# Test: templates/team-admin/scripts/reconcile.sh offline decision logic.
# Stubs `gh` and `git` on PATH so no network/GitHub is touched. Verifies the
# safety gate (enabled != true forces dry-run, opens no PRs), config parsing,
# and scope enumeration.

set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="templates/team-admin/scripts/reconcile.sh"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

cat > "$STUBS/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; [ "${1:-}" = "rev-parse" ] && echo "abc1234"; exit 0; fi
if [ "${1:-}" = "clone" ]; then dest=""; for a in "$@"; do dest="$a"; done; mkdir -p "$dest"; exit 0; fi
exit 0
EOF
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  search) printf 'repo-a\nrepo-b\n'; exit 0 ;;   # two in-scope repos
  api)    exit 1 ;;                              # version stamp not found
esac
exit 0
EOF
chmod +x "$STUBS/git" "$STUBS/gh"

failures=0
# enabled:false in the template config → must force dry-run even though we pass
# DRY_RUN=false, and must never reach the PR path.
out="$(PATH="$STUBS:$PATH" CONFIG=templates/team-admin/config.yml \
      GH_TOKEN=dummy DRY_RUN=false bash "$SCRIPT" 2>&1)"; rc=$?

check() { if grep -q "$2" <<<"$out"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; failures=$((failures+1)); fi; }
[ "$rc" = "0" ] && echo "  [PASS] exits 0" || { echo "  [FAIL] exit $rc"; failures=$((failures+1)); }
check "forces dry-run when disabled" "forcing DRY_RUN"
check "enumerates tagged repos"      "2 repo(s) tagged"
check "flags repos needing bootstrap" "needs bootstrap: repo-a"
check "reports dry_run summary"      "dry_run=true"
if grep -q "PR ready" <<<"$out"; then echo "  [FAIL] opened a PR in dry-run"; failures=$((failures+1)); else echo "  [PASS] no PR opened in dry-run"; fi

# Default stack-config.json generation (the jq transform reconcile.sh runs).
gen="$(jq --arg tier "2" --arg d "2026-06-03" \
  '.stack_tier = (($tier | gsub("[^0-9]";"")) | tonumber)
   | .created = $d | .last_modified = $d
   | .purpose = "Auto-initialized by the Claude Code Stack org reconciler"' \
  templates/stack-config.template.json 2>/dev/null)"
if jq -e '.stack_tier == 2 and .created == "2026-06-03" and (.purpose | test("Auto-initialized"))' <<<"$gen" >/dev/null 2>&1; then
  echo "  [PASS] generates valid default stack-config (tier as number)"
else
  echo "  [FAIL] stack-config generation"; failures=$((failures+1))
fi

[ "$failures" -gt 0 ] && { echo "FAILED: $failures"; exit 1; }
echo "All reconcile tests passed."
