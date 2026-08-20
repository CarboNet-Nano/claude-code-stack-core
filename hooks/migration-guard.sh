#!/usr/bin/env bash
# PreToolUse[Edit|Write|MultiEdit] hook: friction on editing a migration file
# that is already committed to the default branch. ADR-037 D-1.
#
# WHAT THIS CLAIMS: only that the file is committed to the default branch, not
# that it has been applied to any database. Git ancestry / ls-tree cannot see
# the applied-migrations bookkeeping table a real database keeps, so this hook
# does not try to. "Committed" is treated as "cannot rule out applied" — the
# prompt says exactly that, never more. Revisions 1 and 2 of ADR-037 claimed
# this proved applied-ness; that claim was wrong and is not repeated here.
#
# SCOPE: this is friction, not a boundary — same statement as
# schema-deploy-gate.sh. Blocking Edit/Write does nothing about `sed -i`, a
# heredoc, or an interpreter call through Bash. A determined agent on the
# interactive thread can still answer "yes" to the prompt.
#
# COMMITTED-NESS TEST: `git ls-tree <default-branch> -- <path>` only. No
# `merge-base --is-ancestor` — ls-tree checks presence in the CURRENT tree of
# the default branch, which already covers squash-merges (the squashed commit
# still lands the file at that path) without a separate ancestry check.
#
# DEFAULT-BRANCH RESOLUTION: verified in order, each candidate checked with
# `git rev-parse --verify --quiet`, and the branch is used to query ls-tree
# EXACTLY as verified (never re-derived by stripping "origin/" — a repo with
# only a remote-tracking HEAD, the common CI shape, has no local `main` to
# fall back to, and stripping the prefix would silently break that case):
#   refs/remotes/origin/HEAD -> refs/remotes/origin/main -> .../master
#   -> refs/heads/main -> refs/heads/master
#
# FAIL-CLOSED, DELIBERATELY DIVERGING from schema-deploy-gate.sh's "any
# internal failure exits 0": if no candidate resolves, ls-tree itself errors,
# or a rebase is in progress (.git/rebase-merge or .git/rebase-apply exists),
# the file is treated as UNCERTAIN -> handled exactly like "committed". This
# is what "we cannot rule it out" means in the honest-claim framing above.
# Uncertainty is not proof; the prompt text says so.
#
# THE CI EXCEPTION IS REQUIRED: actions/checkout defaults to fetch-depth:1 and
# a detached HEAD, so no default-branch candidate resolves. That makes EVERY
# CI-driven agent see UNCERTAIN, and because CI is a workflow context, that
# escalates to deny. Fail-closed is not free — the deny reason names both
# fixes (fetch-depth:0 + `git remote set-head origin -a`, or explicitly
# turning the hook off for that environment) so a repo hits a documented wall
# with a way out, not a silent one.
#
# WORKFLOW VS INTERACTIVE — the ordering is the load-bearing part. Detected
# from transcript_path containing "/workflows/", identical to
# schema-deploy-gate.sh. Inside a workflow: deny, and RETURN IMMEDIATELY.
# The override file below is never read in that branch. Getting this order
# backwards is what lets an autonomous agent defeat the workflow gate by
# writing the override file itself and retrying — the exact bypass a review
# round demonstrated in 3 turns against an earlier draft.
#
# OVERRIDE: .claude/.migration-override-once, created by the user, single-use
# (deleted on consumption). Honored ONLY when a) not in a workflow context
# (checked first, per above) and b) stack-config's orchestration_mode is
# "main-thread" — other orchestration modes may involve teammates other than
# the human, so the override is not honored there. An override file tracked
# by git is refused (a committed override is repo-controlled, not
# user-controlled) and left in place with a warning; only an untracked file
# is consumed. Consumption is NEVER surfaced as an explicit "allow" decision:
# design-gate.sh sits on this same Edit|Write|MultiEdit matcher, and an
# explicit allow from this hook risks suppressing a sibling hook's deny in a
# way nobody has verified is safe. A silent exit 0 plus a logged row (via
# override-log.sh's ovlog_append, so the log/schema is shared, not
# duplicated) gets the ADR's actual requirement — an audit trail — without
# that coupling risk.
#
# GATING: active whenever resolve-migrations-dir.sh resolves a directory AND
# the edited file is inside it. domain_mode == "schema-migration" adds no
# additional case on its own — the resolver already requires a directory to
# exist before anything can match, so a repo with no migrations directory
# exits regardless of domain_mode. Requiring a stack-config to exist at all
# (via find-stack-config.sh) is a deliberate, ADR-silent choice: an
# unconfigured repo gets no friction from a feature it never opted into. No
# tier floor is applied — that is schema-deploy-gate.sh's policy, not this
# hook's; the ADR does not specify one.
#
# RESOLVER-ERROR HANDLING: if resolve-migrations-dir.sh returns 2 (a
# configured guards.migrations_dir was refused as unsafe), this hook does NOT
# silently no-op — that would blind the guard in exactly the repo that most
# needs it (the one with a bad config). It denies/asks the same as an
# unresolvable default branch: treated as UNCERTAIN, be loud about why via
# stderr, and let the interactive/workflow split decide the action as usual.
#
# OQ-B (ADR-037): latency against a large Edit/Write payload is unmeasured.
# This hook only reads tool_input.file_path, never .content or .new_string,
# so payload size should not matter — but that assumption is unverified until
# measured. Do not call this hook "cheap" without doing so.
# summary: Adds friction (ask/deny) on editing a migration file already committed to the default branch.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="$(cat 2>/dev/null || echo '{}')"

# One jq call, one parse. This hook never needs tool_input.content or
# .new_string — only file_path — but a large migration/generated-SQL edit
# still means a multi-megabyte payload; re-parsing that JSON string from
# scratch per field (four separate `echo "$INPUT" | jq` calls, as an earlier
# draft did) cost ~750ms on a 6.6MB payload in measurement. One parse
# extracting every field this hook needs brings that down to single-digit ms
# regardless of new_string/content size (verified below, OQ-B).
IFS=$'\t' read -r CWD TOOL_NAME FILE_PATH TRANSCRIPT < <(
  jq -r '[(.cwd // ""), (.tool_name // ""), (.tool_input.file_path // ""), (.transcript_path // "")] | @tsv' \
    <<<"$INPUT" 2>/dev/null
)

[[ -z "$CWD" ]] && CWD="$PWD"

case "$TOOL_NAME" in
  Edit|Write|MultiEdit) : ;;
  *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0

# Only fence stack-initialized projects — see header for why this is a
# deliberate choice rather than an ADR requirement.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0

MIG_MODE="$(jq -r '.guards.migration_hook // "on"' "$CONFIG" 2>/dev/null)"
[[ "$MIG_MODE" == "off" ]] && exit 0

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
[[ -z "$REPO_ROOT" ]] && exit 0

# shellcheck source=/dev/null
source "$DIR/../scripts/lib/resolve-migrations-dir.sh" 2>/dev/null || exit 0

RESOLVER_UNCERTAIN=0
rmd_resolve "$REPO_ROOT" >/dev/null 2>/dev/null
RMD_RC=$?
if [[ "$RMD_RC" -eq 2 ]]; then
  # Configured migrations_dir was refused as unsafe. Do not silently no-op
  # — see header. Treat as uncertain rather than exiting.
  RESOLVER_UNCERTAIN=1
elif [[ "$RMD_RC" -ne 0 ]]; then
  # rc 1: no migrations directory in this repo at all. Nothing to guard.
  exit 0
fi

if [[ "$RESOLVER_UNCERTAIN" -eq 0 ]]; then
  rmd_is_migration_file "$FILE_PATH" "$REPO_ROOT" || exit 0
fi

# ── Committed-ness ───────────────────────────────────────────────────────
UNCERTAIN=0
DEFAULT_BRANCH=""

if [[ "$RESOLVER_UNCERTAIN" -eq 1 ]]; then
  UNCERTAIN=1
fi

if [[ -d "$REPO_ROOT/.git/rebase-merge" || -d "$REPO_ROOT/.git/rebase-apply" ]]; then
  UNCERTAIN=1
fi

if [[ "$UNCERTAIN" -eq 0 ]]; then
  for ref in \
    "refs/remotes/origin/HEAD" \
    "refs/remotes/origin/main" \
    "refs/remotes/origin/master" \
    "refs/heads/main" \
    "refs/heads/master"
  do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      # For the symbolic HEAD ref, resolve to the branch it actually points at
      # (still fully-qualified — never stripped to a bare name) so ls-tree
      # gets a ref it can query directly.
      if [[ "$ref" == "refs/remotes/origin/HEAD" ]]; then
        resolved="$(git -C "$REPO_ROOT" symbolic-ref -q "$ref" 2>/dev/null)"
        [[ -n "$resolved" ]] && DEFAULT_BRANCH="$resolved"
      else
        DEFAULT_BRANCH="$ref"
      fi
      [[ -n "$DEFAULT_BRANCH" ]] && break
    fi
  done
  [[ -z "$DEFAULT_BRANCH" ]] && UNCERTAIN=1
fi

REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"
COMMITTED=0

if [[ "$UNCERTAIN" -eq 0 ]]; then
  # argv-only: DEFAULT_BRANCH and REL_PATH passed as separate arguments, never
  # interpolated into a single command string.
  LS_OUT="$(git -C "$REPO_ROOT" ls-tree "$DEFAULT_BRANCH" -- "$REL_PATH" 2>/dev/null)"
  LS_RC=$?
  if [[ $LS_RC -ne 0 ]]; then
    UNCERTAIN=1
  elif [[ -n "$LS_OUT" ]]; then
    COMMITTED=1
  fi
fi

if [[ "$COMMITTED" -eq 0 && "$UNCERTAIN" -eq 0 ]]; then
  # Definitively not committed to the default branch. No friction.
  exit 0
fi

# ── Workflow vs interactive — checked BEFORE the override file is read ─────
# TRANSCRIPT already extracted above, in the same single jq parse as CWD/
# TOOL_NAME/FILE_PATH.
IN_WORKFLOW=0
[[ "$TRANSCRIPT" == */workflows/* ]] && IN_WORKFLOW=1

emit_decision() {
  local decision="$1" reason="$2"
  jq -nc --arg d "$decision" --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}' \
    2>/dev/null || true
}

if [[ "$IN_WORKFLOW" -eq 1 ]]; then
  if [[ "$UNCERTAIN" -eq 1 ]]; then
    REASON="stack migration-guard: could not determine whether ${REL_PATH} is committed to the default branch (unresolvable default branch, shallow clone, or a rebase in progress — the common shape of a CI checkout with fetch-depth:1). Treating it as committed out of caution: we cannot rule out that it has already run. No override is available inside an automated workflow. To fix the underlying check in CI, either set fetch-depth: 0 and run 'git remote set-head origin -a' in your checkout step, or set guards.migration_hook to \"off\" in .claude/stack-config.json for this environment if the check should not run there."
  else
    REASON="stack migration-guard: ${REL_PATH} is already committed to ${DEFAULT_BRANCH} and may have been applied. Editing it from an autonomous workflow has no human to confirm the change is intended, so the stack denies it. Run this on the interactive main thread instead, or set guards.migration_hook to \"off\" in .claude/stack-config.json if this repo intentionally rewrites historical migrations."
  fi
  emit_decision "deny" "$REASON"
  exit 0
fi

# Interactive thread. Only now — after the workflow check has already run —
# is the override file eligible to be read.
ORCH_MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG" 2>/dev/null)"
[[ -n "$ORCH_MODE" ]] || ORCH_MODE="main-thread"

OVERRIDE_FILE="$REPO_ROOT/.claude/.migration-override-once"
OVERRIDE_NOTE=""

if [[ "$ORCH_MODE" == "main-thread" && -f "$OVERRIDE_FILE" ]]; then
  if git -C "$REPO_ROOT" ls-files --error-unmatch ".claude/.migration-override-once" >/dev/null 2>&1; then
    OVERRIDE_NOTE=" An override file exists at .claude/.migration-override-once but it is tracked by git, so it is refused — a committed override is repo-controlled, not yours. Remove it from git and keep a local, untracked copy instead."
  else
    rm -f "$OVERRIDE_FILE" 2>/dev/null
    # shellcheck source=/dev/null
    source "$DIR/override-log.sh" 2>/dev/null
    if declare -F ovlog_append >/dev/null 2>&1; then
      EXTRA="$(jq -nc --arg hook "migration-guard" --arg file "$REL_PATH" \
        '{hook:$hook, file:$file}')"
      ovlog_append "guard_override" "$CWD" "$EXTRA"
    fi
    exit 0
  fi
elif [[ "$ORCH_MODE" != "main-thread" ]]; then
  OVERRIDE_NOTE=" An override at .claude/.migration-override-once is not honored while orchestration_mode is \"$ORCH_MODE\" — only main-thread sessions may use it."
fi

if [[ "$UNCERTAIN" -eq 1 ]]; then
  BASE="stack migration-guard: could not determine whether ${REL_PATH} is committed to the default branch (unresolvable default branch, shallow clone, or a rebase in progress). Treating it as committed out of caution — this does not assert it has been applied, only that we cannot rule it out. Edit anyway?"
else
  BASE="stack migration-guard: ${REL_PATH} is committed to ${DEFAULT_BRANCH} and may already have been applied. This does not assert it has been applied — only that we cannot rule it out. Edit anyway? To skip this prompt once, create .claude/.migration-override-once (e.g. \`touch .claude/.migration-override-once\`) before editing."
fi

emit_decision "ask" "${BASE}${OVERRIDE_NOTE}"
exit 0
