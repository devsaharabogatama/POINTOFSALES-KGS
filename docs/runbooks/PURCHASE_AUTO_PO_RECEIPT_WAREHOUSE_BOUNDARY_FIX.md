# Purchase Step 5/6B — AUTO_PO / Receipt Warehouse Boundary

## Scope

- AUTO_PO tetap dibuat untuk Product aktif pada gudang sumber aktif walaupun
  tujuan penerimaan belum disetel.
- Product nonaktif dan gudang sumber nonaktif tetap tidak dibuatkan PO.
- Supplier kosong tetap memakai `SUPPLIER_PENDING` seperti Step 4.
- Gudang aktif yang diizinkan menerima Purchase wajib dipilih saat membuat
  Goods Receipt.
- PO manual, POS, Stock, FIFO, AP, Finance, dan data production tidak diubah.

## Urutan manual pada isolated Development

Target wajib `fkywtxucmyjvpwdiqpix`.

1. Jalankan [preflight](../../supabase/diagnostics/purchase_auto_po_receipt_warehouse_boundary_fix_preflight.sql).
2. Hentikan jika ada `BLOCKER` atau SQL error.
3. Jalankan [migration](../../supabase/migrations/20260914110000_purchase_auto_po_receipt_warehouse_boundary_fix.sql).
4. Jika migration `20260914110000` sudah terlanjur berhasil tetapi postflight
   melaporkan satu destination filter tersisa, jalankan paket forward-fix:
   [preflight](../../supabase/diagnostics/purchase_auto_po_destination_filter_fix_preflight.sql)
   → [migration](../../supabase/migrations/20260914111000_purchase_auto_po_destination_filter_fix.sql)
   → [postflight](../../supabase/diagnostics/purchase_auto_po_destination_filter_fix_postflight.sql).
5. Jalankan [postflight utama](../../supabase/diagnostics/purchase_auto_po_receipt_warehouse_boundary_fix_postflight.sql).
6. Jalankan paket constraint Supplier Order:
   [preflight](../../supabase/diagnostics/purchase_supplier_order_unset_destination_preflight.sql)
   → [migration](../../supabase/migrations/20260914112000_purchase_supplier_order_unset_destination.sql)
   → [postflight](../../supabase/diagnostics/purchase_supplier_order_unset_destination_postflight.sql).
7. Jalankan [behavioral test](../../supabase/tests/purchase_auto_po_receipt_warehouse_boundary_fix_behavior.sql).
8. Jalankan kedua postflight sekali lagi.

Behavioral test wajib berakhir dengan `TEST PASSED`; seluruh tulisannya berada
dalam transaksi yang di-`ROLLBACK`.

## Forward-fix / rollback note

Jangan mengembalikan migration yang sudah live dengan mengedit ledger atau file
lama. Jika runtime gagal, pertahankan mode Purchase `MANUAL` dan buat migration
forward-fix baru. Preflight sengaja memblokir batch lama yang sudah tertahan oleh
`WAREHOUSE_SETUP_REQUIRED`, karena membuat PO kedua tanpa rekonsiliasi dapat
menggandakan pembelian.

User telah mengonfirmasi seluruh migration, forward-fix, behavioral test, dan
postflight PASS pada isolated Development. Status sekarang **DATABASE LIVE +
BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS**; authenticated smoke/UAT tetap
terpisah dan production/staging tidak disentuh.
