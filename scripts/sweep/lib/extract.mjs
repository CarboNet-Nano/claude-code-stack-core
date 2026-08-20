// scripts/sweep/lib/extract.mjs — shared lexical (regex-based) extraction
// primitives for the Sweep A family's node-side checks (stack ADR-078,
// spec S4.6). Factored out of a2-producer-consumer.sh's originally
// self-contained node script (docs/superpowers/specs/2026-08-16-testing-
// doctrine-redesign.md P1a) so a2-producer-consumer.sh and
// a5-command-callers.sh import ONE implementation of balanced-brace
// object-literal extraction rather than each embedding its own copy.
//
// This file is imported (never executed directly) via dynamic import from
// each check's own throwaway temp node script, using
// `await import(pathToFileURL(process.env.EXTRACT_LIB_PATH).href)` — the
// checks stay self-contained-at-runtime (no new dependency, spec's own
// sanctioned degrade from the TypeScript compiler API), but no longer
// duplicate the extraction logic itself.
//
// Three exports, all pure functions over a source-text string:
//   extractBalanced(text, openIndex) -> the substring strictly between the
//     '{' at openIndex and its matching '}', skipping brace characters
//     inside a quoted string or template literal.
//   parseObjectKeys(objText) -> the Set of static string keys declared at
//     the top level of an object-literal body. A computed key
//     (`[expr]: ...`) or a spread (`...rest`) cannot be resolved
//     statically and is skipped, not guessed.
//   findFunctionBody(source, funcName) -> the balanced body text of a
//     `function funcName(...)`, `const funcName = (...) => {...}`, or
//     `const funcName = function(...) {...}` declaration, or null.

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function extractBalanced(text, openIndex) {
  let depth = 0;
  let inString = null;
  for (let i = openIndex; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") { i++; continue; }
      if (c === inString) inString = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inString = c; continue; }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  return null;
}

// splitTopLevel <text> <sep> -> text split on <sep>, only at bracket depth
// 0 and outside of a quoted string — a nested `{a: {b: 1}}, c` splits into
// two segments, not three.
function splitTopLevel(text, sep) {
  const parts = [];
  let depth = 0, start = 0, inString = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === "\\") { i++; continue; }
      if (c === inString) inString = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inString = c; continue; }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === sep && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
  }
  parts.push(text.slice(start));
  return parts;
}

function topLevelColonIndex(s) {
  let depth = 0, inString = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inString) {
      if (c === "\\") { i++; continue; }
      if (c === inString) inString = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inString = c; continue; }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === ":" && depth === 0) return i;
  }
  return -1;
}

export function parseObjectKeys(objText) {
  const keys = new Set();
  for (const raw of splitTopLevel(objText, ",")) {
    const s = raw.trim();
    if (!s || s.startsWith("...") || s.startsWith("[")) continue;
    const ci = topLevelColonIndex(s);
    let keyPart = (ci >= 0 ? s.slice(0, ci) : s).trim();
    const qm = keyPart.match(/^(['"`])([\s\S]*)\1$/);
    if (qm) {
      // A quoted key literal is valid JS for ANY string content (unlike a
      // bare identifier key) — e.g. command ids are commonly kebab-case
      // ("run-report"), which cannot be written as a bare key at all.
      const literal = qm[2];
      if (literal.length > 0) keys.add(literal);
    } else if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(keyPart)) {
      keys.add(keyPart);
    }
  }
  return keys;
}

export function findFunctionBody(source, funcName) {
  const name = escapeRe(funcName);
  const patterns = [
    new RegExp(`(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\s+${name}\\s*\\([^)]*\\)\\s*(?::[^{]+)?\\{`),
    new RegExp(`(?:export\\s+)?(?:const|let|var)\\s+${name}\\s*(?::[^=]+)?=\\s*(?:async\\s*)?\\([^)]*\\)\\s*(?::[^=>{]+)?=>\\s*\\{`),
    new RegExp(`(?:export\\s+)?(?:const|let|var)\\s+${name}\\s*=\\s*(?:async\\s+)?function\\s*\\([^)]*\\)\\s*\\{`),
  ];
  for (const re of patterns) {
    const m = re.exec(source);
    if (m) {
      const braceIdx = m.index + m[0].length - 1;
      return extractBalanced(source, braceIdx);
    }
  }
  return null;
}
