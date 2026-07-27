# G2 Phase 33 — Master Import Partial Commit Rollout

## Status

`COMPLETE` — user mengonfirmasi migration, 9-check postflight, dan behavioral
test Supabase seluruhnya PASS.

Phase-32 business validator sudah dikonfirmasi user seluruhnya PASS. Phase ini
membuka commit hanya untuk Product Category, UOM, Warehouse, dan Supplier.

## Contract Commit

RPC:

```text
commit_master_import_job(job_id, master_version, confirm_update_count)
```

Guard yang berlaku:

- hanya Company Owner/Admin pada active Company;
- job harus `VALIDATED` dan optimistic job version harus cocok;
- jumlah row `UPDATE` wajib dikonfirmasi persis;
- master version disimpan saat preview;
- master yang berubah setelah preview tidak ditimpa dan menjadi row error
  `MASTER_CHANGED_AFTER_VALIDATION`;
- duplicate/FK/check race saat commit diisolasi pada row terkait;
- row valid lain tetap commit;
- retry response hilang mengembalikan hasil terminal yang sama;
- hasil akhir `COMPLETED` atau `COMPLETED_WITH_ERRORS`;
- row dan COMPLETE event menyimpan actor, before/after, result version, dan
  ringkasan;
- Supplier tetap menulis `supplier_master_audit`.

Commit tidak menyentuh Product, Product-UOM, stock balance, movement, FIFO,
Opening Stock, Sales, Purchase, atau Finance.

## Urutan Manual

1. Migration:

   ```text
   supabase/migrations/20260723190000_g2_phase33_master_import_partial_commit.sql
   ```

2. Postflight:

   ```text
   supabase/diagnostics/g2_phase33_master_import_partial_commit_postflight.sql
   ```

   Expected: 9 row seluruhnya `PASS`, `violation_rows = 0`.

3. Behavioral test:

   ```text
   supabase/tests/g2_phase33_master_import_partial_commit_tests.sql
   ```

   Expected notice:

   ```text
   TEST PASSED: non-stock import commit is confirmation-guarded, tenant-safe, partial-success, optimistic, audited, and idempotent without Product or stock mutation.
   ```

Test selalu `ROLLBACK`.

## Compatibility dan Rollback

- migration Phase 30–32 yang sudah applied tidak diedit;
- row preview lama diberi backfill matched master version;
- direct form CRUD existing tetap berjalan;
- bila migration gagal, transaction rollback utuh;
- bila sudah applied, gunakan forward fix dan jangan edit migration ini;
- API/UI canonical dibuka pada Phase 34 setelah database gate PASS.

## Next Safe Step

Lanjutkan authenticated smoke API/UI Phase 34. Product grouped import, Brand,
serta Opening Stock tetap fase terpisah.
