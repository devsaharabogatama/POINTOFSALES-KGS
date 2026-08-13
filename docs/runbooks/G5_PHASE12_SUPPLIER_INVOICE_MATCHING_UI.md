# Runbook G5 Phase 12 — Backoffice Finance Supplier Invoice Matching UI Smoke Test

Dokumen ini berisi panduan pengujian manual UAT / smoke test untuk fitur **Pencocokan Faktur Supplier (Supplier Invoice Three-Way Matching UI)** di aplikasi Backoffice Finance KGS POS.

---

## Pre-requisites

1. **Database Foundation Phase 11 (G5):**
   Migration `20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql` telah dieksekusi di Supabase dan seluruh diagnostic postflight PASS.
2. **User Role:**
   User yang login mempunyai role Finance (`COMPANY_OWNER`, `COMPANY_ADMIN`, `FINANCE`, atau `ACCOUNTING`).
3. **Master Data & Baseline Data:**
   - Minimal 1 Supplier aktif.
   - Minimal 1 Produk aktif (non-bundle) dengan UOM aktif.
   - (Opsional) Document Goods Receipt POSTED dengan status AP Provisional `OPEN` untuk pengujian alokasi tiga arah (*Three-Way Matching*).

---

## Skenario Smoke Test Manual

### Skenario 1: Navigasi dan Memuat Halaman Faktur Supplier
1. Login ke **Backoffice**.
2. Pilih menu **Finance > Faktur Supplier** (atau **Purchase > Faktur Supplier**).
3. **Ekspektasi:**
   - Halaman *Pencocokan Faktur Supplier* berhasil dimuat tanpa error 404 / 500.
   - Menampilkan 3 tab: `Daftar Faktur Supplier`, `Form Draf Faktur`, dan `Kebijakan Toleransi`.
   - Tidak ada UUID atau kode teknis internal yang ditampilkan di UI; nama bisnis (Nama Supplier, Nama Produk, Nama UOM) ditampilkan dengan jelas.

### Skenario 2: Mengatur Kebijakan Toleransi (Tolerance Policy)
1. Buka tab **Kebijakan Toleransi**.
2. Klik tombol **+ Tambah Kebijakan**.
3. Isi toleransi kuantitas (misal: `5%`), batas qty base (misal: `10`), toleransi nilai (misal: `2%`), dan batas nominal nilai (misal: `50.000`).
4. Simpan kebijakan.
5. **Ekspektasi:**
   - Kebijakan berhasil tersimpan melalui RPC `save_supplier_invoice_tolerance_policy`.
   - Kebijakan muncul pada tabel Kebijakan Toleransi dengan status `Aktif`.

### Skenario 3: Membuat dan Menyimpan Draf Faktur Supplier (*Save Draft*)
1. Buka tab **Form Draf Faktur** (atau klik tombol **+ Buat Draf Faktur**).
2. Pilih **Supplier** dari dropdown.
3. Masukkan **No. Invoice Supplier** (misal: `INV-SUPP-2026-001`).
4. Pilih **Mode Harga** (`EXCLUSIVE` atau `INCLUSIVE`) dan tanggal faktur.
5. Klik **+ Tambah Baris**:
   - Pilih Produk, Satuan (UOM), Qty Invoice, dan Harga Satuan Input.
   - (Opsional) Pilih Aturan Pajak Pembelian.
   - (Opsional) Klik **+ Alokasikan Penerimaan** untuk mengalokasikan ke Penerimaan Barang (*AP Provisional*) OPEN dari supplier tersebut.
6. Klik **Simpan Draf Faktur**.
7. **Ekspektasi:**
   - Draf faktur tersimpan dengan status dokumen `DRAFT` dan status matching `UNMATCHED` / `WITHIN_TOLERANCE` / `MATCHED` / `EXCEPTION` sesuai evaluasi RPC `save_supplier_invoice_draft`.
   - Form mereset dan tampilan kembali ke **Daftar Faktur Supplier** dengan draf faktur baru di baris teratas.

### Skenario 4: Validasi Faktur Supplier (*Validate*)
1. Pada **Daftar Faktur Supplier**, temukan draf faktur yang baru dibuat.
2. Klik tombol **Validate**.
3. Pada modal konfirmasi, klik **Ya, Validasi Faktur**.
4. **Ekspektasi:**
   - Faktur berhasil divalidasi via RPC `validate_supplier_invoice` dengan idempotency key.
   - Status dokumen berubah menjadi `VALIDATED`.
   - Diterbitkan Financial Event `SUPPLIER_INVOICE_VALIDATED` (HOLD_UNTIL_G6).
   - Tombol **Edit Draf** dan **Validate** hilang dari baris faktur tersebut.

### Skenario 5: Pembatalan Faktur Supplier (*Cancel*)
1. Buat draf faktur baru atau pilih faktur yang dapat dibatalkan.
2. Klik tombol **Cancel**.
3. Masukkan alasan pembatalan pada modal konfirmasi (misal: `Faktur ganda / salah input nominal`).
4. Klik **Konfirmasi Pembatalan**.
5. **Ekspektasi:**
   - Faktur berhasil dibatalkan via RPC `cancel_supplier_invoice`.
   - Status dokumen berubah menjadi `CANCELED` dengan badge merah.
   - Alokasi AP Provisional dilepaskan kembali jika faktur sebelumnya berupa DRAFT/HOLD.

---

## Catatan Keamanan & Invariant

- **Zero Stock Effect:** Faktur Supplier tidak mengubah stok, batch FIFO, atau pergerakan barang (*Stock Movement*).
- **Zero Journal Effect:** Jurnal umum dan pembayaran Supplier (*Supplier Payment*) tetap tertutup sampai G6.
- **Auditable & Server-Authoritative:** Seluruh mutasi draf, validasi, dan pembatalan diproses melalui RPC Postgres `SECURITY DEFINER` dengan row-level lock dan versioning.
