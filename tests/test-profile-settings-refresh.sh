#!/usr/bin/env bash
# tests/test-profile-settings-refresh.sh
# Regression: a profile with a PRE-EXISTING settings.json must gain new
# stack-required hook entries when the overlay is refreshed (the ADR-086
# self-update hook never fired on profile sessions because the wiring was
# only seeded at profile creation, never merged on update).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP="$(mktemp -d)"; ORIG_HOME="$HOME"; export HOME="$TMP"
trap 'export HOME="$ORIG_HOME"; rm -rf "$TMP"' EXIT
source scripts/lib/config-merger.sh; source scripts/lib/profile-overlay.sh
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

P="$HOME/.claude-team"
mkdir -p "$P"

# A profile settings.json created BEFORE the self-update hooks existed,
# with a user customization that must survive the merge.
cat > "$P/settings.json" <<'EOF'
{
  "permissions": { "defaultMode": "auto" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/session-start-handoff.sh" } ] }
    ]
  }
}
EOF

po_merge_settings_fragments "$REPO" 4 "$P"

has(){ jq -r ".hooks.$1[].hooks[].command" "$P/settings.json" 2>/dev/null | grep -qc "$2"; }

has SessionStart stack-self-update.sh \
  && ok "SessionStart gains stack-self-update.sh" || bad "SessionStart gains stack-self-update.sh"
has UserPromptSubmit stack-update-apply.sh \
  && ok "UserPromptSubmit gains stack-update-apply.sh" || bad "UserPromptSubmit gains stack-update-apply.sh"
has SessionStart session-start-handoff.sh \
  && ok "pre-existing hook entry kept" || bad "pre-existing hook entry kept"
[[ "$(jq -r '.permissions.defaultMode' "$P/settings.json")" == "auto" ]] \
  && ok "user scalar wins on conflict" || bad "user scalar wins on conflict"
[[ "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(select(. == "~/.claude/hooks/session-start-handoff.sh")) | length' "$P/settings.json")" == 1 ]] \
  && ok "no duplicate hook entries after merge" || bad "no duplicate hook entries after merge"

# Idempotent where it matters: hook lists (execution order is semantic) are
# byte-stable across refreshes; other arrays may re-sort once (unique), so
# the file as a whole must converge by the second refresh.
hooks_before="$(jq -S .hooks "$P/settings.json")"
po_merge_settings_fragments "$REPO" 4 "$P"
[[ "$hooks_before" == "$(jq -S .hooks "$P/settings.json")" ]] \
  && ok "hook wiring stable across refreshes" || bad "hook wiring stable across refreshes"
second="$(jq -S . "$P/settings.json")"
po_merge_settings_fragments "$REPO" 4 "$P"
[[ "$second" == "$(jq -S . "$P/settings.json")" ]] \
  && ok "refresh converges (no growth)" || bad "refresh converges (no growth)"

# A profile with NO real settings.json is untouched (seeding is po_build_overlay's job).
P2="$HOME/.claude-empty"; mkdir -p "$P2"
po_merge_settings_fragments "$REPO" 4 "$P2"
[[ ! -e "$P2/settings.json" ]] \
  && ok "absent settings.json not created" || bad "absent settings.json not created"

echo "profile-settings-refresh: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
