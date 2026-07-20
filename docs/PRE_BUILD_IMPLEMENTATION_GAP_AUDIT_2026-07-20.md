# Audit Gap Implementasi Sebelum Build POS v1

**Tanggal:** 2026-07-20  
**Jenis:** read-only audit terhadap file repository  
**Status:** baseline implementasi; bukan bukti deployment production  
**Scope:** schema/SQL, RLS, RPC, API Backoffice, PWA, UI Backoffice, dan test yang tersedia.

---

## 1. Batas Audit

Audit ini tidak membuka dashboard Supabase/Vercel, tidak membaca secret, tidak menjalankan migration ke database, dan tidak mengubah schema/kode aplikasi. Karena itu:

- status migration yang benar-benar sudah diterapkan di production adalah **BUTUH VERIFIKASI LIVE**;
- hasil di bawah adalah fakta dari file repository pada tanggal audit;
- `database-current-state.md` dan `multi-company-gap-analysis.md` tetap dianggap snapshot historis;
- spesifikasi business terbaru berada pada dokumen modul yang dirutekan oleh `README.md`.

Status yang digunakan:

- **SUDAH ADA**: execution path minimum ditemukan pada repo;
- **PERLU DIPERBAIKI**: ada implementasi, tetapi belum memenuhi invariant/spec;
- **BELUM ADA**: tidak ditemukan execution path aktif;
- **DEFERRED**: sengaja di luar POS v1.

---

## 2. Kesimpulan Eksekutif

Repository sudah memiliki fondasi multi-company, beberapa RLS helper, atomic checkout RPC, stock tables, FIFO tables, Backoffice context switch, server-only service-role usage, dan prototipe PWA. Namun POS v1 **belum aman untuk dibangun langsung di atas jalur transaksi sekarang**.

Blocker utamanya:

1. checkout menerima harga, subtotal, HPP, payment status, dan total dari client tanpa kalkulasi ulang server;
2. transfer stock menerima qty negatif dan belum aman terhadap concurrency;
3. checkout belum menerapkan UOM-to-base, FIFO allocation, Bundle component deduction, Pricelist, Tax, rounding, atau warehouse scope aktif;
4. product import auto-membuat UOM/Gudang dan bersifat all-or-nothing, berlawanan dengan flow master-first dan partial result;
5. purchasing masih satu langkah `confirm purchase`, belum Request Order → Supplier Order → partial receipt → invoice/AP/matching;
6. Finance worker masih hard-coded COA dan masih memakai model Cash Advance lama;
7. PWA aktif masih memakai mock product dan belum tersambung ke offline sync path yang tersedia;
8. test suite hanya mencakup tiga kasus dan belum menguji tampering, concurrency, role matrix, UOM, FIFO, Bundle, offline, ataupun journal balance.

Rekomendasi: jangan menambah UI modul besar lebih dahulu. Mulai dari G1 tenant/security dan G2 canonical master-data contract, lalu bangun ledger stock G3 sebelum checkout G4.

### Evidence map utama

| Area | Anchor repository |
|---|---|
| Client totals diteruskan ke RPC | `backoffice/src/app/api/pos/checkout/route.ts:15`, `backoffice/src/app/api/pos/sync/route.ts:14` |
| Checkout menyimpan angka detail/client dan mengurangi stock | `supabase/checkout_rpc.sql:87`, `supabase/checkout_rpc.sql:95`, `supabase/checkout_rpc.sql:129` |
| Tenant/actor guard checkout | `supabase/checkout_rpc.sql:65`, `supabase/checkout_rpc.sql:100` |
| Transfer tanpa positive-qty/concurrency guard | `supabase/transfer_rpc.sql:35`, `supabase/transfer_rpc.sql:44` |
| Purchase confirm satu langkah | `supabase/confirm_purchase_rpc.sql:19`, `supabase/confirm_purchase_rpc.sql:37`, `supabase/confirm_purchase_rpc.sql:58` |
| Import membuat UOM/Gudang otomatis | `supabase/migrations/002_secure_tenant_product_weight_import.sql:241`, `supabase/migrations/002_secure_tenant_product_weight_import.sql:246` |
| Import route fixed CSV/single RPC | `backoffice/src/app/api/products/import/route.ts:79`, `backoffice/src/app/api/products/import/route.ts:86`, `backoffice/src/app/api/products/import/route.ts:111` |
| PWA entrypoint masih mock | `pwa/src/App.tsx:37`, `pwa/src/App.tsx:75`, `pwa/src/App.tsx:125` |
| Offline helper mengagregasi semua Warehouse dan menghapus record setelah sync | `pwa/src/lib/sync.ts:27`, `pwa/src/lib/sync.ts:39`, `pwa/src/lib/sync.ts:159` |
| Finance worker hard-coded COA | `supabase/worker_rpc.sql:61`, `supabase/worker_rpc.sql:66`, `supabase/worker_rpc.sql:117` |
| Trigger source model Cash Advance lama | `supabase/triggers.sql:2`, `supabase/triggers.sql:40` |
| Backoffice masih satu halaman besar/basic views | `backoffice/src/app/page.tsx:96`, `backoffice/src/app/page.tsx:604`, `backoffice/src/app/page.tsx:622` |

Nomor baris merupakan anchor pada snapshot audit dan dapat bergeser setelah file diedit. Gunakan nama file/function sebagai referensi utama.

---

## 3. Temuan Blocker dan High Risk

### B-01 — Server belum menjadi sumber kebenaran checkout

**Fakta repo:** `backoffice/src/app/api/pos/checkout/route.ts` meneruskan subtotal, discount, grand total, piutang, payment status, detail price/subtotal/COGS, dan payment data dari request ke `create_sales_transaction`. RPC melakukan tenant check dan stock guard, tetapi menyimpan angka client tanpa menghitung ulang dari master/snapshot server.

**Risiko:** user/client yang dimodifikasi dapat mengubah harga, HPP, AR, status lunas, jurnal, dan margin tanpa otorisasi.

**Keputusan:** BLOCKER G4. RPC baru harus resolve dan snapshot Product/UOM/Pricelist/Tax/Discount/Rounding/Payment server-side serta menolak selisih payload.

### B-02 — Transfer stock dapat dibalik dengan qty negatif

**Fakta repo:** `transfer_product_stock` tidak mengecek `p_qty > 0`. Dengan qty negatif, source bertambah dan destination berkurang. Source row juga tidak dikunci `FOR UPDATE` dan update tidak memakai guard atomic `stock_qty >= p_qty`.

**Risiko:** manipulasi stock dan overspend pada transfer concurrent.

**Keputusan:** BLOCKER G3. Tambahkan validation, row locking/atomic guard, idempotency, role+warehouse scope, dan source document.

### B-03 — Tenant integrity hanya mengandalkan check aplikasi/RLS per-row

**Fakta repo:** migration menambah banyak `company_id`, tetapi tidak semua optional inventory table dijadikan `NOT NULL`; tidak ditemukan composite FK yang memastikan child `company_id` sama dengan parent Product/Warehouse/Store. Beberapa business identifiers masih global unique.

**Risiko:** row dapat memiliki Company yang berbeda dari foreign key parent melalui jalur privileged/bug, dan identifier antar-tenant menjadi tidak konsisten.

**Keputusan:** BLOCKER G1/G2. Definisikan tenant contract, backfill, composite/constraint trigger yang aman, dan tenant-scoped unique key.

### B-04 — Import bertentangan dengan master-data governance

**Fakta repo:** import RPC membuat UOM dan Warehouse otomatis, upsert Product berdasar SKU, lalu initial stock. Seluruh file berada dalam satu transaction/RPC; satu error membatalkan semua. UI hanya menyediakan fixed CSV template.

**Risiko:** typo menghasilkan master baru, data acuan berantakan, perubahan massal tidak terkontrol, dan user tidak mendapatkan hasil per baris.

**Keputusan:** BLOCKER G2. Pisahkan export/import tiap master, mapping by ID/code/name, dry-run, partial commit per batch/row yang terkontrol, warning update, history, dan Opening Stock document.

### B-05 — Jalur PWA yang tampil bukan execution path transaksi nyata

**Fakta repo:** `pwa/src/App.tsx` memakai `MOCK_PRODUCTS`, nomor invoice random pendek, kalkulasi sederhana, dan `handleCheckout` hanya menampilkan receipt. Fungsi Dexie/sync tersedia tetapi tidak dipanggil oleh UI utama.

**Risiko:** demo UI dapat disangka POS aktif sementara tidak menghasilkan transaksi database/offline queue.

**Keputusan:** BLOCKER G4. Pisahkan jelas mock/prototype dari production shell; bangun auth/context/session/catalog/cart/checkout state machine yang teruji.

### B-06 — Finance worker hard-coded dan model source sudah drift

**Fakta repo:** worker membuat jurnal dengan kode/nama COA hard-coded dan trigger masih membaca `cash_advances`, sedangkan requirement terbaru menyatukan semuanya sebagai Expense dan menggunakan Transaction Category/account-function mapping.

**Risiko:** jurnal masuk akun salah, tidak scalable per Company, dan workflow lama hidup berdampingan dengan workflow baru.

**Keputusan:** BLOCKER G6. Jangan patch kode COA satu per satu; bangun COA master, account function, versioned mapping resolver, event contract, dan migration/reconciliation data lama.

---

## 4. Gap Matrix

### 4.1 Tenant, Auth, Role, dan Feature

| Capability | Status | Bukti/Gap | Tindakan sebelum gate lulus |
|---|---|---|---|
| Company/Store/POS Terminal/Membership | SUDAH ADA | Ada pada migration 001. | Verifikasi migration live dan data orphan. |
| Super Admin melihat semua Company | SUDAH ADA | Helper dan Backoffice context mendukung bypass/list all. | Tambahkan audit active-company dan destructive confirmation. |
| Company Admin membuat staff Company | PERLU DIPERBAIKI | API server-side tersedia. Store assignment dapat `NONE` untuk role operasional. | Terapkan role-to-scope validation dan lifecycle invitation/reset. |
| RLS core tenant | PERLU DIPERBAIKI | Banyak policy tersedia; broad authenticated grants bergantung penuh pada RLS. | Buat test matrix per table/action/role dan audit semua table baru. |
| Warehouse/Store scoped role | PERLU DIPERBAIKI | Banyak policy hanya mengecek role Company atau generic store membership. | Scope role ke assignment dan target resource, bukan seluruh Company. |
| Feature entitlement Super Admin only | BELUM ADA | Tidak ditemukan master entitlement/API guard. | Bangun Company feature registry + server guard + audit history. |
| Cross-table tenant constraints | BELUM ADA | Tidak ditemukan composite tenant FK menyeluruh. | Tambah constraint/backfill bertahap. |

### 4.2 Master Data dan Import

| Capability | Status | Bukti/Gap | Tindakan |
|---|---|---|---|
| Product basic + weight | SUDAH ADA | Product, weight, tenant SKU index tersedia. | Migrasikan field text lama ke master reference. |
| Product Category master + fallback COA | BELUM ADA | Category masih text. | Master Category Company-scoped, unique, active, mapping optional. |
| UOM master | PERLU DIPERBAIKI | Table tersedia. | Base UOM semantics, precision, active status, tenant NOT NULL. |
| Product multi-UOM + price per UOM | PERLU DIPERBAIKI | Conversion table generik ada; tidak ada sale price per UOM/one-level enforcement. | Redesign contract dan conversion validation. |
| Warehouse master | PERLU DIPERBAIKI | Table tersedia. | Type, max 5 letters, location, assignment, four seed types without hard-coded business names. |
| Supplier master/bank info | BELUM ADA | Purchase hanya menyimpan `supplier_name`. | Master Supplier + account/bank + Company scope. |
| Customer master | PERLU DIPERBAIKI | Basic table/list tersedia. | Category, unique-name policy, debt/balance lifecycle, active/inactivate guard. |
| Global/customer Pricelist | PERLU DIPERBAIKI | Hanya custom price per Customer-Product. | Header/scope/store/date/priority/tier/UOM/version resolver. |
| Payment Method master | BELUM ADA | Payment method masih string/UI constant. | Master, configuration, fee, offline rule, account mapping. |
| Transaction Category/COA/Tax master | BELUM ADA | Jurnal menyimpan COA text; worker hard-coded. | Bangun canonical Finance masters sebelum posting engine. |
| Odoo-like export/import | PERLU DIPERBAIKI | CSV fixed + atomic auto-create master. | Import framework generik sesuai MST-005. |

### 4.3 Inventory

| Capability | Status | Bukti/Gap | Tindakan |
|---|---|---|---|
| Product-Warehouse stock | SUDAH ADA | `product_stocks` dan stock guard checkout tersedia. | Tegaskan base UOM, nonnegative invariant, version/update source. |
| Stock Movement | PERLU DIPERBAIKI | Table dan beberapa insert tersedia. Sale checkout tidak terlihat membuat stock movement. | Central stock ledger service/RPC untuk semua source. |
| Transfer | PERLU DIPERBAIKI | RPC tersedia, tetapi negative/concurrency/role issue. | Tutup B-02 dan tambah document status. |
| FIFO layer | PERLU DIPERBAIKI | Batch table diisi saat purchase/import. | Consumption/allocation/return/reversal/concurrency belum ada. |
| Bundle stock deduction | BELUM ADA | Bundle table ada; checkout tidak expand component. | Atomic expansion, stock check, allocation snapshot. |
| Opening Stock | PERLU DIPERBAIKI | Dicampur ke Product import. | Dokumen terpisah, one-time policy, movement/FIFO/audit. |
| Stock Opname | PERLU DIPERBAIKI | Table dasar tersedia. | Blind count/session cut-off comparison/posting concurrency belum ada. |
| Adjustment | PERLU DIPERBAIKI | Table/policy dasar tersedia. | Approval/source reason/FIFO/value/journal/idempotency belum lengkap. |
| Stock real/movement/opname report | BELUM ADA | Backoffice hanya total stock agregat. | Query/read model per Warehouse/base UOM/source/status. |

### 4.4 POS dan Customer

| Capability | Status | Bukti/Gap | Tindakan |
|---|---|---|---|
| Session open/close | PERLU DIPERBAIKI | Schema ada; UI aktif belum memakai session. | Opening cash, terminal/store, stock snapshots/read model, closing/reconcile. |
| Online checkout atomic | PERLU DIPERBAIKI | RPC transaction dan tenant checks tersedia. | Tutup B-01; tambah state/status/idempotent result. |
| Stock shortage → Draft | BELUM ADA | RPC final hanya error insufficient stock. | Draft document terpisah tanpa stock/journal effect. |
| Pricing/tax/rounding | BELUM ADA | UI memakai price Product dan grand total=subtotal. | Resolver server + explainable price snapshot. |
| Split/electronic payment | PERLU DIPERBAIKI | Payment array tersedia; tidak ada master/total validation/evidence policy enforcement. | Payment resolver, sum validation, URL evidence, verification/reconcile. |
| TEMPO/pro forma/partial collection | BELUM ADA | Header punya tempo fields dasar. | AR document, pro forma, payment history, final invoice on paid. |
| Customer Balance | PERLU DIPERBAIKI | Customer `balance` ada, flow ledger/entitlement tidak ada. | Liability ledger, consume-all rule, approval correction, receipt display. |
| Offline queue/idempotency | PERLU DIPERBAIKI | Dexie/sync helper ada. | UI integration, allowance, retry/ack/error state, retained audit, conflict handling. |
| Receipt/print | PERLU DIPERBAIKI | Browser/Bluetooth mock receipt tersedia. | Snapshot legal/transaction data, reprint, offline marker, numbering. |
| Expense | PERLU DIPERBAIKI | Cash Advance model lama tersedia. | Replace/migrate to unified Expense spec. |
| Setor Kas multi-session | PERLU DIPERBAIKI | Bank deposit satu session model lama. | Multi-session lines, expected vs actual, approval, variance. |
| Ketul | BELUM ADA | Tidak ditemukan execution path. | Bangun setelah core stock/POS invariants lulus dan entitlement tersedia. |

### 4.5 Purchasing dan Finance

| Capability | Status | Bukti/Gap | Tindakan |
|---|---|---|---|
| Purchase basic | PERLU DIPERBAIKI | Header/detail + confirm RPC tersedia. | `p_user_id` unused, role weak, cross-company detail checks absent. |
| RO/Supplier Order/partial receipt | BELUM ADA | Confirm langsung seluruh purchase. | State machine dan document lines terpisah. |
| Accepted/rejected/damaged/return | BELUM ADA | Tidak ada receipt disposition. | Goods Receipt + Return Supplier + movement/value effects. |
| Three-way matching/tolerance | BELUM ADA | Tidak ada Supplier invoice/matching model. | Implement setelah receipt contract stabil. |
| Financial Event queue | PERLU DIPERBAIKI | Event + worker tersedia. | Canonical event schema, version, source status, retry/dead-letter, entitlement. |
| COA/account mapping | BELUM ADA | COA masih text/hard-coded worker. | Master + mapping resolver + seed per Company. |
| Balanced journal | PERLU DIPERBAIKI | Journal lines ada dan worker menulis pasangan. | DB-level balanced-posting invariant, approval, reversal, period lock. |
| AR/AP/subledger | BELUM ADA | Hanya fields ringkas/financial event lama. | Subledger + settlement + source trace. |
| Reconciliation | PERLU DIPERBAIKI | POS reconciliation table dasar ada. | Bank/cash/account reconciliation workspace dan immutable links. |
| Tax engine | BELUM ADA | Tidak ditemukan master/resolver. | Optional per Company dan module Sales/Purchase. |
| Finance reports/cut-off | BELUM ADA | UI hanya daftar jurnal dan jumlah debit/kredit visible. | Read models, period lock, pending analysis, export. |

### 4.6 Test dan Operability

| Capability | Status | Bukti/Gap | Tindakan |
|---|---|---|---|
| SQL tenant/idempotency test | PERLU DIPERBAIKI | Tiga test dalam satu file. | Tambah role/action matrix dan negative tests. |
| Unit/integration app tests | BELUM ADA | Tidak ditemukan test file app. | Test resolver/domain/API/RPC contract. |
| Concurrency test | BELUM ADA | Tidak ditemukan. | Checkout/transfer/receipt/opname/payment replay. |
| Offline replay test | BELUM ADA | Tidak ditemukan. | Duplicate, out-of-order, stale master, partial network failure. |
| Accounting invariant test | BELUM ADA | Tidak ditemukan. | Debit=credit, source uniqueness, reversal, period lock. |
| Migration/backfill verification | PERLU DIPERBAIKI | Runbook lama ada, SQL tersebar di luar migration sequence. | Satu manifest migration, preflight/postflight, checksum, staging restore test. |
| Observability/alerts | BELUM ADA | Console logging saja pada route/sync. | Structured correlation ID tanpa PII, error queue, operational dashboard. |

---

## 5. Konflik Lintas Modul yang Harus Diselesaikan Sebelum Coding

| Konflik | Keputusan final |
|---|---|
| Cash Advance vs Expense | Cash Advance dihentikan sebagai konsep UI/domain; data lama dimigrasikan/mapped ke Expense. |
| Bank Deposit satu sesi vs setoran multi-sesi | Gunakan Deposit header + selected session lines + expected/actual/variance. |
| Harga Product vs Pricelist | Product sale price hanya fallback; resolver menyimpan source/priority/version. |
| Stock dalam UOM jual vs base | Semua ledger stock dalam base UOM; line menyimpan UOM jual, factor snapshot, dan base qty. |
| Weight pada UOM terbesar vs shipping line | Simpan weight manual pada UOM acuan terbesar dan conversion snapshot; toleransi per spec. |
| Draft sale saat stock kosong vs final checkout | Draft tidak membuat stock/jurnal; final di-resolve ulang saat stock ada. |
| Opname berjalan saat toko tetap jualan | Count blind tersimpan dengan timestamp; variance dihitung terhadap stock ledger pada posting policy yang disetujui, bukan membekukan toko. |
| Invoice TEMPO | Pro forma selama belum lunas; invoice final terbit setelah lunas, dengan payment history tetap ada. |
| Ketul sebagai discount/purchase/stock/sale | Gunakan dokumen khusus dengan event terpisah; jangan menyamarkan semua efek dalam discount line POS. |
| COA kategori vs COA transaksi | Transaction Category/account function mapping prioritas; Product Category hanya fallback terkontrol. |

---

## 6. Prioritas Remediasi

1. Buat canonical schema contract dan migration manifest; jangan menambal `schema.sql`, standalone migration, dan production secara terpisah.
2. Tutup tenant integrity dan feature entitlement.
3. Bangun master reference serta import framework sebelum memasukkan data besar.
4. Bangun satu stock ledger atomic yang dipakai Opening, Receipt, Transfer, Sale, Return, Opname, Adjustment, Bundle, dan Ketul.
5. Ganti checkout RPC dengan server resolver + idempotency + snapshot.
6. Hubungkan PWA production shell ke execution path nyata dan offline queue.
7. Bangun purchasing state machine.
8. Ganti worker hard-coded dengan Finance event/mapping engine.
9. Tambahkan automated tests sebelum pilot, bukan setelah data nyata masuk.

Detail urutan dan exit criteria terdapat pada `POS_V1_IMPLEMENTATION_GATES.md`.
