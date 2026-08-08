---
name: pr-comments
description: Posts reviewer/security-auditor findings (reviewer-report.md / security-report.md, or /code-review output) as inline GitHub PR review comments via `gh api`, so findings that currently only surface in conversation also land on the PR diff itself. Use after a review/audit pass, once a PR exists for the branch, to make findings visible to a small team collaborating on GitHub. Idempotent — safe to re-run after a new commit; already-posted findings are skipped.
---

# /pr-comments

Take structured findings (severity + `file:line` + description) and post them as **inline** comments on the GitHub PR's diff, in one batched review call. Never as a general conversation-only summary — the whole point is that findings land where the team already looks: the PR.

## Usage

```
/pr-comments                          # auto-discover PR (current branch) + newest reviewer-report.md/security-report.md
/pr-comments <pr-number>              # override PR number, still auto-discover reports
/pr-comments <path/to/report.md>      # explicit report file, PR = current branch's PR
/pr-comments <pr-number> <path>       # both explicit
```

## Hard rules

- **`event: "COMMENT"` only.** Never submit a review with `APPROVE` or `REQUEST_CHANGES` — this skill posts findings, it does not gate merge. That decision belongs to a human or to foreman composing reviewer + validator output, matching the "reviewer does not approve/merge" rule in `agents/reviewer.md`.
- **Post the findings verbatim.** Don't summarize, soften, or reword a finding's substance when moving it from the report to the PR comment — only reformat (add severity prefix, marker comment).
- **Idempotent.** Before posting, check for comments already carrying this skill's marker and skip duplicates, so re-running after a new commit doesn't spam the PR.

## Step 1 — resolve the PR

- If the first arg is numeric, that's `<pr-number>`. Otherwise resolve from the current branch: `gh pr view --json number,headRefOid,headRepositoryOwner,headRepository`.
- Resolve `OWNER/REPO` via `gh repo view --json owner,name --jq '.owner.login + "/" + .name'` (or from the PR view above).
- Get the head commit: `gh pr view <n> --json headRefOid --jq '.headRefOid'`. This is the `commit_id` the review attaches to.
- No open PR for the branch and no numeric arg given → stop and tell the user to open one first (or pass a PR number explicitly).

## Step 2 — resolve the report(s)

- If an arg is a path to an existing file, use it directly.
- Otherwise auto-discover: find the most recently modified `reviewer-report.md` and the most recently modified `security-report.md` under `.claude/sessions/*/` (`find .claude/sessions -name 'reviewer-report.md' -newermt ... ` or sort by mtime). Use whichever of the two exist; it's fine to have only one.
- Print which file(s) were picked before posting anything — this is the one part of the flow a human should sanity-check.
- Neither file found and no explicit path given → stop and tell the user to run `reviewer`/`security-auditor` first, or point `/pr-comments` at a report path directly.

## Step 3 — parse findings (bucket-scoped, not whole-file)

Only parse bullet lines under these headings — free prose elsewhere (e.g. the DeepSeek third-voice section, compliance notes, recommendation) is not a finding and must not become a PR comment:

- `reviewer-report.md`: `### BLOCKING`, `### NON-BLOCKING`, `### NIT`
- `security-report.md`: `### CRITICAL`, `### HIGH`, `### MEDIUM`, `### LOW / INFORMATIONAL`

Bullet shape: `` - `<file>:<line>` — <rest of the line> `` (accept `—`, `–`, or ` - ` as the separator between the `file:line` token and the description). Severity = the nearest preceding `###` heading. Skip any bullet that doesn't parse to a `file:line` token — don't guess a location for it; it becomes part of the review summary body instead (see Step 5).

## Step 4 — filter to lines actually in the diff

GitHub's review-comments API rejects the **entire batch** if even one comment targets a line outside a diff hunk. Pre-filter, don't post-and-retry:

1. `gh pr diff <n>` and parse it per file: track `+++ b/<file>` to know which file you're in, then walk each hunk (`@@ -a,b +c,d @@`) incrementing a right-side line counter for every context (` `) or added (`+`) line, skipping removed (`-`) lines. This gives the exact set of valid right-side line numbers per file — a file merely appearing in the diff does not mean every line in it is commentable.
2. A finding whose `file:line` is in that set → inline comment (Step 5).
3. A finding whose `file:line` is NOT in that set (renamed/moved file, stale line from a since-amended diff, etc.) → do not drop it; fold it into the review body as plain text so it isn't silently lost, and note it wasn't attachable inline.

## Step 5 — dedupe against already-posted comments

- Fetch existing inline comments: `gh api repos/<owner>/<repo>/pulls/<n>/comments --paginate --jq '.[].body'`.
- Each comment this skill posts is prefixed with a hidden marker: `<!-- stack-pr-comments:<file>:<line> -->`. Before building the batch, skip any finding whose marker already appears in the existing comments — this makes re-running after a new commit additive, not duplicative.

## Step 6 — post the batch

Build one JSON payload and send it via stdin (never `-f`/`-F` for the nested `comments[]` array):

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<n>/reviews --input - <<'JSON'
{
  "commit_id": "<headRefOid>",
  "event": "COMMENT",
  "body": "<summary: counts by severity, plus any findings from Step 4.3 that couldn't attach inline, each as `file:line` — description>",
  "comments": [
    { "path": "<file>", "line": <line>, "side": "RIGHT", "body": "<!-- stack-pr-comments:<file>:<line> -->\n**<SEVERITY>** <description>" }
  ]
}
JSON
```

- If `comments` is empty (nothing new, or nothing was in-diff), skip the reviews endpoint and post a plain PR comment instead: `gh api repos/<owner>/<repo>/issues/<n>/comments -f body="<summary>"` (a review with zero comments and only a body reads oddly in the GitHub UI; an issue comment doesn't).
- If the API call fails (no push/write perms, network blocked, sandbox restriction) — do not fail silently. Print the exact `gh api` command (and the JSON payload, written to a temp file) so the user can run it manually, matching the fallback pattern used in `/auto-merge`.

## Step 7 — report

Print a short summary: PR number, report file(s) used, counts (`N posted inline`, `M skipped as already-posted`, `K folded into the summary body because not in-diff`).

## Integration contract (reviewer/security-auditor)

`agents/reviewer.md` and `agents/security-auditor.md` each call this skill after writing their report: once the report is on disk, they check for an open PR on the current branch (`gh pr view --json number`) and, if one exists, call `/pr-comments <pr-number> <path-to-report>` so the findings land inline instead of staying conversation-only. If no PR exists yet (pre-PR review, or `gh` unavailable), they skip this step silently — the report file remains the source of truth either way.

## What this skill does NOT do

- Approve, request changes, or otherwise gate merge (see Hard rules).
- Invent a `file:line` for a finding that doesn't have one — those stay in the summary body, not as fabricated inline comments.
- Run `/code-review`, `reviewer`, or `security-auditor` itself — it only posts output that already exists on disk.
