# Backoffice AR Workspace Split Impact Audit — 2026-11-11

## Classification and expected outcome

- Task classification: `PRODUCT_BEHAVIOR_CHANGE` (Backoffice UI/navigation only).
- Expected outcome: `Penerimaan Customer` retains receipt entry, aging, statement,
  and receipt history; a separate `Open Credit Customer` menu exposes AR open
  items, manual allocation/refund/balance actions, and reversal without requiring
  users to scroll through the complete aging table.
- No database, Finance posting, stock, FIFO, payment, or historical-data mutation
  is authorized by this task.

## Source of truth and active execution path

### Navigation and permission

- View identifiers, labels, module membership, and permission mapping:
  `backoffice/src/lib/navigation-catalog.ts`.
- Authenticated navigation capabilities:
  `backoffice/src/app/api/me/navigation-catalog/route.ts`.
- Existing permission authority for both workspaces:
  `finance.customer_receipts`, defined by
  `supabase/migrations/20260827100000_finance_customer_receipt_ar_foundation.sql`.
- Page renderer and capability handoff: `backoffice/src/app/page.tsx`.

The new navigation identifier will reuse the existing
`finance.customer_receipts` capability profile. It does not create or infer a
new server permission.

### Receipt workspace

`Penerimaan Customer` -> `CustomerReceiptView` receipt mode ->
`/api/finance/customer-receipts` and report/export routes -> active Customer
Receipt/open-invoice RPCs. Receipt Draft/Post/Cancel behavior remains unchanged.

### Open-credit workspace

`Open Credit Customer` -> `CustomerReceiptView` open-credit mode ->
`/api/finance/customer-receipts` read workspace ->
`get_finance_ar_open_items` plus Customer Balance read model. Explicit actions
continue through `/api/finance/ar-open-credit-actions` into the Task 5 RPCs
defined by `20261106100000_backoffice_ar_open_credit_actions.sql`.

## Database and migration state

- Production evidence supplied by the user proves Task 2–6 and parity/company-
  date forward migrations are installed and their stated postflight/rollback
  behaviors passed.
- The current deployed screenshot proves the open-item read model is already
  returned to the client: KMS shows the `Open-item AR` table with Rp0 open
  credit.
- This task has no migration and does not change the installed database state.

## Impact map

### Direct impact

- Add one Finance navigation view: `ar-open-credits` / `Open Credit Customer`.
- Render receipt/report/history content only in the receipt view.
- Render open-item table, action dialog, and operation history only in the new
  open-credit view.
- Keep the existing workspace/API load so action eligibility remains server-
  derived.

### Downstream impact

- Navigation catalog API returns two views backed by the same permission.
- Breadcrumb and module launcher use the new catalog label automatically.
- Existing Apply, Refund, Convert, Use Balance, and Reversal requests retain the
  same API/RPC payload and idempotency boundary.

### Explicitly preserved

- Customer Receipt Draft/Post/Cancel and overpayment recording.
- AR Aging, Customer Statement, and Excel export.
- Credit Note eligibility: action buttons remain conditional on actual residual,
  Customer, Company, policy, and target Invoice state.
- Invoice, Return/Credit Note, Cash/Bank, Customer Balance, Journal, Finance
  Event, audit, tenant, role, stale-version, retry, and concurrency behavior.
- POS Retail, Backoffice Sales/Dispatch, Stock, Reservation, FIFO/HPP, and
  historical rows.

## Compatibility and regression risk

- Existing bookmarks are in-app view state rather than public routes; the
  original `customer-receipts` identifier remains valid.
- A second view must have an explicit page render branch or the runtime-contract
  test must fail.
- Both views must receive capabilities resolved from the same server permission;
  no client-side privilege widening is allowed.
- Open-credit actions must not remain duplicated at the bottom of the receipt
  workspace.
- Receipt forms/modals must not render in the open-credit workspace.

## Concurrency, idempotency, rollback, and forward fix

- No mutation contract changes. Existing server locks, operation UUIDs, expected
  residuals, stale checks, and append-only reversal remain authoritative.
- Rollback is a client forward-fix reverting the additional view/mode split; no
  database rollback is applicable.

## Test matrix

1. Navigation catalog exposes both views with identical permission key and
   capability profile.
2. Every declared view has an active renderer.
3. Receipt view contains aging, receipt creation/history, and excludes the
   open-item section.
4. Open-credit view contains open-item actions/history and excludes receipt
   creation, aging, and receipt document history.
5. Apply/Refund/Convert/Use Balance/Reversal labels and API/RPC mappings remain
   present and unchanged.
6. Customer Balance actions remain hidden when policy/balance conditions fail.
7. TypeScript, targeted ESLint, focused UI contracts, navigation runtime
   contract, and production build pass.
8. Authenticated browser smoke verifies both Finance menu entries and confirms
   no action button is shown when KMS open credit is Rp0.

## Unknowns affecting design

`NONE`. The requested split changes presentation only and reuses proven
navigation, permission, workspace, and mutation contracts.

## Local implementation evidence

- Focused Backoffice UI contract: `6/6 PASS`.
- Focused AR Playwright contract: `3/3 PASS`.
- Declared-view/navigation renderer contract: `1/1 PASS`.
- Targeted ESLint: PASS.
- TypeScript `--noEmit`: PASS.
- Next production build: PASS.
- The combined static suite additionally exposed one unrelated pre-existing KGFF
  Sample assertion expecting Return text in a Sale-only behavior fixture. It is
  outside this Finance UI task and was not weakened or patched.

Status: `AUDIT COMPLETE`, `LOCAL READY`. Client deployment, authenticated
Production smoke, and user UAT remain unproven.
