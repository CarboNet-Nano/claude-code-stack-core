#!/usr/bin/env bash
# Tests for scripts/sweep-install.sh — the operator-path installer that
# renders templates/workflows/sweep.yml into an existing target repo
# under the header's substitution contract: pin {{STACK_REF}}, refuse to
# write if any {{...}} token survives.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/scripts/sweep-install.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$INSTALL" ] || { echo "FATAL: $INSTALL not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-install-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

SHA="dc6d4d4ac18c8ad38939f9efc4df72055edb6290"

new_target() {
  local r="$TMP/target-$1"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main && echo x > .gitignore )
  echo "$r"
}

t_installs_pinned_workflow() {
  local r; r="$(new_target pinned)"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  local ec=$?
  [[ "$ec" == "0" && -f "$r/.github/workflows/sweep.yml" ]] \
    && grep -q "ref: \"$SHA\"" "$r/.github/workflows/sweep.yml" \
    && ! grep -qE '\{\{[A-Za-z_]+\}\}' "$r/.github/workflows/sweep.yml" \
    && pass "install writes sweep.yml pinned to --ref with no tokens left" \
    || fail "install pinned workflow (ec=$ec)"
}

t_refuses_short_ref() {
  local r; r="$(new_target shortref)"
  bash "$INSTALL" --repo "$r" --ref main >/dev/null 2>&1
  [[ $? -ne 0 && ! -f "$r/.github/workflows/sweep.yml" ]] \
    && pass "a non-40-hex --ref is refused before anything is written" \
    || fail "short ref accepted"
}

t_fail_loud_on_leftover_token() {
  # A doctored stack root whose template carries a second, unknown token.
  local sr="$TMP/stackroot-doctored"
  mkdir -p "$sr/templates/workflows/snippets"
  { cat "$REPO_ROOT/templates/workflows/sweep.yml"; echo "# extra: {{OTHER_TOKEN}}"; } \
    > "$sr/templates/workflows/sweep.yml"
  cp "$REPO_ROOT/templates/workflows/snippets/run-tests-sweep-liveness.yml" "$sr/templates/workflows/snippets/"
  local r; r="$(new_target leftover)"
  local err; err="$(SWEEP_INSTALL_STACK_ROOT="$sr" bash "$INSTALL" --repo "$r" --ref "$SHA" 2>&1 >/dev/null)"
  local ec=$?
  [[ "$ec" -ne 0 && ! -f "$r/.github/workflows/sweep.yml" ]] \
    && grep -q "OTHER_TOKEN" <<<"$err" \
    && pass "fail-loud: a surviving {{...}} token refuses the whole install, names the token, writes nothing" \
    || fail "fail-loud leftover token (ec=$ec err=$err)"
}

t_second_run_is_noop() {
  local r; r="$(new_target idem)"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  local sum1; sum1="$(cksum "$r/.github/workflows/sweep.yml")"
  local out; out="$(bash "$INSTALL" --repo "$r" --ref "$SHA" 2>&1)"
  local ec=$? sum2; sum2="$(cksum "$r/.github/workflows/sweep.yml")"
  [[ "$ec" == "0" && "$sum1" == "$sum2" ]] && grep -q "unchanged" <<<"$out" \
    && pass "re-running at the same pin is a no-op" \
    || fail "idempotent re-run (ec=$ec)"
}

t_differing_file_needs_force() {
  local r; r="$(new_target force)"
  mkdir -p "$r/.github/workflows"; echo "something else" > "$r/.github/workflows/sweep.yml"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  local ec=$?
  local kept; kept="$(cat "$r/.github/workflows/sweep.yml")"
  bash "$INSTALL" --repo "$r" --ref "$SHA" --force >/dev/null 2>&1
  local ec2=$?
  [[ "$ec" -ne 0 && "$kept" == "something else" && "$ec2" == "0" ]] \
    && grep -q "ref: \"$SHA\"" "$r/.github/workflows/sweep.yml" \
    && pass "a differing existing sweep.yml refuses without --force and overwrites with it" \
    || fail "force semantics (ec=$ec ec2=$ec2)"
}

t_config_scaffolded_once_never_clobbered() {
  local r; r="$(new_target config)"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  jq -e '.schema == "sweep-config/v1" and .mode == "observe"' "$r/.claude/sweep.config.json" >/dev/null \
    || { fail "config scaffold shape"; return; }
  echo '{"schema":"sweep-config/v1","mode":"observe","check_modes":{},"surfaces":{},"families":{},"skips":[{"check_id":"E1","reason":"custom"}]}' \
    > "$r/.claude/sweep.config.json"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  jq -e '.skips[0].reason == "custom"' "$r/.claude/sweep.config.json" >/dev/null \
    && pass "sweep.config.json scaffolded once, an existing config is never clobbered" \
    || fail "existing config clobbered"
}

t_gitignore_line_added_once() {
  local r; r="$(new_target gitignore)"
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  bash "$INSTALL" --repo "$r" --ref "$SHA" >/dev/null 2>&1
  local n; n="$(grep -cxF '.claude/sweep/runs.jsonl' "$r/.gitignore")"
  [[ "$n" == "1" ]] \
    && pass "gitignore runs.jsonl line added exactly once across reruns" \
    || fail "gitignore line count $n"
}

t_snippet_printed_rendered() {
  local r; r="$(new_target snippet)"
  local out; out="$(bash "$INSTALL" --repo "$r" --ref "$SHA" 2>&1)"
  grep -q "sweep-liveness:" <<<"$out" && grep -q "ref: \"$SHA\"" <<<"$out" \
    && ! grep -qE '\{\{[A-Za-z_]+\}\}' <<<"$out" \
    && pass "the rendered liveness snippet is printed, pinned, token-free" \
    || fail "snippet render/print"
}

t_installs_pinned_workflow
t_refuses_short_ref
t_fail_loud_on_leftover_token
t_second_run_is_noop
# --gate (queue #241) mutates GitHub repo settings, which a hermetic test
# cannot exercise; what it CAN pin down is the refusal edge: a repo with no
# origin remote must die on the slug derivation, after the local install
# steps but before any gh mutation is attempted.
t_gate_without_remote_refuses() {
  command -v gh >/dev/null 2>&1 || { pass "gate refusal (skipped: no gh on this machine)"; return; }
  local r out ec; r="$(new_target gate-no-remote)"
  out="$(bash "$INSTALL" --repo "$r" --ref "$SHA" --gate 2>&1)"; ec=$?
  [[ "$ec" -ne 0 ]] && grep -q "no origin remote" <<<"$out" \
    && pass "--gate with no origin remote refuses at slug derivation" \
    || fail "gate refusal (ec=$ec out=$out)"
}

t_differing_file_needs_force
t_config_scaffolded_once_never_clobbered
t_gitignore_line_added_once
t_snippet_printed_rendered
t_gate_without_remote_refuses

echo "----"
echo "test-sweep-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
