# Backoffice E2E and Form Requiredness Audit — 2026-10-29

## Outcome

Audit lokal menambahkan regression contract yang membandingkan field mutasi
Backoffice dengan parser/API aktifnya. Audit ini tidak mengakses Production,
tidak mengubah schema/data, dan tidak mengubah flow bisnis.

Status: `LOCAL AUDIT / 10 PASS / 2 FAIL / PRODUCT UI FIX PENDING`.

## Impact map

- Direct impact: label dan requiredness form Inventory, Purchase, Sales, dan
  Finance.
- Downstream impact yang diaudit: payload API, parser server, conditional proof,
  lifecycle cancellation/rejection, dan audit reason.
- Tidak ada dampak Stock, Reservation, FIFO, Payment, Cashier Session, Finance
  Event/Journal, atau data lama karena audit ini read-only terhadap runtime.
- Risiko regression: field audit yang benar-benar wajib dapat keliru dibuat
  opsional; sebaliknya metadata opsional dapat terlihat wajib dan menghambat
  operator.
- Belum terbukti: authenticated browser E2E dengan fixture database untuk setiap
  mutation dan role. Local browser saat ini hanya membuktikan public boundary,
  mocked Retail flow, dan source/runtime contracts.

## Identifier evidence

Semua field di bawah diambil dari komponen UI dan parser/API aktif, bukan dari
nama rekaan:

- Stock Adjustment: `StockAdjustmentView.tsx` dan `stock-adjustment.ts`.
- Stock Transfer: `StockTransferView.tsx` dan `stock-transfer.ts`.
- Opening Stock: `OpeningStockView.tsx` dan `opening-stock.ts`.
- Goods Receipt: `GoodsReceiptView.tsx` dan `goods-receipt.ts`.
- Supplier Order: `SupplierOrderView.tsx` dan `supplier-order.ts`.
- Purchase Return: `PurchaseReturnApprovalView.tsx` dan `purchase-return.ts`.
- Invoice/Customer Receipt: `BackofficeSalesInvoiceView.tsx`,
  `backoffice-sales-invoice.ts`, dan Customer Receipt API routes.
- Supplier Payment: `SupplierPaymentView.tsx` dan `supplier-payment.ts`.
- Guarded lifecycle reasons: Sales cutover, Sales document cancellation, Sales
  Return, Supplier Invoice cancellation, Cash Deposit review, Deposit Variance,
  Finance Operations, Delivery cancellation, Customer Balance, Expense, dan
  Manual Journal.

## Proven contracts that pass

1. Adjustment document/line notes are optional; reason is required per line;
   manual gain-cost override reason is conditional.
2. Transfer document/line notes are optional.
3. Opening Stock notes are optional; zero-HPP reason is required only when HPP
   is exactly zero.
4. Purchase Return reason is required; notes are optional; reject/cancel reasons
   are available in the UI.
5. Conditional payment proof on Backoffice Invoice follows Payment Method
   `proofMode`; reference and notes are optional.
6. Required audit reasons have matching UI input for the guarded transitions
   covered above. No server-required reason without a visible input was found in
   this audited set.

## Proven UI contract failures

The parser accepts all ten fields below as optional, but the UI does not label
them as optional or uses ambiguous wording:

1. Goods Receipt — Supplier delivery number.
2. Goods Receipt — notes.
3. Supplier Order edit — notes.
4. Backoffice Invoice draft — notes.
5. Customer Receipt — reference.
6. Customer Receipt — HTTPS evidence link.
7. Customer Receipt — notes.
8. Supplier Payment — reference number.
9. Supplier Payment — evidence label says `Wajib HTTPS`, although the field
   itself is optional and HTTPS is required only when a value is supplied.
10. Supplier Payment — notes.

These are UI clarity defects, not database-required fields. No mutation or
schema change is required to correct them.

## Automated evidence

Command:

```powershell
cd qa-e2e
npm.cmd test
```

Result: `12 total; 10 passed; 2 failed`. The two failures are deliberately kept
as product-contract failures and group the ten exact label mismatches above.
The existing public boundary, mocked KGFF Retail flow, navigation/rendering,
Retail runtime, POS operational workspace, and guarded Opening Stock tests all
remain PASS.

## Next safe step

Classify the ten labels as a narrow `PRODUCT UI FIX`, change wording only, then
rerun the same 12-test suite. Do not relax server validation for actual business
reasons, conditional evidence, quantity, account, stock, or lifecycle fields.
Authenticated database E2E remains a separate staging/UAT gate.
