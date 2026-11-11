# Backoffice AR Reverse/Create Invoice Impact Audit — 2026-11-10

## Status and classification

- Task classification: `SCHEMA_OR_MIGRATION_CHANGE` + `PRODUCT_BEHAVIOR_CHANGE`.
- Scope: local repository and local Supabase Docker only.
- Production mutation/deployment: forbidden for this task.
- Database state: `INSTALLED_CONSISTENT` locally for AR Tasks 2–5
  (`20261105100000`, `20261105110000`, `20261105120000`,
  `20261106100000`); Task 6 identifiers are `NOT_INSTALLED`.

## Expected business outcome and source of truth

The approved optional action `Post Credit Note & Buat Invoice Pengganti` must
run in one database transaction:

1. post one native Backoffice Credit Note;
2. allocate as much of that Credit Note as possible to the source Invoice's
   current AR residual;
3. leave any excess as Customer-scoped AR open credit;
4. create one editable replacement Invoice in `DRAFT` state;
5. preserve explicit lineage Return -> Credit Note -> source Invoice ->
   replacement Draft;
6. create no replacement Invoice Finance Event/Journal until the user posts the
   replacement Draft;
7. create no Dispatch, Stock, Reservation, FIFO, or HPP effect.

Source: user decisions recorded in
`docs/audits/BACKOFFICE_AR_OPEN_ITEM_CREDIT_RECONCILIATION_IMPACT_2026-11-03.md`
sections 4.4, 5 Task 6, and 8.

“Copy the full Invoice” means copying the commercial document (Customer,
payment term, Product lines, prices, discounts, tax snapshots, delivery fee,
notes) into a new Draft. Historical Receipt allocation and Down Payment
application are settlement records and must not be copied or consumed twice.
The replacement therefore starts with no old payment/DP allocation; Finance can
apply the resulting Customer-scoped open credit after the replacement is
posted.

## Proven active execution path

### Current Credit Note path

`BackofficeSalesReturnView.tsx`
-> `/api/finance/backoffice-credit-notes/[id]/post`
-> `public.post_backoffice_sales_credit_note(uuid,bigint,uuid)`
-> `private.post_backoffice_sales_credit_note_before_retained(...)`
-> `private.ar4_register_backoffice_credit_note_open_item(...)`
-> `financial_events`, `finance_journals`, `finance_journal_lines`,
`ar_open_item_registry`.

Defining sources:

- `supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql`
- `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql`

Local active digests on 2026-11-10:

- native Credit Note post core: `3ce005460e7e50ec4b9d9134e5e4a928`;
- public Credit Note dispatcher: `93723ceab34fd6318088f314e976dd72`.

### Current open-credit allocation path

`CustomerReceiptView.tsx`
-> `/api/finance/ar-open-credit-actions`
-> `public.apply_backoffice_ar_open_credit(...)`
-> `ar_open_item_operations`, `ar_open_item_allocations`.

Defining source:
`supabase/migrations/20261106100000_backoffice_ar_open_credit_actions.sql`.
Local active digest: `1f3eb44dda2997282789da828e31fa81`.

### Current Invoice Draft/edit/post path

`BackofficeSalesInvoiceView.tsx`
-> `/api/sales/backoffice-invoices/[id]`
-> `public.save_backoffice_sales_invoice_draft(...)`
-> `private.save_backoffice_sales_invoice_draft_core(...)`
-> Invoice header/line/quantity-allocation/schedule tables.

Post:
`/api/sales/backoffice-invoices/[id]/transition`
-> `public.post_backoffice_sales_invoice(...)`
-> `private.ar3_post_backoffice_sales_invoice_core(...)`
-> Finance Event/Journal + Invoice open-item registration.

Defining sources:

- `20260909157000_backoffice_sales_invoice_draft_runtime.sql`;
- `20260911150000_backoffice_sales_invoice_client_activation.sql`;
- `20260912124000_backoffice_sales_accepted_overage_invoice_runtime.sql`;
- `20260909161000_backoffice_sales_invoice_posting_runtime.sql`;
- `20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql`.

Local active digests:

- public Draft saver: `91a423d2fb08901b7596f3b048c84cd2`;
- private Draft core: `df35a8304413d1190dfa34541f96eb60`;
- private posting core: `c874b7d081b9781004eaf42522bda1d0`;
- public posting wrapper: `66d5dc48551dbfd0236e31270d2cb6a7`.

## Proven incompatibility with the ordinary Invoice path

The ordinary Draft saver rejects Product qty above
`backoffice_sales_order_lines.to_invoice_base_qty`. A fully invoiced source has
zero remaining qty. The ordinary posting core also requires one `HELD`
`backoffice_sales_invoice_quantity_allocations` row per Product line and moves
that qty from Draft allocation to invoiced qty. Reusing this mechanism would
double-count fulfillment/invoiced quantity and can violate the Sales Order line
constraint. Therefore Task 6 requires a separate, explicit replacement lineage
that bypasses quantity consumption while preserving ordinary Invoice posting
and Finance behavior.

## Identifier sources and planned additive identifiers

Existing identifiers are proven by the migrations above and local catalogs.
The following names do not exist locally and are reserved for the guarded
forward migration:

- `backoffice_sales_invoices.replacement_credit_note_id`;
- `backoffice_sales_invoices.replacement_source_invoice_id`;
- `backoffice_sales_invoice_lines.replacement_source_invoice_line_id`;
- Invoice line `source_kind='CREDIT_NOTE_REPLACEMENT'`;
- AR operation `operation_kind='POST_CREDIT_CREATE_REPLACEMENT'`;
- `private.save_backoffice_replacement_invoice_draft_core(...)`;
- `public.post_backoffice_credit_note_create_replacement_invoice(...)`.

All replacement identifiers are Company-scoped and protected by composite
foreign keys/unique constraints. One Credit Note may create at most one
replacement Invoice.

## Impact map

### Direct impact

- Credit Note modal gains a second explicit action.
- Native Backoffice Credit Note posting and source residual allocation are
  orchestrated atomically.
- Replacement Invoice Draft can be edited/canceled through the existing Invoice
  workspace and posted later through the existing Finance posting path.
- Open-item history exposes the parent operation and replacement lineage.

### Downstream impact

- AR schedule/outstanding decreases only by the actual Credit Note allocation.
- Excess remains AR credit for the same Customer and Company.
- Replacement Draft has no Event/Journal/open item. Posting it later creates the
  normal Invoice Event/Journal/open item.
- Customer Statement and AR Aging continue using explicit allocations.

### Explicitly preserved

- `RETAINED_RETAIL`, POS Retail, Tempo, Customer Balance opt-in rules;
- ordinary Backoffice Invoice quantity holds and Sales Order counters;
- Dispatch, Stock, Reservation, FIFO/HPP, Return receipt;
- historical Posted documents/Journals and legacy Refund Liability rows;
- tax-enabled Backoffice rollout hold;
- existing plain `Post Credit Note` action.

## Concurrency, idempotency, retry, and rollback

- Parent operation locks Company + client operation UUID and the Credit Note,
  source Invoice, source Sales Order, and open items.
- Exact retry returns the recorded response; changed payload with the same UUID
  raises `IDEMPOTENCY_PAYLOAD_CONFLICT`.
- Credit Note post, source allocation, and Draft creation share one transaction;
  any failure rolls all three back.
- Stale Credit Note version, cross-Company identity, wrong process mode,
  duplicate replacement, and tax-enabled Company fail closed.
- Migration rollback policy is forward-fix. The migration is not run on
  production in this task.

## Legacy/backlog classification (Task 8)

- Production evidence recorded in the 2026-11-05 handoff showed zero native
  Backoffice unpaid Refund Liability rows. The Rp2.720.000 liability belonged to
  `RETAINED_RETAIL` and is excluded.
- `LSM RTN-20261021-0000000033` remains a manual Finance allocation case; no
  automatic target Invoice may be invented.
- Local production-shaped bootstrap currently contains zero historical Credit
  Note/open-item rows. This is not behavioral proof for production data.
- Result: no data-reclassification migration is authorized. Task 8 is delivered
  as a SELECT-only rollout inventory plus synthetic rollback tests; any future
  nonzero native candidate requires a separate row-by-row audit and forward
  migration.

## Regression matrix

| Case | Required result |
|---|---|
| Plain native Credit Note post | Existing full-AR/open-credit behavior unchanged |
| Combined action, unpaid source | Allocate up to source residual; create Draft |
| Combined action, paid source | Source allocation zero; full Credit Note remains open |
| Partial source residual | Partial allocation; excess remains open |
| Exact retry | Same response, no duplicate Note/allocation/Draft |
| Changed retry | Rejected |
| Stale version / duplicate action | Rejected |
| Same Customer / cross Customer | Same only / cross rejected |
| Same Company / cross Company | Same only / cross rejected |
| Replacement Draft edit/cancel | Allowed; no Stock/Finance effect |
| Replacement Draft post | Normal Invoice Event/Journal/open item; no qty counter change |
| Ordinary Invoice | Existing quantity holds/counters unchanged |
| DP/Receipt history | Not copied or consumed twice |
| Tax-enabled Backoffice | Held/rejected |
| POS/Retained Retail | No behavior change |
| Open/closed POS session | Irrelevant and unchanged |
| Stock/FIFO before/after | Exactly unchanged by combined action and Draft edit |

## Unknowns affecting design

`NONE`. Settlement history is intentionally not cloned; this is required to
avoid duplicate application. Production data eligibility remains a later
manual rollout gate and is not needed for local product implementation.

## Behavior failure audit — 2026-11-10

The first rollback-only Task 6 behavior reached its final boundary assertion
and failed with `unexpected Retail/Stock/FIFO or extra Dispatch effect`.
Read-only rollback evidence immediately afterward showed zero replacement
Invoices, zero Task 6 parent operations, and zero fixture Customers; the test
transaction rolled back completely.

Root cause is confined to the test harness: `v_before_boundary` was captured
before the canonical SO/Dispatch/Invoice/Return fixture, while
`v_after_boundary` was captured after it. The comparison therefore included
the fixture's legitimate Dispatch, Stock movement, FIFO, and Return effects.
It did not isolate the combined Task 6 action. Product assertions for atomic
post/allocation, Draft zero effect, retry, edit, normal Invoice post, and Sales
Order qty counters had executed before this harness-only assertion, but they
are not promoted to PASS until the corrected behavior reruns successfully.

Classification: `TEST_HARNESS_FIX`. The product migration, business expected
values, and product assertions are unchanged. The correction is limited to
capturing the boundary immediately after the canonical Draft Credit Note is
ready and before the Task 6 action, then comparing after Task 6 execution.

## Task 7 local client evidence — 2026-11-10

- `backoffice/tests/backoffice-ar-credit-note-replacement-ui.test.mjs`: 4/4
  `PASS`.
- Targeted ESLint for the changed API, parser, and UI files: `PASS` with no
  diagnostics.
- TypeScript `--noEmit`: `PASS` with no diagnostics.

The first targeted lint command used the obsolete `eslint --file` option and
was rejected by the repository flat ESLint configuration before source
analysis. This was classified as `TEST_HARNESS_ONLY / command invocation`.
No product code or assertion was changed because of it; the same files were
then checked by invoking the local ESLint binary with direct file paths.

The first Task 8 SELECT-only inventory incorrectly referenced
`company_sales_process_settings.tax_sales_enabled`, which does not exist. It
failed before returning rows and performed no mutation. The defining runtime
and prior preflight prove that the feature is resolved through
`public.private_company_feature_enabled(company.id,'tax_sales_enabled')`.
Classification: `TEST_HARNESS_ONLY / identifier correction`; the inventory
meaning and all review boundaries remain unchanged.

The original Task 2 and Task 3 behaviors require existing production business
rows, so a schema-only local bootstrap failed their preconditions without
testing product behavior. Task 3 received a canonical SO/Dispatch/Invoice
fallback fixture while retaining every original Receipt, allocation, Journal,
retry, and Retail/Stock/FIFO assertion. Its first fallback run exposed a fixture
date mismatch: the fixture used Company-timezone date, while the active Receipt
guard (defined by the active migration) rejects dates above PostgreSQL
`current_date`. That mismatch exposed a product defect because Backoffice
delivery already uses the active Company timezone. It was classified
`PRODUCT FIX`, audited separately, corrected by forward migration
`20261110110000`, and rerun through preflight, postflight, and cumulative Task 3
behavior. The canonical fallback fixture itself remains a `FIXTURE FIX`; no
business assertion was weakened.

## Closing local evidence - 2026-11-10

- Task 3 cumulative rollback behavior: `PASS` (also covers Task 2 registry,
  audit, immutability and direct-table denial).
- Task 5 rollback behavior: `PASS`.
- Task 6 rollback behavior: `PASS`.
- Task 2-6 postflight mandatory rows: `PASS`.
- Backoffice tests: 55/55 `PASS`; lint 0 errors; TypeScript and Next build
  `PASS`.
- Task 8 local legacy inventory: no candidate in dummy data; this is not
  Production evidence and authorizes no reclassification.
- RETAINED_RETAIL compatibility behavior: `BELUM TERBUKTI` locally because no
  eligible historical source exists. Runtime digest/marker contract is proven;
  representative compatibility smoke remains mandatory before Production.
- Authenticated browser smoke and user UAT: not run.
- Production: not accessed or changed.

## Production runtime-anchor divergence - 2026-11-10

Production rejected Task 6 before schema mutation with
`MIGRATION_PRECONDITION_FAILED: Task 6 runtime anchor changed`. Focused
SELECT-only diagnosis proves Task 6 ledger remains zero and exactly one of five
guarded routines differs:

- `public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)`;
- expected repository/local digest: `1f3eb44dda2997282789da828e31fa81`;
- active Production digest: `e89f2602af7757f99ea4b52c822162d6`.

The other four anchors match exactly. Repository tracing finds only migration
`20261106100000_backoffice_ar_open_credit_actions.sql` defining this signature;
no later repository migration replaces it. The semantic difference and its
authority therefore remain `BELUM TERBUKTI`. Task 6 and every downstream
migration are frozen. Do not replace the expected digest until the active
definition is exported and compared statement-by-statement.

Read-only evidence file:
`supabase/diagnostics/backoffice_ar_credit_note_replacement_apply_definition_diagnosis.sql`.

The Production definition export proves no semantic drift. Its body contains
66 CRLF boundaries; after normalizing CRLF to LF, its digest is exactly
`1f3eb44dda2997282789da828e31fa81`, matching repository/local. Owner,
`SECURITY DEFINER`, runtime configuration, signature, and ACL also match the
expected Task 5 contract. Classification is therefore `PRECONDITION CHANGE`
(encoding-sensitive digest guard), not `PRODUCT FIX`.

The Task 6 business design and local behavioral evidence remain valid. The
Production rollout artifact is not valid yet because its raw digest guard is
line-ending-sensitive. The existing locally installed Task 6 migration remains
immutable. A separately versioned, behavior-neutral compatibility step must be
audited and rehearsed before retrying Task 6; directly replacing the expected
hash or editing the installed migration is forbidden.

## Production preflight output-harness correction

After the normalization bridge and Task 5 regression closed, the Task 6
preflight exposed only its final business-boundary row in Supabase SQL Editor.
Repository inspection proved the file used six separate result sets. This is a
`TEST_HARNESS_ONLY` presentation defect: no mandatory assertion failed, but
five results were not returned to the user.

The preflight now emits the same dependency, installation, five-digest runtime,
process and runtime-boundary assertions plus the business boundary through one
ordered result set. No identifier, expected digest, invariant, migration or
Product behavior changed. Local PostgreSQL execution returns all six rows; the
local installation/runtime blockers are expected because Task 6 and later
runtime are already installed there and are not Production evidence.

The first Production postflight paste had the same presentation defect: six
separate SELECT result sets exposed only the final business-boundary row. It is
also classified `TEST_HARNESS_ONLY`. The corrected postflight emits the same
ledger, schema, runtime, data, privilege and business-boundary checks as one
ordered result set. Local PostgreSQL execution returns all six rows with no
write outside the read-only transaction.
