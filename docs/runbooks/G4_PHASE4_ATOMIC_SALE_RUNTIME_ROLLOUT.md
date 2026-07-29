# G4 Phase 4 — Atomic Sale Runtime Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

G4 Phase-3 live preflight telah direview:

- seluruh dependency, Cashier Session, commerce master, Product-UOM, assigned
  Tax, direct-write boundary, Finance category, dan rekonsiliasi
  Stock–Movement–FIFO `PASS`;
- Sale/Detail/Payment history masih kosong;
- dua `BLOCKER` hanya checkout legacy executable/client-authoritative;
- empat `SETUP` tepat pada schema, allocation, price resolver, dan Draft/Post
  RPC yang menjadi target migration ini.

## Scope

Migration `20260729070000_g4_phase4_atomic_sale_runtime.sql`:

- memasang snapshot canonical Sale header/detail/payment;
- membuat server price resolver Customer Pricelist → Global default →
  Product-UOM fallback;
- menyimpan Draft/Hold tanpa Payment final, Movement, FIFO mutation, atau
  Financial Event;
- selalu resolve ulang harga, discount, Tax, dan rounding ketika posting;
- mengembalikan `STOCK_SHORTAGE` sebagai Draft dengan requested/available/
  shortage tanpa partial effect;
- mengunci saldo dan FIFO, mengonsumsi layer oldest-first, serta membuat satu
  immutable Movement per Product/Gudang/Sale;
- mengurangi komponen Bundle, bukan stock Bundle, serta menyimpan component
  revenue/HPP allocation yang totalnya konservatif;
- memvalidasi Payment Method Store scope, fee, surcharge, proof URL,
  split-total, Cash tender/change, dan TEMPO boundary server-side;
- membuat receipt snapshot dan Financial Event `SALE_POSTED` berstatus `HOLD`
  untuk G6;
- menyediakan optimistic version dan posting idempotency;
- mencabut browser execution checkout legacy pada migration yang sama.

Customer Balance dan Ketul tetap ditolak eksplisit karena workflow mereka belum
dibuka. Offline allowance/queue, Return/Refund, Expense, Deposit, dan Finance
journal juga tetap deferred.

## Urutan Eksekusi

### 1. Migration

Jalankan seluruh:

```text
supabase/migrations/20260729070000_g4_phase4_atomic_sale_runtime.sql
```

Expected:

```text
Success. No rows returned
```

Jika `G4_PHASE4_STATE_CHANGED` muncul, transaction otomatis rollback. Jangan
menghapus Sale atau Movement; rerun Phase-3 preflight dan desain backfill
eksplisit.

### 2. Postflight

Jalankan:

```text
supabase/diagnostics/g4_phase4_atomic_sale_runtime_postflight.sql
```

Expected: 17 row dan seluruhnya `PASS`, termasuk:

- schema/table/routine dan migration ledger;
- checkout legacy retired dan canonical RPC boundary;
- direct Sale/stock writes tetap tertutup;
- Draft tanpa final effect;
- posted snapshot/FIFO/Movement/Finance coverage;
- Stock–Movement–FIFO reconciliation;
- Bundle allocation conservation.

### 3. Behavioral Test

Jalankan:

```text
supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql
```

Expected notice:

```text
TEST PASSED: Sale Draft/Post is server-priced, shortage-safe, tenant-safe, FIFO-posted, payment-snapshotted, idempotent, and Finance-evented.
```

Test dibungkus `BEGIN/ROLLBACK` dan mencakup:

- cross-Company Product-UOM rejection;
- payload harga/HPP/total client diabaikan;
- Draft tanpa effect;
- shortage tetap Draft;
- stale version rejection;
- two-layer FIFO;
- immutable Movement, Payment, receipt, dan Finance HOLD;
- retry posting tidak menggandakan effect;
- Bundle component deduction dan allocation conservation.

### 4. Regression

Jalankan:

```text
supabase/tests/g4_phase2_cashier_session_foundation_tests.sql
supabase/tests/g3_phase15_inventory_core_stress_behavior_tests.sql
supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql
supabase/tests/g3_phase12_bundle_foundation_tests.sql
supabase/tests/g3_phase10_stock_opname_foundation_tests.sql
supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql
supabase/tests/g3_phase6_stock_transfer_tests.sql
supabase/tests/g3_phase4_canonical_stock_movement_tests.sql
supabase/tests/g3_phase1_opening_stock_tests.sql
supabase/tests/g2_phase28_tax_resolver_calculator_tests.sql
supabase/tests/g2_phase14_payment_method_foundation_tests.sql
supabase/tests/g1_phase5c_transaction_rls_tests.sql
supabase/tests/g1_security_closure_tests.sql
```

Semua invariant wajib tetap lulus. G1 Phase-5c fixture menerima dua state:
sebelum G4 wrapper legacy menolak active-Company mismatch; setelah G4 browser
execution wrapper tersebut sudah dicabut sepenuhnya.

## Compatibility

- tabel/header/detail/payment legacy tetap ada;
- kolom technical baru memiliki compatibility default atau nullable boundary
  agar rollback-only regression fixture lama tetap dapat dibuat;
- hanya Sale canonical `POSTED` yang diwajibkan memiliki seluruh snapshot;
- direct table mutation tetap tertutup;
- checkout legacy function tetap ada untuk introspection/forward compatibility,
  tetapi `authenticated` tidak dapat mengeksekusinya;
- tidak ada UI/PWA cutover dalam phase database ini.

## Rollback / Forward Fix

Migration transactional. Error sebelum `COMMIT` mengembalikan DDL, function,
grant, dan retirement privilege.

Setelah applied:

- jangan edit atau rerun migration;
- koreksi hanya melalui forward migration;
- jangan menghidupkan kembali checkout legacy;
- jika runtime perlu dihentikan, cabut sementara `EXECUTE` pada
  `save_pos_sale_draft` dan `post_pos_sale` melalui forward fix;
- jangan menghapus Sale/Payment/Movement/FIFO/Event yang sudah posted.

## Next Safe Step

Setelah migration, 17 postflight checks, behavioral test, dan regression PASS:

1. tutup database Sale core;
2. buat Backoffice/PWA online Session + cart + Draft/Post integration;
3. jalankan authenticated E2E serta true concurrent double-post test;
4. baru desain offline allowance/queue dan acknowledgement;
5. Return/Refund, Expense, Deposit, Customer Balance, dan Ketul tetap mengikuti
   phase roadmap masing-masing.
