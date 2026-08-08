#!/usr/bin/env bash
# Tests for scripts/lib/review-router.sh (ADR-025).
# Covers stakes classification (path / domain-mode / sensitivity / force),
# tier selection + model resolution order (env > config > default), the diff
# scope invariant, and the route logger. No network or model calls are made.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/review-router.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# Deterministic local-model availability: existing routine assertions assume the
# local engine is usable (env-independent — CI has no ollama). Section 10
# overrides this per-test to exercise the cloud fallback.
export REVIEW_ASSUME_LOCAL=1

# --- a throwaway git repo with a base commit on main + a feature branch -------
# build_repo <changed_file_path> : commits base, then a feature commit changing
# the given path; leaves HEAD on the feature branch. Echoes nothing.
build_repo() {
  local changed="$1"
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  (
    cd "$R"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    echo base > README.md
    git add -A; git commit -qm base
    git checkout -q -b feat
    mkdir -p "$(dirname "$changed")"
    echo change > "$changed"
    git add -A; git commit -qm feat
  )
  echo "$R"
}

# classify <repo> [env assignments...] -> echoes "high"/"routine"
classify() {
  local R="$1"; shift
  ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_classify_stakes main HEAD" ) | awk '{print $1}'
}

# --- 1. classification: routine path ----------------------------------------
R="$(build_repo docs/notes.md)"
assert_eq "doc change -> routine" "routine" "$(classify "$R")"

R="$(build_repo src/utils/formatter.ts)"
assert_eq "plain refactor -> routine" "routine" "$(classify "$R")"

# --- 2. classification: high-stakes paths -----------------------------------
R="$(build_repo src/auth/login.ts)"
assert_eq "auth path -> high" "high" "$(classify "$R")"

R="$(build_repo supabase/migrations/0007_add_rls.sql)"
assert_eq "migration/.sql path -> high" "high" "$(classify "$R")"

R="$(build_repo services/billing/charge.ts)"
assert_eq "billing path -> high" "high" "$(classify "$R")"

R="$(build_repo .env.production)"
assert_eq "dotenv path -> high" "high" "$(classify "$R")"

# --- 3. overrides -----------------------------------------------------------
R="$(build_repo docs/notes.md)"
assert_eq "REVIEW_TIER_FORCE=high beats routine path" "high" "$(classify "$R" REVIEW_TIER_FORCE=high)"
assert_eq "STACK_DOMAIN_MODE=security -> high" "high" "$(classify "$R" STACK_DOMAIN_MODE=security)"
assert_eq "STACK_DOMAIN_MODE=schema-migration -> high" "high" "$(classify "$R" STACK_DOMAIN_MODE=schema-migration)"
assert_eq "STACK_SENSITIVITY=high -> high" "high" "$(classify "$R" STACK_SENSITIVITY=high)"
assert_eq "STACK_DOMAIN_MODE=frontend stays routine" "routine" "$(classify "$R" STACK_DOMAIN_MODE=frontend)"

# --- 4. tier selection vars (high) ------------------------------------------
R="$(build_repo src/auth/login.ts)"
eval_vars() { # <repo> [env...] -> prints "ENGINE|MODEL|EFFORT|SCOPE|ESC_MODEL"
  local R="$1"; shift
  ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_run x main HEAD >/dev/null; echo \"\$RR_ENGINE|\$RR_MODEL|\$RR_EFFORT|\$RR_SCOPE|\$RR_ESC_MODEL\"" )
}
assert_eq "high tier = codex/gpt-5.5/high/diff" "codex|gpt-5.5|high|diff|" "$(eval_vars "$R")"

# --- 5. tier selection vars (routine) + escalation --------------------------
R="$(build_repo docs/notes.md)"
assert_eq "routine tier = local/qwen + gpt-5.4 escalation, diff scope" \
  "local|qwen2.5-coder:32b|n/a|diff|gpt-5.4" "$(eval_vars "$R")"

# --- 6. model resolution order: env > config > default ----------------------
# config file with a custom routine model; env should still win over it.
CFG="$TMP/custom-routing.json"
cat > "$CFG" <<'JSON'
{ "review_tiers": { "routine": { "model": "qwen2.5-coder:72b", "escalation_model": "gpt-5.4" },
                    "high": { "model": "gpt-5.5", "effort": "high" } } }
JSON
R="$(build_repo docs/notes.md)"
assert_eq "config repoints routine model" \
  "local|qwen2.5-coder:72b|n/a|diff|gpt-5.4" "$(eval_vars "$R" RR_CONFIG="$CFG")"
assert_eq "env beats config for routine model" \
  "local|kimi-k2|n/a|diff|gpt-5.4" "$(eval_vars "$R" RR_CONFIG="$CFG" REVIEW_ROUTINE_MODEL=kimi-k2)"

# --- 7. route logger appends one review_route row ---------------------------
rm -f "$LOG"
( cd "$R"; bash -c "source '$LIB'; rr_log_route reviewer routine local qwen2.5-coder:32b diff no" )
if [[ -f "$LOG" ]]; then
  n="$(grep -c '"event":"review_route"' "$LOG" 2>/dev/null || echo 0)"
  assert_eq "rr_log_route wrote 1 review_route row" "1" "$n"
  ev="$(jq -r '.stakes' "$LOG" 2>/dev/null)"
  assert_eq "logged stakes field" "routine" "$ev"
else
  fail "rr_log_route wrote 1 review_route row (no log file)"
fi

# --- 8. cross-family invariant: no tier resolves to a Claude/anthropic model -
R="$(build_repo src/auth/login.ts)"
hi="$(eval_vars "$R")"
R2="$(build_repo docs/notes.md)"
lo="$(eval_vars "$R2")"
if echo "$hi$lo" | grep -qiE 'claude|anthropic|opus|sonnet|haiku|fable'; then
  fail "cross-family invariant (a tier routed to a Claude model)"
else
  pass "cross-family invariant (no tier routes to a Claude model)"
fi

# --- 9. ADR-025 review hardening: fail-safe + cross-family enforcement -------

# 9a. expanded regex covers crypto/auth paths the original list missed
for p in src/lib/jwt.ts infra/kms/keyring.tf wallet/seed_phrase.ts auth/private_key.pem config/tls/cert.pem services/hmac/verify.ts; do
  R="$(build_repo "$p")"
  assert_eq "expanded regex: $p -> high" "high" "$(classify "$R")"
done

# 9b. invalid REVIEW_TIER_FORCE is IGNORED — must NOT downgrade a high-stakes diff
R="$(build_repo src/auth/login.ts)"
assert_eq "REVIEW_TIER_FORCE typo ignored -> still high" "high" "$(classify "$R" REVIEW_TIER_FORCE=hgih)"
assert_eq "REVIEW_TIER_FORCE=routine honored (by design)" "routine" "$(classify "$R" REVIEW_TIER_FORCE=routine)"

# 9c. git fail-safe: an unresolvable ref defaults HIGH, never silent routine
R="$(build_repo docs/notes.md)"
gb="$( cd "$R"; bash -c "source '$LIB'; rr_classify_stakes nonexistent-ref HEAD" | awk '{print $1}' )"
assert_eq "bad base ref -> high (fail-safe)" "high" "$gb"

# 9d. ADR-011 enforced at resolution: a Claude model via env OR config is refused
resolve() { ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_resolve REVIEW_HIGH_MODEL '.review_tiers.high.model' gpt-5.5 2>/dev/null" ); }
assert_eq "env Claude model refused -> default" "gpt-5.5" "$(resolve REVIEW_HIGH_MODEL=claude-opus-4-8)"
CFGC="$TMP/claude-routing.json"
echo '{ "review_tiers": { "high": { "model": "claude-sonnet-4-6" } } }' > "$CFGC"
assert_eq "config Claude model refused -> default" "gpt-5.5" "$(resolve RR_CONFIG="$CFGC")"
assert_eq "non-Claude override still passes through" "gpt-5.4" "$(resolve REVIEW_HIGH_MODEL=gpt-5.4)"

# --- 10. cloud-safety: local engine falls back to escalation when ollama absent
R="$(build_repo docs/notes.md)"
assert_eq "no local model -> routine falls back to codex/gpt-5.4" \
  "codex|gpt-5.4|medium|diff|" "$(eval_vars "$R" REVIEW_ASSUME_NO_LOCAL=1)"
fb="$( cd "$R"; env REVIEW_ASSUME_NO_LOCAL=1 bash -c "source '$LIB'; rr_run x main HEAD >/dev/null; echo \$RR_LOCAL_FALLBACK" )"
case "$fb" in yes*) pass "RR_LOCAL_FALLBACK flag set when local unavailable" ;; *) fail "RR_LOCAL_FALLBACK flag set when local unavailable (got '$fb')" ;; esac
assert_eq "local available -> stays local (no fallback)" \
  "local|qwen2.5-coder:32b|n/a|diff|gpt-5.4" "$(eval_vars "$R" REVIEW_ASSUME_LOCAL=1)"
R="$(build_repo src/auth/login.ts)"
assert_eq "high tier unaffected by local availability" \
  "codex|gpt-5.5|high|diff|" "$(eval_vars "$R" REVIEW_ASSUME_NO_LOCAL=1)"

# --- 10b. tier gate: local models are Tier-5-only hardware (2026-07-29 incident —
# a Tier-4 machine loading qwen2.5-coder:32b for a routine review crashed it).
# Below Tier 5, `rr_local_available` must refuse even when ollama IS present and
# has the model — no REVIEW_ASSUME_LOCAL/NO_LOCAL override set (that's the only
# explicit user opt-in path, tested above/below).
R="$(build_repo docs/notes.md)"
mkdir -p "$R/.claude"
echo '{ "stack_tier": 4 }' > "$R/.claude/stack-config.json"
FAKE_OLLAMA="$TMP/fake-ollama-bin"
mkdir -p "$FAKE_OLLAMA"
cat > "$FAKE_OLLAMA/ollama" <<'FAKEOLLAMA'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && echo "qwen2.5-coder:32b"
exit 0
FAKEOLLAMA
chmod +x "$FAKE_OLLAMA/ollama"
tier4_route="$( cd "$R"; env -u REVIEW_ASSUME_LOCAL -u REVIEW_ASSUME_NO_LOCAL PATH="$FAKE_OLLAMA:$PATH" bash -c "source '$LIB'; rr_run x main HEAD >/dev/null 2>&1; echo \"\$RR_ENGINE|\$RR_MODEL\"" )"
assert_eq "Tier 4 + ollama present -> still refuses local (no explicit opt-in)" \
  "codex|gpt-5.4" "$tier4_route"

echo '{ "stack_tier": 5 }' > "$R/.claude/stack-config.json"
tier5_route="$( cd "$R"; env -u REVIEW_ASSUME_LOCAL -u REVIEW_ASSUME_NO_LOCAL PATH="$FAKE_OLLAMA:$PATH" bash -c "source '$LIB'; rr_run x main HEAD >/dev/null 2>&1; echo \"\$RR_ENGINE|\$RR_MODEL\"" )"
assert_eq "Tier 5 + ollama present -> local allowed without override" \
  "local|qwen2.5-coder:32b" "$tier5_route"

# --- 11. shell-portability: rr_run must populate RR_ENGINE/RR_MODEL under the
# shell the review subagents actually source this from (zsh on macOS), not only
# bash. Regression guard for the ${!name} bad-substitution bug — rr_resolve
# raised "bad substitution" under zsh and returned an empty engine/model, so
# callers fell back to a hardcoded rung. Every other test forces `bash -c`,
# which is exactly why the bug went undetected.
R="$(build_repo docs/notes.md)"
run_vars_under() { # <shell> <repo> -> "ENGINE|MODEL" ('' if sourcing/resolve fails)
  local shell="$1" repo="$2"
  ( cd "$repo"; REVIEW_ASSUME_LOCAL=1 "$shell" -c "source '$LIB'; rr_run x main HEAD >/dev/null 2>&1; echo \"\$RR_ENGINE|\$RR_MODEL\"" 2>/dev/null )
}
for shell in bash zsh; do
  if command -v "$shell" >/dev/null 2>&1; then
    assert_eq "routine route populates engine/model under $shell" \
      "local|qwen2.5-coder:32b" "$(run_vars_under "$shell" "$R")"
  else
    echo "SKIP: $shell not on PATH (portability check)"
  fi
done

# --- 12. working-tree scan: uncommitted/untracked files count toward stakes --
# Regression for 2026-07-11: rr_classify_stakes read only the commit-range diff,
# so reviews of uncommitted work classified "routine" against an EMPTY diff even
# when high-stakes files (seed/migration) sat untracked in the working tree.

# build_clean_repo : single commit on main, HEAD on main, nothing uncommitted —
# so `rr_classify_stakes main HEAD` sees an empty commit-range diff.
build_clean_repo() {
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  (
    cd "$R"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    echo base > README.md
    git add -A; git commit -qm base
  )
  echo "$R"
}

# 12a. the exact repro: empty range + untracked migration file -> high
R="$(build_clean_repo)"
mkdir -p "$R/supabase/migrations"; echo x > "$R/supabase/migrations/0009_seed.sql"
assert_eq "empty diff + untracked migration -> high" "high" "$(classify "$R")"
c="$( cd "$R"; bash -c "source '$LIB'; rr_classify_stakes main HEAD" )"
case "$c" in
  "high risk-path (uncommitted):"*) pass "reason marks the hit as uncommitted" ;;
  *) fail "reason marks the hit as uncommitted (got '$c')" ;;
esac

# 12b. empty range + untracked ROUTINE file -> stays routine (no over-flag)
R="$(build_clean_repo)"
echo x > "$R/notes.md"
assert_eq "empty diff + untracked routine file -> routine" "routine" "$(classify "$R")"

# 12c. tracked high-stakes file modified but uncommitted -> high
R="$(build_clean_repo)"
mkdir -p "$R/src/auth"; echo v1 > "$R/src/auth/login.ts"
( cd "$R"; git add -A; git commit -qm add-auth )
echo v2 > "$R/src/auth/login.ts"
assert_eq "modified tracked auth file (uncommitted) -> high" "high" "$(classify "$R")"

# 12d. always-scan: routine COMMITTED diff + risky UNTRACKED file -> high
R="$(build_repo docs/notes.md)"
echo x > "$R/secrets_helper.ts"
assert_eq "routine committed diff + untracked risky file -> high" "high" "$(classify "$R")"

# 12e. -uall: risky file INSIDE an untracked dir must be seen (porcelain
# without -uall collapses it to 'dir/' and the regex would miss it)
R="$(build_clean_repo)"
mkdir -p "$R/newmod"; echo x > "$R/newmod/payment.ts"
assert_eq "risky file inside untracked dir -> high (-uall)" "high" "$(classify "$R")"

# 12f. head != current checkout -> working tree is unrelated, NOT scanned
R="$(build_repo docs/notes.md)"   # HEAD is on feat
echo x > "$R/wallet_seed.ts"
notcur="$( cd "$R"; bash -c "source '$LIB'; rr_classify_stakes main main" | awk '{print $1}' )"
assert_eq "head != current checkout ignores working tree" "routine" "$notcur"

# --- 13. machine-wide ~/.claude/config/model-routing.json fallback rung -----
# Regression guard for the propagation gap discovered 2026-08-04: a repo with
# no config/model-routing.json of its own must still pick up a machine-wide
# default from ~/.claude, not silently skip straight to the hardcoded default.
resolve_high() { # <repo> [env...] -> resolved review_tiers.high.model
  local R="$1"; shift
  ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_resolve REVIEW_HIGH_MODEL '.review_tiers.high.model' gpt-5.5 2>/dev/null" )
}

MACHINE_CFG_DIR="$HOME/.claude/config"
MACHINE_CFG="$MACHINE_CFG_DIR/model-routing.json"
mkdir -p "$MACHINE_CFG_DIR"

# 13a. no repo-local config, no RR_CONFIG -> machine-wide file wins over default
echo '{ "review_tiers": { "high": { "model": "gpt-5.6-terra" } } }' > "$MACHINE_CFG"
R="$(build_repo docs/notes.md)"
assert_eq "no repo-local config -> falls back to ~/.claude machine-wide default" \
  "gpt-5.6-terra" "$(resolve_high "$R")"

# 13b. repo-local config present too -> repo-local still wins (override beats
# machine-wide, per the documented resolution order)
CFG_LOCAL="$TMP/repo-local-routing.json"
echo '{ "review_tiers": { "high": { "model": "gpt-5.4" } } }' > "$CFG_LOCAL"
mkdir -p "$R/config"; cp "$CFG_LOCAL" "$R/config/model-routing.json"
( cd "$R" && git add -A && git commit -qm "add repo-local config" ) >/dev/null
assert_eq "repo-local config wins over machine-wide default" \
  "gpt-5.4" "$(resolve_high "$R")"

# 13c. neither repo-local nor machine-wide -> hardcoded default still wins
rm -f "$MACHINE_CFG"
R2="$(build_repo docs/notes.md)"
assert_eq "no repo-local, no machine-wide -> hardcoded default" \
  "gpt-5.5" "$(resolve_high "$R2")"

echo "----------------------------------------"
echo "review-router: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
