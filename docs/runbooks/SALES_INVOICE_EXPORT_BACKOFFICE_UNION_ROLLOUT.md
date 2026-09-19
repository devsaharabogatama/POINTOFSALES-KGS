# Sales Invoice Export Backoffice Union Rollout

Status: LOCAL READY; database rollout, authenticated smoke, dan UAT belum dijalankan.

## Urutan manual Supabase SQL Editor

1. Jalankan penuh [preflight](../../supabase/diagnostics/sales_invoice_export_backoffice_union_preflight.sql). Semua gate selain inventory harus `PASS`.
2. Jalankan penuh [migration](../../supabase/migrations/20260919130000_sales_invoice_export_backoffice_union.sql).
3. Jalankan penuh [behavioral test](../../supabase/tests/sales_invoice_export_backoffice_union_behavior.sql). Test wajib `PASS` dan seluruh fixture di-rollback.
4. Jalankan penuh [postflight](../../supabase/diagnostics/sales_invoice_export_backoffice_union_postflight.sql). Semua contract wajib `PASS`.
5. Deploy client setelah database gate lulus.

## Authenticated smoke

1. Masuk ke Company yang memiliki Invoice Retail dan Backoffice.
2. Buka Data Exchange → Invoice Penjualan, pilih rentang yang mencakup keduanya, lalu Export.
3. Pastikan sheet `Daftar Invoice` memiliki `Sumber`, `Nomor Dokumen`, `Nomor SO`, dan `Status` serta filter header aktif.
4. Pastikan sheet `Detail Produk` menampilkan produk dan qty yang sama dengan dokumen sumber.
5. Filter `Sumber=BACKOFFICE`, lalu cocokkan jumlah dan status dengan workspace Invoice Penjualan.

## Forward-fix / rollback note

Tidak ada data untuk di-rollback. Jika runtime bermasalah, forward-fix `public.export_sales_documents(date,date)` dengan definisi terakhir dari migration `20260907100000`, pertahankan ledger sebagai histori, lalu deploy koreksi dengan version baru. Jangan menghapus atau mengubah Invoice, SO, Stock, Payment, maupun Journal.

