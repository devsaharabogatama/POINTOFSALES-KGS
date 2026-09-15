# Purchase Daily Replenishment Step 6/6C — Client Activation

Target hanya isolated Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada
production atau staging existing.

## Impact

- Menambah read-model referensi exact untuk UI RO: UUID relasi Product-Supplier,
  konversi Purchase UOM, dan Gudang penerimaan aktif.
- Mengaktifkan tab RO/PO, konfirmasi AUTO_RO menjadi PO, pembagian satu Product
  ke beberapa Supplier, dan pembatalan RO/PO melalui RPC Step 6B.
- Tidak mengubah generator 23.59, quantity stok minus, Goods Receipt, Stock,
  FIFO, AP, Finance, POS Retail, atau histori posted.

## Urutan SQL

1. `supabase/diagnostics/purchase_daily_client_workspace_preflight.sql`
2. `supabase/migrations/20260914150000_purchase_daily_client_workspace.sql`
3. `supabase/tests/purchase_daily_client_workspace_behavior.sql`
4. `supabase/diagnostics/purchase_daily_client_workspace_postflight.sql`

Jalankan setiap file secara penuh. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
Setelah seluruh SQL PASS, restart Backoffice lokal lalu smoke dengan
`localadmin@local.com`:

1. buka Purchase > Supplier Order;
2. pastikan tab Request Order dan Purchase Order tampil;
3. buka RO Draft, ubah Qty/Gudang/Supplier bila diperlukan, lalu konfirmasi;
4. pastikan PO hasil konfirmasi tampil pada tab Purchase Order;
5. uji cancel RO Draft;
6. uji cancel PO tanpa Receipt;
7. pastikan PO dengan Receipt Posted ditolak sampai Purchase Return penuh Posted.

Status tidak boleh dinaikkan menjadi SMOKE PASS atau UAT PASS sebelum langkah
browser tersebut benar-benar dijalankan.
