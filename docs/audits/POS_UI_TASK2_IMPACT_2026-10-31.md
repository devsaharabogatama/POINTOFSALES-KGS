# POS UI Task 2 — Impact Audit (2026-10-31)

## Acceptance failure after the first corrective patch — 2026-11-01

- User UAT evidence shows two editable Customer controls in one transaction:
  one in the Catalog Cart header and the pre-existing control in the payment
  dialog. This fails the requirement to **move**, rather than copy, Customer
  selection to Catalog.
- The first focused mocked-browser run also cannot be accepted as product
  evidence: one test loaded an older preview surface because the Playwright
  web-server configuration reused an existing process on port `5197`. The
  rendered trace still contained the old passive Customer label while the
  user's current local surface already showed the new Catalog selector. This is
  classified as `TEST HARNESS PRECONDITION`, not a reason to weaken assertions.
- Corrective product boundary: Catalog becomes the only editable Customer
  surface and also owns `Customer baru` plus the selected Customer balance.
  Payment keeps only Pricelist selection and reads the canonical `customerId`;
  it must not render a second Customer input or duplicate Customer name.
- Status: `AUDIT REOPENED / FIRST PATCH REJECTED BY UAT / LOCAL READY REVOKED`.

### Second acceptance failure — wrong surface placement

- User UAT proves that placing the Customer control below `Keranjang` is also
  incorrect. It competes with Order/Draft actions, collapses the select width,
  and does not satisfy “Customer on the Catalog page” as an operator context.
- The active Catalog panel is the left `Katalog / Pilih produk` surface rendered
  before search, category filters, and product cards (`pwa/src/App.tsx`). The
  Customer control must live there as a compact Catalog context row.
- `Keranjang` returns to order-only information and actions. The payment dialog
  remains read-only with respect to Customer. There is still exactly one
  editable Customer selector and one `Customer baru` action.
- Status remains `PRODUCT PATCH REJECTED BY UAT / LOCAL READY REVOKED`.

### Compact-toolbar correction

- The standalone Customer card was removed. The Catalog heading now uses one
  horizontal toolbar: `Pilih produk` on the left, then `Customer aktif`, its
  selector, `Customer baru`, and the item count on the right.
- At narrower widths the same toolbar wraps as one responsive unit; it does not
  return to the Cart or payment dialog.
- Local browser inspection at the user's active `127.0.0.1:5190` viewport
  confirms the compact heading and restored product height. PWA lint/build
  pass. User visual acceptance remains pending; `UAT PASS` is not claimed.

## Corrective reopening — 2026-11-01

- The earlier `LOCAL READY` claim is revoked. Mocked Playwright and a passive
  customer label did not prove that the requested operator workflow was usable.
- User clarification for point 1: the Catalog surface itself must let the
  cashier see **and select** the active Customer. Keeping the only Customer
  control inside `Pembayaran & penyelesaian` does not satisfy the requirement.
- Current proven gap: `App.tsx` renders `activeCustomer.name` in the Cart header,
  but the only editable Customer `<select>` remains inside the checkout dialog.
- Canonical implementation path is already present and must be reused:
  `loadCatalog()` -> `get_pos_customer_references()` -> `customerId` ->
  `selectCustomer()` -> Pricelist/price-preview/payment/delivery recalculation.
- Scope of the corrective point-1 patch is PWA UI and its regression test only.
  It does not change schema, RPC signatures, Stock, FIFO, Payment posting,
  Finance, cashier-session lifecycle, Backoffice/ODR, or Company context.
- Status after this reopening: `AUDIT COMPLETE / PRODUCT PATCH NOT STARTED /
  REAL LOCAL SMOKE NOT RUN / UAT NOT RUN`.

## Status and scope

- Task classification: `PRODUCT_BEHAVIOR_CHANGE`.
- Current phase: Fase A read-only audit complete for the UI-first slice.
- Production mutation/deployment: none.
- Company used for read-only live inspection: `KGS Company`; company context was not changed.
- Live surface inspected: `https://kgs-pos-pwa.vercel.app/`, active session
  `SES-20261031-0000000162` on `Kasir Utama POS-1`.

This document is the durable Task 2 backlog. Approval of a backlog item does
not mean its runtime is implemented.

## Approved Task 2 backlog

| No. | Requirement | Classification | Current evidence / decision |
| --- | --- | --- | --- |
| 1 | Catalog must visibly show and allow changing the active Customer without opening payment details. | UI-first corrective slice | `App.tsx` already resolves `activeCustomer` and exposes canonical `selectCustomer()`. The previous patch added only a passive label and therefore failed acceptance. Reuse the same state/function in a Catalog customer selector; do not add a query or duplicate customer state. |
| 2 | After a successful confirmation the active cart/order must reset. | Existing behavior + regression test | The active Retail path calls `post_pos_sale_with_pricelist`, loads the receipt, calls `resetSale()`, clears Cart/Draft/payment state, then refreshes Catalog and Drafts (`App.tsx:2969-3014`, `3044-3075`). The existing mocked E2E reaches `Transaksi Posted`. Do not patch product behavior unless a reproducible failure contradicts this evidence; strengthen the assertion that the cart is empty behind/after closing the receipt. |
| 3 | Posted transaction/receipt must show the customer name. | UI-first | The Posted receipt modal renders Invoice/date/lines/payment but not customer (`App.tsx:6000-6075`). The canonical receipt snapshot type does not contain customer (`lib/pos.ts:579-617`). For the current checkout, preserve the already-resolved customer name in UI state before reset; for Session Summary reopen, use `transaction.customerName`. No schema/snapshot mutation in this slice. |
| 4 | Session Summary must show total Expense paid from the selected session; POS Expense entered by the Cashier is already paid, has no separate verification/`Cairkan tunai`, and POS settlement/history is limited to the selected session. | Product + schema forward fix | The prior opening-cash interpretation was rejected by the user. Proven impact and target call chain are recorded in `POS_DIRECT_SESSION_EXPENSE_IMPACT_2026-11-01.md`. |
| 5 | Receipt/Return flow must expose the refund method and make the workflow clear. | Local-ready workflow slice | Separate impact audit completed in `POS_SALES_RETURN_REFUND_METHOD_UI_IMPACT_2026-10-31.md`. The POS now explains that the selected method is finalized only when Backoffice posts the Return, and a Posted Return exposes a printable customer note containing the actual refund method. Draft/Canceled Return cannot print a final note. |
| 6 | Session Summary transaction rows should prioritize customer name instead of DRF. | UI-first | Summary already loads customer via `get_pos_customer_references()` and maps `customerName` (`lib/pos.ts:972-1107`). Live UI shows DRF as primary and customer as secondary. Promote customer to primary; keep DRF/Invoice secondary for traceability. |
| 7 | Catalog Cart must use the available right-column height so `Total akhir` sits at the panel bottom and more purchased items remain visible. | Locally implemented and browser-verified | The earlier “reduce footer footprint” interpretation was incomplete. The proven root cause was the Catalog-only `224px` list cap plus a shrink-wrapped right column. The scoped CSS change makes the list consume the remaining panel height; Compact/mobile and checkout behavior are covered by the focused geometry test. Exact evidence: [Point 7 impact audit](POS_CATALOG_CART_VIEWPORT_IMPACT_2026-11-01.md). Client deploy and user UAT remain pending. |
| 8 | Session Summary must break payments down by Cash/Transfer/QRIS/etc., including split-payment composition. | UI-first | Per-transaction payment snapshots already expose method name/type/route and amount. Reuse the existing counted-transaction predicate and payment snapshots; show per-method totals and mark a transaction `Split payment` when it has multiple legs. Reversal rows remain excluded by the existing read model. |
| 9 | Sales Return transfer destination must be conditional: Cash does not require it; Transfer does. Refund method may differ from original payment, with audit. | Local-ready workflow slice | Existing server contract was proven correct: Cash requires and stores no transfer metadata; Transfer requires destination/reference; the selected method may differ from the original Sale and is snapshotted for audit/Finance. The POS now also clears hidden Transfer state when switching to Cash, with mocked browser regression coverage. |
| 10 | Ketul returned by a customer creates incoming Ketul stock and a discount on the goods purchased. | Later domain/workflow slice | Not a cosmetic discount. Must audit POS-010 Ketul intake/trade-in, Stock, valuation, discount authority, Finance posting, Return compatibility and concurrency before design. |

## UI-first active execution paths

### Customer selection and Cart/Catalog display

`get_pos_customer_references()` -> `loadCatalog()` customer options ->
`App.customerId` -> `activeCustomer` -> shared `selectCustomer()` -> the single
Catalog Customer selector -> checkout Pricelist and downstream calculations.

The Catalog selector is the only editable Customer consumer. Changing it must
invoke the existing function so resolved
lines are cleared, the automatic Pricelist is recalculated, server price
preview reruns, Tempo due-date suggestion follows the Customer, and Delivery
identity follows the Customer. No table, RPC, pricing algorithm or tenant-
context change is permitted.

### Retail checkout, receipt and reset

Checkout fields -> `persistDraft()` -> `save_pos_sale_draft_with_pricelist` ->
`postSale()` -> `post_pos_sale_with_pricelist` -> `loadReceipt()` from the
immutable `sales_headers.receipt_snapshot` -> optional Invoice/Delivery reads ->
`resetSale()` -> Catalog/Draft refresh.

Point-2 corrective ordering is limited to the post-success boundary. The
current implementation waits for optional Invoice/Delivery document loading
before calling `resetSale()`, so a slow optional read can leave the completed
Cart visible after server success. The corrected order is:

`postSale()` final result -> `loadReceipt()` succeeds -> capture Customer and
show receipt -> `resetSale()` immediately -> load optional sales documents and
refresh Catalog/Drafts as non-authoritative post-success reads.

`DRAFT`, shortage, validation, stale-version, permission, and network failure
paths stay before this boundary and must retain Cart/Draft input. An optional
document or refresh failure after final posting must not be reported as a Sale
posting failure or encourage a duplicate retry.

The UI-first patch may only retain a display-only customer name alongside the
receipt modal. It must not change the receipt snapshot, posting RPC, Payment,
Stock, Reservation, FIFO/HPP, cashier session, Finance Event/Journal or
Delivery behavior.

### Session Summary

Summary button -> `SessionSummaryModal` -> `loadCashierSessionSummary()` ->
session-scoped `sales_headers`, `sales_details`, canonical
`get_pos_customer_references()`, and `sales_payments`/payload payment snapshots
-> read-only transaction and product lists.

The UI-first patch changes only display priority (customer primary; DRF and
Invoice retained as secondary identifiers).

The same component receives `cashierSession.openingCash`, which is the existing
canonical `opening_cash_actual`. Payment-method totals are derived exclusively
from the same non-reversal payment legs already used by Cash/non-Cash totals;
they do not change settlement or Finance state.

## Impact map

### Direct impact

- `pwa/src/App.tsx`: replace the passive Catalog customer label with an editable
  selector backed by the existing `customerId`/`selectCustomer()` path; retain
  display on Posted receipt and keep existing reset behavior.
- `pwa/src/App.css`: compact customer/total visual treatment.
- `pwa/src/SessionSummaryModal.tsx`: customer-first transaction heading.
- `pwa/src/SessionSummaryModal.tsx`: render opening session cash, per-method
  totals, and split-payment labels from existing read-only data.
- `qa-e2e/tests/retail-pwa.mocked.spec.ts`: assert visible customer on Catalog,
  Posted receipt, and empty Cart after closing the receipt.

### Downstream impact explicitly preserved

- POS direct Retail posting and Backoffice/ODR flow separation.
- Pricing and Pricelist selection.
- all payment methods, split payment, Tempo and Customer Balance semantics.
- Stock, Reservation, FIFO/HPP and negative-stock authority.
- cashier session state and opening/closing cash.
- Finance Event/queue/Journal and non-cash verification.
- Invoice/Surat Jalan generation and print audit.
- same-Company/cross-Company security and active company context.
- Draft retry, stale version, idempotency and concurrency behavior.
- existing/legacy receipt snapshots (no backfill and no schema change).

### Regression risks

- `resetSale()` changes `activeCustomer` to Walk-In before the Posted receipt
  renders; reading `activeCustomer` directly from the modal would show the wrong
  customer. The selected customer name must be captured before reset.
- Opening an existing Session Summary transaction must use that transaction's
  customer, not the current Cart customer.
- Customer name is display-only in this slice and must not be written into an
  existing canonical receipt snapshot.
- Compact footer must remain keyboard/touch accessible and must not hide `Atur
  pembayaran` in Catalog layout.

## Runtime and migration state

- Schema/migration change: none planned for the UI-first slice.
- Database state relevant to this slice: existing live POS customer references,
  Retail posting RPC and Session Summary read model are active, proven by the
  currently deployed client and repository call chain.
- Client state: current production UI inspected; new changes are not yet built
  or deployed.
- No runtime row count is used as behavioral proof.

## Test matrix for the UI-first slice

| Scenario | Required assertion |
| --- | --- |
| Catalog with Walk-In customer | Customer selector is visible and shows Walk-In; Cart/Price behavior unchanged. |
| Catalog with named customer | Cashier can select it without opening payment details; header and checkout share the same selected value and server price preview reruns. |
| Successful Pickup Retail post | Posted receipt shows the captured customer; no Surat Jalan is introduced. |
| Close Posted receipt | Cart is empty and customer resets according to existing `resetSale()` policy. |
| Reopen from Session Summary | Posted receipt shows the Summary transaction customer, not current Cart customer. |
| Session Summary transaction | Customer is primary; DRF/Invoice remains visible for traceability. |
| Catalog viewport | Compact Total footer leaves more Cart height and payment action remains usable. |
| Backoffice/ODR | No source/runtime change; existing routing assertions remain unchanged. |

Remaining authenticated production smoke is manual and must be reported
separately from local mocked E2E.

## First local run failure classification

- Evidence: `qa-e2e/test-results/retail-pwa.mocked-posts-KG-bbe00--reservation-or-Surat-Jalan/error-context.md`.
- Failure: Playwright timed out selecting the named customer while the Catalog
  checkout overlay was still closed. The locator resolved to the correct
  canonical Customer `<select>`, but the element was intentionally not visible.
- Classification: `TEST HARNESS FIX`, not a product failure.
- Product invariant is unchanged: the customer remains selected through the
  canonical checkout control. The corrected test must open `Atur pembayaran`
  before selecting and must retain all posting/reset assertions.
- No assertion is removed or weakened.

## Rollback / forward-fix note

This slice has no database mutation. Rollback is a source revert of the narrow
PWA display changes. If local or live smoke contradicts the expected reset or
customer identity, stop patching and return to read-only audit before any
follow-up change.

## Verification checkpoint

- PWA `oxlint`: PASS.
- PWA TypeScript + Vite production build + service worker generation: PASS.
- Playwright focused Retail and runtime-contract matrix: `10/10 PASS`.
- Covered behavior: named Customer visibility, direct Retail Pickup post,
  receipt customer, Invoice/no Surat Jalan boundary, reset to empty Cart and
  Walk-In customer, customer-first Session Summary with DRF/Invoice retained,
  canonical opening session cash, per-method Cash/QRIS totals, split-payment
  labeling, plus existing Retail/Backoffice runtime boundaries.
- Status: `AUDIT COMPLETE / LOCAL READY`.
- Not claimed: `CLIENT DEPLOYED`, `AUTHENTICATED SMOKE PASS`, or `UAT PASS`.
- Live production inspection was read-only and no Company context was changed.

## Refund-method follow-up checkpoint (points 5 and 9)

- Dedicated impact audit:
  `docs/audits/POS_SALES_RETURN_REFUND_METHOD_UI_IMPACT_2026-10-31.md`.
- Pure Return-note contract test: PASS.
- PWA lint and production build: PASS.
- Backoffice focused ESLint and production build: PASS.
- Combined mocked Retail plus runtime-contract Playwright: `11/11 PASS`.
- Status: points 5 and 9 are `AUDIT COMPLETE / LOCAL READY`; no migration or
  production data change was needed.
- Not claimed: `CLIENT DEPLOYED`, `AUTHENTICATED SMOKE PASS`, or `UAT PASS`.
- Remaining Task 2 workflow item: point 10, Ketul intake-for-discount. It stays
  deferred to a separate domain/workflow audit.
