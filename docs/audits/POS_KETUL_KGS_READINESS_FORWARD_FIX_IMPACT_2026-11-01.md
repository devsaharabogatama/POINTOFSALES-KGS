# POS Ketul KGS readiness forward-fix impact audit

Date: 2026-11-01  
Classification: `SCHEMA_OR_MIGRATION_CHANGE + PRODUCT_BEHAVIOR_CHANGE`

## Expected business outcome

The approved linked Ketul intake is not a KGFF-only business flow. It must be
available to a Company only when both conditions are true:

1. the Company entitlement `ketul_enabled` is active; and
2. the complete Company-owned catalog, payment, and Finance runtime contract is
   ready.

The urgent live case is KGS. KGS currently shows the Ketul action in the POS,
but the server configuration required to post it exists only for KGFF. The
forward fix must provision the already-approved dedicated Ketul liability
contract for KGS and add a generic server-side readiness gate. It must not
blindly provision Companies whose entitlement is disabled or whose Finance
authority has not been proved.

All functional rules from
`POS_KETUL_CUSTOMER_INTAKE_OFFSET_IMPACT_2026-10-31.md` remain unchanged:
Ketul value is an after-tax settlement offset, not a Sales discount; intake and
Sale post atomically; normal tender pays the remainder; the internal Ketul
method remains hidden; Tempo and Offline remain unsupported; existing Sales
Return does not reverse received Ketul.

## Evidence and migration state

The installed migration `20261031110000_pos_ketul_customer_intake_offset.sql`
is immutable. User-returned Production postflight proves its ledger row and all
nine KGFF contracts. The runtime tables and RPCs created by that migration are
Company-scoped and generic, but its Finance provisioning block hard-codes the
KGFF UUID. This is the exact configuration-scope defect.

Read-only Production evidence collected on 2026-11-01 proves:

- KGS `d290f1ee-6c54-4b01-90e6-d701748f0851` and KGFF
  `a59c534b-909f-4b3f-aba0-ae9db6d90b76` are the only Companies with active
  `ketul_enabled` entitlement;
- each has one active `KETUL` Product Category and exactly four active,
  non-bundle products;
- KGS has active user-owned `1030100-4 / PERSEDIAAN KETUL` and its current
  version-2 `KETUL_CUSTOMER_INTAKE / INVENTORY_ASSET` rule; the old system
  account rule is version 1 and has `effective_to` populated;
- KGS has active user-owned `2010105 / HUTANG LAIN-LAINNYA`, but no
  `2010105-1`, no `CUSTOMER_KETUL_PAYABLE` rule/fallback, and no
  `KETUL_OFFSET` method;
- KGFF has the approved independent postable liability
  `2010105-1 / HUTANG KETUL CUSTOMER`, the payable direct rule/fallback, and
  one active system-only `KETUL_OFFSET / INTERNAL_LIABILITY` method;
- the global `CUSTOMER_KETUL_PAYABLE` function and Ketul system-event contract
  already exist because the installed migration is live.

Database classification:

- KGFF: `INSTALLED_CONSISTENT` for configuration and postflight; Production
  rollback-only behavior rerun remains unreported;
- KGS: `PARTIAL/INCONSISTENT` because entitlement and inventory authority are
  active while payable/method authority is absent;
- other Companies: not in the activation scope; their entitlement is disabled.

One initial read-only REST probe used nonexistent `products.product_name` and
was rejected with `42703`. That product result was discarded. The defining
migrations prove the canonical column is `products.name`; the corrected query
then proved the two exact category/product counts. No Production write was
performed.

## Active call chain

1. `pwa/src/lib/pos.ts::loadCatalog` currently reads
   `company_features.ketul_enabled` directly.
2. `pwa/src/App.tsx` renders `Pengembalian Ketul` when that boolean is true.
3. `KetulIntakeModal.tsx` records product, quantity, and unit price.
4. `saveSaleDraft` calls `save_pos_sale_draft_with_ketul(jsonb)`.
5. `postSale` calls `post_pos_sale_with_ketul(uuid,bigint,uuid)`.
6. The installed generic composition validates Company/Session/Product/value,
   derives the hidden `KETUL_OFFSET` leg, delegates the direct Retail Sale post,
   receives Stock/FIFO, and creates the Ketul Event/Journal.
7. The post core resolves `INVENTORY_ASSET` and
   `CUSTOMER_KETUL_PAYABLE`. KGS currently cannot resolve the latter and cannot
   find the derived internal payment method.

The forward path becomes:

`active Company -> get_pos_ketul_readiness() -> UI gate -> existing generic
save/post composition -> Stock/FIFO + payable Event/Journal`.

## Identifier sources

- `companies.company_code`, `company_features`, and active Company context:
  `20260720090000_g1_phase1_security_feature_foundation.sql` and
  `20260720180000_g1_phase4_active_company_context.sql`.
- Product Category/Product fields:
  `20260721180000_g2_phase1_master_data_foundation.sql` and legacy Product
  baseline.
- Payment Method columns and `KETUL_OFFSET` enum contract:
  `20260722120000_g2_phase14_payment_method_foundation.sql`.
- account functions, direct rules, fallback rules, Event account resolver:
  `20260722150000_g2_phase16_finance_master_foundation.sql` and subsequent
  guarded Finance migrations.
- KGS user-owned COA authority:
  `20261006150000_kgs_retail_pos_user_coa_activation.sql` plus the exact
  Production rows above.
- Ketul tables/RPCs and approved KGFF Finance shape:
  `20261031110000_pos_ketul_customer_intake_offset.sql`.

## Impact map

### Direct impact

- KGS receives one independent postable liability account
  `2010105-1 / HUTANG KETUL CUSTOMER` with no structural parent, matching the
  approved KGFF authority.
- KGS receives one current direct rule and one current fallback for
  `CUSTOMER_KETUL_PAYABLE`.
- KGS receives one active, system-only `KETUL_OFFSET / INTERNAL_LIABILITY`
  method.
- A generic authenticated readiness RPC validates entitlement, Ketul catalog,
  current user-owned inventory/payable mappings, payable fallback, and the
  internal method.
- PWA Ketul visibility uses server readiness, not entitlement alone.
- A readiness RPC error fails closed only for the optional Ketul action; it
  does not prevent the remaining POS Catalog from loading. Database-first
  rollout remains the required order.

### Downstream impact

- KGS direct Retail POS can use the already-installed Ketul composition.
- Ketul Stock/FIFO inbound and the Dr Inventory / Cr Ketul Payable Finance
  Event become reachable for KGS.
- external Cash/non-cash payment processing continues to receive only the Sale
  remainder; Finance verification must never capture the internal Ketul leg.
- session totals, Return, Backoffice/ODR, Tempo, Offline, and ordinary payment
  picker remain unchanged.

### Regression risks

- a readiness test that checks only entitlement would repeat the current defect;
- applying the KGFF UUID or account IDs to KGS would violate tenant ownership;
- activating all Companies would invent Finance authority;
- selecting the expired KGS system Inventory rule would revive system-account
  posting;
- exposing `KETUL_OFFSET` in normal tender would allow settlement without
  intake evidence;
- changing the installed migration would break ledger immutability.

### Explicitly preserved

- installed migration `20261031110000` and all historical rows;
- KGFF account, rules, fallback, payment method, and runtime behavior;
- KGS `2010105` and all of its existing consumers;
- Product prices, Sale tax base, rounding, external payment legs, non-cash
  verification, Customer Receipt, Return/refund, Backoffice/ODR, Stock
  reservation, negative-stock, and Cashier Session behavior;
- Companies other than KGS/KGFF;
- Posted Ketul correction remains a documented gap and is not silently added.

## Concurrency, idempotency, retry, rollback

The configuration migration is guarded by exact absence/presence checks and
one migration ledger row. Existing Ketul save/post idempotency and stale-version
guards remain the authority. The readiness RPC is read-only and Company-context
scoped. Installation creates configuration only and must create no Sale,
Payment, Stock, FIFO, Event, Journal, or Session effect.

The installed migration must never be replayed or edited. A defect in this
forward package requires a newer forward migration. Business effects continue
to use the existing atomic Ketul transaction and rollback behavior.

## Test matrix

| Dimension | Required evidence |
|---|---|
| KGFF | readiness remains true; exact existing configuration unchanged |
| KGS | readiness false before install, true after exact configuration |
| Other Company | disabled entitlement returns false and creates no config |
| Tenant | cross-Company account/method/rule cannot satisfy readiness |
| Catalog | missing/inactive category or no active product blocks readiness |
| Finance | expired/system Inventory rule does not satisfy readiness |
| Payment | internal method stays absent from ordinary payment references |
| Cash/non-cash/split | existing external legs pay only remainder |
| Tempo/Offline | existing rejection and offline-disabled behavior preserved |
| Session | OPEN permits existing composition; closed remains rejected |
| Stock/FIFO/Event/Journal | KGS rollback-only post proves one atomic effect |
| Retry/stale | exact retry idempotent; changed retry/stale version rejected |
| Return | sold-line Return remains independent of received Ketul |
| Backoffice/ODR | unchanged and no Ketul UI on cutover Draft |
| Installation | zero business rows created |

## Remaining gate

Before any Production rollout: exact preflight, forward migration, postflight,
KGS rollback-only behavior, authenticated local POS smoke, then explicit user
approval for deployment. No Production mutation or client deployment is
authorized by this task.

## 2026-11-01 Production behavior failure and re-audit

The first user-run KGS rollback-only behavior reached the installed pricing
runtime and failed with `ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND` while selecting a
non-Ketul Sale fixture. This failure revokes the earlier `LOCAL READY` wording
for the behavioral package. It does not prove a Ketul product-runtime defect.

The active resolver contract is proved by:

- `20260729070000_g4_phase4_atomic_sale_runtime.sql`, lines 378-429: argument
  four is `p_product_uom_id`; the resolver additionally requires an active
  Product, active UOM, active/sales-allowed Product UOM, and non-null,
  nonnegative `sale_price`;
- `20260729210000_g4_phase12_offline_sale_sync.sql`, lines 322-351: the Offline
  wrapper preserves that exact Product-UOM identifier and delegates it to
  `resolve_pos_sale_price_online_core`;
- later terminal and Backoffice wrappers preserve the same signature and
  identifier semantics.

The failed KGS fixture passed `product_uoms.id`, which is correct, but its
candidate query did not join an active `uoms` row and did not require
`candidate.sale_price IS NOT NULL AND candidate.sale_price>=0` before invoking
the resolver in the select/filter expression. An otherwise ineligible row can
therefore reach the fail-closed resolver and raise before a valid candidate is
selected. The older KGFF Ketul behavior contains the same incomplete fixture
predicate.

Classification: `TEST_HARNESS_FIX`. The product RPCs, migration, schema,
assertions, expected business outcome, and Production data must not change.
The corrected fixture must mirror the resolver's eligibility predicate, retain
the positive-price and positive-FIFO requirements, and rerun the same complete
rollback-only assertions. Because the failure occurs before authentication
context setup and before any mutation call, the failed transaction produced no
Sale, Payment, Stock, FIFO, Event, Journal, or Session effect.

## Local implementation evidence

- guarded forward migration `20261101120000` compiles and commits on a
  PostgreSQL 18 disposable fixture;
- the exact preflight returns `PASS/ROOT_CAUSE` for all eight rows on that
  fixture;
- the readiness RPC returns `enabled=true`, `ready=true`, no blocker, and four
  products after migration;
- the exact postflight returns six `PASS` plus the business-boundary `INFO`;
- PWA TypeScript/Vite build and oxlint PASS;
- focused mocked Retail/runtime Playwright is `4/4 PASS`, including the
  fail-closed entitlement-without-readiness case;
- the first disposable migration attempt stopped only because the minimal
  fixture omitted Supabase roles `anon`, `authenticated`, and `service_role`.
  Classification: `FIXTURE FIX`; the migration transaction rolled back. After
  adding those canonical fixture roles, the identical migration passed.

The minimal disposable schema does not contain the full Sale/Session/
Stock/FIFO runtime, so it cannot provide the required end-to-end behavior
proof. The first Production behavior run subsequently exposed the incomplete
Product-UOM fixture predicate documented above and rolled back before mutation.
Both KGS and KGFF behavior fixtures now materialize the complete canonical
resolver eligibility set before calling the resolver. PostgreSQL libpg_query
parses both complete outer SQL files and both corrected fixture queries; each
file retains exactly one `BEGIN`, one `ROLLBACK`, and one resolver call. This is
test-harness syntax and invariant evidence only. The corrected KGS Production
rollback behavior remains pending and is not represented as PASS.

The corrected Production rerun then passed the Product-UOM fixture boundary and
stopped at `current KGS accounting period must be open`. A read-only Production
REST audit proved the exact state: KGS is `MANUAL / CONTROLLED`, October 2026 is
OPEN, and no November 2026 period exists. The installed Ketul posting core calls
`ensure_company_accounting_periods`, which intentionally creates periods only
for `AUTOMATIC` Companies, then requires an `OPEN/REOPENED` period for the
posting date. This is therefore a real Finance configuration blocker, not a
second test-harness defect. No assertion or product runtime may be bypassed.
The required next action is an authorized user creating November 2026 through
Backoffice Finance > Periode, followed by the same rollback-only behavior rerun.
