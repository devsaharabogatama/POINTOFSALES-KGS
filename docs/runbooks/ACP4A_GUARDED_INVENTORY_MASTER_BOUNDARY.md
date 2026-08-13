# ACP-4A Guarded Inventory Master Boundary

Status: database applied; corrected behavioral test user-pass; closing
postflight/preflight and authenticated UI smoke remain evidence gates.

## Tujuan

Menutup blocker ACP-4 tanpa memperluas scope:

- UOM dan Warehouse ditulis melalui RPC tenant/role/version/audit;
- browser tidak lagi menulis langsung `uoms`, `warehouses`, `stores`, atau
  `pos_terminals`;
- Store dan POS Terminal tetap read-only pada Backoffice aktif. Provisioning
  server-admin yang sudah ada tidak diubah;
- semua permission key Inventory tetap `SHADOW`. Enforcement override belum
  dibuka pada fase koreksi ini.

## Urutan manual

1. Jalankan `supabase/migrations/20260812130000_acp_phase4a_guarded_inventory_master_boundary.sql`.
2. Jalankan `supabase/diagnostics/acp_phase4a_guarded_inventory_master_postflight.sql`.
3. Jalankan `supabase/tests/acp_phase4a_guarded_inventory_master_tests.sql`.
4. Jalankan kembali postflight ACP-4A.
5. Jalankan kembali `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`.
6. Restart Backoffice, lalu smoke create/edit UOM dan Warehouse.

## Hasil yang diterima

- seluruh baris postflight ACP-4A `PASS`/`INFO`;
- behavioral test mencetak `TEST PASSED`;
- preflight ACP-4 tidak lagi memiliki blocker direct-write;
- UOM/Warehouse UI tetap dapat create/edit dan Store/Terminal tetap dapat
  dibaca;
- tidak ada akses lintas Company.

## Compatibility dan forward fix

- UUID, kode otomatis, Product-UOM, Stock, Store provisioning, dan Terminal
  provisioning tidak diubah;
- `allow_negative_stock` sengaja tidak menjadi parameter RPC Warehouse karena
  tetap dimiliki flow kebijakan Stock Minus;
- jika rollout gagal, jangan mengedit migration yang telah applied dan jangan
  membuka kembali grant tabel secara manual. Buat forward-fix terpisah.
