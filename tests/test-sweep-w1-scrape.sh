#!/usr/bin/env bash
# tests/test-sweep-w1-scrape.sh — w1-scrape.mjs, the read-only control
# inventory.
#
# W1 proper needs a walk manifest and clicks things. This does neither: it
# opens each screen, lists every interactive control it can see, flags the
# ones wired to nothing, and writes a starter manifest. It is what you run
# against an app BEFORE you have a manifest — including an app whose team
# has hand-written browser checks already and wants to know what those
# checks never mention.
#
# Read-only is enforced, not merely intended: a test asserts no control is
# ever activated.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRAPE="$REPO_ROOT/scripts/sweep/w1-scrape.mjs"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
[ -f "$SCRAPE" ] || { echo "FATAL: $SCRAPE not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/w1-scrape-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PW_HOST=""
for cand in ${W1_PLAYWRIGHT_HOST:-} "$HOME/Claude/carbonet-hr-sync" "$HOME/Claude/SpecOps"; do
  [ -n "$cand" ] && [ -d "$cand/node_modules/playwright" ] && { PW_HOST="$cand"; break; }
done

chromium_probe() {
  [ -n "$PW_HOST" ] || { echo "no resolvable playwright install found"; return; }
  node --input-type=module -e "
    import { createRequire } from 'node:module';
    const require = createRequire('$PW_HOST/');
    try { const { chromium } = require('playwright'); const b = await chromium.launch(); await b.close(); process.stdout.write(''); }
    catch (e) { process.stdout.write('LAUNCH_FAIL: ' + e.message.split('\\n')[0]); }
  " 2>&1
}

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

free_port() { node -e "const n=require('net');const s=n.createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})"; }

# scrape_run <name> <html> [extra-args...] -> stdout of a real scrape
scrape_run() {
  local name="$1" html="$2"; shift 2
  local dir="$TMP/$name"
  mkdir -p "$dir/site" "$dir/node_modules"
  printf '%s' "$html" > "$dir/site/index.html"
  ln -sf "$PW_HOST/node_modules/playwright" "$dir/node_modules/playwright" 2>/dev/null
  ln -sf "$PW_HOST/node_modules/playwright-core" "$dir/node_modules/playwright-core" 2>/dev/null
  local port; port="$(free_port)"
  local pid; pid="$(serve "$dir/site" "$port")"
  sleep 1
  node "$SCRAPE" --base "http://127.0.0.1:$port" --screens / --repo "$dir" "$@" 2>&1
  kill "$pid" 2>/dev/null
}

RICH_HTML='<!doctype html><html><body>
<button onclick="void 0">Save</button>
<button>Edit flow</button>
<a href="/other">Next</a>
<a href="#">Nowhere</a>
<button data-inert="decorative">Badge</button>
<div role="combobox">Tax type</div>
</body></html>'

# ---- argument handling (no browser) ---------------------------------

t_no_base_exits_nonzero() {
  local rc
  node "$SCRAPE" --screens / >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && pass "no --base exits non-zero rather than scraping nothing" || fail "no --base exited 0"
}

t_no_screens_exits_nonzero() {
  local rc
  node "$SCRAPE" --base http://127.0.0.1:1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && pass "no --screens exits non-zero — an empty screen list is not an empty result" || fail "no --screens exited 0"
}

t_unreachable_base_exits_nonzero() {
  local rc
  [ -n "$PW_HOST" ] || { skip "an unreachable base exits non-zero — no playwright install found"; return; }
  local dir="$TMP/unreachable"; mkdir -p "$dir/node_modules"
  ln -sf "$PW_HOST/node_modules/playwright" "$dir/node_modules/playwright" 2>/dev/null
  ln -sf "$PW_HOST/node_modules/playwright-core" "$dir/node_modules/playwright-core" 2>/dev/null
  node "$SCRAPE" --base http://127.0.0.1:1 --screens / --repo "$dir" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && pass "an unreachable base exits non-zero rather than reporting zero controls" || fail "unreachable base exited 0"
}

# ---- the inventory (browser) ----------------------------------------

t_lists_every_interactive_control() {
  local probe out n
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "every interactive control is listed — chromium could not launch here ($probe)"; return; }
  out="$(scrape_run list-all "$RICH_HTML" --json)"
  n="$(printf '%s' "$out" | jq -r '.screens[0].controls | length' 2>/dev/null)"
  [ "$n" = "6" ] \
    && pass "every interactive control is listed — buttons, links, and a role=combobox alike" \
    || fail "control count was '$n', expected 6"
}

t_flags_dead_controls() {
  local probe out dead
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "controls wired to nothing are flagged — chromium could not launch here ($probe)"; return; }
  out="$(scrape_run flag-dead "$RICH_HTML" --json)"
  dead="$(printf '%s' "$out" | jq -r '[.screens[0].controls[] | select(.dead)] | map(.name) | sort | join(",")' 2>/dev/null)"
  [ "$dead" = "Edit flow,Nowhere,Tax type" ] \
    && pass "controls wired to nothing are flagged — including a role-only element with no handler at all — while data-inert is respected" \
    || fail "dead list was '$dead', expected 'Edit flow,Nowhere,Tax type'"
}

t_framework_wired_controls_are_not_flagged_dead() {
  local probe out dead
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "a framework-wired control is not flagged dead — chromium could not launch here ($probe)"; return; }
  # React attaches listeners at the ROOT container, never on the element,
  # so el.onclick is null for every React button ever rendered. This fixture
  # reproduces the shape React 17+ leaves on the DOM node. Without the
  # framework branch the inventory reports an entire React app dead.
  out="$(scrape_run react-wired '<!doctype html><html><body><button id="r">Approve</button><button id="d">Ghost</button><script>document.getElementById("r")["__reactProps$abc123"]={onClick:function(){}};</script></body></html>' --json)"
  dead="$(printf '%s' "$out" | jq -r '[.screens[0].controls[] | select(.dead)] | map(.name) | join(",")' 2>/dev/null)"
  [ "$dead" = "Ghost" ] \
    && pass "a React-wired control is NOT flagged dead, while a truly handlerless one beside it still is" \
    || fail "dead list was '$dead', expected only 'Ghost'"
}

t_never_activates_a_control() {
  local probe out
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "the scrape never activates a control — chromium could not launch here ($probe)"; return; }
  # Any click on this page rewrites the document; if the scrape clicked,
  # the control list would come back as the single button CLICKED renders.
  out="$(scrape_run read-only '<!doctype html><html><body><button onclick="document.body.innerHTML=&quot;<button>CLICKED</button>&quot;">Save</button></body></html>' --json)"
  printf '%s' "$out" | jq -e '[.screens[0].controls[].name] | index("CLICKED") == null' >/dev/null 2>&1 \
    && pass "the scrape never activates a control — read-only is enforced, not merely intended" \
    || fail "the scrape activated a control: $(printf '%s' "$out" | head -3)"
}

t_emits_a_starter_manifest() {
  local probe out
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "a starter walk manifest is emitted — chromium could not launch here ($probe)"; return; }
  out="$(scrape_run starter "$RICH_HTML" --emit-manifest)"
  printf '%s' "$out" | jq -e '.screens[0].controls | length > 0 and (.[0] | has("find") and has("assert"))' >/dev/null 2>&1 \
    && pass "--emit-manifest writes a walk manifest in W1's own shape, ready to edit" \
    || fail "starter manifest was: $(printf '%s' "$out" | head -3)"
}

t_starter_manifest_parses_as_a_real_manifest() {
  local probe out
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "the starter manifest is accepted by W1's own parser — chromium could not launch here ($probe)"; return; }
  out="$(scrape_run starter-valid "$RICH_HTML" --emit-manifest)"
  printf '%s' "$out" > "$TMP/starter.json"
  node --input-type=module -e "
    import { parseWalkManifest } from '$REPO_ROOT/scripts/sweep/lib/w1-manifest.mjs';
    import { readFileSync } from 'node:fs';
    parseWalkManifest(readFileSync('$TMP/starter.json','utf8'));
    process.stdout.write('OK');
  " 2>/dev/null | grep -q OK \
    && pass "the emitted manifest is accepted by W1's own parser — the starter is not a shape W1 would reject" \
    || fail "the emitted manifest did not parse"
}

t_plain_output_names_the_dead_controls() {
  local probe out
  probe="$(chromium_probe)"
  [ -n "$probe" ] && { skip "the plain report names dead controls — chromium could not launch here ($probe)"; return; }
  out="$(scrape_run plain-report "$RICH_HTML")"
  printf '%s' "$out" | grep -q 'Edit flow' && printf '%s' "$out" | grep -qi 'dead' \
    && pass "the default report names each dead control in plain text" \
    || fail "plain report was: $(printf '%s' "$out" | head -5)"
}

t_no_base_exits_nonzero
t_no_screens_exits_nonzero
t_unreachable_base_exits_nonzero
t_lists_every_interactive_control
t_flags_dead_controls
t_framework_wired_controls_are_not_flagged_dead
t_never_activates_a_control
t_emits_a_starter_manifest
t_starter_manifest_parses_as_a_real_manifest
t_plain_output_names_the_dead_controls

echo ""
echo "test-sweep-w1-scrape: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
