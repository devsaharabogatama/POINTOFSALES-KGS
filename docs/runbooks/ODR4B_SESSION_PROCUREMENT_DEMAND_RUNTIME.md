# ODR-4B Session Procurement Demand Runtime

Jalankan berurutan melalui Supabase SQL Editor:

1. `supabase/migrations/20260828160000_odr_phase4b_session_procurement_demand_runtime.sql`;
2. `supabase/tests/odr_phase4b_session_procurement_demand_postflight.sql`;
3. `supabase/tests/odr_phase4b_session_procurement_demand_behavior.sql`;
4. ulangi postflight nomor 2.

Seluruh check wajib `PASS`, kecuali
`procurement_demand_runtime_inventory` yang memang `INFO`.

Runtime ini memperbarui demand shortage secara atomik setelah Confirm/Cancel
Sales Order dan membekukan identitas demand ketika sesi ditutup. Exact retry
tidak menggandakan header, line, atau audit. Demand dapat dibaca Purchasing
melalui composed RPC yang memakai capability `purchase.supplier_orders VIEW`.

ODR-4B belum membuat/mengubah Stock Request dan Supplier Order. Dua Draft PO
lama dan seluruh PO final tetap tidak disentuh. Sinkronisasi Stock Request,
Draft PO, serta delta/amendment final PO adalah gate berikutnya.
