#!/usr/bin/env bash
# Handbook coverage gate: every system in tools/ and scripts/ must be
# mentioned somewhere in docs/handbook/, or carry a reasoned exemption in
# config/handbook-coverage-exemptions.txt. Born from the day the machinery
# chapter shipped without the PM journal or the agent audit — hand-written
# chapters drift; this makes the drift red instead of silent.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB="$REPO_ROOT/docs/handbook"
EXEMPT="$REPO_ROOT/config/handbook-coverage-exemptions.txt"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[[ -d "$HB" ]] || { echo "test-handbook-coverage: $HB missing" >&2; exit 1; }

exemption_reason() {  # exemption_reason <path> -> reason or empty
  [[ -f "$EXEMPT" ]] || return 0
  awk -v p="$1" '$1==p { $1=""; sub(/^ +/,""); print; exit }' "$EXEMPT"
}

mentioned() {  # mentioned <needle> -> 0 if any handbook .md mentions it
  # -w: whole word — a raw substring grep let short names ride along
  # inside unrelated words (#256).
  grep -rilwq -- "$1" "$HB" --include='*.md' 2>/dev/null
}

check_unit() {  # check_unit <repo-relative-path> <needle>
  local path="$1" needle="$2" reason
  if mentioned "$needle"; then
    pass "$path is mentioned in the handbook"
    return
  fi
  reason="$(exemption_reason "$path")"
  if [[ -n "$reason" ]]; then
    pass "$path exempt: $reason"
  else
    fail "$path is in the repo but the handbook never mentions it, and it carries no exemption"
  fi
}

# machinery_page <tools-path> <name> -> 0 iff the system's machinery page
# exists: exactly machinery/<name>.md, or the page bound to it in the
# explicit map. Substring matching is banned (#256): "pm" matching
# pm-journal.md by luck is the same silent-pass failure as the mention
# bar, and a mapping whose target file is missing FAILS rather than
# passing through.
MAP="$REPO_ROOT/config/handbook-coverage-map.txt"
mapped_page() {  # mapped_page <tools-path> -> mapped filename or empty
  [[ -f "$MAP" ]] || return 0
  awk -v p="$1" '$1==p { print $2; exit }' "$MAP"
}
machinery_page() {
  local path="$1" name="$2" mapped
  [[ -f "$HB/machinery/$name.md" ]] && return 0
  mapped="$(mapped_page "$path")"
  [[ -z "$mapped" ]] && return 1
  if [[ ! -f "$HB/machinery/$mapped" ]]; then
    fail "$path is mapped to machinery/$mapped in $(basename "$MAP"), but that page does not exist"
    return 1
  fi
  return 0
}

check_system() {  # check_system <repo-relative-path> <name>
  # Systems need a dedicated machinery page, not a mention. A passing
  # reference in the glossary satisfied the old mention-bar for graphify
  # while the machinery chapter had no page at all — the exact
  # look-green-without-checking failure this gate exists to prevent.
  local path="$1" name="$2" reason
  if machinery_page "$path" "$name"; then
    pass "$path has a machinery page"
    return
  fi
  reason="$(exemption_reason "$path")"
  if [[ -n "$reason" ]]; then
    pass "$path exempt: $reason"
  else
    fail "$path has no machinery page in docs/handbook/machinery/ and no exemption — a mention elsewhere is not coverage"
  fi
}

for d in "$REPO_ROOT"/tools/*/; do
  name="$(basename "$d")"
  check_system "tools/$name" "$name"
done

for s in "$REPO_ROOT"/scripts/*.sh; do
  base="$(basename "$s" .sh)"
  check_unit "scripts/$(basename "$s")" "$base"
done

# The registry is the inventory: every installed skill and subagent the
# stack ships must appear in the generated handbook. Guards against the
# generator silently skipping a capability — the folder scans above can
# only see this repo's directories, never the roster itself.
REG="$REPO_ROOT/config/capability-registry.json"
if [[ -f "$REG" ]] && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r id kind; do
    case "$kind" in
      subagent)
        [[ -f "$HB/agents/$id.md" ]] \
          && pass "registry subagent '$id' has an agent page" \
          || fail "registry subagent '$id' has no page at docs/handbook/agents/$id.md" ;;
      skill)
        grep -q "### $id " "$HB/skills-glossary.md" 2>/dev/null || grep -q "### $id\$" "$HB/skills-glossary.md" 2>/dev/null \
          && pass "registry skill '$id' is in the skills glossary" \
          || fail "registry skill '$id' is missing from docs/handbook/skills-glossary.md" ;;
    esac
  done < <(jq -r '.capabilities[] | select(.kind=="subagent" or .kind=="skill") | [.id, .kind] | @tsv' "$REG")
else
  fail "capability registry or jq unavailable — the inventory cross-check did not run (a skipped check is not a passing check)"
fi

# Exemptions must not rot: every exempted path must still exist, and every
# line must carry a reason.
if [[ -f "$EXEMPT" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    p="${line%%  *}"
    r="${line#*  }"
    if [[ "$p" == "$r" || -z "${r// /}" ]]; then
      fail "exemption '$p' has no reason — silent opt-outs are not allowed"
      continue
    fi
    [[ -e "$REPO_ROOT/$p" ]] \
      && pass "exemption '$p' still points at a real file" \
      || fail "exemption '$p' names a file that no longer exists — delete the stale line"
  done < "$EXEMPT"
fi

echo "test-handbook-coverage: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
