# G2 Phase 31 — Master Import Identity Validator Rollout

## Status

`COMPLETE` — user mengonfirmasi migration, 8-check postflight, dan behavioral
test Supabase seluruhnya PASS.

Phase-30 staging sudah dikonfirmasi user seluruhnya PASS. Phase ini hanya
menambahkan dry-run validator; tidak ada row business master yang di-commit.

## Scope

`validate_master_import_job(...)` memvalidasi common identity/lifecycle untuk:

- Product Category;
- UOM;
- Warehouse;
- Supplier.

Hasil per row disimpan sebagai:

- `CREATE`, `UPDATE`, `SKIP`, atau `ERROR`;
- normalized value;
- matched internal ID;
- before/after state;
- warning wajib untuk update existing;
- stable error code.

Aturan penting:

- matching selalu dibatasi active Company;
- mode ID menolak ID Company lain;
- mode Nama memakai nama ternormalisasi dan tidak menjadi jalur rename;
- kode atau nama duplikat dalam file membuat seluruh row terkait `ERROR`;
- satu row error tidak membatalkan preview row valid;
- retry dengan version lama setelah response hilang mengembalikan preview yang
  sama;
- validator tidak memanggil commit dan tidak mengubah Category/UOM/Warehouse/
  Supplier.

## Urutan Manual

### 1. Migration

Jalankan seluruh file:

```text
supabase/migrations/20260723130000_g2_phase31_master_import_identity_validator.sql
```

### 2. Postflight

```text
supabase/diagnostics/g2_phase31_master_import_identity_validator_postflight.sql
```

Expected: 8 row, seluruhnya `PASS`, `violation_rows = 0`.

### 3. Behavioral test

```text
supabase/tests/g2_phase31_master_import_identity_validator_tests.sql
```

Expected notice:

```text
TEST PASSED: dry-run import validation is tenant-safe, deterministic, idempotent, partial-error tolerant, duplicate-aware, and does not mutate master data.
```

Test dibungkus transaction dan selalu `ROLLBACK`.

## Compatibility dan Forward Fix

- Phase-30 job/staging contract tetap sama.
- Product import, Product-UOM grouped validation, Brand, API/UI, export, dan
  Opening Stock belum dibuka.
- Legacy Product+stock import tetap dikarantina dari API role.
- Jika rollout gagal, transaction migration rollback utuh. Jika sudah applied,
  gunakan forward migration; jangan edit migration ini.

## Next Safe Step

Validator field business empat master diteruskan pada phase 32. Commit tetap
disabled sampai phase tersebut lulus.
