# Backoffice AR Open-Credit Actions Impact Audit

**Tanggal:** 2026-11-06  
**Roadmap:** Backoffice AR Task 5  
**Klasifikasi target:** `PRODUCT_BEHAVIOR_CHANGE` +
`SCHEMA_OR_MIGRATION_CHANGE`  
**Status:** Fase A read-only sedang berjalan. Belum ada runtime, schema,
migration, fixture, atau production data yang diubah oleh audit ini.

## 1. Expected business outcome

Untuk Company dengan proses `BACKOFFICE_DELIVERED_QTY_INVOICE`, Finance dapat
memakai residual Credit Note native Backoffice milik Customer yang sama melalui
tiga tindakan eksplisit:

1. **Apply ke Invoice**: satu Credit Note dapat dialokasikan sebagian/penuh ke
   satu atau beberapa Invoice Customer yang sama. Tidak ada jurnal baru karena
   Invoice dan Credit Note sudah masing-masing tercatat pada AR; tindakan ini
   hanya merekonsiliasi dua open item.
2. **Refund Cash/Bank**: sebagian/penuh open credit dibayarkan kepada Customer.
   Jurnal target adalah Debit `CUSTOMER_RECEIVABLE`, Kredit Cash/Bank, kemudian
   debit AR hasil refund direkonsiliasi dengan Credit Note credit.
3. **Convert ke Customer Balance**: bila feature/policy Customer Balance aktif
   dan Finance memilih tindakan ini, jurnal target adalah Debit
   `CUSTOMER_RECEIVABLE`, Kredit `CUSTOMER_BALANCE_LIABILITY`, kemudian debit AR
   hasil konversi direkonsiliasi dengan Credit Note credit dan Customer Balance
   Customer bertambah.
4. **Gunakan Customer Balance pada Backoffice Invoice Posted**: setelah Invoice
   membentuk AR, Finance dapat memakai saldo Customer yang tersedia sebagian
   atau penuh. Jurnal target adalah Debit `CUSTOMER_BALANCE_LIABILITY`, Kredit
   `CUSTOMER_RECEIVABLE`. Saldo tidak menjadi discount, tidak mengubah revenue,
   dan tidak boleh dipilih saat membuat SO atau Draft/initial Invoice.

Tidak ada alokasi, refund, atau konversi otomatis pada saat Credit Note diposting.
Semua tindakan tetap Company- dan Customer-scoped, append-only, auditable,
idempotent, concurrency-safe, period-aware bila membuat jurnal, dan reversible.

Source of truth keputusan bisnis:

- `docs/audits/BACKOFFICE_AR_OPEN_ITEM_CREDIT_RECONCILIATION_IMPACT_2026-11-03.md`
  bagian 4.3, Task 5, regression matrix, dan keputusan user;
- `docs/audits/BACKOFFICE_AR_CREDIT_NOTE_OPEN_CREDIT_IMPACT_2026-11-05.md`
  bagian 1, 5, 6, dan 9.

## 2. State yang terbukti

- Task 2 open-item foundation migration `20261105100000` sudah database-live.
- Task 3 Invoice/Receipt allocation runtime migration `20261105110000` sudah
  database-live dan rollback-only behavior PASS berdasarkan evidence user.
- Task 4 Credit Note open-credit migration `20261105120000` sudah database-live;
  first/closing postflight dan tiga rollback-only behavior PASS berdasarkan
  evidence user.
- Task 5 belum mempunyai ledger/runtime yang terbukti. State target Task 5
  masih **`NOT_INSTALLED` berdasarkan repository/handoff**, tetapi classification
  production final wajib dikonfirmasi lagi melalui SELECT-only preflight atas
  ledger **dan** object/data state sebelum Fase B.
- Authenticated Task 4 posting smoke dan UAT belum terbukti. Task 5 tidak boleh
  memakai rollback behavior Task 4 sebagai pengganti smoke/UAT tersebut.

## 3. Active call chain dan identifier sources

### 3.1 Open-item registry dan allocation

Definisi aktif berada pada:

- `supabase/migrations/20261105100000_backoffice_ar_open_item_foundation.sql:67-175`;
- `supabase/migrations/20261105100000_backoffice_ar_open_item_foundation.sql:602-661`;
- `supabase/migrations/20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql:72-119`.

Kontrak yang terbukti:

- `ar_open_item_registry` hanya menerima `INVOICE`, `RECEIPT`, `CREDIT_NOTE`,
  dan `PRICE_CORRECTION`;
- `ar_open_item_operations` aktif hanya menerima backfill dan `POST_RECEIPT`;
- `ar_open_item_allocations` menghubungkan satu debit item dan satu credit item;
- allocation guard mengunci kedua item, mensyaratkan direction benar dan
  Customer sama, lalu menolak over-allocation;
- constraint aktif hanya menerima source `RECEIPT_ALLOCATION`, `CREDIT_NOTE`,
  atau `PRICE_CORRECTION` dan mewajibkan `reversal_of_allocation_id IS NULL`;
- `get_finance_ar_open_items(uuid,boolean)` menghitung residual dari penjumlahan
  allocation mentah dan belum mempunyai effective allocation date atau reversal
  semantics.

Implikasi: Task 5 memerlukan forward migration additive untuk operation kind,
source/reversal shape, effective date, dan read semantics. Migration live lama
tidak boleh diedit atau dijalankan ulang.

### 3.2 Credit Note open credit

Task 4 mendaftarkan Credit Note native Backoffice baru sebagai credit item penuh
tanpa allocation. Definisi dan consumer contract terdapat pada:

- `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql`;
- `docs/audits/BACKOFFICE_AR_CREDIT_NOTE_OPEN_CREDIT_IMPACT_2026-11-05.md`.

Open credit ini Customer-scoped dan tidak otomatis mengurangi source Invoice.

### 3.3 Refund lama

Runtime lama:

- `public.post_backoffice_sales_customer_refund(...)` pada
  `supabase/migrations/20260917150000_backoffice_sales_customer_refund.sql:346-517`;
- `public.reverse_backoffice_sales_customer_refund(...)` pada file yang sama
  baris `519-665`;
- API `backoffice/src/app/api/finance/backoffice-credit-notes/[id]/refunds/route.ts`.

Kontrak aktif yang terbukti:

- hanya menerima Credit Note Posted dengan `refund_liability_amount > 0`;
- residual dibatasi terhadap Refund Liability, bukan AR open-credit residual;
- metode settlement hanya `CASH_DRAWER` atau `DIRECT_BANK`;
- post journal: Debit `CUSTOMER_REFUND_LIABILITY`, Kredit Cash/Bank;
- reversal membuat jurnal pembalik dan mempertahankan immutable source lineage;
- permission: `finance.customer_refunds` capability `POST`/`REVERSE`.

Karena Task 4 Credit Note baru mempunyai `refund_liability_amount = 0`, runtime
lama **tidak kompatibel** untuk Task 5. Menghapus eligibility guard saja akan
menghasilkan account ownership yang salah. Jalur legacy Refund Liability dan
`RETAINED_RETAIL` wajib tetap memakai runtime lama.

### 3.4 Customer Balance

Foundation dan maker/checker aktif bersumber dari:

- `supabase/migrations/20260805090000_g4_phase49_customer_balance_foundation.sql`;
- `supabase/migrations/20260805130000_g4_phase52_customer_balance_sale_credit.sql`;
- `supabase/migrations/20260827120000_finance_historical_collection_customer_advance.sql`;
- permission catalog `finance.customer_balances` pada
  `20260812120000_acp_phase2_shadow_permission_foundation.sql:138`.

Kontrak yang terbukti:

- ledger immutable dan `customers.current_balance` diperbarui dalam transaksi;
- correction flow memakai maker/checker dan melarang maker menyetujui request
  sendiri;
- correction memakai source `MANUAL_CORRECTION`; itu bukan lineage yang benar
  untuk konversi open credit;
- credit Customer Balance hanya boleh saat policy aktif dan Customer aktif;
- permission didukung: `VIEW`, `MANAGE`, `REVIEW`, `APPROVE`, `EXPORT` dan
  feature `customer_balance_enabled`.

Implikasi: Task 5 memerlukan source/linkage khusus ke operasi open credit dan
tidak boleh menyamarkan konversi sebagai manual correction.

### 3.5 Client/read panel aktif

- `backoffice/src/app/api/finance/customer-receipts/route.ts:26-43` memanggil
  `get_finance_ar_open_items`.
- `backoffice/src/components/CustomerReceiptView.tsx:215` hanya menampilkan
  open debit/credit residual read-only dan menyatakan Finance memilih Invoice
  Customer yang sama.
- Belum ada mutation UI/API untuk Apply Credit Note, AR-native Refund, atau
  Convert to Customer Balance.
- Runtime `private.post_pos_sale_core(...)` pada
  `20260805160000_g4_phase56_customer_balance_tender.sql` terbukti dapat
  memakai Customer Balance untuk Sale/POS, tetapi tidak ada mutation native
  Backoffice Invoice yang terbukti memakai Customer Balance. Task 5 harus
  menambah jalur settlement Invoice Posted tanpa membuka tender pada SO/Draft
  Invoice.

## 4. Impact map

### 4.1 Direct impact

- schema/constraint open-item operation dan allocation;
- effective allocation/reversal date dan residual calculation;
- mutation RPC Apply, Refund, Convert, dan reversal;
- mutation RPC untuk memakai Customer Balance pada Backoffice Invoice Posted;
- AR-native refund Finance Event/Journal serta Cash/Bank settlement;
- Customer Balance ledger/source linkage untuk conversion;
- permission/maker-checker workflow dan immutable audit;
- Finance UI/API untuk memilih Credit Note, Invoice target, tanggal, metode,
  nominal, reviewer, dan reversal.

### 4.2 Downstream impact

- Invoice outstanding/payment context, Customer Receipt candidates, AR Aging,
  Customer Statement, revision planner, dan read RPC open items;
- accounting period dan prior-period adjustment untuk Refund/Convert;
- payment-method Store/effective-date/proof rules;
- Customer Balance policy, balance statement, tender availability, dan
  `customers.current_balance`;
- status/residual Backoffice Invoice setelah settlement Customer Balance;
- legacy refund status/history and Credit Note display;
- exports/report and audit views.

### 4.3 Explicitly preserved

- POS Retail, cashier session, POS payment verification, dan POS refund;
- Backoffice Sales Order, dispatch, delivery, reservation, Stock/FIFO/HPP;
- posting dan Journal Credit Note Task 4;
- Customer Receipt Cash/Bank-to-AR journal ownership;
- legacy `RETAINED_RETAIL` dan Refund Liability refund/reversal;
- historical Posted documents/Journals dan allocations Task 2;
- price correction;
- Company lain dan cross-tenant isolation.

### 4.4 Regression risks

- double consumption bila refund/convert membuat jurnal tetapi credit residual
  tidak direkonsiliasi atomically;
- incorrect as-of report bila `created_at` dipakai sebagai tanggal allocation;
- over-allocation saat dua reviewer memproses credit yang sama;
- reversal membuka credit dua kali atau tidak memulihkan Invoice residual;
- Customer Balance naik tanpa liability journal atau sebaliknya;
- legacy Refund Liability ikut berpindah ke AR-native path;
- cross-Customer/cross-Company allocation;
- maker menyetujui request sendiri;
- retry dengan payload berbeda diterima;
- locked period dilewati atau jurnal memakai tanggal yang salah.

## 5. Target transaction model yang sudah dapat dikunci

### 5.1 Apply to Invoice

- request berisi satu credit item, satu/lebih debit Invoice item, nominal per
  Invoice, effective date, expected residual/version snapshot, dan idempotency;
- approval memasukkan allocation rows dalam satu transaksi;
- jumlah total tidak boleh melampaui residual credit atau target debit;
- tidak membuat Finance Event/Journal baru;
- reversal append-only menetralkan allocation lama dan membuka residual kembali;
- read consumer menghitung net allocation termasuk reversal dan effective date.

### 5.2 Refund Cash/Bank

- request memilih credit item, nominal, tanggal, payment method, reference,
  evidence, notes, dan idempotency;
- approval membuat satu AR debit item yang bersumber dari journal refund,
  satu allocation Credit Note -> refund debit item, serta Cash/Bank Journal;
- journal: Debit AR, Kredit Cash/Bank;
- semua efek harus satu transaksi; kegagalan salah satu layer menggagalkan semua;
- reversal membuat exact reversing Journal dan append-only reversal allocation.

`ar_open_item_registry` belum menerima jenis debit item refund. Nama identifier
baru belum dikunci sebelum collision inventory dan production preflight.

### 5.3 Convert to Customer Balance

- hanya tersedia ketika policy Customer Balance `ACTIVE`, feature aktif,
  Customer aktif, dan permission sesuai;
- approval membuat Debit AR / Kredit Customer Balance Liability, Customer
  Balance credit ledger, satu AR debit item, dan allocation Credit Note -> debit
  item dalam satu transaksi;
- reversal harus membalik Journal dan Customer Balance ledger serta membuka
  residual open credit. Reversal ditolak bila saldo sudah terpakai dan reversal
  akan membuat balance negatif, kecuali proses koreksi lain yang disetujui
  Finance tersedia.

Nama source type Customer Balance dan item kind baru belum dikunci sebelum
collision inventory dan production preflight.

### 5.4 Gunakan Customer Balance pada Backoffice Invoice Posted

- tindakan hanya tersedia setelah native Backoffice Invoice berstatus Posted
  dan mempunyai residual AR;
- tidak tersedia pada pembuatan SO, confirmation, dispatch, Draft Invoice, atau
  initial Invoice posting;
- nilai maksimal adalah nilai terkecil antara Customer Balance tersedia dan
  residual Invoice;
- Customer dan Company harus sama;
- journal: Debit `CUSTOMER_BALANCE_LIABILITY`, Kredit
  `CUSTOMER_RECEIVABLE`;
- Customer Balance ledger membuat debit entry dan open-item runtime
  merekonsiliasi credit AR journal line tersebut ke Invoice debit item;
- tidak mengubah harga, discount, tax, revenue, Stock, Reservation, FIFO/HPP,
  atau Cash/Bank;
- reversal membalik Journal, memulihkan Customer Balance, dan membuka kembali
  residual Invoice secara append-only.

Direct Apply Credit Note dan Convert ke Customer Balance sama-sama tersedia.
Finance memakai direct Apply ketika Invoice tujuan sudah jelas, atau Convert
ketika kredit ingin disimpan untuk Invoice lain di kemudian hari.

## 6. Concurrency, idempotency, retry, dan rollback

- mutation mengunci Company/operation key, credit item, semua target debit item,
  source document, dan maker/checker request dalam urutan deterministik;
- exact retry mengembalikan response snapshot; same key/different hash ditolak;
- expected version/residual snapshot ditolak bila stale;
- operation, allocation, event, journal, ledger, balance, dan audit berada dalam
  satu database transaction;
- reversal adalah operation baru dan tidak mengubah/menghapus row lama;
- migration rollback bukan downgrade production. Setelah ledger live, koreksi
  memakai forward-fix migration; rollout behavior dijalankan dalam transaction
  rollback-only.

## 7. Regression matrix wajib

1. Credit Note residual lebih kecil/sama/lebih besar dari target Invoice.
2. Apply partial/full ke satu dan beberapa Invoice.
3. Same Customer/Company PASS; different Customer/cross Company ditolak.
4. Invoice open/settled, credit open/settled, stale snapshot, concurrent apply.
5. Partial/full refund Cash dan Bank; invalid/inactive/out-of-store method;
   required proof; open/locked/prior period.
6. Mixed apply + refund; mixed apply + convert; seluruh credit habis tepat.
7. Customer Balance ACTIVE/WIND_DOWN/DISABLED, Customer active/inactive, feature
   on/off, saldo sudah terpakai sebelum reversal.
8. Customer Balance apply partial/full ke satu Invoice Posted; saldo kurang,
   sama, atau lebih besar dari outstanding; SO/Draft Invoice tetap menolak saldo.
9. Maker/checker separation, unauthorized role, exact retry, changed retry,
   duplicate operation, reversal retry.
10. AR Aging, Statement, Invoice context, Receipt candidates, open-item panel dan
   as-of sebelum/sesudah allocation/reversal.
11. Legacy native allocation, `RETAINED_RETAIL`, Refund Liability refund,
    price correction, Customer Receipt, POS Retail tetap sama.
12. Zero Stock/Reservation/FIFO/HPP/cashier-session effect.
13. Full rollback ketika Event, Journal, allocation, balance ledger, atau audit
    gagal di tengah transaksi.

## 8. Hole yang memengaruhi desain

### 8.1 Approval model tindakan manual

Keputusan user 2026-11-06: Task 5 tidak menambah maker/checker terpisah. Apply,
Refund Cash/Bank, Convert, Customer Balance settlement, dan reversal dilakukan
langsung oleh satu actor Finance yang mempunyai capability terkait. Ini
mempertahankan pola operasional refund existing.

Single actor tidak mengurangi server guard: setiap tindakan tetap wajib
Company/Customer-scoped, permission-checked, atomic, period-aware bila membuat
Journal, idempotent, stale-version guarded, audited, dan reversible. Flow
maker/checker existing pada **manual Customer Balance correction** tetap
dipertahankan dan tidak dilonggarkan oleh Task 5.

### 8.2 Effective date Apply

Apply tidak membuat jurnal, tetapi tanggalnya memengaruhi aging/as-of dan audit.

**Rekomendasi:** maker wajib memilih effective date, tidak boleh sebelum tanggal
Credit Note atau Invoice target, dan tidak boleh setelah tanggal Company.
Accounting period check hanya wajib untuk tindakan yang membuat Journal; Apply
tetap menyimpan effective date tanpa mengubah Posted Journal lama.

### 8.3 Reversal setelah Customer Balance telah dipakai

Membalik conversion dapat membuat Customer Balance negatif.

**Rekomendasi:** reversal fail-closed bila available Customer Balance kurang dari
nilai conversion. Finance harus membatalkan penggunaan berikutnya atau memakai
proses koreksi terkontrol sebelum reversal.

### 8.4 Scope UI Fase B

Task roadmap memisahkan runtime Task 5 dan UI/report lengkap Task 7, sedangkan
authenticated smoke membutuhkan entry point resmi.

**Rekomendasi:** Task 5 menyediakan UI minimal operasional pada panel open-item
Finance untuk create/review/reverse dan history dasar. Penyempurnaan report,
filter, dan Credit Note detail penuh tetap Task 7.

### 8.5 Keputusan user 2026-11-06 yang sudah ditutup

- Direct Apply Credit Note ke Invoice dan Convert ke Customer Balance keduanya
  tersedia.
- Customer Balance pada mode Backoffice hanya dapat dipakai sebagai settlement
  setelah Invoice Posted; tidak tersedia pada pembuatan SO atau initial Invoice.
- Settlement boleh partial atau penuh sampai batas residual Invoice dan saldo
  Customer yang tersedia.
- UI minimal operasional termasuk dalam Task 5; penyempurnaan report tetap
  Task 7.

## 9. Hasil production preflight dan gate Fase B

Output production 2026-11-06 mengklasifikasikan Task 5 sebagai
`NOT_INSTALLED`: ledger belum ada dan tidak ditemukan candidate routine Task 5.
Seluruh dependency sampai `20261105120000` terpasang, active function digest
sesuai preflight, allocation identity valid, active Finance queue nol, dan
nonterminal Offline submission nol.

Bukti operasional yang tersedia:

- KMS, LSM, dan SMS memakai `BACKOFFICE_DELIVERED_QTY_INVOICE` serta tidak
  mengaktifkan Sales Tax;
- setiap Company mempunyai satu metode Cash `CASH_DRAWER`, satu BCA
  `DIRECT_BANK`, serta fallback aktif untuk `CASH_DRAWER`, `BANK_RECEIPT`, dan
  `CUSTOMER_RECEIVABLE`;
- accounting period mempunyai empat period yang dapat diposting per Company;
- terdapat 545 Invoice open-item, 184 masih open, dengan total residual
  Rp952.433.500,08;
- belum ada production Task 4 Credit Note open-credit row. Nilai nol ini hanya
  inventory, bukan behavioral proof;
- legacy refund tetap tiga row (dua Refund dan satu Reversal) dengan net
  Rp2.720.000 dan wajib tetap berada pada jalur compatibility lama.

### 9.1 Customer Balance dependency belum terklasifikasi penuh

Direct Apply dan AR-native Cash/Bank Refund tidak mempunyai blocker
konfigurasi dari preflight. Convert ke Customer Balance dan penggunaan
Customer Balance pada Posted Backoffice Invoice belum aktif untuk KMS/LSM/SMS
karena seluruh Company masih memenuhi keadaan berikut:

- feature `customer_balance_enabled=false`;
- lifecycle `DISABLED`;
- active system Customer Balance payment method nol;
- fallback `CUSTOMER_BALANCE_LIABILITY` nol pada inventory preflight;
- Customer dengan saldo dan total saldo sama-sama nol.

Nilai fallback nol **bukan bukti resolver akun gagal**. Definisi aktif
`private.resolve_customer_balance_account` mencoba direct transaction rule,
kemudian Company fallback, kemudian account dengan `system_function_key`.
Migration KMS `20260929120000` bahkan mendefinisikan direct mapping
`CUSTOMER_BALANCE_LIABILITY` ke account `2050100`. Preflight Task 5 sebelumnya
hanya menghitung fallback sehingga belum membuktikan tiga jalur resolver untuk
KMS/LSM/SMS.

Task 5 tidak boleh mengarang akun, mengaktifkan feature, atau membuat mapping
Finance secara diam-diam. Sebelum dependency diperbaiki atau activation
dirancang, diagnosis SELECT-only lanjutan wajib membuktikan direct rule,
fallback, system-function account, category, policy, method, dan trigger sync
per Company. Sampai bukti itu kembali, status dependency adalah
`BELUM TERBUKTI`, bukan `BLOCKER` maupun `READY`.

Diagnosis tersebut tersedia di
`supabase/diagnostics/backoffice_ar_customer_balance_dependency_diagnosis.sql`.
File ini hanya mempunyai satu statement `WITH ... SELECT`, lulus parser
PostgreSQL AST, dan tidak mengandung DDL/DML/control statement.

Eksekusi pertama diagnosis mengembalikan `mapping_resolution BLOCKER` dengan
`violation_rows=0`. Seluruh 11 instance category-path sebenarnya resolve lewat
`DIRECT_RULE` atau `COMPANY_FALLBACK`; status salah berasal dari harness yang
mengharapkan tepat sembilan row. Repository tidak mewajibkan satu category per
system key, dan migration KMS `20260929120000` secara eksplisit mengharapkan
ekspansi 67 pair menjadi 71 mapping karena category aktif dapat lebih dari satu.

Perbaikan diklasifikasikan `TEST_HARNESS_FIX`: kontrak sekarang mewajibkan
sembilan identitas Company/system-key/function, minimal satu category aktif per
identitas, dan setiap instance category aktif harus mempunyai tepat satu
resolution tier yang valid. Assertion mapping tidak dihapus atau dilemahkan.
File terkoreksi kembali lulus parser satu statement dan write-token scan nol.

Production rerun file terkoreksi menghasilkan `PASS`: `expectedPathRows=9`,
`missingPathRows=0`, dan `invalidCategoryRows=0`. Output tetap mengembalikan
seluruh 11 category instance beserta `categoryId`, direct/fallback/system row,
account code/name, dan resolution tier. Karena itu PASS bukan hasil
menyembunyikan duplicate category; semua instance tetap diuji dan terbukti
resolve. Company policy/method foundation, feature-sync trigger, ledger/cache
integrity, dan runtime boundary juga PASS.

Kesimpulan dependency: tidak ditemukan kerusakan mapping atau foundation.
Customer Balance tetap sengaja belum operasional karena entitlement/policy
KMS/LSM/SMS masih `false`/`DISABLED` dan system method inactive. Activation
adalah perubahan konfigurasi berikutnya, bukan perbaikan data yang gagal.

Active call chain dan database state Task 5 sekarang `PROVEN`. Customer Balance
dependency juga telah diklasifikasikan: foundation dan resolver account valid,
sedangkan entitlement/policy KMS/LSM/SMS memang masih nonaktif. Implementasi
Task 5 harus tetap generic dan fail-closed terhadap feature/policy tersebut;
aktivasi Company adalah gate konfigurasi terpisah dan tidak dilakukan diam-diam.

### 9.2 Identifier dan file plan Fase B

Forward migration candidate menggunakan version `20261106100000`; version ini
telah diinventarisasi absent pada ledger dan routine candidate Task 5 juga absent.
Migration live Task 2/3/4 tetap immutable.

Identifier additive yang dipakai Task 5:

- operation kind: `APPLY_CREDIT`, `REFUND_CREDIT`, `CONVERT_CREDIT_BALANCE`,
  `APPLY_CUSTOMER_BALANCE`, dan `REVERSE_OPEN_CREDIT_ACTION`;
- registry item kind: `AR_REFUND`, `AR_BALANCE_CONVERSION`, dan
  `AR_BALANCE_USAGE`;
- allocation source kind: `OPEN_CREDIT_APPLY`, `OPEN_CREDIT_REFUND`,
  `OPEN_CREDIT_CONVERSION`, `CUSTOMER_BALANCE_USAGE`, serta reversal allocation;
- Customer Balance ledger source: `OPEN_CREDIT_CONVERSION` dan
  `BACKOFFICE_INVOICE_PAYMENT`.

Planned files dibatasi pada satu forward migration, pre/postflight, rollback-only
behavior, rollout note, satu Route Handler mutation, panel operasional minimum
di `CustomerReceiptView`, focused UI contract, root status docs, dan handoff.
Tidak ada perubahan pada SO, dispatch, initial Invoice posting, POS Retail,
legacy Refund Liability, Stock/FIFO/HPP, atau migration live lama.

Precondition package wajib membuktikan Task 2/3/4 live konsisten, Task 5 absent,
candidate identifier tidak bertabrakan, Customer Balance resolver valid,
Backoffice/tax boundary, serta queue idle. Behavioral package wajib menguji
partial/full apply, Cash/Bank refund, conversion, Posted-Invoice balance use,
reversal, exact/changed retry, stale/cross-Company/cross-Customer denial,
legacy/POS/Stock/FIFO zero-regression, dan rollback seluruh fixture.

## 10. Checklist evidence-first sebelum SQL diberikan

- [x] identifier existing berasal dari defining migration/runtime aktif;
- [x] state Task 2/3/4 dipisahkan dari state Task 5;
- [x] production state Task 5 diklasifikasikan melalui ledger + object/data;
- [x] keputusan bisnis pada bagian 8 ditutup;
- [x] candidate routine collision inventory lolos;
- [x] precondition dan expected outcome test ditulis pada bagian 7 dan 9.2;
- [x] failure path, compatibility, dan rollback/forward-fix final ditulis pada
  bagian 4, 6, 7, dan 9.2;
- [x] migration, postflight, dan rollback-only behavior utuh lulus parser
  struktural lokal; parser ini tidak menggantikan eksekusi PostgreSQL/Supabase.

## 11. Status implementasi lokal 2026-11-06

Candidate Task 5 telah tersedia di local repository tetapi **belum dijalankan
ke database mana pun**. Evidence lokal yang sudah ada:

- migration parser: 22 statement `PARSE_PASS`;
- postflight parser: 1 statement `PARSE_PASS`;
- rollback-only behavior parser: 2 statement `PARSE_PASS`;
- scoped ESLint: PASS;
- TypeScript `--noEmit`: PASS;
- Next production build: PASS;
- focused UI contract: 5/5 PASS.

Evidence tersebut membuktikan struktur, kompilasi, dan kontrak UI/API lokal.
Ia belum membuktikan fungsi PostgreSQL berhasil dibuat atau behavior database
benar pada production state. Status tetap dipisahkan:

- `AUDIT COMPLETE`: YES;
- `LOCAL READY`: menunggu final package/review repository;
- `DATABASE LIVE`: NO;
- `CLIENT DEPLOYED`: NO;
- `SMOKE PASS`: NO;
- `UAT PASS`: NO.

Rollback-only behavior menggunakan satu native historical Backoffice Credit
Note dan membalik allocation snapshot hanya di dalam subtransaction yang
akhirnya dibatalkan. Ia menguji direct allocation, retry, reversal, stale
residual, conversion, penggunaan saldo pada Posted Invoice, Cash/Bank refund,
reversal Journal, cross-Company denial, dan zero Retail/Stock/FIFO effect.
Customer Balance diaktifkan hanya dalam fixture rollback; konfigurasi Company
production tetap tidak disentuh.

## 12. Local Docker execution evidence 2026-11-09

Bagian ini menggantikan status lokal pada bagian 11 tanpa mengubah status
Production. Candidate migration telah dipasang hanya pada Supabase Docker lokal
production-shaped dan diverifikasi terhadap fixture `LOCALBO`.

Evidence database lokal:

- migration ledger Task 5: tepat satu row;
- postflight runtime, privilege, residual, dan constraint contract: seluruhnya
  `PASS`;
- rollback-only behavior: `PASS` untuk apply Credit Note, exact/changed retry,
  reversal, stale/cross-Customer denial, conversion ke Customer Balance,
  pemakaian saldo hanya pada Posted Invoice, Cash/Bank refund, Journal/reversal,
  cross-Company denial, serta zero Retail/Stock/FIFO effect;
- seluruh write behavior dibatalkan oleh test transaction;
- closing local fixture verifier: `PASS`, Stock dan FIFO kedua Company tetap
  tepat `100`.

Kegagalan fixture yang ditemukan selama eksekusi diklasifikasikan dan diaudit,
bukan ditutup dengan menghapus assertion:

- duplicate declaration: `TEST_HARNESS_FIX`;
- missing one-time Backoffice Receipt/Invoice Finance provisioning pada Company
  dummy yang dibuat setelah schema snapshot: `FIXTURE_FIX` pada bootstrap lokal;
- missing canonical Credit Note fallback pada Company dummy: `FIXTURE_FIX`
  melalui canonical provisioning helper;
- Customer Balance permission/feature setup dijalankan setelah fixture feature
  activation memakai RPC canonical: `FIXTURE_FIX`.

Evidence client lokal:

- focused Node UI/API contract: `5/5 PASS`;
- scoped ESLint: `PASS`;
- TypeScript clean run dengan `--incremental false`: `PASS`;
- fresh Next production build: `PASS`;
- authenticated Route Handler smoke: local login dan active Company context
  `PASS`; POST terautentikasi ke
  `/api/finance/ar-open-credit-actions` menghasilkan expected
  `400 AR_ACTION_INVALID`; request ini sengaja tidak membuat business mutation
  dan active Company context dipulihkan setelah test.

Scope klaim saat ini:

- `AUDIT COMPLETE`: YES;
- `LOCAL READY`: YES untuk package/database/API/static client Task 5;
- `DATABASE LIVE`: LOCAL DOCKER ONLY; Production NO;
- `CLIENT DEPLOYED`: NO;
- `AUTHENTICATED ROUTE SMOKE`: PASS tanpa business mutation;
- `FULL BROWSER ACTION SMOKE`: NOT PROVEN;
- `UAT PASS`: NO.

Windows visual-smoke attempt pada 2026-11-09 berhenti sebelum browser dapat
dipilih karena Computer Use helper mengembalikan `native pipe is unavailable`
pada initial call, retry, dan retry setelah kernel reset. Tidak ada click,
form submit, atau business mutation yang terjadi. Kegagalan tooling ini tidak
diubah menjadi UI PASS.

Rollback/forward-fix tetap additive. Production rollout hanya boleh mengikuti
preflight -> migration -> postflight -> rollback behavior -> closing postflight
dan authenticated browser smoke setelah instruksi eksplisit user.

