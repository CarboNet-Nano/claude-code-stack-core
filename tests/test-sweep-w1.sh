#!/usr/bin/env bash
# tests/test-sweep-w1.sh — W1's driver: the Sweep protocol contract (job on
# stdin, exactly one SWEEP_RESULT:v1 line, last) and every fail-closed path.
#
# Every refusal here is a case where the alternative is a check that exits
# clean having examined nothing. The runner turns a check that exited
# without a result line into `error`, never a pass — so the assertion is
# always the pair: non-zero exit AND no result line.
#
# Browser-bound cases arrive in tasks 5-6 and are gated on a live chromium
# probe, SKIPPED with the probe's own failure text when it cannot launch —
# never faked as a pass (house style: tests/test-sweep-e1.sh).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/sweep/checks/w1-walk-surface.mjs"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available — w1-walk-surface.mjs is a node check"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-w1-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# mkrepo <name> -> path to a throwaway git repo with one commit.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d" && git -C "$d" init -q
  git -C "$d" config user.email t@t.t && git -C "$d" config user.name t
  echo x > "$d/f" && git -C "$d" add f && git -C "$d" commit -qm init
  echo "$d"
}

# job <repo> <config-json> -> a sweep-job/v1 payload on stdout.
job() {
  jq -nc --arg r "$1" --argjson c "$2" \
    '{schema:"sweep-job/v1", check_id:"W1", repo_root:$r, evidence_basis:"staging", surface:"ui-route", config:$c}'
}

# result_b64 <output> -> the base64 payload of the LAST result line.
result_b64() { printf '%s\n' "$1" | sed -n 's/^SWEEP_RESULT:v1 //p' | tail -1; }

# envelope <output> -> the decoded envelope JSON.
envelope() { result_b64 "$1" | base64 -d 2>/dev/null; }

# has_result_line <output> -> 0 if a result line is present.
has_result_line() { printf '%s\n' "$1" | sed -n 's/^SWEEP_RESULT:v1 //p' | head -1 | grep -q . ; }

# assert_failed_closed <label> <rc> <output>
assert_failed_closed() {
  local label="$1" rc="$2" out="$3"
  if [ "$rc" -ne 0 ] && ! has_result_line "$out"; then
    pass "$label"
  else
    fail "$label (rc=$rc, result line present: $(has_result_line "$out" && echo yes || echo no))"
  fi
}

# ---- browser harness -------------------------------------------------
# Playwright is never a stack-repo dependency. The suite reuses an
# existing install from a sibling repo when one is resolvable and its
# browser build matches what is on disk; otherwise every browser-bound
# case SKIPs with the probe's own failure text. A version whose browser
# build is absent produces "Executable doesn't exist", which is a real,
# printable reason -- not something to paper over.
PW_HOST=""
for cand in ${W1_PLAYWRIGHT_HOST:-} "$HOME/Claude/carbonet-hr-sync" "$HOME/Claude/SpecOps"; do
  [ -n "$cand" ] && [ -d "$cand/node_modules/playwright" ] && { PW_HOST="$cand"; break; }
done

# chromium_probe -> "" when a browser really launches here, else the reason.
# Verified by an actual launch, never assumed from the presence of a module.
chromium_probe() {
  [ -n "$PW_HOST" ] || { echo "no resolvable playwright install found (set W1_PLAYWRIGHT_HOST to a repo that has one)"; return; }
  node --input-type=module -e "
    import { createRequire } from 'node:module';
    const require = createRequire('$PW_HOST/');
    try {
      const { chromium } = require('playwright');
      const b = await chromium.launch();
      await b.close();
      process.stdout.write('');
    } catch (e) { process.stdout.write('LAUNCH_FAIL: ' + e.message.split('\\n')[0]); }
  " 2>&1
}

# link_playwright <repo> -> makes playwright resolvable from a throwaway
# repo the way the driver expects to find it: in repo_root/node_modules.
link_playwright() {
  mkdir -p "$1/node_modules"
  ln -sf "$PW_HOST/node_modules/playwright" "$1/node_modules/playwright" 2>/dev/null
  ln -sf "$PW_HOST/node_modules/playwright-core" "$1/node_modules/playwright-core" 2>/dev/null
  for m in "$PW_HOST"/node_modules/.pnpm "$PW_HOST"/node_modules/@playwright; do
    [ -e "$m" ] && ln -sf "$m" "$1/node_modules/$(basename "$m")" 2>/dev/null
  done
  return 0
}

# serve <dir> <port> -> starts a static file server, echoes its pid.
serve() {
  node -e "
    const http=require('http'),fs=require('fs'),p=require('path');
    http.createServer((q,s)=>{
      const u=q.url.split('?')[0];
      const f=p.join('$1', u==='/'?'index.html':u.replace(/^\//,'')+'.html');
      fs.readFile(f,(e,d)=>{ if(e){s.writeHead(404);s.end('')} else {s.writeHead(200,{'Content-Type':'text/html'});s.end(d)} });
    }).listen($2);
  " >/dev/null 2>&1 &
  echo $!
}

# free_port -> an unused localhost port.
free_port() { node -e "const n=require('net');const s=n.createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})"; }

# walk_run <repo> <html> <manifest-json> -> stdout of a real walk, or the
# empty string when the browser could not launch (caller SKIPs).
walk_run() {
  local repo="$1" html="$2" man="$3" port out
  mkdir -p "$repo/site"
  printf '%s' "$html" > "$repo/site/index.html"
  printf '%s' "$man" > "$repo/w.json"
  link_playwright "$repo"
  port="$(free_port)"
  local pid; pid="$(serve "$repo/site" "$port")"
  sleep 1
  export W1_URL="http://127.0.0.1:$port"
  out="$(job "$repo" '{"base_url_env":"W1_URL","route_manifest_cmd":"echo /","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"
  kill "$pid" 2>/dev/null
  unset W1_URL
  printf '%s' "$out"
}

# ---- the four assertion verbs (browser) ------------------------------
# Every verb gets BOTH directions. A verb that cannot fail is vacuous; a
# verb that cannot pass is a permanent false alarm. Neither is a check.

# verb_findings <repo> <html> <find> <verb> -> count of findings for that control
verb_findings() {
  local out
  out="$(walk_run "$1" "$2" "{\"screens\":[{\"screen\":\"/\",\"controls\":[{\"find\":\"$3\",\"assert\":\"$4\"}]}]}")"
  envelope "$out" | jq -r --arg f "$3" '[.findings[] | select(.mechanism=="CONTRACT DRIFT") | select(.identity_key | contains($f))] | length' 2>/dev/null
}

t_navigates_catches_a_control_that_goes_nowhere() {
  local repo probe n
  repo="$(mkrepo verb-nav-fail)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb navigates FAILS on a control that changes nothing — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="void 0">Assign</button></body></html>' Assign navigates)"
  [ "$n" = "1" ] && pass "verb navigates: a control whose activation changes neither URL nor DOM is a finding (AP #215)" \
                 || fail "verb navigates FAIL case gave '$n' findings, expected 1"
}

t_navigates_passes_a_working_control() {
  local repo probe n
  repo="$(mkrepo verb-nav-pass)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb navigates PASSES a working control — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="location.hash=String(Math.random())">Assign</button></body></html>' Assign navigates)"
  [ "$n" = "0" ] && pass "verb navigates: a control that changes the URL produces no finding — the verb can pass, not only fail" \
                 || fail "verb navigates PASS case gave '$n' findings, expected 0"
}

t_menu_geometry_catches_a_clipped_menu() {
  local repo probe n
  repo="$(mkrepo verb-geo-clip)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb opens-menu-adjacent-to-anchor FAILS on a clipped menu — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><div style="height:18px;overflow:hidden"><button onclick="document.getElementById(&apos;m&apos;).style.display=&apos;block&apos;">Tax type</button><div id="m" role="menu" style="display:none;height:300px"><div role="menuitem">A</div></div></div></body></html>' "Tax type" opens-menu-adjacent-to-anchor)"
  [ "$n" = "1" ] && pass "verb opens-menu-adjacent-to-anchor: a menu clipped by an ancestor's overflow is a finding (AP #209)" \
                 || fail "verb geometry CLIP case gave '$n' findings, expected 1"
}

t_menu_geometry_catches_a_mispositioned_menu() {
  local repo probe n
  repo="$(mkrepo verb-geo-pos)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb opens-menu-adjacent-to-anchor FAILS on a menu thrown across the screen — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="document.getElementById(&apos;m&apos;).style.display=&apos;block&apos;">Tax type</button><div id="m" role="menu" style="display:none;position:absolute;left:1500px;top:1200px;height:120px;width:200px"><div role="menuitem">A</div></div></body></html>' "Tax type" opens-menu-adjacent-to-anchor)"
  [ "$n" = "1" ] && pass "verb opens-menu-adjacent-to-anchor: a menu positioned far from its anchor is a finding (AP #212)" \
                 || fail "verb geometry POSITION case gave '$n' findings, expected 1"
}

t_menu_geometry_passes_a_wellplaced_menu() {
  local repo probe n
  repo="$(mkrepo verb-geo-ok)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb opens-menu-adjacent-to-anchor PASSES a well-placed menu — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="document.getElementById(&apos;m&apos;).style.display=&apos;block&apos;">Tax type</button><div id="m" role="menu" style="display:none;height:120px;width:200px"><div role="menuitem">A</div></div></body></html>' "Tax type" opens-menu-adjacent-to-anchor)"
  [ "$n" = "0" ] && pass "verb opens-menu-adjacent-to-anchor: a full-height menu beside its anchor produces no finding" \
                 || fail "verb geometry PASS case gave '$n' findings, expected 0"
}

t_shows_pending_catches_a_silent_control() {
  local repo probe n
  repo="$(mkrepo verb-pend-fail)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb shows-pending FAILS on a control with no feedback — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="void 0">Next</button></body></html>' Next shows-pending)"
  [ "$n" = "1" ] && pass "verb shows-pending: a control that shows no busy state while working is a finding (AP #210)" \
                 || fail "verb shows-pending FAIL case gave '$n' findings, expected 1"
}

t_shows_pending_passes_a_control_with_feedback() {
  local repo probe n
  repo="$(mkrepo verb-pend-pass)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb shows-pending PASSES a control with feedback — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="this.setAttribute(&apos;aria-busy&apos;,&apos;true&apos;)">Next</button></body></html>' Next shows-pending)"
  [ "$n" = "0" ] && pass "verb shows-pending: a control that sets aria-busy produces no finding" \
                 || fail "verb shows-pending PASS case gave '$n' findings, expected 0"
}

t_persists_catches_a_silent_revert() {
  local repo probe n
  repo="$(mkrepo verb-persist-fail)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb persists-after-reload FAILS on a save that reverts — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><input id="f" value="original"><button onclick="document.getElementById(&apos;f&apos;).value=&apos;changed&apos;">Save</button></body></html>' Save persists-after-reload)"
  [ "$n" = "1" ] && pass "verb persists-after-reload: a change that does not survive a reload is a finding (AP #223)" \
                 || fail "verb persists FAIL case gave '$n' findings, expected 1"
}

t_persists_passes_a_real_save() {
  local repo probe n
  repo="$(mkrepo verb-persist-pass)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "verb persists-after-reload PASSES a save that really persists — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><input id="f"><button onclick="localStorage.setItem(&quot;v&quot;,&quot;changed&quot;);document.getElementById(&quot;f&quot;).value=&quot;changed&quot;">Save</button><script>document.getElementById("f").value = localStorage.getItem("v") || "original";</script></body></html>' Save persists-after-reload)"
  [ "$n" = "0" ] && pass "verb persists-after-reload: a change written to storage and rehydrated on load produces no finding" \
                 || fail "verb persists PASS case gave '$n' findings, expected 0"
}

t_a_control_that_does_not_render_is_a_finding() {
  local repo probe n
  repo="$(mkrepo verb-absent)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "a declared control absent from the page is a finding — chromium could not launch here ($probe)"; return; }
  n="$(verb_findings "$repo" '<!doctype html><html><body><button onclick="void 0">Something else</button></body></html>' Ghost navigates)"
  [ "$n" = "1" ] && pass "a declared control that never renders is a finding, not a silent skip" \
                 || fail "absent-control case gave '$n' findings, expected 1"
}

t_assertions_executed_counts_every_walked_control() {
  local repo probe out ex
  repo="$(mkrepo assertions-counted)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "assertions_executed counts every declared control walked — chromium could not launch here ($probe)"; return; }
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="location.hash=&apos;a&apos;">One</button><button onclick="location.hash=&apos;b&apos;">Two</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"One","assert":"navigates"},{"find":"Two","assert":"navigates"}]}]}')"
  ex="$(envelope "$out" | jq -r '.assertions_executed' 2>/dev/null)"
  [ "$ex" = "2" ] && pass "assertions_executed equals the number of declared controls walked — liveness is not vacuous" \
                  || fail "assertions_executed was '$ex', expected 2"
}

t_findings_carry_real_liveness_numbers() {
  local repo probe out lv
  repo="$(mkrepo liveness-stamp)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "findings carry the run's real liveness numbers — chromium could not launch here ($probe)"; return; }
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="location.hash=&apos;a&apos;">One</button><button onclick="void 0">Two</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"One","assert":"navigates"},{"find":"Two","assert":"navigates"}]}]}')"
  lv="$(envelope "$out" | jq -c '[.findings[] | select(.mechanism=="CONTRACT DRIFT")][0].liveness' 2>/dev/null)"
  [ "$lv" = '{"assertions_executed":2,"assertions_passed":1}' ] \
    && pass "a finding carries the run's real liveness numbers (2 executed, 1 passed), never zeroes" \
    || fail "finding liveness was $lv"
}

t_a_failing_verb_makes_the_envelope_fail() {
  local repo probe out st
  repo="$(mkrepo status-fail)"; probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "a failing verb makes the envelope status fail — chromium could not launch here ($probe)"; return; }
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="void 0">Assign</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"Assign","assert":"navigates"}]}]}')"
  st="$(envelope "$out" | jq -r '.status' 2>/dev/null)"
  [ "$st" = "fail" ] && pass "a failing verb makes the envelope status 'fail'" || fail "envelope status was '$st', expected fail"
}

# ---- fail-closed paths ----------------------------------------------

t_unparseable_job_fails_closed() {
  local out rc
  out="$(printf '%s' 'not json' | node "$CHECK" 2>&1)"; rc=$?
  assert_failed_closed "an unparseable sweep-job payload exits non-zero and prints NO result line" "$rc" "$out"
}

t_missing_repo_root_fails_closed() {
  local out rc
  out="$(jq -nc '{schema:"sweep-job/v1",check_id:"W1",config:{}}' | node "$CHECK" 2>&1)"; rc=$?
  assert_failed_closed "a job with no repo_root exits non-zero and prints NO result line" "$rc" "$out"
}

t_missing_route_manifest_cmd_fails_closed() {
  local repo out rc
  repo="$(mkrepo missing-adapter)"
  out="$(job "$repo" '{"base_url_env":"W1_URL","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"; rc=$?
  assert_failed_closed "a missing route_manifest_cmd exits non-zero and prints NO result line" "$rc" "$out"
}

t_missing_base_url_env_fails_closed() {
  local repo out rc
  repo="$(mkrepo missing-base)"
  out="$(job "$repo" '{"route_manifest_cmd":"echo /","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"; rc=$?
  assert_failed_closed "a missing base_url_env exits non-zero and prints NO result line" "$rc" "$out"
}

t_unset_base_url_variable_fails_closed() {
  local repo out rc
  repo="$(mkrepo unset-base)"
  printf '%s' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}' > "$repo/w.json"
  unset W1_ABSENT_URL
  out="$(job "$repo" '{"base_url_env":"W1_ABSENT_URL","route_manifest_cmd":"echo /","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"; rc=$?
  assert_failed_closed "base_url_env naming an EMPTY variable exits non-zero — a declared-but-unset URL is not a walkable app" "$rc" "$out"
}

t_missing_walk_manifest_key_fails_closed() {
  local repo out rc
  repo="$(mkrepo missing-manifest-key)"
  export W1_URL=http://127.0.0.1:1
  out="$(job "$repo" '{"base_url_env":"W1_URL","route_manifest_cmd":"echo /"}' | node "$CHECK" 2>&1)"; rc=$?
  unset W1_URL
  assert_failed_closed "a missing walk_manifest key exits non-zero and prints NO result line" "$rc" "$out"
}

t_unreadable_walk_manifest_fails_closed() {
  local repo out rc
  repo="$(mkrepo unreadable-manifest)"
  export W1_URL=http://127.0.0.1:1
  out="$(job "$repo" '{"base_url_env":"W1_URL","route_manifest_cmd":"echo /","walk_manifest":"nope.json"}' | node "$CHECK" 2>&1)"; rc=$?
  unset W1_URL
  assert_failed_closed "an unreadable walk manifest exits non-zero and prints NO result line" "$rc" "$out"
}

t_unknown_verb_fails_closed_and_names_it() {
  local repo out rc
  repo="$(mkrepo bad-verb)"
  printf '%s' '{"screens":[{"screen":"/","controls":[{"find":"X","assert":"wiggles"}]}]}' > "$repo/w.json"
  export W1_URL=http://127.0.0.1:1
  out="$(job "$repo" '{"base_url_env":"W1_URL","route_manifest_cmd":"echo /","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"; rc=$?
  unset W1_URL
  if [ "$rc" -ne 0 ] && ! has_result_line "$out" && printf '%s' "$out" | grep -q 'wiggles'; then
    pass "an unknown assertion verb exits non-zero, names the verb, and prints NO result line"
  else
    fail "unknown verb gave rc=$rc, output: $out"
  fi
}

t_unwalked_universe_is_never_a_pass() {
  local repo out rc
  repo="$(mkrepo unwalked)"
  printf '%s' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}' > "$repo/w.json"
  export W1_URL=http://127.0.0.1:1
  out="$(job "$repo" '{"base_url_env":"W1_URL","route_manifest_cmd":"echo /","walk_manifest":"w.json"}' | node "$CHECK" 2>&1)"; rc=$?
  unset W1_URL
  # Task 4 ships no browser. A non-empty walk universe must therefore
  # refuse rather than report a pass over screens it never opened.
  # Tasks 5-6 replace this refusal with a real walk; the assertion that a
  # pass is never reported over unwalked screens survives them.
  if [ "$rc" -ne 0 ] && ! has_result_line "$out"; then
    pass "a non-empty walk universe never reports a pass over screens the check did not open"
  else
    fail "unwalked universe gave rc=$rc with a result line present"
  fi
}

# ---- the envelope contract ------------------------------------------

# A fully excluded universe is the one clean path that needs no browser:
# there is nothing to open, so the check can legitimately report a pass.

EXCLUDED_CONFIG='{"base_url_env":"W1_URL","route_manifest_cmd":"echo /admin","walk_manifest":"w.json","exclusions":[{"unit":"/admin","reason":"needs a seeded tenant"}]}'

# run_excluded <name> -> stdout of a fully excluded run.
run_excluded() {
  local repo="$1"
  printf '%s' '{"screens":[{"screen":"/admin","controls":[{"find":"Save","assert":"navigates"}]}]}' > "$repo/w.json"
  export W1_URL=http://127.0.0.1:1
  job "$repo" "$EXCLUDED_CONFIG" | node "$CHECK" 2>/dev/null
  unset W1_URL
}

t_fully_excluded_universe_emits_a_pass_envelope() {
  local repo out env status universe reason
  repo="$(mkrepo all-excluded)"
  out="$(run_excluded "$repo")"
  env="$(envelope "$out")"
  status="$(printf '%s' "$env" | jq -r '.status')"
  universe="$(printf '%s' "$env" | jq -r '.universe_size')"
  reason="$(printf '%s' "$env" | jq -r '.excluded[0].reason')"
  if [ "$status" = "pass" ] && [ "$universe" = "1" ] && [ "$reason" = "needs a seeded tenant" ]; then
    pass "a fully excluded universe emits a pass envelope carrying the exclusion reason, and launches no browser"
  else
    fail "excluded-universe envelope was status=$status universe=$universe reason=$reason"
  fi
}

t_result_line_is_the_last_stdout_line() {
  local repo out last
  repo="$(mkrepo last-line)"
  out="$(run_excluded "$repo")"
  last="$(printf '%s\n' "$out" | tail -1)"
  case "$last" in
    "SWEEP_RESULT:v1 "*) pass "the SWEEP_RESULT line is the LAST stdout line" ;;
    *) fail "last stdout line was '$last'" ;;
  esac
}

t_exactly_one_result_line() {
  local repo out n
  repo="$(mkrepo one-line)"
  out="$(run_excluded "$repo")"
  n="$(printf '%s\n' "$out" | grep -c '^SWEEP_RESULT:v1 ' || true)"
  [ "$n" = "1" ] \
    && pass "the check emits exactly one result line, never two" \
    || fail "the check emitted $n result lines"
}

t_envelope_carries_the_fixed_fields() {
  local repo out env schema checkid surface
  repo="$(mkrepo fixed-fields)"
  out="$(run_excluded "$repo")"
  env="$(envelope "$out")"
  schema="$(printf '%s' "$env" | jq -r '.schema')"
  checkid="$(printf '%s' "$env" | jq -r '.check_id')"
  surface="$(printf '%s' "$env" | jq -r '.surface')"
  if [ "$schema" = "sweep-result/v1" ] && [ "$checkid" = "W1" ] && [ "$surface" = "ui-route" ]; then
    pass "the envelope carries schema sweep-result/v1, check_id W1, and surface ui-route"
  else
    fail "envelope had schema=$schema check_id=$checkid surface=$surface"
  fi
}

t_envelope_declares_both_measurements() {
  local repo out env n
  repo="$(mkrepo measurements)"
  out="$(run_excluded "$repo")"
  env="$(envelope "$out")"
  n="$(printf '%s' "$env" | jq -r '.measurements | length')"
  [ "$n" = "2" ] \
    && pass "the envelope declares both measurements — failed assertions AND undeclared controls" \
    || fail "the envelope declared $n measurements, expected 2"
}

t_envelope_is_valid_json() {
  local repo out env
  repo="$(mkrepo valid-json)"
  out="$(run_excluded "$repo")"
  env="$(envelope "$out")"
  printf '%s' "$env" | jq -e . >/dev/null 2>&1 \
    && pass "the base64 payload decodes to valid JSON" \
    || fail "the base64 payload did not decode to valid JSON"
}

# ---- dead controls and the live-DOM denominator (browser) ------------

DEAD_HTML='<!doctype html><html><body>
<button onclick="void 0">Save</button>
<button>Edit flow</button>
<a href="/other">Next</a>
<a href="#">Nowhere</a>
<button data-inert="decorative badge, never clickable">Badge</button>
</body></html>'

t_dead_controls_are_found() {
  local repo probe out n
  repo="$(mkrepo dead-controls)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "a rendered control wired to nothing is reported — chromium could not launch here, verified by a direct probe ($probe)"
    return
  fi
  out="$(walk_run "$repo" "$DEAD_HTML" '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  n="$(envelope "$out" | jq -r '[.findings[] | select(.mechanism=="DISCONNECTED")] | length' 2>/dev/null)"
  [ "$n" = "2" ] \
    && pass "dead controls are found — a handlerless button and an href='#' link, while data-inert, a real handler and a real href are all exempt" \
    || fail "dead-control count was '$n', expected 2 (output: $(printf '%s' "$out" | head -3))"
}

t_dead_control_finding_is_wellformed() {
  local repo probe out f
  repo="$(mkrepo dead-shape)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "a dead-control finding carries the enum values the schema requires — chromium could not launch here ($probe)"
    return
  fi
  out="$(walk_run "$repo" "$DEAD_HTML" '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  f="$(envelope "$out" | jq -c '[.findings[] | select(.mechanism=="DISCONNECTED")][0] | {mechanism,found_by,surface,surface_source,has_commit:(.evidence.commit|length>0),plain_has_path:(.plain|test("/|\\.mjs"))}' 2>/dev/null)"
  [ "$f" = '{"mechanism":"DISCONNECTED","found_by":"sweep-family-E","surface":"ui-route","surface_source":"declared","has_commit":true,"plain_has_path":false}' ] \
    && pass "a dead-control finding carries mechanism DISCONNECTED, found_by sweep-family-E, a real commit, and a plain sentence with no paths in it" \
    || fail "dead-control finding shape was $f"
}

t_dead_control_identity_key_is_r1_safe() {
  local repo probe out bad
  repo="$(mkrepo dead-r1)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "dead-control identity keys survive R1 — chromium could not launch here ($probe)"
    return
  fi
  out="$(walk_run "$repo" '<!doctype html><html><body><button>Order 12345</button><button onclick="void 0">Save</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  bad="$(envelope "$out" | jq -r '[.findings[] | select(.identity_key | test("[0-9]{4,}"))] | length' 2>/dev/null)"
  [ "$bad" = "0" ] \
    && pass "no dead-control identity_key contains a 4+ digit run — sweep-emit.sh's R1 cannot refuse them" \
    || fail "$bad identity key(s) would be refused by R1"
}

t_coverage_gap_is_reported() {
  local repo probe out undeclared
  repo="$(mkrepo coverage-gap)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "controls rendered but undeclared are counted as coverage gaps — chromium could not launch here ($probe)"
    return
  fi
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="void 0">Save</button><button onclick="void 0">Export</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  undeclared="$(envelope "$out" | jq -r '.measurements[] | select(.statement | test("absent from the walk manifest")) | .count' 2>/dev/null)"
  [ "$undeclared" = "1" ] \
    && pass "a control rendered but absent from the manifest is counted as a coverage gap" \
    || fail "undeclared count was '$undeclared', expected 1"
}

t_coverage_denominator_comes_from_the_dom() {
  local repo probe out denom
  repo="$(mkrepo coverage-denom)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "the coverage denominator is the DOM's control count, not the manifest's — chromium could not launch here ($probe)"
    return
  fi
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="void 0">Save</button><button onclick="void 0">Export</button><button onclick="void 0">Print</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  denom="$(envelope "$out" | jq -r '.measurements[] | select(.statement | test("absent from the walk manifest")) | .denominator' 2>/dev/null)"
  [ "$denom" = "3" ] \
    && pass "the coverage denominator is 3 — every control the DOM rendered, not the 1 the manifest declared" \
    || fail "coverage denominator was '$denom', expected 3"
}

t_full_declaration_reports_no_coverage_gap() {
  local repo probe out undeclared
  repo="$(mkrepo coverage-full)"
  probe="$(chromium_probe)"
  if [ -n "$probe" ]; then
    skip "a manifest naming every rendered control reports no gap — chromium could not launch here ($probe)"
    return
  fi
  out="$(walk_run "$repo" '<!doctype html><html><body><button onclick="void 0">Save</button></body></html>' '{"screens":[{"screen":"/","controls":[{"find":"Save","assert":"navigates"}]}]}')"
  undeclared="$(envelope "$out" | jq -r '.measurements[] | select(.statement | test("absent from the walk manifest")) | .count' 2>/dev/null)"
  [ "$undeclared" = "0" ] \
    && pass "a manifest naming every rendered control reports no coverage gap — the measure can read zero as well as non-zero" \
    || fail "full-declaration undeclared count was '$undeclared', expected 0"
}

t_unparseable_job_fails_closed
t_missing_repo_root_fails_closed
t_missing_route_manifest_cmd_fails_closed
t_missing_base_url_env_fails_closed
t_unset_base_url_variable_fails_closed
t_missing_walk_manifest_key_fails_closed
t_unreadable_walk_manifest_fails_closed
t_unknown_verb_fails_closed_and_names_it
t_unwalked_universe_is_never_a_pass
t_fully_excluded_universe_emits_a_pass_envelope
t_result_line_is_the_last_stdout_line
t_exactly_one_result_line
t_envelope_carries_the_fixed_fields
t_envelope_declares_both_measurements
t_envelope_is_valid_json
t_dead_controls_are_found
t_dead_control_finding_is_wellformed
t_dead_control_identity_key_is_r1_safe
t_coverage_gap_is_reported
t_coverage_denominator_comes_from_the_dom
t_full_declaration_reports_no_coverage_gap
t_navigates_catches_a_control_that_goes_nowhere
t_navigates_passes_a_working_control
t_menu_geometry_catches_a_clipped_menu
t_menu_geometry_catches_a_mispositioned_menu
t_menu_geometry_passes_a_wellplaced_menu
t_shows_pending_catches_a_silent_control
t_shows_pending_passes_a_control_with_feedback
t_persists_catches_a_silent_revert
t_persists_passes_a_real_save
t_a_control_that_does_not_render_is_a_finding
t_assertions_executed_counts_every_walked_control
t_findings_carry_real_liveness_numbers
t_a_failing_verb_makes_the_envelope_fail

echo ""
echo "test-sweep-w1: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
