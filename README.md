# MADS — Management Distribution System

## 2026-09-16 - Backoffice Quotation mode guard LOCAL READY

Quotation Baru sekarang membaca proses aktif Company dan tidak membuka editor
Office yang pasti ditolak ketika Company masih Retail. Pesan mengarahkan user ke
Pengaturan Sales; database cutover guard tetap utuh. Client/API read-only change,
tanpa migration, transaksi, Stock atau Finance mutation. SMS tetap memerlukan
Apply proses Office melalui UI setelah client deployment.
[Impact](docs/audits/BACKOFFICE_QUOTATION_MODE_GUARD_IMPACT_2026-09-16.md).

## 2026-09-16 - Purchase saved Receipt resume fix LOCAL READY

Single/bulk Receive restores saved legacy Receipt lines even when PO line
destinations are null; saved qty/UOM/conditions/SJ/notes are retained. Unsaved
Warehouse boundaries remain. Representative12-line tests, lint/tsc PASS.
Client-only patch, no migration/data reset/stock or Finance writer change.
Production client deployment/authenticated smoke pending.
[Rollout and commit commands](docs/runbooks/PURCHASE_RECEIPT_SAVED_LINES_FIX_2026-09-16.md).

## 2026-09-16 - Office history visibility patch LOCAL READY / clone verified

Original Retail inputs/history now read in existing Quotation/Sales Order list,
with original status, detail and canonical Invoice template. Converted source
links are in SO activity; no duplicate active source or transaction recreation.
Additive read-only reader requires one migration, no historic data backfill.
Clone116 sources/all detail lines PASS, protected values unchanged; canonical
recovery/dedupe/cross-Company regression exit0. Production install/client smoke
for this patch remain manual, not inferred from prior six-release PASS.
[Patch rollout](docs/runbooks/OFFICE_HISTORY_VISIBILITY_RELEASE_2026-09-16.md).

## 2026-09-16 - Production database PASS, user Git delivery pending

User Production runtime/ACL postflight25 PASS, six migration ledger entries.
Legacy reconciliation matches16 previous closing table results; cashier109
already documented (historical full109 digest not captured). UI deployment,
authenticated recovery smoke and UAT remain pending, not database-install gates.
[Scoped commit/push script](scripts/commit-push-office-recovery.ps1):
default preview; -Execute stages only listed recovery files and pushes main.
Excludes HR/dummy/bootstrap operations, rejects unrelated staged files/commits,
no force/pull/reset or Supabase/env mutation. User executes, agent does not push.


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
[preflight](supabase/diagnostics/office_procurement_recovery_release_preflight.sql),
[transaction fingerprints](supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql),
[updated atomic installer](supabase/releases/office_procurement_recovery_install.sql),
[updated postflight](supabase/diagnostics/office_procurement_recovery_release_postflight.sql),
then same fingerprints BEFORE recovery. All17 counts/digests must match while
paused; postflight expects25 PASS. Do not rerun previous90 files or seed tests.
On genuine error, transaction guard still rolls back; stop, retain error, trace
actual definitions rather than bypass. Then user client deployment/recovery smoke
as detailed in current release report. No restored-Production-order claim yet.



## 2026-09-16 - PRODUCTION INSTALL BLOCKED: all15 runtime fingerprints fail

Supersedes release-candidate readiness below. User reports RELEASE_RUNTIME_DRIFT
for all15 functions at final guard before COMMIT. Do not retry/deploy/recover yet.
Committed Production installation state must be checked from the live ledger.
Clone raw fingerprints still match15; CR count0 for all15. Local bundle and reader
migration CR count0. Neither actual Production code drift nor clipboard/formatting
cause is proved; do not normalize/remove fingerprint guard on this evidence.
Prior bundle test was installed-clone re-entry, NOT fresh combined installation.
That proof did not establish fresh Production bundle readiness.

[Read-only live diagnosis](supabase/diagnostics/office_procurement_recovery_runtime_drift_diagnosis.sql) returns one result set:
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
Clone installation re-entry preserves all17 protected transaction fingerprints;
all six bundled source bodies match reviewed migrations exactly.
No fake Receive/stock reset/historical plan-item-KEEP_ITEM rewrite.
Linked active procurement remains blocked on reverse until ownership transfer.

Production nine orders are NOT claimed restored. CLIENT DEPLOYED,
authenticated HTTP SMOKE PASS and UAT PASS remain manual gates.
[Current report, complete package and installation order](docs/runbooks/OFFICE_PROCUREMENT_RECOVERY_RELEASE_REPORT_2026-09-16.md).
Use its one atomic bundle, NOT historical partial installation instructions.
Changed: six new migrations, release pre/post/installer, representative tests,
cutover route/settings, SalesOrderView/page deep links, SalesDocumentView logs,
impact/spec/root/router/handoff. Recovery is explicit Super Admin action with
current versions, atomic target/link/audit and immutable APPLY_ITEM exact retry.
Next safe step: user Production preflight/fingerprints, atomic install/postflight,
unchanged-data comparison, user push/redeploy without env change, KMS/LSM smoke.
Stop on drift/blocker; no reset, ledger-only insertion or private SQL bypass.


> 2026-09-16: pre-dispatch revision/cancel delta20260915142000 is clone-verified.
> Same SO/Reservation/DO identities, canonical recomposition and immutable audit;
> real partial/full dispatch remains protected. Retention, ordinary converter
> two-way, Apply, Invoice/DP/payment and PO/Receive/Bill/payment regression exit0.
> Client eslint/typecheck passed; no Production rollout/client smoke for this fix.
> Historical nine-order recovery RPC and remaining procurement matrix are pending:
> the entire recovery is still NOT RELEASE READY. Do not deploy the incomplete
> retention package. [Current evidence](docs/runbooks/SALES_CUTOVER_PROCUREMENT_RECOVERY.md).
>
> Historical 2026-09-15 blocker (resolved in clone, not Production):
> Procurement recovery current phase2/3 is NOT RELEASE READY. Clone retention
> migration20260915141000 installed; preflight4 PASS/1 SETUP, postflight5 PASS/1 INFO.
> Nonzero conversion fixture stopped at confirmed SO revision: Confirm automatically
> creates PREPARING/READY fulfillment, while canonical Save only accepts CONFIRMED
> fulfillment. Actual Cancel has the same state limitation. Do not relax guards:
> Save deletes/recreates SO lines whose Reservation/DO foreign keys restrict deletion.
> Recovery RPC/UI and Production nine-order recovery are not delivered or executed.
> [Root-cause/evidence and next safe boundary](docs/runbooks/SALES_CUTOVER_PROCUREMENT_RECOVERY.md).

> Procurement-preserving recovery Phase1/3 foundation is clone-verified:
> [rollout/evidence boundaries](docs/runbooks/SALES_CUTOVER_PROCUREMENT_RECOVERY.md).
> Immutable Company-scoped links and Sales VIEW reader preserve existing records;
> canonical owned fixture, retry, authorization and zero operational delta tested.
> This does NOT activate converter/recover retained Production orders; phases2/3
> and authenticated smoke remain pending. No Production reset/mutation/deploy.

> Production Office-empty root cause confirmed: KMS4/LSM5 sources are KEPT solely
> by the procurement blocker in APPLIED plans, with no target documents. Latest
> user decision requires entered orders to move with the business process.
> [Impact audit](docs/audits/OFFICE_SALES_RETAINED_PROCUREMENT_IMPACT_2026-09-15.md)
> and [read-only procurement inventory](supabase/diagnostics/office_sales_retained_procurement_inventory.sql)
> are available; clone SELECT exit0/25 INFO rows is not conversion behavior PASS.
> Actual Production RO/PO links are required before guarded recovery. No fix,
> Production mutation or deployment performed by this task yet.

> User reports empty Office SO after Production activation. [Read-only cutover/list diagnosis](supabase/diagnostics/office_sales_empty_list_cutover_diagnosis.sql)
> is clone syntax-verified; Production mode/counts/lineage await user output. No
> speculative data conversion or application fix performed.

> Release preparation authorized by user: old11 dispatch audits/current COGS and
> one Session CLOSE agree with recorded operations; no fix justified by that trace.
> Local Vercel links point to projects named staging; exact live hosting targets
> and branch await confirmation before deployment. Client smoke/UAT still pending.

> Production DATABASE LIVE user-confirmed: all90 files and final postflight PASS.
> Client deployment/smoke/UAT not yet confirmed. [Reconciliation and client release](docs/runbooks/OFFICE_PURCHASE_PRODUCTION_CLIENT_RELEASE.md)
> uses actual pre-rollout Production legacy-column fingerprints; no fresh clone
> or repeated migration required by default. Agent has not deployed/changed modes.

> Post-rollout legacy reconciliation: user output11 tables PASS/six REVIEW while
> business continued. [Read-only operational trace](supabase/diagnostics/office_purchase_production_operational_delta_trace.sql)
> is clone syntax-verified; Production trace and per-product Stock delta remain
> unproved. No transaction mutation, client release or mode activation performed.

> [Post-rollout review](docs/audits/OFFICE_PURCHASE_PRODUCTION_POST_ROLLOUT_REVIEW_2026-09-15.md):
> old Movement/Event candidate hashes match; current22 affected Stock balances
> match supplied latest Movement balances. Old Sales/Detail/Session history and
> eleven HOLD dispatch Events still need review; authenticated client smoke pending.

> Manual Production install package ready:90 exact files,8 checkpoints, SHA256;
> targeted data guards user PASS. [Open ordered install guide](docs/runbooks/OFFICE_PURCHASE_PRODUCTION_MANUAL_INSTALL.md).
> Production database/client not installed by agent; backup/maintenance, checkpoint
> verification and authenticated smoke/UAT remain required. No fresh clone required by default.

> 2026-09-15 NEXT GATE: reuse completed clone rehearsal; current Production audit
> is SELECT-only and manual. No automatic fresh clone/full replay due to added
> transactions. See [delta audit package](docs/runbooks/OFFICE_PURCHASE_PRODUCTION_DELTA_READ_ONLY.md).
> Migration/deployment remain unauthorized until actual delta and smoke gates close.

> Production outputs reviewed: 702 unchanged routine definitions; 26 differences
> have rehearsed writer locations. 90 ledger-missing files (88 base +2 extras),
> not an execution-order list. Targeted Receipt/negative-evidence data checks next:
> [delta review](docs/audits/OFFICE_PURCHASE_PRODUCTION_DELTA_REVIEW_2026-09-15.md).

> 2026-09-15 FINAL CLONE CHECKPOINT: 89/89 local candidate versions reconcile to
> clone ledger (one preinstalled; 88 base delta), plus Receipt dependency and DP
> forward fix. Canonical WALK-IN/SO regression 22 PASS; Purchase PO/Receipt through
> existing Bill and partial/full Payment 16 PASS; closing FIFO/permission checks
> PASS. Sales baseline identities/values and legacy transaction counts preserved.
> Five Companies stay Retail and Purchase MANUAL. Production/client not deployed;
> current read-only Production delta audit and authenticated UI/concurrency/UAT remain gates.
> See [final clone report](docs/runbooks/OFFICE_PURCHASE_CLONE_REHEARSAL_FINAL_REPORT.md).

### Historical checkpoints below — superseded by the final checkpoint above

> 2026-09-15: Clone Purchase chain through 20260914180000 installed and canonical
> generated-Receipt rollback test PASS (10 scenarios); PO revision test PASS (8).
> Final candidate-ledger reconciliation found 20260912139000 not yet installed;
> this missing WALK-IN payment fix is being audited, so full rehearsal is NOT COMPLETE.
> Production/client untouched. Historical counts remain unchanged before final
> Receipt migration; exact closing preservation and authenticated UI/UAT pending.

> 2026-09-15: Historical clone 76/88 base migrations installed, plus DP compatibility
> fix and missing Receipt workspace dependency 20260825131000. Canonical SO/Invoice/
> DNI rollback behavior and C2B/C3 regressions PASS; Purchase foundation/preview/
> AUTO_RO/AUTO_PO rollback tests and postflight PASS. AUTO_PO warehouse policy is
> intermediate until remaining approved forward fixes. Five Companies stay MANUAL.
> Production/client untouched; Receipt chain, final preservation/UI/UAT still pending.

> 2026-09-15: Clone base chain 72/88 plus additive DP fix 20260915100000 installed.
> DP/overage fix preflight four PASS, postflight three PASS. Canonical test reaches
> DP/Regular Posted and real DNI exit, then stops at Company-2 VIEW permission denial.
> Full behavior NOT PASS; fixture transaction rolls back, document rows zero.
> Production/client untouched; tenant permission expectation audit is next.

> 2026-09-15: Clone 72/88 INSTALLED, NOT BEHAVIOR READY. Canonical rollback fixture
> added for SO Invoice status and real-row DNI. Test stops at DP Draft: active core
> sets overage input [] but trigger rejects non-REGULAR Invoice. Unit 72 postflight
> five PASS; fixture SO/DO/Receipt/Invoice rows all zero after error rollback.
> Forward-fix audit required before continuation; Production/client untouched.

> 2026-09-15: Historical clone 71/88 INSTALLED. Unit 71 DNI migration, classifier/
> definition test and seven postflight checks PASS; real-row report/auth UI coverage
> remains pending. STOP BEFORE unit 72: preflight has zero Backoffice SO; its test
> requires an existing SO and lacks a canonical rollback fixture. Production untouched.

> 2026-09-15: Historical-clone rehearsal 70/88 INSTALLED. Stock Loss 68–69:
> migration/postflight and 13-scenario rollback behavior PASS. Unit 70 ledger split:
> preflight/postflight and C3 12-scenario retest PASS, finalLedgerSplitVerified=true.
> Production/client untouched. Next unit 71 report preparation audit; fresh-clone
> comparison, authenticated UI smoke and UAT remain pending.

> 2026-09-15: Historical-clone rehearsal 67/88 installed. Accepted-overage Finance
> preflight, migration, both postflight and 12-scenario behavior PASS. No posting
> Stock/Invoice/Payment delta. Stopped BEFORE Stock Loss group 68–69 on resolver
> ADJUSTMENT snapshot mismatch (existing forward-fix required); 68 preflight
> PASS/SETUP, no mutation. Production/client untouched; final ledger/UI/UAT pending.

> 2026-09-15: Historical-clone rehearsal 66/88 installed. C3 kind/catalog fixes
> and C4 gates PASS; C3 physical behavior historical pre-split PASS, NOT final
> Invoice ledger compatibility (split/retest pending). Test syntax error fixed
> and rerun PASS. Next 67 Finance fixture needs Auth/Office audit before execution.
> Production/client untouched; fresh clone/authenticated UI smoke/UAT pending.

> 2026-09-15: Still 62/88 installed. C3 fixture actor/mode preparation corrected
> but unexecuted; C3 preflight nine PASS. Stopped BEFORE unit 63 mutation on base
> resolver CORRECTION/BACKORDER contract mismatch. Existing forward-fix resolves
> it; C3 needs grouped dependency verification, not a standalone completion claim.
> Production/client untouched; fresh-clone/UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 62/88 installed. Unit 62 preflight,
> initial/closing postflight and nine-scenario workspace/detail behavior PASS.
> Stopped BEFORE unit 63: C3 fixture lacks Office setup and requires later ledger
> split migration; audit blocker, not executed SQL error. Production/client
> untouched. Fresh-clone rehearsal/authenticated UI smoke/UAT remain pending.

> 2026-09-15: Historical-clone rehearsal 61/88 installed. Unit 61 preflight,
> initial/closing postflight and 11-scenario Invoice runtime behavior PASS.
> Preparation fixed rollback-only; runtime guards unchanged. Stopped BEFORE
> unit 62 on missing Office-mode fixture setup (audit blocker, not SQL error).
> Production/client untouched; fresh-clone rehearsal and UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 60/88 installed. Foundation preflight,
> initial/closing postflight and 12-scenario real-row constraint/trigger behavior
> PASS, rollback-only. No physical Receipt/posting or full tenant-matrix claim.
> Stopped BEFORE unit 61 on missing Office-mode fixture setup. Production/client
> untouched; fresh-clone rehearsal and authenticated UI smoke/UAT pending.

> 2026-09-15: Progress remains 59/88. Unit 60 fixture partially rewritten with
> real rollback-only quantity checks; allocation-trigger coverage still incomplete
> and unverified. Stopped on CLI preflight file-read error (incorrect filename);
> no unit 60 SQL/migration executed, no Production/client writes. Complete fixture
> and use existing `_invoice_line_preflight.sql` before resuming clone rehearsal.

> 2026-09-15: Historical-clone rehearsal 59/88 installed; reconstruction preflight,
> initial/closing postflight and nine-scenario behavior PASS. Warehouse OFF/ON,
> source-to-Transit FIFO/negative allocation and pending state verified rollback-only.
> Stopped BEFORE unit 60: its test uses UPDATE WHERE false and does not provide
> representative constraint behavior. Production/client untouched; fresh-clone
> rehearsal, authenticated UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 58/88 installed; shortage runtime plus
> audit forward-fix preflight/postflight and 15-scenario combined behavior PASS.
> NOT_LOADED return, linked Backorder, date default and retry verified rollback-only;
> LOST/DAMAGED not covered here. Stopped BEFORE unit 59 on missing Office-mode
> fixture setup. Production/client untouched; fresh clone and UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 56/88 installed; foundation preflight,
> migration, initial/closing postflight and seven-scenario constraint behavior
> PASS. Test follows installed ledger version; only pre-split branch executed.
> Stopped BEFORE unit 57 because shortage fixture lacks Office-mode preparation.
> Production/client untouched; fresh-clone rehearsal and UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 55/88 installed. Overage commercial
> approval preflight, initial/closing postflight and nine-scenario behavior PASS.
> Auth/Office fixture preparation rolls back; operational gates preserved.
> Stopped BEFORE unit 56 on missing Office-mode preparation in its fixture.
> Production/client untouched; fresh-clone rehearsal and UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 54/88 installed; mixed Receipt preflight,
> migration, initial/closing postflight and 11-scenario behavioral PASS. Fixture
> prepares Auth/Office rollback-only without bypassing operational gates. Stopped
> BEFORE unit 55 because its approval fixture lacks Office-mode preparation.
> Production/client untouched; fresh-clone rehearsal and UI smoke/UAT pending.

> 2026-09-15: Historical-clone rehearsal 53/88 installed, database gates through
> 53 PASS. Old Invoice-posting regression corrected with rollback-only Office
> setup and real Dispatch/Receipt; 14 scenarios PASS. Units 52–53 foundation and
> physical-state validator PASS, not mixed-operation smoke proof. Stopped BEFORE
> unit 54: its fixture lacks Office-mode preparation. Production/client untouched;
> fresh-clone rehearsal, authenticated UI smoke and UAT still pending.

> 2026-09-15: Historical-clone units 48–51 installed; combined payment behavior
> (17 scenarios) and primary closing postflights PASS. Partial→full payment,
> balanced receipt journal, history, AR reports and retry verified rollback-only;
> five Companies remain Retail. ODR Retail regression PASS, AR regression exits
> successfully. Stopped before additional old Invoice-posting regression because
> its fixture does not prepare Office mode. Unit 52 pending; Production/client
> untouched; final fresh-clone rehearsal and authenticated UI smoke/UAT pending.

> 2026-09-15: Rehearsal remains 47/88 PASS. Audit stopped before unit 48:
> Payment Collection fixture does not prepare Office mode before creating SO,
> while clone Companies remain Retail. Its evolved behavioral also waits for
> dependencies 49–51; that package ordering is expected, not a migration error.
> No DB writes or Production/client access this turn. Fixture correction and
> full dependency-chain audit are the next safe step.

> 2026-09-15: Historical-clone rehearsal unit 47/88 seluruh database gate PASS.
> Invoice Client fixture menyiapkan mode Office rollback-only tanpa bypass root
> gate. SO completion gate, ongkir, jatuh tempo, Qty hold dan read-model PASS;
> lima Company tetap Retail setelah rollback. Production/client tidak disentuh;
> final fresh-clone rehearsal dan authenticated UI smoke/UAT masih pending.

> 2026-09-15: Historical-clone rehearsal unit 46/88 seluruh database gate PASS.
> Negative Dispatch test menyiapkan mode Office hanya dalam rollback-only setup
> dan membersihkan marker sebelum RPC. OFF/ON, Transit/FIFO, penerimaan customer,
> replenishment dan COGS variance PASS; lima Company kembali Retail sesudah test.
> Audit berhenti sebelum unit 47 karena fixture Invoice belum menyiapkan mode
> Office. Production/client tidak disentuh; fresh-clone rehearsal dan UI UAT pending.

> 2026-09-15: Historical-clone rehearsal unit 45/88 seluruh database gate PASS.
> Unit 46 dihentikan sebelum migration: preparation behavioral mengaktifkan
> feature Office tetapi tidak menyiapkan mode Office, sedangkan lima Company
> clone masih Retail dan unit 45 menegakkan root-mode gate. Primary preflight
> unit 46 PASS belum membuktikan fixture siap. Production/client tidak disentuh;
> final fresh-clone rehearsal, authenticated UI smoke dan UAT masih pending.

> 2026-09-15: Preliminary historical-clone rehearsal unit 44/88 seluruh gate PASS.
> Behavioral Session Adoption memakai aktor Auth/Profile baru rollback-only,
> sehingga tidak berbenturan dengan sesi OPEN operasional. Adoption, preserved
> payment save, retry, stale version, dan closing postflight PASS; operations
> kembali nol. Production/client tidak disentuh; unit berikutnya 45/88.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 44/88,
> tetapi gate 44 belum lulus. Migration 42–43 beserta reverse-converter behavior
> PASS setelah fixture price resolution dibuat dua tahap. Migration 44 terpasang,
> lalu behavioral berhenti karena Super Admin fixture sudah mempunyai sesi OPEN
> (`uq_cashier_sessions_one_open_per_cashier`). Production/client tidak disentuh.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 41/88.
> Blocker fixture Retail→Backoffice diperbaiki dengan membuat feature enablement
> rollback-only, bukan mensyaratkan row feature historis. Migration dan behavior
> 41 PASS. Rehearsal berhenti sebelum migration 42 karena exact fixture gate
> Backoffice→Retail menerima error `ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND` dari
> resolver harga. Production/client tidak disentuh.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 40/88.
> Payment Term cutover boundary (`20260910152000`) dan unified Warehouse
> negative-stock authority (`20260910153000`) melewati preflight, migration,
> behavioral rollback, dan postflight. Migration 41 belum dijalankan karena
> fixture preflight Retail→Backoffice menemukan `BLOCKER`; diagnosis read-only
> kemudian berhenti pada schema error kolom `companies.name`. Production/client
> tidak disentuh.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 38/88.
> Cutover Retail Identity/Procurement Blocker dan Delivery Fee parity beserta
> immutable-history forward-fix (`20260910130000`–`151000`) melewati preflight,
> migration, postflight, serta behavioral rollback. Ongkir SO/Invoice dan jurnal
> `DELIVERY_FEE_REVENUE` terbukti tanpa backfill data lama; audit Invoice tetap
> immutable dan POS Retail tidak berubah. Production/client tidak disentuh.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 34/88.
> Invoice Finance Mapping/Posting (`20260909160000`–`161000`) dan Cutover
> Foundation/Preview/Persistent Preview/Refresh-Cancel (`20260909162000`–
> `20260910120000`) melewati preflight, migration, postflight, serta behavioral
> rollback. Invoice Journal dan permission boundary terbukti; semua Company
> tetap Retail dan seluruh cutover plan/item/audit kembali nol. Migration POS
> `20260910100000` yang sudah ada pada baseline juga terverifikasi ulang PASS.
> Production/client tidak disentuh dan belum ada mode switch aktual.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 28/88.
> Gate `20260909153000`–`20260909159000` untuk Receipt Finance Mapping,
> Customer Receipt runtime/posting, Invoice accounting foundation, Draft
> Invoice runtime, digest forward-fix, dan tax breakdown telah melewati seluruh
> preflight, fixture gate, migration, postflight, serta behavioral rollback.
> Receipt membentuk COGS/Inventory Journal canonical; Draft Invoice tetap tanpa
> Finance/Stock effect; breakdown pajak tersimpan dan terekonsiliasi. Seluruh
> fixture kembali nol, feature Office tetap OFF, dan baseline Retail tetap 216
> reservation / 256 delivery / 256 invoice / 585 movement / 245 event.
> Production/client tidak disentuh; final fresh-clone rehearsal tetap pending.

> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 21/88.
> Customer Receipt Foundation (`20260909152000`) telah melewati preflight,
> fixture gate, structural/closing postflight, dan behavioral rollback-only.
> Enam ledger quantity dan tiga relation immutable terpasang dengan zero
> backfill; formula Net Delivered/Qty To Invoice serta over-allocation guard
> terbukti, seluruh fixture hilang, dan baseline Retail/Finance tidak berubah.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 20/88.
> Dispatch to Transit (`20260909151000`) telah melewati dependency/fixture
> preflight, structural/closing postflight, dan behavioral rollback-only.
> Partial+full dispatch, exact retry, stale-version denial, FIFO transfer, dan
> Company stock conservation terbukti; Invoice/Event/Journal tetap nol dan
> seluruh fixture kembali hilang. Production/client tidak disentuh.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 19/88.
> Warehouse Transit Usage Foundation (`20260909150000`) telah melewati
> preflight, fixture gate, postflight, behavioral rollback, dan closing
> postflight. Satu Transit legacy dipertahankan unassigned tanpa perubahan;
> resolver lazy terbukti idempotent, duplikat ditolak, dan tidak ada efek
> Stock/FIFO/Movement. Production dan client tetap tidak disentuh.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 18/88.
> Reservation dan Delivery read-model (`20260909148000`–`149000`) telah
> melewati preflight, structural/closing postflight, dan behavioral rollback.
> Stock Overview menggabungkan POS+Office Reserved tanpa mengubah On Hand;
> Delivery Office terlihat melalui RPC tenant-scoped tetapi operasi tetap
> tertutup. Fixture kembali nol dan baseline Retail tetap utuh.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 16/88.
> Confirm fulfillment runtime (`20260909147000`) juga telah melewati preflight,
> fixture preflight, structural postflight, behavioral rollback-only, dan empat
> closing postflight. Penolakan stock-minus terbukti atomik, opt-in Warehouse
> membuat tepat satu Reservation dan initial DO, serta exact retry tidak
> menggandakan. Semua fixture kembali nol dan baseline Retail tidak berubah.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 15/88.
> Fulfillment foundation dan contract fix (`20260909145000`–`146000`) beserta
> fixture preflight, behavioral rollback-only, dan seluruh closing postflight
> PASS. Kontrak DO hanya `INITIAL/BACKORDER`, initial DO default `READY`, Office
> tetap OFF, tabel fulfillment Backoffice kembali kosong, serta baseline Retail
> tetap 216 reservation / 256 delivery / 256 invoice / 585 movement / 245 event.
> Production dan client tidak disentuh; fresh-clone rehearsal tetap pending.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 13/88.
> Revision/status, activity/cancel guard, dan commercial reset fix beserta
> preflight, behavioral rollback-only, dan closing postflight seluruhnya PASS.
> Office feature tetap OFF, Backoffice runtime kosong, amount constraint tetap
> aktif, dan baseline 256 snapshot / 216 reservation / 585 movement / 245 event
> tidak berubah. Production dan client belum disentuh.
>
> 2026-09-15: Preliminary historical-clone rehearsal mencapai migration 10/88.
> Formal role SALES/SALES_ADMIN, commercial parity, dan canonical price INSERT
> fix beserta preflight baru, structural/closing postflight, serta behavioral
> rollback-only seluruhnya PASS. Office tetap OFF; Backoffice runtime nol dan
> baseline 256 Delivery/Invoice snapshot, 216 Reservation, 585 Stock Movement,
> serta 245 Financial Event tetap utuh. Production dan client belum disentuh.
>
> 2026-09-15: Preliminary historical-clone rehearsal kini mencapai migration
> 7/88. Default Warehouse, canonical Sales tax, dan Pricelist header beserta
> fixture preflight, behavioral rollback-only, dan closing postflight seluruhnya
> PASS. Office feature tetap OFF, Backoffice runtime kosong, dan baseline tetap
> 256 Delivery/Invoice snapshot, 216 Reservation, 585 Stock Movement, serta 245
> Financial Event. Production/client deploy/smoke/UAT belum dijalankan.
>
> 2026-09-15: Preliminary rehearsal pada historical clone
> `idrufihckscppsyclmsu` sudah mencapai migration 4/88. Migration
> `20260908100000`, `20260908110000`, `20260908120000`, dan `20260908121000`
> beserta preflight/postflight dan behavioral rollback-only seluruhnya PASS.
> Fitur Office tetap OFF; fixture runtime nol dan baseline downstream tetap 256
> Delivery/Invoice snapshot, 216 Reservation, 585 Stock Movement, serta 245
> Financial Event. Ini bukan final rehearsal atau production rollout; client
> deploy, smoke, UAT, fresh-clone rehearsal, dan production tetap pending.

> 2026-09-15: Akses profile CLI ke historical rehearsal clone
> `idrufihckscppsyclmsu` sudah terbukti dan repository utama tetap tidak di-link
> ulang. Clone cocok pada ledger, queue, object inventory, Purchase/Stock/Finance,
> serta 51 PO terbuka, tetapi mempunyai 266 Sales Header/657 Sales Detail versus
> production terkini 278/693. Common digest juga berbeda karena sebagian row lama
> berubah setelah restore. Clone tidak dinyatakan identik/final; migration belum
> dimulai. Clone ini hanya boleh menjadi preliminary rehearsal, sedangkan final
> rollout tetap memerlukan bukti terhadap snapshot production terbaru.
> Preliminary rehearsal sudah diizinkan. Koneksi memakai workdir temporary dan
> PAT process-only; repository tetap ter-link ke isolated Development. Guarded
> connection script baru berhenti pada read-only database probe dan belum
> menjalankan migration maupun cutover.

> 2026-09-14: Production discovery Office/Purchase **PASS** dan tetap read-only:
> Finance queue 0, Offline nonterminal 0, base relation 19/19, object baru 0/12,
> serta hanya migration `20260910100000` yang sudah tercatat dari 89 kandidat.
> Delta awal 88 wajib direhearsal pada clone production. Baseline mencakup 267
> Sales Header, 659 Sales Detail, 585 Stock Movement, 245 Financial Event, 56
> Supplier Order, 16 Receipt, 4 Supplier Invoice, dan 2 Supplier Payment. Ada 51
> PO terbuka yang harus diaudit lagi sebelum backfill Receipt `141800`.

> 2026-09-14: Preparation rollout production Office Sales + Purchase diperbarui
> hingga 89 candidate migration (`20260908100000`–`20260914180000`). Delta aktual
> belum diketahui dan wajib berasal dari ledger production read-only. Migration
> terakhir dapat menambah Receipt Draft pada PO terbuka; daftar exact wajib
> direkonsiliasi di clone sebelum rollout. Tidak ada akses/mutation/deploy ke
> production pada tahap ini.

> 2026-09-14: UI Penerimaan Barang Purchase **LOCAL READY** dengan quantity
> awal otomatis sebesar sisa PO dalam UOM yang tepat dan tetap editable.
> Dokumen dapat dipilih sekaligus, diperiksa/diedit per PO dalam popup, lalu
> diposting secara independen: yang berhasil final, yang gagal tetap Draft untuk
> diperbaiki. Endpoint/RPC canonical existing tetap digunakan per Receipt;
> tidak ada schema, backfill, atau perubahan POS Retail. ESLint, TypeScript, dan
> production build 84 halaman PASS; authenticated smoke/UAT masih pending.

> 2026-09-14: Koreksi workflow Purchase **LOCAL READY**. Konfirmasi tetap hanya
> pada RO. Ketika RO dikonfirmasi atau AUTO_PO berjalan, sistem membuat PO
> sekaligus dokumen Receipt per Gudang; Gudang memprosesnya dari menu
> Penerimaan Barang. PO tidak lagi mempunyai tombol untuk memulai Receipt.
> `Buat Bill` tetap berada pada PO dan baru aktif setelah Receipt Posted,
> memakai Faktur Supplier existing. Client lint dan production build 84 halaman
> PASS; migration dan behavioral test sudah PASS pada isolated Development.
> Postflight terakhir, authenticated smoke, dan UAT masih pending.
> Production/staging tidak disentuh. Rollout:
> [`docs/runbooks/PURCHASE_ORDER_GENERATED_RECEIPT_WORKFLOW_ROLLOUT.md`](docs/runbooks/PURCHASE_ORDER_GENERATED_RECEIPT_WORKFLOW_ROLLOUT.md).

> 2026-09-14: Empat fixture AUTO_PO sudah **DATABASE LIVE** hanya pada isolated
> Development `fkywtxucmyjvpwdiqpix`: `PO-20260914-0000000009` sampai
> `PO-20260914-0000000012`. Fixture dibentuk melalui scheduler canonical,
> menghasilkan empat Supplier terpisah, mengembalikan setting Company ke
> `AUTO_RO`, dan belum membuat Receipt/Stock lanjutan/AP/Bill/Payment/Journal.
> Preflight serta postflight PASS; authenticated E2E smoke/UAT masih pending.
> Production/staging tidak disentuh. Panduan:
> [`docs/runbooks/PURCHASE_AUTO_PO_SMOKE_FIXTURE.md`](docs/runbooks/PURCHASE_AUTO_PO_SMOKE_FIXTURE.md).

> 2026-09-14: Purchase RO/PO list parity **LOCAL READY**. Halaman Supplier
> Order sekarang memakai pola daftar Quotation/Sales Order: tab RO dan PO,
> pencarian, filter status/Supplier/tanggal, header tabel yang ringkas, detail
> line, status penerimaan, serta status Bill yang membuka Faktur Supplier
> existing bila user mempunyai akses Finance. Read-model `20260914160000`
> hanya menambahkan proyeksi tenant-scoped Receipt/Bill; tidak membuat modul
> invoice baru dan tidak mengubah RO/PO, Receipt, Return, Stock/FIFO, AP,
> Payment, Journal, scheduler, Sales, atau POS. Lint, TypeScript, dan production
> build 84 halaman PASS. Database isolated Development, authenticated smoke,
> dan UAT masih pending; production/staging tidak disentuh. Rollout:
> [`docs/runbooks/PURCHASE_ORDER_LIST_PARITY_ROLLOUT.md`](docs/runbooks/PURCHASE_ORDER_LIST_PARITY_ROLLOUT.md).

> 2026-09-14: Warehouse non-Transit create/edit validation fix **LOCAL READY**.
> Form dan API kini hanya memproses parent/operation Transit ketika tipe Gudang
> benar-benar `TRANSIT`; Gudang Pusat/Toko/Rusak tidak lagi ditolak oleh field
> Transit kosong. Tidak ada schema, Stock, Purchase, Finance, POS, atau production
> mutation. ESLint dan TypeScript PASS; authenticated retest masih pending.

> 2026-09-14: Paket persiapan rollout Office Sales + Daily Purchase ke production
> sudah tersedia tanpa menjalankan production. Strateginya memakai discovery
> ledger read-only, backup/PITR, clone rehearsal data production, rekonsiliasi
> transaksi/Stock/Finance, rollout DB ber-checkpoint, regression Retail, lalu
> aktivasi pilot per Company. Tidak ada reset atau penghapusan transaksi.
> Panduan: [`docs/runbooks/OFFICE_PURCHASE_PRODUCTION_ROLLOUT_PREPARATION.md`](docs/runbooks/OFFICE_PURCHASE_PRODUCTION_ROLLOUT_PREPARATION.md).

> 2026-09-14: Purchase Step 6/6B migration, midnight-window forward-fix,
> behavior, dan postflight telah dikonfirmasi user seluruhnya PASS pada isolated
> Development. Step 6/6C RO/PO client activation sekarang **DATABASE LIVE +
> USER-CONFIRMED PASS** pada isolated Development:
> read-model exact Product-Supplier/UOM/Gudang, tab RO/PO, konfirmasi RO menjadi
> PO, serta cancel RO/PO memakai runtime canonical. Migration, behavioral test,
> dan postflight 6C telah PASS; authenticated smoke dan UAT masih pending.
> Production/staging tidak disentuh. Rollout:
> [`docs/runbooks/PURCHASE_DAILY_CLIENT_ACTIVATION_ROLLOUT.md`](docs/runbooks/PURCHASE_DAILY_CLIENT_ACTIVATION_ROLLOUT.md).

> 2026-09-14: Purchase Daily Replenishment **Step 1–5/6 DATABASE PASS; Step
> 6/6A LOCAL READY**. Step 5A dan seluruh forward-fix Step 5B telah
> dikonfirmasi user migration, behavior, dan postflight PASS pada isolated
> Development. Paket
> additive memisahkan Goods Receipt PO harian per Gudang, memakai Product COGS
> sebagai biaya provisional yang dapat diedit, dan membuka receipt
> `SUPPLIER_PENDING` melalui clearing serta assignment Supplier per line yang
> append-only. Event pending/reklasifikasi tidak masuk antrian AP lama. Receipt
> manual/POS/Backoffice lama tidak diganti. Step 5B mengoreksi boundary: tujuan
> penerimaan kosong tidak menahan AUTO_PO untuk Product/gudang sumber aktif;
> gudang penerimaan valid tetap wajib saat Receive. Product/gudang sumber
> nonaktif tetap dikecualikan. Forward-fix `20260914112000` menyelaraskan
> constraint Supplier Order agar source boleh terisi saat destination belum
> dipilih, dengan unique guard khusus untuk mencegah line ganda. Supplier
> Bill/Payment/jurnal clearing tetap Step 6. Paket Step 6A berikutnya
> membukukan Receipt supplier-pending ke clearing lebih dahulu, lalu
> menghubungkan assignment Supplier ke AP Provisional dan Antrian Jurnal
> existing tanpa membuat Bill/Payment baru. Production dan staging tidak
> disentuh. Rollout:
> [`docs/runbooks/PURCHASE_DAILY_MULTIWAREHOUSE_RECEIPT_ROLLOUT.md`](docs/runbooks/PURCHASE_DAILY_MULTIWAREHOUSE_RECEIPT_ROLLOUT.md).
> [`docs/runbooks/PURCHASE_AUTO_PO_RECEIPT_WAREHOUSE_BOUNDARY_FIX.md`](docs/runbooks/PURCHASE_AUTO_PO_RECEIPT_WAREHOUSE_BOUNDARY_FIX.md).
> [`docs/runbooks/PURCHASE_SUPPLIER_ASSIGNMENT_AP_BRIDGE_ROLLOUT.md`](docs/runbooks/PURCHASE_SUPPLIER_ASSIGNMENT_AP_BRIDGE_ROLLOUT.md).

> 2026-09-13: Purchase Daily Replenishment **Step 4/6 DATABASE LIVE +
> BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated Development. Step 4
> menambah generator AUTO_PO setelah cutoff: line siap
> langsung menjadi PO confirmed per Supplier/`SUPPLIER_PENDING`, sementara line
> tanpa Gudang penerimaan atau blocker canonical lain ditahan tanpa menghentikan
> line siap. Receipt, Stock/FIFO/AP, Supplier resolution, scheduler/UI/UAT belum
> aktif. Production/staging tidak disentuh. Rollout:
> [`docs/runbooks/PURCHASE_DAILY_AUTO_PO_RUNTIME_ROLLOUT.md`](docs/runbooks/PURCHASE_DAILY_AUTO_PO_RUNTIME_ROLLOUT.md).

> 2026-09-13: Finance process-aware navigation is **LOCAL READY**. Company mode
> Office hides `Verifikasi Pembayaran POS`, `Setor Kas`, and `Selisih Setoran`
> only when no unresolved Retail work exists; Retail mode keeps all controls.
> `Posting Queue` is relabeled `Antrian Jurnal` and remains available because it
> processes cross-module Finance events. The policy fails open for visibility
> (legacy controls remain shown) if canonical mode/count reads are unavailable,
> so unresolved work cannot be stranded. This is client/server read-model only:
> no migration, Finance mutation, POS flow, production, or staging change.
> Targeted lint and production build with 83 pages PASS; authenticated UI smoke
> and UAT remain pending.

> 2026-09-13: Draft Invoice direct-edit and SO table-width correction are
> **LOCAL READY**. `Invoice Penjualan` exposes Edit only for authorized
> Backoffice Drafts and reuses the existing versioned/audited Invoice saver;
> posted/final documents remain immutable. The SO table now fills its panel.
> This is client-only: no database, Stock, Payment, Finance, or production/
> staging mutation. Authenticated smoke/UAT and client deployment remain
> pending.

> 2026-09-12: Backoffice SO Invoice status is **LOCAL READY**. The SO list now
> separates Delivery status from canonical Invoice status, supports Invoice
> filtering, and reuses the existing Invoice editor/detail/list for direct
> navigation. Migration `20260912140000` is read-model only; Database rollout,
> behavior/postflight, authenticated smoke, and UAT remain pending on isolated
> Development. Production/staging were not touched. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_ORDER_INVOICE_STATUS_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_ORDER_INVOICE_STATUS_ROLLOUT.md).

> 2026-09-12: Backoffice WALK-IN Invoice payment forward-fix `20260912139000`
> **LOCAL READY**. Audit membuktikan SO/Invoice Backoffice mengizinkan Customer
> sistem `WALK-IN`, sedangkan saver Penerimaan Customer menolaknya sebelum
> membaca allocation Invoice. Fix dibatasi pada receipt yang seluruh allocation-
> nya merupakan Backoffice Invoice; Retail, uang tanpa allocation, Customer
> Balance, Stock, DO/SJ dan histori Finance tidak dilonggarkan. UI payment juga
> tidak lagi melempar expected server error ke Next.js runtime overlay. Manual
> database gate dan authenticated smoke masih pending; production/staging tidak
> disentuh. Rollout: [`docs/runbooks/BACKOFFICE_SALES_SYSTEM_CUSTOMER_PAYMENT_FIX.md`](docs/runbooks/BACKOFFICE_SALES_SYSTEM_CUSTOMER_PAYMENT_FIX.md).

> 2026-09-12: Backoffice Sales **Step 6/6.1 authenticated read smoke LOCAL
> READY**. Script memakai user Development dan Bearer token nyata untuk membaca
> Company context, SO, DO/SJ, Invoice, Delivered Not Invoiced, serta Data
> Exchange; production/staging ditolak dan tidak ada mutation. PowerShell parse,
> unauthenticated HTTP 401 boundary, targeted lint, dan full build 83 halaman
> PASS; environment guard juga PASS tepat ke `fkywtxucmyjvpwdiqpix`. Eksekusi
> login smoke oleh user masih pending.
>
> 2026-09-12: Backoffice Sales **Step 5/6.3 Delivered Not Invoiced DATABASE
> LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated Development.
> Report Finance memakai posisi Customer accepted dikurangi Invoice
> Posted per komponen SO pada tanggal As-of; Draft tetap termasuk dan Payment tidak
> memengaruhi DNI. Regular, accepted overage, dan ongkir tetap terpisah. Targeted lint
> dan production build PASS; authenticated smoke/UAT masih pending.
> Production/staging tidak disentuh. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_DELIVERED_NOT_INVOICED_REPORT_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DELIVERED_NOT_INVOICED_REPORT_ROLLOUT.md).

> 2026-09-12: Accepted-overage ledger split **DATABASE + BEHAVIOR/POSTFLIGHT
> USER-CONFIRMED PASS**. Audit call chain
> membuktikan resolver C3 menambahkan satu overage ke ledger SO regular dan
> ledger discrepancy sekaligus, sementara Invoice menjumlahkan keduanya sebagai
> source terpisah. Forward-fix `137000` memisahkan kedua ledger dan hanya
> merekonsiliasi data legacy yang terbukti aman; state ambigu menjadi blocker.
> Authenticated smoke/UAT masih pending. Production/staging tidak disentuh.
> Rollout: [`docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_LEDGER_SPLIT_FIX.md`](docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_LEDGER_SPLIT_FIX.md).

> 2026-09-12: Backoffice Sales **Step 5/6.2 DATABASE + BEHAVIOR/POSTFLIGHT
> USER-CONFIRMED PASS**. Event `STOCK_LOSS` dari shortage `LOST`/`DAMAGED`
> disiapkan masuk controlled Finance Posting Queue existing dengan Journal
> Dr Beban Selisih Stok/Cr Persediaan Transit. Stock/FIFO tidak ditulis ulang.
> Paket juga memprovisi approved rule `STOCK_LOSS` yang memang belum disediakan
> migration chain; exact account mapping hanya dipulihkan bila hilang dari satu
> fallback/system account canonical tanpa menimpa custom mapping.
> Database gate telah PASS pada isolated Development; authenticated smoke/UAT
> masih pending dan production/staging tidak disentuh. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_STOCK_LOSS_FINANCE_POSTING_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_STOCK_LOSS_FINANCE_POSTING_ROLLOUT.md).
> Base `135000` kemudian mencapai behavioral tetapi membuka konflik schema:
> discrepancy loss memakai enum `ADJUSTMENT` yang dicadangkan untuk dokumen
> Penyesuaian Stok. Forward-fix additive `136000` menggantinya dengan identity
> `BACKOFFICE_DISCREPANCY_LOSS`; migration, behavior, dan postflight telah
> user-konfirmasi PASS pada isolated Development.

> 2026-09-12: Backoffice Sales **Step 5/6.1 ACCEPTED-OVERAGE FINANCE POSTING
> DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated
> Development. Event COGS kelebihan yang sebelumnya HOLD kini didukung oleh
> controlled Posting Queue existing dengan Journal Dr COGS/Cr Inventory Transit.
> Authenticated smoke/UAT masih pending; production/staging tidak disentuh.

> 2026-09-12: Backoffice Sales **Step 4/6.5C4 DISCREPANCY CLIENT ACTIVATION
> DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS**. Approval komersial accepted overage ditempatkan pada detail SO;
> input dan resolution fisik terhadap DO ditempatkan pada detail Surat Jalan.
> Projection Gudang menyembunyikan harga/diskon/pajak. Database gate dan
> behavioral telah user-konfirmasi PASS; authenticated smoke/UAT masih pending.
> Production/staging tidak disentuh.

> 2026-09-12: Backoffice Sales **Step 4/6.5C3 DATABASE LIVE + BEHAVIOR/
> POSTFLIGHT USER-CONFIRMED PASS** pada isolated Development. Forward-fix
> `20260912132000` menyediakan master `BACKOFFICE_ACCEPTED_OVERAGE_COGS`,
> mapping COGS/Inventory dan versioned rule per Company, lalu mengarahkan resolver
> ke kontrak tersebut. Behavior/postflight telah user-konfirmasi PASS; event tetap HOLD.
> production/staging tidak disentuh. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_OVERAGE_WRONG_ITEM_RESOLUTION_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_OVERAGE_WRONG_ITEM_RESOLUTION_ROLLOUT.md).

> 2026-09-12: Backoffice Sales **Step 4/6.5C2C Accepted-Overage Invoice Client
> DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated
> Development. Read-model, API, form/edit/detail, Print dan PDF Invoice existing
> kini mengenali line `Kelebihan barang`; hanya Qty dapat diedit, sedangkan
> harga/diskon/pajak tetap dari approval Sales. Authenticated smoke/UAT masih
> pending; production/staging tidak disentuh. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_INVOICE_CLIENT_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_INVOICE_CLIENT_ROLLOUT.md).
>
> Step 4/6.5C2B Accepted-Overage Invoice Runtime **DATABASE LIVE +
> BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated Development. Runtime membuka partial Draft/Edit/Cancel/Post untuk
> line `Kelebihan barang`: diskon proporsional, pajak per Invoice dari snapshot
> approval, dan sisa pembulatan pada Invoice terakhir. Rollout:
> [`docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_INVOICE_RUNTIME_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_ACCEPTED_OVERAGE_INVOICE_RUNTIME_ROLLOUT.md).
>
> Step 4/6.5C2A foundation sebelumnya **DATABASE LIVE + BEHAVIOR/POSTFLIGHT
> USER-CONFIRMED PASS** pada isolated Development. Authenticated smoke/UAT belum
> dilakukan.

> 2026-09-12: Backoffice Sales **Step 4/6.5C1 Reconstruction Transfer DATABASE
> LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated Development.
> Helper private merekonstruksi Stock actual Overage/Wrong Item dari
> source ke Transit dengan exact FIFO dan authority minus Warehouse. Belum ada
> public resolver/status/Finance effect; authenticated UI smoke/UAT belum
> dilakukan. Rollout isolated Development:
> [`docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_RECONSTRUCTION_TRANSFER_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_RECONSTRUCTION_TRANSFER_ROLLOUT.md).

> 2026-09-12: Backoffice Sales **Step 4/6.5B Shortage Resolution Runtime LOCAL
> READY**. `BACKORDER`/`ACCEPT_SHORT` memiliki resolver Gudang atomik; return
> memakai exact Transit FIFO, lost/damaged membuat Finance HOLD, dan Backorder
> membuat DO/SJ child pada SO yang sama. Tanggal boleh kosong (otomatis tanggal
> Company) dan dapat diedit. Rollout isolated Development:
> [`docs/runbooks/BACKOFFICE_SALES_SHORTAGE_RESOLUTION_RUNTIME_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_SHORTAGE_RESOLUTION_RUNTIME_ROLLOUT.md).

> 2026-09-12: Backoffice Sales **Step 4/6.5A Warehouse Resolution Foundation
> LOCAL READY**. Accepted overage kini dirancang tetap menunggu reconciliation
> Gudang setelah approval Sales; exact Stock Movement/FIFO/Backorder lineage dan
> batas approved overage disiapkan tanpa mengaktifkan resolver atau efek fisik.
> Manual rollout hanya untuk isolated Development `fkywtxucmyjvpwdiqpix`:
> [`docs/runbooks/BACKOFFICE_SALES_WAREHOUSE_RESOLUTION_FOUNDATION_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_WAREHOUSE_RESOLUTION_FOUNDATION_ROLLOUT.md).

> 2026-09-12: Backoffice Sales **Step 4/6.4 Overage Commercial Approval LOCAL
> READY; DATABASE/BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** pada isolated
> Development. Accepted overage memakai harga, proporsi diskon, dan pajak SO asli
> sebagai default; Sales Admin dapat menyesuaikannya sebelum approval. Approval
> belum mengubah Stock/FIFO/Reservation/DO/Invoice/Finance. Manual rollout hanya
> untuk isolated Development `fkywtxucmyjvpwdiqpix` melalui
> [`docs/runbooks/BACKOFFICE_SALES_OVERAGE_COMMERCIAL_APPROVAL_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_OVERAGE_COMMERCIAL_APPROVAL_ROLLOUT.md).

> 2026-09-12: Backoffice Sales **Step 4/6.3 Mixed Customer Receipt DATABASE
> LIVE + USER-CONFIRMED PASS** pada isolated Development. Runtime mengonsumsi hanya qty accepted dari Transit FIFO,
> langsung membuka Qty To Invoice, dan mempertahankan shortage/wrong-item dalam
> discrepancy terbuka serta SO/DO `IN_TRANSIT`. Regular Invoice dapat dibuat
> dari qty accepted; clean receipt lama tetap kompatibel. Resolution Gudang,
> Backorder DO/SJ, write-off, dan UI belum dibuka. Manual gate:
> [`docs/runbooks/BACKOFFICE_SALES_MIXED_CUSTOMER_RECEIPT_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_MIXED_CUSTOMER_RECEIPT_ROLLOUT.md).

> 2026-09-11: Backoffice Sales **Step 4/6.2 Physical-State Contract DATABASE
> LIVE + USER-CONFIRMED PASS** pada isolated Development. Forward migration
> setelah Step 4/6.1 memisahkan keputusan komersial
> shortage (`BACKORDER`/`ACCEPT_SHORT`) dari posisi fisik
> (`NOT_LOADED`/`RETURNING`/`LOST`/`DAMAGED`) dan menyimpan Product/UOM/qty
> aktual Wrong Item secara independen. Belum ada mutation mixed receipt,
> Stock/FIFO, Backorder, Finance, UI, production, atau staging. Manual gate:
> [`docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_PHYSICAL_STATE_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_PHYSICAL_STATE_ROLLOUT.md).

> 2026-09-11: Backoffice Sales **Step 4/6.1 Discrepancy Contract DATABASE LIVE
> + USER-CONFIRMED PASS** pada isolated Development. Foundation memisahkan qty diterima dari
> short/overage/wrong/lost/damaged, mengunci `ACCEPT_OVERAGE` ke approval Sales,
> resolution operasional ke Gudang, serta exact operation/immutable audit.
> Qty accepted dirancang langsung menjadi Qty To Invoice walaupun Backorder
> terbuka. RPC clean receipt, POS Retail, Stock/FIFO, Invoice, Payment, Finance,
> production, dan staging belum diubah oleh paket ini. Manual gate:
> [`docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_CONTRACT_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DISCREPANCY_CONTRACT_ROLLOUT.md).

> 2026-09-11: **Backoffice payment collection Step 1/3, Step 2/3, dan Step 3/3
> DATABASE LIVE + USER-CONFIRMED PASS** pada isolated Development.
> Step 3 menyatukan Invoice Retail dan Backoffice ke Penerimaan Customer, AR
> Aging, Customer Statement, serta export existing dengan identitas source
> eksplisit dan aging per installment. Step 2 menambah
> status Belum Dibayar/Dibayar Sebagian/Lunas, riwayat receipt, serta tindakan
> `Catat Pembayaran` pada detail Invoice existing. Tindakan ini atomik dan
> idempotent memakai permission, Customer Receipt, dan jurnal Finance canonical;
> menu/template Invoice, POS, Stock, DO, dan FIFO tidak diganti. Manual gate
> aktif: [`docs/runbooks/BACKOFFICE_SALES_AR_REPORTING_INTEGRATION_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_AR_REPORTING_INTEGRATION_ROLLOUT.md).

> 2026-09-11: **Document template/UI consolidation LOCAL READY**. Backoffice
> Sales tidak lagi membuat tab daftar Invoice atau renderer dokumen sendiri.
> Invoice Retail dan Backoffice dibaca dari menu existing `Invoice Penjualan`;
> tombol `Buat Invoice` pada SO Selesai tetap menuju form Draft. Print/PDF
> Invoice dan Surat Jalan Backoffice memakai renderer serta Company Profile/
> Branding existing, termasuk logo, stempel, rekening, dan template tanda
> tangan. Retail tetap kompatibel (kolom fulfillment hanya muncul jika payload
> Backoffice memilikinya). ESLint dan Next.js build PASS. Tidak ada migration,
> database write, production, staging, atau deployment pada koreksi ini;
> authenticated visual/UAT pada isolated Development masih pending.

> 2026-09-11: **Backoffice Invoice client activation DATABASE LIVE ON ISOLATED
> DEVELOPMENT; BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS**. SO Office
> berstatus Selesai kini mempunyai jalur `Buat Invoice` menuju Draft editable,
> partial Qty berdasarkan penerimaan Customer, explicit due date, ongkir,
> penerbitan berizin Finance, daftar Invoice per SO, serta Print/PDF hanya untuk
> Invoice final. Next.js lint/build PASS dan migration `20260911150000` sudah
> mencapai database Development. Behavioral pertama berhenti pada fixture yang
> keliru mensyaratkan Product tanpa open shortage; audit read-only membuktikan
> satu kandidat canonical tertutup oleh dua open allocation Backoffice. Test
> memakai FIFO top-up rollback-only; user kemudian mengonfirmasi behavioral dan
> postflight seluruhnya PASS. Launcher guard dan HTTP lokal PASS, serta endpoint
> Invoice anonim ditolak `401`. Authenticated smoke dan UAT masih menunggu.
> Production/staging/POS tidak disentuh.

> 2026-09-11: forward-fix Backoffice shortage Dispatch berstatus **LOCAL READY;
> MANUAL ISOLATED-DEVELOPMENT SQL GATE PENDING**. Runtime baru hanya mengizinkan
> saldo sumber negatif ketika DO Backoffice memiliki lineage sah dan Warehouse
> `allow_negative_stock=true`; ordinary Transfer dan POS tetap pada kontrak
> masing-masing. Transit FIFO provisional mendukung Customer Receipt sebelum
> replenishment, lalu incoming batch merekonsiliasi biaya. Tidak ada database,
> production, staging, atau deployment yang dijalankan agent. Urutan ada di
> `docs/runbooks/BACKOFFICE_SALES_NEGATIVE_DISPATCH_ROLLOUT.md`.

> 2026-09-11: Cutover **Step 4F/6 Platform control UI LOCAL READY**. Pengaturan
> Modul > Sales kini memiliki panel Super Admin untuk membaca mode Company,
> preview dokumen, membuat/refresh/membatalkan plan, serta menjalankan Apply
> Step 4E dengan version dan idempotency identity. Browser tidak mendapat akses
> tabel cutover; mutation tetap melalui RPC canonical. Lint dan production
> build PASS. Authenticated isolated-Development smoke masih pending;
> production/staging/deployment tidak disentuh.

> 2026-09-11: Cutover **Step 4E/6 atomic Apply LOCAL READY**. Paket baru
> menyediakan Apply manual Super Admin yang merevalidasi live preview dan
> mengonversi item eligible, mempertahankan item blocked/grandfathered, menulis
> lineage/mode history, serta mengganti Company mode dalam satu transaksi.
> Root Retail/Backoffice dan Offline baru mengikuti `active_mode`; source lama
> tetap diselesaikan melalui runtime asal. User mengonfirmasi behavioral
> terkoreksi PASS pada isolated Development. Konfirmasi postflight final serta
> authenticated smoke/UAT masih pending; production dan staging tidak disentuh.

> 2026-09-11: Cutover **Step 4D/6 Retail real-session adoption DATABASE LIVE +
> BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.
> Draft `BACKOFFICE_CUTOVER` hanya dapat diambil sesi POS OPEN dengan
> Company–Store–Warehouse sama. Membuka Draft dan menyimpan ulang payment intent
> tidak menjalankan repricing; edit isi transaksi kembali memakai resolver
> Retail canonical. Exact retry, stale version, immutable operation history,
> lock/takeover, dan scope guard ditegakkan server-side. PWA lint/build PASS.
> Public Apply masih baru tersedia sebagai paket Step 4E local-ready;
> production/staging, deployment, smoke, dan UAT belum disentuh.

> 2026-09-11: Cutover **Step 4C/6 Backoffice -> Retail DATABASE LIVE +
> FORWARD-FIX/BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**. Semua source
> Backoffice eligible menjadi Retail Draft dan wajib dikonfirmasi ulang;
> confirmed future TEMPO menjadi Scheduled Draft. Source Reservation/initial DO
> yang benar-benar untouched dilepas/dibatalkan atomik. Future non-TEMPO,
> multi-installment, Invoice/final effect, serta fulfillment noncanonical tetap
> fail-closed. Belum ada public Apply, mode switch, client deployment, atau
> sentuhan ke production/staging.
> Perbedaan lifecycle tetap disengaja: Backoffice membuat Invoice dari Qty
> customer receipt, sedangkan hasil cutover yang dikonfirmasi ulang akan
> mengikuti proses Invoice Retail lama. Converter Step 4C sendiri tidak membuat
> Invoice, SJ, Reservation, Stock/FIFO, Payment, maupun Finance effect.
> Behavioral awal membuktikan cabang confirmed-source kehilangan parent
> operation untuk FK audit. Base migration tidak diedit; additive
> `20260911111000` memasukkan CANCEL operation memakai identity cutover yang
> sama sebelum audit. User kemudian mengonfirmasi migration forward-fix,
> behavioral rollback, base postflight, dan forward-fix postflight seluruhnya
> PASS. Client attachment, public Apply, mode switch, authenticated smoke/UAT,
> dan production/staging tetap belum disentuh.

> 2026-09-11: Cutover **Step 4B/6 Retail -> Backoffice converter kernel DATABASE
> LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**. Kernel private memetakan
> Retail lifecycle `DRAFT_INPUT` menjadi Draft Quotation, sedangkan lifecycle
> `CONFIRMED/RESERVED` (dan row legacy yang benar-benar ber-runtime
> `SCHEDULED`) menjadi confirmed SO dengan Reservation dan initial DO melalui
> runtime canonical. Future Scheduled timing canonical tetap `DRAFT_INPUT` dan
> menjadi Draft Quotation. Source baru ditutup dalam transaksi
> yang sama setelah target lengkap; operation retry mengembalikan target yang
> sama. Commercial/date/tax/ongkir dipertahankan, sedangkan Stock Movement,
> FIFO/COGS, Payment baru, Finance, public Apply, dan Company mode switch tetap
> nol/tertutup. Store/Customer/gudang/Product-UOM/Product/UOM yang sudah tidak
> aktif ditolak eksplisit sesuai boundary canonical, bukan dikonversi diam-diam.
> Behavioral menggunakan fixture canonical buatan sendiri dan
> rollback penuh. Attempt pertama membuktikan test salah menyamakan Scheduled
> timing dengan runtime lifecycle; migration tidak diubah, test dikoreksi dan
> rerun beserta postflight dikonfirmasi PASS oleh user.
> Production/staging tidak disentuh.

> 2026-09-11: Cutover **Step 4A/6 unified Warehouse negative-stock authority
> DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.
> Transaksi baru POS dan Backoffice hanya mengikuti
> `warehouses.allow_negative_stock`; feature/terminal/toko, permission user,
> limit, dan alasan tidak lagi menjadi gate. Evidence legacy dipertahankan,
> sedangkan Reservation, direct POS, Dispatch/FIFO, dan cutover memakai evidence
> versi Gudang. Attempt pertama rollback pada guard karena target core lokal
> keliru; paket sekarang menargetkan core Reservation yang aktual dan menjaga
> wrapper Invoice/SJ/procurement/payment tetap utuh. SQL baru hanya file lokal;
> patch Dispatch memakai anchor semantik karena runtime pernah direkonstruksi
> oleh forward-fix. Dua attempt behavioral membuka dependency fixture yang
> salah: mula-mula sesi, kemudian Draft operasional. Fixture terbaru membuat
> actor, OPEN session, Draft + Stock Requirement melalui RPC POS canonical,
> payment intent, dan shortage sendiri dalam transaksi rollback-only tanpa
> melemahkan guard POS. User mengonfirmasi behavioral dan postflight PASS;
> authenticated smoke/UAT masih pending. Production/staging tidak disentuh.
> Rerun berikutnya mencapai confirmation dan membuka gap existing antara
> dokumen ODR `PICKUP` dan constraint `sj_required`; behavioral authority kini
> memakai jalur `DELIVERY` canonical. Constraint/flow Pickup belum diubah dan
> tetap menjadi forward-fix terpisah.

> 2026-09-10: Step 1E-B2/6 cutover Payment Term boundary **DATABASE LIVE +
> POSTFLIGHT/BEHAVIOR USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.
> Berdasarkan schema/runtime aktual, Retail hanya memiliki satu `due_date`,
> sedangkan Backoffice dapat menghasilkan beberapa schedule piutang. Preview v2
> mempertahankan satu tanggal absolut untuk candidate tempo dan memblokir
> Office-to-Retail yang memiliki multi-installment agar tetap selesai di proses
> sumber. Signature classifier lama tetap kompatibel; belum ada converter,
> Apply, perubahan mode, atau mutation Sales/Stock/Payment/Finance. Manual
> Authenticated smoke masih pending; production/staging tidak disentuh.

> 2026-09-10: Backoffice delivery-fee parity `20260910150000` sudah
> **DATABASE LIVE ON ISOLATED DEVELOPMENT**, tetapi behavioral test menemukan
> wrapper Draft Invoice mencoba mengubah audit yang immutable. Forward-fix
> additive `20260910151000` kini **DATABASE LIVE + POSTFLIGHT/BEHAVIOR
> USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**: ongkir ditetapkan sebelum core
> canonical menulis response/operation/audit dan input transaction-local selalu
> dibersihkan setelah call. Migration applied `150000`, trigger immutable,
> histori, POS Retail, Stock, Reservation, DO, FIFO/COGS, Payment, serta Finance
> existing tidak diubah. Production/staging tidak disentuh; authenticated smoke
> dan UAT masih menunggu.

> 2026-09-10: Step 1D/6 cutover Retail identity **DATABASE LIVE +
> BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.
> Pending Revision Retail kini diklasifikasikan `BLOCKED`/grandfathered, bukan
> dikonversi sebagai pasangan. Target Office-to-Retail memakai origin sistem
> `BACKOFFICE_CUTOVER` dengan `session_id`, `pos_id`, dan
> `created_session_id` kosong secara bersyarat; origin POS normal tetap wajib
> membawa seluruh identitas tersebut. Paket preflight/migration/behavior/
> postflight sudah lulus di isolated Development. Apply, conversion, mode
> switch, client deployment, smoke, dan UAT belum dilakukan;
> production/staging tidak disentuh.

> 2026-09-10: Backoffice Sales Order activity log UI **LOCAL READY**.
> Revisi tetap mengubah SO bernomor sama seperti pola Odoo; immutable activity
> existing `CREATE/UPDATE/SEND/CONFIRM/REVISE/CANCEL` kini ditampilkan sebagai
> timeline “Log aktivitas” terpisah di bawah dokumen, bukan dicampur ke tab
> Informasi Lainnya. Tidak ada schema/RPC, Order lifecycle, Reservation, DO,
> Stock, Invoice, Payment, atau Finance yang diubah. Scoped ESLint dan Next.js
> production build PASS; authenticated visual smoke masih manual.

> 2026-09-10: Step 1D cutover Apply boundary sudah diputuskan, tetapi converter
> belum ditulis. Item `BLOCKED` tetap grandfathered dan tidak menggagalkan
> switch; Apply hanya manual oleh Platform Super Admin pada/setelah
> `effective_at`, serta seluruh revalidasi/conversion/mode switch wajib atomik.
> Audit schema menemukan dua mapping yang masih memerlukan keputusan eksplisit:
> pending Revision Retail dua-dokumen ke revisi Backoffice in-place, dan SO
> Backoffice tanpa Cashier Session/POS Terminal ke aggregate Retail yang
> mewajibkannya. Production/staging tidak disentuh.

> 2026-09-10: cutover plan refresh/cancel Step 1C/6
> `20260910120000` **DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS ON ISOLATED
> DEVELOPMENT**.
> Refresh mengganti hanya candidate snapshot dengan source version terbaru;
> target mode, effective time, dan reason tetap terkunci. Cancel menyimpan plan,
> item, dan audit sebagai histori. Optimistic plan version, Company lock, exact
> retry, serta Super Admin boundary aktif. Apply/switch dan seluruh efek
> operasional tetap tertutup. User mengonfirmasi migration, postflight, dan
> behavioral rollback seluruhnya PASS; production/staging tidak disentuh.

> 2026-09-10: persistent Retail/Backoffice cutover preview plan
> `20260910110000` **DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS ON ISOLATED
> DEVELOPMENT**.
> Gate Step 1B/6 menyimpan actual-data preview sebagai plan `PREVIEWED`,
> mengunci Company settings version dan source document version per item,
> memakai Company advisory lock serta exact operation-id idempotency. Write
> hanya mengenai plan/item/audit; apply, conversion, Company switch, dan seluruh
> Order/Reservation/PO/Stock/Invoice/Payment/Finance effect tetap tertutup.
> User mengonfirmasi sembilan postflight check PASS, runtime inventory nol,
> dan behavioral rollback PASS.
> Production/staging tidak disentuh.

> 2026-09-10: production POS Scheduled Draft resume forward-fix
> `20260910100000` **PRODUCTION DATABASE LIVE; BEHAVIOR/POSTFLIGHT PASS;
> AUTHENTICATED SMOKE PENDING**.
> Audit call chain membuktikan `Lanjutkan` melakukan save/reprice dan future
> Scheduled TEMPO Draft salah melewati validator effective-date aktif. Fix
> hanya merutekan `SCHEDULED + TEMPO + PRESERVE` ke validator Scheduled,
> mempertahankan tanggal rencana, lock/version chain, dan early-post guard.
> Tidak ada backfill atau perubahan Stock, Reservation, SJ/Invoice, Payment,
> FIFO, maupun Finance. User menjalankan preflight SELECT-only dan seluruh guard
> PASS/expected SETUP, migration, behavioral, dan postflight berhasil menurut
> hasil manual user. Authenticated POS smoke masih menunggu; tidak perlu client
> deploy karena perubahan berada pada RPC database.

> 2026-09-10: actual-data Retail/Backoffice cutover preview
> `20260909163000` **DATABASE LIVE + MANUAL POSTFLIGHT/BEHAVIOR PASS** pada
> isolated Development.
> RPC Super Admin ini hanya membaca dokumen nyata dan mengklasifikasikan
> `CONVERT`, `BLOCKED`, atau `KEEP_SOURCE` dari Revision pair, Reservation,
> Procurement, Dispatch, Stock, Invoice, Payment, Finance, Offline dan
> entitlement. Tidak membuat plan, tidak mengganti mode, dan tidak memutasi
> dokumen operasional. Target hanya isolated Development; development ini
> sudah menjadi dependency Step 1B persistent preview plan.

> 2026-09-10: selective Retail/Backoffice cutover foundation
> `20260909162000` **DATABASE LIVE + MANUAL POSTFLIGHT/BEHAVIOR PASS** pada
> isolated Development. Gate ini menambah default-Retail Company
> setting, immutable mode history, cutover plan/item/audit, serta pure
> eligible/blocker classifier. Tidak ada Company switch, conversion runtime,
> atau perubahan Order, Reservation, PO, Stock/FIFO, Invoice, Payment dan
> Finance. Manual rollout hanya untuk isolated Development; production/staging
> tidak disentuh.

> 2026-09-10: audit awal cutover Retail ke Backoffice menemukan feature
> Backoffice masih **additive**, bukan switch eksklusif; runtime POS belum
> otomatis menolak creation baru ketika feature aktif. Reservation
> Retail/Backoffice sudah terpisah dan Stock Overview menjumlah keduanya.
> Foundation setting/history dan read-only open-work preview kini tersedia,
> tetapi effective creation gate, conversion/apply, legacy source routing, dan
> concurrency/idempotency switch runtime masih belum dibuka.
> Cutover tidak akan menunggu seluruh POS Draft nol: Scheduled Order dan Draft
> Revision yang sudah mempunyai identity server sebelum effective time tetap
> diselesaikan sebagai pipeline Retail; hanya root Sale Retail baru yang ditutup.
> Tidak ada runtime/database/deployment yang diubah; production/staging tidak
> disentuh.

> 2026-09-10: Backoffice Regular/DP Invoice posting runtime
> `20260909161000` **DATABASE LIVE + MANUAL POSTFLIGHT/BEHAVIOR PASS** pada
> isolated Development. Gate ini menambah posting atomik, nomor
> Invoice canonical bersama POS, exact retry, finalisasi quantity hold, aplikasi
> DP auto/editable, dan Journal AR/Advance/Revenue/Output Tax per exact tax
> account. Finance role/custom override ditegakkan khusus RPC ini tanpa
> mengaktifkan permission global yang masih SHADOW. Belum dijalankan di
> database oleh agent; production/staging tidak disentuh.
> Percobaan rollout Development pertama berhenti atomik pada guard lifecycle
> posting rule. File lokal sudah dikoreksi mengikuti lifecycle canonical
> `DRAFT -> lines -> CREATE audit -> APPROVED -> APPROVE audit`; preflight dan
> postflight juga diperketat. Rerun manual terbaru dikonfirmasi PASS oleh user.

> 2026-09-10: Backoffice Regular/DP Invoice Finance mapping
> `20260909160000` **DATABASE LIVE + MANUAL POSTFLIGHT/BEHAVIOR PASS** pada
> isolated Development. Gate ini hanya menambah dua system event,
> Transaction Category, account mapping canonical, dan approved posting
> definition; belum ada posting Invoice/Event/Journal. Rollout manual hanya
> untuk isolated Development; production/staging tidak disentuh.

> 2026-09-10: Invoice multi-tax breakdown `20260909159000` **DATABASE LIVE +
> MANUAL POSTFLIGHT/BEHAVIOR PASS** pada isolated Development.
> DP tetap satu total di UI tetapi backend menyimpan alokasi proporsional per
> tax rule/version/account. Ini fondasi tanpa posting Event/Journal; rollout
> Rollout tidak menyentuh production/staging.

> 2026-09-10: Draft Regular/DP Invoice runtime `20260909157000` dan digest
> forward-fix `20260909158000` dilaporkan **DATABASE LIVE + MANUAL TEST PASS**
> pada isolated Development. Gate berikutnya baru preflight read-only Finance
> posting; AR/Revenue/Tax posting belum dibuat. Production/staging tidak disentuh.

> Behavioral pertama menemukan pgcrypto `digest` belum schema-qualified.
> Forward-fix `20260909158000` **LOCAL READY** memakai kontrak canonical
> `extensions.digest(bytea,text)` tanpa mengubah flow/data; behavioral `157000`
> wajib diulang setelah rollout Development.

> 2026-09-10: Odoo-style Backoffice Invoice accounting foundation
> `20260909156000` **DATABASE LIVE/PASS ON ISOLATED DEVELOPMENT**. Gate zero-backfill
> menyiapkan Payment Terms, Pro-Forma non-akuntansi, Regular/DP Invoice,
> quantity hold, DP deduction, installment schedule, dan audit. Belum ada
> RPC/UI, Payment, Event/Journal, Revenue/Tax/AR, Stock/FIFO, atau perubahan POS.
> Target rollout hanya isolated Development; production/staging tidak disentuh.

> Foundation `20260909156000` kemudian dikonfirmasi user migration/postflight/
> behavior PASS pada isolated Development. Gate aktif berikutnya adalah
> SELECT-only Draft Invoice runtime preflight; runtime dan Finance posting belum
> dibuka.

> 2026-09-10: Backoffice Customer receipt Finance posting `20260909155000`
> **DATABASE LIVE ON ISOLATED DEVELOPMENT; POSTFLIGHT/BEHAVIOR PASS**. Event
> receipt `HOLD` diproses oleh
> queue/dispatcher canonical menjadi Dr COGS dan Cr Inventory Asset berdasarkan
> actual Transit FIFO, dengan tanggal penerimaan sebagai original event date dan
> period fallback canonical. Tidak membuat Invoice, Revenue/AR, Payment, atau
> mutasi Stock baru. Target hanya isolated Development.

> 2026-09-09: clean Backoffice Customer receipt runtime `20260909154000`
> **DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS**.
> DO `IN_TRANSIT` penuh dapat diterima
> dengan tanggal Company yang auto-fill tetapi editable; runtime mengonsumsi
> hanya batch FIFO Transit milik DO, menyelesaikan Reservation/SO, membuka Qty To
> Invoice, dan membuat Event COGS `HOLD`. Tidak membuat Invoice, Revenue/AR,
> Payment, atau Journal sinkron. Target hanya isolated Development.

> 2026-09-09: Backoffice Customer receipt Finance mapping `20260909153000`
> **DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS**.
> Mapping hanya debit COGS dan credit
> Inventory Asset dari akun canonical Company; tidak membuat receipt, Stock,
> Event, Journal, Invoice, Revenue/AR, atau Payment. Target hanya isolated
> Development; production/staging tidak disentuh.

> 2026-09-09: Backoffice Customer receipt / Qty To Invoice foundation
> `20260909152000` **DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL
> POSTFLIGHT/BEHAVIOR PASS**. Gate additive ini
> menyiapkan immutable receipt/FIFO lineage dan ledger Accepted, Return sebelum
> Invoice, Draft allocation, Invoiced, Net Delivered, serta Qty To Invoice.
> Belum ada RPC/UI penerimaan Customer, pengurangan stok Transit, COGS/Event/
> Journal, Invoice, Payment, atau backfill. Target rollout hanya isolated
> Development `fkywtxucmyjvpwdiqpix`; production/staging tidak disentuh.

> 2026-09-09: Backoffice Delivery Dispatch-to-Transit gate
> `20260909151000` **DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL
> POSTFLIGHT/BEHAVIOR PASS**. Partial/full Dispatch memakai Stock Transfer
> canonical untuk memindahkan stok fisik serta FIFO Gudang ke Transit
> `SALES_DELIVERY_OUTBOUND`, menjaga total inventory Company dan menyimpan
> lineage DO ke transfer. Customer receipt, sale-out final, Qty To Invoice,
> Invoice, Payment, dan Finance belum dibuka. Target terverifikasi hanya
> isolated Development `fkywtxucmyjvpwdiqpix`; production/staging tidak
> disentuh. Scoped ESLint dan full Next build 81 route PASS.

> 2026-09-09: Backoffice Confirm fulfillment runtime
> `20260909147000` **DATABASE LIVE ON ISOLATED DEVELOPMENT ONLY**. Confirm SO
> baru sekarang secara atomik membuat full Reserved Out dan satu DO
> `INITIAL/READY`; shortage hanya boleh bila Warehouse mengaktifkan
> `allow_negative_stock`. Bundle memakai resolver komponen canonical. Belum ada
> Stock/FIFO/Invoice/Payment/Finance effect. Manual postflight dan behavioral
> PASS berdasarkan eksekusi user; client/Inventory smoke/UAT belum dimulai; production/staging lama
> tidak disentuh.

> 2026-09-09: Combined Inventory Reserved Out gate `20260909148000` **DATABASE
> LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS PER USER**. Stock Real mempertahankan response lama
> dan menambahkan sisa Reserved Out Backoffice ke sumber POS existing, breakdown
> per sumber, serta detail SO/Customer/DO/tanggal/status. Perubahan read-only;
> On Hand, FIFO, Movement, Delivery, Invoice, Payment, dan Finance tidak dimutasi.
> Target rollout hanya isolated Development; authenticated client smoke/UAT
> masih pending; production/staging tidak disentuh.

> 2026-09-09: Backoffice Delivery visibility gate `20260909149000` **DATABASE
> LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS PER USER**. Inventory > Surat Jalan menggabungkan
> dokumen POS existing dengan DO Backoffice secara source-aware dan read-only.
> Operasi Dispatch, penerimaan, bulk, print audit, discrepancy, Backorder,
> Stock/FIFO, Invoice, Payment, dan Finance Backoffice tetap fail-closed sampai
> gate mutation berikutnya. Lint dan full build PASS; target hanya isolated
> Development; production/staging tidak disentuh.

> 2026-09-09: Dedicated Warehouse Transit usage gate `20260909150000`
> **DATABASE LIVE ON ISOLATED DEVELOPMENT; MANUAL POSTFLIGHT/BEHAVIOR PASS**. Transit dipetakan unik per Gudang
> operasional dan tujuan `Pengiriman Customer`, `Transfer antar Gudang`, atau
> `Retur Customer`; Transit lama dipertahankan tanpa tebakan/backfill. Master
> Gudang UI dan guarded writer tersedia. Resolver lazy sudah disiapkan tetapi
> belum dipanggil Dispatch; Stock/FIFO/Movement/Delivery/Finance tetap nol.
> Targeted lint dan full build PASS; authenticated UI smoke/UAT masih pending;
> production/staging tidak disentuh.

> 2026-09-09: Backoffice fulfillment contract correction
> `20260909146000` **DATABASE LIVE ON ISOLATED DEVELOPMENT ONLY**. DO awal
> sekarang memiliki default `INITIAL` + `READY`; DO tambahan hanya boleh
> `BACKORDER` dengan parent DO. Selisih sebelum penerimaan dicatat pada DO yang
> sama, bukan membuat DO `CORRECTION`; setelah penerimaan selesai wajib melalui
> Retur. Migration hanya mengoreksi schema foundation yang masih kosong dan
> belum mengaktifkan Confirm/Stock/FIFO/Invoice/Payment/Finance runtime. Manual
> correction postflight dan behavioral rerun **PASS berdasarkan eksekusi manual
> user**; production/staging lama tidak disentuh.

> 2026-09-09: Backoffice fulfillment lineage foundation
> `20260909145000` **DATABASE LIVE ON ISOLATED DEVELOPMENT ONLY**. Relation
> Reservation dan multi-Delivery Order (Initial/Backorder) dibuat
> terpisah dari POS retail, tenant-scoped, RLS, composite-FK, dan immutable
> audit. Migration zero-backfill serta tidak mengubah Confirm, Stock/FIFO,
> Invoice, Payment, atau Finance. Manual postflight dan rollback behavior
> pending; production/staging lama tidak disentuh.

> 2026-09-09: forward-fix revisi commercial
> `20260909144000` **DATABASE LIVE ON ISOLATED DEVELOPMENT**. Behavioral test
> sebelumnya rollback karena transient UPDATE mempertahankan
> `grand_total_before_rounding` lama saat subtotal sementara sudah nol. Fix
> mereset seluruh header commercial menjadi zero-state yang valid sebelum
> calculator canonical menulis total final; amount constraint tetap aktif dan
> tidak ada backfill/downstream effect. Fix postflight dan behavioral rerun
> masih pending; production/staging lama tidak disentuh.

> 2026-09-09: Backoffice Quotation/SO revision dan status **DATABASE LIVE ON
> ISOLATED DEVELOPMENT; CLIENT LOCAL BUILD PASS**. UI memisahkan Quotation dan
> Sales Order, tidak lagi menawarkan aksi ambigu `Tandai Terkirim`, menyediakan
> filter status dan basis tanggal eksplisit, serta merevisi SO bernomor sama
> dengan alasan/version/audit. `Dalam perjalanan` berarti barang berangkat dan
> `Selesai` berarti diterima Customer; sesudah selesai perubahan wajib melalui
> Retur. Manual postflight, rollback behavior, authenticated smoke, dan UAT
> masih pending. Confirm Backoffice belum membuat Reservation/DO karena lineage
> DO-before-Invoice masih gate berikutnya. Detail SO memakai full-width table
> dan summary grid agar kolom Jumlah/total sejajar; scoped lint dan guarded
> build PASS. Production/staging lama tidak disentuh.

> 2026-09-09: behavioral commercial pertama menemukan INSERT Draft lama belum
> mengisi `canonical_unit_price` yang baru diwajibkan. Forward-fix
> `20260909141000` **DATABASE LIVE ON ISOLATED DEVELOPMENT** menyalin harga
> canonical dari resolver pada INSERT atomik, tanpa default harga nol, backfill,
> atau efek Stock/Finance. Fix postflight dan behavioral rerun masih menunggu
> eksekusi manual user; production/staging lama tidak disentuh.

> 2026-09-09: Backoffice Sales commercial parity **DATABASE LIVE ON ISOLATED
> DEVELOPMENT; CLIENT LOCAL READY**. Role formal `SALES` dan `SALES_ADMIN`
> memperoleh capability modul Sales dengan tenant boundary tetap aktif.
> Quotation/SO sekarang membawa harga canonical/manual override, discount line
> dan order, pajak inclusive, serta rounding. Pengaturan stok minus ditampilkan
> pada Warehouse dan tetap memakai runtime guard existing. Guarded build dan
> scoped lint PASS; manual postflight, rollback behavior, authenticated smoke,
> POS regression, dan UAT masih pending. Production/staging lama tidak disentuh.

> 2026-09-09: koreksi header Backoffice Quotation/SO **DATABASE LIVE ON
> ISOLATED DEVELOPMENT; CLIENT LOCAL READY**. Pricelist sekarang merupakan
> field header nyata: workspace membawa default Customer dan scope Store/date,
> pilihan AUTO/explicit diteruskan ke canonical server price resolver, dan
> snapshot line menyimpan identitas/sumber harga. Form memakai action/status
> row serta sheet identity/customer/commercial header; Store/Warehouse tetap
> di Informasi Lainnya. Migration/ledger, lint, guarded build, dan diff check
> PASS. SQL postflight, rollback behavior, authenticated visual smoke, POS
> regression, dan UAT masih pending; production/staging lama tidak disentuh.

> 2026-09-09: Backoffice Quotation/SO client vertical slice **LOCAL READY**.
> Menu feature-scoped, list/detail, Draft/Edit/Send/Confirm/Cancel, authenticated
> API proxy, operation UUID, dan optimistic version telah lint + guarded build
> PASS hanya terhadap isolated Development `fkywtxucmyjvpwdiqpix`. Fixture
> master resmi dan feature pilot kini ON hanya untuk satu Company Development;
> closing inventory tetap 0 untuk Reservation/Stock Movement/Delivery/Invoice/
> Payment/Finance. Authenticated browser smoke, POS regression, dan UAT masih
> pending; production/staging lama tidak disentuh.

> 2026-09-08: Backoffice Quotation/SO runtime kini **DATABASE + ROLLBACK
> BEHAVIOR PASS** hanya pada isolated Development `fkywtxucmyjvpwdiqpix`.
> Exact retry, payload conflict, stale version, Draft/Sent/Confirmed/Canceled,
> audit, tenant/permission boundary, dan zero downstream effect telah diuji.
> Forward-fix `20260908121000` mengkualifikasi `extensions.digest`; migration
> chain up to date. Feature tetap OFF; client, fulfillment, Finance, smoke, dan
> UAT belum selesai. Production/staging lama tidak disentuh.

> 2026-09-08: isolated Development `fkywtxucmyjvpwdiqpix` sekarang sinkron
> sampai `20260908110000`. Foundation Quotation/SO Backoffice terisolasi telah
> lolos postflight: 4 relation RLS, 0 browser privilege, 2 immutable history
> trigger, feature tetap OFF, dan 0 efek transaksi ke Stock/Delivery/Invoice/
> Finance. Statusnya **DATABASE FOUNDATION PASS**, bukan runtime/UAT PASS.
> Production dan staging lama tidak disentuh.

> 2026-09-08: isolated Development baseline sekarang sinkron sampai
> `20260908100000`; Backoffice Sales process-identity foundation postflight PASS
> dan feature tetap OFF. Behavioral test masih menunggu Sale fixture dan tidak
> diklaim PASS. Audit call chain menunjukkan Quotation/SO baru harus memakai
> relation terisolasi karena `sales_headers` terikat trigger lifecycle POS.
> Production dan staging lama tidak disentuh.

> 2026-09-08: baseline isolated Development diterapkan sampai
> `20260810185000` (88 migration ledger rows), lalu berhenti fail-closed pada
> `20260810190000` karena project fresh belum mempunyai linked Auth profile
> `super_admin` untuk actor audit. Production/staging tidak disentuh. User perlu
> membuat satu dummy user melalui Authentication project Development; guard
> migration tidak akan dilemahkan atau dibypass.

> 2026-09-08: isolated Supabase Development `fkywtxucmyjvpwdiqpix` telah
> terverifikasi, ter-link, dan isolation guard PASS. Catalog preflight
> membuktikan project fresh tanpa relation aplikasi maupun migration ledger.
> Full migration chain dry-run PASS; belum ada migration/schema/data yang
> diterapkan. Status: **DEVELOPMENT DATABASE FRESH; BASELINE PUSH APPROVAL
> REQUIRED**. Production dan staging lama tetap tidak disentuh.

> 2026-09-08: target isolated Supabase Development telah ditetapkan ke
> `fkywtxucmyjvpwdiqpix`, berbeda dari production dan staging lama. Target sudah
> dikunci pada env lokal yang di-ignore, tetapi akun Supabase CLI current belum
> mempunyai visibility ke project baru. Tidak ada link ulang, query database,
> migration, reset, seed, atau deployment pada project baru. Status:
> **PROJECT IDENTIFIED; CLI ACCESS REQUIRED**.

> 2026-09-08 correction: project Supabase untuk build lokal adalah project baru,
> bukan production dan bukan `POINTOFSALES-KGS-STAGING`. Audit staging terdahulu
> hanya read-only, tidak mengubah data/schema, dan tidak berlaku sebagai baseline
> project baru. Reset staging tidak pernah dijalankan dan telah dibatalkan.
> Launcher sekarang menolak kedua target lama dan menunggu project ref baru yang
> dikonfirmasi user.

> 2026-09-08: staging isolation PASS, tetapi baseline **LEDGER DRIFT**.
> Supabase ledger berhenti `20260814170000` sementara enam migration berikutnya
> hanya tercatat pada custom ledger. `db push` dihentikan sebelum mutation.
> Rebuild dari nol memerlukan reset destruktif project STAGING dan menunggu
> persetujuan eksplisit; production tetap tidak disentuh.

> 2026-09-08: project `POINTOFSALES-KGS-STAGING` telah diverifikasi terpisah dan
> CLI ter-link ke staging, bukan production. Backoffice `.env.local` production
> tidak diubah. Launcher Development allowlist/denylist local-ready; credential
> staging dan baseline database belum diverifikasi, sehingga migration dan
> feature implementation tetap belum dijalankan.

> 2026-09-08: optional Backoffice Sales berada pada **ENVIRONMENT GATE;
> IMPLEMENTATION PAUSED**. Full Supabase lokal tidak tersedia tanpa Docker dan
> PostgreSQL/mock tidak boleh dianggap bukti integrasi. Next action tunggal
> adalah project Supabase Development terpisah, environment isolation, lalu
> reproducible baseline. Production tetap tidak disentuh dan feature tetap OFF.
> Authority: `docs/runbooks/BACKOFFICE_SALES_SAFE_DEVELOPMENT_PLAN.md`.

> 2026-09-08: optional Backoffice Sales mencapai **PHASE 0 SOURCE AUDIT LOCAL
> READY; DATABASE NOT RUN**. Preflight read-only membuktikan model current masih
> one-Sale/one-Invoice, one-Sale/one-Delivery, dan Delivery wajib menunjuk
> Invoice. Next safe step adalah foundation additive default OFF; bukan
> instalasi ulang Windows/Docker. Tidak ada POS, database aktif, env, Company
> setting, atau deployment yang diubah.

> 2026-09-08: Phase 1 process identity foundation **LOCAL READY; DATABASE NOT
> RUN**. Migration `20260908100000` menyiapkan feature Backoffice Sales default
> OFF dan identitas immutable `POS/RETAIL` versus `BACKOFFICE/DELIVERED_QTY`.
> Constraint one-Invoice/one-Delivery existing belum dilepas, sehingga runtime
> POS tetap sama. Preflight, postflight, test rollback, dan runbook tersedia.
> 2026-09-08: arah future optional Backoffice Sales telah dicatat tanpa
> perubahan runtime. Source POS tetap selalu memakai flow retail existing;
> Super Admin dapat mengaktifkan entitlement per Company untuk Quotation -> SO
> -> Reservation/DO -> delivered quantity -> satu atau beberapa Invoice.
> Inventory target memisahkan On Hand, Reserved Out, Available, Incoming, dan
> Forecasted. Multiple Invoice, Qty To Invoice, Backorder, Stock Transit, serta
> Delivered Not Invoiced mempunyai boundary sendiri; pro-forma dan cicilan
> Payment bukan Invoice tambahan. Catatan awal tetap ada di
> `docs/SALES_ORDER_DUAL_INVOICE_PROCESS_NOTES.md`; implementasi Backoffice Sales
> kini berjalan bertahap secara local-first pada Supabase Development terisolasi.
> Belum ada deployment ke production sampai local UAT disetujui.

> 2026-09-07: forward-fix routing Export Invoice berstatus **LOCAL READY;
> DATABASE LIVE; CLIENT AUTHENTICATED SMOKE PENDING**. Next 16/Turbopack lokal
> mengembalikan HTML 404 untuk child route `/api/sales/documents/export`
> walaupun file masuk manifest. Data Exchange sekarang memakai collection route
> aktif `/api/sales/documents?operation=EXPORT`; handler XLSX, authorization,
> Company scope, RPC, dan data tetap sama. Tidak ada migration atau mutation
> transaksi pada perbaikan ini.

> 2026-09-07: koreksi pembacaan tanggal Invoice `SCHEDULED` berstatus **LOCAL
> READY; DATABASE LIVE; CLIENT SMOKE PENDING**. Daftar/detail Backoffice,
> print/PDF, print POS, dan export rentang
> memakai satu resolver: policy `ORDER_DATE` mengambil `planned_order_date`,
> sedangkan `POSTED_DATE` tetap mengambil waktu final/konfirmasi. Snapshot dan
> transaksi lama tidak dimutasi. Postflight Supabase sudah PASS; deploy client, authenticated
> smoke, dan UAT masih manual sesuai
> `docs/runbooks/SALES_INVOICE_SCHEDULED_DATE_READ_FIX.md`.

> 2026-09-07: sandbox HR lokal menambahkan Entitas pada direktori Employee,
> laporan operasional bulanan multi-Company, notification setiap approval, dan
> reminder mock untuk pending lebih dari tujuh hari. Finance/payroll posting
> tetap per Company; scheduler dan persistence belum dibangun.

> 2026-09-07: prototype HR lokal menampilkan akses multi-Company untuk HR dan
> SPV berdasarkan assignment Super Admin, Company selector terbatas scope,
> notifikasi perubahan shift ke HR/atasan, dan master organisasi dummy.
> Semuanya masih state browser pada `hr-sandbox/`; belum ada auth/database/live
> notification dan tidak mengubah runtime MADS.

> 2026-09-07: sandbox HR lokal menampilkan workflow jadwal SPV Departemen ke
> HR `Approve & Publish`, roster Employee per departemen, dan pilihan shift
> mandiri. Contoh Production sekarang memperagakan lima hari dengan jumlah
> shift `3/2/2/3/3` dan nama dummy dikelompokkan per shift. Seluruh aksi masih
> mock/state browser; runtime tetap deferred.

> 2026-09-07: detail Employee Master pada sandbox HR lokal memiliki enam tab
> dan fixture lengkap, termasuk masking NIK/payroll/rekening/NPWP/BPJS. Data,
> reveal control dan riwayat masih mock; belum ada permission/database runtime.

> 2026-09-07: Employee Master pada prototype HR lokal memiliki simulasi reset
> password satu-kali-tampil dan salin pesan WhatsApp. Ini belum terhubung ke
> autentikasi/database MADS; kontrak server-side dan audit masih deferred.

> 2026-09-07: prototype lokal HR memakai palet merah Sahara dan Office Kiosk
> satu kolom portrait tanpa PIN. Perubahan tetap terisolasi di `hr-sandbox/`
> yang di-ignore; belum terhubung ke runtime/database MADS dan belum deployment.

> 2026-09-07: baseline future HR opsional per Company telah dicatat untuk
> Backoffice HR, Office Attendance Kiosk dan Employee Android App di
> `docs/HR_MODULE_PRODUCT_NOTES.md`. Status tetap **DEFERRED**; belum ada schema,
> runtime, UI, APK, feature activation atau deployment HR.
> Arah distribusi yang dicatat adalah Android signed APK internal dengan
> fallback web/PWA untuk iPhone; native iOS dan pembungkusan POS menjadi APK
> belum dibuka.

> 2026-09-07: prototype HR tiga-permukaan tersedia hanya sebagai
> `hr-sandbox/` lokal yang di-ignore dari Git. Lint, TypeScript/Vite build, HTTP
> preview, dan regression build PWA PASS. Tidak ada database, Supabase, APK,
> deployment, atau integrasi runtime MADS.

> 2026-09-04: modal detail Invoice revision activity diperpadat. Status kini
> berupa badge, linkage lama/pengganti berupa nomor Invoice yang dapat diklik,
> dan timeline dipindahkan ke drawer Riwayat yang tertutup secara default.
> Perubahan hanya pada UI Backoffice dan tidak mengubah runtime transaksi.

> 2026-09-04: timeline aktivitas dan tautan dua arah Invoice revisi berstatus
> **local-ready**. Backoffice menampilkan waktu server/actor, nomor Invoice lama
> dan pengganti yang dapat dibuka tanpa memperlihatkan UUID. Pembatalan biasa
> tetap tidak memiliki tautan pengganti. Read model bersifat additive dan tidak
> mengubah Order, Stock, Payment, atau Finance; database rollout dan authenticated
> smoke masih manual sesuai `docs/runbooks/SALES_ORDER_REVISION_ROLLOUT.md`.

> 2026-09-03: catatan Finance future module diperjelas. HR, Manufacture, dan
> Logistik kelak mengirim immutable Financial Event ke canonical Finance, bukan
> menulis Journal langsung. Manufacture mendukung BOM sebagai baseline dan
> actual multi-output/grade/yield dengan cost allocation tersnapshot; COGS
> berasal dari actual finished-goods batch. Status tetap **DEFERRED** dan tidak
> ada perubahan runtime/database.

> 2026-09-03: roadmap masa depan HR, Manufacture, dan Logistik telah diperinci
> sebagai catatan arsitektur. HR mengacu pada kelompok fungsi Mekari Talenta,
> Manufacture pada konsep Odoo, dan Logistik diprioritaskan dari Proof of
> Delivery/tanda tangan digital lalu route planning. Ketiganya tetap
> **DEFERRED**; tidak ada schema, UI, migration, entitlement, database write,
> atau deployment yang dibuka. Lihat
> `docs/ERP_EVOLUTION_ARCHITECTURE_NOTES.md`.

> 2026-09-03: header PWA POS dua baris **local-ready**. Baris utama sekarang
> memuat identitas, Company, pilihan Katalog/Compact, serta utilitas berbentuk
> ikon di sisi kanan. Menu operasional tetap berlabel pada baris kedua yang
> ringkas dan dapat digulir horizontal pada layar sempit. Seluruh feature flag,
> permission, handler, dan alur transaksi existing dipertahankan; tidak ada
> migration atau perubahan database. Deploy dan authenticated visual smoke
> masih manual.

> 2026-09-03: forward-fix lifecycle serah barang Surat Jalan Pickup
> **local-ready**. ODR Phase 3A tanpa sengaja mewajibkan marker Dispatch pada
> seluruh dokumen `DELIVERED`, sehingga Pickup legacy `READY -> DELIVERED`
> gagal walaupun flow tersebut approved. Migration `20260903130000` memulihkan
> hanya jalur Pickup tanpa Reservation; Pickup ODR dan Delivery tetap wajib
> Dispatch. Tidak ada backfill atau perubahan Stock/FIFO/Movement/Finance.
> Rollout manual mengikuti
> `docs/runbooks/INVENTORY_PICKUP_HANDOVER_LIFECYCLE_FIX.md`.

> 2026-09-03: bulk status Inventory Surat Jalan **local-ready**. Checkbox existing
> dapat menjalankan `Kirim terpilih` untuk Delivery READY dan `Tandai terkirim`
> untuk Delivery DISPATCHED. Setiap dokumen tetap memakai runtime canonical
> satuan secara berurutan; Pickup, partial, status campuran, dan stale version
> fail-closed. Tidak ada migration/database change. Deploy dan authenticated
> smoke masih manual sesuai
> `docs/runbooks/INVENTORY_DELIVERY_BULK_STATUS_UI.md`.

> 2026-09-03: Revisi Sales Order pre-dispatch **local-ready**. POS membuat Draft
> replacement tanpa menyentuh Order/Reserved Out lama; saat Confirm, cancel
> source dan confirm replacement berjalan atomik dengan nomor Invoice/SJ baru.
> Order yang sudah Dispatch atau payment verified tetap ditolak. Database dan
> deploy belum dilakukan agent; ikuti
> `docs/runbooks/SALES_ORDER_REVISION_ROLLOUT.md`.

> 2026-09-01: kompatibilitas detail dan unduh/print Surat Jalan ODR untuk Admin
> Gudang **local-ready**. Forward migration `20260901110000` memakai snapshot
> Delivery immutable di bawah `inventory.delivery_documents VIEW`; rollout
> database dan authenticated smoke masih manual. Lihat
> `docs/runbooks/INVENTORY_DELIVERY_ODR_PRINT_COMPATIBILITY.md`.

> 2026-09-01: ODR Dispatch runtime schema forward-fix **local-ready**.
> Error generik Dispatch dilacak ke pemanggilan `digest` dari schema yang salah
> dan referensi kolom requirement legacy. Forward-fix `20260901100000`
> menggunakan `extensions.digest` serta Product canonical tanpa mengubah alur
> bisnis atau data historis. Exact SJ berhasil dalam transaksi rollback; lint
> dan production build Backoffice PASS. Produksi belum dimutasi oleh agent.
> Rollout dan authenticated smoke masih manual; lihat
> `docs/runbooks/ODR_DISPATCH_RUNTIME_SCHEMA_FORWARD_FIX.md`.

> 2026-09-01: Platform Health Operasional Super Admin **local-ready**.
> Dashboard global hanya membaca agregat status lintas Company melalui RPC
> guarded, refresh manual, timeout terbatas, tanpa trigger, auto-fix, atau
> perubahan transaksi. Database rollout, deploy Backoffice, dan authenticated
> Super Admin/regular-user smoke masih manual; lihat
> `docs/runbooks/PLATFORM_OPERATIONAL_HEALTH_DASHBOARD_ROLLOUT.md`.

> 2026-08-31: detail penerimaan pada riwayat Supplier Order local-ready.
> Read model `20260831110000` menampilkan ordered, total receipt `POSTED`, dan
> remaining per barang tanpa mengubah PO, Goods Receipt, Stock, AP, atau
> Finance. Rollout database, deploy Backoffice, dan authenticated smoke masih
> manual; lihat `docs/runbooks/PURCHASE_SUPPLIER_ORDER_RECEIPT_PROGRESS.md`.

> 2026-08-31: forward-fix read-only Purchasing Demand `20260831100000`
> local-ready. Alias Product pada aggregate composed PO diperbaiki tanpa
> mengubah Demand, Request, PO, Stock, atau Finance. Migration, postflight,
> behavioral rollback, dan authenticated smoke masih harus dijalankan manual;
> lihat `docs/runbooks/ODR6C1_PURCHASING_DEMAND_UI_CUTOVER.md`.

> 2026-08-30: forward-fix pembatalan Cash Order dari sesi sumber yang sudah
> ditutup sekarang local-ready. Reversal exact-once masuk ke sesi aktif Kasir
> pada Store yang sama tanpa menulis ulang closing lama. Rollout database,
> deployment, dan authenticated smoke masih manual; lihat
> `docs/runbooks/SALES_ORDER_CANCELLATION_INVOICE_SYNC.md`.

> 2026-08-30: forward-fix ODR Draft-resume local-ready memisahkan Draft input
> dari Order confirmed/reserved. Rollout database dan authenticated smoke masih
> manual; lihat `docs/runbooks/ODR_CONFIRMED_ORDER_DRAFT_RESUME_GUARD.md`.

Arsitektur lanjutan Order Reservation/Dispatch telah **disetujui**. ODR-1,
ODR-2A, dan ODR-2B atomic reservation runtime sudah dikonfirmasi PASS pada
database user. Targetnya: konfirmasi POS
membuat Sales Order serta `Reserved Out`, Stock/FIFO baru berkurang saat Surat
Jalan di-Dispatch, shortage dihimpun per sesi untuk Purchasing, dan verifikasi
pembayaran Finance dipisahkan dari event Dispatch. Rencana enam fase dan batas
compatibility tersedia di
[POS Order Reservation, Dispatch, Procurement, and Finance Plan](docs/POS_ORDER_RESERVATION_DISPATCH_FINANCE_PLAN.md).
ODR-6B.2 Inventory Dispatch UI sekarang **local-ready**. Backoffice Surat Jalan
memakai runtime canonical untuk partial/full Dispatch dan konfirmasi diterima;
Dispatch menyelaraskan On Hand, FIFO, Movement, dan Reserved Out, sedangkan
Received tidak memberi stock effect kedua. Dokumen legacy tetap kompatibel dan
tidak ada migration baru pada tahap UI ini. Deploy serta authenticated smoke
masih menunggu user sesuai
[runbook ODR-6B.2](docs/runbooks/ODR6B2_INVENTORY_DISPATCH_UI_CUTOVER.md).
ODR-6C.1 Purchasing Demand UI juga **local-ready**. Supplier Order sekarang
menampilkan shortage Reservation per sesi serta amendment Draft/final PO, dan
allocation Draft ikut mengurangi daftar permintaan yang masih dapat dibuatkan
PO. Tahap client ini tidak membuat migration atau mengubah PO final. Rollout
manual mengikuti
[runbook ODR-6C.1](docs/runbooks/ODR6C1_PURCHASING_DEMAND_UI_CUTOVER.md).
ODR-6C.2 Finance Payment Verification UI sekarang **local-ready**. Finance
memperoleh composed workspace untuk melihat, memverifikasi, atau menolak
payment intent dengan effective capability, maker-checker, optimistic version,
dan exact retry. Verifikasi hanya membuat Event `HOLD`; jurnal tetap melalui
controlled Posting Queue dan policy Company tidak diubah. Tahap ini tidak
menambah migration. Rollout manual mengikuti
[runbook ODR-6C.2](docs/runbooks/ODR6C2_FINANCE_PAYMENT_VERIFICATION_UI_CUTOVER.md).
Forward-fix Tutup Sesi asynchronous-payment `20260829130000` juga **local-ready**:
kasir tidak lagi menunggu Finance memverifikasi setiap pembayaran untuk menutup
sesi. Cash drawer movement, actual count/difference, antrean verifikasi, audit,
dan controlled Journal tetap dipertahankan. Rollout manual mengikuti
[runbook Cash Session Close](docs/runbooks/CASH_SESSION_CLOSE_ASYNC_PAYMENT_VERIFICATION.md).
Closing database gate ODR-6C.2 sudah dikonfirmasi seluruhnya PASS. ODR-6D
menemukan lalu menutup tiga consumer legacy pada Return, AR/Statement, dan
TEMPO Collection. Combined postflight dan closure preflight kemudian dilaporkan
PASS: Return dibatasi quantity Dispatch immutable, AR/Receipt hanya mengakui
receivable yang sudah Dispatch, dan pre-Dispatch payment tetap Customer
Advance. Order ODR tidak diubah menjadi legacy POSTED. Full authenticated UAT
lintas role/two-Company/retry tetap pending. Ikuti
[runbook compatibility ODR-6D](docs/runbooks/ODR6D_CONSUMER_COMPATIBILITY_ROLLOUT.md).
Contract freeze, klasifikasi historical, failure code, dan manifest ODR-2 ada di
[ODR-1 Live Contract Audit](docs/ODR1_LIVE_CONTRACT_AUDIT.md). Jalankan
[runbook preflight ODR-1](docs/runbooks/ODR1_ORDER_RESERVATION_DISPATCH_PREFLIGHT.md)
dan pastikan tidak ada `BLOCKER` sebelum ODR-2 dimulai.
ODR-2B membentuk `Reserved Out` dengan optimistic version, exact retry,
Product-Warehouse lock, serta validasi stok-minus terhadap saldo proyeksi.
Confirm/Cancel belum mengubah On Hand, FIFO, Movement, dokumen final, atau
Finance. Migration, behavioral, dan closing postflight ODR-2B sudah
dikonfirmasi PASS oleh user. Preflight ODR-3 juga sudah PASS tanpa blocker.
ODR-3A foundation sekarang local-ready untuk linkage Delivery–Reservation,
partial Dispatch, dan immutable allocation evidence; migration ini belum
mengubah Stock/FIFO/Movement/Finance atau dokumen historis. Ikuti
[runbook ODR-2](docs/runbooks/ODR2_SALES_ORDER_RESERVATION_ROLLOUT.md).
Rollout berikutnya mengikuti
[runbook ODR-3A](docs/runbooks/ODR3A_DELIVERY_DISPATCH_FOUNDATION.md).
ODR-3A telah dikonfirmasi user seluruhnya PASS. ODR-3B confirmed-order
documents kini local-ready: Confirm membuat snapshot Invoice/SJ immutable dan
RPC status lama tidak boleh menandai linked Delivery sebagai Dispatch tanpa
runtime stok. Rollout mengikuti
[runbook ODR-3B](docs/runbooks/ODR3B_CONFIRMED_ORDER_DOCUMENTS.md).
ODR-3B juga telah dikonfirmasi user seluruhnya PASS. ODR-3C atomic Delivery
Dispatch sudah database-live dan seluruh SQL gate PASS: partial/full Dispatch menyelaraskan Reservation,
On Hand, FIFO, Movement, dan immutable allocation dalam satu transaksi;
Delivered tidak memberi stock effect kedua dan Finance tetap ditunda ke ODR-5.
Runbook dan evidence mengikuti
[runbook ODR-3C](docs/runbooks/ODR3C_ATOMIC_DELIVERY_DISPATCH.md).
Gate aktif berpindah ke ODR-4 preflight SELECT-only
untuk demand Purchasing per sesi dan sinkronisasi Draft PO; belum ada schema
atau runtime ODR-4 yang diaktifkan. Jalankan
[runbook ODR-4](docs/runbooks/ODR4_PROCUREMENT_DEMAND_PREFLIGHT.md).
Preflight ulang kemudian diterima tanpa blocker. ODR-4A additive demand
foundation kini local-ready dan tetap zero-backfill; Stock Request, Draft/final
PO, stok, serta Finance belum disentuh. Rollout manual mengikuti
[runbook ODR-4A](docs/runbooks/ODR4A_PROCUREMENT_DEMAND_FOUNDATION.md).
User kemudian mengonfirmasi seluruh gate ODR-4A PASS. ODR-4B session demand
runtime kini local-ready: Confirm/Cancel merekonsiliasi demand secara atomik,
session close membekukan identitas, dan Purchasing memperoleh composed read.
Stock Request/PO sync tetap belum dibuka. Rollout mengikuti
[runbook ODR-4B](docs/runbooks/ODR4B_SESSION_PROCUREMENT_DEMAND_RUNTIME.md).

Order TEMPO terjadwal sekarang **local-ready**. Kasir dapat menyimpan order
untuk tanggal mendatang; Draft otomatis tampil sebagai Order aktif ketika
tanggal bisnis Company tercapai, tetapi tetap memerlukan Post manual. Sebelum
Post tidak ada efek Stock, Payment, AR, Invoice, Surat Jalan, Financial Event,
atau jurnal. Tanggal Finance memakai waktu Post aktual dan tanggal rencana tetap
disimpan sebagai referensi order. Rollout manual mengikuti
[runbook POS Scheduled TEMPO Order](docs/runbooks/POS_SCHEDULED_TEMPO_ORDER_ROLLOUT.md).
Preflight, migration, postflight, dan behavior SQL telah dikonfirmasi PASS oleh
user; PWA smoke terautentikasi dan deployment client masih menunggu.

Finance F1–F4B sekarang **local-ready**: kebijakan pembuatan Accounting Period per
Company (`MANUAL`/`AUTOMATIC`), auto-create bulan berjalan dan berikutnya tanpa
membuka periode terkunci, serta perbaikan resume Draft TEMPO dan perbandingan
jatuh tempo berdasarkan tanggal bisnis Company; Customer Receipt, historical
collection, AR aging/statement/export; serta policy posting `CONTROLLED` atau
`AUTOMATIC`. F4B tidak mengubah policy live saat migration dan tidak memposting
backlog secara diam-diam. Rollout terakhir mengikuti
[runbook Finance F4B](docs/runbooks/FINANCE_AR_POSTING_POLICY_CLOSURE.md).

Panduan penggunaan lengkap: [Manual Pengguna MADS](docs/MANUAL_PENGGUNA_KGS_POS.md).
Checklist UAT, edge case, stop condition, dan risk register:
[Matriks UAT User MADS](docs/USER_UAT_EDGE_CASE_RISK_REGISTER.md).

Pengaturan tanggal Invoice per Company sekarang **local-ready**. Owner/Admin
dapat memilih `Tanggal Order` untuk backorder atau `Tanggal Transaksi` untuk
hari POST; print/PDF Backoffice dan POS hanya menampilkan tanggal tanpa jam.
Policy disnapshot pada Invoice baru dan rollout manual mengikuti
[runbook pengaturan tanggal Invoice](docs/runbooks/INVOICE_DATE_DISPLAY_POLICY_ROLLOUT.md).

Penyelarasan dokumen penjualan sekarang **local-ready**. Invoice A4 POS memakai
template canonical yang sama dengan Backoffice, sedangkan Surat Jalan dapat
dipilih per Company sebagai template Gudang (`Warehouse, Security, Driver,
Customer`) atau Toko (`Kasir, Ekspedisi, Customer`). Nota thermal tidak berubah;
policy Surat Jalan disnapshot pada dokumen baru. Rollout manual mengikuti
[runbook penyelarasan template](docs/runbooks/SALES_DOCUMENT_TEMPLATE_ALIGNMENT_ROLLOUT.md).

Kontak Delivery fleksibel sekarang **local-ready**. Nama penerima tetap wajib,
sedangkan telepon, alamat, jadwal, catatan, dan ongkir boleh kosong; data yang
tersedia hanya disnapshot ke transaksi/Surat Jalan dan tidak memutasi Customer.
Rollout manual mengikuti
[runbook kontak opsional Surat Jalan](docs/runbooks/SALES_DELIVERY_OPTIONAL_CONTACT_ROLLOUT.md).

Penerimaan Barang melalui Backoffice Gudang sekarang **local-ready**. Menu baru
`Purchase → Penerimaan Barang` memberi Owner/Admin/Warehouse Admin jalur Draft
tanpa sesi Kasir, tetapi Post tetap memakai mesin canonical Goods Receipt yang
sama dengan PWA untuk Stock, FIFO, AP provisional, Financial Event, status PO,
idempotency, dan audit. Database belum diubah; rollout manual mengikuti
[runbook Penerimaan Barang Backoffice](docs/runbooks/BACKOFFICE_GOODS_RECEIPT_ROLLOUT.md).

Forward-fix workspace, postflight, dan behavioral test telah dikonfirmasi PASS
oleh user. Navigation Backoffice juga dibuat fail-closed per permission agar
satu key bermasalah tidak lagi mengosongkan seluruh aplikasi Super Admin.

Deployment staging 24 Agustus 2026 sudah diperbarui pada
`https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`; kedua root dan manifest PWA lulus
smoke publik. Project serta database production tidak disentuh.

Filter rentang tanggal Inventory Surat Jalan sudah dipasang melalui migration
`20260824120000_inventory_delivery_date_range_filter.sql` dan dideploy ke
Backoffice staging. Penyaringan memakai timezone Company; authenticated UI
smoke tetap menunggu konfirmasi user.

Operasi cutover Product-UOM per Company ke PACK-only sudah **local-ready**.
Operasi default PREVIEW, mengaktifkan PACK untuk beli/jual, menonaktifkan DUS
dari transaksi baru tanpa menghapus histori, serta menjaga referensi Supplier,
Pricelist, berat, dan audit. Database belum diubah; jalankan sesuai
[runbook PACK-only](docs/runbooks/COMPANY_PACK_ONLY_UOM_CUTOVER.md).

Import Pricelist Distributor kini **local-ready** melalui Global Data Exchange.
File Excel/CSV dicocokkan berdasarkan Company aktif dan SKU; COGS/Retail PACK
menjadi harga dasar, harga DUS/UOM lain diturunkan dari faktor UOM, tiga harga
Customer reusable dibuat/diperbarui, dan tier 60/100/150 PACK masuk Global
default. Preview, apply atomik, audit, exact retry, postflight, behavioral test,
dan rollout tersedia pada
[runbook Import Pricelist Distributor](docs/runbooks/DISTRIBUTOR_PRICELIST_IMPORT_ROLLOUT.md).
Database dan deployment belum diubah oleh perubahan lokal ini.
Jika migration dasar import sudah terpasang, gunakan forward-fix
`20260824110000_distributor_pricelist_missing_sku_skip.sql`; SKU yang tidak
ditemukan akan dilewati tanpa membatalkan SKU valid lainnya.

Operasi admin manual untuk akun terdaftar tersedia sebagai SQL terpisah:
[`find_registered_user.sql`](supabase/operations/find_registered_user.sql)
bersifat SELECT-only dan langsung menampilkan seluruh akun beserta Company,
role, serta status membership tanpa perlu UUID; sedangkan
[`update_registered_user_identity.sql`](supabase/operations/update_registered_user_identity.sql)
default PREVIEW dan menyinkronkan email login, profile, email identity, serta
nama metadata secara atomik setelah konfirmasi eksplisit. Password, role,
membership, permission, dan histori tidak diubah.

Update 21 Agustus 2026: Platform kini memiliki workspace **Point of Sales**
untuk membuat dan mengubah Toko/Terminal secara guarded dan audited. PWA
multi-Company memilih Company serta Terminal/Toko sebelum membuka sesi dan
mengunci perpindahan selama sesi aktif. Form User & Akses juga telah diperbaiki:
state role/Toko membership terpilih tidak lagi bercampur dengan form assignment
Company baru. Backoffice dan PWA lint/build PASS. Perubahan sudah dipublikasikan
ke `https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`; kedua root memberi HTTP 200 dan API
Backoffice tanpa sesi tetap menolak dengan HTTP 401 JSON. Project/database
production tidak disentuh.

Staging terbaru berhasil dipublikasikan pada 20 Agustus 2026 dari commit
`cc3efab`: PWA di `https://kgs-pos-pwa-staging.vercel.app` dan Backoffice di
`https://pointofsales-kgs-staging.vercel.app`. Kedua build Vercel dan smoke HTTP
publik PASS; deployment ini tidak mengubah database maupun project production.

Deployment staging berikutnya pada 20 Agustus 2026 mempublikasikan seluruh
working tree terbaru, termasuk Profil/Rekening Company dan export PO terpilih,
langsung ke project ID staging yang terverifikasi. Build Backoffice (70 route)
dan PWA berhasil; kedua alias memberi HTTP 200. Project, environment, database,
dan domain production tidak disentuh.

Paket MADS dokumen/PO/Terminal UI sekarang **local-ready**: Backoffice dapat
mengunduh PDF Invoice dan Surat Jalan dengan nama Customer di depan, Supplier
Order mempunyai export XLSX berizin, dan fitur operasional PWA dapat
disembunyikan per Terminal tanpa mengubah otorisasi server. Branding visual
menjadi **MADS - Management Distribution System**; identifier database
historis tetap dipertahankan. Migration dan authenticated smoke masih menunggu
rollout manual sesuai [runbook](docs/runbooks/MADS_DOCUMENT_PO_TERMINAL_UI_ROLLOUT.md).

Surat Jalan juga mendukung bulk download lokal tanpa schema baru: pengguna
dapat memilih hingga 50 dokumen dan menerima satu ZIP yang tetap berisi PDF
individual Customer-first. Unduh satuan, print, lifecycle pengiriman, tenant,
dan audit dokumen tidak berubah.

Template print/PDF Invoice dan Surat Jalan tidak lagi merender nama Company.
Logo tetap opsional. Invoice tidak mempunyai tanda tangan; Surat Jalan memakai
template Gudang empat pihak atau template Toko tiga pihak sesuai snapshot.

Pengaturan logo dokumen sekarang **local-ready** per Company. Owner/Admin dapat
mengatur logo header dan stempel visual secara independen pada print/PDF Invoice
dan Surat Jalan tanpa menghapus file logo atau menghilangkannya dari navigasi
aplikasi. Stempel tampil mandiri pada Invoice dan berada di kolom pertama Surat
Jalan sesuai template yang dipilih.
Company existing default menampilkan logo header dan menyembunyikan stempel.
Rollout database dan smoke staging masih manual sesuai
[runbook](docs/runbooks/COMPANY_DOCUMENT_LOGO_VISIBILITY_ROLLOUT.md).

UX PWA POS untuk input angka dan penutupan sesi juga **local-ready**. Wheel pada
field numerik kini menggulir container tanpa mengubah nilai. Penutupan sesi
diakses melalui tombol **Tutup Sesi** di header dan kas fisik diisi dalam modal
konfirmasi. Field nominal utama menampilkan pemisah ribuan Indonesia, misalnya
`100.000`, sementara payload server tetap berupa nilai numerik mentah. Tidak ada
kontrak transaksi atau schema yang berubah.

Import/export Customer dan import additive UOM Product sekarang local-ready di
Global Data Exchange. Template additive UOM mengambil seluruh Product aktif dan
memberi satu baris input kosong per Product; baris kosong dilewati, UOM existing
tetap dipertahankan, Base UOM tidak dapat diganti, dan conversion historis yang
sudah dipakai Movement tetap terkunci. Rollout database masih manual melalui
[runbook Customer](docs/runbooks/PRD_CUSTOMER_MASTER_IMPORT_EXPORT.md) lalu
[runbook Product-UOM](docs/runbooks/PRD_PRODUCT_UOM_ADDITIVE_IMPORT_EXPORT.md).
Backoffice targeted ESLint dan production build sudah PASS.

Koreksi lanjutan Product-UOM **local-ready**: Template dan Export kini
menampilkan UOM existing sebagai baris `REFERENCE`, diikuti satu baris `INPUT`
kosong per Product. Reference tidak masuk staging. Validasi yang mengandung
error mempertahankan baris valid agar tetap dapat di-commit, sementara baris
error dapat diunduh dan job nonterminal dapat dibatalkan manual dari Riwayat
Import. Job upload/pemetaan milik pengguna yang
ditinggalkan lebih dari 15 menit juga ditutup otomatis dengan audit setelah
permission import diperiksa ulang. Migration, postflight, behavior, dan
smoke staging mengikuti [runbook koreksi](docs/runbooks/PRODUCT_UOM_CONTEXT_TEMPLATE_JOB_CANCEL_ROLLOUT.md).

Koreksi Master Data UOM/Kategori sebelum UAT sekarang local-ready: nama UOM
kembali terlihat, edit tetap melalui RPC berizin, dan hard delete baru hanya
berlaku untuk row yang belum direferensikan. Master yang sudah dipakai harus
dinonaktifkan; semantik quantity UOM historis dikunci. Migration, postflight,
rollback behavioral test, dan authenticated staging smoke masih menunggu
rollout manual sesuai [runbook](docs/runbooks/PRD_GUARDED_INVENTORY_MASTER_CLEANUP.md).
Local TypeScript, lint, dan production build sudah PASS.

Template persiapan data go-live dan urutan cutover tersedia di
[Paket Template Cutover Go-Live](docs/templates/go-live-cutover/README.md).
Setelah dua migration Data Exchange terbaru diterapkan, dua belas tipe master
di paket mengikuti kontrak Import & Export aktif;
template opening AR/AP/Customer Deposit/GL adalah lembar pengumpulan data dan
belum boleh diinjeksi sebelum workflow opening Finance/subledger tersedia.

Recovery user tanpa Company sekarang local-ready: Super Admin tetap dapat
membuka detail akun setelah membership terakhir dicabut, melihat status tanpa
akses, dan menambahkan kembali Company tanpa mengetik ulang email. Modal tetap
terbuka setelah revoke terakhir. Login Backoffice/PWA tetap fail-closed dan
menampilkan pesan bahwa akun tidak memiliki akses perusahaan; authenticated
staging smoke masih menunggu redeploy.

G6 Phase 8 historical Finance closure sudah database-live dan user-confirmed
PASS. Seluruh 32 Financial Event historis telah final: 31 Event mempunyai tepat
satu canonical Journal dan satu exact-zero Goods Receipt ditutup sebagai
`NO_FINANCIAL_EFFECT`; `HOLD=0`, queue aktif nol, exception terbuka nol, serta
seluruh jurnal seimbang. FIFO dan Inventory GL KGS sama tepat Rp89.485.000;
Supplier AP dan Customer Balance juga reconcile per Company.

Gate aktif kembali ke PRD-1 predeploy closure. Local Backoffice lint/build dan
PWA lint/build 14 Agustus 2026 PASS; hasil client build tidak memuat marker
service-role/private key. PWA masih memberi warning non-blocking untuk main
chunk 555,22 kB (153,61 kB gzip), yang harus diukur pada Preview. Remaining
manual gate adalah authenticated role/preset/two-Company E2E, Auth redirect,
Storage branding/cache, dan Vercel Preview smoke; ini belum merupakan approval
Production.

Dua project Vercel staging dan satu Supabase staging terpisah sudah live.
Fresh-database migration chain terverifikasi lengkap sampai G6 Phase 8G setelah
baseline schema pra-ledger dan compatibility bridge ditambahkan. Alias stabil:
`https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`. Public HTTP/API/secret-boundary smoke
PASS; authenticated role/terminal smoke serta Supabase Auth invite/recovery
redirect masih menjadi manual staging gate dan belum merupakan Production
approval.

PWA Expense Settlement modal menerima deployment UI forward-fix pada tanggal
yang sama: nested dialog sekarang centered, field tidak overlap, konten scroll
internal, dan tablet/mobile layout bounded. Tidak ada business flow atau RPC
yang berubah; lint/build PASS dan visual authenticated smoke menunggu Vercel
redeploy dari Git.

Manual logout Backoffice dan PWA juga diisolasi per aplikasi (`local` scope),
agar logout pada satu domain tidak lagi mencabut refresh token aplikasi lain
untuk user Supabase yang sama. Invalid/expired server session tetap fail-closed.
Behavioral pertama menemukan Goods Receipt sah bernilai Rp0 (seluruh source
amount dan batch value nol); transaksi rollback tanpa live effect. Forward-fix
`20260814143000` sudah database-live dan terbukti menutup event tersebut sebagai
`CANCELED / NO_FINANCIAL_EFFECT`, bukan membuat jurnal nol. Runtime positif
tetap source-verified dan tidak dilonggarkan.

## Current development status (2026-08-13)

Atas revisi user, pemisahan Backoffice Invoice/Surat Jalan sekarang user-pass:
Sales hanya memiliki Invoice, sedangkan Inventory mempunyai Surat Jalan
quantity-only untuk print dan lifecycle. Permission additive
`inventory.delivery_documents`, delivery-only RPC/API/UI, pre/postflight, dan
behavior test pada migration `20260813150000` telah dilaporkan sukses; POS print authority,
canonical Sale, nomor, snapshot, Stock, dan Finance tidak berubah. Backoffice
lint dan production build PASS (67 route/page entries); manual database rollout
dan authenticated role smoke masih pending.

POS pre-presentation smoke menemukan satu stale direct read terhadap protected
`customer_balance_company_policies` setelah ACP-6D. Client sudah dikoreksi
untuk memakai hasil guarded open-session Payment Method RPC sebagai authority
availability Customer Balance; tidak ada grant/RLS/migration yang dibuka.
PWA lint dan production build setelah koreksi PASS. Hard refresh/Service Worker
update dan authenticated POS smoke tetap wajib sebelum demo.

ACP-4B database rollout, postflight, and behavior are user-confirmed PASS:
`inventory.master_data` is the first complete custom
permission enforcement slice. Category/UOM/Warehouse/Category-Tax mutations
are guarded server-side, direct Product Category column grants are closed,
navigation and the consolidated Master API consume effective capabilities,
and the user-detail modal can edit the active preset. ACP-4C Product preflight
returned no blockers. User kemudian mengonfirmasi seluruh SQL ACP-4C dan ACP-4D
PASS/INFO. Product management/reference, Product/UOM/Tax mutation, Product
import, navigation, dan Data Exchange memakai authority efektif masing-masing.
Stock Real
komposit kini terpisah dari Kartu Stok, valuasi/Movement terakhir dihitung di
server, dan export mempunyai authority masing-masing. ACP-4E
migration/postflight/behavior/closing kemudian user-confirmed PASS/INFO;
Transfer Stok sekarang live ENFORCED. ACP-4F migration, postflight, behavior,
G3 Opname regression, dan closing generic juga user-confirmed PASS/INFO;
Penyesuaian Stok dan Stock Opname sekarang live ENFORCED setelah seluruh SQL
ACP-4G user-confirmed PASS/INFO. ACP-4H Stok Awal database, postflight,
behavior, regression, dan closing juga user-confirmed PASS. Seluruh rollout,
postflight, behavior, regression, dan closing ACP-4I Minimum Stock kemudian
user-confirmed PASS. Sembilan key Inventory sekarang live ENFORCED. ACP-5A
Customer preflight, migration, postflight, behavior, regression, dan smoke
kemudian user-confirmed PASS; `contacts.customers` sekarang live ENFORCED.
ACP-5B Supplier preflight, migration, postflight, behavior, regression, dan
authenticated smoke kemudian user-confirmed PASS; `contacts.suppliers`
sekarang live ENFORCED. ACP-5C Supplier Order preflight kemudian dikonfirmasi
tanpa blocker dan seluruh migration, postflight, behavior, serta regression
user-confirmed PASS; `purchase.supplier_orders` sekarang database-live
ENFORCED. Authenticated preset/two-Company smoke tetap menjadi closing UAT.
ACP-5D Purchase Return preflight, migration, postflight, behavior, dan
regression kemudian user-confirmed PASS; `purchase.purchase_returns` sekarang
database-live ENFORCED. Authenticated preset/two-Company smoke tetap menjadi
closing UAT. ACP-5E preflight, migration, postflight, behavior, dan regression
kemudian user-confirmed PASS; `sales.sales_documents` sekarang database-live
ENFORCED. Authenticated preset/two-Company smoke tetap closing UAT. ACP-5F
`sales.pricelists` preflight, migration, postflight, behavior, dan regression
kemudian user-confirmed PASS; runtime database sekarang ENFORCED, sedangkan
authenticated preset/two-Company smoke tetap closing UAT. Resolver POS
online/offline tetap memakai authority terpisah. ACP-5G `sales.bundles`
preflight, migration, postflight, behavior, dan regression kemudian
user-confirmed PASS; runtime database sekarang ENFORCED. Gate aktif berpindah
hanya ke ACP-5H `sales.sales_returns`; seluruh rollout dan regression kemudian
user-confirmed PASS. ACP-5 ditutup database-live, sedangkan authenticated matrix
tetap closing UAT. ACP-6A Expense kemudian user-confirmed PASS dan database-live
ENFORCED. ACP-6B Setor Kas migration, postflight, behavior, dan regressions
juga user-confirmed PASS; authenticated smoke ditunda ke closing UAT. Gate
ACP-6C Deposit Variance database/postflight/behavior/regression kemudian
user-confirmed PASS; smoke ditunda ke closing UAT. ACP-6D Customer Balance,
forward-fix mode `WIND_DOWN`, postflight, behavior, serta regression
Phase-49/52/56 seluruhnya user-confirmed PASS. Smoke Finance tetap ditunda ke
closing UAT. ACP-6E Supplier Invoice migration, postflight, behavior, dan
regressions sudah user-confirmed PASS; authenticated smoke tetap closing UAT.
ACP-6F Supplier Payment migration, postflight, behavior, dan regressions sudah
user-confirmed PASS; authenticated smoke tetap closing UAT. ACP-6G Payment
Method migration, postflight, behavior, regression, dan closing postflight
sekarang user-confirmed PASS; runtime database live `ENFORCED`. Gate aktif
berpindah ke ACP-7 security closure. Consolidated ACP-7/PRD-1 live preflight
terbaru tidak memiliki `BLOCKER`: chain ACP-7 25/25, chain PRD-1 32/32, dan 24
permission enforcement PASS; tenant/Stock/Sale/Document/Journal invariant
bersih serta dua Company aktif. Regular multi-Company identity sudah PASS.
PRD-1 belum ditutup karena distinct override dua Company, fixture minimum pada
satu Company, dan empat role UAT masih `SETUP`.
Sebelum UAT, lifecycle akses user per Company sudah database/postflight/behavior
user-confirmed PASS:
Company selector eksplisit pada detail user, edit role/Store tenant-scoped,
guarded revoke, last-owner protection, override cleanup ber-audit, serta active
context repair. Authenticated UI smoke masih menunggu user.

MADS adalah aplikasi Management Distribution System multi-Company yang sedang
dibangun bertahap dengan Supabase sebagai backend, Next.js untuk Backoffice,
serta React/Vite PWA untuk kasir.

> Dokumen ini adalah README aplikasi yang hidup. Setiap build yang mengubah
> status modul, cara menjalankan aplikasi, migration chain, compatibility, atau
> roadmap wajib memperbarui file ini bersama kode dan handoff.

**Status terakhir:** 14 Agustus 2026
**Gate aktif:** PRD-1 authenticated role/preset/two-Company E2E dan Vercel
Preview readiness. ACP-4 sampai ACP-7 database enforcement serta G6 Phase 8
historical Finance closure user-confirmed PASS. Local lint/build dan secret
bundle scan Backoffice/PWA PASS. Fixture role yang belum lengkap tetap manual
UAT scope, bukan alasan melemahkan permission.
**Runtime:** lokal; Supabase aktif; Vercel Preview belum dibuka

## Kondisi Aplikasi Saat Ini

| Area | Status | Catatan |
|---|---|---|
| Tenant, role, RLS, active Company | Complete | Boundary lintas-Company dan browser mutation sudah diuji |
| Custom permission per submodul | ACP-4B sampai ACP-4I, ACP-5A sampai ACP-5H, dan ACP-6A sampai ACP-6G database PASS | Seluruh key yang dibuka pada Inventory, Contacts/Purchase/Sales, dan Finance database-live ENFORCED; ACP-7 role/preset/two-Company/authenticated closure aktif |
| Product Category, UOM, Warehouse | Complete | Canonical master, guarded API/UI, versioning |
| Product + multi-UOM | Complete | Atomic Product/Product-UOM, base UOM, harga per UOM |
| Supplier + Product-Supplier | Complete | Preferred Supplier, purchase UOM, audit |
| Customer + Customer Category | Complete | Walk-In system, credit boundary, grouping induk/cabang |
| Pricelist | Complete pada online core | Global/Customer reusable; resolver aktif pada canonical Draft/Post |
| Payment Method | Online split-payment ready for smoke | Store scope, fee/proof snapshot, stable payment-leg identity, dan tablet multi-metode UI aktif |
| Transaction Category + minimum COA | Complete pada master dan posting historis | 26 kategori, guarded COA, explicit fallback, rule snapshot, dan Phase 8 controlled posting PASS |
| Tax Sales/Purchase | Sales resolver aktif pada online core | Guarded master/version/assignment; Purchase/jurnal tetap belum dibuka |
| Pengaturan Modul | Entitlement + Offline/Stock Minus policy UI ready for smoke | Super Admin mengelola entitlement; Owner/Admin mengelola policy Company, opt-in Gudang penjualan, dan izin user melalui guarded RPC; Store Manager read-only untuk Stock Minus |
| App Launcher & shell | UXD-2 local-ready; authenticated smoke pending | Home bersih hanya card modul; klik membuka landing submodul. Fast Link search hanya menyaring catalog server-authorized. Logo Company di header menjadi tombol Home. API/RPC/RLS tetap authority final |
| Company branding | BRD-1 database USER VERIFIED; BRD-2 upload/UI LOCAL READY | Server-only Storage upload, magic-byte/MIME/extension/size/SHA-256 validation, generated tenant path, version/audit, cleanup, remove modal, dan Company setting tersedia; authenticated multi-Company smoke pending |
| Sales Invoice, Surat Jalan & Ongkir | SLD-R4 USER VERIFIED | Checkbox Delivery berada di final checkout; ongkir ikut total/payment/offline. Full remaining Return menawarkan refund ongkir eksplisit default OFF; historical Sale/Refund journal sudah ditutup melalui G6 Phase 8 |
| Tax assignment Product/Category | Complete pada Sales online boundary | Category default dan Product inheritance/override memakai nama Tax Rule; resolver aktif saat Draft/Post |
| Tax resolver/calculator | Complete pada Sales online boundary | Effective-dated resolver + deterministic calculation dipakai Draft/Post; Purchase/jurnal belum dicutover |
| Master Import/Export | Complete untuk 7 simple master | Phase 40 DB dan Phase 41 authenticated UI smoke PASS |
| Global Data Exchange Center | DEX-4 navigation cutover local-ready; closing smoke pending | Data Exchange menjadi satu-satunya visible Import/Export entry; role-aware master CSV, tujuh Finance XLSX, guarded import, serta Invoice Penjualan XLSX per rentang tanggal tersedia secara local-ready. Backend compatibility lama tetap aktif |
| Generic import framework | Phase 47 UI local-ready | Grouped Product, Product-Supplier, dan Minimum Stock Produk–Gudang database PASS; Minimum Stock guarded API/UI serta fixed import-export lint/build PASS dan menunggu authenticated smoke; Opening Stock, transaksi, Company, dan Staff/password tetap workflow khusus |
| Stock ledger/FIFO production | Complete pada G3 core boundary | Integrated stress/regression diteruskan tanpa error dan Phase-14 rerun seluruh invariant PASS; Sale/Return/Receipt coverage pindah ke gate transaksi |
| POS checkout/offline production | Online checkout dan Offline core COMPLETE sampai Phase 24 | Retained queue/status-first recovery, time-bounded sync, controlled disconnect/reconnect, single final effect, allowance, dan Stock–Movement–FIFO closing diagnostics dikonfirmasi PASS |
| Sales Return | Complete pada required-approval boundary | PWA Draft serta Backoffice review/post berhasil diuji user; guarded cancel/post, stock/FIFO/Movement/refund, dan historical Finance journal PASS. Posting Kasir/optional approval tetap deferred |
| Expense & Cash In | Deposit variance operational UI complete | Actual/return/additional dan Setor Kas online tersedia sesuai channel; historical Expense/Deposit/Variance posting sudah reconcile melalui G6 Phase 8. Bank matching dan offline Expense/Deposit tetap di luar scope aktif |
| Customer Balance | Phase 56 COMPLETE; Phase 57 UI local-ready | Full-balance ONLINE tender database PASS. POS menampilkan saldo, auto-fill seluruh saldo, minimum tambah belanja, dan receipt; authenticated tablet smoke dapat digabung pada E2E berikutnya |
| POS Stock Minus | Phase 60 database COMPLETE; Phase 61 operational UI accepted | User melanjutkan roadmap setelah guarded Backoffice config dan POS reason/retry tersedia. Default tetap OFF, online non-Bundle saja; replenishment dari Goods Receipt menjadi dependency G5 |
| Purchasing end-to-end | Supplier Payment user-reported PASS; corrective tolerance pending | Historical Goods Receipt, Supplier Invoice, dan Supplier Payment sudah mempunyai canonical Journal atau exact no-effect closure; optional tolerance tetap forward-only |
| Finance posting/reconciliation | G6 Phase 8 historical closure USER VERIFIED | 31 Event/Journal POSTED, 92 lines, satu exact no-effect Event, HOLD/queue/exception nol. FIFO–Inventory GL Rp89.485.000 matched; Supplier AP dan Customer Balance reconcile. Buku Besar, Journal Entries, dan XLSX bulanan tetap menunggu authenticated cross-role/cross-Company Preview smoke |

Status operasional detail dan manual gate terbaru ada di
[`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`](docs/ACTIVE_DEVELOPMENT_HANDOFF.md).

## Struktur Repository

```text
backoffice/   Next.js Backoffice untuk master dan administrasi
pwa/          React/Vite PWA kasir; online canonical checkout local-ready
supabase/     migration, diagnostic, behavioral test, dan schema reference
docs/         requirement, spesifikasi, audit, runbook, dan handoff
```

Alur authority aplikasi:

```text
UI -> authenticated API -> guarded RPC/RLS -> tenant-scoped table/audit
```

UUID, tenant identity, actor, role, version, account function, dan system key
divalidasi server-side. UI menampilkan nama bisnis; identifier teknis tidak
menjadi informasi utama pengguna.

Finance memakai UUID sebagai identity backend, tetapi nomor yang dibaca user
berformat `JUR/JRB/PST/EXC/REC/YYYY/MM/######`. Buku Besar bersifat
account-centric dan Journal Entries document-centric. Rollout perubahan ini
ada di
[`docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md`](docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md).

## Menjalankan Lokal

Prasyarat:

- Node.js yang kompatibel dengan dependency repository;
- project Supabase dan migration chain sesuai
  [`supabase/MIGRATION_MANIFEST.md`](supabase/MIGRATION_MANIFEST.md);
- environment variable lokal. Jangan commit secret.

Backoffice:

```powershell
cd backoffice
npm.cmd install
npm.cmd run dev
```

Pemeriksaan Backoffice:

```powershell
npm.cmd run lint
npm.cmd run build
```

PWA:

```powershell
cd pwa
npm.cmd install
npm.cmd run dev
```

Pemeriksaan PWA:

```powershell
npm.cmd run lint
npm.cmd run build
```

Environment minimum memakai nilai lokal berikut tanpa menuliskan nilainya ke
README atau log:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY atau NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY  # server-only; tidak boleh masuk client
```

PWA memakai nama environment yang terdapat pada `pwa/.env.example`:

```text
VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY
```

Pada development monorepo, placeholder PWA otomatis fallback hanya ke
`NEXT_PUBLIC_SUPABASE_URL` dan public publishable key dari
`backoffice/.env.local`. Deployment PWA tetap wajib mengisi variable `VITE_*`;
service-role key tidak pernah diteruskan ke bundle browser.

Cashier biasa dibuat dari `Kontak > User & Akses` dan wajib dipasangkan ke
Toko. Super Admin serta Company Owner/Admin mewarisi aksi Cashier sesuai
kontrak. Store Manager dapat memakai POS hanya pada Toko assignment aktifnya.
Seluruh operator tetap harus memilih Terminal aktif dan Gudang sale-source.
Jika access token browser sudah ditolak Supabase sebagai `INVALID_SESSION`,
Backoffice membersihkan sesi lokal dan kembali ke layar login; restart server
tidak lagi membiarkan aplikasi terkunci pada token kedaluwarsa.

## Database dan Rollout

- Migration production dijalankan manual melalui runbook; agent tidak boleh
  menerapkannya diam-diam.
- Dataset UAT Finance yang mengikuti guarded Product → Opening Stock →
  controlled posting queue → Journal serta Stock Adjustment → Pending Analysis
  tersedia di
  [`docs/runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md`](docs/runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md).
  Operation ini membuat histori permanen dan hanya untuk database test/pilot.
- Jangan mengedit migration yang sudah applied. Gunakan forward migration.
- Urutan wajib: preflight -> migration -> postflight -> behavioral test ->
  application smoke.
- Diagnostic preflight harus `SELECT-only`.
- Behavioral fixture wajib dibungkus transaction dan `ROLLBACK`.
- Finance worker, checkout resolver, stock posting, atau module deferred tidak
  boleh diaktifkan hanya karena master/schema sudah tersedia.

Router rollout berada di [`docs/README.md`](docs/README.md). Migration canonical
dan checksum berada di
[`supabase/MIGRATION_MANIFEST.md`](supabase/MIGRATION_MANIFEST.md).

## Invariant Utama

- Semua data operasional tenant-scoped berdasarkan Company aktif.
- Browser tidak menulis langsung ledger, stock movement, atau master sensitif.
- Stock disimpan pada base UOM dan tidak boleh negatif.
- Harga, discount, tax, payment total, UOM conversion, stock, dan journal final
  dihitung ulang server-side.
- Mutation penting atomic, versioned, auditable, dan idempotent sesuai source.
- Dokumen posted tidak dihapus; koreksi menggunakan reversal/return/adjustment.
- Journal production harus balanced dan tidak boleh memakai nomor COA
  hard-coded.
- Secret/service-role hanya server-side.

Requirement lengkap:
[`docs/POS_V1_MVP_REQUIREMENT_INDEX.md`](docs/POS_V1_MVP_REQUIREMENT_INDEX.md).

## Dokumentasi Pengembangan

- Entry point dokumen: [`docs/README.md`](docs/README.md)
- Gate implementasi: [`docs/POS_V1_IMPLEMENTATION_GATES.md`](docs/POS_V1_IMPLEMENTATION_GATES.md)
- Handoff aktif: [`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`](docs/ACTIVE_DEVELOPMENT_HANDOFF.md)
- Playbook agent: [`docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`](docs/AI_AGENT_CONTINUATION_PLAYBOOK.md)
- Requirement index: [`docs/POS_V1_MVP_REQUIREMENT_INDEX.md`](docs/POS_V1_MVP_REQUIREMENT_INDEX.md)
- Controlled reset data transaksi per Company: [`docs/runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md`](docs/runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md)
- Finance master API/UI rollout: [`docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md)
- Panduan Kategori Transaksi: [`docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md`](docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md)
- Required-category rollout: [`docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md`](docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md)
- Guarded COA/fallback rollout: [`docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md`](docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md)
- Tax master preflight: [`docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md`](docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md)
- Tax master foundation rollout: [`docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md`](docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md)
- Tax master API/UI rollout: [`docs/runbooks/G2_PHASE23_TAX_MASTER_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE23_TAX_MASTER_API_UI_ROLLOUT.md)
- Module Settings rollout: [`docs/runbooks/G2_PHASE24_MODULE_SETTINGS_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE24_MODULE_SETTINGS_API_UI_ROLLOUT.md)
- App Launcher/shell smoke: [`docs/runbooks/G2_PHASE25_ROLE_AWARE_APP_LAUNCHER_SHELL.md`](docs/runbooks/G2_PHASE25_ROLE_AWARE_APP_LAUNCHER_SHELL.md)
- Tax assignment preflight: [`docs/runbooks/G2_PHASE26_TAX_ASSIGNMENT_PREFLIGHT.md`](docs/runbooks/G2_PHASE26_TAX_ASSIGNMENT_PREFLIGHT.md)
- Guarded Tax assignment rollout: [`docs/runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md`](docs/runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md)
- Tax assignment API/UI smoke: [`docs/runbooks/G2_PHASE27_TAX_ASSIGNMENT_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE27_TAX_ASSIGNMENT_API_UI_ROLLOUT.md)
- Tax resolver/snapshot preflight: [`docs/runbooks/G2_PHASE28_TAX_RESOLVER_SNAPSHOT_PREFLIGHT.md`](docs/runbooks/G2_PHASE28_TAX_RESOLVER_SNAPSHOT_PREFLIGHT.md)
- Tax resolver/calculator rollout: [`docs/runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md)
- Master Import/Export preflight: [`docs/runbooks/G2_PHASE29_IMPORT_FRAMEWORK_PREFLIGHT.md`](docs/runbooks/G2_PHASE29_IMPORT_FRAMEWORK_PREFLIGHT.md)
- Master Import staging rollout: [`docs/runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md`](docs/runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md)
- Master Import identity validator rollout: [`docs/runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md)
- Master Import business validator rollout: [`docs/runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md)
- Master Import partial commit rollout: [`docs/runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md`](docs/runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md)
- Master Import API/UI rollout: [`docs/runbooks/G2_PHASE34_MASTER_IMPORT_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE34_MASTER_IMPORT_API_UI_ROLLOUT.md)
- Full Master Import preflight: [`docs/runbooks/G2_PHASE35_FULL_MASTER_IMPORT_PREFLIGHT.md`](docs/runbooks/G2_PHASE35_FULL_MASTER_IMPORT_PREFLIGHT.md)
- Automatic hidden master code preflight: [`docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODE_PREFLIGHT.md`](docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODE_PREFLIGHT.md)
- Automatic hidden master code rollout: [`docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md`](docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md)
- Automatic master code UI cutover: [`docs/runbooks/G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md`](docs/runbooks/G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md)
- Code-less simple master import rollout: [`docs/runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md`](docs/runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md)
- Code-less Import UI cutover: [`docs/runbooks/G2_PHASE39_CODELESS_MASTER_IMPORT_UI_CUTOVER.md`](docs/runbooks/G2_PHASE39_CODELESS_MASTER_IMPORT_UI_CUTOVER.md)
- Fixed CSV contracts: [`docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`](docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md)
- Kartu Stok API/UI smoke: [`docs/runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md`](docs/runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md)
- Stock Transfer preflight: [`docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md`](docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md)
- Stock Transfer database rollout: [`docs/runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md)
- Stock Transfer API/UI smoke: [`docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md`](docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md)
- Stock Adjustment preflight: [`docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md`](docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md)
- Stock Adjustment database rollout: [`docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md)
- Stock Adjustment API/UI smoke: [`docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md`](docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md)
- Stock Opname preflight: [`docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md`](docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md)
- Stock Opname database rollout: [`docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md)
- Stock Opname Backoffice review/report smoke: [`docs/runbooks/G3_PHASE11_STOCK_OPNAME_BACKOFFICE_API_UI.md`](docs/runbooks/G3_PHASE11_STOCK_OPNAME_BACKOFFICE_API_UI.md)
- Bundle foundation preflight: [`docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md`](docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md)
- Bundle foundation database rollout: [`docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md)
- Offline Stock Allowance rollout: [`docs/runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_FOUNDATION_ROLLOUT.md)
- Offline Sale Sync rollout: [`docs/runbooks/G4_PHASE12_OFFLINE_SYNC_ROLLOUT.md`](docs/runbooks/G4_PHASE12_OFFLINE_SYNC_ROLLOUT.md)
- Offline PWA queue foundation: [`docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md`](docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md)
- Offline catalog cache preflight: [`docs/runbooks/G4_PHASE14_OFFLINE_CATALOG_CACHE_PREFLIGHT.md`](docs/runbooks/G4_PHASE14_OFFLINE_CATALOG_CACHE_PREFLIGHT.md)
- POS Customer quick-create: [`docs/runbooks/G4_PHASE18_POS_CUSTOMER_QUICK_CREATE_ROLLOUT.md`](docs/runbooks/G4_PHASE18_POS_CUSTOMER_QUICK_CREATE_ROLLOUT.md)
- Offline Allowance operations UI: [`docs/runbooks/G4_PHASE19_OFFLINE_ALLOWANCE_OPERATIONS_UI.md`](docs/runbooks/G4_PHASE19_OFFLINE_ALLOWANCE_OPERATIONS_UI.md)
- Cashier Offline Allowance PWA UI: [`docs/runbooks/G4_PHASE20_CASHIER_OFFLINE_ALLOWANCE_PWA_UI.md`](docs/runbooks/G4_PHASE20_CASHIER_OFFLINE_ALLOWANCE_PWA_UI.md)
- Offline checkout queue preflight: [`docs/runbooks/G4_PHASE21_OFFLINE_CHECKOUT_QUEUE_PREFLIGHT.md`](docs/runbooks/G4_PHASE21_OFFLINE_CHECKOUT_QUEUE_PREFLIGHT.md)
- Offline checkout queue PWA UI: [`docs/runbooks/G4_PHASE22_OFFLINE_CHECKOUT_QUEUE_PWA_UI.md`](docs/runbooks/G4_PHASE22_OFFLINE_CHECKOUT_QUEUE_PWA_UI.md)
- POS end-to-end UAT sampai Phase 22: [`docs/runbooks/G4_PHASE22_POS_END_TO_END_UAT.md`](docs/runbooks/G4_PHASE22_POS_END_TO_END_UAT.md)
- Offline cold-start/conflict preflight: [`docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_CONFLICT_PREFLIGHT.md`](docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_CONFLICT_PREFLIGHT.md)
- Offline cold-start/recovery PWA: [`docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_RECOVERY_PWA.md`](docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_RECOVERY_PWA.md)
- Offline disconnect/reconnect stress: [`docs/runbooks/G4_PHASE24_OFFLINE_DISCONNECT_RECONNECT_STRESS.md`](docs/runbooks/G4_PHASE24_OFFLINE_DISCONNECT_RECONNECT_STRESS.md)
- Sales Return readiness preflight: [`docs/runbooks/G4_PHASE25_SALES_RETURN_READINESS_PREFLIGHT.md`](docs/runbooks/G4_PHASE25_SALES_RETURN_READINESS_PREFLIGHT.md)
- Sales Return foundation rollout: [`docs/runbooks/G4_PHASE26_SALES_RETURN_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE26_SALES_RETURN_FOUNDATION_ROLLOUT.md)
- Sales Return PWA Draft UI: [`docs/runbooks/G4_PHASE27_SALES_RETURN_PWA_DRAFT_UI.md`](docs/runbooks/G4_PHASE27_SALES_RETURN_PWA_DRAFT_UI.md)
- Sales Return Backoffice approval UI: [`docs/runbooks/G4_PHASE28_SALES_RETURN_BACKOFFICE_APPROVAL_UI.md`](docs/runbooks/G4_PHASE28_SALES_RETURN_BACKOFFICE_APPROVAL_UI.md)
- Expense dan arus kas preflight: [`docs/runbooks/G4_PHASE29_EXPENSE_CASH_FLOW_PREFLIGHT.md`](docs/runbooks/G4_PHASE29_EXPENSE_CASH_FLOW_PREFLIGHT.md)
- Expense request/approval foundation: [`docs/runbooks/G4_PHASE30_EXPENSE_REQUEST_APPROVAL_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE30_EXPENSE_REQUEST_APPROVAL_FOUNDATION_ROLLOUT.md)
- Expense request PWA UI: [`docs/runbooks/G4_PHASE31_EXPENSE_REQUEST_PWA_UI.md`](docs/runbooks/G4_PHASE31_EXPENSE_REQUEST_PWA_UI.md)
- Expense approval Backoffice UI: [`docs/runbooks/G4_PHASE32_EXPENSE_APPROVAL_BACKOFFICE_UI.md`](docs/runbooks/G4_PHASE32_EXPENSE_APPROVAL_BACKOFFICE_UI.md)
- Expense disbursement preflight: [`docs/runbooks/G4_PHASE33_EXPENSE_DISBURSEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE33_EXPENSE_DISBURSEMENT_PREFLIGHT.md)
- Expense disbursement foundation: [`docs/runbooks/G4_PHASE34_EXPENSE_DISBURSEMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE34_EXPENSE_DISBURSEMENT_FOUNDATION_ROLLOUT.md)
- Expense disbursement operational UI: [`docs/runbooks/G4_PHASE35_EXPENSE_DISBURSEMENT_UI.md`](docs/runbooks/G4_PHASE35_EXPENSE_DISBURSEMENT_UI.md)
- Expense settlement preflight: [`docs/runbooks/G4_PHASE36_EXPENSE_SETTLEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE36_EXPENSE_SETTLEMENT_PREFLIGHT.md)
- Expense settlement foundation: [`docs/runbooks/G4_PHASE37_EXPENSE_SETTLEMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE37_EXPENSE_SETTLEMENT_FOUNDATION_ROLLOUT.md)
- Expense settlement operational UI: [`docs/runbooks/G4_PHASE38_EXPENSE_SETTLEMENT_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE38_EXPENSE_SETTLEMENT_OPERATIONAL_UI.md)
- Additional Expense disbursement preflight: [`docs/runbooks/G4_PHASE39_ADDITIONAL_EXPENSE_DISBURSEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE39_ADDITIONAL_EXPENSE_DISBURSEMENT_PREFLIGHT.md)
- Additional Expense disbursement foundation: [`docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md`](docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md)
- Additional Expense operational UI: [`docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md)
- Cash Deposit multi-Session preflight: [`docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md`](docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md)
- Cash Deposit multi-Session foundation: [`docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md)
- Cash Deposit operational UI: [`docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md)
- Deposit variance resolution preflight: [`docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md`](docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md)
- Deposit variance resolution rollout: [`docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md`](docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md)

## Aturan Pembaruan README

Setiap perubahan material wajib memperbarui bagian yang relevan di file ini:

1. status modul dan gate aktif;
2. behavior yang benar-benar sudah aktif, bukan baru direncanakan;
3. migration/runbook dan langkah menjalankan bila berubah;
4. compatibility serta module yang tetap deferred;
5. link dokumentasi baru;
6. evidence lint/build/database/smoke pada handoff.

README menjelaskan keadaan aplikasi untuk manusia. Detail operasional antar-agent
tetap ditulis di `docs/ACTIVE_DEVELOPMENT_HANDOFF.md`, sedangkan keputusan bisnis
tetap berada pada spesifikasi modul masing-masing.
## Status lokal terbaru — 2026-08-19

Alur stok minus POS ke Permintaan Barang per sesi telah **local-ready**, belum
aktif di database sampai migration `20260819170000` dijalankan. Sale online
yang mendapat otorisasi tetap dapat diposting; close sesi akan membuat tepat
satu Stock Request `SUBMITTED` dari shortage sesi yang belum direplenish.
Migration, preflight, postflight, rollback behavioral test, PWA readiness/error,
notice penutupan, badge Purchasing, dan [runbook rollout](docs/runbooks/PRD_NEGATIVE_STOCK_SESSION_REQUEST_ROLLOUT.md)
tersedia. PWA lint/build, targeted Backoffice lint, Backoffice production build,
static SQL/diff gate, behavioral utama, dan empat regression sudah PASS.
Final postflight serta authenticated smoke masih wajib sebelum dianggap siap
dipakai pada data go-live.

## Status lokal terbaru — 2026-08-20 (Profil/Rekening Company)

Profil Company dan tiga field rekening opsional telah **local-ready** melalui
migration `20260820120000`; belum aktif di database sampai rollout manual.
Platform **Profil Perusahaan** mencakup identitas, alamat, kontak, rekening,
logo, dan setting dokumen. Rekening Supplier otomatis mengisi Draft Pembayaran
Supplier. Toggle rekening Invoice default `OFF`; Invoice baru menyimpan snapshot
rekening immutable, sedangkan Surat Jalan tidak menampilkannya. Backoffice
targeted lint/build dan PWA lint/build PASS. Jalankan migration, postflight,
behavior rollback, lalu staging smoke sesuai
[`COMPANY_PROFILE_BANK_INVOICE_ROLLOUT.md`](docs/runbooks/COMPANY_PROFILE_BANK_INVOICE_ROLLOUT.md).

Update rollout: user telah menjalankan migration, postflight terkoreksi, dan
behavioral rollback test dengan hasil seluruhnya PASS pada database target yang
diuji. Client build tetap menunggu deployment dan authenticated smoke sebelum
fitur dinyatakan aktif end-to-end pada environment tersebut.

## Status lokal terbaru - 2026-08-20 (Export PO Terpilih)

Export Supplier Order kini **local-ready** untuk pilihan eksplisit: admin dapat
memfilter daftar, mencentang PO satuan atau seluruh hasil filter, lalu mengunduh
satu XLSX tiga-sheet yang hanya berisi maksimal 100 PO terpilih. Overload RPC
baru memvalidasi capability EXPORT, active Company, UUID, duplikasi, dan tenant
seluruh dokumen; GET/RPC tanpa argumen lama dipertahankan untuk compatibility.
Migration/postflight/behavior serta rollout manual tersedia di
[`SELECTED_SUPPLIER_ORDER_EXPORT_ROLLOUT.md`](docs/runbooks/SELECTED_SUPPLIER_ORDER_EXPORT_ROLLOUT.md).

## Operasi terkontrol - Duplikasi konfigurasi Finance antar-Company

Untuk onboarding Company baru tersedia operasi SQL preview/apply yang memetakan
COA, hierarchy, Transaction Category, Account Function mapping, dan approved
Posting Rules dari Company sumber ke UUID baru milik Company tujuan. Operasi
menolak target yang sudah mempunyai Financial Event atau Journal; baseline
mapping target tanpa histori dinonaktifkan/di-retire secara audited;
tidak menyalin saldo, transaksi, master operasional, identitas, entitlement,
atau policy Store/Warehouse/Terminal. Panduan dan batas operasinya tersedia di
[`COMPANY_FINANCE_CONFIGURATION_CLONE.md`](docs/runbooks/COMPANY_FINANCE_CONFIGURATION_CLONE.md).

Persiapan Company baru dapat dilanjutkan dengan duplikasi template master
Product tanpa membawa transaksi atau stok. Cakupan, exclusion, dan preflight
fail-closed tersedia di
[`COMPANY_MASTER_TEMPLATE_CLONE.md`](docs/runbooks/COMPANY_MASTER_TEMPLATE_CLONE.md).
Setelah preflight Company tujuan seluruhnya `PASS`, operasi atomik
`clone_company_product_master.sql` dapat dijalankan dalam mode PREVIEW lalu
APPLY. Baseline Global Pricelist direuse berdasarkan code; postflight terpisah
memverifikasi semantic parity dan memastikan tidak ada Stock/transaksi terbawa.

## Status lokal terbaru - 2026-08-21 (Platform POS: Toko & Terminal)

Menu **Platform > Point of Sales** kini local-ready untuk mengelola Toko dan
Terminal pada Company aktif. Mutation guarded, audited, versioned, dan direct
browser write ditutup. PWA mempertahankan satu login multi-Company: Company dan
Terminal/Toko dipilih sebelum membuka sesi, lalu selector Company terkunci
selama sesi aktif. Backoffice lint dan production build PASS; rollout database
dan authenticated smoke masih manual gate. Panduan ada di
[`PLATFORM_POS_STORE_TERMINAL_MANAGEMENT_ROLLOUT.md`](docs/runbooks/PLATFORM_POS_STORE_TERMINAL_MANAGEMENT_ROLLOUT.md).

## Status lokal terbaru - 2026-08-25 (Preview harga Pricelist POS)

Bug harga umum yang tetap tampil sampai Draft disimpan telah diperbaiki secara
local-ready. PWA sekarang meminta preview read-only untuk seluruh Product-UOM
dari resolver Pricelist canonical ketika Customer, Pricelist, atau quantity
berubah. Kartu Product dan cart menampilkan harga server tanpa membuat Draft;
Save/Post tetap menghitung ulang dan tetap menjadi sumber kebenaran. Migration
additive `20260825100000`, postflight, behavior rollback-safe, dan urutan rollout
tersedia di
[`POS_LIVE_PRICELIST_PREVIEW_ROLLOUT.md`](docs/runbooks/POS_LIVE_PRICELIST_PREVIEW_ROLLOUT.md).
PWA oxlint serta production build sudah PASS; database rollout dan authenticated
smoke masih manual sehingga fitur belum dinyatakan aktif pada staging/production.

## Status lokal terbaru - 2026-08-25 (Tier Pricelist diskon persen)

Form Pricelist Backoffice kini dapat membuat rule quantity tier dengan metode
**Diskon persen**, selain harga akhir langsung dan potongan nominal per UOM.
Nilai dibatasi 0–100% dan form menampilkan perkiraan harga akhir berdasarkan
harga normal Product-UOM. Resolver canonical online/offline serta kontrak API
yang sudah ada tetap menjadi sumber kebenaran; tidak ada perubahan schema atau
format Import Pricelist Distributor.

## Status lokal terbaru - 2026-08-25 (Tanggal transaksi TEMPO)

Checkout TEMPO PWA kini menampilkan tanggal transaksi/order read-only dan
tanggal jatuh tempo secara berdampingan. Tanggal transaksi berasal dari
`sales_headers.transaction_date`; default tenor Customer hanya memberikan saran
jatuh tempo dan kasir tetap dapat mengubahnya sebelum Post. Migration additive
`20260825110000`, postflight, behavior read-only, dan runbook rollout tersedia.
Core Save/Post, Finance, serta larangan TEMPO Offline tidak berubah.

## Status lokal terbaru - 2026-08-25 (Price override per Terminal POS)

Point 1 sekarang **local-ready**. Terminal/POS mempunyai policy default OFF
untuk mengizinkan override harga per line bagi seluruh kasir sah pada Terminal.
Harga awal tetap resolver Pricelist canonical; hanya override eksplisit yang
menang. Save Draft dan Post memvalidasi ulang policy, sesi aktif, actor, Store,
Terminal, serta channel Online di server. Sale line menyimpan harga canonical,
harga final, actor, Terminal, sesi, source, dan waktu resolve. Offline tetap
menolak override. Migration `20260825120000`, preflight, postflight, runbook,
Backoffice setting, dan PWA edit/reset sudah tersedia. User mengonfirmasi
preflight, migration, postflight awal, dan behavior rollback-safe PASS.
Postflight ulang menjadi closing database berikutnya; deployment client staging
dan authenticated smoke masih manual. User kemudian mengonfirmasi seluruh
dependency/closing PASS; Backoffice dan PWA berhasil dideploy ke dua alias
staging dengan root/manifest HTTP 200. Authenticated ON/OFF transaction smoke
tetap menjadi gate terakhir sebelum status operasional dinyatakan selesai.

## Status lokal terbaru - 2026-08-25 (Workspace POS laptop dua panel)

PWA POS kini local-ready dengan dua pilihan tampilan. Mode **Katalog** lama tetap
menjadi default. Mode **Compact** menjadi alternatif laptop: searchable Product
dropdown dan keranjang berada di kiri, sedangkan Customer, Pricelist, aturan
transaksi, pembayaran, total, serta aksi Draft/Post berada di kanan. Pilihan
disimpan per browser dan switcher berada di header sebagai satu grup responsif,
sehingga area kerja tidak terdorong turun ketika menu Terminal aktif/nonaktif.
Mode dapat diganti tanpa mengubah isi transaksi. Handler cart, preview
Pricelist, Save Draft, checkout, Offline, stock, payment, dan
Finance tidak diubah. PWA lint serta production build PASS; authenticated
browser smoke dan deployment staging/production belum dilakukan.

Atas koreksi user, mode Katalog memakai kembali layout sebelum Compact: kategori
dan kartu Product berada di kiri, sedangkan satu kolom kanan sticky memuat
keranjang dan checkout. Baris keranjang Katalog dibuat horizontal dan ringkas:
nama Product, quantity/UOM, indikator perubahan harga/diskon bila ada, dan
tombol **Edit**, dengan tiga Product terlihat sebelum scroll. Mode Compact tetap
menampilkan 3–4 kartu keranjang per baris pada desktop.
## Update 2026-08-26 — POS TEMPO Backdated Order/Delivery Local Ready

- POS online kini mempunyai kontrak lokal untuk tanggal efektif order TEMPO
  lampau dan rencana kirim lampau. Tanggal order wajib bukan masa depan, berada
  pada Accounting Period `OPEN/REOPENED`, jatuh tempo tidak lebih awal, dan
  rencana kirim tidak boleh sebelum order.
- Waktu input/posting aktual tetap immutable pada `created_at/posted_at`;
  Financial Event Sale memakai `transaction_date` efektif. Cash/Transfer,
  Offline, Stock Movement, serta lifecycle konfirmasi pengiriman tidak berubah.
- Rollout manual belum dijalankan ke database mana pun. Urutan preflight,
  migration, postflight, behavioral test, dan smoke tersedia di
  `docs/runbooks/POS_TEMPO_BACKDATED_ORDER_DELIVERY_ROLLOUT.md`.

## Rencana 2026-08-26 — Analitik Potensi Produk per Customer

- User menyetujui desain awal submodul opsional `Report > Potensi Produk`.
  Fitur membaca Sale/Return final untuk menghitung actual, potential, gap,
  achievement, dan tren tanpa membuat/mengubah transaksi, Stock, Pricelist,
  Purchasing, Payment, atau Finance.
- Model formula dikonfigurasi per Company dan versioned; saat aktivasi admin
  memilih tanggal efektif serta `FORWARD_ONLY` atau historical backfill sejak
  tanggal tersebut. Feature OFF tidak menjalankan job dan tidak mengganggu
  runtime operasional.
- Status masih **approved design / implementation not started**. Source of truth:
  `docs/PRODUCT_POTENTIAL_ANALYTICS_SPEC.md`. Tidak ada schema, UI, database,
  atau deployment yang dibuka oleh pencatatan ini.

## Operasi lokal 2026-08-26 — Update COGS LSM, SMS, dan KMS

- Paket operasi COGS-only dari `Price List Distributor 26082026.xlsx` sudah
  local-ready dan belum dijalankan ke database mana pun oleh Codex.
- Operasi dijalankan satu Company per run dengan PREVIEW sebagai default,
  confirmation eksplisit untuk APPLY, SKU matching, PACK conversion, atomic
  write, dan Product master audit.
- Hanya `products.cogs` dan `purchase_price` Product-UOM aktif yang boleh
  berubah. Retail, harga jual, Pricelist, UOM nonaktif, Stock/FIFO, transaksi,
  Financial Event, dan Journal tetap tidak disentuh.
- Runbook: `docs/runbooks/COMPANY_COGS_UPDATE_20260826.md`.

## Status lokal terbaru - 2026-08-27 (Penerimaan Customer / AR)

- Foundation database Customer Receipt sudah dikonfirmasi PASS oleh user:
  Draft/Post/Cancel, alokasi parsial satu Customer ke banyak Invoice tempo,
  audit immutable, permission ENFORCED, dan `SALE_PAYMENT` event tersedia.
- Backoffice kini memiliki menu **Finance > Penerimaan Customer** untuk memilih
  Customer, melihat invoice tempo terbuka, mengalokasikan pembayaran, menyimpan
  atau melanjutkan Draft, Post, dan membatalkan Draft.
- Runtime journal lanjutan `20260827110000` local-ready: debit Kas/Bank, kredit
  Piutang Customer, dimensi Customer, source verification, exact replay, serta
  prior-period adjustment. Rollout database runtime dan authenticated smoke
  masih menunggu user; fitur belum dinyatakan aktif di deployment.
- Evidence lokal Backoffice: targeted ESLint PASS dan production build PASS
  (74 route, termasuk `/api/finance/customer-receipts`). Runbook:
  `docs/runbooks/FINANCE_CUSTOMER_RECEIPT_AR_ROLLOUT.md`.

F2 database kemudian dikonfirmasi seluruhnya PASS. F3 sekarang masuk preflight
untuk membedakan pembayaran historis atas invoice yang sudah ada dari dana
advance sebelum invoice tersedia. Advance hanya boleh memakai Customer Balance
yang memang aktif dan tidak pernah otomatis menjadi revenue. Runbook:
`docs/runbooks/FINANCE_HISTORICAL_COLLECTION_ADVANCE_ROLLOUT.md`.

Preflight F3 kemudian dikonfirmasi aman: lima Company tetap mempunyai Customer
Balance `DISABLED`, satu invoice tempo terbuka Rp133.500 menjadi scope smoke,
dan tidak ada Customer Receipt existing. Migration `20260827120000` sekarang
local-ready tanpa auto-enable policy: receipt historis dapat dialokasikan ke
invoice, sedangkan advance murni hanya dapat diposting bila policy sudah
`ACTIVE`, lalu mencatat debit Kas/Bank dan kredit Customer Balance Liability.

F3 postflight selanjutnya dikonfirmasi seluruhnya PASS. Preflight F4A juga
PASS: satu invoice tempo outstanding Rp133.500 siap menjadi fixture tanpa data
dummy. Migration `20260827130000` dan Backoffice reporting kini local-ready
untuk outstanding/aging as-of, Customer Statement, Excel export, serta guard
tanggal bisnis pembayaran tidak lebih awal dari order. Database rollout,
postflight, behavioral test, dan authenticated smoke masih manual; F4B posting
policy/closing regression belum dimulai.

Database yang sempat menjalankan build awal F4A wajib menerapkan forward-fix
`20260827131000` sebelum behavioral test. Fix menyamakan bentuk baris Invoice
dan Receipt pada Customer Statement; tidak mengubah transaksi atau saldo.

Forward-fix, postflight, dan behavioral F4A kemudian dikonfirmasi sukses oleh
user. F4B menjadi fase terakhir: preflight SELECT-only akan menilai mode
CONTROLLED/AUTOMATIC, queue, exception, event/journal coverage, dan rekonsiliasi
AR sebelum runtime policy dibuka.

Preflight F4B kemudian dinilai aman: 31 event/jurnal canonical sudah tertutup,
9 event `HOLD` menjadi backlog controlled queue, satu event `CANCELED` tetap
dikecualikan, dan lima Company masih `CONTROLLED`. Migration `20260827140000`
sekarang local-ready dengan queue `ALL_SUPPORTED`, policy Owner/Admin,
deferred automatic posting, retryable exception, serta UI Backoffice. Migration
tidak memposting backlog; postflight, behavioral test, controlled closure, dan
authenticated smoke masih manual.

Behavioral F4B dan migration policy kemudian berhasil, tetapi controlled live
queue KGS memposting 8 dari 9 event. Satu Sale TEMPO Rp133.500 gagal karena
runtime G6 lama menyamakan seluruh grand total dengan Payment aktual dan belum
membuat leg `CUSTOMER_RECEIVABLE` untuk unpaid/partial TEMPO. Forward-fix
`20260827141000` sekarang local-ready: ia memvalidasi Payment + piutang terhadap
grand total + surcharge, membuat debit AR berdimensi Customer, serta membackfill
interval mapping AR historis secara versioned/audited bila diperlukan. Ia
mempertahankan Cash/split/Return dan tidak mengubah event saat instalasi. Preflight, migration,
postflight, behavioral rollback, lalu controlled retry satu event masih manual;
mode `AUTOMATIC` tetap dilarang sebelum seluruhnya bersih.

User kemudian mengonfirmasi final controlled retry dan kedua postflight PASS:
40 event POSTED mempunyai 40 jurnal POSTED, satu Sale TEMPO mempunyai debit AR,
supported HOLD dan open exception nol, serta balance/duplicate/coverage bersih.
Database closure F4B dinyatakan PASS; yang tersisa hanya authenticated smoke
Cash/TEMPO/Receipt/report dan uji Automatic terbatas pada Company dummy.

## Update 2026-08-27 — Policy Surat Jalan Otomatis Local Ready

- Company dapat memilih di **Platform → Profil Perusahaan** apakah Surat Jalan
  hanya dibuat untuk transaksi `DELIVERY` atau untuk seluruh Sale baru yang
  `POSTED`. Default tetap `DELIVERY_ONLY`; histori tidak dibackfill.
- Surat Jalan Pickup menyimpan intent immutable dan memakai alur **Siap
  diserahkan → Sudah diserahkan**. Delivery tetap **Siap dikirim → Dalam
  perjalanan → Terkirim**.
- Migration additive `20260827153000` menjaga overload RPC lama, optimistic
  version, tenant/role guard, exact one-document-per-Sale, serta no-double-effect
  terhadap Stock, Payment, Financial Event, dan Journal.
- Backoffice lint dan production build PASS (76 route). SQL rollout dan smoke
  authenticated masih manual sesuai
  `docs/runbooks/COMPANY_AUTOMATIC_DELIVERY_DOCUMENT_POLICY_ROLLOUT.md`.
- User kemudian mengonfirmasi rangkaian SQL policy aman. POS kini membaca policy
  Company melalui RPC branding: transaksi baru otomatis mencentang **Perlu
  dikirim** saat mode `ALL_POSTED_SALES`, sementara draft existing tetap memakai
  intent tersimpan. Nilai opsional Customer yang tidak tersedia dibiarkan
  kosong. PWA lint dan production build PASS; smoke browser tetap manual.

## Update 2026-08-28 — ODR-4C Stock Request Projection Local Ready

- ODR-4B telah dikonfirmasi user seluruhnya `PASS`: demand mengikuti
  konfirmasi/pembatalan Order dan dibekukan saat sesi ditutup tanpa memutasi
  Stock Request, PO, Stock, atau Finance.
- ODR-4C local-ready memproyeksikan shortage reservasi sesi yang sudah ditutup
  menjadi satu Stock Request `SUBMITTED`, digabung per Product pada base UOM.
- Stock Request manual dan sumber legacy stok minus dipertahankan. Request baru
  memakai source `SALES_ORDER_RESERVATION`, tidak dapat dibatalkan manual, dan
  mempunyai lineage ke demand/reservation asal.
- Migration, postflight, behavioral test, serta manual smoke masih harus
  dijalankan user sesuai
  `docs/runbooks/ODR4C_SESSION_STOCK_REQUEST_PROJECTION.md`. Sinkronisasi Draft
  PO dan amendment PO final belum dibuka pada fase ini.

User kemudian mengonfirmasi migration, behavioral test, dan closing postflight
ODR-4C seluruhnya PASS. Runtime inventory masih nol karena belum ada sesi ODR
ber-shortage yang ditutup. ODR-4D dimulai sebagai preflight SELECT-only untuk
memisahkan quantity Draft PO yang sepenuhnya allocation-backed dari quantity
manual/campuran serta PO final. Belum ada runtime atau PO mutation baru.

Preflight ODR-4D kemudian dikonfirmasi tanpa blocker: 18 baris Draft PO legacy
seluruhnya allocation-backed, tetapi belum ada request/allocation ODR sehingga
tidak ada data existing yang perlu dimutasi. Foundation amendment additive
`20260828180000` local-ready dan zero-backfill; runtime Draft-PO sync tetap
menunggu closing test foundation.

User kemudian mengonfirmasi foundation amendment seluruhnya PASS dan tetap
zero-backfill. Runtime rekonsiliasi managed Stock Request `20260828190000`
local-ready: perubahan Order setelah sesi ditutup memperbarui request aktif dan
membentuk notice, tetapi belum mengubah PO. Baris kebutuhan nol dinonaktifkan
untuk menjaga lineage; reader Purchasing memfilter baris inactive.

User kemudian mengonfirmasi rekonsiliasi managed request seluruhnya PASS.
Sinkronisasi satu Draft PO `20260828200000` kini local-ready: hanya delta positif
ke satu target yang sepenuhnya allocation-backed dan valid secara UOM yang dapat
diubah atomik. PO final/ambigu/manual, Stock/FIFO/Movement, dan Finance tetap
tidak dimutasi. SQL rollout serta smoke Company dummy masih manual.

User kemudian mengonfirmasi migration, behavioral test, dan closing postflight
ODR-4E seluruhnya PASS. ODR-4 database gate selesai; dua Draft PO dan 17 PO
final existing tetap aman, tanpa open amendment. ODR-5 dimulai melalui preflight
SELECT-only `odr_phase5_finance_dispatch_payment_preflight.sql`. Audit ini
memetakan operasi Dispatch, payment intent, partial Dispatch, periode, akun,
dan jurnal historis; belum ada schema, event, posting runtime, atau UI Finance
ODR-5 yang diaktifkan.

User kemudian mengonfirmasi preflight ODR-5 tanpa blocker. Seluruh source live
ODR masih nol, queue aktif nol, accounting-period readiness bersih, dan histori
40 jurnal/21 event Sale tidak disentuh. Foundation additive zero-backfill
`20260828210000` kini local-ready: empat relation source/audit tertutup dari
browser, event catalog `SALE_DISPATCHED`/`SALE_PAYMENT_VERIFIED`, serta fungsi
akun `CUSTOMER_ADVANCE_LIABILITY`. Foundation belum membuat event, jurnal,
mapping COA, posting runtime, atau UI; rollout SQL masih manual mengikuti
`docs/runbooks/ODR5A_FINANCE_SOURCE_FOUNDATION.md`.

User mengonfirmasi closing postflight ODR-5A seluruhnya PASS: empat relation
RLS/browser-closed, empat trigger, dua event catalog, account function uang
muka, migration ledger, dan zero-backfill bersih; 40 jurnal historis tetap
utuh. ODR-5B dilanjutkan hanya sebagai preflight SELECT-only
`odr_phase5b_finance_mapping_runtime_preflight.sql` untuk memetakan akun per
Company, collision kategori, approved rule, dispatcher, dan controlled queue.
Belum ada event, jurnal, mapping, posting runtime, atau automatic posting baru.

Initial ODR-5B output tidak memiliki blocker: lima Company membutuhkan akun
Customer Advance dan kode default `2190` bebas collision. Empat Company tidak
memiliki system-owned COA/fallback untuk COGS, Inventory, Sales Revenue, serta
sebagian ROUNDING_GAIN. Sebelum membuat akun baru, audit reusable-rule
SELECT-only ditambahkan untuk mencari tepat satu account ID valid yang sudah
dipakai ACTIVE transaction rule. Ini mencegah duplikasi akun ekonomi; migration
mapping tetap belum dibuat sampai output audit ditinjau.

Audit reusable pertama terlalu ketat karena mendahulukan jumlah akun berlabel
system function secara global dan menghasilkan 16 ambiguity. Jurnal historis
tetap valid; resolver existing memakai exact event/category rule. Preflight
dikoreksi agar memilih rule `SALE_POSTED`/`SALE_PAYMENT`, lalu fallback, baru
satu system account. Tidak ada database mutation dari koreksi diagnostic ini.

Output reusable terkoreksi kemudian dikonfirmasi aman: seluruh mapping inti dan
conditional `PASS`; satu-satunya scope tersisa adalah provision akun
`2190 - Uang Muka Customer` pada lima Company. Foundation ODR-5B
`20260828220000` kini local-ready untuk membuat akun advance tersebut, dua
Transaction Category ODR, 17 exact mapping dan dua approved versioned Posting
Rule Set per Company. Migration tetap zero-runtime-effect: tidak membuat Event,
Journal, Stock, FIFO, Payment, atau memproses queue. Rollout manual mengikuti
`docs/runbooks/ODR5B_FINANCE_MAPPING_FOUNDATION.md`; automatic posting dan UI
ODR-6 tetap belum dibuka.

User kemudian mengonfirmasi behavioral dan closing postflight ODR-5B seluruhnya
PASS: lima akun Customer Advance, sepuluh category/rule set, 85 exact mapping,
zero Event/Journal effect, dan 40 jurnal historis tetap utuh. Gate aktif pindah
ke preflight SELECT-only ODR-5C
`odr_phase5c_dispatch_finance_runtime_preflight.sql`. Audit ini memeriksa exact
operation Dispatch, Invoice/SJ, allocation/Movement, actual FIFO cost, periode,
mapping dan controlled boundary sebelum source capture/Event runtime dibuat.

User kemudian mengonfirmasi preflight ODR-5C tanpa blocker. Migration
`20260828230000` kini local-ready: pengurangan Reservation/On Hand/FIFO/Movement
dan capture source Finance berada dalam satu transaksi; satu operation key
menghasilkan satu event `SALE_DISPATCHED` `HOLD`. Partial Dispatch memakai
alokasi komersial proporsional dan Dispatch final menutup residual; controlled
queue dapat membuat jurnal balance. Automatic posting, Payment verification
ODR-5D, serta UI ODR-6 tetap belum aktif. Rollout Supabase dan smoke masih
manual menurut `docs/runbooks/ODR5C_DISPATCH_FINANCE_RUNTIME.md`.

Closing postflight ODR-5C kemudian dikonfirmasi seluruhnya PASS dengan runtime
ODR masih nol dan 40 jurnal historis tetap utuh. Gate berikutnya adalah
preflight SELECT-only ODR-5D
`odr_phase5d_payment_verification_runtime_preflight.sql`: audit payment intent,
Payment Method/proof, total Order, exact mapping/rule, Customer Advance sebelum
Dispatch, Clearing/Piutang sesudah Dispatch, serta Cashier-session boundary.
Belum ada perubahan runtime, Event, Journal, automatic posting, atau UI pada
langkah ini.

Preflight ODR-5D kemudian dikonfirmasi tanpa blocker. Runtime payment
verification `20260828240000` kini local-ready beserta behavioral rollback,
postflight SELECT-only, dan runbook. Confirmed Order menangkap payment intent
immutable; Cash dicatat tepat sekali pada drawer; Finance verify/reject memakai
maker-checker; verified payment membuat satu HOLD Event yang diposting lewat
controlled queue. Payment internal-liability, automatic posting, dan aplikasi
pre-dispatch advance saat Dispatch tetap ditutup sampai gate berikutnya.

Closing ODR-5D kemudian dikonfirmasi seluruhnya PASS dengan runtime tetap nol.
ODR-5E `20260828250000` local-ready: Dispatch source yang baru dibuat akan
direbalance tepat sekali menggunakan surcharge immutable dan verified
pre-dispatch Customer Advance; residual tetap masuk Clearing/Piutang. Stock,
FIFO, Event, effect, dan audit berada dalam transaksi yang sama. Automatic
posting masih ditutup sampai ODR-5F closing reconciliation.

Closing ODR-5E kemudian dikonfirmasi seluruhnya PASS; tidak ada source, event,
jurnal, atau queue ODR parsial. ODR-5F `20260828260000` sekarang local-ready
untuk menyamakan hasil controlled/automatic dispatcher dan menormalkan event
tanpa efek. Seluruh Company existing tetap `CONTROLLED`; migration ini hanya
membuka switch policy yang harus dipilih eksplisit setelah behavioral dan
postflight PASS. UI/E2E ODR-6 belum aktif.

Closing ODR-5F kemudian dikonfirmasi seluruhnya PASS: Finance migration chain,
dispatcher parity, source/event/jurnal, exception, dan Advance ordering bersih;
semua lima Company tetap `CONTROLLED`. ODR-6 dimulai dengan preflight
SELECT-only untuk memeriksa canonical browser RPC dan memetakan cutover POS,
Inventory, Purchasing, Finance, serta Offline boundary sebelum frontend diubah.

Preflight ODR-6 telah dikonfirmasi tanpa blocker. ODR-6A POS Order cutover kini
local-ready: checkout online memakai Confirm Order canonical, daftar Order
aktif/terjadwal terpisah dari Draft, checkout Offline baru fail-closed, dan
cancel Order dilindungi migration `20260828270000` ketika Payment masih
`PENDING`/`VERIFIED`. Rollout Supabase dan authenticated PWA smoke masih manual;
Inventory/Purchasing/Finance UI belum dicutover pada tahap ini.

Authenticated smoke pertama menemukan snapshot Invoice/SJ Order terkonfirmasi
masih membawa nomor sementara `DRAFT-*`. Root cause adalah jalur ODR Confirm
melewati final-post legacy yang dahulu mengalokasikan nomor `INV-*`.
Forward-fix `20260828280000` sekarang local-ready: Reservation tetap dibuat
lebih dahulu, nomor Invoice final dialokasikan tepat sekali sebelum snapshot,
dan hanya snapshot `ORDER_CONFIRM` yang terdampak diperbaiki dengan audit.
Stock, FIFO, Payment, Event, Journal, dan status operasional Order tidak diubah.

Stock Real sebelumnya masih menampilkan placeholder `Reserved: Belum aktif`
meskipun Reservation backend sudah terbentuk. ODR-6B.1 Step 1 sekarang
local-ready melalui migration `20260829090000`: RPC Stock Real menghitung
Reserved Out dari Reservation `OPEN/PARTIALLY_DISPATCHED` dan Available sebagai
On Hand dikurangi Reserved. Backoffice menampilkan nilai tersebut secara nyata.
PWA juga tidak lagi memakai `product_stocks.stock_qty` sebagai ketersediaan;
RPC sesi-kasir menghitung Available dari seluruh Reservation aktif pada Gudang
yang sama melalui forward-fix `20260829100000`. Forward-fix dipisahkan karena
ledger `20260829090000` sudah pernah diterapkan tanpa RPC POS. Tahap ini belum
live sampai forward-fix, deploy kedua client, dan authenticated smoke selesai;
tidak ada mutation Stock/FIFO/Movement/Finance.

Pembatalan Sales Order lintas POS dan Backoffice sekarang **LOCAL READY** lewat
forward migration `20260830110000`. Kedua channel memakai composition canonical
yang melepaskan Reservation, membatalkan Surat Jalan linked, dan menyegarkan
demand Purchasing. Payment intent `PENDING` ikut dibatalkan; Cash pada sesi
terbuka mendapat reversal drawer idempotent. Payment `VERIFIED`, Cash dari sesi
tertutup, dan Order yang sudah Dispatch tetap fail-closed. Invoice snapshot
tidak dihapus: list/detail/export menampilkan status `Dibatalkan`, sedangkan
print/PDF memakai watermark. Rollout Supabase, deploy client, dan authenticated
smoke masih manual menurut
  `docs/runbooks/SALES_ORDER_CANCELLATION_INVOICE_SYNC.md`.

# POS Stock Opname Online UI (2026-09-02)

Blind count Stock Opname pada PWA **LOCAL-READY; SQL DAN STAGING SMOKE MASIH
MANUAL**.
Behavioral create pada stok minus menemukan constraint legacy yang menolak
snapshot stok sistem negatif. Forward-fix `20260902110000` mempertahankan
snapshot system/expected bertanda dan tetap melarang physical count negatif.
UI lazy-loaded menyediakan daftar sesi milik petugas, create/edit Draft, start,
count, movement-aware recount, review, partial complete, cancel, serta resume
setelah refresh. Counter dapat melihat kembali hitungannya sendiri pada sesi
yang sama untuk koreksi typo. Stok sistem, expected, variance, FIFO, HPP, nilai,
dan hasil sesi lain tetap tersembunyi. Baris yang tidak dihitung menjadi
`SKIPPED`, tidak dianggap nol, dan tidak masuk Adjustment.

Migration additive `20260902100000` menambahkan workspace, `20260902110000`
mendukung snapshot stok negatif, dan `20260902120000` menambah owner review
serta partial completion eksplisit. Tidak ada backfill saldo dan hanya line
`COUNTED` yang dapat masuk posting Adjustment. Status belum live sampai seluruh
behavioral rollback, Supabase postflight, dan authenticated staging smoke pada
[`docs/runbooks/POS_STOCK_OPNAME_ONLINE_UI_ROLLOUT.md`](docs/runbooks/POS_STOCK_OPNAME_ONLINE_UI_ROLLOUT.md)
seluruhnya PASS.

# Sales Order revision (2026-09-03)

Revisi Order sebelum Dispatch telah terpasang pada database user dan structural
postflight awal PASS. Authenticated UAT kemudian menemukan
`IDEMPOTENCY_PAYLOAD_CONFLICT`: operation UUID yang sama dipakai oleh cancel
source dan confirm replacement pada satu composition. Forward-fix
`20260903120000` sekarang **LOCAL-READY / MANUAL SUPABASE ROLLOUT PENDING**.
Fix hanya memberi dua child idempotency key deterministik; root Revision Apply,
lineage, optimistic version, rollback atomik, Reservation, Invoice/SJ, Payment,
Purchasing, dan Finance boundary tetap dipertahankan. Urutan manual ada di
[`docs/runbooks/SALES_ORDER_REVISION_ROLLOUT.md`](docs/runbooks/SALES_ORDER_REVISION_ROLLOUT.md).

Authenticated revision juga menemukan `TEMPO_TRANSACTION_DATE_FUTURE` ketika
timestamp Order yang disalin mempunyai jam lebih maju pada tanggal bisnis
Company yang sama. Forward-fix `20260904110000` sekarang **LOCAL-READY / MANUAL
SUPABASE ROLLOUT PENDING**. Validator membandingkan tanggal bisnis Company,
bukan jam mentah; future-date scheduled, periode, due date, delivery date,
atomic revision, serta seluruh Stock/Finance boundary tetap dipertahankan.

Audit berikutnya menemukan tanggal Invoice replacement pada mode `ORDER_DATE`
dapat bergeser ke waktu Draft revisi dibuat. Forward-fix `20260904130000`
sekarang **LOCAL READY / MANUAL SUPABASE ROLLOUT PENDING**: revision start
menyalin kembali tanggal bisnis dan provenance source ke replacement serta
payload canonical. Waktu create/post, nomor Invoice/SJ replacement, Stock,
Reservation, Payment, Dispatch, dan Finance tidak diubah. Invoice final lama
tidak dibackfill; authenticated smoke dua mode tanggal masih wajib.

Audit read-only berikutnya membuktikan Order Scheduled dapat mempunyai waktu
header lama dan `plannedOrderAt` berbeda. Untuk `ORDER_DATE`, planned date adalah
authority; mengarahkan validator ke header saja akan membuat Invoice salah.
Forward-fix `20260904140000` sekarang **DATABASE LIVE / BEHAVIORAL TEST RERUN
PENDING**: Scheduled memakai planned date, sedangkan Immediate/Backorder memakai
canonical header date; revision runtime dan pembuat snapshot Invoice baru memakai
resolver yang sama, sementara timing metadata/provenance dipertahankan atomik.
Ordinary TEMPO dan seluruh efek Stock/Finance tidak berubah, dan periode
effective Order date tetap wajib `OPEN/REOPENED`. Behavioral test awal gagal
karena assertion menginspeksi implementasi wrapper lama; assertion tersebut
diganti dengan pemeriksaan nilai bisnis tanpa mengubah migration yang sudah live.

# Backoffice Quotation/SO Development Pilot (2026-09-09)

Alur Quotation/SO kantor sekarang memiliki full-page document form yang
mengikuti pola kerja Odoo terbaru tanpa menampilkan field yang belum didukung
MADS: action/status bar, Customer dan tanggal di header, Order Lines, Informasi
Lainnya, serta Catatan. Warehouse terisi otomatis dari default Company dan
tetap dapat dioverride sebelum konfirmasi. Default hanya dapat diatur Super
Admin; server menolak Warehouse non-sales, beda tenant, atau tidak sesuai
Store.

Statusnya **DATABASE LIVE PADA ISOLATED DEVELOPMENT SAJA / CLIENT LOCAL READY**.
Migration, rollback behavioral, postflight, lint, dan guarded build PASS;
production serta staging lama tidak disentuh. Confirm pada fase ini masih hanya
membentuk SO: Reservation, Delivery Order, Invoice, Payment, Stock/FIFO, dan
Finance belum aktif. Authenticated visual smoke dan UAT masih wajib sebelum
pengembangan fulfillment dimulai.

Forward migration `20260909110000` kemudian mengoreksi gap pajak pada pilot:
Quotation/SO Backoffice sekarang memakai resolver dan grouped calculator pajak
Sales canonical yang sama dengan POS, menyimpan snapshot rule/rate/base/amount,
dan mempertahankan harga Sales inclusive. Order Lines UI menampilkan Product,
Description, Qty, UOM, Unit Price, Taxes, dan Amount; ringkasan detail
memisahkan DPP dan pajak termasuk tanpa menambah pajak dua kali. Behavioral
rollback, postflight, scoped lint, dan guarded build PASS pada Development;
authenticated visual smoke tetap pending.

Cutover dua arah saat ini berada pada **STEP 1E-A/6 — DATABASE LIVE +
BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS** di isolated Development. Preflight aktual telah
dikonfirmasi user: seluruh dependency/mapping PASS, runtime candidate/plan nol,
dan open procurement terbukti masih memerlukan upgrade fail-closed. Paket lokal
`20260910140000` telah mengubah candidate tersebut menjadi `BLOCKED` tanpa Apply RPC,
conversion dokumen, mode switch, atau mutation data operasional. Urutan manual ada di
[`docs/runbooks/SALES_PROCESS_CUTOVER_APPLY_ROLLOUT.md`](docs/runbooks/SALES_PROCESS_CUTOVER_APPLY_ROLLOUT.md).

Gate **STEP 1E-B1/6 — DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS** menambahkan parity ongkir pada
Quotation/SO dan Regular Invoice Backoffice. Ongkir otomatis dialokasikan ke
Invoice pertama, tetap editable sebelum posting dengan aggregate cap, dilepas
saat Draft Invoice dibatalkan, dilarang pada DP, dan diposting terpisah ke
canonical `DELIVERY_FEE_REVENUE`. POS Retail serta Stock/Reservation/DO/FIFO/
COGS/Payment tidak berubah. Migration awal sudah live pada isolated Development;
behavioral awal menemukan pelanggaran immutable audit; forward-fix `151000`
kemudian dijalankan dan seluruh gate dikonfirmasi PASS. Production/staging tidak disentuh;
urutan manual tersedia di
[`docs/runbooks/BACKOFFICE_SALES_DELIVERY_FEE_PARITY_ROLLOUT.md`](docs/runbooks/BACKOFFICE_SALES_DELIVERY_FEE_PARITY_ROLLOUT.md).

Launcher isolated Backoffice Sales kini memprioritaskan API key legacy bernama
`service_role` untuk kontrak environment `SUPABASE_SERVICE_ROLE_KEY`, lalu baru
fallback ke key bertipe `secret`. Verifikasi 2026-09-11 pada Development
`fkywtxucmyjvpwdiqpix` membuktikan publishable key dan legacy service-role
diterima, sedangkan `default/secret` ditolak `Invalid API key` pada call chain
PostgREST yang sama. Perubahan hanya memengaruhi launcher lokal; database,
production, staging lama, dan business flow tidak diubah.

## Purchase Order full-document workflow (2026-09-14)

Purchase Order Backoffice kini membuka halaman dokumen penuh dari tabel PO,
bukan expanded group. Halaman memakai runtime Purchase existing untuk Edit PO
sebelum Receipt/Bill, Terima Barang melalui Goods Receipt, dan Buat/Lihat Bill
melalui Supplier Invoice. Product serta gudang sumber shortage tetap menjadi
lineage immutable; Supplier, tanggal rencana, catatan, UOM, Qty, harga estimasi,
dan gudang penerimaan per line dapat direvisi secara idempotent sebelum proses
penerimaan atau tagihan dimulai. Migration `20260914170000` beserta behavioral
dan postflight sudah PASS pada isolated Development; client lint, TypeScript,
dan production build 84 route juga PASS. Status client masih **LOCAL READY**;
authenticated UI smoke/UAT dan production rollout belum dilakukan.

# Negative-stock FIFO cost settlement (2026-08-31)

Kontrak koreksi biaya stok minus dan Supplier Invoice sudah dikunci; diagnostic
NSC-0 live telah ditinjau tanpa blocker dan tanpa variance historis nonnol.
NSC-1..3 menyediakan foundation cost source, Goods Receipt provisional-cost
settlement (termasuk receipt nilai nol), Supplier Invoice FIFO revaluation,
serta split Inventory/COGS bersama behavioral rollback dan postflight. Lihat
[`docs/runbooks/NEGATIVE_STOCK_FIFO_FINANCE_COST_SETTLEMENT.md`](docs/runbooks/NEGATIVE_STOCK_FIFO_FINANCE_COST_SETTLEMENT.md).

Rollout manual NSC-1..3 kemudian dikonfirmasi user: foundation dan runtime
postflight seluruhnya `PASS`, termasuk private boundary dan zero-value negative
receipt contract. Runtime live masih memiliki 49 negative allocation terbuka,
sedangkan cost source/batch plan baru masih nol. Status saat ini **runtime
installed / authenticated operational smoke pending**; belum boleh dianggap
closure FIFO–GL sampai ada Dispatch minus → Goods Receipt → Supplier Invoice
variance yang benar-benar diproses melalui controlled queue.
