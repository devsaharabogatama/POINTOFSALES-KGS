# Catatan Master Data Sales dan Pricelist KGS

**Status:** Active Design Draft 0.4 — reusable Customer assignment telah dikonfirmasi
**Tanggal:** 2026-07-22
**Scope aktif:** Pricelist global/customer, quantity tier, diskon manual POS, dan hubungan promo dengan Bundle

---

## 1. Tujuan dan Kepemilikan Modul

Pricelist berada pada:

```text
Sales
└── Master Data
    └── Pricelist
```

Pricelist bukan bagian dari Inventory. Produk hanya menyimpan harga jual dasar per UOM sebagai fallback. POS mengonsumsi hasil pricing resolver milik Sales dan tidak menghitung rule harga sendiri di browser.

Semua master dan rule wajib scoped oleh `company_id`. Data dan rule satu company tidak boleh dibaca atau digunakan company lain.

---

## 2. Hierarki Harga

Resolver bercabang berdasarkan keberadaan Pricelist Customer Eksklusif:

```text
Jika customer memiliki Pricelist Eksklusif aktif:
1. Rule Pricelist Customer Eksklusif
2. Harga jual dasar Produk-UOM

Jika customer tidak memiliki Pricelist Eksklusif:
1. Rule/tier Pricelist Global
2. Harga jual dasar Produk-UOM
```

Pricelist Global tidak ikut diterapkan ketika customer memiliki Pricelist Eksklusif. Jika produk tidak ditemukan pada Pricelist Eksklusif, resolver langsung memakai harga dasar Produk-UOM dan tidak jatuh ke tier global.

Hierarki tersebut berlaku pada mode pemilihan otomatis (`AUTO`). Bila Cashier secara eksplisit memilih Pricelist Global yang eligible, transaksi memakai cabang Global untuk seluruh cart dan menyimpan `pricing_selection_source = CASHIER_OVERRIDE`; sistem tidak mencampur rule Customer Eksklusif dan Global dalam satu resolusi otomatis.

Satu company memiliki tepat satu Pricelist Global default aktif. Setiap Customer
reguler dapat menunjuk maksimal satu Pricelist Eksklusif aktif melalui
`customers.default_pricelist_id`; banyak Customer boleh menunjuk header yang
sama. Pricelist lain tetap boleh disimpan sebagai template/periode alternatif
dan baru berlaku bagi Customer setelah dipilih pada master Customer.

---

## 3. Master Pricelist

Header minimum yang disarankan:

```text
id
company_id
code
name
scope: GLOBAL / CUSTOMER
priority
is_default
applies_all_stores
valid_from nullable
valid_until nullable
is_active
notes nullable
created_at/by
updated_at/by
```

Aturan:

- Kode unik per company.
- Pricelist `CUSTOMER` merupakan template harga reusable dan tidak dimiliki oleh
  satu Customer tertentu.
- Assignment dilakukan dari `customers.default_pricelist_id`; banyak Customer
  boleh menunjuk Pricelist `CUSTOMER` yang sama.
- Satu Customer hanya dapat menunjuk satu Pricelist Eksklusif aktif pada satu
  waktu.
- Walk-In tidak boleh menunjuk Pricelist `CUSTOMER` dan selalu memakai Global
  default yang eligible.
- Satu company hanya dapat memiliki satu Pricelist Global default aktif.
- Pricelist lain boleh tetap aktif/tersimpan untuk periode berbeda; overlap diselesaikan dengan priority tertinggi.
- Pricelist Global dapat berlaku untuk seluruh store pada company (`applies_all_stores = true`) atau hanya store tertentu melalui assignment terpisah.
- Store assignment wajib menunjuk store pada company yang sama dengan Pricelist.
- Tanggal berlaku bersifat opsional. Pricelist tanpa tanggal berlaku selama aktif.
- Pricelist expired tidak dipilih untuk transaksi baru, tetapi snapshot transaksi lama tidak berubah.
- Penghapusan pricelist yang sudah digunakan transaksi dilarang; gunakan inactive/archive.

---

## 4. Rule dan Quantity Tier

Line minimum yang disarankan:

```text
id
company_id
pricelist_id
product_id
product_uom_id
min_qty
tier_qty_basis: SALES_UOM / BASE_UOM_EQUIVALENT
pricing_method: FIXED_PRICE / DISCOUNT_AMOUNT / DISCOUNT_PERCENT
fixed_unit_price nullable
discount_amount_per_unit nullable
discount_percent nullable
valid_from nullable
valid_until nullable
is_active
```

Contoh tier:

```text
Harga dasar Produk A: Rp10.000/PCS

min_qty 1  -> fallback/base Rp10.000
min_qty 5  -> DISCOUNT_AMOUNT Rp500  -> Rp9.500/PCS
min_qty 10 -> DISCOUNT_AMOUNT Rp1.000 -> Rp9.000/PCS
```

Resolver memilih tier dengan `min_qty` terbesar yang masih kurang dari atau sama dengan quantity hasil basis rule.

`tier_qty_basis` dikonfigurasi per rule produk karena karakter tiap produk berbeda:

- `SALES_UOM`: batas dihitung dari quantity UOM yang sedang dijual;
- `BASE_UOM_EQUIVALENT`: quantity penjualan dikonversi lebih dulu ke base UOM. Contoh 1 DUS = 12 PACK dapat memenuhi tier minimum 10 PACK.

Quantity tier hanya berlaku pada Pricelist Global. Pricelist Customer Eksklusif tidak menerima/menumpuk tier global. Untuk `DISCOUNT_AMOUNT`, nominal merupakan potongan **per unit** sesuai basis harga/UOM rule, bukan potongan total line.

---

## 5. Pricelist Customer

- Customer dapat memiliki harga khusus melalui pricelist `CUSTOMER`.
- Pemilihan Pricelist Customer dilakukan pada menu/form Customer, bukan pada
  form header Pricelist.
- Satu Pricelist Customer dapat digunakan oleh banyak Customer; perubahan rule
  berlaku pada transaksi baru seluruh Customer yang menunjuknya.
- Pricelist Customer bersifat eksklusif: ketika aktif, seluruh rule/tier Pricelist Global dilewati.
- Saat customer dipilih pada cart, POS meminta server menghitung ulang seluruh line.
- Saat customer dihapus/diganti, server menghitung ulang harga menggunakan hierarchy yang baru.
- Perubahan harus terlihat oleh Cashier sebelum checkout.
- Transaksi menyimpan customer, pricelist, rule, base price, dan final resolved price sebagai snapshot.
- Produk yang tidak memiliki rule pada Pricelist Customer langsung memakai harga dasar Produk-UOM.
- Customer tanpa Pricelist Eksklusif memakai Pricelist Global; jika tidak ada rule yang cocok, memakai harga dasar Produk-UOM.

### 5.1 Pemilihan Pricelist oleh Cashier

- Resolver otomatis tetap menentukan default berdasarkan customer, store, tanggal berlaku, dan priority.
- Cashier dapat memilih Pricelist lain secara opsional bila ingin mengganti hasil default.
- Pilihan hanya menampilkan Pricelist aktif yang eligible untuk company/store saat itu.
- Untuk customer dengan Pricelist Eksklusif, pilihan eligible mencakup pricelist customer tersebut dan Pricelist Global yang berlaku pada store. Pricelist eksklusif milik customer lain tidak boleh dipilih.
- Pemilihan eksplisit Cashier mengalahkan resolver otomatis untuk transaksi itu dan memicu perhitungan ulang seluruh cart.
- Transaksi menyimpan `pricing_selection_source: AUTO / CASHIER_OVERRIDE`, Pricelist terpilih, actor, dan waktu override.

---

## 6. Diskon Manual POS

Keputusan:

- Cashier dapat memberikan diskon per line produk dan diskon pada total transaksi.
- Diskon mendukung `AMOUNT` dan `PERCENT`.
- Tidak ada limit diskon per role/store pada scope awal.
- Diskon manual boleh diterapkan di atas harga Pricelist Global maupun Pricelist Customer Eksklusif.
- Actor, waktu, tipe, nilai input, dan nominal hasil perhitungan wajib disimpan.
- Diskon tidak boleh membuat nilai line atau grand total menjadi negatif.
- Diskon total transaksi harus dialokasikan kembali secara proporsional ke line untuk refund, laporan, dan kebutuhan Finance.

Urutan kalkulasi awal:

```text
Harga dasar Produk-UOM
-> harga hasil Pricelist
-> diskon manual per line
-> subtotal seluruh line
-> diskon manual transaksi dan alokasi ke line
-> grand total sebelum rounding
-> rounding opsional POS
-> grand total final
```

Diskon manual tidak mengubah Master Produk maupun Master Pricelist.

Harga POS pada scope awal bersifat tax-inclusive. Pemisahan tax base/tax amount dan mapping jurnal dibahas saat modul Tax/Finance difinalkan tanpa mengubah snapshot grand total yang dibayar customer.

---

## 7. Snapshot Transaksi

Sales detail minimum menyimpan:

```text
base_unit_price
pricelist_id nullable
pricelist_line_id nullable
resolved_unit_price
line_discount_type nullable
line_discount_input nullable
line_discount_amount
allocated_order_discount_amount
unit_price_after_discount
line_total
pricing_resolved_at
```

Snapshot diperlukan agar perubahan Produk, Pricelist, customer, atau rule pada masa depan tidak mengubah histori, refund, dan laporan lama.

---

## 8. Promo Menggunakan Bundle

Promo seperti “beli 2 gratis 1” tidak membutuhkan promo engine terpisah pada scope awal. Promo dibuat sebagai produk `BUNDLE`.

Contoh:

```text
Bundle: Produk A 2+1
Komponen stock: Produk A x 3 PCS
Harga jual bundle: setara harga 2 PCS Produk A
```

Saat bundle terjual:

- stok yang berkurang adalah seluruh 3 PCS komponen;
- HPP berasal dari seluruh 3 PCS sesuai FIFO/batch aktual;
- pendapatan menggunakan harga jual bundle;
- komposisi dan harga bundle disimpan sebagai snapshot transaksi;
- bundle tidak boleh berisi bundle lain.

Bundle mempunyai SKU khusus dan harus dipilih atau di-scan secara eksplisit oleh Cashier. POS tidak otomatis mengubah line produk biasa menjadi Bundle dan tidak otomatis menawarkan promo Bundle pada scope awal.

---

## 9. Guardrail Multi-Tenant dan Server

- Semua query dan mutation Pricing wajib memvalidasi company/store/customer/product/UOM.
- Pricing resolver dijalankan server-side/RPC transactional, bukan dipercaya dari harga yang dikirim browser.
- Checkout melakukan resolve/validate ulang tepat sebelum posting.
- Cashier tidak boleh mengirim `resolved_unit_price` arbitrer tanpa rule/audit yang valid.
- Pengecualian price override hanya boleh ada bila Terminal/POS mengaktifkan
  kebijakan khusus yang divalidasi server. Override eksplisit mengalahkan hasil
  Pricelist pada line tersebut, tetapi wajib menyimpan hasil resolver asal dan
  snapshot audit; detail ada pada `POS_TERMINAL_PRICE_OVERRIDE_PLAN.md`.
- Service-role key tidak boleh berada pada frontend.
- Rule inactive/expired tidak berlaku pada transaksi baru.
- Company Admin dan Store Manager dapat CRUD/activate Pricelist hanya untuk company yang di-assign kepada user melalui membership aktif.

---

## 10. Keputusan Terbuka

Tidak ada keputusan business Pricelist yang masih terbuka pada scope saat ini. Detail jurnal diskon/pajak tetap dibahas pada fase Finance.

Aturan Draft/Hold final:

- ketika Draft dilanjutkan, server selalu resolve ulang harga dan promo aktif;
- UI menampilkan snapshot lama, harga terbaru, dan selisih sebelum checkout;
- jika harga terbaru naik, Cashier boleh mempertahankan final price lama dengan diskon manual sebesar selisih;
- resolver price terbaru tetap disimpan bersama snapshot lama, diskon manual, actor, dan waktu untuk audit;
- tindakan tersebut tidak mengaktifkan kembali atau mengubah Pricelist lama;
- jika harga terbaru turun, POS menggunakan harga terbaru yang lebih murah dan Cashier tidak mempertahankan harga snapshot lama yang lebih mahal;
- diskon penjaga harga Draft tidak memerlukan approval pada scope awal karena diskon manual Cashier memang dibebaskan.

---

## 11. Instruksi untuk AI Agent

- Jangan menaruh quantity-tier/customer pricing sebagai kolom tambahan acak pada Produk.
- Jangan mengubah harga dasar Produk ketika Pricelist atau diskon manual dipakai.
- Jangan menghitung harga final hanya di client.
- Jangan kehilangan snapshot rule dan discount allocation pada transaksi.
- Jangan membuat promo engine otomatis sebelum keputusan Bundle UX dikonfirmasi.
- Jangan mencampur Pricelist penjualan dengan harga beli Produk-Supplier.

---

## 12. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-15 | Pricelist berada di Sales Master Data; harga Produk-UOM menjadi fallback | APPROVED |
| 2026-07-15 | Customer Eksklusif -> product base; tanpa customer exclusive memakai Global -> product base | APPROVED |
| 2026-07-15 | Pricelist mendukung quantity tier | APPROVED |
| 2026-07-22 | Header Pricelist Customer reusable; banyak Customer boleh memilih Pricelist yang sama melalui `customers.default_pricelist_id` pada menu Customer | APPROVED |
| 2026-07-15 | Diskon line dan transaksi mendukung nominal/persentase tanpa limit role awal | APPROVED |
| 2026-07-15 | Promo 2+1 dimodelkan sebagai Bundle dengan seluruh komponen stock dan harga bundle manual | APPROVED |
| 2026-07-15 | Satu Global default per company; priority menentukan kandidat Global yang eligible | APPROVED; Customer assignment diperbarui 2026-07-22 |
| 2026-07-15 | Tier hanya Global dan basis SALES_UOM/BASE_UOM_EQUIVALENT configurable per rule produk | APPROVED |
| 2026-07-15 | DISCOUNT_AMOUNT tier merupakan potongan per unit | APPROVED |
| 2026-07-15 | Bundle promo memakai SKU khusus dan dipilih/scan eksplisit tanpa auto-convert | APPROVED |
| 2026-07-15 | Company Admin dan Store Manager mengelola Pricelist sesuai active company assignment | APPROVED |
| 2026-07-15 | Pricelist Global dapat company-wide atau dibatasi ke store tertentu dalam company yang sama | APPROVED |
| 2026-07-15 | Diskon manual boleh ditumpuk di atas Global maupun Customer Exclusive price | APPROVED |
| 2026-07-15 | Pelanggan umum memakai default Global; Cashier dapat memilih Pricelist eligible lain secara opsional | APPROVED |
| 2026-07-15 | Harga POS tax-inclusive; pemisahan pajak dibahas saat fase Tax/Finance | APPROVED |
| 2026-07-16 | Draft selalu resolve harga terbaru; Cashier dapat menjaga harga lama yang lebih murah melalui diskon manual ter-audit | APPROVED |
| 2026-07-16 | Jika harga terbaru turun, POS wajib memakai harga terbaru dan tidak mempertahankan snapshot lama yang lebih mahal | APPROVED |
| 2026-08-25 | Terminal/POS dapat mengizinkan price override bagi seluruh Cashier; tanpa override tetap memakai Pricelist canonical, sedangkan override eksplisit mengalahkan semua Pricelist hanya pada line terkait | APPROVED; NOT IMPLEMENTED |
