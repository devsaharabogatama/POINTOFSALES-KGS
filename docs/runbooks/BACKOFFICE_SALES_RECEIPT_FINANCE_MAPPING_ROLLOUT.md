# Backoffice Sales Receipt Finance Mapping Rollout

Status 2026-09-09: `LOCAL READY`; belum diterapkan ke database.

Gate `20260909153000` menyediakan mapping Finance untuk boundary Customer
receipt saja: debit COGS dan credit Inventory Asset berdasarkan actual Transit
FIFO cost. Migration tidak membuat receipt, Stock Movement, Financial Event,
Journal, Invoice, Revenue/AR, atau Payment.

Akun tidak dibuat atau ditebak. Setiap Company aktif harus dapat memakai akun
valid secara deterministik dari canonical `SALE_POSTED`, lalu
`SALE_DISPATCHED`, Company fallback, atau satu system account. Ambigu/missing
menjadi `BLOCKER`.

## Urutan isolated Development

1. Jalankan `supabase/diagnostics/backoffice_sales_receipt_finance_mapping_preflight.sql`.
2. Stop bila ada `BLOCKER`.
3. Apply `supabase/migrations/20260909153000_backoffice_sales_receipt_finance_mapping.sql`.
4. Jalankan `supabase/diagnostics/backoffice_sales_receipt_finance_mapping_postflight.sql`.
5. Jalankan `supabase/tests/backoffice_sales_receipt_finance_mapping_behavior.sql`.

Behavior test membuat Event rollback-only dan memakai resolver Finance canonical
untuk membuktikan akun COGS/Inventory benar tanpa membuat Journal.

Jangan memakai `supabase db push`; migration sebelumnya dipasang manual dan
ledger CLI tidak sama dengan `private.kgs_schema_migrations`. Production dan
staging lama tidak boleh menjadi target.
