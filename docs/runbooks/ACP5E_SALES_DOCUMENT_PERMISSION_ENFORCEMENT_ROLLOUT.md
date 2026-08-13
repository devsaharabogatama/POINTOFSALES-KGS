# ACP-5E Sales Document Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout pending  
**Permission key:** `sales.sales_documents`  
**Migration:** `20260813020000`

## Outcome

- Backoffice Invoice/Surat Jalan list, detail, dan print memerlukan `VIEW`;
- lifecycle Surat Jalan memerlukan `MANAGE`;
- export CSV snapshot final memerlukan `EXPORT`;
- PWA tetap dapat membuka dan mencetak Invoice final melalui posted-Sale scope,
  tanpa memperoleh permission Backoffice;
- Sales Return dan Finance tetap memakai authority terpisah;
- browser tidak lagi membaca empat tabel dokumen secara langsung.

## Urutan Wajib

1. Jalankan migration:
   `supabase/migrations/20260813020000_acp_phase5e_sales_document_permission_enforcement.sql`
2. Jalankan postflight:
   `supabase/diagnostics/acp_phase5e_sales_document_permission_postflight.sql`
3. Hanya jika seluruh status non-INFO `PASS`, jalankan behavior:
   `supabase/tests/acp_phase5e_sales_document_permission_tests.sql`
4. Jalankan regression:
   - `supabase/tests/sld_phase2_sales_document_tests.sql`
   - `supabase/tests/sld_r2_delivery_fee_tests.sql`
   - `supabase/tests/sld_r4_delivery_fee_return_tests.sql`
   - `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`
5. Rerun postflight ACP-5E sebagai closing check.
6. Restart Backoffice/PWA, lalu smoke:
   - user `LIHAT_SAJA`: list/detail/print boleh, delivery action dan export ditolak;
   - user `OPERASIONAL`: list/detail/print/delivery boleh, export ditolak;
   - user role penuh: seluruh capability baseline boleh;
   - PWA Kasir: transaksi final tetap membuka Invoice dan mencatat print;
   - Company A tidak pernah melihat dokumen Company B;
   - Data Exchange hanya menampilkan `Invoice & Surat Jalan` bila `EXPORT`
     efektif.

Berhenti pada SQL error, postflight `FAIL`, atau regression failure. Jangan
melanjutkan ke ACP-5F sebelum penyebabnya ditutup.

## Compatibility

- signature publik empat RPC lama tetap sama;
- core lama dipindah private dan hanya dipanggil wrapper terjaga;
- shared `sales_headers`, `sales_details`, dan `sales_payments` tidak dicabut;
- tidak ada Sale, Stock, Payment, Return, Financial Event, atau jurnal yang
  diposting ulang;
- Invoice/Surat Jalan existing tetap memakai UUID internal dan nomor manusia
  existing.

## Rollback / Forward Fix

Migration bersifat additive dan tidak menghapus data. Jika application cutover
gagal setelah migration:

1. jangan drop function atau tabel;
2. kembalikan catalog key ke `SHADOW` melalui forward-fix terkontrol;
3. pulihkan SELECT authenticated sementara hanya pada empat tabel dokumen;
4. pertahankan audit/override history;
5. perbaiki consumer lalu lakukan cutover ulang dengan version migration baru.

Jangan mengedit migration setelah diterapkan.
