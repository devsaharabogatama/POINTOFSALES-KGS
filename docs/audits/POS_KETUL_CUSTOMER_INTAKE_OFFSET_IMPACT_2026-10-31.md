# POS Ketul Customer Intake Offset - Phase A Impact Audit

Date: 2026-10-31  
Task classification: `SCHEMA_OR_MIGRATION_CHANGE`  
Status: `AUDIT COMPLETE / LOCAL READY / PRODUCTION NOT INSTALLED`  
Mutation performed by this audit: `NONE`

## 1. Expected business outcome

The approved scope is limited to Ketul received from a Customer while a direct
Retail POS Sale is being checked out:

- Cashier opens **Pengembalian Ketul** and may enter multiple rows.
- Each row must resolve to an active Product in the current Company's exact
  `KETUL` Product Category. Quantity and acquisition unit price are entered by
  the Cashier and must both be positive.
- Duplicate Product rows are merged server-side before valuation.
- The Customer may be Walk-In.
- Ketul value is applied after Sale tax and rounding, cannot exceed the Sale
  amount, and therefore does not reduce the tax base.
- The remaining amount is paid through the existing payment-leg workflow.
- Ketul inventory is received when the Sale is successfully Posted. Sale and
  Ketul intake are one atomic business operation.
- Ketul value is presented as `Potongan Ketul`, but accounting treats it as
  settlement of a Ketul payable, not Sales discount or negative revenue.
- The feature is online-only.
- Vendor processing, standalone Ketul intake/payout, Customer Balance credit,
  and Vendor payment are explicitly deferred.

For an incorrect Posted Ketul intake, correction must use an append-only
Ketul-specific reversal/correction available only to Store Manager, Company
Admin, and Super Admin. It must not silently edit posted Stock, FIFO, Event, or
Journal history.

The existing Sales Return workflow remains the correction path for sold Sale
lines. A partial/full Sales Return refunds the selected sold lines under the
existing rules; it does not remove Ketul already received into store Stock.

## 2. Sources of truth read

- User decisions in the active task, including after-tax offset, Walk-In,
  online-only, value cap, correction authority, and retained Sales Return.
- `docs/KETUL_WORKFLOW_NOTES.md` for the approved Ketul domain foundation.
- `docs/POS_V1_IMPLEMENTATION_GATES.md` for the current deferred-module gate.
- `docs/ACTIVE_DEVELOPMENT_HANDOFF.md` and
  `supabase/MIGRATION_MANIFEST.md` for reported rollout state.
- `supabase/migrations/20260720090000_g1_phase1_security_feature_foundation.sql`
  for `ketul_enabled` and `company_features`.
- `supabase/migrations/20260721180000_g2_phase1_master_data_foundation.sql`
  for Product Category, Product, UOM, and Product UOM ownership.
- `supabase/migrations/20260722120000_g2_phase14_payment_method_foundation.sql`
  for the canonical `KETUL_OFFSET` payment-method contract.
- `supabase/migrations/20260722150000_g2_phase16_finance_master_foundation.sql`
  and `20260722180000_g2_phase18_required_transaction_categories.sql` for
  Finance functions and `KETUL_CUSTOMER_INTAKE`.
- `supabase/migrations/20260729070000_g4_phase4_atomic_sale_runtime.sql` and
  `20260805160000_g4_phase56_customer_balance_tender.sql` for the current
  explicit runtime block on `KETUL_OFFSET`.
- `supabase/migrations/20261006150000_kgs_retail_pos_user_coa_activation.sql`
  and `20261008110000_kgff_retail_finance_authority_clone.sql` for the proven
  Ketul Inventory/Revenue routing in KGS/KGFF.
- `supabase/migrations/20261030120000_pos_retail_direct_post_order_runtime_bridge.sql`,
  `20261030130000_pos_retail_pickup_document_boundary.sql`, and
  `20261031100000_pos_retail_non_cash_atomic_verification.sql` for the latest
  direct Retail checkout and non-cash verification chain in the repository.
- `pwa/src/App.tsx`, `pwa/src/lib/pos.ts`, and
  `pwa/src/SalesReturnModal.tsx` for the active client flow and Return UI.

## 3. Proven current execution path

The pre-change Phase A repository path was:

1. `pwa/src/App.tsx` composes cart, rounding, and payment legs.
2. `pwa/src/lib/pos.ts` calls
   `public.save_pos_sale_draft_with_pricelist(jsonb)` and
   `public.post_pos_sale_with_pricelist(uuid,bigint,uuid)`.
3. The direct Retail bridge transitions only POS +
   `RETAIL_CONFIRM_INVOICE` rows into the Posted/`LEGACY_POSTED` lifecycle.
4. Posting creates the existing Sale documents, movement/FIFO effects,
   Financial Event, payment snapshots, and audit effects.
5. Direct-bank/clearing legs are captured by the installed non-cash chain and
   Finance Verify posts their Event atomically.

At that baseline, the Product Catalog filtered `KETUL_OFFSET`, and the active
database runtime was intentionally authored to raise
`DEFERRED_PAYMENT_METHOD_NOT_ENABLED` for it. There is no Ketul intake table or
posting RPC defined in repository migrations. Therefore the operational Ketul
workflow was **not implemented** at the Phase A baseline, even when
`ketul_enabled` was enabled. Sections 10 onward record the later candidate and
local verification; Production remains not installed.

## 4. Required implementation boundary

The future implementation must add one canonical server-side composition:

`POS payload -> Ketul intake snapshot -> Sale post transaction -> Ketul Stock/FIFO inbound -> Ketul payable -> Ketul offset settlement -> existing external payment legs`

The server, not the client, must enforce:

- current Company, Store, Warehouse, Session, actor, and feature entitlement;
- exact active KETUL Product Category ownership;
- active Product/UOM ownership and decimal precision;
- positive quantity and unit price;
- duplicate merge and exact recomputed total;
- Ketul total `<=` after-tax/after-rounding Sale total;
- online-only execution;
- idempotency key, stale version, exact retry, and payload conflict;
- single transaction rollback across Sale, Stock, FIFO, Payment, Finance, and
  audit effects.

No generic `KETUL_OFFSET` payment method may be exposed in the normal payment
picker. It is derived only from a valid linked Ketul intake snapshot.

## 5. Impact map

### Final semantic-review correction

The final scoped diff review found that the preserved
`BACKOFFICE_CUTOVER` Draft branch bypasses the normal direct-Retail save
wrapper by design. Exposing Ketul on that branch would therefore show an
unsupported UI action and could only end in the server-side
`DIRECT_RETAIL_POS_DRAFT_REQUIRED` rejection. The client now tracks that
adopted cutover state, clears any Ketul UI state when such a Draft is opened,
and hides the Ketul action for that Draft. The existing server ownership guard
remains authoritative. No Backoffice snapshot, price, reservation, dispatch,
payment, Stock, or Finance behavior was changed.

### Direct impact

- POS cart/checkout UI and receipt/history presentation.
- Sale draft payload and server-side draft snapshot.
- New Ketul intake header/line/audit state and correction state.
- Direct Retail post transaction.
- Ketul Stock/FIFO inbound movement.
- Finance Event composition for Ketul Inventory, Ketul payable, and clearing
  that payable through the linked Sale offset.

### Downstream impact

- Session summaries and payment totals must distinguish external tender from
  Ketul offset.
- Non-cash verification must continue to capture only direct-bank/clearing
  payment legs, never the Ketul offset.
- Sale Return must continue using sold-line refundable amounts and must not
  reverse the linked Ketul receipt.
- Stock overview, Stock Opname, transfer, HPP/FIFO, and Finance reports will
  consume the new Ketul inbound Stock and Journal effects.
- Receipt/reprint and Posted transaction lists need Customer and Ketul detail.

### Explicitly preserved

- Backoffice/ODR Sale confirmation, reservation, dispatch, and invoicing.
- Cash auto-verification and direct-bank/clearing Finance verification.
- Tempo Customer Receipt.
- Existing Sales Return/refund workflow.
- Existing Product pricing, tax calculation, rounding, and price overrides.
- Other Companies and historical Posted documents.
- Deferred Ketul Vendor and standalone intake workflows.

### Regression risks

- Treating Ketul as Sales discount would understate revenue or tax.
- Treating Ketul as ordinary payment without intake evidence would create an
  unsupported liability/Stock effect.
- Posting Stock before the Sale commits would orphan Ketul inventory.
- Reusing Customer Balance liability would hide Ketul obligations and violate
  the requested dedicated COA.
- Reversing Ketul automatically during a Sale Return would remove Stock that
  the store physically retains.
- Adding the offset to the ordinary payment picker would allow unsupported
  tender without Ketul rows.

## 6. Migration/database classification

The corrected Production preflight classifies the state as
`INSTALLED_CONSISTENT` for all required foundations and `NOT_INSTALLED` for the
operational Ketul runtime. The exact evidence is recorded in section 10. The
new runtime therefore requires one guarded forward migration; no installed
migration may be edited or replayed.

## 7. Finance authority and resolved hierarchy blocker

Production evidence proves the exact entitlement, Product/UOM set, Transaction
Category, Inventory mapping, runtime guard, and idle queue state. Finance
approved the dedicated liability account as:

- code: `2010105-1`;
- name: `HUTANG KETUL CUSTOMER`;
- parent: `2010105 / HUTANG LAIN-LAINNYA`;
- technical function: `CUSTOMER_KETUL_PAYABLE`;
- compatible type / normal balance: `LIABILITY / CREDIT`.

The first disposable semantic execution of the candidate migration failed at
the canonical COA structure trigger with
`PARENT_ACCOUNT_MUST_BE_NONPOSTABLE`. This is a Product design blocker, not a
fixture failure. The proven live parent `2010105` is active and postable, while
the COA contract forbids a postable account from owning a child.

A subsequent read-only Production audit proves that `2010105` currently owns:

- three active direct rules: `SALES_RETURN / CUSTOMER_REFUND_LIABILITY`,
  `CASH_DEPOSIT / CASH_OVERAGE_LIABILITY`, and
  `CASH_VARIANCE / CASH_OVERAGE_LIABILITY`;
- one active fallback for `CUSTOMER_REFUND_LIABILITY`;
- zero existing `finance_journal_lines` in KGFF.

Therefore converting `2010105` to a nonpostable parent is technically possible
only together with an approved child account and atomic remap for those existing
functions. Creating `2010105-1` without `parent_account_id` would preserve all
existing routing but would not satisfy the approved structural-parent decision.
Neither alternative could be invented by the agent. The user subsequently
selected the compatibility-preserving option: create
`2010105-1 / HUTANG KETUL CUSTOMER` as an independent postable liability with
`parent_account_id=NULL`. Existing account `2010105`, all three direct rules,
and its fallback remain unchanged. This resolves the hierarchy blocker without
changing Return/Refund or Cash Overage routing.

After that decision, `CUSTOMER_KETUL_PAYABLE` remains the dedicated technical
function for both the derived Ketul settlement leg and Ketul intake Financial
Event. No generic payment picker exposure is permitted.

## 8. Before/after regression matrix

| Dimension | Before invariant | Required after invariant |
|---|---|---|
| Cash Sale | Existing direct Retail post | Same, plus valid linked Ketul offset |
| Bank/QRIS/clearing | Pending verification then atomic Verify+Post | Ketul excluded from verification; external leg unchanged |
| Split payment | External legs close Sale total | External legs + Ketul offset close total exactly |
| Tempo | Existing Customer Receipt flow | Unchanged; Ketul point-10 scope must not open Tempo composition |
| Tax disabled | Current KGFF condition | Offset after rounding |
| Tax enabled fixture | Tax computed from Sale lines | Offset after tax; tax base unchanged |
| Walk-In | Customer nullable | Ketul intake remains valid and auditable |
| Named Customer | Existing Customer snapshot | Customer reference retained when supplied |
| Open Session | Checkout permitted | Atomic Ketul+Sale post permitted |
| Closed Session | Checkout denied | Ketul side effects also zero |
| Partial/full Return | Existing selected-line refund | Ketul Stock remains; sold-line refund unchanged |
| Correction | No Ketul correction exists | Append-only authorized Ketul reversal/correction |
| Same Company | Valid ownership | All Ketul objects tenant-consistent |
| Cross Company | Rejected | Rejected before any side effect |
| Retry | Existing Sale idempotency | Exact retry returns same result; changed payload conflicts |
| Stale version | Rejected | Rejected with zero Ketul/Sale effects |
| Concurrent post | Single Sale post | Single Ketul intake, Stock, Event, and Journal effect |
| Offline | Ketul unavailable | Explicitly rejected; no queued Ketul payload |
| Backoffice/ODR | Existing flow | Byte/behavior-compatible except shared additive schema |

## 9. Rollback / forward-fix rule

The live migration chain is append-only. A deployed Ketul migration must not be
edited or replayed. Rollback of business effects must use authorized append-only
Ketul correction entries. Runtime defects require a new forward migration after
the same impact audit and regression gate.

## 10. Preflight harness correction record

### Installed-state behavior fixture session collision

The first Production rollback-only behavior attempt stopped before creating a
Sale because its fixture selected the first Super Admin and unconditionally
inserted another OPEN Cashier Session. The active canonical index
`uq_cashier_sessions_one_open_per_cashier` permits only one OPEN session per
cashier globally, and the selected actor already owned one. Classification:
`TEST_HARNESS FIX`; the explicit transaction aborted and rolled back the period,
stock, batch, and movement fixture writes that preceded the rejected session
insert. No Ketul intake, Sale, Payment, Event, Journal, or Posted effect was
created.

The corrected fixture first reuses an authenticated actor's existing valid OPEN
KGFF session. Only when none exists does it select an actor with no OPEN session
in any Company who satisfies the exact canonical POS access contract: Super
Admin, active Company Owner/Admin, or active Store Cashier/Manager. It then
creates a temporary session. The entire test remains inside the same explicit
rollback transaction; no existing session is closed, adopted, or permanently
changed. All original business assertions remain intact.

The first manual execution failed before returning any row:

`ERROR 42703: column "code" does not exist`

Classification: `TEST_HARNESS FIX`. The failed SELECT made no database
mutation. The invalid identifier `public.companies.code` was removed after the
defining migration `001_multi_company_setup.sql` proved the canonical columns
are `company_code` and `company_name`. Every other relation, column, status,
function signature, and ledger identifier in the preflight was then rechecked
against its defining migration before the corrected file was handed back. No
business assertion or expected invariant was removed or weakened.

The corrected harness then failed a second time before returning rows:

`ERROR 42883: function max(uuid) does not exist`

The earlier claim that the complete query had been checked is withdrawn.
Classification remains `TEST_HARNESS FIX`; Production again received no
mutation. The Company lookup was replaced with an exact-row CTE ordered by
`id::text`, while identity cardinality is checked separately. A persistent
PostgreSQL fixture test was added at
`supabase/tests/pos_ketul_customer_intake_offset_preflight_fixture.sql`; the
Production preflight must execute successfully against PostgreSQL 18 locally
before it can be handed back again.

Local execution evidence: the exact Production preflight was included by the
fixture and executed on PostgreSQL 18 against all referenced relations and
types. It returned 12 result rows, completed with `FIXTURE_EXIT=0`, rolled back
the fixture transaction, and the temporary PostgreSQL server was stopped.

The first valid Production output then reported
`checkoutBlocksKetul=false`. Root-cause tracing proved this was another harness
target error: migration `20260805160000_g4_phase56_customer_balance_tender.sql`
patches and guards
`private.post_pos_sale_online_core(uuid,bigint,uuid)`, not the Draft-save
wrapper previously inspected by the preflight. Classification:
`TEST_HARNESS FIX`. The assertion is retained and retargeted to the proven
active posting core; Product behavior is unchanged.

The retargeted exact preflight was executed again on PostgreSQL 18. It returned
the same 12-row contract with `pos_ketul_preflight_runtime_absence=PASS`,
`checkoutBlocksKetul=true`, `FIXTURE_EXIT=0`, transaction rollback, and a
stopped temporary server.

The corrected Production rerun returned all 12 rows without execution error.
Evidence classifies the live state as:

- dependency ledger `10/10` installed;
- KGFF `ketul_enabled` enabled;
- one exact active KETUL Category with four valid active Products;
- no exposed `KETUL_OFFSET` Payment Method, which is valid for the derived-only
  design;
- exact Inventory mapping to `1030100-4 / PERSEDIAAN KETUL`;
- no operational Ketul routine and the active checkout guard present;
- zero active Finance queue and zero nonterminal Offline submission.

Finance initially selected `2010105-1 / HUTANG KETUL CUSTOMER`, parented to
the proven live `2010105 / HUTANG LAIN-LAINNYA`. The later semantic migration
rehearsal disproved the prior conclusion that this closed Phase A: `2010105` is
postable and already routes three active rules plus one fallback. The earlier
`PHASE B AUTHORIZED` claim is withdrawn. No Production mutation was made.

The final user decision supersedes the structural-parent wording above:
`2010105-1 / HUTANG KETUL CUSTOMER` is an independent postable liability with
`parent_account_id=NULL`. `2010105` and all of its existing direct/fallback
routing remain unchanged.

## 11. Phase B local implementation and evidence

The additive candidate is
`supabase/migrations/20261031110000_pos_ketul_customer_intake_offset.sql`.
It adds the independent liability account, exact direct/fallback mappings,
derived-only `KETUL_OFFSET` method, tenant-owned intake header/line/audit,
save/post composition RPCs, atomic Stock/FIFO receipt, Ketul Event/Journal, and
receipt snapshot. The PWA calls the composition wrappers and keeps the internal
method out of the ordinary payment picker.

Local PostgreSQL 18 evidence:

- exact candidate migration: PASS on a disposable database;
- SELECT-only postflight: 9/9 contract rows PASS;
- rollback-only behavior: PASS for authenticated KGFF scope, repeated-row
  merge, value cap, unchanged Sale total/tax base, stale version denial,
  atomic Sale plus Ketul post, Stock/FIFO, Dr Inventory/Cr Ketul Payable,
  receipt, exact retry, Tempo denial, non-Ketul delegation, and full rollback;
- PWA build: PASS;
- PWA lint: PASS;
- focused Retail mocked Playwright: 4/4 PASS;
- static runtime-contract Playwright: 8/8 PASS.

The disposable full-chain rehearsal cannot install the historical scheduler
migration requiring `pg_cron`; therefore it is not represented as a full fresh
Supabase chain PASS. A runtime-equivalent direct-post bridge was applied in an
isolated clone for the rollback behavior. The Production dependency chain was
previously proven live by user-returned preflight evidence.

Full repository Playwright is 15/19. All four POS tests pass. Three unrelated
Backoffice/public-boundary tests remain failed due current worktree/server
state and are not weakened or claimed fixed.

Status layers:

- `AUDIT COMPLETE`: YES;
- `LOCAL READY`: YES for candidate migration, PWA, postflight, and rollback
  behavior;
- `DATABASE LIVE`: YES; user-confirmed migration plus 9/9 Production postflight
  contracts PASS with zero installation business effect;
- `PRODUCTION BEHAVIOR`: corrected rollback-only rerun pending after the first
  fixture collided with an existing OPEN Cashier Session; corrected fixture
  passes on PostgreSQL 18 disposable runtime;
- `CLIENT DEPLOYED`: NO;
- `SMOKE PASS`: NO authenticated Production smoke;
- `UAT PASS`: NO.

The append-only correction/reversal for an erroneous already-Posted Ketul
intake is not implemented in this slice. Posted rows are immutable; this gap
must remain visible and the overall Ketul workflow must not be called fully
complete until that authorized correction path is designed, implemented, and
tested.

