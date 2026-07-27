# G2 Phase 34 — Master Import & Export API/UI Rollout

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

Phase 33 sudah dikonfirmasi user: migration, 9-check postflight, dan behavioral
test seluruhnya PASS. Phase ini tidak menambah migration. Backoffice membuka
workflow CSV untuk empat master non-stock: Kategori Produk, UOM, Gudang, dan
Supplier.

Product, Product-UOM, Brand, Opening Stock, stock movement, Sales, Purchase,
dan Finance tetap tidak dapat diproses melalui halaman ini.

## Kontrak UI

Menu `Import & Export` hanya terlihat untuk Super Admin, Company Owner, dan
Company Admin. API mengulang pemeriksaan Owner/Admin dan active Company;
visibility menu bukan boundary keamanan.

Alur kerja:

1. pilih jenis master, cara pencocokan, dan tindakan;
2. unduh template atau export data existing;
3. pilih CSV maksimal 5 MB dan 5.000 baris;
4. petakan header file ke field aplikasi;
5. klik `Validasi & tampilkan preview`;
6. periksa CREATE/UPDATE/SKIP/ERROR per baris;
7. konfirmasi jumlah UPDATE secara persis;
8. simpan row valid; row error tetap terisolasi dan dapat diunduh;
9. buka kembali hasil dari Riwayat import.

ID internal hanya ditampilkan sebagai opsi teknis untuk round-trip file export.
User-facing preview memakai nama bisnis. Pencocokan berdasarkan nama menjadi
default.

## Smoke Test Manual

Restart Backoffice setelah build, login sebagai Company Owner/Admin, lalu:

1. buka launcher `Inventory` → `Import & Export`;
2. untuk tiap jenis master, unduh `Template CSV` dan pastikan nama file benar;
3. klik `Export data` dan pastikan file hanya berisi active Company;
4. isi CSV kecil berisi satu baris baru, satu existing tanpa perubahan, dan
   satu kode/nama duplikat;
5. validasi dan pastikan preview menunjukkan Data baru, Tidak berubah, dan
   Error tanpa mengubah master sebelum tombol simpan ditekan;
6. buat satu perubahan existing dan pastikan tombol simpan terkunci sampai
   checkbox jumlah UPDATE dicentang;
7. simpan lalu pastikan status `Selesai` atau `Selesai sebagian` sesuai hasil;
8. unduh baris error dan pastikan pesan user-facing ikut masuk CSV;
9. buka job dari Riwayat dan pastikan preview masih terbaca;
10. login dengan role selain Owner/Admin: menu tidak tampil dan endpoint
    menolak bila dipanggil langsung.

Gunakan data uji yang aman untuk dinonaktifkan melalui form master. Jangan
memakai menu import lama Product.

## Evidence Lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- Next build mendeteksi `/api/master/import-jobs`,
  `/api/master/import-jobs/[id]`, dan `/api/master/import-export`.

Browser visual automation tidak tersambung pada sesi implementasi, sehingga
authenticated smoke di atas belum diklaim PASS.

## Compatibility dan Forward Fix

- direct form CRUD Category/UOM/Warehouse/Supplier tidak berubah;
- legacy `/api/products/import` tidak dipakai halaman baru dan tetap
  dikarantina oleh privilege database;
- parsing file dilakukan di browser, tetapi mapping, validation, commit,
  tenant, role, version, dan audit tetap ditegakkan server/database;
- export dibatasi active Company dan role pengelola;
- migration applied Phase 30–33 tidak diedit.

## Next Safe Step

Setelah authenticated smoke PASS, tutup Phase 34. Product grouped import,
Brand, serta Opening Stock memerlukan preflight dan kontrak terpisah.
