# Catatan Deferred Modal dan Aset KGS

**Status:** Deferred Discovery Note 0.2; baseline umum tersedia, detail belum disetujui  
**Tanggal:** 2026-07-15; diperbarui 2026-07-20  
**Scope:** Placeholder untuk Modal Pemilik/Equity dan Aset Tetap; belum masuk implementasi  

---

## 1. Tujuan

Dokumen ini dibuat agar pembahasan Modal dan Aset tidak terlewat ketika ERP masuk ke fase Finance. Detail workflow, schema, UI, approval, COA, dan jurnal belum diputuskan.

Istilah berikut tidak boleh dicampur:

- `Modal Pemilik/Equity`: setoran modal awal, tambahan modal, dan penarikan pemilik;
- `Aset Tetap`: barang bernilai jangka panjang yang dimiliki company dan dapat mengalami penyusutan;
- `Inventory/Stok`: barang dagang yang dibeli untuk dijual atau digunakan dalam operasi retail.

---

## 2. Kandidat Scope Modal Pemilik

Detail berikut dibahas nanti:

- modal awal company;
- tambahan setoran modal;
- penarikan modal/prive;
- sumber dan tujuan Cash/Bank;
- owner/shareholder/counterparty;
- tanggal efektif dan tanggal posting;
- bukti transaksi;
- approval dan reversal;
- mapping COA equity;
- laporan mutasi modal.

Semua poin masih `NEEDS_FINANCE_DECISION`.

---

## 3. Kandidat Scope Aset Tetap

### 3.1 Baseline Jenis/Kategori Umum

Kategori awal yang lazim dan dapat disesuaikan per company:

- Tanah;
- Bangunan;
- Renovasi/leasehold improvement;
- Kendaraan;
- Mesin dan peralatan produksi;
- Peralatan toko/POS;
- Peralatan gudang/logistik;
- Furniture dan fixture;
- Komputer, perangkat IT, dan jaringan;
- Peralatan kantor;
- Aset tak berwujud/software/license bila nanti dibutuhkan;
- Construction/Asset in Progress bila pembelian belum siap digunakan.

Kategori adalah Master Data per company. Daftar ini hanya baseline umum, bukan kewajiban mengaktifkan semuanya. Akun, masa manfaat, metode penyusutan, threshold, dan nilai residu belum dikunci.

### 3.2 Kandidat Data Register Minimum

```text
company_id
asset_code
asset_name
asset_category_id
asset_type = TANGIBLE | INTANGIBLE | CONSTRUCTION_IN_PROGRESS
acquisition_date
available_for_use_date nullable
acquisition_value
supplier_id nullable
purchase_invoice_reference nullable
store_id / location nullable
custodian nullable
serial_number nullable
description nullable
evidence_url nullable
status
```

- `asset_code` unik per company.
- Bukti/foto mengikuti `EXTERNAL_EVIDENCE_LINK_POLICY.md`; scope awal hanya menyimpan external URL.
- Asset register bukan stock quantity ledger dan bukan Product Bundle/BOM.
- Auth User/Company Membership tidak otomatis menjadi Employee/custodian HR; referensi custodian harus mengikuti boundary HR ketika modul tersebut dibuka.

### 3.3 Kandidat Lifecycle Umum

```text
DRAFT
ACTIVE
IN_MAINTENANCE
IDLE
TRANSFERRED
DISPOSED
SOLD
WRITTEN_OFF
```

Lifecycle tersebut adalah kandidat untuk pembahasan, belum final. Posted acquisition/depreciation/disposal nantinya harus immutable dan dikoreksi melalui reversal/replacement.

Detail berikut dibahas nanti:

- Master Kategori Aset;
- kode, nama, acquisition date, acquisition value, dan supplier;
- company, store/lokasi, custodian, serta status aset;
- capitalization threshold;
- useful life, residual value, dan metode penyusutan;
- jadwal serta posting depreciation;
- transfer lokasi/custodian;
- maintenance bila diperlukan;
- disposal, sale, write-off, impairment, dan reversal;
- hubungan Purchase/AP ke pencatatan aset;
- mapping COA asset, accumulated depreciation, depreciation expense, dan gain/loss disposal;
- register dan laporan aset tetap.

Semua poin masih `NEEDS_FINANCE_DECISION`.

### 3.4 Boundary Klasifikasi

- Barang dagang untuk dijual adalah Inventory, bukan Aset Tetap.
- Barang operasional bernilai kecil dapat menjadi Expense atau controlled equipment sesuai kebijakan kapitalisasi company.
- Pembelian aset melalui Purchasing/AP tidak boleh otomatis menjadi Inventory; line/category transaksi harus menentukan asset acquisition workflow.
- Asset in Progress tidak disusutkan sampai siap digunakan jika kebijakan final memilih model tersebut.
- Maintenance biasa tidak otomatis menambah nilai aset; capitalization improvement memerlukan rule Finance terpisah.

---

## 4. Guardrail untuk AI Agent

- Jangan membuat schema, migration, RPC, API, jurnal, atau UI Modal/Aset sebelum workflow detail disetujui user.
- Jangan mengklasifikasikan Produk STOCK sebagai Aset Tetap hanya karena nilainya besar.
- Jangan mencampur setoran modal pemilik dengan pendapatan penjualan atau Cashier cash-in biasa.
- Jangan menebak COA, masa manfaat, nilai residu, metode penyusutan, atau capitalization threshold.
- Seluruh data wajib tenant-scoped; akses Super Admin lintas company tidak menghilangkan audit company asal.
- Ketika fase ini dimulai, sinkronkan keputusan final ke `docs/FINANCE_INTEGRATION_NOTES.md`.
- Ikuti `ERP_EVOLUTION_ARCHITECTURE_NOTES.md`: Aset menjadi modul ERP terpisah setelah POS stabil dan tidak memperluas scope implementasi POS sekarang.

---

## 5. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-15 | Modal dan Aset harus dicatat agar tidak terlewat dalam roadmap ERP | APPROVED sebagai reminder |
| 2026-07-15 | Modal Pemilik, Aset Tetap, dan Inventory adalah scope berbeda | PROPOSED guardrail; konfirmasi detail pada fase Finance |
| 2026-07-15 | Detail workflow, accounting, schema, dan UI dibahas kemudian | DEFERRED |
| 2026-07-20 | Baseline kategori aset umum dan kandidat asset register ditambahkan agar roadmap ERP tidak melewatkan aset | APPROVED sebagai note, bukan workflow final |
| 2026-07-20 | Kategori/rule dapat disesuaikan per company; depresiasi, threshold, lifecycle, jurnal, dan disposal dibahas lewat batch khusus | DEFERRED |
| 2026-07-20 | Bukti aset memakai external URL sementara dan modul Aset dibuka setelah POS berjalan | APPROVED sebagai boundary |
