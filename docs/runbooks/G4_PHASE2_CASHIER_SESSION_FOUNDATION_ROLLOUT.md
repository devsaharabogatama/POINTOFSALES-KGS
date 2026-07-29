# G4 Phase 2 — Cashier Session Foundation Rollout

## Status

`COMPLETE — USER-CONFIRMED ALL SUCCESS`

G4 Phase-1 readiness telah dikonfirmasi user:

- dependency, Store/Terminal/Gudang jual, Payment Method, Product-UOM, Walk-In,
  tenant reference, dan direct table-write boundary seluruhnya `PASS`;
- tidak ada Session `OPEN` atau histori Sale;
- legacy checkout masih client-authoritative, tidak memakai FIFO, tidak membuat
  canonical Movement, dan masih executable oleh browser;
- server price resolver dan canonical Sale runtime belum tersedia.

Tiga blocker terakhir adalah gap target G4, bukan kerusakan data. Phase ini
hanya memasang Session lifecycle. Legacy checkout tetap dilarang.

Evidence penutupan 29 Juli 2026: user mengonfirmasi migration, seluruh 13
postflight checks, behavioral test, dan regression berhasil. Next gate adalah
G4 Phase 3 Atomic Sale runtime SELECT-only preflight.

## Scope

Migration `20260729040000_g4_phase2_cashier_session_foundation.sql`:

- menambah Gudang jual, cash actual, snapshot timestamp, version, dan update
  timestamp pada Session existing;
- menjaga `opening_balance`, `actual_cash`, `expected_cash`, dan `difference`
  legacy tetap sinkron untuk compatibility;
- menegakkan satu Session `OPEN` per Cashier;
- menyediakan atomic `open_cashier_session(...)` dan
  `close_cashier_session(...)`;
- memvalidasi active Company, Terminal, Store assignment `CASHIER`, dan Gudang
  sale-source server-side;
- menyimpan snapshot seluruh Product STOCK aktif dalam base UOM pada pembukaan
  dan penutupan;
- membuat retry identik idempotent, optimistic version check, RLS, dan audit;
- menghitung expected cash dari opening cash dan posted Cash Sale yang sudah
  ada. Expense, Cash In/Out, Ketul, Refund, dan Deposit baru boleh ditambahkan
  saat source flow masing-masing dibuka.

Phase ini tidak membuat Sale Draft/Post, price/tax/payment resolver, FIFO Sale,
Bundle deduction, Return, offline allowance/queue, receipt, atau Finance
posting.

## Urutan Eksekusi

### 1. Migration

Jalankan seluruh:

```text
supabase/migrations/20260729040000_g4_phase2_cashier_session_foundation.sql
```

Expected:

```text
Success. No rows returned
```

Jika `G4_PHASE2_STATE_CHANGED` muncul, transaction otomatis rollback. Jangan
hapus Session. Tutup atau review Session legacy yang masih `OPEN`, rerun
Phase-1 preflight, lalu evaluasi ulang.

### 2. Postflight

Jalankan:

```text
supabase/diagnostics/g4_phase2_cashier_session_foundation_postflight.sql
```

Expected: 13 row, seluruhnya `PASS`:

1. `migration_ledger`;
2. `required_session_columns`;
3. `required_session_tables`;
4. `required_session_constraints`;
5. `required_session_indexes`;
6. `required_session_routines`;
7. `session_browser_write_boundary`;
8. `session_rpc_execute_boundary`;
9. `duplicate_open_cashier_session`;
10. `open_session_runtime_contract`;
11. `closed_session_cash_contract`;
12. `session_snapshot_shape`;
13. `session_audit_rls`.

### 3. Behavioral Test

Jalankan:

```text
supabase/tests/g4_phase2_cashier_session_foundation_tests.sql
```

Expected notice:

```text
TEST PASSED: Cashier Session open/close is tenant-safe, one-open, cash-counted, stock-snapshotted, versioned, idempotent, and audited.
```

Test menggunakan fixture lintas Company dan dibungkus `BEGIN/ROLLBACK`.

### 4. Regression

Jalankan kembali:

```text
supabase/tests/g3_phase15_inventory_core_stress_behavior_tests.sql
supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql
supabase/tests/g3_phase12_bundle_foundation_tests.sql
supabase/tests/g3_phase10_stock_opname_foundation_tests.sql
supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql
supabase/tests/g3_phase6_stock_transfer_tests.sql
supabase/tests/g3_phase4_canonical_stock_movement_tests.sql
supabase/tests/g3_phase1_opening_stock_tests.sql
supabase/tests/g2_phase14_payment_method_foundation_tests.sql
supabase/tests/g1_phase3_transaction_tenant_constraints_tests.sql
supabase/tests/g1_phase5c_transaction_rls_tests.sql
supabase/tests/g1_phase5d_finance_rls_tests.sql
supabase/tests/g1_phase5e_inventory_operation_rls_tests.sql
supabase/tests/g1_security_closure_tests.sql
```

Semua core invariant harus tetap `PASS`. `stress_fixture_readiness=SETUP` dan
`cross_gate_transaction_stock_coverage=DEFERRED` pada Phase-14 diagnostic tetap
expected sampai fixture/runtime G4/G5 tersedia.

## Compatibility

- tabel dan kolom Session legacy tidak dihapus;
- histori Session `CLOSED` dibackfill dari nilai legacy tanpa mengarang Gudang
  atau snapshot historis;
- direct mutation transaction table tetap tertutup;
- PWA/UI belum diarahkan ke RPC Session ini pada phase database foundation;
- wrapper `create_sales_transaction(...)` masih ada untuk compatibility, tetapi
  tetap dinyatakan unsafe dan tidak boleh dipakai.

## Rollback / Forward Fix

Migration transactional; error sebelum `COMMIT` mengembalikan seluruh DDL,
function, grant, dan backfill.

Setelah migration applied:

- jangan edit atau rerun file migration;
- gunakan forward migration untuk koreksi;
- jangan drop snapshot/audit atau membuka direct table writes;
- bila operasional harus dihentikan sebelum UI dipasang, cabut sementara
  `EXECUTE` dari dua RPC Session melalui forward fix terkontrol—jangan
  menghidupkan checkout legacy.

## Next Safe Step

Setelah migration, 13 postflight check, behavioral test, dan regression PASS:

1. tutup Phase-2 database foundation;
2. desain canonical Sale Draft/Post secara additive;
3. buat server price/payment/tax resolver dan FIFO/Bundle posting atomic;
4. baru setelah semua negative/retry/concurrency test lulus, cutover UI/PWA dan
   cabut browser execution dari checkout legacy.
