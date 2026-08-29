# ODR-4A Procurement Demand Foundation

Jalankan berurutan melalui Supabase SQL Editor:

1. `supabase/migrations/20260828150000_odr_phase4a_procurement_demand_foundation.sql`;
2. `supabase/tests/odr_phase4a_procurement_demand_foundation_postflight.sql`;
3. `supabase/tests/odr_phase4a_procurement_demand_foundation_behavior.sql`;
4. ulangi postflight nomor 2.

Seluruh check wajib `PASS`, kecuali `foundation_runtime_inventory` yang memang
`INFO`. `legacy_draft_supplier_order_preserved` melaporkan jumlah Draft PO live
dan harus tetap `PASS` karena foundation sengaja tidak menyentuhnya.

Migration ini hanya membuat foundation demand internal per sesi, line yang
menunjuk shortage reservation, dan audit append-only. Karena preflight
menunjukkan open shortage nol, migration menolak bila kondisi berubah dan tidak
melakukan backfill diam-diam.

ODR-4A belum membuat Stock Request baru, belum menyinkronkan Draft PO, belum
membuat amendment, dan tidak menyentuh Stock/FIFO/Movement/Finance. Jika satu
langkah gagal, hentikan dan kirim error; jangan lanjut ke ODR-4B runtime.
