# POS Retail per-unit Product discount impact audit

Date: 2026-11-02
Classification: `SCHEMA_OR_MIGRATION_CHANGE` + `PRODUCT_BEHAVIOR_CHANGE`
Phase: A - read-only audit

## Requested outcome

- In direct Retail POS, nominal Product discount (`AMOUNT`) means an amount per
  sold UOM for ordinary Products. Quantity 10 and input Rp100 therefore produces
  a Rp1.000 line discount.
- Lettuce and Bawang Bombay retain the current whole-line nominal discount.
- Percentage discount remains a percentage of line gross.
- The Product editor subtotal reacts immediately to quantity, effective unit
  price, and discount input before the cashier confirms the editor.
- Backoffice Sales Order behavior remains whole-line and is not changed.

## Source of truth and identifiers

| Identifier / behavior | Defining evidence |
|---|---|
| POS server recalculation is mandatory | `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`, cross-module invariant 9 |
| `products`, `product_uoms` | `20260721180000_g2_phase1_master_data_foundation.sql` |
| Product mutation | `20260721210000_g2_phase4_atomic_product_crud.sql`, tax overload `20260723040000`, permission wrappers `20260812150000` |
| Retail POS repricer | `20260729070000_g4_phase4_atomic_sale_runtime.sql`, active outer wrappers `20260811143000` and `20260825120000` |
| Offline catalog | `20260730010000_g4_phase14_offline_catalog_snapshot.sql` |
| Retail/Backoffice Company mode | `company_sales_process_settings.active_mode`, founded by `20260909162000_sales_process_cutover_foundation.sql` |
| Backoffice discount runtime | independent `save_backoffice_sales_order_draft` chain, commercial calculation in `20260909140000_backoffice_sales_commercial_parity.sql` |
| PWA online payload | `pwa/src/App.tsx::draftLines`, `pwa/src/lib/pos.ts::saveSaleDraft` |
| PWA offline calculation | `pwa/src/lib/offlineCheckout.ts::priceOfflineCheckout` |

No table, column, RPC, enum, or Product identity below is inferred from naming
alone.

## Proven current execution path

### Online Retail POS

1. `pwa/src/App.tsx` stores `discountType` and `discountInput` on each Cart item.
2. `draftLines()` sends `lineDiscountType` and `lineDiscountInput` unchanged.
3. `pwa/src/lib/pos.ts::saveSaleDraft()` invokes
   `save_pos_sale_draft_with_ketul(jsonb)`.
4. The Ketul wrapper delegates to the normal POS Draft saver and active
   `private.reprice_pos_sale_draft(...)` chain.
5. The canonical core currently calculates `AMOUNT` as
   `round(lineDiscountInput, 4)`, independent of quantity.
6. The final amount is stored in `sales_details.line_discount_amount`; raw input
   is stored in `sales_details.line_discount_input` and the Draft payload.

### Offline Retail POS

1. `priceOfflineCheckout()` currently calculates `AMOUNT` as the raw input.
2. The queued payload also sends the same raw input.
3. Sync reaches the same canonical POS repricer. Online/offline semantics must
   therefore change together.

### Backoffice

Backoffice does not call the POS PWA editor or offline calculator. Its active
`save_backoffice_sales_order_draft` chain separately calculates nominal
discount as a whole-line amount. That path is explicitly preserved.

## Proven UI defect

`editingResolvedLine?.lineTotal` is preferred in the Product editor. This is the
last server-resolved value, so current quantity/price/discount input is not
reflected until the edit is confirmed and repriced. The fallback subtotal also
treats nominal discount as whole-line. A local preview helper must use the same
basis as the server and must be presentation-only; persisted totals remain
server-authoritative.

## Production read-only evidence

Read-only REST queries using the existing server-only credential proved:

- Retail Companies: BFF, KGFF, KGS, and NB-01020120.
- Exact active exception identities exist only in KGS and KGFF:
  - `L / Lettuce`;
  - `BB / Bawang Bombay`.
- BFF and NB-01020120 currently have no exact matching Product.
- 239 open direct Retail POS Drafts exist.
- Two open Draft lines have an old nominal discount and no basis snapshot:
  - KGS `DRF-20260916-000420`, `DB / Daging Burger Sapi`, quantity 10,
    input 500;
  - KGS `DRF-20261030-000471`, `L / Lettuce`, quantity 10.78, input 480.
- There are zero nonterminal Offline submissions and zero queued Offline lines
  with nominal discount.
- `products.pos_line_discount_amount_basis` does not exist (`42703`).

The two open legacy Draft lines prove that silently deriving the new meaning
from the current Product would corrupt an existing Draft. Compatibility needs
an explicit line-level basis snapshot.

## Design constrained by the evidence

1. Add a Product configuration with values `PER_UNIT` and `LINE_TOTAL`, default
   `PER_UNIT`.
2. Configure only the proven exact `L / Lettuce` and `BB / Bawang Bombay`
   rows as `LINE_TOTAL`. Missing Products in another Retail Company are not
   invented or inserted.
3. Add a line snapshot to `sales_details`; historical `AMOUNT` lines are
   `LINE_TOTAL`, matching the only behavior that existed when they were made.
4. Before enabling the new contract, backfill every open Retail POS Draft line
   with `AMOUNT` to explicit `lineDiscountAmountBasis='LINE_TOTAL'` so its meaning
   cannot change.
5. New PWA lines send the Product basis. The server validates it against the
   Product master and recalculates the amount. The client cannot choose a more
   favorable basis.
6. New Retail POS `PER_UNIT` amount is `input * quantity`; `LINE_TOTAL` remains
   `input`. Percentage is unchanged.
7. Offline snapshot and offline calculator carry the same basis.
8. Backoffice calculation and UI remain whole-line. Cutover converters preserve
   already-calculated amount and are regression-tested.

## Impact map

### Direct impact

- Product configuration and immutable Sale-line snapshot.
- Active Retail POS repricer wrapper.
- Offline catalog snapshot and calculator.
- PWA Product type, Cart/Draft restore, payload, and live subtotal display.

### Downstream impact

- `sales_details.line_discount_amount`, Sale subtotal, tax base, global discount
  allocation, payment total, receipt/Invoice display, and Finance discount
  posting consume the recalculated final amount.
- No Stock quantity, Reservation, FIFO, or HPP formula changes. They still use
  quantity and Product identity; only commercial totals change.
- Cashier Session payment totals change only because the Sale payable amount is
  legitimately lower.

### Regression risks

- reinterpreting legacy Drafts;
- online/offline disagreement;
- letting a client forge `LINE_TOTAL` for a per-unit Product;
- applying POS semantics to Backoffice Sales Orders;
- stale server preview hiding local editor changes;
- discount greater than line gross after multiplication;
- tax and rounding using the wrong pre-discount base;
- retry producing a different result after Product configuration changes.

### Compatibility and retry

- Posted historical rows are not recalculated.
- Existing open Drafts receive an explicit legacy `LINE_TOTAL` snapshot.
- Once a Draft has an explicit basis, exact retry retains that basis. A Product
  configuration change cannot silently rewrite its meaning.
- Version, tenant, actor, terminal, Draft lock, and idempotency guards remain in
  the existing save/post chain.

## Required test matrix

| Case | Expected |
|---|---|
| ordinary Product qty 10, AMOUNT 100 | discount 1.000, live net subtotal |
| Lettuce qty 10.78, AMOUNT 480 | discount 480, not 5.174,4 |
| Bawang Bombay qty 10, AMOUNT 100 | discount 100 |
| PERCENT on all three | existing percent-of-gross behavior |
| quantity and price override edits | subtotal updates before Confirm |
| discount exceeds gross | rejected client preview and server |
| old DB Draft | remains whole-line after resume/save/retry |
| online and offline | equal resolved discount and total |
| exact retry / stale version | idempotent retry / stale denial |
| Retail POS vs Backoffice | new semantics only in Retail POS |
| same/cross Company | exact tenant Product configuration only |
| tax, global discount, rounding | downstream total uses resolved line amount |
| payment, Session, Finance | balance and Journal remain consistent |

## Migration/database state

- Latest user-confirmed live chain includes `20261102150000`.
- Proposed version `20261102160000` is not present in the repository.
- Production probe proves the proposed Product column is absent.
- Classification: `NOT_INSTALLED` for this feature.
- The SELECT-only preflight is
  `supabase/diagnostics/pos_retail_per_unit_product_discount_preflight.sql`.

## Phase B implementation and evidence

Local Phase B adds:

- guarded migration
  `supabase/migrations/20261102160000_pos_retail_per_unit_product_discount.sql`;
- SELECT-only preflight and postflight under `supabase/diagnostics/`;
- authenticated rollback-only behavior
  `supabase/tests/pos_retail_per_unit_product_discount_behavior.sql`;
- online/offline PWA basis propagation and live Product-editor subtotal;
- mocked browser and static runtime regression coverage in `qa-e2e/tests/`.

The migration is deliberately database-first compatible. Existing open Retail
POS nominal-discount Drafts are snapshotted as `LINE_TOTAL`; an old client that
omits the field receives that legacy basis once. A new client must submit the
Product-configured basis, and a persisted Draft cannot be reinterpreted.

Local evidence:

- PWA lint: PASS;
- PWA TypeScript/Vite build: PASS;
- complete mocked POS/runtime Playwright suite: `35/35 PASS`;
- `git diff --check` for the scoped files: PASS;
- SQL identifiers and complete statement boundaries reviewed against defining
  migrations.

The machine has no local PostgreSQL/Docker runtime for full Product-schema SQL
execution. Supabase CLI also cannot write its telemetry file inside the current
sandbox. Therefore migration compile and database behavior are explicitly
`BELUM TERBUKTI`; browser/static PASS must not be treated as database proof.

## Rollout and rollback / forward-fix note

Order is strict:

1. run the SELECT-only preflight;
2. stop unless every mandatory row is PASS and state is `NOT_INSTALLED`;
3. apply migration `20261102160000` exactly once;
4. run the SELECT-only postflight;
5. run the rollback-only behavior test;
6. deploy the PWA only after both database checks pass;
7. authenticated smoke ordinary Product, Lettuce, Bawang Bombay, percentage,
   old Draft resume, and Offline before UAT.

The migration is forward-only. If an installed runtime defect appears, do not
edit or rerun `20261102160000`; freeze client deployment and create a new
guarded forward migration. Before database installation, rollback is simply to
discard the local candidate and client changes together.

## Current status

- `AUDIT COMPLETE`: YES.
- `CLIENT LOCAL VERIFICATION`: PASS (`35/35` mocked/static; build/lint PASS).
- `DATABASE PACKAGE`: CREATED, SQL execution `BELUM TERBUKTI`.
- `DATABASE LIVE`: NO.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO.
- `UAT PASS`: NO.

## 2026-11-02 failed migration attempt re-audit

The first Production execution stopped inside the transaction at the exact
Product exception update with PostgreSQL `42702`:

`column reference "master_version" is ambiguous`.

Root cause is syntactic and proven from the active statement: the target alias
`product` and `company_sales_process_settings setting` are both in the
`UPDATE ... FROM` namespace and both expose `master_version`. The right-hand
expression used the unqualified identifier `master_version`; PostgreSQL cannot
choose its source. The intended source is the target Product row, therefore the
correct expression is `product.master_version + 1`.

Classification: `PRODUCT FIX` to the uninstalled migration candidate. This is
not a business-rule, fixture, or assertion change. The error occurred before
the migration ledger insert and before `COMMIT`; the transaction cannot install
partial DDL/DML. Nevertheless, the corrected preflight must be rerun to prove
the live state remains `NOT_INSTALLED` before another migration attempt.

Regression boundary remains unchanged: only Product configuration versioning
is qualified; discount basis, Draft backfill, POS repricing, Offline, and
Backoffice behavior are not altered by this correction.

## 2026-11-02 preflight result-set failure

The corrected preflight execution returned only
`pos_retail_per_unit_discount_business_boundary`. This is not evidence that the
mandatory checks passed. Root cause is proven in the file: it contains seven
semicolon-separated `SELECT` result sets. The Supabase SQL Editor surfaced only
the final result set, hiding dependency, installation-state, runtime-anchor,
Product-identity, legacy-Draft, and Offline rows from the user.

Classification: `TEST_HARNESS_FIX`. Product code, migration behavior, expected
values, and business assertions must not change. The correction must return all
seven existing checks from one SQL statement/result set. Until that corrected
preflight is rerun, migration state is `UNKNOWN` and migration execution is
blocked.

The first static contract for this correction failed because it counted a
semicolon inside a `--` comment as an executable SQL statement terminator.
The preflight itself has one top-level `WITH`, seven check identifiers joined by
`UNION ALL`, and one executable terminal semicolon. This failure is separately
classified `TEST_HARNESS_FIX`: strip SQL line comments before counting
terminators; do not change the expected executable statement count of one.

The first harness correction still failed because a second semicolon lives
inside the SQL string literal describing the exception rule. The corrected
counter must ignore both line comments and single-quoted SQL literals before
counting terminators. Expected executable statement count remains one; no
Product/preflight assertion may be removed.

The user reran the unified preflight and supplied all seven rows. Dependency
ledger, exact exception Products, installation state, legacy Draft partition,
Offline boundary, and runtime anchors are all PASS; business boundary is INFO.
State is proven `NOT_INSTALLED`, with four exact active exception Products,
239 open Retail POS Drafts, two legacy nominal-discount lines without a basis,
and zero nonterminal Offline submissions. This evidence authorizes one guarded
execution of migration `20261102160000`; it does not prove migration,
postflight, behavior, deployment, smoke, or UAT success.

The user subsequently reported that guarded migration `20261102160000`
executed successfully. This report is not substituted for postflight evidence:
ledger count, schema contract, Product configuration, Draft snapshot backfill,
runtime wrapper, Backoffice boundary, and zero business effect must still pass
the SELECT-only postflight. The next action is postflight, followed only on full
mandatory PASS by the rollback-only behavior test.

The complete Production postflight later supplied by the user passed every
mandatory assertion: one ledger row, both non-null schema columns, exactly four
configured exception Products, no invalid ordinary/exception Product, zero
missing basis across the two legacy nominal-discount Draft lines, one guarded
security-definer repricer with server validation, preserved Backoffice
whole-line behavior, and zero installation Stock/Finance effects. The user also
reports the rollback-only behavior test succeeded. Classification is therefore
`DATABASE LIVE` within those assertions. Client deployment, authenticated POS
smoke, and UAT are not proven.
