#!/usr/bin/env bash
# Tests for tools/handbook/gen.mjs (ADR-081).
# Builds a disposable fixture repo root; never touches the real tree.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/tools/handbook/gen.mjs"
PASS=0; FAIL=0; NOTRUN=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { # check <desc> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want rc=$2 got rc=$3)"; fi
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/handbook-fix.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

mk_fixture() {
  rm -rf "$FIX"; mkdir -p "$FIX"/{agents,config,skills/alpha,skills/beta,tools/handbook,docs/handbook/deck}
  cat > "$FIX/agents/one.md" <<'EOF'
---
name: one
model: sonnet
tools: Read
allowed_invokes:
  - two
forbidden_invokes:
  - two
description: Agent one does one thing.
dispatch_when: when one-shaped work appears
---

# one

Body paragraph for one.
EOF
  cat > "$FIX/agents/two.md" <<'EOF'
---
name: two
model: opus
escalation_model: opus
tools: Read, Write
allowed_invokes: []
description: Agent two does another thing.
dispatch_when: when two-shaped work appears
---

# two

Body paragraph for two.
EOF
  cat > "$FIX/config/model-routing.json" <<'EOF'
{
  "subagent_assignments": {
    "one": {"primary": "anthropic/claude-sonnet-5", "effort": "medium"},
    "two": {"primary": "gemini/gemini-pro", "orchestrated_by": "anthropic/claude-sonnet-5", "escalation": "anthropic/claude-opus-5"}
  }
}
EOF
  cat > "$FIX/config/capability-registry.json" <<'EOF'
{
  "capabilities": [
    {"id": "one", "kind": "subagent", "summary": "one.", "tier_min": 0, "invocation": {"slash": null}},
    {"id": "two", "kind": "subagent", "summary": "two.", "tier_min": 2, "invocation": {"slash": null}},
    {"id": "alpha", "kind": "skill", "summary": "alpha summary.", "tier_min": 0, "invocation": {"slash": "/alpha"}, "user_invocable": true},
    {"id": "beta", "kind": "skill", "summary": "beta summary.", "tier_min": 1, "invocation": {"slash": "/beta"}, "user_invocable": true},
    {"id": "some-hook", "kind": "hook", "summary": "a hook.", "tier_min": 0}
  ]
}
EOF
  cat > "$FIX/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: Alpha does alpha things. Use when alpha is needed.
---
body
EOF
  cat > "$FIX/skills/beta/SKILL.md" <<'EOF'
---
name: beta
description: Beta does beta things.
---
body
EOF
  cat > "$FIX/tools/handbook/groups.json" <<'EOF'
{
  "alpha": {"group": "dev workflow", "touches": "reads code only"},
  "beta": {"group": "safety gates", "touches": "edits config"}
}
EOF
  cat > "$FIX/docs/handbook/README.md" <<'EOF'
# Handbook

<!-- gen:toc:start -->
<!-- gen:toc:end -->

Hand prose below.
EOF
  cat > "$FIX/docs/handbook/00-executive-summary.md" <<'EOF'
# Executive summary

Narrative prose before any slide.

<!-- slide: Why it exists -->
takeaway: One assistant became a governed team.
- friction one
- friction two
notes: Speak slowly here.
  Continue the note.
<!-- /slide -->

More prose. A code sample follows:

```
<!-- slide: Not a slide -->
takeaway: should be ignored
<!-- /slide -->
```

<!-- slide: What changed -->
takeaway: Shipping has gates now with <script> safety.
<!-- /slide -->
EOF
}

echo "== handbook generator tests =="

# 1. write mode + determinism
mk_fixture
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1; check "write mode runs clean" 0 $?
[ -f "$FIX/docs/handbook/agents/one.md" ] && [ -f "$FIX/docs/handbook/agents/two.md" ] && ok "agent pages written" || bad "agent pages missing"
[ -f "$FIX/docs/handbook/skills-glossary.md" ] && ok "glossary written" || bad "glossary missing"
[ -f "$FIX/docs/handbook/deck/slides.json" ] && [ -f "$FIX/docs/handbook/deck/index.html" ] && ok "deck written" || bad "deck missing"
grep -q "pptxgenjs\|NOT-EXECUTED\|stack-presentation" /dev/null 2>/dev/null # placeholder no-op
SNAP1="$(cat "$FIX"/docs/handbook/agents/*.md "$FIX/docs/handbook/skills-glossary.md" "$FIX/docs/handbook/deck/slides.json" "$FIX/docs/handbook/deck/index.html" "$FIX/docs/handbook/deck/site.html" 2>/dev/null | shasum | cut -d' ' -f1)"
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
SNAP2="$(cat "$FIX"/docs/handbook/agents/*.md "$FIX/docs/handbook/skills-glossary.md" "$FIX/docs/handbook/deck/slides.json" "$FIX/docs/handbook/deck/index.html" "$FIX/docs/handbook/deck/site.html" 2>/dev/null | shasum | cut -d' ' -f1)"
[ "$SNAP1" = "$SNAP2" ] && ok "second run byte-identical" || bad "nondeterministic output"

# glossary content assertions
grep -q "Alpha does alpha things" "$FIX/docs/handbook/skills-glossary.md" && ok "glossary uses full SKILL.md description" || bad "glossary missing full description"
grep -q "some-hook" "$FIX/docs/handbook/skills-glossary.md" && ok "hooks appendix present" || bad "hooks appendix missing"
grep -q "orchestrated_by" "$FIX/docs/handbook/agents/two.md" && ok "orchestrator labelled from routing" || bad "orchestrated_by not rendered"
grep -q "Not stated in source." "$FIX/docs/handbook/agents/two.md" && ok "honest fallback text" || bad "fallback text missing"

# 2. --check clean, then drift classes
node "$GEN" --repo-root "$FIX" --check >/dev/null 2>&1; check "--check clean after write" 0 $?
sed -i.bak 's/one thing/ONE THING/' "$FIX/agents/one.md"
node "$GEN" --repo-root "$FIX" --check >/dev/null 2>&1; check "--check detects agent description drift" 1 $?
mv "$FIX/agents/one.md.bak" "$FIX/agents/one.md"
sed -i.bak 's/"effort": "medium"/"effort": "high"/' "$FIX/config/model-routing.json"
node "$GEN" --repo-root "$FIX" --check >/dev/null 2>&1; check "--check detects routing drift" 1 $?
mv "$FIX/config/model-routing.json.bak" "$FIX/config/model-routing.json"
sed -i.bak 's/One assistant/A bot/' "$FIX/docs/handbook/00-executive-summary.md"
node "$GEN" --repo-root "$FIX" --check >/dev/null 2>&1; check "--check detects slides.json drift" 1 $?
mv "$FIX/docs/handbook/00-executive-summary.md.bak" "$FIX/docs/handbook/00-executive-summary.md"
node "$GEN" --repo-root "$FIX" --check >/dev/null 2>&1; check "--check clean after reverts" 0 $?

# 3. exit-3 classes
mk_fixture; node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
rm "$FIX/agents/two.md"
OUT="$(node "$GEN" --repo-root "$FIX" 2>&1)"; RC=$?
check "routing key without agent file -> exit 3" 3 $RC
mk_fixture; node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
rm "$FIX/agents/two.md"
node - "$FIX/config/model-routing.json" <<'EOF'
const fs=require('fs');const p=process.argv[2];const j=JSON.parse(fs.readFileSync(p));delete j.subagent_assignments.two;fs.writeFileSync(p,JSON.stringify(j));
EOF
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1
# registry still lists 'two' as subagent but no file: alignment only covers routing<->files; regenerate should purge orphan page
[ ! -f "$FIX/docs/handbook/agents/two.md" ] && ok "orphan page purged on source deletion" || bad "orphan page not purged"

mk_fixture
sed -i.bak '/dispatch_when/d' "$FIX/agents/one.md"
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1; check "missing dispatch_when -> exit 3" 3 $?
mk_fixture
node - "$FIX/tools/handbook/groups.json" <<'EOF'
const fs=require('fs');const p=process.argv[2];const j=JSON.parse(fs.readFileSync(p));delete j.alpha;fs.writeFileSync(p,JSON.stringify(j));
EOF
node "$GEN" --repo-root "$FIX" 2>&1 | grep -q "alpha" ; check "unmapped skill named in error" 0 $?
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1; check "unmapped skill -> exit 3" 3 $?
mk_fixture
node - "$FIX/tools/handbook/groups.json" <<'EOF'
const fs=require('fs');const p=process.argv[2];const j=JSON.parse(fs.readFileSync(p));j.ghost={group:"personal",touches:"nothing"};fs.writeFileSync(p,JSON.stringify(j));
EOF
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1; check "phantom groups key -> exit 3" 3 $?

# 4. parser failures
mk_fixture
printf '%s\n' '<!-- slide: Broken -->' '- bullet only' '<!-- /slide -->' >> "$FIX/docs/handbook/00-executive-summary.md"
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1; check "missing takeaway -> exit 3" 3 $?
mk_fixture
printf '%s\n' '<!-- slide: Doubled -->' 'takeaway: t' 'notes: a' '' 'notes: b' '<!-- /slide -->' >> "$FIX/docs/handbook/00-executive-summary.md"
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1; check "two notes blocks -> exit 3" 3 $?
mk_fixture
printf '%s\n' '<!-- slide: Unclosed -->' 'takeaway: t' >> "$FIX/docs/handbook/00-executive-summary.md"
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1; check "unclosed slide -> exit 3" 3 $?
mk_fixture
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
node - "$FIX/docs/handbook/deck/slides.json" <<'EOF'
const fs=require('fs');const s=JSON.parse(fs.readFileSync(process.argv[2]));
if(s.length!==2) process.exit(1);                             // fenced fake slide excluded
if(!/Continue the note/.test(s[0].notes)) process.exit(2);    // multi-line notes joined
process.exit(0);
EOF
check "fenced-code slide ignored + notes continuation" 0 $?
grep -q "&lt;script&gt;" "$FIX/docs/handbook/deck/index.html" && ok "HTML escaping applied" || bad "HTML not escaped"
grep -Eq 'src="https?://|href="https?://|url\(https?|@import' "$FIX/docs/handbook/deck/index.html" && bad "external URL in deck html" || ok "deck html self-contained"

# 5. TOC markers
mk_fixture
sed -i.bak '/gen:toc:start/d' "$FIX/docs/handbook/README.md"
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1; check "missing TOC marker -> exit 3" 3 $?

# 6. header guard
mk_fixture; node "$GEN" --repo-root "$FIX" >/dev/null 2>&1
printf 'hand-written content\n' > "$FIX/docs/handbook/agents/one.md"
node "$GEN" --repo-root "$FIX" >/dev/null 2>&1; check "hand-edited generated file -> exit 4" 4 $?
grep -q "hand-written content" "$FIX/docs/handbook/agents/one.md" && ok "hand-edited file untouched" || bad "hand-edited file clobbered"

# 7. usage
node "$GEN" 2>/dev/null; check "missing --repo-root -> exit 2" 2 $?
node "$GEN" --repo-root "$FIX" --bogus 2>/dev/null; check "unknown arg -> exit 2" 2 $?

# 7b. portable roster mode (spec 2026-08-16-handbook-portable-design)
mk_fixture
PROD="$(mktemp -d "${TMPDIR:-/tmp}/handbook-prod.XXXXXX")"
mkdir -p "$PROD/agents"; echo "not a roster" > "$PROD/agents/app-thing.md"   # generic agents/ dir must not crash
HANDBOOK_ROSTER_ROOT="$FIX" node "$GEN" --repo-root "$PROD" >/dev/null 2>&1; check "env-root generates into product repo" 0 $?
[ -f "$PROD/docs/handbook/agents/one.md" ] && ok "env-root pages written to --repo-root" || bad "env-root pages missing"
grep -q '<!-- roster: env -->' "$PROD/docs/handbook/agents/one.md" && ok "roster class token env" || bad "roster line wrong"
grep -rq '/handbook-fix' "$PROD/docs/handbook" && bad "absolute path leaked into generated file" || ok "no absolute paths in output"
HANDBOOK_ROSTER_ROOT="relative/path" node "$GEN" --repo-root "$PROD" >/dev/null 2>&1; check "relative env root -> exit 3" 3 $?
HANDBOOK_ROSTER_ROOT="$PROD" node "$GEN" --repo-root "$PROD" >/dev/null 2>&1; check "incomplete env root -> exit 3" 3 $?

# installed fallback via HOME (bare ~/.claude branch, no env override)
FAKEHOME="$(mktemp -d "${TMPDIR:-/tmp}/handbook-home.XXXXXX")"
mkdir -p "$FAKEHOME/.claude"
cp -R "$FIX/agents" "$FAKEHOME/.claude/agents"
mkdir -p "$FAKEHOME/.claude/config" "$FAKEHOME/.claude/tools/handbook" "$FAKEHOME/.claude/skills"
cp "$FIX/config/model-routing.json" "$FAKEHOME/.claude/config/"
cp "$FIX/config/capability-registry.json" "$FAKEHOME/.claude/config/"
cp "$FIX/tools/handbook/groups.json" "$FAKEHOME/.claude/tools/handbook/"
cp -R "$FIX/skills/alpha" "$FAKEHOME/.claude/skills/alpha"      # beta deliberately absent -> glossary degradation
rm "$FAKEHOME/.claude/agents/two.md"                             # tier-truncated install
HOME="$FAKEHOME" node "$GEN" --repo-root "$PROD" >/dev/null 2>&1; check "installed fallback generates" 0 $?
grep -q '<!-- roster: installed -->' "$PROD/docs/handbook/agents/one.md" && ok "roster class token installed" || bad "installed class missing"
[ ! -f "$PROD/docs/handbook/agents/two.md" ] && ok "routing-only key skipped in installed mode" || bad "routing-only key not skipped"
grep -q "abbreviated" "$PROD/docs/handbook/skills-glossary.md" && ok "glossary degradation line present" || bad "degradation line missing"
rm -rf "$PROD" "$FAKEHOME"

# 7c. deck/site NOT-EXECUTED and site rendering
mk_fixture
rm "$FIX/docs/handbook/00-executive-summary.md"
OUT="$(node "$GEN" --repo-root "$FIX" --deck 2>&1)"; RC=$?
check "--deck without exec summary exits 0" 0 $RC
echo "$OUT" | grep -q "NOT-EXECUTED: deck" && ok "deck NOT-EXECUTED reported" || bad "deck NOT-EXECUTED missing"
[ -f "$FIX/docs/handbook/deck/site.html" ] && ok "site built without exec summary" || bad "site missing"
mk_fixture
printf '%s\n' '# Extra' '' 'See [one](agents/one.md) and <script>alert(1)</script> and [gone](missing-page.md).' > "$FIX/docs/handbook/01-extra.md"
node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
SITE="$FIX/docs/handbook/deck/site.html"
[ -f "$SITE" ] && ok "site.html built" || bad "site.html missing"
grep -Eq 'src="https?://|url\(https?|@import|<link[^>]+href="https?://' "$SITE" && bad "external asset in site" || ok "site assets self-contained"
grep -q '&lt;script&gt;' "$SITE" && ok "site escapes raw html" || bad "site html not escaped"
grep -q 'href="#agents-one' "$SITE" && ok "cross-page link rewritten to anchor" || bad "anchor rewrite failed"
grep -q 'and gone\.' "$SITE" && ! grep -q '<a[^>]*>gone</a>' "$SITE" && ok "absent-page link rendered as text" || bad "absent-page link mishandled"

# 8. pptx (structural smoke; requires node_modules)
if [ -d "$ROOT/tools/handbook/node_modules/pptxgenjs" ]; then
  mk_fixture
  node "$GEN" --repo-root "$FIX" --deck >/dev/null 2>&1
  PPTX="$FIX/docs/handbook/deck/stack-presentation.pptx"
  if [ -f "$PPTX" ]; then
    unzip -l "$PPTX" 2>/dev/null | grep -q '\[Content_Types\].xml' && ok "pptx has content types" || bad "pptx missing content types"
    NSLIDES="$(unzip -l "$PPTX" 2>/dev/null | grep -c 'ppt/slides/slide[0-9]*\.xml$')"
    [ "$NSLIDES" = "2" ] && ok "pptx slide count matches slides.json" || bad "pptx slide count $NSLIDES != 2"
  else
    bad "pptx not produced despite node_modules present"
  fi
else
  NOTRUN=$((NOTRUN+2)); echo "  NOT-EXECUTED: pptx structural tests (npm ci --prefix tools/handbook)"
fi

echo "== $PASS passed, $FAIL failed, $NOTRUN not executed =="
[ "$FAIL" = "0" ]
