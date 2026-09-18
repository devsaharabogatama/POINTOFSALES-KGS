# Retained Retail Return from Backoffice — Compatibility Impact Audit

## Status

`P0 RELEASE DEFECT — DESIGN BOUNDARY LOCKED; IMPLEMENTATION NOT YET LIVE`.

This is not a new business feature. It closes an incomplete Sales-process
cutover: final Retail documents are intentionally retained, but the Office
workspace currently exposes them as read-only history while the only writable
Retail Return path still requires an open Cashier Session.

## Approved outcome

A retained Retail sale that has reached the Customer must be operable from the
Office workspace through the already-approved Backoffice Return flow:

`Return request -> approval -> Warehouse receipt/disposition -> Credit Note ->`
`Finance refund only for excess payment`.

The operator must not switch the Company back to Retail and must not open a
Cashier Session. The original Retail sale, Invoice, payment, dispatch, Stock
Movement, FIFO allocation and Finance history remain the source of truth and
must not be rewritten or replayed.

## Proven root cause

1. `public.get_office_retail_history(uuid)` is explicitly read-only and returns
   retained `sales_headers` rows without a target Office writer.
2. `OfficeRetailHistoryDetail` only links the original Invoice.
3. `public.get_backoffice_sales_return_source(uuid)` accepts only
   `backoffice_sales_orders`.
4. `backoffice_sales_returns.sales_order_id` and its line/Invoice relations are
   hard foreign keys to native Backoffice documents.
5. `public.get_pos_returnable_sales` and the Retail Return save/post chain
   require an open Cashier Session and combine Stock and refund posting in a
   lifecycle that is incompatible with the approved Backoffice flow.
6. The previous cutover acceptance matrix left Return regression after process
   switching open. Therefore migration/build/postflight PASS did not prove this
   scenario.

## Change boundary

### Direct impact

- retained Retail source eligibility and returnable-quantity projection;
- compatibility source/line lineage into the Backoffice Return workspace;
- Backoffice Return UI launch from retained Retail history;
- Warehouse receipt and disposition using original Retail FIFO lineage;
- Retail Invoice snapshot allocation to a source-linked Customer Credit Note;
- Finance refund liability and refund settlement without POS/Cashier Session;
- unified activity/history links.

### Existing paths that must remain unchanged

- new Retail sales and the existing Retail Return RPC/UI;
- native Backoffice SO, Return, Customer Return Receipt, Credit Note and Refund;
- Sales cutover converters and recovery;
- Sales Dispatch/Customer Receipt;
- Purchase, Supplier Receipt, Supplier Return, AP and Supplier Payment;
- existing posted Stock, FIFO, Customer Receipt, payment and Journal rows.

### Data compatibility

- no bulk conversion or backfill of retained Retail documents;
- no synthetic Stock Movement, Receipt, payment or Journal during installation;
- compatibility lineage is created only when a user starts a Return;
- existing posted Retail Returns reduce the remaining returnable quantity;
- a source already converted to a real Office SO is rejected from this path;
- original Retail IDs/numbers remain visible and linked throughout the flow.

## Server-side eligibility

A retained Retail source is eligible only when all conditions hold:

1. active Company matches the source Company;
2. no successful Retail-to-Office target lineage exists;
3. source is not canceled and has Customer-received quantity;
4. requested cumulative quantity does not exceed received quantity minus all
   posted Retail Returns and all non-canceled compatibility Returns;
5. Product, UOM and immutable source snapshots are present;
6. source has no unresolved identity conflict that prevents exact Invoice,
   payment or FIFO lineage.

`DISPATCHED` alone is not proof of Customer receipt. `DELIVERED`/equivalent
Customer-received evidence or a legacy posted sale is required.

## Lifecycle and side effects

| Stage | Stock/FIFO | Invoice/AR | Cash/Bank | Existing source |
|---|---|---|---|---|
| Draft/Submit/Approve | none | none | none | immutable |
| Warehouse RESTOCK | restore exact original cost lineage and On Hand | none | none | immutable |
| Warehouse DESTROY | physical receipt plus linked write-off; no usable On Hand | none | none | immutable |
| Credit Note | none | reduce AR first; create refund liability only for excess | none | immutable |
| Refund | none | consume only posted refund liability | post through Finance method | immutable |

## Concurrency and retry

- serialize by `(company_id, retail_sales_id)` before checking quantity;
- every mutation requires operation UUID, request hash and expected version;
- exact retry returns the original response; changed payload with the same key
  fails;
- stale version, cross-Company source, converted source and cumulative overflow
  fail before any side effect;
- Credit Note/refund caps are checked under the same source lock;
- immutable operation/audit rows record actor, source and before/after state.

## Required nonzero verification matrix

1. legacy posted pickup and delivered shipment;
2. unpaid, partially paid and fully paid source;
3. partial Return followed by a second Return;
4. prior posted Retail Return plus compatibility Return;
5. RESTOCK, DESTROY and split disposition;
6. zero-refund Credit Note, partial refund and full refund;
7. exact retry, payload conflict and stale version;
8. denied role, allowed Sales/Gudang/Finance roles and cross-Company denial;
9. source converted after screen load must fail closed;
10. native Retail Return and native Backoffice Return regression;
11. row/digest reconciliation proving installation changed no legacy business
    transaction.

Zero runtime rows are inventory information, not behavioral proof.

## Production rollout boundary

The repair must be additive and installed database-first. Preflight is
SELECT-only. Migration uses one transaction, a short `lock_timeout`, dependency
fingerprints and no business-row backfill. A lock, dependency drift or ambiguous
Finance/FIFO source aborts the whole migration. Rollback-only behavior runs
before client activation. The old client remains compatible with the additive
database objects; the new client is deployed only after postflight passes.

Final status labels remain separate: `LOCAL READY`, `DATABASE LIVE`,
`CLIENT DEPLOYED`, `SMOKE PASS`, and `UAT PASS`.

## Production preflight finding

The 2026-09-18 Production preflight found 219 eligible sources and 601
returnable lines. Invoice lineage is complete, but all 601 lines lack canonical
`sale_fifo_allocations`. This is a migration blocker for physical receipt: both
the existing Retail Return and native Backoffice Return runtime restore original
cost lineage rather than guessing a current or zero cost. A second SELECT-only
diagnosis must classify surviving per-line requirements/cost and Finance event
evidence before the adapter design can be finalized.

The subsequent diagnosis proved that all 601 lines retain Stock Requirements,
598 lines retain positive line-level FIFO cost and three retain an explicit zero
cost. The aggregate line cost and Finance Event cost both equal Rp911,631,400.
The user approved `LEGACY_AGGREGATE_COST`: prorate the immutable line cost by
returned quantity, preserve an explicit zero where history says zero, and label
the lineage honestly instead of fabricating a missing FIFO batch. A final
SELECT-only qualification verifies single-product or bundle cost assignment and
the original outbound Movement quantities before mutation is authored.

The qualification passed in Production: 601 single-requirement lines, zero
unassignable/cost-mismatch lines, Rp911,631,400 source and assigned cost, and
55,280 base quantity on both requirements and original outbound Movements. The
commercial bridge is therefore allowed to proceed. This does not by itself
authorize physical Receipt or Finance posting; those remain separate guarded
stages.

## Explicitly prohibited shortcuts

- switching Company mode merely to process the Return;
- creating or reopening a Cashier Session for Office processing;
- fabricating an Office SO/Invoice/Receipt as if it were the historical source;
- calling Retail `post_sales_return` from Backoffice;
- resetting Stock or replaying historical FIFO/Finance events;
- relaxing quantity, tenant, permission, version or idempotency guards;
- treating schema/postflight PASS or zero candidate rows as end-to-end proof.
