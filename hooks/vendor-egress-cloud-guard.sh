#!/usr/bin/env bash
# PreToolUse[Bash] hook — ADR-071 D17. CLASS C (ADR-044 D1): raises the cost
# of an accident and of an unsophisticated agent. It is NOT a boundary.
# Defeatable by base64, variable indirection, or an IP literal — see
# hooks/irreversible-deny.sh's header for the same class of caveat. It
# exists ONLY because cloud/CI sessions have no OS sandbox at all (D15 #7):
# active ONLY when is_cloud_session() is true. On a local session with the
# managed floor installed, the real wall is scripts/sandbox-policy-compile.sh
# + the sandbox's own denyWrite/strictAllowlist — this hook changes nothing
# there and is never the layer doing the work.
#
# Denies:
#   1. a TOP-LEVEL command segment that literally names a denied governed
#      host (string match on the receipt's denied_hosts, cloud sessions only)
#   2. a TOP-LEVEL command segment that looks like a write to a
#      denyWrite-listed path
#
# Best-effort: ANY internal failure (missing jq, unreadable receipt,
# malformed input) falls through to exit 0 — this hook must never crash and
# must never deny on an error it cannot diagnose.
#
# summary: Cloud-only, class-C PreToolUse[Bash] guard against denied vendor hosts and denyWrite-listed paths (ADR-071 D17).
set -uo pipefail

# Security-audit CRITICAL fix, 2026-08-11: the /tmp marker file this
# detector's twin in permissions-compile.sh also checks is Bash-writable
# (ADR-063 D4's allowWrite covers /tmp), so a subagent could forge or erase
# it. Removed here; env vars only -- unforgeable across the Bash-tool /
# hook-process boundary. See scripts/sandbox-policy-compile.sh's
# is_cloud_session() for the full rationale (kept in sync deliberately).
is_cloud_session() {
  [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] && return 0
  local v val
  for v in CLAUDE_CODE_CLOUD CLAUDE_CLOUD CODESPACES CLOUD_SHELL; do
    val="${!v:-}"
    case "$val" in [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) return 0 ;; esac
  done
  return 1
}

is_cloud_session || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[[ -z "$CMD" ]] && exit 0

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

deny() {
  local reason="$1"
  jq -nc --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}' \
    2>/dev/null || true
  exit 0
}

# --- best-effort: find the governed denied-host list for this repo ---------
# Reads the receipt scripts/sandbox-policy-compile.sh already wrote for the
# repo containing CWD. No receipt (never compiled, or repo not governed) ->
# nothing to check against -> fall through (best-effort, CG6).
REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
DENIED_HOSTS=()
if [[ -n "$REPO_ROOT" ]] && command -v python3 >/dev/null 2>&1; then
  RECEIPT_KEY="$(printf '%s' "$REPO_ROOT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:16])' 2>/dev/null)"
  RECEIPT="$HOME/.claude/session-state/sandbox-policy/$RECEIPT_KEY.json"
  if [[ -n "$RECEIPT_KEY" && -f "$RECEIPT" ]]; then
    while IFS= read -r h; do
      [[ -n "$h" ]] && DENIED_HOSTS+=("$h")
    done < <(jq -r '.denied_hosts[]? // empty' "$RECEIPT" 2>/dev/null)
  fi
fi

# --- top-level segments only (ADR-063 literal-match precedent) -------------
_split_on_chains() {
  printf '%s\n' "$1" | tr ';|' '\n' | sed 's/&&/\n/g'
}

# Red-team HIGH fix, 2026-08-11 (finding 3): tightened path canonicalization
# and the write-verb set. Class C by design -- this raises the cost of an
# accident and an unsophisticated bypass, it is not, and cannot become, a
# real boundary (see file header). Remaining known-open vectors are
# documented and asserted (not silently left implied) in the CG test block
# in tests/test-vendor-host-policy.sh.
DENY_WRITE_MARKERS=(
  ".claude/settings.json" ".claude/settings.local.json" ".claude/stack-config.json"
  ".claude/hooks/" ".claude/scripts/" ".claude/config/" ".claude/agents/"
  ".claude/skills/" ".claude/lib/" ".claude/stack-defaults.json"
  "settings.json" "settings.local.json" "stack-config.json" "stack-defaults.json"
)
PROTECTED_BASENAMES=("settings.json" "settings.local.json" "stack-config.json" "stack-defaults.json")
# Broadened from shell-redirect verbs to also cover common write-capable
# interpreters (finding 3 vector: `python3 -c 'open(...,"w")...'`, verb not
# previously matched at all).
WRITE_VERBS_RE='(>|tee[[:space:]]|dd[[:space:]]|sed[[:space:]]+-i|cp[[:space:]]|mv[[:space:]]|rm[[:space:]]|python3?[[:space:]]|perl[[:space:]]|ruby[[:space:]]|node[[:space:]]|open\()'

while IFS= read -r seg; do
  [[ -z "${seg// /}" ]] && continue
  seg_lc="$(printf '%s' "$seg" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  # Path canonicalization (finding 3 vector: ".claude/./settings.json"):
  # collapse "/./" -> "/" and squeeze repeated slashes before any matching.
  seg_norm="$seg_lc"
  while [[ "$seg_norm" == *"/./"* ]]; do seg_norm="${seg_norm//\/.\//\/}"; done
  seg_norm="$(printf '%s' "$seg_norm" | sed -E 's#/+#/#g')"

  for h in "${DENIED_HOSTS[@]:-}"; do
    [[ -z "$h" ]] && continue
    if [[ "$seg_norm" == *"$h"* ]]; then
      deny "vendor-egress-cloud-guard (ADR-071 D17, CLASS C — not a boundary): this command names '$h', a governed vendor host denied at this repo's sensitivity level. See config/vendor-hosts.json and docs/ADRs/071-sandbox-vendor-host-compile.md."
    fi
  done

  if [[ "$seg_norm" =~ $WRITE_VERBS_RE ]]; then
    for marker in "${DENY_WRITE_MARKERS[@]}"; do
      if [[ "$seg_norm" == *"$marker"* ]]; then
        deny "vendor-egress-cloud-guard (ADR-071 D17, CLASS C — not a boundary): this command appears to write a denyWrite-listed path ('$marker'). See docs/ADRs/071-sandbox-vendor-host-compile.md D11."
      fi
    done
    # Glob-token matching (finding 3 vector: ".claude/setting?.json" —
    # shell-glob-shaped, not a literal substring of any marker above). Each
    # whitespace-delimited token in the segment is tested, basename-only, as
    # a shell glob PATTERN against every protected literal basename.
    # `set -f` (noglob) is load-bearing here: without it, THIS SCRIPT's own
    # unquoted `for token in $seg_norm` would silently pathname-expand the
    # glob against files that actually exist in $PWD before the token ever
    # reaches the comparison below -- filesystem-state-dependent behavior
    # that must not decide what this detector sees.
    set -f
    for token in $seg_norm; do
      token="${token%\'}"; token="${token#\'}"; token="${token%\"}"; token="${token#\"}"
      base="${token##*/}"
      [[ "$base" == *[\?\*\[]* ]] || continue
      for pb in "${PROTECTED_BASENAMES[@]}"; do
        if [[ "$pb" == $base ]]; then
          set +f
          deny "vendor-egress-cloud-guard (ADR-071 D17, CLASS C — not a boundary): this command appears to write a denyWrite-listed path via a glob pattern ('$token' matches '$pb'). See docs/ADRs/071-sandbox-vendor-host-compile.md D11."
        fi
      done
    done
    set +f
  fi
done < <(_split_on_chains "$CMD")

exit 0
