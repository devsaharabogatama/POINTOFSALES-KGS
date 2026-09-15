# Procurement-preserving Office recovery


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
[Current report, complete package and installation order](OFFICE_PROCUREMENT_RECOVERY_RELEASE_REPORT_2026-09-16.md).
Use its one atomic bundle, NOT historical partial installation instructions.
Changed: six new migrations, release pre/post/installer, representative tests,
cutover route/settings, SalesOrderView/page deep links, SalesDocumentView logs,
impact/spec/root/router/handoff. Recovery is explicit Super Admin action with
current versions, atomic target/link/audit and immutable APPLY_ITEM exact retry.
Next safe step: user Production preflight/fingerprints, atomic install/postflight,
unchanged-data comparison, user push/redeploy without env change, KMS/LSM smoke.
Stop on drift/blocker; no reset, ledger-only insertion or private SQL bypass.


## Delivery boundaries

Phase 1/3: immutable linkage foundation and authorized reader only.
Phase 2/3: procurement-preserving cancellation, revised preview, recovery of
already-APPLIED/KEPT sources and Office lifecycle synchronization.
Phase 3/3: existing document-log/recovery UI integration and authenticated smoke.

Latest user decision: existing Stock Requests stay active and are linked to
target Office SOs, not regenerated. Latest follow-up delegates a balanced method
with target stock zero. This does not authorize resetting product_stocks or
fabricating receipts: On Hand changes only via valid posted operations.

Production evidence: nine RESERVED sources, 27 REQUESTED demand lines, two
SUBMITTED Stock Requests with shared request lines, zero PO allocations, closed
sessions and no payment/dispatch. Recovery must revalidate live facts.

## Phase 1 package

Run entire files in this order on the rehearsal clone first:

1. `supabase/diagnostics/sales_cutover_procurement_lineage_preflight.sql`
2. `supabase/migrations/20260915140000_sales_cutover_procurement_lineage_foundation.sql`
3. `supabase/tests/sales_cutover_procurement_lineage_behavior.sql`
4. `supabase/diagnostics/sales_cutover_procurement_lineage_postflight.sql`

Fresh installation SETUP is expected; dependency or orphan-object BLOCKER is not.
The test owns Draft/Confirm/closed Session/Stock Request/Office Draft fixtures
and all fixture writes roll back. It does not need a user-created operational
Draft or open session. Existing canonical active master tuple is required.

This package must NOT be presented as restoring the nine Production orders.
Do not apply a converter patch or replay historical APPLIED plans until phase 2
and downstream lifecycle behavior have been verified. Authenticated HTTP smoke
and global document-log integration remain phase 3, not a Phase 1 PASS claim.

## Backfill, rollback and forward-fix

No backfill in phase 1: links are captured only when a real conversion/recovery
creates its target; inventing target/source links would falsify history.
No existing operation, demand/request/PO/Receipt, reservation, Stock, FIFO,
payment, Session or Finance row is mutated by foundation installation/linking.

Migration is transactional; any installation error rolls back its whole change.
Rollback-only behavioral fixtures roll back independently. After committed
links exist, do not delete linkage history, edit its snapshot or remove ledger
entries. If later runtime activation fails, keep foundation and old purchase
identities; use an additive forward-fix and stop recovery execution. Leaving
the foundation unused changes no existing business operation. Do not disable
immutability or bypass the canonical cancellation chain to obtain PASS.

## Verification state

Phase 1 preflight clone PASS dependencies/SETUP fresh foundation; migration
exit0 installed on clone idrufihckscppsyclmsu. Owned canonical shortage Draft,
Confirm, closed Session, submitted Stock Request, Office Draft and actual linkage
behavior exit0; retry, authorized read, immutable/actor/operation/context/Company
denial and identical operational snapshots tested. All fixture writes rolled
back; postflight five PASS/one INFO, zero live links NOT behavioral evidence.
Test corrections: canonical Office Save returns data.id; other-Company fixture
Sales feature must be active to reach document-scope assertion. No runtime guard
was relaxed. No Production mutation or deploy.
No phase 2/3 ready/live/smoke/UAT claim.

## Phase2 historical blocker (2026-09-15): NOT RELEASE READY

Clone-only runtime20260915141000 and matching retention preflight/postflight/
behavior were added. Installation exit0; preflight4 PASS/1 SETUP, postflight5
PASS/1 INFO. Do NOT install this runtime migration in Production yet.

The real nonzero public lifecycle test is not PASS. An initial fixture used
unpaid non-TEMPO; canonical Confirm correctly rejected PAYMENT_TOTAL_MISMATCH.
Fixture changed to unpaid TEMPO with valid due date, not a relaxed payment guard.
The second run reached confirmed SO/DO and exact converter retry after asserting
unchanged demand/request/stock/FIFO/Finance, then failed at actual public Save:
BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC.
The whole fixture transaction rolled back; persisted links0 is not test success.

Read-only actual clone definitions establish the incompatible lifecycle:

- compose_backoffice_sales_confirm_fulfillment creates Reservation/initial READY
  DO and changes SO fulfillment to PREPARING automatically.
- save_backoffice_sales_order_draft_before_pricelist_header allows confirmed edit
  only when fulfillment_status=CONFIRMED, then deletes/recreates SO lines.
- transition_backoffice_sales_order permits confirmed Cancel only at CONFIRMED.
- Reservation and DO line FKs reference SO line identity ON DELETE RESTRICT.

Removing the status guard would not supply the missing Reservation/DO delta and
would encounter protected line references. No such guard removal was performed.
Audit must cover all these downstream dependencies before another runtime patch.
Historical recovery RPC/UI remains unimplemented; no Production orders restored.

Next safe boundary: transactional pre-dispatch revision/cancellation with same
SO/DO identities, canonical pricing, Warehouse opt-in, immutable before/after
history, and no mutation of dispatched/received/invoiced/FIFO/payment history.
Then rerun actual public Save/Cancel plus shared-request, commitment, open/closed
session, stale/retry and tenant matrix; only after that activate recovery.

Rollback/forward-fix: clone installed runtime remains under test with no persisted
links/recovery. Do not reset clone or delete migration ledger. Production remains
unchanged. If this phase was installed externally, stop conversion/recovery and
inventory actual lineage before forward-fix; do not reactivate Retail sources or
delete linkage/audit, which could duplicate reservation and lose traceability.

## 2026-09-16: bounded pre-dispatch delta verified in clone

The earlier public confirmed revision/cancel blocker is resolved in clone by
20260915142000. This is not the historical APPLIED/KEPT recovery implementation.
Same SO, Reservation and initial DO IDs/numbers remain. The authorized adapter
locks/validates untouched parents and children; captures full old plans; rebuilds
only unconsumed mutable children with canonical requirements/stock/Bundle/pricing;
and appends immutable before/after fulfillment audit. It never deletes posted
history or resets SO status to bypass a gate. Failure rolls back Save, fulfillment
and procurement synchronization together. Cancel releases existing Reservation
and cancels the same DO before canonical operation/audit completion.

### Complete delta package, clone only for now

Dependency chain:15140000 ->15141000 ->15142000. Do not install only the last
file on Production or activate the incomplete retention/recovery package.
After prerequisites, execute each whole file, not selected text:

1. [Preflight](../../supabase/diagnostics/office_pre_dispatch_fulfillment_delta_preflight.sql)
2. [Migration15142000](../../supabase/migrations/20260915142000_office_pre_dispatch_fulfillment_delta.sql)
3. [Rollback-only behavior](../../supabase/tests/office_pre_dispatch_fulfillment_delta_behavior.sql)
4. [Postflight](../../supabase/diagnostics/office_pre_dispatch_fulfillment_delta_postflight.sql)

Clone installation exit0, preflight3 PASS/1 SETUP/1 INFO, postflight5 PASS/1 INFO.
First installation attempt rolled back due to a missing generated-function SQL
terminator; corrected SQL terminator and reinstalled, no runtime guard disabled.
Nonzero owned public lifecycle fixture exit0: conversion/preserved request,
same-parent revision, request reduction/restoration/cap, full history, exact retry,
stale denial, Warehouse opt-out failure restores all state, cancellation/retry,
real partial and full dispatch reject ordinary revision/cancel. All fixture rows
rolled back; sequence values may advance despite rollback.

Regression exit0: retention, ordinary converter both directions, atomic Apply,
SO invoice status/DP/payment and Purchase AUTO_PO/Receive/Bill/payment. The old
reverse fixture was prepared in Company Office mode within rollback, clearing
trusted preparation scope before public creation. The old Invoice fixture now
uses Company timezone date rather than database current_date for acceptance.
These are fixture corrections, not disabled production mode/date guards.
Targeted Backoffice SalesOrderView eslint and TypeScript noEmit exit0.

### Rollback / forward-fix / smoke boundary

Installation is transactional. No existing-row backfill or posted stock/FIFO/
payment/session/Finance effect occurs from installing the delta. After committed
revisions, do not delete audits/lineage or restore an old Save implementation that
cannot maintain current fulfillment. Stop conversion/recovery and use an additive
forward-fix against inventoried current versions. Do not reset database/stock.
SQL prerequisite rollout must precede client rollout. Authenticated smoke must
exercise Edit/Cancel with allowed role, denied role, same document links/history,
Warehouse opt-out rollback, dispatch protection and list refresh on the intended
Company. Agent has not deployed client or executed authenticated HTTP smoke.

### Remaining release gates, not claimed as PASS

Additional [shared-request rollback behavior](../../supabase/tests/office_retained_shared_request_behavior.sql)
exit0: two canonical Retail orders share one Stock Request line. Converting,
reducing/restoring/cancelling one SO preserves the other RESERVED Retail order
and unreleased demand. Request totals4 ->3 ->4 ->4 ->2 in canonical UOM factor.
This proves mixed-source sharing, not multiple converted links/final commitments.

Shared request with multiple converted links; final PO commitments; open session
with absent request snapshot (JSON null versus SQL NULL preservation boundary);
linked Office reverse ownership; actual concurrent execution; historical
APPLIED/KEPT recovery RPC/current-version/exact-retry and source log links.
Ordinary reverse regression is not proof for linked Office reverse conversion.
Production nine sources remain unrecovered. LOCAL READY applies only to this
bounded delta; DATABASE LIVE is clone only; CLIENT DEPLOYED, SMOKE PASS and UAT
PASS are not established for this fix. Whole recovery remains NOT RELEASE READY.
