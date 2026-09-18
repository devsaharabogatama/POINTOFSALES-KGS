# Backoffice Sales Return — Step 1/5 Commercial Foundation Rollout

## Status

`LOCAL READY; MANUAL DATABASE ROLLOUT, AUTHENTICATED SMOKE, AND UAT PENDING`.

Paket ini hanya membuat lifecycle komersial Return: Draft, Submit, Approve, dan
Cancel sebelum penerimaan. Paket tidak mengubah Stock/FIFO, Invoice/Credit Note,
Payment/Refund, Cashier Session, Financial Event, atau Journal.

## Urutan wajib

Jalankan setiap file penuh melalui SQL Editor pada target non-Production lebih
dahulu. Berhenti pada error, `BLOCKER`, atau `FAIL`.

1. [Preflight](../../supabase/diagnostics/backoffice_sales_return_commercial_preflight.sql)
2. [Migration](../../supabase/migrations/20260917110000_backoffice_sales_return_commercial_foundation.sql)
3. [Postflight](../../supabase/diagnostics/backoffice_sales_return_commercial_postflight.sql)
4. [Behavioral test](../../supabase/tests/backoffice_sales_return_commercial_behavior.sql)
5. Jalankan [Postflight](../../supabase/diagnostics/backoffice_sales_return_commercial_postflight.sql) kembali.

Behavioral test membuat SO/Return representatif dalam satu transaksi dan selalu
`ROLLBACK`. Test tidak memerlukan Return existing dan tidak meninggalkan fixture.

## Expected evidence

- Seluruh row non-`INFO` pada preflight/postflight adalah `PASS`.
- Behavioral menghasilkan tepat satu row `PASS`.
- Permission menunjukkan `FINANCE` sebagai approver dan bukan operator Draft.
- Test membuktikan exact retry, stale-version rejection, concurrent
  over-allocation rejection, cancellation release, immutable audit, serta nol
  perubahan Stock/Invoice/Finance oleh lifecycle komersial.

## Authenticated smoke setelah database live

Client UI Step 5 belum tersedia. Smoke sementara dilakukan lewat authenticated
RPC/API harness: Sales membuat dan Submit Draft, Sales Admin atau Finance
Approve, lalu verifikasi user Sales biasa tidak mempunyai capability Approve.
Jangan menggunakan transaksi customer Production untuk smoke destruktif.

## Rollback / forward-fix

Sebelum ada business row, rollback dapat menghapus objek Step 1 dalam urutan
dependency terbalik. Setelah Return tersimpan, jangan delete dokumen/audit dan
jangan edit migration applied; gunakan migration forward-fix. Step 2 harus
memakai Return approved sebagai source dan tidak boleh menulis efek fisik dari
Draft/Submitted saja.
