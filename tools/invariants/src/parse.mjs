// Parse contract for docs/invariants/*.sql (ADR-082 P1f):
//
// The file MUST begin with a contiguous block of `-- key: value` lines (any
// order, no repeats; parsing stops at the first line that does not start
// with `--`). Required keys: id (must equal the filename basename sans
// .sql; [a-z0-9-]+), statement (one line, free text -- no continuation;
// naturally guaranteed by the line-based header format), severity
// (critical|warn), expect (zero-rows | scalar-equals:<v>).
//
// After the header, the remaining text is executed as ONE statement: a
// semicolon followed by any non-whitespace is a parse error (multi-
// statement files are banned so the read-only + timeout guarantees stay
// per-query). Checking only the FIRST semicolon is sufficient -- if a
// second statement follows, the text after the first semicolon is
// necessarily non-whitespace (it contains that second semicolon, at least).

const HEADER_LINE_RE = /^-- ([a-z][a-z0-9_]*): (.*)$/;
const ID_RE = /^[a-z0-9-]+$/;
const REQUIRED_KEYS = ['id', 'statement', 'severity', 'expect'];

function basenameSansSql(absPath) {
  const parts = absPath.split('/');
  const filename = parts[parts.length - 1];
  return filename.endsWith('.sql') ? filename.slice(0, -4) : filename;
}

// Returns { ok:true, invariant:{id,statement,severity,expect,query,file} }
// or { ok:false, error:<string> }. Never throws on malformed input --
// callers (bin.mjs's `run`) turn a parse error into exit 3.
export function parseInvariantText(absPath, text) {
  const lines = text.split('\n');
  const header = {};
  let i = 0;
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (!line.startsWith('--')) break;
    const m = line.match(HEADER_LINE_RE);
    if (!m) return { ok: false, error: `malformed header line ${i + 1}: ${JSON.stringify(line)}` };
    const [, key, value] = m;
    if (key in header) return { ok: false, error: `duplicate header key '${key}' at line ${i + 1}` };
    header[key] = value;
  }

  for (const key of REQUIRED_KEYS) {
    if (!(key in header)) return { ok: false, error: `missing required key '${key}'` };
  }

  if (!ID_RE.test(header.id)) {
    return { ok: false, error: `id '${header.id}' does not match ${ID_RE}` };
  }
  const expectedId = basenameSansSql(absPath);
  if (header.id !== expectedId) {
    return { ok: false, error: `id '${header.id}' does not match filename basename '${expectedId}'` };
  }
  if (header.severity !== 'critical' && header.severity !== 'warn') {
    return { ok: false, error: `severity must be 'critical' or 'warn', got '${header.severity}'` };
  }

  let expect;
  if (header.expect === 'zero-rows') {
    expect = { type: 'zero-rows' };
  } else if (header.expect.startsWith('scalar-equals:')) {
    const value = header.expect.slice('scalar-equals:'.length);
    if (!value) return { ok: false, error: `expect 'scalar-equals:' is missing a value` };
    expect = { type: 'scalar-equals', value };
  } else {
    return { ok: false, error: `expect must be 'zero-rows' or 'scalar-equals:<v>', got '${header.expect}'` };
  }

  const body = lines.slice(i).join('\n').trim();
  if (body.length === 0) return { ok: false, error: 'empty query body after the header block' };

  const semiIdx = body.indexOf(';');
  if (semiIdx !== -1 && body.slice(semiIdx + 1).trim().length > 0) {
    return { ok: false, error: 'multi-statement file (a semicolon is followed by non-whitespace)' };
  }

  return {
    ok: true,
    invariant: {
      id: header.id,
      statement: header.statement,
      severity: header.severity,
      expect,
      query: body,
      file: absPath,
    },
  };
}

export function parseInvariantFile(absPath, readFileImpl) {
  const text = readFileImpl(absPath, 'utf8');
  return parseInvariantText(absPath, text);
}
