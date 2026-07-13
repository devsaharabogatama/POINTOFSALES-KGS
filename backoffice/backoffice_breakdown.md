# Master Arsitektur & Breakdown Detail Backoffice KGS (4 Modul Utama)

Dokumen ini mendefinisikan rancangan teknis, struktur database, laporan, dan rencana implementasi Next.js untuk **KGS Backoffice Dashboard** yang terbagi menjadi **4 Modul Utama**.

---

## 1. Pembagian 4 Modul Utama & Akses Role (RBAC)

Akses halaman di Next.js dibatasi menggunakan Middleware/Auth check dan RLS Supabase:

| Modul Besar | Fitur & Sub-Modul | Cashier | Manager | Owner |
| :--- | :--- | :---: | :---: | :---: |
| **1. Inventory / Stock** | Stok Realtime, Transfer Stok, Opname, Adjustment, Konfirmasi PO, Laporan Kartu Stok | ❌ |  |  |
| **2. Keuangan (Finance)**| Jurnal Umum, Laporan P&L, Neraca, Approval Cash Advance, Setoran Bank | ❌ | ❌ |  |
| **3. Customer** | CRUD Pelanggan, Log Deposit, Pricelist Kustom per Pelanggan | ❌ |  |  |
| **4. Master Data** | CRUD Produk, Konfigurasi Bundling, Master Satuan (UOM) & Konversi | ❌ |  |  |

---

## 2. Modul Master Data (UOM & Konversi)

Pembelian barang seringkali menggunakan satuan besar (misal: Dus/Box) sedangkan penjualan menggunakan satuan kecil (misal: Pcs/Pack). Kita akan membuat Master Satuan (UOM) dinamis.

### A. Tambahan Tabel Database
```sql
-- Master Satuan (UOM)
CREATE TABLE uoms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL, -- e.g. 'PCS', 'DUS', 'PACK', 'SAK', 'KG', 'BATANG'
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Konversi Satuan per Produk
CREATE TABLE product_uom_conversions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    from_uom_id UUID NOT NULL REFERENCES uoms(id) ON DELETE CASCADE, -- Satuan besar (e.g. DUS)
    to_uom_id UUID NOT NULL REFERENCES uoms(id) ON DELETE CASCADE,   -- Satuan kecil (e.g. PCS)
    conversion_factor NUMERIC NOT NULL,                              -- e.g. 1 DUS = 12 PCS (factor = 12)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_uom_conversion UNIQUE (product_id, from_uom_id, to_uom_id)
);
```

---

## 3. Modul Master Data (Produk Bundling)

Produk bundling adalah produk virtual yang berisi kombinasi beberapa produk komponen dengan harga jual khusus.

### A. Logika Persediaan & FIFO untuk Bundling
1. **Stok Virtual**: Produk bundling tidak memiliki stok fisik langsung di tabel `product_stocks`. Stok bundling dihitung secara dinamis di POS berdasarkan batas minimum stok komponen-komponennya.
2. **Pemotongan Stok**: Saat produk bundling terjual, sistem (lewat RPC Checkout) otomatis mengurangi stok produk komponen penyusunnya di tabel `product_stocks`.
3. **Kalkulasi HPP/COGS**: HPP produk bundling dihitung dari akumulasi HPP masing-masing komponen penyusun yang dikurangi berdasarkan alokasi antrean FIFO (`product_batches`).

### B. Relasi Database (Bundling)
Tabel `product_bundle_items` akan mencatat komponen penyusun:
```sql
CREATE TABLE product_bundle_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bundle_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE, -- Produk bertipe 'is_bundle = TRUE'
    item_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,   -- Produk komponen riil
    qty NUMERIC NOT NULL DEFAULT 1,                                    -- Jumlah komponen dalam bundle
    CONSTRAINT chk_qty_positive CHECK (qty > 0)
);
```

---

## 4. Modul Pelanggan (Customer) & Daftar Harga Kustom (Pricelist)

Memisahkan pengelolaan pelanggan, saldo deposit/piutang, serta pengaturan harga kustom.

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

---

## 5. Modul Inventory (Stok, Adjustment, Opname & Kartu Stok)

Koreksi stok, audit berkala, dan penelusuran mutasi fisik barang.

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
    system_qty NUMERIC NOT NULL,
    physical_qty NUMERIC NOT NULL,
    difference NUMERIC NOT NULL,
    notes TEXT
);

-- Penyesuaian stok manual (mandiri atau dari hasil opname)
CREATE TABLE stock_adjustments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    adjustment_no TEXT UNIQUE NOT NULL, -- e.g. ADJ-20260713-0001
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    opname_detail_id UUID REFERENCES stock_opname_details(id) ON DELETE SET NULL,
    qty_adjusted NUMERIC NOT NULL, -- Positif untuk penambahan, negatif untuk pengurangan
    cogs_unit NUMERIC NOT NULL,    -- HPP per unit saat penyesuaian
    reason TEXT NOT NULL,          -- e.g. 'Rusak', 'Hilang', 'Selisih Opname'
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tipe Mutasi Kartu Stok
CREATE TYPE stock_movement_type AS ENUM ('SALE', 'PURCHASE', 'ADJUSTMENT', 'TRANSFER_IN', 'TRANSFER_OUT');

-- Log kartu stok historis per warehouse
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

---

## 6. Laporan Keuangan (Finance Module)

Double-entry ledger yang menyajikan:
1. **Laba / Rugi (P&L)**: Menghitung Pendapatan minus HPP FIFO aktual (berdasarkan log alokasi `sales_fifo_allocations`) minus beban CA.
2. **Neraca Keuangan**: Menyajikan Aktiva vs Pasiva secara realtime.

---

## 7. Rencana Tugas Implementasi (To-Do List)

### Langkah 7.1: Eksekusi SQL Migrasi Baru (Supabase)
* [ ] Jalankan query pembuatan tabel `uoms` dan `product_uom_conversions` (Master UOM).
* [ ] Jalankan query pembuatan tabel `product_batches` dan `sales_fifo_allocations` (FIFO).
* [ ] Jalankan query pembuatan tipe `opname_status` dan tabel `stock_opnames`, `stock_opname_details`, serta `stock_adjustments` (Opname & Adjustment).
* [ ] Jalankan query pembuatan tabel `customer_pricelists` (Pricelist kustom).
* [ ] Jalankan query pembuatan tipe `stock_movement_type` dan tabel `stock_movements` (Kartu Stok).
* [ ] Buat trigger/fungsi PostgreSQL `allocate_fifo_cogs()` untuk mendukung penjualan bundling dan alokasi FIFO otomatis saat checkout.
* [ ] Buat fungsi trigger/RPC `approve_stock_opname()` untuk mengesahkan opname fisik.
* [ ] Buat trigger log mutasi otomatis untuk mengisi tabel `stock_movements` setiap kali stok berubah.

### Langkah 7.2: Pembuatan API & Komponen Impor di Backoffice
* [x] Setup route `/api/products/import` untuk membaca data CSV/Excel produk.
* [x] Buat UI Halaman CRUD Produk dan tombol Impor CSV.

### Langkah 7.3: Halaman Konfirmasi Order Stok & Penyesuaian Stok
* [x] Buat UI Manajemen Pembelian (PO) dengan filter "Menunggu Konfirmasi".
* [x] Tautkan tombol "Konfirmasi Terima" ke RPC database yang menambah stok dan batch FIFO.
* [x] Buat UI Manajemen Penyesuaian Stok (*Stock Adjustment*) & Halaman Audit hitung fisik (*Stock Opname*).

### Langkah 7.4: Modul Pelanggan & Pricelist Kustom
* [x] Buat halaman terpisah untuk CRUD Pelanggan (Customer Manager).
* [x] Buat sub-modul untuk mengatur daftar harga kustom (*customer pricelist*) per produk untuk pelanggan tertentu.

### Langkah 7.5: Laporan Laba/Rugi FIFO & Kartu Stok
* [ ] Perbarui tab Laporan Keuangan agar menghitung HPP berdasarkan hasil alokasi tabel `sales_fifo_allocations`.
* [ ] Buat sub-tab Laporan Pergerakan Stok (*Stock Card*) untuk memantau mutasi barang masuk/keluar.
