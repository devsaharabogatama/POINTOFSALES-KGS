# ACP-4D Stock Read Models Preflight

Status: SELECT-ONLY READY; live output pending.

## Outcome

Audit the next ACP-4 Inventory slice before any enforcement:

- `inventory.stock_real` controls the composed Stock Real/reporting page,
  including FIFO valuation and low-stock context;
- `inventory.stock_movements` controls the immutable Kartu Stok ledger;
- operational workflows may retain narrowly scoped on-hand references only
  after authorizing their own permission key;
- no client `purpose` flag may bypass either reporting permission.

This preflight does not change catalog status, grants, RLS, data, API, or UI.

## Run

Run the complete file in Supabase SQL Editor:

`supabase/diagnostics/acp_phase4d_stock_read_models_preflight.sql`

Return every row. Stop before migration design if any `BLOCKER` appears.
`REVIEW` and `SETUP` are expected design/runtime work, not permission to ignore
them.

## Review criteria

The next implementation may be designed only when:

1. ACP-4B and ACP-4C dependencies exist;
2. both keys remain customizable `SHADOW` before cutover;
3. balance, movement, FIFO, latest snapshot, tenant references, and browser
   write boundaries pass;
4. current overrides and live row volume are known;
5. Stock Real stops shipping the complete Movement ledger and raw FIFO layers
   to the browser merely to compute summaries;
6. Stock Real and Movement exports receive distinct server-side permission
   checks;
7. checkout/Purchase/Transfer/Adjustment/Opname compatibility remains outside
   the reporting permission and is regression-tested.

## Explicit boundary

This phase does not change stock quantity, FIFO, movement history, minimum-stock
policy, negative-stock behavior, checkout, Purchase receipt, or any final
document workflow. It only prepares read/report permission separation.
