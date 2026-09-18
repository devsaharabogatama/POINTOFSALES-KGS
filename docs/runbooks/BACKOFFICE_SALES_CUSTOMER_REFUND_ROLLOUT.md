# Backoffice Sales Return Step 4/5 - Customer Refund Rollout

## Status

`LOCAL READY`. Paket belum `DATABASE LIVE`, `SMOKE PASS`, atau `UAT PASS` sampai
seluruh gate manual dijalankan pada target database.

## Outcome

Finance dapat membayar liability Refund yang sudah dibentuk oleh Credit Note
Retur Customer:

- Cash langsung mengkredit akun Kas dari Payment Method;
- Transfer Bank mengkredit akun Bank dari Payment Method;
- tidak ada POS atau Cashier Session;
- Refund boleh parsial dan kumulatif tidak boleh melebihi liability Credit Note;
- bukti mengikuti `proof_mode` Payment Method;
- Refund posted immutable, sedangkan koreksi memakai reversal source-linked.

Journal Refund adalah debit `CUSTOMER_REFUND_LIABILITY` dan kredit akun
settlement. Reversal membalik persis akun serta nilai Journal sumber. Customer
Statement menampilkan Refund sebagai debit dan reversal sebagai credit agar
saldo kembali rekonsiliasi.

## Impact dan compatibility

- Direct: permission Finance, dokumen/operation/audit Refund, Financial Event,
  Journal, payment context Invoice, dan Customer Statement.
- Tidak berubah: Stock/FIFO, Customer Return Receipt, SO/DO, Invoice posted,
  Customer Receipt posted, Retur Retail, POS, dan Cashier Session.
- Migration zero-backfill. Credit Note existing tetap utuh; hanya Credit Note
  posted dengan `refund_liability_amount > 0` yang eligible.
- Transaction memakai source row lock, exact retry, amount cap, optimistic
  source version, periode akuntansi, dan immutable history.

## Urutan manual wajib

Jika `20260917150000` belum terpasang, jalankan dua file dasar terlebih dahulu:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_customer_refund_preflight.sql)
2. [Migration](../../supabase/migrations/20260917150000_backoffice_sales_customer_refund.sql)

Jika `20260917150000` sudah terpasang, jangan jalankan ulang dua file dasar.
Lanjutkan forward-fix dan verifikasi berikut secara berurutan:

1. [Reversal-fix preflight](../../supabase/diagnostics/backoffice_sales_customer_refund_reversal_fix_preflight.sql)
2. [Reversal-fix migration](../../supabase/migrations/20260917151000_backoffice_sales_customer_refund_reversal_guard_fix.sql)
3. [Behavioral test](../../supabase/tests/backoffice_sales_customer_refund_behavior.sql)
4. [Reversal-fix postflight](../../supabase/diagnostics/backoffice_sales_customer_refund_reversal_fix_postflight.sql)
5. [Full postflight](../../supabase/diagnostics/backoffice_sales_customer_refund_postflight.sql)

Stop bila ada SQL error, `BLOCKER`, atau `FAIL`. Jangan menjalankan selection
parsial, memasukkan ledger manual, menghapus transaksi, atau mengubah migration
yang sudah applied.

Behavioral test membuat fixture melalui runtime canonical Step 1-3, mem-post
dua partial Refund, menolak over-refund, menguji exact retry, membuat reversal,
memeriksa Journal/Statement, dan membuktikan Cashier Session tidak berubah.
Semua fixture dirollback oleh subtransaction internal.

## Authenticated smoke

1. Login sebagai Finance pada Company yang mempunyai Credit Note
   `REFUND_PENDING`.
2. Post partial Cash Refund dan periksa sisa liability, Journal, serta Statement.
3. Post sisa Transfer Refund dengan bukti bila metode mewajibkannya.
4. Pastikan Return menjadi `COMPLETED`.
5. Reverse salah satu Refund dengan alasan dan pastikan Return kembali
   `REFUND_PENDING` serta Journal reversal menunjuk Journal sumber.
6. Pastikan tidak ada sesi kasir yang dibuat atau berubah.
7. Ulang operation key yang sama dan pastikan exact retry tidak menggandakan
   Refund/Event/Journal.

## Rollback dan forward-fix

- Sebelum migration: tidak ada perubahan database.
- Migration transactional dan fail-closed.
- Setelah schema terpasang tetapi belum ada Refund operasional, koreksi memakai
  migration forward-fix additive.
- Setelah Refund posted, jangan drop schema atau menghapus dokumen. Gunakan RPC
  reversal source-linked.

## Exit gate

- `LOCAL READY`: file dan pemeriksaan lokal selesai.
- `DATABASE LIVE`: migration berhasil pada target.
- `BEHAVIOR/POSTFLIGHT PASS`: behavioral dan seluruh non-INFO postflight PASS.
- `SMOKE PASS`: authenticated flow nyata Cash, Transfer, partial dan reversal.
- `UAT PASS`: user menyetujui hasil operasional.

Step 5 UI/E2E belum diaktifkan oleh paket ini.
