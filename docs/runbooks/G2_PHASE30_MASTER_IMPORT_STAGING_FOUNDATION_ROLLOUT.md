# G2 Phase 30 — Master Import Staging Foundation Rollout

## Status

`COMPLETE` — user mengonfirmasi migration, 11-check postflight, dan behavioral
test seluruhnya PASS.

## Hasil Preflight

Phase-29 live result tidak memiliki blocker:

- normalized identity seluruh master tidak duplikat;
- Product memiliki canonical reference dan Product-UOM group valid;
- belum ada Sales/Purchase/Movement history;
- browser tidak dapat menjalankan import legacy;
- satu expected `REVIEW` membuktikan legacy routine mencampur initial stock atau
  auto-master;
- tiga Product–Warehouse pair masih eligible untuk Opening Stock, tetapi tidak
  disentuh pada phase ini;
- Brand master belum ada dan tetap deferred sampai scope master-nya dibuka.

## Perubahan Foundation

Migration `20260723100000` membuat:

- `master_import_jobs`: tenant, idempotency key, jenis import, reference mode,
  operation mode, checksum file, mapping, status, counters, actor/time, version;
- `master_import_rows`: row asli, fingerprint, group key, hasil normalisasi,
  operation, warning/error, before/after state;
- `master_import_job_events`: history append-only CREATE/STAGE dan future
  lifecycle events;
- `create_master_import_job(...)`: guarded, tenant-safe, concurrency-safe, dan
  idempotent;
- `stage_master_import_rows(...)`: payload maksimal 5.000 row, validasi struktur
  sebelum replace, optimistic version, dan lost-response retry idempotent;
- RLS read-only untuk Company Owner/Admin serta Super Admin pada active Company;
- quarantine execute privilege untuk RPC legacy Product + initial stock.

Import type awal hanya master non-stock:

- Product Category;
- UOM;
- Warehouse;
- Supplier.

Phase ini belum memvalidasi isi field business dan belum melakukan commit ke
master. Product grouped import, CSV API/UI, export, file storage, Brand, dan
Opening Stock tetap deferred.

## Urutan Manual

### 1. Migration

```text
supabase/migrations/20260723100000_g2_phase30_master_import_staging_foundation.sql
```

### 2. Postflight

```text
supabase/diagnostics/g2_phase30_master_import_staging_postflight.sql
```

Expected: 11 row, seluruhnya `PASS`, `violation_rows = 0`.

### 3. Behavioral test

```text
supabase/tests/g2_phase30_master_import_staging_tests.sql
```

Expected notice:

```text
TEST PASSED: non-stock import staging is tenant-safe, idempotent, versioned, audited, and legacy Product+stock import is quarantined.
```

Test memakai transaction dan selalu `ROLLBACK`.

## Compatibility

- tidak mengubah Category/UOM/Warehouse/Supplier/Product existing;
- tidak membuat atau mengubah stok;
- route import lama tetap ada pada source untuk compatibility audit, tetapi RPC
  legacy tidak executable oleh API role;
- Backoffice import baru belum dibuka sampai validation/commit RPC tersedia;
- Opening Stock tetap dependency G3 atomic stock ledger.

## Next Safe Step

Validator dry-run empat master non-stock diteruskan pada phase 31. Commit tetap
fase terpisah setelah validator identitas dan field business terbukti.
