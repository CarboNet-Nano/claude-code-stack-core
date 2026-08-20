#!/usr/bin/env bash
# scripts/sweep-install.sh — install the Sweep into an EXISTING target repo
# (stack ADR-078; the "INTO A TARGET REPO" substitution contract from
# templates/workflows/sweep.yml's header, previously a written contract
# with no owner). New repos get the same result from carbonet-provisioner's
# sweep-gate step; this is the operator path for repos that already exist.
#
# What it does (all local, nothing pushed):
#   1. Renders templates/workflows/sweep.yml with {{STACK_REF}} pinned to
#      --ref, REFUSING if any {{...}} token survives — an unsubstituted
#      ref resolves to nothing and the workflow can never run.
#   2. Writes .github/workflows/sweep.yml (no-op when identical; refuses
#      to overwrite a differing file without --force).
#   3. Scaffolds .claude/sweep.config.json (observe mode) if absent — a new
#      scaffold's `skips` names every non-B4 inventory id with a reason.
#   3b. Existing-adopter upgrade path (doctrine v2 P1a, ADR-082): when the
#      config already exists, any installed inventory id that is neither
#      a declared family block nor a reason-skip gets APPENDED to `skips`
#      with a stack-upgrade reason — generic over the whole inventory, not
#      specific to any one check id, so a fleet heals on re-pin without a
#      red window instead of silently shipping an id with no config entry.
#      Idempotent: an id already declared or skipped is left alone, so
#      re-running never appends a second entry for the same id.
#   4. Adds the runs.jsonl gitignore line (findings.jsonl IS committed).
#   5. Prints the rendered sweep-liveness snippet for the ONE manual step
#      this script will not automate: pasting the job into the repo's
#      existing REQUIRED run-tests workflow (S7.3 authorises exactly that
#      edit; splicing YAML blind risks corrupting a required workflow).
#
# Auth: repos read the stack through the CarboNet-Nano org secret
# SWEEP_STACK_DEPLOY_KEY (org-wide, 2026-08-16). Repos outside that org
# need their own deploy key + repo secret.
#
# Usage: sweep-install.sh --repo <path> --ref <40-hex stack sha> [--force]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SWEEP_INSTALL_STACK_ROOT:-$(dirname "$SCRIPT_DIR")}"
TEMPLATE="$STACK_ROOT/templates/workflows/sweep.yml"
SNIPPET="$STACK_ROOT/templates/workflows/snippets/run-tests-sweep-liveness.yml"
# shellcheck source=/dev/null
source "$STACK_ROOT/scripts/sweep/lib/sweep-config.sh"

UPGRADE_DATE="2026-08-16"

# heal_inventory_gaps <config-json-file> -> the config with a stack-upgrade
# skip appended for every installed inventory id that is neither a
# declared family block nor already reason-skipped. Generic over
# scripts/sweep/inventory.txt (or SWEEP_INVENTORY_FILE in tests) — never
# hardcodes a check id, so the same branch heals every future family too.
heal_inventory_gaps() {
  local cfg="$1" inv_json
  inv_json="$(sweep_inventory_ids | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  jq --arg date "$UPGRADE_DATE" --argjson inventory "$inv_json" '
    ($inventory) as $ids |
    (.families // {}) as $fam |
    (.skips // []) as $skips |
    reduce $ids[] as $id (.;
      if ($fam | has($id)) or ([$skips[] | select(.check_id == $id)] | length > 0)
      then .
      else .skips += [{check_id: $id, reason: ("added by stack upgrade " + $date + " — configure or keep skipped")}]
      end)
  ' "$cfg"
}

die() { echo "sweep-install: $*" >&2; exit 1; }

REPO="" REF="" FORCE=0 GATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --gate) GATE=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$REPO" && -n "$REF" ]] || die "usage: sweep-install.sh --repo <path> --ref <40-hex sha> [--force] [--gate]"
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "--ref must be a full 40-hex commit sha (got: $REF)"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
[[ -f "$SNIPPET" ]] || die "snippet not found: $SNIPPET"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || die "--repo is not a git repository: $REPO"

# render <template-file> -> substituted content on stdout; dies if any
# {{...}} token survives (the fail-loud half of the contract).
render() {
  local out
  out="$(sed "s/{{STACK_REF}}/$REF/g" "$1")"
  local leftover
  leftover="$(grep -oE '\{\{[A-Za-z_]+\}\}' <<<"$out" | head -1)"
  [[ -n "$leftover" ]] && die "unsubstituted token $leftover remains after rendering $1 — refusing to write"
  printf '%s\n' "$out"
}

RENDERED="$(render "$TEMPLATE")" || exit 1
RENDERED_SNIPPET="$(render "$SNIPPET")" || exit 1

DEST="$REPO/.github/workflows/sweep.yml"
if [[ -f "$DEST" ]] && [[ "$(cat "$DEST")" == "$RENDERED" ]]; then
  echo "sweep.yml: already installed at this pin — unchanged"
elif [[ -f "$DEST" && "$FORCE" -ne 1 ]]; then
  die "sweep.yml already exists and differs — rerun with --force to overwrite"
else
  mkdir -p "$REPO/.github/workflows"
  printf '%s\n' "$RENDERED" > "$DEST"
  echo "sweep.yml: written (pinned to ${REF:0:12})"
fi

CONFIG="$REPO/.claude/sweep.config.json"
if [[ -f "$CONFIG" ]]; then
  HEALED="$(heal_inventory_gaps "$CONFIG")" || die "could not read the installed check inventory to heal $CONFIG"
  if [[ "$HEALED" != "$(jq . "$CONFIG")" ]]; then
    printf '%s\n' "$HEALED" | jq . > "$CONFIG"
    echo "sweep.config.json: already present — healed (stack-upgrade skips appended for undeclared inventory ids)"
  else
    echo "sweep.config.json: already present — untouched"
  fi
else
  mkdir -p "$REPO/.claude"
  printf '%s\n' '{
  "schema": "sweep-config/v1",
  "mode": "observe",
  "check_modes": {},
  "surfaces": { "B4": "ci-gate" },
  "families": { "B4": {} },
  "skips": [
    { "check_id": "A5", "reason": "no command_map/interface_files declared yet for this repo — configure or keep skipped" }
  ]
}' > "$CONFIG"
  echo "sweep.config.json: scaffolded (observe mode — add reason-carrying skips per repo)"
fi
echo "detection cadence: optional — add detection_cadence.owner to $CONFIG and install .github/workflows/detection-cadence.yml to enable"

GITIGNORE="$REPO/.gitignore"
if [[ -f "$GITIGNORE" ]] && grep -qxF '.claude/sweep/runs.jsonl' "$GITIGNORE"; then
  echo ".gitignore: sweep entries already present"
else
  {
    echo ""
    echo "# Sweep per-run telemetry (never committed; findings.jsonl IS committed)"
    echo ".claude/sweep/runs.jsonl"
  } >> "$GITIGNORE"
  echo ".gitignore: sweep entries added"
fi

# --gate (queue #241): the remote half provisioner sweep-gate does for new
# repos — required-checks ruleset + allow_auto_merge + ENABLE_AUTO_MERGE.
# Opt-in because everything above is local-by-contract ("all local,
# nothing pushed"); this flag is the one explicitly-requested exception.
# COGS/AP/app-template all had the workflows but none of this, so PRs
# merged red. Idempotent: PUTs an existing ruleset, variable set is an
# upsert. NOTE: required checks belong in this PER-REPO ruleset, never in
# the org-wide main-branch-protection ruleset (it targets every repo).
if [[ "$GATE" -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || die "--gate needs gh"
  SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null \
    | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
  [[ -n "$SLUG" ]] || die "--gate: no origin remote to derive owner/repo from"

  if [[ "$(gh api "repos/$SLUG" --jq '.allow_auto_merge' 2>/dev/null)" != "true" ]]; then
    gh api -X PATCH "repos/$SLUG" -F allow_auto_merge=true >/dev/null \
      && echo "gate: allow_auto_merge enabled" \
      || die "--gate: could not enable allow_auto_merge on $SLUG"
  else
    echo "gate: allow_auto_merge already enabled"
  fi

  RULESET_JSON='{
    "name": "auto-merge-required-checks",
    "target": "branch",
    "enforcement": "active",
    "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
    "rules": [
      { "type": "required_status_checks",
        "parameters": {
          "strict_required_status_checks_policy": true,
          "required_status_checks": [ { "context": "run-tests" } ] } }
    ]
  }'
  RS_ID="$(gh api "repos/$SLUG/rulesets" --jq '[.[]|select(.name=="auto-merge-required-checks")][0].id // empty' 2>/dev/null)"
  if [[ -n "$RS_ID" ]]; then
    printf '%s' "$RULESET_JSON" | gh api -X PUT "repos/$SLUG/rulesets/$RS_ID" --input - >/dev/null \
      && echo "gate: ruleset auto-merge-required-checks updated (id $RS_ID)" \
      || die "--gate: could not update ruleset $RS_ID on $SLUG"
  else
    printf '%s' "$RULESET_JSON" | gh api -X POST "repos/$SLUG/rulesets" --input - >/dev/null \
      && echo "gate: ruleset auto-merge-required-checks created (requires run-tests)" \
      || die "--gate: could not create the ruleset on $SLUG"
  fi

  gh variable set ENABLE_AUTO_MERGE --repo "$SLUG" --body "true" >/dev/null 2>&1 \
    && echo "gate: repo variable ENABLE_AUTO_MERGE=true" \
    || die "--gate: could not set ENABLE_AUTO_MERGE on $SLUG"
fi

cat <<EOF

MANUAL STEP — paste this job under the \`jobs:\` key of the repo's
existing REQUIRED run-tests workflow (the one edit S7.3 authorises;
this script never splices a required workflow blind):
--- sweep-liveness job (rendered, pinned to ${REF:0:12}) ---
$RENDERED_SNIPPET
--- end sweep-liveness job ---

Then: commit. Gate wiring (required-checks ruleset + auto-merge):
rerun with --gate, or /auto-merge on <repo>; the provisioner does this
for generated repos. CarboNet-Nano repos authenticate via the org-wide
SWEEP_STACK_DEPLOY_KEY secret; repos elsewhere need their own deploy
key on get-lade/claude-code-stack and a repo secret of that name.
EOF
