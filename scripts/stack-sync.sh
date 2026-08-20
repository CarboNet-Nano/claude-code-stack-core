#!/usr/bin/env bash
# stack-sync — reconcile every repo's .claude/stack-config.json against the
# current stack contract. ADR-068.
#
# update.sh refreshes the machine-wide install at ~/.claude. Nothing refreshed
# the per-repo config, which /project-init writes once and never revisits — so
# every repo drifts. This is that missing tool.
#
# Usage:
#   ./scripts/stack-sync.sh [--root PATH]... [--repo PATH] [--apply] [--json]
#
#   (no flags)   dry-run over the default roots — writes nothing
#   --apply      the only way to write. There is no -y; --apply IS the consent.
#   --repo PATH  reconcile exactly one repo
#   --json       machine-readable summary on stdout
#
# Exit: 0 all good · 1 at least one repo failed · 2 usage/preflight error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/repo-walk.sh"
source "$REPO_ROOT/lib/stack-config-validate.sh"

TEMPLATE="$REPO_ROOT/templates/stack-config.template.json"
SCHEMA="$REPO_ROOT/schemas/stack-config-schema.json"
LEVELS="$REPO_ROOT/config/loop-levels.json"
DEFAULTS="$HOME/.claude/stack-defaults.json"

APPLY=0; JSON_OUT=0; SINGLE_REPO=""; declare -a ROOTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --json)  JSON_OUT=1; shift ;;
    --repo)  SINGLE_REPO="$2"; shift 2 ;;
    --root)  ROOTS+=("$2"); shift 2 ;;
    --root=*) ROOTS+=("${1#*=}"); shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "stack-sync: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for f in "$TEMPLATE" "$SCHEMA" "$LEVELS" "$REPO_ROOT/lib/stack-config-validate.sh"; do
  [[ -f "$f" ]] || { echo "stack-sync: missing required file: $f" >&2; exit 2; }
done
command -v jq >/dev/null || { echo "stack-sync: jq is required" >&2; exit 2; }

CURRENT_VERSION="$(jq -r '.stack_version // empty' "$DEFAULTS" 2>/dev/null)"
[[ -n "$CURRENT_VERSION" ]] || CURRENT_VERSION="$(jq -r '.stack_version' "$TEMPLATE")"

TARGET_TIER=4          # D11 floor
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fields never written — each encodes per-repo intent the template cannot know.
# stack_tier is deliberately absent: D11 lifts it to the tier-4 floor.
KEEP_LIST='["purpose","created","domain_mode","domain_mode_paths","sensitivity",
            "required_approvals","strict_mode","model_overrides","skill_overrides",
            "change_history","tenant_id","portable_sync"]'

# ---------------------------------------------------------------- provenance
# D3b: a field still equal to its ORIGINAL version's default is stale and may be
# reconciled; a field that diverges from it was edited on purpose and is kept.
# The repo has no version tags, so the historical template is recovered by
# searching history for the commit that carried that stack_version.
original_template() {
  local version="${1:-}"
  [[ -n "$version" ]] || return 1
  local cache="$WORK/tmpl-$version.json"
  [[ -f "$cache" ]] && { printf '%s\n' "$cache"; return 0; }
  [[ -f "$WORK/tmpl-$version.miss" ]] && return 1

  local sha
  sha="$(git -C "$REPO_ROOT" log --all --format=%H -S"\"stack_version\": \"$version\"" \
         -- templates/stack-config.template.json 2>/dev/null | head -1)"
  if [[ -n "$sha" ]] &&
     git -C "$REPO_ROOT" show "$sha:templates/stack-config.template.json" >"$cache" 2>/dev/null &&
     jq -e . "$cache" >/dev/null 2>&1; then
    printf '%s\n' "$cache"; return 0
  fi
  : >"$WORK/tmpl-$version.miss"
  return 1
}

canon() { jq -S 'walk(if type == "number" then . + 0 else . end)' "$@"; }

# --------------------------------------------------------------- reconcile
# Emits the reconciled config on stdout. Pure: reads, never writes.
reconcile() {
  local cur="$1" orig="$2"   # orig = original-version template, or /dev/null

  jq -n \
    --slurpfile cur "$cur" \
    --slurpfile tpl "$TEMPLATE" \
    --slurpfile lvl "$LEVELS" \
    --slurpfile orig "$orig" \
    --argjson keep "$KEEP_LIST" \
    --arg version "$CURRENT_VERSION" \
    --argjson target_tier "$TARGET_TIER" '
    ($cur[0]) as $c | ($tpl[0]) as $t | ($lvl[0]) as $L |
    (if ($orig | length) > 0 then $orig[0] else null end) as $o |

    # ---- D11 first: the tier lift precedes every tier-dependent rule (D11a).
    (if ($c.stack_tier // 0) < $target_tier then $target_tier else $c.stack_tier end) as $tier |

    # ---- D4: synthesize schema-required fields that are absent.
    ($c.stack_version // $version) as $ver |
    ($c.purpose // "TODO — describe this repo (auto-filled by stack-sync; needs a human)") as $purpose |
    ($c.created // ($t.created)) as $created |

    # ---- D3b: is a field deliberate, or merely stale?
    # Deliberate when it differs from what project-init would have written at
    # the version this repo stamps. With no original template available the
    # test cannot run, and the keep-list alone governs (reported as degraded).
    def deliberate($k):
      ($o != null) and ($c | has($k)) and (($c[$k]) != ($o[$k]));

    def reconciled($k):
      if ($keep | index($k)) then ($c[$k])
      elif deliberate($k) then ($c[$k])
      elif ($c | has($k)) then ($t[$k])
      else ($t[$k]) end;

    # ---- D3a: loop_policy + cost_protection, three ordered branches.
    ($c.loop_policy.level // null) as $level |
    (if $level == null then null else ($L.levels[$level] // null) end) as $preset |

    # branch 1 — tier <= 1 gets no loop_policy. Post-lift this is unreachable
    # for existing repos, but the rule stands for any repo pinned low later.
    ($tier <= 1) as $no_loop |

    (if $no_loop then null
     elif $preset != null then
       # branch 2 — MERGE the preset over the existing block. The preset carries
       # 5 of 12 schema fields; the rest must survive, including
       # irreversible_actions_break_loop (an invariant at every level).
       ($t.loop_policy) * ($c.loop_policy // {}) * ($preset.loop_policy) * {level: $level}
     elif ($c | has("loop_policy")) then
       # branch 3 — no declared level: add absent sub-keys, keep present values.
       ($t.loop_policy) * ($c.loop_policy)
     else ($t.loop_policy) end) as $loop |

    # ---- D10: cap ladder, floor-only, never lowers an existing cap.
    (if   $tier <= 1 then 20
     elif $tier <= 3 then 35
     else 50 end) as $ladder_cap |

    # A recorded cap-clear is honored — never silently re-capped.
    ([ ($c.change_history // [])[]
       | select((.setting // "") | test("hard_cap"))
       | select((.new_value // .value // "") | tostring | test("null|none")) ] | length > 0) as $cleared |

    (if $preset != null then ($t.cost_protection) * ($c.cost_protection // {}) * ($preset.cost_protection)
     elif ($c | has("cost_protection")) then ($t.cost_protection) * ($c.cost_protection)
     else ($t.cost_protection) end) as $cost_base |

    ($cost_base
     | if (.per_session_hard_cap_usd == null) and ($cleared | not)
       then .per_session_hard_cap_usd = $ladder_cap else . end) as $cost |

    # ---- assemble. Key order follows the template for readable diffs.
    ($t | keys_unsorted) as $order |
    ( reduce $order[] as $k ({};
        . + { ($k):
              (if   $k == "stack_tier"      then $tier
               elif $k == "stack_version"   then $version
               elif $k == "purpose"         then $purpose
               elif $k == "created"         then $created
               elif $k == "loop_policy"     then $loop
               elif $k == "cost_protection" then $cost
               # D5: the roster always becomes [] — the schema defines that as
               # "use tier defaults", so foreman resolves it at read time.
               # Deliberately EXEMPT from the D3b provenance test: this list was
               # machine-generated by project-init enumerating whatever was
               # installed that day, never hand-picked. Live counts run 0,6,9,11,
               # 12,13,16,17,19,20,21,23,24 — install history, not intent. Asking
               # "does it differ from its era default" reads every one of those
               # as deliberate and preserves exactly the staleness D5 exists to
               # remove.
               elif $k == "active_subagents" then []
               elif $k == "last_modified"   then (now | strftime("%Y-%m-%d"))
               else reconciled($k) end) })
    ) as $base |

    # Preserve any repo-specific key the template does not define (tenant_id).
    ($c | with_entries(select(.key as $k | ($base | has($k)) | not))) as $extra |
    ($base + $extra)
    | if $no_loop then del(.loop_policy) else . end
    '
}

# ------------------------------------------------------------------- report
declare -a CHANGED=() UNCHANGED=() FAILED=() DEGRADED=()

process_repo() {
  local repo="$1" name cfg cur_c new_c new tier_before tier_after
  name="$(basename "$repo")"
  cfg="$repo/.claude/stack-config.json"

  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    FAILED+=("$name: invalid JSON"); return
  fi
  if [[ "$(jq -r '.stack_tier // "null"' "$cfg")" == "null" ]]; then
    FAILED+=("$name: no stack_tier — refusing to guess"); return
  fi

  local stamped orig="/dev/null"
  stamped="$(jq -r '.stack_version // empty' "$cfg")"
  if [[ -n "$stamped" ]]; then
    orig="$(original_template "$stamped" || true)"
    [[ -n "$orig" ]] || { orig="/dev/null"; DEGRADED+=("$name (v$stamped template unavailable — keep-list only)"); }
  else
    DEGRADED+=("$name (no stack_version — keep-list only)")
  fi

  new="$WORK/$name.new.json"
  if ! reconcile "$cfg" "$orig" >"$new" 2>"$WORK/$name.err"; then
    FAILED+=("$name: reconcile failed — $(head -1 "$WORK/$name.err")"); return
  fi
  if ! jq -e . "$new" >/dev/null 2>&1; then
    FAILED+=("$name: produced invalid JSON"); return
  fi
  # D7 validation, via the shared validator (A-D8: stack-sync.sh and
  # org-check.sh/`/carbonet` must never disagree about what a valid config
  # is). A config that fails is discarded, never written.
  local verr
  verr="$(scv_validate "$new" "$SCHEMA")"
  if [[ -n "$verr" ]]; then
    FAILED+=("$name: $verr"); return
  fi

  # D6a — compare canonically, ignoring last_modified (always moves).
  cur_c="$(canon "$cfg" | jq 'del(.last_modified)')"
  new_c="$(canon "$new" | jq 'del(.last_modified)')"
  if [[ "$cur_c" == "$new_c" ]]; then
    UNCHANGED+=("$name"); return
  fi

  tier_before="$(jq -r '.stack_tier' "$cfg")"; tier_after="$(jq -r '.stack_tier' "$new")"
  local summary; summary="$name"
  [[ "$tier_before" != "$tier_after" ]] && summary="$summary  tier ${tier_before}→${tier_after}"
  local cap_b cap_a
  cap_b="$(jq -r '.cost_protection.per_session_hard_cap_usd // "none"' "$cfg")"
  cap_a="$(jq -r '.cost_protection.per_session_hard_cap_usd // "none"' "$new")"
  [[ "$cap_b" != "$cap_a" ]] && summary="$summary  cap ${cap_b}→\$${cap_a}"
  local ag_b ag_a
  ag_b="$(jq -r '.active_subagents | if type=="array" then length else "absent" end' "$cfg")"
  ag_a="$(jq -r '.active_subagents | length' "$new")"
  [[ "$ag_b" != "$ag_a" ]] && summary="$summary  agents ${ag_b}→${ag_a}"
  local added
  added="$(jq -n --slurpfile a "$cfg" --slurpfile b "$new" \
      '[($b[0]|keys[])] - [($a[0]|keys[])] | join(",")')"
  added="${added//\"/}"
  [[ -n "$added" ]] && summary="$summary  +[$added]"
  CHANGED+=("$summary")

  if (( APPLY )); then
    local backup="$cfg.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$cfg" "$backup" || { FAILED+=("$name: backup failed"); return; }
    local tmp="$repo/.claude/.stack-config.tmp.$$"
    if jq . "$new" >"$tmp" 2>/dev/null && mv "$tmp" "$cfg"; then
      :
    else
      rm -f "$tmp"; FAILED+=("$name: write failed"); return
    fi
  fi
}

# --------------------------------------------------------------------- main
declare -a REPOS=()
if [[ -n "$SINGLE_REPO" ]]; then
  REPOS=("$SINGLE_REPO")
else
  while IFS= read -r r; do [[ -n "$r" ]] && REPOS+=("$r"); done < <(
    if (( ${#ROOTS[@]} )); then
      args=(); for r in "${ROOTS[@]}"; do args+=(--root "$r"); done
      walk_repos --max-depth 1 "${args[@]}"
    else
      walk_repos --max-depth 1 --root "$HOME/Antigravity" --root "$HOME/Claude"
    fi
  )
fi

(( ${#REPOS[@]} )) || { echo "stack-sync: no stack-initialized repos found" >&2; exit 2; }

for repo in "${REPOS[@]}"; do process_repo "$repo"; done

if (( JSON_OUT )); then
  jq -n --argjson c "$(printf '%s\n' "${CHANGED[@]:-}"   | jq -R . | jq -s 'map(select(. != ""))')" \
        --argjson u "$(printf '%s\n' "${UNCHANGED[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
        --argjson f "$(printf '%s\n' "${FAILED[@]:-}"    | jq -R . | jq -s 'map(select(. != ""))')" \
        --argjson d "$(printf '%s\n' "${DEGRADED[@]:-}"  | jq -R . | jq -s 'map(select(. != ""))')" \
        --argjson applied "$APPLY" \
        '{applied: ($applied == 1), changed: $c, unchanged: $u, failed: $f, degraded: $d}'
else
  echo "=============================================================="
  echo " stack-sync — $( ((APPLY)) && echo 'APPLYING' || echo 'DRY RUN (nothing written)')"
  echo " ${#REPOS[@]} repos · stack v$CURRENT_VERSION · tier floor $TARGET_TIER"
  echo "=============================================================="
  if (( ${#CHANGED[@]} )); then
    echo; echo "CHANGED (${#CHANGED[@]}):"
    printf '  %s\n' "${CHANGED[@]}"
  fi
  if (( ${#UNCHANGED[@]} )); then
    echo; echo "UNCHANGED (${#UNCHANGED[@]}): ${UNCHANGED[*]}"
  fi
  if (( ${#DEGRADED[@]} )); then
    echo; echo "DEGRADED — provenance test unavailable, keep-list only (${#DEGRADED[@]}):"
    printf '  %s\n' "${DEGRADED[@]}"
  fi
  if (( ${#FAILED[@]} )); then
    echo; echo "FAILED (${#FAILED[@]}):"
    printf '  %s\n' "${FAILED[@]}"
  fi
  echo
  (( APPLY )) || echo "Dry run. Re-run with --apply to write."
fi

(( ${#FAILED[@]} )) && exit 1
exit 0
