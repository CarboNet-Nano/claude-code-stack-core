import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// REQ-120/121 — behavior matrix: agent x (domain mode x sensitivity) ->
// {assertiveness, autonomy}. resolveMatrix is pure: every layer arrives as
// data via `overrides`, no disk I/O inside it. Reading real files (repo
// stack-config.json's `pm_matrix`, portfolio.json's `.matrix`,
// config/behavior-matrix.json) is a separate, explicit step (loadOverrides /
// loadDefaultMatrix) so callers choose when disk is touched.

const __dirname = dirname(fileURLToPath(import.meta.url));

export const LADDER = ["observe", "recommend", "decide-with-review", "decide", "gate"];
export const DOMAIN_MODES = ["financial-code", "schema-migration", "ui-design", "deploy", "default"];
export const SENSITIVITY_LEVELS = ["normal", "sensitive", "confidential"];
export const DIALS = ["assertiveness", "autonomy"];
export const GATED_DOMAIN_MODES = new Set(["financial-code", "schema-migration"]);

export const DEFAULT_MATRIX_PATH = join(__dirname, "..", "..", "..", "config", "behavior-matrix.json");
const DEFAULT_AGENTS_DIR = join(__dirname, "..", "..", "..", "agents");

// REQ-120 accept: roster is derived from the REAL agents/*.md directory, plus
// the anticipated `pm` row — agents/pm.md does not exist until Task 14, but
// config/behavior-matrix.json seeds that row now, so the roster-coverage
// test is honest about the one file it expects but cannot yet find on disk.
export function deriveRoster(agentsDir = DEFAULT_AGENTS_DIR) {
  const names = readdirSync(agentsDir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => f.slice(0, -3));
  const roster = new Set(names);
  roster.add("pm");
  return [...roster].sort();
}

function isValidCell(cell) {
  if (typeof cell !== "object" || cell === null) return false;
  return DIALS.every((dial) => LADDER.includes(cell[dial]));
}

// validateMatrix(json, roster) -> string[] of issues; empty means valid.
// Checks coverage (every roster agent, every domain mode, every sensitivity)
// and value validity. Does NOT judge whether a row is "reasoned" — that is a
// plan-review/human concern, not a test assertion.
export function validateMatrix(json, roster) {
  const issues = [];
  const agents = json?.agents ?? {};

  for (const agentName of roster) {
    const row = agents[agentName];
    if (!row) {
      issues.push(`missing agent row: ${agentName}`);
      continue;
    }
    for (const domainMode of DOMAIN_MODES) {
      const byMode = row[domainMode];
      if (!byMode) {
        issues.push(`${agentName}: missing domain mode '${domainMode}'`);
        continue;
      }
      for (const sensitivity of SENSITIVITY_LEVELS) {
        const cell = byMode[sensitivity];
        if (!isValidCell(cell)) {
          issues.push(`${agentName}/${domainMode}/${sensitivity}: invalid cell ${JSON.stringify(cell)}`);
          continue;
        }
        if (GATED_DOMAIN_MODES.has(domainMode) && cell.assertiveness !== "gate") {
          issues.push(
            `${agentName}/${domainMode}/${sensitivity}: assertiveness must be 'gate', got '${cell.assertiveness}'`
          );
        }
      }
    }
  }

  return issues;
}

export function loadDefaultMatrix(path = DEFAULT_MATRIX_PATH) {
  if (!existsSync(path)) {
    throw new Error(`matrix: no defaults file found at ${path}`);
  }
  return JSON.parse(readFileSync(path, "utf8"));
}

function readMatrixField(path, field) {
  if (!path || !existsSync(path)) return undefined;
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  return parsed?.[field];
}

// loadOverrides reads the REAL project/portfolio config shapes: a repo's
// `stack-config.json` may carry a `pm_matrix` field, a `portfolio.json` may
// carry a `.matrix` field. Both are optional and independently absent —
// today's real config/portfolio.json has no `.matrix` key at all, which must
// resolve to `undefined`, not an error.
export function loadOverrides({ repoConfigPath, portfolioConfigPath } = {}) {
  return {
    repo: readMatrixField(repoConfigPath, "pm_matrix"),
    portfolio: readMatrixField(portfolioConfigPath, "matrix")
  };
}

function lookupCell(tree, agent, domainMode, sensitivity) {
  return tree?.[agent]?.[domainMode]?.[sensitivity];
}

// REQ-125 — an override "lowers a shipped default gate" when the SHIPPED
// default for this exact (agent, domainMode, sensitivity) cell has a dial
// pinned at the strictest ladder rung ("gate") and the winning override
// moves that same dial to a lower rung (toward less human control). Scoped
// to dial-by-dial comparison, not the whole cell, and only fires against a
// "gate" baseline — a default of "recommend" being overridden downward is
// an ordinary tuning choice, not a change-control event. This is a pure
// read-time signal (used by both `brief.mjs` rendering and, independently,
// anything else that resolves the matrix), distinct from the write-time
// confirm-gating in matrix-edit.mjs.
function loweredGateWarnings({ agent, domainMode, sensitivity, overrideCell, shippedDefaultCell }) {
  if (!shippedDefaultCell) return [];
  const warnings = [];
  for (const dial of DIALS) {
    const before = shippedDefaultCell[dial];
    const after = overrideCell[dial];
    if (before !== "gate") continue;
    if (!LADDER.includes(after)) continue;
    if (LADDER.indexOf(after) < LADDER.indexOf(before)) {
      warnings.push({ agent, domainMode, sensitivity, dial, before, after });
    }
  }
  return warnings;
}

// resolveMatrix — FINAL return shape (review BLOCKER: no signature change in
// Task 11). Pure function. `warnings` is `[]` unless the winning layer is an
// override (repo/portfolio/persona) that lowers a shipped default "gate"
// dial (REQ-125) — never populated when the shipped default itself is the
// answer, since there is nothing to warn about overriding.
//
// Precedence (REQ-121; ADR-013/034 core-overlay): overrides.repo >
// overrides.portfolio > overrides.persona (empty P1b slot — wired here,
// unpopulated until a later task) > overrides.stackDefault.agents >
// overrides.stackDefault.fallback.
//
// Unknown domain mode / sensitivity normalize to "default" / "normal" before
// any lookup. An agent absent from every layer falls through to the shipped
// fallback cube. resolveMatrix never throws.
export function resolveMatrix({ agent, domainMode, sensitivity }, overrides = {}) {
  const { repo, portfolio, persona, stackDefault } = overrides;

  const resolvedDomainMode = DOMAIN_MODES.includes(domainMode) ? domainMode : "default";
  const resolvedSensitivity = SENSITIVITY_LEVELS.includes(sensitivity) ? sensitivity : "normal";

  const shippedDefaultCell =
    lookupCell(stackDefault?.agents, agent, resolvedDomainMode, resolvedSensitivity) ??
    stackDefault?.fallback?.[resolvedDomainMode]?.[resolvedSensitivity];

  for (const layer of [repo, portfolio, persona]) {
    const cell = lookupCell(layer, agent, resolvedDomainMode, resolvedSensitivity);
    if (cell) {
      const warnings = loweredGateWarnings({
        agent,
        domainMode: resolvedDomainMode,
        sensitivity: resolvedSensitivity,
        overrideCell: cell,
        shippedDefaultCell
      });
      return { cell: { ...cell }, warnings };
    }
  }

  return { cell: shippedDefaultCell ? { ...shippedDefaultCell } : undefined, warnings: [] };
}

// REQ-123 — execution join. A matrix row may optionally name an
// `execution: {tier, effort, advisor, fanout}` sub-object (resolveMatrix
// already passes it through untouched via its `{ ...cell }` spread — no
// change to resolveMatrix's FINAL {cell, warnings} shape was needed). The
// matrix is the JOIN point only: `config/model-routing.json` stays
// authoritative for model ids/pricing. `tier` is a symbolic tier NAME —
// cheap -> strong, index-aligned to model-routing.json's
// `model_fit.tier_ladder` — never a model id literal, so this file (and the
// shipped config/behavior-matrix.json) can carry a real cross-reference to
// model-routing without ever embedding one of its ids.
export const EXECUTION_TIERS = ["haiku", "sonnet", "opus", "fable"];

// resolveExecution(cell, modelRouting) -> profile | null. Pure: no disk I/O,
// `modelRouting` arrives as already-parsed data (the real config/model-
// routing.json or a fixture shaped like it). Returns null when the row names
// no execution profile — REQ-123 makes the field optional. Throws on a tier
// name outside EXECUTION_TIERS, or when modelRouting has no tier_ladder entry
// at the resolved index — both are configuration errors, not silent no-ops.
//
// Review fix (Task 10 follow-up): the tier<->tier_ladder join was pure index
// alignment — /model-audit edits tier_ladder over time, and an insert/reorder
// (not append) would silently hand back the WRONG model for a
// correctly-spelled tier, with no signal. Guard it with a runtime substring
// self-check: the id at tier_ladder[tierIndex] must contain the tier's own
// family word (e.g. "haiku" for tier "haiku"). Family words never collide
// with the literal-scan's banned provider-prefix strings, so this check
// itself never trips it.
export function resolveExecution(cell, modelRouting) {
  const execution = cell?.execution;
  if (!execution) return null;

  const { tier, effort, advisor = null, fanout = 1 } = execution;
  const tierIndex = EXECUTION_TIERS.indexOf(tier);
  if (tierIndex === -1) {
    throw new Error(`resolveExecution: unknown execution tier '${tier}' — must be one of ${EXECUTION_TIERS.join("|")}`);
  }

  const model = modelRouting?.model_fit?.tier_ladder?.[tierIndex];
  if (!model) {
    throw new Error(`resolveExecution: model-routing has no tier_ladder entry for tier '${tier}' (index ${tierIndex})`);
  }
  if (!model.includes(tier)) {
    throw new Error(
      `resolveExecution: tier_ladder[${tierIndex}] ('${model}') does not contain the family word for tier '${tier}' — tier_ladder may have been reordered/edited out from under EXECUTION_TIERS`
    );
  }

  return { tier, model, effort, advisor, fanout };
}

// REQ-124 — pace dial. A portfolio-level pace (fast|balanced|frugal) biases
// three axes together: run-plan parallel width (REQ-150, P2), execution-tier
// selection (REQ-123, above), and the PM's time-vs-spend weighting in
// priority calls. applyPace is the pure biasing function P1b ships; building
// an actual run plan from its output is P2. `inputs` is the UNBIASED
// baseline {runPlanWidth, executionTier, timeVsSpendWeight} for one
// scenario — produced elsewhere (a future caller reads the pace from
// config/portfolio.json; this function never touches disk). `balanced` is
// the identity transform. Each axis clamps at its own ladder boundary rather
// than over/underflowing.
export const PACE_VALUES = ["fast", "balanced", "frugal"];

const PACE_STEP = { fast: 1, balanced: 0, frugal: -1 };
const PACE_WEIGHT_DELTA = { fast: 0.3, balanced: 0, frugal: -0.3 };
const MIN_RUN_PLAN_WIDTH = 1;
const MAX_RUN_PLAN_WIDTH = 5;

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

export function applyPace(pace, inputs) {
  if (!PACE_VALUES.includes(pace)) {
    throw new Error(`applyPace: unknown pace '${pace}' — must be one of ${PACE_VALUES.join("|")}`);
  }

  const { runPlanWidth, executionTier, timeVsSpendWeight } = inputs;
  const tierIndex = EXECUTION_TIERS.indexOf(executionTier);
  if (tierIndex === -1) {
    throw new Error(`applyPace: unknown executionTier '${executionTier}' — must be one of ${EXECUTION_TIERS.join("|")}`);
  }

  const step = PACE_STEP[pace];
  const nextTierIndex = clamp(tierIndex + step, 0, EXECUTION_TIERS.length - 1);

  return {
    runPlanWidth: clamp(runPlanWidth + step, MIN_RUN_PLAN_WIDTH, MAX_RUN_PLAN_WIDTH),
    executionTier: EXECUTION_TIERS[nextTierIndex],
    timeVsSpendWeight: clamp(timeVsSpendWeight + PACE_WEIGHT_DELTA[pace], 0, 1)
  };
}
