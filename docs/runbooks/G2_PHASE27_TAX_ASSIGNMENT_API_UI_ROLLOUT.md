# G2 Phase 27 — Tax Assignment API/UI Smoke

## Status

Database dependency `20260723040000` sudah dikonfirmasi user: migration,
postflight, dan behavioral test seluruhnya PASS.

Implementasi menambahkan:

- read API untuk Tax Rule yang aktif dan efektif sekarang;
- entitlement Sales/Purchase Tax untuk menentukan visibility input;
- guarded Category Tax assignment route;
- tombol Pajak pada tabel Category;
- default Tax Rule Sales/Purchase pada Category;
- Product inheritance dari Category;
- override Tax Product opsional yang tersimpan atomically bersama Product-UOM;
- nama Tax Rule dan rate user-facing tanpa UUID;
- Escape tetap menutup seluruh modal terkait.

Resolver, kalkulasi transaksi, Tax snapshot, posting, dan reporting tetap
disabled. Authenticated smoke kemudian dikonfirmasi aman oleh user.

## Urutan Smoke Manual

Restart Backoffice, lalu gunakan Company aktif yang sama.

### 1. State tanpa entitlement

1. buka `Master Inventory → Kategori Produk`;
2. klik ikon Pajak pada Category;
3. pastikan scope yang belum aktif menampilkan keterangan dari Pengaturan Modul,
   bukan dropdown kosong atau error;
4. tekan `Esc` dan pastikan modal tertutup;
5. buka Product dan pastikan form tetap dapat dibuka tanpa notifikasi error.

### 2. Siapkan Tax Rule

Sebagai Super Admin:

1. buka `Platform → Pengaturan Modul`;
2. aktifkan `Pajak Penjualan` dan/atau `Pajak Pembelian`;
3. buka `Finance → Aturan Pajak`;
4. buat minimal satu Tax Rule `ACTIVE` dengan periode efektif saat ini untuk
   scope yang diaktifkan.

### 3. Default Category

1. kembali ke `Master Inventory → Kategori Produk`;
2. klik ikon Pajak pada Category;
3. pilih Tax Rule berdasarkan **nama**;
4. simpan dan pastikan tabel menampilkan nama aturan pada kolom Pajak Default;
5. buka ulang modal dan pastikan pilihan tersimpan.

### 4. Inheritance dan override Product

1. buka `Inventory → Produk & Stok` lalu edit Product;
2. pastikan pilihan awal bertuliskan `Ikuti Category · <nama aturan>`;
3. simpan tanpa override dan pastikan tabel Product menampilkan Tax efektif dari
   Category;
4. edit kembali, pilih satu override Product, lalu simpan;
5. pastikan tabel menampilkan nama override tersebut;
6. kembalikan ke `Ikuti Category` dan pastikan inheritance aktif kembali.

### 5. Compatibility dan Home

Pastikan Category create/edit kode-nama-status, UOM, Warehouse, dan Product-UOM
existing tetap dapat disimpan. Tidak boleh ada UUID, `UOM-02`, atau identifier
internal sebagai label utama user.

Klik ikon hijau/nama `KGS POS` pada fast link. Tampilan harus kembali ke
launcher Home tanpa reload dan sidebar tertutup.

## Evidence Lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- route dinamis Category Tax assignment dan Tax options terdeteksi pada build;
- automated visual browser smoke tidak tersedia pada sesi agent ini;
- authenticated Tax assignment smoke dikonfirmasi aman oleh user.

## Next Safe Step

Tax assignment UI ditutup pada master boundary. Fase berikut tidak boleh
langsung mengaktifkan checkout calculation. Jalankan SELECT-only preflight
resolver/snapshot lebih dulu; prioritas canonical tetap
`Product override → Category default → no tax` secara server-side.
