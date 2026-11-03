# POS Retail non-cash permission regression — Phase A audit

Date: 2026-11-02
Classification: `READ_ONLY_AUDIT`
Product/schema mutation: none

## Incident and expected outcome

An authenticated KGS cashier receives `permission denied for table
sales_payment_verification_requests` while completing a POS payment. The
approved flow is:

1. POS posts the Retail sale without exposing a verification action;
2. the server captures each `DIRECT_BANK`/`CLEARING` leg as a `PENDING`
   verification request;
3. Finance performs one atomic **Verify and Post** action;
4. Cash and Tempo keep their existing boundaries.

The POS transaction must not receive direct table privileges. The internal
capture must execute through the audited server-side privilege boundary.

## Source-of-truth call chain

- Client submit: `pwa/src/App.tsx`, `postSaleWithNegativeReason()` calls
  `postSale()` after persisting the Draft.
- Client RPC wrapper: `pwa/src/lib/pos.ts`, `postSale()` invokes
  `public.post_pos_sale_with_ketul(uuid,bigint,uuid)`.
- Ketul wrapper: migration `20261031110000`, declared `SECURITY DEFINER`, calls
  `public.post_pos_sale_with_pricelist(uuid,bigint,uuid)`.
- Non-cash capture: migration `20261031100000` creates an `AFTER UPDATE` trigger
  on `public.sales_headers`. Its trigger function calls
  `private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid)`.
- Finance settlement ownership: the same migration adds
  `private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text)`
  to the Sale financial-event core.
- Finance review: `public.review_sales_payment_verification(...)` verifies the
  request and invokes `private.post_financial_event_core(...)` atomically.

All table and routine identifiers above are sourced from migrations
`20260828210000`, `20260729100000`, `20261031100000`, and `20261031110000`.

## Proven failure in prior evidence

The rollback behavior at
`supabase/tests/pos_retail_non_cash_atomic_verification_behavior.sql` did not
exercise authenticated POS checkout. It called the private capture helper
directly from the privileged SQL test transaction before setting the JWT to an
`authenticated` actor. The later authenticated cases only exercised Finance
review authorization. Therefore its PASS does not prove the POS-to-trigger
privilege boundary.

The postflight checked object existence and definition anchors, but did not
prove routine ownership, `prosecdef`, effective owner table privileges, or an
authenticated call through the public checkout RPC.

Previous claims remain limited to the cases actually asserted. Authenticated
POS non-cash smoke is `FAIL`, and UAT is `FAIL` for the affected path.

## Impact map

### Direct impact

- Retail POS checkout using a payment path that reaches the non-cash capture or
  settlement resolver.
- `sales_headers`, `sales_payments`, and
  `sales_payment_verification_requests` within one posting transaction.

### Downstream impact

- failed checkout rolls back Invoice, Payment, Stock movement, FIFO/HPP,
  financial Event/Journal, receipt snapshot, and verification request;
- Finance receives no request for a rolled-back checkout;
- retry behavior must remain exact and idempotent after correction.

### Explicitly preserved

- no direct `authenticated` grants on the internal verification tables;
- maker-checker and Finance capability checks;
- Cash auto-verification and Tempo Customer Receipt;
- Backoffice sales/dispatch/invoice flow;
- historical requests, Events, Journals, and Posted sales;
- tenant isolation and immutable applied migrations.

## Active database evidence and root cause

The user ran
`supabase/diagnostics/pos_retail_non_cash_permission_regression_diagnosis.sql`.
Its output proves:

- migrations `20261031100000` and `20261031110000` are installed;
- the verification table is owned by `postgres`, has RLS enabled, and correctly
  grants no direct `SELECT`/`INSERT`/`UPDATE` to `authenticated`;
- the direct Retail capture helper, its Sale trigger, the Ketul wrapper, the
  public posting wrapper, and Finance review routine have their intended owner
  and `SECURITY DEFINER` boundary;
- the only routine in the complete verification-table reference inventory that
  is not `SECURITY DEFINER` is
  `private.trg_enforce_no_pending_pos_cash()`.

Migration `20260923100000` proves that this routine is attached as a
`DEFERRABLE INITIALLY DEFERRED` constraint trigger. The deferred check runs at
the transaction constraint boundary, after the nested posting routine's
definer context has returned to the authenticated cashier. The trigger then
performs a direct `SELECT` from
`public.sales_payment_verification_requests`, which the table contract
correctly denies to `authenticated`. This exactly matches the browser error.

Root-cause classification: `PRODUCT FIX` / server privilege boundary. It is
not a payment-flow change and not a reason to grant browser table access.

Database state is `INSTALLED_CONSISTENT` for the applied Retail non-cash
migrations, with a proven forward-fix requirement in the older deferred Cash
guard. Applied migrations remain immutable.

## Before/after design

Before: the deferred guard runs as the caller and cannot inspect its protected
table during authenticated checkout.

After: the same guard body and the same deferred trigger run as the function
owner (`postgres`). Cash `PENDING` rows are still rejected with
`POS_CASH_AUTO_VERIFICATION_REQUIRED`; non-cash `PENDING` rows pass; the browser
still has no direct table privileges.

No table, column, policy, payment status, settlement route, Finance mapping, or
client behavior changes.

## Concurrency, retry, and rollback

- transaction timing and deferred execution are unchanged;
- exact payment-request uniqueness and capture idempotency are unchanged;
- failed posting continues to roll back Sale, Payment, Stock/FIFO, Finance, and
  verification effects atomically;
- rollback is a new forward migration that restores `SECURITY INVOKER`; it is
  not an edit or rerun of a live migration;
- authenticated POS smoke is still mandatory after database rollout because a
  rollback-only SQL behavior test cannot prove the deployed browser session.

## Required regression matrix after a proven forward fix

- authenticated cashier: Cash, Transfer/DIRECT_BANK, QRIS/CLEARING, split;
- POS contains no verification action;
- non-cash checkout posts once and creates exactly one `PENDING` request;
- Finance Verify posts one payment Event/Journal atomically;
- rejection, exact retry, duplicate request, stale version, and concurrency;
- open/closed cashier session;
- Tempo remains in Customer Receipt;
- Pickup/Delivery;
- same Company/cross-Company;
- Stock, Reservation, FIFO/HPP, Invoice, Payment, Finance and audit lineage;
- Backoffice process remains unchanged;
- existing Posted and pending historical rows remain unchanged.

## Current status

- `AUDIT COMPLETE`: YES - root cause and bounded forward fix are proven.
- `LOCAL READY`: forward package authored and rollback behavior passed.
- `DATABASE LIVE`: migration `20261102140000` installed; its exact-ledger
  precondition and deferred authenticated execution passed in the user-run
  rollback behavior.
- `CLIENT DEPLOYED`: no client change is required for this server defect.
- `SMOKE PASS`: NO; a real POS Transfer/QRIS checkout has not been rerun.
- `UAT PASS`: NO.

User-provided behavior evidence:

`pos_retail_non_cash_deferred_guard_privilege_behavior,PASS,0`

This proves the installed forward migration, protected-table denial, deferred
trigger execution under an authenticated actor, unchanged guard timing/body,
and full rollback.

The user subsequently supplied the complete SELECT-only postflight: ledger,
owner/`SECURITY DEFINER`, enabled deferred trigger, exact trigger function, and
continued denial of authenticated `SELECT`/`INSERT`/`UPDATE` all pass. This
closes the database postflight gate. It does not substitute for a real browser
checkout.
