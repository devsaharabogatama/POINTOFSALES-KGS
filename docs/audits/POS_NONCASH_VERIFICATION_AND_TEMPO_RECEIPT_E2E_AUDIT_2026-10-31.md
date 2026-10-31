# POS Non-Cash Verification and Tempo Receipt E2E Audit

## Post-installation exception checkpoint — 2026-10-31

The Production postflight after migration `20261031100000` passed the ledger,
runtime, 38-row non-cash backlog, and Customer Receipt boundaries, but its
global Cash assertion failed on four `CASH_DRAWER + MANUAL_REVIEW` rows. The
behavior test and client deployment are frozen until those rows are classified.

Source tracing proves the new migration inserts only `DIRECT_BANK` and
`CLEARING`; it cannot create a Cash request. Migration `20260923100000` added
`verification_mode` with the compatibility default `MANUAL_REVIEW`, converted
pending Cash to `AUTO_CASH`, and intentionally retained immutable terminal
historical requests. Therefore the failed global-zero assertion may be a test
harness/precondition defect, but that conclusion remains **BELUM TERBUKTI**
until the exact four rows are compared with both migration timestamps.

SELECT-only evidence package:
`supabase/diagnostics/pos_retail_non_cash_atomic_cash_boundary_diagnosis.sql`.
No request, Event, Journal, session, migration, or client state is changed by
that diagnostic.

The returned Production evidence classifies all four rows as compatible legacy
history: all were requested before migration `20260923100000`, all are terminal
(three `CANCELED`, one `VERIFIED` with its single Posted Journal), none is
`PENDING`, and none was created by or after migration `20261031100000`. The
active mutation guard also contains both `POS_CASH_MANUAL_VERIFICATION_FORBIDDEN`
and `PAYMENT_VERIFICATION_MODE_IMMUTABLE`.

Classification: `TEST_HARNESS FIX`. The postflight Cash assertion is now scoped
to the actual invariant: fail when the Auto-Cash migration timestamp is absent,
when any manual Cash request was created on/after that cutover, or when any
manual Cash request remains `PENDING`. It reports, but does not mutate, terminal
pre-cutover history. No product behavior, live migration, or database data is
changed by this correction.

### Rollback behavior authorization failure

The first Production behavior attempt stopped before any Finance mutation with
`CUSTOM_PERMISSION_DENIED`. The failing call used the payment request's
`requested_by` actor (a direct POS maker) and expected
`MAKER_CHECKER_REQUIRED`, but the active RPC correctly enforces `APPROVE`
permission before checking maker-checker identity. The test therefore conflated
two independent negative invariants.

No Product change is authorized from this error. The next classification is
pending a SELECT-only fixture inventory:
`supabase/diagnostics/pos_retail_non_cash_atomic_behavior_permission_diagnosis.sql`.
It proves whether a pending request exists whose maker has `APPROVE`, and
whether each request has an independent approver. Until that output is known,
the behavior test, deployment, smoke, and UAT remain frozen.

The returned fixture inventory proves all 17 pending Bank requests were made by
actors without `APPROVE`, while every request has two independent approvers
(Company Admin and Super Admin). Classification is `FIXTURE FIX`: the behavior
test now asserts the real POS maker receives `CUSTOM_PERMISSION_DENIED`, then
creates a separate authorized-maker request inside the rollback transaction to
exercise `MAKER_CHECKER_REQUIRED`. The real request is still verified only by
an independent approver. No Product permission, live request, Event, Journal,
or migration is changed by this correction.

Date: 2026-10-31
Classification: `READ_ONLY_AUDIT`
Product/database mutation: none

## Business decisions under audit

1. A POS non-cash payment must be reviewed by Finance. One successful Finance
   verification action must also post the final journal; there must be no
   second manual journal-queue action.
2. A payment against a Tempo invoice remains in Finance **Penerimaan Customer**.
   Posting the receipt must allocate the invoice and create its final journal.

Cash is explicitly outside decision 1. Its existing `CASH_DRAWER`
auto-verification contract is preserved.

## Evidence scope

This audit used:

- active PWA checkout code;
- active Backoffice Finance UI and API routes;
- defining and latest composing migrations for payment verification, POS Cash
  auto-verification, direct Retail posting, Customer Receipt, and AR reporting;
- SQL behavior/postflight suites and local Playwright contracts;
- repository rollout records;
- SELECT-only Production reads against project `nbxjslqojexjfogamnjt` on
  2026-10-31. No Production write or RPC mutation was executed.

The private migration ledger is not exposed through PostgREST (`406 Not
Acceptable`). Ledger state below therefore uses earlier user-confirmed outputs
where available and labels the remaining ledger evidence explicitly.

## Identifier evidence

| Identifier | Defining/active source |
| --- | --- |
| PWA direct checkout | `pwa/src/App.tsx` `postSaleWithNegativeReason()` -> `postSale()` |
| POS post adapter | `pwa/src/lib/pos.ts` `postSale()` -> `post_pos_sale_with_pricelist` |
| Direct-post runtime bridge | `supabase/migrations/20261030120000_pos_retail_direct_post_order_runtime_bridge.sql` |
| Order payment request capture | `supabase/migrations/20260923100000_pos_cash_auto_verification.sql` `private.capture_sales_order_payment_requests` |
| Finance payment review | `supabase/migrations/20260828240000_odr_phase5d_payment_verification_runtime.sql` `public.review_sales_payment_verification` |
| Payment event posting | same migration, `private.post_odr_payment_financial_event_core` |
| Verification UI/API | `backoffice/src/components/SalesPaymentVerificationPanel.tsx`; `backoffice/src/app/api/finance/sales-payment-verifications/route.ts` |
| Customer Receipt UI/API | `backoffice/src/components/CustomerReceiptView.tsx`; `backoffice/src/app/api/finance/customer-receipts/route.ts` |
| Unified Customer Receipt post | `supabase/migrations/20260911163000_backoffice_sales_ar_reporting_integration.sql` `public.post_customer_receipt_unified` |
| Atomic Receipt journal runtime | `supabase/migrations/20260827110000_finance_customer_receipt_posting_runtime.sql` `public.post_customer_receipt` and `private.post_customer_receipt_financial_event_core` |

## Active call-chain result

### A. POS non-cash payment

Current active checkout:

```text
PWA Selesaikan Transaksi
  -> post_pos_sale_with_pricelist
  -> public.post_pos_sale
  -> private.post_pos_sale_before_schedule_core
  -> direct sale finalization
  -> sales_payments + SALE_POSTED(HOLD)
```

It does **not** enter:

```text
confirm_pos_sales_order
  -> private.capture_sales_order_payment_requests
  -> sales_payment_verification_requests(PENDING)
  -> Finance review
```

The repository Playwright runtime contract currently enforces this bypass:
`qa-e2e/tests/runtime-contract.spec.ts` requires `postSale()` and forbids
`confirmSalesOrder()` in the active checkout function. The mocked PWA test only
asserts the direct post RPC; it does not assert non-cash verification or final
Finance journal identity.

Production SELECT-only evidence for POS Retail transactions since the
2026-10-30 cutover:

- 48 direct POS Retail rows inspected;
- 42 are `POSTED`, five are `DRAFT`, and one is another terminal state;
- the 42 Posted sales contain 43 payment legs: five Cash and 38 non-cash;
- non-cash composition is 21 `QRIS/CLEARING` and 17
  `TRANSFER/DIRECT_BANK`;
- one sale uses split payment;
- all 38 non-cash sales have **zero** payment-verification request;
- all 42 Posted sales have a `SALE_POSTED` Event in `HOLD`;
- those 42 Events have zero Finance Journal.

The older verification runtime is installed and contains 14 historical
requests: nine `VERIFIED`, three `CANCELED`, and two `PENDING`. The two pending
non-cash rows are one `CLEARING` and one `DIRECT_BANK`; they do not cover the 38
recent direct-post non-cash sales.

Even when a request does reach the older Finance UI, verification is not atomic
with journal posting. `review_sales_payment_verification` inserts a
`SALE_PAYMENT_VERIFIED` Event with status `HOLD`. The UI explicitly says
“Proses melalui Antrian Jurnal” and exposes an **Antrian Jurnal** button.
`private.post_odr_payment_financial_event_core` is a later posting action.

**Verdict for decision 1: `TIDAK BERJALAN`.**

There are two independent gaps:

1. active direct Retail checkout bypasses request creation for non-cash;
2. the retained review action creates only a HOLD Event and does not post its
   journal in the same transaction.

### Existing COA and journal contract (no new unverified-funds COA required)

The gap is not a missing account choice. Production already has one active
`SALE_PAYMENT_VERIFIED` category, an approved Posting Rule Set, and effective
account rules for every function consumed by
`private.post_odr_payment_financial_event_core`.

Current effective account resolution is identical by account code for KGS and
KGFF:

| Function | Account |
| --- | --- |
| `BANK` / `BANK_RECEIPT` | `1010100-1` - BANK BCA |
| `PAYMENT_CLEARING` | `1080100` - HUBUNGAN REKENING KORAN |
| `CUSTOMER_ADVANCE_LIABILITY` | `2050100` - UANG MUKA PENJUALAN |
| `CUSTOMER_RECEIVABLE` | `1020100` - PIUTANG USAHA |
| `CASH_DRAWER` | `1010100-3` - KAS KECIL |

The posting core already creates a balanced journal in one database
transaction: debit the payment method's settlement function and credit
Customer Advance, Customer Receivable, or Payment Clearing according to the
request snapshot. If source and target resolve to the same account, it closes
the Event as `CANCELED / NO_FINANCIAL_EFFECT` instead of creating a zero-value
journal.

Production contains one historical Posted `SALE_PAYMENT_VERIFIED` Event and
Posted Journal, proving the journal path has executed. Its 2026-09-16 lines use
the then-effective legacy accounts `1110 Kas Laci` and `2190 Uang Muka
Customer`; this does not contradict the current effective user-owned mapping,
which changed on 2026-10-07.

The current UI/API split is also exact:

```text
Verifikasi
  -> POST /api/finance/sales-payment-verifications
  -> review_sales_payment_verification
  -> request VERIFIED + SALE_PAYMENT_VERIFIED Event HOLD

Antrian Jurnal
  -> approve/process financial event posting queue
  -> private.post_financial_event_core
  -> private.post_odr_payment_financial_event_core
  -> Event/Journal POSTED (or NO_FINANCIAL_EFFECT)
```

Therefore the approved change is to make the successful Finance verification
invoke the existing posting core atomically and remove the second manual queue
action for this process. It is **not** to invent a new COA or a second journal
type.

One accounting-ownership issue remains material to Phase B: current direct POS
sales already persist `sales_payments` with `BANK_RECEIPT` for Transfer and
`PAYMENT_CLEARING` for QRIS, while their `SALE_POSTED` Events remain `HOLD`.
The correction must ensure only one Event owns each settlement debit before
either Event is posted. This is a call-chain issue, not a Finance mapping gap.

### B. Tempo payment through Penerimaan Customer

Active collection chain:

```text
Finance > Penerimaan Customer
  -> SAVE_DRAFT
  -> save_customer_receipt_allocated_draft
  -> allocation to RETAIL_SALE / BACKOFFICE_SALES_INVOICE
  -> POST
  -> post_customer_receipt_unified
  -> post_customer_receipt_allocated
  -> public.post_customer_receipt
  -> Financial Event SALE_PAYMENT
  -> final POSTED journal atomically
```

The journal runtime writes:

- debit: receipt Cash/Bank account snapshot;
- credit: Customer Receivable account snapshot;
- source Event and Journal both become `POSTED` in the same database
  transaction;
- advisory locking, optimistic `master_version`, idempotency key, outstanding
  recheck, and exact Event-Journal identity are present.

Production SELECT-only reconciliation:

- 428 Customer Receipt documents exist;
- 418 are `POSTED`, ten are non-Posted;
- exactly 418 `SALE_PAYMENT` Events are present and all are `POSTED`;
- every one of the 418 Posted receipts has its Event and a Posted Journal;
- no Posted receipt is missing an Event or Journal;
- 234 Retail allocation rows resolve to 214 Retail sales;
- all 234 Retail allocations point to `is_tempo=true`; none points to a
  non-Tempo sale.

There are 419 `SALE_PAYMENT` journals in total, one more than the current
Posted Receipt/Event population. This audit did not classify the additional
journal because it does not break the exact 418 Posted Receipt -> Event ->
Journal reconciliation. It remains a separate historical inventory item if an
exact one-to-one global cleanup is later requested.

**Verdict for decision 2: `SUDAH BERJALAN` at database/runtime level.**

Production data proves real Posted Tempo allocations and final journals, not
only zero-row postflight. This audit did not perform a new authenticated browser
mutation, so the status is not promoted to a new `UAT PASS` for the current
client build.

## Database state classification

| Scope | Classification | Evidence |
| --- | --- | --- |
| POS Cash auto-verification `20260923100000` | `INSTALLED_CONSISTENT` | Earlier user-confirmed ledger/behavior/postflight PASS plus 14 live request rows and current routine/UI contract. |
| Direct Retail bridge `20261030120000` and Pickup boundary `20261030130000` | `INSTALLED_CONSISTENT` | Earlier user-confirmed migration/behavior/postflight plus live direct-post rows. |
| Customer Receipt runtime | `OBJECT/DATA CONSISTENT; EXACT LEDGER NOT RE-QUERIED THIS TURN` | 418 exact Posted Receipt -> Posted Event -> Posted Journal chains. Private ledger is not REST-exposed; earlier rollout records prove isolated Development gates, while live Production objects/data prove active runtime. |

## Impact map for the future correction

No correction is implemented by this audit. Any Phase B design must cover the
following consumers before editing.

### Direct impact

- PWA checkout orchestration and response copy;
- payment-intent/request capture for `QRIS/CLEARING` and
  `TRANSFER/DIRECT_BANK`;
- Finance verification API/RPC/UI;
- atomic verification + Event + Journal transaction;
- maker-checker, proof, stale version, exact retry, and rejection paths.

### Downstream impact

- `SALE_POSTED` versus `SALE_PAYMENT_VERIFIED` accounting ownership;
- prevention of duplicate settlement debit between both Events;
- Cash auto-verification and cashier expected-cash/session close;
- split payment where Cash and non-cash legs have different finality;
- Invoice/receipt display, Customer balance, and Tempo AR;
- Finance queue/backlog, Event status, journal identity, and audit history;
- existing 42 `SALE_POSTED HOLD` Events and 38 unverified non-cash payment legs;
- Pickup/Delivery, Stock/FIFO, Return/Refund, and Backoffice flows, all of which
  must remain unchanged unless a proven accounting dependency requires a
  scoped forward fix.

### Compatibility and rollout risks

- Retrofitting request rows for the 38 existing non-cash sales without an
  approved backlog policy could duplicate settlement or alter history.
- Posting `SALE_PAYMENT_VERIFIED` while `SALE_POSTED` still owns the same
  payment settlement leg would double-debit Cash/Bank/Clearing.
- Posting the entire `SALE_POSTED` journal from the payment verification action
  would couple sales recognition/COGS to payment approval and must be explicitly
  designed, especially for split payments and Tempo.
- Cash must not be pushed back into manual Finance verification.
- Penerimaan Customer must remain the only collection route for later Tempo
  payments and must not receive immediate non-cash POS payments.

## Mandatory regression matrix for Phase B

| Dimension | Required cases |
| --- | --- |
| Methods | Cash, QRIS/CLEARING, Transfer/DIRECT_BANK, Cash+non-cash split |
| Payment decision | pending, verified, rejected, exact retry, stale version, maker-checker denial |
| Session | open; close blocked/unblocked according to exact payment contract; closed-session retry |
| Sales | Pickup and Delivery; immediate and scheduled; Tempo and non-Tempo |
| Finance | request identity, Event identity, balanced Posted Journal, no duplicate settlement, controlled backlog handling |
| Stock | positive FIFO and allowed negative stock; no payment decision may duplicate Movement/FIFO |
| Channels | POS Retail preserved; Backoffice order/invoice/payment flow unchanged |
| Tenant | same-Company success, cross-Company denial |
| History | pre-cutover request rows; 38 current unverified direct payments; 42 current HOLD sale Events |
| Failure | atomic rollback on mapping, period, account, proof, or journal failure |

## Phase A correction design

This section closes the design gate for the approved point-1 correction. It
does not authorize or record a Production mutation.

### Refreshed Production backlog evidence

A second SELECT-only inventory on 2026-10-31 corrected the PowerShell array
enumeration used by the earlier count and inspected the complete direct Retail
population instead of a partial result:

- 349 `POS + RETAIL_CONFIRM_INVOICE` Sales rows were inspected;
- 82 are final `POSTED + LEGACY_POSTED` direct Retail Sales;
- those final Sales contain 40 `DIRECT_BANK` or `CLEARING` payment legs without
  a verification request;
- 38 legs belong to Sales whose exact `SALE_POSTED` Event is `HOLD` and has no
  Finance Journal;
- two `DIRECT_BANK` legs belong to Sales whose `SALE_POSTED` Event and Journal
  are already `POSTED` under the legacy accounting ownership;
- no final direct Retail non-cash leg is missing its exact `SALE_POSTED` Event.

The earlier 38-leg observation therefore remains the exact safe backfill set,
but it was not the complete non-cash inventory. The two already-posted legacy
legs must not receive a second settlement Journal and are explicitly excluded
from backfill. Existing Posted Journals remain immutable.

### Expected business outcome

1. A new direct Retail POS `DIRECT_BANK` or `CLEARING` payment creates one
   immutable `PENDING / MANUAL_REVIEW` verification request from the persisted
   `sales_payments` snapshot. Cash remains outside this manual workspace.
2. Finance `VERIFY` creates the `SALE_PAYMENT_VERIFIED` Event and immediately
   invokes the existing posting core in the same database transaction.
3. If account mapping, Posting Rule Set, accounting period, or journal posting
   fails, the verification request remains `PENDING`; no half-verified state is
   committed.
4. The direct Retail `SALE_POSTED` Journal owns revenue, tax, COGS, inventory,
   receivable, and a temporary `PAYMENT_CLEARING` debit for every non-cash leg
   that has a verification request. It does not debit Bank directly.
5. The verification Journal owns settlement reclassification:
   `DIRECT_BANK` debits its Bank/Bank Receipt function and credits
   `PAYMENT_CLEARING`. A `CLEARING` method whose configured source and target
   resolve to the same account closes as the existing
   `CANCELED / NO_FINANCIAL_EFFECT` result, without a zero-value Journal.
6. Tempo collections after invoicing remain exclusively in
   **Penerimaan Customer** and retain their proven atomic Customer Receipt
   journal path.

### Active execution path after the correction

```text
PWA post_pos_sale_with_pricelist
  -> public.post_pos_sale
  -> private.post_pos_sale_before_schedule_core
  -> sales_payments persisted
  -> sales_headers becomes POSTED + LEGACY_POSTED
  -> AFTER UPDATE trigger
  -> private.capture_direct_retail_non_cash_payment_requests
  -> non-cash request PENDING (Cash untouched)

Finance Verify
  -> POST /api/finance/sales-payment-verifications
  -> public.review_sales_payment_verification
  -> request VERIFIED + SALE_PAYMENT_VERIFIED Event HOLD
  -> private.post_financial_event_core
  -> private.post_odr_payment_financial_event_core
  -> Event/Journal POSTED or Event CANCELED/NO_FINANCIAL_EFFECT
  -> one transaction commits
```

### Identifier and implementation sources

| Planned identifier/change | Defining evidence |
| --- | --- |
| direct payment source | `public.sales_payments` columns populated by `20260729070000_g4_phase4_atomic_sale_runtime.sql`, with `client_payment_key` from `20260729150000_g4_phase8_payment_leg_identity.sql` and settlement function snapshot from `20260814110000_g6_phase8b_sale_return_posting_runtime.sql` |
| verification request shape and guards | `20260828210000_odr_phase5a_finance_source_foundation.sql`, `20260828240000_odr_phase5d_payment_verification_runtime.sql`, and `20260923100000_pos_cash_auto_verification.sql` |
| atomic posting dispatcher/core | `private.post_financial_event_core` and `private.post_odr_payment_financial_event_core` in `20260828240000_odr_phase5d_payment_verification_runtime.sql` |
| direct Retail final lifecycle | `20261030120000_pos_retail_direct_post_order_runtime_bridge.sql` |
| Sale settlement loop | `private.post_sale_return_financial_event_core`, defined by `20260827141000_finance_tempo_sale_posting_fix.sql` and composed by `20260925100000_gross_sales_discount_accounting.sql`, `20261006150000_kgs_retail_pos_user_coa_activation.sql`, `20261008110000_kgff_retail_finance_authority_clone.sql`, and `20261012100000_bff_kgff_finance_configuration_clone.sql` |

### Direct and downstream impact

- **Direct:** direct Retail non-cash request capture, Finance verification RPC,
  verification UI copy, and settlement-account ownership in the Sale posting
  core.
- **Finance downstream:** `SALE_POSTED`, `SALE_PAYMENT_VERIFIED`, Posting Rule
  Set/account resolution, accounting period, queue visibility, Event/Journal
  audit, exact retry, and stale-version behavior.
- **Operational downstream:** cashier session identity and proof snapshot are
  copied from persisted payment/session data. Stock Movement, Reservation,
  FIFO/HPP, Invoice, receipt, Pickup/Delivery, and session cash calculation are
  not mutated by verification.
- **Compatibility:** Cash auto-verification, Customer Balance, Return/Refund,
  ODR/Backoffice fulfillment, current category-specific KGS/KGFF/BFF revenue
  and inventory posting, gross discount, and Customer Receipt remain intact.

### Concurrency, retry, and history policy

- request uniqueness remains `(company_id, sales_id, client_payment_key)`;
- trigger capture locks the Sale and treats an exact existing request as an
  idempotent retry; a different immutable snapshot is a conflict;
- Finance review keeps its request row lock, maker-checker, optimistic
  `master_version`, and idempotency audit key;
- the posting core retains its Event lock and Event/Journal idempotency;
- the 38 safe historical legs receive additive request/audit rows only;
- the two already-posted legacy legs are not backfilled or rewritten;
- rollout is a forward-only migration. If rollout fails, the transaction rolls
  back. After a successful rollout, correction is another guarded forward fix,
  never deletion of requests, Events, Journals, or ledger rows.

### Database/migration state for implementation

- prerequisite runtime through `20261030130000`:
  `INSTALLED_CONSISTENT`, based on prior user-confirmed ledger/postflight and
  current Production object/data behavior;
- planned forward migration `20261031100000`:
  repository package authored but `NOT_INSTALLED` in Production;
- Production period evidence: KGS has Open July, August, and September 2026
  periods but no period covering 2026-10-31; KGFF has an Open October period.
  KGS October must be created/opened before migration and authenticated
  verification smoke;
- design-changing unknown: `NONE`; the missing KGS period is a proven manual
  rollout blocker, not an unknown.

The implementation must fail closed if the live function definitions, 38/2
backlog partition, active Finance queue, nonterminal Offline submissions, or
required mapping/period authority differs from the preflight evidence.

## Status

- `AUDIT COMPLETE`
- `CORRECTION DESIGN COMPLETE`
- `PRODUCT FIX SOURCE AUTHORED`
- `LOCAL READY`: not claimed because SQL database rehearsal is pending
- `DATABASE LIVE`: current, defective point-1 behavior and working point-2
  behavior only
- `CLIENT DEPLOYED`: current direct-post client
- `SMOKE PASS`: not claimed for the requested target behavior
- `UAT PASS`: not claimed

The Phase B source package now exists. The next safe step is to create/open the
KGS October accounting period, then run preflight, migration, postflight, and
rollback-only behavior in that order. Production rollout, client deployment,
authenticated smoke, and UAT remain separate user-operated gates.
