# Finance TEMPO Sale Posting Forward-Fix

Status: **database rollout, behavioral, controlled retry, dan final postflight PASS;
authenticated operational smoke masih manual**.

## Masalah yang dikoreksi

Controlled queue F4B berhasil memposting delapan dari sembilan event KGS. Satu
`SALE_POSTED` TEMPO Rp133.500 gagal dengan
`FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH`. Snapshot grand total, COGS, pajak,
dan Sale source cocok; satu-satunya perbedaan adalah pembayaran aktual nol
sementara seluruh nominal masih menjadi `sales_headers.sisa_piutang`.

Runtime G6 lama mengharuskan jumlah Payment sama dengan grand total walaupun
POS secara sah mengizinkan TEMPO unpaid/partial. Forward-fix membuat debit
`CUSTOMER_RECEIVABLE` sebesar piutang source dan memvalidasi:

```text
actual payment + receivable = grand total + customer surcharge
```

Cash, Transfer, split payment, Customer Balance tender, dan Sales Return tetap
memakai cabang existing. Migration tidak memposting atau mengubah event live.
Jika mapping AR baru efektif setelah tanggal event historis, migration menambah
versi fallback untuk interval sebelumnya dengan account yang sama dan audit
Finance Master; mapping aktif yang lebih baru tidak dimutasi.

## Urutan rollout

1. Pastikan Company tetap pada mode `CONTROLLED` dan tidak ada queue berstatus
   `PREVIEWED`, `APPROVED`, atau `PROCESSING`.
2. Jalankan
   [`finance_tempo_sale_posting_fix_preflight.sql`](../../supabase/diagnostics/finance_tempo_sale_posting_fix_preflight.sql).
   `tempo_receivable_account_resolution=BACKFILL` boleh terjadi bila account
   candidate tunggal tercantum; `BLOCKER` tetap dilarang. Check lain wajib
   `PASS/INFO`.
3. Jalankan migration
   [`20260827141000_finance_tempo_sale_posting_fix.sql`](../../supabase/migrations/20260827141000_finance_tempo_sale_posting_fix.sql).
4. Jalankan
   [`finance_tempo_sale_posting_fix_postflight.sql`](../../supabase/diagnostics/finance_tempo_sale_posting_fix_postflight.sql).
   Sebelum retry, `tempo_hold_retry_scope=BACKFILL` dan
   `tempo_posting_exception_scope=BACKFILL` untuk satu event adalah expected;
   check lain wajib `PASS/INFO`.
5. Jalankan
   [`finance_tempo_sale_posting_fix_behavioral_test.sql`](../../supabase/tests/finance_tempo_sale_posting_fix_behavioral_test.sql).
   Test memposting event TEMPO yang sama, memeriksa debit AR, journal balance,
   exact replay, lalu me-rollback seluruh write.
6. Di Backoffice KGS, buat queue Controlled baru. Preview harus berisi satu
   event, lalu Approve dan Process.
7. Jalankan ulang postflight forward-fix dan postflight F4B. Target:
   `tempo_hold_retry_scope=PASS`, exception nol, seluruh supported HOLD nol,
   journal balance/coverage/duplicate seluruhnya PASS.
8. Baru lakukan smoke Cash, partial TEMPO, unpaid TEMPO, Customer Receipt, dan
   policy `AUTOMATIC` pada Company dummy.

## Rollback dan compatibility

- Sebelum event retry berhasil, rollback operasional cukup mempertahankan
  policy `CONTROLLED`; migration tidak mengubah business row.
- Setelah jurnal TEMPO terbentuk, jangan drop function atau menghapus jurnal.
  Gunakan forward-fix/reversal resmi bila ditemukan masalah.
- Queue lama `COMPLETED_WITH_ERRORS` tetap menjadi audit. Retry dilakukan lewat
  queue baru dan exact event-to-journal identity mencegah duplikasi.
- Pembayaran Customer berikutnya tetap memakai Customer Receipt:
  `Dr Cash/Bank; Cr CUSTOMER_RECEIVABLE`.

## Evidence live closure

- Controlled retry: satu Sale TEMPO berhasil diposting tanpa kegagalan.
- F4B final: 40 event POSTED, 40 journal POSTED, supported HOLD nol,
  open exception nol, duplicate dan balance checks PASS.
- TEMPO final: satu posted TEMPO mempunyai receivable journal coverage;
  HOLD/exception nol dan account resolution PASS.
