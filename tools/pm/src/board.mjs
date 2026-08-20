const PM_LABEL = "pm";
const VALID_SOURCES = new Set(["review", "audit", "handoff", "human"]);
const TRACK_PATTERN = /^[a-z0-9-]+$/;

export async function listPmIssues(execFile, repos) {
  const results = [];

  for (const repo of repos) {
    try {
      const result = await execFile("gh", [
        "issue",
        "list",
        "--repo",
        repo,
        "--label",
        PM_LABEL,
        "--state",
        "open",
        "--json",
        "number,title,labels"
      ]);
      results.push({ repo, ok: true, result });
    } catch (err) {
      // One repo's gh failure must not zero out the whole portfolio's count —
      // isolate per-repo and let the caller decide how to surface it.
      results.push({ repo, ok: false, error: err.message });
    }
  }

  return results;
}

export async function fileIssue(execFile, scope, repo, { title, body, track, source }) {
  if (!scope.includes(repo)) {
    throw new Error("repo out of portfolio scope");
  }

  if (!VALID_SOURCES.has(source)) {
    throw new Error(`source must be one of: ${Array.from(VALID_SOURCES).join(", ")}`);
  }

  if (!TRACK_PATTERN.test(track)) {
    throw new Error("track must match /^[a-z0-9-]+$/");
  }

  const args = [
    "issue",
    "create",
    "--repo",
    repo,
    "--title",
    title,
    "--body",
    body,
    "--label",
    PM_LABEL,
    "--label",
    `track:${track}`,
    "--label",
    `source:${source}`
  ];

  const result = await execFile("gh", args);
  return result;
}

export async function closeIssue(execFile, scope, repo, number, comment) {
  if (!scope.includes(repo)) {
    throw new Error("repo out of portfolio scope");
  }

  if (!comment || comment.trim() === "") {
    throw new Error("closing comment required");
  }

  // Comment first
  await execFile("gh", [
    "issue",
    "comment",
    String(number),
    "--repo",
    repo,
    "--body",
    comment
  ]);

  // Then close
  await execFile("gh", [
    "issue",
    "close",
    String(number),
    "--repo",
    repo
  ]);
}
