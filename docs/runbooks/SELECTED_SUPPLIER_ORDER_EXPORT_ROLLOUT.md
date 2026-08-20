# Rollout Export Supplier Order Terpilih

## Kontrak

- Admin memilih PO melalui checkbox pada daftar yang sudah difilter.
- **Pilih semua hasil filter** hanya memilih PO yang sedang terlihat.
- Maksimal 100 PO per workbook.
- Satu XLSX tetap berisi tiga sheet: Daftar PO, Detail Barang, dan Informasi Export.
- Server memvalidasi capability `purchase.supplier_orders EXPORT`, active Company,
  setiap UUID, duplikasi, batas jumlah, dan kepemilikan seluruh PO.
- Endpoint GET/RPC tanpa argumen lama dipertahankan untuk kompatibilitas, tetapi
  UI baru menggunakan POST dan RPC UUID-array.

## Urutan rollout

1. Jalankan `supabase/migrations/20260820130000_selected_supplier_order_export.sql`.
2. Jalankan `supabase/tests/selected_supplier_order_export_postflight.sql`; seluruh baris wajib PASS.
3. Jalankan `supabase/tests/selected_supplier_order_export_behavior.sql`; harus
   sukses dan berakhir ROLLBACK. Test memakai Owner/Admin aktif pada Company
   yang mempunyai PO; bila fixture tersebut tidak ada, test memakai linked
   Super Admin pada Company aktif yang mempunyai PO.
4. Deploy Backoffice staging.
5. Smoke: filter daftar, pilih dua PO, export, lalu pastikan hanya dua PO dan
   seluruh baris detail miliknya yang berada di workbook.
6. Uji satu PO, pilih-semua hasil filter, reset filter, batas 100, serta user tanpa EXPORT.

## Forward-fix

Jika UI baru gagal, client lama masih dapat memakai GET export existing. Jangan
drop overload lama atau membuka direct SELECT. Perbaikan database berikutnya
wajib additive.
