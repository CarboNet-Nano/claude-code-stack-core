#!/usr/bin/env bash
# Test: scripts/mirror-sync.sh + scripts/lib/mirror-scrub.sh + .gitattributes
# (ADR-036 Job A — one-way snapshot sync of the scrubbed core to a tenant
# mirror repo). Harness style of tests/test-pack-installer.sh.
#
# Deny-by-default (post cross-family review): .gitattributes now ignores
# everything except an explicit installable-core allowlist. This suite
# proves BOTH halves of that: the archive is install-complete (case a) AND
# the two files that leaked under the old allowlist-by-exclusion version
# (docs/ADRs/035-*.md, .claude/stack-config.json) are absent (case b).

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/mirror-scrub.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap "rm -rf '$TMP'" EXIT

# --- Fixture: a full copy of the real repo's tracked-content dirs, so
# mirror-sync.sh's self-referential REPO_ROOT (computed from its own path)
# resolves to a fixture with a REAL install.sh, REAL tier manifests, and the
# REAL sensitive files (docs/ADRs/035-*.md, .claude/stack-config.json) that
# must NOT ship — this is not tested with stand-ins. ---

FIXTURE="$TMP/core-fixture"
mkdir -p "$FIXTURE"
for d in agents config hooks lib schemas scripts skills templates tests docs tools .claude; do
  [[ -e "$REPO_ROOT/$d" ]] && cp -R "$REPO_ROOT/$d" "$FIXTURE/$d"
done
# tools/* packages carry uncommitted node_modules; the real repo gitignores
# them, but the fixture repo has no .gitignore, so drop them before add -A.
rm -rf "$FIXTURE"/tools/*/node_modules
cp "$REPO_ROOT/README.md" "$FIXTURE/README.md"
cp "$REPO_ROOT/LICENSE" "$FIXTURE/LICENSE"
cp "$REPO_ROOT/.gitattributes" "$FIXTURE/.gitattributes"

git init -q "$FIXTURE"
git -C "$FIXTURE" add -A
# maintenance.auto/gc.auto off: commit otherwise spawns a detached
# `git maintenance run --auto` child under $TMP that races the EXIT trap's
# rm -rf on slow runners (same fix as mirror-sync.sh's snapshot commit).
git -C "$FIXTURE" -c user.name=test -c user.email=test@example.com \
  -c maintenance.auto=false -c gc.auto=0 \
  commit -q -m "fixture: full repo snapshot for mirror-sync tests" >/dev/null

ARCHIVED="$TMP/archived"
mkdir -p "$ARCHIVED"
git -C "$FIXTURE" archive HEAD | tar -x -C "$ARCHIVED"

# --- (a) deny-by-default archive still contains the full installable core:
# run the REAL installer against the REAL archived tree in a scratch $HOME. ---

SCRATCH_HOME="$TMP/scratch-home"
mkdir -p "$SCRATCH_HOME"
install_log="$TMP/install.log"
if ! HOME="$SCRATCH_HOME" CLAUDE_CONFIG_DIR="" bash "$ARCHIVED/scripts/install.sh" \
    --tier=2 --mode=fresh --skip-requirements > "$install_log" 2>&1; then
  echo "FAIL: scripts/install.sh failed against the archived (deny-by-default) tree"
  echo "--- install log ---"
  cat "$install_log"
  exit 1
fi
if [[ ! -f "$SCRATCH_HOME/.claude/settings.json" ]]; then
  echo "FAIL: install ran but did not land ~/.claude/settings.json"
  exit 1
fi

echo "PASS: deny-by-default archive is install-complete (scripts/install.sh succeeds)"

# --- (b) real sensitive files are ABSENT from the archive: ADR-035 (live CF
# account/store IDs) and .claude/stack-config.json (never installable-core) ---

for gone in docs/ADRs/035-tenant-secrets-cloudflare-store.md \
  .claude/stack-config.json .claude/settings.json .claude/next_prompt.md \
  docs/handoffs/2026-07-22-1144.md; do
  if [[ -e "$ARCHIVED/$gone" ]]; then
    echo "FAIL: $gone present in archived tree (deny-by-default not honored)"
    exit 1
  fi
done
if [[ -d "$ARCHIVED/docs" ]]; then
  echo "FAIL: docs/ present at all in archived tree (deny-by-default should exclude it wholesale)"
  exit 1
fi
if [[ -d "$ARCHIVED/.claude" ]]; then
  echo "FAIL: .claude/ present at all in archived tree (deny-by-default should exclude it wholesale)"
  exit 1
fi

echo "PASS: docs/ADRs (incl. live CF IDs) and .claude/ (incl. stack-config.json) are absent from the archive"

# --- (c) scrub_guard fails closed on planted sentinels, all-misses ---

CLEAN_TREE="$TMP/clean_tree"
mkdir -p "$CLEAN_TREE/scripts"
echo "ok" > "$CLEAN_TREE/scripts/install.sh"
if ! scrub_guard "$CLEAN_TREE"; then
  echo "FAIL: scrub_guard rejected a clean tree"
  exit 1
fi

DIRTY_TREE="$TMP/dirty_tree"
mkdir -p "$DIRTY_TREE/docs/handoffs" "$DIRTY_TREE/.claude" "$DIRTY_TREE/scripts"
echo "leaked handoff" > "$DIRTY_TREE/docs/handoffs/leak.md"
echo "resume" > "$DIRTY_TREE/.claude/next_prompt.md"
echo "LOCAL=1" > "$DIRTY_TREE/scripts/.env.local"
# Every planted secret is split across adjacent string literals so this
# test's own source line never contains the contiguous secret-shape
# substring — otherwise this very file, once it ships as part of core,
# would trip the mirror it's testing.
echo "STRIPE_KEY=sk_live_""abc123def456ghi789" > "$DIRTY_TREE/oops-secret.txt"
echo "GH_TOKEN=ghp_""1234567890abcdefghij1234567890abcdef" > "$DIRTY_TREE/oops-ghp.txt"
echo "GH_FINE=github_pat_""11ABCDEFG0123456789abcdefghijklmnop" > "$DIRTY_TREE/oops-fine.txt"

if scrub_out="$(scrub_guard "$DIRTY_TREE" 2>&1)"; then
  scrub_rc=0
else
  scrub_rc=$?
fi
if [[ "$scrub_rc" -eq 0 ]]; then
  echo "FAIL: scrub_guard passed a tree with planted sentinels"
  exit 1
fi
for expect in "docs/" ".claude/" ".env.local" "oops-secret.txt" "oops-ghp.txt" "oops-fine.txt"; do
  if ! grep -qF "$expect" <<<"$scrub_out"; then
    echo "FAIL: scrub_guard did not report $expect (all-misses expected, not first-fail)"
    echo "--- scrub_guard output ---"
    echo "$scrub_out"
    exit 1
  fi
done

echo "PASS: scrub_guard fails closed and lists every violation (allowlist + .env + sk_/ghp_/github_pat_)"

# --- (h) grep failure fails closed (not swallowed as "clean") ---

grep() { echo "mock: simulated grep failure" >&2; return 2; }
if scrub_err_out="$(scrub_guard "$CLEAN_TREE" 2>&1)"; then
  scrub_err_rc=0
else
  scrub_err_rc=$?
fi
unset -f grep
if [[ "$scrub_err_rc" -eq 0 ]]; then
  echo "FAIL: scrub_guard reported clean when the secret-shape grep itself errored"
  exit 1
fi
if ! grep -q "grep exit" <<<"$scrub_err_out"; then
  echo "FAIL: grep-error violation not reported: $scrub_err_out"
  exit 1
fi

echo "PASS: a grep error in the secret-shape scan fails closed, not silently clean"

# --- (j) non-https --dest is rejected ---

BARE_J="$TMP/bare-j.git"
git init -q --bare "$BARE_J"
if out_j="$(bash "$FIXTURE/scripts/mirror-sync.sh" --dest "git@github.com:example/tenant-mirror.git" 2>&1)"; then
  echo "FAIL: non-https --dest was accepted: $out_j"
  exit 1
fi
if ! grep -qi "https" <<<"$out_j"; then
  echo "FAIL: non-https rejection has no explanatory message: $out_j"
  exit 1
fi

echo "PASS: non-https --dest is rejected"

# --- Push-mechanics tests (d, e, f, g) run against a local bare repo,
# reached through an https:// URL via a throwaway `url.insteadOf` mapping
# (GIT_CONFIG_GLOBAL) — same offline technique git's own test suite uses —
# so mirror-sync.sh exercises its real https-only, real push code path
# without any network access. ---

push_url_config() { # <bare-repo-path> -> path to a throwaway gitconfig
  local bare="$1"
  local conf="$TMP/gitconfig-$(basename "$bare" .git).conf"
  # maintenance/gc off: receive-pack in the local bare repo otherwise spawns
  # a detached `git maintenance run --auto` child under $TMP after each push,
  # racing this test's EXIT-trap rm -rf.
  printf '[url "%s"]\n\tinsteadOf = https://mirror.invalid/tenant-mirror.git\n[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n' "$bare" > "$conf"
  echo "$conf"
}
FAKE_HTTPS_DEST="https://mirror.invalid/tenant-mirror.git"

# --- (d): --dry-run never pushes ---

if ! out_d="$(bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" --dry-run 2>&1)"; then
  echo "FAIL: --dry-run exited nonzero on a clean fixture: $out_d"
  exit 1
fi

echo "PASS: --dry-run never pushes (no network dest was even contacted)"

# --- (e): the push token never appears in captured output ---

BARE_E="$TMP/bare-e.git"
git init -q --bare "$BARE_E"
TOKEN="SUPERSECRET_MIRROR_TOKEN_XYZ"
if ! out_e="$(GIT_CONFIG_GLOBAL="$(push_url_config "$BARE_E")" \
    LADE_MIRROR_PUSH_TOKEN="$TOKEN" \
    bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" 2>&1)"; then
  echo "FAIL: push run failed unexpectedly: $out_e"
  exit 1
fi
if grep -q "$TOKEN" <<<"$out_e"; then
  echo "FAIL: push token leaked into captured output"
  exit 1
fi
if ! git -C "$BARE_E" rev-parse main >/dev/null 2>&1; then
  echo "FAIL: push did not land on the mirror's main"
  exit 1
fi

echo "PASS: push token never appears in output"

# --- (f): idempotency — two independent runs at the same HEAD produce a
# byte-identical mirror tree (compared by git tree hash, not commit sha,
# since each run creates a fresh parentless snapshot commit) ---

BARE_F1="$TMP/bare-f1.git"
BARE_F2="$TMP/bare-f2.git"
git init -q --bare "$BARE_F1"
git init -q --bare "$BARE_F2"

if ! out_f1a="$(GIT_CONFIG_GLOBAL="$(push_url_config "$BARE_F1")" LADE_MIRROR_PUSH_TOKEN=tok \
    bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" 2>&1)"; then
  echo "FAIL: idempotency run 1 (bare-f1) failed: $out_f1a"
  exit 1
fi
# Re-run against the same dest: exercises force-push-over-existing-main too.
if ! out_f1b="$(GIT_CONFIG_GLOBAL="$(push_url_config "$BARE_F1")" LADE_MIRROR_PUSH_TOKEN=tok \
    bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" 2>&1)"; then
  echo "FAIL: idempotency run 2 (bare-f1, force-push-over-existing-main) failed: $out_f1b"
  exit 1
fi
if ! out_f2="$(GIT_CONFIG_GLOBAL="$(push_url_config "$BARE_F2")" LADE_MIRROR_PUSH_TOKEN=tok \
    bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" 2>&1)"; then
  echo "FAIL: idempotency run 3 (bare-f2) failed: $out_f2"
  exit 1
fi

tree1="$(git -C "$BARE_F1" rev-parse main^{tree})"
tree2="$(git -C "$BARE_F2" rev-parse main^{tree})"
if [[ "$tree1" != "$tree2" ]]; then
  echo "FAIL: mirror tree not idempotent across independent runs ($tree1 != $tree2)"
  exit 1
fi

echo "PASS: mirror tree is idempotent at a fixed ref"

# --- (g): missing LADE_MIRROR_PUSH_TOKEN fails closed with remediation ---

BARE_G="$TMP/bare-g.git"
git init -q --bare "$BARE_G"
if out_g="$(GIT_CONFIG_GLOBAL="$(push_url_config "$BARE_G")" \
    env -u LADE_MIRROR_PUSH_TOKEN \
    bash "$FIXTURE/scripts/mirror-sync.sh" --dest "$FAKE_HTTPS_DEST" 2>&1)"; then
  echo "FAIL: push without LADE_MIRROR_PUSH_TOKEN exited 0"
  exit 1
fi
if ! grep -q "LADE_MIRROR_PUSH_TOKEN" <<<"$out_g"; then
  echo "FAIL: missing-token failure has no remediation message: $out_g"
  exit 1
fi

echo "PASS: missing token fails closed with a remediation message"

echo "PASS: mirror-sync deny-by-default scrub + snapshot-push mechanism verified"
