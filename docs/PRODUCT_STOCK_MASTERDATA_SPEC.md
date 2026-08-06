# Spesifikasi Produk, Master Data, dan Inventory KGS

**Status:** Draft 1.31 — Guardrail final Ketul telah dikonfirmasi  
**Tanggal:** 2026-07-15  
**Pemilik keputusan bisnis:** User/Product Owner KGS  
**Scope aktif:** Produk dan stok  
**Dokumen ini belum memberi izin implementasi schema, backend, RPC, atau UI.**

---

## 1. Tujuan Dokumen

Dokumen ini menjadi kontrak kerja bersama untuk membangun modul Produk dan Inventory KGS secara bertahap. Dokumen harus dapat dibaca oleh developer maupun AI agent lain tanpa bergantung pada percakapan sebelumnya.

Target utamanya:

1. Master data tidak dibuat secara liar saat import transaksi atau stok.
2. Produk, kategori, UOM, gudang, dan referensi akuntansi memiliki sumber data yang jelas.
3. Import mengikuti pola staging seperti Odoo: upload, mapping, validasi, preview, lalu commit.
4. Saldo stok saat ini dapat ditelusuri kembali ke seluruh stock movement.
5. Koreksi stok wajib melalui dokumen adjustment atau stock opname, bukan edit angka saldo langsung.
6. Seluruh data tetap terisolasi per company.
7. Desain tetap kompatibel dengan POS, pembelian, FIFO, dan keuangan yang sudah direncanakan.

---

## 2. Batas Scope

### 2.1 Termasuk dalam scope tahap ini

- Struktur menu dan submodul Inventory.
- Master Produk.
- Master Kategori Produk.
- Master UOM dan konversi UOM produk.
- Master Gudang.
- Persiapan referensi COA pada kategori produk.
- Stock Movement/Kartu Stok.
- Stock Real/Saldo Saat Ini.
- Stock Adjustment.
- Stock Opname dan Report Stock Opname.
- Konfirmasi Order yang berdampak pada penerimaan stok.
- Import master produk dan stok awal dengan staging, validasi, preview, dan audit.
- Hak akses dalam konteks multi-company.
- Aturan integritas data dan acceptance criteria.

### 2.2 Belum termasuk dalam scope implementasi

- Implementasi database/migration baru.
- Implementasi API/RPC baru.
- Implementasi UI baru.
- Purchasing lengkap dari permintaan pembelian sampai tagihan supplier.
- Sales order/delivery lengkap.
- Posting jurnal final dan laporan keuangan final.
- Barcode label/printing.
- Integrasi ongkir eksternal.
- Lot, serial number, dan expiry date sampai diputuskan dibutuhkan.

Scope yang belum termasuk hanya boleh dikerjakan setelah dokumen ini disetujui dan keputusan terbuka sudah dijawab.

---

## 3. Fakta Kondisi Project Saat Ini

Bagian ini berisi fakta dari repository, bukan target desain.

### 3.1 Fakta database

- `products` saat ini memiliki SKU, nama, kategori berbentuk teks, harga jual (`price`), HPP/harga beli (`cogs`), UOM teks, `uom_id`, status bundle, status aktif, `company_id`, dan `weight_per_uom_kg`.
- `uoms` dan `product_uom_conversions` sudah dirancang pada `supabase/inventory_migration.sql`.
- `warehouses`, `product_stocks`, `product_batches`, `stock_movements`, `stock_adjustments`, `stock_opnames`, dan `stock_opname_details` sudah memiliki rancangan/tabel existing.
- `company_id` sudah ditambahkan ke tabel inventory melalui migrasi multi-company.
- SKU, kode UOM, dan kode gudang sudah diarahkan agar unik per company, bukan global.
- `confirm_purchase_order()` menambah saldo stok, membuat FIFO batch, dan menulis movement bertipe `PURCHASE`.

Gap penting: RPC existing `confirm_purchase_order()` belum memodelkan request dari POS, pemesanan oleh Store Manager, partial receipt per kedatangan, penerimaan oleh kasir, invoice matching oleh Finance, AP provisional, koreksi harga aktual, dan pembayaran. RPC tersebut tidak boleh dianggap sudah memenuhi flow target pada bagian 9.4.

### 3.2 Fakta import existing

Endpoint existing:

```text
POST /api/products/import
```

Template existing memuat:

```text
sku
nama_produk
kategori
harga_jual_umum
harga_beli_awal_hpp
satuan_uom
berat_per_uom_kg
stok_awal
kode_gudang
```

Satu import existing melakukan seluruh tindakan berikut secara langsung:

1. Membaca CSV.
2. Membuat UOM apabila kode belum ada.
3. Membuat gudang apabila kode belum ada.
4. Membuat atau memperbarui produk berdasarkan `(company_id, sku)`.
5. Membuat saldo stok awal.
6. Membuat batch FIFO untuk stok awal.
7. Membuat stock movement bertipe `PURCHASE` untuk stok awal.

Import dilakukan dalam pemanggilan RPC tanpa tabel staging dan tanpa preview validasi di UI.

### 3.3 Fakta UI existing

- Navigasi backoffice saat ini hanya memiliki halaman gabungan **Produk & Stok**.
- Halaman menampilkan daftar produk, total stok, berat per UOM, lokasi gudang, pencarian, dan tombol import CSV.
- CRUD manual produk, master kategori, master UOM, master gudang, movement, adjustment, opname, dan konfirmasi order belum terlihat pada jalur render aktif `backoffice/src/app/page.tsx`.
- `backoffice/backoffice_breakdown.md` menandai beberapa fitur inventory sebagai selesai, tetapi implementasi UI aktif saat ini belum sesuai dengan checklist tersebut. Checklist lama tidak boleh dijadikan bukti bahwa fitur sudah tersedia.

---

## 4. Masalah yang Harus Diselesaikan

### 4.1 Import mencampur master dan transaksi

Kode UOM atau gudang yang salah ketik dapat langsung menjadi master baru. Contoh:

```text
PCS
Pcs
PC
PCC
```

Tanpa normalisasi dan approval, nilai tersebut berpotensi menjadi empat master berbeda.

### 4.2 Kategori masih berupa teks bebas

Kategori produk belum menjadi entitas master yang dapat dipakai untuk:

- filter dan reporting;
- default COA;
- default kebijakan inventory;
- default pajak di masa depan;
- default costing/accounting behavior.

### 4.3 Saldo stok dapat kehilangan konteks dokumen

Stok awal, pembelian, transfer, penjualan, adjustment, dan opname harus memiliki dokumen sumber yang jelas. Penamaan stok awal sebagai `PURCHASE` membuat audit sumber stok menjadi ambigu.

### 4.4 Tidak ada dry-run dan preview

User belum dapat melihat:

- baris valid;
- baris error;
- master referensi yang tidak ditemukan;
- record yang akan dibuat;
- record yang akan diperbarui;
- perubahan harga;
- perubahan UOM;
- dampak stok;
- duplicate di file atau database.

### 4.5 Dokumen dan implementasi mengalami drift

Dokumen lama mencatat fitur selesai, tetapi jalur UI aktif belum menyediakan fitur tersebut. Spesifikasi baru harus memiliki status yang bisa dibuktikan:

```text
PROPOSED -> APPROVED -> IMPLEMENTED -> VERIFIED
```

---

## 5. Prinsip Desain

1. **Company scoped:** seluruh master dan transaksi inventory wajib memiliki `company_id`.
2. **Master first:** transaksi/import hanya boleh mereferensikan master yang sudah valid.
3. **No silent creation:** import produk tidak boleh diam-diam membuat kategori, UOM, gudang, atau COA.
4. **Preview before commit:** setiap bulk import wajib memiliki tahap validasi dan preview.
5. **Immutable stock history:** movement final tidak diedit atau dihapus; koreksi memakai reversal/adjustment.
6. **No direct balance editing:** `product_stocks.stock_qty` bukan field CRUD biasa.
7. **Document driven:** setiap perubahan stok harus berasal dari dokumen yang dapat ditelusuri.
8. **Idempotent:** import atau konfirmasi yang dikirim ulang tidak boleh menggandakan stok.
9. **Soft archive:** master yang sudah dipakai transaksi tidak dihapus; cukup dinonaktifkan.
10. **Explicit status:** draft tidak memengaruhi stok; hanya dokumen posted/confirmed yang memengaruhi stok.
11. **Base UOM:** saldo internal harus disimpan dalam satu base UOM per produk.
12. **Auditability:** actor, waktu, company, sumber, alasan, dan nilai sebelum/sesudah harus dapat dilihat.

---

## 6. Struktur Modul Target

Struktur awal yang diusulkan:

```text
Inventory
├── Stock Real / Saat Ini
├── Stock Movement / Kartu Stok
├── Transfer Stok
├── Adjustment Stok
├── Stock Opname
├── Report Stock Opname
└── Konfirmasi Order

Master Data
├── Produk
├── Kategori Produk
├── Brand/Merek
├── UOM
├── Konversi UOM Produk
├── Gudang
├── Supplier
├── Relasi Produk-Supplier
└── Import & Export Data
```

Catatan:

- Master Data menjadi tempat CRUD referensi reusable.
- Inventory menjadi tempat saldo dan dokumen pergerakan stok.
- Import Data berada di Master Data, tetapi import stok awal menghasilkan dokumen inventory terpisah.
- Transfer Stok sudah dikenal oleh schema existing dan tetap dipertahankan walaupun tidak disebut eksplisit pada permintaan terbaru.

---

## 7. Master Data Target

### 7.1 Master Produk

Field awal yang diusulkan:

| Kelompok | Field | Aturan awal | Status keputusan |
|---|---|---|---|
| Identitas | Company | Wajib, dari company aktif | Disepakati dari arsitektur existing |
| Identitas | Kode/SKU | Wajib, diisi manual, unik per company | Disepakati |
| Identitas | Nama produk | Wajib, tidak boleh duplikat dalam company yang sama | Disepakati |
| Identitas | Barcode | Opsional per UOM dan unik per company bila diisi | Disepakati |
| Identitas | Gambar utama | Opsional satu gambar teroptimasi; dapat dinonaktifkan bila quota terbatas | Disepakati |
| Klasifikasi | Kategori produk | Wajib memilih dari Master Kategori melalui dropdown | Disepakati |
| Klasifikasi | Brand/Merek | Opsional, memilih dari Master Brand | Disepakati |
| Klasifikasi | Tipe produk | Hanya `STOCK` dan `BUNDLE` untuk fokus retail | Disepakati |
| Harga | Harga beli | Wajib per UOM yang digunakan, tidak negatif | Disepakati; metode costing masih perlu detail |
| Harga | Harga jual | Wajib per UOM yang dijual, tidak negatif | Disepakati |
| UOM | UOM produk | Minimal satu, dapat ditambah beberapa UOM turunan secara manual | Disepakati |
| UOM | UOM terbesar/referensi | Diturunkan otomatis dari faktor terbesar dan menjadi acuan berat | Disepakati |
| Logistik | Berat UOM terbesar | Wajib diisi manual | Disepakati |
| Logistik | Panjang/lebar/tinggi | Belum dibutuhkan | Ditunda |
| Inventory | Dapat memiliki stok | Diturunkan dari tipe produk | Diusulkan |
| Inventory | Minimum stock | Opsional per produk-gudang; hanya memicu notice Cashier | Disepakati |
| Accounting | Kategori/COA default | Diturunkan dari kategori; tidak ada override COA per Produk pada scope ini | Disepakati; mapping akun final ditunda ke Finance |
| Status | Aktif/arsip | Soft archive | Diusulkan |
| Audit | created/updated by & at | Wajib | Diusulkan |

Aturan awal:

- Produk retail pada scope ini hanya bertipe `STOCK` atau `BUNDLE`.
- Produk tidak boleh dibuat tanpa kategori yang valid dan minimal satu UOM.
- Kategori tidak diketik sebagai teks bebas; user wajib memilih dari dropdown Master Kategori.
- SKU selalu diisi manual oleh user dan unik per company.
- Nama produk tidak boleh duplikat dalam company yang sama. Perbedaan kapitalisasi dan spasi tidak boleh dipakai untuk melewati validasi duplikat.
- Satu produk dibuat satu kali dan dapat memiliki beberapa UOM/kemasan. UOM turunan tidak dibuat sebagai produk atau SKU baru.
- Harga beli dan harga jual dasar ditentukan manual per UOM. Harga UOM besar tidak dihitung otomatis dari harga UOM kecil karena kebijakan harga per kemasan dapat berbeda.
- Harga jual dasar Produk-UOM adalah fallback terakhir. Customer dengan Pricelist Eksklusif melewati Pricelist Global; tanpa customer exclusive, Global berlaku sebelum fallback produk.
- POS dapat menjual menggunakan UOM produk yang diaktifkan untuk penjualan.
- Penjualan dalam UOM apa pun mengurangi saldo dalam base/stock UOM terkecil setelah dikonversi.
- Produk yang sudah memiliki movement tidak boleh mengganti base UOM tanpa proses konversi/migrasi terkontrol.
- Mengubah harga tidak mengubah harga pada transaksi historis.
- Mengubah HPP referensi tidak mengubah batch FIFO historis.
- Produk nonaktif tetap muncul pada transaksi dan laporan historis.

### 7.1.1 Field form pembuatan produk

Form awal pembuatan produk wajib berisi:

```text
Kode/SKU
Nama Produk
Gambar Utama (opsional)
Kategori Produk (dropdown dari Master Kategori)
Brand/Merek (dropdown opsional dari Master Brand)
Tipe Produk: STOCK / BUNDLE
Daftar UOM
UOM Terbesar/Acuan Berat
Berat UOM Terbesar
Status Aktif
```

Base UOM dipilih satu kali pada identitas Product dan tidak diulang sebagai baris
turunan. Bagian UOM turunan bersifat repeatable. User dapat menekan **Tambah
Kemasan** untuk menambah satuan di atas base, lalu mengisi hubungan langsung
seperti `1 DUS = 10 KETUL`. UI mengurutkan grading berdasarkan faktor ke base.

Contoh:

```text
Produk       : Saus ABC
SKU          : SAUS-ABC
Kategori     : Saus & Bumbu
Tipe         : STOCK
UOM terbesar : DUS
Berat DUS    : 6 kg (diisi manual)
Turunan      : 1 DUS = 12 PACK

Harga PACK
- Harga beli : Rp5.000 (diisi manual)
- Harga jual : Rp7.000 (diisi manual)

Harga DUS
- Harga beli : Rp55.000 (diisi manual)
- Harga jual : Rp80.000 (diisi manual)
```

Satu produk tersebut tetap memiliki satu SKU. `DUS` dan `PACK` adalah pilihan UOM pada produk yang sama.

Harga `DUS` tidak wajib sama dengan harga `PACK x 12`. Setiap UOM menyimpan harga manualnya sendiri.

Harga beli pada form Produk adalah **harga beli awal/referensi** yang diisi manual agar produk dapat digunakan sebelum memiliki histori pembelian. Setelah tersedia invoice supplier tervalidasi, UI menampilkan **Harga Beli Terakhir** dari supplier utama secara terpisah. Harga beli awal tidak ditimpa diam-diam dan bukan sumber langsung HPP transaksi historis.

### 7.1.2 Gambar Produk Ringan

Gambar produk bersifat opsional dan tidak boleh menjadi blocker pembuatan/import Produk. Target awal hanya satu gambar utama per produk.

Aturan efisiensi untuk Supabase/Vercel free tier:

- Scope awal tidak meng-upload gambar ke Supabase Storage. User menyimpan foto di Google Drive lalu sistem hanya menyimpan `image_url`/metadata sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`.
- Backend tetap menjaga row metadata tenant-scoped, tetapi akses file mengikuti sharing permission Google Drive milik company.
- Browser/server tidak menerima Google credential, tidak mengunduh file, dan tidak mem-proxy gambar melalui Vercel.
- Product list menggunakan placeholder. Preview eksternal hanya dilakukan bila browser dapat mengakses URL; aksi utama tetap membuka link.
- Link wajib HTTPS dan perubahan URL menyimpan actor/waktu audit.
- Migrasi ke private Supabase Storage/RLS ditunda sampai ada keputusan capacity, retention, rollout, dan rollback baru.
- Galeri banyak gambar, import gambar massal, dan image processing berat ditunda.
- Fitur gambar dapat dimatikan melalui feature flag/config bila quota storage/bandwidth terbatas.
- Produk tanpa gambar menggunakan placeholder lokal dan seluruh fungsi POS tetap berjalan.
- Penggantian gambar dan cleanup object lama harus tercatat/aman agar tidak membuat orphan file berlebihan.

### 7.2 Master Kategori Produk

Kategori adalah master per company, bukan teks bebas.

Field awal:

```text
company_id
category_code
category_name
inventory_valuation_coa_id nullable
stock_input_coa_id nullable
stock_output_coa_id nullable
cogs_coa_id nullable
sales_income_coa_id nullable
sales_return_coa_id nullable
purchase_return_coa_id nullable
status
created_at / created_by
updated_at / updated_by
```

Catatan:

- Master Kategori hanya satu tingkat/flat dan tidak memiliki parent category.
- Kode kategori diisi manual dan unik per company.
- Nama kategori tidak boleh duplikat dalam company yang sama setelah normalisasi kapitalisasi dan spasi.
- Nama dan jumlah field COA belum final.
- Pada fase Produk & Stok, seluruh field COA kategori boleh kosong sampai Master COA dan Finance resmi tersedia.
- Ketika fase Finance diaktifkan, mapping COA yang ditetapkan sebagai wajib harus dilengkapi sebelum kategori boleh digunakan untuk transaksi baru.
- Aturan/kategori transaksi adalah penentu utama pencatatan jurnal.
- COA pada kategori produk hanya menjadi fallback apabila mapping COA transaksi tidak tersedia.
- Guardrail yang diusulkan: jika mapping transaksi dan fallback kategori sama-sama kosong, posting jurnal berstatus `ERROR`/ditahan untuk diperbaiki; sistem tidak menebak akun. Guardrail ini dikonfirmasi kembali saat fase Finance.
- Product Master tidak memiliki override COA pada scope saat ini. Produk mengikuti fallback dari kategorinya.
- Implementasi dilarang menyimpan kode COA teks bebas jika master COA sudah tersedia.

Prioritas resolusi akun target (level 1 dan 2 disepakati; level 3 masih guardrail usulan):

```text
1. COA dari aturan/kategori transaksi
2. COA fallback dari Master Kategori Produk
3. Explicit company fallback yang compatible
4. Tidak ditemukan -> posting ditahan/ERROR
```

Detail integrasi keuangan dan daftar keputusan tertunda dicatat pada:

```text
docs/FINANCE_INTEGRATION_NOTES.md
```

### 7.3 Master UOM

Field awal:

```text
company_id
uom_code
uom_name
uom_category/type
decimal_precision
allow_decimal
status
```

Contoh:

```text
PCS, unit, tidak pecahan
SAK, unit kemasan, tidak pecahan
KG, berat, boleh pecahan
GRAM, berat, boleh pecahan
METER, panjang, boleh pecahan
```

Aturan awal:

- Kode UOM unik per company.
- Import produk hanya boleh memakai kode UOM aktif yang sudah ada.
- Perbedaan huruf besar/kecil dan spasi dinormalisasi sebelum validasi.
- UOM yang sudah digunakan tidak dihapus.
- Daftar UOM global hanya mendefinisikan jenis satuan seperti `DUS` dan `PACK`; hubungan `1 DUS = 12 PACK` diatur pada produk.
- `allow_decimal = false` mewajibkan quantity bilangan bulat untuk UOM seperti PCS, PACK, dan DUS.
- `allow_decimal = true` memperbolehkan quantity pecahan untuk UOM seperti KG, LITER, GRAM, dan METER.
- `decimal_precision` default adalah 3 digit dan hanya berlaku ketika `allow_decimal = true`.
- Input quantity yang melebihi precision UOM ditolak dengan notice agar user memperbaikinya; sistem tidak membulatkan quantity diam-diam.
- Fitur rounding DOWN/UP yang disepakati berlaku pada grand total nilai penjualan, bukan pada quantity inventory.

### 7.4 Konversi UOM Produk

Konversi dapat berbeda per produk. Contoh:

```text
Produk A: 1 DUS = 12 PCS
Produk B: 1 DUS = 24 PCS
```

Field awal:

```text
company_id
product_id
from_uom_id
to_uom_id
conversion_factor
purchase_allowed
sales_allowed
barcode nullable
purchase_price
sale_price
weight_per_from_uom_kg nullable
status
```

Aturan awal:

- Satu produk dapat memiliki beberapa UOM yang ditambahkan manual.
- Base/stock UOM wajib merupakan UOM terkecil produk.
- Seluruh UOM lain wajib menyimpan faktor konversi langsung ke base UOM terkecil.
- Konversi tidak disimpan sebagai rantai bertingkat antar-UOM non-base. Contoh: jika base `PCS`, maka `PACK = 10 PCS` dan `DUS = 120 PCS`, bukan hanya `DUS = 12 PACK`.
- UI boleh menampilkan hubungan kemasan yang mudah dibaca, tetapi kalkulasi dan penyimpanan selalu menggunakan faktor langsung ke base.
- UOM terbesar diturunkan otomatis dari faktor aktif terbesar pada produk dan
  menjadi acuan berat. User tidak memilih radio acuan berat secara manual.
- Berat UOM terbesar diisi manual.
- Berat UOM turunan dihitung proporsional dari berat UOM terbesar dan faktor konversi. Jika `1 DUS = 12 PACK` dan berat `1 DUS = 6 kg`, berat kalkulasi `1 PACK = 0,5 kg`.
- Berat turunan merupakan estimasi operasional/ongkir dan boleh tidak 100% sama dengan berat fisik akibat kemasan luar atau pembulatan.
- Sistem tidak meminta user mengisi berat setiap UOM secara manual pada tahap awal.
- Harga beli dan harga jual dapat berbeda pada setiap UOM dan wajib diisi manual untuk UOM yang diaktifkan.
- Semua saldo disimpan dalam base UOM.
- Quantity transaksi dikonversi ke base UOM saat posting.
- Precision input, intermediate calculation, FIFO unit cost, weight estimate, cross-document UOM, dan conversion versioning mengikuti `docs/UOM_WEIGHT_VALUATION_SPEC.md`.
- Faktor konversi wajib positif.
- Siklus konversi yang kontradiktif harus ditolak.
- Perubahan faktor tidak boleh mengubah transaksi historis; transaksi menyimpan snapshot faktor yang digunakan.
- Barcode bersifat opsional per UOM produk.
- Barcode yang diisi wajib unik dalam company yang sama setelah normalisasi.
- Satu barcode hanya mengarah ke satu kombinasi produk-UOM aktif; duplikasi membuat validasi/import gagal.
- Scan barcode yang cocok persis menambahkan quantity `1` menggunakan UOM dan harga milik barcode tersebut.
- Jika kombinasi produk-UOM yang sama sudah berada di keranjang, scan berikutnya menambah quantity line tersebut; Cashier tetap dapat mengubah quantity secara manual.
- UOM berbeda pada produk yang sama tetap menjadi line terpisah karena faktor dan harga dapat berbeda.
- Barcode tidak ditemukan hanya menampilkan notice dan tidak pernah membuat Produk/UOM secara otomatis.

### 7.4.1 Aturan stok dan harga lintas UOM

Contoh:

```text
Produk             : Saus ABC
Base/stock UOM     : PACK
UOM jual tambahan : DUS
Konversi           : 1 DUS = 12 PACK
Saldo database     : 120 PACK
Tampilan konversi  : 10 DUS atau 120 PACK
```

Jika POS menjual `2 DUS`, movement stok tetap ditulis dalam base UOM:

```text
2 DUS x 12 PACK = 24 PACK keluar
Saldo: 120 PACK -> 96 PACK
```

Harga transaksi mengikuti harga UOM yang dipilih pada POS:

```text
Harga jual 1 PACK = Rp7.000
Harga jual 1 DUS  = Rp80.000
```

Harga `DUS` tidak dihitung sebagai `12 x Rp7.000`. Transaction line wajib menyimpan snapshot:

```text
selected_uom_id
transaction_qty
conversion_factor_snapshot
base_qty
unit_price_snapshot
subtotal
```

### 7.4.2 Aturan produk bundle

Produk `BUNDLE` bersifat virtual:

- Tidak memiliki saldo fisik sendiri pada `product_stocks`.
- Memiliki daftar komponen produk beserta quantity dan UOM komponennya.
- Available quantity bundle dihitung dari komponen yang paling membatasi.
- Saat bundle terjual, stok yang berkurang adalah stok setiap komponen setelah dikonversi ke base UOM komponen.
- Berat bundle dihitung dari total estimasi berat seluruh komponen.
- HPP bundle dihitung dari total HPP komponen sesuai costing/FIFO yang berlaku.
- Harga jual bundle diisi manual dan tidak wajib sama dengan penjumlahan harga jual komponen.
- Bundle dapat mewakili promo seperti 2+1: quantity stock seluruh komponen tetap berkurang, sedangkan harga jual bundle dapat setara item yang dibayar.
- Perubahan komposisi bundle tidak mengubah snapshot transaksi bundle historis.
- Komponen bundle wajib berupa produk bertipe `STOCK`.
- Produk bertipe `BUNDLE` tidak boleh menjadi komponen bundle lain; nested bundle ditolak untuk mencegah loop dan ketidakjelasan stok/HPP.

Contoh:

```text
Bundle: Paket Saus
- 2 PACK Saus ABC
- 1 PCS Botol Minum

Stok Saus ABC   : 20 PACK -> kapasitas 10 bundle
Stok Botol      : 7 PCS   -> kapasitas 7 bundle
Available bundle: 7
```

### 7.5 Master Gudang

Field awal:

```text
company_id
warehouse_code
warehouse_name
warehouse_type
store_id nullable
location/address
is_sale_source
is_purchase_destination
allow_negative_stock
status
```

Aturan awal:

- Tipe gudang dasar terdiri dari `CENTRAL`, `STORE`, `DAMAGED`, dan `TRANSIT`.
- Kode gudang diisi manual oleh user.
- Kode gudang terdiri dari 1–5 huruf, dinormalisasi menjadi huruf kapital, dan unik per company.
- Gudang bertipe `STORE` wajib terhubung ke tepat satu store.
- Gudang bertipe `CENTRAL` boleh tidak terhubung ke store.
- Gudang `DAMAGED` dan `TRANSIT` boleh company-level tanpa store atau dihubungkan ke store bila dibutuhkan.
- Lokasi/alamat gudang bersifat opsional. Beberapa gudang fungsional seperti Gudang Bahan Baku dan Gudang Packaging boleh berada pada lokasi/alamat yang sama.
- Gudang hanya menyimpan lokasi/alamat umum. Master rak, bin, aisle, atau sublokasi tidak dibutuhkan pada scope ini.
- `is_purchase_destination` menandai gudang yang boleh dipilih sebagai tujuan penerimaan stok pada Purchase/receipt dari vendor. Field ini bukan alamat vendor dan tidak berarti vendor tertentu wajib selalu mengirim ke gudang tersebut.
- `is_sale_source` menandai gudang yang stoknya boleh dipilih sebagai sumber pemenuhan/penjualan.
- Import tidak boleh otomatis membuat gudang.
- Gudang yang memiliki histori tidak dihapus.
- Master Gudang dapat dikelola oleh Company Owner/Admin, Warehouse Admin, dan Store Manager/SPV Toko sesuai scope aksesnya.
- Super Admin tetap dapat mengelola seluruh gudang pada seluruh company.
- Stok negatif tidak diizinkan.

Hak kelola awal:

| Role sistem | Istilah bisnis | Scope kelola gudang |
|---|---|---|
| `super_admin` | Super Admin | Seluruh company |
| `COMPANY_OWNER` / `COMPANY_ADMIN` | Owner/Admin | Seluruh gudang dalam company aktif |
| `WAREHOUSE_ADMIN` | Admin Gudang | Gudang yang ditugaskan/diizinkan dalam company |
| `STORE_MANAGER` | SPV Toko | Gudang `STORE` yang terhubung ke store penugasannya |

Hak “mengatur” mencakup melihat, membuat, memperbarui, mengaktifkan, dan menonaktifkan master dalam scope tersebut. Hard delete tetap dilarang jika gudang sudah mempunyai histori.

Tipe gudang dasar:

| Tipe | Fungsi |
|---|---|
| `CENTRAL` | Gudang pusat/distribusi company |
| `STORE` | Gudang operasional toko/POS dan wajib terkait store |
| `DAMAGED` | Penampungan barang rusak/tidak layak jual |
| `TRANSIT` | Penampungan logis barang yang sedang dipindahkan/dalam perjalanan |

Contoh kode valid:

```text
GDS
KGS
RSK
TRNST
```

Contoh kode tidak valid:

```text
GUDANG       # lebih dari 5 huruf
GD-01        # mengandung simbol dan angka
             # kosong
```

### 7.6 Master Brand/Merek

Brand adalah master reusable per company dan bersifat opsional pada Produk.

Field awal:

```text
company_id
brand_code
brand_name
is_active
created_at / created_by
updated_at / updated_by
```

Aturan:

- Kode dan nama Brand unik per company setelah normalisasi.
- Produk boleh tidak memiliki Brand.
- Brand nonaktif tidak dapat dipilih untuk produk baru, tetapi tetap terlihat pada histori/produk existing.
- Brand yang sudah dipakai tidak dihapus permanen.
- Import Produk hanya mereferensikan Brand existing dan tidak membuat Brand secara diam-diam.

### 7.6.1 Kandidat master data lanjutan

Entitas berikut berpotensi reusable, tetapi belum masuk implementasi tahap pertama:

- Lokasi/rak/bin di dalam gudang.
- Pajak optional dan entitlement-nya independen per company/modul. Super Admin dapat men-toggle `SALES_TAX` dan `PURCHASE_TAX` secara terpisah; Product Category menyimpan default Sales/Purchase Tax Rule dan Produk dapat override sesuai `docs/TAX_ENGINE_SPEC.md`.
- Pricelist.
- Barcode alternatif.
- Packaging.
- Master COA.

Entitas tidak otomatis dibuat menjadi tabel hanya karena disebut di sini. Harus ada kebutuhan bisnis dan keputusan eksplisit.

### 7.7 Master Alasan Adjustment

Alasan Adjustment menjadi master reusable per company agar pencatatan konsisten dan dapat dipakai untuk reporting serta mapping Finance di masa depan.

Field minimum:

```text
company_id
reason_code
reason_name
direction_allowed: INCREASE / DECREASE / BOTH
finance_treatment: STOCK_GAIN / STOCK_LOSS / OTHER
is_active
created_at / created_by
updated_at / updated_by
```

Contoh awal:

```text
BARANG_RUSAK
BARANG_HILANG
SALAH_INPUT
SELISIH_STOK
KEDALUWARSA
KOREKSI_MIGRASI
```

COA tidak ditentukan langsung pada fase Produk & Stok. `finance_treatment` hanya memberi klasifikasi awal; mapping akun final mengikuti `docs/FINANCE_INTEGRATION_NOTES.md`.

### 7.8 Master Supplier

Supplier menjadi master reusable per company dan dipilih ketika Store Manager membuat order ke supplier.

Field awal:

```text
company_id
supplier_code
supplier_name
contact_name nullable
phone nullable
address nullable
npwp nullable
payment_term nullable
bank_name nullable
bank_account_number nullable
bank_account_holder nullable
is_active
created_at / created_by
updated_at / updated_by
```

Aturan awal:

- Kode Supplier diisi manual dan unik per company.
- Nama Supplier tidak boleh ambigu dalam company yang sama.
- Supplier nonaktif tidak dapat dipilih untuk order baru, tetapi tetap tampil pada histori.
- Supplier yang sudah memiliki order/invoice tidak dapat dihapus permanen.
- Satu rekening utama supplier dapat disimpan agar Finance dapat menyalin nomor rekening ketika melakukan pembayaran.
- Nomor rekening hanya menjadi referensi pembayaran; akses perubahan dibatasi ke role pengelola Master Supplier dan setiap perubahan wajib memiliki audit trail.
- Saldo hutang, limit kredit, rekening tambahan, serta aturan pajak lebih lanjut dibahas kembali pada fase Purchasing/Finance.

### 7.9 Relasi Produk-Supplier

Satu produk dapat dibeli dari beberapa supplier. Relasi ini menyimpan referensi pembelian per supplier dan menjadi sumber pencarian harga beli ketika Store Manager membuat Supplier Order.

Field awal:

```text
company_id
product_id
supplier_id
supplier_product_code nullable
purchase_uom_id
reference_purchase_price nullable
last_purchase_price nullable
is_preferred_supplier
is_active
last_price_updated_at nullable
last_price_source_document_id nullable
created_at / created_by
updated_at / updated_by
```

Aturan:

- Kombinasi produk dan supplier unik dalam company yang sama.
- Satu produk boleh memiliki banyak supplier aktif, tetapi maksimal satu supplier utama/default.
- Supplier utama bersifat opsional dan hanya menjadi saran; Store Manager tetap dapat memilih supplier aktif lain.
- `purchase_uom_id` wajib merupakan UOM aktif milik produk tersebut.
- `reference_purchase_price` dapat diisi manual/berasal dari penawaran atau order awal sebagai default sebelum tersedia invoice tervalidasi.
- `last_purchase_price` hanya berasal dari invoice supplier yang sudah divalidasi Finance dan disimpan untuk UOM pembelian pada relasi tersebut, bukan dipaksakan sebagai harga per base UOM.
- Kode produk versi supplier bersifat opsional dan membantu pencarian/komunikasi order.
- Prioritas default harga Supplier Order adalah `last_purchase_price`, lalu `reference_purchase_price`, lalu harga beli awal Produk pada UOM terkait.
- Store Manager dapat mengubah harga pada Supplier Order. Nilai yang digunakan order disimpan sebagai snapshot.
- Setelah invoice supplier divalidasi Finance, harga aktual menjadi sumber pembaruan `last_purchase_price` beserta referensi dokumennya.
- Membuat Supplier Order atau mem-posting Goods Receipt tidak memperbarui `last_purchase_price`.
- Perubahan harga referensi tidak mengubah Supplier Order, receipt, batch, HPP, atau jurnal historis.

Hubungan dengan HPP:

- Harga produk/master dan harga Produk-Supplier adalah harga beli referensi untuk membantu pemesanan.
- Goods Receipt membuat batch FIFO provisional menggunakan snapshot harga Supplier Order.
- Harga invoice aktual yang divalidasi Finance mengoreksi nilai batch/valuation sesuai aturan Finance.
- HPP penjualan berasal dari cost batch/FIFO yang dikonsumsi, bukan langsung membaca harga referensi terbaru dari master produk atau relasi supplier.
- Jika koreksi harga aktual terjadi setelah sebagian batch terjual, alokasi selisih ke Persediaan/HPP/Price Variance tetap dibahas pada fase Finance.

---

## 8. Model Stok Target

### 8.1 Stock Real / Saat Ini

Stock Real adalah saldo terkini per kombinasi:

```text
company + warehouse + product + base UOM
```

Tampilan minimum:

```text
SKU
Nama produk
Kategori
Gudang
On hand
Reserved
Available
Base UOM
Nilai persediaan
Waktu movement terakhir
```

Formula awal yang diusulkan:

```text
On Hand  = saldo seluruh movement posted
Reserved = stok yang dipesan/dialokasikan tetapi belum keluar
Available = On Hand - Reserved
```

`Reserved` belum dapat diimplementasikan sampai arti “Konfirmasi Order” diputuskan.

Saldo database selalu menggunakan UOM terkecil/base. UI boleh menampilkan hasil konversi ke UOM lain, tetapi angka hasil konversi bukan saldo terpisah.

Saldo tidak boleh menjadi negatif. Jika posting penjualan akan menyebabkan satu atau lebih saldo produk menjadi negatif, seluruh transaksi penjualan tidak diposting dan disimpan sebagai `DRAFT`.

### 8.1.1 Minimum Stock dan Notice POS

Minimum stock bersifat opsional per kombinasi produk-gudang:

```text
company_id
warehouse_id
product_id
minimum_stock_base_qty nullable
low_stock_alert_enabled
updated_at / updated_by
```

Aturan:

- Threshold disimpan dalam base UOM dan dapat ditampilkan dalam UOM produk lain melalui konversi.
- Jika threshold kosong atau alert nonaktif, tidak ada notice.
- Ketika saldo on-hand mencapai atau di bawah threshold, POS menampilkan notice non-blocking kepada Cashier yang bertugas pada gudang/store tersebut.
- Notice tidak membuat Stock Request atau Supplier Order otomatis.
- Cashier dapat membuka aksi **Buat Stock Request** dari notice dengan produk, gudang, dan sisa stok terisi sebagai context; quantity request tetap diisi/dikonfirmasi user.
- Notice tidak menghalangi penjualan selama stok masih mencukupi.

### 8.1.2 Penjualan saat stok tidak mencukupi

Flow target:

```text
User mencoba checkout/konfirmasi penjualan
-> sistem mengunci dan memeriksa saldo seluruh item pada gudang sumber
-> jika semua cukup: transaksi dapat diposting
-> jika satu saja tidak cukup: seluruh transaksi tetap DRAFT
-> tidak ada stock movement
-> tidak ada pengurangan product_stocks
-> tidak ada payment final, financial event, atau jurnal
-> UI menampilkan notice kekurangan stok
```

Notice minimum:

```text
SKU
Nama produk
Gudang
UOM transaksi
Quantity diminta
Quantity tersedia
Quantity kurang
```

Contoh:

```text
Stok Saus ABC di KGS tidak cukup.
Diminta : 2 DUS / 24 PACK
Tersedia: 18 PACK
Kurang  : 6 PACK
Transaksi disimpan sebagai draft dan belum mengurangi stok.
```

Pemeriksaan dan posting harus atomic. Sistem tidak boleh mem-posting sebagian line lalu menjadikan line lain draft.

Selama transaksi masih `DRAFT`:

- transaksi belum dianggap penjualan final;
- stok belum berkurang dan belum direservasi kecuali fitur reservation disetujui kemudian;
- data metode/besaran pembayaran, jika sudah diinput, hanya tersimpan sebagai draft checkout;
- tidak ada row payment final;
- tidak ada `financial_events` yang siap diproses;
- tidak ada `journal_entries`;
- tidak masuk laporan keuangan sebagai transaksi posted.

Transaksi hanya boleh masuk keuangan setelah berhasil melewati pemeriksaan stok dan berubah menjadi status confirmed/posted.

Aturan Draft/Hold Order:

- Semua draft tetap editable dan dapat dibuat karena shortage maupun tombol Hold Order manual.
- Draft tidak mereservasi stok dan dapat dilanjutkan Cashier/terminal lain dalam store yang sama dengan satu edit lock aktif.
- Draft dapat melewati pergantian sesi; creator/session asal dan poster/session final disimpan terpisah.
- Setelah stok tersedia, Cashier melakukan retry/konfirmasi manual dan server memvalidasi ulang seluruh transaksi.
- Harga/promo dihitung ulang sesuai kondisi ketika draft dilanjutkan; perubahan dari snapshot awal ditampilkan untuk konfirmasi.
- Payment pada draft hanya catatan sementara dan wajib dikonfirmasi ulang ketika posting.
- Draft lama mendapat stale notice setelah default 7 hari dengan optional store override dan tidak dihapus otomatis.
- Edit lock kedaluwarsa setelah 5 menit tidak aktif dan dapat diambil alih dengan konfirmasi serta audit.
- Nomor draft dibuat otomatis; label, customer, dan catatan bersifat opsional.
- Pembatalan menyimpan actor/waktu dengan alasan opsional.

### 8.1.3 Stock Keluar Sesi dan Sisa Stock di POS

Cashier dapat melihat metrik operasional per produk pada sesi aktif:

```text
opening_stock_snapshot
gross_sold_qty
sales_return_or_reversal_qty
net_stock_out_qty
current_stock_on_hand
last_stock_updated_at
```

Aturan:

- **Stock Awal Sesi** adalah snapshot seluruh produk aktif pada gudang penjualan ketika sesi berubah menjadi `OPEN`.
- Produk yang dibuat setelah sesi dibuka memiliki stock awal `0` pada laporan sesi tersebut.
- **Terjual Kotor** menghitung movement penjualan posted untuk `active_cashier_session_id` tanpa mengurangi retur.
- **Retur/Reversal** ditampilkan terpisah. Retur yang diproses pada sesi aktif tetap masuk ke sesi tersebut walaupun invoice/penjualan asal berasal dari sesi atau hari sebelumnya; referensi invoice dan sesi asal wajib disimpan.
- **Net Keluar** = Terjual Kotor - Retur/Reversal posted.
- Draft, canceled, dan transaksi gagal tidak dihitung.
- **Stock Terkini** adalah saldo live `product_stocks` pada gudang aktif dan mencakup movement sah dari seluruh user/proses.
- Receipt barang yang berhasil diposting segera memperbarui Stock Terkini pada POS tanpa membuka sesi baru.
- Transaksi yang sebelumnya tertahan karena stok kurang dapat dicoba kembali setelah saldo masuk mencukupi; server tetap melakukan pemeriksaan dan lock saldo ulang saat posting.
- Ketika sesi ditutup, sistem menyimpan snapshot stock penutupan agar Ringkasan Tutup Sesi tidak berubah akibat movement setelah sesi selesai.
- Stock awal dikurangi net keluar tidak wajib sama dengan stock terkini karena dapat ada movement lain selama sesi.
- **Movement Lain** dipisahkan menjadi Penerimaan, Transfer Masuk, Transfer Keluar, Adjustment Masuk/Keluar, Opname, dan jenis non-sale lain agar Store Manager dapat merekonsiliasi perubahan saldo.
- UI dapat mengonversi angka base ke UOM produk terpilih dan menampilkan waktu pembaruan terakhir.
- Product card cukup menampilkan Stock Terkini. Stock Awal, Terjual, Retur, Net Keluar, dan Movement Lain berada pada detail/panel stok agar card tidak penuh.
- Detail stok produk sesi ikut tersedia pada Ringkasan Tutup Sesi dan laporan Store Manager, tetapi tidak memenuhi ringkasan/struk utama.
- Bundle menampilkan jumlah bundle terjual pada sesi dan available bundle live dari komponen pembatas.
- Cashier tidak dapat melihat HPP, cost batch, atau nilai persediaan.
- Snapshot dan query wajib company/store/warehouse/session scoped.

### 8.1.4 Rounding Grand Total Penjualan

Rounding digunakan ketika penjualan berbasis berat/quantity pecahan menghasilkan grand total nilai yang tidak bulat dalam satuan pembayaran.

```text
grand_total_before_rounding
rounding_applied
rounding_direction: NONE / DOWN / UP
rounding_increment: 100
rounding_adjustment
grand_total_after_rounding
rounding_selected_by
```

Aturan:

- Rounding diterapkan pada grand total penjualan setelah perhitungan line, diskon, dan komponen nilai lain; bukan pada quantity inventory.
- Kelipatan rounding tetap Rp100 pada scope awal.
- Rounding bersifat opsional per transaksi dan tersedia untuk semua metode pembayaran.
- Cashier dapat memilih **Tanpa Pembulatan**, **Bulatkan ke Bawah**, atau **Bulatkan ke Atas**.
- Jika tidak dipakai, `rounding_direction = NONE`, adjustment `0`, dan total akhir sama dengan total awal.
- DOWN mengambil kelipatan Rp100 terdekat di bawah total; UP mengambil kelipatan Rp100 terdekat di atas total.
- Jika total sudah kelipatan Rp100, rounding adjustment tetap `0`.
- Tidak diperlukan policy paksa per store pada scope awal.
- POS menampilkan total sebelum rounding, selisih rounding, dan total sesudah rounding sebelum pembayaran dikonfirmasi.
- Stock movement dan HPP tetap menggunakan quantity transaksi asli yang valid sesuai precision UOM.
- Sales header/payment menyimpan seluruh field rounding sebagai snapshot audit.
- Jumlah seluruh settlement/tender wajib sama dengan `grand_total_after_rounding` atau total awal ketika rounding tidak dipakai. Tender mencakup payment uang serta instrumen non-cash seperti `CUSTOMER_BALANCE` dan `KETUL_OFFSET`; offset tidak mengurangi revenue invoice.
- Laporan Store Manager menampilkan arah dan nilai rounding per transaksi serta total akumulasi rounding DOWN, UP, dan net difference.
- Struk menampilkan **Total Sebelum Pembulatan**, **Pembulatan**, dan **Total Akhir** ketika rounding dipakai.
- COA/perlakuan Finance untuk selisih rounding ditentukan pada fase Finance.

### 8.1.5 Sales Refund dan Rounding

- Approval refund dikontrol konfigurasi `refund_approval_mode` per company dengan optional store override:
  - `REQUIRED`: Cashier membuat draft dan Store Manager atau Company Admin/Super Admin harus mengotorisasi/posting.
  - `OPTIONAL`: Cashier dapat mem-posting langsung; semua actor/waktu tetap diaudit dan Store Manager melihatnya pada laporan.
- Company Owner/Admin mengatur default company. Store Manager dapat membuat override hanya untuk store dalam scope penugasannya; store override menang terhadap company default.
- Pada mode `REQUIRED`, Cashier hanya membuat refund `DRAFT`. Store Manager atau Company Admin/Super Admin memeriksa dan mem-posting refund dari Backoffice; approval melalui POS tidak menjadi kebutuhan scope awal.
- Refund penuh mengembalikan persis `grand_total_after_rounding` yang benar-benar dibayar pada transaksi asal dan membalik rounding adjustment asal.
- Refund penuh tidak melakukan pilihan rounding baru.
- Refund sebagian menghitung nilai dari line, quantity, harga, dan alokasi diskon snapshot transaksi asal.
- Total refund sebagian boleh menggunakan rounding Rp100 terpisah dengan pilihan `NONE`, `DOWN`, atau `UP`.
- Dokumen refund sebagian menyimpan total sebelum/sesudah rounding, adjustment, direction, actor, invoice/sesi asal, dan sesi eksekusi.
- Akumulasi refund tidak boleh melebihi sisa nilai yang masih dapat dikembalikan dari transaksi asal.
- Pengembalian stok/HPP mengikuti quantity dan costing transaksi asal; rounding refund hanya memengaruhi nilai refund/payment.
- Laporan Store Manager membedakan rounding penjualan dan rounding refund.
- Metode refund fleksibel: `CASH` atau `TRANSFER`, tidak wajib sama dengan metode pembayaran asal.
- Refund menyimpan original payment method dan refund method agar perbedaannya dapat diaudit.
- Refund transfer menyimpan informasi rekening/tujuan dan nomor referensi transfer yang tersedia. Bukti transfer bersifat opsional pada scope awal.
- Kondisi pengembalian ditentukan per line:
  - `SALEABLE`: quantity masuk kembali ke gudang `STORE` asal.
  - `DAMAGED`: quantity masuk ke gudang `DAMAGED` terkait.
  - `NO_PHYSICAL_RETURN`: refund nilai tanpa penambahan stock.
- Stock movement/HPP reversal hanya mengikuti barang fisik yang benar-benar kembali; `NO_PHYSICAL_RETURN` tidak membuat stock-in atau reversal HPP dan hanya memakai Credit Note/refund Finance.

Kolom laporan rounding minimum:

```text
transaction_at
invoice_or_refund_no
cashier
payment_method
document_type: SALE / REFUND
total_before_rounding
rounding_direction
rounding_adjustment
total_after_rounding
```

### 8.1.6 Sesi Kasir, Export Excel, dan Setor Kas

- Cashier mengisi saldo awal kas secara manual setiap membuka sesi.
- Satu Cashier hanya boleh memiliki satu sesi `OPEN` dalam satu waktu.
- Saat tutup sesi, sistem menampilkan expected cash, actual cash yang diinput, dan selisih secara langsung kepada Cashier.
- Jika Cashier menambah uang untuk menutup kekurangan, penambahan tersebut dicatat sebagai cash-in/settlement terpisah agar selisih awal tetap dapat diaudit.
- Transfer, QR, Card, dan metode non-cash lain diringkas otomatis dari transaksi posted; Cashier hanya menghitung kas fisik.
- Cashier dapat mengunduh workbook Excel flow keuangan untuk sesi miliknya sendiri tanpa HPP, cost batch, atau COA internal.
- Menu Setor Kas dapat memilih beberapa sesi `CLOSED` dalam company/store yang sama.
- Nilai wajib setor per sesi berasal dari actual closing cash dikurangi saldo modal sesi berikutnya yang diinput saat membuat Setor Kas.
- Header setoran membandingkan total expected seluruh sesi terpilih dengan total aktual yang diinput Cashier.
- Setoran aktual boleh kurang/lebih. Setelah Finance atau Company Admin/Super Admin approve, seluruh sesi terpilih dianggap selesai dan selisih menjadi exception Finance, bukan partial deposit.
- Finance menjadi approver operasional; Company Admin/Super Admin mewarisi kewenangan approval. Jurnal baru dibuat setelah approval berdasarkan nominal aktual. Bukti mengikuti konfigurasi REQUIRED/OPTIONAL per company/store.

### 8.2 Stock Movement / Kartu Stok

Movement adalah ledger fisik inventory dan harus append-only setelah posted.

Stock Movement bersifat read-only di UI. User tidak dapat membuat, mengedit, atau menghapus movement secara manual.

Field/tampilan minimum:

```text
tanggal dan waktu
company
gudang
produk
base UOM
quantity in
quantity out
saldo setelah movement
movement type
nomor dokumen sumber
reference table/type
reference id
actor
status
notes
```

Movement type minimum yang sudah dikenal:

```text
SALE
PURCHASE
ADJUSTMENT
TRANSFER_IN
TRANSFER_OUT
```

Tambahan yang diusulkan:

```text
OPENING_BALANCE
SALES_RETURN
PURCHASE_RETURN
OPNAME_GAIN
OPNAME_LOSS
REVERSAL
```

Movement type final harus diputuskan sebelum migration.

Setiap movement hanya boleh dibuat oleh dokumen/proses sumber yang valid:

```text
OPENING_BALANCE
SALE
PURCHASE
TRANSFER_IN / TRANSFER_OUT
ADJUSTMENT
OPNAME_GAIN / OPNAME_LOSS
SALES_RETURN / PURCHASE_RETURN
REVERSAL
```

Movement tanpa source document/reference ditolak, kecuali data migrasi legacy yang ditandai khusus dan diaudit.

### 8.3 Sumber kebenaran stok

Target prinsip:

- `stock_movements` adalah ledger/audit perubahan stok.
- `product_stocks` adalah saldo cepat/materialized balance untuk operasional.
- Setiap update `product_stocks` wajib terjadi dalam transaksi database yang sama dengan insert movement.
- Sistem menyediakan audit untuk membandingkan saldo `product_stocks` dengan agregasi movement.
- Selisih audit tidak diperbaiki dengan edit langsung; gunakan repair procedure yang tercatat.

---

## 9. Dokumen Inventory

### 9.1 Adjustment Stock

Adjustment dipakai untuk koreksi terkontrol di luar transaksi normal.

Flow yang disepakati:

```text
DRAFT -> POSTED
      -> CANCELED
```

Tidak ada approval/maker-checker terpisah. Store Manager/SPV Toko dapat membuat dan mem-posting Adjustment untuk gudang store dalam scope penugasannya. Company Admin/Super Admin dapat melakukan tindakan yang sama dalam company scope. Warehouse Admin tidak dapat mem-posting Adjustment.

Draft tidak mengubah stok. Hanya status `POSTED` yang membuat movement dan memperbarui saldo.

Header minimum:

```text
adjustment_no
company
warehouse
adjustment_date
reason
notes
status
created_by
posted_by/at
canceled_by/at nullable
```

Detail minimum:

```text
product
system_qty_snapshot
final_physical_qty
calculated_difference
base_uom
cogs_snapshot
adjustment_reason_id
notes
```

User mengisi **stok akhir/fisik**, bukan angka plus/minus. Sistem menghitung:

```text
calculated_difference = final_physical_qty - system_qty_snapshot
```

Contoh:

```text
Stok sistem       : 100 PCS
Stok akhir/fisik  : 95 PCS
Selisih otomatis  : -5 PCS
Movement          : ADJUSTMENT -5 PCS
```

Adjustment dapat dibuat:

- langsung dari menu Adjustment; atau
- melalui tombol **Buat Adjustment** pada Report Stock Opname agar nilai fisik hasil opname terisi otomatis.

Aturan selisih:

- Selisih negatif diklasifikasikan sebagai `STOCK_LOSS`/kerugian persediaan.
- Selisih positif diklasifikasikan sebagai `STOCK_GAIN`/selisih stok lebih atau pendapatan lain-lain, bukan pendapatan penjualan.
- Implementasi jurnal belum dilakukan pada fase Produk & Stok; mapping Stock Gain/Loss sudah disetujui pada dokumen Finance dan account ID tetap configurable per company.
- Final stock default tidak boleh negatif. User membuka scope STK-006 pada
  2026-08-05 untuk exception POS yang berizin; sampai policy, permission,
  provisional costing, replenishment reconciliation, audit, dan regression
  khusus lulus, seluruh runtime existing tetap menolak stock negatif.

Adjustment posted tidak dapat diedit/dihapus. Koreksi atas adjustment posted menggunakan reversal atau adjustment baru yang memiliki reference ke dokumen sebelumnya.

### 9.2 Stock Opname

Stock Opname dilakukan per satu gudang. Mode penghitungan tersedia pada aplikasi POS agar kasir dapat membuat sesi baru dan menginput hasil fisik di lokasi. Store Manager atau Company Admin/Super Admin melakukan perbandingan dan posting melalui Backoffice; Finance dapat memantau hasil tanpa menjadi approval wajib.

Flow status:

```text
DRAFT -> COUNTING -> COMPLETED -> POSTED
                         |       -> CANCELED
                         -> RECOUNT_REQUIRED (per line)
```

Prinsip:

- Opname berlaku untuk satu company dan satu gudang.
- Scope penghitungan fleksibel melalui filter: semua produk, kategori tertentu, atau produk terpilih.
- Sistem menyimpan snapshot saldo dan movement watermark pada waktu mulai.
- Kasir dapat membuat sesi Stock Opname baru langsung dari POS tanpa menunggu assignment dari Backoffice.
- Stock Opname dapat dilakukan setiap hari atau sesuai kebijakan operasional company/store.
- Kasir mengisi physical quantity melalui mode Stock Opname di POS.
- POS menggunakan blind count: kasir tidak melihat system quantity, expected quantity, difference, atau nilai rupiah saat menghitung.
- Kasir dapat mengedit hitungan selama sesi berstatus `DRAFT` atau `COUNTING`.
- Setelah kasir menekan **Selesaikan Penghitungan**, sesi menjadi `COMPLETED` dan angka hitung terkunci.
- Setiap line menyimpan `count_started_at`, `counted_at`, kasir penghitung, dan movement watermark.
- Difference dihitung sistem, bukan diketik manual.
- Store Manager melihat perbandingan system quantity dengan physical quantity dan memeriksa hasil dari Backoffice.
- Finance memiliki akses lihat/review opsional, tetapi tidak wajib memberi approval sebelum posting.
- Store Manager tidak dapat mengedit physical quantity yang diinput kasir.
- Jika hasil diragukan, Store Manager menggunakan aksi **Minta Hitung Ulang** dan kasir menginput hasil baru melalui POS.
- Saat dokumen diposting, sistem membuat Adjustment untuk seluruh line yang memiliki selisih.
- Store Manager mengeksekusi posting/Adjustment hasil opname sesuai assignment; Company Admin/Super Admin dapat mengeksekusi tindakan yang sama dalam company scope.
- Dokumen posted tidak dapat diedit.

### 9.2.1 Model non-blocking yang diusulkan

Gudang tidak dibekukan penuh selama Stock Opname karena aktivitas POS harus tetap berjalan dan review/posting dapat dilakukan beberapa hari kemudian.

Model target:

```text
1. Opname dimulai dan mengambil snapshot saldo/movement watermark
2. POS tetap dapat menjual
3. Kasir menghitung produk dan menyimpan waktu hitung setiap line
4. Sistem menghitung expected quantity pada waktu line dihitung
5. Store Manager atau Company Admin/Super Admin mereview selisih di Backoffice; Finance dapat memantau
6. Saat posting, sistem lock saldo terkini dan menerapkan variance yang disetujui
7. Adjustment dan movement dibuat atomic
```

Formula per line:

```text
expected_qty_at_count
= system_qty_at_opname_start
+ movement dari opname_start sampai counted_at

variance_at_count
= physical_qty - expected_qty_at_count

final_qty_at_post
= current_qty_at_post + approved_variance_at_count
```

Contoh:

```text
Snapshot awal              : 100 PCS
Penjualan sebelum dihitung : -10 PCS
Expected saat dihitung     : 90 PCS
Hasil fisik kasir          : 88 PCS
Variance opname            : -2 PCS

Penjualan setelah dihitung : -20 PCS
Saldo saat posting         : 70 PCS
Adjustment yang diterapkan : -2 PCS
Saldo akhir setelah post   : 68 PCS
```

Deteksi transaksi saat penghitungan:

- Jika ada movement antara `count_started_at` dan `counted_at`, line ditandai `RECOUNT_REQUIRED`.
- Line `RECOUNT_REQUIRED` tidak boleh diposting sebelum dihitung ulang.
- Sistem tidak menghentikan seluruh transaksi POS; hanya meminta recount pada produk yang hasilnya berpotensi tercampur transaksi.
- Posting wajib mengunci saldo produk terkait untuk mencegah race condition saat Adjustment dibuat.

Status model non-blocking ini: **APPROVED.**

### 9.2.2 Blind count di POS

Kasir hanya melihat informasi yang diperlukan untuk menghitung:

```text
SKU
Nama produk
UOM hitung
kolom physical quantity
catatan opsional
```

Kasir tidak melihat:

```text
system quantity
expected quantity
difference
HPP
nilai selisih
hasil hitung sesi sebelumnya
```

Perbandingan tersebut hanya tersedia di Backoffice untuk Store Manager dan role yang berhak melihat laporan, termasuk Finance.

### 9.2.3 Beberapa sesi dan supersede hasil lama

Kasir dapat membuat beberapa sesi Stock Opname. Untuk mencegah double adjustment pada produk yang sama:

- Jika produk dan gudang yang sama dihitung lagi sebelum hasil lama diposting, line hitungan terbaru menjadi hasil aktif.
- Line lama yang overlap ditandai `SUPERSEDED` dan tidak dapat diposting.
- Supersede berlaku per line produk, bukan otomatis membatalkan seluruh sesi lama.
- Line lain pada sesi lama yang tidak overlap tetap dapat direview/diposting.
- Hasil yang sudah `POSTED` tidak dapat disupersede; sesi berikutnya menjadi penghitungan baru atas saldo setelah posting sebelumnya.
- Sistem menyimpan reference dari line lama ke line pengganti untuk audit.

Contoh:

```text
Sesi Senin
- Saus ABC = 90  -> SUPERSEDED
- Kecap XYZ = 40 -> tetap aktif

Sesi Selasa
- Saus ABC = 88  -> hasil aktif terbaru
```

Status line minimum:

```text
PENDING
COUNTED
RECOUNT_REQUIRED
SUPERSEDED
POSTED
```

### 9.3 Report Stock Opname

Report minimum:

```text
nomor opname
tanggal/cutoff
gudang
status
SKU dan nama produk
system quantity
physical quantity
difference quantity
HPP snapshot
nilai selisih
alasan/catatan
counter
reviewed_by_store_manager / reviewed_at
finance_viewed_by / viewed_at nullable
recount_status
counted_at
posted movement reference
```

Filter minimum:

```text
company
gudang
periode
status
kategori
produk
selisih saja
recount required
belum direview Store Manager
```

Export spreadsheet/PDF ditunda sampai format laporan disepakati.

### 9.4 Konfirmasi Order

Konfirmasi Order bukan sekadar konfirmasi Purchase Order existing. Flow bisnis target dimulai dari kebutuhan barang yang diminta melalui POS.

### 9.4.1 Flow end-to-end

```text
Sales/POS membuat Stock Request
-> Store Manager review kebutuhan
-> Store Manager membuat/konfirmasi Supplier Order
-> Supplier mengirim barang, dapat bertahap/partial
-> Kasir menerima dan menghitung barang melalui POS
-> Receipt posted menambah stok dan membuat AP provisional
-> Finance melihat tagihan sistem
-> Finance mencocokkan dengan invoice fisik supplier
-> Finance menginput harga/nilai aktual dan melakukan adjustment invoice
-> AP final dibayar
```

Istilah `Sales/POS` menggunakan user Cashier existing. Tidak dibuat role Sales baru pada scope ini.

### 9.4.2 Dokumen dan status

#### A. Stock Request dari POS

```text
DRAFT
SUBMITTED
ORDERED
PARTIALLY_RECEIVED
RECEIVED
CLOSED
CANCELED
```

Field minimum:

```text
request_no
company_id
store_id
requesting_pos_id
requested_by
requested_at
needed_date nullable
notes nullable
status
closed_by nullable
closed_at nullable
```

Line minimum:

```text
product_id
requested_uom_id
requested_qty
requested_base_qty
ordered_base_qty calculated
remaining_request_base_qty calculated
notes nullable
```

Stock Request belum mengubah stok dan belum membuat pencatatan keuangan.

Aturan penutupan:

- Request dapat terhubung ke satu atau beberapa Supplier Order.
- Jika hanya sebagian quantity yang dipesan, sisa request tetap terbuka.
- Store Manager dapat menutup sisa request secara manual tanpa alasan wajib.
- Penutupan menyimpan `closed_by` dan `closed_at` sebagai audit trail.
- Menutup Stock Request tidak membatalkan Supplier Order, Goods Receipt, atau transaksi lain yang sudah terbentuk.
- Status `CLOSED` berarti tidak ada order tambahan yang akan dibuat dari sisa request tersebut; histori requested, ordered, dan received quantity tetap terlihat.

#### B. Supplier Order oleh Store Manager

```text
DRAFT
CONFIRMED
PARTIALLY_RECEIVED
RECEIVED
CANCELED
```

Field minimum:

```text
order_no
source_request_id
company_id
store_id
destination_warehouse_id
supplier_id
order_date
expected_date nullable
ordered_by
status
notes nullable
```

Line minimum:

```text
product_id
ordered_uom_id
ordered_qty
ordered_base_qty
estimated_unit_price
estimated_subtotal
```

Harga pada Supplier Order adalah harga estimasi/referensi dan dapat berbeda dari invoice fisik supplier.

Aturan grouping dan quantity:

- Satu Stock Request dapat dipecah menjadi beberapa Supplier Order.
- Store Manager atau Company Admin/Super Admin memilih supplier untuk setiap line request.
- Cashier tidak memilih supplier pada Stock Request; request hanya berisi produk, UOM, quantity, dan catatan.
- Backoffice menampilkan supplier utama/default serta supplier aktif lain dari relasi Produk-Supplier sebagai pilihan Store Manager.
- Jika supplier aktif belum memiliki relasi dengan produk, Store Manager tetap boleh memilihnya. Sebelum konfirmasi order, sistem menawarkan **Simpan sebagai Supplier Produk**.
- Jika opsi disetujui, sistem membuat relasi Produk-Supplier menggunakan supplier, UOM pembelian, dan harga referensi order. `last_purchase_price` tetap kosong sampai invoice divalidasi Finance.
- Pembuatan relasi dari order wajib eksplisit dan tercatat; sistem tidak membuat master relasi secara diam-diam.
- Sistem dapat mengelompokkan line menjadi satu Supplier Order per supplier untuk company/store/gudang tujuan yang sama.
- Store Manager atau Company Admin/Super Admin menentukan quantity final yang benar-benar diorder ke supplier.
- Quantity order boleh berbeda dari requested quantity dan tidak membutuhkan alasan wajib.
- Requested quantity tetap disimpan sebagai snapshot agar kebutuhan awal dapat dibandingkan dengan ordered quantity.
- UOM pembelian dan harga terakhir dari relasi Produk-Supplier menjadi default line order, tetapi Store Manager dapat mengubah keduanya menggunakan UOM produk yang valid.
- Harga yang dikonfirmasi disimpan sebagai snapshot Supplier Order dan menjadi cost provisional pada Goods Receipt.
- Sisa request yang tidak diorder tetap terlihat sebagai unfulfilled/canceled quantity sesuai keputusan Store Manager.

#### C. Goods Receipt oleh Kasir di POS

Partial receipt wajib didukung. Satu Supplier Order dapat memiliki beberapa receipt.

```text
DRAFT
POSTED
CANCELED
```

Field minimum:

```text
receipt_no
supplier_order_id
company_id
store_id
warehouse_id
received_by
received_at
supplier_delivery_no nullable
notes nullable
status
```

Line minimum:

```text
supplier_order_line_id
product_id
received_uom_id
received_qty
received_base_qty
accepted_good_qty nullable
damaged_qty nullable
rejected_qty nullable
accepted_base_qty
estimated_unit_price_snapshot
is_over_received
over_received_base_qty
```

Saat receipt diposting:

1. Validasi company, store, supplier order, gudang, produk, dan UOM.
2. Bandingkan quantity dengan sisa order dan hitung over-received quantity bila ada.
3. Konversi quantity diterima ke base UOM terkecil.
4. Tambah stock balance hanya untuk quantity yang diterima/accepted.
5. Buat FIFO batch menggunakan harga estimasi snapshot sampai Finance menginput nilai aktual.
6. Buat stock movement `PURCHASE_RECEIPT`/`PURCHASE`.
7. Perbarui received quantity dan status order menjadi `PARTIALLY_RECEIVED` atau `RECEIVED`.
8. Buat sumber AP provisional berdasarkan quantity diterima dan harga estimasi.
9. Cegah double posting menggunakan idempotency key dan status lock.

Over-receipt diperbolehkan:

- Quantity aktual tetap dapat diinput dan diposting oleh kasir.
- Accepted over-receipt tetap menambah stok.
- AP provisional menggunakan quantity aktual yang diterima/accepted, termasuk kelebihan.
- Receipt/line diberi flag `OVER_RECEIVED` dan menyimpan selisih terhadap sisa order.
- Finance melihat flag tersebut saat mencocokkan Supplier Order, surat jalan/Goods Receipt, dan invoice fisik.
- Over-receipt tidak membutuhkan approval Store Manager sebelum stok masuk pada flow saat ini.

Pencatatan kondisi barang dibuat opsional agar form penerimaan utama tetap sederhana:

- Secara default kasir cukup mengisi UOM dan quantity diterima; seluruh quantity dianggap diterima baik.
- Aksi opsional **Ada barang rusak/ditolak** membuka field `accepted_good_qty`, `damaged_qty`, dan `rejected_qty`.
- Quantity rusak yang tetap diterima masuk ke gudang bertipe `DAMAGED` dan ikut membentuk stok/AP provisional.
- Quantity ditolak tidak masuk stok dan tidak membentuk AP provisional.
- Total quantity baik, rusak, dan ditolak harus sama dengan quantity aktual yang dicatat dari surat jalan.
- Barang yang sudah diterima, termasuk yang masuk gudang `DAMAGED`, dikembalikan menggunakan Purchase Return terpisah.

### 9.4.3 AP provisional dan invoice fisik

Kebutuhan bisnis:

- Setelah receipt diposting, sistem mengakui tagihan sementara/AP provisional sebelum dibayar.
- Nilai provisional menggunakan accepted quantity dikali harga estimasi Supplier Order.
- Finance melihat daftar receipt/tagihan yang belum dicocokkan.
- Finance melakukan three-way reconciliation antara Supplier Order, surat jalan/Goods Receipt, dan invoice fisik supplier sesuai `docs/PURCHASE_MATCHING_TOLERANCE_SPEC.md`.
- Matching invoice bersifat fleksibel/many-to-many: satu invoice dapat mencakup beberapa Supplier Order dan Goods Receipt, dan satu order/receipt dapat dialokasikan ke beberapa invoice bila penagihan dilakukan bertahap.
- Seluruh dokumen dalam satu matching wajib berasal dari company dan supplier yang sama; sistem menyimpan allocation per line agar quantity/nilai tidak dihitung dua kali.
- Finance menginput harga aktual, pajak, diskon, ongkir, atau nilai lain yang nanti disepakati.
- Selisih harga estimasi dan aktual menghasilkan adjustment valuation/accounting yang dapat diaudit.
- Setelah invoice divalidasi, AP provisional berubah menjadi AP final.
- Pembayaran mengurangi AP final sesuai nilai dan metode pembayaran aktual.
- Over-receipt, short receipt, damaged quantity, dan Purchase Return wajib terlihat pada layar reconciliation.

Konsep jurnal awal dicatat pada `docs/FINANCE_INTEGRATION_NOTES.md`. Schema Finance, invoice matching, price variance, pajak, dan payment belum diimplementasikan pada fase Produk & Stok.

### 9.4.4 Role awal

| Tahap | Role utama | Channel |
|---|---|---|
| Buat Stock Request | Cashier existing | POS |
| Review dan order ke supplier | Store Manager | Backoffice |
| Terima barang supplier | Kasir pada store/POS tujuan | POS |
| Pantau receipt/tagihan | Finance | Backoffice |
| Match invoice fisik dan input nilai aktual | Finance | Backoffice |
| Bayar AP | Finance sesuai approval yang nanti ditentukan | Backoffice |

RLS wajib memastikan seluruh dokumen, supplier, gudang, dan user berasal dari company/store yang sama.

### 9.4.5 Purchase Return / Retur ke Supplier

Purchase Return adalah dokumen terpisah untuk barang yang sudah diterima/masuk stok lalu dikembalikan ke supplier.

Flow awal:

```text
DRAFT
POSTED
CANCELED
```

Field minimum header:

```text
return_no
company_id
store_id
warehouse_id
supplier_id
source_receipt_id
source_supplier_order_id
return_date
returned_by
return_reason
supplier_return_document_no nullable
handed_over_at nullable
status
notes nullable
```

Field minimum line:

```text
source_receipt_line_id
product_id
return_uom_id
return_qty
return_base_qty
unit_cost_snapshot
```

Aturan:

- Return quantity tidak boleh melebihi net accepted quantity dikurangi return sebelumnya.
- Produk return wajib berasal dari `source_receipt_line_id`. Produk bebas yang tidak terdapat pada Goods Receipt asal tidak dapat ditambahkan.
- Alasan return menggunakan satu field yang dapat memilih nilai saran umum atau menerima teks bebas. Alasan wajib terisi, tetapi tidak menggunakan daftar master yang panjang.
- Partial return didukung.
- UOM retur dapat memakai UOM Produk aktif mana pun dan tidak harus sama dengan
  UOM pembelian/Receipt. Contoh: Receipt `1 Dus = 10 Ketul` dapat diretur
  `3 Ketul`. Server mengonversi quantity langsung ke base UOM menggunakan
  conversion snapshot dan tetap menegakkan precision serta batas FIFO sumber.
- Return posted mengurangi stok gudang sumber dan membuat movement `PURCHASE_RETURN`.
- Jika barang berada di gudang `DAMAGED`, return mengurangi gudang tersebut.
- Jika invoice belum final, return posted langsung mengurangi AP provisional.
- Jika invoice sudah final atau sudah dibayar, jurnal/invoice lama tidak diubah. Finance mencatat supplier credit note, refund, receivable, atau offset AP berikutnya dengan referensi ke Purchase Return.
- Debit/Credit Note hanya mengoreksi nilai dan tidak membuat stock movement; source, allocation, pajak, dan approval mengikuti `docs/DEBIT_CREDIT_NOTE_SPEC.md`.
- Jika nilai Purchase Return melebihi AP Supplier yang masih terbuka, selisih menjadi Piutang Refund Supplier dan dapat diselesaikan melalui Transfer supplier atau offset invoice berikutnya.
- Koreksi harga invoice aktual dialokasikan ke remaining FIFO Inventory dan HPP variance untuk quantity yang sudah terjual; jurnal sale historis tidak diubah.
- Return tidak menghapus Goods Receipt asli.
- Return posted tidak dapat diedit/dihapus; koreksi menggunakan reversal.
- Posting harus idempotent dan atomic antara dokumen return, stock balance, movement, serta sumber adjustment AP.

Cashier dapat membuat draft Purchase Return dari POS. Store Manager atau Company Admin/Super Admin dapat memeriksa dan mem-posting Purchase Return melalui Backoffice ketika barang benar-benar diserahkan kepada supplier. Stok dan AP tidak berubah selama return masih `DRAFT`.

---

## 10. Sistem Import Bergaya Odoo

### 10.1 Prinsip import

Import adalah alat bulk CRUD yang terkontrol, bukan jalan pintas untuk melewati master data dan dokumen inventory.

Format minimum yang wajib didukung adalah CSV. Dukungan XLSX/Excel boleh ditambahkan bila implementasinya tidak menambah risiko/kompleksitas besar, tetapi XLSX bukan blocker fase pertama.

### 10.1.1 Menu Import & Export

Master Data memiliki satu area **Import & Export** dengan pilihan jenis data:

```text
Kategori Produk
Brand/Merek
UOM
Gudang
Supplier
Produk
Relasi Produk-Supplier
Minimum Stock Produk-Gudang
Opening Stock
```

Export selalu tenant scoped berdasarkan company aktif dan mengikuti hak akses user.

Export master minimum memuat:

```text
internal_id
code
name
status
field relevan lain
```

Tujuan export:

- menjadi daftar referensi master yang valid;
- membantu user menyiapkan file import berikutnya;
- memungkinkan user menggunakan ID atau nama master existing;
- menjadi template edit massal yang dapat di-import kembali;
- tidak otomatis menjadi backup database penuh.

### 10.2 Jenis import harus dipisah

```text
Import Master Produk
Import Master Kategori
Import Master Brand
Import Master UOM
Import Konversi UOM Produk
Import Master Gudang
Import Master Supplier
Import Relasi Produk-Supplier
Import Minimum Stock Produk-Gudang
Import Opening Balance/Stok Awal
```

Satu file tidak boleh sekaligus membuat semua master dan mem-posting stok, kecuali ada mode onboarding khusus yang memiliki urutan validasi dan approval eksplisit.

Urutan kerja bisnis yang disepakati:

```text
1. Buat atau import Master Kategori
2. Buat atau import Master Brand bila digunakan
3. Buat atau import Master UOM
4. Buat atau import Master Gudang
5. Buat atau import Master Supplier
6. Export master referensi tersebut
7. Isi file Import Produk menggunakan ID atau nama dari hasil export
8. Validasi dan preview Import Produk
9. Konfirmasi Import Produk
10. Buat/import relasi Produk-Supplier bila diperlukan
11. Import Opening Stock/minimum stock secara terpisah
```

Import Produk tidak boleh membuat Kategori, UOM, atau Gudang baru secara otomatis.

### 10.3 Alur import

```text
1. Pilih jenis import
2. Unduh template
3. Upload CSV/XLSX
4. Pilih delimiter/sheet bila diperlukan
5. Pilih mode referensi: ID atau Nama
6. Mapping kolom file ke field sistem
7. Normalisasi nilai
8. Validasi seluruh baris
9. Preview hasil
10. Pilih create/update policy
11. Konfirmasi perubahan
12. Commit baris valid
13. Tampilkan hasil dan error report
14. Simpan import history/audit
```

### 10.4 Status import job

```text
UPLOADED
MAPPED
VALIDATED
READY
PROCESSING
COMPLETED
COMPLETED_WITH_ERRORS
FAILED
CANCELED
```

### 10.5 Preview wajib

Preview menunjukkan per baris:

```text
row number
operation: CREATE / UPDATE / SKIP / ERROR
matched record
normalized values
warning
error
field yang berubah
nilai lama
nilai baru
```

Preview wajib menampilkan ringkasan:

```text
jumlah CREATE
jumlah UPDATE
jumlah SKIP
jumlah ERROR
```

Setiap row `UPDATE` diberi warning bahwa import akan mengubah data existing. User harus menekan **Konfirmasi Import** sebelum perubahan dijalankan.

### 10.6 Kebijakan referensi master

Default aman:

- Kategori tidak ditemukan -> error.
- UOM tidak ditemukan -> error.
- Brand yang diisi tetapi tidak ditemukan -> error.
- Gudang tidak ditemukan -> error.
- Produk atau Supplier pada import relasi tidak ditemukan -> error.
- COA tidak ditemukan -> error atau warning sesuai mode.
- Master nonaktif -> error.
- Tidak ada silent create.

Mode “buat master yang belum ada” hanya boleh ditambahkan bila user secara eksplisit mengaktifkannya dan melihat preview master yang akan dibuat.

Untuk flow yang sudah disepakati, Import Produk tidak menyediakan mode tersebut. Referensi wajib sudah tersedia lebih dahulu.

### 10.6.1 Referensi menggunakan ID atau Nama

Pada satu import job, user memilih tepat satu mode:

```text
REFERENCE_BY_ID
atau
REFERENCE_BY_NAME
```

File tidak boleh mencampur ID dan nama sebagai key referensi dalam satu job.

Contoh mode ID:

```text
category_id
brand_id
base_uom_id
warehouse_id
product_id
supplier_id
```

Contoh mode Nama:

```text
category_name
brand_name
base_uom_name
warehouse_name
product_name
supplier_name
```

Aturan resolusi:

- ID harus ditemukan dalam company aktif.
- Nama dinormalisasi terhadap kapitalisasi dan spasi, lalu harus cocok tepat satu master aktif dalam company aktif.
- Jika nama tidak ditemukan, row error.
- Jika nama cocok lebih dari satu record, row error `AMBIGUOUS_REFERENCE`; sistem tidak memilih secara acak.
- Master nonaktif tidak boleh digunakan untuk import produk baru.
- ID dari company lain harus ditolak walaupun ID valid.

Karena nama dapat digunakan sebagai referensi/update key, nama Kategori, UOM, dan Gudang harus dijaga tidak ambigu dalam company yang sama. Validator wajib mendeteksi duplikasi sebelum commit.

### 10.7 Duplicate dan matching

SKU tetap wajib dan unik per company. Untuk mendeteksi record existing pada import, user dapat memilih ID atau nama sesuai mode import:

```text
REFERENCE_BY_ID   -> company_id + product_id
REFERENCE_BY_NAME -> company_id + normalized product_name
```

Setelah matched, SKU pada row tetap divalidasi agar tidak konflik dengan produk lain.

Kebijakan yang harus tersedia:

```text
Create only
Update existing only
Create and update
```

Jika ID atau nama yang dipilih cocok dengan record existing:

- mode `Create only` -> row ditandai `ERROR/EXISTS` atau `SKIP` sesuai pilihan user;
- mode `Update existing only` -> row ditandai `UPDATE`;
- mode `Create and update` -> row ditandai `UPDATE`;
- preview wajib menampilkan field yang akan berubah;
- commit update hanya berjalan setelah user mengonfirmasi warning perubahan data.

Import harus menolak:

- SKU kosong;
- SKU duplikat dalam file;
- SKU conflict lintas record dalam company;
- angka tidak valid;
- harga/berat/faktor negatif;
- UOM/gudang/kategori tidak valid;
- perubahan base UOM pada produk yang sudah punya movement tanpa prosedur khusus.

### 10.7.1 Format baris produk dan UOM

Import Produk menggunakan format long/berulang seperti pola import Odoo. Satu produk dapat memiliki beberapa row, masing-masing untuk satu UOM.

Contoh:

```text
sku      | product_name | category_name | uom_name | factor_to_base | is_base | is_largest | buy_price | sale_price | weight_kg
SAUS-ABC | Saus ABC     | Saus          | PACK     | 1              | TRUE    | FALSE      | 5000      | 7000       |
SAUS-ABC | Saus ABC     | Saus          | DUS      | 12             | FALSE   | TRUE       | 55000     | 80000      | 6
```

Aturan grouping:

- Seluruh row dengan SKU/product key yang sama dianggap satu logical product group.
- Field header produk seperti nama, kategori, dan tipe wajib konsisten pada seluruh row dalam group.
- Tepat satu UOM ditandai sebagai base/terkecil.
- Tepat satu UOM ditandai sebagai UOM terbesar/acuan berat.
- Kombinasi produk dan UOM tidak boleh duplikat dalam file.
- Seluruh group produk diproses atomic: produk beserta semua UOM berhasil bersama atau gagal bersama.
- Error pada satu group tidak membatalkan group produk valid lain.

### 10.7.2 Field update yang dilindungi

Setelah produk memiliki stock movement atau transaksi, import tidak boleh mengubah langsung:

```text
SKU
product_type: STOCK / BUNDLE
base_uom_id
struktur/faktor konversi yang sudah dipakai transaksi
```

Perubahan field struktural tersebut membutuhkan prosedur migrasi/koreksi khusus dengan audit, bukan bulk import biasa.

Field yang boleh diperbarui melalui import setelah preview dan konfirmasi:

```text
product_name
category_id
purchase_price per UOM
sale_price per UOM
weight UOM terbesar
is_active
```

Perubahan kategori tidak mengubah transaksi atau mapping accounting historis.

### 10.7.3 Rename pada mode Nama

- Mode `REFERENCE_BY_NAME` menggunakan nama untuk menemukan record existing.
- Karena nama adalah matching key, nama tidak boleh sekaligus diganti pada job tersebut.
- Rename melalui import wajib menggunakan `REFERENCE_BY_ID`.
- Rename manual melalui form CRUD tetap diperbolehkan sesuai hak akses dan validasi duplikasi.

### 10.8 Import stok awal

Stok awal bukan field pada import master produk. Stok awal harus menjadi dokumen inventory tersendiri:

```text
Opening Balance Batch
├── company
├── warehouse
├── effective date
├── source/import job
├── approval status
└── lines: product, qty base UOM, unit cost
```

Saat posted, sistem membuat:

- movement `OPENING_BALANCE`;
- saldo `product_stocks`;
- batch cost/FIFO awal;
- audit actor dan import job.

Posting ulang job yang sama harus idempotent.

Opening Stock hanya boleh digunakan pada awal penggunaan sistem untuk kombinasi produk dan gudang yang belum pernah memiliki stock movement. Jika movement sudah ada, row Opening Stock ditolak dan perubahan wajib dilakukan melalui Adjustment.

Opening Stock menggunakan master yang sudah tersedia dan memilih tepat satu mode referensi ID atau Nama. Field minimum:

```text
warehouse_id atau warehouse_name
effective_date
product_id atau product_name
base_uom_id atau base_uom_name
opening_quantity_base
unit_cost_base
notes
```

Opening Stock tidak mengubah saldo saat upload atau preview. Saldo baru berubah setelah user menekan konfirmasi/posting.

Tanggal efektif, gudang, produk, quantity dalam base UOM terkecil, HPP per base UOM, dan catatan wajib tersedia pada dokumen yang diposting.

Hak akses dan accounting boundary:

- Store Manager atau Finance dapat menyiapkan Draft/import Opening Stock.
- Company Admin melakukan posting; Super Admin dapat menyiapkan dan mem-posting lintas company sesuai scope.
- Posting membuat movement, stock balance, FIFO layer, serta financial event secara atomic.
- Mapping default Finance adalah Debit Persediaan dan Kredit Opening Balance Clearing; account ID aktual dapat dikonfigurasi Finance per company.
- `unit_cost_base = 0` diperbolehkan dengan warning dan alasan wajib.
- Setelah kombinasi Produk-Gudang memiliki movement pertama, Opening Stock berikutnya ditolak dan koreksi wajib memakai Adjustment.

### 10.9 Error handling

User dapat mengunduh error report yang berisi file asli ditambah:

```text
_row_status
_operation
_error_code
_error_message
```

Commit menggunakan **partial success**:

- record valid dijalankan;
- record error tidak dijalankan;
- setiap record/logical group tetap atomic;
- satu produk beserta daftar UOM, konversi, dan harganya harus berhasil seluruhnya atau gagal seluruhnya;
- kegagalan satu produk tidak membatalkan produk valid lain;
- job berstatus `COMPLETED_WITH_ERRORS` jika terdapat record gagal;
- UI menampilkan notifikasi jumlah berhasil dan gagal;
- error report dapat diunduh dan di-import ulang setelah diperbaiki.

### 10.10 Import history

History minimum:

```text
job id
company
import type
file name
file checksum
uploaded by/at
validated by/at
committed by/at
total rows
created rows
updated rows
skipped rows
error rows
status
result file
```

History juga menyimpan:

```text
reference_mode: ID / NAME
operation_mode: CREATE_ONLY / UPDATE_ONLY / CREATE_AND_UPDATE
confirmed_update_count
file_checksum
```

File import dan error report harus private dan tenant scoped bila disimpan di Supabase Storage.

---

## 11. Hak Akses Awal

`COMPANY_ADMIN` mewarisi seluruh kewenangan Store Manager, Warehouse Admin, Finance/Accounting, dan Cashier dalam company membership-nya. `SUPER_ADMIN` memiliki kewenangan yang sama lintas company. Semua role tetap tunduk pada invariant dokumen final, append-only ledger/movement, serta workflow reversal resmi.

| Fitur | Super Admin | Company Owner/Admin | Warehouse Admin | Store Manager | Cashier |
|---|---:|---:|---:|---:|---:|
| Lihat master company | Semua company | Company sendiri | Company sendiri | Company/store sendiri | Master aktif yang diperlukan POS |
| CRUD Produk/Kategori/UOM | Ya | Ya | Perlu keputusan | Tidak | Tidak |
| CRUD Gudang | Ya | Ya | Ya, gudang dalam scope | Ya, gudang STORE dalam assignment | Tidak |
| Import master | Ya | Ya | Perlu keputusan | Tidak | Tidak |
| Lihat stock real | Semua | Company sendiri | Gudang yang diizinkan | Store/gudang yang diizinkan | Gudang POS aktif |
| Lihat movement | Semua | Company sendiri | Gudang yang diizinkan | Store/gudang yang diizinkan | Terbatas bila diperlukan |
| Lihat adjustment | Semua | Company sendiri | Gudang yang diizinkan | Store/gudang penugasan | Tidak |
| Buat/post adjustment | Ya, company terpilih | Ya, seluruh company | Tidak | Ya, store/gudang penugasan | Tidak |
| Buat sesi/input hitung opname di POS | Tidak | Tidak | Tidak | Boleh mendampingi | Ya, pada store/POS penugasan |
| Review opname di Backoffice | Semua | Company sendiri | Gudang yang diizinkan | Store/gudang penugasan | Tidak |
| Pantau/review Finance | Semua | Company sendiri | Tidak | Tidak | Tidak; role `FINANCE` pada company yang sama dapat melihat tanpa approval wajib |
| Post opname/Adjustment | Ya, company terpilih | Ya, seluruh company | Tidak | Ya, store/gudang penugasan | Tidak |

RLS tetap menjadi enforcement utama. Menyembunyikan menu tidak dianggap sebagai authorization.

---

## 12. Invariant dan Larangan Implementasi

Agent implementasi wajib menjaga aturan berikut:

1. Produk, UOM, kategori, gudang, balance, dan movement tidak boleh lintas company.
2. Gudang dan produk pada satu dokumen harus berasal dari company yang sama.
3. `product_stocks` tidak boleh diedit langsung dari browser.
4. Dokumen draft tidak mengubah stok.
5. Satu source line tidak boleh menghasilkan movement posted lebih dari sekali.
6. Transfer menghasilkan movement OUT dan IN dengan satu transfer reference.
7. Adjustment/opname posted tidak boleh dihapus.
8. Movement tidak boleh tidak memiliki source/reference, kecuali migration legacy yang ditandai jelas.
9. Base UOM dan conversion snapshot harus tersedia pada transaksi posted.
10. Import tidak boleh membuat master referensi diam-diam.
11. Semua operasi bulk harus tenant scoped dan diaudit.
12. Service role key hanya boleh digunakan di backend.

---

## 13. Tahapan Implementasi Setelah Approval

Tahapan ini masih berupa rencana, bukan instruksi eksekusi.

### Fase 1 — Finalisasi keputusan bisnis

- Finalisasi field tambahan Produk di luar field minimum yang sudah disepakati.
- Finalisasi costing harga beli dan field opsional Produk.
- Finalisasi pembulatan konversi quantity dan berat turunan.
- Finalisasi kategori dan COA.
- Gunakan `docs/FINANCE_INTEGRATION_NOTES.md` sebagai kontrak penundaan agar pekerjaan Finance tidak terlewat.
- Finalisasi definisi Konfirmasi Order.
- Finalisasi detail timeout/retensi sesi Stock Opname yang ditinggalkan dalam status DRAFT/COUNTING.
- Finalisasi kebijakan import error.

### Fase 2 — Audit schema dan migration plan

- Bandingkan schema target dengan database production aktual.
- Tentukan tabel baru versus alter existing.
- Susun additive migration dan backfill.
- Susun rollback dan test SQL.

### Fase 3 — Master Data CRUD

- Kategori Produk.
- Brand/Merek.
- UOM.
- Gudang.
- Supplier dan rekening utama.
- Produk dan konversi UOM.
- Relasi Produk-Supplier.
- Audit dan soft archive.

### Fase 4 — Import staging

- Import job dan row staging.
- Mapping dan validator.
- Preview/dry-run.
- Commit master produk.
- Commit Master Supplier dan relasi Produk-Supplier sesuai jenis job terpisah.
- Error report dan history.

### Fase 5 — Inventory documents

- Stock Real.
- Movement.
- Opening Balance.
- Adjustment.
- Opname dan report.
- Konfirmasi receipt/order.

### Fase 6 — Accounting linkage

- Master COA.
- Mapping kategori produk.
- Event accounting untuk purchase, sale, adjustment, gain/loss, dan return.

---

## 14. Acceptance Criteria Tingkat Sistem

Pekerjaan Produk & Stok belum dianggap selesai sebelum:

- Produk dapat dibuat dan diedit manual tanpa import.
- Master kategori, UOM, konversi, dan gudang tersedia.
- Master Supplier dan relasi Produk-Supplier tersedia untuk Supplier Order.
- Import mempunyai mapping, validation, preview, dan history.
- Import tidak membuat master referensi tanpa persetujuan.
- Opening balance terpisah dari master produk.
- Setiap perubahan stok memiliki movement dan source document.
- Stock Real dapat direkonsiliasi dengan movement.
- Adjustment mempunyai controlled posting oleh Store Manager dan audit trail; Stock Opname memiliki input POS, review Backoffice, posting, dan audit trail.
- Konfirmasi order idempotent dan tidak menggandakan saldo.
- Partial receipt tidak menggandakan received quantity, stock movement, FIFO batch, atau AP provisional.
- Super Admin dapat berpindah company.
- User tenant hanya dapat mengakses company/gudang yang diizinkan.
- Test cross-company dan duplicate posting lulus.
- Dokumentasi status diubah menjadi `VERIFIED` hanya setelah diuji pada jalur aplikasi aktif.

---

## 15. Instruksi untuk AI Agent Berikutnya

Sebelum mengubah code, agent wajib:

1. Membaca dokumen ini sampai selesai.
2. Membaca schema dan migration production yang benar-benar sudah diterapkan.
3. Membedakan fakta repository, fakta database production, asumsi, dan rekomendasi.
4. Tidak menganggap checklist lama sebagai bukti fitur aktif.
5. Tidak mengubah schema sebelum keputusan bisnis pada bagian 16 disetujui.
6. Menjaga kompatibilitas multi-company dan RLS.
7. Membuat patch additive dan migration yang dapat diaudit.
8. Menyediakan test, deployment order, validasi, dan rollback.
9. Tidak membuat UI sebelum kontrak field dan workflow disetujui.
10. Memperbarui dokumen ini bersama setiap keputusan user.

Format update keputusan:

```text
Tanggal:
Bagian:
Keputusan user:
Dampak data:
Dampak workflow:
Status: PROPOSED / APPROVED / IMPLEMENTED / VERIFIED
```

---

## 16. Keputusan Terbuka

### 16.1 Produk — ditanyakan pada sesi berikutnya

Tidak ada keputusan terbuka untuk identitas minimum Produk. Gambar utama tersedia opsional dengan batas free-tier.

### 16.2 UOM dan berat

Tidak ada keputusan terbuka untuk struktur konversi dasar: seluruh UOM dikonversi langsung ke base UOM terkecil.

### 16.3 Kategori dan COA

Tidak ada keputusan taxonomy terbuka. Definisi Transaction Category, permanent system key, required account function, resolver, versioning, serta activation gate berada pada `docs/TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`.

Keputusan yang sudah final:

- Kategori produk satu tingkat/flat.
- Kode kategori diisi manual.
- COA kategori boleh kosong pada fase Produk & Stok.
- Pada fase Finance, mapping COA akan menjadi wajib sesuai kebutuhan posting.
- Aturan/kategori transaksi menentukan pencatatan utama.
- COA kategori produk hanya fallback.
- Company fallback harus eksplisit; jika seluruh level gagal, posting ditahan tanpa partial journal.

### 16.4 Gudang

Tidak ada keputusan terbuka untuk format kode gudang pada scope ini: kode manual menggunakan huruf `A-Z` dengan panjang maksimal 5 karakter.

Keputusan yang sudah final:

- Empat tipe dasar: `CENTRAL`, `STORE`, `DAMAGED`, `TRANSIT`.
- Gudang `STORE` wajib terkait store; gudang `CENTRAL` boleh company-level.
- Gudang `DAMAGED` dan `TRANSIT` boleh company-level atau terkait store.
- Kode gudang diisi manual dan maksimal 5 huruf.
- Gudang cukup memiliki lokasi/alamat; rak/bin tidak diperlukan.
- Company Admin, Warehouse Admin, dan Store Manager/SPV Toko dapat mengatur gudang sesuai scope masing-masing.
- Stok negatif tidak diizinkan.
- Penjualan dengan stok tidak cukup disimpan sebagai draft dan menampilkan notice.

### 16.5 Import

- Berapa lama import history dan file hasil disimpan?

Keputusan yang sudah final:

- CSV wajib; XLSX opsional bila implementasinya mudah dan aman.
- Tersedia menu Import & Export per jenis master.
- User export master referensi sebelum Import Produk.
- Import menggunakan satu mode referensi: ID atau Nama.
- Import Produk tidak membuat Kategori, UOM, atau Gudang otomatis.
- Tidak ada mode onboarding yang membuat master referensi secara diam-diam dari Import Produk.
- Data existing yang matched menjadi `UPDATE` sesuai operation mode dan wajib menampilkan warning.
- Preview menampilkan CREATE, UPDATE, SKIP, ERROR, nilai lama, nilai baru, dan field berubah.
- Commit menggunakan partial success; record valid masuk dan record gagal diberi notifikasi/error report.
- Opening Stock adalah import terpisah dan baru mengubah stok setelah dikonfirmasi.
- Import Produk memakai beberapa row per produk untuk menampung UOM turunannya.
- Seluruh row/UOM satu produk diproses sebagai satu group atomic.
- SKU, tipe produk, base UOM, dan faktor konversi yang sudah dipakai transaksi tidak boleh diubah lewat import biasa.
- Rename lewat import wajib memakai mode ID; mode Nama tidak dapat mengganti matching name.

### 16.6 Stock workflow

- Draft selalu resolve harga/promo terbaru. Jika harga naik, Cashier dapat mempertahankan final price lama melalui diskon manual ter-audit; jika harga turun, harga terbaru yang lebih murah wajib digunakan.

Keputusan yang sudah final:

- Jika satu line kekurangan stok, seluruh order tetap `DRAFT`.
- Draft tidak membuat stock movement, payment final, financial event, atau jurnal.
- Draft belum masuk laporan keuangan.
- Draft tidak mereservasi stok, tetap editable, dapat dibuat melalui Hold Order, dan dikonfirmasi ulang manual.
- Cashier/terminal lain dalam store yang sama dapat melanjutkan draft dengan single-editor lock.
- Draft tidak dihapus otomatis; stale notice mengikuti konfigurasi dan alasan cancel bersifat opsional.
- Stale default 7 hari; harga/promo dihitung ulang; edit lock timeout 5 menit; pembayaran draft wajib dikonfirmasi ulang.
- Draft memiliki nomor otomatis dengan label, customer, dan catatan opsional.
- Opening Stock hanya berlaku sebelum terdapat movement; perubahan berikutnya menggunakan Adjustment.
- Stock Movement read-only dan hanya dibuat oleh source document/proses sistem.
- Adjustment menggunakan input stok akhir/fisik; selisih dihitung sistem.
- Alasan Adjustment menggunakan master reusable.
- Store Manager dapat membuat/post Adjustment dalam assignment; Company Admin/Super Admin mewarisi kewenangan tersebut. Tidak ada approval terpisah.
- Selisih negatif diklasifikasikan sebagai Stock Loss dan selisih positif sebagai Stock Gain.
- Stock Opname dilakukan per gudang melalui mode input POS oleh kasir.
- Kasir dapat membuat sesi baru langsung dari POS, termasuk setiap hari sesuai kebijakan.
- Scope opname fleksibel: semua produk, per kategori, atau produk terpilih.
- POS memakai blind count; kasir tidak melihat saldo sistem atau selisih.
- Store Manager atau Company Admin/Super Admin membandingkan dan mem-posting dari Backoffice.
- Finance dapat memantau/review, tetapi bukan approval wajib.
- Status Stock Opname: DRAFT, COUNTING, COMPLETED, POSTED, atau CANCELED; line dapat berstatus RECOUNT_REQUIRED.
- Posting Stock Opname membuat Adjustment otomatis untuk line yang memiliki selisih.
- Model non-blocking disetujui: POS tetap berjalan, expected quantity dihitung pada waktu count, dan movement selama count window memicu recount produk terkait.
- Hitungan terbaru menggantikan line produk/gudang sama yang belum diposting; line lama berstatus `SUPERSEDED`.
- Kasir dapat mengedit sampai `COMPLETED`; setelah itu angka terkunci.
- Store Manager tidak dapat mengubah angka kasir dan hanya dapat meminta recount.
- Stock Request dibuat dari POS, Store Manager membuat Supplier Order, Kasir menerima barang melalui POS, dan Finance memproses invoice/AP melalui Backoffice.
- Partial receipt didukung dan satu Supplier Order dapat memiliki beberapa Goods Receipt.
- Receipt posted menambah stok accepted quantity, membuat movement/FIFO batch, dan sumber AP provisional.
- Harga order bersifat estimasi; Finance menginput nilai aktual dari invoice fisik dan sistem menyimpan adjustment harga.
- Master Supplier menjadi bagian Master Data.
- Cashier existing membuat Stock Request; tidak ada role Sales baru.
- Satu request dapat dipecah/dikelompokkan menjadi Supplier Order per supplier.
- Store Manager atau Company Admin/Super Admin menentukan ordered quantity final tanpa alasan wajib; requested quantity tetap menjadi audit snapshot.
- Over-receipt boleh diposting ke stok dan AP provisional, lalu ditandai untuk three-way reconciliation oleh Finance.
- Purchase Return mendukung partial return, movement pengurangan stok, dan adjustment AP/credit note sesuai status invoice.
- Field barang rusak/ditolak bersifat opsional dan tersembunyi secara default; barang rusak yang diterima masuk gudang `DAMAGED`, sedangkan barang ditolak tidak menambah stok/AP.
- Invoice matching bersifat fleksibel/many-to-many dengan allocation yang dapat diaudit untuk dokumen dari company dan supplier yang sama.
- Cashier membuat draft Purchase Return dari POS dan Store Manager atau Company Admin/Super Admin mem-posting melalui Backoffice.
- Return sebelum invoice final langsung mengurangi AP provisional; return setelah invoice final/dibayar diproses melalui credit note/refund/offset tanpa mengubah jurnal lama.
- Return hanya boleh memilih line dari Goods Receipt asal; alasan dapat dipilih dari saran atau ditulis bebas, dan posting dilakukan saat barang diserahkan kepada supplier.
- Master Supplier menyimpan satu rekening utama sebagai referensi agar Finance dapat menyalin data pembayaran tanpa pencarian ulang.
- Cashier membuat Stock Request tanpa memilih supplier; Store Manager atau Company Admin/Super Admin memilih supplier saat membuat order.
- Satu produk dapat memiliki banyak supplier dengan maksimal satu supplier utama opsional.
- Relasi Produk-Supplier menyimpan kode supplier, UOM pembelian, harga beli terakhir, flag utama, dan status aktif.
- Harga beli awal Produk menjadi fallback sebelum ada histori. Harga terakhir invoice supplier utama ditampilkan terpisah dan menjadi default pertama Supplier Order.
- Supplier tanpa relasi tetap dapat dipilih Store Manager; sistem menawarkan pembuatan relasi dengan konfirmasi eksplisit.
- Harga terakhir menjadi default yang dapat diubah Store Manager dan disimpan sebagai snapshot order/receipt provisional.
- `last_purchase_price` hanya diperbarui saat invoice divalidasi Finance, bukan saat order atau receipt.
- HPP transaksi berasal dari cost batch/FIFO; harga invoice aktual mengoreksi valuation dan memperbarui harga beli terakhir tanpa mengubah histori.
- Sisa Stock Request dapat ditutup Store Manager tanpa alasan wajib dengan audit `closed_by/closed_at`; dokumen order/receipt existing tidak dibatalkan.
- Barcode tersedia opsional per produk-UOM dan unik per company bila diisi.
- Brand menjadi master reusable opsional pada Produk.
- Bundle hanya dapat berisi komponen `STOCK`; nested bundle dilarang.
- UOM mengatur `allow_decimal` dan precision default 3; UOM unit/kemasan bulat sedangkan berat/volume/panjang dapat pecahan.
- Minimum stock opsional per produk-gudang hanya membuat notice Cashier dan tidak membuat request/order otomatis.
- POS menampilkan stock awal sesi, terjual kotor, retur/reversal, net keluar, stock terkini, dan snapshot penutupan tanpa menampilkan HPP/nilai persediaan.
- Product card hanya menampilkan stock terkini; detail sesi tersedia pada panel produk dan Ringkasan Tutup Sesi.
- Rounding grand total bersifat opsional untuk semua metode pembayaran, memakai kelipatan Rp100, dan dipilih Cashier sebagai NONE/DOWN/UP.
- Struk menampilkan total sebelum pembulatan, adjustment pembulatan, dan total akhir.
- Seluruh UOM produk menyimpan faktor langsung ke base UOM terkecil; rantai konversi non-base tidak digunakan untuk kalkulasi.
- Full refund mengembalikan total akhir yang dibayar; partial refund boleh melakukan rounding Rp100 terpisah dengan audit lengkap.
- Laporan Store Manager menyimpan detail rounding sale/refund per invoice, Cashier, metode pembayaran, arah, adjustment, dan total akhir.
- Produk memiliki satu link gambar utama opsional dari Google Drive/external HTTPS; aplikasi tidak menyimpan/proxy binary. Galeri/import gambar ditunda.
- Scan barcode menambah quantity 1 atau menaikkan line produk-UOM yang sama; quantity tetap dapat diedit Cashier.
- Approval refund dapat dikonfigurasi REQUIRED atau OPTIONAL per company/store; metode refund Cash/Transfer fleksibel.
- Company Owner/Admin mengatur default approval refund, Store Manager dapat override store dalam scope, dan mode REQUIRED diposting Store Manager atau Company Admin/Super Admin melalui Backoffice.
- Bukti refund transfer bersifat opsional pada scope awal.
- Refund line memilih SALEABLE, DAMAGED, atau NO_PHYSICAL_RETURN untuk menentukan dampak stok.
- Gambar Produk disimpan dalam private bucket tenant-scoped; akses lintas company dan penggunaan service role di browser dilarang.
- Barcode timbangan/embedded weight-price ditunda; fase awal hanya barcode biasa Produk-UOM.
- Expense dan arus kas non-penjualan wajib dibahas pada fase detail POS; reminder dicatat di `docs/POS_DEVELOPMENT_NOTES.md` dan detailnya di `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`.
- Cashier mengisi opening cash manual, hanya memiliki satu sesi OPEN, dan melihat expected/actual/difference ketika closing.
- Cashier dapat mengunduh Excel sesi sendiri dan membuat Setor Kas dari satu atau beberapa sesi CLOSED dalam company/store yang sama.
- Setor Kas mengunci sesi saat submit, dapat berbeda dari expected, diselesaikan melalui approval Finance, dan baru membuat jurnal setelah approval.
- Draft/Hold Order tetap editable, lintas sesi/terminal dalam store, memakai edit lock, tidak mereservasi stok, dan tidak dihapus otomatis.
- Pricelist berada di Sales Master Data; harga Produk-UOM hanya fallback setelah customer/global pricelist tidak ditemukan.
- Diskon manual line/transaksi mendukung nominal/persentase; promo quantity gratis memakai Bundle.
- Quantity tier hanya berlaku pada Global Pricelist, basisnya configurable per rule produk, dan potongan nominal berlaku per unit.
- Bundle promo memakai SKU khusus yang dipilih/scan eksplisit; tidak ada auto-convert cart.
- Bundle tetap satu line komersial tanpa stok sendiri; revenue allocation analitik, component FIFO/HPP, tax/diskon/rounding, reporting, dan return snapshot mengikuti `docs/BUNDLE_REVENUE_ALLOCATION_SPEC.md`.
- Global Pricelist dapat company-wide/store-specific; pelanggan umum memakai default dan Cashier dapat memilih Pricelist eligible lain secara opsional.
- Diskon manual dapat ditumpuk di atas Pricelist; harga POS bersifat tax-inclusive pada scope awal.
- Ketul adalah tiang kebab dengan beberapa Produk STOCK di category Ketul, UOM PCS integer, gudang toko biasa, dan harga manual per transaksi.
- Category Ketul direferensikan oleh konfigurasi, bukan nama hardcoded. Entitlement Ketul diaktifkan/dinonaktifkan per company hanya oleh Super Admin; fitur disabled menyembunyikan workflow dan memblokir mutation baru tanpa menghapus histori.
- Customer intake membuat FIFO batch dari manual acquisition value yang boleh nol.
- Dispatch Vendor memindahkan sent qty dari gudang STORE aktif ke `TRANSIT`; pending qty tetap di `TRANSIT` dan boleh direkonsiliasi melalui beberapa hasil parsial.
- Accepted qty menjadi stock-out dan mengonsumsi FIFO/HPP saat hasil Vendor dicatat. Rejected qty dipindahkan dari `TRANSIT` ke stock aktif atau `DAMAGED` dan tidak mengakui revenue/HPP Vendor.
- Jika transaksi dibatalkan sebelum Finance confirmation, accepted qty wajib diretur fisik dan FIFO layer/unit cost asal dipulihkan ke stock aktif atau `DAMAGED` agar valuation tetap balance.
- Nilai total dokumen Vendor dialokasikan proporsional berdasarkan estimasi accepted line. Settlement dapat menggabungkan beberapa hasil parsial atau membayar satu hasil secara bertahap; saldo kurang menjadi outstanding Vendor.
- Jika seluruh estimasi accepted line nol, alokasi total memakai proporsi accepted qty. Outstanding Vendor memiliki due date dan aging.
- Koreksi quantity setelah Finance confirmation wajib membuat stock/FIFO reversal dan financial reversal yang saling mereferensikan.
- Selisih pembulatan alokasi Vendor ditempelkan ke line bernilai terbesar. Due date diinput manual dan dokumen otomatis `CLOSED` setelah seluruh quantity, transit, settlement, dan workflow lanjutan selesai.
- Quantity status dan settlement status dipisahkan. Koreksi movement memakai delta/reversal append-only; stok kurang memblokir dispatch posting tetapi tetap mengizinkan penyimpanan `DRAFT`.
- Produk sama digabung satu line, nomor dokumen otomatis per company/store, mutation idempotent, `CLOSED` immutable, dan Vendor inactive hanya memblokir dispatch baru.
- Cash Ketul yang terkait sesi ikut expected cash/export/setoran sesi. `KETUL_OFFSET` menjadi settlement non-cash terhadap invoice setelah rounding, bukan diskon atau pengurang revenue.
- Ketul dispatch menyimpan origin store. Jika gudang `TRANSIT` bersifat company-level, movement tetap wajib membawa origin store dan reject tidak boleh dikembalikan ke store lain.

---

## 17. Decision Log

| Tanggal | Bagian | Keputusan | Status |
|---|---|---|---|
| 2026-07-14 | Scope | Fokus awal Produk dan Stok; tulis spesifikasi sebelum implementasi | APPROVED |
| 2026-07-14 | Struktur | Tambahkan Stock Movement, Stock Real, Master Data, Adjustment, Report Opname, dan Konfirmasi Order | APPROVED secara garis besar |
| 2026-07-14 | Master Data | Produk, kategori, UOM, gudang, dan referensi reusable dikelola sebagai master | APPROVED secara garis besar |
| 2026-07-14 | Accounting | Kategori produk disiapkan untuk mapping COA | APPROVED secara garis besar; field belum final |
| 2026-07-14 | Import | Import harus dirapikan seperti pola Odoo | APPROVED secara konsep; workflow detail belum final |
| 2026-07-14 | Tipe Produk | Fokus retail hanya membutuhkan produk `STOCK` dan `BUNDLE` | APPROVED |
| 2026-07-14 | Identitas Produk | SKU diisi manual; nama produk tidak boleh duplikat dalam company yang sama | APPROVED |
| 2026-07-14 | UOM Produk | Satu produk dapat memiliki beberapa UOM turunan yang diisi manual; UOM bukan produk/SKU terpisah | APPROVED |
| 2026-07-14 | Berat Produk | Berat diisi manual pada UOM terbesar sebagai acuan | APPROVED |
| 2026-07-14 | Kategori Produk | Kategori memiliki master tersendiri dan dipilih melalui dropdown pada form produk | APPROVED |
| 2026-07-14 | Saldo per UOM | Saldo disimpan dalam UOM terkecil dan dapat ditampilkan dalam hasil konversi UOM lain | APPROVED |
| 2026-07-14 | Harga per UOM | Harga beli dan jual diisi manual per UOM; harga UOM besar tidak dihitung dari harga UOM kecil | APPROVED |
| 2026-07-14 | Berat Turunan | Berat UOM turunan dihitung proporsional dari berat UOM terbesar sebagai estimasi | APPROVED |
| 2026-07-14 | Bundle | Bundle tidak memiliki stok fisik; stok, berat, dan HPP mengikuti komponen, sedangkan harga jual diisi manual | APPROVED |
| 2026-07-14 | Struktur Kategori | Kategori produk hanya satu tingkat dan kode kategori diisi manual | APPROVED |
| 2026-07-14 | COA Kategori | Mapping COA boleh kosong selama fase Produk & Stok, tetapi wajib diselesaikan saat fase Finance | APPROVED |
| 2026-07-14 | Prioritas Posting | Kategori/aturan transaksi menentukan COA utama; COA kategori produk hanya fallback | APPROVED |
| 2026-07-14 | Tipe Gudang | Master Gudang memiliki tipe `CENTRAL`, `STORE`, `DAMAGED`, dan `TRANSIT` | APPROVED |
| 2026-07-14 | Relasi Gudang | Gudang `STORE` wajib terhubung ke store; `CENTRAL` boleh company-level | APPROVED |
| 2026-07-14 | Kode Gudang | Kode gudang diisi manual dan maksimal 5 huruf | APPROVED |
| 2026-07-14 | Stok Negatif | Stok negatif tidak diizinkan; penjualan dengan stok tidak cukup disimpan sebagai draft dan diberi notice | APPROVED secara konsep; detail reconfirm masih terbuka |
| 2026-07-14 | Lokasi Gudang | Gudang cukup menyimpan lokasi/alamat tanpa master rak/bin | APPROVED |
| 2026-07-14 | Pengelola Gudang | Company Admin, Warehouse Admin, dan Store Manager/SPV Toko dapat mengatur gudang sesuai scope; Super Admin/Owner tetap mengikuti hierarki | APPROVED |
| 2026-07-14 | Gudang Damaged/Transit | `DAMAGED` dan `TRANSIT` boleh company-level atau dihubungkan ke store | APPROVED |
| 2026-07-14 | Atomic Sales Draft | Kekurangan satu line membuat seluruh order tetap draft | APPROVED |
| 2026-07-14 | Draft dan Finance | Order draft belum membuat payment final, financial event, jurnal, atau pencatatan laporan keuangan | APPROVED |
| 2026-07-14 | Format Import | CSV wajib; XLSX/Excel opsional jika mudah dan aman diimplementasikan | APPROVED |
| 2026-07-14 | Import & Export | User dapat export master referensi lalu import menggunakan ID atau nama yang sudah tersedia | APPROVED |
| 2026-07-14 | Update via Import | Record existing yang matched dapat di-update dan wajib diberi warning sebelum konfirmasi | APPROVED |
| 2026-07-14 | Partial Success | Record valid di-commit, record gagal tidak dijalankan dan diberi notifikasi/error report | APPROVED |
| 2026-07-14 | Preview Import | Preview CREATE/UPDATE/SKIP/ERROR dan perubahan wajib tersedia sebelum konfirmasi | APPROVED |
| 2026-07-14 | Opening Stock Import | Opening Stock terpisah dan hanya mengubah stok setelah dikonfirmasi | APPROVED |
| 2026-07-14 | Format Produk-UOM | Import Produk memakai beberapa row per produk/UOM seperti pola Odoo | APPROVED |
| 2026-07-14 | Protected Import Fields | SKU, tipe produk, base UOM, dan faktor konversi historis tidak dapat diubah lewat import biasa | APPROVED |
| 2026-07-14 | Rename via Import | Rename data existing wajib menggunakan mode ID, bukan mode Nama | APPROVED |
| 2026-07-14 | Missing Reference | Kategori, UOM, atau gudang yang tidak ditemukan membuat record gagal tanpa auto-create | APPROVED |
| 2026-07-14 | Opening Stock Eligibility | Opening Stock hanya untuk produk-gudang tanpa movement; perubahan berikutnya melalui Adjustment | APPROVED |
| 2026-07-14 | Opening Stock Fields | Tanggal, gudang, produk, quantity base UOM, HPP base UOM, dan catatan disimpan | APPROVED |
| 2026-07-17 | Opening Stock Authority | Store Manager/Finance menyiapkan Draft; Company Admin posting; Super Admin memiliki seluruh authority | APPROVED |
| 2026-07-17 | Opening Stock Accounting | Posting atomic membuat FIFO layer dan event Debit Inventory/Credit Opening Clearing | APPROVED; account configurable |
| 2026-07-17 | Opening Stock Zero Cost | Cost nol boleh dengan warning dan alasan wajib | APPROVED |
| 2026-07-14 | Movement Integrity | Stock Movement read-only dan hanya berasal dari source document/proses sistem | APPROVED |
| 2026-07-14 | Adjustment Input | User mengisi stok akhir/fisik dan sistem menghitung selisih | APPROVED |
| 2026-07-14 | Adjustment Reason | Alasan Adjustment menjadi master reusable | APPROVED |
| 2026-07-14 | Adjustment Authority | Store Manager dapat membuat/post dalam assignment; Company Admin/Super Admin mewarisi kewenangan; Warehouse Admin tidak | APPROVED, diperbarui 2026-07-15 |
| 2026-07-14 | Stock Gain/Loss | Selisih negatif menjadi Stock Loss; selisih positif menjadi Stock Gain/pendapatan lain-lain | APPROVED; mapping Finance resolved 2026-07-17 |
| 2026-07-14 | Opname Channel | Kasir menginput Stock Opname melalui POS; Store Manager dan Finance mereview dari Backoffice | APPROVED |
| 2026-07-14 | Opname Scope | Stock Opname per gudang dengan filter semua produk, kategori, atau produk terpilih | APPROVED |
| 2026-07-14 | Opname Posting | Posting membuat Adjustment untuk line berselisih; Store Manager atau Company Admin/Super Admin sesuai scope | APPROVED, diperbarui 2026-07-15 |
| 2026-07-14 | Non-Blocking Opname | POS tetap berjalan; expected quantity direkonsiliasi berdasarkan waktu hitung dan movement | APPROVED |
| 2026-07-14 | Opname Session Creation | Kasir dapat membuat sesi Stock Opname baru langsung dari POS setiap hari/sesuai kebijakan | APPROVED |
| 2026-07-14 | Blind Count | Kasir hanya menginput physical quantity tanpa melihat saldo sistem, selisih, atau nilai | APPROVED |
| 2026-07-14 | Opname Review | Store Manager atau Company Admin/Super Admin melakukan perbandingan/posting; Finance dapat memantau tanpa approval wajib | APPROVED |
| 2026-07-14 | Opname Supersede | Hitungan terbaru menggantikan line produk/gudang sama yang belum diposting tanpa membatalkan line lain | APPROVED |
| 2026-07-14 | Opname Edit Lock | Kasir dapat edit saat DRAFT/COUNTING; angka terkunci setelah COMPLETED | APPROVED |
| 2026-07-14 | Opname Recount | Store Manager tidak mengubah angka kasir; koreksi melalui Minta Hitung Ulang | APPROVED |
| 2026-07-14 | Order Flow | POS Stock Request -> Store Manager Supplier Order -> Kasir Goods Receipt -> Finance Invoice/AP/Payment | APPROVED |
| 2026-07-14 | Partial Receipt | Supplier Order dapat diterima bertahap melalui beberapa Goods Receipt | APPROVED |
| 2026-07-14 | Receipt Quantity | Kasir menginput quantity dan UOM aktual; accepted quantity dikonversi ke base UOM | APPROVED |
| 2026-07-14 | Supplier Master | Supplier menjadi master reusable per company | APPROVED |
| 2026-07-14 | Provisional AP | Receipt posted membentuk AP provisional dengan harga estimasi; Finance mencocokkan invoice fisik dan menginput nilai aktual sebelum pembayaran | APPROVED secara konsep; detail Finance tertunda |
| 2026-07-14 | Stock Request Role | Cashier existing membuat Stock Request; tidak dibuat role Sales baru | APPROVED |
| 2026-07-14 | Supplier Grouping | Satu request dapat dipecah dan line dikelompokkan menjadi Supplier Order per supplier | APPROVED |
| 2026-07-14 | Ordered Quantity | Store Manager atau Company Admin/Super Admin menentukan quantity order final; requested quantity tetap disimpan tanpa alasan perubahan wajib | APPROVED |
| 2026-07-14 | Over Receipt | Quantity lebih boleh diposting ke stok/AP provisional dan ditandai untuk rekonsiliasi Finance | APPROVED |
| 2026-07-14 | Receipt Condition | Field barang baik/rusak/ditolak bersifat opsional dan tersembunyi secara default; rusak yang diterima masuk DAMAGED, ditolak tidak masuk stok/AP | APPROVED |
| 2026-07-14 | Invoice Matching | Matching bersifat fleksibel/many-to-many per company dan supplier dengan allocation yang dapat diaudit | APPROVED secara konsep; schema Finance tertunda |
| 2026-07-14 | Purchase Return | Cashier membuat draft di POS; Store Manager atau Company Admin/Super Admin posting di Backoffice | APPROVED, diperbarui 2026-07-15 |
| 2026-07-14 | Return Source | Produk return wajib berasal dari Goods Receipt asal dan tidak menerima line produk bebas | APPROVED |
| 2026-07-14 | Return Reason | Satu field alasan wajib dapat menggunakan nilai saran atau teks bebas | APPROVED |
| 2026-07-14 | Return Posting Time | Store Manager atau Company Admin/Super Admin posting ketika barang benar-benar diserahkan kepada supplier | APPROVED, diperbarui 2026-07-15 |
| 2026-08-06 | Purchase Return UOM | Retur boleh memakai UOM Produk aktif yang berbeda dari UOM pembelian/Receipt; conversion langsung ke base UOM dan source FIFO limit tetap wajib | APPROVED |
| 2026-07-17 | Purchase Price Variance | Invoice aktual merevaluasi remaining FIFO dan mencatat variance HPP untuk quantity terjual | APPROVED |
| 2026-07-17 | Supplier Refund Receivable | Return melebihi AP terbuka menjadi Piutang Refund Supplier untuk Transfer/offset berikutnya | APPROVED |
| 2026-07-14 | Supplier Bank Reference | Master Supplier menyimpan satu rekening utama untuk referensi/copy oleh Finance saat pembayaran | APPROVED |
| 2026-07-14 | Supplier Selection | Cashier tidak memilih supplier; Store Manager atau Company Admin/Super Admin memilih saat membuat Supplier Order | APPROVED |
| 2026-07-14 | Product Supplier | Satu produk dapat memiliki banyak supplier dengan satu preferred supplier opsional | APPROVED |
| 2026-07-14 | Supplier Purchase Reference | Relasi menyimpan kode supplier, UOM pembelian, harga beli terakhir, preferred flag, dan status | APPROVED |
| 2026-07-14 | Purchase Price and HPP | Harga supplier menjadi default order/provisional batch; HPP memakai FIFO batch dan dikoreksi dari invoice aktual | APPROVED secara konsep; alokasi price variance tertunda ke Finance |
| 2026-07-14 | Initial vs Last Purchase Price | Harga beli awal diisi manual; harga terakhir supplier utama dari invoice tervalidasi ditampilkan terpisah | APPROVED |
| 2026-07-14 | Inline Product Supplier | Store Manager boleh memilih supplier tanpa relasi dan menyimpan relasi melalui konfirmasi eksplisit | APPROVED |
| 2026-07-14 | Last Price Update | Harga beli terakhir hanya diperbarui saat invoice divalidasi Finance, bukan saat order/receipt | APPROVED |
| 2026-07-14 | Stock Request Closure | Store Manager dapat menutup sisa request tanpa alasan; actor/waktu tersimpan dan dokumen existing tetap berlaku | APPROVED |
| 2026-07-14 | Barcode | Barcode opsional per produk-UOM dan unik per company bila diisi | APPROVED |
| 2026-07-14 | Brand | Master Brand reusable tersedia; pemilihan Brand pada Produk bersifat opsional | APPROVED |
| 2026-07-14 | Bundle Components | Bundle hanya berisi produk STOCK dan nested bundle dilarang | APPROVED |
| 2026-07-14 | Decimal UOM | UOM unit/kemasan wajib bulat; UOM berat/volume/panjang dapat pecahan dengan precision default 3 | APPROVED |
| 2026-07-14 | Minimum Stock | Threshold opsional per produk-gudang memicu notice Cashier tanpa auto request/order | APPROVED |
| 2026-07-15 | POS Session Stock Visibility | Cashier melihat snapshot seluruh stock awal, terjual kotor, retur, net keluar, dan stock terkini live; closing menyimpan snapshot | APPROVED |
| 2026-07-15 | POS Stock Card UX | Card hanya menampilkan stock terkini; detail sesi berada di panel produk/ringkasan sesi | APPROVED |
| 2026-07-15 | Low Stock UX | Satu badge jumlah produk stok menipis membuka daftar; tidak memakai toast per produk | APPROVED |
| 2026-07-15 | Session Closing Stock | Detail stok per produk tersedia pada Ringkasan Tutup Sesi tanpa memenuhi struk utama | APPROVED |
| 2026-07-15 | Live Receipt Stock | Receipt posted memperbarui stock terkini POS dan transaksi shortage dapat dicoba kembali dengan validasi server | APPROVED |
| 2026-07-15 | Cross-Session Sales Return | Retur masuk ke sesi eksekusi dan menyimpan referensi invoice/sesi penjualan asal | APPROVED |
| 2026-07-15 | Other Session Movements | Laporan memisahkan penerimaan, transfer masuk/keluar, adjustment, opname, dan movement non-sale lain | APPROVED |
| 2026-07-15 | Grand Total Rounding | Opsional untuk semua metode; Cashier memilih NONE/DOWN/UP ke kelipatan Rp100 dan laporan Store Manager menyimpan selisih | APPROVED; gain/loss mapping resolved 2026-07-17 |
| 2026-07-15 | Rounding Receipt | Struk menampilkan total sebelum rounding, adjustment, dan total akhir | APPROVED |
| 2026-07-15 | Direct Base Conversion | Semua UOM produk dikonversi langsung ke base UOM terkecil; tidak memakai rantai non-base untuk kalkulasi | APPROVED |
| 2026-07-15 | Full Refund Rounding | Full refund mengembalikan persis total setelah rounding dan membalik adjustment asal | APPROVED |
| 2026-07-15 | Partial Refund Rounding | Partial refund boleh memakai rounding Rp100 NONE/DOWN/UP terpisah dengan audit | APPROVED |
| 2026-07-15 | Rounding Manager Report | Laporan memuat waktu, dokumen, Cashier, metode, total awal, arah, adjustment, dan total akhir | APPROVED |
| 2026-07-15 | Product Image | Satu gambar utama opsional | APPROVED; storage internal disupersede 2026-07-19 oleh external Drive link sementara |
| 2026-07-19 | External Product Photo | Foto Produk memakai Google Drive/external HTTPS link; aplikasi hanya menyimpan URL/metadata | APPROVED |
| 2026-07-15 | Barcode Cart Behavior | Scan exact menambah 1 atau menaikkan quantity line produk-UOM sama; manual edit tetap tersedia | APPROVED |
| 2026-07-15 | Refund Approval Configuration | Mode REQUIRED atau OPTIONAL dapat diatur per company/store | APPROVED |
| 2026-07-15 | Refund Stock Disposition | Return line memilih SALEABLE, DAMAGED, atau NO_PHYSICAL_RETURN | APPROVED |
| 2026-07-15 | Refund Method | Refund dapat menggunakan Cash atau Transfer sesuai kondisi lapangan | APPROVED |
| 2026-07-15 | Private Product Images | Gambar berada di private tenant-scoped Storage dan hanya dapat diakses member company | APPROVED |
| 2026-07-15 | Scale Barcode | Barcode timbangan/embedded price-weight ditunda; barcode biasa Produk-UOM menjadi scope awal | APPROVED |
| 2026-07-15 | POS Expense/Arus Kas Reminder | Modul dicatat agar tidak terlewat; detail workflow/Finance dibahas terpisah | APPROVED sebagai reminder |
| 2026-07-15 | Refund Configuration Authority | Company Owner/Admin mengatur default company; Store Manager dapat override store dalam scope dan store override menjadi prioritas | APPROVED |
| 2026-07-15 | Required Refund Approval Channel | Mode REQUIRED dibuat draft oleh Cashier dan diposting Store Manager atau Company Admin/Super Admin melalui Backoffice | APPROVED, diperbarui 2026-07-15 |
| 2026-07-15 | Transfer Refund Proof | Bukti transfer opsional pada scope awal; data tujuan dan referensi yang tersedia tetap disimpan | APPROVED |
| 2026-07-15 | Cashier Session Cash | Opening cash manual; satu Cashier hanya boleh memiliki satu sesi OPEN; closing menampilkan expected, actual, dan selisih | APPROVED |
| 2026-07-15 | Session Finance Export | Cashier dapat mengunduh workbook Excel flow keuangan untuk sesi miliknya sendiri | APPROVED |
| 2026-07-15 | Multi-Session Cash Deposit | Cashier dapat memilih beberapa sesi CLOSED dan menginput total setoran aktual terhadap total expected bersih | APPROVED |
| 2026-07-15 | Deposit Variance | Nominal aktual boleh kurang/lebih; sesi selesai saat Finance approve dan variance menjadi exception Finance | APPROVED |
| 2026-07-15 | Deposit Approval and Journal | Finance atau Company Admin/Super Admin approve/reject; jurnal hanya dibuat setelah approval berdasarkan nominal aktual | APPROVED, diperbarui 2026-07-15 |
| 2026-07-15 | Deposit Float and Proof | Saldo berikutnya diinput saat membuat Setor Kas; bukti REQUIRED/OPTIONAL melalui konfigurasi company/store | APPROVED |
| 2026-07-15 | Draft and Hold Order | Semua draft editable; Hold manual tersedia; retry posting dilakukan manual tanpa reservasi stok | APPROVED |
| 2026-07-15 | Cross-Terminal Draft | Cashier lain dalam store yang sama dapat melanjutkan draft dengan single-editor lock dan audit creator/poster | APPROVED |
| 2026-07-15 | Draft Retention | Draft tidak dihapus otomatis, stale notice configurable, dan alasan cancel opsional | APPROVED |
| 2026-07-15 | Draft Stale Default | Default 7 hari dengan optional store override | APPROVED |
| 2026-07-15 | Draft Repricing | Harga/promo dihitung ulang ketika dilanjutkan dan perubahan ditampilkan untuk konfirmasi | APPROVED |
| 2026-07-15 | Draft Lock Timeout | Lock dilepas setelah 5 menit tidak aktif dan takeover membutuhkan konfirmasi/audit | APPROVED |
| 2026-07-15 | Draft Identification | Nomor otomatis; label, customer, dan catatan opsional | APPROVED |
| 2026-07-15 | Draft Payment | Payment hanya catatan sementara dan wajib dikonfirmasi ulang ketika posting | APPROVED |
| 2026-07-15 | Sales Pricelist Boundary | Pricelist berada di Sales Master Data; harga Produk-UOM menjadi fallback | APPROVED |
| 2026-07-15 | Manual Discount | Diskon line dan transaksi mendukung nominal/persentase tanpa limit role awal | APPROVED |
| 2026-07-15 | Bundle Promotion | Promo 2+1 menggunakan Bundle; seluruh komponen mengurangi stok/HPP dan harga bundle diisi manual | APPROVED |
| 2026-07-20 | Bundle Revenue Allocation | MVP journal satu nilai ke Bundle; component analytic allocation memakai price/HPP/qty fallback dan original snapshot | APPROVED |
| 2026-07-15 | Exclusive Customer Pricing | Pricelist Customer melewati Global tier dan fallback langsung ke harga dasar Produk-UOM | APPROVED |
| 2026-07-15 | Global Quantity Tier | Tier hanya Global; basis per rule SALES_UOM/BASE_UOM dan nominal discount per unit | APPROVED |
| 2026-07-15 | Explicit Bundle SKU | Bundle promo dipilih/scan melalui SKU khusus tanpa auto-convert | APPROVED |
| 2026-07-15 | Pricelist Access | Company Admin dan Store Manager mengelola berdasarkan active company assignment | APPROVED |
| 2026-07-15 | Pricelist Store Assignment | Global Pricelist dapat berlaku seluruh store atau store tertentu dalam company | APPROVED |
| 2026-07-15 | Cashier Pricelist Selection | Customer umum memakai default Global; Cashier dapat memilih Pricelist eligible lain secara opsional | APPROVED |
| 2026-07-15 | Pricing Stack and Tax | Diskon manual dapat ditumpuk; harga POS tax-inclusive | APPROVED |
| 2026-07-17 | Optional Tax Entitlement | Pajak dapat diaktifkan per company hanya oleh Super Admin | APPROVED; Tax Engine resolved 2026-07-20 |
| 2026-07-19 | Module Tax Entitlement | SALES_TAX dan PURCHASE_TAX dapat diaktifkan independen agar pembelian dapat berpajak saat penjualan tidak, atau sebaliknya | APPROVED |
| 2026-07-20 | Tax Resolver | Product Category menjadi default Sales/Purchase Tax Rule dan Produk dapat override | APPROVED |
| 2026-07-20 | Purchase Matching Contract | Partial/many-to-many matching, over-receipt tolerance, accepted damaged/rejected, invoice HOLD, dan residual AP Provisional | APPROVED |
| 2026-07-20 | UOM/Weight Valuation Contract | Input precision, high-precision FIFO, weight logistics-only, cross-UOM snapshot, dan controlled conversion version | APPROVED |
| 2026-07-20 | Transaction Category Contract | Permanent system key, flexible company category, required account function, versioned resolver, dan missing-mapping HOLD | APPROVED |
| 2026-07-20 | ERP Evolution Boundary | Product/UOM/Inventory disiapkan reusable untuk future Manufacture/Logistik tanpa menambah scope POS sekarang | APPROVED sebagai arah |
| 2026-07-15 | Customer Master | Code otomatis, kategori reusable, company-wide, quick-create, nama unik, Walk-In row, dan saldo kelebihan transfer | APPROVED secara operasional |
| 2026-07-15 | Ketul Product Model | Beberapa jenis Ketul menjadi Produk STOCK category Ketul, UOM PCS, gudang toko, dan harga manual | APPROVED |
| 2026-07-15 | Ketul Operations | Cashier posting Customer intake dan Vendor sale; Store Manager monitor; feature company/store configurable | APPROVED secara operasional |
| 2026-07-15 | Ketul FIFO | Intake membentuk FIFO batch dari manual value; accepted Vendor qty mengonsumsi FIFO | APPROVED |
| 2026-07-15 | Ketul Vendor Disposition | Rejected qty kembali ke active/damaged; actual Vendor amount menjadi nilai final | APPROVED |
| 2026-07-15 | Ketul Transit | Dispatch memindahkan sent qty STORE ke TRANSIT; pending qty tetap di TRANSIT | APPROVED |
| 2026-07-15 | Ketul Partial Result | Cashier/Finance dapat mencatat beberapa hasil parsial; accepted qty stock-out/HPP saat hasil dicatat | APPROVED |
| 2026-07-16 | Feature Entitlement | Customer Balance dan Ketul hanya dapat diaktifkan/dinonaktifkan Super Admin per company | APPROVED |
| 2026-07-16 | Draft Pricelist Revalidation | Draft selalu resolve harga terbaru; Cashier dapat menjaga harga lama yang lebih murah melalui diskon manual ter-audit | APPROVED |
| 2026-07-16 | POS Offline Reliability | Penjualan offline menjadi PENDING_SYNC dengan idempotency/acknowledgement; physical handover hanya dalam Offline Stock Allowance | APPROVED; allocation/pricing detail terbuka |
| 2026-07-16 | Offline Stock Allowance | Stock server direservasi per terminal/session dalam base UOM; offline sale tidak boleh melebihi allowance | APPROVED |
| 2026-07-16 | Offline Allowance Allocation | Default 20% available unreserved stock untuk terminal terpilih; terikat sesi dan force revoke ter-audit | APPROVED |
| 2026-07-16 | Offline Snapshot Posting | Harga dan Product/UOM snapshot transaksi fisik offline dihormati saat sync; perubahan menjadi variance/exception | APPROVED |
| 2026-07-16 | Offline Allowance Rounding | Integer floor minimum 1 bila tersedia; decimal floor sesuai precision; total reservation tidak melebihi stock | APPROVED |
| 2026-07-16 | Offline Payment Exception | Payment elektronik gagal tidak membatalkan stock-out/sale fisik dan diselesaikan Finance melalui event append-only | APPROVED |
| 2026-07-16 | Offline Stock Opname | Blind count offline memakai time anchor/sequence; movement queue sync sebelum count dan late movement memicu recount | APPROVED |
| 2026-07-16 | Offline Opname Posting Gate | Adjustment menunggu queue relevan; terminal hilang membutuhkan exception audit dan physical recount | APPROVED |
| 2026-07-15 | Ketul Document Allocation | Total Vendor dialokasikan proporsional berdasarkan estimated accepted line | APPROVED |
| 2026-07-15 | Ketul Settlement | Payment/result many-to-many dan sisa belum dibayar menjadi outstanding Vendor | APPROVED |
| 2026-07-15 | Ketul Cancellation Return | Retur fisik memulihkan FIFO layer/cost asal ke active atau DAMAGED | APPROVED |
| 2026-07-15 | Ketul Zero Allocation | Estimated value nol memakai accepted qty sebagai fallback alokasi | APPROVED |
| 2026-07-15 | Ketul Aging and Reversal | Outstanding memiliki due date/aging; koreksi qty pasca-confirmation memakai stock/FIFO dan financial reversal | APPROVED |
| 2026-07-15 | Ketul Close Rule | Rounding masuk line terbesar; due date manual; dokumen auto-close ketika seluruh flow selesai | APPROVED |
| 2026-07-15 | Ketul Final Guardrail | Status quantity/payment dipisah, movement append-only, shortage blocked, auto number, idempotency, CLOSED immutable | APPROVED |
| 2026-07-15 | Ketul Inactive Vendor | Dispatch baru diblokir; dokumen dan outstanding lama tetap dapat diselesaikan | APPROVED |
| 2026-07-15 | Company Admin Authority | Company Admin memiliki seluruh kewenangan role bawahan dalam company miliknya; Super Admin lintas company | APPROVED |
