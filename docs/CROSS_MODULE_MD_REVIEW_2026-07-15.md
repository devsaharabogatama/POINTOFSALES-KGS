# Review Silang Dokumen Modul KGS

**Status:** Review Selesai 1.1 (business workflow)  
**Tanggal:** 2026-07-15  
**Scope:** Konsistensi business workflow, ownership modul, role, stock timing, pricing, settlement, dan boundary Finance  

> **Pembaruan 2026-07-19:** Review ini tetap menjadi acuan konflik lintas modul. Untuk mapping jurnal, account template, dan open decision Finance terbaru, gunakan `FINANCE_MAPPING_REVIEW_2026-07-19.md`. Keputusan Finance pada review terbaru mengalahkan catatan Finance lama di file ini bila ada perbedaan.

---

## 1. Dokumen yang Direview

Kontrak bisnis utama:

1. `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`
2. `docs/POS_DEVELOPMENT_NOTES.md`
3. `docs/FINANCE_INTEGRATION_NOTES.md`
4. `docs/SALES_PRICELIST_NOTES.md`
5. `docs/SALES_CUSTOMER_MASTERDATA_SPEC.md`
6. `docs/KETUL_WORKFLOW_NOTES.md`
7. `docs/CAPITAL_AND_ASSET_NOTES.md`

Dokumen arsitektur/keamanan pendukung:

1. `KGS_MULTI_COMPANY_DATA_STRUCTURE_SPEC.md`
2. `KGS_BACKOFFICE_AUTH_FLOW_WORKFLOW.md`
3. `docs/rls-access-matrix.md`
4. `docs/database-current-state.md`
5. `docs/multi-company-gap-analysis.md`

Review ini membandingkan dokumen. Review ini belum membuktikan bahwa schema production, RLS, RPC, API, dan UI sudah mengikuti kontrak tersebut.

---

## 2. Aturan Precedence

Jika dua dokumen berbeda, gunakan urutan berikut sampai konflik diselesaikan:

1. keputusan user terbaru yang tercatat pada spesifikasi modul khusus;
2. spesifikasi business workflow khusus, misalnya Ketul/Pricelist/Customer;
3. spesifikasi lintas modul Product/Stock dan POS;
4. Finance Notes untuk boundary dan pekerjaan accounting yang ditunda;
5. dokumen arsitektur multi-company;
6. snapshot current-state/gap lama.

Dokumen snapshot tidak boleh mengalahkan keputusan bisnis baru.

---

## 3. Verdict Ringkas

Tidak ditemukan konflik fatal pada alur inti berikut setelah klarifikasi dokumentasi:

- Produk, UOM, berat, harga per UOM, dan saldo base UOM;
- Bundle virtual dan pengurangan stock komponen;
- Draft sale ketika stock tidak cukup;
- Stock Request -> Supplier Order -> Goods Receipt -> Invoice/AP;
- Stock Opname non-blocking dan Adjustment oleh Store Manager atau Company Admin/Super Admin sesuai scope;
- hierarchy Pricelist, diskon, rounding, serta snapshot harga;
- Customer Balance sebagai ledger dan payment method;
- Customer Intake Ketul -> FIFO -> Transit -> Vendor Result -> Settlement;
- integrasi Cash Ketul dengan sesi Kasir;
- pemisahan Inventory, Aset Tetap, dan Modal Pemilik.

Konflik business authorization telah diselesaikan melalui hierarchy terbaru. Pekerjaan tersisa adalah audit dan penyelarasan policy SQL/API/navigation terhadap hierarchy tersebut. Beberapa keputusan modul masih terbuka, tetapi bukan konflik antar-workflow.

Pengecualian hierarchy yang disengaja: seluruh feature entitlement hanya dapat diaktifkan/dinonaktifkan Super Admin per company. Company Admin tetap mengelola workflow operasional setelah entitlement aktif. Feature dengan liability/dokumen lama memakai `WIND_DOWN` sebelum `DISABLED`.

---

## 4. Konflik Authorization yang Telah Diputuskan

### AUTH-01 — Hak Jurnal Company Admin

**Severity:** RESOLVED pada business contract  
**Status:** APPROVED; IMPLEMENTATION_AUDIT_REQUIRED

- Company Admin memiliki seluruh kewenangan role bawahan, termasuk Finance/Accounting dan akses Jurnal, hanya dalam company membership aktif.
- Super Admin memiliki kewenangan tersebut lintas company.

Guardrail:

- kewenangan penuh dijalankan melalui workflow posting, approval, dan reversal;
- Company Admin/Super Admin tidak boleh UPDATE/DELETE jurnal final secara langsung;
- RLS, API, navigation, dan test masih harus diselaraskan.

### AUTH-02 — Hak Adjustment Warehouse Admin

**Severity:** RESOLVED pada business contract  
**Status:** APPROVED; IMPLEMENTATION_AUDIT_REQUIRED

- Store Manager dapat membuat/post Adjustment dalam store assignment.
- Company Admin dapat melakukan seluruh action tersebut dalam company membership-nya.
- Super Admin dapat melakukannya lintas company.

Target business contract saat ini:

- Warehouse Admin boleh mengelola Gudang, melihat stock/movement, dan menjalankan transfer sesuai scope;
- Warehouse Admin tidak boleh mem-posting Adjustment;
- posting tetap melalui dokumen Adjustment append-only, bukan edit balance/movement langsung.

### AUTH-03 — Quick-create Customer oleh Cashier

**Severity:** HIGH bila diimplementasikan sebagai table INSERT  
**Status:** RESOLVED_IN_BUSINESS_DOC; IMPLEMENTATION_AUDIT_REQUIRED

- Customer/POS membutuhkan quick-create oleh Cashier;
- matriks lama memberi Cashier akses baca Products/Customers saja.

Resolusi dokumen:

- Cashier tidak mendapat INSERT tabel Customer secara bebas;
- quick-create wajib melalui RPC/API server terkontrol, tenant-scoped, normalized, unique, dan idempotent.

### AUTH-04 — Matriks Role Belum Lengkap

**Severity:** HIGH  
**Status:** BUSINESS_HIERARCHY_APPROVED; POLICY_REWRITE_REQUIRED

Hierarchy target:

- `SUPER_ADMIN`: seluruh company;
- `COMPANY_OWNER/COMPANY_ADMIN`: seluruh kewenangan dalam company membership;
- `FINANCE/ACCOUNTING`, `STORE_MANAGER`, `WAREHOUSE_ADMIN`, `CASHIER`: scope/action khusus;
- Company Admin/Super Admin mewarisi approval Setor Kas, Refund, Opname/Adjustment, Purchase Return, dan final fund confirmation Ketul.

Matriks bisnis sudah diperbarui, tetapi policy SQL aktual tetap harus diaudit sebelum dianggap implemented.

---

## 5. Drift yang Sudah Diperbaiki Saat Review

### DOC-01 — Costing FIFO

Finance Notes sebelumnya membuka kembali pilihan FIFO/average. Product/Stock dan Ketul sudah mengunci FIFO. Pertanyaan Finance diubah: FIFO tetap digunakan; yang terbuka hanya jurnal koreksi valuation/HPP akibat harga invoice aktual.

### DOC-02 — COA Override Produk

Tabel field Produk sebelumnya menyebut kemungkinan override COA per Produk, sedangkan bagian Finance menyatakan tidak ada override pada scope awal. Field Produk sudah diselaraskan: mapping mengikuti kategori; detail COA final ditunda.

### DOC-03 — Hak CRUD Gudang

Tabel role Product/Stock sebelumnya menandai Warehouse Admin sebagai belum diputuskan dan Store Manager tidak boleh CRUD. Sudah diselaraskan dengan keputusan user:

- Company Owner/Admin: company scope;
- Warehouse Admin: gudang dalam scope;
- Store Manager: gudang STORE dalam assignment.

### DOC-04 — Format Kode Gudang

Pertanyaan huruf atau angka sudah ditutup. Target saat ini: manual, huruf `A-Z`, maksimal lima karakter.

### DOC-05 — Hierarki Pricelist AUTO vs Cashier Override

Pricelist Customer Eksklusif melewati Global dalam resolver otomatis. Cashier masih boleh memilih Global yang eligible secara eksplisit. Dokumen sudah menjelaskan bahwa override memilih satu cabang resolver, bukan menumpuk Customer dan Global.

### DOC-06 — Status Ketul

Referensi enum campuran `FINANCE_CONFIRMED` sudah diganti dengan:

- quantity status terpisah;
- settlement status terpisah;
- payment confirmation sebagai event;
- `CLOSED` sebagai lifecycle akhir otomatis.

### DOC-07 — Ketul Offset dan Invariant Pembayaran

Potongan Ketul bukan diskon. `KETUL_OFFSET` sekarang dinyatakan sebagai settlement/tender non-cash setelah rounding. Revenue dan grand total invoice tetap utuh, sementara total seluruh tender tetap menutup grand total.

### DOC-08 — Cash Ketul dan Sesi Kasir

Formula sesi sudah diperjelas:

- Cash Vendor Ketul menambah expected drawer;
- Cash payout Customer Intake mengurangi drawer;
- Customer Balance/Ketul Offset tidak mengubah drawer;
- Backoffice Cash Receipt tanpa sesi tidak masuk drawer/setoran Kasir.

### DOC-09 — Snapshot Multi-company Lama

`database-current-state.md` dan `multi-company-gap-analysis.md` sudah diberi label historical pre-migration agar tidak dibaca sebagai kondisi production terkini.

---

## 6. Integrasi Lintas Modul yang Konsisten

### 6.1 Produk, UOM, Stok, dan Ongkir

- saldo disimpan pada base UOM terkecil;
- setiap UOM langsung dikonversi ke base UOM;
- harga beli/jual manual per UOM;
- berat manual pada UOM terbesar;
- berat turunan dihitung proporsional sebagai estimasi;
- transaksi menyimpan snapshot UOM, faktor, harga, dan base quantity.

Tidak ada konflik dengan Pricelist karena Pricelist menimpa harga jual transaksi, bukan faktor UOM atau Master Produk.

### 6.2 Pricing, Rounding, Customer Balance, dan Ketul

Urutan konsisten:

```text
Harga Produk-UOM
-> Pricelist terpilih
-> diskon line
-> diskon transaksi dan alokasi line
-> grand total sebelum rounding
-> rounding opsional
-> grand total final/revenue
-> settlement Cash/Transfer/QR/Customer Balance/Ketul Offset
```

Ketul Offset dan Customer Balance bukan diskon sehingga refund, revenue, dan laporan harga tidak kehilangan basis awal.

### 6.3 Draft Sale dan Stock

- shortage sale membuat seluruh order tetap Draft;
- Draft tidak mereservasi atau mengubah stock;
- Draft tidak membuat payment final/jurnal;
- posting selalu melakukan server revalidation terhadap stock, pricing, UOM, dan tenant.

Ketul dispatch mempunyai aturan berbeda tetapi tidak konflik: shortage memblokir posting dispatch, sementara dokumen tetap boleh disimpan Draft.

### 6.4 Stock Opname dan Operasi POS

- count tidak membekukan penjualan;
- Cashier menggunakan blind count;
- Store Manager atau Company Admin/Super Admin membandingkan dan posting;
- movement selama count window memicu recount line terkait;
- posting membuat Adjustment append-only.

### 6.5 Purchasing dan Finance

- request/order memakai quantity dan harga estimasi;
- Goods Receipt menambah stock/FIFO dan AP provisional;
- Finance mencocokkan invoice fisik dan nilai aktual;
- return sebelum/sesudah invoice final mempunyai koreksi berbeda tanpa mengubah histori;
- FIFO tetap menjadi costing operasional.

### 6.6 Ketul dan Warehouse Transit

- Customer Intake menambah stock/FIFO pada store;
- dispatch memindahkannya ke Transit;
- accepted quantity membuat stock-out/HPP;
- rejected quantity kembali ke active/Damaged;
- company-level Transit tetap membawa origin store agar stock tidak bercampur.

---

## 7. Keputusan Terbuka yang Bukan Konflik

### Customer

- exceptional settlement untuk Customer inactive pada fase Expense;
- mapping akun jurnal write-off/recovery piutang TEMPO.

### Expense/Arus Kas

- workflow bisnis selesai; hanya mapping jurnal Finance, accounting lock, serta retention/ukuran evidence yang masih terbuka;

### Pricelist/POS

- lifecycle TEMPO, Customer Statement, multi-Pro Forma payment, correction, write-off, recovery, authority, dan reversal sudah selesai pada level bisnis; hanya mapping jurnal/retention teknis yang tetap terbuka pada fase Finance;

### Product/Import

- retention Import History dan file error;
- akses Warehouse Admin terhadap Import master;
- aturan Finance/COA yang memang ditunda.

### Finance

- mapping debit/kredit source event terhadap template COA; account type/hierarchy/template leaf sudah diputuskan;
- mapping debit/kredit/payment method;
- AP provisional ke AP final;
- detail format PRIOR_PERIOD_ADJUSTMENT/cut-off pada accounting period lock;
- Tax Engine optional, landed cost, variance, refund/reversal;
- detail formula/export laporan keuangan; paket laporan minimum sudah diputuskan;
- Expense dan arus kas non-penjualan;
- Modal Pemilik dan Aset Tetap.

Fondasi Finance Core sudah diputuskan: accrual, template COA per company, kode manual, automatic/manual journal boundary, immutable posted journal, satu ledger IDR per company, reporting dimension store/warehouse, monthly lock/reopen authority, reconciliation, bank statement import, accounting date/prior-period adjustment, optional Tax entitlement, dan paket laporan minimum. Detail di atas bukan konflik, tetapi pekerjaan Finance lanjutan.

Keputusan terbuka tersebut membatasi fase implementasi masing-masing tetapi tidak membatalkan spesifikasi Product/Stock atau Ketul yang sudah selesai.

---

## 8. Risiko Implementasi Bila Review Diabaikan

1. Policy SQL lama tidak mewariskan kewenangan Company Admin sehingga UI dan database berbeda.
2. Warehouse Admin dapat melakukan Adjustment jika policy lama tidak diperketat.
3. Quick-create Customer gagal karena RLS atau dibuka terlalu lebar.
4. Ketul Offset dicatat sebagai diskon sehingga revenue/refund salah.
5. Cash Ketul tidak masuk expected drawer dan menghasilkan selisih sesi palsu.
6. Transit Ketul company-level mencampur pending stock antar-store.
7. Dokumen lama dibaca sebagai current-state sehingga migration/RLS diterapkan dua kali atau dengan asumsi salah.

---

## 9. Rekomendasi Urutan Berikutnya

1. Cocokkan RLS/API/navigation/test dengan hierarchy Company Admin dan Super Admin yang baru disetujui.
2. Selesaikan batch keputusan Customer Balance.
3. Bahas Expense dan arus kas non-penjualan sebagai workflow operasional berikutnya.
4. Audit schema dan code terhadap kontrak Product/Stock/Ketul; jangan implementasi Finance penuh dulu.
5. Bahas Finance, Modal, dan Aset pada fase terpisah.

---

## 10. Kesimpulan

Workflow Ketul selesai pada level bisnis dan sudah menyatu dengan Stock, POS, Customer, Session, Setor Kas, dan Finance boundary. Product/Stock, POS, Pricelist, dan Ketul tidak mempunyai konflik fatal setelah perbaikan dokumentasi.

Tidak ada konflik business workflow fatal yang tersisa. Lifecycle dasar TEMPO kini konsisten: posting operasional/AR terjadi saat barang diserahkan, sedangkan Invoice final baru terbit setelah lunas dan tidak mengulang jurnal. Risiko terbesar berikutnya adalah implementation drift: RLS/API/navigation lama mungkin belum mengikuti hierarchy baru. Edge case TEMPO dan detail Finance masih harus diselesaikan bertahap dan tidak boleh ditebak oleh AI agent.
