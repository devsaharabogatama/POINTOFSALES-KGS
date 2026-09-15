# Office procurement recovery - release candidate 2026-09-16

## 2026-09-16 - Production database PASS, user Git delivery pending

User Production runtime/ACL postflight25 PASS, six migration ledger entries.
Legacy reconciliation matches16 previous closing table results; cashier109
already documented (historical full109 digest not captured). UI deployment,
authenticated recovery smoke and UAT remain pending, not database-install gates.
[Scoped commit/push script](../../scripts/commit-push-office-recovery.ps1):
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
[preflight](../../supabase/diagnostics/office_procurement_recovery_release_preflight.sql),
[transaction fingerprints](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql),
[updated atomic installer](../../supabase/releases/office_procurement_recovery_install.sql),
[updated postflight](../../supabase/diagnostics/office_procurement_recovery_release_postflight.sql),
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

[Read-only live diagnosis](../../supabase/diagnostics/office_procurement_recovery_runtime_drift_diagnosis.sql) returns one result set:
15 expected/actual hashes, missing functions, LF comparison, CR counts, ledger
and session metadata. Clone run exit0:15 MATCH +2 INFO. No runtime/DDL or stock,
reservation, FIFO, payment, cashier-session, Finance or audit mutation in this fix.
No privileged credentials logged; no CLI/environment/Production link changed.
Next safe step: obtain complete Production diagnosis, confirm rollback/install
state, then inspect actual discrepancy before any functional installer patch.
Keep historical tests intact; no reset, ledger insertion or guard bypass.


## Status yang benar-benar terbukti

LOCAL READY: SQL, reader/API/UI, scoped eslint, TypeScript dan Next production build exit0.
DATABASE LIVE: enam migration baru hanya di clone idrufihckscppsyclmsu.
CLIENT DEPLOYED: belum untuk paket ini. SMOKE PASS (authenticated HTTP/browser) dan UAT PASS: belum.
Production nbxjslqojexjfogamnjt tidak diubah agent; sembilan order lama belum dinyatakan berhasil dipindahkan.
Ini paket siap instalasi terkontrol, bukan klaim production sudah sehat atau jaminan tanpa error.

## Perubahan dan compatibility

- Link immutable menyambungkan Retail source, demand/request lama dan target SO.
- Source Retail ditutup melalui converter canonical; SO, Reservation dan DO dibuat,
  tanpa menduplikasi Stock Request lama. On Hand/FIFO/payment/Finance tidak di-reset.
- Revisi sebelum dispatch mempertahankan ID/no SO, Reservation, initial DO.
  Mutable child plans direkomposisi; before/after lengkap dicatat immutable.
  Dispatch, invoice/receipt/discrepancy yang sudah memakai line menolak revisi biasa.
- Kebutuhan procurement dibatasi shortage asal. Pengurangan/cancel satu SO tidak
  melepaskan kebutuhan SO/order lain yang berbagi request. PO final dan allocations
  tetap; selisih masuk amendment canonical, bukan edit PO final.
- Recovery eksplisit untuk item KEPT solely OPEN_PROCUREMENT pada plan APPLIED.
  Historical plan/item/KEEP_ITEM tidak ditulis ulang; APPLY_ITEM recovery ditambahkan.
  Current versions, Company mode, actor, retry dan eligibility diperiksa server.
- Pengaturan proses penjualan existing mendapat tombol Pindahkan ke Office.
  Source dan SO memakai document log existing dengan link timbal balik.
  Tidak menambah tab Invoice atau mengganti template/settings Company.
- Linked Office order dengan procurement unreleased tetap BLOCKED pada reverse.
  Ordinary reverse tetap melalui flow existing; ownership transfer tersebut bukan
  fitur yang diam-diam dibuka dalam patch ini.

## Evidence clone

Enam migration freshly installed individual dan kemudian diuji sebagai satu runtime:
15140000,15141000,15142000,16100000,16101000,16102000 (prefix tanggal202609).
12 behavioral files exit0, fixture canonical nonzero dan BEGIN/ROLLBACK:

1. sales_cutover_procurement_lineage_behavior.sql
2. sales_cutover_procurement_retention_behavior.sql
3. office_pre_dispatch_fulfillment_delta_behavior.sql
4. office_retained_shared_request_behavior.sql
5. office_retained_open_session_behavior.sql
6. office_retained_final_po_behavior.sql
7. retained_order_recovery_behavior.sql
8. sales_process_cutover_retail_to_backoffice_converter_behavior.sql
9. sales_process_cutover_backoffice_to_retail_converter_behavior.sql
10. sales_process_cutover_atomic_apply_behavior.sql
11. backoffice_sales_order_invoice_status_rehearsal_behavior.sql
12. purchase_bill_payment_clone_e2e_behavior.sql

Matrix: open/closed session, shared Retail/Office request, two recovered SOs,
committed final PO, real partial/full dispatch, pending/posted invoice and
DP/payment regression, denied actor/tenant, exact retry/payload conflict, stale
version, Warehouse opt-out failure with atomic state restoration.
Concurrency: two live connections; holder locks Company mode/cutover, actual
public Recovery contender receives lock timeout55P03. This proves serialization,
not two successful simultaneous recovery mutations. Retry behavior tested separately.
Fixture writes roll back; PostgreSQL sequences may advance despite rollback.

Release preflight: 8 PASS /1 INFO on installed clone.
Release postflight: 25 PASS, one complete result set, covering15 exact function
fingerprints, ledger, public/private ACL, RLS/table privileges and target references.
Zero persisted recovery rows are not behavior evidence.
Atomic installer re-entry exit0; dynamic multi-statement parser proof exit0.
Read-only snapshots immediately before/after clone installer re-entry: all17
protected table counts and whole-row digests identical. Six bundled source bodies
match their migration sources exactly (excluding outer BEGIN/COMMIT); PASS.
Fresh combined-bundle installation was NOT replayed on a reset clone. Fresh individual
migration installs plus exact source-body packaging and final runtime verification
are the installation evidence; no new clone/reset/history rewriting was performed.

Client: eslint five modified files exit0; tsc --noEmit exit0; npm build exit0,
84 static pages. Build used process-only isolated-development URL and non-access
placeholder keys: compile/prerender evidence only, not authenticated connectivity.
Development launcher stopped403 retrieving development keys from clone account;
no login/link/env file was changed to bypass it.

Corrections recorded: real JSON-null/SQL-NULL preservation bug fixed additively;
initial generated SQL terminator corrected after transactional rollback; canonical
fixture Company mode/date corrected without relaxing guards. Final-PO test assertion
used nonexistent reason_code, corrected to actual reason after schema audit.
An inline parser command had PowerShell dollar-quote escaping error; replaced by
file-backed rollback parser test. Postflight consolidated into ONE result set.
No immutability, payment or stock guard was disabled.

## Manual installation - SQL Editor Production only

1. Confirm dashboard project nbxjslqojexjfogamnjt. Retain a current recoverable backup.
   Coordinate a short mutation pause for POS/Office/Purchase and background jobs;
   do not delete sessions, drafts, transactions or queues to get PASS.
2. Run entire [release preflight](../../supabase/diagnostics/office_procurement_recovery_release_preflight.sql).
   PASS/INFO and fresh SETUP are allowed. BLOCKER: stop. Partial REVIEW: investigate
   installed prefix and guards; do not insert ledger entries manually.
   Existing open preview must be cancelled through its normal authorized UI.
3. Capture/save entire [transaction fingerprints](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql)
   before installation. This query returns17 protected transaction tables.
4. Run entire [atomic installer](../../supabase/releases/office_procurement_recovery_install.sql).
   This replaces running six files separately. Do NOT rerun previous90 files.
   BEGIN/COMMIT wraps all missing migrations; own guards remain and final exact
   function comparison aborts on drift. No recovery/backfill operation runs here.
5. Run entire [release postflight](../../supabase/diagnostics/office_procurement_recovery_release_postflight.sql).
   Expect25 PASS. Rerun/save transaction fingerprints BEFORE any recovery.
   Under mutation pause all17 counts/digests must equal the pre-install capture.
   Differences require tracing; never delete/reset/replace data to match.
6. User commit/push/redeploy Backoffice code only after database checks pass.
   Keep existing Vercel Production Supabase environment unchanged.
   See file allowlist below; never git add . or include dummy/bootstrap operations.
7. Log in as real Super Admin. Select KMS, then Sales module/process settings.
   Read current retained-order candidates and click Pindahkan ke Office explicitly.
   Do NOT re-Apply the old APPLIED plan or call private converter from SQL Editor.
   Each recovery revalidates current source/settings versions and eligibility.
   Repeat for LSM only after first recovery smoke is sound. Prior CSV counts4/5
   are historical: new dispatch/payment/revision can change live eligibility.
8. Verify new SO is visible, source is no longer active, both logs link correctly.
   Refresh/revisit SO link; no duplicate target on retry. Old request IDs and
   shared obligations remain; stock/FIFO/payment/journal have no fake postings.
   Confirm ordinary allowed revision/cancel, actual warehouse dispatch/receive,
   invoice creation/posting/payment as appropriate using approved genuine records.
   Other role/company cannot recover; ordinary Retail and Purchase still work.
9. Save smoke outcomes and rerun postflight. Only then mark CLIENT DEPLOYED,
   SMOKE PASS and UAT PASS. Release normal operation after the agreed checks.

Do not run owned behavioral fixtures/bootstrap seeds on Production.
If install errors, transaction rolls back all additions in that attempt. Stop and
retain error/output; investigate drift against actual definitions. If SQL Editor
leaves an aborted transaction session, end it with ROLLBACK before further reads.
After committed recovery do not rollback by deleting SO/links/audits or reviving
source. Stop further recovery and use additive forward-fix/canonical correction.
Client revert may hide Recovery, but must not revert completed business operations.

## Commit allowlist

Client:
- backoffice/src/app/api/platform/sales-process-cutover/route.ts
- backoffice/src/app/page.tsx
- backoffice/src/components/BackofficeSalesOrderView.tsx
- backoffice/src/components/SalesDocumentView.tsx
- backoffice/src/components/SalesProcessCutoverSettings.tsx

SQL: the six migration files; office_procurement_recovery_install release file;
lineage/retention/delta/recovery/release diagnostics and corresponding tests;
modified legacy reverse and invoice-status rehearsal fixture tests.
Documentation: README.md, docs/README.md, ACTIVE_DEVELOPMENT_HANDOFF.md,
SALES_ORDER_DUAL_INVOICE_PROCESS_NOTES.md, retained-procurement impact audit,
SALES_CUTOVER_PROCUREMENT_RECOVERY.md and this report.
Review git diff and git diff --cached before committing. Leave unrelated
HR_MODULE_PRODUCT_NOTES and all bootstrap/enable/seed operations untouched.

## Remaining gates, not additional development assumptions

Production live preflight/fingerprint equality, user deployment, authenticated
HTTP/browser smoke and UAT are manual and not established by clone PASS.
The actual retained Production candidates may legitimately fail current canonical
eligibility; preserve the error and audit live facts instead of bypassing it.
