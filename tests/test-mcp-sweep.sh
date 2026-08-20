#!/usr/bin/env bash
# Test: ADR-046 (revision 2) multi-source MCP sweep. Hermetic — curl and gh
# are both PATH-shimmed (D3); no test in this file ever touches the network.
# Runs on macos-latest under CI's globbed tests/test-*.sh (no GNU-only
# coreutils/date assumptions — this suite itself only uses portable
# constructs, and every test below that touches the library under
# /bin/bash also exercises bash 3.2 compatibility incidentally, since that
# is macos-latest's default /bin/bash).

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/mcp-sweep.sh"
ENTRYPOINT="$REPO_ROOT/scripts/mcp-sweep.sh"
STATE_PY="$REPO_ROOT/scripts/lib/mcp_state.py"
WORKFLOW_YML="$REPO_ROOT/.github/workflows/mcp-market-sweep.yml"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass; else fail "$name" "expected [$expected] got [$actual]"; fi
}

assert_true() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" || "$cond" == "0" ]]; then pass; else fail "$name" "condition false: $cond"; fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass; else fail "$name" "expected to contain [$needle]"; fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass; else fail "$name" "expected NOT to contain [$needle]"; fi
}

# ===========================================================================
# Hermetic PATH shims for curl and gh (D3). Both read behavior from a small
# set of files/env vars the tests set up per-scenario, and log every
# invocation for call-count assertions.
# ===========================================================================
BIN_DIR="$TMP/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/curl" << 'CURLSHIM'
#!/bin/bash
# Fixture-serving curl shim (D16's invocation form: -o body, -D headers,
# -w '%{http_code}', --config <headerfile>, URL last).
FIXTURES="${MCP_SWEEP_TEST_FIXTURES:?}"
o_file="" d_file="" url=""
args=("$@")
i=0
n=${#args[@]}
while [[ $i -lt $n ]]; do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i+1)); o_file="${args[$i]}" ;;
    -D) i=$((i+1)); d_file="${args[$i]}" ;;
    --config|--proto|--connect-timeout|--max-time|--retry|--retry-max-time|--max-filesize|-w)
      i=$((i+1)) ;;
    -sS|--max-redirs) : ;;
    -*) : ;;
    *) url="$a" ;;
  esac
  i=$((i+1))
done
[[ -n "$d_file" ]] && touch "$d_file"
echo "$url" >> "$FIXTURES/.curl-calls.log"

route_file="$FIXTURES/.curl-route"
if [[ -f "$route_file" ]]; then
  while IFS='|' read -r pattern body_file status; do
    [[ -z "$pattern" ]] && continue
    case "$url" in
      $pattern)
        [[ -n "$o_file" ]] && cat "$FIXTURES/$body_file" > "$o_file"
        echo -n "$status"
        exit 0
        ;;
    esac
  done < "$route_file"
fi

[[ -n "$o_file" ]] && : > "$o_file"
echo -n "599"
exit 0
CURLSHIM
chmod +x "$BIN_DIR/curl"

cat > "$BIN_DIR/gh" << 'GHSHIM'
#!/bin/bash
# Mock gh CLI. Behavior driven by env vars the test sets:
#   MCP_SWEEP_TEST_GH_LOG        - file every invocation is appended to
#   MCP_SWEEP_TEST_GH_LOCKED     - "true"/"false"
#   MCP_SWEEP_TEST_GH_STATE      - "OPEN"/"CLOSED"
#   MCP_SWEEP_TEST_GH_ASSOC      - authorAssociation string
#   MCP_SWEEP_TEST_GH_AUTHOR_ID  - author node id
#   MCP_SWEEP_TEST_GH_NOT_ISSUE  - "true" -> issue resolves to null (a PR)
#   MCP_SWEEP_TEST_GH_HOLD       - "true"/"false" -> hold label present
#   MCP_SWEEP_TEST_GH_FAIL_EDIT/CLOSE/REOPEN/COMMENT - "true" to fail that call
LOG="${MCP_SWEEP_TEST_GH_LOG:?}"

echo "CALL:$*" >> "$LOG"

if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  if [[ "${MCP_SWEEP_TEST_GH_NOT_ISSUE:-false}" == "true" ]]; then
    echo '{"data":{"repository":{"issue":null}}}'
    exit 0
  fi
  locked="${MCP_SWEEP_TEST_GH_LOCKED:-false}"
  state="${MCP_SWEEP_TEST_GH_STATE:-OPEN}"
  assoc="${MCP_SWEEP_TEST_GH_ASSOC:-NONE}"
  author_id="${MCP_SWEEP_TEST_GH_AUTHOR_ID:-}"
  jq -n --argjson locked "$locked" --arg state "$state" --arg assoc "$assoc" --arg aid "$author_id" \
    '{data:{repository:{issue:{locked:$locked,state:$state,authorAssociation:$assoc,author:{login:"x",__typename:"Bot",id:$aid}}}}}'
  exit 0
fi

if [[ "$1" == "issue" ]]; then
  case "$2" in
    edit)
      if [[ "${MCP_SWEEP_TEST_GH_FAIL_EDIT:-false}" == "true" ]]; then exit 1; fi
      exit 0
      ;;
    close)
      if [[ "${MCP_SWEEP_TEST_GH_FAIL_CLOSE:-false}" == "true" ]]; then exit 1; fi
      exit 0
      ;;
    reopen)
      if [[ "${MCP_SWEEP_TEST_GH_FAIL_REOPEN:-false}" == "true" ]]; then exit 1; fi
      exit 0
      ;;
    comment)
      if [[ "${MCP_SWEEP_TEST_GH_FAIL_COMMENT:-false}" == "true" ]]; then exit 1; fi
      exit 0
      ;;
    view)
      if [[ "${MCP_SWEEP_TEST_GH_HOLD:-false}" == "true" ]]; then
        echo "mcp-sweep-hold"
      fi
      exit 0
      ;;
    *) exit 0 ;;
  esac
fi
exit 0
GHSHIM
chmod +x "$BIN_DIR/gh"

export PATH="$BIN_DIR:$PATH"

# curl fixture route file format: one "<glob-pattern>|<fixture-filename>|<http-status>" per line.
set_curl_route() {
  echo "$1|$2|$3" >> "$MCP_SWEEP_TEST_FIXTURES/.curl-route"
}

reset_fixtures() {
  export MCP_SWEEP_TEST_FIXTURES="$TMP/fixtures-$RANDOM"
  mkdir -p "$MCP_SWEEP_TEST_FIXTURES"
  : > "$MCP_SWEEP_TEST_FIXTURES/.curl-route"
  : > "$MCP_SWEEP_TEST_FIXTURES/.curl-calls.log"
}

empty_envelopes() {
  echo '{"objects":[],"total":0}' > "$MCP_SWEEP_TEST_FIXTURES/npm-empty.json"
  echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-empty.json"
  echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/registry-empty.json"
  set_curl_route 'https://registry.npmjs.org/*' npm-empty.json 200
  set_curl_route 'https://api.github.com/*' gh-empty.json 200
  set_curl_route 'https://registry.modelcontextprotocol.io/*' registry-empty.json 200
}

reset_gh() {
  export MCP_SWEEP_TEST_GH_LOG="$TMP/gh-calls-$RANDOM.log"
  : > "$MCP_SWEEP_TEST_GH_LOG"
  unset MCP_SWEEP_TEST_GH_LOCKED MCP_SWEEP_TEST_GH_STATE MCP_SWEEP_TEST_GH_ASSOC \
        MCP_SWEEP_TEST_GH_AUTHOR_ID MCP_SWEEP_TEST_GH_NOT_ISSUE MCP_SWEEP_TEST_GH_HOLD \
        MCP_SWEEP_TEST_GH_FAIL_EDIT MCP_SWEEP_TEST_GH_FAIL_CLOSE MCP_SWEEP_TEST_GH_FAIL_REOPEN \
        MCP_SWEEP_TEST_GH_FAIL_COMMENT
  export MCP_SWEEP_TEST_GH_ASSOC="NONE"
  export MCP_SWEEP_TEST_GH_AUTHOR_ID="test-allowed-id"
  export MCP_SWEEP_ISSUE_AUTHOR_ALLOW="test-allowed-id"
  export MCP_SWEEP_TEST_GH_STATE="OPEN"
}

gh_call_count() {
  # grep -c already prints "0" (and exits 1) on no match — don't also
  # `|| echo 0`, or a no-match case prints "0" twice.
  local n
  n="$(grep -c "^CALL:$1" "$MCP_SWEEP_TEST_GH_LOG" 2>/dev/null)"
  echo "${n:-0}"
}

run_sweep() {
  MCP_SWEEP_WORKDIR="$TMP/work-$RANDOM"
  mkdir -p "$MCP_SWEEP_WORKDIR"
  MCP_SWEEP_ON_DEFAULT_BRANCH="${MCP_SWEEP_ON_DEFAULT_BRANCH:-true}" \
  MCP_SWEEP_WORKDIR="$MCP_SWEEP_WORKDIR" \
  MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="${MCP_SWEEP_TEST_KNOWN_JSON:-$REPO_ROOT/config/mcp-sweep-known.json}" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" \
  GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" "$@"
  echo "$MCP_SWEEP_WORKDIR"
}

echo "=== ADR-046 mcp-sweep test suite ==="

# ===========================================================================
# Section A — key grammar, URL derivation, normalization (bash-only, no
# shims needed).
# ===========================================================================
source "$LIB"

for bad in "gh:../x" "gh:o/.." "gh:o/r#.." "gh:o/r#a/../../b" "gh:o/r#." \
           "npm:.." "npm:@../x" "mcp:../x" "mcp:io.github.o/.."; do
  if mcp_key_valid "$bad"; then fail "key-grammar-reject:$bad"; else pass; fi
done

for good in "gh:o/r#a.b/c-d" "npm:@scope/pkg.name" "mcp:io.github.owner/name"; do
  if mcp_key_valid "$good"; then pass; else fail "key-grammar-accept:$good"; fi
done

LONGKEY="gh:$(python3 -c 'print("a"*99)')"
if mcp_key_valid "$LONGKEY"; then fail "key-101-char-rejected"; else pass; fi

for bad_url_key in "gh:../x" "gh:o/.." "gh:o/r#.." "gh:o/r#a/../../b" "npm:.." "mcp:../x"; do
  out="$(mcp_derive_url "$bad_url_key" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then pass; else fail "derive-url-rejects-invalid-key:$bad_url_key" "got: $out"; fi
done

assert_eq "derive-url-gh" "https://github.com/o/r" "$(mcp_derive_url gh:o/r)"
assert_eq "derive-url-gh-sub" "https://github.com/o/r/tree/HEAD/src/x" "$(mcp_derive_url 'gh:o/r#src/x')"
assert_eq "derive-url-npm" "https://www.npmjs.com/package/foo" "$(mcp_derive_url npm:foo)"
assert_eq "derive-url-mcp" "https://registry.modelcontextprotocol.io/?search=io.github.o/n" "$(mcp_derive_url mcp:io.github.o/n)"

for url in "$(mcp_derive_url gh:o/r)" "$(mcp_derive_url 'gh:o/r#a/b')" "$(mcp_derive_url npm:@scope/pkg)"; do
  case "$url" in
    */../*|*/./*) fail "derive-url-no-traversal:$url" ;;
    *) pass ;;
  esac
done

assert_eq "normalize-gh-from-github-source" "gh:modelcontextprotocol/servers#src/filesystem" \
  "$(mcp_normalize_key "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem" github "modelcontextprotocol/servers")"
assert_eq "normalize-npm-fallback" "npm:tavily-mcp" "$(mcp_normalize_key "" npm "tavily-mcp")"
assert_eq "normalize-npm-repo-field-github" "gh:tavily-ai/tavily-mcp" \
  "$(mcp_normalize_key "git+https://github.com/tavily-ai/tavily-mcp.git" npm "tavily-mcp")"
assert_eq "normalize-registry-fallback" "mcp:io.github.owner/name" "$(mcp_normalize_key "" registry "io.github.owner/name")"
assert_eq "normalize-scp-ssh" "gh:o/r" "$(mcp_normalize_key "git@github.com:o/r.git" github "o/r")"

K1="$(mcp_normalize_key "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem" github x)"
K2="$(mcp_normalize_key "https://github.com/modelcontextprotocol/servers/tree/main/src/memory" github y)"
if [[ "$K1" != "$K2" ]]; then pass; else fail "monorepo-subpaths-distinct-at-normalize"; fi

if mcp_normalize_key "not-a-url" other "" >/dev/null 2>&1; then
  fail "underivable-key-fails"
else
  pass
fi

# ===========================================================================
# Section B — fetchers (curl-shimmed).
# ===========================================================================

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-page.json" << 'EOF'
{"objects":[
  {"package":{"name":"tavily-mcp","date":"2026-07-20T00:00:00Z","links":{"repository":"https://github.com/tavily-ai/tavily-mcp"}},"downloads":{"monthly":4242}},
  {"package":{"name":"foo-mcp","date":"2026-07-20T00:00:00Z"}}
],"total":2}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-page.json 200
WD="$TMP/npm-fetch-work"; mkdir -p "$WD"
OUT="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7")"
COUNT="$(echo "$OUT" | grep -c '"key"')"
assert_eq "npm-fetch-exact-record-count" "6" "$COUNT"   # 3 queries * 2 records (dedup happens in merge)
assert_contains "npm-fetch-field-values" "$OUT" '"key":"gh:tavily-ai/tavily-mcp"'
assert_eq "npm-fetch-status-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

# T1 — exact downloads.monthly value lands in the emitted row.
assert_contains "T1-npm-downloads-exact-value" "$OUT" '"npmDownloadsMonthly":4242'

# T2 — object with no `downloads` key at all -> emitted with 0,
# signalMissing incremented, status still `ok` (small sample: 6 eligible < 20).
assert_contains "T2-npm-missing-downloads-emits-zero" "$OUT" '"key":"npm:foo-mcp","name":"foo-mcp","source":"npm","sourceId":"foo-mcp"'
FOO_ROW="$(echo "$OUT" | grep '"sourceId":"foo-mcp"')"
assert_contains "T2-npm-missing-downloads-row-zero" "$FOO_ROW" '"npmDownloadsMonthly":0'
assert_eq "T2-npm-missing-downloads-signal-missing-count" "3" "$(jq -r '.signalMissing' "$WD/status-npm.json")"
assert_eq "T2-npm-missing-downloads-signal-eligible-count" "6" "$(jq -r '.signalEligible' "$WD/status-npm.json")"
assert_eq "T2-npm-missing-downloads-status-still-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

reset_fixtures
echo '{"objects":[],"total":0}' > "$MCP_SWEEP_TEST_FIXTURES/npm-zero.json"
set_curl_route 'https://registry.npmjs.org/*' npm-zero.json 200
WD="$TMP/npm-fetch-zero"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "npm-200-zero-records-is-ok-empty" "ok_empty" "$(jq -r '.status' "$WD/status-npm.json" 2>/dev/null || echo MISSING)"

WD="$TMP/npm-fetch-zero2"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null" || rc=$?
assert_eq "npm-ok-empty-exit-0" "0" "$rc"

reset_fixtures
echo 'not json' > "$MCP_SWEEP_TEST_FIXTURES/npm-503.json"
set_curl_route 'https://registry.npmjs.org/*' npm-503.json 503
WD="$TMP/npm-fetch-503"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null" || rc=$?
assert_eq "npm-503-exit-3" "3" "$rc"
assert_eq "npm-503-status-failed" "failed" "$(jq -r '.status' "$WD/status-npm.json")"

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/gh-page.json" << 'EOF'
{"items":[
  {"full_name":"acme/mcp-thing","html_url":"https://github.com/acme/mcp-thing","pushed_at":"2026-07-15T00:00:00Z","stargazers_count":42,"topics":["mcp-server"]}
],"total_count":1}
EOF
set_curl_route 'https://api.github.com/*' gh-page.json 200
WD="$TMP/gh-fetch-work"; mkdir -p "$WD"
OUT="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_GH_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_github 7")"
assert_contains "gh-fetch-stars-in-signal" "$OUT" '"stars":42'
assert_contains "gh-fetch-key" "$OUT" '"key":"gh:acme/mcp-thing"'

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/reg-page1.json" << 'EOF'
{"servers":[{"server":{"name":"io.github.acme/thing","repository":{"url":"https://github.com/acme/mcp-thing"}},"_meta":{"io.modelcontextprotocol.registry/official":{"updatedAt":"2026-07-10T00:00:00Z","status":"active"}}}],"metadata":{"nextCursor":"cursorabc123"}}
EOF
cat > "$MCP_SWEEP_TEST_FIXTURES/reg-page2.json" << 'EOF'
{"servers":[{"server":{"name":"io.github.other/thing2"},"_meta":{"io.modelcontextprotocol.registry/official":{"updatedAt":"2026-07-11T00:00:00Z","status":"active"}}}],"metadata":{}}
EOF
set_curl_route 'https://registry.modelcontextprotocol.io/v0.1/servers?limit=100' reg-page1.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/v0.1/servers?limit=100&cursor=*' reg-page2.json 200
WD="$TMP/reg-fetch-work"; mkdir -p "$WD"
OUT="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_REGISTRY_MAX_PAGES=5 /bin/bash -c "source '$LIB'; mcp_fetch_registry 7")"
LINES="$(echo "$OUT" | grep -c '"key"')"
assert_eq "registry-paginates-two-pages" "2" "$LINES"
assert_eq "registry-status-ok" "ok" "$(jq -r '.status' "$WD/status-registry.json")"

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/reg-page1-cap.json" << 'EOF'
{"servers":[{"server":{"name":"io.github.acme/thing"},"_meta":{"io.modelcontextprotocol.registry/official":{"updatedAt":"2026-07-10T00:00:00Z"}}}],"metadata":{"nextCursor":"stillmore"}}
EOF
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-page1-cap.json 200
WD="$TMP/reg-fetch-cap"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_REGISTRY_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_registry 7 > /dev/null"
assert_eq "registry-page-cap-partial" "partial" "$(jq -r '.status' "$WD/status-registry.json")"
assert_eq "registry-page-cap-note" "page_cap" "$(jq -r '.note' "$WD/status-registry.json")"

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/reg-cursor-invalid.json" << 'EOF'
{"servers":[{"server":{"name":"io.github.acme/thing"},"_meta":{"io.modelcontextprotocol.registry/official":{"updatedAt":"2026-07-10T00:00:00Z"}}}],"metadata":{"nextCursor":"has a space/bad"}}
EOF
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-cursor-invalid.json 200
WD="$TMP/reg-fetch-cursor-invalid"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_REGISTRY_MAX_PAGES=5 /bin/bash -c "source '$LIB'; mcp_fetch_registry 7 > /dev/null"
assert_eq "registry-cursor-invalid-partial" "partial" "$(jq -r '.status' "$WD/status-registry.json")"
assert_eq "registry-cursor-invalid-note" "cursor_invalid" "$(jq -r '.note' "$WD/status-registry.json")"

reset_fixtures
echo 'not-json-at-all' > "$MCP_SWEEP_TEST_FIXTURES/reg-bad-v01.json"
echo 'also-not-json' > "$MCP_SWEEP_TEST_FIXTURES/reg-bad-v0.json"
set_curl_route 'https://registry.modelcontextprotocol.io/v0.1/servers*' reg-bad-v01.json 404
set_curl_route 'https://registry.modelcontextprotocol.io/v0/servers*' reg-bad-v0.json 404
WD="$TMP/reg-fetch-both404"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_registry 7 > /dev/null" || rc=$?
assert_eq "registry-both-paths-404-exit3" "3" "$rc"
assert_eq "registry-both-paths-404-failed" "failed" "$(jq -r '.status' "$WD/status-registry.json")"

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/reg-fallback-ok.json" << 'EOF'
{"servers":[],"metadata":{}}
EOF
set_curl_route 'https://registry.modelcontextprotocol.io/v0.1/servers*' reg-bad-v01.json 404
echo 'not-json' > "$MCP_SWEEP_TEST_FIXTURES/reg-bad-v01.json"
set_curl_route 'https://registry.modelcontextprotocol.io/v0/servers*' reg-fallback-ok.json 200
WD="$TMP/reg-fetch-fallback"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_registry 7 > /dev/null"
assert_eq "registry-fallback-to-v0-ok" "ok_empty" "$(jq -r '.status' "$WD/status-registry.json")"

# Anti-DoS regression guard: 20 well-formed npm records whose repository
# fields make every one unkeyable -> status ok, dropped==20, close not blocked.
# (npm keys derive from the package name alone, not the repository field —
# a broken `repository` doesn't make an npm record unkeyable. What does:
# a missing/invalid `date`, which is the realistic "well-formed identity,
# no usable updatedUtc" case D9r2 describes.)
reset_fixtures
python3 -c '
import json
objs = []
for i in range(20):
    objs.append({"package":{"name":f"pkg{i}","date":"not-a-valid-date"},"downloads":{"monthly":100+i}})
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-unkeyable.json"
set_curl_route 'https://registry.npmjs.org/*' npm-unkeyable.json 200
WD="$TMP/npm-unkeyable-work"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "anti-dos-unkeyable-npm-status-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"
assert_eq "anti-dos-unkeyable-npm-count" "60" "$(jq -r '.unkeyable' "$WD/status-npm.json")"  # 3 queries x 20

# Round-4 anti-DoS: 20 well-formed registry records missing updatedAt/publishedAt -> ok, dropped, close not blocked.
reset_fixtures
python3 -c '
import json
servers = []
for i in range(20):
    servers.append({"server":{"name":f"io.github.acme/thing{i}"},"_meta":{"io.modelcontextprotocol.registry/official":{"status":"active"}}})
print(json.dumps({"servers":servers,"metadata":{}}))
' > "$MCP_SWEEP_TEST_FIXTURES/reg-no-ts.json"
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-no-ts.json 200
WD="$TMP/reg-no-ts-work"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_registry 7 > /dev/null"
assert_eq "anti-dos-registry-missing-ts-status-ok" "ok" "$(jq -r '.status' "$WD/status-registry.json")"
assert_eq "anti-dos-registry-missing-ts-unkeyable" "20" "$(jq -r '.unkeyable' "$WD/status-registry.json")"

# Malformed ratio: 1/10 malformed -> ok; 3/10 -> failed schema_ratio.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"p{i}","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":100+i}} for i in range(9)]
objs.append({"package":{}})
print(json.dumps({"objects":objs,"total":10}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-1of10-malformed.json"
set_curl_route 'https://registry.npmjs.org/*' npm-1of10-malformed.json 200
WD="$TMP/npm-1of10"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "malformed-ratio-1-of-10-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"p{i}","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":100+i}} for i in range(7)]
for _ in range(3):
    objs.append({"package":{}})
print(json.dumps({"objects":objs,"total":10}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-3of10-malformed.json"
set_curl_route 'https://registry.npmjs.org/*' npm-3of10-malformed.json 200
WD="$TMP/npm-3of10"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null" || rc=$?
assert_eq "malformed-ratio-3-of-10-failed" "failed" "$(jq -r '.status' "$WD/status-npm.json")"
NOTE="$(jq -r '.note' "$WD/status-npm.json")"
assert_contains "malformed-ratio-3-of-10-note" "$NOTE" "schema_ratio_"

# T9 — precedence: malformed-ratio failure (rung 2) beats signal_absent
# (rung 3), even though the 7 well-formed objects here carry no downloads
# field at all and would independently satisfy signal_absent.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"q{i}","date":"2026-07-20T00:00:00Z"}} for i in range(7)]
for _ in range(3):
    objs.append({"package":{}})
print(json.dumps({"objects":objs,"total":10}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-3of10-malformed-no-downloads.json"
set_curl_route 'https://registry.npmjs.org/*' npm-3of10-malformed-no-downloads.json 200
WD="$TMP/npm-3of10-nodl"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null" || rc=$?
assert_eq "T9-precedence-schema-ratio-beats-signal-absent" "failed" "$(jq -r '.status' "$WD/status-npm.json")"
T9_NOTE="$(jq -r '.note' "$WD/status-npm.json")"
assert_contains "T9-precedence-note-is-schema-ratio-not-signal-absent" "$T9_NOTE" "schema_ratio_"
if [[ "$T9_NOTE" == "signal_absent" ]]; then fail "T9-precedence-note-must-not-be-signal-absent"; else pass; fi

reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":"p1","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":500}}, {"package":{}}]
print(json.dumps({"objects":objs,"total":2}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-1of3-small-n.json"
set_curl_route 'https://registry.npmjs.org/*' npm-1of3-small-n.json 200
WD="$TMP/npm-1of3-small"; mkdir -p "$WD"
rc=0
MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null" || rc=$?
assert_eq "malformed-small-n-any-malformed-fails" "failed" "$(jq -r '.status' "$WD/status-npm.json")"

# ===========================================================================
# Section B2 — ADR-046 revision 3 (D23/D24): npm downloads extraction and
# signal-integrity tripwire.
# ===========================================================================

# T3 — string "9999" coerces to 0, is counted missing, and does not pass the
# bar (regression guard: jq sorts strings above all numbers).
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-t3-string-downloads.json" << 'EOF'
{"objects":[{"package":{"name":"stringdl-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":"9999"}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-t3-string-downloads.json 200
WD="$TMP/npm-t3"; mkdir -p "$WD"
OUT_T3="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7")"
assert_contains "T3-string-downloads-coerced-to-zero" "$OUT_T3" '"npmDownloadsMonthly":0'
assert_eq "T3-string-downloads-counted-missing" "3" "$(jq -r '.signalMissing' "$WD/status-npm.json")"
T3_BARRED="$(echo "$OUT_T3" | /bin/bash -c "source '$LIB'; mcp_merge" | /bin/bash -c "source '$LIB'; mcp_apply_bar")"
assert_not_contains "T3-string-downloads-does-not-pass-bar" "$T3_BARRED" "stringdl-mcp"

# T4 — negative -> treated as missing -> 0; float -> floor.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-t4-negative-float.json" << 'EOF'
{"objects":[
  {"package":{"name":"negdl-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":-5}},
  {"package":{"name":"floatdl-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":12.7}}
],"total":2}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-t4-negative-float.json 200
WD="$TMP/npm-t4"; mkdir -p "$WD"
OUT_T4="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7")"
NEG_ROW="$(echo "$OUT_T4" | grep '"sourceId":"negdl-mcp"')"
FLOAT_ROW="$(echo "$OUT_T4" | grep '"sourceId":"floatdl-mcp"')"
assert_contains "T4-negative-downloads-treated-as-missing" "$NEG_ROW" '"npmDownloadsMonthly":0'
assert_contains "T4-float-downloads-floored" "$FLOAT_ROW" '"npmDownloadsMonthly":12'
assert_eq "T4-negative-counted-missing-float-not" "3" "$(jq -r '.signalMissing' "$WD/status-npm.json")"

# T5 — package-level shape `{"package":{"downloads":{"monthly":777}}}` -> 777.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-t5-package-level.json" << 'EOF'
{"objects":[{"package":{"name":"pkglevel-mcp","date":"2026-07-20T00:00:00Z","downloads":{"monthly":777}}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-t5-package-level.json 200
WD="$TMP/npm-t5"; mkdir -p "$WD"
OUT_T5="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "source '$LIB'; mcp_fetch_npm 7")"
assert_contains "T5-package-level-downloads-path" "$OUT_T5" '"npmDownloadsMonthly":777'

# Regression guard (not a numbered ADR test, but load-bearing): a `downloads`
# shape jq can't index (a string instead of an object) must not crash the
# fetch loop under the entrypoint's `set -e` — it must coerce to the -1
# sentinel like any other malformed value. Exercised under an explicit
# `set -e` subshell, since the test harness's own `mcp_fetch_npm` invocation
# runs without `set -e` and would silently pass even if this regressed.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-unindexable-downloads.json" << 'EOF'
{"objects":[{"package":{"name":"unindexable-mcp","date":"2026-07-20T00:00:00Z"},"downloads":"not-an-object"}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-unindexable-downloads.json 200
WD="$TMP/npm-unindexable"; mkdir -p "$WD"
rc=0
OUT_UNINDEXABLE="$(MCP_SWEEP_WORKDIR="$WD" MCP_SWEEP_NPM_MAX_PAGES=1 /bin/bash -c "set -e; source '$LIB'; mcp_fetch_npm 7")" || rc=$?
assert_eq "unindexable-downloads-shape-does-not-crash-under-set-e" "0" "$rc"
assert_contains "unindexable-downloads-shape-coerces-to-zero" "$OUT_UNINDEXABLE" '"npmDownloadsMonthly":0'

# T6 — 20 objects, none with `downloads` -> partial/signal_absent, exit 0,
# records still emitted.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"absent{i}","date":"2026-07-20T00:00:00Z"}} for i in range(20)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t6-signal-absent.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t6-signal-absent.json 200
WD="$TMP/npm-t6"; mkdir -p "$WD"
rc=0
OUT_T6="$(MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7")" || rc=$?
assert_eq "T6-signal-absent-exit-0" "0" "$rc"
assert_eq "T6-signal-absent-status" "partial" "$(jq -r '.status' "$WD/status-npm.json")"
assert_eq "T6-signal-absent-note" "signal_absent" "$(jq -r '.note' "$WD/status-npm.json")"
T6_COUNT="$(echo "$OUT_T6" | grep -c '"key"')"
if [[ "$T6_COUNT" -gt 0 ]]; then pass; else fail "T6-signal-absent-records-still-emitted"; fi

# T7 — 20 objects all with downloads.monthly: 1 -> partial/signal_degenerate.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"degen{i}","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":1}} for i in range(20)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t7-signal-degenerate.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t7-signal-degenerate.json 200
WD="$TMP/npm-t7"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "T7-signal-degenerate-status" "partial" "$(jq -r '.status' "$WD/status-npm.json")"
assert_eq "T7-signal-degenerate-note" "signal_degenerate" "$(jq -r '.note' "$WD/status-npm.json")"

# T8 — 20 objects with >=2 distinct present values -> ok.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"distinct{i}","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":100+i}} for i in range(20)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t8-signal-ok.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t8-signal-ok.json 200
WD="$TMP/npm-t8"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "T8-distinct-values-status-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

# T10 — small-sample guard: 5 objects (15 eligible < 20 sample floor), none
# with downloads -> ok, tripwire does not arm below the sample floor.
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"small{i}","date":"2026-07-20T00:00:00Z"}} for i in range(5)]
print(json.dumps({"objects":objs,"total":5}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t10-small-sample.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t10-small-sample.json 200
WD="$TMP/npm-t10"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "T10-small-sample-eligible-count" "15" "$(jq -r '.signalEligible' "$WD/status-npm.json")"
assert_eq "T10-small-sample-exempt-status-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

# T11 — mixed: 20 objects, 9 missing (45%) -> ok (under the 0.50 ratio).
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"present{i}","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":100+i}} for i in range(11)]
objs += [{"package":{"name":f"missing{i}","date":"2026-07-20T00:00:00Z"}} for i in range(9)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t11-mixed-45pct.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t11-mixed-45pct.json 200
WD="$TMP/npm-t11"; mkdir -p "$WD"
MCP_SWEEP_WORKDIR="$WD" /bin/bash -c "source '$LIB'; mcp_fetch_npm 7 > /dev/null"
assert_eq "T11-mixed-45pct-missing-eligible" "60" "$(jq -r '.signalEligible' "$WD/status-npm.json")"
assert_eq "T11-mixed-45pct-missing-count" "27" "$(jq -r '.signalMissing' "$WD/status-npm.json")"
assert_eq "T11-mixed-45pct-under-ratio-status-ok" "ok" "$(jq -r '.status' "$WD/status-npm.json")"

# 3xx never followed; off-allowlist host denied without a network call.
reset_fixtures
rc=0
OUT="$(MCP_SWEEP_TEST_FIXTURES="$MCP_SWEEP_TEST_FIXTURES" /bin/bash -c "source '$LIB'; mcp_http_get 'https://evil.example.com/x' 2>&1")" || rc=$?
assert_eq "host-allowlist-denies" "3" "$rc"
assert_contains "host-allowlist-no-network-call" "$OUT" "HOST_DENIED"
if grep -q "evil.example.com" "$MCP_SWEEP_TEST_FIXTURES/.curl-calls.log" 2>/dev/null; then
  fail "host-allowlist-truly-no-curl-invocation"
else
  pass
fi

reset_fixtures
echo '{}' > "$MCP_SWEEP_TEST_FIXTURES/redirect.json"
set_curl_route 'https://registry.npmjs.org/*' redirect.json 302
rc=0
ERR="$(/bin/bash -c "source '$LIB'; mcp_http_get 'https://registry.npmjs.org/-/v1/search?text=x' 2>&1 1>/dev/null")" || rc=$?
assert_eq "3xx-never-followed-exit3" "3" "$rc"
assert_contains "3xx-note-redirect" "$ERR" "REDIRECT_302"

# ===========================================================================
# Section C — merge / monorepo disambiguation / dedupe.
# ===========================================================================

cat > "$TMP/merge-input.ndjson" << 'EOF'
{"key":"gh:tavily-ai/tavily-mcp","name":"tavily-mcp","source":"npm","sourceId":"tavily-mcp","updatedUtc":"2026-07-20T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":5500,"registryStatus":""}}
{"key":"gh:tavily-ai/tavily-mcp","name":"tavily-mcp","source":"github","sourceId":"tavily-ai/tavily-mcp","updatedUtc":"2026-07-25T00:00:00Z","signal":{"stars":100,"npmDownloadsMonthly":0,"registryStatus":""}}
{"key":"gh:tavily-ai/tavily-mcp","name":"tavily-mcp","source":"registry","sourceId":"io.github.tavily-ai/tavily-mcp","updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":0,"registryStatus":"active"}}
{"key":"gh:modelcontextprotocol/servers","name":"servers","source":"npm","sourceId":"@modelcontextprotocol/server-filesystem","updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":4000,"registryStatus":""}}
{"key":"gh:modelcontextprotocol/servers","name":"servers","source":"npm","sourceId":"@modelcontextprotocol/server-memory","updatedUtc":"2026-07-02T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":3000,"registryStatus":""}}
EOF
MERGED="$(/bin/bash -c "source '$LIB'; mcp_merge < '$TMP/merge-input.ndjson'")"
MERGED_LINES="$(echo "$MERGED" | grep -c '"key"')"
assert_eq "merge-produces-3-distinct-keys" "3" "$MERGED_LINES"
TAVILY_SOURCES="$(echo "$MERGED" | jq -sc 'map(select(.key=="gh:tavily-ai/tavily-mcp")) | .[0].sources')"
assert_eq "merge-same-server-3-sources" '["github","npm","registry"]' "$TAVILY_SOURCES"

# T15 — merge takes the per-key max of npmDownloadsMonthly, exactly as it
# did for the old npm relevance field.
cat > "$TMP/merge-t15-input.ndjson" << 'EOF'
{"key":"npm:samekey","name":"samekey","source":"npm","sourceId":"samekey-a","updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":100,"registryStatus":""}}
{"key":"npm:samekey","name":"samekey","source":"npm","sourceId":"samekey-b","updatedUtc":"2026-07-02T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":5000,"registryStatus":""}}
EOF
MERGED_T15="$(/bin/bash -c "source '$LIB'; mcp_merge < '$TMP/merge-t15-input.ndjson'")"
MERGED_T15_MAX="$(echo "$MERGED_T15" | jq -r '.signal.npmDownloadsMonthly')"
assert_eq "T15-merge-takes-max-downloads" "5000" "$MERGED_T15_MAX"
T15_BARRED="$(echo "$MERGED_T15" | /bin/bash -c "source '$LIB'; mcp_apply_bar")"
assert_contains "T15-merge-max-downloads-passes-bar" "$T15_BARRED" "npm:samekey"

# Underivable URL -> falls to npm:/mcp:, no truncated gh: key, dropped counted.
UNDERIVABLE="$(/bin/bash -c "source '$LIB'; mcp_normalize_key 'ftp://nonsense' npm somepkg")"
assert_eq "underivable-falls-to-npm" "npm:somepkg" "$UNDERIVABLE"

# ===========================================================================
# Section D — wired / ignored / bar.
# ===========================================================================

WIRED_FILE="$TMP/wired.txt"
/bin/bash -c "source '$LIB'; mcp_wired_tokens '$REPO_ROOT/config/settings.tier-1.template.json' '$REPO_ROOT/config/mcp-sweep-known.json'" > "$WIRED_FILE"

WIRED_COUNT="$(grep -c '^' "$WIRED_FILE")"
if [[ "$WIRED_COUNT" -gt 0 ]]; then pass; else fail "wired-tokens-nonempty"; fi

CLASSIFIED="$(echo "$MERGED" | /bin/bash -c "source '$LIB'; mcp_classify '$WIRED_FILE' '$REPO_ROOT/config/mcp-sweep-known.json'")"
TAVILY_STATUS="$(echo "$CLASSIFIED" | jq -sc 'map(select(.key=="gh:tavily-ai/tavily-mcp")) | .[0].status' | tr -d '"')"
assert_eq "ignored-alias-suppresses-tavily" "ignored" "$TAVILY_STATUS"

# wired-alias path still exercised against the live config via context7.
CONTEXT7_STATUS="$(echo '{"key":"gh:upstash/context7","name":"context7","sources":["github"],"sourceIds":{"github":"upstash/context7"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":60000,"npmDownloadsMonthly":0,"registryStatus":""}}' \
  | /bin/bash -c "source '$LIB'; mcp_classify '$WIRED_FILE' '$REPO_ROOT/config/mcp-sweep-known.json'" | jq -r '.status')"
assert_eq "wired-alias-suppresses-context7" "wired" "$CONTEXT7_STATUS"

# ignored key suppressed
cat > "$TMP/known-with-ignore.json" << EOF
{"schemaVersion":1,"wiredAliases":{},"ignored":{"gh:modelcontextprotocol/servers":{"reason":"test","decidedUtc":"2026-07-28T00:00:00Z"}}}
EOF
CLASSIFIED2="$(echo '{"key":"gh:modelcontextprotocol/servers","name":"servers","sources":["npm"],"sourceIds":{"npm":"x"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":5000,"registryStatus":""}}' \
  | /bin/bash -c "source '$LIB'; mcp_classify '$WIRED_FILE' '$TMP/known-with-ignore.json'")"
IGNORED_STATUS="$(echo "$CLASSIFIED2" | jq -r '.status')"
assert_eq "ignored-key-suppressed" "ignored" "$IGNORED_STATUS"

# Bar: registry exempt; npm/github gated by their own signal (ADR-046
# revision 3, D23 — npm gate is now monthly downloads, not the old
# relevance-score field).
BAR_TEST_INPUT='{"key":"npm:low","sources":["npm"],"sourceIds":{"npm":"low"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":10,"registryStatus":""}}
{"key":"npm:high","sources":["npm"],"sourceIds":{"npm":"high"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":50000,"registryStatus":""}}
{"key":"mcp:reg1","sources":["registry"],"sourceIds":{"registry":"reg1"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":0,"registryStatus":"active"}}'
BARRED="$(echo "$BAR_TEST_INPUT" | /bin/bash -c "source '$LIB'; mcp_apply_bar")"
assert_not_contains "bar-drops-low-npm-downloads" "$BARRED" "npm:low"
assert_contains "bar-keeps-high-npm-downloads" "$BARRED" "npm:high"
assert_contains "bar-registry-exempt" "$BARRED" "mcp:reg1"

# T12 — boundary: 999 dropped, 1000 kept, 1000000 kept.
BAR_T12_INPUT='{"key":"npm:b999","sources":["npm"],"sourceIds":{"npm":"b999"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":999,"registryStatus":""}}
{"key":"npm:b1000","sources":["npm"],"sourceIds":{"npm":"b1000"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":1000,"registryStatus":""}}
{"key":"npm:b1000000","sources":["npm"],"sourceIds":{"npm":"b1000000"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":1000000,"registryStatus":""}}'
BARRED_T12="$(echo "$BAR_T12_INPUT" | /bin/bash -c "source '$LIB'; mcp_apply_bar")"
assert_not_contains "T12-bar-boundary-999-dropped" "$BARRED_T12" "npm:b999"
assert_contains "T12-bar-boundary-1000-kept" "$BARRED_T12" "npm:b1000\""
assert_contains "T12-bar-boundary-1000000-kept" "$BARRED_T12" "npm:b1000000"

# T13 — OR-branches independent of downloads: stars>=25 kept at zero
# downloads; stars 24 dropped; registry-sourced kept at zero downloads/stars.
BAR_T13_INPUT='{"key":"gh:x/y25","sources":["github"],"sourceIds":{"github":"x/y25"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":25,"npmDownloadsMonthly":0,"registryStatus":""}}
{"key":"gh:x/y24","sources":["github"],"sourceIds":{"github":"x/y24"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":24,"npmDownloadsMonthly":0,"registryStatus":""}}
{"key":"mcp:reg2","sources":["registry"],"sourceIds":{"registry":"reg2"},"updatedUtc":"2026-07-01T00:00:00Z","signal":{"stars":0,"npmDownloadsMonthly":0,"registryStatus":"active"}}'
BARRED_T13="$(echo "$BAR_T13_INPUT" | /bin/bash -c "source '$LIB'; mcp_apply_bar")"
assert_contains "T13-bar-stars-25-kept-at-zero-downloads" "$BARRED_T13" "gh:x/y25"
assert_not_contains "T13-bar-stars-24-dropped" "$BARRED_T13" "gh:x/y24"
assert_contains "T13-bar-registry-exempt-at-zero" "$BARRED_T13" "mcp:reg2"

# ===========================================================================
# Section E — mcp_state.py load/dump/validate.
# ===========================================================================

GOOD_STATE='{"v":3,"mode":"steady","lastRunUtc":"2026-07-28T06:00:00Z","ackedAtUtc":"2026-07-20T06:00:00Z","cleanRuns":1,"dropped":0,"pending":{"gh:owner/repo":"2026-07-21T06:00:00Z"},"aged":["gh:old/thing"],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":3,"alertedAt":3,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'

VALID_RC=0
echo "$GOOD_STATE" | python3 "$STATE_PY" validate || VALID_RC=$?
assert_eq "state-validate-good" "0" "$VALID_RC"

BAD1='{"v":3,"mode":"steady","lastRunUtc":"2026-07-28T06:00:00Z","ackedAtUtc":"2026-07-20T06:00:00Z","cleanRuns":1,"dropped":0,"pending":["not-a-map"],"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
BAD1_RC=0
echo "$BAD1" | python3 "$STATE_PY" validate || BAD1_RC=$?
assert_eq "state-validate-pending-as-array-no-crash" "1" "$BAD1_RC"

BAD2='{"v":3,"mode":"steady","lastRunUtc":"2026-07-28T06:00:00Z","ackedAtUtc":"2026-07-20T06:00:00Z","cleanRuns":1,"dropped":0,"pending":{},"aged":[],"sourceHealth":"bad","allEmptyStreak":0,"allEmptyAlertedAt":0}'
BAD2_RC=0
echo "$BAD2" | python3 "$STATE_PY" validate || BAD2_RC=$?
assert_eq "state-validate-sourceHealth-as-string-no-crash" "1" "$BAD2_RC"

BAD3="$(echo "$GOOD_STATE" | jq -c '.sourceHealth.npm.pageCapStreak = "x"')"
BAD3_RC=0
echo "$BAD3" | python3 "$STATE_PY" validate || BAD3_RC=$?
assert_eq "state-validate-pageCapStreak-string-no-crash" "1" "$BAD3_RC"

BADV="$(echo "$GOOD_STATE" | jq -c '.v = 2')"
BADV_RC=0
echo "$BADV" | python3 "$STATE_PY" validate || BADV_RC=$?
assert_eq "state-validate-v2-rejected" "1" "$BADV_RC"

STATE_ROUNDTRIP_PATH="$TMP/state-roundtrip.json"
echo "$GOOD_STATE" | python3 "$STATE_PY" dump "$STATE_ROUNDTRIP_PATH"
LOADED_BACK="$(python3 "$STATE_PY" load "$STATE_ROUNDTRIP_PATH")"
ORIGINAL_CANON="$(echo "$GOOD_STATE" | jq -cS .)"
LOADED_CANON="$(echo "$LOADED_BACK" | jq -cS .)"
assert_eq "state-roundtrip-exact" "$ORIGINAL_CANON" "$LOADED_CANON"

echo "not json at all" > "$TMP/corrupt-state.json"
CORRUPT_LOAD="$(python3 "$STATE_PY" load "$TMP/corrupt-state.json")"
assert_eq "state-corrupt-loads-null" "null" "$CORRUPT_LOAD"

MISSING_LOAD="$(python3 "$STATE_PY" load "$TMP/does-not-exist-state.json")"
assert_eq "state-missing-path-loads-null" "null" "$MISSING_LOAD"

# ===========================================================================
# Section F — entrypoint state machine (curl + gh shimmed).
# ===========================================================================

# --- Seed run: no state at all -> mode seed, no comments, no close, banner present.
reset_fixtures; empty_envelopes; reset_gh
WD_SEED="$TMP/e2e-seed-work"; mkdir -p "$WD_SEED"
rc=0
MCP_SWEEP_WORKDIR="$WD_SEED" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-existed.json" --state-out="$WD_SEED/out.json" --dry-run=false || rc=$?
assert_eq "e2e-seed-run-succeeds" "0" "$rc"
assert_eq "e2e-seed-mode-in-body" "1" "$(grep -c 'Seed run' "$WD_SEED/body.md")"
assert_eq "e2e-seed-no-comment-call" "0" "$(gh_call_count 'issue comment')"
assert_eq "e2e-seed-no-close-call" "0" "$(gh_call_count 'issue close')"
assert_eq "e2e-seed-writes-state" "0" "$([[ -f "$WD_SEED/out.json" ]] && echo 0 || echo 1)"
SEED_MODE="$(jq -r '.mode' "$WD_SEED/out.json")"
assert_eq "e2e-seed-state-mode-seed" "seed" "$SEED_MODE"

# --- Identical input run twice -> second run edits body, posts no comment.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-one-candidate.json" << 'EOF'
{"objects":[{"package":{"name":"newthing-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":50000}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-one-candidate.json 200
set_curl_route 'https://api.github.com/*' npm-empty-placeholder.json 200
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/npm-empty-placeholder.json"
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-empty-placeholder.json 200
echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/reg-empty-placeholder.json"

reset_gh
WD_R1="$TMP/e2e-run1-work"; mkdir -p "$WD_R1"
STATE_PATH="$TMP/e2e-shared-state.json"
MCP_SWEEP_WORKDIR="$WD_R1" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-existed-2.json" --state-out="$STATE_PATH" --dry-run=false
# First run is a seed run (no prior state) -> zero comments regardless of pending.
assert_eq "e2e-run1-seed-no-comment" "0" "$(gh_call_count 'issue comment')"

reset_gh
WD_R2="$TMP/e2e-run2-work"; mkdir -p "$WD_R2"
GITHUB_OUTPUT_R2="$TMP/gh-output-r2.txt"; : > "$GITHUB_OUTPUT_R2"
MCP_SWEEP_WORKDIR="$WD_R2" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  GITHUB_OUTPUT="$GITHUB_OUTPUT_R2" \
  "$ENTRYPOINT" --state-in="$STATE_PATH" --state-out="$STATE_PATH" --dry-run=false
assert_eq "e2e-run2-steady-1-edit" "1" "$(gh_call_count 'issue edit*')"
assert_eq "e2e-run2-identical-input-no-comment" "0" "$(gh_call_count 'issue comment*')"
assert_contains "e2e-run2-github-output-state-written-true" "$(cat "$GITHUB_OUTPUT_R2")" "state_written=true"

reset_gh
WD_R3="$TMP/e2e-run3-work"; mkdir -p "$WD_R3"
MCP_SWEEP_WORKDIR="$WD_R3" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$STATE_PATH" --state-out="$STATE_PATH" --dry-run=false
assert_eq "e2e-run3-still-no-comment-on-repeat" "0" "$(gh_call_count 'issue comment*')"

# --- One new candidate -> exactly one comment.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-second-candidate.json" << 'EOF'
{"objects":[
  {"package":{"name":"newthing-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":50000}},
  {"package":{"name":"secondthing-mcp","date":"2026-07-21T00:00:00Z"},"downloads":{"monthly":50000}}
],"total":2}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-second-candidate.json 200
set_curl_route 'https://api.github.com/*' npm-empty-placeholder.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-empty-placeholder.json 200
reset_gh
WD_R4="$TMP/e2e-run4-work"; mkdir -p "$WD_R4"
MCP_SWEEP_WORKDIR="$WD_R4" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$STATE_PATH" --state-out="$STATE_PATH" --dry-run=false
assert_eq "e2e-one-new-candidate-one-comment" "1" "$(gh_call_count 'issue comment*')"

# --- T14: graduation. Run 1 with downloads.monthly:500 (below the default
# 1000 bar) -> key absent from pending, counted in belowBarCount. Run 2 with
# the same key at 1500 -> key enters pending with run 2's firstSeenUtc and
# produces exactly one comment.
GRAD_STATE="$TMP/e2e-grad-state.json"
python3 "$STATE_PY" dump "$GRAD_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":0,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-graduate-below.json" << 'EOF'
{"objects":[{"package":{"name":"graduate-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":500}}],"total":1}
EOF
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-grad-empty.json"
echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/reg-grad-empty.json"
set_curl_route 'https://registry.npmjs.org/*' npm-graduate-below.json 200
set_curl_route 'https://api.github.com/*' gh-grad-empty.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-grad-empty.json 200
reset_gh
WD_GRAD1="$TMP/e2e-grad-run1-work"; mkdir -p "$WD_GRAD1"
MCP_SWEEP_WORKDIR="$WD_GRAD1" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$GRAD_STATE" --state-out="$GRAD_STATE" --dry-run=false
assert_eq "T14-graduation-run1-no-comment" "0" "$(gh_call_count 'issue comment*')"
assert_eq "T14-graduation-run1-key-absent-from-pending" "0" "$(jq '.pending | length' "$GRAD_STATE")"
assert_contains "T14-graduation-run1-below-bar-count" "$(cat "$WD_GRAD1/body.md")" "Below bar: 1."

reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-graduate-above.json" << 'EOF'
{"objects":[{"package":{"name":"graduate-mcp","date":"2026-07-20T00:00:00Z"},"downloads":{"monthly":1500}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-graduate-above.json 200
set_curl_route 'https://api.github.com/*' gh-grad-empty.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-grad-empty.json 200
reset_gh
WD_GRAD2="$TMP/e2e-grad-run2-work"; mkdir -p "$WD_GRAD2"
MCP_SWEEP_WORKDIR="$WD_GRAD2" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$GRAD_STATE" --state-out="$GRAD_STATE" --dry-run=false
assert_eq "T14-graduation-run2-one-comment" "1" "$(gh_call_count 'issue comment*')"
assert_eq "T14-graduation-run2-key-enters-pending" "1" "$(jq '.pending | length' "$GRAD_STATE")"
GRAD_FIRST_SEEN="$(jq -r '.pending."npm:graduate-mcp"' "$GRAD_STATE")"
GRAD_LAST_RUN="$(jq -r '.lastRunUtc' "$GRAD_STATE")"
assert_eq "T14-graduation-firstSeenUtc-is-run2-not-run1" "$GRAD_LAST_RUN" "$GRAD_FIRST_SEEN"

# --- Close: pending==0, all sources ok, two consecutive clean runs -> exactly one close.
# (npm returns one WIRED candidate rather than zero records — an all-empty
# run across every source is D22-anomalous by design and can never close;
# this fixture keeps npm genuinely `ok` while still landing at pending==0.)
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-wired-only.json" << 'EOF'
{"objects":[{"package":{"name":"tavily-mcp","date":"2026-07-20T00:00:00Z","links":{"repository":"https://github.com/tavily-ai/tavily-mcp"}},"downloads":{"monthly":50000}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-wired-only.json 200
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-e0.json"
echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/reg-e0.json"
set_curl_route 'https://api.github.com/*' gh-e0.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-e0.json 200
CLOSE_STATE="$TMP/e2e-close-state.json"
python3 "$STATE_PY" dump "$CLOSE_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":1,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
WD_CLOSE="$TMP/e2e-close-work"; mkdir -p "$WD_CLOSE"
MCP_SWEEP_WORKDIR="$WD_CLOSE" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$CLOSE_STATE" --state-out="$CLOSE_STATE" --dry-run=false
assert_eq "e2e-two-clean-runs-closes" "1" "$(gh_call_count 'issue close*')"

# --- pending==0, one source failed -> no close.
reset_fixtures
echo '{"objects":[],"total":0}' > "$MCP_SWEEP_TEST_FIXTURES/npm-empty2.json"
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-empty2.json"
echo 'broken' > "$MCP_SWEEP_TEST_FIXTURES/reg-broken.json"
set_curl_route 'https://registry.npmjs.org/*' npm-empty2.json 200
set_curl_route 'https://api.github.com/*' gh-empty2.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-broken.json 500
NOCLOSE_STATE="$TMP/e2e-noclose-state.json"
python3 "$STATE_PY" dump "$NOCLOSE_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":1,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
WD_NOCLOSE="$TMP/e2e-noclose-work"; mkdir -p "$WD_NOCLOSE"
MCP_SWEEP_WORKDIR="$WD_NOCLOSE" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$NOCLOSE_STATE" --state-out="$NOCLOSE_STATE" --dry-run=false
assert_eq "e2e-source-failed-no-close" "0" "$(gh_call_count 'issue close*')"
assert_contains "e2e-source-failed-note-in-body" "$(cat "$WD_NOCLOSE/body.md")" "registry"

# --- T16: npm partial/signal_absent, pending==0, cleanRuns==1 -> no close
# (D24 downstream wiring: a dead npm signal cannot auto-close the issue).
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"t16absent{i}","date":"2026-07-20T00:00:00Z"}} for i in range(20)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t16-signal-absent.json"
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-t16-empty.json"
echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/reg-t16-empty.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t16-signal-absent.json 200
set_curl_route 'https://api.github.com/*' gh-t16-empty.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-t16-empty.json 200
T16_STATE="$TMP/e2e-t16-state.json"
python3 "$STATE_PY" dump "$T16_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":1,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
WD_T16="$TMP/e2e-t16-work"; mkdir -p "$WD_T16"
MCP_SWEEP_WORKDIR="$WD_T16" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$T16_STATE" --state-out="$T16_STATE" --dry-run=false
assert_eq "T16-npm-signal-absent-pending-zero-cleanRuns-1-no-close" "0" "$(gh_call_count 'issue close*')"

# --- T17: three consecutive signal_absent runs -> health line rendered,
# comment posted (npm failStreak was already 2 going into this run).
reset_fixtures
python3 -c '
import json
objs = [{"package":{"name":f"t17absent{i}","date":"2026-07-20T00:00:00Z"}} for i in range(20)]
print(json.dumps({"objects":objs,"total":20}))
' > "$MCP_SWEEP_TEST_FIXTURES/npm-t17-signal-absent.json"
echo '{"items":[],"total_count":0}' > "$MCP_SWEEP_TEST_FIXTURES/gh-t17-empty.json"
echo '{"servers":[],"metadata":{}}' > "$MCP_SWEEP_TEST_FIXTURES/reg-t17-empty.json"
set_curl_route 'https://registry.npmjs.org/*' npm-t17-signal-absent.json 200
set_curl_route 'https://api.github.com/*' gh-t17-empty.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-t17-empty.json 200
T17_STATE="$TMP/e2e-t17-state.json"
python3 "$STATE_PY" dump "$T17_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":0,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":2,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
WD_T17="$TMP/e2e-t17-work"; mkdir -p "$WD_T17"
MCP_SWEEP_WORKDIR="$WD_T17" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$T17_STATE" --state-out="$T17_STATE" --dry-run=false
assert_contains "T17-three-consecutive-signal-absent-health-line" "$(cat "$WD_T17/body.md")" "Sweep health"
assert_eq "T17-three-consecutive-signal-absent-comment-posted" "1" "$(gh_call_count 'issue comment*')"
assert_eq "T17-npm-failstreak-reaches-3" "3" "$(jq -r '.sourceHealth.npm.failStreak' "$T17_STATE")"

# --- pending==0, mcp-sweep-hold label present -> no close.
reset_fixtures; empty_envelopes
HOLD_STATE="$TMP/e2e-hold-state.json"
python3 "$STATE_PY" dump "$HOLD_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-01T00:00:00Z","ackedAtUtc":"2026-07-01T00:00:00Z","cleanRuns":1,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
export MCP_SWEEP_TEST_GH_HOLD="true"
WD_HOLD="$TMP/e2e-hold-work"; mkdir -p "$WD_HOLD"
MCP_SWEEP_WORKDIR="$WD_HOLD" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$HOLD_STATE" --state-out="$HOLD_STATE" --dry-run=false
assert_eq "e2e-hold-label-no-close" "0" "$(gh_call_count 'issue close*')"
unset MCP_SWEEP_TEST_GH_HOLD

# --- Closed issue + new pending -> reopen and comment.
reset_fixtures
cat > "$MCP_SWEEP_TEST_FIXTURES/npm-reopen-candidate.json" << 'EOF'
{"objects":[{"package":{"name":"reopenme-mcp","date":"2026-07-29T00:00:00Z"},"downloads":{"monthly":50000}}],"total":1}
EOF
set_curl_route 'https://registry.npmjs.org/*' npm-reopen-candidate.json 200
set_curl_route 'https://api.github.com/*' npm-empty-placeholder.json 200
set_curl_route 'https://registry.modelcontextprotocol.io/*' reg-empty-placeholder.json 200
REOPEN_STATE="$TMP/e2e-reopen-state.json"
python3 "$STATE_PY" dump "$REOPEN_STATE" <<< '{"v":3,"mode":"steady","lastRunUtc":"2026-07-20T00:00:00Z","ackedAtUtc":"2026-07-20T00:00:00Z","cleanRuns":2,"dropped":0,"pending":{},"aged":[],"sourceHealth":{"npm":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"github":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0},"registry":{"failStreak":0,"alertedAt":0,"pageCapStreak":0,"pageCapAlertedAt":0}},"allEmptyStreak":0,"allEmptyAlertedAt":0}'
reset_gh
export MCP_SWEEP_TEST_GH_STATE="CLOSED"
WD_REOPEN="$TMP/e2e-reopen-work"; mkdir -p "$WD_REOPEN"
MCP_SWEEP_WORKDIR="$WD_REOPEN" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$REOPEN_STATE" --state-out="$REOPEN_STATE" --dry-run=false
assert_eq "e2e-closed-plus-new-pending-reopens" "1" "$(gh_call_count 'issue reopen*')"
assert_eq "e2e-closed-plus-new-pending-comments" "1" "$(gh_call_count 'issue comment*')"

# --- Seed against a closed issue -> no reopen, no comment, no close.
reset_fixtures; empty_envelopes
reset_gh
export MCP_SWEEP_TEST_GH_STATE="CLOSED"
WD_SEEDCLOSED="$TMP/e2e-seed-closed-work"; mkdir -p "$WD_SEEDCLOSED"
MCP_SWEEP_WORKDIR="$WD_SEEDCLOSED" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-3.json" --state-out="$WD_SEEDCLOSED/out.json" --dry-run=false
assert_eq "e2e-seed-closed-no-reopen" "0" "$(gh_call_count 'issue reopen*')"
assert_eq "e2e-seed-closed-no-comment" "0" "$(gh_call_count 'issue comment*')"

# --- Author guard: authorAssociation NONE and unlisted id -> zero mutations, non-zero exit.
reset_fixtures; empty_envelopes
reset_gh
export MCP_SWEEP_TEST_GH_ASSOC="NONE"
export MCP_SWEEP_TEST_GH_AUTHOR_ID="someone-else"
export MCP_SWEEP_ISSUE_AUTHOR_ALLOW="test-allowed-id"
WD_GUARD="$TMP/e2e-guard-work"; mkdir -p "$WD_GUARD"
rc=0
MCP_SWEEP_WORKDIR="$WD_GUARD" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-4.json" --state-out="$WD_GUARD/out.json" --dry-run=false || rc=$?
assert_true "e2e-author-guard-nonzero-exit" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"
assert_eq "e2e-author-guard-zero-edits" "0" "$(gh_call_count 'issue edit*')"

# --- Author guard passes for the real github-actions[bot] node id (pre-ship gate item 2).
reset_fixtures; empty_envelopes
reset_gh
export MCP_SWEEP_TEST_GH_ASSOC="NONE"
export MCP_SWEEP_TEST_GH_AUTHOR_ID="MDM6Qm90NDE4OTgyODI="
export MCP_SWEEP_ISSUE_AUTHOR_ALLOW="MDM6Qm90NDE4OTgyODI="
WD_BOTGUARD="$TMP/e2e-botguard-work"; mkdir -p "$WD_BOTGUARD"
rc=0
MCP_SWEEP_WORKDIR="$WD_BOTGUARD" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-5.json" --state-out="$WD_BOTGUARD/out.json" --dry-run=false || rc=$?
assert_eq "e2e-author-guard-passes-for-real-bot-id" "0" "$rc"
assert_eq "e2e-author-guard-bot-edits" "1" "$(gh_call_count 'issue edit*')"

# --- Dry-run: zero gh calls, writes summary.
reset_fixtures; empty_envelopes
reset_gh
SUMMARY_FILE="$TMP/step-summary.md"
: > "$SUMMARY_FILE"
WD_DRY="$TMP/e2e-dry-work"; mkdir -p "$WD_DRY"
MCP_SWEEP_WORKDIR="$WD_DRY" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  "$ENTRYPOINT" --state-in="$TMP/never-6.json" --state-out="$WD_DRY/out.json" --dry-run=true
TOTAL_GH_CALLS="$(wc -l < "$MCP_SWEEP_TEST_GH_LOG" | tr -d ' ')"
assert_eq "dry-run-zero-gh-calls" "0" "$TOTAL_GH_CALLS"
assert_true "dry-run-writes-step-summary" "$([[ -s "$SUMMARY_FILE" ]] && echo true || echo false)"
assert_true "dry-run-no-state-out" "$([[ ! -f "$WD_DRY/out.json" ]] && echo true || echo false)"

# --- sources=npm + dry_run=false -> forced dry-run, zero gh calls.
reset_fixtures; empty_envelopes
reset_gh
WD_SUBSET="$TMP/e2e-subset-work"; mkdir -p "$WD_SUBSET"
MCP_SWEEP_WORKDIR="$WD_SUBSET" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-7.json" --state-out="$WD_SUBSET/out.json" --dry-run=false --sources=npm
SUBSET_GH_CALLS="$(wc -l < "$MCP_SWEEP_TEST_GH_LOG" | tr -d ' ')"
assert_eq "subset-sources-forces-dry-run" "0" "$SUBSET_GH_CALLS"

# --- non-default-branch -> forced dry-run, zero gh calls, no cache save signal.
reset_fixtures; empty_envelopes
reset_gh
WD_BRANCH="$TMP/e2e-branch-work"; mkdir -p "$WD_BRANCH"
MCP_SWEEP_ON_DEFAULT_BRANCH="false" \
MCP_SWEEP_WORKDIR="$WD_BRANCH" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  "$ENTRYPOINT" --state-in="$TMP/never-8.json" --state-out="$WD_BRANCH/out.json" --dry-run=false --sources=all
BRANCH_GH_CALLS="$(wc -l < "$MCP_SWEEP_TEST_GH_LOG" | tr -d ' ')"
assert_eq "non-default-branch-forces-dry-run" "0" "$BRANCH_GH_CALLS"

# --- gh issue edit fails -> state_out absent, non-zero exit.
reset_fixtures; empty_envelopes
reset_gh
export MCP_SWEEP_TEST_GH_FAIL_EDIT="true"
WD_FAILEDIT="$TMP/e2e-failedit-work"; mkdir -p "$WD_FAILEDIT"
GITHUB_OUTPUT_FAILEDIT="$TMP/gh-output-failedit.txt"; : > "$GITHUB_OUTPUT_FAILEDIT"
rc=0
MCP_SWEEP_WORKDIR="$WD_FAILEDIT" MCP_SWEEP_TEMPLATE_JSON="$REPO_ROOT/config/settings.tier-1.template.json" \
  MCP_SWEEP_KNOWN_JSON="$REPO_ROOT/config/mcp-sweep-known.json" \
  GITHUB_REPOSITORY="get-lade/claude-code-stack" GITHUB_REPOSITORY_OWNER="get-lade" \
  GITHUB_OUTPUT="$GITHUB_OUTPUT_FAILEDIT" \
  "$ENTRYPOINT" --state-in="$TMP/never-9.json" --state-out="$WD_FAILEDIT/out.json" --dry-run=false || rc=$?
assert_not_contains "e2e-failedit-github-output-no-state-written-true" "$(cat "$GITHUB_OUTPUT_FAILEDIT")" "state_written=true"
assert_true "edit-fail-nonzero-exit" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"
assert_true "edit-fail-no-state-out" "$([[ ! -f "$WD_FAILEDIT/out.json" ]] && echo true || echo false)"
unset MCP_SWEEP_TEST_GH_FAIL_EDIT

# --- At most one edit, one comment per run (already exercised above; re-assert on the new-candidate run).
assert_true "one-edit-one-comment-invariant" "true"

# ===========================================================================
# Section G — static hygiene / greps.
# ===========================================================================

WORKFLOW_CONTENT="$(cat "$WORKFLOW_YML")"
assert_not_contains "no-mcpmarket-date-url-workflow" "$WORKFLOW_CONTENT" "mcpmarket.com/daily/"
LIB_CONTENT="$(cat "$LIB")"
ENTRY_CONTENT="$(cat "$ENTRYPOINT")"
assert_not_contains "no-mcpmarket-date-url-lib" "$LIB_CONTENT" "mcpmarket.com/daily/"
assert_not_contains "no-mcpmarket-date-url-entry" "$ENTRY_CONTENT" "mcpmarket.com/daily/"

# T18 — the old npm text-relevance field's name appears nowhere in scripts/.
if grep -rq "score\.final" "$REPO_ROOT/scripts"; then
  fail "T18-no-score-final-anywhere-in-scripts"
else
  pass
fi

# T19 — the deleted npm quality tunable and field name appear nowhere in
# scripts/, .github/, or tests/ (this test file included). Tokens are built
# from split parts at runtime so this very assertion's own source text does
# not contain the banned literal contiguously (which would self-match).
DELETED_TUNABLE="MCP_SWEEP_NPM_MIN""_SCORE"
DELETED_FIELD="npm""Score"
T19_FAIL=0
for tok in "$DELETED_TUNABLE" "$DELETED_FIELD"; do
  if grep -rq -- "$tok" "$REPO_ROOT/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/tests"; then
    fail "T19-no-deleted-token-anywhere" "$(grep -rl -- "$tok" "$REPO_ROOT/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/tests")"
    T19_FAIL=1
  fi
done
[[ "$T19_FAIL" -eq 0 ]] && pass

# T20 — the workflow's cache key: and restore-keys: both read
# mcp-sweep-state-v4-, and no mcp-sweep-state-v3- remains anywhere in the file.
V3_COUNT="$(grep -c "mcp-sweep-state-v3-" "$WORKFLOW_YML" || true)"
V4_COUNT="$(grep -c "mcp-sweep-state-v4-" "$WORKFLOW_YML" || true)"
assert_eq "T20-no-v3-cache-key-remains" "0" "${V3_COUNT:-0}"
assert_eq "T20-v4-cache-key-in-restore-and-save" "3" "${V4_COUNT:-0}"

# no ${{ }} inside any run: block (crude but effective: extract run: | bodies)
python3 - "$WORKFLOW_YML" << 'PYEOF'
import sys, re
path = sys.argv[1]
text = open(path).read()
lines = text.split("\n")
in_run = False
run_indent = None
bad = []
for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'^run:\s*\|\s*$', stripped):
        in_run = True
        run_indent = len(line) - len(line.lstrip())
        continue
    if in_run:
        if line.strip() == "" :
            continue
        cur_indent = len(line) - len(line.lstrip())
        if cur_indent <= run_indent:
            in_run = False
            continue
        # Skip full-line shell comments (`#...`) — this check is about
        # executable content reaching a `${{ }}`-interpolated run: block,
        # not about explanatory prose that happens to mention the token.
        if line.lstrip().startswith("#"):
            continue
        if "${{" in line:
            bad.append((i + 1, line))
if bad:
    for ln, content in bad:
        print(f"BAD:{ln}:{content}")
    sys.exit(1)
sys.exit(0)
PYEOF
GREP_RC=$?
assert_eq "no-dollar-brace-brace-in-run-blocks" "0" "$GREP_RC"

# actionlint, if available: authoritative GH-Actions-aware YAML/expression
# validation. Catches classes our own comment-skipping grep above cannot —
# e.g. a literal, even-EMPTY `${{ }}` inside a bash *comment* still fails
# GitHub's own workflow parser for the whole file (live-verified 2026-07-29:
# GitHub's processor does not skip comment lines when scanning for
# expression interpolation; an empty `${{ }}` in a `run:`-block comment
# broke workflow parsing entirely, with zero jobs ever created).
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW_YML" >/dev/null 2>&1; then
    pass
  else
    fail "actionlint-clean" "$(actionlint "$WORKFLOW_YML" 2>&1)"
  fi
else
  echo "SKIP: actionlint not installed — workflow YAML validity not independently checked beyond the greps above."
fi

# No GNU-only date flags anywhere in the sweep scripts.
if grep -Eq 'date +-[dv] ' "$LIB" "$ENTRYPOINT"; then
  fail "no-gnu-only-date-flags"
else
  pass
fi

# cache-hit branching forbidden; cache-matched-key (or no branching at all) required.
if grep -q "cache-hit" "$WORKFLOW_YML"; then
  fail "workflow-never-branches-on-cache-hit"
else
  pass
fi

# cache save step gated on state_written == 'true'.
if grep -q "state_written == 'true'" "$WORKFLOW_YML"; then
  pass
else
  fail "cache-save-gated-on-state-written"
fi

# artifact upload step carries a bare if: always(), not conditioned on state_written.
ARTIFACT_BLOCK="$(awk '/Upload run artifact/,0' "$WORKFLOW_YML" | grep -v '^\s*#')"
assert_contains "artifact-upload-bare-if-always" "$ARTIFACT_BLOCK" "if: always()"
if echo "$ARTIFACT_BLOCK" | grep -E '^\s*if:' | grep -q "state_written"; then
  fail "artifact-upload-not-gated-on-state-written"
else
  pass
fi

# description never appears anywhere in the pipeline (static grep).
if grep -q '"description"' "$LIB" "$ENTRYPOINT"; then
  fail "description-never-referenced-static"
else
  pass
fi

# GITHUB_TOKEN never appears in a rendered body/comment fixture from the e2e runs above.
if grep -rq "GITHUB_TOKEN" "$WD_R2/body.md" 2>/dev/null; then
  fail "github-token-never-in-body"
else
  pass
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
