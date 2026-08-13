# ACP-5G Bundle Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout pending  
**Permission key:** `sales.bundles`

## Perubahan

- Backoffice memakai satu composed RPC guarded `VIEW`;
- save Product Bundle, sales UOM, dan komposisi tetap atomik serta memakai
  `MANAGE`;
- availability memakai `VIEW` dan hanya mengembalikan kapasitas komponen untuk
  Bundle/Gudang yang diminta;
- Bundle UI memperoleh Product/UOM/Category/Warehouse reference sempit dari
  response yang sama, tanpa memerlukan Master Inventory;
- direct authenticated read tabel khusus Bundle ditutup setelah UI cutover;
- POS component expansion/FIFO, Sales Return allocation, Product biasa, Stock,
  pricing, dan Finance tidak diubah.

## Urutan Wajib

1. Jalankan migration:
   `supabase/migrations/20260813040000_acp_phase5g_bundle_permission_enforcement.sql`
2. Jalankan postflight:
   `supabase/diagnostics/acp_phase5g_bundle_permission_postflight.sql`
3. Semua selain `INFO` wajib `PASS`.
4. Jalankan behavior rollback-safe:
   `supabase/tests/acp_phase5g_bundle_permission_tests.sql`
5. Jalankan regression berurutan:
   - `supabase/tests/g3_phase12_bundle_foundation_tests.sql`;
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
   - `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`;
   - `supabase/tests/acp_phase4c_product_permission_tests.sql`;
   - `supabase/tests/acp_phase5f_pricelist_permission_tests.sql`.
6. Ulangi postflight ACP-5G.
7. Restart Backoffice dan PWA, lalu smoke:
   - Manager normal: list/create/edit/availability Bundle berhasil;
   - `LIHAT_SAJA`: list dan availability berhasil, create/edit ditolak;
   - `TANPA_AKSES`: menu dan direct URL ditolak;
   - user Bundle tidak perlu akses Master Inventory untuk picker sempit;
   - checkout Bundle mengurangi stock/FIFO komponen, bukan Bundle;
   - Return Bundle tetap memakai allocation final;
   - Company A tidak melihat Bundle Company B.

## Stop Condition

Berhenti pada SQL error, postflight `FAIL`, behavioral/regression failure,
Bundle picker kosong, availability berubah, POS Bundle gagal, physical Bundle
stock muncul, atau kebocoran lintas Company. Jangan memperbaiki transaksi final
secara langsung.

## Compatibility dan Forward Fix

Signature public save dan availability tetap sama. UUID Product Bundle,
composition, derived weight, sales UOM, POS expansion, Sale allocation, FIFO,
dan Return snapshot tidak berubah. Migration bersifat forward-only; kegagalan
setelah commit diperbaiki melalui migration baru, bukan dengan mengedit migration
yang sudah applied atau membuka kembali direct table read.
