#!/usr/bin/env bash
# Tests for ADR-045 (user-docs-writer roster agent + tools/user-docs/ runner +
# /user-docs and /user-docs-refresh skills), scope (c): the runner is fully
# built, but `reset-required` and `manual` docs-tests are REFUSED
# (NEEDS-RECAPTURE) rather than auto-replayed.
#
# Case ids map 1:1 to the architect handoff's 31-item test plan.
#
# EXECUTION REALITY — read this before trusting a green run.
# The plan's gating case (T1) and most of its authoring/freshness cases require
# things a static shell suite cannot produce: a live `claude -p` session that can
# dispatch a subagent, a live Playwright MCP server, a running dev server, and a
# vision model. Those cases are reported here as `NOT-EXECUTED` with the exact
# missing precondition, never silently skipped and never counted as passes. The
# final summary prints the NOT-EXECUTED count separately from PASS/FAIL, so a
# clean run cannot be mistaken for full plan coverage.
#
# What IS genuinely executed: every runner enforcement gate (T14–T18 and the
# exit-code precedence), the static half of T1 that actually discriminates the
# F2 hallucinated-tool-call failure mode, and every repo-hygiene/provenance case
# (T22, T27–T31). The runner's refusal gates are decidable offline BY DESIGN —
# docsMeta is parsed statically and no browser is launched for a spec the runner
# will refuse — which is what makes them testable here at all.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$REPO_ROOT/agents/user-docs-writer.md"
SKILL="$REPO_ROOT/skills/user-docs/SKILL.md"
REFRESH="$REPO_ROOT/skills/user-docs-refresh/SKILL.md"
RUNNER="$REPO_ROOT/tools/user-docs"
FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
ADR045="$REPO_ROOT/docs/ADRs/045-user-docs-writer-roster-and-runner.md"
ADR003="$REPO_ROOT/docs/ADRs/003-21-subagents.md"
TIER3="$REPO_ROOT/config/tier-manifests/tier-3.json"
# ADR-064: the subagent roster ships from tier-0, so a tier-3 install picks up
# agents/*.md through the extends chain, not from tier-3's own file list.
TIER0="$REPO_ROOT/config/tier-manifests/tier-0.json"
REGISTRY="$REPO_ROOT/config/capability-registry.json"

PASS=0
FAIL=0
NOTRUN=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
notrun() { echo "NOT-EXECUTED: $1 — requires $2"; NOTRUN=$((NOTRUN+1)); }

assert_eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: '$2' | actual: '$3')"; fi; }
assert_file() { if [[ -f "$2" ]]; then pass "$1"; else fail "$1 (missing file: $2)"; fi; }
assert_grep() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (not found in $2: '$3')"; fi; }
assert_nogrep() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1 (unexpectedly found in $2: '$3')"; else pass "$1"; fi; }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# GATING — T1 / T2
# ---------------------------------------------------------------------------
echo "--- T1 (browser grant) ---"
notrun "T1 live half: dispatch user-docs-writer and assert a real browser tool call succeeds (tool_uses>=1, no <invoke> emitted as literal text)" \
       "a live claude -p session with a Playwright MCP server and a reachable app"

# T1's static half. This is not a formality: F2 (docs/runbooks/stack-cloud-overrides.md)
# was a malformed frontmatter block resolving to an EMPTY toolset, after which
# agents hallucinated tool calls as text. The three checks below are exactly the
# properties that distinguish a browser-inheriting agent file from that failure.
assert_file "T1a: agents/user-docs-writer.md exists" "$AGENT"
assert_eq   "T1b: agent declares NO tools: line (D3 — MCP names cannot pass the model-pins regex, so omission is the only shape that inherits a browser)" \
            "0" "$(grep -c '^tools:' "$AGENT")"
assert_eq   "T1c: frontmatter name matches the filename stem (the registry generator drops files without a valid name:)" \
            "user-docs-writer" "$(grep -m1 '^name:' "$AGENT" | sed 's/^name: *//')"
if bash "$REPO_ROOT/tests/test-agent-model-pins.sh" >/dev/null 2>&1; then
  pass "T1d: tests/test-agent-model-pins.sh passes with the new agent file present"
else
  fail "T1d: tests/test-agent-model-pins.sh fails with the new agent file present"
fi
assert_grep "T1e: agent file documents that mcp_tools: is inert, not the grant mechanism" \
            "$AGENT" "stack-convention marker, not a grant"

# The ADR asserts a factual count about the repo; verify rather than trust it.
assert_eq "T1f: ADR-045's amended 'four roster agents omit tools:' count matches the tree (excluding the new file)" \
          "4" "$(grep -L '^tools:' "$REPO_ROOT"/agents/*.md | grep -cv 'user-docs-writer.md')"

echo "--- T2 (prefix resolution) ---"
notrun "T2 live half: preflight selects mcp__playwright__* / mcp__plugin_playwright_playwright__* / STOPs when neither is live" \
       "a live session where MCP server availability can be toggled"
assert_grep "T2a: skill prefers the stack-declared mcp__playwright__* server first" "$SKILL" "prefer \`mcp__playwright__*\`"
assert_grep "T2b: skill names the plugin server as the fallback" "$SKILL" "mcp__plugin_playwright_playwright__*"
assert_grep "T2c: skill STOPs with a fix message when neither resolves" "$SKILL" "No Playwright MCP server is live."
# D4/constraint: never hardcode a prefix in a committed runner artifact. Scoped to
# tools/ deliberately — the ADR and skills legitimately NAME both prefixes as prose.
if grep -rlF 'mcp__' "$RUNNER"/*.ts "$RUNNER"/src 2>/dev/null | grep -q .; then
  fail "T2d: no mcp__ prefix is hardcoded anywhere under tools/user-docs/"
else
  pass "T2d: no mcp__ prefix is hardcoded anywhere under tools/user-docs/"
fi

# ---------------------------------------------------------------------------
# AUTHORING (Phase 1) — T3..T7
# ---------------------------------------------------------------------------
echo "--- T3..T7 (authoring) ---"
for case_desc in \
  "T3: /user-docs produces guide + PNGs + docs-test + handoff report" \
  "T4: every 'click X -> Y appears' sentence maps to a screenshot from this run" \
  "T5: guide has feature: front matter, role/tier prerequisites, alt text, 3-5 justified screenshots" \
  "T6: troubleshooting entries match error strings grep-verifiable in the flow's source" \
  "T7: a flow that could not be completed live is reported as such, not documented as working"; do
  notrun "$case_desc" "a running dev server and a live browser session"
done
# Static proxy: the rules those live cases enforce are present in the agent's charter.
assert_grep "T4a: agent charter states the no-capture-no-claim rule" "$AGENT" "**No capture, no claim.**"
assert_grep "T5a: editorial checklist requires feature: front matter" "$SKILL" "\`feature: <slug>\` front matter present"
assert_grep "T5b: editorial checklist bans screenshot carpet and requires per-capture justification" "$SKILL" "no screenshot carpet"
assert_grep "T5c: editorial checklist forbids color-only references" "$SKILL" "no color-only references"
assert_grep "T6a: troubleshooting must come from grepped error strings" "$SKILL" "grepped from this flow's code"
assert_grep "T7a: handoff format has a 'Flows I could NOT complete live' section" "$AGENT" "Flows I could NOT complete live"

# ---------------------------------------------------------------------------
# FRESH-EYES GATE — T8 / T9
# ---------------------------------------------------------------------------
echo "--- T8/T9 (fresh-eyes gate) ---"
notrun "T8: a general-purpose subagent given ONLY the guide markdown + base URL + storage state completes the flow with zero stuck/ambiguous" \
       "a live session that can dispatch a subagent, plus a running app"
notrun "T9 (negative): a broken expected-result line or wrong UI label makes the gate report stuck/ambiguous and blocks the guide" \
       "the same live gate as T8"
assert_grep "T8a: gate dispatches a general-purpose subagent with the guide inline and NO repo path" "$SKILL" "Give it no repo path"
assert_grep "T8b: pass condition is every step completed, zero stuck, zero ambiguous" "$SKILL" "**Pass condition: every step \`completed\`, zero \`stuck\`, zero \`ambiguous\`.**"
assert_grep "T9a: an unpassed gate blocks — the guide must not be reported done" "$SKILL" "must not be reported as done"

# ---------------------------------------------------------------------------
# AUTH — T10 / T11
# ---------------------------------------------------------------------------
echo "--- T10/T11 (auth) ---"
notrun "T10 live half: each MCQ branch (a/b/c) actually ends with storage state written to .claude/docs-capture/auth/<role>.json" \
       "a live login against a running app (incl. an SSO/MFA human-assisted branch)"
assert_grep "T10a: skill offers branch (a) existing storage state" "$SKILL" "a) Existing Playwright storage state"
assert_grep "T10b: skill offers branch (b) env-var test credentials" "$SKILL" "b) Test-account credentials in env vars"
assert_grep "T10c: skill offers branch (c) human-assisted login" "$SKILL" "c) Human-assisted"
assert_grep "T10d: all three branches converge on .claude/docs-capture/auth/<role>.json" "$SKILL" "All three end by exporting storage state to"
assert_grep "T10e: .gitignore covers .claude/docs-capture/" "$REPO_ROOT/.gitignore" ".claude/docs-capture/"
notrun "T11 live half: no credential string appears in any produced guide, docs-test, screenshot, or transcript" \
       "a completed authoring run to inspect"
assert_grep "T11a: agent charter forbids credentials in chat/guides/docs-tests/screenshots" "$AGENT" "**Credentials never appear**"

# ---------------------------------------------------------------------------
# RUNNER + REPLAY MODES (scope c) — T12..T18
# ---------------------------------------------------------------------------
echo "--- runner: static contract ---"
assert_file "runner: package.json"          "$RUNNER/package.json"
assert_file "runner: playwright.config.ts"  "$RUNNER/playwright.config.ts"
assert_file "runner: src/index.ts"          "$RUNNER/src/index.ts"
assert_file "runner: bin.ts"                "$RUNNER/bin.ts"
if [[ -x "$RUNNER/bin.ts" ]]; then pass "runner: bin.ts is executable"; else fail "runner: bin.ts is not executable"; fi
assert_grep "runner: package.json declares bin user-docs-run" "$RUNNER/package.json" "\"user-docs-run\": \"./bin.ts\""
assert_grep "runner: src exports docsTest"  "$RUNNER/src/index.ts" "export const docsTest"
assert_grep "runner: src exports shot"      "$RUNNER/src/index.ts" "export async function shot"
assert_grep "runner: src exports the DocsMeta type" "$RUNNER/src/index.ts" "export type DocsMeta"
# Playwright's default testMatch glob does NOT match *.docs.ts; without an explicit
# override the runner silently reports zero tests and every guide looks fresh.
assert_grep "runner: playwright.config.ts sets testMatch for *.docs.ts" "$RUNNER/playwright.config.ts" "testMatch: '**/*.docs.ts'"
assert_grep "runner: video capture is off (out of scope per the handoff)" "$RUNNER/playwright.config.ts" "video: 'off'"
assert_grep "runner: config resolves storageState per-file from docsMeta" "$RUNNER/playwright.config.ts" "meta.authState"
# Scope (c): docsMeta.reset is recorded but never executed.
if grep -nE 'exec[A-Za-z]*\(|spawn[A-Za-z]*\(' "$RUNNER/bin.ts" | grep -qi 'reset'; then
  fail "scope-c: bin.ts must NOT execute docsMeta.reset"
else
  pass "scope-c: bin.ts never executes docsMeta.reset (reset-command execution is a follow-up phase)"
fi
# T13's "zero vision calls" is structural, not incidental: the runner has no vision
# path at all. Assertion failures are detected by native Playwright assertions.
if grep -rqiE 'anthropic|openai|vision|image/png.*base64' "$RUNNER/bin.ts" "$RUNNER/src/index.ts" 2>/dev/null; then
  fail "T13a: runner makes zero vision/model calls (breakage detection is assertion-only)"
else
  pass "T13a: runner makes zero vision/model calls (breakage detection is assertion-only)"
fi

echo "--- runner: live enforcement gates ---"
if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  notrun "T14-T18 runner gates" "node + npx on PATH"
elif [[ ! -d "$RUNNER/node_modules" ]]; then
  notrun "T14-T18 runner gates" "the runner bootstrap (npm install in tools/user-docs/) — deliberately NOT vendored, per ADR-045 D5"
else
  FIX="$TMP/fixture-repo"
  mkdir -p "$FIX/.claude" "$FIX/docs/user/captures"
  cat > "$FIX/.claude/user-docs.json" <<'JSON'
{ "baseUrl": "http://localhost:3000", "roles": [], "personas": [],
  "captureBaseUrlAllowlist": ["http://localhost:3000"] }
JSON
  make_spec() { # make_spec <slug> <replay> [extra-field]
    cat > "$FIX/docs/user/captures/$1.docs.ts" <<SPEC
import { docsTest, shot, type DocsMeta } from '@stack/user-docs';
export const docsMeta: DocsMeta = {
  guide: 'docs/user/flows/$1.md',
  role: 'workspace-admin',
  authState: '.claude/docs-capture/auth/workspace-admin.json',
  replay: '$2',
  sideEffects: ['creates a record'],${3:-}
};
docsTest('$1', async ({ page }) => { await page.goto('/'); await shot(page, 'start'); });
SPEC
  }
  make_spec manual-flow manual
  make_spec reset-flow reset-required "
  reset: 'npm run seed:demo',"
  make_spec auto-flow auto

  run_runner() { ( cd "$RUNNER" && npx tsx bin.ts "$@" 2>&1 ); }
  rc_of() { ( cd "$RUNNER" && npx tsx bin.ts "$@" >/dev/null 2>&1; echo $? ); }

  # T14 — manual is never auto-replayed.
  out="$(run_runner --guide manual-flow --repo "$FIX" --base-url http://localhost:3000)"
  rc="$(rc_of --guide manual-flow --repo "$FIX" --base-url http://localhost:3000)"
  assert_eq "T14: manual docs-test -> exit 2" "2" "$rc"
  case "$out" in *"NEEDS-RECAPTURE (manual)"*) pass "T14: manual docs-test -> status NEEDS-RECAPTURE (manual)" ;;
                 *) fail "T14: expected 'NEEDS-RECAPTURE (manual)', got: $out" ;; esac

  # T15 (scope c) — reset-required is refused exactly like manual, and docsMeta.reset
  # is recorded but never attempted.
  out="$(run_runner --guide reset-flow --repo "$FIX" --base-url http://localhost:3000)"
  rc="$(rc_of --guide reset-flow --repo "$FIX" --base-url http://localhost:3000)"
  assert_eq "T15: reset-required docs-test -> exit 2" "2" "$rc"
  case "$out" in *"NEEDS-RECAPTURE (reset-required, not yet automated)"*)
      pass "T15: reset-required -> 'NEEDS-RECAPTURE (reset-required, not yet automated)'" ;;
    *) fail "T15: expected the reset-required refusal string, got: $out" ;; esac

  # The refusal must be decided WITHOUT a browser — otherwise scope (c) leaks.
  case "$out" in *"Executable doesn't exist"*|*"browserType.launch"*)
      fail "T15a: refusal must be decided from a static docsMeta parse, before any browser launch" ;;
    *) pass "T15a: refusal is decided from a static docsMeta parse, before any browser launch" ;; esac

  # T16 — missing storage state is AUTH-EXPIRED (3), distinct from STALE (1).
  out="$(run_runner --guide auto-flow --repo "$FIX" --base-url http://localhost:3000)"
  rc="$(rc_of --guide auto-flow --repo "$FIX" --base-url http://localhost:3000)"
  assert_eq "T16: missing storage state -> exit 3" "3" "$rc"
  case "$out" in *AUTH-EXPIRED*) pass "T16: missing storage state -> status AUTH-EXPIRED (not STALE)" ;;
                 *) fail "T16: expected AUTH-EXPIRED, got: $out" ;; esac

  # T17 — production can never be reached by a replay.
  out="$(run_runner --all --repo "$FIX" --base-url https://app.production.example)"
  rc="$(rc_of --all --repo "$FIX" --base-url https://app.production.example)"
  assert_eq "T17: base URL outside captureBaseUrlAllowlist -> exit 5" "5" "$rc"
  case "$out" in *captureBaseUrlAllowlist*) pass "T17: allowlist refusal names captureBaseUrlAllowlist" ;;
                 *) fail "T17: expected an allowlist refusal, got: $out" ;; esac

  # T18 — a missing bootstrap is RUNNER-UNAVAILABLE (4), never STALE.
  BARE="$TMP/bare-runner"; mkdir -p "$BARE"
  cp -R "$RUNNER/bin.ts" "$RUNNER/src" "$RUNNER/package.json" "$RUNNER/playwright.config.ts" "$BARE/"
  [[ -f "$RUNNER/tsconfig.json" ]] && cp "$RUNNER/tsconfig.json" "$BARE/"
  out="$( cd "$RUNNER" && npx tsx "$BARE/bin.ts" --all --repo "$FIX" --base-url http://localhost:3000 2>&1 )"
  rc="$( cd "$RUNNER" && npx tsx "$BARE/bin.ts" --all --repo "$FIX" --base-url http://localhost:3000 >/dev/null 2>&1; echo $? )"
  assert_eq "T18: missing node_modules -> exit 4" "4" "$rc"
  case "$out" in *RUNNER-UNAVAILABLE*) pass "T18: missing node_modules -> RUNNER-UNAVAILABLE (not STALE)" ;;
                 *) fail "T18: expected RUNNER-UNAVAILABLE, got: $out" ;; esac

  # Exit-code precedence. FILE 9 says "highest severity wins" while numbering STALE=1
  # below NEEDS-RECAPTURE=2, so the ordering cannot be "highest number wins". The
  # self-consistent reading, asserted here: 5 > 4 > 3 > 1 > 2 > 0.
  rc="$(rc_of --all --repo "$FIX" --base-url http://localhost:3000)"
  assert_eq "precedence: AUTH-EXPIRED(3) outranks NEEDS-RECAPTURE(2) in a mixed sweep" "3" "$rc"
  rc="$(rc_of --all --repo "$FIX" --base-url https://app.production.example)"
  assert_eq "precedence: config/allowlist error(5) outranks every per-guide status" "5" "$rc"

  # --json is the ONLY contract /user-docs-refresh parses; assert its shape.
  json_out="$(run_runner --guide reset-flow --repo "$FIX" --base-url http://localhost:3000 --json)"
  shape="$(printf '%s' "$json_out" | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d["results"][0]
print(",".join(sorted(d.keys())), "|", ",".join(sorted(r.keys())), "|", r["status"], r["replay"])
' 2>/dev/null)"
  assert_eq "--json contract: keys and values match FILE 9" \
    "results | captures,failure,guide,replay,status | NEEDS-RECAPTURE reset-required" "$shape"

  # Spec collection. This is the seam every gate above deliberately short-circuits
  # past, and the one that can produce a SILENT FALSE-GREEN: if the
  # `@stack/user-docs` alias fails to resolve, or testMatch does not match
  # `*.docs.ts`, Playwright collects zero tests, no assertion can fail, and every
  # guide reports `fresh`. `--list` proves collection works without launching a
  # browser or needing a dev server, so it is genuinely executable here.
  listed="$( cd "$RUNNER" && USER_DOCS_REPO="$FIX" npx playwright test --config playwright.config.ts --list 2>&1 )"
  assert_eq "collection: all 3 fixture docs-tests are collected (alias resolves, testMatch matches)" \
    "3" "$(printf '%s\n' "$listed" | grep -c '\.docs\.ts:[0-9]')"
  case "$listed" in *"Cannot find module '@stack/user-docs'"*)
      fail "collection: the @stack/user-docs alias does not resolve — no spec can load" ;;
    *) pass "collection: the @stack/user-docs alias resolves for consumer docs-tests" ;; esac
  # Per-project testMatch must isolate one spec per project, or storageState
  # cannot be resolved per-role.
  assert_eq "collection: one project per docs-test, each matching only its own file" \
    "3" "$(printf '%s\n' "$listed" | grep -cE '^\s*\[[a-z-]+\] › ')"
  # The alias is carried by the runner's tsconfig; assert the wiring exists so a
  # future edit cannot quietly drop it back to a zero-tests-collected state.
  assert_grep "collection: playwright.config.ts pins the tsconfig that carries the alias" \
    "$RUNNER/playwright.config.ts" "tsconfig: join(RUNNER_DIR, 'tsconfig.json')"
  assert_grep "collection: tsconfig declares the @stack/user-docs path alias" \
    "$RUNNER/tsconfig.json" "\"@stack/user-docs\": [\"./src/index.ts\"]"
  # And the false-green itself is fenced at runtime.
  assert_grep "collection: a run that collects zero tests is escalated, never reported fresh" \
    "$RUNNER/bin.ts" "Refusing to report a guide fresh on a run that executed nothing."

  # Static docsMeta parsing is what makes every gate above browser-free.
  parse_out="$( cd "$RUNNER" && npx tsx -e '
import { parseDocsMeta } from "./src/index.ts";
const src = `export const docsMeta: DocsMeta = { guide: "g.md", role: "admin", authState: "a.json", replay: "reset-required", sideEffects: ["x","y"], reset: "npm run seed" };`;
const m = parseDocsMeta(src);
console.log([m?.replay, m?.reset, m?.sideEffects?.join("+"), parseDocsMeta("no meta here") === null].join("|"));
' 2>/dev/null )"
  assert_eq "parseDocsMeta: static parse reads replay/reset/sideEffects and returns null when absent" \
    "reset-required|npm run seed|x+y|true" "$parse_out"
fi

notrun "T12: deleting all PNGs for an auto guide and re-running regenerates the identical capture set" \
       "Chromium + a running dev server + valid storage state"
notrun "T13 live half: a broken selector makes the runner exit 1 and name the failing test and step" \
       "Chromium + a running dev server"

# ---------------------------------------------------------------------------
# FRESHNESS CLASSIFICATION — T19..T22
# ---------------------------------------------------------------------------
echo "--- T19..T22 (freshness) ---"
notrun "T19: changed button copy -> invalidating -> step text updated -> fresh-eyes gate re-runs and re-passes" "a live app, a vision model, and a dispatchable subagent"
notrun "T20: theme-color-only change -> cosmetic -> PNG staged, guide text byte-identical" "a live app and a vision model"
notrun "T21 live half: no UI change -> byte-identical captures -> zero vision calls and no PNG churn" "a live app and a vision model"
# T21's mechanism IS statically checkable, and it is the load-bearing half: fresh
# captures go to a scratch dir, so a refresh sweep cannot dirty committed PNGs
# before the byte comparison decides whether anything changed.
assert_grep "T21a: refresh mode writes fresh captures to a scratch dir, not over the committed PNG" "$RUNNER/src/index.ts" "USER_DOCS_FRESH_DIR"
assert_grep "T21b: byte-identical is computed per capture and reported" "$RUNNER/bin.ts" "identical(c.committed, c.fresh)"
assert_grep "T21c: skill states byte-identical captures skip vision entirely" "$REFRESH" "**Byte-identical → skip vision entirely.**"

# T22 — prompt provenance. Scoped to the blockquoted prompt itself: the prose
# BELOW it legitimately explains why /screenshot-diff's TARGET framing is wrong.
PROMPT="$TMP/freshness-prompt.txt"
awk '/^> Image 1 is the screenshot/,/^$/' "$REFRESH" > "$PROMPT"
if [[ -s "$PROMPT" ]]; then
  pass "T22a: the freshness prompt block is present and extractable"
  assert_grep "T22b: prompt offers the verdict 'unchanged'"     "$PROMPT" "\`unchanged\`"
  assert_grep "T22c: prompt offers the verdict 'cosmetic'"      "$PROMPT" "\`cosmetic\`"
  assert_grep "T22d: prompt offers the verdict 'invalidating'"  "$PROMPT" "\`invalidating\`"
  assert_grep "T22e: prompt frames image 1 as a historical record, NOT a desired state" "$PROMPT" "NOT a desired state"
  assert_nogrep "T22f: prompt contains no 'TARGET' framing" "$PROMPT" "TARGET"
  assert_nogrep "T22g: prompt does not ask which version looks better" "$PROMPT" "what we want"
  assert_grep "T22h: prompt explicitly forbids 'which version looks better' judgements" "$PROMPT" "Do not evaluate which version looks better"
else
  fail "T22a: could not extract the freshness prompt block from $REFRESH"
fi
# Not byte-shared with /screenshot-diff: that skill has no in-repo source at all
# (verified by the architect — it is a machine-local personal tool).
if [[ -d "$REPO_ROOT/skills/screenshot-diff" ]]; then
  if diff -q "$PROMPT" <(awk '/^>/' "$REPO_ROOT/skills/screenshot-diff/SKILL.md") >/dev/null 2>&1; then
    fail "T22i: freshness prompt is byte-identical to /screenshot-diff's prompt"
  else
    pass "T22i: freshness prompt is not byte-shared with /screenshot-diff's prompt"
  fi
else
  pass "T22i: /screenshot-diff has no in-repo source, so no byte-sharing is possible"
fi
assert_grep "T22j: skill states the do-not-reuse rationale" "$REFRESH" "**Do not reuse \`/screenshot-diff\`'s prompt.**"

# ---------------------------------------------------------------------------
# COST GATING — T23 / T24
# ---------------------------------------------------------------------------
echo "--- T23/T24 (cost gating) ---"
notrun "T23 (positive): --all over 100+ captures runs a /cost-gate 10-sample, writes a projection, and shows pre-bulk-job with a real number" "a live session with a populated docs/user/captures/ and a metered model call"
notrun "T24 (negative): a single-guide refresh does not trip pre-bulk-job and does not prompt" "the same live gate as T23"
assert_grep "T23a: --all declares task_type: bulk_job (the wiring that reaches the existing gate)" "$REFRESH" "task_type: bulk_job"
assert_grep "T23b: --all runs a 10-capture /cost-gate sample before the gate prompt" "$REFRESH" "10-capture sample"
assert_grep "T23c: projection is written to .claude/cost-projections/" "$REFRESH" ".claude/cost-projections/"
assert_grep "T24a: single-guide refreshes are explicitly ungated" "$REFRESH" "run **ungated**"
# D7 — the gate already existed; config/approval-gates.json must NOT have been edited.
gates_task_types="$(python3 -c "
import json; g=json.load(open('$REPO_ROOT/config/approval-gates.json'))
gates=g.get('gates', g)
e=gates.get('pre-bulk-job', {}) if isinstance(gates, dict) else {}
print(','.join(e.get('applies_to_task_types', [])))
" 2>/dev/null)"
assert_eq "T24b (D7): pre-bulk-job already applies to bulk_job — approval-gates.json needed no edit" "bulk_job" "$gates_task_types"

# ---------------------------------------------------------------------------
# FOREMAN ROUTING — T25..T27
# ---------------------------------------------------------------------------
echo "--- T25..T27 (foreman routing) ---"
notrun "T25 live half: a UI-touching feature shows the offer once, after validator; a backend-only feature shows none" "a live foreman dispatch over a real change"
assert_grep "T25a: foreman task-type taxonomy includes user-docs" "$FOREMAN" "\`user-docs\` — end-user documentation"
assert_grep "T25b: foreman team table has a user-docs row" "$FOREMAN" "| user-docs (ADR-045) | user-docs-writer"
assert_grep "T25c: the offer is post-validator and never silent" "$FOREMAN" "After \`validator\` passes on a change that is **user-facing**"
assert_grep "T25d: backend-only changes get no offer" "$FOREMAN" "Backend-only changes get no offer at all."
notrun "T26 live half: inside a governed loop, no prompt and no dispatch occur" "a live governed-loop run with an active loop-state file"
assert_grep "T26a: headless detection keys on the ADR-020 loop-state file" "$FOREMAN" "loop-state[.<session-id>].json"
assert_grep "T26b: the literal auto-decline receipt line is specified verbatim" "$FOREMAN" "user-docs: suggested, auto-declined (headless) — <task> @ <iso>"
assert_grep "T26c: the receipt lands in .claude/sessions/<session-id>/user-docs-suggested.md" "$FOREMAN" "user-docs-suggested.md"
assert_grep "T26d: composition template reports the user-docs suggestion outcome" "$FOREMAN" "## User-docs suggestion (ADR-045)"
notrun "T27 live half: /dispatch user-docs-writer resolves and the role appears in /team-status" "a live session"
# T27a originally required "user-docs-writer" to be listed in this repo's
# active_subagents. ADR-068 D5 then made an empty active_subagents mean "the whole
# roster is available" and reconciles any enumerated list back to [], so the old
# assertion demanded the one state the reconcile tool is built to remove. What
# actually makes the role dispatchable is the agent file shipping in the tier
# manifest, so assert that instead.
assert_grep "T27a: the role ships in the tier manifest (ADR-068 D5: [] means full roster)" \
  "$REPO_ROOT/config/tier-manifests/tier-0.json" "agents/user-docs-writer.md"
if [[ "$(jq -r '.active_subagents | length' "$REPO_ROOT/.claude/stack-config.json")" == "0" ]]; then
  pass "T27a: active_subagents is [] — the ADR-068 D5 reconciled state"
else
  fail "T27a: active_subagents is enumerated; ADR-068 D5 reconciles it to []"
fi
assert_grep "T27b: model-routing.json assigns the role a model" "$REPO_ROOT/config/model-routing.json" "\"user-docs-writer\": {"
assert_grep "T27c: the roster hook recognizes user-docs-writer as a roster agentType" "$REPO_ROOT/hooks/workflow-roster-check.sh" "|user-docs-writer|"

# ---------------------------------------------------------------------------
# REPO HYGIENE / REGRESSION — T28..T31
# ---------------------------------------------------------------------------
echo "--- T28..T31 (hygiene) ---"
if bash "$REPO_ROOT/tests/test-agent-model-pins.sh" >/dev/null 2>&1; then
  pass "T28: tests/test-agent-model-pins.sh passes unmodified"
else
  fail "T28: tests/test-agent-model-pins.sh fails"
fi
if git -C "$REPO_ROOT" diff --quiet -- tests/test-agent-model-pins.sh 2>/dev/null; then
  pass "T28a: tests/test-agent-model-pins.sh is unmodified (the regex guard was not relaxed)"
else
  fail "T28a: tests/test-agent-model-pins.sh was modified — the handoff forbids relaxing this guard"
fi

if "$REPO_ROOT/scripts/gen-capability-registry.sh" --check >/dev/null 2>&1; then
  pass "T29: capability registry is freshly generated (--check clean)"
else
  fail "T29: capability registry is stale — run scripts/gen-capability-registry.sh and commit"
fi
reg_entry="$(python3 -c "
import json; r=json.load(open('$REGISTRY'))
e=[c for c in r['capabilities'] if c['id']=='user-docs-writer']
print(e[0]['kind'] if e else 'MISSING')
" 2>/dev/null)"
assert_eq "T29a: registry contains a user-docs-writer subagent entry" "subagent" "$reg_entry"
for sk in user-docs user-docs-refresh; do
  got="$(python3 -c "
import json; r=json.load(open('$REGISTRY'))
e=[c for c in r['capabilities'] if c['id']=='$sk']
print(e[0]['invocation']['slash'] if e else 'MISSING')
" 2>/dev/null)"
  assert_eq "T29b: registry exposes /$sk as a skill" "/$sk" "$got"
done

# T30 — tier-3 install shape. The clean-machine matrix lives in test-install.sh.
notrun "T30 live half: a clean-machine Tier-3 install passes its smoke tests, including with npm absent" "a clean machine / the CI per-tier install matrix (tests/test-install.sh)"
t3_missing=""
for f in skills/user-docs/SKILL.md skills/user-docs-refresh/SKILL.md \
         tools/user-docs/package.json tools/user-docs/playwright.config.ts tools/user-docs/src/index.ts tools/user-docs/bin.ts; do
  grep -qF "\"from\": \"$f\"" "$TIER3" || t3_missing="$t3_missing $f"
done
grep -qF '"from": "agents/user-docs-writer.md"' "$TIER0" || t3_missing="$t3_missing agents/user-docs-writer.md(tier-0)"
assert_eq "T30a: tier-3 manifest installs every runner/skill file; tier-0 installs the agent" "" "$t3_missing"
assert_grep "T30b: bin.ts is installed executable" "$TIER3" "\"tools/user-docs/bin.ts\", \"to\": \"~/.claude/tools/user-docs/bin.ts\", \"executable\": true"
assert_grep "T30c: smoke test asserts bin.ts is executable on the target" "$TIER3" "test -x ~/.claude/tools/user-docs/bin.ts"
# The install must not fail on a machine that never dispatches this role.
npm_req="$(python3 -c "
import json; m=json.load(open('$TIER3'))
print(sum(1 for r in m.get('requirements', []) if r.get('name')=='npm' and not r.get('advisory')))
" 2>/dev/null)"
assert_eq "T30d: no hard 'command: npm' requirement was added to tier-3" "0" "$npm_req"
# Every manifest 'from' path must actually exist, or the install breaks.
t3_absent=""
while read -r p; do
  [[ -e "$REPO_ROOT/$p" ]] || t3_absent="$t3_absent $p"
done < <(python3 -c "
import json; m=json.load(open('$TIER3'))
[print(f['from']) for g in m.get('files', {}).values() for f in g if 'from' in f]
" 2>/dev/null)
assert_eq "T30e: every tier-3 manifest 'from' path exists in the repo" "" "$t3_absent"

# T31 — the count and the ADR agree.
assert_eq "T31: agents/ holds 25 agent files (24 + pm, P1b)" "25" "$(ls "$REPO_ROOT"/agents/*.md | wc -l | tr -d ' ')"
assert_grep "T31a: ADR-003 records the ADR-045 amendment" "$ADR003" "**Amended by:** ADR-045"
assert_grep "T31b: ADR-003 says 24 agent files / 22 named roles" "$ADR003" "total agent files to 24 if counting these, but the core/specialist/meta naming convention says 22"
assert_grep "T31c: ADR-003 lists user-docs-writer on a 7-strong specialist bench" "$ADR003" "Specialist bench (7):"
assert_file "T31d: ADR-045 exists" "$ADR045"
assert_grep "T31e: ADR-045 records the scope-c refusal decision (D10)" "$ADR045" "**D10 (scope-c specific)"
# Roles 2/3 must not have leaked into the roster (D9).
if ls "$REPO_ROOT"/agents/logic-extractor.md "$REPO_ROOT"/agents/docs-synthesizer.md >/dev/null 2>&1; then
  fail "T31f (D9): Roles 2/3 (logic-extractor / docs-synthesizer) are out of scope and must not exist"
else
  pass "T31f (D9): Roles 2/3 (logic-extractor / docs-synthesizer) were not built"
fi

# T31g (ADR-050 D1) — logic extraction generalized as a skill, not a roster
# seat: the capability exists in skill form AND still no agents/logic-extractor.md.
LOGIC_SKILL="$REPO_ROOT/skills/user-docs-logic/SKILL.md"
if [[ -f "$LOGIC_SKILL" ]] && ! [[ -f "$REPO_ROOT/agents/logic-extractor.md" ]]; then
  pass "T31g (ADR-050 D1): logic extraction shipped as skills/user-docs-logic/SKILL.md, no roster seat taken"
else
  fail "T31g (ADR-050 D1): expected skills/user-docs-logic/SKILL.md to exist and agents/logic-extractor.md to not"
fi

echo
echo "Results: $PASS passed, $FAIL failed, $NOTRUN not executed"
echo
echo "NOT-EXECUTED cases are plan items that need a live claude -p session, a live"
echo "Playwright MCP server, a running dev server, or a vision model. They are"
echo "unverified — a clean run here is NOT full coverage of the 31-item plan."
[[ "$FAIL" -eq 0 ]]
