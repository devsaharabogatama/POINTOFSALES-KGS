# Purchase RO/PO List Parity Rollout

Target hanya isolated Development `fkywtxucmyjvpwdiqpix`. Production dan staging
existing tidak disentuh.

## Dampak

- Menyamakan shell daftar Purchase dengan Quotation/Sales Order: tab RO/PO,
  pencarian, status, Supplier, basis tanggal, rentang tanggal, dan tabel.
- Menambahkan projection read-only status/link Faktur Supplier dari immutable
  allocation `supplier_order_line_id`.
- Tidak mengubah RO/PO, Receipt, Return, Stock, FIFO, AP, Supplier Invoice,
  Payment, Journal, scheduler 23:59, POS, permission, atau data historis.

## Urutan SQL

1. `supabase/diagnostics/purchase_order_list_parity_preflight.sql`
2. `supabase/migrations/20260914160000_purchase_order_list_parity_read_model.sql`
3. `supabase/tests/purchase_order_list_parity_behavior.sql`
4. `supabase/diagnostics/purchase_order_list_parity_postflight.sql`

Jalankan setiap file penuh dan hentikan pada `BLOCKER`, `FAIL`, atau SQL error.

## Smoke lokal

1. Restart Backoffice lokal lalu buka Purchase > Supplier Order.
2. Pastikan Request Order dan Purchase Order berupa tabel, bukan kartu terpisah.
3. Uji pencarian, status, Supplier, tanggal, dan rentang tanggal.
4. Pastikan PO tanpa Receipt `Belum siap`, PO dengan Receipt eligible `Siap dibuat`,
   Draft/HOLD/partial/fully billed mengikuti Faktur Supplier yang benar.
   PO yang Supplier-nya masih belum ditentukan harus tetap `Belum siap` sampai
   assignment Supplier canonical selesai.
5. Klik status Bill dengan akses Finance: satu Bill membuka detail, beberapa Bill
   membuka daftar terfokus. Tanpa akses Finance badge tetap read-only.
6. Pastikan konfirmasi/cancel RO/PO dan export PO existing tetap bekerja.

## Rollback / forward-fix

Migration mengganti wrapper read RPC tanpa data backfill. Setelah migration
terpasang, jangan menghapus ledger atau mengembalikan nama fungsi manual.
Jika ditemukan masalah, buat forward-fix yang mengganti hanya definisi public
reader/classifier. Client dapat di-rollback mandiri ke list lama karena mutation
contract tidak berubah.
