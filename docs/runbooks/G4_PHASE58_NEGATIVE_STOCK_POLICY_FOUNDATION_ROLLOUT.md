# G4 Phase 58 — Negative Stock Policy Foundation Rollout

Phase ini menyiapkan konfigurasi berlapis untuk STK-006 tanpa membuka transaksi
stok minus. Runtime berikutnya baru boleh mempertimbangkan pengecualian jika
entitlement Company, policy Company, opt-in Gudang sumber penjualan, permission
user, batas kuantitas, masa berlaku, alasan, dan audit semuanya valid.

Default setelah migration tetap **OFF**. Canonical Sale masih mengembalikan
`STOCK_SHORTAGE`; tabel authorization/allocation baru merupakan kontrak untuk
runtime dan rekonsiliasi replenishment berikutnya.

## Urutan Eksekusi

Jalankan file utuh satu per satu di Supabase SQL Editor:

1. `supabase/migrations/20260805190000_g4_phase58_negative_stock_policy_foundation.sql`
2. `supabase/diagnostics/g4_phase58_negative_stock_policy_postflight.sql`
3. `supabase/tests/g4_phase58_negative_stock_policy_tests.sql`
4. regression berikut:
   - `supabase/diagnostics/g4_phase56_customer_balance_tender_postflight.sql`
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`
   - `supabase/diagnostics/g4_phase4_atomic_sale_runtime_postflight.sql`
   - `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`
   - `supabase/tests/g1_security_closure_tests.sql`
5. jalankan kembali postflight Phase 58 sebagai closing check.

Hash migration yang diharapkan:

```text
c5d9823b3a7e8c7b04a8dfbe66f4ae7e457b0cb0ab36c378f3bd1ac5fef1bb76
```

## Kriteria Lulus

- semua row postflight berstatus `PASS` dan `violation_rows = 0`;
- behavioral test menampilkan notice `TEST PASSED` lalu rollback;
- tidak ada `product_stocks.stock_qty < 0` atau FIFO quantity negatif;
- browser tidak mempunyai direct write ke policy, permission, authorization,
  allocation, maupun Warehouse;
- canonical Sale masih fail-closed pada kekurangan stok.

## Compatibility dan Forward-Fix

- data Warehouse lama dipertahankan dan tetap `allow_negative_stock = FALSE`;
- tidak ada Sale, Movement, FIFO, Customer Balance, atau Finance history yang
  ditulis ulang;
- jangan mengedit migration setelah applied. Jika transaction rollback, kirim
  error lengkap, perbaiki file, lalu rerun. Jika ledger sudah ada, gunakan
  migration forward-fix baru;
- jangan aktifkan fitur untuk operasional sampai runtime authorization,
  allocation, replenishment, Backoffice UI, dan POS reason flow selesai diuji.

