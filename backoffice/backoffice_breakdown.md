# Spesifikasi Arsitektur & Breakdown Detail Backoffice KGS

Dokumen ini mendefinisikan desain teknis, struktur database tambahan, dan alur modul manajerial untuk backend **KGS Backoffice Dashboard**.

---

## 1. Pemisahan Modul Berdasarkan Role (Role-Based Access Control)

Akses halaman di Next.js akan dibatasi menggunakan Middleware/Auth check dan RLS Supabase:

| Modul | Sub-Fitur | Cashier | Manager | Owner |
| :--- | :--- | :---: | :---: | :---: |
| **Stock Management** | Stok Barang, Transfer Stok, Konfirmasi PO | ❌ |  |  |
| **Product Master Data** | CRUD Produk, Harga Jual, Import Data | ❌ |  |  |
| **Finance Module** | Jurnal Ledger, P&L, Neraca, Approval CA | ❌ | ❌ |  |

---

## 2. Alur Desain FIFO (First-In, First-Out) untuk HPP

Untuk mengakomodasi fluktuasi harga pembelian, kita akan mengabaikan rata-rata (*Average*) dan menerapkan metode FIFO murni. Barang yang dibeli pertama kali akan dikeluarkan terlebih dahulu saat ada penjualan.

### A. Tambahan Tabel Database
Kita memerlukan dua tabel baru di Supabase:

```sql
-- Batch persediaan barang masuk (pembelian)
CREATE TABLE product_batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    qty_purchased NUMERIC NOT NULL,
    qty_remaining NUMERIC NOT NULL, -- Sisa stok di batch ini
    cogs_unit NUMERIC NOT NULL,     -- Harga beli per unit (HPP)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Catatan detail alokasi penjualan terhadap batch FIFO
CREATE TABLE sales_fifo_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_detail_id UUID NOT NULL REFERENCES sales_details(id) ON DELETE CASCADE,
    product_batch_id UUID NOT NULL REFERENCES product_batches(id) ON DELETE CASCADE,
    qty_allocated NUMERIC NOT NULL,  -- Kuantitas yang diambil dari batch ini
    cogs_unit NUMERIC NOT NULL,      -- HPP batch saat dibeli
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### B. Visualisasi Alur FIFO (Mermaid)

```mermaid
graph TD
    PO[1. Pembelian PO Masuk] -->|Konfirmasi Manajer| PB[2. Buat Product Batch Baru - cogs_unit = Harga Beli]
    PB -->|Sisa Stok Disimpan di| qty_remaining[product_batches.qty_remaining]
    
    Sale[3. POS Checkout / Jual Barang] -->|Trigger Alokasi FIFO| FIFO[4. Ambil Batch Tertua - created_at ASC]
    FIFO -->|Kurangi qty_remaining| Ded[5. Update product_batches]
    FIFO -->|Simpan Alokasi Detail| Alloc[6. Insert sales_fifo_allocations]
    Alloc -->|Hitung Rata-rata HPP Batch| UpdateSD[7. Tulis cogs_unit & cogs_total ke sales_details]
```

---

## 3. Modul Konfirmasi Order Stok (Stock Confirmation)

Modul ini memproses penambahan stok. Penambahan stok tidak langsung terjadi saat PO dibuat, melainkan harus dikonfirmasi oleh manajer setelah fisik barang sampai di gudang.

1. **Kasir / Staf mengajukan Order Stok (Draft Purchase Order)**.
2. **Manajer meninjau berkas PO masuk**.
3. **Manajer mengklik "Konfirmasi & Terima Barang"**:
   * Sistem merubah status `purchases_headers.payment_status` ke status yang sesuai.
   * Sistem menambah kuantitas di `product_stocks`.
   * Sistem membuat baris baru di `product_batches` (untuk log FIFO HPP) dengan harga beli saat itu.

---

## 4. Modul Import Master Data (CSV / Excel Import)

Untuk mempercepat inisiasi proyek, manajer memerlukan alat import data. 
* **Format File (CSV)**:
  ```csv
  sku,name,category,price,purchase_price,uom,initial_stock,warehouse_code
  PROD-001,Semen Padang 50kg,Bahan Bangunan,72000,65000,sak,100,GDS
  ```
* **Logika Backend**:
  1. Membaca baris CSV.
  2. Melakukan UPSERT ke tabel `products`.
  3. Memasukkan data stok awal ke `product_stocks` sesuai dengan `warehouse_code`.
  4. Membuat Batch Persediaan Awal di `product_batches` dengan `cogs_unit = purchase_price`.

---

## 5. Modul Penyesuaian Stok (Stock Adjustment) & Stock Opname

Untuk menangani selisih stok akibat barang rusak, susut, atau audit fisik periodik secara akurat:

### A. Tambahan Tabel Database
```sql
-- Status Opname
CREATE TYPE opname_status AS ENUM ('DRAFT', 'SUBMITTED', 'APPROVED');

-- Audit fisik stok opname
CREATE TABLE stock_opnames (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_no TEXT UNIQUE NOT NULL, -- e.g. OPN-20260713-0001
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    status opname_status NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Detail hitungan fisik stok opname per item
CREATE TABLE stock_opname_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id UUID NOT NULL REFERENCES stock_opnames(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    system_qty NUMERIC NOT NULL,   -- Stok tercatat di sistem
    physical_qty NUMERIC NOT NULL, -- Stok fisik yang dihitung
    difference NUMERIC NOT NULL,   -- Selisih (system_qty - physical_qty)
    notes TEXT
);

-- Penyesuaian stok manual (penyesuaian mandiri atau hasil dari opname)
CREATE TABLE stock_adjustments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    adjustment_no TEXT UNIQUE NOT NULL, -- e.g. ADJ-20260713-0001
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    opname_detail_id UUID REFERENCES stock_opname_details(id) ON DELETE SET NULL, -- Referensi jika dibuat dari opname
    qty_adjusted NUMERIC NOT NULL, -- Positif untuk penambahan, negatif untuk pengurangan
    cogs_unit NUMERIC NOT NULL,    -- Harga per unit saat disesuaikan (HPP)
    reason TEXT NOT NULL,          -- e.g. 'Rusak', 'Hilang', 'Selisih Opname'
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### B. Hubungan dengan Metode FIFO
1. **Penyesuaian Positif (Stok Bertambah / Temuan)**:
   * Menambahkan stok di `product_stocks`.
   * Membuat batch persediaan baru di `product_batches` dengan `cogs_unit` setara dengan COGS produk saat itu.
2. **Penyesuaian Negatif (Stok Berkurang / Rusak / Hilang)**:
   * Mengurangi stok di `product_stocks`.
   * Mengurangi sisa stok (`qty_remaining`) dari batch FIFO tertua (`product_batches`), mirip dengan pemotongan transaksi penjualan.
   * Menulis event akuntansi `'EXPENSE_POSTED'` dengan nilai total kerugian HPP barang ke antrean `financial_events` dengan kategori `'Kerugian Selisih Persediaan'` agar otomatis terposting ke Buku Besar.

---

## 6. Modul Pelanggan (Customer) & Daftar Harga Kustom (Pricelists)

Untuk memisahkan manajemen pelanggan dari modul stok, serta memberikan fleksibilitas harga jual:

### A. Tambahan Tabel Database
```sql
-- Daftar harga kustom per pelanggan (Pricelist)
CREATE TABLE customer_pricelists (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    custom_price NUMERIC NOT NULL, -- Harga khusus untuk pelanggan ini
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_customer_product_price UNIQUE (customer_id, product_id)
);
```

### B. Alur Logika Harga Kustom di POS
1. Saat kasir memilih pelanggan (*Customer*) di POS, aplikasi kasir memeriksa apakah pelanggan tersebut memiliki harga khusus untuk produk di keranjang belanja.
2. POS melakukan query ke IndexedDB (yang sudah disinkronisasikan dengan `customer_pricelists`) atau API.
3. Jika ditemukan, harga jual default produk digantikan oleh `custom_price`. Jika tidak, menggunakan harga umum default produk.

---

## 7. Laporan Pergerakan Stok (Kartu Stok / Stock Card)

Untuk melacak histori mutasi keluar-masuk stok barang di setiap gudang secara terperinci untuk audit:

### A. Tambahan Tabel Database
```sql
CREATE TYPE stock_movement_type AS ENUM ('SALE', 'PURCHASE', 'ADJUSTMENT', 'TRANSFER_IN', 'TRANSFER_OUT');

-- Log kartu stok historis
CREATE TABLE stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    qty_change NUMERIC NOT NULL, -- Positif (masuk) atau Negatif (keluar)
    movement_type stock_movement_type NOT NULL,
    reference_table TEXT NOT NULL, -- e.g. 'sales_details', 'purchases_details', 'stock_adjustments'
    reference_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### B. Otomatisasi Log Pergerakan Stok
Kita akan membuat trigger di database Supabase agar setiap kali ada perubahan stok (dari penjualan POS, pembelian, transfer gudang, maupun penyesuaian/opname), data mutasi otomatis tercatat di `stock_movements`. Ini menjamin laporan pergerakan stok 100% akurat.

---

## 8. Rencana Tugas Implementasi (To-Do List)

### Langkah 8.1: Eksekusi SQL Migrasi Baru (Supabase)
* [ ] Jalankan query pembuatan tabel `product_batches` dan `sales_fifo_allocations` (FIFO).
* [ ] Jalankan query pembuatan tipe `opname_status` dan tabel `stock_opnames`, `stock_opname_details`, serta `stock_adjustments` (Opname & Adjustment).
* [ ] Jalankan query pembuatan tabel `customer_pricelists` (Pricelist kustom).
* [ ] Jalankan query pembuatan tipe `stock_movement_type` dan tabel `stock_movements` (Kartu Stok).
* [ ] Buat trigger/fungsi PostgreSQL `allocate_fifo_cogs()` untuk melakukan kalkulasi FIFO otomatis saat terjadi penjualan.
* [ ] Buat fungsi trigger/RPC `approve_stock_opname()` untuk mengesahkan opname fisik dan meluncurkan penyesuaian stok otomatis.
* [ ] Buat trigger log mutasi otomatis untuk mengisi tabel `stock_movements` setiap kali stok berubah.

### Langkah 8.2: Pembuatan API & Komponen Impor di Backoffice
* [ ] Setup route `/api/products/import` untuk membaca data CSV/Excel produk.
* [ ] Buat UI Halaman CRUD Produk dan tombol Impor CSV.

### Langkah 8.3: Halaman Konfirmasi Order Stok & Penyesuaian Stok
* [ ] Buat UI Manajemen Pembelian (PO) dengan filter "Menunggu Konfirmasi".
* [ ] Tautkan tombol "Konfirmasi Terima" ke RPC database yang menambah stok dan batch FIFO.
* [ ] Buat UI Manajemen Penyesuaian Stok (*Stock Adjustment*) & Halaman Audit hitung fisik (*Stock Opname*).

### Langkah 8.4: Modul Pelanggan & Pricelist Kustom
* [ ] Buat halaman terpisah untuk CRUD Pelanggan (Customer Manager).
* [ ] Buat sub-modul untuk mengatur daftar harga kustom (*customer pricelist*) per produk untuk pelanggan tertentu.

### Langkah 8.5: Laporan Laba/Rugi FIFO & Kartu Stok
* [ ] Perbarui tab Laporan Keuangan agar menghitung HPP berdasarkan hasil alokasi tabel `sales_fifo_allocations` (bukan harga rata-rata/cogs statis).
* [ ] Buat sub-tab Laporan Pergerakan Stok (*Stock Card*) dengan filter pencarian per produk, per gudang, dan rentang tanggal untuk melihat histori masuk/keluar barang.
