# Vendored skill — provenance

`claude-automation-recommender` is vendored from Anthropic's official
`claude-code-setup` plugin (claude-plugins-official marketplace), v1.0.0.

- Upstream: https://github.com/anthropics/claude-code (plugins/claude-code-setup)
- Author: Isabella He (isabella@anthropic.com), Anthropic
- License: Apache-2.0 (see ./LICENSE)

Vendored (not referenced as a plugin) so it ships through the stack's
copy-into-`~/.claude` install path and works in cloud sessions, which have no
plugin support. Re-sync manually from upstream when the plugin updates.
