# ACP-4F Stock Adjustment Permission Enforcement

Status: LOCAL READY; manual Supabase rollout dan authenticated smoke menunggu.

## Boundary

ACP-4F menegakkan tepat `inventory.stock_adjustments`:

- `VIEW`: navigation, list/detail, Reason, Product/Gudang reference, dan proof;
- `CREATE_DRAFT`: membuat Draft dan Reason baru;
- `EDIT_DRAFT`: mengubah Draft atau Reason existing;
- `POST`: core atomic FIFO, Movement, dan Finance event yang sudah terbukti;
- `CANCEL_FINAL`: pembatalan Draft sesuai role baseline.

Browser tidak lagi membaca lima tabel Adjustment. Satu composed RPC menyuplai
data dan narrow references. Stock Opname tetap memakai core Adjustment yang sama
melalui jalur privat tepercaya; izin Opname tidak berubah dan tidak dapat dipakai
untuk membuat Adjustment manual. Narrow RPC sementara mempertahankan tampilan
referensi Adjustment hasil Opname sampai slice Opname sendiri dibuka.

## Urutan SQL manual

Jalankan setiap file secara penuh. Berhenti pada error atau row `FAIL`:

1. `supabase/migrations/20260812180000_acp_phase4f_stock_adjustment_permission_enforcement.sql`
2. `supabase/diagnostics/acp_phase4f_stock_adjustment_permission_postflight.sql`
3. `supabase/tests/acp_phase4f_stock_adjustment_permission_tests.sql`
4. `supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`
5. ulangi langkah 2
6. `supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql`

Expected notice langkah 3:

`TEST PASSED: Stock Adjustment permission is separated, tenant-safe, direct reads are closed, and Stock Opname retains a trusted core.`

Langkah 4 adalah regression wajib untuk membuktikan Opname masih menghasilkan
Adjustment, FIFO, dan Movement secara atomic setelah internal call dipindahkan.

## Authenticated smoke

1. `IKUTI_ROLE`: Company Owner/Admin dan Store Manager sesuai assignment dapat
   View/Create/Edit/Post/Cancel; Finance/Accounting tetap View-only.
2. `LIHAT_SAJA`: page/detail aktif; seluruh mutation hilang dan direct API/RPC
   mutation ditolak.
3. `OPERASIONAL`: Create/Edit aktif; Post/Cancel hilang dan ditolak.
4. `TANPA_AKSES`: Home/Fast Link menghilangkan menu; direct route/API/RPC baca
   dan mutation ditolak.
5. Ganti Company A/B dan pastikan dokumen, Reason, Product, Gudang, saldo,
   allocation, serta Movement tidak pernah silang tenant.
6. Post satu Draft Adjustment dan satu disposable Opname dengan selisih; cek
   satu final effect, FIFO/Movement balance, dan relasi Opname → Adjustment.

## Compatibility dan recovery

Signature RPC Adjustment serta `post_stock_opname` tetap kompatibel. Reason
mutation yang sebelumnya tidak mempunyai UI kini ikut capability guard agar
tidak menjadi bypass. `service_role` mempertahankan private-core/table access.
Jika smoke gagal, kembalikan override user ke `IKUTI_ROLE` dan buat forward fix;
jangan edit migration applied atau membuka lagi direct table SELECT.
