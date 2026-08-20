import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import {
  LADDER,
  DOMAIN_MODES,
  SENSITIVITY_LEVELS,
  DEFAULT_MATRIX_PATH,
  EXECUTION_TIERS,
  PACE_VALUES,
  deriveRoster,
  validateMatrix,
  loadDefaultMatrix,
  loadOverrides,
  resolveMatrix,
  resolveExecution,
  applyPace
} from "../src/matrix.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..", "..", "..");
const REAL_STACK_CONFIG_PATH = join(REPO_ROOT, ".claude", "stack-config.json");
const REAL_PORTFOLIO_PATH = join(REPO_ROOT, "config", "portfolio.json");
const REAL_MODEL_ROUTING_PATH = join(REPO_ROOT, "config", "model-routing.json");
const MATRIX_SRC_PATH = join(__dirname, "..", "src", "matrix.mjs");

const roster = deriveRoster();
const defaultMatrix = loadDefaultMatrix();

test("REQ-120: LADDER and SENSITIVITY_LEVELS match the shipped enums verbatim", () => {
  assert.deepEqual(LADDER, ["observe", "recommend", "decide-with-review", "decide", "gate"]);
  assert.deepEqual(DOMAIN_MODES, ["financial-code", "schema-migration", "ui-design", "deploy", "default"]);
  // schemas/stack-config-schema.json:73 — the stack's existing sensitivity enum.
  assert.deepEqual(SENSITIVITY_LEVELS, ["normal", "sensitive", "confidential"]);
});

test("REQ-120: deriveRoster covers every real agents/*.md file plus the anticipated 'pm' row", () => {
  assert.ok(roster.includes("pm"), "pm row must be seeded ahead of Task 14 creating agents/pm.md");
  assert.ok(roster.includes("implementer"));
  assert.ok(roster.includes("accessibility-auditor"));
  assert.equal(new Set(roster).size, roster.length, "roster must be deduplicated");
});

test("REQ-120: validateMatrix accepts the shipped defaults file against the real roster", () => {
  const issues = validateMatrix(defaultMatrix, roster);
  assert.deepEqual(issues, []);
});

test("REQ-120: validateMatrix rejects a matrix missing one rostered agent (roster-coverage RED case)", () => {
  const { implementer: _dropped, ...rest } = defaultMatrix.agents;
  const broken = { ...defaultMatrix, agents: rest };
  const issues = validateMatrix(broken, roster);
  assert.ok(issues.some((i) => i.includes("missing agent row: implementer")));
});

test("REQ-120: validateMatrix rejects a missing 'pm' row specifically", () => {
  const { pm: _dropped, ...rest } = defaultMatrix.agents;
  const broken = { ...defaultMatrix, agents: rest };
  const issues = validateMatrix(broken, roster);
  assert.ok(issues.some((i) => i.includes("missing agent row: pm")));
});

test("REQ-120: validateMatrix rejects an invalid assertiveness value not on the 5-step ladder", () => {
  const broken = structuredClone(defaultMatrix);
  broken.agents.implementer.default.normal.assertiveness = "conviction";
  const issues = validateMatrix(broken, roster);
  assert.ok(issues.some((i) => i.includes("implementer/default/normal") && i.includes("invalid cell")));
});

test("REQ-120: validateMatrix rejects a matrix using a sensitivity key outside normal|sensitive|confidential", () => {
  const broken = structuredClone(defaultMatrix);
  // rename 'sensitive' -> a bogus key; validateMatrix must flag the now-missing
  // 'sensitive' entry rather than silently accepting the unrecognized one.
  const { sensitive, ...rest } = broken.agents.implementer.default;
  broken.agents.implementer.default = { ...rest, "very-sensitive": sensitive };
  const issues = validateMatrix(broken, roster);
  assert.ok(
    issues.some((i) => i.startsWith("implementer/default/sensitive:") && i.includes("invalid cell"))
  );
});

test("REQ-120: shipped defaults — every financial-code cell has assertiveness 'gate', all agents and sensitivities", () => {
  for (const agentName of roster) {
    for (const sensitivity of SENSITIVITY_LEVELS) {
      const cell = defaultMatrix.agents[agentName]["financial-code"][sensitivity];
      assert.equal(cell.assertiveness, "gate", `${agentName}/financial-code/${sensitivity}`);
    }
  }
});

test("REQ-120: shipped defaults — every schema-migration cell has assertiveness 'gate', all agents and sensitivities", () => {
  for (const agentName of roster) {
    for (const sensitivity of SENSITIVITY_LEVELS) {
      const cell = defaultMatrix.agents[agentName]["schema-migration"][sensitivity];
      assert.equal(cell.assertiveness, "gate", `${agentName}/schema-migration/${sensitivity}`);
    }
  }
});

test("REQ-121: resolveMatrix — repo override beats a conflicting portfolio cell", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "normal" };
  const overrides = {
    repo: { implementer: { default: { normal: { assertiveness: "gate", autonomy: "observe" } } } },
    portfolio: { implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } } },
    stackDefault: defaultMatrix
  };
  const { cell, warnings } = resolveMatrix(input, overrides);
  assert.deepEqual(cell, { assertiveness: "gate", autonomy: "observe" });
  assert.deepEqual(warnings, []);
});

test("REQ-121: resolveMatrix — partial repo override is per-cell, not whole-agent: an unrelated cell falls through to portfolio/stack-default (regression trap for a future whole-agent-replace refactor)", () => {
  const repo = { implementer: { "financial-code": { normal: { assertiveness: "gate", autonomy: "observe" } } } };

  // The overridden cell: repo wins.
  const overridden = resolveMatrix(
    { agent: "implementer", domainMode: "financial-code", sensitivity: "normal" },
    { repo, stackDefault: defaultMatrix }
  );
  assert.deepEqual(overridden.cell, { assertiveness: "gate", autonomy: "observe" });

  // A different cell on the SAME agent: repo has no entry for it, so it must
  // fall through to portfolio, then stack default — never inherit or block
  // on the repo override existing for a different (domainMode, sensitivity).
  const portfolio = { implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } } };
  const fallsThroughToPortfolio = resolveMatrix(
    { agent: "implementer", domainMode: "default", sensitivity: "normal" },
    { repo, portfolio, stackDefault: defaultMatrix }
  );
  assert.deepEqual(fallsThroughToPortfolio.cell, { assertiveness: "decide", autonomy: "decide" });

  const fallsThroughToStackDefault = resolveMatrix(
    { agent: "implementer", domainMode: "default", sensitivity: "normal" },
    { repo, stackDefault: defaultMatrix }
  );
  assert.deepEqual(fallsThroughToStackDefault.cell, defaultMatrix.agents.implementer.default.normal);
  assert.notDeepEqual(fallsThroughToStackDefault.cell, { assertiveness: "gate", autonomy: "observe" });
});

test("REQ-120: shipped defaults — the fallback cube's financial-code/schema-migration cells are also 'gate' (not just rostered agents)", () => {
  for (const sensitivity of SENSITIVITY_LEVELS) {
    assert.equal(defaultMatrix.fallback["financial-code"][sensitivity].assertiveness, "gate");
    assert.equal(defaultMatrix.fallback["schema-migration"][sensitivity].assertiveness, "gate");
  }
});

test("REQ-121: resolveMatrix — portfolio override beats stack default when repo/persona are absent", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "normal" };
  const overrides = {
    portfolio: { implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } } },
    stackDefault: defaultMatrix
  };
  const { cell } = resolveMatrix(input, overrides);
  assert.deepEqual(cell, { assertiveness: "decide", autonomy: "decide" });
});

test("REQ-121: resolveMatrix — persona layer (wired now, empty in P1b production) beats stack default when present", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "normal" };
  const overrides = {
    persona: { implementer: { default: { normal: { assertiveness: "observe", autonomy: "observe" } } } },
    stackDefault: defaultMatrix
  };
  const { cell } = resolveMatrix(input, overrides);
  assert.deepEqual(cell, { assertiveness: "observe", autonomy: "observe" });
});

test("REQ-121: resolveMatrix — full chain: repo wins over portfolio, persona, and stack default all populated", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "normal" };
  const overrides = {
    repo: { implementer: { default: { normal: { assertiveness: "gate", autonomy: "gate" } } } },
    portfolio: { implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } } },
    persona: { implementer: { default: { normal: { assertiveness: "observe", autonomy: "observe" } } } },
    stackDefault: defaultMatrix
  };
  const { cell } = resolveMatrix(input, overrides);
  assert.deepEqual(cell, { assertiveness: "gate", autonomy: "gate" });
});

test("REQ-120: resolveMatrix — unknown domain mode falls back to 'default' context, never throws", () => {
  const input = { agent: "implementer", domainMode: "totally-bogus-mode", sensitivity: "normal" };
  assert.doesNotThrow(() => resolveMatrix(input, { stackDefault: defaultMatrix }));
  const { cell } = resolveMatrix(input, { stackDefault: defaultMatrix });
  assert.deepEqual(cell, defaultMatrix.agents.implementer.default.normal);
});

test("REQ-120: resolveMatrix — unknown agent falls back to the shipped fallback cube, never throws", () => {
  const input = { agent: "no-such-agent", domainMode: "default", sensitivity: "normal" };
  assert.doesNotThrow(() => resolveMatrix(input, { stackDefault: defaultMatrix }));
  const { cell } = resolveMatrix(input, { stackDefault: defaultMatrix });
  assert.deepEqual(cell, defaultMatrix.fallback.default.normal);
});

test("REQ-120: resolveMatrix — unknown sensitivity falls back to 'normal', never throws", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "bogus" };
  const { cell } = resolveMatrix(input, { stackDefault: defaultMatrix });
  assert.deepEqual(cell, defaultMatrix.agents.implementer.default.normal);
});

test("REQ-120: resolveMatrix return shape is exactly {cell, warnings} with warnings deep-equal []", () => {
  const input = { agent: "implementer", domainMode: "default", sensitivity: "normal" };
  const result = resolveMatrix(input, { stackDefault: defaultMatrix });
  assert.deepEqual(Object.keys(result).sort(), ["cell", "warnings"]);
  assert.deepEqual(result.warnings, []);
});

test("REQ-121: resolveMatrix is pure — same input twice yields deep-equal (not necessarily identical) output", () => {
  const input = { agent: "security-auditor", domainMode: "financial-code", sensitivity: "confidential" };
  const overrides = { stackDefault: defaultMatrix };
  const first = resolveMatrix(input, overrides);
  const second = resolveMatrix({ ...input }, { ...overrides });
  assert.deepEqual(first, second);
});

test("REQ-121: loadOverrides round-trips a fixture stack-config.json pm_matrix and portfolio.json .matrix", () => {
  const tmp = mkdtempSync(join(tmpdir(), "matrix-loadoverrides-"));
  try {
    const repoConfigPath = join(tmp, "stack-config.json");
    const portfolioConfigPath = join(tmp, "portfolio.json");

    writeFileSync(
      repoConfigPath,
      JSON.stringify({
        pm_matrix: { implementer: { default: { normal: { assertiveness: "gate", autonomy: "observe" } } } }
      })
    );
    writeFileSync(
      portfolioConfigPath,
      JSON.stringify({
        portfolios: { carbonet: { pace: "balanced", members: [] } },
        matrix: { implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } } }
      })
    );

    const overrides = loadOverrides({ repoConfigPath, portfolioConfigPath });
    assert.deepEqual(overrides.repo, {
      implementer: { default: { normal: { assertiveness: "gate", autonomy: "observe" } } }
    });
    assert.deepEqual(overrides.portfolio, {
      implementer: { default: { normal: { assertiveness: "decide", autonomy: "decide" } } }
    });

    const { cell } = resolveMatrix(
      { agent: "implementer", domainMode: "default", sensitivity: "normal" },
      { ...overrides, stackDefault: defaultMatrix }
    );
    assert.deepEqual(cell, { assertiveness: "gate", autonomy: "observe" });
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("REQ-121: loadOverrides against the real repo config/portfolio.json — no .matrix key yields undefined, resolver still resolves", () => {
  const overrides = loadOverrides({
    repoConfigPath: REAL_STACK_CONFIG_PATH,
    portfolioConfigPath: REAL_PORTFOLIO_PATH
  });
  assert.equal(overrides.repo, undefined, "real .claude/stack-config.json has no pm_matrix field yet");
  assert.equal(overrides.portfolio, undefined, "real config/portfolio.json has no .matrix field yet");

  const { cell, warnings } = resolveMatrix(
    { agent: "implementer", domainMode: "default", sensitivity: "normal" },
    { ...overrides, stackDefault: defaultMatrix }
  );
  assert.deepEqual(cell, defaultMatrix.agents.implementer.default.normal);
  assert.deepEqual(warnings, []);
});

test("REQ-121: loadOverrides returns undefined layers when paths are absent or missing, never throws", () => {
  assert.doesNotThrow(() => loadOverrides({}));
  assert.deepEqual(loadOverrides({}), { repo: undefined, portfolio: undefined });
  assert.deepEqual(
    loadOverrides({ repoConfigPath: join(tmpdir(), "does-not-exist-matrix.json") }),
    { repo: undefined, portfolio: undefined }
  );
});

test("REQ-120: DEFAULT_MATRIX_PATH points at the shipped config/behavior-matrix.json", () => {
  assert.ok(DEFAULT_MATRIX_PATH.endsWith(join("config", "behavior-matrix.json")));
});

// ---------------------------------------------------------------------------
// REQ-123: execution join. resolveExecution(cell, modelRouting) -> profile.
// The matrix is the JOIN point only — config/model-routing.json stays
// authoritative for model ids/pricing. cell.execution.tier is a symbolic
// tier NAME (EXECUTION_TIERS), never a model id literal.
// ---------------------------------------------------------------------------

const MODEL_ROUTING_FIXTURE = {
  model_fit: {
    tier_ladder: ["fixture-model-haiku", "fixture-model-sonnet", "fixture-model-opus", "fixture-model-fable"]
  }
};

test("REQ-123: EXECUTION_TIERS is a 4-rung cheap->strong ladder with no model-id literal", () => {
  assert.deepEqual(EXECUTION_TIERS, ["haiku", "sonnet", "opus", "fable"]);
});

test("REQ-123: resolveExecution joins cell.execution against a model-routing fixture by tier NAME", () => {
  const cell = {
    assertiveness: "recommend",
    autonomy: "decide-with-review",
    execution: { tier: "sonnet", effort: "medium", advisor: null, fanout: 1 }
  };
  const profile = resolveExecution(cell, MODEL_ROUTING_FIXTURE);
  assert.deepEqual(profile, {
    tier: "sonnet",
    model: "fixture-model-sonnet",
    effort: "medium",
    advisor: null,
    fanout: 1
  });
});

test("REQ-123: resolveExecution defaults advisor to null and fanout to 1 when the row omits them", () => {
  const cell = { execution: { tier: "haiku", effort: "low" } };
  const profile = resolveExecution(cell, MODEL_ROUTING_FIXTURE);
  assert.deepEqual(profile, { tier: "haiku", model: "fixture-model-haiku", effort: "low", advisor: null, fanout: 1 });
});

test("REQ-123: resolveExecution returns null when the row names no execution profile (it is optional)", () => {
  const cell = { assertiveness: "recommend", autonomy: "decide-with-review" };
  assert.equal(resolveExecution(cell, MODEL_ROUTING_FIXTURE), null);
  assert.equal(resolveExecution(undefined, MODEL_ROUTING_FIXTURE), null);
});

test("REQ-123: resolveExecution throws on a tier name absent from EXECUTION_TIERS", () => {
  const cell = { execution: { tier: "flagship-turbo", effort: "high" } };
  assert.throws(() => resolveExecution(cell, MODEL_ROUTING_FIXTURE), /unknown execution tier/);
});

test("REQ-123: resolveExecution throws if model-routing has no tier_ladder entry for the resolved index", () => {
  const cell = { execution: { tier: "fable", effort: "high" } };
  const shortLadder = { model_fit: { tier_ladder: ["fixture-model-haiku"] } };
  assert.throws(() => resolveExecution(cell, shortLadder), /tier_ladder/);
});

test("REQ-123: a proposal fixture carrying a dial change AND a profile change validates as one unit (resolveMatrix -> resolveExecution)", () => {
  const overrides = {
    repo: {
      implementer: {
        default: {
          normal: {
            assertiveness: "gate",
            autonomy: "gate",
            execution: { tier: "opus", effort: "high", advisor: "reviewer", fanout: 2 }
          }
        }
      }
    },
    stackDefault: loadDefaultMatrix()
  };
  const { cell, warnings } = resolveMatrix(
    { agent: "implementer", domainMode: "default", sensitivity: "normal" },
    overrides
  );
  assert.deepEqual(warnings, []);
  assert.equal(cell.assertiveness, "gate", "dial change carried through resolveMatrix");
  assert.equal(cell.autonomy, "gate", "dial change carried through resolveMatrix");

  const profile = resolveExecution(cell, MODEL_ROUTING_FIXTURE);
  assert.deepEqual(profile, {
    tier: "opus",
    model: "fixture-model-opus",
    effort: "high",
    advisor: "reviewer",
    fanout: 2
  });
});

test("REQ-123: resolveExecution throws when tier_ladder[index] does not contain the tier's family word (reorder-safety self-check)", () => {
  const cell = { execution: { tier: "sonnet", effort: "medium" } };
  // tier "sonnet" resolves to index 1 — put an unrelated id there, as an
  // insert/reorder of the real tier_ladder would.
  const reordered = { model_fit: { tier_ladder: ["fixture-model-haiku", "fixture-model-opus", "fixture-model-sonnet"] } };
  assert.throws(() => resolveExecution(cell, reordered), /does not contain the family word/);
});

test("REQ-123: live-file consistency — every EXECUTION_TIERS entry's real tier_ladder id contains its family word", () => {
  const modelRouting = JSON.parse(readFileSync(REAL_MODEL_ROUTING_PATH, "utf8"));
  const tierLadder = modelRouting.model_fit.tier_ladder;
  EXECUTION_TIERS.forEach((tier, index) => {
    const model = tierLadder[index];
    assert.ok(model, `config/model-routing.json model_fit.tier_ladder has no entry at index ${index} for tier '${tier}'`);
    assert.ok(
      model.includes(tier),
      `config/model-routing.json model_fit.tier_ladder[${index}] ('${model}') does not contain family word '${tier}' — EXECUTION_TIERS has drifted from the live tier_ladder`
    );
  });
});

test("REQ-123: literal-scan — matrix.mjs never embeds a claude-/gpt-/gemini- model id literal", () => {
  const src = readFileSync(MATRIX_SRC_PATH, "utf8");
  for (const banned of ["claude-", "gpt-", "gemini-"]) {
    assert.ok(!src.includes(banned), `matrix.mjs must not contain the literal '${banned}'`);
  }
});

test("REQ-123: literal-scan — config/behavior-matrix.json never embeds a claude-/gpt-/gemini- model id literal", () => {
  const src = readFileSync(DEFAULT_MATRIX_PATH, "utf8");
  for (const banned of ["claude-", "gpt-", "gemini-"]) {
    assert.ok(!src.includes(banned), `behavior-matrix.json must not contain the literal '${banned}'`);
  }
});

// ---------------------------------------------------------------------------
// REQ-124: pace dial. applyPace(pace, inputs) -> {runPlanWidth,
// executionTier, timeVsSpendWeight}. `inputs` is the unbiased baseline triple
// for one scenario; applyPace nudges each axis by pace. `balanced` is the
// identity transform.
// ---------------------------------------------------------------------------

const PACE_BASELINE = { runPlanWidth: 2, executionTier: "sonnet", timeVsSpendWeight: 0.5 };

test("REQ-124: PACE_VALUES is exactly fast|balanced|frugal", () => {
  assert.deepEqual(PACE_VALUES, ["fast", "balanced", "frugal"]);
});

test("REQ-124: applyPace — balanced is the identity transform on the baseline", () => {
  assert.deepEqual(applyPace("balanced", PACE_BASELINE), PACE_BASELINE);
});

test("REQ-124: applyPace — same scenario, fast vs frugal differ on ALL THREE outputs", () => {
  const fast = applyPace("fast", PACE_BASELINE);
  const frugal = applyPace("frugal", PACE_BASELINE);
  assert.notEqual(fast.runPlanWidth, frugal.runPlanWidth, "runPlanWidth must differ");
  assert.notEqual(fast.executionTier, frugal.executionTier, "executionTier must differ");
  assert.notEqual(fast.timeVsSpendWeight, frugal.timeVsSpendWeight, "timeVsSpendWeight must differ");
});

test("REQ-124: applyPace — fast widens run-plan width and biases toward a stronger execution tier", () => {
  const fast = applyPace("fast", PACE_BASELINE);
  assert.ok(fast.runPlanWidth > PACE_BASELINE.runPlanWidth);
  assert.ok(EXECUTION_TIERS.indexOf(fast.executionTier) > EXECUTION_TIERS.indexOf(PACE_BASELINE.executionTier));
});

test("REQ-124: applyPace — frugal narrows run-plan width and biases toward a cheaper execution tier", () => {
  const frugal = applyPace("frugal", PACE_BASELINE);
  assert.ok(frugal.runPlanWidth < PACE_BASELINE.runPlanWidth);
  assert.ok(EXECUTION_TIERS.indexOf(frugal.executionTier) < EXECUTION_TIERS.indexOf(PACE_BASELINE.executionTier));
});

test("REQ-124: applyPace — balanced sits strictly between fast and frugal on the time-vs-spend weight axis", () => {
  const fast = applyPace("fast", PACE_BASELINE);
  const balanced = applyPace("balanced", PACE_BASELINE);
  const frugal = applyPace("frugal", PACE_BASELINE);
  assert.ok(frugal.timeVsSpendWeight < balanced.timeVsSpendWeight, "frugal < balanced");
  assert.ok(balanced.timeVsSpendWeight < fast.timeVsSpendWeight, "balanced < fast");
});

test("REQ-124: applyPace — runPlanWidth, executionTier, and timeVsSpendWeight clamp at ladder boundaries", () => {
  const atTop = { runPlanWidth: 5, executionTier: "fable", timeVsSpendWeight: 1 };
  const fast = applyPace("fast", atTop);
  assert.deepEqual(fast, atTop, "already at the top of every axis — fast cannot overflow it");

  const atBottom = { runPlanWidth: 1, executionTier: "haiku", timeVsSpendWeight: 0 };
  const frugal = applyPace("frugal", atBottom);
  assert.deepEqual(frugal, atBottom, "already at the bottom of every axis — frugal cannot underflow it");
});

test("REQ-124: applyPace — unknown pace throws", () => {
  assert.throws(() => applyPace("turbo", PACE_BASELINE), /unknown pace/);
});
