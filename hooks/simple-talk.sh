#!/usr/bin/env bash
# UserPromptSubmit hook: simple-talk modifier (ADR-032).
#
# Reads session_prefs.simple_talk from the live session-state file and, when set
# to "plain" or "caveman", injects a per-turn directive shaping HOW plainly the
# assistant writes. This is the wording/jargon axis — orthogonal to
# communication_style (which sets length via brevity-drift budgets).
# "off" (default) = silent, zero behavior change.
#
# Every-turn (not SessionStart-once) on purpose: like brevity-drift.sh, the
# directive must stay fresh as context grows, or the model drifts back.
#
# Fail-safe: any problem -> exit 0 with no output. Never blocks or corrupts a turn.
# summary: Injects a per-turn directive shaping how plainly the assistant writes, per the simple_talk session preference.

set -uo pipefail

PREFS="$HOME/.claude/session-state/current-prefs.json"
[ -f "$PREFS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

MODE="$(jq -r '.simple_talk // "off"' "$PREFS" 2>/dev/null || echo off)"

case "$MODE" in
  plain)
    MSG="SIMPLE TALK: plain — top-priority reply rule. Every reply SHORT and PLAIN: answer first, no preamble, no recap of my message, no wrap-up summary, fewest lines that fully answer; everyday words, gloss any unavoidable jargon in <=4 words. If 'short' and 'complete' conflict, stay short and end with 'want more?'. Code, commit/PR text, and safety warnings stay full and correct."
    ;;
  caveman)
    MSG="SIMPLE TALK: caveman — top-priority reply rule, beats any verbosity/style/output-style setting. Every reply SHORT and PLAIN, caveman-style: answer first, fewest lines, no intro/recap/wrap-up; tiny everyday words, drop filler (the/a/is/that), fragments fine, short lists over prose; big/technical word -> small word or gloss in <=4 words. If 'short' fights 'complete', stay short, end with 'want more?'. Full and correct ONLY for code, commit/PR text, safety warnings, and multi-step safety-critical sequences."
    ;;
  *)
    exit 0
    ;;
esac

jq -cn --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}' 2>/dev/null || exit 0
