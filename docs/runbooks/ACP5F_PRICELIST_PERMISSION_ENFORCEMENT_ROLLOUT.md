# ACP-5F Pricelist Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout pending  
**Permission key:** `sales.pricelists`

## Perubahan

- Backoffice memakai satu composed RPC guarded `VIEW`;
- save Pricelist/rule/Store assignment memakai `MANAGE`;
- Data Exchange menambah export Pricelist guarded `EXPORT`;
- POS online memakai open-Cashier-session reference RPC sendiri;
- Offline catalog snapshot dan server price resolver tidak diubah;
- Customer assignment tetap melalui `contacts.customers MANAGE`;
- direct authenticated read empat tabel Pricelist ditutup setelah consumer
  aplikasi dipindahkan.

## Urutan Wajib

1. Jalankan migration:
   `supabase/migrations/20260813030000_acp_phase5f_pricelist_permission_enforcement.sql`
2. Jalankan postflight:
   `supabase/diagnostics/acp_phase5f_pricelist_permission_postflight.sql`
3. Semua selain `INFO` wajib `PASS`.
4. Jalankan behavior rollback-safe:
   `supabase/tests/acp_phase5f_pricelist_permission_tests.sql`
5. Jalankan regression:
   - `supabase/tests/g2_phase12_pricelist_foundation_tests.sql`;
   - `supabase/tests/g2_phase13_pricelist_default_guard_tests.sql`;
   - `supabase/tests/g2_phase13_reusable_customer_pricelist_tests.sql`;
   - `supabase/tests/g4_phase5_cashier_pricelist_override_tests.sql`;
   - `supabase/tests/acp_phase5a_customer_permission_tests.sql`;
   - `supabase/tests/acp_phase5e_sales_document_permission_tests.sql`.
6. Ulangi postflight ACP-5F.
7. Restart Backoffice dan PWA, lalu smoke:
   - Manager normal: list/create/edit Pricelist dan export berhasil;
   - `LIHAT_SAJA`: list berhasil, create/edit/export ditolak;
   - `TANPA_AKSES`: menu dan direct URL ditolak;
   - Cashier: Customer default dan eligible Global override tetap tampil;
   - checkout online serta retained Offline checkout menghasilkan harga sama;
   - Company A tidak melihat Pricelist Company B.

## Stop Condition

Berhenti pada SQL error, postflight `FAIL`, behavioral/regression failure,
Pricelist POS kosong, harga berubah, atau kebocoran lintas Company. Jangan
memperbaiki data transaksi langsung.

## Compatibility dan Forward Fix

Signature public save tetap sama. UUID, resolver, pricing rule, Sale snapshot,
Customer assignment, dan Offline payload tidak berubah. Karena migration
forward-only, kegagalan setelah commit diperbaiki dengan migration baru; jangan
mengedit migration yang sudah applied atau membuka kembali direct table read.
