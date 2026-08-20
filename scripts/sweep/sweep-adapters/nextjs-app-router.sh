#!/usr/bin/env bash
# scripts/sweep/sweep-adapters/nextjs-app-router.sh — the default route-
# manifest adapter for E1 (stack ADR-078, spec S4.6 [RT-9], task 7 of the
# Sweep serial spine). E1's universe comes from a config-declared command
# that prints one route per line, never from a hardcoded framework
# assumption — this is the stack's one shipped adapter for that seam, for
# repos on Next.js App Router.
#
# Mapping (verified against tests/fixtures/sweep-e1-adapter):
#   src/app/page.tsx           -> /
#   src/app/foo/page.tsx       -> /foo
#   src/app/foo/bar/page.tsx   -> /foo/bar
#   src/app/(marketing)/about/page.tsx -> /about   (route-group segments,
#     any path segment wrapped in parens, are stripped — Next.js convention,
#     a route group changes nothing about the URL)
#   src/app/users/[id]/page.tsx -> /users/[id]     (dynamic segments are
#     printed as-is; E1 decides what to do with them — usually excluding
#     them by default with reason "dynamic segment needs a sample id" —
#     that decision lives in the check, not this adapter [RT-9])
#
# usage: nextjs-app-router.sh <route_root>
# <route_root> is the directory containing page.tsx files (e.g. "src/app"),
# resolved relative to the caller's cwd — the runner/check decides cwd,
# this adapter has no opinion on it.

set -uo pipefail

ROOT="${1:?usage: nextjs-app-router.sh <route_root>}"
ROOT="${ROOT%/}"

if [[ ! -d "$ROOT" ]]; then
  echo "nextjs-app-router: route root '$ROOT' does not exist" >&2
  exit 1
fi

find "$ROOT" -type f -name 'page.tsx' | while IFS= read -r page; do
  rel="${page#"$ROOT"/}"
  rel="${rel%page.tsx}"
  rel="${rel%/}"

  route=""
  segments=()
  IFS='/' read -ra segments <<< "$rel"
  for seg in "${segments[@]+"${segments[@]}"}"; do
    [[ -z "$seg" ]] && continue
    [[ "$seg" =~ ^\(.*\)$ ]] && continue   # route group — stripped from the URL
    route="$route/$seg"
  done
  [[ -z "$route" ]] && route="/"
  echo "$route"
done | sort   # sort the resulting ROUTE strings, not the source file paths —
              # a file-path sort orders /foo/bar/page.tsx before /foo/page.tsx
