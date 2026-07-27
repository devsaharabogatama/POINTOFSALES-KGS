# Runbook G1 Fase 5D - Finance RLS

**Migration:** `supabase/migrations/20260721120000_g1_phase5d_finance_rls.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** legacy Cash Advance/Expense, Bank Deposit, Financial Event, Journal Entry, dan POS Reconciliation.

## Perubahan Keamanan

- Cashier hanya membaca Expense/Setoran yang dibuatnya sendiri.
- Store Manager dapat meninjau Expense/Setoran Store assignment.
- Company Admin dan Finance/Accounting membaca data Finance pada active Company.
- Cashier tidak dapat membaca Financial Event, Journal, atau Reconciliation.
- Browser tidak dapat memutasi lima tabel Finance secara langsung.
- Financial worker tetap eksklusif `service_role`.
- Composite FK mengikat Session, Store, Sales, Event, Journal, dan Reconciliation pada Company yang sama.
- Nama tabel `cash_advances` dipertahankan sementara; contract canonical akan menggunakan Expense.

## Urutan Manual

1. Pastikan Phase 5C DB test, POS, dan Backoffice smoke sudah aman.
2. Jalankan `supabase/diagnostics/g1_phase5d_finance_rls_preflight.sql`.
3. Semua 5 baris wajib `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export lalu jalankan migration `20260721120000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase5d_finance_rls_postflight.sql`; harus 31 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase5d_finance_rls_tests.sql`.
7. Reload Backoffice lokal; menu Finance dan jurnal harus tetap termuat untuk Super Admin.

Expected notice:

```text
TEST PASSED: Finance reads are scoped, Cashier cannot see ledger, and worker remains service-role-only.
```

## Stop Condition

- Jangan migration jika ada scope null, tenant mismatch, atau jurnal tidak balance.
- Jangan memberi Cashier SELECT ke Event/Jurnal atau direct write ke Expense/Setoran.
- Jangan memberi `authenticated` akses worker hanya untuk memperbaiki endpoint.
- Jika Finance Backoffice gagal termuat, kirim active Company ID dan error PostgREST lengkap.
- Jangan lanjut ke stock-operation RLS sebelum DB test dan local smoke aman.

## Forward Fix

Setelah apply, perbaikan harus melalui migration baru. Vercel belum dibutuhkan.
