#!/usr/bin/env bash
# Test: deltas-only lint rejects verbatim core content in a pack (M3,
# ADR-013 amendment — lint is load-bearing, not optional).

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/pack-lint.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

CORE="$TMP/core"
mkdir -p "$CORE/skills/sample" "$CORE/config" "$CORE/docs"
cat > "$CORE/skills/sample/SKILL.md" << 'EOF'
# Sample
Core skill body.
EOF
cat > "$CORE/config/routing.json" << 'EOF'
{ "alpha": 1, "beta": { "gamma": 2 } }
EOF
cat > "$CORE/docs/guide.md" << 'EOF'
Docs are excluded from the corpus.
EOF

mk_pack() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cat > "$dir/tenant.json" << 'EOF'
{ "tenant_id": "carbonet", "pack_version": "1.0.0", "github": { "org": "CarboNet-Nano" } }
EOF
}

# 1. Verbatim core file (even at a DIFFERENT path) fails, naming the file
PACK="$TMP/pack1"
mk_pack "$PACK"
mkdir -p "$PACK/skills/renamed"
cp "$CORE/skills/sample/SKILL.md" "$PACK/skills/renamed/SKILL.md"
if OUT="$(lint_pack_deltas "$PACK" "$CORE" 2>&1)"; then
  echo "FAIL: verbatim core copy passed lint"
  exit 1
fi
if ! grep -q "skills/renamed/SKILL.md" <<< "$OUT" || ! grep -q "skills/sample/SKILL.md" <<< "$OUT"; then
  echo "FAIL: lint did not name pack file + matching core path: $OUT"
  exit 1
fi

# 2. Key-reordered copy of a core JSON still fails (canonical-form hash)
PACK="$TMP/pack2"
mk_pack "$PACK"
mkdir -p "$PACK/config"
cat > "$PACK/config/routing.json" << 'EOF'
{ "beta": { "gamma": 2 }, "alpha": 1 }
EOF
if lint_pack_deltas "$PACK" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: key-reordered core JSON passed lint"
  exit 1
fi

# 3. Genuinely modified file passes
PACK="$TMP/pack3"
mk_pack "$PACK"
mkdir -p "$PACK/skills/sample" "$PACK/config"
cat > "$PACK/skills/sample/SKILL.md" << 'EOF'
# Sample
Tenant-modified skill body.
EOF
cat > "$PACK/config/routing.json" << 'EOF'
{ "alpha": 99, "beta": { "gamma": 2 } }
EOF
if ! lint_pack_deltas "$PACK" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: genuinely modified pack failed lint"
  exit 1
fi

# 4. A verbatim copy of an EXCLUDED core file (docs/) passes — not in corpus
PACK="$TMP/pack4"
mk_pack "$PACK"
mkdir -p "$PACK/notes"
cp "$CORE/docs/guide.md" "$PACK/notes/guide.md"
if ! lint_pack_deltas "$PACK" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: copy of excluded docs/ file was rejected"
  exit 1
fi

# 5. tenant.json / README.md are exempt from hashing
PACK="$TMP/pack5"
mk_pack "$PACK"
echo "readme" > "$PACK/README.md"
if ! lint_pack_deltas "$PACK" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: manifest-only pack failed lint"
  exit 1
fi

# 6. Standalone wrapper works and exits non-zero on violation
PACK="$TMP/pack6"
mk_pack "$PACK"
mkdir -p "$PACK/skills/sample"
cp "$CORE/skills/sample/SKILL.md" "$PACK/skills/sample/SKILL.md"
if bash "$REPO_ROOT/scripts/pack-lint.sh" "$PACK" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: standalone pack-lint.sh passed a verbatim copy"
  exit 1
fi

echo "PASS: deltas-only lint rejects verbatim core content"
