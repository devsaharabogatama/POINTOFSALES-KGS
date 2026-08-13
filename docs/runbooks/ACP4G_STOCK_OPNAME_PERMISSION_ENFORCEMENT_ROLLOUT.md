# ACP-4G Stock Opname Permission Enforcement

Status: LOCAL READY; manual Supabase rollout dan authenticated smoke menunggu.

## Boundary

ACP-4G menegakkan tepat `inventory.stock_opnames` dengan dua channel yang tidak
saling membuka akses:

- Backoffice report memakai capability `VIEW`; `REVIEW`, `POST`, dan
  `CANCEL_FINAL` diperiksa terpisah;
- blind count tetap dibatasi oleh Store role dan Gudang assignment existing;
  restriction `LIHAT_SAJA`/`TANPA_AKSES` hanya dapat mengurangi akses;
- composed Backoffice RPC mengembalikan sesi, detail, attempt, actor label,
  Gudang terpakai, serta bukti Adjustment tanpa membuka empat tabel Opname;
- payload blind count tetap tidak memuat system/expected/physical/variance;
- Post tetap memakai private trusted Adjustment core dari ACP-4F.

Warehouse Admin adalah Backoffice `VIEW` saja. Review/Post tetap Company
Owner/Admin atau Store Manager sesuai authority Opname yang sudah terbukti.
Opening Stock dan Minimum Stock tetap `SHADOW`.

## Urutan SQL manual

Jalankan setiap file secara penuh. Berhenti pada error atau row `FAIL`:

1. `supabase/migrations/20260812190000_acp_phase4g_stock_opname_permission_enforcement.sql`
2. `supabase/diagnostics/acp_phase4g_stock_opname_permission_postflight.sql`
3. `supabase/tests/acp_phase4g_stock_opname_permission_tests.sql`
4. `supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`
5. `supabase/tests/acp_phase4f_stock_adjustment_permission_tests.sql`
6. ulangi langkah 2
7. `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected notice langkah 3:

`TEST PASSED: Stock Opname report and blind-count channels are separated, restriction-aware, tenant-safe, and still post through canonical Adjustment.`

Langkah 4 menguji lifecycle blind count/recount/Post canonical. Langkah 5
membuktikan trusted Opname-to-Adjustment core tidak berubah menjadi permission
bypass.

## Authenticated smoke

1. Finance/Accounting/Warehouse Admin dengan `IKUTI_ROLE` dapat membuka report,
   tetapi tidak melihat tombol recount/Post/cancel.
2. Store Manager dengan `IKUTI_ROLE` dapat review, recount, Post, dan cancel
   sesuai status dokumen serta Store/Gudang authority existing.
3. `LIHAT_SAJA`: report tetap terlihat; mutation hilang dan direct API/RPC
   mutation ditolak.
4. `OPERASIONAL`: blind create/count untuk actor yang memang eligible tetap
   tersedia, tetapi Post/cancel final ditolak.
5. `TANPA_AKSES`: menu Backoffice hilang, composed report ditolak, dan Cashier
   yang sebelumnya eligible tidak dapat membuat/melanjutkan blind count.
6. Ganti Company A/B dan pastikan sesi, attempt, actor, Gudang, serta Adjustment
   tidak pernah silang tenant.

## Compatibility dan recovery

Semua signature publik Opname dipertahankan. Browser tidak lagi dapat membaca
tabel Opname atau helper referensi Adjustment lama. `service_role` tetap dapat
mengakses private core. Bila smoke gagal, reset override ke `IKUTI_ROLE` dan
buat forward fix; jangan edit migration applied atau membuka direct table read.

