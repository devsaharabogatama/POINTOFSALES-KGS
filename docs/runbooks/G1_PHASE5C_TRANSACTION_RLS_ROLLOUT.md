# Runbook G1 Fase 5C - Transaction RLS

**Migration:** `supabase/migrations/20260721090000_g1_phase5c_transaction_rls.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** Cashier Session, Sales Header/Detail/Payment, dan Purchase Header/Detail.

## Perubahan Keamanan

- Cashier hanya membaca sesi dan penjualannya sendiri pada active Company.
- Store Manager membaca transaksi Store assignment; Company Admin dan Finance membaca transaksi Company aktif.
- Sales Detail dan Payment mengikuti visibility parent Sales Header.
- Purchase Header/Detail dibaca oleh role yang memiliki akses Store, termasuk Cashier penerima barang.
- Browser tidak mendapat INSERT/UPDATE/DELETE langsung ke enam tabel transaksi.
- Checkout lama tetap kompatibel melalui RPC, tetapi sekarang wajib memakai Session dari active Company.
- Implementasi checkout lama tetap dinyatakan sementara; perhitungan server canonical dibangun pada G4.

## Urutan Manual

1. Pastikan Phase 5B postflight, behavioral test, dan Backoffice smoke sudah aman.
2. Jalankan `supabase/diagnostics/g1_phase5c_transaction_rls_preflight.sql`.
3. Semua 5 baris harus `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export lalu jalankan migration `20260721090000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase5c_transaction_rls_postflight.sql`; harus 18 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase5c_transaction_rls_tests.sql`.
7. Reload Backoffice lokal. Dashboard, Product, Customer, dan Finance read harus tetap termuat.
8. Bila POS checkout lokal sudah digunakan, lakukan satu checkout test Company aktif dan pastikan tidak muncul `ACTIVE_COMPANY_MISMATCH`.

Expected notice:

```text
TEST PASSED: transaction reads follow actor/Store/Company scope and direct writes are blocked.
```

## Stop Condition

- Jangan migration bila preflight menemukan tenant mismatch atau checkout RPC hilang/tidak aman.
- Jika PostgREST read gagal, kirim tabel, role, active Company ID, dan error lengkap.
- Jangan memberi kembali direct INSERT/UPDATE pada Sales/Payment/Purchase untuk memperbaiki UI.
- Jika checkout menghasilkan `ACTIVE_COMPANY_MISMATCH`, pastikan selector Company sama dengan Company Session; jangan bypass wrapper.
- Jangan lanjut ke Finance/ledger RLS sampai seluruh test dan local smoke PASS.

## Forward Fix

Perbaikan setelah apply wajib melalui migration baru. Runtime masih lokal + Supabase; Vercel belum dibutuhkan.
