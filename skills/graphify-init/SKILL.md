---
name: graphify-init
description: One-time, free, idempotent setup of the graphify knowledge-graph tool for this repo. Creates the pinned shared venv (graphifyy[gemini,sql]==0.9.32) at ~/.claude/tools/graphify/, verifies both extras, and adds the output paths to .gitignore BEFORE any extraction can run. Writes no CLAUDE.md region — that is /graphify-extract's job, after a graph actually exists (ADR-054 D10). Spends nothing and sends nothing off-machine. Run before /graphify-extract. ADR-054.
---

# /graphify-init

One-time, free, idempotent. Sets up the shared `graphify` venv and this repo's
`.gitignore`. Spends nothing, sends nothing off-machine, writes no CLAUDE.md
region. See `docs/ADRs/054-graphify-standardization.md` for the full design —
this skill implements ADR-054 D2, D7 (P1–P3), D9, D10 rule 1, and D11's offer.

## Steps

### 1. Venv (D2)
If `~/.claude/tools/graphify/.venv` is absent:
```bash
python3 -m venv ~/.claude/tools/graphify/.venv
~/.claude/tools/graphify/.venv/bin/pip install -r ~/.claude/tools/graphify/requirements.txt
```
If the venv already exists, reuse it as-is. **Never run `pip install
--upgrade`** — a version bump is a manual pin edit per ADR-054 D2, not
something any skill does automatically.

### 2. Verify extras (D7 P2/P3)
In the venv:
```bash
~/.claude/tools/graphify/.venv/bin/python -c "import openai"
~/.claude/tools/graphify/.venv/bin/python -c "import tree_sitter_sql"
```
Either import failing ⇒ print the exact remediation and stop (do not continue
to step 3):
- `import openai` fails: `pip install "graphifyy[gemini]"` — this is the
  observed loud failure mode (all chunks error `openai package required`).
- `import tree_sitter_sql` fails: `pip install "graphifyy[sql]"` — this is
  the dangerous **silent** failure mode: `.sql` files parse to zero nodes
  with no error at all.

### 3. Version (D2, D7 P1)
```bash
~/.claude/tools/graphify/.venv/bin/graphify --version
```
Must equal `0.9.32` exactly. A mismatch means something pip-installed over
the pinned venv — stop and cite ADR-054 D2's bump procedure (edit the pin,
blow away the venv, re-run the full test plan against a real repo, record
the delta in the calibration log, amend the ADR's pin line). Do not
auto-correct the mismatch.

### 4. `.gitignore` (D9)
Append to the target repo's `.gitignore`, matching on the exact line so
re-runs never duplicate:
```
# graphify (ADR-054) — regenerable, large, contains source excerpts. Never commit.
graphify-out/
graph.json
```
Also ensure `.claude/graphify/` is present in the repo's existing stack
scratch `.gitignore` block (the same block `/project-init` step 6 writes) —
add it there if missing, using the same exact-line match. If `.gitignore`
cannot be written (permissions, absent repo root, etc.), stop here — do not
proceed to step 5, and do not let `/graphify-extract` run with an un-ignored
output path (ADR-054 D9's ordering is load-bearing: the egress-candidate
scan in `/graphify-extract` step 3a excludes gitignored paths, so an
un-ignored `graphify-out/` would enter the scan set as if the tool's own
output were repo source).

### 5. Vendor skill — do not install
Per ADR-054's resolved open question (option a): do **not** run
`graphify install --platform claude`. `~/.claude/skills/graphify/` (the
vendor's own directory) is left untouched by this skill.

### 6. No CLAUDE.md edit
This skill must not create, update, or remove the
`<!-- GRAPHIFY_MANAGED -->` region in any CLAUDE.md (ADR-054 D10 rule 1).
That region is written only by `/graphify-extract`, only after a receipt
exists, only from that receipt's real values — writing it here, before a
graph exists, would tell Claude a queryable graph is available when none is.

### 7. Offer
Ask: "Build the graph now? This is metered. [y/N]"
- `y` ⇒ invoke `/graphify-extract`.
- `n` / no answer ⇒ done, print nothing further.

This step never blocks or fails init — a declined offer, or any error
surfaced by `/graphify-extract` if invoked, is not a failure of
`/graphify-init` itself, which has already completed successfully by this
point.
