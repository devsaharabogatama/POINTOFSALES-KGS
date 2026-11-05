# Backoffice AR Open-Item Foundation Impact Audit

**Tanggal:** 2026-11-05
**Task:** Task 2 dari
`BACKOFFICE_AR_OPEN_ITEM_CREDIT_RECONCILIATION_IMPACT_2026-11-03.md`
**Klasifikasi:** Fase A `READ_ONLY_AUDIT` untuk calon
`SCHEMA_OR_MIGRATION_CHANGE`
**Status:** `AUDIT COMPLETE` untuk desain foundation Task 2. Canonical line
identity, cutover KMS, mixed Receipt, correction, revision, dan retained-Retail
exception telah diklasifikasikan dari Production read-only evidence. Tidak ada
schema/runtime/data/client yang diubah.

## 1. Expected business outcome dan keputusan yang mengikat

Foundation harus memungkinkan Finance melakukan rekonsiliasi manual seperti
open-item accounting tanpa mengubah histori posted:

- Invoice Backoffice membentuk open debit Piutang Customer;
- Customer Receipt dan Credit Note membentuk open credit;
- Finance memilih Invoice tujuan milik Customer dan Company yang sama;
- sumber kredit, nilai awal, alokasi parsial, residual, actor, waktu, dan exact
  operation tetap dapat diaudit;
- Customer Balance hanya berubah melalui aksi eksplisit pada task berikutnya;
- Return fisik tanpa Credit Note tetap menunggu pilihan manual Finance;
- POS Retail, Stock/FIFO, dispatch, dan journal lama tidak berubah.

Source of truth bisnis: keputusan user pada 2026-11-03 dan 2026-11-05 yang
tercatat di audit induk. Keputusan terbaru ini mengungguli narasi lama
`DEBIT_CREDIT_NOTE_SPEC.md` untuk target flow baru, tetapi spec lama tetap
menjelaskan runtime yang saat ini aktif sampai forward migration terpisah.

## 2. Active execution path yang terbukti

### 2.1 Invoice debit AR

`private.post_backoffice_sales_invoice_financial_event_core(...)` membuat Journal posted
dengan satu baris Debit `CUSTOMER_RECEIVABLE` sebesar `grand_total`, menyimpan
`customer_id`, dan menautkannya melalui `financial_event_id`.

Sumber:

- `supabase/migrations/20260909161000_backoffice_sales_invoice_posting_runtime.sql:625-644`;
- tabel `finance_journals` dan `finance_journal_lines`:
  `20260810180000_g6_phase2_tenant_safe_journal_foundation.sql:180-343`.

### 2.2 Customer Receipt credit AR dan alokasi existing

Dokumen ada pada `customer_receipt_documents`. Alokasi Backoffice existing ada
pada `customer_receipt_backoffice_invoice_allocations` dan menghubungkan satu
Receipt ke satu atau lebih Invoice. Final child row tidak dapat diubah setelah
Receipt final. Runtime save/post mengunci dokumen, memeriksa amount, permission,
version, dan allocation.

Sumber:

- `20260827100000_finance_customer_receipt_ar_foundation.sql:24-135`;
- `20260827120000_finance_historical_collection_customer_advance.sql:18-113`;
- `20260911160000_backoffice_sales_payment_collection_runtime.sql:40-510`;
- API aktif `backoffice/src/app/api/finance/customer-receipts/route.ts`.

`received_amount` wajib sama dengan allocated `total_amount`, kecuali receipt
advance yang seluruhnya dipindah eksplisit ke Customer Balance. Current runtime
tidak mempunyai posted Customer Receipt reversal; yang tersedia hanya cancel
Draft. Ini wajib dipertahankan sebagai batas foundation, bukan diisi dengan
asumsi reversal baru.

### 2.3 Credit Note credit AR current

`private.post_backoffice_sales_credit_note_before_retained(...)` menghitung
`ar_reduction_amount` dan `refund_liability_amount`. Hanya nilai AR reduction
yang dijurnal Kredit `CUSTOMER_RECEIVABLE`; liability dijurnal terpisah.
Customer Statement, AR Aging, Invoice payment context, dan schedule saat ini
mengurangi Invoice sumber langsung dari nilai agregat tersebut.

Sumber:

- schema: `20260917130000_backoffice_sales_return_credit_note_foundation.sql:123-344`;
- runtime aktif:
  `20261006140000_backoffice_unified_posted_invoice_revision.sql:2035-2245`;
- report aktif file yang sama: `1158-1500`.

### 2.4 Refund current

`backoffice_sales_customer_refunds` saat ini melunasi
`CUSTOMER_REFUND_LIABILITY`, bukan AR open credit. Refund dan reversal memiliki
Finance Event/Journal sendiri dan immutable operation/audit lineage.

Sumber:
`20260917150000_backoffice_sales_customer_refund.sql:151-645`.

Foundation Task 2 tidak boleh menafsirkan refund lama sebagai rekonsiliasi AR.

### 2.5 Corrections yang juga menghasilkan AR line

Koreksi harga posted (`backoffice_sales_invoice_price_corrections`) dapat
membuat Debit atau Kredit `CUSTOMER_RECEIVABLE`. Unified posted Invoice revision
(`private.backoffice_invoice_revisions`) dapat mengubah payable dan bahkan
effective Customer melalui journal tambahan. Keduanya adalah consumer wajib;
foundation yang hanya membaca `invoice.grand_total` akan salah.

Sumber:

- `20260928110000_backoffice_posted_invoice_price_correction.sql:110-179,643-801`;
- `20261006140000_backoffice_unified_posted_invoice_revision.sql:566-668,804-851`.

## 3. Candidate foundation dan koreksi berdasarkan production evidence

### 3.1 Canonical item candidate — histori sebelum final diagnosis

Candidate yang diaudit adalah **baris Journal posted dengan snapshot function
`CUSTOMER_RECEIVABLE`**, bukan tabel nominal Invoice/Credit baru. Alasannya:

- setiap debit/kredit sudah membawa Company, account, Customer, amount, source
  Journal/Event, date, dan posted immutability;
- Invoice revision dan price correction otomatis menjadi item baru sesuai
  jurnalnya tanpa menulis ulang nilai Invoice lama;
- source cashflow tetap dapat ditelusuri ke Receipt, Credit Note, refund, atau
  correction melalui `finance_journals.source_type/source_id` dan Event;
- open residual dapat dihitung sebagai amount journal line dikurangi allocation
  efektif; tidak ada saldo kedua yang dapat drift dari GL.

Production inventory 2026-11-05 membantah penggunaan langsung
`finance_journals.source_type/source_id` sebagai identitas universal. Query
pertama menemukan 122 dari 535 posted Invoice dan 103 dari 313 posted Receipt
yang tidak mempunyai AR line melalui exact direct-source join. Karena source
document juga mempunyai `financial_event_id` dan Journal mempunyai
`financial_event_id`, baris tersebut belum boleh diklasifikasikan sebagai
missing Journal sebelum event lineage diuji. Candidate direct-source di atas
ditarik kembali; schema Task 2 belum boleh dirancang dari candidate tersebut.

### 3.2 Candidate allocation model — tertahan

Identifier final belum boleh dibuat sebelum production event-lineage diagnosis
selesai. Bentuk minimal yang sebelumnya diaudit tetap hanya hipotesis:

- append-only allocation header/operation dengan `(company_id, operation_id)`
  unique, request hash, actor, operation type, response snapshot, dan timestamp;
- append-only allocation line yang menautkan satu AR debit journal line dengan
  satu AR credit journal line serta amount positif;
- immutable audit row untuk create/reversal operation;
- read RPC yang menghitung original amount, allocated, residual, document
  lineage, dan source Customer tanpa memberi direct table privilege ke client.

Invariant server-side wajib:

1. kedua journal berstatus `POSTED` dan Company sama;
2. debit line hanya mempunyai `debit>0`, credit line hanya `credit>0`;
3. keduanya `CUSTOMER_RECEIVABLE`, Customer sama, dan account sama kecuali
   production evidence membuktikan mapping change yang memerlukan explicit
   transfer journal;
4. cumulative effective allocation tidak melebihi debit maupun credit line;
5. operation exact retry mengembalikan snapshot yang sama; payload berbeda
   dengan operation ID sama ditolak;
6. lock order deterministik atas kedua line mencegah concurrent over-allocation;
7. reversal adalah append-only inverse operation; row lama tidak di-update atau
   dihapus;
8. direct access anon/authenticated ditolak; mutation hanya lewat
   `SECURITY DEFINER` RPC dan permission capability Finance;
9. Retail/Backoffice mixed source tidak boleh meninggalkan false residual.

## 4. Backfill compatibility plan

Backfill tidak membuat Journal atau mengubah source document.

- Posted Invoice: gunakan AR debit journal line existing sebagai debit item.
- Posted Backoffice Customer Receipt allocation: buat allocation snapshot dari
  receipt AR credit line ke Invoice AR debit line sebesar
  `customer_receipt_backoffice_invoice_allocations.allocated_amount`.
- Posted native Backoffice Credit Note: hanya `ar_reduction_amount` existing
  yang dialokasikan ke source Invoice. `refund_liability_amount` tidak masuk AR.
- Retail/Backoffice mixed Receipt: seluruh porsi yang memakai credit journal
  line yang sama harus dapat dibuktikan settled. Bila ada row mixed, desain
  harus memasukkan bridge/slice yang eksplisit; tidak boleh menganggap sisa
  credit sebagai open Backoffice credit.
- Price correction dan unified Invoice revision: Journal AR debit/credit harus
  masuk read model. Exact backfill/allocation treatment menunggu production
  inventory karena jumlah dan customer-change row belum diketahui.
- Existing reports/schedules tetap memakai source lama pada Task 2. Cutover
  report baru hanya boleh terjadi pada Task 7 setelah parity proof; ini mencegah
  double subtraction.

## 5. Impact map

### Direct impact calon Fase B

- tabel allocation/operation/audit append-only;
- read RPC residual dan lineage;
- backfill snapshot dari existing posted Receipt/Credit Note allocations;
- permission/RLS untuk Finance read dan future mutation.

### Downstream consumers yang sudah diinventarisasi

- `get_finance_customer_receipts()`;
- `get_finance_ar_aging(date,uuid,uuid)`;
- `get_finance_customer_statement(uuid,date,date,uuid)`;
- `get_backoffice_sales_invoice_payment_context(uuid)`;
- `reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)`;
- Customer Receipt API/UI dan report export;
- Backoffice Invoice payment context;
- Backoffice Return/Credit Note/Refund APIs dan UI;
- price correction dan unified posted Invoice revision;
- Finance Event/Journal, accounting period, permission, RLS, operation/audit.

### Explicitly preserved

- POS Retail sale/payment/return and cashier session;
- Backoffice SO, dispatch, delivery, Return physical receipt;
- Stock, reservation, FIFO/HPP;
- posted source Journal/Event/document and existing allocation rows;
- Customer Balance ledger and current balance;
- native Refund Liability and retained Retail bridge;
- other Companies and future Company provisioning.

## 6. Concurrency, retry, rollback, dan forward-fix

- allocation mutation memakai transaction tunggal dan advisory lock keyed by
  Company + operation ID, lalu row lock debit/credit dalam UUID order;
- residual dicek ulang setelah lock, bukan dari UI preview;
- migration guard memerlukan exact dependency/object definitions dan state
  `NOT_INSTALLED`; live migration version tidak pernah diubah/rerun;
- migration rollback hanya untuk transaksi instalasi yang belum commit;
  setelah live, correction harus forward migration baru;
- backfill key deterministik dari source allocation identity agar repeat
  candidate dapat dibuktikan tanpa duplicate;
- kegagalan satu source row membatalkan seluruh migration; tidak ada partial
  commit atau pseudo-PASS.

## 7. Regression matrix wajib sebelum Fase B dinyatakan siap

| Dimensi | Sebelum | Sesudah foundation | Status |
|---|---|---|---|
| unpaid/partial/paid Invoice | source report existing | parity residual | belum diuji |
| Receipt one/multi Invoice | source allocation existing | allocation snapshot sama | belum diuji |
| mixed Retail/Backoffice Receipt | source share satu Receipt | tidak boleh false credit | `BELUM TERBUKTI` |
| Credit Note < = > residual | AR split existing | legacy snapshot tanpa rewrite | belum diuji |
| price correction +/- | report effective total | AR journal item terwakili | `BELUM TERBUKTI` |
| unified revision/customer change | revision journal | Customer lineage konsisten | `BELUM TERBUKTI` |
| same/cross Customer | implicit source guards | cross Customer ditolak | belum diuji |
| same/cross Company | tenant FKs | cross Company ditolak | belum diuji |
| retry/changed retry | operation-specific | exact replay / mismatch reject | belum diuji |
| stale/concurrent allocation | source locks | no over-allocation | belum diuji |
| Customer Balance | existing explicit path | tidak berubah | belum diuji |
| Refund Liability/retained Retail | existing path | tidak berubah | belum diuji |
| POS Retail | existing flow | behavior identik | belum diuji |

## 8. Production evidence terbaru dan evidence yang masih dibutuhkan

### 8.1 Hasil journal-line inventory 2026-11-05

User menjalankan SELECT-only:

`supabase/diagnostics/backoffice_ar_open_item_journal_line_inventory.sql`

Hasil yang terbukti:

1. Company scope KMS, LSM, dan SMS benar dan ketiganya memakai
   `BACKOFFICE_DELIVERED_QTY_INVOICE`;
2. 535 posted Invoice diperiksa; 122 gagal exact direct-source AR join;
3. 313 posted Receipt yang mempunyai Backoffice allocation diperiksa; 103
   gagal exact direct-source AR join;
4. terdapat 14 Receipt dengan alokasi Retail dan Backoffice dalam satu dokumen;
   satu Credit AR penuh tidak boleh dianggap seluruhnya milik Backoffice;
5. existing allocation pair mempunyai 117 unresolved/mismatch rows pada model
   direct-source, termasuk 37 account/customer mismatches;
6. source inventory juga memuat KMS receivable reclassification, retained
   credit split reclassification, price correction, dan Invoice revision;
7. production result mencabut asumsi bahwa `source_type/source_id` sendiri
   cukup untuk backfill open-item.

`FAIL` tersebut dipertahankan sebagai evidence. Ia tidak diubah menjadi PASS,
tidak dikecilkan assertion-nya, dan tidak membuktikan bahwa 122/103 dokumen
benar-benar tidak mempunyai Journal. Klasifikasi error:
`PRECONDITION CHANGE / DESIGN ROOT-CAUSE AUDIT`.

### 8.2 Diagnosis berikutnya

Jalankan SELECT-only:

`supabase/diagnostics/backoffice_ar_open_item_lineage_diagnosis.sql`

Query ini membandingkan direct-source lineage dengan
`document.financial_event_id -> finance_journals.financial_event_id`, lalu
memisahkan:

1. event-linked match vs document/event/journal/AR-line yang benar-benar hilang;
2. source type Journal alternatif tanpa menghapus bukti direct-source FAIL;
3. account mismatch, Customer mismatch, atau unresolved pair secara terpisah;
4. nominal Retail, Backoffice, dan unallocated pada 14 mixed Receipt;
5. Credit Note per `source_kind` dan event lineage-nya.

Static verification: PostgreSQL 18 parser menerima tepat satu `SelectStmt`;
SHA-256 file
`9DFD9A5CA618EE082529ABE706E34EA97D8FA29F886DD57E98E42206C264E00F`.

Sampai output diagnosis diklasifikasikan, production backfill shape tetap
`BELUM TERBUKTI`. Unknown ini dapat mengubah desain schema dan perlakuan
Receipt campuran, sehingga SOP Gate Fase B **gagal** dan tidak ada migration
yang boleh dibuat.

## 9. Status

- `AUDIT COMPLETE`: YES untuk Fase A Task 2 foundation.
- `LOCAL READY`: NO.
- `DATABASE LIVE`: NO untuk capability baru.
- `CLIENT DEPLOYED`: NO.
- `SMOKE PASS`: NO.
- `UAT PASS`: NO.

## 13. Migration execution failure dan Phase A re-audit

Eksekusi target pada 2026-11-05 berhenti sebelum `COMMIT` dengan PostgreSQL
`42703`: `record "new" has no field "actor_id"` pada
`private.trg_ar_open_item_audit_insert()`. Klaim package siap dijalankan dicabut.
Status database setelah error adalah `UNKNOWN` sampai ledger dan seluruh object
state dibuktikan kembali oleh preflight SELECT-only.

### Root cause yang terbukti dari source

Satu fungsi audit dipasang sebagai `AFTER INSERT` pada tiga record shape:

- `ar_open_item_registry`: actor disimpan pada `created_by`;
- `ar_open_item_operations`: actor disimpan pada `actor_id`;
- `ar_open_item_allocations`: actor disimpan pada `created_by`.

Implementasi gagal memakai `CASE TG_TABLE_NAME ... NEW.actor_id ...
NEW.created_by`. PL/pgSQL tetap meresolve field record pada row type pemanggil;
karena registry tidak memiliki `actor_id`, insert registry pertama gagal. Ini
adalah `PRODUCT FIX` pada candidate `SCHEMA_OR_MIGRATION_CHANGE`, bukan masalah
data Production dan bukan alasan untuk melemahkan assertion.

### Impact map ulang

- Direct impact: insert registry, operation, allocation, dan audit snapshot.
- Downstream: seluruh backfill berhenti sebelum residual RPC dapat dipakai.
- Preserved oleh transaction rollback yang diharapkan tetapi belum dibuktikan:
  source Invoice/Receipt/Credit Note/correction, Posted Journal/Event,
  Backoffice runtime, POS, Customer Balance, Stock/FIFO.
- Compatibility risk: actor audit harus tetap berasal dari kolom canonical
  masing-masing tabel; fallback actor atau NULL diam-diam dilarang.
- Concurrency/idempotency: desain transaction/advisory lock dan unique source
  identity tidak berubah; exact retry tetap ditolak oleh installation guard.
- Rollback/forward-fix rule: bila preflight membuktikan `NOT_INSTALLED`, candidate
  migration yang belum pernah committed boleh dikoreksi. Bila ledger/object
  menunjukkan `PARTIAL/INCONSISTENT` atau `INSTALLED_CONSISTENT`, file tersebut
  tidak boleh diubah/dijalankan ulang dan koreksi wajib migration versi baru.

### Regression evidence yang wajib ditambah sebelum rollout berikutnya

1. trigger actor lineage untuk `REGISTRY`, `OPERATION`, dan `ALLOCATION`;
2. audit snapshot tepat satu per inserted entity;
3. backfill source/registry/allocation count tetap exact;
4. immutable guard, same-Customer allocation, residual limit, stale/retry dan
   cross-Company boundary tetap berlaku;
5. parser/static PASS tidak lagi disebut behavioral proof; migration transaction,
   postflight, rollback behavior, authenticated smoke, dan UAT tetap gate
   terpisah.

Current status setelah failure:

- `AUDIT COMPLETE`: NO untuk re-audit Fase B sampai state database terbukti;
- `LOCAL READY`: NO;
- `DATABASE LIVE`: UNKNOWN;
- `CLIENT DEPLOYED`: N/A;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.

### State proof dan corrected candidate

User mengembalikan preflight lengkap setelah failure. Evidence membuktikan
`NOT_INSTALLED`: ledger, registry, operations, allocations, audit, dan RPC
semuanya tidak ada; seluruh dependency, canonical Journal line, revision,
Receipt slice, dan runtime boundary tetap PASS. Karena migration belum pernah
committed, candidate `20261105100000` dikoreksi tanpa membuat forward version
palsu.

Shared trigger sekarang tidak mereferensikan heterogeneous `NEW.actor_id` atau
`NEW.created_by`. Ia mengambil immutable `to_jsonb(NEW)`, memilih actor
berdasarkan exact `TG_TABLE_NAME`, dan fail-closed bila entity/actor/company/id
tidak tersedia. Migration assertion, postflight, dan rollback behavior kini
memeriksa actor dan snapshot lineage untuk ketiga entity kind.

Local evidence:

- PostgreSQL 18 `libpg_query` parser: migration 44 statements, preflight 1,
  postflight 1, behavior 4;
- PostgreSQL 18.4 single-user isolated transaction mengeksekusi trigger pada
  synthetic registry, operation, dan allocation row; ketiganya menghasilkan
  actor/snapshot yang tepat lalu seluruh write di-rollback;
- scoped `git diff --check` PASS;
- full migration/backfill belum dapat dijalankan pada local parser-only database
  karena database tersebut bukan full Supabase schema/fixture.

Status corrected candidate:

- `AUDIT COMPLETE`: YES untuk correction scope;
- `LOCAL READY`: NO — full migration/backfill belum dieksekusi lokal;
- `DATABASE LIVE`: NO;
- `CLIENT DEPLOYED`: N/A;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.

## 14. Current authoritative status setelah Production rollout

Bagian status sebelumnya merupakan histori gate pada saat masing-masing fase.
Status terbaru yang mengungguli checkpoint historis tersebut:

- corrected migration `20261105100000` telah `DATABASE LIVE`;
- first Production postflight PASS untuk exact source/registry parity, 383
  allocations tanpa over-allocation, 1.617/1.617 audit actor/snapshot lineage,
  serta RPC-only authenticated privilege;
- exact rollback behavior PASS untuk authenticated Finance VIEW read, active
  Company dan Customer isolation, append-only registry, ketiga actor lineage,
  shared operation trigger execution, allocation residual guard, operation
  idempotency, direct-table denial, dan zero canonical source mutation;
- seluruh behavior test write di-rollback;
- closing postflight setelah rollback PASS dengan hasil identik: exact registry,
  383 allocations, zero over-allocation, 1.617/1.617 audit lineage, dan
  RPC-only privilege tetap utuh;
- authenticated UI/API smoke dan UAT belum dijalankan.

Status authoritative:

- `AUDIT COMPLETE`: YES;
- `DATABASE LIVE`: YES;
- `FIRST POSTFLIGHT PASS`: YES;
- `ROLLBACK BEHAVIOR PASS`: YES;
- `CLOSING POSTFLIGHT PASS`: YES;
- `CLIENT DEPLOYED`: N/A;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.

### Production migration dan first postflight

User mengonfirmasi corrected migration berhasil dan mengembalikan postflight
lengkap. Evidence Production:

- ledger `20261105100000`: tepat 1;
- registry sama persis dengan source: 535 Invoice, 313 Receipt, 2 price
  correction, dan 1 native Backoffice Credit Note;
- 383 allocation total, termasuk exact 380 Receipt allocations, tanpa
  over-allocation;
- 1.617 audit untuk 1.617 expected entity inserts; actor dan immutable snapshot
  mismatch: 0;
- authenticated dapat mengeksekusi RPC tetapi tidak mempunyai direct SELECT ke
  empat tabel foundation.

Scope bukti ini adalah installation/backfill/read-privilege contract. Ia belum
membuktikan authenticated Finance behavior, rollback regression, atau UI/API
smoke.

Status sekarang:

- `AUDIT COMPLETE`: YES;
- `LOCAL READY`: NO (tidak dipakai untuk mengklaim Production behavior);
- `DATABASE LIVE`: YES;
- `POSTFLIGHT PASS`: YES;
- `CLIENT DEPLOYED`: N/A;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.

## 10. Event-lineage result dan KMS account cutover diagnosis

User menjalankan
`supabase/diagnostics/backoffice_ar_open_item_lineage_diagnosis.sql` dan
mengembalikan seluruh enam output pada 2026-11-05. Hasilnya mempersempit gap
menjadi KMS saja:

- 52 Invoice KMS sampai 2026-09-29 senilai Rp179.303.800 dikenali melalui
  direct/event AR line; 122 Invoice mulai 2026-09-30 senilai Rp460.119.440
  mempunyai Event dan Posted Journal yang source-linked, tetapi tidak dikenali
  oleh filter `account_function_key_snapshot='CUSTOMER_RECEIVABLE'`;
- 15 Receipt KMS sampai 2026-09-29 senilai Rp51.117.838 dikenali; 103 Receipt
  mulai 2026-09-30 senilai Rp447.623.468 mempunyai Event dan Posted Journal
  yang source-linked, tetapi gagal pada filter snapshot yang sama;
- seluruh unresolved allocation pair berada di KMS: 80 Invoice-side dan 37
  Receipt-side. LSM dan SMS seluruh pair cocok pada diagnosis tersebut;
- satu retained KMS Credit Note Rp78.400 juga mempunyai Event dan Journal,
  tetapi tidak dikenali oleh filter snapshot;
- 14 mixed Retail/Backoffice Receipt semuanya fully allocated; desain tetap
  wajib mempertahankan partition/slice agar satu credit journal line tidak
  menghasilkan false residual.

Repository tracing menjelaskan kemungkinan akar teknis tanpa menyatakan data
GL rusak:

1. `private.resolve_financial_event_account(...)` memilih account berdasarkan
   `transaction_account_rules` atau fallback dan event date;
2. trigger `private.trg_g6_guard_finance_journal_line()` mengisi
   `account_function_key_snapshot` dari
   `chart_of_accounts.system_function_key`, bukan dari routing key transaksi;
3. KMS mapping activation mengarahkan `CUSTOMER_RECEIVABLE` ke workbook account
   `1020100 / PIUTANG USAHA` mulai cutover, sedangkan akun tersebut merupakan
   user-owned/reused account. Karena itu snapshot function dapat NULL walaupun
   account resolution dan nominal journal benar.

Sumber definisi:

- `20260810200000_g6_phase4_atomic_single_event_posting.sql:370-427,563-568`;
- `20260810180000_g6_phase2_tenant_safe_journal_foundation.sql:560-571`;
- `20260929110000_kms_finance_coa_workbook_alignment.sql:21-31`;
- `20260929120000_kms_finance_workbook_mapping_activation.sql:9-43`;
- `20261007100000_kms_retail_ar_canonical_backlog_repair.sql:1-18,117-121`.

Klasifikasi temuan: `TEST HARNESS / PRECONDITION CHANGE`, bukan Product fix.
Assertion lama tidak dihapus; filter function snapshot terbukti tidak cukup
sebagai identitas universal untuk user-owned COA.

Diagnosis SELECT-only berikutnya:

`supabase/diagnostics/backoffice_ar_open_item_kms_account_lineage_diagnosis.sql`

Query tersebut membuktikan exact KMS COA `1210/1020100`, seluruh histori route
`CUSTOMER_RECEIVABLE`, keunikan Invoice line berdasarkan event-date resolver,
Receipt line berdasarkan immutable `receivable_account_id_snapshot`, serta
bentuk retained Credit Note. Query tidak menulis data atau memanggil mutation.

Gate ini berlaku saat diagnosis diterbitkan dan sekarang telah diselesaikan oleh
hasil pada bagian 11. Ia dipertahankan sebagai histori mengapa migration tidak
dibuat sebelum account-lineage terbukti.

## 11. Final account-lineage result dan desain yang diterima

User menjalankan diagnosis KMS account-lineage lengkap pada 2026-11-05.
Production evidence membuktikan:

1. akun lama `1210 / Piutang Customer` memakai
   `system_function_key=CUSTOMER_RECEIVABLE`, sedangkan workbook account
   `1020100 / PIUTANG USAHA` memakai
   `system_function_key=ACCOUNTS_RECEIVABLE`;
2. transaction route tetap memakai `CUSTOMER_RECEIVABLE`. Perbedaan alias
   snapshot tersebut adalah seluruh penyebab false-missing pada diagnosis lama;
3. seluruh 174 Posted Invoice KMS mempunyai tepat satu line debit AR dengan
   account, Customer, dan nominal yang benar: 52 dokumen Rp179.303.800 pada
   `1210`, lalu 122 dokumen Rp460.119.440 pada `1020100`;
4. seluruh 118 Posted Receipt KMS yang mengandung Backoffice allocation
   mempunyai tepat satu line credit pada immutable
   `receivable_account_id_snapshot`: 15 dokumen Rp51.117.838 pada `1210`, lalu
   103 dokumen Rp447.623.468 pada `1020100`;
5. seluruh route Invoice yang diuji unique; `ambiguous_route=0`, seluruh
   Invoice/Receipt `invalid_line_shape=0`;
6. dua KMS price correction adalah Credit Note AR adjustment total Rp540.000;
   production inventory membuktikan tidak ada missing AR line atau Customer;
7. Invoice revision inventory berisi KMS 5, LSM 1, SMS 24, semuanya
   `payableDelta=0` dan tidak mengubah Customer. Ia tetap menjadi future
   consumer, tetapi tidak menghasilkan open item tambahan pada backfill kini;
8. 14 mixed Retail/Backoffice Receipt fully allocated. Backfill harus membuat
   slice allocation dari nilai child allocation existing, bukan membuka
   residual atas seluruh Receipt credit line;
9. `CN-20260919-0000000012` Rp78.400 adalah retained-Retail exception. Original
   Event Journal memakai Refund Liability; migration immutable `20260919131000`
   membuat append-only `RETAINED_CREDIT_SPLIT_RECLASSIFICATION` debit Refund
   Liability / credit AR. Row ini bukan native Backoffice Credit Note dan
   dikecualikan dari Task 2 Backoffice backfill tanpa mengubah jurnalnya.

### Canonical identity yang diterima untuk Fase B

- Invoice debit: exact Posted Journal linked by `financial_event_id`, lalu line
  pada account hasil event-date resolver, Customer sama, debit sama dengan
  source amount;
- Receipt credit: exact Posted Journal linked by `financial_event_id`, lalu line
  pada `customer_receipt_documents.receivable_account_id_snapshot`, Customer
  sama, credit sama dengan `total_amount`;
- native Backoffice Credit Note: exact source/event Journal AR credit sebesar
  `ar_reduction_amount`; Refund Liability tidak masuk open AR credit;
- price correction: exact source Journal AR line dan Customer existing;
- retained-Retail reclassification, Refund, Customer Balance, dan POS Retail
  tidak menjadi item Task 2;
- `account_function_key_snapshot` tidak boleh dipakai sendiri sebagai universal
  AR identity karena legitimate tenant COA dapat memakai alias fungsi berbeda.

Dengan bukti ini tidak ada lagi `BELUM TERBUKTI` yang mengubah desain foundation
Task 2. Fase B boleh disiapkan sebagai forward migration baru, tetapi belum
dibuat, belum dijalankan, dan belum mengubah status runtime.

## 12. Fase B local package

SOP Gate Fase B ditampilkan pada 2026-11-05 dengan call chain `PROVEN`, state
`NOT_INSTALLED`, dan `Unknown affecting design: NONE`. Package additive yang
disiapkan:

- `supabase/migrations/20261105100000_backoffice_ar_open_item_foundation.sql`;
- `supabase/diagnostics/backoffice_ar_open_item_foundation_preflight.sql`;
- `supabase/diagnostics/backoffice_ar_open_item_foundation_postflight.sql`;
- `supabase/tests/backoffice_ar_open_item_foundation_behavior.sql`;
- `docs/runbooks/BACKOFFICE_AR_OPEN_ITEM_FOUNDATION_ROLLOUT_2026-11-05.md`.

Desain menyimpan immutable registry yang menunjuk Journal line canonical,
operation idempotency, allocation, dan audit. Receipt campuran disimpan hanya
sebesar jumlah child Backoffice allocation. Allocation trigger mengunci kedua
item dan menolak beda Customer/direction, operation mismatch, serta nominal
melebihi residual. Browser tidak mendapat direct table access; RPC baca memakai
permission existing `finance.customer_receipts / VIEW`.

Runtime posting existing belum menulis item baru pada fase ini. Perubahan
transactional Invoice/Receipt/Credit Note dan aksi manual Apply/Refund tetap
Task 3/4, sehingga package ini tidak diklaim sebagai flow Odoo lengkap.

Static evidence: PostgreSQL parser 18.0.4 menerima migration 44 statements,
preflight 1 statement, postflight 1 statement, dan behavior 4 statements;
scoped `git diff --check` PASS; preflight/postflight mutation-token scan nol.
Database target belum menjalankan file mana pun.

Status historis ketika package pertama dibuat (telah digantikan oleh current
authoritative status pada bagian 14):

- `AUDIT COMPLETE`: YES;
- `LOCAL READY`: NO; baru parser/static gate, belum ada eksekusi database;
- `DATABASE LIVE`: NO;
- `CLIENT DEPLOYED`: N/A untuk Task 2;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.
