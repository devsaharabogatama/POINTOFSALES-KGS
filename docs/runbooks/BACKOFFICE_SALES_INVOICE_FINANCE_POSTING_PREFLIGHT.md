# Backoffice Sales Invoice Finance Posting Preflight

Status: SELECT-only, isolated Development Supabase. Belum ada migration posting.

## Tujuan

Mengaudit kontrak sebelum membuat posting Finance untuk Regular Invoice dan DP
Invoice pada flow `BACKOFFICE_DELIVERED_QTY_INVOICE`. Pemeriksaan ini tidak
mengubah Invoice, Financial Event, Journal, Stock, POS, atau konfigurasi Finance.

## Impact map gate berikutnya

- Direct: status/nomor Invoice, quantity hold, DP application, receivable
  schedule, Financial Event, Journal, dan audit/idempotency.
- Downstream: AR Customer, Revenue, Output Tax, Customer Advance Liability,
  payment allocation, laporan Finance, dan reversal/credit note.
- Tidak boleh berubah: POS retail, `sales_headers`/`SALE_POSTED`, Customer
  receipt COGS, DO/Transit/FIFO, serta data Company lain.
- Risiko utama: mapping akun ambigu, pajak DP multi-rate kehilangan lineage,
  periode Invoice tertutup, retry/stale version, dan double posting.

## Cara menjalankan

Target hanya project Development `fkywtxucmyjvpwdiqpix`.

1. Buka SQL Editor project tersebut.
2. Jalankan seluruh
   `supabase/diagnostics/backoffice_sales_invoice_finance_posting_preflight.sql`.
3. Kirim semua row `check_name,status,violation_rows,details`.

Stop bila ada `BLOCKER` atau SQL error. Dua row `REVIEW` memang meminta keputusan
bisnis sebelum migration posting ditulis:

- `dp_tax_group_posting_contract`;
- `invoice_accounting_period_policy`.

## Boundary

Jangan menjalankan `db push`, jangan menjalankan file ini pada production atau
staging, dan jangan membuat posting Invoice sebelum output serta dua keputusan
`REVIEW` ditutup.
