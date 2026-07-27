# Runbook G2 Fase 8 - Customer Foundation Rollout

**Scope:** Customer Category, canonical Customer identity, dan system Walk-In  
**Dependency:** Supplier foundation complete; Customer preflight clean  
**Status:** COMPLETE (DATABASE)

**Evidence 2026-07-21:** user mengonfirmasi migration sukses, 13/13
postflight `PASS`, dan behavioral test menghasilkan `TEST PASSED`.

## Perubahan

- `customer_categories` tenant-scoped dengan normalized unique code/name,
  lifecycle aktif, master version, dan audit;
- `customers` diperluas dengan Category, email, tipe Customer, credit term,
  active/system flag, notes, master version, actor, dan timestamp;
- satu kategori sistem `GENERAL / Umum` serta satu Customer sistem `WALK-IN /
  Pelanggan Umum` untuk setiap Company existing;
- trigger provisioning membuat default yang sama saat Company baru dibuat;
- kode Customer otomatis concurrency-safe `CUST-000001` per Company;
- system Walk-In tidak dapat diedit/dinonaktifkan melalui RPC;
- `current_balance` tidak tersedia sebagai input RPC dan tetap nol/read-only pada
  fase ini;
- credit limit/term hanya dapat diubah role Finance/Accounting atau hierarchy
  Company Admin/Owner; Store Manager tetap dapat mengelola identitas;
- direct authenticated INSERT/UPDATE/DELETE ditutup;
- mutation memakai `save_customer_category` dan `save_customer` dengan active
  Company, role, tenant reference, optimistic version, dan audit before/after.

## Urutan Manual

1. Jalankan migration sekali:
   `supabase/migrations/20260722010000_g2_phase8_customer_foundation.sql`.
2. Jika sukses, jalankan:
   `supabase/diagnostics/g2_phase8_customer_foundation_postflight.sql`.
3. Expected: 13 baris dan seluruhnya `PASS`.
4. Jalankan:
   `supabase/tests/g2_phase8_customer_foundation_tests.sql`.
5. Expected: query sukses dan notice terakhir berisi `TEST PASSED`.
6. Restart Backoffice dan smoke menu existing. UI Customer canonical belum
   dibuka sampai database evidence dikonfirmasi.

## Stop Condition

- Jangan menjalankan migration dua kali.
- Jika muncul `G2_PHASE8_STATE_CHANGED`, hentikan dan rerun preflight; jangan
  menghapus Customer untuk melewati guard.
- Jika migration gagal, transaction rollback otomatis; jangan menjalankan
  postflight/test.
- Jika ada postflight `FAIL`, kirim seluruh baris FAIL.
- Jika behavioral test gagal, kirim error persis. Semua fixture test rollback.
- Setelah applied, migration tidak boleh diedit; koreksi menggunakan forward
  migration baru.

## Belum Termasuk

- API/UI canonical Customer dan Customer Category (dilanjutkan pada fase 9);
- Cashier quick-create Customer;
- Customer Balance ledger dan correction workflow;
- TEMPO/AR, Customer Statement, Pricelist, Tax, atau Finance posting;
- import/export Customer;
- perubahan POS checkout atau stock.
