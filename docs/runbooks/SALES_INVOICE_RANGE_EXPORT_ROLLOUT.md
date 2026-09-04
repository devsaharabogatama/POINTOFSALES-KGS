# Sales Invoice Date-Range XLSX Export Rollout

## Tujuan

Global Data Exchange dapat mengekspor Invoice Penjualan per rentang tanggal
tanpa menarik seluruh histori. Workbook tetap Company-scoped dan berisi:

1. `Daftar Invoice`: satu baris per Invoice, termasuk total dan status batal;
2. `Detail Produk`: satu baris per produk Invoice;
3. `Informasi Export`: Company, rentang, waktu export, dan ringkasan jumlah.

Dasar filter adalah tanggal yang tampil pada snapshot Invoice sesuai policy
Company (`ORDER_DATE` atau `POSTED_DATE`). Export membaca snapshot immutable dan
tidak menulis Sale, Stock, Payment, Financial Event, atau Journal.

## Urutan rollout manual

Jalankan satu per satu di SQL Editor Supabase target:

1. `supabase/diagnostics/sales_invoice_range_export_preflight.sql`;
2. `supabase/migrations/20260904100000_sales_invoice_range_export.sql`;
3. `supabase/tests/sales_invoice_range_export_behavior.sql`;
4. `supabase/diagnostics/sales_invoice_range_export_postflight.sql`;
5. deploy/restart Backoffice, lalu hard refresh browser.

Hentikan rollout bila ada SQL error, `BLOCKER`, atau `FAIL`. `SETUP` untuk RPC
rentang pada preflight adalah expected sebelum migration. Behavioral test berada
dalam transaksi dan selalu `ROLLBACK`.

## Smoke test pengguna

1. Pilih Company yang memiliki Invoice pada bulan pengujian.
2. Buka **Data Exchange → Export → Sales → Invoice Penjualan**.
3. Isi tanggal mulai dan tanggal akhir, lalu klik **Export XLSX**.
4. Pastikan nama file memuat kode Company dan rentang tanggal.
5. Pastikan ketiga sheet tersedia.
6. Cocokkan satu Invoice multi-produk: header muncul sekali pada `Daftar
   Invoice`, seluruh produknya muncul pada `Detail Produk`, dan total sama dengan
   detail Invoice di Backoffice.
7. Uji rentang tanpa Invoice; workbook tetap terunduh dengan header dan jumlah
   nol.
8. Pindah Company lalu ulangi; data Company pertama tidak boleh muncul.
9. Uji akun tanpa capability `sales.sales_documents EXPORT`; dataset atau API
   harus tetap ditolak.

## Compatibility dan forward-fix

- RPC lama `export_sales_documents()` tetap tersedia bagi client lama.
- RPC baru hanya overload `(DATE, DATE)` dan tidak mengubah schema transaksi.
- Bila frontend belum dideploy, export CSV lama tetap bekerja melalui bundle
  lama. Setelah frontend baru aktif, migration ini wajib sudah terpasang.
- Rollback database tidak dilakukan dengan menghapus data. Jika perlu
  forward-fix, perbaiki overload baru; jangan mengubah snapshot Invoice.
