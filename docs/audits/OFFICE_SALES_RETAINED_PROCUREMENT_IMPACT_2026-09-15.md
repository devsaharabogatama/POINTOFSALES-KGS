# Retained Office cutover orders: impact-first audit


## 2026-09-16 - CRLF fingerprint fix CLONE VERIFIED, Production retry pending

Supersedes prior diagnostic hold for formatting, not Production-live/smoke gates.
User Production output proves all six release ledger entries absent and six new
routines missing: failed install did not commit. Old function CR counts3..299.
Pre-update LF hashes are NOT expected to equal post-update hashes.
Clone reproduces15 actual definitions changed to CRLF: raw comparison15 failures,
CRLF->LF comparison15 matches, entire routine fixture rolled back.
Exact revised installer guard accepts those15 CRLF definitions and rejects a
real reader source change; rollback test exit0. No hash expectations changed,
no whitespace/comments/config stripping, no business routine/migration body changes.
Installer and postflight now compare full definitions after CRLF->LF only.
Recovery behavioral regression exit0; installer re-entry exit0; postflight25 PASS.
Production may still expose genuine post-update code drift; guard remains strict.

Changed this fix: installer verification, release postflight, two rollback tests,
impact/report/router/handoff/root notes. No new schema/backfill, stock/reservation/
FIFO/payment/session/Finance/audit operation, CLI link/env change or agent deployment.
No seventh migration/ledger entry is required for verification-file correction.
Local code ready; database verified only in clone; Production installation and
CLIENT DEPLOYED/authenticated SMOKE/UAT remain user manual checks.

Next safe run: current backup/pause; entire
[preflight](../../supabase/diagnostics/office_procurement_recovery_release_preflight.sql),
[transaction fingerprints](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql),
[updated atomic installer](../../supabase/releases/office_procurement_recovery_install.sql),
[updated postflight](../../supabase/diagnostics/office_procurement_recovery_release_postflight.sql),
then same fingerprints BEFORE recovery. All17 counts/digests must match while
paused; postflight expects25 PASS. Do not rerun previous90 files or seed tests.
On genuine error, transaction guard still rolls back; stop, retain error, trace
actual definitions rather than bypass. Then user client deployment/recovery smoke
as detailed in current release report. No restored-Production-order claim yet.


## Fingerprint portability impact - before comparison fix

User live diagnosis: release ledger0, six new routines absent; failed bundle
rolled back. Nine remaining predecessor functions contain3..299 CR characters.
Their LF hashes differ from POST-update expectations because they are still
pre-update definitions; this output is NOT proof of semantic drift after install.
Direct impact: installer/postflight fingerprint comparator only, no migration
body, routine signature, role/RLS policy or business flow change. Compare full
pg_get_functiondef after CRLF->LF only; do not strip whitespace/comments/config.
Downstream: same strict drift decision and atomic rollback; real source changes
must still fail. No stock/reservation/FIFO/payment/session/Finance/audit data
mutation or backfill; concurrent operational consumers unchanged. Test real
clone function definitions reformatted CRLF within rollback, old raw comparison
must fail, normalized comparison must match; intentional code change must fail.
Actual fresh Production outcome remains manual. Never patch expected hashes
from unknown live code or remove the guard to accept drift.


## 2026-09-16 - PRODUCTION INSTALL BLOCKED: all15 runtime fingerprints fail

Supersedes release-candidate readiness below. User reports RELEASE_RUNTIME_DRIFT
for all15 functions at final guard before COMMIT. Do not retry/deploy/recover yet.
Committed Production installation state must be checked from the live ledger.
Clone raw fingerprints still match15; CR count0 for all15. Local bundle and reader
migration CR count0. Neither actual Production code drift nor clipboard/formatting
cause is proved; do not normalize/remove fingerprint guard on this evidence.
Prior bundle test was installed-clone re-entry, NOT fresh combined installation.
That proof did not establish fresh Production bundle readiness.

[Read-only live diagnosis](../../supabase/diagnostics/office_procurement_recovery_runtime_drift_diagnosis.sql) returns one result set:
15 expected/actual hashes, missing functions, LF comparison, CR counts, ledger
and session metadata. Clone run exit0:15 MATCH +2 INFO. No runtime/DDL or stock,
reservation, FIFO, payment, cashier-session, Finance or audit mutation in this fix.
No privileged credentials logged; no CLI/environment/Production link changed.
Next safe step: obtain complete Production diagnosis, confirm rollback/install
state, then inspect actual discrepancy before any functional installer patch.
Keep historical tests intact; no reset, ledger insertion or guard bypass.



## Current 2026-09-16 - recovery release candidate

Supersedes historical NOT READY / pending notes below.
LOCAL READY: six repair migrations and existing UI/API/document-log integration.
DATABASE LIVE: clone idrufihckscppsyclmsu only. No Production SQL/deploy by agent.
12 nonzero rollback behavioral regressions exit0: open/closed sessions, shared
request/two recovered SOs, final PO, actual partial/full dispatch, role/tenant,
retry/stale, Retail/Office Invoice/DP/payment and Purchase regression.
Two live connections verify Recovery Company-lock serialization; retry separately.
Scoped eslint, tsc and Next production build exit0 (compile-only non-access keys).
Atomic installer re-entry/parser proof exit0; full release postflight25 PASS.
No fake Receive/stock reset/historical plan-item-KEEP_ITEM rewrite.
Linked active procurement remains blocked on reverse until ownership transfer.

Production nine orders are NOT claimed restored. CLIENT DEPLOYED,
authenticated HTTP SMOKE PASS and UAT PASS remain manual gates.
[Current report, complete package and installation order](../runbooks/OFFICE_PROCUREMENT_RECOVERY_RELEASE_REPORT_2026-09-16.md).
Use its one atomic bundle, NOT historical partial installation instructions.
Changed: six new migrations, release pre/post/installer, representative tests,
cutover route/settings, SalesOrderView/page deep links, SalesDocumentView logs,
impact/spec/root/router/handoff. Recovery is explicit Super Admin action with
current versions, atomic target/link/audit and immutable APPLY_ITEM exact retry.
Next safe step: user Production preflight/fingerprints, atomic install/postflight,
unchanged-data comparison, user push/redeploy without env change, KMS/LSM smoke.
Stop on drift/blocker; no reset, ledger-only insertion or private SQL bypass.


## Confirmed relationship inventory and approved design (latest)

2026-09-16 release completion impact (before implementation): open-session
fixture confirms CUTOVER_PROCUREMENT_PRESERVATION_FAILED because JSON null
snapshots are compared to SQL NULL after LEFT JOIN. Normalize absent request
rows to JSON null; retain whole-row preservation comparisons for present rows.
Additive forward-fix only, do not edit installed15141000 history. No data backfill.
Historical recovery uses the existing immutable cutover audit APPLY_ITEM with
explicit recovery metadata, leaving APPLIED plan/KEPT item/KEEP_ITEM untouched.
Public Super Admin RPC validates active Company Office mode, source/item/current
versions, prior KEEP_ITEM procurement-only reason, no existing target, current
canonical converter eligibility. Company-mode then cutover advisory locks and
row locks; same operation exact retry returns original result. Target/link/audit
commit atomically; any failure rolls back. Existing plan read projects recovered
target from appended audit; existing document-log reader must expose that audit.
Reverse linked active procurement must use the existing OPEN_PROCUREMENT blocker
in preview and converter until a verified ownership transfer exists. No new
Retail policy, no stock/payment/Finance reset, no Production mutation by agent.

Production attachment 5937d25d-9618-412a-ba9b-f57b3c12a875 establishes nine
Office-Company retained Retail sources, 27 REQUESTED demand lines, two SUBMITTED
Stock Requests, no supplier-order allocations, no dispatch or payment, closed
sessions, and source Invoice snapshots. Shared Stock Request lines occur across
several source orders; preserve those identities and do not duplicate them.

User explicitly approves preserving the active Stock Requests and linking them
to target Office SOs without replacement purchasing requests. Implementation is
split at invariant boundaries, not silently removing a blocker:

1. Add immutable Company-scoped procurement lineage and an authorized read
   contract; do not activate conversion or release anything in this phase.
2. Preserve procurement through source cancellation and recover APPLIED/KEPT
   sources; adapt actual preview and subsequent Office lifecycle consumers.
3. Integrate existing document logs/recovery UI and authenticated end-to-end
   verification with source-target/Stock Request identity reconciliation.

User delegates the balanced synchronization method (stock0 is not permission
to reset stock). Phase2 preserves original purchasing obligation on conversion.
Office revision reduces/reinstates that obligation within its original shortage
cap, distributing shared Product demand once across source lines. Removed Product,
changed Warehouse or canceled SO releases the old obligation. Extra Office Reserve
does not create another Stock Request: the approved Office replenishment basis
remains actual negative On Hand. Canonical request reconciliation/Draft PO sync
protects existing PO commitments and creates existing amendments when required.

Phase2 direct changes: narrow cancellation refresh adapter, converter linkage,
Office Save/Cancel synchronization wrappers, procurement classifier, additive
authenticated recovery of historical KEPT items. Historical APPLIED plan/item
and KEEP_ITEM audit remain unchanged; recovery appends APPLY_ITEM with explicit
recovery metadata. No automatic recovery/backfill during migration.
Downstream coverage: aggregate shared request-line Warehouse once (not a join
that multiplies one request quantity per demand). Reverse cutover of a linked SO
must preserve procurement through a separately verified reverse path; keep the
existing procurement restriction until that path is proved.
Locks: mode advisory then Company cutover advisory, target/source/dependency
rows; all operations and request changes atomic. Expected version and operation
actor/source correlation are mandatory; retry must not duplicate target/audit.
No Stock/FIFO/payment/session/Finance mutation. Nonzero clone fixtures must cover
closed/open session, shared request, reduce/reinstate/cancel, commitment protection,
paid/dispatched denial, stale/retry and tenant scope. HTTP smoke is a separate gate.
Forward fix only after active lineage: do not drop links or reactivate canceled
Retail sources, as either would lose history or duplicate reservations.

Foundation impact: one additive linkage table, private linker, immutable/scope
guard and Sales VIEW read RPC; only linkage rows/ledger may be written. No
existing demand/request/PO/reservation/Stock/FIFO/payment/session/Finance/audit
mutation. Tenant FK, unique demand lineage, captured before-state, exact retry,
Company advisory lock and actor/context enforcement are required. Backfill is
zero rows: conversion has not occurred and history must not be fabricated.

## Latest requirement and actual Production evidence

User 2026-09-15: orders already entered must move with the business process;
internal procurement must not leave them behind. This overrides the earlier
procurement-only grandfathering rule for the affected open orders. Do not
silently equate a procurement fix to conversion of every financial/status case.

Attachment 79114153-a702-45bf-b3de-564d55d3930e confirms:
- KMS plan 5f6c3894-f455-4071-9094-7e9e69f6e9ab APPLIED, four BLOCKED/KEPT.
- LSM plan e56b0339-9395-432d-bcad-8a60c46c0543 APPLIED, five BLOCKED/KEPT.
- All nine have only OPEN_PROCUREMENT_MUST_FINISH and null target IDs.
  Both Company modes are Office; Office SO and Quotation counts are zero.
  This is actual retention, not an established environment/list rendering bug.

## Impact map before any converter patch

- Direct: actual-data preview, classifier, Retail-to-Office converter, and
  additive recovery of already-APPLIED/KEPT sources. Original Apply cannot
  simply be retried to convert those historical items.
- Consumers/tables: sales_headers, Retail reservations, procurement demand/lines,
  stock requests, supplier-order allocations, Office SO/lines/reservations/DO,
  cutover plans/items/audit and document-log readers. Office list already reads
  the correct Office aggregate; projecting Retail rows alone is not conversion.
- Downstream: public.cancel_pos_sales_order invokes procurement refresh, whose
  composed wrappers call request reconciliation and single Draft PO sync.
  Source reservation release therefore releases internal demand and can alter
  related RO/Draft PO or create an amendment against a final PO.
- Stock/FIFO/payment/session/Finance: do not dispatch, duplicate reservation,
  invent session identities, reverse payments, or modify posted journals.
  Office Confirm creates its own reservation/DO; retaining the active Retail
  reservation would double reserve.
- Old data: demand sales_id and reservation_line_id FKs target Retail tables,
  not Office UUIDs. Preserve source IDs and immutable history; do not rewrite
  APPLIED-plan audits as though the original conversion had succeeded.
- Concurrency/idempotency/retry: Company transaction lock, locked source and
  purchasing dependencies, expected versions, exact operation retry and unique
  target lineage are required. Recovery is not a mode flip or historical reset.
- Regression risk: merely removing the procurement blocker exposes cancellation
  side effects. RO/PO/Receipt links must be inventoried before choosing recovery.
- Rollback: representative fixture writes roll back together; no production
  deletion, reset, mode flip or ledger-only repair is authorized.

## Required facts and next safe step

The supplied output has a boolean procurement blocker, not actual RO/PO links.
OPEN, REQUESTED, ORDERED and AMENDMENT_REQUIRED all produce that same boolean.
Whether the nine sources have only internal demand or allocated purchasing
documents is not established. Payment/revision/partial dispatch cases outside
the nine must not be silently included/excluded under a claim of all orders.

Run the complete SELECT-only
`supabase/diagnostics/office_sales_retained_procurement_inventory.sql` in
Production. It inventories all nonterminal Retail sources, actual demand,
RO/PO allocation/Receipt state, payment/revision/dispatch boundaries and cutover
links. Retain the full result; do not run a selected fragment.

After that: design against actual links, then deliver guarded migration,
preflight, postflight, representative rollback behavior and authenticated smoke.
No ready-for-presentation claim before actual source-target/downstream evidence.

## Evidence and delivery status

## Pre-dispatch delta design (before implementation, 2026-09-15)

2026-09-16 verification: delta15142000 installed in clone, preflight3 PASS/1 SETUP/
1 INFO, postflight5 PASS/1 INFO. Nonzero owned public lifecycle test exit0:
same SO/Reservation/DO identity, qty reduce/reinstate/cap and old request sync,
full immutable audit, exact retry/stale, Warehouse opt-out atomic rollback,
cancel/retry, real partial/full dispatch denies ordinary revision/cancel.
Regression ordinary converter both ways/Apply/Invoice-DP-payment/Purchase
Receive-Bill-payment exit0, all fixtures rollback. Targeted UI eslint/tsc exit0.
No Production installation/recovery/deploy or authenticated smoke. Historical
APPLIED/KEPT recovery and shared/final-PO/open-session/linked-reverse/concurrency
matrix remain unverified; whole recovery is not release ready.

Additional owned shared-request fixture exit0: two canonical Retail sources share
one request line; one converted SO qty reduce/reinstate/cancel preserves the other
Retail source and its requirement. All writes rolled back. Multiple converted
links, final PO commitments and other listed release gates remain unverified.

Actual clone pg_constraint/pg_trigger inventory establishes mutable pre-dispatch
lines and protected Invoice/Dispatch/Receipt/Discrepancy consumers. Same SO,
Reservation and initial DO IDs/numbers remain. Canonical Save retains pricing,
role/version/reason/audit behavior and rewrites only unconsumed mutable line rows.
Before that rewrite, an authorized private delta adapter locks the SO, Reservation,
DO and child rows, validates one untouched active Reservation/initial ready DO,
and rejects actual dispatch/receipt/invoice/discrepancy dependencies. Capture full
old headers/lines in immutable fulfillment audit before rebuilding mutable lines.
No posted history, link table or purchasing identity is deleted.

Rebuild uses the audited canonical stock-requirement/availability/Bundle/Warehouse
opt-in algorithm, updating existing parent headers instead of inserting another
Reservation/DO or issuing another document number. Stock lock/shortage checks
remain; neither On Hand nor FIFO changes. No temporary status rollback: core
Save accepts PREPARING only in an actor/order-bound, validated delta context.
Failure rolls back detach, Save, procurement sync, rebuild and audit together.
Cancellation releases the untouched existing reservation and cancels existing DO
transactionally before canonical status/audit operation and demand sync.
All normal Draft operations and unrelated Retail remain on their existing chain.
Post-dispatch/received/invoiced boundaries stay fail-closed; no new Retur policy.

Clone idrufihckscppsyclmsu SELECT execution exit0, 25 INFO rows. This proves
SQL/schema execution, not Production relationships or converter behavior.
No runtime/schema/Stock/FIFO/payment/Finance mutation or deployment performed.
Converter fix and Production recovery remain pending actual relationship data.
