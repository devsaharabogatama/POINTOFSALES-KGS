# Spesifikasi Analitik Potensi Produk per Customer

**Status:** APPROVED DESIGN — IMPLEMENTATION NOT STARTED  
**Keputusan user:** 2026-08-26  
**Target menu:** `Report > Potensi Produk`  
**Sifat fitur:** opsional per Company, read-only terhadap transaksi  
**Batas otorisasi saat ini:** dokumen ini mengizinkan pencatatan desain, bukan
perubahan schema, UI, runtime, database, atau deployment.

---

## 1. Outcome

Submodul ini menghitung peluang cross-selling Product per Customer dari
transaksi penjualan final. Contoh awal berasal dari workbook
`01.Draft Potensi Produk Customer 2026.xlsx`: pembelian aktual Daging Kebab
menjadi driver untuk memperkirakan kebutuhan Tortilla, Lettuce, Saus,
Mayones, Dus, dan Kertas Pembungkus; pembelian Burger dapat menjadi driver
untuk Roti dan kemasan Burger.

Hasil minimum per Customer, Product target, dan periode:

- quantity aktual;
- quantity potensial;
- gap peluang `max(potensial - aktual, 0)`;
- surplus aktual terhadap model bila aktual melebihi potensi;
- achievement `aktual / potensial`, tanpa batas maksimum 100%;
- versi model dan waktu kalkulasi;
- status kalkulasi dan alasan kegagalan bila ada.

Ini adalah analitik peluang, bukan forecast machine-learning, target Finance,
atau dokumen transaksi.

---

## 2. Keputusan Bisnis yang Sudah Disetujui

1. Fitur berada di modul **Report**, bukan diwajibkan dibuka dari satu per satu
   halaman Customer. Detail Customer hanya boleh menjadi drill-down opsional.
2. Fitur dapat dinyalakan/dimatikan per Company. Hanya Super Admin yang boleh
   mengubah entitlement Company sesuai invariant `TEN-003`.
3. Formula tidak di-hard-code. Company mengatur model, driver, yield, kebutuhan
   per unit/porsi, Product target, UOM laporan, dan tanggal efektif melalui UI.
4. Fitur hanya membaca transaksi final dan menulis konfigurasi/snapshot
   analitiknya sendiri.
5. Kegagalan atau keterlambatan kalkulasi tidak boleh memblokir POS, Draft,
   Post, Return, Stock, Purchasing, Payment, atau Finance.
6. Saat pertama diaktifkan, admin memilih tanggal mulai perhitungan dan apakah
   histori sejak tanggal tersebut perlu di-backfill. Seluruh histori tidak
   dihitung otomatis tanpa keputusan eksplisit.
7. Mematikan fitur tidak menghapus konfigurasi atau snapshot. Re-enable dapat
   melanjutkan dari watermark terakhir dan mengejar periode yang tertinggal.
8. Perubahan formula menghasilkan versi baru dengan `effective_from`; hasil
   historis tidak berubah diam-diam.

---

## 3. Boundary Wajib

Alur satu arah:

```text
Sale/Return POSTED -> reader analitik -> calculation run -> report snapshot
```

Submodul tidak boleh:

- membuat/mengubah Sale Draft, Sales Order, Invoice, Surat Jalan, atau Return;
- mengubah Pricelist, harga, diskon, pajak, atau hasil resolver POS;
- membuat Stock Request, Supplier Order, atau dokumen Purchasing lain;
- mengubah Product Stock, FIFO, HPP, atau Stock Movement;
- membuat Financial Event, Journal, AR/AP, Customer Balance, atau settlement;
- menimpa atau menghapus transaksi historis;
- menjadi dependency synchronous pada RPC Save/Post operasional;
- menjalankan kalkulasi berat di request halaman atau transaksi POS;
- memperluas Company, Store, role, feature, atau custom-permission authority.

Tabel snapshot/config analitik tidak boleh direferensikan sebagai foreign-key
dependency dari tabel transaksi operasional.

---

## 4. Interpretasi Workbook Referensi

Workbook yang dianalisis mempunyai sheet `DESEMBER`, `JANUARI`–`MEI`,
`PROGRESS`, dan `DAGING`. Desember cocok dengan total 2025 pada `PROGRESS`,
sedangkan Januari–Mei cocok dengan 2026.

Formula contoh Tortilla:

```text
portion_count = driver_daging_kg * 0,8 * 1.000 / 25
potential_tortilla_pack = portion_count / 20
```

Target lain memakai koefisien per porsi:

- Lettuce 30 gram;
- Saus 14 gram;
- Mayones 13 gram;
- Dus Pembungkus 1 pcs;
- Kertas Pembungkus 1 pcs.

Burger memakai konversi contoh 1 pack = 10 pcs, lalu potensi Roti/kemasan
mengikuti jumlah pcs. Angka 80%, 25 gram, dan isi kemasan adalah data konfigurasi
yang masih harus divalidasi owner bisnis; bukan konstanta sistem.

Workbook mencocokkan Customer dengan nama yang berubah antarbulan. Sistem wajib
memakai `customer_id` tenant-scoped dan tidak boleh memakai normalized name
sebagai identity analitik.

---

## 5. Model Konfigurasi

Satu Company dapat mempunyai beberapa **Model Potensi Produk**. Minimum field:

### Header model

- `company_id`;
- nama/kode manusiawi;
- status Draft/Active/Retired;
- versi dan optimistic `master_version`;
- `effective_from` dan optional `effective_until`;
- scope semua Customer, Customer Category, atau daftar Customer tertentu;
- tanggal mulai kalkulasi;
- mode `FORWARD_ONLY` atau `BACKFILL_FROM_START_DATE`;
- timezone Company;
- actor dan immutable audit.

### Driver

- satu atau beberapa Product driver;
- base UOM snapshot dan dimensi UOM yang kompatibel;
- faktor kontribusi/yield, misalnya `0,8`;
- denominator unit/porsi, misalnya `0,025 kg` per porsi;
- aturan agregasi bila beberapa Product driver dipakai.

Beberapa SKU Daging Kebab dapat masuk model yang sama, tetapi semuanya harus
dikonversi ke dimensi base UOM yang kompatibel sebelum dijumlahkan.

### Target

- Product target;
- kebutuhan target per unit/porsi driver;
- base UOM snapshot;
- UOM laporan;
- precision dan rounding display;
- status aktif;
- urutan display.

Engine tidak menerima expression SQL/JavaScript bebas dari user. UI bisnis
dikompilasi menjadi rasio numerik yang divalidasi server agar aman, konsisten,
dan mudah diaudit.

---

## 6. Kontrak Kalkulasi

### Dataset sumber

- hanya Sale `POSTED` milik Company dan Customer reguler;
- Draft/Canceled/failed/offline nonterminal tidak dihitung;
- quantity memakai immutable conversion snapshot transaksi, bukan master UOM
  terbaru;
- tanggal analitik memakai `transaction_date` efektif Company;
- Return `POSTED` mengurangi aktual sesuai keputusan atribusi Return yang masih
  terbuka pada bagian 12;
- Walk-In dikecualikan karena tidak memiliki holder potensi yang stabil;
- Customer inactive tetap muncul untuk periode historis jika pernah mempunyai
  transaksi valid.

### Formula canonical

```text
driver_effective_base_qty = net_driver_base_qty * yield_factor
driver_units              = driver_effective_base_qty / driver_unit_base_qty
potential_target_base_qty = driver_units * target_base_qty_per_driver_unit
actual_target_base_qty    = net posted target quantity
gap_base_qty              = max(potential - actual, 0)
surplus_base_qty          = max(actual - potential, 0)
achievement_percent       = actual / potential * 100
```

Jika `potential = 0`, achievement bernilai `NULL`, bukan error atau `0%`.
Hasil lebih dari 100% valid dan tidak dipotong.

---

## 7. Aktivasi, Backfill, dan Recalculation

Saat entitlement pertama kali dinyalakan, wizard mewajibkan:

1. memilih model aktif;
2. memilih tanggal efektif model;
3. memilih `FORWARD_ONLY` atau `BACKFILL_FROM_START_DATE`;
4. menampilkan estimasi Customer, periode, dan jumlah baris yang dihitung;
5. konfirmasi eksplisit sebelum enqueue backfill.

Backfill dan refresh berjalan sebagai job terpisah, chunked, retry-safe, dan
idempotent. Halaman hanya membaca progress/status; tidak menjalankan kalkulasi
besar secara synchronous.

- Bulan berjalan dapat direfresh incrementally.
- Sale backdated atau Return yang menyentuh periode lama menandai hanya bucket
  Customer/model/periode terkait untuk recalculation.
- Snapshot periode lama menyimpan model version yang digunakan.
- Recalculation manual wajib audited dan tidak boleh mengubah transaksi sumber.
- Feature OFF menghentikan enqueue baru dan menyembunyikan menu, tetapi tidak
  menghapus job history/snapshot.

---

## 8. UI Report

Submodul `Report > Potensi Produk` direncanakan mempunyai:

1. **Dashboard** — actual, potential, gap, achievement, dan freshness;
2. **Per Customer** — seluruh Customer dalam satu tabel dengan drill-down;
3. **Per Produk** — peluang terbesar per Product target;
4. **Tren Bulanan** — actual versus potential dan perubahan antarperiode;
5. **Model Perhitungan** — konfigurasi/version history untuk user berwenang;
6. **Riwayat Kalkulasi** — run, progress, failure, retry, dan watermark;
7. **Export Excel** — dataset sesuai filter dan permission user.

Filter minimum: Company aktif, periode, model/version, Customer, kategori
Customer, Product driver, Product target, Store jika scope Store dibuka, status
Customer, achievement, serta freshness.

---

## 9. Authority dan Tenant

Target permission key: `reports.product_potential` dengan capability terpisah:

- `VIEW` untuk laporan;
- `EXPORT` untuk export;
- `MANAGE_MODEL` untuk Draft/version model;
- `RUN_CALCULATION` untuk backfill/recalculation terkontrol.

Role baseline final masih menunggu keputusan. Rekomendasi awal:

- Company Owner/Admin: seluruh capability;
- Store Manager: VIEW sesuai scope yang disetujui;
- Finance/Accounting: VIEW/EXPORT bila laporan dibutuhkan;
- Cashier/Warehouse Admin: tidak ada baseline access.

Custom permission hanya boleh mempersempit baseline. Semua RPC/read/snapshot
wajib memvalidasi active Company dan tidak boleh mengandalkan menu tersembunyi.

---

## 10. Performance dan Penyimpanan

- Query sumber tidak dipanggil oleh POS Save/Post.
- Kalkulasi memakai worker/job dengan bounded batch dan watermark.
- Snapshot minimum bergrain Company + model version + period + Customer +
  target Product.
- Report membaca snapshot, bukan mengagregasi seluruh Sale detail setiap render.
- Source checksum/count disimpan agar exact retry menghasilkan hasil sama.
- Satu active run per Company/model/scope; duplicate enqueue mengembalikan run
  existing.
- Error satu Company/model tidak boleh menghentikan Company lain.

---

## 11. Rencana Implementasi

### Phase POT-1 — Contract dan preflight

- audit Product/UOM/Customer/Sale/Return source;
- validasi workbook coefficients dan open decisions;
- schema/config/job/snapshot preflight;
- no runtime activation.

### Phase POT-2 — Foundation dan engine

- versioned model/config/audit;
- calculation job, idempotency, tenant boundary;
- posted-sale/Base-UOM reader;
- unit, cross-tenant, retry, backdate, dan return tests.

### Phase POT-3 — Model management

- guarded composed RPC;
- Backoffice model editor;
- activation wizard, date/mode, estimate, and job progress;
- feature remains default OFF.

### Phase POT-4 — Report workspace

- Dashboard, Customer/Product table, trend, drill-down, freshness;
- permission-aware module navigation;
- no operational action from analytics.

### Phase POT-5 — Export dan controlled UAT

- permission-aware Excel export;
- optional historical import only if specifically approved;
- compare selected Customer/month against workbook;
- load, retry, feature OFF/ON, backdated Sale, Return, and two-Company UAT.

Setiap phase memerlukan preflight, additive migration bila relevan, postflight,
behavioral test, compatibility note, dan manual smoke. Feature baru dapat
ditandai operational hanya setelah POT-5 lulus pada Company pilot.

---

## 12. Keputusan yang Masih Terbuka

Sebelum POT-1 implementation, user/business owner perlu memutuskan:

1. arti persis faktor yield `80%` dan porsi `25 gram`;
2. Product/SKU mana yang menjadi driver Daging Kebab dan Burger;
3. apakah Return mengurangi bulan Sale asal atau bulan Return diposting;
4. apakah formula berlaku semua Store atau dapat berbeda per Store;
5. baseline role VIEW/EXPORT/MANAGE/RUN;
6. apakah period snapshot dapat dibekukan atau selalu recalculable;
7. apakah transaksi historis sebelum go-live cukup dari system history atau
   membutuhkan import khusus;
8. apakah Customer tanpa transaksi driver tetap ditampilkan sebagai zero/no-data;
9. apakah jumlah gerobak hanya filter/dimensi atau ikut menjadi driver formula.

Tidak satu pun keputusan terbuka boleh ditebak di migration/runtime.

---

## 13. Acceptance Criteria Akhir

1. Fitur OFF tidak memunculkan menu, menjalankan job, atau mengubah behavior
   transaksi.
2. Feature ON menghasilkan parity dengan sample workbook yang disetujui.
3. Actual hanya berasal dari source final dengan UOM snapshot yang benar.
4. Backfill mulai dari tanggal eksplisit dan exact retry tidak menggandakan
   snapshot.
5. Perubahan model membuat version baru dan tidak menulis ulang transaksi.
6. Cross-Company read/write ditolak server.
7. Sale/Post/Return tetap sukses walaupun analytic worker gagal.
8. Export sama dengan filter/report dan hanya tersedia bagi user berizin.
9. Hasil dapat ditelusuri ke Company, model version, period, Customer, Product,
   source watermark, actor, dan calculation run.

