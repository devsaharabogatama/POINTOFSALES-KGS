# Gate Implementasi dan Rollout POS v1

**Status:** APPROVED delivery guardrail  
**Tanggal:** 2026-07-20  
**Pilot awal:** satu Company, satu Store, satu POS Terminal  
**Prinsip:** gate berikut bersifat berurutan. UI dapat diprototipe, tetapi tidak boleh dianggap selesai atau dihubungkan ke data production sebelum dependency gate lulus.

---

## 1. Checklist Wajib pada Setiap Gate

Setiap gate harus memiliki artefak berikut:

1. requirement ID dan source-of-truth yang dituju;
2. migration forward-only yang dapat dijalankan ulang secara aman atau mempunyai precondition jelas;
3. backfill untuk data lama, termasuk row gagal/ambiguous;
4. RLS, GRANT, API, RPC, dan feature-entitlement guard;
5. idempotency/concurrency contract;
6. automated test dan UAT evidence;
7. observability minimum: correlation/source ID, error status, retry policy, tanpa secret/PII berlebihan;
8. deployment runbook, postflight query, rollback teknis, dan rollback operasional.

Rollback tidak selalu berarti `DROP COLUMN`. Untuk migration data berisiko, gunakan expand → backfill → dual-read/compare → cutover → contract. Setelah transaksi baru dibuat, rollback operasional dapat berarti mematikan feature, menghentikan posting, atau kembali ke read-only sambil mempertahankan histori.

---

## 2. G0 — Baseline dan Migration Control

### Deliverable

- tetapkan canonical migration directory dan manifest urutan file;
- snapshot schema staging/production tanpa secret;
- inventarisasi extension, enum, function signature, trigger, policy, grant, index, dan applied migration;
- klasifikasikan standalone SQL lama: migrate, supersede, atau archive;
- buat data-quality query untuk missing/mismatched `company_id`, duplicate business key, negative stock, orphan FK, unbalanced journal.

### Exit criteria

- database kosong dapat dibangun dari nol;
- snapshot staging dapat di-upgrade tanpa kehilangan data;
- applied-state production terverifikasi, tidak diasumsikan dari repo;
- semua SQL berikutnya mempunyai nomor/owner/dependency/rollback note.

### Stop condition

Jangan lanjut G1 jika schema repo dan schema live belum dapat dibandingkan atau ada orphan tenant yang belum diselesaikan.

---

## 3. G1 — Tenant, Security, Role, dan Feature Entitlement

### Deliverable

- canonical Company/Store/POS/Warehouse/User membership model;
- tenant `NOT NULL` dan cross-table consistency constraint;
- tenant-scoped business keys;
- role assignment scope per Company/Store/Warehouse;
- feature registry Company, hanya dimutasi Super Admin;
- active Company context eksplisit dan audit actor;
- SECURITY DEFINER hardening: fixed search path, minimal execute grants, actor check, input tenant validation;
- matrix RLS/API/RPC seluruh tabel/action.

### Test minimum

- setiap role mencoba SELECT/INSERT/UPDATE/DELETE pada Company sendiri dan Company lain;
- forged `company_id`, `store_id`, `warehouse_id`, `user_id` ditolak;
- feature disabled ditolak oleh API/RPC walau request dibuat manual;
- Company Admin tidak dapat menaikkan user menjadi Super Admin atau menyentuh Company lain;
- Super Admin dapat beroperasi lintas Company tetapi setiap mutation membutuhkan target Company eksplisit.

### Exit criteria

- tidak ada tabel tenant-bearing tanpa policy/constraint yang didokumentasikan;
- tidak ada route client yang memakai service-role key;
- negative access test lulus 100%.

---

## 4. G2 — Canonical Master Data dan Import Framework

### Deliverable

- Product Category, Product, UOM, Product UOM/price, Warehouse, Supplier, Customer, Customer Category, Pricelist, Payment Method, Transaction Category, Tax, dan COA minimum;
- stable internal ID + tenant-scoped code/name rules + active/inactive lifecycle;
- master version/update timestamp untuk cache/offline;
- generic export/import job: template/export, mapping, dry-run, row validation, update warning, partial result, history, downloadable error rows;
- Opening Stock dipisahkan dari Product import;
- no auto-create reference saat Product import kecuali mode eksplisit yang belum diaktifkan pada v1.

### Gate aktif Import/Export

- empat import sederhana (Product Category, UOM, Warehouse, Supplier) sudah
  mencapai API/UI;
- Phase-35 readiness, Phase-36/37 automatic-code DB/UI, dan Phase-38 code-less
  validator sudah PASS; Phase-39 template/export UI dan smoke user selesai;
- Phase-40 migration, forward fix `20260727100000`, postflight, behavioral
  test, dan Phase-38 regression sudah PASS; Phase-41 template/export/preview
  UI untuk Customer Category, COA, dan Transaction Category local-ready dan
  menunggu authenticated smoke;
- ekspansi ke seluruh master yang dapat dibuat user memakai kontrak versioned
  pada `MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`;
- sebelum ekspansi schema/job processor, wajib lulus
  `g2_phase35_full_master_import_preflight.sql`;
- Product, Pricelist, dan Payment Method diproses sebagai atomic group;
- kode teknis Category/UOM/Warehouse/Supplier/Customer Category/Pricelist/
  Payment Method/custom Transaction Category dibuat server-side dan tidak
  diminta pada create template; UUID tetap canonical;
- Product SKU, Customer code, COA account code, Tax code, barcode, dan kode
  Product milik Supplier tetap business-facing;
- Company, Staff/password, Opening Stock, transaksi, stock movement, dan journal
  tidak boleh masuk generic master import.

### Test minimum

- typo reference tidak membuat UOM/Gudang/Kategori baru;
- referensi dapat dipilih dengan ID atau code/name yang unambiguous;
- duplicate/multi-match menghasilkan row error;
- satu row gagal tidak membatalkan row valid;
- update existing menyimpan before/after audit;
- import Company A tidak dapat reference master Company B;
- UOM factor, precision, weight, dan price per UOM tervalidasi.

### Exit criteria

- user dapat membuat/edit master via form maupun import dengan hasil yang sama;
- Product dan stock tidak lagi bergantung pada free-text category/UOM/warehouse;
- cache payload master mempunyai version contract.

---

## 5. G3 — Stock Ledger, FIFO, Bundle, Opname, dan Adjustment

### Deliverable

- satu atomic stock-posting service/RPC untuk semua movement source;
- base-UOM quantity snapshot dan Product-Warehouse balance;
- movement immutable, source unique, actor/time/status tercatat;
- nonnegative final stock dengan row lock/atomic guarded update;
- Opening, Receipt, Transfer, Sale, Return, Bundle, Ketul, Opname, Adjustment event type;
- FIFO receive/consume/return/reversal dan valuation;
- Bundle expansion tanpa nested Bundle;
- Stock Opname blind count dan posting Adjustment tanpa membekukan penjualan;
- stock real, movement/card, valuation, opname report/read model.

### Test minimum

- qty nol/negatif ditolak;
- 20 checkout/transfer concurrent tidak membuat stock negatif atau lost update;
- duplicate source/idempotency tidak menggandakan movement;
- UOM jual dikonversi tepat ke base;
- Bundle mengurangi komponen tepat sekali;
- FIFO multi-batch dan return mengembalikan layer sesuai contract;
- Opname yang overlap dengan sale menghasilkan variance deterministik sesuai timestamp/policy;
- Company/Warehouse mismatch ditolak.

### Exit criteria

- balance dapat direkonstruksi dari movement;
- `product_stocks` sama dengan agregat ledger pada reconciliation query;
- tidak ada jalur mutation stock langsung dari client/table API.

---

## 6. G4 — POS Online/Offline dan Operasional Kasir

### Deliverable

- production PWA shell: auth, active Company/Store/Terminal, Cashier Session, master sync, cart, Draft/Hold/Pending list;
- server price resolver: Product fallback, Global Pricelist/tier, Customer Pricelist, manual discount, Tax, rounding kelipatan 100;
- atomic checkout menggunakan stock ledger, payment validator, Customer Balance, TEMPO, receipt snapshot, dan Financial Event contract;
- shortage menjadi Draft tanpa stock/journal effect;
- offline queue dengan allowance, client transaction ID, idempotency key, retry/error state, acknowledgement, master version, dan conflict UX;
- Payment Method/split/evidence URL;
- Expense, close session, Deposit multi-session, Excel session flow;
- notification/action links untuk RO pending, low stock, payment/approval, dan sync error;
- Ketul hanya setelah core checkout/stock stabil dan feature enabled.

### Test minimum

- price/HPP/total/status tampering dari client ditolak atau dihitung ulang;
- payment sum, change, rounding, tax, discount, Customer Balance, TEMPO konsisten;
- retry online/offline 10 kali menghasilkan satu sale/movement/event;
- jaringan putus pada setiap tahap sync dapat dipulihkan tanpa kehilangan local record;
- stale catalog/stock menghasilkan resolvable conflict, bukan silent overwrite;
- receipt/reprint menggunakan snapshot transaksi, bukan master terbaru;
- feature disabled tidak muncul dan API menolak;
- cash/session/deposit/expense flow merekonsiliasi expected vs actual.

### Exit criteria

- tidak ada `MOCK_PRODUCTS` atau mock checkout pada production entrypoint;
- transaksi pilot dapat ditelusuri dari local client ID hingga sale, movement, payment, event, dan receipt;
- offline UAT lulus pada koneksi diputus/nyambung berulang.

---

## 7. G5 — Purchasing Dasar

### Deliverable

- Request Order dari POS/Sales;
- Store Manager membuat/group Supplier Order per Supplier dan menentukan qty final;
- Goods Receipt partial/lebih dengan accepted/rejected/damaged dan source document;
- stock/FIFO hanya dari qty accepted;
- Return Supplier partial/full;
- Supplier invoice, provisional AP/valuation, real price adjustment, tolerance/matching;
- supplier bank info dapat disalin Finance saat payment;
- status history dan notification pending.

### Test minimum

- partial receipt berulang tidak melebihi state order tanpa warning/policy;
- product/warehouse/supplier Company mismatch ditolak;
- duplicate receipt tidak menggandakan stock/FIFO/AP;
- rejected/damaged tidak masuk sellable stock;
- Return mengurangi stock dan menghasilkan debit-note/AP effect sesuai source;
- price invoice berbeda dari receipt menghasilkan variance, bukan rewrite layer tanpa audit.

### Exit criteria

- setiap stock masuk dapat dilacak ke receipt;
- AP provisional dan invoice real dapat direkonsiliasi;
- flow confirm-purchase lama telah dimigrasikan atau dinonaktifkan dengan aman.

---

## 8. G6 — Finance Core, Posting, Reconciliation, dan Report

### Deliverable

- COA hierarchy/configuration, account function, Transaction Category mapping version;
- canonical Financial Event yang immutable/idempotent;
- journal posting balanced, source-linked, approval-aware, reversible, period-locked;
- Cash/Bank, AR/TEMPO/collection, Customer Balance liability, AP/purchase/payment, Expense, Deposit variance, Tax, Stock/HPP, Bundle allocation, Ketul, Debit/Credit Note;
- reconciliation per account/source;
- report minimum dan pending/draft/hold analysis;
- external evidence URL visible pada Finance flow;
- dead-letter/retry workspace untuk event gagal.

### Test minimum

- setiap event fixture menghasilkan debit=credit;
- missing/ambiguous mapping masuk error queue, bukan jurnal setengah;
- duplicate event tidak menggandakan journal;
- posted period menolak mutation dan hanya menerima reversal pada period terbuka;
- subledger AR/AP/Customer Balance sama dengan control account;
- stock valuation ledger sama dengan inventory account setelah reconciliation;
- Finance dapat override konfigurasi yang diizinkan dan audit before/after tersimpan;
- report dapat drill down ke source document.

### Exit criteria

- seluruh mapping wajib untuk feature pilot lengkap;
- trial balance seimbang dan tidak ada orphan event/journal;
- close/reopen/reversal UAT lulus;
- hard-coded COA worker lama tidak lagi menjadi execution path aktif.

---

## 9. Pilot, Cutover, dan Rollback

### Deployment timing

Kondisi project saat G1 adalah **runtime lokal + GitHub untuk versioning + Supabase**. Belum ada Vercel project dan tidak perlu membuat deployment hanya untuk menyelesaikan migration gate.

Urutan deployment yang disetujui:

1. **G1 berjalan:** Backoffice/PWA tetap lokal. Push GitHub dipakai untuk versioning/review, bukan tanda siap deploy.
2. **Setelah G2 lulus:** buat Vercel project dan environment **Preview** untuk Backoffice serta PWA. Konfigurasi environment variable, Supabase Auth redirect/allowlist, domain preview, dan server-only secret. Preview hanya memakai test/UAT data dan belum menerima transaksi operasional.
3. **Setelah G3 dan G4 lulus lokal:** gunakan Preview untuk internal end-to-end UAT Product/Stock/Session/Checkout, pengukuran network/function/egress, serta retry/concurrency. Feature optional tetap disabled kecuali UAT-nya sendiri sudah lulus.
4. **Setelah G5 dan G6 serta seluruh cutover checklist lulus:** buat deployment **Production pilot** untuk satu Company, satu Store, dan satu POS Terminal.
5. **Setelah pilot reconciliation stabil:** perluas Store/Terminal bertahap. Jangan menganggap GitHub push, Vercel build PASS, atau Preview URL sebagai production approval.

Auto-deploy Production dari branch kerja tidak boleh diaktifkan. Production harus memakai protected branch/tag atau approval manual dan selalu merujuk migration manifest + rollout evidence yang sesuai.

### Pilot scope

- satu Company;
- satu Store;
- satu POS Terminal;
- user terbatas: Super Admin, Company Admin, Store Manager, Finance, satu-dua Cashier;
- master dan opening stock telah direview dua orang;
- Ketul/Customer Balance/Tax hanya dinyalakan bila UAT fiturnya lulus.

### Cutover checklist

1. freeze input master lama selama window singkat;
2. backup/snapshot dan catat row count/checksum;
3. jalankan migration + backfill + postflight;
4. import master, review error, lalu Opening Stock;
5. lakukan controlled sale Cash, Transfer, TEMPO, Return, Expense, Deposit, Receipt;
6. cocokkan stock movement, session cash, AR/AP, event, journal, dan reports;
7. buka pilot dengan monitoring error queue dan daily reconciliation.

### Rollback trigger

- cross-tenant visibility/mutation;
- stock negatif/lost movement;
- duplicate sale/payment/journal akibat retry;
- jurnal tidak balance;
- offline queue kehilangan transaksi;
- discrepancy material yang tidak dapat ditelusuri ke source.

### Rollback action

- matikan feature/checkout mutation dan pertahankan read-only;
- hentikan worker Finance jika sumber event bermasalah;
- jangan hapus transaksi pilot;
- export source/event/movement/journal untuk reconciliation;
- gunakan compensating reversal/adjustment setelah penyebab disetujui;
- restore hanya jika runbook membuktikan tidak menghilangkan transaksi sah setelah snapshot.

---

## 10. Urutan Kerja Pertama

Sprint implementasi pertama sebaiknya hanya mencakup:

1. G0 migration manifest dan live-state audit;
2. G1 tenant constraint/RLS/feature entitlement;
3. desain canonical master schema G2 beserta import dry-run contract;
4. test harness tenant + RPC concurrency yang akan dipakai semua gate.

Jangan mulai dari mempercantik halaman Produk atau menambah menu POS. Kedua UI tersebut baru aman disambungkan setelah contract G1–G3 stabil.
