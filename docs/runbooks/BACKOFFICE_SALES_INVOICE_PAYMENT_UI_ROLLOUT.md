# Backoffice Sales Invoice Payment UI — Step 2/3

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT**. Authenticated UAT/client closure tetap dicatat terpisah.

Target: isolated Development `fkywtxucmyjvpwdiqpix` only  
Production/staging existing: **do not run**

## Outcome

Detail Invoice existing menampilkan status pembayaran yang diturunkan dari
Customer Receipt `POSTED`, sisa tagihan, dan riwayat pembayaran. User dengan
capability `CREATE_DRAFT` dan `POST` pada `finance.customer_receipts` memperoleh
tombol **Catat Pembayaran**. Satu konfirmasi membentuk Draft receipt, posting,
jurnal Debit Kas/Bank — Kredit Piutang, serta rekonsiliasi schedule dalam satu
transaksi database dan satu operation UUID exact-retry.

Tidak dibuat menu Invoice, template Invoice, atau ledger pembayaran baru.
Receipt tetap dokumen canonical. POS Retail, Stock, Reservation, DO, Transit,
FIFO/HPP, nilai/tanggal Invoice, dan source SO tidak dimutasi.

## Urutan manual

Jalankan file utuh, bukan selected text:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_invoice_payment_ui_preflight.sql)
2. Pastikan tidak ada `BLOCKER`, `FAIL`, atau SQL error.
3. [Migration](../../supabase/migrations/20260911162000_backoffice_sales_invoice_payment_ui_runtime.sql)
4. [Behavioral test](../../supabase/tests/backoffice_sales_payment_collection_behavior.sql)
5. [Postflight](../../supabase/diagnostics/backoffice_sales_invoice_payment_ui_postflight.sql)
6. Ulangi [postflight Step 1](../../supabase/diagnostics/backoffice_sales_payment_collection_postflight.sql).

Behavioral membuat sendiri SO → DO → penerimaan Customer → Invoice → pembayaran
partial dan final di dalam transaksi rollback-only. Ia juga menguji exact retry,
over-allocation, payment context dua receipt, schedule lunas, jurnal balance,
dan zero mutation terhadap Sales/allocation Retail.

## Authenticated smoke setelah seluruh SQL PASS

1. Restart launcher Development dan login `localadmin@local.com`.
2. Buka Invoice Backoffice berstatus Terbit.
3. Pastikan status awal dan sisa tagihan sesuai.
4. Klik **Catat Pembayaran**, isi sebagian dari sisa, lalu **Catat & Posting**.
5. Pastikan status menjadi **Dibayar sebagian**, receipt dan nomor jurnal muncul.
6. Bayar sisa tagihan; pastikan **Lunas** dan tombol pembayaran hilang.
7. Refresh browser; pastikan dua riwayat tetap ada dan tidak ada receipt/jurnal duplikat.

## Rollback / forward-fix

Sebelum operation berhasil, rollback teknis dapat menghapus RPC, trigger/helper,
dan tabel operation Step 2. Setelah ada receipt `POSTED`, jangan menghapus atau
mengubah histori; koreksi memakai forward-fix additive. Gagal di tengah RPC
merollback receipt, allocation, schedule, event, jurnal, dan operation bersama.
