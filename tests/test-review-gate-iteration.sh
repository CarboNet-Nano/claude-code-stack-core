#!/usr/bin/env bash
# Tests for hooks/review-gate.sh's D12 iteration tolerance (ADR-087 D12).
# R1 subset of the 102-case plan, cases 55-61.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/review-gate.sh"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset CLAUDE_CONFIG_DIR

make_repo() {
  local mode="$1"
  local R="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$R/.claude"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  echo base > "$R/README.md"
  jq -nc --arg m "$mode" '{stack_tier:2, stack_version:"1.0.0", purpose:"test", created:"2026-01-01", guards:{review_gate:$m}}' > "$R/.claude/stack-config.json"
  git -C "$R" add -A; git -C "$R" commit -qm base >/dev/null
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  git -C "$R" checkout -q -b feat
  echo "$R"
}

repo_hash_of() {
  local realroot; realroot="$(git -C "$1" rev-parse --show-toplevel)"
  shasum -a 256 <<<"$realroot" | cut -c1-12
}

write_receipt() { # <repo_hash> <kind> <sha> <seat> <family> [overrides] [subject_path]
  local rh="$1" kind="$2" sha="$3" seat="$4" family="$5" overrides="${6:-.}" subject_path="${7:-subject.txt}"
  local dir="$HOME/.claude/state/attest/reviews/${rh}/${kind}/${sha}"
  mkdir -p "$dir"
  jq -nc --arg family "$family" --arg kind "$kind" --arg sha "$sha" --arg as_of "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg spath "$subject_path" '{
    schema:"stack-receipt/v1", kind:"review", writer:"review-receipt-mint.sh@1",
    as_of:$as_of, max_age_s:604800,
    subject:{kind:$kind, path:(if $kind=="artifact" then $spath else null end),
             content_sha:(if $kind=="artifact" then $sha else null end),
             patch_sha:(if $kind=="patch" then $sha else null end),
             base_commit:null, reviewed_head:null, repo_root:"/x", repo_hash:"y", mint_head_commit:"z"},
    verdict:"reviewed", reason:null, needs_human:false,
    evidence:{family:$family, http_status:200, prompt_bytes:1200, output_bytes:600, usage:{output_tokens:150}},
    error:null
  }' | jq -c "$overrides" > "$dir/${seat}.json"
}

dispatch_payload() {
  jq -nc --arg cwd "$1" --arg agent "$2" --arg prompt "$3" \
    '{cwd:$cwd, tool_name:"Agent", tool_input:{subagent_type:$agent, prompt:$prompt}}'
}
bash_payload() {
  jq -nc --arg cwd "$1" --arg cmd "$2" '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}}'
}
run_gate() { echo "$1" | bash "$HOOK" 2>/dev/null; }
decision_is_deny() { [[ "$1" == *'"permissionDecision":"deny"'* ]]; }

commit_artifact() { # <repo> <path> <content> -> content_sha of the resulting blob
  local R="$1" p="$2" c="$3"
  mkdir -p "$(dirname "$R/$p")"
  printf '%s\n' "$c" > "$R/$p"
  ( cd "$R" && git add -A && git commit -qm "add $p" >/dev/null )
  git -C "$R" hash-object -w --no-filters "$R/$p"
}

# ─── 55: fix a typo (delta low) -> passes via the ancestor hatch, no re-review
R55="$(make_repo on)"
SHA55_OLD="$(commit_artifact "$R55" "src/doit.sh" "#!/bin/bash
echo helo world")"
RH55="$(repo_hash_of "$R55")"
write_receipt "$RH55" artifact "$SHA55_OLD" reviewer openai . "src/doit.sh"
printf '#!/bin/bash\necho hello world\n' > "$R55/src/doit.sh"
( cd "$R55" && git add -A && git commit -qm "fix typo" >/dev/null )
OUT55="$(run_gate "$(dispatch_payload "$R55" implementer "Review-subject: src/doit.sh")")"
[[ -z "$OUT55" ]] && pass "55: typo-fix delta -> passes via the ancestor hatch" || fail "55: out='$OUT55'"

# ─── 56: the edit adds a function (delta med) -> deny subject_moved ───────
R56="$(make_repo on)"
SHA56_OLD="$(commit_artifact "$R56" "src/doit2.sh" "#!/bin/bash
echo v1")"
RH56="$(repo_hash_of "$R56")"
write_receipt "$RH56" artifact "$SHA56_OLD" reviewer openai . "src/doit2.sh"
cat > "$R56/src/doit2.sh" <<'EOF'
#!/bin/bash
echo v1
new_function() {
  echo "line one"
  echo "line two"
  echo "line three"
}
new_function
EOF
( cd "$R56" && git add -A && git commit -qm "add function" >/dev/null )
OUT56="$(run_gate "$(dispatch_payload "$R56" implementer "Review-subject: src/doit2.sh")")"
[[ "$OUT56" == *"reason=subject_moved"* ]] && pass "56: adds-a-function delta -> deny subject_moved (no hatch)" || fail "56: out='$OUT56'"

# ─── 57: no accumulation -- three successive low edits whose COMBINED delta
#     classifies med -> deny (a hop-by-hop implementation passes this wrongly)
R57="$(make_repo on)"
SHA57_OLD="$(commit_artifact "$R57" "src/accum.sh" "#!/bin/bash
echo line0")"
RH57="$(repo_hash_of "$R57")"
write_receipt "$RH57" artifact "$SHA57_OLD" reviewer openai . "src/accum.sh"
printf '#!/bin/bash\necho line0\necho line1\necho line2\n' > "$R57/src/accum.sh"
( cd "$R57" && git add -A && git commit -qm "edit1" >/dev/null )
printf '#!/bin/bash\necho line0\necho line1\necho line2\necho line3\necho line4\n' > "$R57/src/accum.sh"
( cd "$R57" && git add -A && git commit -qm "edit2" >/dev/null )
printf '#!/bin/bash\necho line0\necho line1\necho line2\necho line3\necho line4\necho line5\necho line6\n' > "$R57/src/accum.sh"
( cd "$R57" && git add -A && git commit -qm "edit3" >/dev/null )
OUT57="$(run_gate "$(dispatch_payload "$R57" implementer "Review-subject: src/accum.sh")")"
[[ "$OUT57" == *"reason=subject_moved"* ]] && pass "57: combined delta (from the ORIGINAL reviewed point) exceeds the low threshold -> deny, no accumulation loophole" || fail "57: out='$OUT57'"

# ─── 58: G2 -- review a branch, add a docs-only commit -> passes. Add a
#     source commit -> deny. ────────────────────────────────────────────────
STUB="$REPO_ROOT/tests/fixtures/panel-review-stub-vendor.sh"
BIGCTX="$(printf '%*s' 1200 '' | tr ' ' 'a')"
R58="$(make_repo on)"
mkdir -p "$R58/src"; echo "feature v1" > "$R58/src/feat.sh"
( cd "$R58" && git add -A && git commit -qm "feature" >/dev/null )
BASE58="$(cd "$R58" && bash -c "source '$REPO_ROOT/scripts/lib/review-router.sh'; rr_default_base")"
PR58_OUT="$(cd "$R58" && echo "$BIGCTX" | PR_GEMINI_LIB="$STUB" PR_OPENAI_LIB="$STUB" STUB_RC=0 \
  bash "$REPO_ROOT/scripts/panel-review.sh" reviewer --diff "${BASE58}..HEAD")"
MINT58="$(jq -nc --arg cwd "$R58" --arg cmd "bash scripts/panel-review.sh reviewer --diff x" --arg out "$PR58_OUT" \
  '{cwd:$cwd, tool_name:"Bash", tool_input:{command:$cmd}, tool_response:$out}')"
echo "$MINT58" | bash "$REPO_ROOT/hooks/review-receipt-mint.sh" >/dev/null 2>&1

echo "more docs" >> "$R58/README.md"
( cd "$R58" && git add -A && git commit -qm "docs only" >/dev/null )
OUT58A="$(run_gate "$(bash_payload "$R58" "gh pr create --title x --body y")")"
[[ -z "$OUT58A" ]] && pass "58a: docs-only commit added after review -> still passes (low delta hatch)" || fail "58a: out='$OUT58A'"

echo "echo more-source-code" >> "$R58/src/feat.sh"
( cd "$R58" && git add -A && git commit -qm "source change" >/dev/null )
OUT58B="$(run_gate "$(bash_payload "$R58" "gh pr create --title x --body y")")"
decision_is_deny "$OUT58B" && pass "58b: a source commit added after review -> deny (delta no longer low)" || fail "58b: out='$OUT58B'"

# ─── 59: ancestor blob pruned -> no hatch, deny no_receipt ────────────────
R59="$(make_repo on)"
SHA59_OLD="$(commit_artifact "$R59" "src/pruneme.sh" "#!/bin/bash
echo will-be-pruned")"
RH59="$(repo_hash_of "$R59")"
write_receipt "$RH59" artifact "$SHA59_OLD" reviewer openai . "src/pruneme.sh"
# Manually delete the loose object to simulate a gc'd blob (test-only; real
# git gc has its own reachability heuristics this test does not depend on).
OBJ_PATH="$R59/.git/objects/${SHA59_OLD:0:2}/${SHA59_OLD:2}"
rm -f "$OBJ_PATH"
printf '#!/bin/bash\necho tiny-edit\n' > "$R59/src/pruneme.sh"
( cd "$R59" && git add -A && git commit -qm "tiny edit" >/dev/null )
OUT59="$(run_gate "$(dispatch_payload "$R59" implementer "Review-subject: src/pruneme.sh")")"
[[ "$OUT59" == *"reason=no_receipt"* || "$OUT59" == *"reason=subject_moved"* ]] \
  && pass "59: pruned ancestor blob -> no hatch (denies, fail-closed)" || fail "59: out='$OUT59'"

# ─── 60: reviewed_head rebased away -> deny ────────────────────────────────
R60="$(make_repo on)"
mkdir -p "$R60/src"; echo "feature v1" > "$R60/src/rb.sh"
( cd "$R60" && git add -A && git commit -qm "feature" >/dev/null )
ORPHAN_HEAD="$(git -C "$R60" rev-parse HEAD)"
BASE60_SHA="$(git -C "$R60" rev-parse origin/main)"
PATCH60_SHA="$(cd "$R60" && bash -c "source '$REPO_ROOT/lib/receipt.sh'; rcpt_patch_sha '$R60' '$BASE60_SHA' '$ORPHAN_HEAD'")"
RH60="$(repo_hash_of "$R60")"
mkdir -p "$HOME/.claude/state/attest/reviews/${RH60}/patch/${PATCH60_SHA}"
jq -nc --arg as_of "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rh "$ORPHAN_HEAD" --arg bc "$BASE60_SHA" '{
  schema:"stack-receipt/v1", kind:"review", writer:"review-receipt-mint.sh@1",
  as_of:$as_of, max_age_s:604800,
  subject:{kind:"patch", path:null, content_sha:null, patch_sha:"'"$PATCH60_SHA"'", base_commit:$bc, reviewed_head:$rh, repo_root:"/x", repo_hash:"y", mint_head_commit:"z"},
  verdict:"reviewed", reason:null, needs_human:false,
  evidence:{family:"openai", http_status:200, prompt_bytes:1200, output_bytes:600, usage:{output_tokens:150}},
  error:null
}' > "$HOME/.claude/state/attest/reviews/${RH60}/patch/${PATCH60_SHA}/reviewer.json"
# "Rebase away" by resetting the branch to a NEW commit that does not descend
# from ORPHAN_HEAD -- merge-base --is-ancestor will fail.
git -C "$R60" reset -q --hard origin/main
mkdir -p "$R60/src"
echo "different work" > "$R60/src/other.sh"
( cd "$R60" && git add -A && git commit -qm "rebased history" >/dev/null )
OUT60="$(run_gate "$(bash_payload "$R60" "gh pr create --title x --body y")")"
decision_is_deny "$OUT60" && pass "60: reviewed_head no longer an ancestor of HEAD -> deny" || fail "60: out='$OUT60'"

# ─── 61: every hatch pass writes event:"review_gate_ancestor_pass" ────────
GATE_LOG="$HOME/.claude/logs/review-gate.jsonl"
grep -q '"event":"review_gate_ancestor_pass"' "$GATE_LOG" 2>/dev/null \
  && pass "61a: at least one ancestor-pass event logged (from case 55/58a)" || fail "61a: no ancestor-pass event found"
LAST_HATCH="$(grep '"event":"review_gate_ancestor_pass"' "$GATE_LOG" 2>/dev/null | tail -1)"
echo "$LAST_HATCH" | jq -e '.kind and (has("path") or has("reviewed_head"))' >/dev/null 2>&1 \
  && pass "61b: hatch-pass row carries the delta identity (path or reviewed_head)" || fail "61b: row='$LAST_HATCH'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
