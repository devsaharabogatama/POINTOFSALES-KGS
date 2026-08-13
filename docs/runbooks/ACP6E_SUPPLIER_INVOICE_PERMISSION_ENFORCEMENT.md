# ACP-6E Supplier Invoice Permission Enforcement

**Permission:** `finance.supplier_invoices`  
**Migration:** `20260813110000`  
**Finance boundary:** Financial Event tetap `HOLD`; tidak membuat Journal

## Keputusan capability

- `VIEW`: daftar/detail Faktur Supplier dan matching proof;
- `CREATE_DRAFT`: membuat Draft;
- `EDIT_DRAFT`: mengubah atau membatalkan `DRAFT/HOLD`;
- `POST`: validasi atomic menjadi AP Final;
- `APPROVE`: mengubah kebijakan tolerance Company/Supplier;
- `EXPORT`: export Faktur Supplier bulanan;
- `REVIEW` dipertahankan dalam catalog untuk compatibility, tetapi lifecycle
  Faktur Supplier saat ini tidak memiliki state review terpisah.

Tolerance tetap opsional. Nilai absolute `NULL` tidak diubah menjadi batas nol.

## Urutan rollout manual

Jalankan satu file penuh per langkah dan berhenti pada error/`FAIL`:

1. `supabase/migrations/20260813110000_acp_phase6e_supplier_invoice_permission_enforcement.sql`
2. restart Backoffice;
3. `supabase/diagnostics/acp_phase6e_supplier_invoice_permission_postflight.sql`
4. `supabase/tests/acp_phase6e_supplier_invoice_permission_tests.sql`
5. regression `supabase/tests/g5_phase11_supplier_invoice_matching_tests.sql`
6. regression `supabase/tests/g5_phase14_supplier_payment_tests.sql`
7. `supabase/diagnostics/g5_optional_tolerance_contract_postflight.sql`
8. ulangi postflight ACP-6E.

Kirim seluruh row postflight dan hasil setiap behavioral/regression. Migration
bersifat transactional; bila gagal sebelum `COMMIT`, transaksi rollback. Setelah
applied, jangan edit/rerun migration—buat forward-fix baru.

## Smoke setelah database PASS

Smoke gabungan tetap boleh ditunda ke closing UAT sesuai keputusan user. Saat
dijalankan, minimal buktikan:

- LIHAT_SAJA hanya dapat membuka daftar/detail;
- OPERASIONAL dapat Draft/Edit tetapi tidak POST/tolerance/export;
- approval/full preset dapat mengubah tolerance dan POST;
- Pembayaran Supplier tetap melihat invoice payable tanpa memiliki akses kelola
  Faktur Supplier;
- Company A tidak melihat data Company B.

## Compatibility

- body transaksi G5 terakhir dipertahankan sebagai private core;
- Supplier Payment memakai RPC reference sempit miliknya sendiri;
- Purchase Return memiliki RPC reference sempit miliknya sendiri;
- browser tidak lagi memperoleh `SELECT` enam tabel dedicated Supplier Invoice;
- Purchase Receipt, Stock, FIFO, AP allocation, dan event history tidak diubah.

