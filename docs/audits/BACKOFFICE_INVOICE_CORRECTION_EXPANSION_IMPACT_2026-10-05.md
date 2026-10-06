# Backoffice Koreksi Invoice impact and implementation decisions

Status: implementation authorized; dependency audit in progress. No expanded
runtime, migration or deployment is delivered by this document.

Update 2026-10-06: the invoice-revision portion described below is installed and
behavior-verified on authorized staging. The exact guarded Production migration
was subsequently run once by the user; Production behavior and postflight remain
pending. The agent did not access Production. Payment-error reversal/date
correction, actual payout, manual due-date
override and repeated customer/date relocation remain unimplemented and must not
be inferred from the staging PASS.

The self-contained Production behavior package is
`supabase/tests/backoffice_unified_posted_invoice_revision_behavior.sql`, SHA256
`fe4e8dbdd70781660407a793dddabac07061a5240d205e8f763e0f8a53b607a6`.
Its exact SQL passed a staging rollback rehearsal with nine PASS rows and 312
restored table fingerprints. Internal behavior fragments are not standalone
user-run files.

The first Production behavior attempt stopped before business assertions on a
test-only one-line fixture precondition and rolled back. Audit found that the
amount-preview harness iterated arbitrary real Posted Invoices, although its
fixture assertions intentionally require one line. This is classified as a
`TEST HARNESS FIX`: the corrected package records exactly two one-line Invoices
that it creates transactionally and scopes the preview loop to those IDs. No
runtime definition, migration, expected amount, authorization, retry,
immutability, Finance, or rollback assertion was relaxed. The corrected exact
The next Production attempts found a separate SQL Editor portability defect:
both the new seed table and the older four-Invoice table could be absent for a
later block. The final package removes every temporary table, including its
authenticated/report handoff tables, and replaces only that ephemeral transport
with transaction-local PostgreSQL settings. It creates no persistent helper and
changes no assertion. A static scan proves zero `CREATE TEMP` and zero removed-
table references. The resulting exact file returned nine PASS rows on staging
at `2026-10-06T08:15:00.022Z`, with all 312 tracked table fingerprints restored
after rollback.

The staging-bound built client additionally passed an authenticated HTTP smoke
through the real Next Invoice/revision routes on 2026-10-06: unauthenticated and
cross-Company access were rejected; POST plus exact retry, effective reload,
immutable source Invoice/lines and balanced revision journals passed. Closing
postflight remained clean afterward. Temporary smoke users were disabled and
banned. Visual browser smoke remains pending because the in-app browser connector
was unavailable; this is not represented as UAT.

User-run Production preflight passed on 2026-10-06 with target migration absent,
zero object collision, zero active Finance queue, zero nonterminal Offline rows,
exact dependency/runtime/Company contracts, and 226 eligible Posted Regular
Invoices across the three target Companies. The agent did not connect to
Production. That output authorized the later user-run migration recorded below.

The user subsequently ran the exact guarded migration once and reported the
expected `pg_advisory_xact_lock` result with no error. Treat it as installed but
not yet fully closed. The corrected rollback-only Production behavior later
returned its terminal aggregate `PASS`, listing all nine suites and rollback;
closing postflight subsequently returned all required PASS rows: exact ledger,
relations/routines/permissions, zero active Finance queue, and zero invalid
history/schedules. Runtime inventory is zero before first real use. Production
database rollout is closed; the agent still did not access Production. Client
deployment, authenticated smoke and UAT remain pending.

## Approved scope

One Koreksi Invoice form edits unit price, line discount, invoice date and
invoice billing customer. Invoice accounting uses the effective invoice
customer even when different from SO customer. Preserve SO, DO, original
product links, quantity, UOM, Stock, reservation, FIFO and COGS. Goods changes
after receipt use Return. Correction notes are optional; revision time is
server-owned and distinct from invoice date. Preserve original evidence and
posted journals; append corrections with before/after audit.

The existing rollout enables KMS/LSM/SMS Regular posted invoices. Other Company
activation, Retail/POS, DP invoice editing, tax-selection edits, master payment
term edits and delivery fee edits are not implicitly authorized by this expansion.

## Verified repository evidence

| Consumer | Observed dependency | Required treatment |
|---|---|---|
| `backoffice/src/components/BackofficeSalesInvoiceView.tsx` | Posted editor is price-only; existing PDF uses effective price context | Unified correction form and preview, effective identity/date/discount, revision history |
| `backoffice/src/app/api/sales/backoffice-invoices/[id]/price-corrections/route.ts` | Calls price-only RPC with master version, price revision, operation ID and lines | Preserve old contract while introducing expanded validated contract |
| `backoffice/src/lib/backoffice-sales-invoice.ts` | Parser accepts only invoiceLineId and newUnitPrice per correction line | New payload must reject quantity/product/UOM changes server-side |
| `20260928110000_backoffice_posted_invoice_price_correction.sql` | Reads original line discount; rejects zero financial delta; journals use original invoice customer | Cannot reuse unchanged for identity-only/date-only/discount-only changes |
| Same migration | Date derives from server; closed period falls forward; current price context and Return use effective price | Separate revision timestamp from document/accounting date; maintain tax and Return valuation |
| `20260911160000_backoffice_sales_payment_collection_runtime.sql` | Save and Post require invoice customer to equal Receipt customer, and invoice date not after receipt date (lines 248-249, 436-437) | Coordinate customer/date revisions with pending and posted allocations and concurrent Receipt posting |
| `20260911163000_backoffice_sales_ar_reporting_integration.sql` | Aging and statement filter original invoice customer and date | Version-aware effective/as-of ownership and date; preserve prior statements and AR/GL parity |
| `20260917131000_backoffice_sales_return_credit_note_runtime.sql` | Credit Note captures invoice customer (line 608) | Keep Return guard until new ownership/valuation behavior is validated |
| `20260919130000_sales_invoice_export_backoffice_union.sql` | Export joins customer and filters invoice date | Effective revision must be used for current export and declared cutoff semantics |
| `20261002100000_sales_export_net_sales_detail.sql` | Net export still joins invoice customer and filters invoice date (lines 146-155) | Update identity/date without changing physical or commercial net-quantity lineage |

These are repository findings, not proof of currently installed production
function bodies. Before migration, obtain installed routine/schema/ledger
evidence and compare the active definitions including later wrappers.

## Direct and downstream impact

Direct: correction header/line/operation history, preview and posting RPC,
permission checks, version locking, Invoice UI and invoice activity.

Downstream: effective invoice amounts and snapshots, receivable schedules,
Receipt selection/save/post, customer statement, aging, invoice-based sales
reports, exports, printing, Return valuation, customer journal attribution,
accounting-period cutoff and existing correction retry behavior.

No direct changes to source SO/DO or operational stock tables are permitted.
Cashier sessions and POS remain compatibility regression cases, not new scope.
COA functions must resolve to existing authorized mapping; missing mapping is a
blocker, never permission to create an account.

## Confirmed business decisions

1. User explicitly chose to allow customer changes after payment/DP through
   special correction transfer/reallocation. Transfer only the target invoice's
   allocated portion; do not reassign a shared Receipt or entire DP document.
   Preserve original payment evidence and all other invoice allocations. Draft
   allocations need stale-state handling and posting rechecks.
2. User explicitly chose that changing invoice date also moves accounting
   recognition when periods are open. This is not document-date-only editing.
   Original posted journals remain immutable; design the reversal/replacement
   entries and corresponding as-of AR treatment together.

Existing Return guard remains. Both affected periods must be validated open;
no silent reopening or fallback to document-date-only changes.

3. Customer must be selected from Company-scoped master customer, not free text.
4. Keep the previous invoice-to-due-date interval when invoice date changes;
   explicit manual due date is permitted for an authorized admin. This does not
   change the master payment term. Multi-installment handling must preserve each
   schedule and be tested, not silently collapsed to one due date.
5. A genuine payment before the revised invoice date becomes an advance until
   that invoice date and is then applied. A fully paid invoice remains paid if
   its effective amount has not changed. Do not create fictitious cash movement.
6. A falsely recorded payment with no real funds is reversed as a payment error,
   not converted into an advance, Credit Note or refund. A genuine payment with
   a wrong date uses payment correction with immutable source evidence.
7. Invoice and Finance are two entry points to ONE canonical correction service.
   Finance must select the source invoice. Tagihan correction, payment correction
   and real cash/bank refund remain distinct, linked operations in that service.
   No free-standing Journal is a substitute for these operational documents.
8. Credit Note is not evidence of refund payment. Actual refund must consume a
   linked available refundable amount; both documents and remaining liability
   must appear on the source invoice regardless of entry point. Duplicate retry
   or alternate entry point must not create a second accounting effect.

## Implementation architecture

- Immutable revision snapshot preserving original header/line identity and all
  previous values. Effective-reader contract shared by all listed consumers.
- Server preview calculates tax, discount, financial deltas and dependency
  blockers. Confirmation recalculates under locks; client totals are not trusted.
- One transaction commits revision, applicable correction accounting, schedules,
  audit and stored retry response, or rolls everything back.
- Persist a stable client operation ID for network retries; different payload
  with the same key fails. Recheck invoice and revision version, active Company,
  capability and dependency state at posting time.
- Decide lock order jointly with Receipt/Return/DP writers to prevent customer
  transfer racing a payment. A reader-only precheck is insufficient.
- Preserve old price-correction compatibility without letting the old endpoint
  bypass expanded revision version checks. No partial UI activation.
- Backfill policy should default uncorrected invoices to original values without
  fabricating revision history. Existing price corrections remain effective.

## Verification and rollout gates

Preflight must inspect exact installed schema, routines, mapping, periods,
existing correction/Receipt/DP/Return dependencies and data shapes. It must not
assume relation/column names from this design. Then guarded additive migration,
representative rollback-only behavior, postflight, authenticated smoke and UAT.

Cases: price up/down, discount-only, identity-only, changed debtor, date-only,
cross-month, closed period, combined edit, partial/fully paid, DP, Return,
overpayment, same-key retry, changed-key payload, stale revision, concurrent
Receipt/Return, tenant/role denial, source product links, current/as-of AR/GL,
print/export parity, no Stock/FIFO/SO/DO mutation and old price-correction path.

After revisions exist, rollback is forward-fix; never delete posted correction
history. Disable new entry point if required while preserving readers and
existing posted data. No production migration or deploy is authorized by this
local implementation task.

## Current evidence

Read-only repository audit only. No code, database, schema, journal, account or
business document changed. No behavioral PASS or production readiness claimed.

SQL runtime access was attempted through the already linked Development project.
CLI failed before query execution with `Unsupported Config Type`. No database
query or mutation was executed by that attempt. No PostgreSQL client or Docker
command was found on PATH during local tooling discovery.

Prepared catalog-only discovery query:
`supabase/diagnostics/backoffice_invoice_correction_expansion_runtime_audit.sql`.
It returns relation columns, constraints, triggers and relevant installed function
bodies. Its FOUND/OBSERVED rows are inventory, not safety/behavioral PASS. User
must run the complete query on the intended database and return the full export
before active runtime parity and migration guards can be finalized. No business
data is selected. Installed ledger contents and representative business-state
inventory remain subsequent checks; this query does not claim to cover them.

User supplied runtime output in attachment
`684465b8-f509-4815-9352-02f16f544af8/Pasted text.txt`: 17 relations, 223
constraints, 31 triggers and 52 routines; no missing-routine rows; every details
cell parses as JSON. This closes catalog discovery, NOT behavioral validation.
The installed Receipt child trigger rejects mutation for non-Draft documents;
installed statement filters both Receipt and Invoice customer. An append-only
settlement transfer must update the effective statement interpretation, not
merely change invoice display identity.

## Initial implementation boundary

Implement the shared strict command contract and due-date calculation with
standalone automated tests first. It is deliberately not connected to either
UI/API entry point until database posting, authorization, effective readers,
settlement transfer, period relocation and compatibility tests exist together.
This component validates syntax only; it cannot prove master ownership,
authorization, availability of refund funds, open periods or correct journals.
Never label passing contract tests as database or accounting behavioral PASS.

### Initial local code evidence

- Added `backoffice/src/lib/backoffice-invoice-correction-command.ts`:
  strict discriminated commands for invoice revision, payment error correction
  and linked refund; decimal strings preserve numeric(24,4); rejects actor,
  Company, totals, journal payloads and immutable product/quantity/UOM fields.
- Invoice identity/date changes use the same command as price/discount changes.
  Payment correction explicitly distinguishes no real funds from wrong date.
  Refund requires a source credit and payment method; database must still verify
  that source credit belongs to the invoice and has sufficient refundable funds.
- Canonical payload comparison normalizes line ordering, UUID case and decimals.
  This does NOT implement persisted idempotency: database operation uniqueness,
  locks and stored response remain mandatory unfinished work.
- Due-date helper retains the previous day interval or accepts explicit override
  only with caller-supplied server authorization. This helper does not establish
  permission by itself; runtime must derive authority from authenticated actor.
- `node --test tests/backoffice-invoice-correction-command.test.mjs`: 43/43 PASS.
- `node node_modules/typescript/bin/tsc --noEmit --incremental false`: PASS.
- No API/UI imports the new module. No SQL writes or production deployment.
  Full feature and accounting behavior remain UNIMPLEMENTED/UNVERIFIED.

## Live data baseline and testing environment boundary

Read-only REST access succeeded using existing server-side configuration; CLI
SQL access remains unavailable. Added
`scripts/audit-invoice-correction-baseline.ps1` for repeatable scoped inventory.
No credentials appear in output. This is multiple REST requests, not a single
transactional snapshot; it cannot authorize a migration or prove concurrency.

Observed baseline: 210 posted Regular invoices in KMS/LSM/SMS, each with one
original posted source journal; eight Receipt documents with multiple Backoffice
allocations; 227 posted and ten canceled Receipt documents; zero posted DP
applications; nine open periods; zero unbalanced posted journal headers in the
scoped read. Header balance is not line-level/source-level reconciliation.

`supabase/diagnostics/backoffice_invoice_correction_settlement_baseline.sql`
provides a single-SELECT, detailed alternative for atomic source/period/allocation
inventory, based on supplied runtime columns. It has not been executed against
PostgreSQL and is not a tested migration preflight. No user rerun is needed for
the summarized REST inventory already collected.

An isolated PostgreSQL test database with this migration chain is required for
actual settlement transfer, shared-allocation preservation, nonzero DP fixtures,
multi-session races and rollback tests. Production mutation/fixture creation is
not authorized. The existing CLI-linked project is not automatically an approved
test target. Obtain the user's target selection and authorization before running
migrations/fixtures there. Do not ask for secrets in chat.

### Superseding environment authority (2026-10-05)

User selected staging `yjxpddwrjdczuqyixqwi` and authorized alignment/rehearsal.
Production access by the agent is now explicitly prohibited, even read-only.
Earlier REST baseline is historical evidence, not permission to reconnect.
Production SQL must be supplied to the user for execution and exported results.
Current CLI access only lists the separate backup project; staging access still
needs to be restored. Do not substitute that backup or change application env.

Initial comparison reuses the existing SELECT-only
`supabase/diagnostics/office_purchase_production_delta_catalog.sql`. It is a
catalog inventory, not a backup, deployment script or full-parity certificate.
No staging reset, data copy or blind migration replay is planned. Inspect
staging state and integrations before designing the sync package; Production
credentials and external jobs must not be copied to staging.

## 2026-10-06 - User-supplied atomic settlement baseline accepted

Source attachment `f899e7b2-6626-4886-b18a-16bb78191ec0/Pasted text.txt`,
SHA256 `160fda3e7044aa553c59f89315f2ec1ce7984e52b41706b1bf97d849da35ff97`,
snapshot2026-10-06T04:22:05.44494Z. Parsed all595 CSV rows and every JSON detail;
all reported statuses INFO, zero REVIEW. This is baseline evidence, not rollout
approval. No Production connection or mutation performed by the agent.

| Company | Posted Regular | Unpaid | Partially paid | Paid |
|---|---:|---:|---:|---:|
| KMS | 73 | 46 | 2 | 25 |
| LSM | 98 | 54 | 0 | 44 |
| SMS | 39 | 31 | 0 | 8 |

Classification uses original total plus posted price delta against posted Receipt
allocations. Every exported Invoice has one schedule; schedule amounts equal
effective totals and allocated payments equal exported posted Receipt amounts.
Two KMS price-correction source rows; no Return Credit rows or DP applications
linked to the scoped posted Regular invoices. Absence here does NOT prove no DP
or Return documents exist elsewhere, and must not remove those test cases.

80 posted allocations belong to70 distinct Receipt documents. Eight receipts
span multiple scoped invoices (one KMS,seven LSM). Three of those LSM receipts
have total allocations larger than the sum of their rows in this scoped export:
CR/2026/09/000219,000253,000261. This is out-of-scope allocation evidence, NOT
an accounting discrepancy and NOT proof of a particular other source type.
Never rewrite an entire Receipt/customer or assume scoped rows are its full
allocation set. Preserve all allocations not selected by the correction.

292 source-journal rows represent282 distinct posted journals (210 Invoice,
70 Receipt,two price corrections); repeated Receipt journals are expected from
per-Invoice lineage, not duplicate posting. Each source reports one original
posted journal. Decimal arithmetic on every exported line set matches both
header totals and equal debit/credit. This does not independently prove account
classification, complete GL/AR parity or source/customer attribution correctness.
All9 exported periods (Aug/Sep/Oct for each Company) are OPEN at the snapshot;
posting must still recheck both affected periods under locks, never cache OPEN.

Design/test consequence: include unpaid/partial/full settlement, shared Receipt
with2 and4 invoice allocations, additional unexported-source allocation, existing
price corrections, synthetic nonzero DP and multiple installments, cross-month
plus closed-period denial. A future transfer records only the corrected invoice
share and effective customer attribution; original Receipt identity, bank/cash
movement and unrelated Invoice payments remain immutable. No new accounting
function/account authorized by this evidence.

The requested Production inventory gate is satisfied; no user SQL rerun needed.
Staging schema/reference/mode synchronization and old Invoice/price/payment
baseline already passed (see staging alignment audit). Expanded correction
service/migration/UI remain unimplemented; next work is staging implementation
and representative settlement-transfer/period-relocation tests, not Production
deployment or a claim that the expanded feature is ready.

## Staging implementation slice: revision amount preview (2026-10-06)

Direct impact: an additive PRIVATE, invoker-only calculation candidate, loaded
only inside the staging rollback harness. It reads exact Invoice/line/customer
and price-correction tables; uses the existing tax calculator and current
effective line amounts. It accepts price/discount only for the complete original
Sales Order product-line set. No quantity/product/UOM/tax override is accepted.

Downstream: its per-line before/after gross revenue, discount, tax and payable
delta will feed the future immutable revision posting service. This is NOT a
posting authorization, accounting journal, revision store or endpoint. Existing
Invoice/Finance/UI consumers remain unchanged. Existing price corrections are
included in the before state; delivery fee and DP lines are not recalculated.

Stock, reservation, FIFO, payment, cashier, Finance and audit rows: no writes.
Compatibility: no existing function is replaced. No migration ledger is inserted.
Concurrency: preview is a single statement snapshot; a future posting service
must lock and reload all inputs, periods and settlement allocations. Preview
cannot be cached as authority. Retry is deterministic, not a financial operation.
Rollback: outer test rollback removes both candidate routine and fixtures.

Regression risks: inclusive-tax rounding; discounts exceeding line total; NULL,
NaN, duplicate/foreign/missing line IDs; confusing gross and net revenue;
Return-adjusted source. Tests must exercise actual canonical taxed fixtures,
existing effective-price parity, negative cases and table fingerprint equality.
Unproven here: customer/payment transfer, due-date redistribution, period moves,
shared allocation locks, persistent revision posting, UI and end-to-end UAT.

The same rollback candidate also includes KEEP_TERM date preview. It reads the
current Invoice date, every schedule row and both Accounting Periods. It preserves
each schedule ID, installment order, amount and paid/credited values and shifts
only proposed dates by the original interval. A changed date requires both
periods OPEN or already legitimately REOPENED (canonical lifecycle); no automatic
reopening. No dates/journals are actually written. Manual due-date overrides and
revision-effective dates after future metadata revisions remain integration work.

Evidence 2026-10-06T04:43:27.638Z, staging yjxpddwrjdczuqyixqwi only:
SQL SHA256 `4a47024dbba65fd4007ffae664ddc1dfed44f4f9e0777fe6a10e32d824a9ccb2`.
Four behavioral result rows PASS: three unchanged canonical flow assertion
bodies plus new amount/date preview tests. Nonzero taxed and untaxed Regular
fixtures, existing price corrections, DP and paid invoice exercised. Invalid
money/quantity/ownership/stale revisions rejected; next-month date and locked
source/destination periods tested. No multi-installment fixture yet: preserve
this as a remaining behavioral gap, not a passed scenario. Preview has no public
grant and is not an authenticated correction endpoint. Existing authenticated
price/payment RPC reads passed separately. After rollback all308 table row
fingerprints identical and both candidate routine identities absent. Sequence
gaps are allowed, as in existing staging baseline.

First run rejected a test-generated six-decimal discount string; fixture now
normalizes currency to four decimals, matching the command parser. Validation
was not relaxed; failed-run receipt retained. This remains a prototype outside
the migrations directory. Production release requires the complete preflight,
guarded migration, postflight, rollback/forward-fix, authenticated E2E and UAT
package after settlement/accounting integration. No Production action now.

## Next slice: immutable prepared operation and settlement source snapshot

Outcome: implement PRIVATE preparation storage for the eventual atomic correction
orchestrator, not an independently successful revision. Source-derived Company,
actor, master Customer, invoice version, current price revision and complete line
set are required. A prepared operation has no accounting/effective-reader effect.

Direct impact: additive private preparation table, immutable mutation guard,
source snapshot function, permission-checked capture and freshness assertion.
Runtime existing writers are NOT patched. Receipt source snapshot includes the
target allocation and ALL sibling Backoffice/Retail allocations separately;
DP application and tax lineage are retained. Shared documents are never reassigned.
Customer is reloaded from the active Company's master, not supplied as a name.

Lock review: current Receipt writers lock Receipt then Invoice. Preparation locks
only its operation key and Invoice, never then locks Receipt, avoiding an inverse
Receipt/Invoice lock chain. This captures a plan, not a financial commit. A full
dependency snapshot equality recheck detects drift, but is NOT sufficient posting
concurrency control. Final settlement writers still require coordinated locking
and rechecks. Neither this private capture nor its snapshots may be exposed as a
posting endpoint while that work is incomplete.

Retry: Company+operation ID, normalized payload, stable stored response; changed
payload is rejected. Permissions checked before retry. Actor/time owned by server.
Storage immutable; no posted revision counter or journal created by preparation.
Rollback-only staging DDL/fixtures removed after tests. No production migration,
backfill, COA, SO/DO, Stock/FIFO, Payment, Finance or cashier mutation from capture.

Tests: canonical nonzero DP and posted shared Receipts spanning four and two
Invoices; complete sibling preservation, exact retry, conflicting key, invalid
Customer, auth failure, drift detection, immutable history, and whole-database
rollback fingerprints. Expanded posting/customer transfer and concurrent writers
remain unproven; no claim of final transaction safety from this preparation slice.

## Staging execution-plan gate (2026-10-06)

The next private candidate remains read-only with respect to business data. It
locks every target Receipt in stable UUID order before the Invoice, then locks
DP source Invoices and the old/new accounting periods, rechecks the complete
prepared snapshot and emits an execution plan. This follows the installed
Receipt writer's Receipt-to-Invoice order and prevents a future writer from
silently reassigning an entire shared payment.

The representative staging fixture proves three target Receipt dependencies:
two posted shared documents with target allocations totaling 1,100 and one Draft
target allocation of 50. Moving the Invoice date forward classifies the posted
1,100 as genuine customer advance until the revised Invoice date. The plan also
retains a nonzero posted DP transfer, the source Journal and old/new periods,
while explicitly reporting zero Stock, FIFO, SO and DO effect.

Every pre-Invoice Receipt requires an OPEN/REOPENED Receipt-date period, the
posted Receipt AR snapshot account and a resolvable advance-liability account.
The first run exposed that `CUSTOMER_ADVANCE_LIABILITY` is not a Receipt-event
mapping. The corrected planner resolves it from the canonical
`BACKOFFICE_SALES_INVOICE` event, which is where the installed catalog defines
the function. No account, category or fallback was created.

Final staging evidence: `2026-10-06T05:57:28.898Z`, SQL SHA256
`9fbd5f96ba1df2e831748056eee1d6ad1b5cdf9f3688d9bc40a09b5a247585e0`.
Six behavior result rows PASS; all 308 tracked table fingerprints match after
rollback and every candidate object is absent. This authorizes work on the
atomic writer, not Production rollout or UI exposure. The writer still must
create immutable revision/settlement lineage, source-linked reversal and
replacement journals, advance/reapplication legs, amount/discount deltas,
effective readers and representative concurrent retry tests as one transaction.

Journal planning then passed at `2026-10-06T06:06:29.712Z`, SQL SHA256
`0a37de6ae7f9b2ba6221a4d5bee9dff67e783403176b981212e4969816e8c074`.
Seven rollback-only behavior rows PASS and 308 tracked table fingerprints match.
The plan proves independently balanced recognition reversal/replacement,
Receipt-to-advance and later application, direct AR attribution transfer, and DP
attribution transfer. It contains no writer effect. This is the final read-only
gate before append-only execution storage and Finance writes; it is not a live
feature, migration, endpoint, deployment or Production authorization.

## Staging append-only writer gate (2026-10-06)

The candidate now persists immutable private revision, line and selected-share
settlement attribution rows inside one transaction, posts independently balanced
source-linked Finance legs, rebuilds receivable schedules and exposes effective
customer/date/price/discount/total readers. Source Invoice/lines, original posted
Journal, Receipt documents/allocations and DP applications remain immutable.
The global automatic-journal reversal guard was not weakened: recognition
offsets use `PRIOR_PERIOD_ADJUSTMENT` with the exact source Journal retained in
the execution snapshot.

An authenticated public RPC now composes prepare+execute atomically and a public
read context exposes effective identity, lines, schedules and immutable history.
The legacy price-only writer is guarded after the first unified revision so it
cannot bypass the new revision chain. Repeated amount-only revisions are tested;
a second customer/date move is intentionally rejected until relocation of every
prior effective recognition leg is implemented.

That early writer-only rehearsal at `2026-10-06T06:25:30.996Z` is retained as
historical evidence, not current status. The completed guarded migration is now
installed on staging; downstream AR/statement/export/Return/UI consumers,
multi-installment/concurrency cases, the nine-suite Production behavior package,
closing postflight and authenticated Next API smoke all pass. Production remains
untouched. Remaining gates are user-run Production preflight/rollout, client
deployment, visual browser smoke and UAT.
