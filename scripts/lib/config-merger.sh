#!/usr/bin/env bash
# JSON config merger. Preserves user customizations while adding stack content.

merge_json() {
  local source="$1"
  local target="$2"

  # Deep merge: objects deep-merged, arrays concatenated (deduped). On a
  # scalar conflict the user's (target) value is kept; the stack's (source)
  # value is applied only with the user's approval. With a terminal present
  # each conflict is prompted; otherwise (or with STACK_MERGE_NONINTERACTIVE
  # set) the user value is kept and a <target>.merge-conflicts report written.

  # Scalar conflicts: leaf paths that are differing, non-null scalars in both.
  # Only object-key paths count — paths through an array index are skipped,
  # since arrays are concatenated (no positional merge, so no conflict).
  local conflicts n
  conflicts="$(jq -n --slurpfile t "$target" --slurpfile s "$source" '
    ($t[0]) as $tgt | ($s[0]) as $src |
    [ ($src | paths(scalars)) as $p
      | select($p | all(type == "string"))
      | ($tgt | getpath($p)) as $mine
      | ($src | getpath($p)) as $theirs
      | select($mine != null and $theirs != null and $mine != $theirs)
      | {path: $p, mine: $mine, stack: $theirs} ]
  ')"
  n="$(jq 'length' <<<"$conflicts")"

  # Base merge — user wins on scalar conflict.
  # NOTE: jq function arguments are call-by-name filters, not values. The
  # args MUST be bound to $-variables up front — otherwise the recursive
  # `deep_merge(a[$k]; b[$k])` re-evaluates `a`/`b` against the reduce
  # accumulator instead of the original inputs, which fails on nested data.
  local tmp
  tmp="$(mktemp)"
  # After the generic merge, collapse Claude hook blocks that share a matcher.
  # The generic array rule (`($a+$b)|unique`) dedups only byte-identical
  # objects, so a base `{matcher:"Bash",hooks:[X]}` and a tier fragment
  # `{matcher:"Bash",hooks:[X,Y]}` survive as two blocks — duplicating the
  # matcher and re-running X. merge_hook_groups regroups each event array by
  # .matcher and order-stable-dedups the concatenated hooks into one block.
  jq -s '
    def dedup_stable: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def merge_hook_groups:
      group_by(.matcher)
      | map(
          (.[0].matcher) as $m
          | (map(.hooks // []) | add | dedup_stable) as $h
          | if $m == null then {hooks: $h} else {matcher: $m, hooks: $h} end
        );
    def deep_merge(a; b):
      a as $a | b as $b |
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce (($a + $b) | keys[]) as $k ({}; .[$k] = deep_merge($a[$k]; $b[$k]))
      elif ($a | type) == "array" and ($b | type) == "array" then
        ($a + $b) | unique
      elif $a == null then $b
      else $a end;
    deep_merge(.[0]; .[1])
    | if (.hooks | type) == "object" then
        .hooks |= with_entries(
          if (.value | type) == "array" then .value |= merge_hook_groups else . end)
      else . end
  ' "$target" "$source" > "$tmp"

  # Resolve conflicts — stack value applied only on approval.
  if [[ "$n" -gt 0 ]]; then
    local interactive=0
    if [[ -z "${STACK_MERGE_NONINTERACTIVE:-}" ]] && { : >/dev/tty; } 2>/dev/null; then
      interactive=1
    fi

    if [[ "$interactive" == 1 ]]; then
      echo "  $n config conflict(s) merging into $(basename "$target"):" >&2
      local i key mine stack path_json ans
      for (( i = 0; i < n; i++ )); do
        key="$(jq -r ".[$i].path | join(\".\")" <<<"$conflicts")"
        mine="$(jq -c ".[$i].mine" <<<"$conflicts")"
        stack="$(jq -c ".[$i].stack" <<<"$conflicts")"
        path_json="$(jq -c ".[$i].path" <<<"$conflicts")"
        printf '    %s — yours: %s | stack: %s\n    Use the stack value? [y/N] ' \
          "$key" "$mine" "$stack" >/dev/tty
        read -r ans </dev/tty || ans=""
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
          jq --argjson p "$path_json" --argjson v "$stack" 'setpath($p; $v)' \
            "$tmp" >"$tmp.next" && mv "$tmp.next" "$tmp"
        fi
      done
    else
      local report="${target}.merge-conflicts"
      jq '.' <<<"$conflicts" >"$report"
      echo "  WARN: $n config conflict(s) merging into $(basename "$target")." >&2
      echo "  Kept your values. Review $report, or re-run install in a terminal." >&2
    fi
  fi

  mv "$tmp" "$target"
}

# pack_config_overrides_preview <source> <target> -> JSON array of
# {path, previous, pack} for every scalar merge_json_pack_wins would
# overwrite, WITHOUT writing anything. Extracted so a pre-write review gate
# (ADR-055, install_pack) can show the exact same diff merge_json_pack_wins
# is about to apply, rather than a hand-duplicated approximation of it.
pack_config_overrides_preview() {
  local source="$1" target="$2"
  jq -n --slurpfile t "$target" --slurpfile s "$source" '
    ($t[0]) as $tgt | ($s[0]) as $src |
    # paths(scalars) would skip explicit-null leaves (null is falsy in jq
    # conditionals), and a pack null is a deletion we must log.
    [ ($src | paths(type != "object" and type != "array")) as $p
      | select($p | all(type == "string"))
      | ($tgt | try getpath($p) catch null) as $previous
      | ($src | getpath($p)) as $pack
      | select($previous != null and $previous != $pack)
      | {path: $p, previous: $previous, pack: $pack} ]
  '
}

merge_json_pack_wins() {
  local source="$1"   # pack file
  local target="$2"   # installed ~/.claude file

  # Sibling of merge_json with the OPPOSITE conflict winner: merge_json keeps
  # the target (user) value on a scalar conflict; this keeps the source (pack)
  # value (ADR-013 amendment #1, ADR-034 §2 — pack-wins compose). Do NOT call
  # merge_json with swapped args instead: that would also invert the hook-group
  # regroup targeting and the conflict-report semantics. Always non-interactive;
  # every overwritten scalar path is logged to <target>.pack-overrides
  # (path, previous, pack) — the audit trail replacing merge_json's prompt.
  # An EXPLICIT pack null also wins (has()-based merge), so a pack can delete
  # a value; an absent key means "no opinion" and the target survives.
  # Callers often run this with errexit suppressed (inside `if !` chains), so
  # every fallible step is checked explicitly — a failed jq must never leave
  # an empty file mv'd over the target.

  local overrides n
  overrides="$(pack_config_overrides_preview "$source" "$target")" || return 1
  n="$(jq 'length' <<<"$overrides")" || return 1

  # Same call-by-name caveat as merge_json: bind args to $-variables up front.
  local tmp
  tmp="$(mktemp)" || return 1
  if ! jq -s '
    def dedup_stable: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def merge_hook_groups:
      group_by(.matcher)
      | map(
          (.[0].matcher) as $m
          | (map(.hooks // []) | add | dedup_stable) as $h
          | if $m == null then {hooks: $h} else {matcher: $m, hooks: $h} end
        );
    def deep_merge(a; b):
      a as $a | b as $b |
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce (($a + $b) | keys[]) as $k ({};
          .[$k] = (if ($a | has($k)) and ($b | has($k)) then deep_merge($a[$k]; $b[$k])
                   elif ($b | has($k)) then $b[$k]
                   else $a[$k] end))
      elif ($a | type) == "array" and ($b | type) == "array" then
        ($a + $b) | dedup_stable
      else $b end;
    deep_merge(.[0]; .[1])
    | if (.hooks | type) == "object" then
        .hooks |= with_entries(
          if (.value | type) == "array" then .value |= merge_hook_groups else . end)
      else . end
  ' "$target" "$source" > "$tmp"; then
    rm -f "$tmp"
    echo "  [pack-fail] merge_json_pack_wins: jq merge failed for $target" >&2
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "  [pack-fail] merge_json_pack_wins: merge produced invalid JSON for $target" >&2
    return 1
  fi

  # The report reflects the CURRENT run — a converged re-run removes it.
  if [[ "$n" -gt 0 ]]; then
    jq '.' <<<"$overrides" > "${target}.pack-overrides" || { rm -f "$tmp"; return 1; }
    echo "  [pack-override] $n value(s) overwritten in $(basename "$target") — see ${target}.pack-overrides" >&2
  else
    rm -f "${target}.pack-overrides"
  fi

  mv "$tmp" "$target" || return 1
}

append_stack_section() {
  local source="$1"
  local target="$2"

  # Look for stack-managed section marker in target. Both markers are
  # declared up front so the append (else) branch can reference end_marker
  # too — bash has no block scope, so an in-branch `local` would leave it
  # unset on the other path (fatal under `set -u`).
  local marker="<!-- CLAUDE_CODE_STACK_MANAGED -->"
  local end_marker="<!-- /CLAUDE_CODE_STACK_MANAGED -->"

  if grep -q "$marker" "$target" 2>/dev/null; then
    # Section exists; replace between marker and end-marker
    awk -v source="$source" -v marker="$marker" -v end_marker="$end_marker" '
      BEGIN { in_section = 0 }
      $0 ~ marker { in_section = 1; print; while ((getline line < source) > 0) print line; next }
      $0 ~ end_marker { in_section = 0; print; next }
      !in_section { print }
    ' "$target" > "$target.new"
    mv "$target.new" "$target"
  else
    # Section doesn't exist; append
    {
      echo ""
      echo "$marker"
      cat "$source"
      echo "$end_marker"
    } >> "$target"
  fi
}
