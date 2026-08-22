#!/usr/bin/env bash
# lib/plain-text-guard.sh — the plain-English vocabulary gate (ADR-072 D10).
#
# Extracted verbatim from scripts/org-check.sh (a pure move: same names, same
# bodies, same allowlist-by-outcome design — the design's explicit
# instruction). These five functions were hardened over four review rounds
# with live-reproduced bypasses recorded in the comments below; the comment
# blocks move with the code because they are why the functions look the way
# they do. Both scripts/org-check.sh and scripts/session-brief.sh source this.
#
# tests/test-carbonet-check.sh must pass unchanged after org-check.sh was
# switched to source this file instead of defining these functions inline —
# that suite is the acceptance gate for the extraction.
#
# Sourcing contract: org-check.sh and session-brief.sh both go through
# `_scv_safe_source <this-file> _scv_has_non_ascii _scv_contains_banned_words
# _scv_contains_banned_vocab sanitize_field sanitize_path` (that helper is
# NOT duplicated here — it is generic and each caller already has its own
# copy for sourcing OTHER libs too). If sourcing this file fails or is
# incomplete, callers degrade to "untrusted-everything mode" themselves
# (ADR-072 D10, rev 2's fail-SAFE fix for finding 8): they redefine
# sanitize_field/sanitize_path locally as unconditional placeholder returns,
# so every config-derived value prints as a placeholder rather than the
# script bricking with exit 2. There is no detection in that mode — which is
# exactly why it's safe.

# --------------------------------------------------------------- sanitizer
# `org.json` is installed org-wide (not always authored by the person running
# `/carbonet`) and `.claude/stack-config.json`'s free-text fields flow into
# `scv_validate`'s error text unfiltered too — either can carry a crafted
# value (display_name, support_contact, an unknown provider name, access_url,
# the config path itself, a version string, a schema-check "found: ..."
# value) that would otherwise defeat the vocabulary gate this whole script is
# built around.
#
# ALLOWLIST-BY-OUTCOME, NOT BLACKLIST-BY-TRANSFORMATION (reviewer finding,
# 2026-08-11 re-verification pass). A prior version tried to REPAIR a bad
# value in place (`${s//TOKEN/VALUE}` etc.) — live-reproduced bypasses:
# mixed case ("TokEn", "CrEdEnTiAl") never matched the three fixed casings
# tried; separator-obfuscated text ("A-P-I", "A P I", "cre-dential",
# "4-0-1") never matched the literal substrings at all; and bare `env` (named
# in this script's own vocabulary-gate comment) was never checked. Every one
# of those was a direct consequence of trying to EDIT the string instead of
# deciding whether to trust it. This version instead only ever makes a binary
# choice — print the value UNCHANGED, or print a fixed, content-free
# placeholder — so there is no partial transformation left to route around.
#
# Detection normalizes away exactly what defeated the old approach: lowercase
# + strip everything that isn't a-z0-9, so case and separator choice can't
# matter. Known, disclosed cost of that same normalization: it also flags
# words that merely CONTAIN a banned substring (e.g. "environment" contains
# "env", "Sinapis" contains "api") — accepted, because the failure mode is
# "an unusual but honest value gets replaced by a generic placeholder," never
# "a crafted value leaks."
# True if $1 contains any byte outside the 7-bit ASCII range. Reject-not-
# interpret (reviewer finding, round 3): the ASCII-only lowercase/strip
# normalizer in _scv_contains_banned_words is blind to Unicode homoglyphs
# (e.g. Cyrillic а/е/о or fullwidth letters that LOOK like "token"/"api" but
# never match the a-z0-9 comparison) — trying to transliterate every
# homoglyph is an unbounded problem; refusing any non-ASCII content outright
# is not. Every field this gates through is meant to be short plain-English
# text (an org display name, a support contact) — legitimate non-ASCII use
# is rare enough that the placeholder is an acceptable, safe default.
_scv_has_non_ascii() {
  local rest
  rest="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177')"
  [[ -n "$rest" ]]
}

# _scv_contains_banned_words: non-ASCII rejection, then the case/separator-
# insensitive word check (api/credential/keychain/token/export/env/exitcode)
# — safe to run on a filesystem path.
_scv_contains_banned_words() {
  _scv_has_non_ascii "$1" && return 0
  local norm
  norm="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9')"
  case "$norm" in
    *api*|*credential*|*keychain*|*token*|*export*|*env*|*exitcode*) return 0 ;;
    *) return 1 ;;
  esac
}

# Adds the 4xx/5xx-shaped-number check on top — NOT safe for filesystem
# paths: a stock macOS $TMPDIR (e.g. ".../T/tmp.40000gq/...") routinely
# contains an incidental 3-digit run, which isn't gated vocabulary and
# shouldn't hide the path.
_scv_contains_banned_vocab() {
  _scv_contains_banned_words "$1" && return 0
  local norm
  norm="$(printf '%s' "$1" | LC_ALL=C tr -cd '0-9')"
  [[ "$norm" =~ [45][0-9][0-9] ]] && return 0
  return 1
}

# sanitize_field <value> [<max-len>] [<placeholder>]
# For free-text config VALUES (display_name, support_contact, access_url,
# scv_validate error text, version strings) — words + status-shaped numbers.
sanitize_field() {
  local s="${1:-}" max="${2:-160}" placeholder="${3:-(from your settings)}"
  s="$(printf '%.*s' "$max" "$s" | tr -d '\000-\037\177')"
  if _scv_contains_banned_vocab "$s"; then
    printf '%s' "$placeholder"
  else
    printf '%s' "$s"
  fi
}

# sanitize_path <value> [<max-len>] [<placeholder>]
# For filesystem paths — words only (see _scv_contains_banned_vocab's note
# above on why the number check would false-positive on an ordinary tmpdir).
sanitize_path() {
  local s="${1:-}" max="${2:-200}" placeholder="${3:-(path hidden)}"
  s="$(printf '%.*s' "$max" "$s" | tr -d '\000-\037\177')"
  if _scv_contains_banned_words "$s"; then
    printf '%s' "$placeholder"
  else
    printf '%s' "$s"
  fi
}
