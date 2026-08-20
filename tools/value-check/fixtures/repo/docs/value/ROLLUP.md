## repo
coverage: NOT-ESTABLISHED (no ratified feature inventory)
generated 2026-07-31T13:59:25Z from 1 claim / 1 verdict · bodySha256 5af7798ef6fe9f8baa36251f99f9da72c32c647bd9b7635294a5499095bfeae5

### PASS — daily-march auto-settlement
The daily march settles CSP fulfillments and CP/P consumption automatically, writing one ledger row per real settle or consume; before it shipped, each settle was a manual reconciliation action.
  auto_settled_writes_since_launch — target ≥ 50 by 2026-09-01, observed **63**
  measured 2026-06-25 → 2026-07-29 (n=5, minN=4) · source daily_march_ledger, 2d old
  direct-measure · claim md-daily-march-autosettle-v1 · probe @b2f8b479 · reviewed by openai:gpt-5.5, gemini:gemini-3.1-pro-preview
