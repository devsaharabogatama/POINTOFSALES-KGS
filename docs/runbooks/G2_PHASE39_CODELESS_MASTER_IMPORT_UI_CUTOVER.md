# G2 Phase 39 — Code-less Master Import UI Cutover

## Status

`COMPLETE`

## Outcome

Backoffice Import/Export untuk Product Category, UOM, Warehouse, dan Supplier
tidak lagi meminta atau menampilkan kode teknis:

- template create hanya berisi nama dan field bisnis;
- export update membawa `internal_id` hanya untuk mode pencocokan ID;
- mode default tetap pencocokan nama;
- preview, diff, dan error download tidak menampilkan kode sistem;
- CSV lama yang memiliki kolom `code` tetap dapat diproses otomatis sebagai
  compatibility input.

Referensi Toko pada Gudang tidak lagi meminta UUID. Template memakai
`store_name`; export menghasilkan `Nama Toko (KODE)`. Import menerima label
tersebut, nama yang unik, atau kode Toko existing. API hanya menyelesaikan
referensi ke Toko aktif milik Company aktif dan tidak pernah auto-create Toko.

## Local Evidence

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- production build mengenali route Import/Export dan Import Job;
- Phase-38 migration, 7-check postflight, dan behavioral test dikonfirmasi user
  seluruhnya PASS.
- authenticated Phase-39 smoke dikonfirmasi user aman pada 2026-07-27.

## Manual Smoke

Restart Backoffice, login sebagai Company Owner/Admin, lalu:

1. buka `Inventory` → `Import & Export`;
2. unduh keempat `Template CSV`;
3. pastikan tidak ada `code`, `category_code`, `uom_code`, `warehouse_code`,
   `supplier_code`, atau `internal_id` pada template create;
4. isi dan preview satu Category, UOM, Gudang Central, serta Supplier baru;
5. pastikan preview hanya menampilkan nama dan perubahan bisnis;
6. simpan dan pastikan kode otomatis tidak diminta;
7. untuk Gudang tipe `STORE`, isi `store_name` memakai label hasil export,
   nama Toko unik, atau kode Toko; pastikan Toko terselesaikan benar;
8. isi Toko yang tidak ada dan pastikan row menjadi error tanpa membuat Toko;
9. unduh `Export data`; pastikan kode teknis tidak ada, sedangkan
   `internal_id` tersedia untuk round-trip update;
10. pilih mode `Cocokkan ID internal`, import hasil export, dan pastikan update
    existing berhasil setelah konfirmasi;
11. opsional: import satu CSV lama berkode dan pastikan tetap kompatibel.

## Compatibility

- direct form CRUD tidak berubah;
- UUID tetap canonical dan hanya ditampilkan pada export update;
- technical code stable dari preview hingga commit;
- job history, exact UPDATE confirmation, partial row error, audit,
  concurrency/version guard, dan retry idempotency tetap aktif;
- tidak ada Product, stock, Opening Stock, checkout, Purchase, atau Finance
  posting yang dibuka.

## Next Safe Step

Setelah smoke PASS, perluas katalog import secara additive menurut
`docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`: master sederhana lebih dulu, lalu
Product/Pricelist/Payment Method sebagai atomic group. Jangan mengubah migration
Phase 30–38 yang sudah applied.
