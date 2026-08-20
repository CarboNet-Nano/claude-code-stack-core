#!/usr/bin/env bash
# rtk (token-reduction proxy) installer — ADR-063 D6.2.
# Pinned commit + sha256 compute-and-compare; never a mutable-ref curl|sh.
# To bump: set RTK_INSTALL_COMMIT to the new commit, recompute the hash
# (curl the pinned URL | shasum -a 256), update RTK_INSTALL_SHA256.
# Sourced by cloud-bootstrap.sh; standalone-testable (tests/test-cloud-bootstrap.sh).

RTK_INSTALL_COMMIT="${RTK_INSTALL_COMMIT:-b34be37caf3796b69a50952a28e60e32b5daad43}"
RTK_INSTALL_SHA256="${RTK_INSTALL_SHA256:-d6eb73a772903e13ff34ee1be8a8b24e896ba9a978f20d2279a08b4083ea6f77}"

# Installs rtk if absent. Prints progress via `log` if defined, else echo.
# Returns 0 on installed-or-already-present, 1 on any refusal/failure.
rtk_install_pinned() {
  local _log="echo"
  declare -F log >/dev/null && _log="log"

  if command -v rtk >/dev/null 2>&1; then
    "$_log" "rtk already on PATH; skipping install."
    return 0
  fi

  "$_log" "Installing rtk (token-reduction proxy)..."
  local installer actual
  installer="$(mktemp)"
  if ! curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/${RTK_INSTALL_COMMIT}/install.sh" \
       -o "$installer" 2>/dev/null; then
    rm -f "$installer"
    "$_log" "WARNING: rtk installer download failed."
    return 1
  fi
  actual="$(shasum -a 256 "$installer" | cut -d' ' -f1)"
  if [ "$actual" != "$RTK_INSTALL_SHA256" ]; then
    rm -f "$installer"
    "$_log" "WARNING: rtk installer hash mismatch (got $actual) — refusing to run it."
    return 1
  fi
  if sh "$installer" >/dev/null 2>&1; then
    rm -f "$installer"
    export PATH="$HOME/.local/bin:$PATH"
    "$_log" "rtk installed ($(rtk --version 2>/dev/null || echo 'version unknown'))."
    return 0
  fi
  rm -f "$installer"
  "$_log" "WARNING: rtk install failed. Sessions will run without token compression."
  return 1
}
