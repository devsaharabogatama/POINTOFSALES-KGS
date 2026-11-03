# POS Return Invoice 0951 FIFO Exhaustion Audit (2026-11-02)

## Classification and observed failure

- Classification: `READ_ONLY_AUDIT`.
- Invoice: `INV-20261101-0000000951`.
- UI offered five units as returnable, but direct Retail confirmation returned
  `SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED`.
- No Product, schema, database data, fixture, assertion, or deployment was
  changed by this diagnosis.

## Proven active call chain

1. `public.get_pos_returnable_sales(...)` in migration `20260829110000`
   calculates visible remaining quantity from the source sold/dispatched
   quantity minus quantities on `POSTED` Return documents.
2. It does not check remaining source `sale_fifo_allocations` or
   `negative_stock_sale_allocations` when presenting a line as returnable.
3. `public.submit_pos_sales_return_with_delivery_fee(...)` in installed
   migration `20261102100000` saves the Retail Return and calls
   `private.acp5h_post_sales_return_core(...)` atomically.
4. The posting core iterates only `sale_fifo_allocations`, subtracts prior
   `sales_return_fifo_restorations`, and raises
   `SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED` if positive FIFO cannot cover the
   physical Return quantity.
5. The current Return posting core has no branch that restores the
   `negative_stock_sale_allocations` lineage.

## Production diagnosis result

- The error is a Stock/FIFO source-lineage failure, not a Transfer-metadata
  failure and not a browser required-field failure.
- The user-provided SELECT-only output proves the exact row-level cause:
  `NEGATIVE_STOCK_SOURCE_NOT_RESTORED_BY_CURRENT_RETURN_CORE`.
- Exact lineage for `Daging Burger Sapi`:
  - sold/returnable/visible remaining: `5`;
  - required base quantity: `5`;
  - positive FIFO allocated/remaining: `0 / 0`;
  - negative-stock shortage/replenished: `5 / 0`.
- Therefore this Sale was fully posted from negative stock and has no positive
  FIFO allocation that the current Return core can restore. Prior Return
  exhaustion and incomplete positive FIFO are ruled out for this invoice.
- The UI/backend mismatch is proven: visible returnable quantity alone is not
  sufficient evidence that a physical Return is postable through current FIFO.

## Diagnostic and next gate

- Diagnosis is complete; rerunning it is unnecessary unless source data changes.
- A Product fix must define how a physical Return reverses an unreplenished
  negative-stock allocation: stock inbound, provisional HPP reversal,
  outstanding negative quantity reduction/reconciliation, later replenishment
  compatibility, exact retry, and Return reversal/correction.
- Any implementation requires a new Phase A impact audit and SOP Gate covering
  Stock, FIFO/HPP, Finance, retry, old data, Retail, Backoffice, and mixed
  positive-FIFO plus negative-stock Sales. Hiding this Sale from the UI would
  only conceal a legitimate Return and is not an acceptable correction.
