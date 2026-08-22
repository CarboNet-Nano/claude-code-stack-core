#!/usr/bin/env bash
# scripts/gen-portable-core-manifest.sh — generate config/portable-core-manifest.json
# (ADR-075 D6). Source-repo-only, and DELIBERATELY NOT a tier-0 entry.
#
# Why not tier-0 (D6 guard 1): the manifest's whole value is that `known` holds
# every blob a managed path has ever had. Regenerating it anywhere but the full
# source history produces a manifest where `known == [current]`, which
# classifies every older copy `diverged` and silently disables self-healing for
# the entire fleet. Not shipping the generator means it cannot be run by
# accident on a consumer machine.
#
# Guard 2 is the belt to that suspenders: this script refuses on a shallow
# clone, and on any managed path with fewer than 2 commits — the shape a
# force-pushed parentless snapshot (the public mirror) always has (-> PM8).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
gen-portable-core-manifest.sh [--check] [--out PATH]

  (default)   regenerate config/portable-core-manifest.json
  --check     write nothing; exit 0 if the on-disk .files matches a fresh
              generation, 1 if it differs (prints the differing paths)
  --out PATH  write somewhere other than the default
EOF
}

CHECK=0
OUT="$REPO_ROOT/config/portable-core-manifest.json"
# The committed manifest is ALWAYS the seed for `known`, even when --out
# redirects the write elsewhere (a --out temp file holds no history, and
# seeding from it would silently defeat the append-only rule below).
PRIOR_SRC="$REPO_ROOT/config/portable-core-manifest.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "gen-portable-core-manifest: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "gen-portable-core-manifest: git is required" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "gen-portable-core-manifest: jq is required" >&2; exit 2; }

_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else return 1; fi
}
printf '' | _sha256 >/dev/null 2>&1 || {
  echo "gen-portable-core-manifest: no sha256 tool (shasum or sha256sum)" >&2; exit 2; }

SKILLS_LIST="$REPO_ROOT/config/portable-core-skills.json"
[[ -f "$SKILLS_LIST" ]] || {
  echo "gen-portable-core-manifest: not the stack source repo (no config/portable-core-skills.json)" >&2
  exit 2; }
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "gen-portable-core-manifest: not a git repository" >&2; exit 2; }

# --- D6 guard 2, part 1: shallowness is a WARNING, not a refusal.
#
# ADR-075 D6 specified refusing outright on `--is-shallow-repository`. That
# gate is wrong against reality: the maintainer's own source clone reports
# shallow while carrying 617 commits and 20 revisions of a managed path. A
# blunt refusal there means the generator can never run on the machine that
# owns the manifest — it would fail closed on the only supported workflow.
#
# The precise test is per-path, below: a force-pushed parentless snapshot (the
# public mirror, the case D6 actually exists to catch) yields exactly ONE
# commit per path regardless of clone depth, so that check catches it while
# this one only guesses. Shallowness is reported so a thin manifest is
# attributable, and left to the per-path gate to reject if it truly is thin.
if [[ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
  echo "gen-portable-core-manifest: note — shallow clone; 'known' covers only the history present here." >&2
fi

mapfile_compat() {  # macOS ships bash 3.2; no mapfile.
  local __var="$1"; shift
  local __line; local -a __acc=()
  while IFS= read -r __line; do [[ -n "$__line" ]] && __acc+=("$__line"); done
  eval "$__var=(\"\${__acc[@]+\${__acc[@]}}\")"
}

SKILLS=()
mapfile_compat SKILLS < <(jq -r '.skills[]' "$SKILLS_LIST" 2>/dev/null)
(( ${#SKILLS[@]} > 0 )) || { echo "gen-portable-core-manifest: no skills listed" >&2; exit 2; }

PATHS=()
for s in "${SKILLS[@]}"; do
  _p=()
  mapfile_compat _p < <(git -C "$REPO_ROOT" ls-files "skills/$s/" 2>/dev/null)
  PATHS+=("${_p[@]+${_p[@]}}")
done
(( ${#PATHS[@]} > 0 )) || { echo "gen-portable-core-manifest: no managed files found" >&2; exit 2; }

FILES_JSON='{}'
for rel in "${PATHS[@]}"; do
  abs="$REPO_ROOT/$rel"
  [[ -f "$abs" ]] || continue

  current="sha256:$(_sha256 < "$abs")"

  # --- D6 guard 2, part 2: a parentless force-pushed snapshot (the public
  # mirror) yields exactly one commit per path, forever, regardless of clone
  # depth. That is the case that silently breaks the fleet, so refuse on it.
  commit_count="$(git -C "$REPO_ROOT" log --all --format=%H -- "$rel" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$commit_count" =~ ^[0-9]+$ ]] && (( commit_count < 2 )); then
    cat >&2 <<EOF
gen-portable-core-manifest: refusing — '$rel' has $commit_count commit(s) in this repo.

A managed path with no history means this is a snapshot, not the source
repository — the public mirror is force-pushed parentless, so it always looks
like this. A manifest generated here would hold one hash per path and classify
every older copy as hand-edited.

Run this in a full clone of the stack source repository.
EOF
    exit 2
  fi

  # APPEND-ONLY. `known` means "every version the stack has ever published",
  # and git is not a reliable record of that: a squash merge, a deleted
  # branch, a dropped stash or a `gc` all make a real published version
  # unreachable. Rebuilding purely from `git log --all` therefore SHRINKS
  # the list over time, and a machine still holding a dropped version stops
  # being recognised as stale — it reads as hand-edited and never
  # self-heals again, which is precisely the failure ADR-075 exists to
  # prevent. Measured 2026-08-19: a plain rebuild dropped 1 hash from
  # goodmorning and 2 from project-init, one of them surviving only in a
  # dangling commit.
  #
  # So: seed from whatever the committed manifest already holds, then add
  # what history can still see. Entries are never removed by this script.
  # `current` is listed first so the freshest hash heads the list.
  prior="$(jq -r --arg p "$rel" '.files[$p].known[]? // empty' "$PRIOR_SRC" 2>/dev/null)"

  known="$(
    { printf '%s\n' "$current"
      printf '%s' "$prior" | grep -E '^sha256:[0-9a-f]{64}$' || true
      git -C "$REPO_ROOT" log --all --format=%H -- "$rel" 2>/dev/null | while IFS= read -r c; do
        blob="$(git -C "$REPO_ROOT" show "$c:$rel" 2>/dev/null | _sha256 2>/dev/null)"
        [[ -n "$blob" ]] && printf 'sha256:%s\n' "$blob"
      done
    } | grep -v '^$' | awk '!seen[$0]++' | jq -R . | jq -sc .
  )"
  [[ -z "$known" ]] && known="[\"$current\"]"

  FILES_JSON="$(jq -c --arg p "$rel" --arg cur "$current" --argjson k "$known" \
    '.[$p] = {current: $cur, known: $k, known_count: ($k | length)}' <<<"$FILES_JSON")"
done

if (( CHECK )); then
  [[ -f "$OUT" ]] || { echo "gen-portable-core-manifest: $OUT does not exist — run without --check" >&2; exit 1; }
  if jq -e --argjson fresh "$FILES_JSON" '.files == $fresh' "$OUT" >/dev/null 2>&1; then
    exit 0
  fi
  echo "gen-portable-core-manifest: config/portable-core-manifest.json is out of date." >&2
  jq -r --argjson fresh "$FILES_JSON" '
    (.files // {}) as $on
    | (($on | keys) + ($fresh | keys) | unique)[]
    | select(($on[.] // null) != ($fresh[.] // null))
    | "  differs: \(.)"' "$OUT" >&2 2>/dev/null
  echo "  regenerate with: bash scripts/gen-portable-core-manifest.sh" >&2
  exit 1
fi

# Same source the capability registry stamps from — there is no VERSION file.
STACK_VERSION=""
[[ -f "$REPO_ROOT/.claude/stack-config.json" ]] && \
  STACK_VERSION="$(jq -r '.stack_version // ""' "$REPO_ROOT/.claude/stack-config.json" 2>/dev/null)"
[[ "$STACK_VERSION" == "null" ]] && STACK_VERSION=""
SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
SOURCE_REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^git@([^:]+):#\1/#; s#^https?://##; s#\.git$##')"

tmp="$(mktemp "${TMPDIR:-/tmp}/pcm.XXXXXX")" || exit 2
jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$STACK_VERSION" \
      --arg sha "$SOURCE_SHA" --arg repo "$SOURCE_REPO" --argjson files "$FILES_JSON" \
  '{generated_at: $now, stack_version: $v, source_sha: $sha, source_repo: $repo, files: $files}' \
  > "$tmp" || { rm -f "$tmp"; exit 2; }
mkdir -p "$(dirname "$OUT")" 2>/dev/null
mv "$tmp" "$OUT" || { rm -f "$tmp"; exit 2; }

echo "Wrote $(jq -r '.files | length' "$OUT") managed files to $OUT"
exit 0
