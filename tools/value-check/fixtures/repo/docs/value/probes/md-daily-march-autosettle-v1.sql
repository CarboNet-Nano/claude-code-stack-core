-- md-daily-march-autosettle-v1.sql — fixture-quality probe for claim
-- md-daily-march-autosettle-v1 (Contract B, kind: sql-readonly).
--
-- Read-only against manufacturing-dashboard's public.daily_march_ledger
-- (ADR-050 v3 Slice 3, supabase/migrations/20260625a_march_confirm.sql).
-- Counts ledger rows written by an ACTUAL settle or consume — op =
-- 'fulfillment' OR op LIKE 'consume!_%' ESCAPE '!' (escaping the literal
-- underscore with '!' rather than the default backslash escape char, which
-- score.mjs:probeSafetyViolations rejects unconditionally — CRITICAL 1,
-- 2026-07-31 audit) — never op = 'void_consume', which would double-count
-- a corrected write.
--
-- This is a CUMULATIVE total over the observed window, not a rate — the
-- D11 reviewer (2026-07-31 live ratify dry-run) correctly rejected an
-- earlier version of this claim/probe pair that named the metric
-- "...per_week" while measuring a cumulative count (a target that could
-- PASS on a below-target weekly rate). `n` is the count of distinct weeks
-- observed — a statistical-basis signal for D13 bound 1, not a denominator.
--
-- D9 Layer 1: connects as the probeRole-scoped read-only role, SELECT-only
-- on the probeTables allowlist (public.daily_march_ledger). D14 question 4
-- (D11 review): this SELECTs only cohort_day and op — no sales_order_id, no
-- forecast_order_id, no totes, nothing that could carry a row identifier
-- into a string field.
--
-- Output: exactly one VALUE-OBSERVATION line and exactly one VALUE-FRESHNESS
-- line (D14's closed allowlist — score.mjs discards everything else). Run
-- with `psql ... -t -A -q` (value-check-gate.sh's run_probe_sql_readonly) so
-- these two lines are the only bytes on stdout.
WITH qualifying AS (
    SELECT cohort_day
    FROM public.daily_march_ledger
    WHERE op = 'fulfillment' OR op LIKE 'consume!_%' ESCAPE '!'
), weeks AS (
    SELECT DISTINCT date_trunc('week', cohort_day) AS wk FROM qualifying
), obs AS (
    SELECT
        'VALUE-OBSERVATION ' || jsonb_build_object(
            'metric', 'auto_settled_writes_since_launch',
            'value',  (SELECT count(*) FROM qualifying),
            'n',      (SELECT count(*) FROM weeks),
            'unit',   'writes',
            'window', jsonb_build_object(
                'from', to_char((SELECT min(cohort_day) FROM qualifying), 'YYYY-MM-DD'),
                'to',   to_char((SELECT max(cohort_day) FROM qualifying), 'YYYY-MM-DD')
            )
        )::text AS line
), fresh AS (
    SELECT
        'VALUE-FRESHNESS ' || jsonb_build_object(
            'source', 'daily_march_ledger',
            'asOf',   to_char((SELECT max(cohort_day) FROM qualifying), 'YYYY-MM-DD')
        )::text AS line
)
SELECT line FROM obs
UNION ALL
SELECT line FROM fresh;
