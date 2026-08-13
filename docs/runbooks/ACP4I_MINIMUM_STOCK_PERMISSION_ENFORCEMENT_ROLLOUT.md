# ACP-4I Minimum Stock Permission Enforcement

Status: LOCAL READY; manual Supabase rollout dan authenticated smoke menunggu.

## Boundary

ACP-4I menegakkan tepat `inventory.minimum_stock`:

- Company Owner/Admin dan Warehouse Admin: View/Manage Company-wide;
- Store Manager: View/Manage hanya Gudang dari Store membership aktif;
- restriction preset dapat mengurangi View/Manage/Export/Import;
- user di luar baseline tidak memperoleh akses.

Halaman membaca setting, Product/Base UOM, Gudang berwenang, saldo pasangan,
dan audit melalui satu RPC `get_inventory_minimum_stock()`. Global Data Exchange
dan seluruh lifecycle import Minimum Stock memakai capability Export/Import
yang sama. Browser tidak lagi membaca tabel setting/audit, Product reference,
Master Warehouse, atau Stock Real untuk merender halaman ini.

Minimum Stock tetap notice non-blocking. Migration tidak mengubah saldo,
Movement, FIFO, Stock Request, Supplier Order, atau Finance Event.

## Urutan SQL manual

Jalankan penuh dan berhenti pada error atau `FAIL`:

1. [`20260812210000_acp_phase4i_minimum_stock_permission_enforcement.sql`](../../supabase/migrations/20260812210000_acp_phase4i_minimum_stock_permission_enforcement.sql)
2. [`acp_phase4i_minimum_stock_permission_postflight.sql`](../../supabase/diagnostics/acp_phase4i_minimum_stock_permission_postflight.sql)
3. [`acp_phase4i_minimum_stock_permission_tests.sql`](../../supabase/tests/acp_phase4i_minimum_stock_permission_tests.sql)
4. [`g2_phase46_product_warehouse_minimum_stock_tests.sql`](../../supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql)
5. ulangi langkah 2
6. [`acp_phase4_inventory_pilot_preflight.sql`](../../supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql)

Expected langkah 3:

`TEST PASSED: Minimum Stock is capability-aware, Store-scoped, tenant-safe, and stock-neutral.`

## Authenticated smoke

1. Owner/Admin dan Warehouse Admin melihat semua Gudang Company dan dapat edit.
2. Store Manager hanya melihat/mengelola Gudang Store assignment aktifnya.
3. `LIHAT_SAJA`: halaman/export tersedia; mutation/import ditolak.
4. `OPERASIONAL`: View/Manage tersedia; Export/Import mengikuti capability aktif.
5. `TANPA_AKSES`: menu, API, RPC, export, dan import ditolak.
6. Ganti Company A/B; setting, Product, Gudang, saldo, audit, dan import job
   tidak boleh silang tenant.
7. Simpan threshold lalu verifikasi saldo, Movement, FIFO, Request, dan Order
   tidak berubah.

## Recovery

Migration forward-only. Jika smoke gagal, reset override ke `IKUTI_ROLE`,
hentikan mutation/import Minimum Stock, dan buat forward fix. Jangan membuka
kembali direct table read atau mengedit migration yang sudah applied.
