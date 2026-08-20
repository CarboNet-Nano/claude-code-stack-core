#!/usr/bin/env bash
# tests/test-sweep-e1.sh — Tests for E1 (stack ADR-078, task 7 of the
# Sweep serial spine): scripts/sweep/sweep-adapters/nextjs-app-router.sh
# (the route-manifest adapter seam, spec S4.6 [RT-9]) and
# scripts/sweep/checks/e1-load-routes.mjs (the Playwright driver).
#
# Reproduces audit row #10: a *client* render throw — SSR HTML returned
# fine, tsc/tests/build all passed, and the page was blank in production.
# The adapter tests are static (a fixture page.tsx tree, no browser, no
# network). The driver tests run the check for real, against a throwaway
# node:http server, with two exceptions gated on a live chromium probe:
# if this sandbox cannot actually launch a browser (verified directly,
# never assumed), those specific cases are SKIPPED with the probe's own
# failure reason printed — never faked as a pass (house style: see
# tests/test-merger-interactive.sh's "no pty available (sandboxed?)").
#
# Playwright itself is never a stack-repo dependency (Karpathy rule 8):
# it is installed, once per test run, into a throwaway TARGET repo under
# $TMP — exactly the shape the driver expects to find it in (repo_root's
# own node_modules), and exactly the "lazily bootstrapped, never
# vendored" precedent tools/user-docs/.run/ already uses.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/scripts/sweep/sweep-adapters/nextjs-app-router.sh"
CHECK="$REPO_ROOT/scripts/sweep/checks/e1-load-routes.mjs"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

EMIT_LIB="$REPO_ROOT/scripts/sweep/lib/sweep-emit.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available — e1-load-routes.mjs is a node check"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
[ -f "$ADAPTER" ] || { echo "FATAL: $ADAPTER not found"; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
[ -f "$EMIT_LIB" ] || { echo "FATAL: $EMIT_LIB not found"; exit 1; }
# shellcheck source=/dev/null
source "$EMIT_LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-e1-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null' EXIT

# mkpage <file> -> creates an empty page.tsx (and its parent dirs) at <file>.
mkpage() { mkdir -p "$(dirname "$1")" && : > "$1"; }

# =====================================================================
# Adapter tests — static fixture trees, no browser, no network (RT-9)
# =====================================================================

# adapter_routes <route_root> -> sorted route list, one per line.
adapter_routes() { "$ADAPTER" "$1"; }

t_adapter_root_and_nested_pages() {
  local root="$TMP/adapter-basic/src/app"
  mkpage "$root/page.tsx"
  mkpage "$root/foo/page.tsx"
  mkpage "$root/foo/bar/page.tsx"

  local got want
  got="$(adapter_routes "$root")"
  want=$'/\n/foo\n/foo/bar'
  [[ "$got" == "$want" ]] \
    && pass "adapter: src/app/page.tsx -> /, src/app/foo/page.tsx -> /foo, nested -> /foo/bar" \
    || fail "adapter: root/nested mapping (got: $(printf '%q' "$got"))"
}

t_adapter_route_group_stripped() {
  local root="$TMP/adapter-group/src/app"
  mkpage "$root/(marketing)/about/page.tsx"

  local got
  got="$(adapter_routes "$root")"
  [[ "$got" == "/about" ]] \
    && pass "adapter: a route-group segment (marketing) is stripped from the URL" \
    || fail "adapter: route-group stripping (got: $(printf '%q' "$got"))"
}

t_adapter_nested_route_groups_stripped() {
  local root="$TMP/adapter-nested-group/src/app"
  mkpage "$root/(app)/(auth)/login/page.tsx"

  local got
  got="$(adapter_routes "$root")"
  [[ "$got" == "/login" ]] \
    && pass "adapter: two nested route-group segments are both stripped" \
    || fail "adapter: nested route-group stripping (got: $(printf '%q' "$got"))"
}

t_adapter_dynamic_segment_printed_as_is() {
  local root="$TMP/adapter-dynamic/src/app"
  mkpage "$root/users/[id]/page.tsx"

  local got
  got="$(adapter_routes "$root")"
  [[ "$got" == "/users/[id]" ]] \
    && pass "adapter: a dynamic [id] segment is printed as-is (the check decides exclusion, not the adapter)" \
    || fail "adapter: dynamic segment printed as-is (got: $(printf '%q' "$got"))"
}

t_adapter_ignores_non_page_files() {
  local root="$TMP/adapter-nonpage/src/app"
  mkpage "$root/page.tsx"
  : > "$root/layout.tsx"
  mkdir -p "$root/foo"
  : > "$root/foo/loading.tsx"

  local got
  got="$(adapter_routes "$root")"
  [[ "$got" == "/" ]] \
    && pass "adapter: only page.tsx files become routes — layout.tsx/loading.tsx are never enumerated" \
    || fail "adapter: non-page files ignored (got: $(printf '%q' "$got"))"
}

t_adapter_exact_route_list_combined() {
  local root="$TMP/adapter-combined/src/app"
  mkpage "$root/page.tsx"
  mkpage "$root/foo/page.tsx"
  mkpage "$root/(marketing)/about/page.tsx"
  mkpage "$root/users/[id]/page.tsx"
  : > "$root/layout.tsx"

  local got want
  got="$(adapter_routes "$root")"
  want=$'/\n/about\n/foo\n/users/[id]'
  [[ "$got" == "$want" ]] \
    && pass "adapter: exact route list for a combined fixture tree (root, nested, group, dynamic)" \
    || fail "adapter: exact route list (got: $(printf '%q' "$got"), want: $(printf '%q' "$want"))"
}

t_adapter_missing_root_fails_clearly() {
  "$ADAPTER" "$TMP/does-not-exist-$$" >"$TMP/adapter-missing.out" 2>"$TMP/adapter-missing.err"
  local ec=$?
  local out_empty=false
  [[ ! -s "$TMP/adapter-missing.out" ]] && out_empty=true
  [[ "$ec" -ne 0 && "$out_empty" == "true" && -s "$TMP/adapter-missing.err" ]] \
    && pass "adapter: a missing route_root exits non-zero with a stderr message and no routes printed" \
    || fail "adapter: missing route_root (ec=$ec out_empty=$out_empty err=$(cat "$TMP/adapter-missing.err" 2>/dev/null))"
}

# =====================================================================
# Driver tests — the real e1-load-routes.mjs, invoked with sweep-job/v1
# on stdin exactly like sweep-run.sh would (task 4's contract).
# =====================================================================

# new_git_repo <name> -> a real throwaway repo with one commit, so
# `git -C <repo> rev-parse HEAD` (the driver's evidence.commit source)
# succeeds. Mirrors tests/test-sweep-b4.sh's new_repo helper.
new_git_repo() {
  local r="$TMP/repo-$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q -b main && git config user.email t@t.t && git config user.name t \
      && echo x > README.md && git add -A && git commit -qm "chore: init" ) >/dev/null
  echo "$r"
}

# mkmanifest <name> <route...> -> an executable script at $TMP/<name>.sh
# that prints the given routes, one per line — the route_manifest_cmd
# adapter seam [RT-9], deliberately not the Next.js adapter, proving the
# driver is generic over any one-line manifest command.
mkmanifest() {
  local name="$1"; shift
  local f="$TMP/manifest-$name.sh"
  {
    echo '#!/usr/bin/env bash'
    for r in "$@"; do printf 'echo %q\n' "$r"; done
  } > "$f"
  chmod +x "$f"
  echo "$f"
}

# build_job <repo_root> <manifest_cmd> <base_url_env> [exclusions_json]
build_job() {
  jq -cn --arg repo "$1" --arg cmd "$2" --arg baseenv "$3" --argjson excl "${4:-[]}" '
    {schema:"sweep-job/v1", run_id:"2026-08-15T00:00:00Z.test01", check_id:"E1",
     repo_root:$repo, cadence:"push-main", writes_findings:true,
     evidence_basis:"static-source", surface:"ui-route",
     config:{app:"app", route_manifest_cmd:$cmd, base_url_env:$baseenv, exclusions:$excl},
     changed_paths:null, connection:null, budget_ms:120000}'
}

# run_check <job-json> [ENV_VAR=value ...] -> sets ENV_OUT (decoded
# envelope, or "" when there is no result line), RUN_EC (exit code), and
# RUN_STDERR. `env` (not `env -i`) — this suite is not exercising the
# runner's allowlist fence (that is tests/test-sweep-runner.sh's job);
# it only needs to control specific vars like the base URL.
run_check() {
  local job="$1"; shift
  local raw
  raw="$(printf '%s' "$job" | env "$@" node "$CHECK" 2>"$TMP/e1.stderr")"
  RUN_EC=$?
  RUN_STDERR="$(cat "$TMP/e1.stderr")"
  local line
  line="$(grep '^SWEEP_RESULT:v1 ' <<<"$raw" | tail -1)"
  if [[ -n "$line" ]]; then
    ENV_OUT="$(printf '%s' "${line#SWEEP_RESULT:v1 }" | base64 -d 2>/dev/null)"
  else
    ENV_OUT=""
  fi
}

t_driver_playwright_missing_exits_nonzero_no_result_line() {
  local r; r="$(new_git_repo pw-missing)"
  local manifest; manifest="$(mkmanifest pw-missing /a)"
  run_check "$(build_job "$r" "$manifest" SWEEP_TEST_E1_BASE_URL)" SWEEP_TEST_E1_BASE_URL="http://127.0.0.1:1"

  [[ "$RUN_EC" -ne 0 && -z "$ENV_OUT" && "$RUN_STDERR" == *"playwright is not resolvable"* ]] \
    && pass "driver: playwright not resolvable from repo_root's node_modules -> exits non-zero, no result line, clear stderr" \
    || fail "driver: playwright missing (ec=$RUN_EC env_out=$([[ -n "$ENV_OUT" ]] && echo present || echo absent) stderr=$RUN_STDERR)"
}

t_driver_non_next_fixture_nonzero_universe_no_browser_needed() {
  local r; r="$(new_git_repo non-next)"
  # A custom, non-Next-shaped one-line manifest command (RT-9) — every
  # route it prints is a dynamic segment, so every one is excluded by
  # default and the driver never needs a browser to report the universe.
  local manifest; manifest="$(mkmanifest non-next '/users/[id]' '/posts/[slug]' '/x/[y]/[z]')"
  run_check "$(build_job "$r" "$manifest" SWEEP_TEST_E1_BASE_URL)"

  local status universe excluded_n assertions findings_n
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  excluded_n="$(jq -r '.excluded | length' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  local reason0; reason0="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "pass" && "$universe" == "3" && "$excluded_n" == "3" \
     && "$assertions" == "0" && "$findings_n" == "0" \
     && "$reason0" == "dynamic segment needs a sample id" ]] \
    && pass "driver: a non-Next manifest command enumerates a non-zero universe (3), all excluded by default (RT-9, no browser needed)" \
    || fail "driver: non-Next fixture non-zero universe (ec=$RUN_EC status=$status universe=$universe excluded=$excluded_n assertions=$assertions findings=$findings_n reason0=$reason0)"
}

# ---- The two cases below need a real chromium launch. Probed once,
# directly, before deciding to run or skip them — never assumed either
# way (spec's own "never fake a pass" instruction).

PW_AVAILABLE=0
PW_SKIP_REASON=""
PW_TARGET_REPO=""

setup_playwright_target() {
  PW_TARGET_REPO="$(new_git_repo pw-target)"

  if ! command -v npm >/dev/null 2>&1; then
    PW_SKIP_REASON="npm is not available on this machine — cannot install playwright into the target fixture repo"
    return
  fi

  ( cd "$PW_TARGET_REPO" && npm init -y >/dev/null 2>&1 \
      && npm install --no-audit --no-fund playwright@1.62.1 ) >"$TMP/pw-install.log" 2>&1

  if [[ ! -d "$PW_TARGET_REPO/node_modules/playwright" ]]; then
    PW_SKIP_REASON="playwright could not be installed into the target fixture repo — see $TMP/pw-install.log (likely no network egress to registry.npmjs.org here)"
    return
  fi

  local probe
  probe="$(cd "$PW_TARGET_REPO" && node -e '
    const { chromium } = require("playwright");
    (async () => {
      try {
        const b = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
        await b.close();
        console.log("LAUNCH_OK");
      } catch (e) {
        console.log("LAUNCH_FAIL: " + String(e && e.message || e).split("\n")[0]);
      }
    })();
  ' 2>&1)"

  if [[ "$probe" == *LAUNCH_OK* ]]; then
    PW_AVAILABLE=1
  else
    PW_SKIP_REASON="chromium could not actually launch in this sandbox, verified by a direct chromium.launch() probe ($probe) — a sandbox process/mach-port restriction on this machine, not a defect in the check"
  fi
}

# start_test_server -> starts a throwaway node:http server serving /a (a
# script that does not throw), /b and /reports/2026 (scripts that throw —
# the latter to exercise a route whose identity_key would trip R1's 4+
# digit-run refusal verbatim), and /legacy (throws IF fetched — used only
# to prove an excluded route is never requested). Every request path is
# appended to $ACCESS_LOG, one per line, so a test can assert a route was
# never fetched instead of merely asserting on the envelope. Sets
# SERVER_PID, BASE_URL and ACCESS_LOG.
start_test_server() {
  local server_js="$TMP/server.mjs"
  cat > "$server_js" <<'SERVERJS'
import http from "node:http";
import fs from "node:fs";
const accessLog = process.env.ACCESS_LOG;
const ok = (res, marker) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`<html><body><h1>${marker}</h1><script>window.__ok = true;</script></body></html>`);
};
const broken = (res, marker) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`<html><body><h1>${marker}</h1><script>throw new Error('boom-${marker}');</script></body></html>`);
};
const server = http.createServer((req, res) => {
  if (accessLog) fs.appendFileSync(accessLog, req.url + "\n");
  // Chromium logs a failed resource load (a 404) as a console message of
  // type "error" — the browser's own auto-requested /favicon.ico would
  // otherwise false-positive every "ok" route as broken. Answer it clean
  // (204), same as any real app that ships a favicon.
  if (req.url === "/favicon.ico") { res.writeHead(204); return res.end(); }
  if (req.url === "/a") return ok(res, "A");
  if (req.url === "/b") return broken(res, "B");
  if (req.url === "/reports/2026") return broken(res, "reports-2026");
  if (req.url === "/legacy") return broken(res, "legacy-should-never-be-fetched");
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
});
server.listen(0, "127.0.0.1", () => { console.log(server.address().port); });
SERVERJS
  ACCESS_LOG="$(mktemp "$TMP/access-log.XXXXXX")"
  : > "$ACCESS_LOG"
  # A unique port-file per call (never a fixed $TMP/server.port shared
  # across every test's server) plus a 15s budget — under real chromium
  # load (several driver tests in a row each launching/closing a browser)
  # a 5s budget on a shared filename produced a silent race: the NEXT
  # test's wait loop could pass its `-s` check against a STALE file from
  # a server that had not started yet, handing back an empty port and a
  # `http://127.0.0.1/a` URL with no port at all (net::ERR_CONNECTION_REFUSED,
  # misread as the route itself being broken). Fail loudly instead.
  local port_file; port_file="$(mktemp "$TMP/server-port.XXXXXX")"
  ACCESS_LOG="$ACCESS_LOG" node "$server_js" > "$port_file" 2>"$TMP/server.err" &
  SERVER_PID=$!
  local tries=0
  while [[ ! -s "$port_file" && "$tries" -lt 150 ]]; do sleep 0.1; tries=$((tries+1)); done
  local port; port="$(cat "$port_file" 2>/dev/null)"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    echo "FATAL: start_test_server: the throwaway node:http server never reported a port within 15s (got: '$port'; server stderr: $(cat "$TMP/server.err" 2>/dev/null))" >&2
    BASE_URL=""
    return
  fi
  BASE_URL="http://127.0.0.1:$port"
}

stop_test_server() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

t_driver_two_routes_one_broken() {
  local name="driver: two routes (A ok, B throws) -> 1 finding for B, universe_size 2, assertions_executed 2"
  if [[ "$PW_AVAILABLE" != "1" ]]; then
    skip "$name — $PW_SKIP_REASON"
    return
  fi

  start_test_server
  local manifest; manifest="$(mkmanifest ab /a /b)"
  run_check "$(build_job "$PW_TARGET_REPO" "$manifest" SWEEP_TEST_E1_BASE_URL)" SWEEP_TEST_E1_BASE_URL="$BASE_URL"
  stop_test_server

  local status universe assertions passed findings_n ident mech surface found_by plain has_status
  status="$(jq -r '.status' <<<"$ENV_OUT")"
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  passed="$(jq -r '.assertions_passed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  ident="$(jq -r '.findings[0].identity_key' <<<"$ENV_OUT")"
  mech="$(jq -r '.findings[0].mechanism' <<<"$ENV_OUT")"
  surface="$(jq -r '.findings[0].surface' <<<"$ENV_OUT")"
  found_by="$(jq -r '.findings[0].found_by' <<<"$ENV_OUT")"
  plain="$(jq -r '.findings[0].plain' <<<"$ENV_OUT")"
  has_status="$(jq -r '.findings[0] | has("status")' <<<"$ENV_OUT")"

  [[ "$RUN_EC" -eq 0 && "$status" == "fail" && "$universe" == "2" && "$assertions" == "2" && "$passed" == "1" \
     && "$findings_n" == "1" && "$ident" == "/b" && "$mech" == "CONTRACT DRIFT" && "$surface" == "ui-route" \
     && "$found_by" == "sweep-family-E" && "$has_status" == "false" \
     && "$plain" == "The /b screen fails to load — a visitor sees a blank or broken page." ]] \
    && pass "$name" \
    || fail "$name (ec=$RUN_EC status=$status universe=$universe assertions=$assertions passed=$passed findings=$findings_n ident=$ident mech=$mech surface=$surface found_by=$found_by plain=$plain has_status=$has_status)"
}

t_driver_envelope_echoes_job_identity() {
  local name="driver: envelope echoes the job's evidence_basis and surface byte-for-byte"
  if [[ "$PW_AVAILABLE" != "1" ]]; then
    skip "$name — $PW_SKIP_REASON"
    return
  fi

  start_test_server
  local manifest; manifest="$(mkmanifest identity /a)"
  run_check "$(build_job "$PW_TARGET_REPO" "$manifest" SWEEP_TEST_E1_BASE_URL)" SWEEP_TEST_E1_BASE_URL="$BASE_URL"
  stop_test_server

  local schema check_id basis surface
  schema="$(jq -r '.schema' <<<"$ENV_OUT")"
  check_id="$(jq -r '.check_id' <<<"$ENV_OUT")"
  basis="$(jq -r '.evidence_basis' <<<"$ENV_OUT")"
  surface="$(jq -r '.surface' <<<"$ENV_OUT")"

  [[ "$schema" == "sweep-result/v1" && "$check_id" == "E1" && "$basis" == "static-source" && "$surface" == "ui-route" ]] \
    && pass "$name" \
    || fail "$name (schema=$schema check_id=$check_id basis=$basis surface=$surface)"
}

# t_driver_digit_run_route_survives_r1 — fix round 1 (coordinator IMPORTANT
# item). A route containing a 4+ digit run (/reports/2026) would trip
# sweep-emit.sh's real R1 refusal if identity_key were the raw route.
# Proves three things against the REAL sourced sweep_emit_finding, not a
# reimplementation: (1) the emitted identity_key contains no 4+ digit run,
# (2) it round-trips through sweep_emit_finding without refusal, (3) it is
# stable across two independent runs of the same job.
t_driver_digit_run_route_survives_r1() {
  local name="driver: /reports/2026 (a route with a 4+ digit run) breaks -> identity_key is R1-safe, survives the real sweep_emit_finding, stable across reruns"
  if [[ "$PW_AVAILABLE" != "1" ]]; then
    skip "$name — $PW_SKIP_REASON"
    return
  fi

  start_test_server
  local manifest; manifest="$(mkmanifest digit-run /reports/2026)"
  local job; job="$(build_job "$PW_TARGET_REPO" "$manifest" SWEEP_TEST_E1_BASE_URL)"

  run_check "$job" SWEEP_TEST_E1_BASE_URL="$BASE_URL"
  local run1_ec="$RUN_EC" run1_env="$ENV_OUT"
  run_check "$job" SWEEP_TEST_E1_BASE_URL="$BASE_URL"
  local run2_env="$ENV_OUT"
  stop_test_server

  local ident1 ident2 plain
  ident1="$(jq -r '.findings[0].identity_key' <<<"$run1_env")"
  ident2="$(jq -r '.findings[0].identity_key' <<<"$run2_env")"
  plain="$(jq -r '.findings[0].plain' <<<"$run1_env")"

  local r1_safe=true
  [[ "$ident1" =~ [0-9]{4,} ]] && r1_safe=false

  local f fid stamped findings_out emit_ok=false emit_err=""
  f="$(jq -c '.findings[0]' <<<"$run1_env")"
  fid="$(sweep_finding_id repo E1 "CONTRACT DRIFT" "" "$ident1")"
  stamped="$(jq -c --arg fid "$fid" '.schema="finding-record/v1" | .finding_id=$fid
    | .run_id="2026-08-15T00:00:00Z.test01" | .repo="repo" | .created_at="2026-08-15T00:00:00Z"' <<<"$f")"
  findings_out="$(mktemp "$TMP/findings.XXXXXX")"
  if sweep_emit_finding "$findings_out" "$stamped" 2>"$TMP/emit.err"; then
    emit_ok=true
  else
    emit_err="$(cat "$TMP/emit.err" 2>/dev/null)"
  fi
  local emit_lines; emit_lines="$(wc -l < "$findings_out" 2>/dev/null | tr -d ' ')"

  [[ "$run1_ec" -eq 0 && "$r1_safe" == "true" && -n "$ident1" && "$ident1" == "$ident2" \
     && "$emit_ok" == "true" && "$emit_lines" == "1" \
     && "$plain" == "The /reports/2026 screen fails to load — a visitor sees a blank or broken page." ]] \
    && pass "$name" \
    || fail "$name (ec=$run1_ec ident1=$ident1 ident2=$ident2 r1_safe=$r1_safe emit_ok=$emit_ok emit_err=$emit_err emit_lines=$emit_lines plain=$plain)"
}

# t_driver_exclusion_declared_never_fetched — fix round 1 (coordinator
# COVERAGE item). config.exclusions[] was implemented but never exercised
# by a test. /legacy is declared excluded with its own reason (distinct
# from the dynamic-segment default); the server would fail it if fetched,
# so the ACCESS_LOG proving it was never requested is a real assertion,
# not a tautology.
t_driver_exclusion_declared_never_fetched() {
  local name="driver: a config.exclusions[] entry appears in excluded[] with its own reason, and its route is never fetched"
  if [[ "$PW_AVAILABLE" != "1" ]]; then
    skip "$name — $PW_SKIP_REASON"
    return
  fi

  start_test_server
  local manifest; manifest="$(mkmanifest exclusion /a /legacy)"
  local excl_json='[{"unit":"/legacy","reason":"read-only import artifact, ADR-041"}]'
  run_check "$(build_job "$PW_TARGET_REPO" "$manifest" SWEEP_TEST_E1_BASE_URL "$excl_json")" SWEEP_TEST_E1_BASE_URL="$BASE_URL"
  stop_test_server

  local universe excluded_n unit reason assertions findings_n fetched_legacy
  universe="$(jq -r '.universe_size' <<<"$ENV_OUT")"
  excluded_n="$(jq -r '.excluded | length' <<<"$ENV_OUT")"
  unit="$(jq -r '.excluded[0].unit' <<<"$ENV_OUT")"
  reason="$(jq -r '.excluded[0].reason' <<<"$ENV_OUT")"
  assertions="$(jq -r '.assertions_executed' <<<"$ENV_OUT")"
  findings_n="$(jq -r '.findings | length' <<<"$ENV_OUT")"
  fetched_legacy="no"
  grep -qx "/legacy" "$ACCESS_LOG" 2>/dev/null && fetched_legacy="yes"

  [[ "$RUN_EC" -eq 0 && "$universe" == "2" && "$excluded_n" == "1" && "$unit" == "/legacy" \
     && "$reason" == "read-only import artifact, ADR-041" && "$reason" != "dynamic segment needs a sample id" \
     && "$assertions" == "1" && "$findings_n" == "0" && "$fetched_legacy" == "no" ]] \
    && pass "$name" \
    || fail "$name (ec=$RUN_EC universe=$universe excluded=$excluded_n unit=$unit reason=$reason assertions=$assertions findings=$findings_n fetched_legacy=$fetched_legacy)"
}

t_adapter_root_and_nested_pages
t_adapter_route_group_stripped
t_adapter_nested_route_groups_stripped
t_adapter_dynamic_segment_printed_as_is
t_adapter_ignores_non_page_files
t_adapter_exact_route_list_combined
t_adapter_missing_root_fails_clearly

t_driver_playwright_missing_exits_nonzero_no_result_line
t_driver_non_next_fixture_nonzero_universe_no_browser_needed

setup_playwright_target
t_driver_two_routes_one_broken
t_driver_envelope_echoes_job_identity
t_driver_digit_run_route_survives_r1
t_driver_exclusion_declared_never_fetched

echo "----"
echo "test-sweep-e1: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
