# UXD-1 Navigation Authority dan Repository Hygiene Audit

**Tanggal:** 2026-08-11  
**Status:** COMPLETE — audit/contract only; UXD-2 belum diimplementasikan

## Outcome

Audit menetapkan sumber akses untuk launcher dua tingkat dan memastikan file
lokal yang besar atau sensitif tidak ikut ke Git. Tidak ada schema, data,
grant, atau runtime bisnis yang diubah pada fase ini.

## Temuan Navigation Authority

1. `backoffice/src/app/page.tsx` masih memiliki registry `navigation`, daftar
   role, dan `appModules` di Client Component. Filter hanya memakai
   `isSuperAdmin` dan `roleCode`; entitlement serta scope operasional belum
   menjadi input launcher.
2. Klik card modul langsung membuka submodul pertama. Home masih memuat hero
   sapaan dan ringkasan operasional, sehingga belum memenuhi launcher dua
   tingkat yang disetujui.
3. `Faktur Supplier` dan `Pembayaran Supplier` dimiliki dua launcher sekaligus:
   Purchase dan Finance. Ownership canonical UXD-2 ditetapkan ke Finance;
   Purchase tetap fokus Supplier Order dan Retur Pembelian.
4. Visibility halaman dan kemampuan mutation tidak identik. Catalog UXD-2
   wajib memisahkan `canView` dari capability aksi.
5. Switch Company saat ini memanggil `goHome()`. Perilaku ini benar dan wajib
   dipertahankan agar active view Company lama tidak terbawa ke Company baru.
6. Seluruh 97 Route Handler yang diaudit memiliki jalur auth/context eksplisit
   atau retirement guard; tidak ditemukan route aktif yang hanya mengandalkan
   card/menu tersembunyi sebagai security.
7. API/RPC/RLS tetap authority final. Catalog launcher tidak menggantikan
   validasi server pada setiap read/mutation.

## Ownership Modul Canonical UXD-2

| Modul | Submodul canonical |
|---|---|
| Inventory | Stock Real, Kartu Stok, Transfer, Penyesuaian, Stock Opname, Produk & UOM, Stok Awal, Minimum Stock, Master Inventory |
| Kontak | Pelanggan, Supplier, User & Akses |
| Purchase | Supplier Order, Retur Pembelian |
| Sales | Pricelist, Bundle, Approval Return Penjualan |
| Finance | Expense, Setor Kas, Selisih Setoran, Saldo Customer, Faktur Supplier, Pembayaran Supplier, Metode Pembayaran, Pajak, Kategori/COA, Jurnal |
| Platform | Perusahaan, Pengaturan Modul |
| Data Exchange | Export dan Import global sesuai catalog server |

Kasir tidak memperoleh launcher Backoffice. Granular ACL editor ala Odoo tetap
deferred; "authorized" berarti effective Company membership/role, Super Admin
boundary, feature entitlement, dan scope yang sudah ada—bukan permission model
baru.

## Contract Implementasi UXD-2

- server mengembalikan catalog serializable dengan stable module/submodule ID,
  label, description, order, `canView`, capability aksi, serta feature state;
- client memetakan stable icon key ke icon lokal dan hanya membuka View yang
  ada dalam catalog aktif;
- deep navigation/refresh atau Company switch fail-safe ke Home bila View tidak
  lagi tersedia;
- card Home hanya modul, card landing hanya submodul; hero/statistik dihapus;
- sidebar tetap fast link dan bukan sumber authorization;
- direct API denial dan cross-Company diuji terpisah dari visual visibility.

## Matrix Role Minimum

| Role | Modul yang dapat muncul |
|---|---|
| Super Admin | Semua modul termasuk Platform |
| Company Owner/Admin | Inventory, Kontak, Purchase, Sales, Finance, Platform, Data Exchange |
| Store Manager | Inventory sesuai scope, Kontak sesuai role, Purchase, Sales, Data Exchange, Pengaturan Modul read-only |
| Warehouse Admin | Inventory, Supplier pada Kontak, Data Exchange sesuai action server |
| Finance/Accounting | Finance, Inventory read-only terkait, Pelanggan/Supplier, Sales sesuai role, Data Exchange sesuai action server |
| Cashier | Tidak ada aplikasi Backoffice |

Capability aktual tetap mengikuti guard komponen/API/RPC yang lebih sempit.

## Audit Git dan Artefak

- ukuran object Git sekitar 9.8 MB; repository belum bengkak;
- local `backoffice/.next` sekitar 1.4 GB, gabungan `node_modules` sekitar
  634 MB, dan `pwa/dist` sekitar 0.8 MB; semuanya ignored;
- `.supabase/telemetry.json` dikeluarkan dari index Git tanpa menghapus copy
  lokal, lalu seluruh `/.supabase/` di-ignore;
- `/.codex/`, `/.agents/`, `/.vercel/`, coverage, test report, screenshot,
  log, temp, export user, DB dump/backup/local database di-ignore;
- `.env.*` di-ignore dengan exception untuk `**/.env.example`;
- `backoffice/.env.example` memakai placeholder, bukan config project;
- tidak ditemukan private key, service-role assignment, atau DB dump tracked;
- canonical SQL pada `supabase/migrations`, `supabase/diagnostics`,
  `supabase/tests`, dan `supabase/operations` wajib tetap tracked karena
  merupakan source code, verification, dan rollout evidence;
- fixed template seperti `backoffice/public/import_template.csv` tetap tracked.
  Export hasil user/diagnostic disimpan di `/exports`, `/tmp`, atau di luar repo.

## Evidence dan Compatibility

- read-only inspection navigation, Company switch, role constants, settings,
  server auth helper, dan seluruh Route Handler;
- tracked largest-file inventory, ignored build/cache size, serta tracked
  secret/dump filename scan;
- tidak ada aplikasi atau SQL runtime yang berubah;
- compatibility penuh untuk canonical SQL, DEX, Backoffice, dan PWA.

## Next Safe Step

Implementasikan UXD-2 berdasarkan catalog server-readable di atas, kemudian
jalankan lint/build serta authenticated role/Company smoke sebelum BRD-1.
