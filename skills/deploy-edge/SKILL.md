---
name: deploy-edge
description: Deploy a Supabase edge function with all guardrails. Wraps the deploy script with branch check, cost-log integration, pre-deploy ops check, deploy execution, and post-deploy smoke test. Use instead of running `node scripts/deploy-edge.mjs` directly. Required by approval gate `pre-deploy` in financial-code mode.
---

# /deploy-edge

Deploy with guardrails. Replaces raw `node scripts/deploy-edge.mjs` invocation.

## Steps

### 1. Pre-flight checks (ops)
- Verify on the correct branch (not main unless explicitly allowed in stack-config.json).
- Verify uncommitted changes are intentional or stashed.
- Verify edge function source compiles (`tsc --noEmit`).
- Verify required secrets are present in Supabase for the function.

If any fail: stop and report.

### 2. User confirmation
Print:
```
About to deploy: <function-name>
From branch: <branch>
To project: <supabase-project-ref>
Last commit: <sha> — <subject>
Proceed? [y/N]
```

WAIT.

### 3. Execute deploy
- `node scripts/deploy-edge.mjs <function-name>`
- Capture output.

### 4. Post-deploy verification (ops)
- Hit the deployed function with a known-good request.
- Compare response to expected (read from a smoke-test fixture).
- Check recent logs for errors (last 60 seconds).

### 5. Cost-log
- Write a row to cost_log: kind=deploy, function=<name>, branch=<branch>, sha=<sha>, status=<success|failed>.

### 6. Report
```
Deploy: <function-name>
Status: <SUCCESS | FAILED with details>
Branch: <branch>
SHA: <sha>
Smoke test: <PASS | FAIL>
Logs (last 60s): <count> errors
```

### 7. If deploy failed
- Don't rollback automatically — flag to user with the recovery options.
- Common recovery: `node scripts/deploy-edge.mjs <function-name>` from main / previous commit.
