# Runbook G1 Fase 5E - Inventory Operation RLS

**Migration:** `supabase/migrations/20260721150000_g1_phase5e_inventory_operation_rls.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** FIFO allocation, Stock Opname, Opname Detail, Stock Adjustment, dan Stock Movement.

## Perubahan Keamanan

- Composite FK mencegah FIFO, Opname, Adjustment, dan Movement mengacu ke object Company lain.
- Company Admin, Store Manager, Warehouse Admin, dan Finance/Accounting dapat membaca data inventory-operation pada active Company.
- Cashier hanya dapat membaca header Stock Opname yang dibuatnya sendiri.
- Detail legacy tidak diberikan langsung kepada Cashier karena memuat `system_qty` dan `difference`; blind-count POS wajib memakai contract/view/RPC khusus pada fase implementasi.
- Cashier tidak dapat membaca FIFO allocation, Adjustment, atau Movement langsung.
- Lima tabel inventory-operation bersifat read-only dari browser.
- Legacy `transfer_product_stock()` tetap eksklusif `service_role` karena belum memiliki contract actor, active Company, idempotency, dan concurrency final.
- Workflow mutation canonical untuk Opname/Adjustment/Transfer tetap pekerjaan G2/G3; migration ini tidak mengklaim flow tersebut sudah tersedia.

## Urutan Manual

1. Pastikan Phase 5D DB test serta local POS/Backoffice smoke aman.
2. Jalankan `supabase/diagnostics/g1_phase5e_inventory_operation_rls_preflight.sql`.
3. Semua 5 baris wajib `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export lalu jalankan migration `20260721150000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase5e_inventory_operation_rls_postflight.sql`; harus 32 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase5e_inventory_operation_rls_tests.sql`.
7. Reload POS dan Backoffice lokal; menu existing harus tetap utuh dan Company aktif tetap benar.

Expected notice:

```text
TEST PASSED: inventory operation reads are scoped and browser mutations remain blocked.
```

## Stop Condition

- Jangan migration jika ada tenant mismatch, FIFO quantity invalid, atau arithmetic Opname lama yang tidak sesuai contract canonical.
- Jangan memperbaiki row live secara asumsi; kirim jumlah pelanggaran dan lakukan audit sumber data.
- Jangan memberi browser direct write hanya untuk membuat UI Adjustment/Opname bekerja.
- Jangan membuka legacy transfer RPC kepada `authenticated`.
- Jangan lanjut ke penutupan G1 sebelum DB test dan smoke lokal aman.

## Forward Fix

Setelah apply, perbaikan harus melalui migration baru. Vercel belum dibutuhkan.
