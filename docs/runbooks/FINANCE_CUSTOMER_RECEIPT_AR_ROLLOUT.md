# F2 Customer Receipt and AR Allocation Rollout

Status: **foundation database PASS; Backoffice dan posting journal local-ready**.

## Langkah aktif

Jalankan berurutan:

1. [`finance_customer_receipt_ar_preflight.sql`](../../supabase/diagnostics/finance_customer_receipt_ar_preflight.sql)
2. [`20260827100000_finance_customer_receipt_ar_foundation.sql`](../../supabase/migrations/20260827100000_finance_customer_receipt_ar_foundation.sql)
3. [`finance_customer_receipt_ar_postflight.sql`](../../supabase/diagnostics/finance_customer_receipt_ar_postflight.sql)
4. [`finance_customer_receipt_posting_preflight.sql`](../../supabase/diagnostics/finance_customer_receipt_posting_preflight.sql)
5. [`20260827110000_finance_customer_receipt_posting_runtime.sql`](../../supabase/migrations/20260827110000_finance_customer_receipt_posting_runtime.sql)
6. [`finance_customer_receipt_posting_postflight.sql`](../../supabase/diagnostics/finance_customer_receipt_posting_postflight.sql)

Preflight memeriksa:

- dependency Finance operational posting dan F1 period policy;
- kesiapan kategori `SALE_PAYMENT`;
- resolusi tunggal `CUSTOMER_RECEIVABLE`, `CASH_DRAWER`, dan `BANK`;
- Customer dan Invoice snapshot untuk Sale TEMPO POSTED;
- rekonsiliasi nominal `grand total = paid + receivable`;
- metode penerimaan aktif per Company;
- inventory historis piutang yang akan menjadi opening scope F2.

Migration foundation membuka Draft/Post/Cancel, multi-Invoice partial allocation,
exact retry, immutable audit, account snapshots, dan `SALE_PAYMENT` event `HOLD`.
User telah mengonfirmasi seluruh postflight foundation PASS pada 2026-08-27.

Migration posting berikutnya menambahkan journal plan atomik dan terverifikasi:

- debit akun Kas/Bank snapshot sesuai settlement route;
- kredit `CUSTOMER_RECEIVABLE`;
- dimensi Customer pada kedua journal line;
- satu event tepat satu jurnal, exact replay aman;
- tanggal receipt memakai periodenya sendiri, atau prior-period adjustment ke
  periode terbuka berikutnya bila diproses setelah periodenya ditutup.

Setelah langkah 6 PASS, lakukan authenticated smoke di Backoffice:

1. buka **Finance > Penerimaan Customer**;
2. pilih Customer dengan invoice tempo terbuka;
3. isi sebagian atau seluruh sisa invoice lalu simpan Draft;
4. buka ulang Draft dan pastikan alokasi tetap sama;
5. Post dan pastikan jurnal debit Kas/Bank, kredit Piutang Customer seimbang;
6. pastikan sisa invoice pada workspace berkurang dan invoice lain tidak berubah.
