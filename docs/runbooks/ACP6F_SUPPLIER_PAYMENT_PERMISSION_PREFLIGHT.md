# ACP-6F Supplier Payment Permission Preflight

**Gate:** ACP-6F Finance cutover  
**Permission key:** `finance.supplier_payments`  
**Runtime action:** none; diagnostic is SELECT-only

## Purpose

Audit the complete Supplier Payment/AP settlement boundary before enforcement:

- payment header, Invoice allocations, lifecycle, audit, and idempotency;
- Draft/Edit, validation final, and Draft-only cancellation authority;
- narrow Supplier, payable-Invoice, and eligible source-account references;
- AP allocation and invoice-balance reconciliation;
- immutable validated event snapshot and Finance HOLD boundary;
- tenant isolation, browser grants, override integrity, and optional export.

This phase must not alter Supplier Invoice matching, Supplier identity, payment
method master, Journal posting, or final reversal authority.

## Run

Run the complete file:

`supabase/diagnostics/acp_phase6f_supplier_payment_permission_preflight.sql`

Return every `check_name,status,details` row. Do not run selected fragments.

## Interpretation

- `BLOCKER`: stop; dependency, historical data, tenant, account, allocation,
  grant, or canonical runtime is unsafe.
- `REVIEW`: approved boundary that enforcement must implement; it is not an
  automatic failure.
- `SETUP`: expected missing ACP read/hook/export runtime before implementation.
- `PASS`/`INFO`: safe baseline or inventory evidence.

Pay particular attention to `canceled_supplier_payment_with_final_effect` and
`supplier_payment_source_account_integrity`. A VALIDATED payment may not be
canceled through this workflow; correction belongs to guarded append-only
Finance reversal. An explicit source account must belong to the active Company
and be active, postable, and compatible with cash/bank settlement.

## Next Safe Step

Only after every output row is reviewed with no unexplained `BLOCKER`, build
one ACP-6F enforcement slice: composed read, capability guards, source-account
server validation/reference, Backoffice cutover, optional monthly export,
direct-read closure, postflight, rollback-safe behavior, G5 Phase-14 regression,
and closing smoke. Do not enforce Payment Method or Journal permissions in the
same migration and do not release Supplier Payment Financial Events from HOLD.
