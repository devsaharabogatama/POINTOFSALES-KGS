# Sales Export RO Reconciliation — Impact Map

## Objective

Extend the existing Sales Invoice XLSX with separate operational sheets so
commercial history is not mistaken for current replenishment demand.

## Output contract

The existing `Daftar Invoice`, `Detail Produk`, and `Informasi Export` sheets
remain additive-compatible. New sheets are:

1. `Kebutuhan RO Bersih`: current open Retail/Backoffice negative-stock sources,
   excluding reconciled and reversed allocations, with reconstructed active
   Draft RO / active Stock Request / remaining active PO coverage;
2. `Pembatalan Reversal`: canceled Retail stock effects and exact posted Stock
   reversals in the selected effect-date range;
3. `Retur Customer`: posted native Retail Return and Backoffice/retained-Retail
   receipt quantities, separating RESTOCK from DESTROY/no-physical-return.

`Kebutuhan RO Bersih` is a current snapshot across all source dates. It is not
restricted by Invoice date because the current RO may legitimately cover older
unreplenished shortages. The other sheets state their own date basis.

## Impact map

Direct impact:

- new read-only private reconciliation core and authenticated RPCs;
- Sales Data Exchange API composes the existing Invoice payload with the new
  reconciliation payload in one database snapshot;
- XLSX adds three sheets and explicit metadata.

Downstream impact:

- Operations may reconcile active RO/PO coverage from the dedicated sheet;
- canceled/reversed/returned quantities no longer require manual inference from
  gross Invoice lines;
- historical Invoice export remains unchanged and must not be treated as Stock
  movement truth.

No mutation:

- Invoice, SO, Return, Stock, FIFO, RO, Stock Request, PO, Receipt, Payment,
  Financial Event, Journal, Cashier Session, and audit histories are read-only.

## Canonical boundaries

- Retail open shortage: `reconciled_at IS NULL` and `reversed_at IS NULL`;
- Backoffice open shortage: `reconciled_at IS NULL`;
- Draft daily RO counts only while batch is `DRAFT` and line is not `ORDERED`;
- after RO conversion, only remaining active PO quantity counts;
- active Stock Request counts only quantity not allocated to an active PO;
- `RESTOCK` reduces physical Stock need; `DESTROY`, Credit Note, and Refund do
  not add Stock;
- source-to-procurement coverage is an explicit FIFO-by-time reconstruction,
  not persisted RO-to-SO lineage.

## Risks and controls

- Date semantics are exposed per sheet instead of silently mixing Invoice date
  and Stock-effective date.
- Quantity is base-UOM throughout the RO reconciliation sheet.
- Source/coverage arithmetic and exact KMS/LSM/SMS Company scope are postflight
  gates. The sheet is source reconciliation; the canonical RO runtime remains
  the authority that calculates the final product-level candidate.
- Existing export RPC remains untouched; the new RPC is additive.
- Client deployment must follow successful database rollout.

## Status gates

- LOCAL READY requires lint/typecheck/static SQL checks.
- DATABASE LIVE requires preflight, migration, behavioral test, and postflight.
- CLIENT DEPLOYED requires the Backoffice build deployment.
- SMOKE PASS requires authenticated XLSX download for KMS, SMS, and LSM.
- UAT PASS requires Operations to reconcile at least one RO containing a
  cancellation/reversal and one Return.

## Rollback / forward-fix note

The migration is additive and read-only. Before client deployment it can be
rolled back by dropping only
`public.export_sales_stock_reconciliation(date,date)` and
`public.export_sales_documents_with_reconciliation(date,date)` plus
`private.get_sales_export_ro_reconciliation_core(uuid,date,date)`, then removing
the exact `20260928100000` ledger row. After the client starts calling the new
RPC, prefer a forward fix: dropping the RPC first would make every Sales export
fail. No business rows require reversal because the migration does not mutate
Invoice, Stock, Return, RO/PO, or Finance data.
