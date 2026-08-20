#!/usr/bin/env bash
# scripts/stack-help.sh — deterministic, registry-driven command index.
#
# ADR-065 D1 (docs/plans/2026-08-10-onboarding-and-environment-repair.md
# §Scope 1), amended by
# docs/superpowers/specs/2026-08-16-handbook-portable-design.md D65-A..F.
#
# Usage: scripts/stack-help.sh [--registry PATH] [--groups PATH] [--tier N]
#                               [--no-verify-installed] [--json] [--help]
#
# Exit 0 on success. Exit 1 on a malformed/unreadable registry or a
# help-groups.json naming an id that is not a kind:"skill" entry in the
# registry. Exit 2 on a bad flag.
#
# Renders config/capability-registry.json capabilities[] rows where
# kind=="skill" && user_invocable, grouped per config/help-groups.json,
# filtered by effective tier = min(repo tier, installed tier). Aliases come
# from the registry's TOP-LEVEL "aliases" object ({"hi":"goodmorning",...})
# per D65-D — NOT from alias_of fields on capabilities[] entries — and render
# as a suffix on the target row. A missing .aliases key is treated as {}.
#
# ADR-083 D19: at render time, ~/.claude/config/aliases.org.json (when
# present and parseable) is merged over the registry's stack-only aliases,
# org wins on a shared word, `disable` removes it. Missing or malformed org
# file -> {}, same fail-open as the missing-.aliases case (this is a render
# step, not the fail-closed generator — see gen-alias-stubs.sh for that).
# No source marker is rendered (D19 — provenance is /alias explain's job).
# The "Missing on disk" footer also names declared-but-not-yet-materialized
# words (D16's one-session generation lag).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Registry and groups must come from the SAME root or the help screen mixes
# two vintages of the skill list. Installed root wins only when it has both;
# otherwise fall back to the repo the script itself lives in, so a dev
# checkout works before update.sh has shipped these files to ~/.claude.
if [[ -f "$CONFIG_DIR/config/capability-registry.json" && -f "$CONFIG_DIR/config/help-groups.json" ]]; then
  DATA_ROOT="$CONFIG_DIR"
else
  DATA_ROOT="$REPO_ROOT"
fi
REGISTRY="$DATA_ROOT/config/capability-registry.json"
GROUPS_FILE="$DATA_ROOT/config/help-groups.json"
TIER_OVERRIDE=""
NO_VERIFY=false
JSON_OUT=false

usage() {
  cat <<'EOF'
scripts/stack-help.sh [--registry PATH] [--groups PATH] [--tier N]
                      [--no-verify-installed] [--json] [--help]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      [[ $# -ge 2 ]] || { echo "stack-help: --registry needs a value" >&2; exit 2; }
      REGISTRY="$2"; shift 2 ;;
    --groups)
      [[ $# -ge 2 ]] || { echo "stack-help: --groups needs a value" >&2; exit 2; }
      GROUPS_FILE="$2"; shift 2 ;;
    --tier)
      [[ $# -ge 2 ]] || { echo "stack-help: --tier needs a value" >&2; exit 2; }
      TIER_OVERRIDE="$2"
      if ! [[ "$TIER_OVERRIDE" =~ ^[0-5]$ ]]; then
        echo "stack-help: --tier must be 0..5" >&2
        exit 2
      fi
      shift 2 ;;
    --no-verify-installed) NO_VERIFY=true; shift ;;
    --json) JSON_OUT=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "stack-help: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- registry / groups validity --------------------------------------------

if ! jq -e '.capabilities | type == "array"' "$REGISTRY" >/dev/null 2>&1; then
  echo "stack-help: malformed or unreadable registry: $REGISTRY" >&2
  exit 1
fi

if ! jq -e '.groups | type == "array"' "$GROUPS_FILE" >/dev/null 2>&1; then
  echo "stack-help: malformed or unreadable help-groups: $GROUPS_FILE" >&2
  exit 1
fi

unknown_id="$(jq -r --slurpfile reg "$REGISTRY" '
  ($reg[0].capabilities // []) as $caps
  | ([.groups[]?.members[]?] | unique) as $members
  | ($caps | map(select(.kind == "skill")) | map(.id)) as $skill_ids
  | (($members - $skill_ids) | sort) as $unknown
  | if ($unknown | length) > 0 then $unknown[0] else empty end
' "$GROUPS_FILE")"
if [[ -n "$unknown_id" ]]; then
  echo "stack-help: help-groups.json names an id that is not a skill in the registry: $unknown_id" >&2
  exit 1
fi

# --- effective tier ----------------------------------------------------------
# ADR-065 D4: effective_tier = min(repo_tier, installed_tier).

find_stack_config="$CONFIG_DIR/lib/find-stack-config.sh"
[[ -x "$find_stack_config" ]] || find_stack_config="$SCRIPT_DIR/../lib/find-stack-config.sh"

repo_tier=""
if [[ -x "$find_stack_config" ]]; then
  repo_config="$(bash "$find_stack_config" "$PWD" 2>/dev/null || true)"
  if [[ -n "$repo_config" && -f "$repo_config" ]]; then
    repo_tier="$(jq -r '.stack_tier // empty' "$repo_config" 2>/dev/null)"
  fi
fi
if ! [[ "${repo_tier:-}" =~ ^[0-9]+$ ]]; then
  if [[ -f "$CONFIG_DIR/stack-defaults.json" ]]; then
    repo_tier="$(jq -r '.default_tier // empty' "$CONFIG_DIR/stack-defaults.json" 2>/dev/null)"
  fi
fi
if ! [[ "${repo_tier:-}" =~ ^[0-9]+$ ]]; then
  repo_tier=0
fi

installed_tier=""
if [[ -f "$CONFIG_DIR/.stack-install.json" ]]; then
  installed_tier="$(jq -r '.tier // empty' "$CONFIG_DIR/.stack-install.json" 2>/dev/null)"
fi
if ! [[ "${installed_tier:-}" =~ ^[0-9]+$ ]]; then
  installed_tier=5
fi

if [[ -n "$TIER_OVERRIDE" ]]; then
  effective_tier="$TIER_OVERRIDE"
else
  effective_tier=$(( repo_tier < installed_tier ? repo_tier : installed_tier ))
fi

# --- org alias merge (D19) ----------------------------------------------------
# Read-only render-time merge: org wins on a shared word, `disable` removes
# it. Missing/malformed org file -> {} (fail-open).

ORG_ALIASES_FILE="$CONFIG_DIR/config/aliases.org.json"
org_words_json='{}'
if [[ -f "$ORG_ALIASES_FILE" ]] && jq -e '.aliases | type == "object"' "$ORG_ALIASES_FILE" >/dev/null 2>&1; then
  org_words_json="$(jq -c '.aliases' "$ORG_ALIASES_FILE" 2>/dev/null)" || org_words_json='{}'
fi

merged_aliases_json="$(jq -c --argjson org "$org_words_json" '
  (.aliases // {}) as $stack
  | ($org | to_entries | map(select(.value.disable != true)) | map({(.key): .value.target}) | add // {}) as $org_targets
  | ($org | to_entries | map(select(.value.disable == true)) | map(.key)) as $org_disabled
  | ($stack | to_entries | map(select(([.key] - $org_disabled) | length > 0)) | map({(.key): .value}) | add // {}) as $stack_live
  | ($stack_live + $org_targets)
' "$REGISTRY")"

# --- candidate rows -----------------------------------------------------------
# Predicate: kind=="skill" && user_invocable==true && tier_min <= effective_tier.

intermediate="$(jq -c --argjson tier "$effective_tier" --argjson aliasmap "$merged_aliases_json" '
  def fmt_summary:
    . as $s
    | (if ($s | length) > 0 then ($s[0:1] | ascii_downcase) + $s[1:] else $s end) as $lc
    | (if ($lc | endswith(".")) then $lc[0:-1] else $lc end) as $np
    | if ($np | length) <= 60 then $np
      else
        ($np[0:60]) as $cut
        | ($cut | rindex(" ")) as $idx
        | (if $idx == null then $cut else $cut[0:$idx] end)
      end;
  (.capabilities // []) as $caps
  | ($caps | map(select(.kind == "subagent")) | length) as $subagent_count
  | ($aliasmap | to_entries | sort_by(.key)
     | reduce .[] as $e ({}; .[$e.value] += [("/" + $e.key)])) as $alias_by_target
  | ($caps
     | map(select(.kind == "skill" and (.user_invocable == true) and ((.tier_min // 0) <= $tier)))
     | map({id, slash: (.invocation.slash // ("/" + .id)), summary: ((.summary // "") | fmt_summary)})
    ) as $rows
  | {rows: $rows, alias_by_target: $alias_by_target, subagent_count: $subagent_count}
' "$REGISTRY")"

# --- group into named groups + fallback "more" --------------------------------

groups_and_more="$(jq -c --argjson inter "$intermediate" '
  (.groups // []) as $groups
  | (.fallback_group // {"id": "more", "title": "More"}) as $fb
  | ($inter.rows) as $rows
  | ($groups | map({id, title, members: (.members // [])})) as $gdefs
  | ($gdefs | map(.members[]) | unique) as $claimed
  | ($rows | map(select(.id as $i | ($claimed | index($i)) == null)) | sort_by(.id)) as $more_rows
  | ($gdefs | map(
       . as $g
       | { id: $g.id, title: $g.title,
           items: ($g.members | map(. as $mid | ($rows[] | select(.id == $mid))))
         }
     )) as $named
  | ($named + [{id: $fb.id, title: $fb.title, items: $more_rows}])
' "$GROUPS_FILE")"

# --- installed-file cross-check (D4's missing-on-disk footer leg) -------------

all_ids="$(jq -r '[.[].items[].id] | unique | .[]' <<< "$groups_and_more")"

missing_ids=()
if [[ "$NO_VERIFY" != true ]]; then
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if [[ ! -f "$CONFIG_DIR/skills/$id/SKILL.md" ]]; then
      missing_ids+=("$id")
    fi
  done <<< "$all_ids"

  # ADR-083 D19/D16: a word can be resolved (declared, live, non-disabled)
  # for up to one session before scripts/gen-alias-stubs.sh materializes its
  # stub. Name it in the same footer, same signal as a missing skill file.
  while IFS= read -r word; do
    [[ -z "$word" ]] && continue
    if [[ ! -f "$CONFIG_DIR/skills/$word/SKILL.md" ]]; then
      missing_ids+=("$word")
    fi
  done < <(jq -r 'keys[]' <<< "$merged_aliases_json")
fi

missing_json="$(printf '%s\n' "${missing_ids[@]-}" | jq -R -s 'split("\n") | map(select(length > 0))')"

# --- final structure (drives both --json and text rendering) ------------------

final="$(jq -c --argjson missing "$missing_json" --argjson inter "$intermediate" \
  --argjson tier "$effective_tier" --argjson repo_tier "$repo_tier" --argjson installed_tier "$installed_tier" '
  ($inter.alias_by_target) as $abt
  | ($inter.subagent_count) as $subc
  | (. as $groups
     | map({
         id, title,
         items: (.items
                 | map(select(.id as $i | ($missing | index($i)) == null))
                 | map(. + {aliases: ($abt[.id] // [])})
                )
       })
     | map(select((.items | length) > 0))
    ) as $rendered_groups
  | ($rendered_groups | map(.items | length) | add // 0) as $total
  | ($missing | sort | map("/" + .)) as $missing_slashes
  | {
      effective_tier: $tier, repo_tier: $repo_tier, installed_tier: $installed_tier,
      total: $total, groups: $rendered_groups, missing: $missing_slashes,
      subagent_count: $subc
    }
' <<< "$groups_and_more")"

if [[ "$JSON_OUT" == true ]]; then
  echo "$final"
  exit 0
fi

# --- text rendering -----------------------------------------------------------

M="$(jq -r '.total' <<< "$final")"
echo "Claude Code Stack — Tier ${effective_tier} · ${M} commands available"
echo

while IFS= read -r grp; do
  title="$(jq -r '.title' <<< "$grp")"
  echo "$title"
  jq -c '.items[]' <<< "$grp" | while IFS= read -r item; do
    slash="$(jq -r '.slash' <<< "$item")"
    summary="$(jq -r '.summary' <<< "$item")"
    aliases="$(jq -r '.aliases | join(", ")' <<< "$item")"
    label="$slash"
    [[ -n "$aliases" ]] && label="$slash (or $aliases)"
    printf '  %-29s  %s\n' "$label" "$summary"
  done
  echo
done < <(jq -c '.groups[]' <<< "$final")

missing_line="$(jq -r '.missing | join(", ")' <<< "$final")"
if [[ -n "$missing_line" ]]; then
  echo "Missing on disk (run update.sh): $missing_line"
fi

# D65-C: this footer line consumes ADR-065 D6's reserved footer line. A
# future /stack-tour skill appends a second line here — do not replace this
# one when that lands.
echo "Full handbook: /handbook · how the machinery behaves: /operating"

exit 0
