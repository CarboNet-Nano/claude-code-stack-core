import { LADDER, GATED_DOMAIN_MODES } from "./matrix.mjs";

// REQ-125 — change-control on the human-control axis. LADDER is data:
// observe < recommend < decide-with-review < decide < gate. "Lowering" a
// dial means moving to a LOWER ladder index (toward less human control,
// e.g. gate -> decide). Contexts that require explicit human confirmation
// before a lowering is allowed: the two domain modes that ship with a
// hard "gate" floor (financial-code, schema-migration), and either
// sensitive/confidential sensitivity level, regardless of domain mode.
const CONFIRM_SENSITIVITIES = new Set(["sensitive", "confidential"]);

export function isLowering(before, after) {
  const beforeIndex = LADDER.indexOf(before);
  const afterIndex = LADDER.indexOf(after);
  if (beforeIndex === -1 || afterIndex === -1) {
    throw new Error(`isLowering: dial values must be on the LADDER — got before='${before}' after='${after}'`);
  }
  return afterIndex < beforeIndex;
}

export function requiresConfirm({ domainMode, sensitivity, before, after }) {
  if (!isLowering(before, after)) return false;
  return GATED_DOMAIN_MODES.has(domainMode) || CONFIRM_SENSITIVITIES.has(sensitivity);
}

// planMatrixEdit — pure decision, no I/O. Returns whether the edit is
// allowed and whether it needed (and got) confirmation, without touching a
// journal or any file.
export function planMatrixEdit({ domainMode, sensitivity, dial, before, after, confirmLower }) {
  if (!LADDER.includes(before) || !LADDER.includes(after)) {
    return { allowed: false, reason: `invalid ladder value — before='${before}' after='${after}' must be one of ${LADDER.join("|")}` };
  }

  const lowering = isLowering(before, after);
  const needsConfirm = lowering && requiresConfirm({ domainMode, sensitivity, before, after });

  if (needsConfirm && confirmLower !== true) {
    return {
      allowed: false,
      lowering,
      needsConfirm: true,
      reason: `lowering ${dial} ${before} -> ${after} on ${domainMode}/${sensitivity} requires --confirm-lower`
    };
  }

  return { allowed: true, lowering, needsConfirm };
}

export function buildMatrixChangeEvent({ agent, domainMode, sensitivity, dial, before, after, confirmLower, portfolio, nowIso, author = "user" }) {
  return {
    ts: nowIso,
    type: "matrix_change",
    subject: agent,
    author,
    portfolio,
    body: {
      agent,
      context: { domainMode, sensitivity },
      dial,
      before,
      after,
      confirmed: confirmLower === true
    }
  };
}

// editMatrix — pure decision layer. Returns whether the edit is allowed
// and, for a CONFIRMED lowering in a gated context, the matrix_change
// event ready to journal (REQ-125 ties the event specifically to that
// flow; ordinary raises and ungated lowerings apply silently, no journal
// noise). Deliberately does NOT touch a journal or any file itself — review
// fix: journaling here (before the caller's config write) risked a
// journal-before-apply false audit trail on a write failure. The caller
// (cli.mjs) writes the config FIRST and appends this event only after that
// write succeeds, mirroring runCloseout's journal-last pattern.
export function editMatrix(input) {
  const plan = planMatrixEdit(input);
  if (!plan.allowed) {
    return { ok: false, reason: plan.reason, needsConfirm: plan.needsConfirm === true };
  }

  if (!plan.lowering || !plan.needsConfirm) {
    return { ok: true, lowering: plan.lowering };
  }

  return { ok: true, lowering: true, event: buildMatrixChangeEvent(input) };
}
