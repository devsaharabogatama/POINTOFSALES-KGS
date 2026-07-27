# Runbook G1 Fase 3 — Transaction Tenant Consistency

**Migration:** `supabase/migrations/20260720150000_g1_phase3_transaction_tenant_consistency.sql`  
**Requirement:** TEN-001  
**Scope:** Cashier Session, Sales Header/Detail, Sales Payment, Purchase Header/Detail.

## Yang Berubah

- Sembilan composite parent key dan 19 composite foreign key menjaga Company, Store, POS, Session, Customer, Product, Warehouse, Sale, Payment, dan Purchase tetap konsisten.
- Payment wajib menunjuk Session yang sama dengan Sale.
- Sale dengan Store/POS terisi wajib cocok dengan Store/POS milik Cashier Session.
- FK ID lama dipertahankan agar execution path existing tetap kompatibel.
- Tidak ada perubahan status transaksi, angka, stock, jurnal, RLS, role, atau UI.

Penambahan FK kedua membuat PostgREST memiliki lebih dari satu relationship untuk beberapa pasangan tabel. Query embed baru wajib memakai relationship hint berdasarkan nama FK. Jangan menghapus composite FK untuk mengatasi `PGRST201`.

## Urutan Manual

1. Pastikan G1 fase 2, behavioral test, dan smoke frontend lokal sudah PASS.
2. Jalankan `supabase/diagnostics/g1_phase3_transaction_tenant_preflight.sql`.
3. Semua 19 baris wajib `PASS` dan `mismatch_rows = 0`.
4. Ambil backup/export dan pilih waktu trafik rendah.
5. Jalankan seluruh migration `20260720150000...sql` sebagai satu batch.
6. Jalankan `supabase/diagnostics/g1_phase3_transaction_tenant_postflight.sql`; harus ada 30 baris dan semuanya `PASS`.
7. Jalankan `supabase/tests/g1_phase3_transaction_tenant_constraints_tests.sql`; harus muncul notice `TEST PASSED` dan transaksi test di-`ROLLBACK`.
8. Reload runtime lokal. Smoke test login, Company aktif, daftar Product/Stock, dan flow POS/Sales yang memang sudah tersedia. UI master baru tetap menunggu G2.

## Stop Condition

- Preflight memiliki satu saja `FAIL`: jangan jalankan migration dan jangan memperbaiki `company_id` otomatis.
- Migration gagal: simpan error lengkap; transaction akan rollback.
- Postflight/behavior gagal: jangan lanjut ke G1 role/RLS matrix atau G2.
- Frontend mendapat `PGRST201`: perbaiki query embed dengan relationship hint eksplisit, bukan membuang constraint.

## Rollback / Forward Fix

Migration bersifat forward-only setelah write baru bergantung pada constraint. Regression integration diperbaiki pada resolver/query/request asal. Belum ada deployment Vercel pada fase ini; GitHub hanya versioning dan runtime tetap lokal + Supabase.
