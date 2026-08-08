#!/usr/bin/env bash
# Test: merge_json interactive conflict resolution, driven through a pty.
# `expect` answers the per-conflict prompt. Skips cleanly if expect is absent
# (the non-interactive path is covered by test-config-merger.sh).

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
MERGER="$SCRIPT_DIR/../scripts/lib/config-merger.sh"

if ! command -v expect > /dev/null 2>&1; then
  echo "SKIP: expect not installed — interactive merge path not exercised"
  exit 0
fi

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

# Wrapper expect can spawn with no nested quoting on the spawn line.
cat > "$TMP/do-merge.sh" << EOF
#!/usr/bin/env bash
source "$MERGER"
merge_json "\$1" "\$2"
EOF
chmod +x "$TMP/do-merge.sh"

# Expect driver. argv: answer, wrapper, source, target.
cat > "$TMP/drive.exp" << 'EOF'
set timeout 10
set ans [lindex $argv 0]
set mrg [lindex $argv 1]
set src [lindex $argv 2]
set tgt [lindex $argv 3]
spawn bash $mrg $src $tgt
expect {
  -re {Use the stack value\? \[y/N\] } { send "$ans\r" }
  timeout { exit 2 }
  eof     { exit 3 }
}
expect eof
EOF

make_fixture() {
  cat > "$1/target.json" << 'EOF'
{ "shared": "user_value", "only_user": 1 }
EOF
  cat > "$1/source.json" << 'EOF'
{ "shared": "stack_value", "only_stack": 2 }
EOF
}

drive() {  # $1 = dir, $2 = answer (y|n)
  expect "$TMP/drive.exp" "$2" "$TMP/do-merge.sh" \
    "$1/source.json" "$1/target.json" > /dev/null
}

failures=0

# Scenario A: approve the conflict -> stack value wins
mkdir -p "$TMP/a"; make_fixture "$TMP/a"
if ! drive "$TMP/a" y; then
  echo "FAIL: expect driver failed (approve case)"; failures=$((failures + 1))
fi
if ! jq -e '.shared == "stack_value"' "$TMP/a/target.json" > /dev/null 2>&1; then
  echo "FAIL: approved conflict did not take the stack value"
  failures=$((failures + 1))
fi
if ! jq -e '.only_user == 1 and .only_stack == 2' "$TMP/a/target.json" > /dev/null 2>&1; then
  echo "FAIL: non-conflicting keys lost (approve case)"
  failures=$((failures + 1))
fi

# Scenario B: decline the conflict -> user value kept
mkdir -p "$TMP/b"; make_fixture "$TMP/b"
if ! drive "$TMP/b" n; then
  echo "FAIL: expect driver failed (decline case)"; failures=$((failures + 1))
fi
if ! jq -e '.shared == "user_value"' "$TMP/b/target.json" > /dev/null 2>&1; then
  echo "FAIL: declined conflict did not keep the user value"
  failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS: interactive conflict resolution (approve + decline)"
  exit 0
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
