# Opening Balance direct-entry impact map — 2026-10-29

## Outcome

Provide one Company-scoped Backoffice workspace for Finance to prepare an
opening balance without CSV/XLSX. The document contains ordinary GL lines and
one aggregate AR/AP balance per Customer/Supplier, is balanced before submission, and is posted by
an authorized approver as one canonical `OPENING_BALANCE` journal.

This is a local implementation package. It does not authorize a Production
migration or deployment.

## Evidence and database state

- `FINANCE_CORE_ACCOUNTING_SPEC.md` sections 7.1–7.2 approve a Finance Draft,
  Company Admin approval/posting, balanced posting, and reversal/replacement.
- `20260810180000_g6_phase2_tenant_safe_journal_foundation.sql` defines
  `finance_journals`, `finance_journal_lines`, the `OPENING_BALANCE` journal
  type, period/status guards, party dimensions, and immutable POSTED rows.
- `20260919120000_manual_finance_journal_runtime.sql` defines the active
  Finance capability and journal-line snapshot guards reused by this workflow.
- `20260827100000_finance_customer_receipt_ar_foundation.sql` and
  `20260911160000_backoffice_sales_payment_collection_runtime.sql` prove that
  existing Customer Receipt allocations only accept Retail or Backoffice
  invoices.
- `20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql` and
  `20260807150000_g5_phase14_supplier_payment_foundation.sql` prove that the
  existing AP/payment tables are receipt-matched operational documents.
- Production evidence returned by the user on 2026-10-29 proves the KGFF
  master/Finance clone is installed and opening business rows are still zero.

New migration `20261029100000` state is `NOT_INSTALLED` by definition in the
repository. Production object/ledger state for that new version remains
`BELUM TERBUKTI` until the SELECT-only preflight is run by the user.

## Impact map

### Direct impact

- new opening document, line, and audit tables;
- transactional Draft/save/submit/post/cancel RPCs;
- one Backoffice API route and one Finance workspace component;
- posting creates one balanced `finance_journals` row plus canonical journal
  lines with Customer/Supplier dimensions.

### Downstream impact

- Trial Balance, GL, P&L and Balance Sheet include the posted journal through
  the existing POSTED-journal readers;
- AR/AP detail is retained as posted per-party opening lines and can be reconciled to the
  same journal/account/party dimensions;
- historical invoice numbers, dates, due dates, and transaction history are
  intentionally not imported, following the Finance cutover decision;
- Opening Stock remains a separate source and must not be re-entered in this
  document. The Inventory and Opening Clearing accounts are visible for
  reconciliation but Inventory lines are rejected here.

### Explicitly unchanged

- Product stock, FIFO, reservation, cashier sessions and POS are unchanged;
- operational Sale, Customer Receipt, Goods Receipt, Supplier Invoice and
  Supplier Payment documents are not fabricated;
- posted operational journals and other Companies are unchanged;
- import/export remains optional and is not required by this UI.

### Regression risks

- double-counting inventory if an Inventory control account is manually used;
- GL/subledger mismatch if AR/AP control accounts are entered as ordinary GL;
- cross-Company party/account references;
- duplicate posting on retry or stale Draft editing;
- posting into a locked/missing accounting period.

The database RPC therefore validates line shape and Company ownership,
requires exact control-account mappings, rejects Inventory and party control
accounts on ordinary GL lines, uses row/advisory locks and idempotency keys,
and refuses non-open periods.

## Current boundary

This first runtime establishes correct opening documents, one balanced journal,
and party-level opening balances. Existing Customer Receipt and Supplier
Payment allocation RPCs are not silently widened in the same change. Their
integration is a separate high-risk consumer change because both currently
have source-specific foreign keys and posting reconciliation. Until that
consumer extension passes its own behavior matrix, an opening AR/AP balance is
visible/reconcilable but cannot be selected by the existing payment dialogs.

Opening Stock reads the current Company-owned `products.cogs` as its default
HPP per Base UOM when a Product is selected. The operator may correct that
value before saving the Draft. A zero default still requires the existing
zero-cost reason; the server continues to validate the submitted value.

## Verification matrix

- create/update Draft without legacy invoice history and exact retry;
- balanced/unbalanced submit;
- stale version rejection;
- cross-Company account/customer/supplier rejection;
- ordinary GL rejection for Inventory/AR/AP control accounts;
- approval permission and maker/approver separation;
- open versus locked accounting period;
- idempotent post retry;
- posted immutability and cancellation only before posting;
- zero Stock/FIFO/Sale/Purchase/Payment effect;
- multi-Company isolation.

## Rollback / forward-fix

Before Production installation, remove the local package normally. After a
Production version is installed it is immutable. Any correction must use a new
forward migration. Posted opening journals are corrected only with the
existing reversal/replacement workflow; tables or ledger rows must not be
deleted.
