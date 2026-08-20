---
name: graphify-extract
description: Build or refresh this repo's graphify knowledge graph. METERED — sends the corpus to a hosted LLM backend. Runs preflight assertions, a sensitivity/egress gate, a free --code-only inventory, then a written cost projection, and HARD STOPS for the literal word "proceed" before spending anything. Writes .claude/graphify/receipt.json and appends to the calibration log. ADR-054.
---

# /graphify-extract

Build or refresh this repo's `graphify` knowledge graph. **METERED** —
full extraction sends the corpus to a hosted LLM backend and costs real
money. This skill never runs without an explicit `proceed`. See
`docs/ADRs/054-graphify-standardization.md` (D4–D10) for the full design;
this file is the executable contract.

Run `/graphify-init` first if the shared venv does not exist yet.

Steps run in this exact order. Numbering matches this skill's own contract
(ADR-054 D4's preamble notes the two documents' numbering diverges for
steps 4–6 only; 1–3 (incl. 3a/3b/3c), 6.5, and 7 mean the same thing in
both).

## 1. Preflight P1–P4 (ADR-054 D7)
Run all of these before any spend. Any failure ⇒ stop with the exact
remediation command; do not warn-and-continue.

| # | Assertion | On failure |
|---|---|---|
| P1 | `~/.claude/tools/graphify/.venv/bin/graphify --version` equals `0.9.32` | Stop. Cite ADR-054 D2's bump procedure — a mismatch means someone pip-installed over the venv. |
| P2 | Backend is gemini/openai/deepseek ⇒ `~/.claude/tools/graphify/.venv/bin/python -c "import openai"` succeeds | Stop. Print `pip install "graphifyy[gemini]"` (the observed loud failure: 15/15 chunks errored `openai package required`). |
| P3 | Repo contains ≥1 `.sql` file ⇒ `~/.claude/tools/graphify/.venv/bin/python -c "import tree_sitter_sql"` succeeds | Stop. Print `pip install "graphifyy[sql]"` — **hard fail**, because the failure mode is a silent schema-blind graph, not an error. |
| P4 | Backend key resolves — `GEMINI_API_KEY` env, else macOS Keychain `gemini-api-key` | Stop. Cite the tier-3 `gemini_requirement` idiom (ADR-027/ADR-031) — API only, never a CLI. |

## 2. Preflight P5 — `.gitignore` covers the outputs (ADR-054 D7, D9)
Confirm the target repo's `.gitignore` already contains `graphify-out/`,
`graph.json`, and `.claude/graphify/`. If not, stop and point at
`/graphify-init` — do not extract until it does. **This must run before
step 3a**, not merely before spend: step 3a's enumeration excludes
gitignored paths, so an un-ignored `graphify-out/` would enter the
egress-candidate scan as if the tool's own output were repo source.

**No `graphify` CLI invocation of any kind — including the free
`--code-only` inventory in step 4 — may run before P5 passes.**

## 3. Sensitivity gate (ADR-054 D6), three sub-steps in this order

### 3a. Egress-candidate set (ECS)
Free, local, zero network, zero egress, zero LLM:
```bash
git ls-files -z --cached --others --exclude-standard
```
Restrict to paths that still exist in the worktree. This is a
**stack-owned enumeration and comes from no `graphify` report** — that is
the entire point of this step. If the target is not a git worktree, the
ECS is uncomputable: treat the repo as `confidential` (the D6 table),
refuse full extraction, and offer `--code-only`.

Compute the ECS **once**, here, and reuse it four ways: by 3c below, by
step 6.5 as the diff baseline, by step 7(i)'s containment check, and — only
if the V1 branch below selects it — as step 5's projection denominator.
The enumeration *command* itself is re-run twice more against the live
worktree later, for two different purposes: at step 6.5 to compute the
pause-window delta, and at step 7 purely as a classifier for the
containment check's escapees. The 3a snapshot itself is never mutated
once taken.

### 3b. Config arm
Read `sensitivity.level` from the target repo's `.claude/stack-config.json`.
- `confidential` ⇒ full extraction refused; `--code-only` offered.
- Missing, unreadable, or unparseable config ⇒ **treated as `confidential`**
  (fail-safe on ambiguity — a repo with no stack-config is exactly the repo
  whose sensitivity nobody has assessed).
- `normal` or `sensitive` ⇒ continue to 3c; 3c can only raise this, never
  lower it.

### 3c. Heuristic arm
Source `~/.claude/scripts/lib/deepseek-review.sh` and reuse its
`DSR_BLOCK_RE` variable — **never** copy the regex inline; a copy drifts
away from the original the first time ADR-029's pattern is tuned. Run it
over the **3a ECS** — paths and contents (`grep -I`; binary files skipped,
no directory exempted by name). This is the dispatch-eligible file set,
never the `--code-only` code-file set (that substitution was round 2's
CRITICAL and is exactly what the ECS exists to prevent).

Any hit on either arm ⇒ the effective level is at least `sensitive`,
whatever the config said. This arm can only **escalate**; a clean scan
never de-escalates a declared `sensitive` or `confidential` level.

**When the effective level is `sensitive` (declared or escalated):**
require an explicit acknowledgement — naming the provider, the backend
model, the volume ("~N MB of source across F files will be sent to
`<provider>`"), and, if escalated, the triggering evidence ("matched
`<first hit path>`; N of F **scanned** files matched") — before any
`graphify` invocation whatsoever, including step 4's free inventory. On
acknowledgement, write a `graphify.egress_ack` `change_history` entry
carrying the user's one-line reason and, if escalated, that same evidence
string verbatim. **This is the only durable record written at this
point** — see the `F` rule and the receipt-timing rule immediately below;
do **not** write anything into `.claude/graphify/receipt.json` here. Hold
the acknowledgement (its timestamp, the user's reason, and the setting
name `graphify.egress_ack`) in memory; step 7(ii) is where it is written
into the receipt.

**The `F` rule — one rule, four write sites, stated together so a partial
fix is impossible.** `F` — the "N of **F** scanned files matched" token —
is **always the 3a ECS size, `|ECS|`, and nothing else.** Never the
code-file count, and never `|ECS ∪ Δ|` (the step-6.5 scan set of record) —
`Δ` does not exist yet when any of these four are written, and on most
runs never exists at all. `F` is character-identical across all four:
1. the acknowledgement text printed to the user here at 3c;
2. the `graphify.egress_ack` `change_history` entry written here at 3c;
3. `sensitivity_escalated_by` on the step-4 `mode: code-only` receipt;
4. `sensitivity_escalated_by` on the step-7 `mode: full` receipt.

A future edit that raises `F` to `|ECS ∪ Δ|` at step 7 alone — to "match"
step 6.5's larger scan set — reproduces the exact defect this rule
prevents, in a new location: the same run's two receipts would then
disagree about the same event. See step 6.5 and step 7(ii) for the
resulting (expected, documented) gap between `F` and
`egress_scan_files`.

## 4. Inventory: free `--code-only` run
```bash
~/.claude/tools/graphify/.venv/bin/graphify extract --code-only
```
Free, zero LLM, zero egress, permitted at every sensitivity level (P5 has
already passed). This report is **never an input to step 3c** — wiring it
there is exactly the round-2 CRITICAL step 3a exists to prevent.

**V1 decision (must be resolved empirically before this skill is trusted
in a new environment — ADR-054 D4 V1; record the outcome in
`notes.graphify` in the tier-3 manifest):**
- If the report's file count includes non-code files (docs, markdown,
  configs) ⇒ that count is the projection basis for step 5.
- If the report counts only parsed code files ⇒ the projection basis
  falls back to **the step-3a ECS enumeration size** instead, and step 5's
  band label states that its denominator is a git inventory rather than
  graphify's own report. The `--code-only` run still happens and its
  graph is still retained; only its count stops being the projection
  input.

Retain the graph — it is free, already written, and independently useful
for AST questions. Then, following step 7(ii)–(iv) below with
`"mode": "code-only"` and **no** containment check (nothing was
dispatched): write `.claude/graphify/receipt.json`, append the
calibration log is **not** done for a `code-only` run (calibration tracks
real spend only), and write/replace the `<!-- GRAPHIFY_MANAGED -->` region
in the project's `CLAUDE.md` from this receipt — this is the step ADR-054
D10 rule 2 means when it cites "D4 step 5." The region carries the
mandatory doc-blind caveat paragraph, because the mode is `code-only`. A
later full run overwrites both the graph and rewrites the receipt
(`"mode": "full"`) and the region.

## 5. Projection (ADR-054 D5)
```
files        = the V1-selected basis above
est_low_usd  = files * 0.0008
est_high_usd = files * 0.0018      # 1.5x safety margin on the doc-heavy anchor
```
Write `.claude/cost-projections/<YYYY-MM-DD>-graphify-<repo>.md` with a
3–4 line summary, and include this label verbatim in spirit:

> Calibrated on **n=2** full extractions, Gemini backend, graphifyy
> 0.9.32, 2026-08-01. The band is wide because measured tokens-per-file
> varied 1,245–1,900 between the two corpora. Changing backend or model
> invalidates this calibration entirely.

State plainly which basis produced `files` (graphify's own `--code-only`
report, or the step-3a git enumeration) so a reader can tell which V1
branch this run took.

**Calibration override.** Once
`~/.claude/tools/graphify/calibration.jsonl` holds **≥5** entries for the
current `graphify_version` + `backend` pair, compute the band from the
log's own min/max per-file cost instead of the constants above. Below 5,
use the shipped band and n=2 label unchanged.

**Hard cap.** If `est_high_usd` exceeds
`cost_protection.per_session_hard_cap_usd` (when set), **refuse outright**
— do not prompt — matching `/cost-cap`'s stated semantics.

## 6. Hard stop
Print the 3–4 line summary. Wait for the literal word `proceed`, for as
long as the human takes. Never background this wait or the run it gates.

## 6.5. Pre-dispatch re-scan of the pause window (mandatory)
This step runs **immediately after the `proceed` of step 6 returns**, and
**before step 7's `graphify extract` process is launched** — its position
is the entire fix; written earlier it re-scans the same corpus 3c already
scanned and closes nothing, written later it is the containment monitor,
which by construction reports too late.

Re-run 3a's enumeration command verbatim against the live worktree:
`ECS' = git ls-files -z --cached --others --exclude-standard` (restricted
to worktree-existing paths). `Δ = ECS' \ ECS` — **additions only**; a file
deleted or newly gitignored during the pause cannot be dispatched and is
not part of `Δ`.

Exactly three outcomes, no fourth:

- **`Δ` is empty** ⇒ fall through to step 7 unchanged.
  `egress_scan_files` = the 3a ECS size; `egress_scan_basis` carries no
  suffix.
- **`Δ` is non-empty and 3c's heuristic (same `DSR_BLOCK_RE`, same source)
  scans it clean** ⇒ dispatch. The **scan set of record** becomes
  `ECS ∪ Δ` — that is what `egress_scan_files` counts and what step 7(i)'s
  containment check subtracts. `egress_scan_basis` gains the suffix
  `+ pre-dispatch re-scan (D4 step 6.5)`. This is **not** what `F` means:
  `F` stays `|ECS|` everywhere it is written (the rule above). So
  `egress_scan_files` may legitimately exceed `F` by exactly `|Δ|` on this
  path — every file in `Δ` really was scanned, just after the
  acknowledgement text was already committed. This gap is expected and
  documented; do not "fix" it by recomputing `F`.
- **`Δ` is non-empty and the heuristic hits** ⇒ **abort the run outright.**
  This branch writes no acknowledgement record of any kind and prompts
  for nothing — no reason, no confirmation, no journal entry, no waiting.
  Nothing is dispatched, no full receipt is written, the calibration log
  is not appended, and the `<!-- GRAPHIFY_MANAGED -->` region is not
  rewritten — it still reflects whatever step 4 wrote. Print every
  matching path in `Δ`, which arm matched (path or content), and the
  first match. State plainly that the hard-stop pause changed the corpus
  after it was scanned, and instruct the user to **re-run
  `/graphify-extract` from the beginning** — say explicitly that the run
  is **not resumable**. Exit non-zero. This abort fires **whether or not
  3c already escalated earlier in this same run** — a prior escalation at
  3c never satisfies this check; this branch asks for nothing that an
  earlier step could have already supplied.

  A re-run recomputes 3a/3b/3c against the now-current worktree, so the
  file that triggered the abort is enumerated by the primary gate on the
  next attempt and, if it escalates there, is acknowledged exactly once,
  like any other file.

There is no second acknowledgement anywhere in this skill. The D5
projection and its hard-cap verdict are **not** recomputed over `Δ` — a
named, accepted residual: a delta bounded by one human's edits during one
interactive pause cannot move a band this wide.

## 7. Full extraction
**Precondition: step 6.5 completed with no escalation.** An escalation
there aborts the run; this step never executes in that case.

```bash
~/.claude/tools/graphify/.venv/bin/graphify extract
```

### 7a. Retry pass (default, ADR-054 D4 addendum — empirically chosen)
If the extraction above reports any `produced no nodes` files, run the
**exact same command again, unmodified** (no `--mode deep`, no
`--token-budget` change):
```bash
~/.claude/tools/graphify/.venv/bin/graphify extract
```
This is a normal incremental run — cached files are free, only the
previously-empty files are retried. **Do not loop this** — one retry only,
then continue to (i) below whether or not files are still empty.

This is the default because it was measured, once, against the two other
"try harder" knobs on a real corpus (530 files, claude-code-stack,
2026-08-02) and won on every axis:

| Variant | Extra cost | Nodes gained | Zero-node files after | Notes |
|---|---|---|---|---|
| **plain retry (this step)** | +$0.16 | **+57** | 99/174 retried | fewest dropped/misattributed nodes of the three |
| `--mode deep` (full re-run) | +$0.01 (same as baseline) | +10 | *more* empty (212/362) | lost 4 real ADRs to source-file ID collisions — a regression, not a fix |
| `--token-budget 120000` (2x) | +$0.15 (same as retry) | +10 | *more* empty (132/174) | no evidence files were truncated by the default budget |

Neither `--mode deep` nor a larger `--token-budget` is a stack default as
of this writing — both cost the same or more than a plain retry for a
**worse** graph on the one corpus tested. The residual zero-node files
after the retry are not a budget/depth problem: they cluster on files that
share a basename with others in the corpus (e.g. many
`architecture-critic.md` / `reviewer.md` under different review-round
directories), which appears to confuse the model's per-chunk file
attribution — no flag on this CLI fixes that. If a future corpus's
zero-node files behave differently, re-run this comparison before trusting
this table on that corpus; it is one data point, not a law.

Set `mode` for the receipt (step 7(ii)) to `"full+retry"` if this pass
changed anything (any file gained ≥1 node it didn't have before), else
leave it `"full"` (nothing was empty, or the retry found nothing new).

On completion of 7 (and 7a if it ran), in this exact order:

**(i) Containment check.** Run against the **final** `graph.json` — i.e.
after 7a's retry, if it ran. Collect the distinct file paths appearing in
`graph.json`'s node IDs (the node ID is *path + entity name*, so this
operand is genuinely vendor-side output, not our own git list handed back
to us). Re-run 3a's enumeration command once more against the live
worktree, purely as a classifier. Subtract the **scan set of record**
(`ECS ∪ Δ` from step 6.5 — *not* the bare 3a snapshot, or every
pause-window addition would misreport as an escapee despite having been
scanned). For each remaining path:
- **Absent from the fresh enumeration** ⇒ gitignored, or otherwise outside
  what `git ls-files --cached --others --exclude-standard` returns, yet
  the vendor's walk reached it. Print it loudly as a **V2 violation** —
  this is a real finding; the next run's posture is an open question for
  the maintainer.
- **Present in the fresh enumeration but not in the scan set of record**
  ⇒ the file appeared during extraction's own runtime. Print it as a
  **late addition**, explicitly not a V2 violation.

Both classes land in the receipt's `graph_paths_outside_scan_set`; the
distinction is **printed only** — add no additional receipt field for it.

**Known accepted residual, not fixed here:** a file created *and* deleted
inside extraction's runtime is walked into `graph.json` but is absent
from the fresh enumeration, so it is labelled a V2 violation when it was
really a transient artifact. This is a loud false alarm on a monitor,
never a silent miss, and is documented rather than patched (ADR-054 D6).

**(ii) Write `.claude/graphify/receipt.json`** (schema below).
**This is where the receipt's `egress_ack` object is written** — from the
acknowledgement held in memory since 3c, matching that entry's `at`,
`reason`, and `change_history_setting` exactly. `sensitivity_escalated_by`
carries the **same `F = |ECS|` evidence string** the step-4 `code-only`
receipt already carried, character-identical — never recompute `F` here
from the now-known `Δ`. A run that never escalated at 3c writes
`egress_ack: null` here, as on every earlier receipt in the run.
`nodes`/`edges`/`communities`/`in_tokens`/`out_tokens`/`usd`/
`zero_node_files`/`dropped_nodes` are the totals across step 7 **and**
7a combined (both passes are one build), never step 7 alone.

**(iii) Append one line** to `~/.claude/tools/graphify/calibration.jsonl`
(schema below) — one line for the whole build (7 + 7a combined), not one
line per pass.

**(iv) Write/replace the `<!-- GRAPHIFY_MANAGED -->` region** in the
project's `CLAUDE.md`, populated verbatim from the receipt just written
(region text below). Then print any `GRAPH-INCOMPLETE` counts, observing
the no-negative-conclusion rule (Signals section below).

## Receipt schema (`.claude/graphify/receipt.json`)

```json
{
  "graph_path": "graphify-out/graph.json",
  "graphify_version": "0.9.32",
  "backend": "gemini", "model": "<id>", "mode": "full",
  "extracted_at": "<iso>", "commit": "<sha>", "branch": "<name>",
  "files_dispatched": 500, "code_files": 164, "doc_files": 336,
  "dispatched_paths": ["docs/ADRs/001-....md", "skills/cost-gate/SKILL.md", "..."],
  "dispatched_paths_sha256": "<sha256 of the sorted list, newline-joined>",
  "untracked_dispatched": [],
  "zero_node_files": 0, "dropped_nodes": 0,
  "nodes": 2626, "edges": 3067, "communities": 421,
  "in_tokens": 950000, "out_tokens": 42000, "usd": 0.60,
  "sensitivity_at_extraction": "normal",
  "sensitivity_effective": "sensitive",
  "sensitivity_escalated_by": "heuristic: content match in scripts/lib/deepseek-review.sh (12 of 500 scanned files matched)",
  "egress_ack": {
    "at": "2026-08-01T14:19:52Z",
    "reason": "Private repo; Gemini backend approved for this one build.",
    "change_history_setting": "graphify.egress_ack"
  },
  "egress_scan_basis": "git ls-files --cached --others --exclude-standard (ADR-054 D4 step 3a)",
  "egress_scan_files": 500,
  "graph_paths_outside_scan_set": [],
  "provenance": {
    "recomputed_locally": ["commit", "branch", "files_dispatched", "extracted_at",
                           "graph_path", "dispatched_paths",
                           "dispatched_paths_sha256", "untracked_dispatched",
                           "sensitivity_at_extraction", "sensitivity_effective",
                           "sensitivity_escalated_by", "egress_ack",
                           "egress_scan_basis", "egress_scan_files"],
    "derived_from_vendor_output": ["graph_paths_outside_scan_set"],
    "reported_by_vendor": ["zero_node_files","dropped_nodes","nodes","edges",
                           "communities","in_tokens","out_tokens","usd"]
  }
}
```

`mode` is `"full"` if step 7a's retry pass never ran or changed nothing,
`"full+retry"` if it added ≥1 node (see step 7a). `dispatched_paths` is
machine-only — never printed to the user or included in any console
summary; `dispatched_paths_sha256` is what a human-facing summary displays
instead. A `mode: code-only` receipt carries `null` for
`egress_ack` and `graph_paths_outside_scan_set`, omits the token/cost
fields, and still records the sensitivity fields (3a/3b/3c ran
regardless). `egress_scan_basis` and `egress_scan_files` are written on
**every** run, `code-only` included.

## Calibration log line (`~/.claude/tools/graphify/calibration.jsonl`)
Appended after every **real** (full, or full+retry) extraction, one JSON
object per line, covering the whole build (7 + 7a combined):
```json
{"date":"<iso>","repo":"<basename>","graphify_version":"0.9.32","backend":"gemini",
 "model":"<id>","mode":"full","files":500,"code_files":164,"doc_files":336,
 "in_tokens":950000,"out_tokens":42000,"usd":0.60,
 "zero_node_files":0,"dropped_nodes":0}
```
A `code-only` inventory run never appends here — it spent nothing.

## CLAUDE.md region (`<!-- GRAPHIFY_MANAGED -->`, ADR-054 D10)

`mode: full` (or `full+retry`, same region — the mode string is
substituted verbatim from the receipt either way):
```markdown
<!-- GRAPHIFY_MANAGED -->
A graphify knowledge graph exists at `graphify-out/graph.json`
(built <extracted_at>T<time>Z @ <commit>, mode: <full|full+retry>, graphifyy 0.9.32).

Authority: `.claude/graphify/receipt.json` is the source of truth for this
graph. If its `graph_path` does not resolve, the graph is GRAPH-ABSENT
(ADR-054 D8) — ignore this section entirely and use Read/Grep.

For "where is X used", "what depends on Y", "what is this module for", and
cross-file orientation: run `graphify query` / `graphify explain` /
`graphify path` first. They are local lookups — zero LLM cost, no network.

Two rules:
- A query returning nothing is NOT evidence the thing does not exist
  (ADR-054 D8, GRAPH-INCOMPLETE). Confirm every negative with Grep/Read.
- If the graph is GRAPH-STALE, re-run `/graphify-extract --refresh`.
  Detecting staleness is free; the re-run itself is METERED and needs the
  same explicit approval as any other extraction.
<!-- /GRAPHIFY_MANAGED -->
```

`mode: code-only` — the same region, with this paragraph inserted
immediately after the first (built …) line, mandatory:
```markdown
This graph is **code-only**: built by AST extraction with zero LLM calls, it
contains **no docs, markdown, configs, or SQL prose at all**. It can answer
nothing about documentation, ADRs, or configuration, and a miss on any such
question means only that this graph never saw the file — it is not evidence
of anything. Build a full graph with `/graphify-extract` (METERED) if you
need those.
```

Every field in the region (`graph_path`, the ISO timestamp, the sha, and
the mode string) is substituted from the receipt's real values — no
placeholder (`<ISO>`, `<sha>`, `<full|code-only>`) may ever reach a
written file. The region replaces only the text between its own markers
and never touches anything else in `CLAUDE.md`. Re-running this skill
after new commits updates the sha and timestamp in place.

## Signals (ADR-054 D8) — consumed by any reader, not just this skill

| Signal | Meaning | Remedy |
|---|---|---|
| `GRAPH-ABSENT` | No receipt, or the receipt's `graph_path` does not resolve | Plain Read/Grep. Never reported as "nothing found." Free. |
| `GRAPH-STALE` | Graph built at commit X; the condition below evaluates true | Detecting is free (pure git). Fixing is `/graphify-extract --refresh` — **METERED**, requires the same explicit `proceed` as any other extraction. No agent, loop, or hook may invoke the remedy automatically. |
| `GRAPH-INCOMPLETE` | The build's own report shows dispatched files that produced zero nodes, and/or dropped/out-of-scope nodes | Treat the graph as a lossy index. Free. Optionally re-run — the vendor states a re-run retries omitted files — but that re-run is METERED under the same approval rule. |

**Consumer rule, mandatory:** a `graphify query` returning no results must
never be reported by any caller as "X does not exist." Any negative
conclusion drawn from the graph requires a Grep/Read confirmation against
the working tree, always.

**`GRAPH-STALE`, computed exactly:**
```
X   = receipt.commit
D   = set(receipt.dispatched_paths)
C   = changed set from `git diff --name-status -M X..HEAD`, where an R
      (rename) entry contributes BOTH its old and its new path
U0  = set(receipt.untracked_dispatched)
U1  = current untracked set from
      `git status --porcelain --untracked-files=all`, restricted to the
      roots graphify walked

GRAPH-STALE  ⇔  (HEAD != X  and  D ∩ C ≠ ∅)  or  U1 != U0
```
`-M` (rename detection) is mandatory: without it a rename appears as a
delete plus an add, and whether the pair intersects `D` depends on which
side happened to be dispatched — a coin flip. An untracked dispatched
file being **edited in place** is a named, accepted residual this check
cannot see (no anchor to detect it against without hashing every
dispatched file at check time) — it is documented here so it is not
assumed to be covered.
