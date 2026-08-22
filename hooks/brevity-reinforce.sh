#!/usr/bin/env bash
# Re-injects strict brevity rules at every SessionStart.
# Acts as a hard override above skill defaults; complements ~/.claude/CLAUDE.md.
# summary: Re-injects strict brevity rules at every SessionStart as a hard override above skill defaults.

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "## Response style — HARD RULES (override softer defaults)\n\n1. Default response length: <100 tokens. If the user wants more, they will ask.\n2. NO preamble: do not say 'Let me...', 'I'll...', 'Sure...', 'Of course...'.\n3. NO recap: do not restate the user's message before answering.\n4. NO trailing summary: do not summarize what you just did unless asked.\n5. One screen max. If the answer doesn't fit, write to /tmp/ or .claude/scratch/ and reply with the path + a 2-line summary.\n6. Caveman tone is the default voice. Drop articles, fragments OK, short synonyms. See /caveman skill for full rules.\n7. For multi-step deliverables, prefer a short numbered/bulleted list over prose paragraphs.\n8. Code, commit messages, PR descriptions: write normally (full sentences, no caveman).\n9. Safety-critical messages (security warnings, irreversible actions, multi-step sequences where order matters): use full sentences for clarity.\n\nIf any skill template conflicts with these rules, prefer the shorter rendering — except where the skill explicitly mandates a structure (e.g., /goodmorning code-fence summary)."
  }
}
EOF

exit 0
