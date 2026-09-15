# Backoffice WALK-IN Invoice Payment Fix

Status: **LOCAL READY**  
Target: isolated Development `fkywtxucmyjvpwdiqpix` only. Production/staging are out of scope.

## Root cause and boundary

Backoffice allowed the system Customer `WALK-IN` through SO, delivery and posted
Invoice. The canonical allocated Customer Receipt saver rejected every system
Customer before inspecting that the receipt was fully tied to that posted
Backoffice Invoice. The Invoice UI therefore failed with
`CUSTOMER_RECEIPT_CUSTOMER_INVALID`.

The forward-fix permits an active system Customer only when every allocation is
`BACKOFFICE_SALES_INVOICE`. It does not permit Retail allocation, unallocated
money, Customer Balance, advance, or a cross-Customer Invoice. Existing source,
outstanding, date, payment-method, permission, period, idempotency and posting
guards remain active.

The client fix separately keeps an expected server rejection inside the payment
modal instead of rethrowing it into the Next.js runtime overlay.

## Impact map

- Direct: allocated Customer Receipt customer validation and Invoice payment UI error handling.
- Downstream: Backoffice Invoice allocation, AR installment reconciliation, Receipt Financial Event and Debit Kas/Bank–Credit AR journal.
- Unchanged: POS/Retail payment, Customer Balance, Stock, Reservation, FIFO/HPP,
  DO/SJ, Invoice value/date/template, Cashier Session and document history.
- Retry/concurrency: existing Invoice operation lock, request snapshot and exact-retry contract are retained.
- Historical compatibility: no existing Receipt, Invoice, allocation, event or Journal is updated.

## Mandatory manual order

Run each SQL file in full:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_system_customer_payment_preflight.sql)
2. [Migration](../../supabase/migrations/20260912139000_backoffice_sales_system_customer_payment_fix.sql)
3. [Postflight](../../supabase/diagnostics/backoffice_sales_system_customer_payment_postflight.sql)
4. [Behavioral test](../../supabase/tests/backoffice_sales_system_customer_payment_behavior.sql)
5. Run Postflight again.

Stop on SQL error, `BLOCKER`, or `FAIL`. Do not rerun the migration after its
ledger row exists. The behavior uses a real unpaid posted WALK-IN Backoffice
Invoice but all payment, allocation, Finance and context writes are rolled back.

## Completion states

- LOCAL READY: file/static verification complete.
- DATABASE LIVE: migration applied to isolated Development.
- BEHAVIOR/POSTFLIGHT PASS: pending user SQL output.
- CLIENT SMOKE/UAT: pending after restarting the local client and retrying the same Invoice.

Rollback is not required because no historical row is rewritten. Before any
system-customer Receipt is posted, a forward migration could restore the exact
old guard. After use, preserve immutable Receipt/Journal history and correct only
through an additive forward-fix.
