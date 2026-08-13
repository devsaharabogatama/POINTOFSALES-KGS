# G6 Finance Corrective Recovery Plan

**Status:** ACTIVE CORRECTIVE GATE  
**Tanggal:** 2026-08-10  
**Boundary:** Finance posting baru tetap tertutup sampai gate berikut lulus
berurutan.

## Alasan koreksi

Draft implementasi G6 sebelumnya ditolak dari jalur rollout karena:

- menghapus jurnal `JRN-%` dan mengubah event `POSTED` menjadi `HOLD`;
- memberi `authenticated` akses ke `SECURITY DEFINER` Finance tanpa pemeriksaan
  active Company dan role;
- mengubah arti tabel canonical `transaction_account_rules`;
- memakai akun/nominal fallback yang menebak data Finance;
- tidak mempunyai transaction wrapper, migration ledger, checksum manifest,
  forward-fix boundary, dan tenant-negative test memadai;
- mengklaim `COMPLETE` sebelum rollout dan regression live.

Artifact tersebut tidak boleh dijalankan. Jika preflight menemukan salah satu
version draft sudah applied atau object-nya sudah hidup, hentikan dan buat
forward fix berdasarkan live-state. Jangan menghapus jurnal atau mengedit
migration yang sudah applied.

## Keputusan bisnis yang dipertahankan

- Supplier Invoice tolerance bersifat opsional. Tanpa policy, selisih nilai
  boleh diterima sebagai `WITHIN_TOLERANCE`, tetapi selisih tetap disimpan dan
  quantity wajib berasal dari Goods Receipt eligible.
- Setiap Company diperlakukan seperti aplikasi Finance terpisah dalam satu
  database: data, rule, journal, period, report, dan mutation selalu
  tenant-scoped.
- Missing/ambiguous mapping harus `HOLD/ERROR`; sistem tidak menebak akun atau
  nominal.
- Jurnal posted immutable. Koreksi hanya reversal/replacement append-only pada
  period yang sah.

## Urutan corrective phases

### Corrective Phase 0 — quarantine dan status repair

- keluarkan draft migration/postflight/test G6 yang ditolak dari jalur rollout;
- tutup endpoint/UI posting otomatis;
- pulihkan Finance UI ke journal read-only existing;
- perbaiki README, handoff, gate, dan migration manifest.

Exit: tidak ada file rollout berbahaya atau klaim G6 complete.

### Corrective Phase 1 — live-state preflight (`USER-VERIFIED PASS`)

Jalankan `supabase/diagnostics/g6_phase1_posting_engine_preflight.sql`.

Audit minimum:

- dependency dan ledger version;
- apakah draft G6 pernah terpasang sebagian;
- requiredness/history guard canonical transaction rule;
- privilege RPC/table Finance;
- event-journal tenant/source integrity;
- duplicate/unbalanced/orphan history;
- current COA/rule/fallback readiness;
- runtime schema inventory tanpa mutation.

Live preflight pertama menemukan 10 routine rejected/legacy masih executable
oleh `authenticated`, sementara seluruh journal/tenant/canonical-rule check
lain PASS. Corrective migration `20260810170000` hanya mencabut privilege
`PUBLIC`/`anon`/`authenticated`, mempertahankan `service_role`, dan tidak
menghapus routine atau memproses event HOLD. Rerun preflight wajib nol blocker.

Exit: seluruh `BLOCKER` nol atau tersedia forward-fix khusus live-state.

### Corrective Phase 2 — tenant-safe journal foundation (`COMPLETE; USER VERIFIED`)

Phase 1 sudah ditutup user tanpa blocker. Sebelum DDL, jalankan
`g6_phase2_journal_foundation_preflight.sql` karena live database memiliki
object period/line parsial yang tidak boleh dianggap canonical hanya dari
namanya. Scope sesudah live-state direview:

- accounting period per Company, tidak auto-open secara diam-diam;
- canonical journal header/line dengan tenant composite FK;
- immutable posted history dan official reversal link;
- private posting core;
- public RPC hanya Finance/Company Admin/Super Admin, active Company wajib sama;
- transaction, migration guard, ledger, manifest checksum, postflight,
  rollback-safe behavior, dan cross-Company negative test.

Live-state dan focused contract diagnostic sudah dikonfirmasi PASS. Migration
`20260810180000` mempertahankan `accounting_periods.start_date/end_date`, tidak
memakai rejected `journal_lines`, dan membuat canonical additive
`finance_journals`/`finance_journal_lines`/audit. User mengonfirmasi migration,
postflight, dan behavioral test seluruhnya PASS pada 2026-08-10.

Belum membuka automatic posting bila mapping belum lengkap.

### Corrective Phase 3 — versioned posting mapping (`COMPLETE; USER VERIFIED`)

Phase 3 telah ditutup setelah preflight, ownership correction, mapping
migration, postflight, dan corrected rollback-safe behavioral test seluruhnya
dikonfirmasi user PASS. Output source amount key, required Account Function,
rule/fallback, dan compatible COA menjadi dasar tanpa menebak nominal atau akun.

Live output menemukan 34 required mapping pada 25 Category, 52 event-function
row pada 26 event HOLD, dan seluruh 16 Company–Function mempunyai compatible
candidate. Gate explicit pertama terlalu ketat karena menganggap beberapa akun
ber-tag fungsi yang sama selalu ambigu. Rollout local-ready
`20260810190000` memperketatnya lagi: provisioning mengutamakan tepat satu akun
system-owned dengan `system_function_key` identik; bila tidak ada akun sistem,
tepat satu akun explicit dapat dipakai. Provisioning tidak pernah memilih akun
hanya dari tipe kompatibel. Gate berhenti bila hasil tetap ambigu. Preflight
menampilkan function key serta jumlah kandidat
system/explicit bila blocker masih ada. Model
header/line/audit serta guarded Draft/Approve dibuat, tetapi expression belum
dieksekusi dan event HOLD belum disentuh.

Live rerun kemudian membuktikan lima function masing-masing mempunyai dua akun
system-owned karena COA Company pernah diimport langsung sebagai akun sistem.
Keputusan user: seed minimum COA tetap system-owned, sedangkan akun import tetap
menjadi Company-owned. Forward fix `20260810185000` melakukan reclassification
flag secara audited tanpa mengubah UUID/kode/nama/function/history dan menjadi
dependency wajib sebelum `20260810190000`.

User mengonfirmasi forward fix, postflight, behavior, dan closing preflight
sukses. Dependency serta explicit account scope sekarang PASS; 34 required
mapping dan 52 event-function row menjadi controlled backfill Phase 3, sedangkan
26 event HOLD tetap tidak diproses.

- pertahankan arti canonical `transaction_account_rules`;
- kebutuhan debit/credit/amount expression memakai model baru yang versioned,
  approved, effective-dated, audited, dan terhubung ke Transaction Category,
  System Event, serta Account Function;
- tidak ada universal first-account fallback atau nominal default;
- mapping missing/ambiguous masuk posting exception queue.

### Corrective Phase 4 — single-event posting engine (`COMPLETE; USER VERIFIED`)

Status aktif: preflight SELECT-only dikonfirmasi user seluruhnya aman. Rollout
local-ready melalui migration `20260810200000`, postflight, behavioral test,
dan runbook Phase 4. Engine awal sengaja dibatasi ke kontrak paling eksplisit
`STOCK_OPENING`: dokumen sumber dan total cost divalidasi, lalu debit Inventory
Asset harus sama dengan credit Opening Balance Clearing. Unsupported event tetap
HOLD dan masuk exception; migration tidak memproses event existing.

User kemudian mengonfirmasi migration, postflight, dan behavioral test Phase 4
seluruhnya PASS. Engine single-event siap sebagai dependency queue, tetapi
historical HOLD tetap belum diproses.

- row lock dan exact idempotency;
- payload/schema resolver per source event;
- balanced line set divalidasi sebelum satu row jurnal ditulis;
- source/version/account snapshots;
- locked/backdated period mengikuti approved prior-period contract;
- event hanya `POSTED` setelah jurnal lengkap committed.

### Corrective Phase 5 — controlled queue dan historical backfill (`DATABASE COMPLETE; LIVE RUN PENDING`)

Diagnostic SELECT-only
`supabase/diagnostics/g6_phase5_controlled_queue_preflight.sql` memetakan
historical HOLD yang benar-benar didukung engine Phase 4, source/rule/period,
Company scope, existing exception, browser boundary, serta expected queue
schema/RPC. Diagnostic tidak menjalankan resolver atau memproses event.

Live output dikonfirmasi user tanpa blocker/review: satu `STOCK_OPENING` pada
satu active Company siap controlled backfill; source, approved rule, period,
identity, privilege, dan early-journal guard seluruhnya PASS. Sebanyak 25 event
dari sembilan contract lain tetap `DEFERRED`.

Migration `20260810210000` menambah queue run/item/audit, single-active-Company
guard, immutable preview hash/version/source snapshot, explicit approval,
per-event subtransaction isolation, exception capture, exact Phase-4 posting
authority, RLS, dan browser write closure. Migration tidak membuat run dan
tidak memproses event existing. Postflight, rollback-safe behavior, dan rollout
runbook local-ready; manual Supabase rollout menunggu user.

User kemudian mengonfirmasi migration, postflight, dan behavioral test Phase 5
seluruhnya sukses. Queue database/runtime ditutup `USER VERIFIED`, tetapi satu
historical `STOCK_OPENING` live sengaja tetap HOLD karena rollout runbook
melarang pemrosesan sebelum closing review. Ini adalah pending controlled run,
bukan kegagalan migration.

- queue selalu satu active Company per request;
- tidak ada nullable Company untuk browser/operator;
- failure per event tercatat tanpa partial journal;
- historical HOLD dipreview dan disetujui sebelum batch;
- tidak pernah menghapus jurnal lama atau mengubah `POSTED` menjadi `HOLD`.

### Corrective Phase 6 — reports dan reconciliation (`PHASE 6B ACTIVE PREFLIGHT`)

Diagnostic SELECT-only
`supabase/diagnostics/g6_phase6_reporting_reconciliation_preflight.sql`
mengaudit POSTED-only ledger, timezone/cut-off, period/prior-period, report dan
reconciliation schema/RPC, Stock FIFO versus Inventory GL, Supplier AP versus
GL, Customer Balance versus GL, serta operational pending exposure. Diagnostic
tidak memproses HOLD atau membangun cache/report.

- GL, Trial Balance, P&L, Balance Sheet, AR/AP, Customer Balance, Stock/FIFO;
- tenant/role enforced di RPC, bukan hanya menu/API;
- drill-down source dan pending/error analysis;
- report baru dibuka setelah reconciliation fixtures lulus.

Live output telah direview tanpa `BLOCKER` atau `REVIEW`. Nilai FIFO
Rp84.710.000 sementara Inventory GL masih nol karena belum ada canonical
journal `POSTED`; satu supported historical `STOCK_OPENING` tetap `HOLD` dan
25 event dari sembilan contract lain tetap `DEFERRED`. Kondisi ini merupakan
controlled backfill scope, bukan izin membuat jurnal penyeimbang manual.

Phase 6A lokal tersedia melalui migration `20260810220000`, postflight,
rollback-safe behavioral test, dan rollout runbook. Scope hanya Trial Balance
dan General Ledger dari canonical journal `POSTED`, dengan active-Company,
Finance-role, timezone, filter Store/Gudang, version metadata, source
drill-down, pagination, RLS, serta immutable report history. P&L, Neraca,
pending analysis, reconciliation mutation, export worker, UI, live queue run,
dan unsupported event tetap tertutup sampai gate berikutnya.

User telah mengonfirmasi migration, postflight, dan behavioral test Phase 6A
seluruhnya PASS. Phase 6B dimulai dengan diagnostic SELECT-only khusus sebelum
controlled live run: source/rule/period, active queue, open exception, report
runtime, browser boundary, dan baseline FIFO–Inventory GL diperiksa kembali.
Live queue tetap belum boleh dijalankan sampai output Phase 6B bebas
`BLOCKER`/`REVIEW` dan direview.

User kemudian mengirim output Phase 6B tanpa blocker/review: satu historical
`STOCK_OPENING` Rp450.000 mempunyai source/rule/period valid, tanpa queue,
journal, atau exception awal. Controlled operation dikunci ke snapshot tersebut
dan harus diikuti closing postflight. FIFO Rp84.710.000 tidak akan langsung
reconcile karena 25 event dari sembilan contract lain masih HOLD/deferred;
selisih sesudah posting bukan alasan membuat jurnal manual.

Controlled operation dan closing postflight kemudian dikonfirmasi user PASS:
queue final `COMPLETED` dengan satu posted item, event/journal/amount/function
coverage tepat, tanpa duplicate atau exception, serta dua report line live.
Inventory GL sekarang Rp450.000 dan FIFO Rp84.710.000; sisa Rp84.260.000 tetap
deferred. Phase 6C berlanjut melalui SELECT-only audit P&L, Neraca, pending-event
analysis, dan reconciliation summary tanpa membuka resolver event baru.

Phase 6C preflight kemudian dikonfirmasi tanpa blocker/review: live POSTED
fixture seimbang, Neraca equation valid, timezone/privilege/quarantine aman,
sedangkan empat report/RPC dan dua reconciliation relation merupakan expected
setup. Rollout `20260810230000` local-ready untuk POSTED-only P&L/Neraca,
pending exposure yang eksplisit bukan laporan keuangan, serta current-only
FIFO/AP/Customer Balance reconciliation tanpa auto-adjustment. Historical
subledger snapshot ditolak daripada menghasilkan angka rekonstruksi palsu.

User mengonfirmasi migration, postflight, dan rollback-safe behavior Phase 6C
seluruhnya PASS pada 2026-08-11. Phase 6C ditutup `COMPLETE; USER VERIFIED`.

Phase-7 operations/pilot preflight kemudian dikonfirmasi tanpa
`BLOCKER`/`REVIEW`. Canonical schema/RPC, period, queue, journal integrity, dan
browser boundary PASS. Expected gap adalah reversal runtime `SETUP` serta satu
Company perlu Finance operator dan Company Owner/Admin approver (`BACKFILL`).
25 HOLD/sembilan contract dan selisih FIFO–GL Rp84.260.000 tetap deferred.

Corrective Phase 7A sekarang local-ready melalui migration `20260811090000`.
RPC reversal bersifat append-only, tenant/role/period-aware, exact-idempotent,
dan hanya menerima jurnal `MANUAL`/`OPENING_BALANCE`. Jurnal otomatis tetap
source-controlled agar reversal Finance tidak memisahkan GL dari Stock/FIFO,
AP/AR, Payment, atau dokumen operasional asal.

User kemudian mengonfirmasi migration, postflight, dan rollback-safe behavior
Phase 7A seluruhnya PASS. Phase 7A ditutup `COMPLETE; USER VERIFIED`.

### Corrective Phase 7 — Backoffice posting/reversal UI dan pilot

- status aktif dimulai dari SELECT-only
  `g6_phase7_finance_operations_pilot_preflight.sql`;
- endpoint Backoffice worker lama `process_financial_events_queue` dibuat
  fail-closed sebelum pilot karena service-role legacy worker bukan canonical
  execution path;
- role-aware workspace;
- explicit confirmation untuk post/retry/reversal/reopen period;
- tidak ada direct browser write;
- authenticated cross-role/cross-Company UAT;
- pilot reconciliation dan stress sebelum Vercel deployment gate.

Phase 7B Backoffice workspace sekarang `LOCAL READY; AUTHENTICATED SMOKE
PENDING`. UI/API membaca canonical journal/line, period, queue, exception, COA,
dan report RPC; seluruh mutation tetap melalui guarded RPC. Scope queue tidak
berubah dari `STOCK_OPENING`, automatic journal tidak mendapat tombol reversal,
dan reconciliation tidak membuat adjustment. Acuan smoke:
`docs/runbooks/G6_PHASE7B_FINANCE_OPERATIONS_UI.md`.

Keputusan UX lanjutan yang disetujui user sebelum pilot final:

- UUID/random technical identity tidak ditampilkan kepada user; UUID tetap
  menjadi backend identity/FK/idempotency key;
- jurnal, jurnal pembalik, posting queue, dan exception memakai nomor dokumen
  manusiawi yang dibuat server-side, tenant-scoped, dan concurrency-safe;
- General Ledger mengikuti pola ringkasan seluruh akun untuk periode terpilih,
  kemudian baris akun dapat di-expand secara lazy ke journal-line detail;
- Journal Entries menjadi page terpisah yang berpusat pada daftar dokumen
  jurnal, lalu membuka seluruh debit/kredit/account movement ketika dipilih;
- export laporan memakai filter periode dan minimum XLSX beserta metadata
  Company, timezone, generated-at, filter, dan report version.

Nomor display tidak boleh mengganti UUID atau memutus historical reference.
Format final/generator/backfill harus diaudit terhadap `journal_no`, `queue_no`,
existing source document number, dan counter allocator sebelum migration dibuat.

#### Phase 7B UX forward fix (`DATABASE USER VERIFIED; UI SMOKE PENDING`)

Perubahan rundown yang disetujui user sudah diimplementasikan secara additive:

- migration `20260811100000` menambah allocator privat dan persistent display
  number `JUR/JRB/PST/EXC/REC` per Company, bulan, dan prefix;
- UUID, FK, idempotency key, `journal_no`, dan `queue_no` lama tetap utuh sebagai
  identity backend; browser tidak memperoleh akses allocator/counter;
- Buku Besar menjadi page account-centric: seluruh COA tampil, dapat dicari,
  difilter, dan di-expand lazy ke transaksi POSTED serta saldo berjalan;
- Journal Entries menjadi page document-centric dengan filter bulan, search,
  detail debit/kredit, dan drill-through dari Buku Besar;
- export bulanan Buku Besar dan Journal Entries menghasilkan OOXML `.xlsx`
  berisi summary/detail/metadata tenant dan report version.

User mengonfirmasi preflight, migration, postflight, dan behavior seluruhnya
sukses. Sisa manual gate: restart Backoffice -> authenticated
cross-role/cross-Company UI/XLSX smoke. Acuan:
`docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md`. Phase 7B belum
boleh ditandai complete sebelum output database dan smoke user diterima.

## Deferred sesudah pilot/Vercel

Rencana future **inter-Company Sales/Purchase** dicatat tetapi tidak dibuka pada
MVP saat ini. Targetnya: transaksi antar Company dalam database yang sama dapat
membuat pasangan dokumen Sales/Purchase otomatis, dengan persetujuan kedua
Company, nomor/source berbeda, harga/tax/UOM snapshot, elimination/reconciliation
Finance, idempotency, dan tanpa berbagi akses tenant. Desain baru dimulai setelah
aplikasi lolos pilot, stress test, dan siap diuji melalui Vercel.

## Evidence wajib setiap phase

- daftar file dan checksum migration;
- local static test;
- output manual migration/postflight/behavior/regression;
- authenticated tenant/role smoke;
- compatibility dan remaining gap;
- update handoff, root README, implementation gate, dan migration manifest bila
  ada schema change.
