# G3 Phase 3 — Stock Real / Saat Ini API/UI

## Status

`READY FOR AUTHENTICATED SMOKE TEST`

Fase ini mengikuti struktur modul target `PRODUCT_STOCK_MASTERDATA_SPEC.md`.
Tidak ada migration atau mutation baru. `product_stocks` tetap materialized
balance dan `stock_movements` tetap ledger append-only.

## Scope

Halaman `Inventory > Stock Real` menampilkan per pasangan Product–Gudang:

- Product, SKU, kategori, Gudang, dan Base UOM;
- `On Hand` dari `product_stocks`;
- `Reserved` ditandai belum aktif;
- `Available = On Hand` sampai reservation contract G4 dibuka;
- threshold Minimum Stock dan preview kondisi;
- nilai persediaan dari sisa FIFO layer;
- tipe dan waktu movement terakhir.

Filter tersedia untuk pencarian, Gudang, dan stok menipis. Halaman ini read-only.

## Explicit deferred boundary

- `Stock Movement / Kartu Stok` adalah langkah G3 berikutnya;
- reservation/available final, badge Cashier, notification inbox, dan aksi
  Stock Request berada di G4;
- Request Order, Supplier Order, dan Goods Receipt berada di G5;
- tidak ada push notification, scheduler, auto request, atau auto order;
- Product tanpa dokumen stok posted belum mempunyai baris Stock Real.

## Smoke test

1. Restart Backoffice dan buka `Inventory > Stock Real`.
2. Pastikan Opening Stock yang sudah `POSTED` muncul sebagai satu saldo
   Product–Gudang.
3. Cocokkan On Hand dengan quantity Opening Stock dan Base UOM-nya.
4. Pastikan Available sama dengan On Hand dan Reserved tertulis `Belum aktif`.
5. Cocokkan nilai FIFO dengan `quantity remaining × HPP`.
6. Pastikan movement terakhir adalah `OPENING_BALANCE`.
7. Atur Minimum Stock di atas On Hand lalu refresh Stock Real; baris harus
   terdeteksi menipis.
8. Uji filter Gudang, pencarian, dan `Hanya stok menipis`.
9. Login role lain dan pastikan RLS/scope tetap membatasi data Company aktif.

## Local evidence

- `npm.cmd run lint`
- `npm.cmd run build`
- `git diff --check`
