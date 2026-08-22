#!/usr/bin/env bash
# ADR-063 phase "template rollout": the tier-1 settings template (installed to
# ~/.claude/settings.json for every tier >=1) must ship the sandbox block, and
# its lists must stay a superset of the ADR-063 D3/D4 audit sets plus the
# dogfood findings promoted in #157 (excludedCommands, unix sockets, mktemp
# paths). strictAllowlist must NOT appear in any project/tier template — it is
# user/managed/CLI scope only (D5).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/config/settings.tier-1.template.json"
FAIL=0

fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

check_jq() {
  local desc="$1" expr="$2"
  if jq -e "$expr" "$TEMPLATE" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_jq "sandbox.enabled true" '.sandbox.enabled == true'
check_jq "failIfUnavailable false (D2)" '.sandbox.failIfUnavailable == false'
check_jq "autoAllowBashIfSandboxed true (D1)" '.sandbox.autoAllowBashIfSandboxed == true'
# D18 P4 (2026-08-21) inverts the #157 posture: `gh *` must NOT be excluded
# from the sandbox any more — an excluded gh runs with unrestricted network
# and filesystem, which is the exact hole the broker exists to close.
if jq -e '.sandbox.excludedCommands | index("gh *")' "$TEMPLATE" >/dev/null 2>&1; then
  fail "D18 P4: gh * must NOT be in excludedCommands (broker-only GitHub writes)"
else
  pass "D18 P4: gh * absent from excludedCommands"
fi
check_jq "excludedCommands covers installed pm CLI (gh subprocess)" \
  '.sandbox.excludedCommands | map(test("pm/bin.mjs")) | any'
check_jq "allowAllUnixSockets true (tsx IPC, #157)" \
  '.sandbox.network.allowAllUnixSockets == true'

# D3 runtime domain set (ADR-071 D2 revision) — template must contain
# api.anthropic.com and every infra host; the four third-party AI vendor
# hosts moved to the per-repo scripts/sandbox-policy-compile.sh compiler and
# must NOT ship in this (user-scope) template (T2 below).
D3_DOMAINS=(
  api.anthropic.com api.github.com github.com
  raw.githubusercontent.com objects.githubusercontent.com codeload.github.com
  registry.npmjs.org registry.modelcontextprotocol.io
  formulae.brew.sh ghcr.io pypi.org files.pythonhosted.org
  cdn.playwright.dev playwright.download.prss.microsoft.com
)
for d in "${D3_DOMAINS[@]}"; do
  check_jq "allowedDomains: $d" ".sandbox.network.allowedDomains | index(\"$d\")"
done

# D18 P4 (2026-08-21): the infra hosts are broker-only now. api.cloudflare.com
# and *.neon.tech must NOT ship in the template — the agent reaches those
# vendors only through the stack-broker daemon (which is not sandboxed).
for d in api.cloudflare.com '*.neon.tech'; do
  if jq -e ".sandbox.network.allowedDomains | index(\"$d\")" "$TEMPLATE" >/dev/null 2>&1; then
    fail "D18 P4: $d must NOT be in allowedDomains (broker-only surface)"
  else
    pass "D18 P4: $d absent from allowedDomains"
  fi
done

# T2 (ADR-071 §T) — the four third-party vendor hosts must NOT appear in the
# tier-1 (user-scope) template; they are compiler-owned, per repo, from
# config/vendor-hosts.json (ADR-071 D2).
T2_REMOVED_VENDOR_HOSTS=(
  api.openai.com generativelanguage.googleapis.com api.deepseek.com api.x.ai
)
for d in "${T2_REMOVED_VENDOR_HOSTS[@]}"; do
  if jq -e ".sandbox.network.allowedDomains | index(\"$d\")" "$TEMPLATE" >/dev/null 2>&1; then
    fail "T2: $d must NOT be in the tier-1 template (ADR-071 D2 -- compiler-owned)"
  else
    pass "T2: $d absent from the tier-1 template (ADR-071 D2)"
  fi
done

# D4 write surface + mktemp reality (macOS mktemp ignores TMPDIR, #157).
D4_WRITES=(
  "~/.claude" "/tmp" "/private/tmp" "/var/folders" "/private/var/folders"
  "~/.npm" "~/Library/Caches/ms-playwright"
)
for w in "${D4_WRITES[@]}"; do
  check_jq "allowWrite: $w" ".sandbox.filesystem.allowWrite | index(\"$w\")"
done

# D5: strictAllowlist must not ship in any project-scope template.
for t in "$REPO_ROOT"/config/settings.*.template.json; do
  if jq -e '.sandbox.network.strictAllowlist? // empty' "$t" >/dev/null 2>&1; then
    fail "strictAllowlist illegally present in $(basename "$t") (D5: user scope only)"
  else
    pass "no strictAllowlist in $(basename "$t")"
  fi
done

# ─────────────────────────────────────────────────────────────────────────
# T4-T7 (ADR-071) — config/vendor-hosts.json and its consumers.
# ─────────────────────────────────────────────────────────────────────────
VENDOR_HOSTS="$REPO_ROOT/config/vendor-hosts.json"
VENDOR_SCHEMA="$REPO_ROOT/schemas/vendor-hosts-schema.json"

# T4 — vendor-hosts.json validates against its schema (hand-rolled check;
# this repo has no jsonschema dependency, matching permissions-baseline.json's
# own precedent of an embedded structural validator rather than a library).
if [ -f "$VENDOR_HOSTS" ] && [ -f "$VENDOR_SCHEMA" ]; then
  T4_OUT="$(python3 - "$VENDOR_HOSTS" "$VENDOR_SCHEMA" <<'PYEOF'
import json, sys
hosts_path, schema_path = sys.argv[1:3]
with open(hosts_path, encoding="utf-8") as fh:
    data = json.load(fh)
with open(schema_path, encoding="utf-8") as fh:
    schema = json.load(fh)
errors = []
if not isinstance(data, dict):
    errors.append("root is not an object")
else:
    for req in schema.get("required", []):
        if req not in data:
            errors.append(f"missing required top-level key '{req}'")
    vendors = data.get("vendors")
    if not isinstance(vendors, list):
        errors.append("vendors is not an array")
    else:
        req_fields = schema["definitions"]["vendorEntry"]["required"]
        seen_hosts = set()
        runtime_count = 0
        for i, v in enumerate(vendors):
            if not isinstance(v, dict):
                errors.append(f"vendors[{i}] is not an object")
                continue
            for f in req_fields:
                if f not in v:
                    errors.append(f"vendors[{i}] missing required field '{f}'")
            host = v.get("host")
            if isinstance(host, str):
                if host != host.lower() or "://" in host or "*" in host or ":" in host:
                    errors.append(f"vendors[{i}] host '{host}' is not lowercase/scheme-free/glob-free/port-free")
                if host in seen_hosts:
                    errors.append(f"duplicate host '{host}'")
                seen_hosts.add(host)
            if v.get("is_runtime") is True:
                runtime_count += 1
        if runtime_count != 1:
            errors.append(f"expected exactly one is_runtime:true host, found {runtime_count}")
print("\n".join(errors))
PYEOF
)"
  if [ -z "$T4_OUT" ]; then
    pass "T4: config/vendor-hosts.json validates against its schema"
  else
    fail "T4: config/vendor-hosts.json schema violations: $T4_OUT"
  fi
else
  fail "T4: config/vendor-hosts.json or schemas/vendor-hosts-schema.json missing"
fi

# T5 — hygiene: cleared_at_sensitive:true REQUIRES non-null reviewed_on and
# non-empty terms_url (ADR-071 D5). A violation is a CI failure, not merely a
# "not cleared" runtime fallback -- this is the drift gate.
T5_OUT="$(jq -r '
  .vendors[]?
  | select(.cleared_at_sensitive == true)
  | select((.reviewed_on == null) or (.reviewed_on == "") or (.terms_url == null) or (.terms_url == ""))
  | .host
' "$VENDOR_HOSTS" 2>/dev/null)"
if [ -z "$T5_OUT" ]; then
  pass "T5: every cleared_at_sensitive:true host has a reviewed_on date and a terms_url"
else
  fail "T5: cleared_at_sensitive:true with missing reviewed_on/terms_url: $T5_OUT"
fi

# T5g (docs/plans/2026-08-11-gemini-paid-tier-precondition.md, Option A /
# A-D21) — drift gate: generativelanguage.googleapis.com must stay
# cleared_at_sensitive:false, and its `why` must name the reason (ADR-071
# D15 #6), so the flag cannot quietly flip back open. Changing this requires
# an ADR amendment that also changes this test -- which is the point.
#
# Factored into a helper parameterized on the vendor-hosts.json path (reviewer
# fix, NON-BLOCKING A9, 2026-08-11) so A9 below can re-run the SAME check
# logic against a mutated fixture and assert it actually trips, rather than
# merely asserting the fixture's field differs from the original.
t5g_check() {  # t5g_check <vendor-hosts-path>  -> prints PASS or "FAIL: <reason>"; returns 0/1
  local path="$1" cleared why
  cleared="$(jq -r '.vendors[]? | select(.host == "generativelanguage.googleapis.com") | .cleared_at_sensitive' "$path" 2>/dev/null)"
  why="$(jq -r '.vendors[]? | select(.host == "generativelanguage.googleapis.com") | .why' "$path" 2>/dev/null)"
  if [ "$cleared" != "false" ]; then
    echo "FAIL: generativelanguage.googleapis.com must be cleared_at_sensitive:false (got '$cleared')"
    return 1
  fi
  if ! printf '%s' "$why" | grep -qF "ADR-071 D15 #6"; then
    echo "FAIL: why does not cite ADR-071 D15 #6: $why"
    return 1
  fi
  echo "PASS"
  return 0
}

# NOTE: this file runs under `set -euo pipefail`, so every t5g_check call
# below is invoked as an `if` CONDITION (never a bare `$(...)` assignment) --
# an `if`'s condition is exempt from -e's "exit on first nonzero" rule, so a
# deliberately-failing call (A9) does not abort the whole suite.
if T5G_OUT="$(t5g_check "$VENDOR_HOSTS")"; then
  pass "T5g: generativelanguage.googleapis.com is cleared_at_sensitive:false and why cites ADR-071 D15 #6"
else
  fail "T5g: $T5G_OUT"
fi

# A9 (gemini-paid-tier-precondition Option A) — t5g_check must actually FAIL
# when run against a fixture with cleared_at_sensitive flipped to true, not
# just assert the fixture's field differs from the shipped file. This exercises
# the real check predicate, so a future regression to the predicate itself
# (e.g. checking the wrong file, or a broken condition) would be caught here,
# not just a broken fixture-writer.
T5G_FIXTURE="$(mktemp)"
jq '(.vendors[] | select(.host == "generativelanguage.googleapis.com") | .cleared_at_sensitive) |= true' \
  "$VENDOR_HOSTS" > "$T5G_FIXTURE"
if T5G_FIXTURE_OUT="$(t5g_check "$T5G_FIXTURE")"; then
  T5G_FIXTURE_RC=0
else
  T5G_FIXTURE_RC=$?
fi
if [ "$T5G_FIXTURE_RC" -ne 0 ] && [[ "$T5G_FIXTURE_OUT" == FAIL:*cleared_at_sensitive:false* ]]; then
  pass "A9: t5g_check actually fails on a fixture with cleared_at_sensitive flipped to true (drift gate has real teeth)"
else
  fail "A9: t5g_check did not fail as expected on the mutated fixture: rc=$T5G_FIXTURE_RC out='$T5G_FIXTURE_OUT'"
fi
# Negative control the other direction: t5g_check must still PASS on the real,
# unmutated file (proves the helper isn't just unconditionally failing).
if T5G_REAL_OUT="$(t5g_check "$VENDOR_HOSTS")"; then
  [ "$T5G_REAL_OUT" = "PASS" ] \
    && pass "A9: t5g_check still passes on the real, unmutated vendor-hosts.json" \
    || fail "A9: t5g_check unexpectedly failed on the real file: $T5G_REAL_OUT"
else
  fail "A9: t5g_check unexpectedly failed on the real file: $T5G_REAL_OUT"
fi
rm -f "$T5G_FIXTURE"

# T6 — no governed vendor host is reachable via an excludedCommands pattern
# (D15 #1: excludedCommands run entirely outside the sandbox).
T6_HOSTS="$(jq -r '.vendors[]?.host' "$VENDOR_HOSTS" 2>/dev/null)"
T6_FAIL=0
for t in "$REPO_ROOT"/config/settings.*.template.json "$REPO_ROOT/config/managed-settings.floor.json"; do
  [ -f "$t" ] || continue
  EXCL="$(jq -r '.sandbox.excludedCommands[]? // empty' "$t" 2>/dev/null)"
  [ -z "$EXCL" ] && continue
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    if printf '%s' "$EXCL" | grep -qF "$h"; then
      fail "T6: excludedCommands in $(basename "$t") mentions governed host $h"
      T6_FAIL=1
    fi
  done <<< "$T6_HOSTS"
done
[ "$T6_FAIL" -eq 0 ] && pass "T6: no governed vendor host is named in any excludedCommands list"

# T7 (D16) — drift test: every AI-vendor hostname literal in scripts/lib/*.sh
# must be declared in config/vendor-hosts.json. Scoped to the five vendor
# review helpers' known hostnames rather than a blind https:// scan, which
# would false-positive on api.github.com, registry.npmjs.org, etc.
KNOWN_AI_VENDOR_HOSTS=(
  api.openai.com generativelanguage.googleapis.com api.deepseek.com
  api.x.ai openrouter.ai
)
T7_FAIL=0
for h in "${KNOWN_AI_VENDOR_HOSTS[@]}"; do
  if grep -rq -- "$h" "$REPO_ROOT"/scripts/lib/*.sh 2>/dev/null; then
    if ! jq -e --arg h "$h" '[.vendors[]?.host] | index($h) != null' "$VENDOR_HOSTS" >/dev/null 2>&1; then
      fail "T7: $h appears in scripts/lib/*.sh but is not declared in config/vendor-hosts.json"
      T7_FAIL=1
    fi
  fi
done
[ "$T7_FAIL" -eq 0 ] && pass "T7: every AI-vendor host literal in scripts/lib/*.sh is declared in config/vendor-hosts.json"

# Repo dogfood block and template must not drift on the shared keys.
DOGFOOD="$REPO_ROOT/.claude/settings.json"
if [ -f "$DOGFOOD" ]; then
  for key in enabled failIfUnavailable autoAllowBashIfSandboxed; do
    a=$(jq -r ".sandbox.$key" "$TEMPLATE")
    b=$(jq -r ".sandbox.$key" "$DOGFOOD")
    if [ "$a" = "$b" ]; then pass "template/dogfood agree on $key"; else fail "template/dogfood drift on $key ($a vs $b)"; fi
  done
fi


# ─────────────────────────────────────────────────────────────────────────
# ADR-086 R1 — wiring assertions (T24-T26, T59). This is the file that
# already asserts over both settings.global.template.json (via $T6's loop
# below is over settings.*.template.json + the floor) and
# managed-settings.floor.json (T6), so the implementer's handoff places the
# self-update hooks' wiring checks here rather than a third test file.
# ─────────────────────────────────────────────────────────────────────────
GLOBAL_TEMPLATE="$REPO_ROOT/config/settings.global.template.json"
TIER0_MANIFEST="$REPO_ROOT/config/tier-manifests/tier-0.json"
FLOOR="$REPO_ROOT/config/managed-settings.floor.json"

# T24 — both hooks wired, correct events, timeout >= the 90s apply budget.
if jq -e '.hooks.SessionStart[0].hooks[] | select(.command=="~/.claude/hooks/stack-self-update.sh") | .timeout >= 90' "$GLOBAL_TEMPLATE" >/dev/null 2>&1; then
  pass "T24: settings.global.template.json wires stack-self-update.sh on SessionStart, timeout >= 90s"
else
  fail "T24: stack-self-update.sh missing/mistimed on SessionStart in settings.global.template.json"
fi
if jq -e '.hooks.UserPromptSubmit[0].hooks[] | select(.command=="~/.claude/hooks/stack-update-apply.sh") | .timeout >= 90' "$GLOBAL_TEMPLATE" >/dev/null 2>&1; then
  pass "T24: settings.global.template.json wires stack-update-apply.sh on UserPromptSubmit, timeout >= 90s"
else
  fail "T24: stack-update-apply.sh missing/mistimed on UserPromptSubmit in settings.global.template.json"
fi

# T25 — tier-0.json ships both hooks and smoke-tests both.
for hook in stack-self-update stack-update-apply; do
  if jq -e --arg f "hooks/${hook}.sh" '.files.global | map(.from) | index($f)' "$TIER0_MANIFEST" >/dev/null 2>&1; then
    pass "T25: tier-0.json ships hooks/${hook}.sh"
  else
    fail "T25: tier-0.json does not ship hooks/${hook}.sh"
  fi
  if jq -e --arg s "test -x ~/.claude/hooks/${hook}.sh" '.smoke_tests | index($s)' "$TIER0_MANIFEST" >/dev/null 2>&1; then
    pass "T25: tier-0.json smoke-tests hooks/${hook}.sh"
  else
    fail "T25: tier-0.json does not smoke-test hooks/${hook}.sh"
  fi
done

# T26 — hooks/hooks.json (the plugin distribution) wires NEITHER hook (D9):
# a plugin install has no install stamp, no pin, no source repo.
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
if grep -q "stack-self-update.sh\|stack-update-apply.sh" "$HOOKS_JSON" 2>/dev/null; then
  fail "T26: hooks/hooks.json unexpectedly references a stack self-update hook"
else
  pass "T26: hooks/hooks.json wires neither stack-self-update.sh nor stack-update-apply.sh"
fi

# T59 — the floor's five new denyWrite entries (D10 + D17), the original
# eleven still present, no blanket ~/.claude/state/**, no stack-consent entry.
for entry in \
  '~/.claude/.stack-install.json' '**/.claude/.stack-install.json' \
  '~/.claude/state/stack-update/**' '**/.claude/state/stack-update/**' \
  '~/.claude-*/state/stack-update/**'
do
  if jq -e --arg e "$entry" '.sandbox.filesystem.denyWrite | index($e)' "$FLOOR" >/dev/null 2>&1; then
    pass "T59: floor denyWrite includes $entry"
  else
    fail "T59: floor denyWrite missing $entry"
  fi
done
if jq -e '.sandbox.filesystem.denyWrite | index("~/.claude/state/**")' "$FLOOR" >/dev/null 2>&1; then
  fail "T59: floor denyWrite must NOT contain a blanket ~/.claude/state/** (would break peer features)"
else
  pass "T59: floor denyWrite has no blanket ~/.claude/state/**"
fi
if jq -e '.sandbox.filesystem.denyWrite[] | select(test("stack-consent"))' "$FLOOR" >/dev/null 2>&1; then
  fail "T59: floor denyWrite must NOT contain a state/stack-consent entry (the model must be able to write consent)"
else
  pass "T59: floor denyWrite has no state/stack-consent entry"
fi

exit $FAIL
