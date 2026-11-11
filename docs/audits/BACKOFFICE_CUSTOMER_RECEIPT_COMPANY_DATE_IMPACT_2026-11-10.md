# Backoffice Customer Receipt Company-Date Impact Audit

Date: 2026-11-10  
Classification: `SCHEMA_OR_MIGRATION_CHANGE`  
Scope: local development only; production is not accessed or changed.

## Expected business outcome

A Backoffice Finance user may record a Customer Receipt dated on the current
business date of the active Company. The same Company date already governs
Delivery receipt and other Backoffice operational documents. A Receipt must
still reject dates after that Company date.

## Proven active call chain

1. Invoice payment UI posts to
   `backoffice/src/app/api/sales/backoffice-invoices/[id]/payments/route.ts`.
2. That route calls `public.register_backoffice_sales_invoice_payment`.
3. The wrapper calls `public.save_customer_receipt_allocated_draft` and then
   the canonical Receipt post runtime.
4. Finance Receipt workspace also calls either
   `public.save_customer_receipt_allocated_draft` or
   `public.save_customer_receipt_open_credit_draft`; the open-credit wrapper
   delegates to the same allocated saver.
5. Active local saver digest is
   `f77bd1009a5c15f063748981ad48e77d`, contains exactly one
   `p_receipt_date > current_date` guard, and has no Company-date variable.

Defining sources:

- base saver: `20260911160000_backoffice_sales_payment_collection_runtime.sql`;
- active outstanding patches:
  `20260919110000_customer_receipt_credit_note_outstanding_alignment.sql` and
  later Invoice/AR migrations;
- open-credit and Invoice-payment wrappers:
  `20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql`;
- Delivery Company-date guard:
  active `private.receive_backoffice_sales_delivery_core`.

## Reproduced local evidence

- PostgreSQL `current_date`: `2026-11-09`.
- LOCALBO Company timezone: `Asia/Jakarta`.
- LOCALBO Company clock date: `2026-11-10`.
- Delivery dispatched on Company date rejects acceptance on UTC date as
  `CUSTOMER_RECEIPT_DATE_BEFORE_DISPATCH`.
- Customer Receipt dated on Company date rejects it as
  `CUSTOMER_RECEIPT_DATE_FUTURE` because the saver uses UTC `current_date`.

The two guards therefore have no common valid date during this timezone window.

## Impact map

Direct impact:

- only `public.save_customer_receipt_allocated_draft` date validation changes;
- `save_customer_receipt_open_credit_draft` and
  `register_backoffice_sales_invoice_payment` inherit the correction through
  their existing delegation.

Downstream impact:

- Backoffice Invoice payment;
- Backoffice Customer Receipt partial/full allocation;
- residual Receipt open credit;
- Retail Tempo allocation handled by the same saver.

Explicitly unchanged:

- Receipt amount, Customer, payment method, evidence, allocation, outstanding,
  Journal, permission, idempotency, and posting validation;
- POS direct payment and cashier session;
- SO, Dispatch, Invoice, Return, Stock, Reservation, FIFO/HPP;
- Customer Balance and Credit Note actions;
- historical documents and Journals.

## Compatibility, concurrency, retry, rollback

- No table or data backfill is required.
- Existing Draft/Posted Receipts are not rewritten.
- The function remains transactional and uses its existing row locks and
  version/idempotency behavior.
- Migration is guarded by ledger, active digest, exact single anchor, Company
  timezone validity, and zero active Finance/offline work.
- Rollback policy is forward-fix; production migration is not authorized in
  this local phase.

## Regression matrix

| Case | Expected |
|---|---|
| Company date equals UTC date | unchanged, accepted |
| Company date one day ahead of UTC | Company date accepted |
| Date after Company date | rejected |
| Partial Receipt allocation | one allocation plus residual open credit |
| Invoice payment wrapper | same canonical Receipt/Journal lineage |
| Exact retry / changed retry | unchanged |
| Cross Customer/Company | rejected |
| Retail/Stock/FIFO | zero additional effect |
| Historical Receipt/Journal | unchanged |

Unknown affecting design: `NONE`.

## Production regression evidence after parity rollout

The first cumulative Task 3 regression after Production parity installation
stopped at `TEST_FAILED: future Company Receipt date accepted`. The transaction
rolled back. Repository tracing proves this is not evidence that reversal parity
changed Receipt behavior: parity changes the shared Credit Note allocation
consumer only and does not replace the Customer Receipt saver.

The failing assertion depends on forward migration `20261110110000`, but the
Task 3 test precondition previously required only `20261105110000`. Production
had not installed `20261110110000`, so the harness entered a Company-date
assertion against the older UTC-date runtime. Classification:
`TEST_HARNESS_FIX + missing PRODUCT dependency`.

The harness now requires both migration ledgers before any fixture write. The
future Company-date assertion is unchanged. Production parity remains installed,
but its cumulative regression gate is open until the Company-date preflight,
migration, postflight, and the same Task 3 regression pass in the documented
order.

Local Docker rerun after the harness correction is `PASS`. It executes the
unchanged future-date assertion plus Receipt allocation, Journal, retry,
audit/privilege, and zero Retail/Stock/FIFO checks; every fixture write rolls
back. This is local harness evidence only and does not classify the missing
Production migration as installed.

## Installed-state Production fixture correction

After the Company-date migration and postflight passed in Production, the Task
3 regression again stopped at the future-date assertion. The Product runtime was
not disproven. The historical Production fixture assigned `v_receipt_date` from
`greatest(invoice.invoice_date, period.start_date)` and then tested
`v_receipt_date + 1`. That value can still be before the active Company date and
is therefore valid. Local had selected its newly created fallback Invoice, so
the same expression happened to mean tomorrow and concealed the harness defect.

Classification: `TEST_HARNESS_FIX`. The negative assertion now derives
`v_company_today` from the selected active Company's proven timezone and submits
exactly `v_company_today + 1`. The ordinary valid Receipt continues using the
period-compatible `v_receipt_date`; no Product assertion, migration, schema, or
Production data is changed.

The corrected future-date case then passed far enough in Production to expose a
second installed-state harness failure at the combined Task 2 audit-lineage
assertion. That assertion scans all historical Company audit rows. Task 5 later
added nullable `effective_date` to `ar_open_item_allocations`, while historical
Task 2 JSON snapshots retain their original row shape. Exact comparison with
the current `to_jsonb(allocation)` can therefore report schema evolution as data
corruption. A SELECT-only diagnosis now separates missing entity, actor mismatch,
raw snapshot mismatch, legacy missing key, and mismatch after adding only the
known compatibility key. No assertion is changed until that Production output
classifies the actual failing branch.

Production diagnosis proves the branch conclusively. Registry and operation
entities, actors, and snapshots have zero mismatch in KMS, LSM, and SMS.
Allocation actors/entities also have zero mismatch. All 383 allocation rows
fail only the raw JSON shape comparison (`KMS 134`, `LSM 192`, `SMS 57`), all
383 snapshots predate the nullable `effective_date` key, and mismatch becomes
zero when only that known nullable key is normalized. This is a
`TEST_HARNESS_FIX`; it is not a Product, data, trigger, or migration failure.

The compatibility assertion must remain strict for every historical key and
must normalize only the proven schema-evolution key: compare the stored snapshot
to the current allocation row with `effective_date` removed only when the stored
snapshot itself does not contain that key. Missing entity, actor mismatch, any
other field mismatch, and mismatch on snapshots that already contain
`effective_date` remain failures. The same invalid raw comparison exists in the
Task 2 behavior and Task 2 postflight, so all three harness consumers must be
corrected together; Product runtime and immutable migration files remain
untouched.

Local verification of the corrected harness is deliberately scoped. The
focused read-only compatibility behavior passes legacy-key, current-key, and
non-schema-mismatch cases. Task 3 rollback behavior passes through Receipt,
Journal, retry, audit/privilege, and zero Retail/Stock/FIFO assertions. Task 2
postflight reports its audit contract PASS, but its separate allocation
contract reports one pre-existing local over-allocation; therefore the complete
postflight is not claimed PASS. Task 2 behavior is locally fixture-blocked
because the non-identical local database has no authenticated Finance VIEW actor
with AR items. Production remains the only authority for the rerun of the exact
failing Task 3 regression.

Production rerun of the corrected Task 3 behavior is now `PASS`. It proves the
Company-date denial, valid Receipt date, partial allocation/residual credit,
single Cash/Bank-to-AR Journal, append-only registration, read residual,
exact/changed retry behavior, Invoice payment entry point, Task 2 audit lineage,
direct-table denial, and zero Retail/Stock/FIFO effect on the Production state;
all fixture writes rolled back. This closes only Task 3 cumulative regression.
Task 4/5/6 parity regressions, closing parity postflight, authenticated smoke,
and UAT remain separate pending gates.
