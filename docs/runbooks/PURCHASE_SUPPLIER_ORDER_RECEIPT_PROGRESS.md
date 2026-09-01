# Supplier Order Receipt Progress

## Status

`LOCAL READY; MANUAL SUPABASE ROLLOUT DAN AUTHENTICATED SMOKE PENDING`.

Fitur ini menambahkan detail barang pada riwayat Supplier Order. Setiap baris
menampilkan quantity dipesan, quantity yang sudah diterima, dan sisa yang belum
diterima dalam UOM order.

## Kontrak

- sumber quantity diterima hanya `goods_receipt_documents.status='POSTED'`;
- beberapa Goods Receipt untuk satu PO line dijumlahkan dalam base quantity;
- Draft dan receipt yang dibatalkan tidak dihitung;
- remaining adalah `greatest(ordered_base_qty - received_base_qty, 0)`;
- angka kemudian dikonversi ke UOM order memakai immutable
  `factor_to_base_snapshot` PO line;
- `NOT_RECEIVED`, `PARTIAL`, dan `COMPLETE` mengikuti kontrak status PO yang
  sudah ada;
- read model tidak membuat atau mengubah PO, Goods Receipt, Stock, AP, atau
  Finance.

## Urutan rollout

1. Jalankan SELECT-only
   [`purchase_supplier_order_receipt_progress_preflight.sql`](../../supabase/diagnostics/purchase_supplier_order_receipt_progress_preflight.sql).
2. Semua baris `BLOCKER` harus nol/tidak ada. `SETUP` dan `INFO` adalah expected.
3. Jalankan migration
   [`20260831110000_purchase_supplier_order_receipt_progress_read_model.sql`](../../supabase/migrations/20260831110000_purchase_supplier_order_receipt_progress_read_model.sql).
4. Jalankan SELECT-only
   [`purchase_supplier_order_receipt_progress_postflight.sql`](../../supabase/tests/purchase_supplier_order_receipt_progress_postflight.sql).
5. Jalankan rollback-safe
   [`purchase_supplier_order_receipt_progress_behavior.sql`](../../supabase/tests/purchase_supplier_order_receipt_progress_behavior.sql).
6. Jalankan postflight sekali lagi. Semua selain `INFO` wajib `PASS`.
7. Deploy Backoffice, hard refresh, lalu lakukan authenticated smoke.

## Authenticated smoke

1. Buka `Purchase -> Supplier Order` dan klik `Lihat detail barang` pada PO
   Draft: semua barang harus tampil, diterima nol, dan status `Belum diterima`.
2. Buka PO `PARTIALLY_RECEIVED`: cocokkan ordered, received, dan remaining
   terhadap Goods Receipt final terkait.
3. Buka PO `RECEIVED`: setiap baris normal harus `Selesai diterima` dan remaining
   nol.
4. Bila satu PO mempunyai beberapa Goods Receipt, pastikan jumlah received
   merupakan total seluruh receipt `POSTED`.
5. Pastikan filter, checkbox export, export Excel, dan konfirmasi Draft tetap
   bekerja seperti sebelumnya.
6. Uji user tanpa `purchase.supplier_orders VIEW`; halaman tetap ditolak.
7. Ganti Company dan pastikan detail tidak membawa Product/receipt Company lain.

## Rollback / forward repair

Tidak ada tabel, kolom, atau backfill baru. Jika read contract perlu dibatalkan,
rollback Backoffice bersamaan dengan forward migration yang mengembalikan
definisi `get_purchase_supplier_orders()` dari `20260828190000`. Jangan mengubah
atau menghapus PO dan Goods Receipt untuk melakukan rollback.
