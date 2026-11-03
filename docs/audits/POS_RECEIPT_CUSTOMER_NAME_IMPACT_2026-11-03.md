# POS receipt Customer name impact audit

Date: 2026-11-03  
Classification: `PRODUCT_BEHAVIOR_CHANGE`  
Phase: A complete

## Expected outcome and source of truth

The printed POS receipt must display the Customer name selected for the Sale.
The formal Sales Invoice already displays the snapshotted Customer under
`Ditagihkan kepada`; this task changes only the thermal/browser receipt.

## Active call chain and identifiers

- Online print: `pwa/src/App.tsx::handlePrint` calls
  `pwa/src/lib/printer.ts::ESCPOSPrinter.print`.
- Online Customer source: `receiptCustomerName`, captured before the Sale form
  resets and already displayed in the receipt modal.
- Offline print: `handlePrintOfflineSlip` calls the same printer and has the
  authoritative snapshot at `offlineSlip.preview.customerName`, defined in
  `pwa/src/lib/offlineCheckout.ts`.
- Thermal renderer: `ESCPOSPrinter.print` builds ESC/POS text.
- Browser fallback: `ESCPOSPrinter.openPrintableReceipt` builds the 80mm HTML.
- Formal Invoice: `openSalesInvoicePrint` already reads
  `snapshot.customer.name`; it is preserved.

## Impact map

- Direct: add required `customerName` to the internal `ReceiptData` type; pass
  it from both online and offline callers; render it in ESC/POS and browser
  fallback metadata.
- Downstream: Bluetooth and browser printing receive one additional text row.
- Preserved: Sale mutation, receipt snapshot, Customer selection, pricing,
  Payment, cashier session, Stock, Reservation, FIFO/HPP, Finance, audit,
  Invoice/SJ, Return, Backoffice, online/offline transaction semantics.
- Compatibility: both current callers are updated atomically; no public API,
  database, migration, or historical data changes.
- Security: browser output continues to use `escapeHtml`; ESC/POS Customer text
  must normalize embedded CR/LF so user data cannot inject extra printer rows.
- Concurrency/idempotency/retry/rollback: not applicable; print is a read-only
  client side effect and transaction identifiers are unchanged.

## Test matrix

- TypeScript/lint proves both required callers provide `customerName`.
- Static contract proves both ESC/POS and browser receipt render Customer.
- Online named Customer and Walk-In use the captured display name.
- Offline receipt uses the immutable offline preview Customer name.
- Formal Invoice remains unchanged.

## Unknown affecting design

None. All identifiers and both callers are present in repository source.
