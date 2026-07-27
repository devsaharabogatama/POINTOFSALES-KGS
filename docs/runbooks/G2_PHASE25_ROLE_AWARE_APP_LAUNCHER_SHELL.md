# G2 Phase 25 — Role-aware App Launcher dan Fast-link Shell

## Outcome

Halaman awal Backoffice menjadi launcher modul bergaya ERP/Odoo. Modul besar
mengumpulkan shortcut pekerjaan terkait dan hanya muncul bila role aktif
memiliki sedikitnya satu subfitur yang tersedia. Sidebar lama diubah menjadi
fast-link overlay yang dapat ditampilkan/disembunyikan, memiliki scroll sendiri,
dan tidak mengubah lebar halaman utama.

## Pengelompokan Awal

- **Inventory:** Produk & Stok, Master Inventory;
- **Kontak:** Pelanggan, Supplier, User & Akses;
- **Sales:** Pricelist; Promo dan Bundling baru ditambahkan setelah contract dan
  implementation gate-nya dibuka;
- **Finance:** Metode Pembayaran, Aturan Pajak, Kategori & COA, Jurnal Keuangan;
- **Platform:** Perusahaan dan Pengaturan Modul, khusus Super Admin.

Supplier sengaja berada di Kontak, bukan Inventory: gudang mengelola stock,
sedangkan Supplier adalah identitas pihak eksternal. `User & Akses` hanya
tersedia untuk Super Admin, Company Owner, dan Company Admin. Visibility
Pelanggan/Supplier tetap mengikuti role canonical masing-masing.

Metode Pembayaran dan Pajak sengaja berada di Finance karena konfigurasi
tersebut berhubungan dengan settlement, account, reconciliation, dan posting.
Sales difokuskan pada cara menjual: Pricelist sekarang, kemudian Promo dan
Bundling setelah benar-benar diimplementasikan. Launcher tidak menampilkan
placeholder mati untuk modul yang belum tersedia.

## Access Boundary

- visibility launcher/sidebar mengikuti role canonical pada Company aktif;
- Super Admin melihat seluruh aplikasi;
- launcher dan sidebar hanya UX; API/RPC/RLS tetap otoritas keamanan;
- permission granular per-user/submenu belum dibuat dan tidak boleh ditiru
  hanya dengan client-side hiding;
- granular permission memerlukan schema capability, assignment tenant/user,
  guarded RPC, audit, server middleware/API enforcement, preflight, migration,
  postflight, dan behavioral test pada fase terpisah.

## Perubahan UI

- tombol menu selalu tersedia pada header desktop/mobile;
- sidebar floating di atas halaman dan tidak mendorong konten;
- nav memakai `h-dvh`, `min-h-0`, dan `overflow-y-auto`, sehingga daftar panjang
  dapat di-scroll tanpa menggeser halaman utama;
- memilih fast link otomatis menutup sidebar;
- halaman depan menampilkan module card dan submodule quick links;
- role tanpa aplikasi Backoffice memperoleh empty state yang jelas.

## Evidence Lokal

```text
npm run lint   PASS
npm run build  PASS
```

Pemeriksaan visual authenticated tetap memerlukan restart dan smoke oleh user.

## Manual Smoke

1. restart Backoffice dan login sebagai Super Admin;
2. pastikan halaman awal menampilkan Inventory, Sales, Finance, Tim, Platform;
3. klik hamburger pada monitor kecil dan desktop;
4. pastikan sidebar muncul di atas halaman, konten utama tidak bergeser, dan
   daftar link bisa di-scroll sampai item terakhir;
5. pilih link dan pastikan sidebar menutup otomatis;
6. uji Company Owner/Admin, Store Manager, Warehouse Admin, Finance,
   Accounting, dan Cashier;
7. pastikan setiap role hanya melihat module/submodule sesuai role canonical;
8. pastikan membuka URL/API tanpa hak tetap ditolak server-side;
9. smoke seluruh menu existing.

## Next Safe Step

Setelah shell smoke lulus, lanjutkan Tax Product/Category assignment yang sudah
menunggu. Permission granular per-user/submodule harus diawali diagnostic dan
access-matrix design terpisah agar tidak mengacaukan gate Tax.
