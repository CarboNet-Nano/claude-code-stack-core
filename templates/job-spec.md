# Job spec: <role name>

REQ-160 (Role-definition audit, P3 — template defined here in P1b, exemplar
is `agents/pm.md`). Every rostered agent definition is a research-grounded
job spec, not a prompt tidy-up: the seven sections below are the fixed
contract. A per-role spec written to this template cites real-world role
research (the professional job this agent replaces for a solo builder) and,
once ≥90 days of dispatch logs exist, actual-use evidence (misroutes,
overlap merges, dead-role verdicts) — P1b's exemplar (the PM) has no
dispatch history yet, so its Body of Knowledge section cites role research
only; later P3 rewrites cite both.

## Mission

<One paragraph. What does this seat exist to do, and for whom? State the
outcome it's accountable for, not the tasks it performs.>

## Responsibilities

<Bulleted list. What does this role actually do, day to day? Scope it —
what's explicitly NOT this role's job belongs here too, as a sub-bullet or a
short "Not responsible for" line.>

## How This Role Is Judged In Industry

<How is the human professional this agent replaces evaluated in a real job?
Cite the actual review criteria, KPIs, or professional norms of that role —
this section is what keeps the agent's design grounded in a real job rather
than an invented one.>

## Seniority / Experience Posture

<What level of judgment does this role assume — junior/execution-only,
senior/autonomous, or something context-dependent? State how that maps to
the behavior-matrix dials (assertiveness/autonomy) for this role's default
row.>

## Collaborators & Known Friction Points

<Who does this role hand off to / receive from? Where does friction
historically happen at that boundary (misrouted work, redundant review,
unclear ownership)? Name the adjacent roles explicitly.>

## Body of Knowledge

<What does this role need to know to do the job — domain concepts, house
conventions, external standards? Cite role research (and, once available,
dispatch-log evidence) rather than asserting it from first principles.>

## Default Matrix Row & Execution Profile

<Which `config/behavior-matrix.json` row (or fallback tier) governs this
role by default, and why those assertiveness/autonomy values fit the role's
judgment posture? Which `config/model-routing.json` `subagent_assignments`
entry routes it, and at what model/effort tier, and why?>
