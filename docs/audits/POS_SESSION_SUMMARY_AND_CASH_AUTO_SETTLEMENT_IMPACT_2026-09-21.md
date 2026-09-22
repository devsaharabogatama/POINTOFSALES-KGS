# POS Session Summary and Cash Auto-Settlement Impact Audit

**Date:** 2026-09-21
**Status:** UI `CLIENT DEPLOYED / PUBLIC LOAD PASS`; Cash workflow `AUDITED / NOT IMPLEMENTED`
**Scope:** Retail POS/PWA only. Backoffice Sales workflow is not changed.

## UI follow-up 2026-09-22

- Product name, unit price, quantity, and line total use separated labeled
  regions so Catalog and Compact cards remain readable.
- The final/estimated total is rendered by one shared sticky Cart footer in both
  layouts. Catalog keeps the payment-modal launcher there; Compact keeps its
  existing adjacent checkout panel.
- The footer reads the existing `paymentDue` or `fallbackSubtotal`; no pricing,
  checkout, Payment, Session, Stock/FIFO, or Finance mutation changed.
- Status: `LOCAL READY`; client deploy and authenticated visual UAT pending.

## Customer permission correction 2026-09-22

- The first Production client used a direct `customers` read for Summary labels.
  ACP-5A correctly rejected it for Cashier, causing the entire Summary load to
  fail.
- The consumer now uses canonical `get_pos_customer_references()` instead. The
  RPC already enforces active Company and an OPEN session for the actor.
- No Customer-table grant, RLS policy, schema, transaction row, or Finance/Stock
  behavior changes. Authenticated Cashier smoke remains mandatory after deploy.

## Approved outcome

1. Catalog Cart shows unit price and line total without opening Edit.
2. One Session Summary modal shows Cash, every recorded non-Cash leg regardless
   of Finance verification status, total recorded payment, session transactions,
   Product/quantity detail, and expandable canonical document detail.
3. Cash is accepted operationally by the Cashier and should not require manual
   Finance verification. Transfer and other non-Cash methods remain in Finance
   verification.
4. Existing global searchable-select rule remains unchanged.
5. Catalog checkout moves into a modal so payment detail does not force a long
   page scroll.
6. Separate Sales Discount journal presentation is deferred pending Finance
   policy confirmation.

## Existing execution paths audited

- `public.confirm_pos_sales_order` calls
  `private.capture_sales_order_payment_requests`.
- Every external payment leg currently creates one
  `sales_payment_verification_requests` row with status `PENDING`.
- Cash also creates an immutable Cash Drawer `IN` movement immediately.
- `public.review_sales_payment_verification` applies maker-checker, changes the
  request to `VERIFIED`, and creates one `SALE_PAYMENT_VERIFIED` HOLD Event.
- Controlled posting converts that Event into a balanced Journal.
- Verified pre-dispatch payment is consumed by ODR-5E advance reconciliation.

## Why hiding Cash in Backoffice is unsafe

Filtering Cash only in `SalesPaymentVerificationPanel` would strand its request
in `PENDING`. It would block Session close, retain stale-payment warnings and
pending menu counts, omit the Finance Event/Journal, affect cancellation and
revision eligibility, and leave existing pending Cash unresolved.

Cash removal is therefore a runtime policy migration, not a UI-only change.

## Required target contract

At Sales Order confirmation, in one transaction:

1. retain the immutable payment request and Cash Drawer `IN` movement;
2. classify Cash from the server-owned Payment Method snapshot;
3. auto-finalize Cash with explicit `AUTO_VERIFY_CASH` audit;
4. create exactly one idempotent `SALE_PAYMENT_VERIFIED` HOLD Event;
5. keep Transfer/non-Cash `PENDING` for Finance maker-checker;
6. exclude Cash from the manual queue, pending menu count and stale alert;
7. allow Session close when no manual non-Cash issue remains;
8. preserve controlled Journal posting and Dispatch advance reconciliation.

Cash still participates in Finance accounting. Only the human verification
decision is removed.

## Downstream impact

- Current pre-dispatch cancellation reverses `PENDING` Cash with one Drawer
  `OUT`, while generic cancellation rejects every `VERIFIED` request.
- Auto-finalized Cash therefore needs an explicit cancellation branch: cancel a
  HOLD Event and reverse the Drawer exactly once; after Journal POSTED, preserve
  history and require a source-linked reversal/refund.
- Revision must continue to treat collected Cash as a financial fact.
- Session summary does not replace expected/actual Cash reconciliation.
- Return/refund, Expense and Deposit remain drawer movements, not Sales summary.
- Stock, Reservation, FIFO and Dispatch quantity rules do not change.
- Existing verified/rejected Cash history remains immutable. Existing pending
  Cash requires guarded classification and deterministic forward transition.
- Transfer/non-Cash maker-checker and Offline gates remain unchanged.

## Risk and workload

Risk is **medium-high** because the change crosses Cashier Session,
cancellation, Finance Event/Journal, Dispatch advance and health reporting.
It needs a dedicated preflight, guarded migration, rollback-only behavior test,
postflight, authenticated smoke and forward-fix note.

The behavior matrix must cover Cash-only, Transfer-only, split payment, retry,
payload conflict, open/closed Session, Session close, cancel before Dispatch,
reversal after Journal POSTED, partial/full Dispatch, Return/refund,
cross-tenant denial, online/offline boundary, health/menu counts, stale version
and concurrency.

## Current evidence and limits

- PWA lint: PASS.
- PWA TypeScript and production build: PASS.
- `git diff --check`: PASS.
- Read-only Summary helper mutation scan: PASS; no insert/update/delete path.
- All native PWA selects remain under the existing global enhancer with the
  approved threshold of at least 10 eligible options.
- Local production preview: HTTP 200 and built assets contain the Cart,
  checkout-modal, Session Summary, and canonical-document action labels.
- Browser visual smoke could not start because local sandbox metadata was
  rejected. Authenticated visual behavior remains unproven.
- No Cash runtime, schema, Production data, Event, Journal, Stock, FIFO or
  Cashier Session row was changed by this task.
