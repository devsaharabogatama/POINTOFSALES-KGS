# F4A AR Reporting Rollout

Status: **migration, postflight, behavioral test, dan Backoffice local-ready;
manual Supabase rollout menunggu user**.

Preflight live telah dikonfirmasi user tanpa blocker: satu invoice TEMPO terbuka
memiliki outstanding Rp133.500 dan seluruh temporal/source integrity PASS.

## Urutan eksekusi

1. Jalankan migration
   [`20260827130000_finance_ar_reporting_runtime.sql`](../../supabase/migrations/20260827130000_finance_ar_reporting_runtime.sql).
2. Jalankan
   [`finance_ar_reporting_postflight.sql`](../../supabase/diagnostics/finance_ar_reporting_postflight.sql).
3. Jika seluruh check selain `INFO` adalah `PASS`, jalankan
   [`finance_ar_reporting_behavioral_test.sql`](../../supabase/tests/finance_ar_reporting_behavioral_test.sql).
4. Setelah keduanya PASS, smoke menu **Finance → Penerimaan Customer**: ubah
   tanggal laporan, pilih Customer, cek saldo statement, lalu download kedua
   workbook Excel.

### Forward-fix untuk database yang sudah menjalankan migration 130000 awal

Versi awal Customer Statement kehilangan `store_id/store_name` pada cabang
Receipt sehingga UNION baru gagal saat fungsi dipanggil. Jangan mengulang
migration 130000. Jalankan:

1. [`20260827131000_finance_ar_statement_union_fix.sql`](../../supabase/migrations/20260827131000_finance_ar_statement_union_fix.sql);
2. [`finance_ar_statement_union_fix_postflight.sql`](../../supabase/diagnostics/finance_ar_statement_union_fix_postflight.sql);
3. ulangi behavioral test F4A.

Forward-fix hanya mengganti definisi satu fungsi report; tidak menyentuh Sale,
Receipt, allocation, Journal, saldo Customer, Stock, maupun active context.

Target F4A:

- outstanding invoice berdasarkan Sale TEMPO POSTED dikurangi allocation dari
  Customer Receipt POSTED sampai tanggal `as of`;
- aging `Belum Jatuh Tempo`, `1–30`, `31–60`, `61–90`, dan `>90 hari`;
- statement Customer kronologis yang menampilkan Invoice, Receipt allocation,
  saldo berjalan, tanggal order, jatuh tempo, dan tanggal pembayaran aktual;
- export Excel bulanan/as-of melalui permission `finance.customer_receipts EXPORT`;
- guard server bahwa tanggal bisnis pembayaran tidak mendahului tanggal bisnis
  order. Waktu input boleh lebih akhir daripada keduanya.

Report hanya membaca snapshot final. Ia tidak mengubah Sale, Receipt, Customer
Balance, Financial Event, Journal, Stock, atau dokumen operasional lain.

Migration menambahkan guard pada allocation agar tanggal bisnis pembayaran
tidak dapat lebih awal daripada tanggal bisnis order. Timestamp input boleh
lebih akhir. Rollback aman dilakukan dengan forward-fix: cabut tiga public
report RPC dan trigger hanya bila belum ada client yang memakai runtime; tidak
ada tabel atau data transaksi baru untuk dipulihkan.
