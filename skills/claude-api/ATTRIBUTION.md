# Vendored skill — provenance

`claude-api` is vendored from Anthropic's official skills repository.

- Upstream: https://github.com/anthropics/skills (path: `skills/claude-api`)
- Upstream commit: `b29e7cf65e5cb78a5ac33d582270551bc74a14eb`
- Author: Anthropic
- License: Apache-2.0 (see ./LICENSE.txt)

Vendored (not referenced as a plugin) so it ships through the stack's
copy-into-`~/.claude` install path and works in cloud sessions, which have no
plugin support. Re-sync manually from upstream when the skill updates.

Reference for the Claude API / Anthropic SDK — model ids, pricing, params,
streaming, tool use, MCP, agents, caching, token counting, and model
migration. Includes per-language reference files (`python/`, `typescript/`,
`java/`, `go/`, `ruby/`, `csharp/`, `php/`, `curl/`, `shared/`).
