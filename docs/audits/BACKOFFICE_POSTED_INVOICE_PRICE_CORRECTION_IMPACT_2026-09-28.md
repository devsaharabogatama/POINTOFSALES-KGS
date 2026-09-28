# Backoffice Posted Invoice Price Correction Impact — 2026-09-28

## Approved outcome

- A posted Regular Backoffice Invoice exposes `Koreksi Harga`.
- The user changes product unit prices only. The server supplies the correction
  timestamp/date; no reason or manually selected date is requested.
- The original Invoice, posted Journal, Customer Receipt, Stock, FIFO, COGS,
  quantity, UOM, Product, Customer, SO, Warehouse, discount, tax selection, DP,
  delivery fee, and rounding snapshots remain immutable.
- A positive difference posts a Customer Debit Note journal. A negative
  difference posts a Customer Credit Note journal. The effective Invoice total
  is the original total plus posted price-correction deltas.

## Impact map

### Direct

- Add immutable price-correction header, line, operation, and audit lineage.
- Add a tenant-scoped, optimistic-versioned, idempotent posting RPC.
- Extend Invoice detail/payment read models with effective prices, totals,
  correction history, and price-correction refund liability.
- Extend receivable schedules, Customer Receipt workspace/save/post guards,
  aging, and statement to the same effective Invoice total.
- Add a posted-Invoice price-only editor in Backoffice.

### Downstream

- AR outstanding, Customer Receipt, Finance aging/statement schedules, return
  Credit Notes, gross Revenue, Output Tax, and Customer Refund Liability.
- Existing account functions are reused. This change creates no COA and applies
  no account mapping automatically.

### Explicitly unchanged

- Stock Movement, reservation, FIFO, COGS, Sales delivery/receipt quantity,
  Return quantity, posted Customer Receipts, original Invoice rows, and original
  posted Journals.
- Retail/POS Invoice behavior.

## Runtime rules

1. Only `POSTED` `REGULAR` Backoffice Invoices are eligible.
2. Only original Sales Order product lines are price-editable; accepted-overage,
   DP, deduction, and non-product lines stay immutable.
3. KMS, LSM, and SMS are the only enabled Companies in this rollout.
4. An Invoice that already has a Draft/Posted Return Credit Note is blocked from
   later price correction. A Return created after a price correction values its
   Credit Note from the latest effective price.
5. A single correction cannot mix price increases and decreases. This keeps the
   accounting document unambiguously a Debit Note or Credit Note.
6. All eligible lines must be supplied and the server recomputes DPP and tax
   from immutable Invoice tax snapshots.
7. A decrease cannot make the effective Invoice total non-positive or smaller
   than already-posted Return Credit Notes.
8. A decrease consumes open AR first. Any excess over open AR becomes Customer
   Refund Liability; posted receipts are never rewritten.
   A later increase reduces that Refund Liability first before creating new AR.
9. The correction date is the Company-local date derived from the server
   timestamp. A closed period rolls to the next open period as a prior-period
   adjustment while preserving the original correction date.
10. Exact retry returns the stored response. A changed payload with the same
    operation ID fails. Both the Invoice master version and independent price
    revision are locked and rechecked in the posting transaction.

## Deliberate boundary

- A price decrease exceeding open AR records a visible Customer Refund
  Liability and `REFUND_PENDING` status. This migration does not silently reuse
  the Return-specific Refund document, because that document requires Return
  and Return Credit Note lineage. Cash/bank payout of this new liability remains
  a separate forward feature; the liability is not hidden or netted away.

## Rollout and rollback boundary

- Additive migration `20260928110000`; no historical Journal is rewritten.
- Preflight, rollback-only behavior, and postflight must pass before client
  deployment. Production deployment remains manual.
- After a correction is posted, rollback is forward-fix only; disabling the UI
  does not remove posted accounting history.
