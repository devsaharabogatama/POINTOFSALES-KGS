# KGFF Sample zero-price discount compatibility impact audit

Date: 2026-11-03
Classification: `PRODUCT_BEHAVIOR_CHANGE`
Phase: A - read-only audit
Failure classification: `PRODUCT FIX`

## Incident and expected outcome

The authenticated KGFF POS smoke exposed
`LINE_DISCOUNT_EXCEEDS_LINE_TOTAL` after the `KGS003 / SALES KGS` Customer
Pricelist resolved a sale line to Rp0. The Pricelist rollout itself is live and
its resolver behavior passed, but that test did not cover a cart or Draft that
already carried a positive Product discount.

Expected compatibility behavior:

- an authoritative zero effective unit price cannot carry a Product discount;
- the POS must remove that meaningless discount before saving the Draft and
  make the removal visible to the cashier;
- positive-price lines, percentage discounts, per-unit discount semantics,
  price override, other Customers, and Backoffice behavior remain unchanged;
- the database guard remains fail-closed for forged or stale payloads;
- this compatibility fix does not claim that the separate zero-total Sample
  Stock/FIFO/Finance posting flow is complete.

## Proven active execution path and identifier sources

| Path / identifier | Defining evidence |
|---|---|
| Customer selection | `pwa/src/App.tsx::selectCustomer` clears the selected Pricelist and resolved lines, but does not clear Product discounts |
| Authoritative catalog preview | `pwa/src/App.tsx` calls `previewPosSalePrices`; `pwa/src/lib/pos.ts::previewPosSalePrices` invokes `preview_pos_sale_prices` and returns `unitPrice` per Product-UOM |
| Draft payload | `pwa/src/App.tsx::draftLines` sends `lineDiscountType`, `lineDiscountInput`, and `lineDiscountAmountBasis` unchanged |
| Draft save | `pwa/src/App.tsx::persistDraft` delegates to `pwa/src/lib/pos.ts::saveSaleDraft` |
| Retail repricer | `supabase/migrations/20261102160000_pos_retail_per_unit_product_discount.sql::private.reprice_pos_sale_draft` wraps the previously active repricer and converts per-unit nominal discount to the effective line amount |
| Canonical rejection | `supabase/migrations/20260729070000_g4_phase4_atomic_sale_runtime.sql` calculates `v_line_gross = resolved price * quantity` and raises `LINE_DISCOUNT_EXCEEDS_LINE_TOTAL` when the submitted discount is greater than gross |
| Offline equivalent | `pwa/src/lib/offlineCheckout.ts::priceOfflineCheckout` contains the same fail-closed comparison |
| Sample Pricelist state | User-supplied postflight proves migration `20261103100000`, one exact SALES KGS assignment, and 78/78 active zero-price rules; user also reported resolver behavior PASS |

No new database identifier is introduced by this client compatibility patch.

## Root cause

The zero-price Pricelist and Product discount features are individually valid,
but their composition was absent from the regression matrix. A Cart item can
retain a positive discount when Customer/Pricelist repricing changes its
canonical price to zero. The client preview renders the net value as zero, yet
`draftLines()` still sends the old positive discount. The server correctly
rejects the invalid commercial shape instead of silently accepting it.

The failure is therefore not repaired by weakening the server assertion or by
changing the Pricelist. The client must normalize the impossible combination
using the same authoritative preview used to display the Customer price.

## Impact map

### Direct impact

- Online Retail POS Draft persistence and Product editor presentation.
- Only Cart lines whose effective unit price is proven zero by the server
  preview and which do not have a positive manual price override.
- Positive Product discount state is cleared before the Draft payload is sent.

### Downstream impact

- The canonical repricer receives a zero-price line with no Product discount.
- Sale amount remains zero for the line; no pricing rule or Product base price
  changes.
- The server remains authoritative and continues rejecting forged positive
  discounts against a zero gross amount.

### Explicitly unchanged

- Backoffice Sales Order and its whole-line discount semantics.
- Positive-price Retail POS discount behavior, including ordinary per-unit
  nominal discount and Lettuce/Bawang Bombay whole-line exceptions.
- Percentage discount, global transaction discount on positive totals, manual
  price override, tax, rounding, Tempo, Pickup/Delivery, and split payment.
- Stock, Reservation, FIFO/HPP, cashier session, Payment verification, Finance
  Event/queue/Journal, audit, historical Posted Sales, and other Companies.
- Offline Sample checkout remains outside this patch; the existing offline
  guard continues to reject a discount larger than the offline-resolved gross.

## Compatibility, concurrency, retry, and rollback

- Existing Posted Sales are immutable and untouched.
- Existing Drafts are not bulk rewritten. When opened and repriced online, a
  zero-price line is normalized before the next save.
- Exact retry sends the same normalized commercial payload.
- Stale version, Draft lock, tenant, actor, and idempotency guards remain in the
  existing save/post chain.
- No schema or data migration is required. Rollback before deployment is the
  client diff; after deployment, use a client forward-fix rather than modifying
  live migration `20261103100000` or `20261102160000`.

## Regression matrix

| Case | Required result |
|---|---|
| SALES KGS, zero price, no prior discount | Draft line saves with price 0 and no Product discount |
| SALES KGS, zero price, prior AMOUNT discount | POS visibly removes discount; no line-discount error |
| SALES KGS, zero price, prior PERCENT discount | POS visibly removes discount; no line-discount error |
| Zero canonical price with positive allowed price override | Discount remains applicable to the positive override price |
| Mixed zero- and positive-price Cart | Only zero-price line discount is removed |
| Positive-price ordinary Product | Per-unit nominal discount remains unchanged |
| Lettuce/Bawang Bombay | Whole-line nominal exception remains unchanged |
| Customer switched back to ordinary pricing | New discounts can be entered normally |
| Existing Draft resumed | Online authoritative reprice normalizes only an impossible zero-price discount |
| Save/Post exact retry and stale version | Existing idempotency / stale-version behavior preserved |
| Backoffice | No client or server behavior change |
| Offline | Existing fail-closed behavior preserved; no Sample enablement claim |

## Database state and remaining boundary

- `20261103100000`: `INSTALLED_CONSISTENT` within the user-supplied postflight
  and resolver behavior assertions.
- `20261102160000`: `INSTALLED_CONSISTENT` within the previously supplied
  postflight and rollback behavior assertions.
- Client compatibility for zero-price plus existing Product discount:
  `FIXED LOCALLY / NOT DEPLOYED` after Phase B.
- User evidence identifies the affected Draft as `DRF-20261102-000558`,
  Customer `SALES KGS`, one item, total Rp0. Persisted downstream effects remain
  `BELUM TERBUKTI`; this client fix does not repair or rewrite database rows.
- Zero-total Sample Stock/FIFO/Finance posting and Sample/Promotion Expense
  mapping remain a separate closed gate and must not be claimed by this fix.

## Phase B verification requirements

1. Add unit/static coverage for zero-price AMOUNT and PERCENT normalization,
   positive override preservation, and positive-price behavior.
2. Add mocked browser coverage for Customer repricing with an existing Product
   discount and visible cashier feedback.
3. Run PWA lint, build, scoped tests, and `git diff --check`.
4. Deployment remains prohibited without explicit user instruction.
5. After deployment, run authenticated KGFF smoke. Do not interpret local or
   mocked PASS as `SMOKE PASS` or `UAT PASS`.

## Phase B implementation and evidence

- The online Retail POS now requests an authoritative price preview before
  saving or resuming a Draft. A positive Product discount is removed only when
  the effective line price is zero and no positive manual price override is
  present.
- The Product editor disables Product-discount input for a proven zero-price
  line and shows the cashier why the discount is unavailable.
- Existing Draft resume uses the same normalization path before calling the
  canonical Draft saver. Backoffice cutover Drafts remain outside this path.
- `npm.cmd run lint` in `pwa`: PASS.
- `npm.cmd run build` in `pwa`: PASS (existing bundle-size warning only).
- Playwright mocked POS plus runtime-contract regression: `38/38 PASS`, covering
  new Cart normalization, exact existing-Draft resume, positive price override,
  and ordinary positive-price discount behavior.
- Two initial failures were classified as `TEST_HARNESS_FIX`: one locator
  assumed a dialog role that the existing Draft panel does not expose; one
  assertion matched hidden select-option text rather than the visible Cart
  note. Product assertions and exact RPC-payload checks were retained.

Status: `AUDIT COMPLETE`, `LOCAL READY`; database configuration remains live
from the existing migration, while this client fix is `CLIENT DEPLOYED: NO`,
`SMOKE PASS: NO`, and `UAT PASS: NO`.
