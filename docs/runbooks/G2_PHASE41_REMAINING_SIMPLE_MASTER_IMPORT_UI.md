# G2 Phase 41 — Remaining Simple Master Import UI

## Status

`LOCAL READY — AUTHENTICATED SMOKE TEST PENDING`

## Outcome

Backoffice Import & Export sekarang mendukung tiga tipe database Phase 40:

- Kategori Pelanggan;
- Chart of Account;
- Kategori Transaksi.

Template create mengikuti kontrak CSV fixed. Export menyertakan `internal_id`
untuk update yang aman. UUID tetap identitas internal dan tidak perlu dibuat
atau dihafalkan user.

## Kontrak CSV

### Kategori Pelanggan

```text
name,is_active
```

### Chart of Account

```text
code,name,account_type,normal_balance,parent_account_code,system_function_key,is_postable,allow_manual_posting,allow_reconciliation,is_active
```

`code` tetap ditampilkan karena merupakan kode akun bisnis. Akun induk harus
sudah ada atau berada pada baris sebelumnya di file.

### Kategori Transaksi

```text
name,system_key,description,is_active
```

`system_key` harus menunjuk System Event aktif yang sudah tersedia.

## Boundary

- kategori pelanggan sistem, COA sistem, dan kategori transaksi wajib ikut
  tersedia pada export sebagai referensi;
- baris sistem tersebut export-only dan ditolak bila dicoba diubah lewat
  import;
- setiap mutation tetap melalui validator dan guarded RPC database Phase 40;
- empat tipe lama tetap kompatibel;
- Product, Product-UOM, Pricelist, Payment Method, Opening Stock, transaksi,
  stock movement, dan jurnal tidak dibuka lewat UI ini.

## Evidence Lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- Next.js production build mencakup route dinamis
  `/api/master/import-export`, `/api/master/import-jobs`, dan
  `/api/master/import-jobs/[id]`.

## Smoke Test Manual

Restart Backoffice lalu login sebagai Company Owner/Admin:

1. buka **Import & Export**;
2. pilih masing-masing dari tiga tipe baru dan unduh template;
3. pastikan header template persis seperti kontrak di atas;
4. unduh export dan pastikan nama user-facing tampil, sedangkan UUID hanya ada
   pada kolom `internal_id`;
5. buat satu Kategori Pelanggan custom melalui preview lalu commit;
6. buat satu COA parent dan satu child; parent diletakkan lebih dahulu;
7. buat satu Kategori Transaksi custom dengan `system_key` valid;
8. ekspor hasilnya, lalu uji update memakai mode **ID internal dari hasil
   export**;
9. coba masukkan satu baris bawaan sistem dan pastikan preview menolaknya tanpa
   menghalangi baris custom yang valid;
10. ulangi satu smoke ringan untuk salah satu dari empat tipe lama.

Expected: tidak ada notification schema-cache/API error; preview menjelaskan
baris create/update/error; commit hanya menyimpan baris valid.

## Compatibility dan Next Safe Step

Phase 40 database dan Phase 38 compatibility regression sudah dikonfirmasi
PASS oleh user. Setelah smoke di atas diterima, tandai Phase 41 `COMPLETE`.
Ekspansi master grouped wajib memakai gate terpisah karena mutation-nya atomic.

