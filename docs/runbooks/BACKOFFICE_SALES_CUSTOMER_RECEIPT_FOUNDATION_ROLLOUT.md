# Backoffice Sales Customer Receipt Foundation Rollout

Status 2026-09-09: `LOCAL READY`; belum dijalankan pada database mana pun.

Gate `20260909152000` hanya menyiapkan ledger penerimaan bersih dan formula
quantity Invoiceable. Gate ini belum menyediakan tombol/RPC penerimaan Customer,
belum mengurangi stok Transit, belum membuat COGS/Financial Event/Journal, dan
belum membuat Invoice.

## Contract yang dikunci

- Customer receipt hanya akan dibuka dari DO `IN_TRANSIT` setelah seluruh
  quantity DO diberangkatkan.
- Batch yang kelak dikonsumsi harus batch Transit hasil Dispatch DO terkait,
  bukan FIFO global Transit yang dapat mengambil barang DO lain.
- `Net Delivered = Accepted - Return sebelum Invoice`.
- `Qty To Invoice = Net Delivered - alokasi Draft Invoice - Qty Posted Invoice`.
- Draft Invoice kelak menahan quantity; cancel Draft melepas quantity tersebut.
- Selisih kurang/lebih/salah/rusak tetap fail-closed sampai disposition bisnis
  dan actor authority disetujui; foundation ini tidak mengarang disposition.

## Impact map

- Direct: enam kolom quantity pada line SO dan tiga immutable receipt/FIFO table.
- Downstream belum aktif: Customer receipt runtime, Stock sale-out, COGS,
  Delivered Not Invoiced, Draft/Posted Invoice, Revenue/AR, Payment, Return.
- Compatibility: seluruh line historis memperoleh nilai nol; tidak ada backfill
  yang mengklaim pengiriman lama sebagai penerimaan Backoffice.
- Security: relation baru RLS enabled dan tidak dapat dibaca/ditulis browser.
- Vocabulary Stock Movement final sengaja belum ditambah pada foundation; itu
  harus masuk gate runtime yang juga membuat sale-out secara atomik.
- Rollback: sebelum runtime/data dipakai, forward-fix dapat mencabut artefak.
  Setelah dipakai, jangan drop; gunakan forward-fix additive.

## Urutan hanya isolated Development

1. Pastikan target project-ref `fkywtxucmyjvpwdiqpix`.
2. Jalankan `supabase/diagnostics/backoffice_sales_customer_receipt_foundation_preflight.sql`.
3. Stop jika ada `BLOCKER`.
4. Apply `supabase/migrations/20260909152000_backoffice_sales_customer_receipt_foundation.sql`.
5. Jalankan `supabase/diagnostics/backoffice_sales_customer_receipt_foundation_postflight.sql`.
6. Jalankan `supabase/tests/backoffice_sales_customer_receipt_foundation_behavior.sql`.

Jangan memakai `supabase db push` untuk gate ini. Dry-run CLI memang memastikan
link menuju project development yang benar, tetapi masih mencantumkan `151000`
karena migration itu sebelumnya dipasang manual lewat SQL Editor dan hanya
tercatat pada `private.kgs_schema_migrations`.

Behavioral test menggunakan preparation yang sama dengan runtime Backoffice
Sales, menguji formula ledger pada row nyata, lalu me-`ROLLBACK` semua fixture.
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyixqwi`
tidak boleh menjadi target gate ini.
