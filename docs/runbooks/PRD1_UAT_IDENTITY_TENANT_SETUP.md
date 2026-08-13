# PRD-1 UAT Identity dan Two-Company Setup

**Status:** MANUAL SETUP READY  
**Tujuan:** membuat fixture login/tenant untuk closing regression tanpa menaruh
password, email pribadi, UUID, atau service-role key di repository.

## Hasil Preflight Live

Preflight PRD-1 user-reported tanpa `BLOCKER`. Seluruh Stock, FIFO, Movement,
Finance journal, Invoice/Surat Jalan, Return, browser write boundary, import,
dan Offline queue PASS. Setup yang tersisa:

- satu Company aktif kedua;
- role `COMPANY_OWNER`, `COMPANY_ADMIN`, `FINANCE`, `ACCOUNTING`,
  `WAREHOUSE_ADMIN`, dan `CASHIER`;
- satu user biasa dengan membership aktif pada dua Company untuk menguji
  selector Company. `SUPER_ADMIN` global tidak menggantikan test ini.

Finance `HOLD` 29 row/9 contract tetap controlled deferred dan tidak diproses
oleh setup ini.

## Urutan Canonical

1. Login Backoffice sebagai Super Admin.
2. Buka `Platform -> Perusahaan -> Perusahaan baru`.
3. Buat Company UAT kedua beserta akun Owner memakai email UAT dan password
   sementara unik. Jangan memakai akun produksi atau mencatat password di Git.
4. Masuk/switch ke Company utama. Dari `Kontak -> Tim & Akses`, buat akun:
   Company Admin, Finance, Accounting, Admin Gudang, dan Kasir. Store Manager
   existing boleh digunakan bila benar-benar aktif.
5. Kasir wajib dipilihkan Toko aktif. Akun non-Kasir hanya diberi Toko bila
   scope pekerjaannya memang store-specific.
6. Switch ke Company UAT kedua. Pastikan ada Toko aktif, Terminal aktif, dan
   satu Gudang aktif bertanda sumber penjualan. Tenant registration membuat
   Owner/Toko/Gudang awal, tetapi Terminal dan flag sumber penjualan tetap harus
   diverifikasi melalui konfigurasi canonical.
7. Buat minimal Product beserta base/sales UOM, Customer, Payment Method, dan
   opening stock yang diperlukan untuk E2E. Jangan menyalin UUID/data tenant A.
8. Buat Kasir Company kedua dan assign ke Toko yang memiliki Terminal.
9. Untuk test selector user biasa multi-Company, tambahkan satu akun UAT
   non-super ke kedua Company melalui `Tim & Akses -> Tambah akses akun
   existing`. Action ini tersedia setelah rollout PRD phase 3 pada
   `PRD1_EXISTING_USER_MULTI_COMPANY_ROLLOUT.md`. Jangan melakukan INSERT
   membership manual.

## Konvensi Akun UAT

Gunakan mailbox/domain test milik project. Nama yang disarankan hanya label:

- `UAT Owner B`;
- `UAT Admin A`;
- `UAT Finance A`;
- `UAT Accounting A`;
- `UAT Warehouse A`;
- `UAT Store Manager A`;
- `UAT Cashier A` dan `UAT Cashier B`;
- `UAT Multi Company`.

Setiap akun memakai password unik minimal delapan karakter dan harus diganti
atau dihapus setelah UAT. Jangan memakai satu password bersama.

## Verifikasi Database

Setelah setup, jalankan seluruh file:

`supabase/diagnostics/prd_phase2_uat_identity_tenant_postflight.sql`

Interpretasi:

- `BLOCKER` wajib nol;
- `SETUP` menunjukkan fixture yang belum lengkap;
- seluruh pemeriksaan role, Company, Cashier, operational scope, dan minimum
  master harus `PASS` sebelum matrix login dimulai.

## Matrix Login Setelah Postflight PASS

Untuk setiap role, cek Home, Fast Link, direct route, API, dan RPC. Menu yang
tidak dimiliki tidak boleh muncul dan direct URL/API tetap harus 403/ditolak.
Kemudian switch tenant dengan `UAT Multi Company` dan pastikan list/detail,
Stock, Customer, Product, Sale, Finance, dokumen, Export/Import, dan cache tenant
lama hilang. Percobaan ID tenant lain harus ditolak server.

## Compatibility dan Rollback

- Setup menggunakan flow akun/Company existing; tidak ada migration schema.
- Company utama dan histori tidak diubah oleh file diagnostic.
- Bila satu pembuatan akun gagal, jangan mengulang dengan email berbeda sebelum
  memastikan Auth user/profile/membership hasil percobaan tidak tertinggal.
- Cleanup setelah UAT dilakukan lewat workflow admin terkontrol; jangan DELETE
  Auth/Profile/Membership langsung dari browser atau SQL ad-hoc.
