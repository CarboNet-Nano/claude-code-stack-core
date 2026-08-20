#!/usr/bin/env bash
# Shared helpers for the usage-check gate (scripts/usage-check.sh,
# hooks/usage-check-token.sh, hooks/usage-check-gate.sh). Sourceable only —
# has no side effects when sourced, matching the override-log.sh convention
# (BASH_SOURCE guard would only matter if this file also had direct-exec
# behavior; it does not, so none is needed).
#
# One normalization rule, one hash rule, one timestamp rule, used identically
# by every consumer — derivation drift between the minting hook and the gate
# would itself be a correctness bug (ADR-057).

# uc_normalize_target <file|symbol> <raw> -> echoes normalized target string.
uc_normalize_target() {
  local kind="$1" raw="$2"
  if [[ "$kind" == "symbol" ]]; then
    if [[ "$raw" == symbol:* ]]; then
      echo "$raw"
    else
      echo "symbol:$raw"
    fi
    return 0
  fi
  # file: strip leading "./", strip trailing "/"
  raw="${raw#./}"
  raw="${raw%/}"
  echo "$raw"
}

# uc_repo_hash <repo_root_abs_path> -> echoes 12-hex-char sha256 prefix.
uc_repo_hash() {
  shasum -a 256 <<<"$1" | cut -c1-12
}

# uc_target_hash <file|symbol> <normalized_target> -> echoes 12-hex-char sha256 prefix.
uc_target_hash() {
  local kind="$1" normalized="$2"
  shasum -a 256 <<<"${kind}:${normalized}" | cut -c1-12
}

# uc_sanitize_sid <raw_sid> -> echoes filename-safe sid ("nosession" if empty).
uc_sanitize_sid() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo "nosession"
    return 0
  fi
  echo "${raw//[^A-Za-z0-9._-]/_}"
}

# uc_now_iso -> echoes current UTC timestamp, ISO-8601 seconds, Z suffix.
uc_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# uc_iso_to_epoch <iso8601-Z-string> -> echoes epoch seconds, or empty on
# unparseable input. Portable across macOS (BSD date) and Linux (GNU date).
uc_iso_to_epoch() {
  local iso="${1:-}"
  local epoch
  epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)"
  if [[ -z "$epoch" ]]; then
    epoch="$(date -u -d "$iso" +%s 2>/dev/null)"
  fi
  echo "$epoch"
}

# uc_token_path <repo_hash> <target_hash> <sanitized_sid> -> echoes full path.
uc_token_path() {
  local repo_hash="$1" target_hash="$2" sid="$3"
  echo "$HOME/.claude/usage-check/tokens/usage-check.${repo_hash}.${target_hash}.${sid}.json"
}
