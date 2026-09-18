# Backoffice Sales Return & Refund Step 5/5 Rollout

Status: `LOCAL READY`; database rollout, authenticated smoke, dan UAT belum dilakukan.

## Dampak

- Sales memperoleh workspace Retur & Refund, link dari SO, Credit Note, refund,
  reversal, dan log aktivitas.
- Inventory memperoleh Penerimaan Retur Customer dengan authority
  `inventory.customer_return_receipts`; Gudang tidak diwajibkan punya izin Sales.
- Mutation tetap memakai RPC Step 1-4. Migration Step 5 hanya menambah tiga
  read-model tanpa backfill atau mutation Stock, FIFO, Invoice, Payment,
  Financial Event, Journal, Retur Retail, POS, atau Cashier Session.

## Urutan manual

Jalankan setiap file penuh pada database yang sudah memiliki Step 1-4 sampai
`20260917151000`:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_return_ui_preflight.sql)
2. [Migration](../../supabase/migrations/20260918100000_backoffice_sales_return_ui_read_models.sql)
3. [Postflight](../../supabase/diagnostics/backoffice_sales_return_ui_postflight.sql)
4. deploy client hanya setelah semua check non-`INFO` `PASS`.

Hentikan rollout pada SQL error, `BLOCKER`, atau `FAIL`. Migration tidak boleh
dijalankan ulang setelah ledger terpasang.

## Authenticated smoke wajib

1. Sales membuat Draft Retur dari SO selesai, lalu submit.
2. Sales Admin atau Finance menyetujui; actor berbeda harus tetap boleh.
3. Gudang mem-post split RESTOCK/DESTROY; DESTROY tanpa catatan harus ditolak.
4. Finance mengalokasikan qty secara eksplisit ke un-invoiced, Draft Invoice,
   dan Posted Invoice; sistem tidak boleh menebak Invoice.
5. Post Credit Note, partial refund, exact retry, lalu source-linked reversal;
   verifikasi Journal balance dan Customer Statement.
6. Verifikasi cross-Company ditolak dan stale version ditolak.
7. Verifikasi Retur Retail, Supplier Receipt, POS, dan Cashier Session tetap.

Jika read-model gagal setelah install, gunakan migration forward-fix baru.
Jangan menghapus histori atau dokumen final Step 1-4.
