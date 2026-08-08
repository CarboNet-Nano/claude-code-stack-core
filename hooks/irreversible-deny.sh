#!/usr/bin/env bash
# PreToolUse[Bash] hook: during an ACTIVE loop, deny irreversible commands so
# an unattended loop cannot push/merge/deploy/delete/move money. Outside a
# loop, stays silent. Red-team owns the pattern list. Best-effort: exit 0.
# summary: Denies irreversible bash commands (push, merge, deploy, rm -rf) during an active loop.
#
# ---------------------------------------------------------------------------
# Known limitations (Phase 1) — best-effort defense-in-depth, NOT a security
# boundary. Pattern-matching cannot catch all evasions:
#
#   - sudo -u USER git push (user-switch before command)
#   - env -i git push (env with cleared environment)
#   - Deeply nested shells: bash -c 'bash -c "git push"' (3+ levels)
#   - Heredoc injection: bash -c "$(cat <<'EOF' ... EOF)"
#   - $() or eval inside the command string
#   - base64/encoded commands: bash -c "$(echo Z2l0IHB1c2g= | base64 -d)"
#   - Custom git wrappers or aliases (e.g. mygit push, gp)
#   - Obfuscated env vars: x=push; git $x
#
# The real security boundary is: the autonomy ceiling (tier-scaled) + the
# human checkpoint requirement (bounded-autonomous loops need external
# termination) + Claude Code's own permission system. This hook is
# defense-in-depth to make accidental irreversible actions unlikely during
# normal loop operation, not to prevent a determined adversary.
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
# Guard against unset HOME before using it as a fallback path.
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# Per-session state (ADR-020): the session id in the payload is authoritative
# for this event; export it so loop_read_state resolves THIS session's file
# instead of falling through to the wrong/legacy one (previously always
# read as inactive, so this deny gate never fired during a real loop).
_SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$_SID" ]] && export CLAUDE_CODE_SESSION_ID="$_SID"

[[ "$(loop_read_state | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
[[ -z "$CMD" ]] && exit 0

# --- normalize the command for token-aware matching ---
#
# Problems with raw substring grep:
#   - git -C repo push, command git push, /usr/bin/git push evade git patterns
#   - git p'ush', git pu\sh (shell quoting) evade subcommand detection
#   - rm -fr, rm -r -f evade rm -rf
#   - git merge-base falsely matches git merge (no right boundary)
#
# Strategy:
#   1. Strip shell quoting noise (backslashes outside strings, paired quotes)
#      so p'ush' -> push and pu\sh -> push.
#   2. Strip leading path from first token (/usr/bin/git -> git).
#   3. Strip "command " / "exec " prefixes so command git push -> git push.
#   4. For git: skip global options (-C <path>, --git-dir=..., etc.) to
#      reach the actual subcommand, then match it with a word boundary.
#   5. For rm: collect all flags and check if both -r/-R and -f appear.

# Step 1: strip backslash-letter sequences and paired single/double quotes
# (conservative: remove \<char> and 'str' / "str" wrappers around word chars)
NORM="$CMD"
NORM="$(printf '%s' "$NORM" | sed "s/\\\\//g; s/'//g; s/\"//g")"

# Step 2+3: strip leading path and known shell dispatch prefixes repeatedly.
# Also strips env / sudo / sh -c / bash -c wrappers so that
# `env git push`, `sudo git push`, `bash -c "git push"` are caught.
# Known residual bypasses (not worth the false-positive cost to block here):
#   - Deeply nested shells: bash -c 'bash -c "git push"' (three+ levels)
#   - Heredoc injection: bash -c "$(cat <<'EOF' ... EOF)"
#   - $() or eval inside the command string
#   - Custom git wrappers or aliases (e.g. mygit push)
#   - Obfuscated env vars: x=push; git $x
strip_prefixes() {
  local s="$1"
  # strip path prefix from leading binary
  s="$(printf '%s' "$s" | sed -E 's|^[[:space:]]*/[^[:space:]]*/||')"
  # Repeat up to 5 times to peel env/sudo/sh-c/bash-c/command/exec/builtin layers.
  local i lead
  for i in 1 2 3 4 5; do
    # strip "command " / "exec " / "builtin " prefixes
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(command|exec|builtin)[[:space:]]+//')"
    # strip "env " with optional VAR=val arguments (env FOO=bar git push -> git push)
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')"
    # strip plain "env " with no assignments
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*env[[:space:]]+//')"
    # strip "sudo " (with or without flags like -n, -E, -u user)
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*sudo([[:space:]]+-[A-Za-z][^[:space:]]*)*[[:space:]]+//')"
    # strip shell -c wrappers (sh -c, bash -c, dash -c, zsh -c) using pure bash
    # to avoid macOS sed ERE alternation issues with double-quoted expressions.
    lead="$(printf '%s' "$s" | awk '{print $1}')"
    case "$lead" in
      sh|bash|dash|zsh)
        # Remove the "sh -c " / "bash -lc " prefix (handle combined flags like -lc, -cl).
        # Pattern: shell-name SPACE -<optional-letters>c SPACE
        s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*[a-z]+[[:space:]]+-[a-zA-Z]*c[[:space:]]+//')"
        # strip leading/trailing single or double quote (already removed by Step 1,
        # but guard in case they survived)
        s="${s#\'}" ; s="${s%\'}"
        s="${s#\"}" ; s="${s%\"}"
        ;;
    esac
    # strip another path prefix that may have been revealed
    s="$(printf '%s' "$s" | sed -E 's|^[[:space:]]*/[^[:space:]]*/||')"
  done
  printf '%s' "$s"
}
NORM="$(strip_prefixes "$NORM")"

# Extract leading binary name from normalized command
BIN="$(printf '%s' "$NORM" | awk '{print $1}')"
REST="$(printf '%s' "$NORM" | cut -d' ' -f2-)"

# Step 4: for git, skip global options to find the subcommand
# Git global options that consume an argument: -C, --git-dir, --work-tree,
# --namespace, --super-prefix, -c, --config-env, --exec-path, --html-path,
# --man-path, --info-path. Flags: --version, --help, --no-pager, -p, --bare,
# --no-replace-objects, --literal-pathspecs, --glob-pathspecs, --noglob-pathspecs,
# --icase-pathspecs, --no-optional-locks, --no-advice.
git_subcommand() {
  local args="$1"
  local skip_next=false
  local tok
  for tok in $args; do
    if $skip_next; then
      skip_next=false
      continue
    fi
    case "$tok" in
      -C|--git-dir|--work-tree|--namespace|--super-prefix|-c|--config-env|--exec-path)
        skip_next=true ;;
      --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|-c=*|--config-env=*|--exec-path=*)
        ;;  # value embedded, skip nothing extra
      -*)
        ;;  # other flag, skip
      *)
        printf '%s' "$tok"
        return ;;
    esac
  done
}

# Step 5: for rm, check if -r/-R AND -f both appear across all tokens
rm_is_recursive_force() {
  local args="$1"
  local has_r=false has_f=false tok flag
  for tok in $args; do
    # each token: if it starts with - it's a flag group (e.g. -rf, -fr, -r, -f)
    case "$tok" in
      --recursive) has_r=true ;;
      --force)     has_f=true ;;
      -*)
        # strip leading dash(es) and iterate chars
        flag="${tok#-}"; flag="${flag#-}"
        case "$flag" in *r*|*R*) has_r=true ;; esac
        case "$flag" in *f*)     has_f=true ;; esac
        ;;
    esac
  done
  $has_r && $has_f
}

# Check a single normalized segment for denied patterns.
# Returns 0 (true) if the segment should be denied.
segment_is_denied() {
  local seg="$1"
  # Strip prefixes from the individual segment so wrappers inside chains are caught.
  seg="$(strip_prefixes "$seg")"
  local bin rest subcmd
  bin="$(printf '%s' "$seg" | awk '{print $1}')"
  # Use awk for rest to handle leading-space segments (cut -d' ' -f2- is field-index
  # based and gives wrong result when the string starts with a space).
  rest="$(printf '%s' "$seg" | awk '{$1=""; sub(/^ /,""); print}')"
  if [[ "$bin" == "git" ]]; then
    subcmd="$(git_subcommand "$rest")"
    case "$subcmd" in
      push|merge|"reset")
        if [[ "$subcmd" == "reset" ]]; then
          printf '%s' "$rest" | grep -qwF -- '--hard' && return 0
        else
          return 0
        fi
        ;;
    esac
  elif [[ "$bin" == "rm" ]]; then
    rm_is_recursive_force "$rest" && return 0
  elif printf '%s' "$seg" | grep -qiE \
    'deploy-edge|supabase[[:space:]].*delete|supabase[[:space:]].*drop|drop[[:space:]]+table([[:space:]]|$)|truncate[[:space:]]|stripe[[:space:]]|gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

DENIED=false
MATCHED_SEG=""

# Split the normalized command on chain operators (;, &&, ||, |) so that
# `git push; true` and `false || git push` are both caught.
# Use a while-read loop (portable; avoids bash-version issues with read -a).
_split_on_chains() {
  # Add trailing newline so the last segment is read by `while IFS= read -r`.
  printf '%s\n' "$1" | tr ';|' '\n' | sed 's/&&/\n/g'
}

while IFS= read -r _seg; do
  # Skip blank/whitespace-only segments produced by the split.
  [[ -z "${_seg// /}" ]] && continue
  if segment_is_denied "$_seg"; then DENIED=true; MATCHED_SEG="$_seg"; break; fi
done < <(_split_on_chains "$NORM")

if $DENIED; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
    permissionDecisionReason:"irreversible-deny: an active loop may not run irreversible actions (push/merge/deploy/delete/money). Pause the loop or get a human checkpoint, then run this outside the loop."}}' 2>/dev/null || true

  # ── Gap telemetry (ADR-044 D6) ──────────────────────────────────────────
  # When this hook denies a call that no static permissions.deny rule would
  # have caught, log one line of coverage telemetry -- this is NOT a gate,
  # it never changes the decision above. A denial already mirrored by a
  # static Bash(<verb>:*) rule is by definition not a gap and MUST NOT be
  # logged. Best-effort: any failure here is silently skipped (never blocks,
  # never crashes -- the deny above has already been emitted).
  CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "$CWD" ]] && CWD="$PWD"
  COVERED=0
  GAP_CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
  if [[ -n "$GAP_CONFIG" ]]; then
    GAP_SIDECAR="$(dirname "$GAP_CONFIG")/permissions.stack.json"
    if [[ -f "$GAP_SIDECAR" ]]; then
      while IFS= read -r _emitted; do
        [[ "$_emitted" =~ ^Bash\((.*):\*\)$ ]] || continue
        _prefix="${BASH_REMATCH[1]}"
        case "$MATCHED_SEG" in
          "$_prefix"*) COVERED=1 ;;
        esac
        [[ "$COVERED" -eq 1 ]] && break
      done < <(jq -r '.emitted.deny[]? // empty' "$GAP_SIDECAR" 2>/dev/null)
    fi
  fi
  if [[ "$COVERED" -eq 0 ]]; then
    # Never log raw arguments -- a segment like `psql "postgres://u:p@host/db"`
    # or `PGPASSWORD=x psql ...` must not leak the URL/credential into the gap
    # log. Only the leading verb token is used, and only if it looks like a
    # command name (no `=`, `/`, `:`, quotes) -- otherwise fall back to a fixed
    # placeholder so nothing arg-shaped is ever written to disk.
    _verb="$(printf '%s' "$MATCHED_SEG" | awk '{print $1}')"
    if [[ "$_verb" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      RULE_CANDIDATE="Bash(${_verb}:*)"
    else
      RULE_CANDIDATE="Bash(<unrecognized>:*)"
    fi
    mkdir -p "$HOME/.claude/logs" 2>/dev/null
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "irreversible-deny" \
      --arg tool "Bash" --arg class_hint "bash" --arg rule "$RULE_CANDIDATE" \
      '{ts:$ts, hook:$hook, tool:$tool, class_hint:$class_hint, rule_candidate:$rule}' \
      >> "$HOME/.claude/logs/permissions-gap.jsonl" 2>/dev/null || true
  fi
fi
exit 0
