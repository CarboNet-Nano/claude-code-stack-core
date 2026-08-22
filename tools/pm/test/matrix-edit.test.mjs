import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveMatrix, loadDefaultMatrix } from "../src/matrix.mjs";
import { isLowering, requiresConfirm, planMatrixEdit, editMatrix } from "../src/matrix-edit.mjs";
import { main } from "../src/cli.mjs";

const defaultMatrix = loadDefaultMatrix();

function makeJournal() {
  const calls = [];
  return {
    calls,
    append(e) {
      calls.push(e);
      return `fake-event-${calls.length}`;
    }
  };
}

// ---------------------------------------------------------------------------
// isLowering / requiresConfirm — pure LADDER comparison
// ---------------------------------------------------------------------------

test("REQ-125: isLowering — gate -> decide is a lowering", () => {
  assert.equal(isLowering("gate", "decide"), true);
});

test("REQ-125: isLowering — decide -> gate is NOT a lowering (raise)", () => {
  assert.equal(isLowering("decide", "gate"), false);
});

test("REQ-125: isLowering — same value is not a lowering", () => {
  assert.equal(isLowering("gate", "gate"), false);
});

test("REQ-125: isLowering — throws on a value off the LADDER", () => {
  assert.throws(() => isLowering("gate", "conviction"), /LADDER/);
});

test("REQ-125: requiresConfirm — financial-code lowering requires confirm", () => {
  assert.equal(requiresConfirm({ domainMode: "financial-code", sensitivity: "normal", before: "gate", after: "decide" }), true);
});

test("REQ-125: requiresConfirm — schema-migration lowering requires confirm", () => {
  assert.equal(requiresConfirm({ domainMode: "schema-migration", sensitivity: "normal", before: "gate", after: "decide" }), true);
});

test("REQ-125: requiresConfirm — confidential sensitivity lowering requires confirm regardless of domain mode", () => {
  assert.equal(requiresConfirm({ domainMode: "default", sensitivity: "confidential", before: "decide", after: "observe" }), true);
});

test("REQ-125: requiresConfirm — sensitive sensitivity lowering requires confirm regardless of domain mode", () => {
  assert.equal(requiresConfirm({ domainMode: "ui-design", sensitivity: "sensitive", before: "decide", after: "recommend" }), true);
});

test("REQ-125: requiresConfirm — lowering on ui-design × normal needs no confirm (ungated context)", () => {
  assert.equal(requiresConfirm({ domainMode: "ui-design", sensitivity: "normal", before: "gate", after: "decide" }), false);
});

test("REQ-125: requiresConfirm — raising never requires confirm, even on a gated context", () => {
  assert.equal(requiresConfirm({ domainMode: "financial-code", sensitivity: "normal", before: "decide", after: "gate" }), false);
});

// ---------------------------------------------------------------------------
// planMatrixEdit — pure decision, no I/O
// ---------------------------------------------------------------------------

test("REQ-125: planMatrixEdit — lowering gate->decide on financial-code without confirm is refused", () => {
  const plan = planMatrixEdit({ domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: false });
  assert.equal(plan.allowed, false);
  assert.equal(plan.needsConfirm, true);
  assert.match(plan.reason, /--confirm-lower/);
});

test("REQ-125: planMatrixEdit — same lowering WITH confirm is allowed", () => {
  const plan = planMatrixEdit({ domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: true });
  assert.equal(plan.allowed, true);
  assert.equal(plan.lowering, true);
  assert.equal(plan.needsConfirm, true);
});

test("REQ-125: planMatrixEdit — raising needs no confirm", () => {
  const plan = planMatrixEdit({ domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "decide", after: "gate", confirmLower: false });
  assert.equal(plan.allowed, true);
  assert.equal(plan.lowering, false);
});

test("REQ-125: planMatrixEdit — lowering on ui-design × normal needs no confirm", () => {
  const plan = planMatrixEdit({ domainMode: "ui-design", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: false });
  assert.equal(plan.allowed, true);
  assert.equal(plan.lowering, true);
  assert.equal(plan.needsConfirm, false);
});

test("REQ-125: planMatrixEdit — confidential context lowering without confirm is refused", () => {
  const plan = planMatrixEdit({ domainMode: "default", sensitivity: "confidential", dial: "autonomy", before: "decide", after: "observe", confirmLower: false });
  assert.equal(plan.allowed, false);
  assert.equal(plan.needsConfirm, true);
});

test("REQ-125: planMatrixEdit — invalid ladder value is refused", () => {
  const plan = planMatrixEdit({ domainMode: "default", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "bogus", confirmLower: true });
  assert.equal(plan.allowed, false);
  assert.match(plan.reason, /invalid ladder value/);
});

// ---------------------------------------------------------------------------
// editMatrix — PURE decision layer. No journal, no file I/O — it only
// decides and, for a confirmed gated lowering, hands back the matrix_change
// event ready to journal. Review fix: journaling used to happen INSIDE
// editMatrix, before the caller's config write — a write failure would then
// leave a permanent journal record (confirmed:true) for a change that never
// took effect. The actual journal.append call now lives in cli.mjs's
// runMatrixSet, AFTER the config write succeeds (see the CLI section below
// for the write-then-journal ordering tests).
// ---------------------------------------------------------------------------

test("REQ-125: editMatrix — lowering on financial-code without confirm: refused, no event built", () => {
  const result = editMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: false, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(result.ok, false);
  assert.equal(result.event, undefined, "no changes decided means no event to journal");
});

test("REQ-125: editMatrix — lowering on financial-code WITH confirm: applied, returns a matrix_change event with before/after", () => {
  const result = editMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: true, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(result.ok, true);
  assert.ok(result.event, "expected a matrix_change event to be returned for journaling");
  assert.equal(result.event.type, "matrix_change");
  assert.equal(result.event.portfolio, "carbonet");
  assert.deepEqual(result.event.body, {
    agent: "implementer",
    context: { domainMode: "financial-code", sensitivity: "normal" },
    dial: "assertiveness",
    before: "gate",
    after: "decide",
    confirmed: true
  });
});

test("REQ-125: editMatrix — RAISING needs no confirm and returns no event", () => {
  const result = editMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal", dial: "assertiveness", before: "decide", after: "gate", confirmLower: false, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(result.ok, true);
  assert.equal(result.event, undefined);
});

test("REQ-125: editMatrix — lowering on ui-design × normal needs no confirm and returns no event", () => {
  const result = editMatrix({ agent: "designer", domainMode: "ui-design", sensitivity: "normal", dial: "assertiveness", before: "gate", after: "decide", confirmLower: false, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(result.ok, true);
  assert.equal(result.event, undefined, "ungated lowering applies silently, no matrix_change noise");
});

test("REQ-125: editMatrix — confidential context lowering requires confirm; refused without it, event returned with it", () => {
  const refused = editMatrix({ agent: "implementer", domainMode: "default", sensitivity: "confidential", dial: "autonomy", before: "decide", after: "observe", confirmLower: false, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(refused.ok, false);
  assert.equal(refused.event, undefined);

  const applied = editMatrix({ agent: "implementer", domainMode: "default", sensitivity: "confidential", dial: "autonomy", before: "decide", after: "observe", confirmLower: true, portfolio: "carbonet", nowIso: "2026-08-08T12:00:00.000Z" });
  assert.equal(applied.ok, true);
  assert.equal(applied.event.body.confirmed, true);
});

// ---------------------------------------------------------------------------
// resolveMatrix warnings (REQ-125, populated in matrix.mjs, Task 9's
// {cell, warnings} shape now non-empty for a lowered-gate override)
// ---------------------------------------------------------------------------

test("REQ-125: resolveMatrix — portfolio override lowering a shipped 'gate' assertiveness yields a populated warnings array", () => {
  const overrides = {
    portfolio: { implementer: { "financial-code": { normal: { assertiveness: "decide", autonomy: "decide-with-review" } } } },
    stackDefault: defaultMatrix
  };
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal" }, overrides);
  assert.equal(warnings.length, 1);
  assert.deepEqual(warnings[0], {
    agent: "implementer",
    domainMode: "financial-code",
    sensitivity: "normal",
    dial: "assertiveness",
    before: "gate",
    after: "decide"
  });
});

test("REQ-125: resolveMatrix — non-lowering override yields warnings: []", () => {
  const overrides = {
    portfolio: { implementer: { "financial-code": { normal: { assertiveness: "gate", autonomy: "decide" } } } },
    stackDefault: defaultMatrix
  };
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal" }, overrides);
  assert.deepEqual(warnings, []);
});

test("REQ-125: resolveMatrix — an override that RAISES a dial never warns, even far from the default", () => {
  const overrides = {
    repo: { implementer: { default: { normal: { assertiveness: "gate", autonomy: "gate" } } } },
    stackDefault: defaultMatrix
  };
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "default", sensitivity: "normal" }, overrides);
  assert.deepEqual(warnings, []);
});

test("REQ-125: resolveMatrix — lowering a non-'gate' shipped default (e.g. 'recommend') is ordinary tuning, no warning", () => {
  // shipped default for implementer/default/normal is {assertiveness: recommend, autonomy: decide-with-review}
  const overrides = {
    portfolio: { implementer: { default: { normal: { assertiveness: "observe", autonomy: "observe" } } } },
    stackDefault: defaultMatrix
  };
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "default", sensitivity: "normal" }, overrides);
  assert.deepEqual(warnings, []);
});

test("REQ-125: resolveMatrix — both dials lowered from a shipped 'gate' baseline yields two warning entries", () => {
  // No shipped cell in the real defaults has BOTH dials pinned to 'gate'
  // (autonomy's floor there is 'observe' — see financial-code/confidential
  // above), so build a synthetic stackDefault to exercise the per-dial
  // loop independently of what today's real matrix happens to ship.
  const syntheticDefault = {
    agents: { implementer: { "financial-code": { confidential: { assertiveness: "gate", autonomy: "gate" } } } },
    fallback: {}
  };
  const overrides = {
    portfolio: { implementer: { "financial-code": { confidential: { assertiveness: "decide", autonomy: "recommend" } } } },
    stackDefault: syntheticDefault
  };
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "confidential" }, overrides);
  assert.equal(warnings.length, 2);
  assert.deepEqual(new Set(warnings.map((w) => w.dial)), new Set(["assertiveness", "autonomy"]));
});

test("REQ-125: resolveMatrix — no override layer present (shipped default answers directly) never warns", () => {
  const { warnings } = resolveMatrix({ agent: "implementer", domainMode: "financial-code", sensitivity: "normal" }, { stackDefault: defaultMatrix });
  assert.deepEqual(warnings, []);
});

// ---------------------------------------------------------------------------
// CLI: `pm matrix set` — end-to-end through main(), fake journal + in-memory
// portfolio.json file (no real disk I/O).
// ---------------------------------------------------------------------------

const CONFIG_PATH = "/fake/config/portfolio.json";

function makePortfolioConfig() {
  return JSON.stringify({ portfolios: { carbonet: { pace: "balanced", members: [] } } });
}

function baseCliDeps(overrides = {}) {
  const files = overrides.files || { [CONFIG_PATH]: makePortfolioConfig() };
  const stdoutLines = [];
  const journal = overrides.journal || makeJournal();
  return {
    journal,
    readFile: async (p) => {
      if (!(p in files)) throw new Error(`ENOENT: ${p}`);
      return files[p];
    },
    writeFile: async (p, c) => {
      files[p] = c;
    },
    stdout: (line) => stdoutLines.push(line),
    stdoutLines,
    files,
    nowIso: () => "2026-08-08T12:00:00.000Z",
    configPath: CONFIG_PATH
  };
}

test("CLI: pm matrix set — lowering on financial-code without --confirm-lower: refused, nothing written, no journal event", async () => {
  const deps = baseCliDeps();
  const before = deps.files[CONFIG_PATH];

  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--domain", "financial-code", "--dial", "assertiveness", "--value", "decide"],
    deps
  );

  assert.equal(result.code, 1);
  assert.equal(deps.files[CONFIG_PATH], before, "config file must be untouched on refusal");
  assert.equal(deps.journal.calls.length, 0);
  assert.ok(deps.stdoutLines.some((l) => l.includes("refused")));
});

test("CLI: pm matrix set — lowering on financial-code WITH --confirm-lower: applied, config written, matrix_change journaled", async () => {
  const deps = baseCliDeps();

  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--domain", "financial-code", "--dial", "assertiveness", "--value", "decide", "--confirm-lower"],
    deps
  );

  assert.equal(result.code, 0);
  assert.equal(result.before, "gate");
  assert.equal(result.after, "decide");
  assert.equal(deps.journal.calls.length, 1);
  assert.equal(deps.journal.calls[0].body.confirmed, true);

  const written = JSON.parse(deps.files[CONFIG_PATH]);
  assert.equal(written.matrix.implementer["financial-code"].normal.assertiveness, "decide");
  assert.equal(written.matrix.implementer["financial-code"].normal.autonomy, "decide-with-review", "untouched dial preserved from the resolved cell");
  assert.equal(written.portfolios.carbonet.pace, "balanced", "unrelated config untouched");
});

// Review fix — journal-before-apply regression trap: a confirmed lowering
// whose config write FAILS must produce NO journal event (a journal entry
// for a change that never took effect would be a false audit trail, the
// opposite of REQ-125's purpose) and must leave the config file byte-
// identical to what it was before the run.
test("CLI: pm matrix set — writeFile throws after a confirmed lowering: NO journal event, config unchanged, honest non-zero error", async () => {
  const deps = baseCliDeps();
  const originalConfig = deps.files[CONFIG_PATH];
  deps.writeFile = async () => {
    throw new Error("disk full");
  };

  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--domain", "financial-code", "--dial", "assertiveness", "--value", "decide", "--confirm-lower"],
    deps
  );

  assert.equal(result.code, 1);
  assert.equal(deps.files[CONFIG_PATH], originalConfig, "config file must be byte-identical — the write never landed");
  assert.equal(deps.journal.calls.length, 0, "a confirmed lowering that never took effect must not produce a matrix_change event");
  assert.ok(
    deps.stdoutLines.some((l) => l.includes("disk full") && l.includes("no journal entry made")),
    `expected an honest error naming the cause and confirming no journal entry, got: ${JSON.stringify(deps.stdoutLines)}`
  );
});

// Task 8: deps.journal is the SAME PG-engine-shaped object cutover wires for
// every command, not just brief/closeout -- append() is genuinely async
// under the real engine. A fake that actually returns a Promise (unlike
// this file's sync makeJournal() above) proves the CLI awaits it rather
// than printing/returning the Promise object itself as the event id.
test("CLI: pm matrix set — against a genuinely async journal, the printed/returned event id is the awaited value, not a pending Promise", async () => {
  const asyncJournal = {
    calls: [],
    async append(e) {
      asyncJournal.calls.push(e);
      return "real-async-event-id";
    }
  };
  const deps = baseCliDeps({ journal: asyncJournal });

  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--domain", "financial-code", "--dial", "assertiveness", "--value", "decide", "--confirm-lower"],
    deps
  );

  assert.equal(result.code, 0);
  assert.equal(result.eventId, "real-async-event-id", "eventId must be the awaited value, not a Promise");
  assert.ok(
    deps.stdoutLines.some((l) => l.includes("(journaled real-async-event-id)")),
    `expected the real event id in the printed line, not a stringified Promise, got: ${JSON.stringify(deps.stdoutLines)}`
  );
});

test("CLI: pm matrix set — raising needs no --confirm-lower and applies", async () => {
  const deps = baseCliDeps({
    files: {
      [CONFIG_PATH]: JSON.stringify({
        portfolios: { carbonet: { pace: "balanced", members: [] } },
        matrix: { implementer: { "financial-code": { normal: { assertiveness: "decide", autonomy: "decide-with-review" } } } }
      })
    }
  });

  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--domain", "financial-code", "--dial", "assertiveness", "--value", "gate"],
    deps
  );

  assert.equal(result.code, 0);
  assert.equal(deps.journal.calls.length, 0, "a raise is never journaled as a matrix_change");
  const written = JSON.parse(deps.files[CONFIG_PATH]);
  assert.equal(written.matrix.implementer["financial-code"].normal.assertiveness, "gate");
});

test("CLI: pm matrix set — missing required flags refused with code 1", async () => {
  const deps = baseCliDeps();
  const result = await main(["matrix", "set", "--portfolio", "carbonet"], deps);
  assert.equal(result.code, 1);
  assert.equal(deps.journal.calls.length, 0);
});

test("CLI: pm matrix set — invalid --dial refused with code 1", async () => {
  const deps = baseCliDeps();
  const result = await main(
    ["matrix", "set", "--portfolio", "carbonet", "--agent", "implementer", "--dial", "conviction", "--value", "gate"],
    deps
  );
  assert.equal(result.code, 1);
});

test("CLI: pm matrix — unknown subcommand refused with code 1", async () => {
  const deps = baseCliDeps();
  const result = await main(["matrix", "bogus-subcommand"], deps);
  assert.equal(result.code, 1);
});
