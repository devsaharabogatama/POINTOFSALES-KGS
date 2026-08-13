# ACP-5H Sales Return Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout pending  
**Permission key:** `sales.sales_returns`

## Perubahan

- Backoffice list/detail Return memakai composed RPC guarded `VIEW`;
- `POST` tetap satu-satunya final approval dan menjalankan posting atomik lama;
- pembatalan Draft Backoffice memakai `CANCEL_FINAL`;
- tidak dibuat status Review baru; capability `REVIEW` dipertahankan untuk
  kompatibilitas catalog;
- PWA memperoleh Sale yang masih dapat diretur, nominal refundable, ongkir yang
  tersisa, dan Gudang Rusak melalui RPC khusus open-session;
- Draft PWA tetap memakai authority Kasir/Store/session, bukan Backoffice VIEW;
- direct authenticated read lima tabel khusus Return ditutup setelah kedua UI
  dipindahkan;
- FIFO restoration, Bundle allocation, refund, delivery-fee decision,
  idempotency, dan event Finance `HOLD` tidak diubah.

## Urutan Wajib

1. Jalankan migration:
   `supabase/migrations/20260813050000_acp_phase5h_sales_return_permission_enforcement.sql`
2. Jalankan postflight:
   `supabase/diagnostics/acp_phase5h_sales_return_permission_postflight.sql`
3. Semua selain `INFO` wajib `PASS`.
4. Jalankan behavior rollback-safe:
   `supabase/tests/acp_phase5h_sales_return_permission_tests.sql`
5. Jalankan regression berurutan:
   - `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`;
   - `supabase/tests/sld_r4_delivery_fee_return_tests.sql`;
   - `supabase/tests/g3_phase12_bundle_foundation_tests.sql`;
   - `supabase/tests/acp_phase5e_sales_document_permission_tests.sql`;
   - `supabase/tests/acp_phase5g_bundle_permission_tests.sql`.
6. Ulangi postflight ACP-5H.
7. Restart Backoffice dan PWA, lalu smoke:
   - Manager normal: list/detail/Post/Cancel Draft sesuai role berhasil;
   - `LIHAT_SAJA`: list/detail berhasil, Post/Cancel ditolak;
   - `TANPA_AKSES`: menu dan direct URL Backoffice ditolak;
   - Kasir dengan sesi aktif tetap dapat mencari sumber dan membuat Draft;
   - Kasir tanpa sesi aktif ditolak;
   - Return penuh/parsial, refund ongkir eksplisit, dan Bundle Return tetap sama;
   - Company A tidak melihat Return Company B.

## Stop Condition

Berhenti pada SQL error, postflight `FAIL`, regression gagal, sumber Return PWA
kosong padahal eligible, nominal refund berubah, Post menggandakan final effect,
Finance event tidak tetap `HOLD`, atau kebocoran lintas Company. Jangan membuka
direct table read sebagai perbaikan.

## Compatibility dan Forward Fix

Signature public save, Post, dan Cancel tetap sama. UUID, lifecycle
`DRAFT/POSTED/CANCELED`, refund, movement, FIFO restoration, delivery-fee
snapshot, idempotency, dan Finance HOLD dipertahankan. `list_returnable_sales`
tetap tersedia sebagai compatibility RPC, tetapi UI PWA aktif memakai response
terkomposisi baru. Migration forward-only; kegagalan setelah commit diperbaiki
dengan migration baru.
