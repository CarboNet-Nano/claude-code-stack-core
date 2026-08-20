# Vendored: @neondatabase/serverless

Vendored per ADR-060 §D: `tools/pm` cannot take an npm dependency
(ADR-058/059's no-npm-install-at-runtime constraint), so the driver source is
committed directly instead of referenced via `package.json`.

- package: `@neondatabase/serverless`
- version: `1.1.0`
- upstream: https://github.com/neondatabase/serverless
- tarball: https://registry.npmjs.org/@neondatabase/serverless/-/serverless-1.1.0.tgz
- sha256: cd940bd313d790f634fd44154e4a8cb8026c2bdf145539be2986cf3468d3562b
  (tarball SHA-256, from the npm registry — verifies the download, not the
  vendored file below)
- index.mjs sha256: 2913bd33766e5e9ca954c86d77c3664fc4169b2188cc8de558a07bb04ca0df27
  (vendored-file SHA-256, recomputed from the committed file — this is the
  checksum the lint and installer actually verify, since once vendored the
  driver ships as a bare file, not a tarball; see issue #152)
- npm registry shasum (sha1, cross-checked against the tarball above):
  35046d1125932153dd306bd3d7c269306914e005
- license: MIT (see `LICENSE`, copied verbatim from the package)
- fetched: 2026-08-08

## What's vendored

`index.mjs` is the package's published ESM build, copied verbatim
(byte-for-byte from the tarball's `package/index.mjs`) — not re-extracted or
hand-edited. It is a single self-contained esbuild bundle with **zero
external `import`/`require`/`node:` references** (verified by grep across the
whole file before vendoring), so it has no runtime dependencies of its own —
consistent with ADR-060 §D's "Node ≥22 global `fetch` stays the only runtime
requirement."

The bundle includes both the HTTP-mode path (`neon(...)`, used by this
project) and a WebSocket-based `Pool`/`Client` path (not used). Per ADR-060
§D, this project calls **HTTP mode only** — the seam files
(`tools/pm/src/{directory,provision,db}.mjs`) never import or construct
`Pool`/`Client`. The unused WebSocket code is inert: it is never imported,
opens no socket, and is not "an npm dependency" in the ADR-058/059 sense
(nothing depends on `ws` being installed, because that path is never
reached). Because the whole file is verifiably import-free, vendoring it
whole (rather than attempting a manual dead-code prune of a minified
esbuild bundle, which would be unverifiable against upstream) is the safer
choice: this file can always be diffed byte-for-byte against a freshly
downloaded tarball to confirm nothing was altered.

## Re-vendoring a newer version

1. Fetch the new tarball from the npm registry.
2. Confirm its SHA-1 matches the registry's published `dist.shasum` for that
   version (`npm view @neondatabase/serverless@<version> dist` or the
   registry JSON API).
3. Compute and record the tarball's SHA-256 here.
4. Replace `index.mjs` with `package/index.mjs` from the new tarball,
   verbatim.
5. Recompute `index.mjs`'s own SHA-256 (`shasum -a 256 index.mjs`) and update
   the `index.mjs sha256:` line above to match — this is the value
   `tools/pm/test/neon-literal.test.mjs` and `scripts/lib/tier-installer.sh`
   actually verify against the committed file, so a stale value here fails
   the lint and blocks install, not silently passes.
6. Update `LICENSE` if it changed.
7. Update the `version`/`sha256`/`index.mjs sha256`/`fetched` fields above.
