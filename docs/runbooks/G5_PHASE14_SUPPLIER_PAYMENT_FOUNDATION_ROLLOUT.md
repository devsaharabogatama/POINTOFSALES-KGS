# Runbook G5 Phase 14 — Supplier Payment / AP Settlement Foundation Rollout

Dokumen ini berisi panduan eksekusi manual rollout fondasi database **Pembayaran Supplier (Supplier Payment & AP Settlement Foundation)** di aplikasi POS & Backoffice KGS POS.

---

## Urutan Eksekusi Manual

1. **Jalankan Migration Foundation:**
   - Eksekusi file: `supabase/migrations/20260807150000_g5_phase14_supplier_payment_foundation.sql` di Supabase SQL Editor.
   - **Target:** Membuka tabel `supplier_payment_documents`, `supplier_payment_allocations`, `supplier_payment_audit`, serta RPC `save_supplier_payment_draft`, `validate_supplier_payment`, `cancel_supplier_payment`.

2. **Jalankan Diagnostic Postflight:**
   - Eksekusi file: `supabase/diagnostics/g5_phase14_supplier_payment_postflight.sql` di Supabase SQL Editor.
   - **Target:** Seluruh 5 check (`g5_supplier_payment_migration_registered`, `canonical_supplier_payment_tables`, `supplier_payment_rls_enabled`, `supplier_payment_rpcs`, `supplier_payment_direct_write_boundary`) harus mengembalikan status **`PASS`**.

3. **Jalankan Behavioral Test Suite:**
   - Eksekusi file: `supabase/tests/g5_phase14_supplier_payment_tests.sql` di Supabase SQL Editor.
   - **Target:** Menghasilkan output `NOTICE: G5 Phase 14 Supplier Payment Behavioral Tests PASS`. SELURUH TEST BERSIFAT ROLLBACK-SAFE (*zero permanent mutation*).

---

## Catatan Invariant & Batasan Scope Phase 14

- **Status Faktur Terikat:** Pembayaran Supplier hanya melunasi Faktur Supplier yang berstatus **`VALIDATED`**.
- **Batasan Nominal:** Nominal alokasi pembayaran tidak boleh melebihi sisa AP Final dari faktur terkait.
- **Zero Journal Effect:** Jurnal Keuangan umum / Buku Besar G6 (*General Ledger posting*) **tetap tertutup** sampai Gate 6.
- **Server-Authoritative:** Tidak ada direct write dari browser; seluruh mutasi pembayaran dieksekusi via RPC PostgreSQL `SECURITY DEFINER` dengan row lock dan versioning.
