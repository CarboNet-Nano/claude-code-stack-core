---
name: env-doctor
description: Diagnose a broken or unfamiliar dev environment before you start work. Checks toolchain versions, required env vars, auth/credential presence, network/proxy reachability, and project setup (deps installed, services running). Use at session start in an unfamiliar repo, when a command fails with a setup-shaped error (command not found, missing key, connection refused), or when onboarding to a cloud/fresh-clone environment.
---

# /env-doctor

Run a fast, read-only health check of the current environment and report what's
ready vs. what's missing — before a setup problem wastes a debugging cycle.

This skill DIAGNOSES; it does not mutate. It never installs, exports, or writes
credentials. It reports findings and suggests the fix command for the human to run.

## When to use

- Session start in an unfamiliar or freshly-cloned repo.
- A command just failed with a setup-shaped error: `command not found`,
  `connection refused`, `401/403`, `ENOENT`, `missing key`, TLS/proxy errors.
- Onboarding a cloud/remote environment where you can't assume local setup.

## Steps

### 1. Detect the project type
Look for `package.json`, `pyproject.toml`/`requirements.txt`, `go.mod`,
`Cargo.toml`, `Gemfile`, `*.csproj`. Record which ecosystems are in play —
the rest of the checks key off this.

### 2. Toolchain presence + version
For each detected ecosystem, check the runtime is on PATH and meets any pinned
version (`.nvmrc`, `engines`, `python_requires`, `go` directive). Report
`missing` / `wrong-version` / `ok` per tool. Do not install anything.

### 3. Dependencies installed
- Node: `node_modules` present and not stale vs. lockfile.
- Python: a virtualenv active or deps importable.
- Others: the ecosystem's equivalent (`vendor/`, `target/`, etc.).
Report whether an install step is needed — name the command, don't run it.

### 4. Required env vars + auth
Read `.env.example` / README / config templates for the var names the project
expects. Check which are SET (presence only — never print values). Flag missing
ones. For services with obvious auth (cloud CLIs, registries), note whether a
credential/login appears present. Never echo secret contents.

### 5. Network / proxy reachability
If the project talks to known hosts (registry, API base URL, DB), check basic
reachability. In proxied environments, surface proxy/TLS misconfig explicitly
(per the env's proxy README) rather than reporting a generic failure.

### 6. Services running
If the project expects a local service (dev server, DB, container), check whether
it's up. Report `up` / `down` / `unknown` — don't start anything.

### 7. Report
Print a compact table: `check | status | fix`. Order by severity
(blockers first). End with the single highest-priority next action. If everything
passes, say so in one line.

## Output contract

- Read-only: zero mutations, zero installs, zero credential writes.
- Secrets: presence only, never values.
- Every `missing`/`broken` row carries the exact command the human should run.
