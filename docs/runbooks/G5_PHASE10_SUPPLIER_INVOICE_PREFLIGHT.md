# G5 Phase 10 — Supplier Invoice Preflight

> Correction 2026-08-06: legacy `purchases_headers` has no operational
> `status` column. The preflight derives legacy financial backfill scope only
> from the verified `grand_total` and `paid_amount` columns.

## Urutan

1. Terapkan forward-fix `20260806080000_g5_phase9_purchase_return_uom_fix.sql`.
2. Jalankan `g5_phase9_purchase_return_uom_fix_postflight.sql`; seluruh row harus PASS.
3. Jalankan regression `g5_phase8_purchase_return_foundation_tests.sql`; harus `TEST PASSED`.
4. Restart PWA, lalu pastikan retur Receipt `1 Dus` menawarkan `Ketul` dan dapat menyimpan quantity parsial.
5. Baru jalankan seluruh `g5_phase10_supplier_invoice_preflight.sql` dan kirim semua row.

## Interpretasi preflight

- `BLOCKER`: hentikan; jangan membuat migration Supplier Invoice.
- `REVIEW`: data legacy memiliki nilai/status finansial dan perlu keputusan backfill eksplisit.
- `BACKFILL`: AP provisional Receipt existing akan menjadi scope allocation awal; ini expected tetapi harus dihitung tepat.
- `INFO`: inventory/schema baseline, bukan kegagalan.

Supplier Invoice berikutnya akan mengikuti three-way matching
Order → Receipt → Invoice. Invoice tidak menambah stock/FIFO; quantity/value
allocation memakai base UOM dan immutable source ID. AP Final/variance dapat
dibangun sebagai canonical subledger/event, tetapi jurnal final tetap menunggu G6.
