# G3 Phase 12 — Canonical Bundle Foundation Rollout

## Status

`READY FOR MANUAL DATABASE ROLLOUT`

Live preflight dikonfirmasi user:

- seluruh invariant `PASS`;
- zero Bundle dan zero component row;
- zero physical stock/Movement/FIFO pada Bundle;
- zero backfill;
- dua Gudang sale-source aktif;
- direct component INSERT/UPDATE legacy masih terbuka dan akan ditutup;
- schema/audit/guarded RPC canonical belum tersedia sesuai expected.

## Scope Migration

Migration `20260729010000_g3_phase12_bundle_foundation.sql`:

- menambah canonical component UOM, quantity, line ordering, version, actor, dan
  timestamp pada `product_bundle_items`;
- menjaga kolom legacy `qty` tetap sinkron selama expand compatibility;
- menambah tenant FK, uniqueness, positive quantity, no-self, trigger nested,
  active component, serta Product type immutability;
- membuat audit composition;
- menyediakan atomic `save_bundle_with_components(...)`;
- menurunkan berat Bundle dari berat/UOM komponen;
- membuat private deterministic component expansion untuk G4;
- membuat reviewer availability per Gudang berdasarkan komponen pembatas;
- mencabut direct browser write pada composition.

Migration tidak mengaktifkan checkout, sale posting, component revenue
allocation, Return, Import Bundle, atau POS/offline.

## Urutan Eksekusi

### 1. Migration

Jalankan seluruh:

```text
supabase/migrations/20260729010000_g3_phase12_bundle_foundation.sql
```

Expected: `Success. No rows returned`.

Jika guard `G3_PHASE12_STATE_CHANGED` muncul, transaction rollback otomatis.
Jangan menghapus data; rerun preflight dan buat backfill eksplisit.

### 2. Postflight

Jalankan:

```text
supabase/diagnostics/g3_phase12_bundle_foundation_postflight.sql
```

Expected: 14 row dan seluruhnya `PASS`:

1. `migration_ledger`;
2. `required_bundle_columns`;
3. `required_bundle_constraints`;
4. `required_bundle_indexes`;
5. `required_bundle_triggers`;
6. `required_bundle_routines`;
7. `bundle_browser_privilege_boundary`;
8. `bundle_audit_rls`;
9. `invalid_bundle_component_shape`;
10. `duplicate_bundle_component_or_line`;
11. `active_bundle_composition_coverage`;
12. `bundle_virtual_stock_invariant`;
13. `bundle_uom_contract`;
14. `bundle_audit_inventory`.

### 3. Behavioral Test

Jalankan:

```text
supabase/tests/g3_phase12_bundle_foundation_tests.sql
```

Expected notice:

```text
TEST PASSED: Bundle save is atomic, tenant-safe, non-nested, versioned, audited, virtual-stock-only, and availability is component-limited.
```

Test dibungkus `BEGIN/ROLLBACK`.

### 4. Regression

Jalankan kembali:

```text
supabase/tests/g2_phase4_atomic_product_crud_tests.sql
supabase/tests/g3_phase10_stock_opname_foundation_tests.sql
supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql
supabase/tests/g3_phase6_stock_transfer_tests.sql
supabase/tests/g3_phase4_canonical_stock_movement_tests.sql
supabase/tests/g3_phase1_opening_stock_tests.sql
supabase/tests/g1_security_closure_tests.sql
```

Semua harus PASS.

## Compatibility

- Product `STOCK` dan RPC existing tetap aktif.
- `product_bundle_items.qty` tidak dihapus.
- Product type menjadi immutable; Product STOCK tidak dikonversi diam-diam
  menjadi Bundle dan sebaliknya.
- Bundle commercial UOM hanya sales-enabled dan factor `1`.
- Bundle tidak memperoleh `product_stocks`, `stock_movements`, atau
  `product_batches`.

## Rollback / Forward Fix

Migration transactional. Error sebelum `COMMIT` mengembalikan seluruh schema,
function, grant, dan data.

Setelah applied:

- jangan edit atau rerun migration;
- perbaiki dengan forward migration;
- jangan drop component/audit atau mengubah Bundle menjadi STOCK;
- checkout G4 harus menggunakan private expansion dan menyimpan snapshot
  transaksi, bukan membaca composition terbaru untuk histori.
